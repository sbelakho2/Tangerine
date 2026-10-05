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
  let host = Host.create ~repo_root:"." ~argv:[||] () in
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
                (Vm_value.agg
                   [|
                     Vm_value.String "s";
                     Vm_value.Tuple
                       (Vm_value.agg
                          [| Vm_value.Ref (Vm_value.Region (Vm_value.raw_region_ref owned)); Vm_value.RawPtr raw |]);
                   |])
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
      (Vm_value.agg
         [|
           Vm_value.Int (Int_value.of_int64 ~width:32 ~signed:false 0xDEADBEEFL);
           Vm_value.Int (Int_value.of_int64 ~width:128 ~signed:true (-1L));
           Vm_value.Bool true;
           Vm_value.Char (Uchar.of_int 0x1F600);
           Vm_value.String "h\195\169llo";
           Vm_value.array [| Vm_value.Float64 0x3FF0000000000000L; Vm_value.Unit |];
           Vm_value.Enum
             (1, Vm_value.agg [| Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true 42L) |]);
         |])
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

let ref_of (p : Vm_memory.pointer) : Vm_value.t =
  Vm_value.Ref (Vm_value.Region (Vm_value.raw_region_ref p))

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
        (Vm_value.array [| ref_of res.(0); ref_of res.(1); ref_of res.(2) |]);
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
          when Vm_value.arr_length elems = 3
               && Vm_value.equal (Vm_value.arr_get elems 0) (ref_of run.sres.(0))
               && Vm_value.equal (Vm_value.arr_get elems 1) (ref_of run.sres.(3))
               && Vm_value.equal (Vm_value.arr_get elems 2) (ref_of run.sres.(2)) ->
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
        (Vm_value.array [| ref_of res.(0); ref_of res.(1); ref_of res.(2) |]);
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
      Vm_value.Live (Vm_value.array [| ref_of res.(0); ref_of res.(1) |])
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
         | Vm_value.Live (Vm_value.Array elems), Vm_value.Live (Vm_value.Enum (0, a))
           when Vm_value.arr_length elems = 1
                && Vm_value.equal (Vm_value.arr_get elems 0) (ref_of run.sres.(0))
                && (match Vm_value.agg_singleton a with
                    | Some v -> Vm_value.equal v (ref_of run.sres.(1))
                    | None -> false) ->
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
        (Vm_value.array [| ref_of res.(0); ref_of res.(1); ref_of res.(2) |])
  in
  (match seeded_run prog_arr seed_vec 3 with
   | Setup_error m -> fail "array_clear: entry setup: %s" m
   | Ran_error (m, _) -> fail "array_clear: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "array_clear" (Array.to_list run.sres);
       (match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Array elems) when Vm_value.arr_length elems = 0 ->
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
      Vm_value.Live (Vm_value.set_of_list [ ref_of res.(0); ref_of res.(1) ])
  in
  (match seeded_run prog_set seed_set 2 with
   | Setup_error m -> fail "set_clear: entry setup: %s" m
   | Ran_error (m, _) -> fail "set_clear: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "set_clear" (Array.to_list run.sres);
       (match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Set store) when Vm_value.set_elems store = [] ->
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
    frame.locals.(1) <-
      Vm_value.Live (Vm_value.set_of_list [ Vm_value.String "a"; Vm_value.String "b" ]);
    frame.locals.(2) <- Vm_value.Live (Vm_value.String "b")
  in
  (match seeded_run prog seed_matched 0 with
   | Setup_error m -> fail "set_remove matched: entry setup: %s" m
   | Ran_error (m, _) -> fail "set_remove matched: %s" m
   | Ran_ok run -> (
       match (run.sframe.locals.(0), run.sframe.locals.(1)) with
       | Vm_value.Live (Vm_value.Bool true), Vm_value.Live (Vm_value.Set store) -> (
           match Vm_value.set_elems store with
           | [ e ] when Vm_value.equal e (Vm_value.String "a") ->
               pass
                 "set_remove: the matched element leaves the caller's set exactly once (Bool=true, set = {a}) and the removed channel drops it"
           | _ -> fail "set_remove matched: wrong Bool/set shape after the call")
       | _ -> fail "set_remove matched: wrong Bool/set shape after the call"));
  let seed_resource (_vm : Vm.t) (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <- Vm_value.Live (Vm_value.set_of_list [ ref_of res.(0) ]);
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
    frame.locals.(1) <- Vm_value.Live Vm_value.map_empty;
    frame.locals.(2) <- Vm_value.Live (Vm_value.String "a");
    frame.locals.(3) <- Vm_value.Live (Vm_value.array [| ref_of res.(0); ref_of res.(1) |]);
    frame.locals.(5) <- Vm_value.Live (Vm_value.String "a");
    frame.locals.(6) <- Vm_value.Live (Vm_value.array [| ref_of res.(2) |])
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
         | Vm_value.Live (Vm_value.Map store), Vm_value.Live (Vm_value.Enum (0, a)) -> (
             match (Vm_value.agg_singleton a, Vm_value.map_pairs store) with
             | Some (Vm_value.Array v1), [ (k, Vm_value.Array v2) ]
               when Vm_value.equal k (Vm_value.String "a")
                    && Vm_value.arr_length v2 = 1 && Vm_value.arr_length v1 = 2
                    && Vm_value.equal (Vm_value.arr_get v2 0) (ref_of run.sres.(2))
                    && Vm_value.equal (Vm_value.arr_get v1 0) (ref_of run.sres.(0))
                    && Vm_value.equal (Vm_value.arr_get v1 1) (ref_of run.sres.(1)) ->
                 pass
                   "map_insert replace: old V returned in the Option (not dropped internally), new V stored exactly once"
             | _ ->
                 fail "map_insert replace: wrong map/Option shape after the calls")
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
        (Vm_value.array
           [|
             Vm_value.array [| Vm_value.String "x"; Vm_value.String "y" |];
             Vm_value.array [| Vm_value.String "z" |];
           |]);
    frame.locals.(2) <- Vm_value.Live (int64_value 1L);
    frame.locals.(3) <- Vm_value.Live (Vm_value.array [| Vm_value.String "w" |])
  in
  (match seeded_run prog_set seed_str 0 with
   | Setup_error m -> fail "nested Vec[Vec[String]]: entry setup: %s" m
   | Ran_error (m, _) -> fail "nested Vec[Vec[String]]: %s" m
   | Ran_ok run -> (
       match run.sframe.locals.(1) with
       | Vm_value.Live (Vm_value.Array elems)
         when Vm_value.arr_length elems = 2
              && Vm_value.equal (Vm_value.arr_get elems 0)
                   (Vm_value.array [| Vm_value.String "x"; Vm_value.String "y" |])
              && Vm_value.equal (Vm_value.arr_get elems 1)
                   (Vm_value.array [| Vm_value.String "w" |]) ->
           pass
             "nested Vec[Vec[String]]: set(1, [w]) replaces the inner vec — retained inner vec shared, displaced inner vec [z] dropped once, no double drop"
       | _ -> fail "nested Vec[Vec[String]]: wrong outer-vec shape after the call"));
  let seed_owned (_vm : Vm.t) (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live
        (Vm_value.array
           [|
             Vm_value.array [| ref_of res.(0); ref_of res.(1) |];
             Vm_value.array [| ref_of res.(2) |];
           |]);
    frame.locals.(2) <- Vm_value.Live (int64_value 1L);
    frame.locals.(3) <- Vm_value.Live (Vm_value.array [| ref_of res.(3) |])
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

(* ── (h) the unwind pair (__intrinsic_try_invoke / __intrinsic_longjmp) ──

   std/core.tg's experimental protocol: try_invoke[T](f: fn() -> T) runs
   the guest function and yields Option[T] — Some(value) on a normal
   return, None when the callee traps or unwinds.  The trap text travels
   through the guest's own `_current_panic` payload static (the channel
   catch_unwind reads after None); a __intrinsic_longjmp is delivered to
   the INNERMOST active try_invoke (begin_unwind always selects the top
   catch frame) and never clobbers a payload begin_unwind already stored;
   a longjmp with no active handler stays the precise deterministic host
   error. *)

let unwind_intrinsic (name : string) : Seed_mir.callee =
  collection_intrinsic name

let panic_static_ty = Type_repr.Named (Ids.Type_id.make 9001, [||])

let constant_fn (name : string) (inst : Instance_id.t) (value : int) : Seed_mir.function_ =
  {
    Seed_mir.name;
    instance = inst;
    params = [||];
    locals = [| i64 |];
    blocks =
      [|
        { id = 0;
          statements =
            [ Seed_mir.Assign (local 0, Seed_mir.Use (int_op value)) ];
          terminator = Seed_mir.Ret };
      |];
    entry = 0;
  }

let div_zero_fn (name : string) (inst : Instance_id.t) : Seed_mir.function_ =
  {
    Seed_mir.name;
    instance = inst;
    params = [||];
    locals = [| i64 |];
    blocks =
      [|
        { id = 0;
          statements =
            [
              Seed_mir.Assign
                ( local 0,
                  Seed_mir.BinaryOp (Seed_mir.Div, int_op 1, int_op 0) );
            ];
          terminator = Seed_mir.Ret };
      |];
    entry = 0;
  }

let longjmp_fn (name : string) (inst : Instance_id.t) : Seed_mir.function_ =
  {
    Seed_mir.name;
    instance = inst;
    params = [||];
    locals = [| Type_repr.Unit |];
    blocks =
      [|
        { id = 0;
          statements = [];
          terminator =
            Seed_mir.Call
              ( local 0,
                unwind_intrinsic "__intrinsic_longjmp",
                [|
                  { Seed_mir.effect_ = Access_effect.Read;
                    value = Seed_mir.Constant (int_value 0L) };
                |],
                1,
                None ) };
        { id = 1; statements = []; terminator = Seed_mir.Ret };
      |];
    entry = 0;
  }

(* A function that itself calls try_invoke(longjmp_fn): the inner handler
   must catch the unwind, so the outer try_invoke sees a normal return. *)
let nested_handler_fn (name : string) (inst : Instance_id.t)
    (inner : Instance_id.t) : Seed_mir.function_ =
  {
    Seed_mir.name;
    instance = inst;
    params = [||];
    locals = [| Type_repr.Unit; Type_repr.Function ([||], Type_repr.Unit); i64 |];
    blocks =
      [|
        { id = 0;
          statements =
            [
              Seed_mir.Assign
                ( local 1,
                  Seed_mir.Use (Seed_mir.Constant (Seed_mir.Function inner)) );
            ];
          terminator =
            Seed_mir.Call
              ( local 2,
                unwind_intrinsic "__intrinsic_try_invoke",
                [| read_arg 1 |],
                1,
                None ) };
        { id = 1; statements = []; terminator = Seed_mir.Ret };
      |];
    entry = 0;
  }

let unwind_prog (payload_init : Seed_mir.constant option)
    (extra_fns : Seed_mir.function_ array) (main_locals : Type_repr.t array)
    (main_blocks : Seed_mir.block array) : Seed_mir.program =
  {
    Seed_mir.functions =
      Array.append
        [|
          { Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = main_locals;
            blocks = main_blocks;
            entry = 0 };
        |]
        extra_fns;
    statics = [| ("std::core::_current_panic", panic_static_ty, true, payload_init) |];
    types = [||];
  }

(* main: _1 = f; _2 = __intrinsic_try_invoke(_1) *)
let try_invoke_main (f : Instance_id.t) : Seed_mir.block array =
  [|
    { id = 0;
      statements =
        [
          Seed_mir.Assign
            (local 1, Seed_mir.Use (Seed_mir.Constant (Seed_mir.Function f)));
        ];
      terminator =
        Seed_mir.Call
          ( local 2,
            unwind_intrinsic "__intrinsic_try_invoke",
            [| read_arg 1 |],
            1,
            None ) };
    { id = 1; statements = []; terminator = Seed_mir.Ret };
  |]

let is_option_none (v : Vm_value.t) : bool =
  match v with Vm_value.Enum (1, a) -> Vm_value.agg_len a = 0 | _ -> false

let option_some (v : Vm_value.t) : Vm_value.t option =
  match v with Vm_value.Enum (0, a) -> Vm_value.agg_singleton a | _ -> None

let payload_text (v : Vm_value.slot) : string option =
  match v with
  | Vm_value.Live (Vm_value.Enum (0, a)) -> (
      match Vm_value.agg_singleton a with
      | Some (Vm_value.Enum (0, b)) -> (
          match Vm_value.agg_singleton b with
          | Some (Vm_value.String s) -> Some s
          | _ -> None)
      | _ -> None)
  | _ -> None

let check_unwind_pair () =
  let main_locals = [| Type_repr.Unit; Type_repr.Function ([||], i64); i64 |] in
  (* (1) normal return -> Option::Some(7) *)
  (match
     seeded_run
       (unwind_prog None [| constant_fn "ok" (instance 1) 7 |] main_locals
          (try_invoke_main (instance 1)))
       (fun _ _ _ -> ())
       0
   with
   | Setup_error m -> fail "try_invoke success: entry setup: %s" m
   | Ran_error (m, _) -> fail "try_invoke success: unexpected trap: %s" m
   | Ran_ok run -> (
       match run.sframe.locals.(2) with
       | Vm_value.Live v when option_some v = Some (int64_value 7L) ->
           pass
             "try_invoke(fn returning 7) -> Option::Some(7) through the VM invocation channel"
       | other -> fail "try_invoke success: wrong result shape %s" (Vm_value.slot_state other)));
  (* (2) guest trap -> Option::None with the trap text in _current_panic *)
  (match
     seeded_run
       (unwind_prog None [| div_zero_fn "trap" (instance 1) |] main_locals
          (try_invoke_main (instance 1)))
       (fun _ _ _ -> ())
       0
   with
   | Setup_error m -> fail "try_invoke trap: entry setup: %s" m
   | Ran_error (m, _) -> fail "try_invoke trap: the trap escaped the handler: %s" m
   | Ran_ok run ->
       (match run.sframe.locals.(2) with
       | Vm_value.Live v when is_option_none v ->
           pass "try_invoke(fn dividing by zero) -> Option::None (the trap is caught)"
       | other ->
           fail "try_invoke trap: expected Option::None, got %s" (Vm_value.slot_state other));
       (match payload_text run.sframe.statics.(0) with
       | Some msg when contains msg "division by zero" ->
           pass
             "try_invoke trap: the trapped text is recorded in the guest's _current_panic payload (contains \"division by zero\")"
       | Some msg ->
           fail "try_invoke trap: _current_panic carries the wrong text: %s" msg
       | None ->
           fail "try_invoke trap: _current_panic was not populated (slot %s)"
             (Vm_value.slot_state run.sframe.statics.(0))));
  (* (3) guest unwind -> Option::None, and an already-stored payload is
     preserved (begin_unwind wrote it before longjmping).  The preset is
     the VM's materialization of the Option::Some enum constant — a
     distinguishable shape that the trap path would overwrite. *)
  let preset = Some (Seed_mir.Enum (Ids.Variant_index.make 0, panic_static_ty)) in
  (match
     seeded_run
       (unwind_prog preset [| longjmp_fn "unwind" (instance 1) |] main_locals
          (try_invoke_main (instance 1)))
       (fun _ _ _ -> ())
       0
   with
   | Setup_error m -> fail "try_invoke unwind: entry setup: %s" m
   | Ran_error (m, _) -> fail "try_invoke unwind: the unwind escaped the handler: %s" m
   | Ran_ok run ->
       (match run.sframe.locals.(2) with
       | Vm_value.Live v when is_option_none v ->
           pass
             "__intrinsic_longjmp inside the invoked function -> Option::None at the active try_invoke"
       | other ->
           fail "try_invoke unwind: expected Option::None, got %s"
             (Vm_value.slot_state other));
       (match run.sframe.statics.(0) with
       | Vm_value.Live (Vm_value.Enum (0, a)) when Vm_value.agg_len a = 0 ->
           pass
             "try_invoke unwind: the payload already stored in _current_panic is not clobbered by the delivery"
       | other ->
           fail "try_invoke unwind: _current_panic changed: %s" (Vm_value.slot_state other)));
  (* (4) nesting: the INNERMOST handler catches the longjmp; the outer
     try_invoke sees a normal return *)
  (match
     seeded_run
       (unwind_prog None
          [| longjmp_fn "unwind" (instance 1);
             nested_handler_fn "outer" (instance 2) (instance 1) |]
          main_locals
          (try_invoke_main (instance 2)))
       (fun _ _ _ -> ())
       0
   with
   | Setup_error m -> fail "try_invoke nesting: entry setup: %s" m
   | Ran_error (m, _) -> fail "try_invoke nesting: unexpected trap: %s" m
   | Ran_ok run -> (
       match run.sframe.locals.(2) with
       | Vm_value.Live v when option_some v = Some Vm_value.Unit ->
           pass
             "a nested longjmp is delivered to the innermost try_invoke; the outer invocation returns Some(())"
       | other ->
           fail "try_invoke nesting: wrong outer result shape %s" (Vm_value.slot_state other)));
  (* (5) longjmp with no active handler stays a precise deterministic trap *)
  let no_handler_main : Seed_mir.block array =
    [|
      { id = 0;
        statements = [];
        terminator =
          Seed_mir.Call
            ( local 0,
              unwind_intrinsic "__intrinsic_longjmp",
              [|
                { Seed_mir.effect_ = Access_effect.Read;
                  value = Seed_mir.Constant (int_value 0L) };
              |],
              1,
              None ) };
      { id = 1; statements = []; terminator = Seed_mir.Ret };
    |]
  in
  (match
     seeded_run
       (unwind_prog None [||] [| Type_repr.Unit |] no_handler_main)
       (fun _ _ _ -> ())
       0
   with
   | Setup_error m -> fail "longjmp without handler: entry setup: %s" m
   | Ran_ok _ -> fail "longjmp without handler: the run returned instead of trapping"
   | Ran_error (m, _) ->
       if contains m "no active try frame" then
         pass
           "longjmp with no active try_invoke stays the precise deterministic host error"
       else fail "longjmp without handler: wrong trap text: %s" m);
  (* (6) a non-function argument fails closed instead of fabricating a value *)
  let non_fn_main : Seed_mir.block array =
    [|
      { id = 0;
        statements = [];
        terminator =
          Seed_mir.Call
            ( local 2,
              unwind_intrinsic "__intrinsic_try_invoke",
              [|
                { Seed_mir.effect_ = Access_effect.Read;
                  value = Seed_mir.Constant (int_value 5L) };
              |],
              1,
              None ) };
      { id = 1; statements = []; terminator = Seed_mir.Ret };
    |]
  in
  match
    seeded_run
      (unwind_prog None [||] main_locals non_fn_main)
      (fun _ _ _ -> ())
      0
  with
  | Setup_error m -> fail "try_invoke non-function: entry setup: %s" m
  | Ran_ok _ -> fail "try_invoke non-function: returned instead of trapping"
  | Ran_error (m, _) ->
      if contains m "not a function value" then
        pass "try_invoke rejects a non-function argument (deterministic VM trap)"
      else fail "try_invoke non-function: wrong trap text: %s" m

(* the in-place element-write fast path (the growable-array cell's
   `owned` flag): a by-value (Read) parameter gives the callee a second
   holder while the caller's binding stays live.  The callee moves the
   parameter into a local and writes element 0 through a projected
   Assign; the caller's array must keep its old content (the write
   forks a private cell).  A leaked in-place write would show here. *)
let check_inplace_set_alias () =
  let prog =
    { Seed_mir.functions =
        [|
          { Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = [| string_ty; vec_ty |];
            blocks =
              [|
                { id = 0;
                  statements =
                    [ Seed_mir.Assign
                        ( local 1,
                          Seed_mir.Aggregate
                            (Seed_mir.ArrayAgg, [ Seed_mir.Constant (Seed_mir.String "seed") ]) ) ];
                  terminator =
                    Seed_mir.Call
                      ( local 0, Seed_mir.User (instance 1),
                        [| read_arg 1 |], 1, None ) };
                { id = 1; statements = []; terminator = Seed_mir.Ret } |];
            entry = 0 };
          { Seed_mir.name = "move_set";
            instance = instance 1;
            params = [| { pt_convention = Access_effect.Let; pt_type = vec_ty } |];
            locals = [| string_ty; vec_ty; vec_ty |];
            blocks =
              [|
                { id = 0;
                  statements =
                    [ Seed_mir.Assign (local 2, Seed_mir.Use (Seed_mir.Move (local 1)));
                      Seed_mir.Assign
                        ( { root = Seed_mir.Local 2; projections = [ Seed_mir.ConstantIndex 0 ] },
                          Seed_mir.Use (Seed_mir.Constant (Seed_mir.String "mutated")) );
                      Seed_mir.Assign
                        ( local 0, Seed_mir.Use (Seed_mir.Constant (Seed_mir.String "")) ) ];
                  terminator = Seed_mir.Ret } |];
            entry = 0 } |];
      statics = [||];
      types = [||] }
  in
  (match seeded_run prog (fun _ _ _ -> ()) 0 with
   | Setup_error m -> fail "in-place set alias: entry setup: %s" m
   | Ran_error (m, _) -> fail "in-place set alias: %s" m
   | Ran_ok run -> (
       match run.sframe.locals.(1) with
       | Vm_value.Live (Vm_value.Array elems)
         when Vm_value.arr_length elems = 1
              && Vm_value.equal (Vm_value.arr_get elems 0) (Vm_value.String "seed") ->
           pass
             "in-place set alias: the callee's element write forked — the caller's by-value argument kept [seed]"
       | other ->
           fail "in-place set alias: the caller's argument changed: %s"
             (Vm_value.slot_state other)))

(* ── (i) recursive sharing propagation for NESTED growable arrays ──

   The audit's top-P0/P1 correctness risk: `arr_mark_shared_value`
   marked only a TOP-LEVEL Array, so aliasing a value that CONTAINS an
   array (Struct/Tuple/Enum/Closure fields, Array elements, Map/Set
   members) left the nested cell `owned = true`; a projected in-place
   element write through one holder could then mutate the backing data
   every other holder reads.  The fix makes the mark DEEP and
   cycle-safe (vm_value.ml's mark_value_shared; arr_push marks the one
   value that can enter a shared cell afterwards).

   Two legs prove the fix:
     • OCaml level — the tracking contract itself.  Every case builds a
       container embedding an array, records the second holder exactly
       as the VM does (`arr_mark_shared_value` on the container), then
       takes the in-place fast path (`arr_set_direct`) through the
       nested array a holder can reach.  With shallow tracking the
       nested cell is still owned and the write mutates the shared
       backing data (the test fails); with the recursive mark the cell
       is shared, the write forks, and the aliased value keeps [1,2].
      • VM level — the end-to-end value semantics for every shape the
        guest MIR can express (Struct field, tuple index, Array element,
        Enum payload writes through the Downcast write arm — the (j)
        battery below — plus the host-intrinsic Map[String, Array] /
        Set[Array] extraction paths).  A closure capture has no
        projection and stays covered at the OCaml level above. *)

let oi (n : int) : Vm_value.t =
  Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int n))

let int_list (a : Vm_value.arr) : int list =
  List.map
    (function Vm_value.Int i -> Int64.to_int (Int_value.to_int64 i) | _ -> min_int)
    (Vm_value.arr_to_list a)

let expect_ints (what : string) (a : Vm_value.arr) (want : int list) : bool =
  let got = int_list a in
  if got = want then true
  else begin
    fail "%s: contents are [%s] (expected [%s])" what
      (String.concat ";" (List.map string_of_int got))
      (String.concat ";" (List.map string_of_int want));
    false
  end

(* one nested-alias case: build a container embedding a fresh [1,2]
   array, mark the container shared (B = A), extract the nested array
   through the container, and take the direct in-place write path on
   it.  The first holder's value must stay byte-for-byte [1,2] and the
   write must land in a FORKED cell. *)
let nested_alias_case (name : string) (build : Vm_value.t -> Vm_value.t)
    (extract : Vm_value.t -> Vm_value.t) : unit =
  let inner = Vm_value.array [| oi 1; oi 2 |] in
  let container = build inner in
  (* Closures are not serializable (a closure carries an instance id, not
     a byte image); their identity check falls back to structural
     equality below. *)
  let before = try Some (Vm_value.serialize container) with Failure _ -> None in
  Vm_value.arr_mark_shared_value container;
  let view =
    match extract container with
    | Vm_value.Array a -> a
    | _ ->
        fail "%s: the test's extraction did not yield an array" name;
        Vm_value.arr_empty
  in
  let updated = Vm_value.arr_set_direct view 0 (oi 99) in
  let old_ok = expect_ints (name ^ ": the aliased holder") view [ 1; 2 ] in
  let new_ok = expect_ints (name ^ ": the direct write's own view") updated [ 99; 2 ] in
  let identity_ok =
    match before with
    | Some b -> Vm_value.serialize container = b
    | None -> Vm_value.equal container (build inner)
  in
  let forked = not (view.Vm_value.cell == updated.Vm_value.cell) in
  if old_ok && new_ok && identity_ok && forked then
    pass
      "%s: the recursive mark disables the in-place write — the nested cell forks, the aliased value stays byte-identical"
      name
  else if old_ok && identity_ok && not forked then
    fail "%s: arr_set_direct mutated the shared cell in place (no fork)" name
  else ()

let check_nested_sharing_tracking () =
  nested_alias_case "nested sharing: Struct(Array)"
    (fun i -> Vm_value.Struct (Vm_value.agg [| i |]))
    (function Vm_value.Struct f -> Vm_value.agg_get f 0 | _ -> assert false);
  nested_alias_case "nested sharing: Tuple(Array)"
    (fun i -> Vm_value.Tuple (Vm_value.agg [| i |]))
    (function Vm_value.Tuple f -> Vm_value.agg_get f 0 | _ -> assert false);
  nested_alias_case "nested sharing: Enum(Array)"
    (fun i -> Vm_value.Enum (0, Vm_value.agg [| i |]))
    (function Vm_value.Enum (_, f) -> Vm_value.agg_get f 0 | _ -> assert false);
  nested_alias_case "nested sharing: Array(Array) element" (fun i -> Vm_value.array [| i |])
    (function Vm_value.Array a -> Vm_value.arr_get a 0 | _ -> assert false);
  nested_alias_case "nested sharing: Closure capture Array"
    (fun i -> Vm_value.Closure (instance 77, Vm_value.agg [| i |]))
    (function Vm_value.Closure (_, caps) -> Vm_value.agg_get caps 0 | _ -> assert false);
  nested_alias_case "nested sharing: Map value Array"
    (fun i -> Vm_value.map_of_pairs [ (Vm_value.String "k", i) ])
    (function
      | Vm_value.Map m -> (
          match Vm_value.map_find m (Vm_value.String "k") with
          | Some (_, v) -> v
          | None -> assert false)
      | _ -> assert false);
  nested_alias_case "nested sharing: Map key Array"
    (fun i -> Vm_value.map_of_pairs [ (i, Vm_value.String "v") ])
    (function
      | Vm_value.Map m -> (
          match Vm_value.map_pairs m with (k, _) :: _ -> k | [] -> assert false)
      | _ -> assert false);
  nested_alias_case "nested sharing: Set(Array) element" (fun i -> Vm_value.set_of_list [ i ])
    (function
      | Vm_value.Set s -> (
          match Vm_value.set_elems s with x :: _ -> x | [] -> assert false)
      | _ -> assert false);
  nested_alias_case "nested sharing: Set(Struct(Array)) element"
    (fun i -> Vm_value.set_of_list [ Vm_value.Struct (Vm_value.agg [| i |]) ])
    (function
      | Vm_value.Set s -> (
          match Vm_value.set_elems s with
          | Vm_value.Struct f :: _ -> Vm_value.agg_get f 0
          | _ -> assert false)
      | _ -> assert false)

(* a value appended into an ALREADY-SHARED cell is reachable from every
   holder of that cell: the deep walk stops at an unowned cell, so
   arr_push must mark the appended value itself.  A direct write through
   the appended array must therefore fork; before the fix it mutated the
   shared cell in place. *)
let check_push_sharing_maintenance () =
  let a = Vm_value.arr_of_array [| oi 0 |] in
  Vm_value.arr_mark_shared a;
  let inner = Vm_value.arr_of_array [| oi 5 |] in
  let _grown = Vm_value.arr_push a (Vm_value.Array inner) in
  let updated = Vm_value.arr_set_direct inner 0 (oi 99) in
  let old_ok = expect_ints "push into a shared cell: the appended value" inner [ 5 ] in
  let new_ok = expect_ints "push into a shared cell: the write's own view" updated [ 99 ] in
  let forked = not (inner.Vm_value.cell == updated.Vm_value.cell) in
  if old_ok && new_ok && forked then
    pass
      "push into a shared cell: the appended value is marked shared — a direct write through it forks and the shared value keeps [5]"
  else if old_ok && not forked then
    fail
      "push into a shared cell: the appended value was NOT marked — an in-place write aliased the shared value";
  (* a push at an UNIQUE frontier must stay the amortized in-place
     append: same cell, grown, still owned *)
  let b = Vm_value.arr_of_array [| oi 1 |] in
  let b' = Vm_value.arr_push b (oi 2) in
  if (not b'.Vm_value.cell.owned) || not (b'.Vm_value.cell == b.Vm_value.cell) then
    fail "push at an unshared frontier: the append forked instead of growing in place"
  else ignore (expect_ints "push at an unshared frontier" b' [ 1; 2 ])

(* the walk terminates on a cyclic value (an element that is a view of
   its own cell) — the only mutable links in the value model pass
   through an array cell, and the cell's flag is set before descending. *)
let check_cyclic_mark () =
  let a = Vm_value.arr_of_array [| oi 1 |] in
  let self = Vm_value.Array a in
  let grown = Vm_value.arr_push a self in
  Vm_value.arr_mark_shared_value (Vm_value.Array grown);
  pass
    "cycle-safe deep mark: marking an array whose element contains the array's own cell terminates"

(* ── persistent Map/Set store-mark memoization (the O(N*M) wall) ──
   The deep mark is memoized per STORE (map_marked/set_marked): the
   first alias of a large table walks every member, a repeated alias is
   O(1), so repeatedly fetched/copied resolver/typechecker tables are
   not re-walked mark after mark (the self-host preflight's quadratic
   shared-marking zone, mark_nodes ~2.2e10).  The frontier rule keeps
   the invariant: a member inserted into a marked store is marked at
   insert, so a later direct write through an alias forks. *)
let check_store_mark_memoization () =
  let array_member i = Vm_value.array [| oi i; oi (i + 1) |] in
  let set = Vm_value.set_of_list (List.init 200 array_member) in
  Vm_value.arr_mark_shared_value set;
  let after_first = !Vm_value.prof_mark_nodes in
  Vm_value.arr_mark_shared_value set;
  let after_second = !Vm_value.prof_mark_nodes in
  if after_second - after_first > 3 then
    fail "Set mark memoization: a repeated mark of a 200-member Set visited %d nodes"
      (after_second - after_first)
  else pass "Set mark memoization: a repeated mark of a 200-member Set is O(1)";
  let map =
    Vm_value.map_of_pairs
      (List.init 200 (fun i ->
           (Vm_value.String (string_of_int i), array_member i)))
  in
  Vm_value.arr_mark_shared_value map;
  let after_third = !Vm_value.prof_mark_nodes in
  Vm_value.arr_mark_shared_value map;
  let after_fourth = !Vm_value.prof_mark_nodes in
  if after_fourth - after_third > 3 then
    fail "Map mark memoization: a repeated mark of a 200-entry Map visited %d nodes"
      (after_fourth - after_third)
  else pass "Map mark memoization: a repeated mark of a 200-entry Map is O(1)";
  (* the first mark must have reached every member: extracting one and
     taking the direct write path forks *)
  let member =
    match Vm_value.set_elems (match set with Vm_value.Set s -> s | _ -> assert false) with
    | x :: _ -> (match x with Vm_value.Array a -> a | _ -> assert false)
    | [] -> assert false
  in
  (* The fork contract: a direct write on a shared member must return a
     NEW array (physical cell differs), the new array must hold the new
     value, and the ORIGINAL member must still read the old value — not
     merely "the original cell's owned flag is false". *)
  let before = Vm_value.arr_get member 0 in
  let after = oi 99 in
  let updated = Vm_value.arr_set_direct member 0 after in
  if updated.Vm_value.cell == member.Vm_value.cell then
    fail "Set mark memoization: the direct write did not fork a shared member"
  else if Vm_value.arr_get updated 0 <> after then
    fail "Set mark memoization: the forked array did not receive the new value"
  else if Vm_value.arr_get member 0 <> before then
    fail
      "Set mark memoization: the original array was mutated by a write to the fork"
  else pass "Set mark memoization: the first mark reached every member (a direct write forks and leaves the original intact)";
  (* insert into a MARKED store marks the incoming member at insert *)
  let extra = Vm_value.arr_of_array [| oi 7; oi 8 |] in
  let _ =
    Vm_value.set_insert
      (match set with Vm_value.Set s -> s | _ -> assert false)
      (Vm_value.Array extra)
  in
  let updated = Vm_value.arr_set_direct extra 0 (oi 99) in
  if extra.Vm_value.cell == updated.Vm_value.cell then
    fail
      "Set frontier maintenance: an inserted member stayed owned — a later alias could be mutated in place"
  else
    pass
      "Set frontier maintenance: a member inserted into a marked store is marked at insert (the direct write forks)"

(* (g5) the compiler-internal PERSISTENT-MAP SNAPSHOT (ResolvedNames and
   the other compiler carriers): the immutable store is shared O(1) with
   every reachable array marked shared, a later insert creates a new
   store and leaves the snapshot unchanged, and a store carrying an owned
   region ref is refused fail-closed (sharing it would double-drop the
   region).  This is the option-3 Clone performance recovery, NOT the
   public generic Clone. *)
let check_map_snapshot () =
  let arr = Vm_value.arr_of_array [| oi 1; oi 2 |] in
  let empty =
    match Vm_value.map_empty with Vm_value.Map s -> s | _ -> assert false
  in
  let _, store =
    Vm_value.map_insert_entry empty (Vm_value.String "k") (Vm_value.Array arr)
  in
  (match Vm_value.map_snapshot store with
  | Error e -> fail "map snapshot refused a pure store: %s" e
  | Ok shared ->
      if not (shared == store) then
        fail "map snapshot copied the store instead of sharing it O(1)"
      else pass "map snapshot shares the immutable pure store O(1)";
      let updated = Vm_value.arr_set_direct arr 0 (oi 9) in
      if updated.Vm_value.cell == arr.Vm_value.cell then
        fail "map snapshot did not deep-mark reachable arrays shared"
      else
        pass
          "map snapshot deep-marks reachable arrays shared (the direct write forks)";
      let _, store2 =
        Vm_value.map_insert_entry store (Vm_value.String "k2") (oi 5)
      in
      if Vm_value.map_len store2 = 2 && Vm_value.map_len store = 1 then
        pass
          "map snapshot persistence: a later insert leaves the snapshot unchanged"
      else fail "map snapshot persistence broken");
  let rr = Vm_value.alloc_region_ref (oi 7) in
  let empty2 =
    match Vm_value.map_empty with Vm_value.Map s -> s | _ -> assert false
  in
  let _, store3 =
    Vm_value.map_insert_entry empty2 (Vm_value.String "r")
      (Vm_value.Ref (Vm_value.Region rr))
  in
  (match Vm_value.map_snapshot store3 with
  | Error _ ->
      pass
        "map snapshot refuses a store carrying an owned region ref (fail-closed)"
  | Ok _ ->
      fail
        "map snapshot shared a resource-bearing store (double-drop hazard)");
  (* the incremental purity flag: an insert of an owned ref flips it on
     the RESULT store; removal is conservative (a false stays false) *)
  let rr2 = Vm_value.alloc_region_ref (oi 11) in
  let _, impure =
    Vm_value.map_insert_entry store (Vm_value.String "r")
      (Vm_value.Ref (Vm_value.Region rr2))
  in
  (match Vm_value.map_snapshot impure with
  | Error _ ->
      pass "inserting an owned region ref flips the incremental purity flag"
  | Ok _ -> fail "an impure insert stayed snapshot-able");
  let _, after_removal = Vm_value.map_remove impure (Vm_value.String "r") in
  match Vm_value.map_snapshot after_removal with
  | Error _ ->
      pass "purity stays conservative across removal (impure stays impure)"
  | Ok _ -> fail "removal re-proved purity without a walk"

(* ── the VM-level nested-alias battery (guest-expressible shapes) ── *)

let nested_arr_ty = Type_repr.Fixed_array (i64, 2)
let nested_arr_arr_ty = Type_repr.Fixed_array (nested_arr_ty, 2)
let nested_tup_ty = Type_repr.Tuple [| nested_arr_ty |]
let nested_s_tid = Ids.Type_id.make 401
let nested_s_ty = Type_repr.Named (nested_s_tid, [||])

let nested_s_def : Seed_mir.type_def =
  Seed_mir.StructDef
    { sd_id = nested_s_tid; sd_fields = [ mk_fd 4011 0 nested_arr_ty ] }

let nested_arr_value () : Vm_value.t = Vm_value.array [| oi 1; oi 2 |]

let nested_holder_ok (v : Vm_value.t) : bool =
  Vm_value.serialize v = Vm_value.serialize (nested_arr_value ())

(* run the program; its return value must be the untouched holder's
   nested [0] = 1, and the holder slot named by `holder` must still
   serialize byte-identically to [1,2]. *)
let check_nested_vm (what : string) (prog : Seed_mir.program) (holder : int) : unit =
  match Vm.entry_frame_of ~program:prog ~entry:(entry_of prog) ~argv:[||] with
  | Error m -> fail "%s: entry setup: %s" what m
  | Ok (vm, frame) -> (
      match Vm.run_inspect vm frame with
      | Error m -> fail "%s: %s" what m
      | Ok ret ->
          let holder_ok =
            match frame.locals.(holder) with
            | Vm_value.Live v -> (
                match v with
                | Vm_value.Struct f -> nested_holder_ok (Vm_value.agg_get f 0)
                | Vm_value.Tuple f -> nested_holder_ok (Vm_value.agg_get f 0)
                | Vm_value.Array a -> nested_holder_ok (Vm_value.arr_get a 0)
                | _ -> false)
            | _ -> false
          in
          if ret <> "1" then
            fail "%s: the untouched holder read %s (expected 1 — the alias was mutated)" what
              ret
          else if not holder_ok then
            fail "%s: the untouched holder's nested array is no longer byte-identical to [1,2]"
              what
          else
            pass
              "%s: the nested element write forked — the untouched holder stays byte-identical [1,2]"
              what)

(* Build the container in local 2, alias it into local 3 (Copy — the
   Read/Copy mark), mutate the nested element through one holder
   (`mutate_through`), and return the nested element read through the
   other.  Prelude statements build the inner array(s) in scratch
   locals; local 5 is the return scratch. *)
let nested_vm_prog (locals : Type_repr.t array) (types : Seed_mir.type_def array)
    (prelude : Seed_mir.statement list) (build : Seed_mir.rvalue)
    (mutate_through : int) (hit : Seed_mir.projection list) : Seed_mir.program =
  let other = if mutate_through = 2 then 3 else 2 in
  single_block locals types
    (prelude
    @ [
        Seed_mir.Assign (pl 2, build);
        Seed_mir.Assign (pl 3, Seed_mir.Use (Seed_mir.Copy (pl 2)));
        Seed_mir.Assign (plp mutate_through hit, Seed_mir.Use (int_op 99));
        Seed_mir.Assign (pl 5, Seed_mir.Use (Seed_mir.Copy (plp other hit)));
        Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Copy (pl 5)));
      ])
    Seed_mir.Ret

let check_nested_array_vm_alias () =
  let inner_prelude =
    [ Seed_mir.Assign
        ( pl 1,
          Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 1; int_op 2 ]) ) ]
  in
  let struct_build =
    Seed_mir.Aggregate
      ( Seed_mir.StructCtor (nested_s_tid, [| Ids.Field_index.make 0 |]),
        [ Seed_mir.Copy (pl 1) ] )
  in
  check_nested_vm "VM alias: Struct(Array), mutate B read A"
    (nested_vm_prog
       [| i64; nested_arr_ty; nested_s_ty; nested_s_ty; i64; i64 |]
       [| nested_s_def |] inner_prelude struct_build 3 [ fid 4011; cidx 0 ])
    2;
  check_nested_vm "VM alias: Struct(Array), mutate A read B"
    (nested_vm_prog
       [| i64; nested_arr_ty; nested_s_ty; nested_s_ty; i64; i64 |]
       [| nested_s_def |] inner_prelude struct_build 2 [ fid 4011; cidx 0 ])
    3;
  let tuple_build =
    Seed_mir.Aggregate (Seed_mir.TupleAgg, [ Seed_mir.Copy (pl 1) ])
  in
  check_nested_vm "VM alias: Tuple(Array), mutate B read A"
    (nested_vm_prog
       [| i64; nested_arr_ty; nested_tup_ty; nested_tup_ty; i64; i64 |]
       [||] inner_prelude tuple_build 3 [ cidx 0; cidx 0 ])
    2;
  check_nested_vm "VM alias: Tuple(Array), mutate A read B"
    (nested_vm_prog
       [| i64; nested_arr_ty; nested_tup_ty; nested_tup_ty; i64; i64 |]
       [||] inner_prelude tuple_build 2 [ cidx 0; cidx 0 ])
    3;
  let arr_arr_build =
    Seed_mir.Aggregate
      (Seed_mir.ArrayAgg, [ Seed_mir.Copy (pl 1); Seed_mir.Copy (pl 4) ])
  in
  let arr_arr_prelude =
    inner_prelude
    @ [ Seed_mir.Assign
          ( pl 4,
            Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 3; int_op 4 ]) ) ]
  in
  check_nested_vm "VM alias: Array(Array), mutate B read A"
    (nested_vm_prog
       [| i64; nested_arr_ty; nested_arr_arr_ty; nested_arr_arr_ty; nested_arr_ty; i64 |]
       [||] arr_arr_prelude arr_arr_build 3 [ cidx 0; cidx 0 ])
    2;
  check_nested_vm "VM alias: Array(Array), mutate A read B"
    (nested_vm_prog
       [| i64; nested_arr_ty; nested_arr_arr_ty; nested_arr_arr_ty; nested_arr_ty; i64 |]
       [||] arr_arr_prelude arr_arr_build 2 [ cidx 0; cidx 0 ])
    3;
  (* the host extraction path: vec_get returns the STORED inner array
     (the binding marks it shared), then a direct projected write lands
     on the extracted root cell — it must fork, never mutate the vec's
     stored element *)
  let get_prog =
    prog_with_types
      [| Type_repr.Unit; nested_arr_ty; nested_arr_ty; nested_arr_arr_ty;
         nested_arr_arr_ty; nested_arr_ty; i64 |]
      [||]
      [|
        { Seed_mir.id = 0;
          statements =
            [
              Seed_mir.Assign
                ( pl 1,
                  Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 1; int_op 2 ]) );
              Seed_mir.Assign
                ( pl 2,
                  Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 3; int_op 4 ]) );
              Seed_mir.Assign
                ( pl 3,
                  Seed_mir.Aggregate
                    (Seed_mir.ArrayAgg, [ Seed_mir.Copy (pl 1); Seed_mir.Copy (pl 2) ]) );
              Seed_mir.Assign (pl 4, Seed_mir.Use (Seed_mir.Copy (pl 3)));
              Seed_mir.Assign (pl 6, Seed_mir.Use (int_op 0));
            ];
          terminator =
            Seed_mir.Call
              ( local 5,
                collection_intrinsic "__intrinsic_array_get",
                [| read_arg 3; read_arg 6 |],
                1,
                None ) };
        { Seed_mir.id = 1;
          statements =
            [
              Seed_mir.Assign (plp 5 [ cidx 0 ], Seed_mir.Use (int_op 99));
              Seed_mir.Assign
                ( pl 0,
                  Seed_mir.Use
                    (Seed_mir.Copy
                       { root = Seed_mir.Local 3; projections = [ cidx 0; cidx 0 ] }) );
            ];
          terminator = Seed_mir.Ret };
      |]
  in
  (match Vm.entry_frame_of ~program:get_prog ~entry:(entry_of get_prog) ~argv:[||] with
   | Error m -> fail "VM alias: host vec_get extraction: entry setup: %s" m
   | Ok (vm, frame) -> (
       match Vm.run_inspect vm frame with
       | Error m -> fail "VM alias: host vec_get extraction: %s" m
       | Ok ret ->
           let extracted_ok =
             match frame.locals.(5) with
             | Vm_value.Live (Vm_value.Array a) -> int_list a = [ 99; 2 ]
             | _ -> false
           in
           if ret <> "1" then
             fail
               "VM alias: host vec_get extraction: the vec's stored inner array became %s (expected 1)"
               ret
           else if not extracted_ok then
             fail "VM alias: host vec_get extraction: the extracted array is not [99,2]"
           else
             pass
               "VM alias: host vec_get extraction — the direct write forked; the vec's stored inner array stays [1,2]"))

(* Map[String, Array] through the REAL host bindings: copy the map,
   read the stored array through the copy (map_get marks it shared),
   take the direct write path on the extracted array, and check the
   map's retained value stays byte-identical.  option_expect transfers
   the payload out of the Option. *)
let check_nested_map_vm_alias () =
  let map_ty = Type_repr.Named (Ids.Type_id.make 1, [| string_ty; nested_arr_ty |]) in
  let opt_ty = Type_repr.Named (Ids.Type_id.make 3, [||]) in
  let prog =
    main_prog [| Type_repr.Unit; map_ty; opt_ty; vec_ty; string_ty; string_ty |]
      [|
        { id = 0;
          statements = [];
          terminator =
            Seed_mir.Call
              ( local 2,
                collection_intrinsic "__intrinsic_map_get",
                [| read_arg 1; read_arg 4 |],
                1,
                None ) };
        { id = 1;
          statements = [];
          terminator =
            Seed_mir.Call
              ( local 3,
                collection_intrinsic "__intrinsic_option_expect",
                [| consume_move 2; read_arg 5 |],
                2,
                None ) };
        { id = 2;
          statements =
            [
              Seed_mir.Assign (plp 3 [ cidx 0 ], Seed_mir.Use (int_op 99));
              Seed_mir.Assign (pl 0, Seed_mir.Use (int_op 0));
            ];
          terminator = Seed_mir.Ret };
      |]
  in
  let seed (_vm : Vm.t) (frame : Vm_value.frame) (_res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live
        (Vm_value.map_of_pairs [ (Vm_value.String "k", nested_arr_value ()) ]);
    frame.locals.(4) <- Vm_value.Live (Vm_value.String "k");
    frame.locals.(5) <- Vm_value.Live (Vm_value.String "missing")
  in
  match seeded_run prog seed 0 with
  | Setup_error m -> fail "VM alias: Map[String, Array]: entry setup: %s" m
  | Ran_error (m, _) -> fail "VM alias: Map[String, Array]: %s" m
  | Ran_ok run ->
      let stored_ok =
        match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Map store) -> (
            match Vm_value.map_find store (Vm_value.String "k") with
            | Some (_, v) -> nested_holder_ok v
            | None -> false)
        | _ -> false
      in
      let extracted_ok =
        match run.sframe.locals.(3) with
        | Vm_value.Live (Vm_value.Array a) -> int_list a = [ 99; 2 ]
        | _ -> false
      in
      if stored_ok && extracted_ok then
        pass
          "VM alias: Map[String, Array] — map_get marks the stored array shared; the direct write forked and the map's retained value stays [1,2]"
      else if not stored_ok then
        fail "VM alias: Map[String, Array]: the map's stored array was mutated in place"
      else fail "VM alias: Map[String, Array]: the extracted array is not [99,2]"

(* Set[Array] through the REAL host bindings: set_entries returns the
   stored elements (each marked shared), vec_get extracts one, and the
   direct write on it must fork rather than mutate the set's member. *)
let check_nested_set_vm_alias () =
  let set_ty_arr = Type_repr.Named (Ids.Type_id.make 2, [| nested_arr_ty |]) in
  let prog =
    main_prog [| Type_repr.Unit; set_ty_arr; vec_ty; vec_ty; i64 |]
      [|
        { id = 0;
          statements = [];
          terminator =
            Seed_mir.Call
              ( local 2,
                collection_intrinsic "__intrinsic_set_entries",
                [| read_arg 1 |],
                1,
                None ) };
        { id = 1;
          statements = [];
          terminator =
            Seed_mir.Call
              ( local 3,
                collection_intrinsic "__intrinsic_array_get",
                [| read_arg 2; read_arg 4 |],
                2,
                None ) };
        { id = 2;
          statements =
            [
              Seed_mir.Assign (plp 3 [ cidx 0 ], Seed_mir.Use (int_op 99));
              Seed_mir.Assign (pl 0, Seed_mir.Use (int_op 0));
            ];
          terminator = Seed_mir.Ret };
      |]
  in
  let seed (_vm : Vm.t) (frame : Vm_value.frame) (_res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live (Vm_value.set_of_list [ nested_arr_value () ]);
    frame.locals.(4) <- Vm_value.Live (int64_value 0L)
  in
  match seeded_run prog seed 0 with
  | Setup_error m -> fail "VM alias: Set[Array]: entry setup: %s" m
  | Ran_error (m, _) -> fail "VM alias: Set[Array]: %s" m
  | Ran_ok run ->
      let stored_ok =
        match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Set store) -> (
            match Vm_value.set_elems store with
            | [ v ] -> nested_holder_ok v
            | _ -> false)
        | _ -> false
      in
      let extracted_ok =
        match run.sframe.locals.(3) with
        | Vm_value.Live (Vm_value.Array a) -> int_list a = [ 99; 2 ]
        | _ -> false
      in
      if stored_ok && extracted_ok then
        pass
          "VM alias: Set[Array] — set_entries marks each member shared; the direct write forked and the set's member stays [1,2]"
      else if not stored_ok then
        fail "VM alias: Set[Array]: the set's stored member was mutated in place"
      else fail "VM alias: Set[Array]: the extracted array is not [99,2]"

(* ── (j) enum-downcast projected writes (audit P0/P1-2) ─────────────

   `update_place`'s write path used to return the base enum for a
   Downcast projection (`| Seed_mir.Downcast _ -> base`) — a write whose
   destination crossed an enum downcast silently vanished.  The write
   arm now mirrors the read side: the semantic VariantId resolves to the
   declaration-order runtime tag through the owner enum def, the runtime
   tag must equal it, the payload struct is updated recursively with the
   remaining projections, and the enum is rebuilt; a non-enum base, a
   wrong runtime tag and a non-struct payload rebuild all trap
   deterministically.

   The battery (hand-built MIR, verifier-checked where the program is
   conforming — the two defense-in-depth traps pin the verifier's
   fail-closed rejection AND the VM's deterministic trap):
     1. payload scalar write through [Downcast; ConstantIndex] (the
        sibling payload position must stay untouched);
     2. payload nested-array element write (the array lives INSIDE the
        payload — the COW/fork path must still apply);
     3. [Downcast; Field] through a struct payload;
     4. a deeper [Downcast; ConstantIndex; ConstantIndex] chain;
     5. the wrong-variant write traps (runtime tag != VariantId tag);
     6. the non-enum base traps (and the verifier rejects the chain);
     7. the non-struct whole-payload rebuild traps (verifier-rejected
        shape, never a silent no-op);
     8. the A/B alias case: B = A (Copy marks the enum payload's array
        shared), mutate B's payload array element, A stays [1,2]. *)

let edw_tid = Ids.Type_id.make 601
let edw_s_tid = Ids.Type_id.make 602
let edw_enum_ty = Type_repr.Named (edw_tid, [||])
let edw_s_ty = Type_repr.Named (edw_s_tid, [||])
let edw_inner_tup_ty = Type_repr.Tuple [| i64; i64 |]

let edw_s_def : Seed_mir.type_def =
  Seed_mir.StructDef
    { sd_id = edw_s_tid; sd_fields = [ mk_fd 6011 0 i64; mk_fd 6012 1 i64 ] }

let edw_v_pair = 60
let edw_v_nested = 61
let edw_v_structy = 62
let edw_v_deep = 63

let edw_enum_def : Seed_mir.type_def =
  Seed_mir.EnumDef
    {
      ed_id = edw_tid;
      ed_variants =
        [
          { vd_id = Ids.Variant_id.make edw_v_pair;
            vd_index = Ids.Variant_index.make 0;
            vd_payload = Type_repr.Tuple [| i64; i64 |] };
          { vd_id = Ids.Variant_id.make edw_v_nested;
            vd_index = Ids.Variant_index.make 1;
            vd_payload = Type_repr.Tuple [| nested_arr_ty |] };
          { vd_id = Ids.Variant_id.make edw_v_structy;
            vd_index = Ids.Variant_index.make 2;
            vd_payload = edw_s_ty };
          { vd_id = Ids.Variant_id.make edw_v_deep;
            vd_index = Ids.Variant_index.make 3;
            vd_payload = Type_repr.Tuple [| edw_inner_tup_ty; i64 |] };
        ];
    }

let edw_types = [| edw_enum_def; edw_s_def |]

let dcast (v : int) : Seed_mir.projection =
  Seed_mir.Downcast (Ids.Variant_id.make v)

let edw_is_int (v : Vm_value.t) (want : int) : bool =
  Vm_value.equal v (int64_value (Int64.of_int want))

let edw_expect_valid (what : string) (prog : Seed_mir.program) : unit =
  match Mir_verify.require_valid_concrete prog with
  | Ok () -> ()
  | Error errs ->
      fail "%s: Mir_verify rejected the conforming program: %s" what
        (String.concat "; " errs)

let edw_expect_invalid (what : string) (prog : Seed_mir.program) : unit =
  match Mir_verify.require_valid_concrete prog with
  | Ok () ->
      fail "%s: Mir_verify accepted a program it must reject" what
  | Error _ -> ()

let edw_run_seeded (what : string) (prog : Seed_mir.program)
    (seed : Vm.t -> Vm_value.frame -> Vm_memory.pointer array -> unit) :
    seeded_run option =
  match seeded_run prog seed 0 with
  | Ran_ok run -> Some run
  | Ran_error (m, _) -> fail "%s: %s" what m; None
  | Setup_error m -> fail "%s: entry setup: %s" what m; None

let edw_expect_seeded_trap (what : string) (prog : Seed_mir.program)
    (seed : Vm.t -> Vm_value.frame -> Vm_memory.pointer array -> unit)
    (needle : string) : unit =
  match seeded_run prog seed 0 with
  | Ran_error (m, _) ->
      if contains m needle then pass "%s: deterministic trap" what
      else fail "%s: trap message %S does not contain %S" what m needle
  | Ran_ok _ -> fail "%s: the write silently succeeded (no trap)" what
  | Setup_error m -> fail "%s: entry setup: %s" what m

let edw_live_int (frame : Vm_value.frame) (l : int) (want : int) : bool =
  match frame.locals.(l) with Vm_value.Live v -> edw_is_int v want | _ -> false

let check_edw_scalar_write () =
  let what = "enum downcast write: payload scalar [Downcast; ConstantIndex]" in
  let prog =
    single_block
      [| i64; edw_enum_ty |]
      edw_types
      [
        Seed_mir.Assign
          ( pl 1,
            Seed_mir.Aggregate
              ( Seed_mir.EnumCtor (edw_tid, Ids.Variant_index.make 0),
                [ int_op 7; int_op 8 ] ) );
        Seed_mir.Assign
          (plp 1 [ dcast edw_v_pair; cidx 0 ], Seed_mir.Use (int_op 42));
        Seed_mir.Assign
          ( pl 0,
            Seed_mir.Use (Seed_mir.Copy (plp 1 [ dcast edw_v_pair; cidx 1 ])) );
      ]
      Seed_mir.Ret
  in
  edw_expect_valid what prog;
  match edw_run_seeded what prog (fun _ _ _ -> ()) with
  | None -> ()
  | Some run ->
      let payload_ok =
        match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Enum (0, p)) ->
            Vm_value.agg_len p = 2
            && edw_is_int (Vm_value.agg_get p 0) 42
            && edw_is_int (Vm_value.agg_get p 1) 8
        | _ -> false
      in
      if payload_ok && edw_live_int run.sframe 0 8 then
        pass
          "%s: the write landed (payload [42; 8]); the sibling position stays 8 and the read-back is 8"
          what
      else fail "%s: the payload is not [42; 8]" what

let check_edw_nested_array_write () =
  let what = "enum downcast write: payload nested-array element" in
  let prog =
    single_block
      [| i64; edw_enum_ty; nested_arr_ty |]
      edw_types
      [
        Seed_mir.Assign
          (pl 2, Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 1; int_op 2 ]));
        Seed_mir.Assign
          ( pl 1,
            Seed_mir.Aggregate
              ( Seed_mir.EnumCtor (edw_tid, Ids.Variant_index.make 1),
                [ Seed_mir.Copy (pl 2) ] ) );
        Seed_mir.Assign
          (plp 1 [ dcast edw_v_nested; cidx 0; cidx 1 ], Seed_mir.Use (int_op 99));
        Seed_mir.Assign
          ( pl 0,
            Seed_mir.Use
              (Seed_mir.Copy (plp 1 [ dcast edw_v_nested; cidx 0; cidx 0 ])) );
      ]
      Seed_mir.Ret
  in
  edw_expect_valid what prog;
  match edw_run_seeded what prog (fun _ _ _ -> ()) with
  | None -> ()
  | Some run ->
      let payload_ok =
        match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Enum (1, p)) -> (
            match Vm_value.agg_get p 0 with
            | Vm_value.Array a -> int_list a = [ 1; 99 ]
            | _ -> false)
        | _ -> false
      in
      let source_ok =
        match run.sframe.locals.(2) with
        | Vm_value.Live (Vm_value.Array a) -> int_list a = [ 1; 2 ]
        | _ -> false
      in
      if payload_ok && source_ok && edw_live_int run.sframe 0 1 then
        pass
          "%s: [Downcast; ConstantIndex 0; ConstantIndex 1] = 99 landed in the payload array ([1; 99]); the copied source array stays [1; 2]"
          what
      else fail "%s: payload=%b source=%b" what payload_ok source_ok

let check_edw_field_write () =
  let what = "enum downcast write: struct payload [Downcast; Field]" in
  let prog =
    single_block
      [| i64; edw_enum_ty |]
      edw_types
      [
        Seed_mir.Assign
          ( pl 1,
            Seed_mir.Aggregate
              ( Seed_mir.EnumCtor (edw_tid, Ids.Variant_index.make 2),
                [ int_op 7; int_op 8 ] ) );
        Seed_mir.Assign
          (plp 1 [ dcast edw_v_structy; fid 6011 ], Seed_mir.Use (int_op 42));
        Seed_mir.Assign
          ( pl 0,
            Seed_mir.Use (Seed_mir.Copy (plp 1 [ dcast edw_v_structy; fid 6012 ])) );
      ]
      Seed_mir.Ret
  in
  edw_expect_valid what prog;
  match edw_run_seeded what prog (fun _ _ _ -> ()) with
  | None -> ()
  | Some run ->
      let payload_ok =
        match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Enum (2, p)) ->
            edw_is_int (Vm_value.agg_get p 0) 42
            && edw_is_int (Vm_value.agg_get p 1) 8
        | _ -> false
      in
      if payload_ok && edw_live_int run.sframe 0 8 then
        pass
          "%s: the payload field write landed ([42; 8]); the sibling field stays 8"
          what
      else fail "%s: the payload is not [42; 8]" what

let check_edw_deep_chain_write () =
  let what = "enum downcast write: deeper [Downcast; ConstantIndex; ConstantIndex]" in
  let prog =
    single_block
      [| i64; edw_enum_ty; edw_inner_tup_ty |]
      edw_types
      [
        Seed_mir.Assign
          (pl 2, Seed_mir.Aggregate (Seed_mir.TupleAgg, [ int_op 7; int_op 8 ]));
        Seed_mir.Assign
          ( pl 1,
            Seed_mir.Aggregate
              ( Seed_mir.EnumCtor (edw_tid, Ids.Variant_index.make 3),
                [ Seed_mir.Copy (pl 2); int_op 9 ] ) );
        Seed_mir.Assign
          (plp 1 [ dcast edw_v_deep; cidx 0; cidx 1 ], Seed_mir.Use (int_op 42));
        Seed_mir.Assign
          ( pl 0,
            Seed_mir.Use
              (Seed_mir.Copy (plp 1 [ dcast edw_v_deep; cidx 0; cidx 0 ])) );
      ]
      Seed_mir.Ret
  in
  edw_expect_valid what prog;
  match edw_run_seeded what prog (fun _ _ _ -> ()) with
  | None -> ()
  | Some run ->
      let payload_ok =
        match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Enum (3, p)) -> (
            match Vm_value.agg_get p 0 with
            | Vm_value.Tuple inner ->
                edw_is_int (Vm_value.agg_get inner 0) 7
                && edw_is_int (Vm_value.agg_get inner 1) 42
            | _ -> false)
        | _ -> false
      in
      if payload_ok && edw_live_int run.sframe 0 7 then
        pass
          "%s: the inner payload tuple became (7, 42) and the read-back is 7"
          what
      else fail "%s: the inner payload tuple is not (7, 42)" what

let check_edw_wrong_variant_trap () =
  let what = "enum downcast write: wrong runtime variant" in
  let prog =
    single_block
      [| i64; edw_enum_ty |]
      edw_types
      [
        Seed_mir.Assign
          ( pl 1,
            Seed_mir.Aggregate
              ( Seed_mir.EnumCtor (edw_tid, Ids.Variant_index.make 2),
                [ int_op 7; int_op 8 ] ) );
        Seed_mir.Assign
          (plp 1 [ dcast edw_v_pair; cidx 0 ], Seed_mir.Use (int_op 42));
        Seed_mir.Assign (pl 0, Seed_mir.Use (int_op 0));
      ]
      Seed_mir.Ret
  in
  edw_expect_valid what prog;
  edw_expect_seeded_trap what prog (fun _ _ _ -> ()) "runtime tag 2"

let check_edw_non_enum_trap () =
  let what = "enum downcast write: non-enum base" in
  let prog =
    single_block
      [| i64; i64 |]
      [||]
      [
        Seed_mir.Assign (pl 1, Seed_mir.Use (int_op 5));
        Seed_mir.Assign (plp 1 [ dcast edw_v_pair; cidx 0 ], Seed_mir.Use (int_op 42));
        Seed_mir.Assign (pl 0, Seed_mir.Use (int_op 0));
      ]
      Seed_mir.Ret
  in
  edw_expect_invalid what prog;
  edw_expect_seeded_trap what prog (fun _ _ _ -> ()) "non-enum"

let check_edw_rebuild_trap () =
  let what = "enum downcast write: non-struct payload rebuild" in
  let prog =
    single_block
      [| i64; edw_enum_ty; nested_arr_ty |]
      edw_types
      [
        Seed_mir.Assign
          (pl 2, Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 1; int_op 2 ]));
        Seed_mir.Assign
          ( pl 1,
            Seed_mir.Aggregate
              ( Seed_mir.EnumCtor (edw_tid, Ids.Variant_index.make 1),
                [ Seed_mir.Copy (pl 2) ] ) );
        Seed_mir.Assign (plp 1 [ dcast edw_v_nested ], Seed_mir.Use (int_op 5));
        Seed_mir.Assign (pl 0, Seed_mir.Use (int_op 0));
      ]
      Seed_mir.Ret
  in
  edw_expect_invalid what prog;
  edw_expect_seeded_trap what prog (fun _ _ _ -> ()) "expected payload struct"

let check_edw_alias_cow () =
  let what = "enum downcast write: A/B alias COW across the enum payload" in
  let prog =
    single_block
      [| i64; edw_enum_ty; nested_arr_ty; edw_enum_ty |]
      edw_types
      [
        Seed_mir.Assign
          (pl 2, Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 1; int_op 2 ]));
        Seed_mir.Assign
          ( pl 1,
            Seed_mir.Aggregate
              ( Seed_mir.EnumCtor (edw_tid, Ids.Variant_index.make 1),
                [ Seed_mir.Copy (pl 2) ] ) );
        Seed_mir.Assign (pl 3, Seed_mir.Use (Seed_mir.Copy (pl 1)));
        Seed_mir.Assign
          (plp 3 [ dcast edw_v_nested; cidx 0; cidx 1 ], Seed_mir.Use (int_op 99));
        Seed_mir.Assign
          ( pl 0,
            Seed_mir.Use
              (Seed_mir.Copy (plp 1 [ dcast edw_v_nested; cidx 0; cidx 1 ])) );
      ]
      Seed_mir.Ret
  in
  let payload_of (frame : Vm_value.frame) (l : int) : int list option =
    match frame.locals.(l) with
    | Vm_value.Live (Vm_value.Enum (1, p)) -> (
        match Vm_value.agg_get p 0 with
        | Vm_value.Array a -> Some (int_list a)
        | _ -> None)
    | _ -> None
  in
  match edw_run_seeded what prog (fun _ _ _ -> ()) with
  | None -> ()
  | Some run -> (
      match (payload_of run.sframe 1, payload_of run.sframe 3) with
      | Some a, Some b when a = [ 1; 2 ] && b = [ 1; 99 ] && edw_live_int run.sframe 0 2 ->
          pass
            "%s: mutating B's payload array forked ([1; 99]); A stays [1; 2] and the read-back through A is 2"
            what
      | Some a, Some b ->
          fail "%s: A=%s B=%s (expected A=[1;2], B=[1;99])" what
            (String.concat ";" (List.map string_of_int a))
            (String.concat ";" (List.map string_of_int b))
      | _ -> fail "%s: an enum payload is not a live array" what)

(* ── (k) the drop mirror through enum-downcast destinations ─────────

   `drop_old_value_at`'s projected resolve recursed a Downcast into
   payload POSITION 0 (instead of the payload STRUCT the read and write
   arms use) and resolved every Field against the root local type
   (instead of the projected owner type).  Both defects stayed dormant
   while the displaced leaf was copyable and position 0 happened to fall
   through to the no-value fallback, but now that downcast writes land
   they leak (or over-drop) the displaced OWNED component.

   The battery proves the corrected mirror end to end.  The owned-drop
   cases (0-5, 7) seed region owners at frame setup exactly like the (g)
   ownership battery — the verifier's static state cannot see a seeded
   value (it treats the seeded local as possibly uninitialized), so those
   legs are VM-only; the (j) battery already owns the verifier-accepted
   shapes, and case 6b keeps one MIR-built, verifier-checked trap.
     0. the root dispatch is ACTIVATED (the pre-fix `else` attached to
        the inner bounds `if`, leaving the whole local-root branch dead):
        a whole-local overwrite drops the displaced value exactly once;
     1. [Downcast; ConstantIndex 0] overwriting an owned payload
        component frees the displaced region EXACTLY once and stores the
        new ref;
     2. [Downcast; Field] resolves the FieldId against the projected
        payload struct (the defect's root-type resolve traps on the
        enum) and frees the displaced payload field exactly once;
     3. a unique nested array of refs inside the payload: the displaced
        element drops exactly once and its sibling stays owned;
     4. the A/B payload COW: the payload's nested array is marked shared
        by the Copy, the deeper projected write forks and A stays intact;
     5. a wrong runtime variant traps BEFORE any drop (the displaced
        payload ref is not freed by the failed assignment);
     6. an unknown FieldId traps deterministically (VM-only seeded);
        a Field on a tuple payload (whose FieldId resolves against the
        payload type) is verifier-rejected and traps in the VM;
     7. a moved-out payload component is a no-op for the drop mirror (no
        double drop) — the moved value is destroyed exactly once by its
        new owner. *)

let dmd_tid = Ids.Type_id.make 701
let dmd_s_tid = Ids.Type_id.make 702
let dmd_enum_ty = Type_repr.Named (dmd_tid, [||])
let dmd_s_ty = Type_repr.Named (dmd_s_tid, [||])
let dmd_i64_arr_ty = Type_repr.Fixed_array (i64, 2)
let dmd_ref_arr_ty = Type_repr.Fixed_array (ref_ty, 2)

let dmd_s_def : Seed_mir.type_def =
  Seed_mir.StructDef
    {
      sd_id = dmd_s_tid;
      sd_fields =
        [ mk_fd 7011 0 ref_ty; mk_fd 7012 1 i64; mk_fd 7013 2 dmd_i64_arr_ty ];
    }

let dmd_v_ref = 70
let dmd_v_sref = 71
let dmd_v_refarr = 72

let dmd_enum_def : Seed_mir.type_def =
  Seed_mir.EnumDef
    {
      ed_id = dmd_tid;
      ed_variants =
        [
          { vd_id = Ids.Variant_id.make dmd_v_ref;
            vd_index = Ids.Variant_index.make 0;
            vd_payload = Type_repr.Tuple [| ref_ty |] };
          { vd_id = Ids.Variant_id.make dmd_v_sref;
            vd_index = Ids.Variant_index.make 1;
            vd_payload = dmd_s_ty };
          { vd_id = Ids.Variant_id.make dmd_v_refarr;
            vd_index = Ids.Variant_index.make 2;
            vd_payload = Type_repr.Tuple [| dmd_ref_arr_ty |] };
        ];
    }

let dmd_types = [| dmd_enum_def; dmd_s_def |]

let dmd_dcast (v : int) : Seed_mir.projection =
  Seed_mir.Downcast (Ids.Variant_id.make v)

let dmd_ref (p : Vm_memory.pointer) : Vm_value.t =
  Vm_value.Ref (Vm_value.Region (Vm_value.raw_region_ref p))

let dmd_run (what : string) (n : int) (prog : Seed_mir.program)
    (seed : Vm.t -> Vm_value.frame -> Vm_memory.pointer array -> unit) :
    seeded_run option =
  match seeded_run prog seed n with
  | Ran_ok run -> Some run
  | Ran_error (m, _) -> fail "%s: %s" what m; None
  | Setup_error m -> fail "%s: entry setup: %s" what m; None

let dmd_expect_trap (what : string) (n : int) (prog : Seed_mir.program)
    (seed : Vm.t -> Vm_value.frame -> Vm_memory.pointer array -> unit)
    (needle : string) : unit =
  match seeded_run prog seed n with
  | Ran_error (m, _) ->
      if contains m needle then pass "%s: deterministic trap" what
      else fail "%s: trap message %S does not contain %S" what m needle
  | Ran_ok _ -> fail "%s: the write silently succeeded (no trap)" what
  | Setup_error m -> fail "%s: entry setup: %s" what m

(* The region-ownership leg: the expect_* diagnostics already fail with
   the precise region, so the callers only need the combined verdict to
   decide whether their semantic pass line may print. *)
let dmd_region_checks (vm : Vm.t) (what : string)
    (dead : Vm_memory.pointer list) (live : Vm_memory.pointer list) : bool =
  let before = !failures in
  expect_dropped vm what dead;
  expect_owned vm what live;
  !failures = before

let dmd_struct_payload (frame : Vm_value.frame) (l : int) : Vm_value.t array option =
  match frame.locals.(l) with
  | Vm_value.Live (Vm_value.Enum (1, p)) ->
      Some (Array.init (Vm_value.agg_len p) (Vm_value.agg_get p))
  | _ -> None

(* 0. the whole-root overwrite drops the displaced value exactly once
   (the root dispatch's previously dead local branch). *)
let check_dmd_whole_root_drop () =
  let what = "enum-downcast drop: whole-local overwrite drops the displaced value" in
  let prog =
    single_block
      [| Type_repr.Unit; ref_ty; ref_ty |]
      [||]
      [
        Seed_mir.Assign (pl 1, Seed_mir.Use (Seed_mir.Move (pl 2)));
        Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Constant Seed_mir.Unit));
      ]
      Seed_mir.Ret
  in
  let seed _vm (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <- Vm_value.Live (dmd_ref res.(0));
    frame.locals.(2) <- Vm_value.Live (dmd_ref res.(1))
  in
  match dmd_run what 2 prog seed with
  | None -> ()
  | Some run ->
      let regions_ok =
        dmd_region_checks run.svm what [ run.sres.(0) ] [ run.sres.(1) ]
      in
      let stored_ok =
        match run.sframe.locals.(1) with
        | Vm_value.Live v -> Vm_value.equal v (dmd_ref run.sres.(1))
        | _ -> false
      in
      if regions_ok && stored_ok then
        pass
          "%s: the whole-root overwrite freed the displaced region exactly once and stored the new ref"
          what
      else if not regions_ok then ()
      else fail "%s: the local does not hold the freshly stored ref" what

(* 1. [Downcast; ConstantIndex 0] over an owned payload component. *)
let check_dmd_payload_component_drop () =
  let what = "enum-downcast drop: displaced owned payload component" in
  let prog =
    single_block
      [| Type_repr.Unit; dmd_enum_ty; ref_ty |]
      dmd_types
      [
        Seed_mir.Assign
          ( plp 1 [ dmd_dcast dmd_v_ref; cidx 0 ],
            Seed_mir.Use (Seed_mir.Move (pl 2)) );
        Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Constant Seed_mir.Unit));
      ]
      Seed_mir.Ret
  in
  let seed _vm (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live (Vm_value.Enum (0, Vm_value.agg [| dmd_ref res.(0) |]));
    frame.locals.(2) <- Vm_value.Live (dmd_ref res.(1))
  in
  match dmd_run what 2 prog seed with
  | None -> ()
  | Some run ->
      let regions_ok =
        dmd_region_checks run.svm what [ run.sres.(0) ] [ run.sres.(1) ]
      in
      let stored_ok =
        match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Enum (0, p)) ->
            Vm_value.agg_len p = 1
            && Vm_value.equal (Vm_value.agg_get p 0) (dmd_ref run.sres.(1))
        | _ -> false
      in
      if regions_ok && stored_ok then
        pass
          "%s: [Downcast; ConstantIndex 0] freed the displaced region exactly once, stored the new ref, and the new ref stays owned"
          what
      else if not regions_ok then ()
      else fail "%s: the payload does not hold the freshly stored ref" what

(* 2. [Downcast; Field] resolves the FieldId against the projected payload
   struct; the displaced field ref drops exactly once. *)
let check_dmd_payload_field_drop () =
  let what = "enum-downcast drop: [Downcast; Field] on the projected payload struct" in
  let prog =
    single_block
      [| Type_repr.Unit; dmd_enum_ty; ref_ty |]
      dmd_types
      [
        Seed_mir.Assign
          ( plp 1 [ dmd_dcast dmd_v_sref; fid 7011 ],
            Seed_mir.Use (Seed_mir.Move (pl 2)) );
        Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Constant Seed_mir.Unit));
      ]
      Seed_mir.Ret
  in
  let seed _vm (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live
        (Vm_value.Enum
           ( 1,
             Vm_value.agg
               [| dmd_ref res.(0); int64_value 5L; Vm_value.array [| oi 7; oi 8 |] |] ));
    frame.locals.(2) <- Vm_value.Live (dmd_ref res.(1))
  in
  match dmd_run what 2 prog seed with
  | None -> ()
  | Some run ->
      let regions_ok =
        dmd_region_checks run.svm what [ run.sres.(0) ] [ run.sres.(1) ]
      in
      let stored_ok =
        match dmd_struct_payload run.sframe 1 with
        | Some p ->
            Array.length p = 3
            && Vm_value.equal p.(0) (dmd_ref run.sres.(1))
            && edw_is_int p.(1) 5
            && (match p.(2) with Vm_value.Array a -> int_list a = [ 7; 8 ] | _ -> false)
        | None -> false
      in
      if regions_ok && stored_ok then
        pass
          "%s: the field write landed on the payload struct (the siblings stay [5; [7;8]]); the displaced ref region was freed exactly once"
          what
      else if not regions_ok then ()
      else fail "%s: the payload struct was not rebuilt with the new field ref" what

(* 3. a unique nested array of refs inside the payload: the displaced
   element drops exactly once and its sibling stays owned. *)
let check_dmd_payload_array_element_drop () =
  let what = "enum-downcast drop: displaced ref element of a payload array" in
  let prog =
    single_block
      [| Type_repr.Unit; dmd_enum_ty; ref_ty |]
      dmd_types
      [
        Seed_mir.Assign
          ( plp 1 [ dmd_dcast dmd_v_refarr; cidx 0; cidx 1 ],
            Seed_mir.Use (Seed_mir.Move (pl 2)) );
        Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Constant Seed_mir.Unit));
      ]
      Seed_mir.Ret
  in
  let seed _vm (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live
        (Vm_value.Enum
           ( 2,
             Vm_value.agg [| Vm_value.array [| dmd_ref res.(0); dmd_ref res.(1) |] |] ));
    frame.locals.(2) <- Vm_value.Live (dmd_ref res.(2))
  in
  match dmd_run what 3 prog seed with
  | None -> ()
  | Some run ->
      let regions_ok =
        dmd_region_checks run.svm what [ run.sres.(1) ] [ run.sres.(0); run.sres.(2) ]
      in
      let stored_ok =
        match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Enum (2, p)) -> (
            match Vm_value.agg_get p 0 with
            | Vm_value.Array a ->
                Vm_value.arr_length a = 2
                && Vm_value.equal (Vm_value.arr_get a 0) (dmd_ref run.sres.(0))
                && Vm_value.equal (Vm_value.arr_get a 1) (dmd_ref run.sres.(2))
            | _ -> false)
        | _ -> false
      in
      if regions_ok && stored_ok then
        pass
          "%s: [Downcast; ConstantIndex 0; ConstantIndex 1] dropped only the displaced element (the sibling and the stored ref stay owned)"
          what
      else if not regions_ok then ()
      else fail "%s: the payload array is not [sibling; new ref]" what

(* 4. the A/B payload COW: the payload's nested array is marked shared by
   the Copy; the deeper projected write forks and A stays intact. *)
let check_dmd_payload_array_cow () =
  let what = "enum-downcast drop: payload nested-array COW across A/B" in
  let prog =
    single_block
      [| Type_repr.Unit; dmd_enum_ty; dmd_enum_ty |]
      dmd_types
      [
        Seed_mir.Assign (pl 2, Seed_mir.Use (Seed_mir.Copy (pl 1)));
        Seed_mir.Assign
          ( plp 2 [ dmd_dcast dmd_v_sref; fid 7013; cidx 1 ],
            Seed_mir.Use (int_op 99) );
        Seed_mir.Assign
          ( pl 0,
            Seed_mir.Use
              (Seed_mir.Copy (plp 1 [ dmd_dcast dmd_v_sref; fid 7013; cidx 1 ])) );
      ]
      Seed_mir.Ret
  in
  let seed _vm (frame : Vm_value.frame) (_res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live
        (Vm_value.Enum
           ( 1,
             Vm_value.agg
               [| Vm_value.Null; int64_value 5L; Vm_value.array [| oi 7; oi 8 |] |] ));
  in
  let payload_array (frame : Vm_value.frame) (l : int) : int list option =
    match dmd_struct_payload frame l with
    | Some p -> (
        match p.(2) with Vm_value.Array a -> Some (int_list a) | _ -> None)
    | None -> None
  in
  match dmd_run what 0 prog seed with
  | None -> ()
  | Some run -> (
      match (payload_array run.sframe 1, payload_array run.sframe 2) with
      | Some a, Some b when a = [ 7; 8 ] && b = [ 7; 99 ] && edw_live_int run.sframe 0 8 ->
          pass
            "%s: the Copy marked the payload array shared, B's deeper projected write forked ([7; 99]), A stays [7; 8]"
            what
      | Some a, Some b ->
          fail "%s: A=%s B=%s (expected A=[7;8], B=[7;99])" what
            (String.concat ";" (List.map string_of_int a))
            (String.concat ";" (List.map string_of_int b))
      | _ -> fail "%s: the payload arrays are not live int arrays" what)

(* 5. a wrong runtime variant must trap BEFORE the drop resolves anything:
   the parked payload ref must stay owned (a pre-trap drop would free it).
   The destination is the WHOLE downcast payload so the defect's
   payload-position-0 recursion would resolve the parked field-0 ref and
   free it before the tag check ever runs. *)
let check_dmd_wrong_variant_trap () =
  let what = "enum-downcast drop: wrong runtime variant traps before any drop" in
  let prog =
    single_block
      [| Type_repr.Unit; dmd_enum_ty; ref_ty |]
      dmd_types
      [
        Seed_mir.Assign
          ( plp 1 [ dmd_dcast dmd_v_ref ],
            Seed_mir.Use (Seed_mir.Move (pl 2)) );
        Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Constant Seed_mir.Unit));
      ]
      Seed_mir.Ret
  in
  let seed _vm (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    (* the LIVE value is the struct variant (tag 1); the destination
       downcasts to the ref variant (semantic 70, tag 0) — the mismatch
       must trap without touching the struct payload's field 0 ref *)
    frame.locals.(1) <-
      Vm_value.Live
        (Vm_value.Enum
           ( 1,
             Vm_value.agg
               [| dmd_ref res.(0); int64_value 5L; Vm_value.array [| oi 7; oi 8 |] |] ));
    frame.locals.(2) <- Vm_value.Live (dmd_ref res.(1))
  in
  match seeded_run prog seed 2 with
  | Ran_error (m, run) ->
      if contains m "runtime tag 1" then begin
        if
          dmd_region_checks run.svm (what ^ ": the parked payload ref") []
            [ run.sres.(0) ]
        then pass "%s: the tag mismatch trapped and the payload was left untouched" what
      end
      else fail "%s: unexpected trap %S" what m
  | Ran_ok _ -> fail "%s: the wrong-variant write silently succeeded" what
  | Setup_error m -> fail "%s: entry setup: %s" what m

(* 6. an unknown FieldId traps deterministically. *)
let check_dmd_wrong_field_trap () =
  let what = "enum-downcast drop: unknown FieldId traps" in
  let prog =
    single_block
      [| Type_repr.Unit; dmd_enum_ty |]
      dmd_types
      [
        Seed_mir.Assign
          ( plp 1 [ dmd_dcast dmd_v_sref; fid 9999 ],
            Seed_mir.Use (int_op 5) );
        Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Constant Seed_mir.Unit));
      ]
      Seed_mir.Ret
  in
  dmd_expect_trap what 0 prog
    (fun _vm (frame : Vm_value.frame) (_res : Vm_memory.pointer array) ->
      frame.locals.(1) <-
        Vm_value.Live
          (Vm_value.Enum
             ( 1,
               Vm_value.agg
                 [| Vm_value.Null; int64_value 5L; Vm_value.array [| oi 7; oi 8 |] |] )))
    "field identity #9999 not found"

(* 6b. a Field over a TUPLE payload: the projected owner is not a struct,
   so the FieldId resolves against the payload type (a tuple) and both the
   verifier and the VM's drop mirror reject it deterministically. *)
let check_dmd_field_on_tuple_payload_trap () =
  let what = "enum-downcast drop: Field on a tuple payload traps" in
  let prog =
    single_block
      [| i64; edw_enum_ty |]
      edw_types
      [
        Seed_mir.Assign
          ( pl 1,
            Seed_mir.Aggregate
              ( Seed_mir.EnumCtor (edw_tid, Ids.Variant_index.make 0),
                [ int_op 7; int_op 8 ] ) );
        Seed_mir.Assign
          (plp 1 [ dcast edw_v_pair; fid 6011 ], Seed_mir.Use (int_op 42));
        Seed_mir.Assign (pl 0, Seed_mir.Use (int_op 0));
      ]
      Seed_mir.Ret
  in
  edw_expect_invalid what prog;
  edw_expect_seeded_trap what prog (fun _ _ _ -> ()) "non-struct static type"

(* 7. a moved-out payload component is not dropped again: the moved value
   is destroyed exactly once by its new owner. *)
let check_dmd_moved_out_no_double_drop () =
  let what = "enum-downcast drop: moved-out payload component is not double-dropped" in
  let prog =
    prog_with_types
      [| Type_repr.Unit; dmd_enum_ty; ref_ty; ref_ty; ref_ty |]
      dmd_types
      [|
        {
          Seed_mir.id = 0;
          statements =
            [
              Seed_mir.Assign
                ( pl 3,
                  Seed_mir.Use (Seed_mir.Move (plp 1 [ dmd_dcast dmd_v_ref; cidx 0 ])) );
              Seed_mir.Assign
                ( plp 1 [ dmd_dcast dmd_v_ref; cidx 0 ],
                  Seed_mir.Use (Seed_mir.Move (pl 2)) );
              Seed_mir.Assign
                ( pl 4,
                  Seed_mir.Use (Seed_mir.Move (plp 1 [ dmd_dcast dmd_v_ref; cidx 0 ])) );
              Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Constant Seed_mir.Unit));
            ];
          terminator = Seed_mir.Goto 1;
        };
        { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Drop (local 3, 2, None) };
        { Seed_mir.id = 2; statements = []; terminator = Seed_mir.Drop (local 4, 3, None) };
        { Seed_mir.id = 3; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  let seed _vm (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live (Vm_value.Enum (0, Vm_value.agg [| dmd_ref res.(0) |]));
    frame.locals.(2) <- Vm_value.Live (dmd_ref res.(1))
  in
  match dmd_run what 2 prog seed with
  | None -> ()
  | Some run ->
      let regions_ok =
        dmd_region_checks run.svm what [ run.sres.(0); run.sres.(1) ] []
      in
      if regions_ok then
        pass
          "%s: the re-assignment left the MovedOut hole alone; each region was freed exactly once by its own drop (a second free would have trapped)"
          what


(* ── (h) call-result destination replacement (audit P1-7 / P1-8) ─────

   A call-result store is an assignment: the OLD value of the exact
   destination place is dropped exactly once before the result lands.
   This section crosses both producers (a user function and a host
   intrinsic) with every place shape (whole local, struct field, enum
   payload, enum->struct nested field, projected static), plus the
   lifecycle edges (uninitialized and MovedOut destinations, a trapping
   call, a wrong-variant destination trap, repeated A->B->C overwrite)
   and the audit-P1-8 deref / dynamic-index rules.  Region-backed refs
   are the ownership counters: a freed region = dropped exactly once,
   a live one = still owned (a second free would trap in the glue). *)

let crr_s_tid = Ids.Type_id.make 701
let crr_s_ty = Type_repr.Named (crr_s_tid, [||])

let crr_s_def : Seed_mir.type_def =
  Seed_mir.StructDef { sd_id = crr_s_tid; sd_fields = [ mk_fd 7011 0 ref_ty ] }

let crr_e_tid = Ids.Type_id.make 702
let crr_e_ty = Type_repr.Named (crr_e_tid, [||])
let crr_v_ref = Ids.Variant_id.make 7001
let crr_v_struct = Ids.Variant_id.make 7002

let crr_e_def : Seed_mir.type_def =
  Seed_mir.EnumDef
    {
      ed_id = crr_e_tid;
      ed_variants =
        [
          { vd_id = crr_v_ref;
            vd_index = Ids.Variant_index.make 0;
            vd_payload = Type_repr.Tuple [| ref_ty |] };
          { vd_id = crr_v_struct;
            vd_index = Ids.Variant_index.make 1;
            vd_payload = crr_s_ty };
        ];
    }

let crr_types = [| crr_s_def; crr_e_def |]

(* the user producer: returns its ref argument unchanged (the caller
   seeds distinct regions for the destination and the argument). *)
let crr_produce_fn : Seed_mir.function_ =
  {
    Seed_mir.name = "produce";
    instance = instance 1;
    params = [| { Type_repr.pt_convention = Access_effect.Let; pt_type = ref_ty } |];
    locals = [| ref_ty; ref_ty |];
    blocks =
      [|
        {
          Seed_mir.id = 0;
          statements =
            [ Seed_mir.Assign (pl 0, Seed_mir.Use (Seed_mir.Copy (pl 1))) ];
          terminator = Seed_mir.Ret;
        };
      |];
    entry = 0;
  }

let crr_prog (locals : Type_repr.t array)
    (statics : (string * Type_repr.t * bool * Seed_mir.constant option) array)
    (blocks : Seed_mir.block array) : Seed_mir.program =
  {
    Seed_mir.functions =
      [|
        { Seed_mir.name = "main"; instance = instance 0; params = [||]; locals; blocks; entry = 0 };
        crr_produce_fn;
      |];
    statics;
    types = crr_types;
  }

let crr_arg (l : int) : Seed_mir.call_arg =
  { Seed_mir.effect_ = Access_effect.Read; value = Seed_mir.Copy (pl l) }

let crr_struct (p : Vm_memory.pointer) : Vm_value.t =
  Vm_value.Struct (Vm_value.agg [| ref_of p |])
let crr_enum (tag : int) (payload : Vm_value.t array) : Vm_value.t =
  Vm_value.Enum (tag, Vm_value.agg payload)

let crr_ref_slot (what : string) (slot : Vm_value.slot)
    (p : Vm_memory.pointer) : unit =
  match slot with
  | Vm_value.Live v when Vm_value.equal v (ref_of p) -> ()
  | _ -> fail "%s: destination slot is not the expected region-backed ref" what

let check_call_result_destinations () =
  let seed_dest_arg (_vm : Vm.t) (frame : Vm_value.frame)
      (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <- Vm_value.Live (ref_of res.(0));
    frame.locals.(2) <- Vm_value.Live (ref_of res.(1))
  in
  (* (1) user function -> whole local *)
  let whole_local =
    crr_prog [| i64; ref_ty; ref_ty |] [||]
      [|
        { Seed_mir.id = 0; statements = [];
          terminator =
            Seed_mir.Call (pl 1, Seed_mir.User (instance 1), [| crr_arg 2 |], 1, None) };
        { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  (match seeded_run whole_local seed_dest_arg 2 with
   | Setup_error m -> fail "call dest whole local: setup: %s" m
   | Ran_error (m, _) -> fail "call dest whole local: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "user call -> whole local (displaced)" [ run.sres.(0) ];
       expect_owned run.svm "user call -> whole local (installed)" [ run.sres.(1) ];
       crr_ref_slot "user call -> whole local" run.sframe.locals.(1) run.sres.(1);
       pass "user call -> whole local: the displaced R1 dropped exactly once, the result R2 installed");
  (* (2) user function -> struct field *)
  let struct_field =
    let open Seed_mir in
    crr_prog [| i64; crr_s_ty; ref_ty |] [||]
      [|
        { id = 0; statements = [];
          terminator =
            Call
              ( { root = Local 1; projections = [ Field (Ids.Field_id.make 7011) ] },
                User (instance 1), [| crr_arg 2 |], 1, None ) };
        { id = 1; statements = []; terminator = Ret };
      |]
  in
  (match seeded_run struct_field
           (fun _ frame res ->
             frame.locals.(1) <- Vm_value.Live (crr_struct res.(0));
             frame.locals.(2) <- Vm_value.Live (ref_of res.(1)))
           2
   with
   | Setup_error m -> fail "call dest struct field: setup: %s" m
   | Ran_error (m, _) -> fail "call dest struct field: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "user call -> struct field (displaced)" [ run.sres.(0) ];
       expect_owned run.svm "user call -> struct field (installed)" [ run.sres.(1) ];
       (match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Struct fields)
          when Vm_value.agg_len fields = 1
               && Vm_value.equal (Vm_value.agg_get fields 0) (ref_of run.sres.(1)) -> ()
        | _ -> fail "user call -> struct field: the field does not hold the result");
       pass "user call -> struct field: the displaced R1 dropped exactly once, the field holds R2");
  (* (3) user function -> enum payload (downcast destination) *)
  let enum_payload =
    let open Seed_mir in
    crr_prog [| i64; crr_e_ty; ref_ty |] [||]
      [|
        { id = 0; statements = [];
          terminator =
            Call
              ( { root = Local 1;
                  projections = [ Downcast crr_v_ref; ConstantIndex 0 ] },
                User (instance 1), [| crr_arg 2 |], 1, None ) };
        { id = 1; statements = []; terminator = Ret };
      |]
  in
  (match seeded_run enum_payload
           (fun _ frame res ->
             frame.locals.(1) <- Vm_value.Live (crr_enum 0 [| ref_of res.(0) |]);
             frame.locals.(2) <- Vm_value.Live (ref_of res.(1)))
           2
   with
   | Setup_error m -> fail "call dest enum payload: setup: %s" m
   | Ran_error (m, _) -> fail "call dest enum payload: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "user call -> enum payload (displaced)" [ run.sres.(0) ];
       expect_owned run.svm "user call -> enum payload (installed)" [ run.sres.(1) ];
       (match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Enum (0, payload))
          when Vm_value.agg_len payload = 1
               && Vm_value.equal (Vm_value.agg_get payload 0) (ref_of run.sres.(1)) -> ()
        | _ -> fail "user call -> enum payload: the payload does not hold the result");
       pass "user call -> enum payload: the displaced R1 dropped exactly once, the payload holds R2");
  (* (4) user function -> nested [Downcast; Field] destination *)
  let nested_field =
    let open Seed_mir in
    crr_prog [| i64; crr_e_ty; ref_ty |] [||]
      [|
        { id = 0; statements = [];
          terminator =
            Call
              ( { root = Local 1;
                  projections = [ Downcast crr_v_struct; Field (Ids.Field_id.make 7011) ] },
                User (instance 1), [| crr_arg 2 |], 1, None ) };
        { id = 1; statements = []; terminator = Ret };
      |]
  in
  (match seeded_run nested_field
           (fun _ frame res ->
             frame.locals.(1) <-
               Vm_value.Live (crr_enum 1 [| ref_of res.(0) |]);
             frame.locals.(2) <- Vm_value.Live (ref_of res.(1)))
           2
   with
   | Setup_error m -> fail "call dest nested enum->struct: setup: %s" m
   | Ran_error (m, _) -> fail "call dest nested enum->struct: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "user call -> nested enum->struct field (displaced)" [ run.sres.(0) ];
       expect_owned run.svm "user call -> nested enum->struct field (installed)" [ run.sres.(1) ];
       (match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Enum (1, payload))
          when Vm_value.agg_len payload = 1
               && Vm_value.equal (Vm_value.agg_get payload 0) (ref_of run.sres.(1)) -> ()
        | _ -> fail "user call -> nested enum->struct: the nested field does not hold the result");
       pass
         "user call -> nested enum->struct field: the displaced R1 dropped exactly once, the deep field holds R2");
  (* (5) user function -> projected static destination *)
  let static_field =
    let open Seed_mir in
    crr_prog [| i64; ref_ty |]
      [| ("CRR_S", crr_s_ty, true, None) |]
      [|
        { id = 0; statements = [];
          terminator =
            Call
              ( { root = Static 0; projections = [ Field (Ids.Field_id.make 7011) ] },
                User (instance 1), [| crr_arg 1 |], 1, None ) };
        { id = 1; statements = []; terminator = Ret };
      |]
  in
  (match seeded_run static_field
           (fun _ frame res ->
             frame.statics.(0) <- Vm_value.Live (crr_struct res.(0));
             frame.locals.(1) <- Vm_value.Live (ref_of res.(1)))
           2
   with
   | Setup_error m -> fail "call dest projected static: setup: %s" m
   | Ran_error (m, _) -> fail "call dest projected static: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "user call -> projected static (displaced)" [ run.sres.(0) ];
       expect_owned run.svm "user call -> projected static (installed)" [ run.sres.(1) ];
       (match run.sframe.statics.(0) with
        | Vm_value.Live (Vm_value.Struct fields)
          when Vm_value.agg_len fields = 1
               && Vm_value.equal (Vm_value.agg_get fields 0) (ref_of run.sres.(1)) -> ()
        | _ -> fail "user call -> projected static: the static field does not hold the result");
       pass
         "user call -> projected static field: the displaced R1 dropped exactly once, the static holds R2");
  (* (6) host intrinsic -> whole local *)
  let host_whole =
    let open Seed_mir in
    crr_prog [| i64; ref_ty; vec_ty; i64 |] [||]
      [|
        { id = 0; statements = [];
          terminator =
            Call (pl 1, collection_intrinsic "__intrinsic_array_get",
                  [| mod_arg 2; read_arg 3 |], 1, None) };
        { id = 1; statements = []; terminator = Ret };
      |]
  in
  (match seeded_run host_whole
           (fun _ frame res ->
             frame.locals.(1) <- Vm_value.Live (ref_of res.(0));
             frame.locals.(2) <- Vm_value.Live (Vm_value.array [| ref_of res.(1) |]);
             frame.locals.(3) <- Vm_value.Live (int64_value 0L))
           2
   with
   | Setup_error m -> fail "host result -> whole local: setup: %s" m
   | Ran_error (m, _) -> fail "host result -> whole local: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "host result -> whole local (displaced)" [ run.sres.(0) ];
       expect_owned run.svm "host result -> whole local (copied element stays owned)"
         [ run.sres.(1) ];
       crr_ref_slot "host result -> whole local" run.sframe.locals.(1) run.sres.(1);
       pass
         "host intrinsic -> whole local: the displaced R1 dropped exactly once, the read element installed");
  (* (7) host intrinsic -> struct field *)
  let host_field =
    let open Seed_mir in
    crr_prog [| i64; crr_s_ty; vec_ty; i64 |] [||]
      [|
        { id = 0; statements = [];
          terminator =
            Call
              ( { root = Local 1; projections = [ Field (Ids.Field_id.make 7011) ] },
                collection_intrinsic "__intrinsic_array_get",
                [| mod_arg 2; read_arg 3 |], 1, None ) };
        { id = 1; statements = []; terminator = Ret };
      |]
  in
  (match seeded_run host_field
           (fun _ frame res ->
             frame.locals.(1) <- Vm_value.Live (crr_struct res.(0));
             frame.locals.(2) <- Vm_value.Live (Vm_value.array [| ref_of res.(1) |]);
             frame.locals.(3) <- Vm_value.Live (int64_value 0L))
           2
   with
   | Setup_error m -> fail "host result -> struct field: setup: %s" m
   | Ran_error (m, _) -> fail "host result -> struct field: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "host result -> struct field (displaced)" [ run.sres.(0) ];
       (match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Struct fields)
          when Vm_value.agg_len fields = 1
               && Vm_value.equal (Vm_value.agg_get fields 0) (ref_of run.sres.(1)) -> ()
        | _ -> fail "host result -> struct field: the field does not hold the result");
       pass
         "host intrinsic -> struct field: the displaced R1 dropped exactly once, the field holds the read element");
  (* (8) host intrinsic -> projected static *)
  let host_static =
    let open Seed_mir in
    crr_prog [| i64; vec_ty; i64 |]
      [| ("CRR_T", crr_s_ty, true, None) |]
      [|
        { id = 0; statements = [];
          terminator =
            Call
              ( { root = Static 0; projections = [ Field (Ids.Field_id.make 7011) ] },
                collection_intrinsic "__intrinsic_array_get",
                [| mod_arg 1; read_arg 2 |], 1, None ) };
        { id = 1; statements = []; terminator = Ret };
      |]
  in
  (match seeded_run host_static
           (fun _ frame res ->
             frame.statics.(0) <- Vm_value.Live (crr_struct res.(0));
             frame.locals.(1) <- Vm_value.Live (Vm_value.array [| ref_of res.(1) |]);
             frame.locals.(2) <- Vm_value.Live (int64_value 0L))
           2
   with
   | Setup_error m -> fail "host result -> projected static: setup: %s" m
   | Ran_error (m, _) -> fail "host result -> projected static: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "host result -> projected static (displaced)" [ run.sres.(0) ];
       (match run.sframe.statics.(0) with
        | Vm_value.Live (Vm_value.Struct fields)
          when Vm_value.agg_len fields = 1
               && Vm_value.equal (Vm_value.agg_get fields 0) (ref_of run.sres.(1)) -> ()
        | _ -> fail "host result -> projected static: the static field does not hold the result");
       pass
         "host intrinsic -> projected static field: the displaced R1 dropped exactly once, the static holds the read element");
  (* (9) uninitialized destination -> no drop, the result lands *)
  let uninit_dest =
    crr_prog [| i64; ref_ty; ref_ty |] [||]
      [|
        { Seed_mir.id = 0; statements = [];
          terminator =
            Seed_mir.Call (pl 1, Seed_mir.User (instance 1), [| crr_arg 2 |], 1, None) };
        { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  (match seeded_run uninit_dest
           (fun _ frame res -> frame.locals.(2) <- Vm_value.Live (ref_of res.(0)))
           1
   with
   | Setup_error m -> fail "call dest uninitialized: setup: %s" m
   | Ran_error (m, _) -> fail "call dest uninitialized: %s" m
   | Ran_ok run ->
       expect_owned run.svm "call dest uninitialized (nothing was displaced)" [ run.sres.(0) ];
       crr_ref_slot "call dest uninitialized" run.sframe.locals.(1) run.sres.(0);
       pass
         "call dest uninitialized: no drop ran (the slot was never initialized) and the result installed");
  (* (10) MovedOut destination -> no drop, the result lands *)
  let moved_dest = uninit_dest in
  (match seeded_run moved_dest
           (fun _ frame res ->
             frame.locals.(1) <- Vm_value.Moved;
             frame.locals.(2) <- Vm_value.Live (ref_of res.(0)))
           1
   with
   | Setup_error m -> fail "call dest moved-out: setup: %s" m
   | Ran_error (m, _) -> fail "call dest moved-out: %s" m
   | Ran_ok run ->
       expect_owned run.svm "call dest moved-out (nothing was displaced)" [ run.sres.(0) ];
       crr_ref_slot "call dest moved-out" run.sframe.locals.(1) run.sres.(0);
       pass "call dest moved-out: no drop ran (the slot was moved out) and the result installed");
  (* (11) a trapping call leaves the destination semantically intact *)
  let trap_dest =
    crr_prog [| i64; ref_ty |] [||]
      [|
        { Seed_mir.id = 0; statements = [];
          terminator =
            Seed_mir.Call (pl 1, Seed_mir.User (instance 99), [||], 1, None) };
        { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  (match seeded_run trap_dest
           (fun _ frame res -> frame.locals.(1) <- Vm_value.Live (ref_of res.(0)))
           1
   with
   | Setup_error m -> fail "call trap leaves dest: setup: %s" m
   | Ran_ok _ -> fail "call trap leaves dest: the unknown-instance call did not trap"
   | Ran_error (m, run) ->
       if not (contains m "unknown instance") then
         fail "call trap leaves dest: unexpected trap text: %s" m;
       expect_owned run.svm "call trap leaves dest (old value intact)" [ run.sres.(0) ];
       crr_ref_slot "call trap leaves dest" run.sframe.locals.(1) run.sres.(0);
       pass
         "trapping call: the old destination stays semantically intact (no drop before a result exists)");
  (* (12) a wrong-variant destination traps BEFORE dropping unrelated storage *)
  let wrong_variant =
    let open Seed_mir in
    crr_prog [| i64; crr_e_ty; ref_ty |] [||]
      [|
        { id = 0; statements = [];
          terminator =
            Call
              ( { root = Local 1; projections = [ Downcast crr_v_struct ] },
                User (instance 1), [| crr_arg 2 |], 1, None ) };
        { id = 1; statements = []; terminator = Ret };
      |]
  in
  (match seeded_run wrong_variant
           (fun _ frame res ->
             frame.locals.(1) <- Vm_value.Live (crr_enum 0 [| ref_of res.(0) |]);
             frame.locals.(2) <- Vm_value.Live (ref_of res.(1)))
           2
   with
   | Setup_error m -> fail "call dest wrong variant: setup: %s" m
   | Ran_ok _ -> fail "call dest wrong variant: the mismatched downcast did not trap"
   | Ran_error (m, run) ->
       if not (contains m "variant downcast") then
         fail "call dest wrong variant: unexpected trap text: %s" m;
       expect_owned run.svm "call dest wrong variant (unrelated storage untouched)"
         [ run.sres.(0); run.sres.(1) ];
       pass
         "wrong-variant destination: traps before dropping the unrelated live payload (both regions stay owned)");
  (* (13) repeated overwrite A -> B -> C drops exactly the two displaced values *)
  let repeated =
    crr_prog [| i64; ref_ty; ref_ty; ref_ty |] [||]
      [|
        { Seed_mir.id = 0; statements = [];
          terminator =
            Seed_mir.Call (pl 1, Seed_mir.User (instance 1), [| crr_arg 2 |], 1, None) };
        { Seed_mir.id = 1; statements = [];
          terminator =
            Seed_mir.Call (pl 1, Seed_mir.User (instance 1), [| crr_arg 3 |], 2, None) };
        { Seed_mir.id = 2; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  (match seeded_run repeated
           (fun _ frame res ->
             frame.locals.(1) <- Vm_value.Live (ref_of res.(0));
             frame.locals.(2) <- Vm_value.Live (ref_of res.(1));
             frame.locals.(3) <- Vm_value.Live (ref_of res.(2)))
           3
   with
   | Setup_error m -> fail "repeated overwrite: setup: %s" m
   | Ran_error (m, _) -> fail "repeated overwrite: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "repeated overwrite (both displaced values)" [ run.sres.(0); run.sres.(1) ];
       expect_owned run.svm "repeated overwrite (the final value)" [ run.sres.(2) ];
       crr_ref_slot "repeated overwrite" run.sframe.locals.(1) run.sres.(2);
       pass
         "repeated overwrite A->B->C: exactly the two displaced values dropped, the final result installed")

(* audit P1-8: dynamic-index destinations are tracked (the VM drops the
   displaced element) — both the assignment form and the call-result
   form. *)
let check_dynamic_index_overwrite_drop () =
  let arr_ty = Type_repr.Fixed_array (ref_ty, 3) in
  let idx = Seed_mir.Index 2 in
  let prog_assign =
    crr_prog [| i64; arr_ty; i64; ref_ty |] [||]
      [|
        { Seed_mir.id = 0;
          statements =
            [ Seed_mir.Assign
                ( { Seed_mir.root = Seed_mir.Local 1; projections = [ idx ] },
                  Seed_mir.Use (Seed_mir.Copy (pl 3)) ) ];
          terminator = Seed_mir.Ret };
      |]
  in
  let seed (_vm : Vm.t) (frame : Vm_value.frame) (res : Vm_memory.pointer array) : unit =
    frame.locals.(1) <-
      Vm_value.Live (Vm_value.array [| ref_of res.(0); ref_of res.(1); ref_of res.(2) |]);
    frame.locals.(2) <- Vm_value.Live (int64_value 1L);
    frame.locals.(3) <- Vm_value.Live (ref_of res.(3))
  in
  (match seeded_run prog_assign seed 4 with
   | Setup_error m -> fail "dynamic-index overwrite (assign): setup: %s" m
   | Ran_error (m, _) -> fail "dynamic-index overwrite (assign): %s" m
   | Ran_ok run ->
       expect_dropped run.svm "dynamic-index overwrite (displaced element)" [ run.sres.(1) ];
       expect_owned run.svm "dynamic-index overwrite (untouched siblings + new value)"
         [ run.sres.(0); run.sres.(2); run.sres.(3) ];
       (match run.sframe.locals.(1) with
        | Vm_value.Live (Vm_value.Array elems)
          when Vm_value.arr_length elems = 3
               && Vm_value.equal (Vm_value.arr_get elems 1) (ref_of run.sres.(3)) -> ()
        | _ -> fail "dynamic-index overwrite: the element was not replaced");
       pass
         "dynamic index overwrite: the displaced element drops exactly once and the new value lands");
  let prog_call =
    crr_prog [| i64; arr_ty; i64; ref_ty |] [||]
      [|
        { Seed_mir.id = 0; statements = [];
          terminator =
            Seed_mir.Call
              ( { Seed_mir.root = Seed_mir.Local 1; projections = [ idx ] },
                Seed_mir.User (instance 1), [| crr_arg 3 |], 1, None ) };
        { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  (match seeded_run prog_call seed 4 with
   | Setup_error m -> fail "dynamic-index overwrite (call result): setup: %s" m
   | Ran_error (m, _) -> fail "dynamic-index overwrite (call result): %s" m
   | Ran_ok run ->
       expect_dropped run.svm "dynamic-index call-result overwrite (displaced element)"
         [ run.sres.(1) ];
       expect_owned run.svm "dynamic-index call-result overwrite (siblings + result)"
         [ run.sres.(0); run.sres.(2); run.sres.(3) ];
       pass
         "dynamic index call-result overwrite: the displaced element drops exactly once through the call-result store")

(* audit P1-8: a deref destination over a REAL reference delegates the
   displaced drop to the target place (no leakage, no double drop). *)
let check_deref_place_overwrite_drop () =
  let prog =
    crr_prog [| i64; ref_ty; ref_ty; ref_ty |] [||]
      [|
        { Seed_mir.id = 0;
          statements = [ Seed_mir.Assign (pl 1, Seed_mir.Ref (pl 3)) ];
          terminator =
            Seed_mir.Call
              ( { Seed_mir.root = Seed_mir.Local 1; projections = [ Seed_mir.Deref ] },
                Seed_mir.User (instance 1), [| crr_arg 2 |], 1, None ) };
        { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Ret };
      |]
  in
  (match
     seeded_run prog
       (fun _ frame res ->
         frame.locals.(2) <- Vm_value.Live (ref_of res.(1));
         frame.locals.(3) <- Vm_value.Live (ref_of res.(0)))
       2
   with
   | Setup_error m -> fail "deref-place overwrite: setup: %s" m
   | Ran_error (m, _) -> fail "deref-place overwrite: %s" m
   | Ran_ok run ->
       expect_dropped run.svm "deref-place overwrite (displaced target value)" [ run.sres.(0) ];
       expect_owned run.svm "deref-place overwrite (installed target value)" [ run.sres.(1) ];
       crr_ref_slot "deref-place overwrite (the ref target place)" run.sframe.locals.(3) run.sres.(1);
       pass
         "deref destination over a real reference: the displaced target drops exactly once and the write lands in the target place")

(* audit P1-8 (the explicit `unsafe` boundary): a raw-pointer deref
   destination is a serialized memory image with no place identity.  The
   VM performs the store without attempting a displaced drop (never a
   guessed free into unidentifiable memory), and the scalar raw-store
   vocabulary works end to end.  The kernel's one owning raw-write
   primitive (std::ffi::write_ptr / SliceMut::write) is `unsafe` by
   contract: the caller owns the slot's lifecycle. *)
let check_raw_deref_store_boundary () =
  let raw_mut_i64 = Type_repr.Raw_ptr (Type_repr.Mutable, i64) in
  let prog =
    {
      Seed_mir.functions =
        [|
          {
            Seed_mir.name = "main";
            instance = instance 0;
            params = [||];
            locals = [| i64; raw_mut_i64 |];
            blocks =
              [|
                {
                  Seed_mir.id = 0;
                  statements =
                    [
                      Seed_mir.Assign
                        ( { Seed_mir.root = Seed_mir.Local 1;
                            projections = [ Seed_mir.Deref ] },
                          Seed_mir.Use (int_op 42) );
                      Seed_mir.Assign
                        ( pl 0,
                          Seed_mir.Use
                            (Seed_mir.Copy
                               { Seed_mir.root = Seed_mir.Local 1;
                                 projections = [ Seed_mir.Deref ] }) );
                    ];
                  terminator = Seed_mir.Ret;
                };
              |];
            entry = 0;
          };
        |];
      statics = [||];
      types = [||];
    }
  in
  (match
     seeded_run prog
       (fun vm frame _res ->
         match Vm_memory.alloc vm.Vm.memory 64 8 with
         | Ok p -> frame.locals.(1) <- Vm_value.Live (Vm_value.RawPtr p)
         | Error e -> fail "raw deref store: region alloc failed: %s" (Vm_memory.mem_error_string e))
       0
   with
   | Setup_error m -> fail "raw deref store: setup: %s" m
   | Ran_error (m, _) -> fail "raw deref store: %s" m
   | Ran_ok run -> (
       match run.sframe.locals.(0) with
       | Vm_value.Live (Vm_value.Int i) when Int_value.to_int64 i = 42L ->
           pass
             "raw deref boundary: a scalar raw store writes through the pointer and reads back (no displaced drop attempted — the explicit unsafe boundary)"
       | _ -> fail "raw deref store: the raw memory read back did not hold 42"))

(* (g2) CAPTURED-REF LIFETIME SCALE: the value-backed computed-ref
   representation must recycle: a long capture/drop loop returns the live
   capture count to baseline and allocates NO simulated VM region, and a
   dropped capture traps deterministically on a second drop. *)
let check_captured_ref_lifetime () =
  let m = Vm_memory.create () in
  let payload =
    Vm_value.Tuple
      (Vm_value.agg [| int64_value 7L; Vm_value.String "captured" |])
  in
  let baseline_live = !Vm_value.prof_captured_live in
  let baseline_regions = !Vm_memory.prof_regions in
  for _ = 1 to 100_000 do
    let rr = Vm_value.alloc_region_ref payload in
    Vm_value.drop_glue m (Vm_value.Ref (Vm_value.Region rr))
  done;
  if !Vm_value.prof_captured_live <> baseline_live then
    fail "captured refs: live count did not return to baseline (%d -> %d)"
      baseline_live !Vm_value.prof_captured_live
  else
    pass
      "captured refs: 100k capture/drop cycles return the live count to baseline";
  if !Vm_memory.prof_regions <> baseline_regions then
    fail "captured refs: capture allocated %d simulated VM region(s)"
      (!Vm_memory.prof_regions - baseline_regions)
  else pass "captured refs: no simulated VM region allocation per capture";
  let rr = Vm_value.alloc_region_ref payload in
  let v = Vm_value.Ref (Vm_value.Region rr) in
  Vm_value.drop_glue m v;
  if rr.Vm_value.rlive then
    fail "captured refs: drop did not clear the ownership flag"
  else pass "captured refs: drop clears the ownership flag exactly once";
  match
    (try
       Vm_value.drop_glue m v;
       `No_trap
     with Failure msg -> `Trap msg)
  with
  | `Trap msg when contains msg "freed region" ->
      pass "captured refs: a second drop traps deterministically"
  | `Trap msg ->
      fail "captured refs: double drop trapped with the wrong message: %s" msg
  | `No_trap -> fail "captured refs: double drop did not trap"

(* (g3) RSS GUARD: the parser reads the kB unit (page-size independent),
   and a requested ceiling is enforced from the first step — or fails
   closed at VM construction when the host cannot measure RSS. *)
let check_rss_guard () =
  (match Vm.vmrss_kb_of_status_line "VmRSS:\t  1234 kB" with
  | Some 1234 ->
      pass "RSS parser reads VmRSS kB (page-size independent)"
  | other ->
      fail "RSS parser returned %s"
        (match other with Some n -> string_of_int n | None -> "None"));
  let prog = dyn_index_fn [| i64 |] [] Seed_mir.Ret in
  match
    Vm.entry_frame_of_li
      ~limits:{ Vm.default_limits with max_rss_bytes = 1 }
      ~lang_items:Lang_items.seed_defaults ~program:prog
      ~entry:(entry_of prog) ~argv:[||]
  with
  | Error m when contains m "unavailable" ->
      pass "RSS ceiling fails closed when the host cannot measure RSS"
  | Error m -> fail "RSS guard: VM construction failed: %s" m
  | Ok (vm, frame) -> (
      match
        (try
           Vm.run_frame vm frame;
           `No_trap
         with Failure m -> `Trap m)
      with
      | `Trap m when contains m "RSS limit exceeded" ->
          pass "RSS ceiling trips from the first step"
      | `Trap m -> fail "RSS guard trapped with the wrong message: %s" m
      | `No_trap -> fail "RSS ceiling did not trip")

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
  check_inplace_set_alias ();
  (* audit top-P0/P1: recursive sharing propagation for nested arrays *)
  check_nested_sharing_tracking ();
  check_push_sharing_maintenance ();
  check_cyclic_mark ();
  check_store_mark_memoization ();
  check_map_snapshot ();
  check_nested_array_vm_alias ();
  check_nested_map_vm_alias ();
  check_nested_set_vm_alias ();
  (* audit P0/P1-2: enum-downcast projected writes *)
  check_edw_scalar_write ();
  check_edw_nested_array_write ();
  check_edw_field_write ();
  check_edw_deep_chain_write ();
  check_edw_wrong_variant_trap ();
  check_edw_non_enum_trap ();
  check_edw_rebuild_trap ();
  check_edw_alias_cow ();
  (* call-result destination replacement + P1-8 overwrite rules *)
  check_call_result_destinations ();
  check_dynamic_index_overwrite_drop ();
  check_deref_place_overwrite_drop ();
  check_raw_deref_store_boundary ();
  (* enum-downcast drop mirror: displaced owned components, COW, traps *)
  check_dmd_whole_root_drop ();
  check_dmd_payload_component_drop ();
  check_dmd_payload_field_drop ();
  check_dmd_payload_array_element_drop ();
  check_dmd_payload_array_cow ();
  check_dmd_wrong_variant_trap ();
  check_dmd_wrong_field_trap ();
  check_dmd_field_on_tuple_payload_trap ();
  check_dmd_moved_out_no_double_drop ();
  check_unwind_pair ();
  check_captured_ref_lifetime ();
  check_rss_guard ();
  if !failures = 0 then begin
    Printf.printf "ALL PASS\n";
    Selfcheck_sentinel.emit_and_exit "tg_vmsem"
  end
  else begin
    Printf.printf "%d FAILURE(S)\n" !failures;
    exit 1
  end
