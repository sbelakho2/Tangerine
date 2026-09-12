(* tg_vmsem.ml — Seed VM kernel-closure primitive self-check.

   Hand-constructed Seed_mir programs (same construction style as
   tg_vmstrict.ml) proving the audit's remaining VM primitives:

     (a) DYNAMIC INDEX projections: the seed's dynamic-index form is
         `Seed_mir.Index local` — the payload is a LOCAL whose value is
         the runtime index.  Array element read (index 1 -> 20), a
         dynamic-indexed write (99 at index 1) read back (99), Tuple
         and String (char) element reads, and deterministic
         out-of-bounds traps (index 5, negative index) whose message
         contains "index"/"bounds".
     (b) POINTER DEREFERENCE: a u64 stored through a RawPtr deref and
         loaded back (4242), a String stored/loaded with an equality
         assert, and deterministic traps on out-of-bounds writes and
         reads of freed regions.
     (c) REF / REFMUT WRITEBACK: a RefMut of a local place writes
         through to the local (the local's value changes), reads back
         through the ref, and a projected ref (a tuple element) writes
         in place.  A computed-value ref (`Ref` of a deref) keeps a
         region copy: reads work, writes through it trap.
     (d) RECURSIVE DROP: a tuple containing a String and an inner tuple
         built by moves; after the outer Drop every contained slot has
         transitioned per the slot machine (String slot Moved, inner
         tuple slot Moved, outer slot Dropped), a second Drop traps
         ("drop of a dropped slot"), a read of the dropped slot traps,
         and the value-level glue frees a region-backed ref found
         inside a nested aggregate while leaving raw pointers alive.
     (e) SERIALIZATION: serialize/deserialize round-trips a nested
         value (ints, bool, char, string, array, enum).
     (f) PROJECTED MOVE/CONSUME — THE PARTIAL-MOVE SEMANTICS (audit P12
         / verifier rule 19a): the seed VM EXECUTES projected moves —
         `Move p`/`Consume p` on a place with projections reads the
         projected component and writes the MovedOut hole marker INTO
         the component; the root slot stays Live with the hole, reads
         through the hole trap, and the drop glue masks the holes.
         The verifier's moved lattice is projection-aware per place
         key and check_projected_move_transfer enforces the transfer
         rules at every projected Move/Consume operand:
         (a) a projected transfer is valid only when its moved key is
         Live (exact-key double move / a path under a moved component
         / any path out of a whole-moved root = second-consume
         rejections); (b) the root stays usable for reads/transfers
         of OTHER components while every WHOLE-root read/use of a
         partially-moved root is rejected; (c) an assign INTO the
         moved component re-initializes it (the key clears; whole-root
         use revives) while an assign deeper than a moved key writes
         through the hole (a rejection); (d) a whole-root Deinit/Drop
         with moved components is the sanctioned exit (the glue mask
         skips the holes) while a Deinit/Drop of a moved component
         itself is the double-destruction rejection.  The proof has
         two legs: VERIFIER — every legal case passes
         Mir_verify.require_valid_concrete AND require_valid_template
         and every illegal case is rejected with the precise finding;
         VM — the legal cases execute to their expected values with
         the hole left inside the still-Live root, and the glue-mask
         drop of a partially-moved root runs without trapping.  The
         two legs close the audit: verified programs and the executor
         agree about every projected transfer.
     (g) COLLECTION HOST-INTRINSIC WRITEBACK OWNERSHIP (audit P0-3):
         the collection intrinsics' copy-on-write writebacks carry the
         replaced container AND the `removed` members that left it;
         the VM's writeback application installs the replacement and
         then drops every removed value exactly once with the
         canonical per-type drop.  Region-backed refs serve as the
         owned element resources (region freed = dropped exactly once,
         still live = still owned, second free = deterministic trap),
         and VM memory is inspected after each run: array_set displace
         + scope end, OOB set (nothing consumed), pop transfer, clear,
         set remove (matched and resource fail-closed), map insert
         replace with nested Vec values, and adversarial
         Vec[Vec[String]] / Vec[Vec[Owned]] nesting.

   Prints PASS/FAIL per check and a final ALL PASS line. *)

let failures = ref 0

let fail fmt = Printf.ksprintf (fun s -> Printf.printf "FAIL: %s\n" s; incr failures) fmt
let pass fmt = Printf.ksprintf (fun s -> Printf.printf "PASS: %s\n" s) fmt

(* Substring test on VM error messages (err_trap prefixes them). *)
let contains (haystack : string) (needle : string) : bool =
  let h = String.length haystack and n = String.length needle in
  if n = 0 then true
  else if n > h then false
  else begin
    let rec go i =
      i + n <= h && (String.sub haystack i n = needle || go (i + 1))
    in
    go 0
  end

let i64 = Type_repr.Int Type_repr.Int
let string_ty = Type_repr.String
let raw_ptr_ty = Type_repr.Raw_ptr (Type_repr.Immutable, i64)
let ref_ty = Type_repr.Ref_internal (Type_repr.Mutable, i64)
let tuple2_ty = Type_repr.Tuple [| i64; i64 |]

let int_value (n : int64) : Seed_mir.constant =
  Seed_mir.Integer (Int_value.of_int64 ~width:64 ~signed:true n)

let int_op (n : int) : Seed_mir.operand = Seed_mir.Constant (int_value (Int64.of_int n))
let str_op (s : string) : Seed_mir.operand = Seed_mir.Constant (Seed_mir.String s)

(* The raw-pointer address codec (vm_memory.ml): the runtime `Ptr as Int`
   spelling.  The pointer selfchecks name the harness's pre-allocated
   regions through the codec — the address of region 0 is NOT the integer
   0 (0 is the null address). *)
let region0 : Vm_memory.pointer = { Vm_memory.region = 0; offset = 0 }

let addr_op (p : Vm_memory.pointer) : Seed_mir.operand =
  Seed_mir.Constant (int_value (Vm_memory.pointer_to_int64 p))

let instance (callable : int) : Instance_id.t =
  Instance_id.make ~callable:(Ids.Callable_id.make callable) ~type_args:[||]

let entry_of (prog : Seed_mir.program) : Instance_id.t =
  prog.Seed_mir.functions.(0).Seed_mir.instance

let run_program (prog : Seed_mir.program) : (int, Vm.vm_error) result =
  let host = Host.create ~repo_root:"." ~argv:[||] in
  Vm.run ~program:prog ~entry:(entry_of prog) ~argv:[||] ~host

let run_inspect (prog : Seed_mir.program) : (string, string) result =
  match Vm.entry_frame_of ~program:prog ~entry:(entry_of prog) ~argv:[||] with
  | Error m -> Error m
  | Ok (vm, frame) -> Vm.run_inspect vm frame

(* ── (a) dynamic index projections ────────────────────────────────── *)

let dyn_index_fn (locals : Type_repr.t array) (statements : Seed_mir.statement list)
    (terminator : Seed_mir.terminator) : Seed_mir.program =
  { Seed_mir.functions =
      [|
        { Seed_mir.name = "main";
          instance = instance 0;
          params = [||];
          locals;
          blocks = [| { id = 0; statements; terminator } |];
          entry = 0 };
      |];
    statics = [||];
    types = [||] }

let check_dyn_index () =
  (* array read: arr[_1] with _1 = 1 -> 20 *)
  (match
     run_inspect
       (dyn_index_fn
          [| i64; i64; i64; i64 |]
          [
            Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (int_op 1));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 2; projections = [] },
               Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 10; int_op 20; int_op 30 ]));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 3; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy { root = Seed_mir.Local 2; projections = [ Seed_mir.Index 1 ] }));
            Seed_mir.Assign ({ root = Seed_mir.Local 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { root = Seed_mir.Local 3; projections = [] }));
          ]
          Seed_mir.Ret)
   with
   | Ok "20" -> pass "dynamic index: arr[_1] with _1 = 1 reads 20"
   | Ok other -> fail "dynamic index read: unexpected return %s (expected 20)" other
   | Error m -> fail "dynamic index read: %s" m);
  (* dynamic-indexed write: arr[_1] = 99, then read back -> 99 *)
  (match
     run_inspect
       (dyn_index_fn
          [| i64; i64; i64 |]
          [
            Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (int_op 1));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 2; projections = [] },
               Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 10; int_op 20; int_op 30 ]));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 2; projections = [ Seed_mir.Index 1 ] },
               Seed_mir.Use (int_op 99));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 0; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy { root = Seed_mir.Local 2; projections = [ Seed_mir.Index 1 ] }));
          ]
          Seed_mir.Ret)
   with
   | Ok "99" -> pass "dynamic index: arr[_1] = 99 writes the element in place, read back 99"
   | Ok other -> fail "dynamic index write: unexpected return %s (expected 99)" other
   | Error m -> fail "dynamic index write: %s" m);
  (* out-of-bounds: index 5 on a 3-element array must trap *)
  (match
     run_program
       (dyn_index_fn
          [| i64; i64; i64; i64 |]
          [
            Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (int_op 5));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 2; projections = [] },
               Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 10; int_op 20; int_op 30 ]));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 3; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy { root = Seed_mir.Local 2; projections = [ Seed_mir.Index 1 ] }));
            Seed_mir.Assign ({ root = Seed_mir.Local 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { root = Seed_mir.Local 3; projections = [] }));
          ]
          Seed_mir.Ret)
   with
   | Error e when contains e.Vm.message "index" || contains e.Vm.message "bounds" ->
       pass "dynamic index: out-of-bounds index 5 traps deterministically (%s)" e.Vm.message
   | Error e -> fail "dynamic index: OOB trapped with the wrong message: %s" e.Vm.message
   | Ok _ -> fail "dynamic index: OOB index 5 did not trap");
  (* negative index must trap *)
  (match
     run_program
       (dyn_index_fn
          [| i64; i64; i64; i64 |]
          [
            Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (Seed_mir.Constant (int_value (-1L))));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 2; projections = [] },
               Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 10; int_op 20; int_op 30 ]));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 3; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy { root = Seed_mir.Local 2; projections = [ Seed_mir.Index 1 ] }));
            Seed_mir.Assign ({ root = Seed_mir.Local 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { root = Seed_mir.Local 3; projections = [] }));
          ]
          Seed_mir.Ret)
   with
   | Error e when contains e.Vm.message "index" || contains e.Vm.message "bounds" ->
       pass "dynamic index: negative index traps deterministically (%s)" e.Vm.message
   | Error e -> fail "dynamic index: negative index trapped with the wrong message: %s" e.Vm.message
   | Ok _ -> fail "dynamic index: negative index did not trap");
  (* tuple element read through a dynamic index *)
  (match
     run_inspect
       (dyn_index_fn
          [| i64; i64; i64; i64 |]
          [
            Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (int_op 0));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 2; projections = [] },
               Seed_mir.Aggregate (Seed_mir.TupleAgg, [ int_op 7; int_op 8 ]));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 3; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy { root = Seed_mir.Local 2; projections = [ Seed_mir.Index 1 ] }));
            Seed_mir.Assign ({ root = Seed_mir.Local 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { root = Seed_mir.Local 3; projections = [] }));
          ]
          Seed_mir.Ret)
   with
   | Ok "7" -> pass "dynamic index: tuple[_1] with _1 = 0 reads 7"
   | Ok other -> fail "dynamic index tuple: unexpected return %s (expected 7)" other
   | Error m -> fail "dynamic index tuple: %s" m);
  (* string char read through a dynamic index: "abc"[_1] with _1 = 2 is
     the Char 'c' (byte index, consistent with String.length) *)
  let str_prog =
    {
      Seed_mir.functions =
        [|
          { Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = [| i64; i64; string_ty; Type_repr.Char |];
            blocks =
              [|
                { id = 0;
                  statements =
                    [
                      Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (int_op 2));
                      Seed_mir.Assign ({ root = Seed_mir.Local 2; projections = [] }, Seed_mir.Use (str_op "abc"));
                      Seed_mir.Assign
                        ({ root = Seed_mir.Local 3; projections = [] },
                         Seed_mir.Use
                           (Seed_mir.Copy { root = Seed_mir.Local 2; projections = [ Seed_mir.Index 1 ] }));
                    ];
                  terminator =
                    Seed_mir.SwitchInt
                      (Seed_mir.Copy { root = Seed_mir.Local 3; projections = [] },
                       [ (99L, 1) ], 2) };
                { id = 1;
                  statements =
                    [ Seed_mir.Assign ({ root = Seed_mir.Local 0; projections = [] }, Seed_mir.Use (int_op 1)) ];
                  terminator = Seed_mir.Ret };
                { id = 2;
                  statements =
                    [ Seed_mir.Assign ({ root = Seed_mir.Local 0; projections = [] }, Seed_mir.Use (int_op 0)) ];
                  terminator = Seed_mir.Ret };
              |];
            entry = 0 };
        |];
      statics = [||];
      types = [||] }
  in
  (match run_inspect str_prog with
   | Ok "1" -> pass "dynamic index: string[_1] with _1 = 2 reads the char 'c'"
   | Ok other -> fail "dynamic index string: unexpected return %s (expected 1)" other
   | Error m -> fail "dynamic index string: %s" m)

(* ── (b) pointer dereference through the simulated memory ─────────── *)

let check_pointer () =
  let prog =
    {
      Seed_mir.functions =
        [|
          { Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = [| i64; i64; raw_ptr_ty; i64; string_ty; string_ty; Type_repr.Bool |];
            blocks =
              [|
                { id = 0;
                  statements =
                    [
                      Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (int_op 4242));
                      Seed_mir.Assign
                        ({ root = Seed_mir.Local 2; projections = [] },
                         Seed_mir.Cast (addr_op region0, raw_ptr_ty));
                      (* store the u64 through the RawPtr *)
                      Seed_mir.Assign
                        ({ root = Seed_mir.Local 2; projections = [ Seed_mir.Deref ] },
                         Seed_mir.Use (Seed_mir.Copy { root = Seed_mir.Local 1; projections = [] }));
                      (* load it back *)
                      Seed_mir.Assign
                        ({ root = Seed_mir.Local 3; projections = [] },
                         Seed_mir.Use
                           (Seed_mir.Copy { root = Seed_mir.Local 2; projections = [ Seed_mir.Deref ] }));
                      (* String round-trip through the same pointer *)
                      Seed_mir.Assign
                        ({ root = Seed_mir.Local 4; projections = [] }, Seed_mir.Use (str_op "hello, seed"));
                      Seed_mir.Assign
                        ({ root = Seed_mir.Local 2; projections = [ Seed_mir.Deref ] },
                         Seed_mir.Use (Seed_mir.Copy { root = Seed_mir.Local 4; projections = [] }));
                      Seed_mir.Assign
                        ({ root = Seed_mir.Local 5; projections = [] },
                         Seed_mir.Use
                           (Seed_mir.Copy { root = Seed_mir.Local 2; projections = [ Seed_mir.Deref ] }));
                      Seed_mir.Assign
                        ({ root = Seed_mir.Local 6; projections = [] },
                         Seed_mir.BinaryOp
                           ( Seed_mir.Eq,
                             Seed_mir.Copy { root = Seed_mir.Local 5; projections = [] },
                             str_op "hello, seed" ));
                    ];
                  terminator =
                    Seed_mir.Assert
                      (Seed_mir.Copy { root = Seed_mir.Local 6; projections = [] }, true,
                       "string deref round-trip mismatch", 1) };
                { id = 1;
                  statements = [ Seed_mir.Assign ({ root = Seed_mir.Local 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { root = Seed_mir.Local 3; projections = [] })) ];
                  terminator = Seed_mir.Ret };
              |];
            entry = 0 };
        |];
      statics = [||];
      types = [||] }
  in
  (match Vm.entry_frame_of ~program:prog ~entry:(entry_of prog) ~argv:[||] with
   | Error m -> fail "pointer: entry_frame_of: %s" m
   | Ok (vm, frame) -> (
       match Vm_memory.alloc vm.Vm.memory 64 8 with
       | Error e ->
           fail "pointer: harness pre-allocation failed: %s" (Vm_memory.mem_error_string e)
       | Ok _ -> (
           match Vm.run_inspect vm frame with
           | Ok "4242" ->
               pass "pointer: u64 store/load through a RawPtr deref (4242) and a String store/load round-trip (asserted equal)"
           | Ok other -> fail "pointer: unexpected return %s (expected 4242)" other
           | Error m -> fail "pointer: %s" m)));
  (* out-of-bounds deref write traps *)
  let prog_small =
    {
      Seed_mir.functions =
        [|
          { Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = [| i64; i64; raw_ptr_ty |];
            blocks =
              [|
                { id = 0;
                  statements =
                    [
                      Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (int_op 5));
                      Seed_mir.Assign
                        ({ root = Seed_mir.Local 2; projections = [] },
                         Seed_mir.Cast (addr_op region0, raw_ptr_ty));
                      Seed_mir.Assign
                        ({ root = Seed_mir.Local 2; projections = [ Seed_mir.Deref ] },
                         Seed_mir.Use (Seed_mir.Copy { root = Seed_mir.Local 1; projections = [] }));
                    ];
                  terminator = Seed_mir.Ret };
              |];
            entry = 0 };
        |];
      statics = [||];
      types = [||] }
  in
  (match Vm.entry_frame_of ~program:prog_small ~entry:(entry_of prog_small) ~argv:[||] with
   | Error m -> fail "pointer OOB: entry_frame_of: %s" m
   | Ok (vm, frame) -> (
       match Vm_memory.alloc vm.Vm.memory 1 1 with
       | Error e ->
           fail "pointer OOB: harness pre-allocation failed: %s" (Vm_memory.mem_error_string e)
       | Ok _ -> (
           match Vm.run_inspect vm frame with
           | Error m when contains m "bounds" ->
               pass "pointer: out-of-bounds deref write traps (%s)" m
           | Error m -> fail "pointer: OOB write trapped with the wrong message: %s" m
           | Ok _ -> fail "pointer: out-of-bounds deref write did not trap")));
  (* deref read of a freed region traps *)
  let prog_dead =
    {
      Seed_mir.functions =
        [|
          { Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = [| i64; i64; raw_ptr_ty; i64 |];
            blocks =
              [|
                { id = 0;
                  statements =
                    [
                      Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (int_op 7));
                      Seed_mir.Assign
                        ({ root = Seed_mir.Local 2; projections = [] },
                         Seed_mir.Cast (addr_op region0, raw_ptr_ty));
                      Seed_mir.Assign
                        ({ root = Seed_mir.Local 3; projections = [] },
                         Seed_mir.Use
                           (Seed_mir.Copy { root = Seed_mir.Local 2; projections = [ Seed_mir.Deref ] }));
                      Seed_mir.Assign ({ root = Seed_mir.Local 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { root = Seed_mir.Local 3; projections = [] }));
                    ];
                  terminator = Seed_mir.Ret };
              |];
            entry = 0 };
        |];
      statics = [||];
      types = [||] }
  in
  (match Vm.entry_frame_of ~program:prog_dead ~entry:(entry_of prog_dead) ~argv:[||] with
   | Error m -> fail "pointer dead: entry_frame_of: %s" m
   | Ok (vm, frame) -> (
       match Vm_memory.alloc vm.Vm.memory 32 8 with
       | Error e ->
           fail "pointer dead: harness pre-allocation failed: %s" (Vm_memory.mem_error_string e)
       | Ok p -> (
           match Vm_memory.free vm.Vm.memory p with
           | Error e ->
               fail "pointer dead: harness free failed: %s" (Vm_memory.mem_error_string e)
           | Ok () -> (
               match Vm.run_inspect vm frame with
               | Error m when contains m "freed" ->
                   pass "pointer: deref read of a freed region traps (%s)" m
               | Error m -> fail "pointer: freed-region read trapped with the wrong message: %s" m
               | Ok _ -> fail "pointer: deref read of a freed region did not trap"))))

(* ── (c) ref / refmut writeback ───────────────────────────────────── *)

let check_ref_writeback () =
  (* RefMut of a whole local: write through lands in the local *)
  (match
     run_inspect
       (dyn_index_fn
          [| i64; i64; ref_ty; i64 |]
          [
            Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (int_op 7));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 2; projections = [] },
               Seed_mir.RefMut { root = Seed_mir.Local 1; projections = [] });
            Seed_mir.Assign
              ({ root = Seed_mir.Local 2; projections = [ Seed_mir.Deref ] },
               Seed_mir.Use (int_op 99));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 3; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy { root = Seed_mir.Local 2; projections = [ Seed_mir.Deref ] }));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 0; projections = [] },
               Seed_mir.BinaryOp
                 ( Seed_mir.Add,
                   Seed_mir.Copy { root = Seed_mir.Local 1; projections = [] },
                   Seed_mir.Copy { root = Seed_mir.Local 3; projections = [] } ));
          ]
          Seed_mir.Ret)
   with
   | Ok "198" ->
       pass "ref writeback: writing through the RefMut updated the local in place (99 + 99 = 198)"
   | Ok other -> fail "ref writeback: unexpected return %s (expected 198)" other
   | Error m -> fail "ref writeback: %s" m);
  (* projected ref: a ref to a tuple element writes in place *)
  (match
     run_inspect
       (dyn_index_fn
          [| i64; tuple2_ty; ref_ty; i64; i64 |]
          [
            Seed_mir.Assign
              ({ root = Seed_mir.Local 1; projections = [] },
               Seed_mir.Aggregate (Seed_mir.TupleAgg, [ int_op 5; int_op 6 ]));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 2; projections = [] },
               Seed_mir.RefMut { root = Seed_mir.Local 1; projections = [ Seed_mir.ConstantIndex 1 ] });
            Seed_mir.Assign
              ({ root = Seed_mir.Local 2; projections = [ Seed_mir.Deref ] },
               Seed_mir.Use (int_op 77));
            Seed_mir.Assign
              ({ root = Seed_mir.Local 3; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy
                    { root = Seed_mir.Local 1; projections = [ Seed_mir.ConstantIndex 1 ] }));
            Seed_mir.Assign ({ root = Seed_mir.Local 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { root = Seed_mir.Local 3; projections = [] }));
          ]
          Seed_mir.Ret)
   with
   | Ok "77" ->
       pass "ref writeback: a ref to tuple element 1 writes through to the tuple in place"
   | Ok other -> fail "projected ref: unexpected return %s (expected 77)" other
   | Error m -> fail "projected ref: %s" m);
  (* computed-value ref (ref of a deref): reads load the region copy;
     writes through it trap *)
  let region_ref_prog (write : bool) : Seed_mir.program =
    let statements =
      [
        Seed_mir.Assign
          ({ root = Seed_mir.Local 2; projections = [] },
           Seed_mir.Cast (addr_op region0, raw_ptr_ty));
        Seed_mir.Assign
          ({ root = Seed_mir.Local 3; projections = [] },
           Seed_mir.Ref { root = Seed_mir.Local 2; projections = [ Seed_mir.Deref ] });
      ]
      @
      if write then
        [
          Seed_mir.Assign
            ({ root = Seed_mir.Local 3; projections = [ Seed_mir.Deref ] },
             Seed_mir.Use (int_op 1));
        ]
      else
        [
          Seed_mir.Assign
            ({ root = Seed_mir.Local 4; projections = [] },
             Seed_mir.Use
               (Seed_mir.Copy { root = Seed_mir.Local 3; projections = [ Seed_mir.Deref ] }));
          Seed_mir.Assign ({ root = Seed_mir.Local 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { root = Seed_mir.Local 4; projections = [] }));
        ]
    in
    {
      Seed_mir.functions =
        [|
          { Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = [| i64; i64; raw_ptr_ty; ref_ty; i64 |];
            blocks = [| { id = 0; statements; terminator = Seed_mir.Ret } |];
            entry = 0 };
        |];
      statics = [||];
      types = [||] }
  in
  let seed_region (vm : Vm.t) : (unit, string) result =
    match Vm_memory.alloc vm.Vm.memory 32 8 with
    | Error e -> Error (Vm_memory.mem_error_string e)
    | Ok p -> (
        match Vm_memory.bytes_of_region vm.Vm.memory p with
        | Error e -> Error (Vm_memory.mem_error_string e)
        | Ok bytes ->
            let payload = Vm_value.serialize (Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true 5L)) in
            Bytes.blit payload 0 bytes 0 (Bytes.length payload);
            Ok ())
  in
  let prog_r = region_ref_prog false in
  (match Vm.entry_frame_of ~program:prog_r ~entry:(entry_of prog_r) ~argv:[||] with
   | Error m -> fail "region ref: entry_frame_of: %s" m
   | Ok (vm, frame) -> (
       match seed_region vm with
       | Error m -> fail "region ref: harness seeding failed: %s" m
       | Ok () -> (
           match Vm.run_inspect vm frame with
           | Ok "5" -> pass "region ref: reading through a computed-value ref loads the region copy (5)"
           | Ok other -> fail "region ref: unexpected return %s (expected 5)" other
           | Error m -> fail "region ref: %s" m)));
  let prog_w = region_ref_prog true in
  (match Vm.entry_frame_of ~program:prog_w ~entry:(entry_of prog_w) ~argv:[||] with
   | Error m -> fail "region ref write: entry_frame_of: %s" m
   | Ok (vm, frame) -> (
       match seed_region vm with
       | Error m -> fail "region ref write: harness seeding failed: %s" m
       | Ok () -> (
           match Vm.run_inspect vm frame with
           | Error m when contains m "ref" ->
               pass "region ref: writing through a computed-value ref traps deterministically (%s)" m
           | Error m -> fail "region ref: write trapped with the wrong message: %s" m
           | Ok _ -> fail "region ref: writing through a computed-value ref did not trap")))

(* ── (d) recursive drop ───────────────────────────────────────────── *)

let drop_program () : Seed_mir.program =
  {
    Seed_mir.functions =
      [|
        { Seed_mir.name = "main";
          instance = instance 0;
          params = [||];
          locals =
            [| Type_repr.Unit; string_ty; tuple2_ty; Type_repr.Tuple [| string_ty; tuple2_ty |] |];
          blocks =
            [|
              { id = 0;
                statements =
                  [
                    Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (str_op "hello"));
                    Seed_mir.Assign
                      ({ root = Seed_mir.Local 2; projections = [] },
                       Seed_mir.Aggregate (Seed_mir.TupleAgg, [ int_op 10; int_op 20 ]));
                    Seed_mir.Assign
                      ({ root = Seed_mir.Local 3; projections = [] },
                       Seed_mir.Aggregate
                         ( Seed_mir.TupleAgg,
                           [ Seed_mir.Move { root = Seed_mir.Local 1; projections = [] };
                             Seed_mir.Move { root = Seed_mir.Local 2; projections = [] } ] ));
                  ];
                terminator = Seed_mir.Drop ({ root = Seed_mir.Local 3; projections = [] }, 1, None) };
              { id = 1; statements = []; terminator = Seed_mir.Ret };
            |];
          entry = 0 };
      |];
    statics = [||];
    types = [||] }

let check_recursive_drop () =
  let prog = drop_program () in
  (match Vm.entry_frame_of ~program:prog ~entry:(entry_of prog) ~argv:[||] with
   | Error m -> fail "recursive drop: entry_frame_of: %s" m
   | Ok (vm, frame) -> (
       match Vm.run_inspect vm frame with
       | Error m -> fail "recursive drop: %s" m
       | Ok _ -> (
           if Vm_value.slot_state frame.locals.(1) = "moved" then
             pass "recursive drop: the String slot moved into the aggregate is in the moved state"
           else
             fail "recursive drop: String slot state is %s (expected moved)"
               (Vm_value.slot_state frame.locals.(1));
           if Vm_value.slot_state frame.locals.(2) = "moved" then
             pass "recursive drop: the inner-tuple slot moved into the aggregate is in the moved state"
           else
             fail "recursive drop: inner-tuple slot state is %s (expected moved)"
               (Vm_value.slot_state frame.locals.(2));
           if Vm_value.slot_state frame.locals.(3) = "dropped" then
             pass "recursive drop: the outer tuple slot is in the dropped state"
           else
             fail "recursive drop: outer slot state is %s (expected dropped)"
               (Vm_value.slot_state frame.locals.(3)))));
  (* a second Drop of the same slot traps deterministically *)
  let double_prog =
    {
      Seed_mir.functions =
        [|
          { Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = [| Type_repr.Unit; string_ty |];
            blocks =
              [|
                { id = 0; statements = [ Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (str_op "x")) ];
                  terminator = Seed_mir.Drop ({ root = Seed_mir.Local 1; projections = [] }, 1, None) };
                { id = 1; statements = [];
                  terminator = Seed_mir.Drop ({ root = Seed_mir.Local 1; projections = [] }, 2, None) };
                { id = 2; statements = []; terminator = Seed_mir.Ret };
              |];
            entry = 0 };
        |];
      statics = [||];
      types = [||] }
  in
  (match run_program double_prog with
   | Error e when contains e.Vm.message "drop of a dropped slot" ->
       pass "recursive drop: a second drop of the dropped slot traps (\"drop of a dropped slot\")"
   | Error e -> fail "recursive drop: double drop trapped with the wrong message: %s" e.Vm.message
   | Ok _ -> fail "recursive drop: a second drop of the dropped slot did not trap");
  (* reading a dropped slot traps *)
  let read_dropped_prog =
    {
      Seed_mir.functions =
        [|
          { Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = [| i64; string_ty; i64 |];
            blocks =
              [|
                { id = 0; statements = [ Seed_mir.Assign ({ root = Seed_mir.Local 1; projections = [] }, Seed_mir.Use (str_op "x")) ];
                  terminator = Seed_mir.Drop ({ root = Seed_mir.Local 1; projections = [] }, 1, None) };
                { id = 1;
                  statements =
                    [
                      Seed_mir.Assign
                        ({ root = Seed_mir.Local 2; projections = [] },
                         Seed_mir.Use (Seed_mir.Copy { root = Seed_mir.Local 1; projections = [] }));
                      Seed_mir.Assign ({ root = Seed_mir.Local 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { root = Seed_mir.Local 2; projections = [] }));
                    ];
                  terminator = Seed_mir.Ret };
              |];
            entry = 0 };
        |];
      statics = [||];
      types = [||] }
  in
  (match run_program read_dropped_prog with
   | Error e when contains e.Vm.message "moved slot" ->
       pass "recursive drop: reading the dropped slot traps (\"read of a moved slot\")"
   | Error e -> fail "recursive drop: read-after-drop trapped with the wrong message: %s" e.Vm.message
   | Ok _ -> fail "recursive drop: reading the dropped slot did not trap");
  (* value-level glue: a region-backed ref nested inside the tuple is
     freed by the recursion; a raw pointer is not owned *)
  let m = Vm_memory.create () in
  (match Vm_memory.alloc m 32 8 with
   | Error e -> fail "drop glue: alloc 1 failed: %s" (Vm_memory.mem_error_string e)
   | Ok owned -> (
       match Vm_memory.alloc m 32 8 with
       | Error e -> fail "drop glue: alloc 2 failed: %s" (Vm_memory.mem_error_string e)
       | Ok raw -> (
           let v =
             Vm_value.Tuple
               [|
                 Vm_value.String "s";
                 Vm_value.Tuple
                   [| Vm_value.Ref (Vm_value.Region owned); Vm_value.RawPtr raw |];
               |]
           in
           Vm_value.drop_glue m v;
           (match Vm_memory.region_of m owned with
            | Error _ ->
                pass "drop glue: the region-backed ref inside the nested tuple was freed by the recursion"
            | Ok _ ->
                fail "drop glue: the region-backed ref's region was NOT freed by the recursive glue");
            (match Vm_memory.region_of m raw with
             | Ok _ -> pass "drop glue: a raw pointer inside the tuple is not owned (region stays live)"
             | Error e ->
                 fail "drop glue: the raw-pointer region was freed: %s" (Vm_memory.mem_error_string e)))))

(* ── (e) serialization round-trip ─────────────────────────────────── *)

let check_serialization () =
  let v =
    Vm_value.Tuple
      [|
        Vm_value.Int (Int_value.of_int64 ~width:32 ~signed:false 0xDEADBEEFL);
        Vm_value.Int (Int_value.of_int64 ~width:128 ~signed:true (-1L));
        Vm_value.Bool true;
        Vm_value.Char (Uchar.of_int 0x1F600);
        Vm_value.String "h\195\169llo";
        Vm_value.Array [| Vm_value.Float64 0x3FF0000000000000L; Vm_value.Unit |];
        Vm_value.Enum (1, [| Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true 42L) |]);
      |]
  in
  let back = Vm_value.deserialize (Vm_value.serialize v) in
  if Vm_value.equal v back then
    pass "serialization: nested value round-trips (u32/i128/bool/char/utf-8 string/array/float/enum)"
  else
    fail "serialization: round-trip produced a different value"

(* ── (f) projected Move/Consume — the partial-move semantics (audit
       P12 / verifier rule 19a) ─────────────────────────────────────

   The seed VM EXECUTES projected moves: `Move p`/`Consume p` on a
   place WITH projections reads the projected component and writes the
   MovedOut hole marker INTO the component — the root slot stays Live
   with the hole, reads through the hole trap, and the drop glue masks
   the holes (a whole-root Drop/Deinit of a partially-moved root drops
   exactly the still-owned remainder).  The verifier's moved lattice is
   projection-aware per place key, and check_projected_move_transfer
   enforces the transfer rules at every projected Move/Consume operand
   position:
     (a) a projected transfer is valid only when its moved key is Live
         in the lattice — the exact-key double move, a path under a
         moved component, and any path out of a whole-moved root are
         the second-consume rejections;
     (b) the root stays usable for the OTHER components (sibling
         reads/transfers are legal) while every WHOLE-root read/use of
         a root any component of which is moved is rejected;
     (c) an assign INTO the moved component re-initializes it (the
         hole is replaced in place, the key clears, and whole-root use
         is valid again); an assign deeper than a moved key writes
         through the hole (a rejection);
     (d) a whole-root Deinit/Drop with moved components is the
         sanctioned partial-move exit (the glue mask skips the holes),
         while a Deinit/Drop of a moved component itself is the
         double-destruction rejection.
   Each legal case is proven through the VERIFIER (concrete AND
   template mode) and executed in the VM to its expected value; each
   illegal case is proven rejected in both modes. *)

let tuple2_ty_str = Type_repr.Tuple [| string_ty; i64 |]
let arr2_str_ty = Type_repr.Fixed_array (string_ty, 2)

let s1_tid = Ids.Type_id.make 101
let s1_ty = Type_repr.Named (s1_tid, [||])
let s2_tid = Ids.Type_id.make 102
let s2_ty = Type_repr.Named (s2_tid, [||])

let mk_fd (fid : int) (idx : int) (ty : Type_repr.t) : Seed_mir.field_def =
  { Seed_mir.fd_id = Ids.Field_id.make fid; fd_index = Ids.Field_index.make idx; fd_ty = ty }

(* struct S1 { a: String, b: Int } — the Field-projection root *)
let s1_def : Seed_mir.type_def =
  Seed_mir.StructDef
    { sd_id = s1_tid; sd_fields = [ mk_fd 1 0 string_ty; mk_fd 2 1 i64 ] }

(* struct S2 { a: (String, Int), b: Int } — the NESTED chain (a struct
   field holding a tuple: Field then ConstantIndex) *)
let s2_def : Seed_mir.type_def =
  Seed_mir.StructDef
    { sd_id = s2_tid; sd_fields = [ mk_fd 3 0 tuple2_ty_str; mk_fd 4 1 i64 ] }

let pl (n : int) : Seed_mir.place = { Seed_mir.root = Seed_mir.Local n; projections = [] }

let plp (n : int) (projs : Seed_mir.projection list) : Seed_mir.place =
  { Seed_mir.root = Seed_mir.Local n; projections = projs }

let cidx (i : int) : Seed_mir.projection = Seed_mir.ConstantIndex i
let fid (n : int) : Seed_mir.projection = Seed_mir.Field (Ids.Field_id.make n)

let prog_with_types (locals : Type_repr.t array) (types : Seed_mir.type_def array)
    (blocks : Seed_mir.block array) : Seed_mir.program =
  { Seed_mir.functions =
      [|
        { Seed_mir.name = "main";
          instance = instance 0;
          params = [||];
          locals;
          blocks;
          entry = 0 };
      |];
    statics = [||];
    types }

let single_block (locals : Type_repr.t array) (types : Seed_mir.type_def array)
    (statements : Seed_mir.statement list) (terminator : Seed_mir.terminator) :
    Seed_mir.program =
  prog_with_types locals types [| { Seed_mir.id = 0; statements; terminator } |]

let s1_value (a : Seed_mir.operand) (b : Seed_mir.operand) : Seed_mir.rvalue =
  Seed_mir.Aggregate
    ( Seed_mir.StructCtor (s1_tid, [| Ids.Field_index.make 0; Ids.Field_index.make 1 |]),
      [ a; b ] )

let s2_value (a : Seed_mir.operand) (b : Seed_mir.operand) : Seed_mir.rvalue =
  Seed_mir.Aggregate
    ( Seed_mir.StructCtor (s2_tid, [| Ids.Field_index.make 0; Ids.Field_index.make 1 |]),
      [ a; b ] )

let projected_consume_arg_prog () : Seed_mir.program =
  let callee =
    {
      Seed_mir.name = "take";
      instance = instance 1;
      params = [| { Type_repr.pt_convention = Access_effect.Sink; pt_type = string_ty } |];
      locals = [| i64; string_ty |];
      blocks =
        [|
          {
            Seed_mir.id = 0;
            statements = [ Seed_mir.Assign ({ root = Seed_mir.Local 0; projections = [] }, Seed_mir.Use (int_op 0)) ];
            terminator = Seed_mir.Ret;
          };
        |];
      entry = 0;
    }
  in
  let main =
    {
      Seed_mir.name = "main";
      instance = instance 0;
      params = [||];
      locals = [| i64; tuple2_ty_str |];
      blocks =
        [|
          {
            Seed_mir.id = 0;
            statements =
              [
                Seed_mir.Assign
                  ({ root = Seed_mir.Local 1; projections = [] },
                   Seed_mir.Aggregate (Seed_mir.TupleAgg, [ str_op "hello"; int_op 42 ]));
              ];
            terminator =
              Seed_mir.Call
                ( { root = Seed_mir.Local 0; projections = [] },
                  Seed_mir.User (instance 1),
                  [|
                    {
                      Seed_mir.effect_ = Access_effect.Consume;
                      value =
                        Seed_mir.Move { root = Seed_mir.Local 1; projections = [ Seed_mir.ConstantIndex 0 ] };
                    };
                  |],
                  1,
                  None );
          };
          { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  { Seed_mir.functions = [| main; callee |]; statics = [||]; types = [||] }

let check_projected_move () =
  (* leg 1: the verifier — every LEGAL projected transfer passes
     concrete mode (the pre-VM gate) and template mode alike; every
     ILLEGAL one is rejected with the precise finding *)
  let expect_accept (name : string) (prog : Seed_mir.program) =
    (match Mir_verify.require_valid_concrete prog with
     | Ok () -> pass "%s: verifier accepts (concrete mode)" name
     | Error errs ->
         fail "%s: verifier rejected (concrete mode): %s" name
           (String.concat "; " errs));
    (match Mir_verify.require_valid_template prog with
     | Ok () -> pass "%s: verifier accepts (template mode)" name
     | Error errs ->
         fail "%s: verifier rejected (template mode): %s" name
           (String.concat "; " errs))
  in
  let expect_verify_reject (name : string) (prog : Seed_mir.program) (needle : string) =
    (match Mir_verify.require_valid_concrete prog with
     | Error errs when List.exists (fun e -> contains e needle) errs ->
         pass "%s: verifier rejects with %S (concrete mode)" name needle
     | Ok () -> fail "%s: verifier ACCEPTED (concrete mode)" name
     | Error errs ->
         fail "%s: verifier rejected with the wrong message: %s" name
           (String.concat "; " errs));
    (match Mir_verify.require_valid_template prog with
     | Error errs when List.exists (fun e -> contains e needle) errs ->
         pass "%s: verifier rejects with %S (template mode)" name needle
     | Ok () -> fail "%s: verifier ACCEPTED (template mode)" name
     | Error errs ->
         fail "%s: verifier rejected with the wrong message (template mode): %s" name
           (String.concat "; " errs))
  in
  (* leg 2: the VM executes the legal programs — the projected
     component transfers out and the MovedOut hole stays inside the
     still-Live root *)
  let expect_vm (name : string) (prog : Seed_mir.program) (expected : string) =
    match run_inspect prog with
    | Ok s when s = expected ->
        pass "%s: VM executes to %s (projected move left the hole; the root stayed Live)"
          name expected
    | Ok other -> fail "%s: unexpected VM result %s (expected %s)" name other expected
    | Error m -> fail "%s: %s" name m
  in
  let expect_vm_state (name : string) (prog : Seed_mir.program) (slot : int)
      (state : string) =
    match Vm.entry_frame_of ~program:prog ~entry:(entry_of prog) ~argv:[||] with
    | Error m -> fail "%s: entry_frame_of: %s" name m
    | Ok (vm, frame) -> (
        match Vm.run_inspect vm frame with
        | Error m -> fail "%s: %s" name m
        | Ok _ ->
            if Vm_value.slot_state frame.locals.(slot) = state then
              pass "%s: local _%d ends in state %s" name slot state
            else
              fail "%s: local _%d ends in state %s (expected %s)" name slot
                (Vm_value.slot_state frame.locals.(slot)) state)
  in

  (* ── (a) move component 0, then read the SIBLING component — valid,
     both modes, and the VM reads 42 back through the hole-free path
     while the root slot stays Live *)
  let sibling_read =
    single_block
      [| i64; tuple2_ty_str; string_ty |]
      [||]
      [
        Seed_mir.Assign (pl 1, Seed_mir.Aggregate (Seed_mir.TupleAgg, [ str_op "hello"; int_op 42 ]));
        Seed_mir.Assign (pl 2, Seed_mir.Use (Seed_mir.Move (plp 1 [ cidx 0 ])));
        Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Copy (plp 1 [ cidx 1 ])));
      ]
      Seed_mir.Ret
  in
  expect_accept "move tuple component 0 then read sibling component 1" sibling_read;
  expect_vm "move tuple component 0 then read sibling component 1" sibling_read "42";
  expect_vm_state "move tuple component 0 then read sibling component 1"
    sibling_read 1 "live";
  (* ── (b) whole-root use of a partially-moved root — rejected *)
  let whole_root_use =
    single_block
      [| i64; tuple2_ty_str; string_ty |]
      [||]
      [
        Seed_mir.Assign (pl 1, Seed_mir.Aggregate (Seed_mir.TupleAgg, [ str_op "hello"; int_op 42 ]));
        Seed_mir.Assign (pl 2, Seed_mir.Use (Seed_mir.Move (plp 1 [ cidx 0 ])));
        Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Move (pl 1)));
      ]
      Seed_mir.Ret
  in
  expect_verify_reject "whole-root move of a partially-moved root" whole_root_use
    "second consume";
  (* ── (a) double projected move of the exact key — rejected; the
     Consume verb is governed by the same lattice *)
  let double_projected (second : Seed_mir.operand) : Seed_mir.program =
    single_block
      [| Type_repr.Unit; tuple2_ty_str; string_ty; string_ty |]
      [||]
      [
        Seed_mir.Assign (pl 1, Seed_mir.Aggregate (Seed_mir.TupleAgg, [ str_op "hello"; int_op 42 ]));
        Seed_mir.Assign (pl 2, Seed_mir.Use (Seed_mir.Move (plp 1 [ cidx 0 ])));
        Seed_mir.Assign (pl 3, Seed_mir.Use second);
      ]
      Seed_mir.Ret
  in
  expect_verify_reject "move of an already-moved component (double projected move)"
    (double_projected (Seed_mir.Move (plp 1 [ cidx 0 ])))
    "second consume";
  expect_verify_reject
    "consume verb after the component already moved (the lattice does not distinguish verbs)"
    (double_projected (Seed_mir.Consume (plp 1 [ cidx 0 ])))
    "second consume";
  (* ── (a) a projected move out of a WHOLE-moved root (the "" key
     covers every path) — rejected *)
  let move_of_moved_root =
    single_block
      [| Type_repr.Unit; tuple2_ty_str; tuple2_ty_str; string_ty |]
      [||]
      [
        Seed_mir.Assign (pl 1, Seed_mir.Aggregate (Seed_mir.TupleAgg, [ str_op "hello"; int_op 42 ]));
        Seed_mir.Assign (pl 2, Seed_mir.Use (Seed_mir.Move (pl 1)));
        Seed_mir.Assign (pl 3, Seed_mir.Use (Seed_mir.Move (plp 1 [ cidx 0 ])));
      ]
      Seed_mir.Ret
  in
  expect_verify_reject "projected move out of a whole-moved root" move_of_moved_root
    "whole root was already moved out";
  (* ── (c) re-initialize the moved component, then use the whole root
     again — valid in both modes and in the VM (the assign replaces
     the hole in place; the whole-root move revives) *)
  let reinit_whole =
    single_block
      [| i64; tuple2_ty_str; string_ty; tuple2_ty_str |]
      [||]
      [
        Seed_mir.Assign (pl 1, Seed_mir.Aggregate (Seed_mir.TupleAgg, [ str_op "hello"; int_op 42 ]));
        Seed_mir.Assign (pl 2, Seed_mir.Use (Seed_mir.Move (plp 1 [ cidx 0 ])));
        Seed_mir.Assign (plp 1 [ cidx 0 ], Seed_mir.Use (str_op "reborn"));
        Seed_mir.Assign (pl 3, Seed_mir.Use (Seed_mir.Move (pl 1)));
        Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Copy (plp 3 [ cidx 1 ])));
      ]
      Seed_mir.Ret
  in
  expect_accept "re-initialize the moved component then use the whole root" reinit_whole;
  expect_vm "re-initialize the moved component then use the whole root" reinit_whole "42";
  expect_vm_state "re-initialize the moved component then use the whole root"
    reinit_whole 1 "moved";
  (* ── (d) a whole-root Deinit with one moved FIELD is the sanctioned
     partial-move exit — the glue mask skips the hole (the VM's typed
     drop is a no-op over MovedOut), the root slot ends Dropped and
     nothing double-destroys *)
  let deinit_moved_root =
    prog_with_types
      [| Type_repr.Unit; s1_ty; string_ty |]
      [| s1_def |]
      [|
        { Seed_mir.id = 0;
          statements =
            [
              Seed_mir.Assign (pl 1, s1_value (str_op "keep") (int_op 7));
              Seed_mir.Assign (pl 2, Seed_mir.Use (Seed_mir.Move (plp 1 [ fid 1 ])));
            ];
          terminator = Seed_mir.Deinit (pl 1, 1, None) };
        { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  expect_accept "Deinit of the whole root with one moved field" deinit_moved_root;
  expect_vm_state "Deinit of the whole root with one moved field (glue masks the hole)"
    deinit_moved_root 1 "dropped";
  (* ── (d) a Deinit of the moved component ITSELF is the
     double-destruction rejection *)
  let deinit_moved_field =
    prog_with_types
      [| Type_repr.Unit; s1_ty; string_ty |]
      [| s1_def |]
      [|
        { Seed_mir.id = 0;
          statements =
            [
              Seed_mir.Assign (pl 1, s1_value (str_op "keep") (int_op 7));
              Seed_mir.Assign (pl 2, Seed_mir.Use (Seed_mir.Move (plp 1 [ fid 1 ])));
            ];
          terminator = Seed_mir.Deinit (plp 1 [ fid 1 ], 1, None) };
        { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  expect_verify_reject "Deinit of the moved component itself (double destruction)"
    deinit_moved_field "previously moved";
  (* ── fixed-array (ConstantIndex) chains: element moves are
     per-index keys — element 1 stays movable after element 0 moved,
     and the whole-root use after an element move is rejected *)
  let fixed_siblings =
    single_block
      [| string_ty; arr2_str_ty; string_ty; string_ty |]
      [||]
      [
        Seed_mir.Assign (pl 1, Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ str_op "x"; str_op "y" ]));
        Seed_mir.Assign (pl 2, Seed_mir.Use (Seed_mir.Move (plp 1 [ cidx 0 ])));
        Seed_mir.Assign (pl 3, Seed_mir.Use (Seed_mir.Move (plp 1 [ cidx 1 ])));
        Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Move (pl 3)));
      ]
      Seed_mir.Ret
  in
  expect_accept "fixed array: move element 0 then move sibling element 1" fixed_siblings;
  expect_vm "fixed array: move element 0 then move sibling element 1" fixed_siblings "y";
  let fixed_whole_use =
    single_block
      [| Type_repr.Unit; arr2_str_ty; string_ty; arr2_str_ty |]
      [||]
      [
        Seed_mir.Assign (pl 1, Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ str_op "x"; str_op "y" ]));
        Seed_mir.Assign (pl 2, Seed_mir.Use (Seed_mir.Move (plp 1 [ cidx 0 ])));
        Seed_mir.Assign (pl 3, Seed_mir.Use (Seed_mir.Move (pl 1)));
      ]
      Seed_mir.Ret
  in
  expect_verify_reject "whole-root move of a fixed array after an element move"
    fixed_whole_use "second consume";
  (* ── NESTED chains (Field then ConstantIndex): the deep move keys
     the full path — the deep sibling reads through the live
     remainder, the whole root and the deeper component stay
     governed by the same rules *)
  let nested_sibling =
    single_block
      [| i64; s2_ty; string_ty; tuple2_ty_str |]
      [| s2_def |]
      [
        Seed_mir.Assign (pl 3, Seed_mir.Aggregate (Seed_mir.TupleAgg, [ str_op "deep"; int_op 42 ]));
        Seed_mir.Assign (pl 1, s2_value (Seed_mir.Move (pl 3)) (int_op 7));
        Seed_mir.Assign
          ( pl 2,
            Seed_mir.Use
              (Seed_mir.Move (plp 1 [ fid 3; cidx 0 ])) );
        Seed_mir.Assign
          ( pl 0,
            Seed_mir.Use
              (Seed_mir.Copy (plp 1 [ fid 3; cidx 1 ])) );
      ]
      Seed_mir.Ret
  in
  expect_accept "nested chain: move the tuple component inside the field then read the deep sibling"
    nested_sibling;
  expect_vm "nested chain: move the tuple component inside the field then read the deep sibling"
    nested_sibling "42";
  let nested_whole_use =
    single_block
      [| i64; s2_ty; string_ty; tuple2_ty_str; s2_ty |]
      [| s2_def |]
      [
        Seed_mir.Assign (pl 3, Seed_mir.Aggregate (Seed_mir.TupleAgg, [ str_op "deep"; int_op 42 ]));
        Seed_mir.Assign (pl 1, s2_value (Seed_mir.Move (pl 3)) (int_op 7));
        Seed_mir.Assign
          ( pl 2,
            Seed_mir.Use
              (Seed_mir.Move (plp 1 [ fid 3; cidx 0 ])) );
        Seed_mir.Assign (pl 4, Seed_mir.Use (Seed_mir.Move (pl 1)));
      ]
      Seed_mir.Ret
  in
  expect_verify_reject "whole-root use after a deep nested move" nested_whole_use
    "second consume";
  let nested_deinit_root =
    prog_with_types
      [| Type_repr.Unit; s2_ty; string_ty; tuple2_ty_str |]
      [| s2_def |]
      [|
        { Seed_mir.id = 0;
          statements =
            [
              Seed_mir.Assign (pl 3, Seed_mir.Aggregate (Seed_mir.TupleAgg, [ str_op "deep"; int_op 42 ]));
              Seed_mir.Assign (pl 1, s2_value (Seed_mir.Move (pl 3)) (int_op 7));
              Seed_mir.Assign
                ( pl 2,
                  Seed_mir.Use
                    (Seed_mir.Move (plp 1 [ fid 3; cidx 0 ])) );
            ];
          terminator = Seed_mir.Deinit (pl 1, 1, None) };
        { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  expect_accept "Deinit of the whole root after a deep nested move" nested_deinit_root;
  expect_vm_state "Deinit of the whole root after a deep nested move (glue masks the hole)"
    nested_deinit_root 1 "dropped";
  (* ── a projected Move passed as a Consume-effect call argument is
     checked at the same operand position as every other projected
     transfer: the single-use move of component 0 is legal, executes,
     and the callee receives the component value *)
  let arg_prog = projected_consume_arg_prog () in
  expect_accept "projected move as a Consume-effect call argument" arg_prog;
  (match run_inspect arg_prog with
   | Ok "0" -> pass "projected move as a Consume-effect call arg: VM passes the component and returns 0"
   | Ok other -> fail "projected-move call arg: unexpected result %s (expected 0)" other
   | Error m -> fail "projected-move call arg: %s" m);
  (* positive control: a WHOLE-ROOT move still verifies and runs (the
     partial-move rules are about components, not about moving) *)
  let root_move_prog =
    single_block
      [| i64; tuple2_ty_str; tuple2_ty_str |]
      [||]
      [
        Seed_mir.Assign (pl 1, Seed_mir.Aggregate (Seed_mir.TupleAgg, [ str_op "hello"; int_op 42 ]));
        Seed_mir.Assign (pl 2, Seed_mir.Use (Seed_mir.Move (pl 1)));
        Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Copy (plp 2 [ cidx 1 ])));
      ]
      Seed_mir.Ret
  in
  expect_accept "whole-root Move" root_move_prog;
  expect_vm "whole-root Move" root_move_prog "42"

(* ── (g) host-intrinsic collection writeback ownership (audit P0-3) ──

   The collection intrinsics mutate through the ownership-explicit
   writeback channel: each writeback carries the copy-on-write
   REPLACEMENT plus the `removed` members that LEFT the caller's
   container, and the VM's writeback application installs the
   replacement and then drops every removed value EXACTLY ONCE with
   the canonical per-type drop (drop_value_typed under the
   collection's member type / the structural glue).  The checks drive
   the REAL manifest bindings through hand-built MIR whose elements
   are region-backed refs — each element's region is its drop
   counter: freed = dropped exactly once; live = still owned (a leak
   if it should have dropped); a second free of one region is a
   deterministic drop-glue failure, so a double drop traps instead of
   passing silently.  VM memory and frame locals are inspected after
   each run. *)

let collection_intrinsic (name : string) : Seed_mir.callee =
  match Intrinsic_registry.lookup Intrinsic_registry.manifest ~name with
  | Some (id, _) -> Seed_mir.Intrinsic (Intrinsic_registry.Id.to_int id, [||])
  | None ->
      fail "intrinsic '%s' not declared" name;
      Seed_mir.Intrinsic (-1, [||])

let vec_ty = Type_repr.Named (Ids.Type_id.make 0, [| string_ty |])
let set_ty = Type_repr.Named (Ids.Type_id.make 2, [| string_ty |])
let map_sv_ty = Type_repr.Named (Ids.Type_id.make 1, [| string_ty; string_ty |])

let local (l : int) : Seed_mir.place = { root = Seed_mir.Local l; projections = [] }

let mod_arg (l : int) : Seed_mir.call_arg =
  { Seed_mir.effect_ = Access_effect.Modify; value = Seed_mir.Copy (local l) }

let read_arg (l : int) : Seed_mir.call_arg =
  { Seed_mir.effect_ = Access_effect.Read; value = Seed_mir.Copy (local l) }

let consume_move (l : int) : Seed_mir.call_arg =
  { Seed_mir.effect_ = Access_effect.Consume; value = Seed_mir.Move (local l) }

let consume_copy (l : int) : Seed_mir.call_arg =
  { Seed_mir.effect_ = Access_effect.Consume; value = Seed_mir.Copy (local l) }

let main_prog (locals : Type_repr.t array) (blocks : Seed_mir.block array) :
    Seed_mir.program =
  { Seed_mir.functions =
      [|
        { Seed_mir.name = "main";
          instance = instance 0;
          params = [||];
          locals;
          blocks;
          entry = 0 };
      |];
    statics = [||];
    types = [||] }

let int64_value (n : int64) : Vm_value.t =
  Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true n)

let ref_of (p : Vm_memory.pointer) : Vm_value.t = Vm_value.Ref (Vm_value.Region p)

type seeded_run = {
  svm : Vm.t;
  sframe : Vm_value.frame;
  sres : Vm_memory.pointer array;
}

type seeded_outcome =
  | Ran_ok of seeded_run
  | Ran_error of string * seeded_run
  | Setup_error of string

(* Build an entry frame, allocate `n` resource regions (each region is
   an element resource's drop counter), let the caller seed the locals,
   then run to completion (or to the deterministic trap). *)
let seeded_run (prog : Seed_mir.program)
    (seed : Vm.t -> Vm_value.frame -> Vm_memory.pointer array -> unit) (n : int) :
    seeded_outcome =
  match Vm.entry_frame_of ~program:prog ~entry:(entry_of prog) ~argv:[||] with
  | Error m -> Setup_error m
  | Ok (vm, frame) ->
      let res =
        Array.init n (fun _ ->
            match Vm_memory.alloc vm.Vm.memory 8 8 with
            | Ok p -> p
            | Error e ->
                fail "resource alloc failed: %s" (Vm_memory.mem_error_string e);
                { Vm_memory.region = -1; offset = 0 })
      in
      seed vm frame res;
      let run = { svm = vm; sframe = frame; sres = res } in
      (match Vm.run_inspect vm frame with
       | Error m -> Ran_error (m, run)
       | Ok _ -> Ran_ok run)

let region_live (vm : Vm.t) (p : Vm_memory.pointer) : bool =
  match Vm_memory.region_of vm.Vm.memory p with
  | Ok _ -> true
  | Error _ -> false

let expect_dropped (vm : Vm.t) (what : string) (ps : Vm_memory.pointer list) : unit =
  List.iter
    (fun p ->
      if region_live vm p then
        fail "%s: region %d was NOT dropped (expected exactly one drop)" what
          p.Vm_memory.region)
    ps

let expect_owned (vm : Vm.t) (what : string) (ps : Vm_memory.pointer list) : unit =
  List.iter
    (fun p ->
      if not (region_live vm p) then
        fail "%s: region %d was dropped but must still be owned" what p.Vm_memory.region)
    ps

(* Vec=[R1,R2,R3]; set(1,R4): immediately R2 drops=1, R1/R3/R4 drops=0;
   at the vec's scope end R1=R3=R4=1 and R2 stays 1 (never freed a
   second time — it is not in the replacement, and the old container is
   never dropped as a whole). *)
let check_array_set_ownership () =
  let prog_immediate =
    main_prog [| Type_repr.Unit; vec_ty; i64; string_ty |]
      [|
        { id = 0;
          statements = [];
          terminator =
            Seed_mir.Call
              ( local 0, collection_intrinsic "__intrinsic_array_set",
                [| mod_arg 1; read_arg 2; consume_move 3 |], 1, None ) };
        { id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  let seed_vec (_vm : Vm.t) (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live
        (Vm_value.Array [| ref_of res.(0); ref_of res.(1); ref_of res.(2) |]);
    frame.locals.(2) <- Vm_value.Live (int64_value 1L);
    frame.locals.(3) <- Vm_value.Live (ref_of res.(3))
  in
  (match seeded_run prog_immediate seed_vec 4 with
   | Setup_error m -> fail "array_set ownership: entry setup: %s" m
   | Ran_error (m, _) -> fail "array_set ownership: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "array_set(1,R4) immediately after the call" [ run.sres.(1) ];
       expect_owned run.svm "array_set(1,R4) immediately after the call"
         [ run.sres.(0); run.sres.(2); run.sres.(3) ];
       (match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Array elems)
          when Array.length elems = 3 && Vm_value.equal elems.(0) (ref_of run.sres.(0))
               && Vm_value.equal elems.(1) (ref_of run.sres.(3))
               && Vm_value.equal elems.(2) (ref_of run.sres.(2)) ->
            pass
              "array_set(1,R4): the displaced R2 dropped exactly once at the call (R1/R3/R4 drops=0), the writeback installed [R1,R4,R3]"
        | other ->
            fail "array_set(1,R4): unexpected vec local after the call: %s"
              (Vm_value.slot_state other)));
  let prog_scope_end =
    main_prog [| Type_repr.Unit; vec_ty; i64; string_ty |]
      [|
        { id = 0;
          statements = [];
          terminator =
            Seed_mir.Call
              ( local 0, collection_intrinsic "__intrinsic_array_set",
                [| mod_arg 1; read_arg 2; consume_move 3 |], 1, None ) };
        { id = 1; statements = []; terminator = Seed_mir.Drop (local 1, 2, None) };
        { id = 2; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  (match seeded_run prog_scope_end seed_vec 4 with
   | Setup_error m -> fail "array_set scope end: entry setup: %s" m
   | Ran_error (m, _) -> fail "array_set scope end trapped (a double drop?): %s" m
   | Ran_ok run ->
       expect_dropped run.svm "array_set scope end" (Array.to_list run.sres);
       pass
         "array_set(1,R4) scope end: the vec drop frees R1/R3/R4 exactly once; R2 is not double-dropped (its first drop was at the call)")

(* OOB set: container unchanged, old elements unchanged, sink stays
   caller-owned (the failed check consumed nothing — no writeback, no
   removed drop). *)
let check_array_set_oob () =
  let prog =
    main_prog [| Type_repr.Unit; vec_ty; i64; string_ty |]
      [|
        { id = 0;
          statements = [];
          terminator =
            Seed_mir.Call
              ( local 0, collection_intrinsic "__intrinsic_array_set",
                [| mod_arg 1; read_arg 2; consume_move 3 |], 1, None ) };
        { id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  let seed (_vm : Vm.t) (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live
        (Vm_value.Array [| ref_of res.(0); ref_of res.(1); ref_of res.(2) |]);
    frame.locals.(2) <- Vm_value.Live (int64_value 3L);
    frame.locals.(3) <- Vm_value.Live (ref_of res.(3))
  in
  (match seeded_run prog seed 4 with
   | Setup_error m -> fail "array_set OOB: entry setup: %s" m
   | Ran_ok _ -> fail "array_set OOB: out-of-bounds set did not trap"
   | Ran_error (m, run) ->
       if not (contains m "out of bounds") then fail "array_set OOB: wrong error: %s" m
       else begin
         expect_owned run.svm "array_set OOB: old elements (container unchanged)"
           [ run.sres.(0); run.sres.(1); run.sres.(2) ];
         expect_owned run.svm "array_set OOB: the sink (still caller-owned)"
           [ run.sres.(3) ];
         pass
           "array_set OOB: the failed check consumes nothing — container and old elements unchanged, sink region still live"
       end)

(* pop: the popped resource is NOT dropped by the host (ownership
   transfers into the returned Option); the caller's drop of the
   returned value frees it exactly once. *)
let check_array_pop_ownership () =
  let seed_vec (_vm : Vm.t) (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live (Vm_value.Array [| ref_of res.(0); ref_of res.(1) |])
  in
  let prog_transfer =
    main_prog [| Type_repr.Unit; vec_ty; string_ty; string_ty |]
      [|
        { id = 0;
          statements = [];
          terminator =
            Seed_mir.Call ( local 2, collection_intrinsic "__intrinsic_array_pop",
              [| mod_arg 1 |], 1, None ) };
        { id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  (match seeded_run prog_transfer seed_vec 2 with
   | Setup_error m -> fail "pop transfer: entry setup: %s" m
   | Ran_error (m, _) -> fail "pop transfer: %s" m
   | Ran_ok run ->
       expect_owned run.svm "pop: transferred element (drops=0 at the call)"
         [ run.sres.(0); run.sres.(1) ];
       (match (run.sframe.locals.(1), run.sframe.locals.(2)) with
        | Vm_value.Live (Vm_value.Array elems), Vm_value.Live (Vm_value.Enum (0, [| v |]))
          when Array.length elems = 1 && Vm_value.equal elems.(0) (ref_of run.sres.(0))
               && Vm_value.equal v (ref_of run.sres.(1)) ->
            pass
              "pop: the popped R2 is NOT dropped by the host — it transfers into the returned Option (vec holds [R1])"
        | _ ->
            fail "pop: the writeback/return shapes are wrong (vec must hold [R1], the Option must carry R2)"));
  let prog_caller_drop =
    main_prog [| Type_repr.Unit; vec_ty; string_ty; string_ty |]
      [|
        { id = 0;
          statements = [];
          terminator =
            Seed_mir.Call ( local 2, collection_intrinsic "__intrinsic_array_pop",
              [| mod_arg 1 |], 1, None ) };
        { id = 1; statements = []; terminator = Seed_mir.Drop (local 2, 2, None) };
        { id = 2; statements = []; terminator = Seed_mir.Drop (local 1, 3, None) };
        { id = 3; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  (match seeded_run prog_caller_drop seed_vec 2 with
   | Setup_error m -> fail "pop caller drop: entry setup: %s" m
   | Ran_error (m, _) ->
       fail "pop caller drop trapped (a double drop?): %s" m
   | Ran_ok run ->
       expect_dropped run.svm "pop caller drop" (Array.to_list run.sres);
       pass
         "pop: the returned value drops exactly once at the caller (Option drop frees R2, vec drop frees R1)")

(* clear: every prior member drops exactly once (array_clear and
   set_clear share the same removed-drop machinery). *)
let check_clear_ownership () =
  let prog_arr =
    main_prog [| Type_repr.Unit; vec_ty |]
      [|
        { id = 0;
          statements = [];
          terminator =
            Seed_mir.Call ( local 0, collection_intrinsic "__intrinsic_array_clear",
              [| mod_arg 1 |], 1, None ) };
        { id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  let seed_vec (_vm : Vm.t) (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live
        (Vm_value.Array
           [| ref_of res.(0); ref_of res.(1); ref_of res.(2) |])
  in
  (match seeded_run prog_arr seed_vec 3 with
   | Setup_error m -> fail "array_clear: entry setup: %s" m
   | Ran_error (m, _) -> fail "array_clear: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "array_clear" (Array.to_list run.sres);
       (match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Array elems) when Array.length elems = 0 ->
            pass
              "array_clear: every prior member (R1,R2,R3) drops exactly once and the writeback installs the empty vec"
        | other -> fail "array_clear: the vec local is not empty: %s" (Vm_value.slot_state other)));
  let prog_set =
    main_prog [| Type_repr.Unit; set_ty |]
      [|
        { id = 0;
          statements = [];
          terminator =
            Seed_mir.Call ( local 0, collection_intrinsic "__intrinsic_set_clear",
              [| mod_arg 1 |], 1, None ) };
        { id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  let seed_set (_vm : Vm.t) (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live (Vm_value.Set [ ref_of res.(0); ref_of res.(1) ])
  in
  (match seeded_run prog_set seed_set 2 with
   | Setup_error m -> fail "set_clear: entry setup: %s" m
   | Ran_error (m, _) -> fail "set_clear: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "set_clear" (Array.to_list run.sres);
       (match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Set []) ->
            pass "set_clear: every prior member drops exactly once (the removed channel)"
        | other -> fail "set_clear: the set local is not empty: %s" (Vm_value.slot_state other)))

(* set remove: the matched element leaves the caller's set exactly once
   (the removed channel drops it; the language value is Bool).  An
   equality decision is never made on a resource carrier, so a
   resource-element remove is fail-closed: no match, no drop. *)
let check_set_remove_ownership () =
  let prog =
    main_prog [| Type_repr.Unit; set_ty; string_ty |]
      [|
        { id = 0;
          statements = [];
          terminator =
            Seed_mir.Call
              ( local 0, collection_intrinsic "__intrinsic_set_remove",
                [| mod_arg 1; read_arg 2 |], 1, None ) };
        { id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  let seed_matched (_vm : Vm.t) (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    ignore res;
    frame.locals.(1) <- Vm_value.Live (Vm_value.Set [ Vm_value.String "a"; Vm_value.String "b" ]);
    frame.locals.(2) <- Vm_value.Live (Vm_value.String "b")
  in
  (match seeded_run prog seed_matched 0 with
   | Setup_error m -> fail "set_remove matched: entry setup: %s" m
   | Ran_error (m, _) -> fail "set_remove matched: %s" m
   | Ran_ok run -> (
       match (run.sframe.locals.(0), run.sframe.locals.(1)) with
       | Vm_value.Live (Vm_value.Bool true), Vm_value.Live (Vm_value.Set [ e ])
         when Vm_value.equal e (Vm_value.String "a") ->
           pass
             "set_remove: the matched element leaves the caller's set exactly once (Bool=true, set = {a}) and the removed channel drops it"
       | _ -> fail "set_remove matched: wrong Bool/set shape after the call"));
  let seed_resource (_vm : Vm.t) (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <- Vm_value.Live (Vm_value.Set [ ref_of res.(0) ]);
    frame.locals.(2) <- Vm_value.Live (ref_of res.(1))
  in
  (match seeded_run prog seed_resource 2 with
   | Setup_error m -> fail "set_remove resource: entry setup: %s" m
   | Ran_error (m, _) -> fail "set_remove resource: %s" m
   | Ran_ok run -> (
       match run.sframe.locals.(0) with
       | Vm_value.Live (Vm_value.Bool false) ->
           expect_owned run.svm "set_remove resource (no equality on resource carriers)"
             [ run.sres.(0); run.sres.(1) ];
           pass
             "set_remove on a resource carrier is fail-closed: no match, nothing removed, nothing dropped (stored element and item stay owned)"
       | _ -> fail "set_remove resource: expected Bool false (no equality on resource carriers)"))

(* map insert/replace (Map[String, Vec[Owned]]-shaped nested values):
   the fresh insert stores the sink vec; the replace returns the OLD V
   in the Option — the old V is NOT dropped internally (its members'
   regions stay live) and the NEW V is stored exactly once (dropped
   exactly once when the caller drops the map). *)
let check_map_insert_ownership () =
  let prog =
    main_prog
      [| Type_repr.Unit; map_sv_ty; string_ty; string_ty; string_ty; string_ty;
         string_ty; string_ty; string_ty |]
      [|
        { id = 0;
          statements = [];
          terminator =
            Seed_mir.Call
              ( local 4, collection_intrinsic "__intrinsic_map_insert",
                [| mod_arg 1; consume_move 2; consume_move 3 |], 1, None ) };
        { id = 1;
          statements = [];
          terminator =
            Seed_mir.Call
              ( local 4, collection_intrinsic "__intrinsic_map_insert",
                [| mod_arg 1; consume_copy 5; consume_move 6 |], 2, None ) };
        { id = 2; statements = []; terminator = Seed_mir.Drop (local 4, 3, None) };
        { id = 3; statements = []; terminator = Seed_mir.Drop (local 1, 4, None) };
        { id = 4; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  let seed (_vm : Vm.t) (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <- Vm_value.Live (Vm_value.Map []);
    frame.locals.(2) <- Vm_value.Live (Vm_value.String "a");
    frame.locals.(3) <- Vm_value.Live (Vm_value.Array [| ref_of res.(0); ref_of res.(1) |]);
    frame.locals.(5) <- Vm_value.Live (Vm_value.String "a");
    frame.locals.(6) <- Vm_value.Live (Vm_value.Array [| ref_of res.(2) |])
  in
  let prog_no_drops =
    { prog with
      Seed_mir.functions =
        [|
          { (prog.Seed_mir.functions.(0)) with
            Seed_mir.blocks =
              [|
                { id = 0;
                  statements = [];
                  terminator =
                    Seed_mir.Call
                      ( local 4, collection_intrinsic "__intrinsic_map_insert",
                        [| mod_arg 1; consume_move 2; consume_move 3 |], 1, None ) };
                { id = 1;
                  statements = [];
                  terminator =
                    Seed_mir.Call
                      ( local 4, collection_intrinsic "__intrinsic_map_insert",
                        [| mod_arg 1; consume_copy 5; consume_move 6 |], 2, None ) };
                { id = 2; statements = []; terminator = Seed_mir.Ret };
              |];
          };
        |] }
  in
  (match seeded_run prog_no_drops seed 3 with
   | Setup_error m -> fail "map_insert replace: entry setup: %s" m
   | Ran_error (m, _) -> fail "map_insert replace: %s" m
   | Ran_ok run ->
       expect_owned run.svm "map_insert replace: old V members (transferred to the returned Option)"
         [ run.sres.(0); run.sres.(1) ];
       expect_owned run.svm "map_insert replace: new V member (stored exactly once)"
         [ run.sres.(2) ];
       (match (run.sframe.locals.(1), run.sframe.locals.(4)) with
        | Vm_value.Live (Vm_value.Map [ (k, Vm_value.Array v2) ]),
          Vm_value.Live (Vm_value.Enum (0, [| Vm_value.Array v1 |]))
          when Vm_value.equal k (Vm_value.String "a") && Array.length v2 = 1
               && Vm_value.equal v2.(0) (ref_of run.sres.(2)) && Array.length v1 = 2
               && Vm_value.equal v1.(0) (ref_of run.sres.(0))
               && Vm_value.equal v1.(1) (ref_of run.sres.(1)) ->
            pass
              "map_insert replace: old V returned in the Option (not dropped internally), new V stored exactly once"
        | _ ->
            fail "map_insert replace: wrong map/Option shape after the calls"));
  (match seeded_run prog seed 3 with
   | Setup_error m -> fail "map_insert caller drop: entry setup: %s" m
   | Ran_error (m, _) -> fail "map_insert caller drop trapped (a double drop?): %s" m
   | Ran_ok run ->
       expect_dropped run.svm "map_insert caller drop"
         [ run.sres.(0); run.sres.(1); run.sres.(2) ];
       pass
         "map_insert replace: the old V drops exactly once at the caller (Option drop), the stored new V exactly once at the map's scope end")

(* adversarial nesting: Vec[Vec[String]] (the removed member is itself
   a vec) and Vec[Vec[Owned]] (a nested removed vec's resources drop
   exactly once; a whole-old-container drop would double-destroy the
   shared retained inner vecs and trap). *)
let check_nested_set_ownership () =
  let prog_set =
    main_prog [| Type_repr.Unit; vec_ty; i64; string_ty |]
      [|
        { id = 0;
          statements = [];
          terminator =
            Seed_mir.Call
              ( local 0, collection_intrinsic "__intrinsic_array_set",
                [| mod_arg 1; read_arg 2; consume_move 3 |], 1, None ) };
        { id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  let seed_str (_vm : Vm.t) (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    ignore res;
    frame.locals.(1) <-
      Vm_value.Live
        (Vm_value.Array
           [|
             Vm_value.Array [| Vm_value.String "x"; Vm_value.String "y" |];
             Vm_value.Array [| Vm_value.String "z" |];
           |]);
    frame.locals.(2) <- Vm_value.Live (int64_value 1L);
    frame.locals.(3) <- Vm_value.Live (Vm_value.Array [| Vm_value.String "w" |])
  in
  (match seeded_run prog_set seed_str 0 with
   | Setup_error m -> fail "nested Vec[Vec[String]]: entry setup: %s" m
   | Ran_error (m, _) -> fail "nested Vec[Vec[String]]: %s" m
   | Ran_ok run -> (
       match run.sframe.locals.(1) with
       | Vm_value.Live (Vm_value.Array elems)
         when Array.length elems = 2
              && Vm_value.equal elems.(0)
                   (Vm_value.Array [| Vm_value.String "x"; Vm_value.String "y" |])
              && Vm_value.equal elems.(1)
                   (Vm_value.Array [| Vm_value.String "w" |]) ->
           pass
             "nested Vec[Vec[String]]: set(1, [w]) replaces the inner vec — retained inner vec shared, displaced inner vec [z] dropped once, no double drop"
       | _ -> fail "nested Vec[Vec[String]]: wrong outer-vec shape after the call"));
  let seed_owned (_vm : Vm.t) (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live
        (Vm_value.Array
           [|
             Vm_value.Array [| ref_of res.(0); ref_of res.(1) |];
             Vm_value.Array [| ref_of res.(2) |];
           |]);
    frame.locals.(2) <- Vm_value.Live (int64_value 1L);
    frame.locals.(3) <- Vm_value.Live (Vm_value.Array [| ref_of res.(3) |])
  in
  (match seeded_run prog_set seed_owned 4 with
   | Setup_error m -> fail "nested Vec[Vec[Owned]]: entry setup: %s" m
   | Ran_error (m, _) -> fail "nested Vec[Vec[Owned]] trapped (a double drop?): %s" m
   | Ran_ok run ->
       expect_dropped run.svm
         "nested Vec[Vec[Owned]]: the displaced inner vec's member"
         [ run.sres.(2) ];
       expect_owned run.svm "nested Vec[Vec[Owned]]: retained and sink members"
         [ run.sres.(0); run.sres.(1); run.sres.(3) ];
       pass
         "nested Vec[Vec[Owned]]: set(1, [R4]) drops the displaced inner vec's R3 exactly once; the retained inner vec ([R1,R2]) and the sink [R4] stay owned")

let () =
  Printf.printf "Seed VM kernel-closure primitive self-check\n";
  check_dyn_index ();
  check_pointer ();
  check_ref_writeback ();
  check_recursive_drop ();
  check_serialization ();
  check_projected_move ();
  (* audit P0-3: collection host-intrinsic writeback ownership *)
  check_array_set_ownership ();
  check_array_set_oob ();
  check_array_pop_ownership ();
  check_clear_ownership ();
  check_set_remove_ownership ();
  check_map_insert_ownership ();
  check_nested_set_ownership ();
  if !failures = 0 then begin
    Printf.printf "ALL PASS\n";
    exit 0
  end
  else begin
    Printf.printf "%d FAILURE(S)\n" !failures;
    exit 1
  end
