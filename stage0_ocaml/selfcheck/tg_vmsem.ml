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
            Seed_mir.Assign ({ local = 1; projections = [] }, Seed_mir.Use (int_op 1));
            Seed_mir.Assign
              ({ local = 2; projections = [] },
               Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 10; int_op 20; int_op 30 ]));
            Seed_mir.Assign
              ({ local = 3; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy { local = 2; projections = [ Seed_mir.Index 1 ] }));
            Seed_mir.Assign ({ local = 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { local = 3; projections = [] }));
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
            Seed_mir.Assign ({ local = 1; projections = [] }, Seed_mir.Use (int_op 1));
            Seed_mir.Assign
              ({ local = 2; projections = [] },
               Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 10; int_op 20; int_op 30 ]));
            Seed_mir.Assign
              ({ local = 2; projections = [ Seed_mir.Index 1 ] },
               Seed_mir.Use (int_op 99));
            Seed_mir.Assign
              ({ local = 0; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy { local = 2; projections = [ Seed_mir.Index 1 ] }));
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
            Seed_mir.Assign ({ local = 1; projections = [] }, Seed_mir.Use (int_op 5));
            Seed_mir.Assign
              ({ local = 2; projections = [] },
               Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 10; int_op 20; int_op 30 ]));
            Seed_mir.Assign
              ({ local = 3; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy { local = 2; projections = [ Seed_mir.Index 1 ] }));
            Seed_mir.Assign ({ local = 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { local = 3; projections = [] }));
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
            Seed_mir.Assign ({ local = 1; projections = [] }, Seed_mir.Use (Seed_mir.Constant (int_value (-1L))));
            Seed_mir.Assign
              ({ local = 2; projections = [] },
               Seed_mir.Aggregate (Seed_mir.ArrayAgg, [ int_op 10; int_op 20; int_op 30 ]));
            Seed_mir.Assign
              ({ local = 3; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy { local = 2; projections = [ Seed_mir.Index 1 ] }));
            Seed_mir.Assign ({ local = 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { local = 3; projections = [] }));
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
            Seed_mir.Assign ({ local = 1; projections = [] }, Seed_mir.Use (int_op 0));
            Seed_mir.Assign
              ({ local = 2; projections = [] },
               Seed_mir.Aggregate (Seed_mir.TupleAgg, [ int_op 7; int_op 8 ]));
            Seed_mir.Assign
              ({ local = 3; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy { local = 2; projections = [ Seed_mir.Index 1 ] }));
            Seed_mir.Assign ({ local = 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { local = 3; projections = [] }));
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
                      Seed_mir.Assign ({ local = 1; projections = [] }, Seed_mir.Use (int_op 2));
                      Seed_mir.Assign ({ local = 2; projections = [] }, Seed_mir.Use (str_op "abc"));
                      Seed_mir.Assign
                        ({ local = 3; projections = [] },
                         Seed_mir.Use
                           (Seed_mir.Copy { local = 2; projections = [ Seed_mir.Index 1 ] }));
                    ];
                  terminator =
                    Seed_mir.SwitchInt
                      (Seed_mir.Copy { local = 3; projections = [] },
                       [ (99L, 1) ], 2) };
                { id = 1;
                  statements =
                    [ Seed_mir.Assign ({ local = 0; projections = [] }, Seed_mir.Use (int_op 1)) ];
                  terminator = Seed_mir.Ret };
                { id = 2;
                  statements =
                    [ Seed_mir.Assign ({ local = 0; projections = [] }, Seed_mir.Use (int_op 0)) ];
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
                      Seed_mir.Assign ({ local = 1; projections = [] }, Seed_mir.Use (int_op 4242));
                      Seed_mir.Assign
                        ({ local = 2; projections = [] },
                         Seed_mir.Cast (int_op 0, raw_ptr_ty));
                      (* store the u64 through the RawPtr *)
                      Seed_mir.Assign
                        ({ local = 2; projections = [ Seed_mir.Deref ] },
                         Seed_mir.Use (Seed_mir.Copy { local = 1; projections = [] }));
                      (* load it back *)
                      Seed_mir.Assign
                        ({ local = 3; projections = [] },
                         Seed_mir.Use
                           (Seed_mir.Copy { local = 2; projections = [ Seed_mir.Deref ] }));
                      (* String round-trip through the same pointer *)
                      Seed_mir.Assign
                        ({ local = 4; projections = [] }, Seed_mir.Use (str_op "hello, seed"));
                      Seed_mir.Assign
                        ({ local = 2; projections = [ Seed_mir.Deref ] },
                         Seed_mir.Use (Seed_mir.Copy { local = 4; projections = [] }));
                      Seed_mir.Assign
                        ({ local = 5; projections = [] },
                         Seed_mir.Use
                           (Seed_mir.Copy { local = 2; projections = [ Seed_mir.Deref ] }));
                      Seed_mir.Assign
                        ({ local = 6; projections = [] },
                         Seed_mir.BinaryOp
                           ( Seed_mir.Eq,
                             Seed_mir.Copy { local = 5; projections = [] },
                             str_op "hello, seed" ));
                    ];
                  terminator =
                    Seed_mir.Assert
                      (Seed_mir.Copy { local = 6; projections = [] }, true,
                       "string deref round-trip mismatch", 1) };
                { id = 1;
                  statements = [ Seed_mir.Assign ({ local = 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { local = 3; projections = [] })) ];
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
                      Seed_mir.Assign ({ local = 1; projections = [] }, Seed_mir.Use (int_op 5));
                      Seed_mir.Assign
                        ({ local = 2; projections = [] },
                         Seed_mir.Cast (int_op 0, raw_ptr_ty));
                      Seed_mir.Assign
                        ({ local = 2; projections = [ Seed_mir.Deref ] },
                         Seed_mir.Use (Seed_mir.Copy { local = 1; projections = [] }));
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
                      Seed_mir.Assign ({ local = 1; projections = [] }, Seed_mir.Use (int_op 7));
                      Seed_mir.Assign
                        ({ local = 2; projections = [] },
                         Seed_mir.Cast (int_op 0, raw_ptr_ty));
                      Seed_mir.Assign
                        ({ local = 3; projections = [] },
                         Seed_mir.Use
                           (Seed_mir.Copy { local = 2; projections = [ Seed_mir.Deref ] }));
                      Seed_mir.Assign ({ local = 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { local = 3; projections = [] }));
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
            Seed_mir.Assign ({ local = 1; projections = [] }, Seed_mir.Use (int_op 7));
            Seed_mir.Assign
              ({ local = 2; projections = [] },
               Seed_mir.RefMut { local = 1; projections = [] });
            Seed_mir.Assign
              ({ local = 2; projections = [ Seed_mir.Deref ] },
               Seed_mir.Use (int_op 99));
            Seed_mir.Assign
              ({ local = 3; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy { local = 2; projections = [ Seed_mir.Deref ] }));
            Seed_mir.Assign
              ({ local = 0; projections = [] },
               Seed_mir.BinaryOp
                 ( Seed_mir.Add,
                   Seed_mir.Copy { local = 1; projections = [] },
                   Seed_mir.Copy { local = 3; projections = [] } ));
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
              ({ local = 1; projections = [] },
               Seed_mir.Aggregate (Seed_mir.TupleAgg, [ int_op 5; int_op 6 ]));
            Seed_mir.Assign
              ({ local = 2; projections = [] },
               Seed_mir.RefMut { local = 1; projections = [ Seed_mir.ConstantIndex 1 ] });
            Seed_mir.Assign
              ({ local = 2; projections = [ Seed_mir.Deref ] },
               Seed_mir.Use (int_op 77));
            Seed_mir.Assign
              ({ local = 3; projections = [] },
               Seed_mir.Use
                 (Seed_mir.Copy
                    { local = 1; projections = [ Seed_mir.ConstantIndex 1 ] }));
            Seed_mir.Assign ({ local = 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { local = 3; projections = [] }));
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
          ({ local = 2; projections = [] },
           Seed_mir.Cast (int_op 0, raw_ptr_ty));
        Seed_mir.Assign
          ({ local = 3; projections = [] },
           Seed_mir.Ref { local = 2; projections = [ Seed_mir.Deref ] });
      ]
      @
      if write then
        [
          Seed_mir.Assign
            ({ local = 3; projections = [ Seed_mir.Deref ] },
             Seed_mir.Use (int_op 1));
        ]
      else
        [
          Seed_mir.Assign
            ({ local = 4; projections = [] },
             Seed_mir.Use
               (Seed_mir.Copy { local = 3; projections = [ Seed_mir.Deref ] }));
          Seed_mir.Assign ({ local = 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { local = 4; projections = [] }));
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
                    Seed_mir.Assign ({ local = 1; projections = [] }, Seed_mir.Use (str_op "hello"));
                    Seed_mir.Assign
                      ({ local = 2; projections = [] },
                       Seed_mir.Aggregate (Seed_mir.TupleAgg, [ int_op 10; int_op 20 ]));
                    Seed_mir.Assign
                      ({ local = 3; projections = [] },
                       Seed_mir.Aggregate
                         ( Seed_mir.TupleAgg,
                           [ Seed_mir.Move { local = 1; projections = [] };
                             Seed_mir.Move { local = 2; projections = [] } ] ));
                  ];
                terminator = Seed_mir.Drop ({ local = 3; projections = [] }, 1, None) };
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
                { id = 0; statements = [ Seed_mir.Assign ({ local = 1; projections = [] }, Seed_mir.Use (str_op "x")) ];
                  terminator = Seed_mir.Drop ({ local = 1; projections = [] }, 1, None) };
                { id = 1; statements = [];
                  terminator = Seed_mir.Drop ({ local = 1; projections = [] }, 2, None) };
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
                { id = 0; statements = [ Seed_mir.Assign ({ local = 1; projections = [] }, Seed_mir.Use (str_op "x")) ];
                  terminator = Seed_mir.Drop ({ local = 1; projections = [] }, 1, None) };
                { id = 1;
                  statements =
                    [
                      Seed_mir.Assign
                        ({ local = 2; projections = [] },
                         Seed_mir.Use (Seed_mir.Copy { local = 1; projections = [] }));
                      Seed_mir.Assign ({ local = 0; projections = [] }, Seed_mir.Use (Seed_mir.Copy { local = 2; projections = [] }));
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

let () =
  Printf.printf "Seed VM kernel-closure primitive self-check\n";
  check_dyn_index ();
  check_pointer ();
  check_ref_writeback ();
  check_recursive_drop ();
  check_serialization ();
  if !failures = 0 then begin
    Printf.printf "ALL PASS\n";
    exit 0
  end
  else begin
    Printf.printf "%d FAILURE(S)\n" !failures;
    exit 1
  end
