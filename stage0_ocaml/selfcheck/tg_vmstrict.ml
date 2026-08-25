(* tg_vmstrict.ml — Seed VM strictness self-check.

   Proves the audit fixes with hand-constructed Seed_mir programs:
     (a) division/remainder by zero traps deterministically ("division by
         zero"), and signed min / -1 traps ("signed division overflow")
         instead of silently inventing a value;
     (b) a callee that returns without initializing its return slot traps
         as an invariant failure when the declared return type is not
         unit, while a Unit-typed callee may legitimately leave _0
         uninitialized and returns Unit;
     (c) a function whose block array is not indexed by block id
         (blocks.(i).id <> i) traps at frame creation;
     (d) Vm_memory strictness: negative sizes and invalid alignments are
         rejected at alloc, and free is strict (live base pointer only,
         exactly once). *)

let fail fmt = Printf.ksprintf (fun s -> Printf.printf "FAIL: %s\n" s; exit 1) fmt
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

let int_constant (n : int64) : Seed_mir.constant =
  Seed_mir.Integer (Int_value.of_int64 ~width:64 ~signed:true n)

let instance (callable : int) : Instance_id.t =
  Instance_id.make ~callable:(Ids.Callable_id.make callable) ~type_args:[||]

let run_program (prog : Seed_mir.program) : (int, Vm.vm_error) result =
  let entry = prog.Seed_mir.functions.(0).Seed_mir.instance in
  let host = Host.create ~repo_root:"." ~argv:[||] in
  Vm.run ~program:prog ~entry ~argv:[||] ~host

(* ── (a) division / remainder by zero, and signed min / -1 ────────── *)

let check_div_rem () =
  let mk (op : Seed_mir.bin_op) (l : int64) (r : int64) : Seed_mir.program =
    let fn =
      {
        Seed_mir.name = "main";
        instance = instance 0;
        params = [||];
        locals = [| i64 |];
        blocks =
          [|
            { id = 0;
              statements =
                [
                  Seed_mir.Assign
                    ({ local = 0; projections = [] },
                     Seed_mir.BinaryOp (op, Seed_mir.Constant (int_constant l),
                       Seed_mir.Constant (int_constant r)));
                ];
              terminator = Seed_mir.Ret };
          |];
        entry = 0;
      }
    in
    { Seed_mir.functions = [| fn |]; statics = [||]; types = [||] }
  in
  (match run_program (mk Seed_mir.Div 1L 0L) with
   | Error e when contains e.Vm.message "division by zero" ->
       pass "x = 1 / 0 traps deterministically (\"division by zero\")"
   | Error e -> fail "1 / 0 trapped with the wrong message: %s" e.Vm.message
   | Ok _ -> fail "1 / 0 did not trap");
  (match run_program (mk Seed_mir.Rem 1L 0L) with
   | Error e when contains e.Vm.message "division by zero" ->
       pass "x = 1 %% 0 traps deterministically (\"division by zero\")"
   | Error e -> fail "1 %% 0 trapped with the wrong message: %s" e.Vm.message
   | Ok _ -> fail "1 %% 0 did not trap");
  (match run_program (mk Seed_mir.Div Int64.min_int (-1L)) with
   | Error e when contains e.Vm.message "signed division overflow" ->
       pass "Int.min_value / -1 traps deterministically (\"signed division overflow\")"
   | Error e -> fail "min / -1 trapped with the wrong message: %s" e.Vm.message
   | Ok _ -> fail "min / -1 did not trap")

(* ── (b) uninitialized callee return slot ─────────────────────────── *)

let check_uninit_return () =
  let leaky_inst = instance 1 in
  let main_inst = instance 0 in
  let leaky =
    {
      Seed_mir.name = "leaky";
      instance = leaky_inst;
      params = [||];
      locals = [| i64 |];
      blocks = [| { id = 0; statements = []; terminator = Seed_mir.Ret } |];
      entry = 0;
    }
  in
  let main =
    {
      Seed_mir.name = "main";
      instance = main_inst;
      params = [||];
      locals = [| i64 |];
      blocks =
        [|
          { id = 0;
            statements = [];
            terminator =
              Seed_mir.Call ({ local = 0; projections = [] }, Seed_mir.User leaky_inst,
                [||], 1, None) };
          { id = 1; statements = []; terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  let prog = { Seed_mir.functions = [| main; leaky |]; statics = [||]; types = [||] } in
  (match run_program prog with
   | Error e when contains e.Vm.message "uninitialized return slot" ->
       pass "callee returning without initializing a non-Unit return slot traps (invariant)"
   | Error e -> fail "uninitialized return slot trapped with the wrong message: %s" e.Vm.message
   | Ok _ -> fail "uninitialized non-Unit return slot silently succeeded");
  (* positive: a Unit-typed callee may legitimately leave _0 uninitialized *)
  let unit_inst = instance 3 in
  let unit_main_inst = instance 2 in
  let unit_fn =
    {
      Seed_mir.name = "unit_leaky";
      instance = unit_inst;
      params = [||];
      locals = [| Type_repr.Unit |];
      blocks = [| { id = 0; statements = []; terminator = Seed_mir.Ret } |];
      entry = 0;
    }
  in
  let unit_main =
    {
      Seed_mir.name = "main";
      instance = unit_main_inst;
      params = [||];
      locals = [| Type_repr.Unit |];
      blocks =
        [|
          { id = 0;
            statements = [];
            terminator =
              Seed_mir.Call ({ local = 0; projections = [] }, Seed_mir.User unit_inst,
                [||], 1, None) };
          { id = 1; statements = []; terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  let prog_u = { Seed_mir.functions = [| unit_main; unit_fn |]; statics = [||]; types = [||] } in
  (match run_program prog_u with
   | Ok 0 -> pass "Unit-typed callee with uninitialized _0 returns Unit (legitimate)"
   | Error e -> fail "Unit-typed callee unexpectedly trapped: %s" e.Vm.message
   | Ok _ -> fail "Unit-typed callee program returned a non-zero exit code")

(* ── (c) block array must be indexed by block id ──────────────────── *)

let check_block_id_invariant () =
  let fn =
    {
      Seed_mir.name = "badblocks";
      instance = instance 0;
      params = [||];
      locals = [| Type_repr.Unit |];
      blocks =
        [|
          { id = 0; statements = []; terminator = Seed_mir.Goto 1 };
          { id = 0; statements = []; terminator = Seed_mir.Ret };
        |];
      entry = 0;
    }
  in
  let prog = { Seed_mir.functions = [| fn |]; statics = [||]; types = [||] } in
  let entry = prog.Seed_mir.functions.(0).Seed_mir.instance in
  (match Vm.entry_frame_of ~program:prog ~entry ~argv:[||] with
   | Error m when contains m "must be indexed by block id" ->
       pass "block array with blocks.(1).id = 0 traps at frame creation"
   | Error m -> fail "block-id invariant trapped with the wrong message: %s" m
   | Ok _ -> fail "out-of-order block ids passed frame creation");
  (match run_program prog with
   | Error e when contains e.Vm.message "must be indexed by block id" ->
       pass "block-id violation is reported as a deterministic VM error"
   | Error e -> fail "block-id violation reported with the wrong message: %s" e.Vm.message
   | Ok _ -> fail "block-id violation did not trap")

(* ── (d) Vm_memory strictness ─────────────────────────────────────── *)

let check_memory () =
  let m = Vm_memory.create () in
  (match Vm_memory.alloc m (-4) 8 with
   | Error e -> pass "alloc -4 returns Error (%s)" (Vm_memory.mem_error_string e)
   | Ok _ -> fail "alloc -4 succeeded (negative size must be rejected)");
  (match Vm_memory.alloc m 16 3 with
   | Error _ -> pass "alloc 16 align 3 returns Error (alignment must be a power of two)"
   | Ok _ -> fail "alloc 16 align 3 succeeded");
  (match Vm_memory.alloc m 16 0 with
   | Error _ -> pass "alloc 16 align 0 returns Error (alignment must be positive)"
   | Ok _ -> fail "alloc 16 align 0 succeeded");
  (match Vm_memory.alloc m 16 8 with
   | Error e -> fail "alloc 16 align 8 failed: %s" (Vm_memory.mem_error_string e)
   | Ok p ->
       (match Vm_memory.free m p with
        | Ok () -> pass "alloc 16 align 8 succeeds, free(ptr) succeeds"
        | Error e -> fail "free of a live base pointer failed: %s" (Vm_memory.mem_error_string e));
       (match Vm_memory.free m p with
        | Error _ -> pass "free(ptr) again returns Error (double free)"
        | Ok () -> fail "double free succeeded");
       let p_off = { p with Vm_memory.offset = 4 } in
       (match Vm_memory.free m p_off with
        | Error _ -> pass "free of a non-base pointer returns Error"
        | Ok () -> fail "free of a non-base pointer succeeded"));
  (match Vm_memory.free m { Vm_memory.region = 999; offset = 0 } with
   | Error _ -> pass "free of an invalid region returns Error"
   | Ok () -> fail "free of an invalid region succeeded")

let () =
  Printf.printf "Seed VM strictness self-check\n";
  check_div_rem ();
  check_uninit_return ();
  check_block_id_invariant ();
  check_memory ();
  Printf.printf "OK: vm strictness self-check passed\n";
  exit 0
