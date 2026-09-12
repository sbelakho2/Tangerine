(* vmbench.ml — focused Seed VM dispatch-loop micro-benchmark.

   Builds hand-constructed Seed MIR programs (same construction style as
   selfcheck/tg_vmsem.ml) that exercise the interpreter's per-instruction
   paths:
     arith  — a hot loop of integer binops and local copies, plus one
              user Call per iteration (frame push/pop + fn lookup);
     fields — a hot loop of struct-field projections (read + write), the
              clone-walk shape the bootstrap kernel spends most of its
              time in.
   Reports wall time, step count and ns/step.  The step count must be
   IDENTICAL before and after any interpreter optimisation (the step
   accounting is semantic); the ns/step is the tuning metric. *)

let iterations = ref 1_000_000
let mode = ref "arith"
let dummy_types = ref 0
let dummy_blocks = ref 1
let boxes = ref 0

let i64 = Type_repr.Int Type_repr.Int

let int_op (n : int) : Seed_mir.operand =
  Seed_mir.Constant
    (Seed_mir.Integer (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int n)))

let loc (l : int) : Seed_mir.place = { Seed_mir.root = Seed_mir.Local l; projections = [] }
let copy (l : int) : Seed_mir.operand = Seed_mir.Copy (loc l)
let assign (l : int) (rv : Seed_mir.rvalue) : Seed_mir.statement = Seed_mir.Assign (loc l, rv)
let binop op a b = Seed_mir.BinaryOp (op, copy a, copy b)

let instance (c : int) : Instance_id.t =
  Instance_id.make ~callable:(Ids.Callable_id.make c) ~type_args:[||]

let param : Type_repr.param_type = { pt_convention = Access_effect.Let; pt_type = i64 }

(* when VMBENCH_BOXES > 0 the callee's parameter is a Named type and the
   VM's box-instance list is populated, so every call's transparent-box
   check scans that list (the kernel's mono'd Box[T] world) *)
let box_param : Type_repr.param_type =
  { pt_convention = Access_effect.Let; pt_type = Type_repr.Named (Ids.Type_id.make 5000, [||]) }

let callee_param () : Type_repr.param_type = if !boxes > 0 then box_param else param

(* ── arith: a loop with 8 statements + 1 call per iteration ───────── *)

let arith_program () : Seed_mir.program =
  let nblocks = max 1 !dummy_blocks in
  let step_fn =
    { Seed_mir.name = "step";
      instance = instance 1;
      params = [| callee_param () |];
      locals = [| i64; i64 |];
      blocks =
        Array.init nblocks (fun i ->
            if i = 0 then
              { Seed_mir.id = i;
                statements = [ assign 0 (Seed_mir.Use (copy 1)) ];
                terminator = Seed_mir.Ret }
            else
              (* unreachable blocks: the frame-shape validation walks
                 every block on each call, so this measures that walk *)
              { Seed_mir.id = i; statements = []; terminator = Seed_mir.Ret });
      entry = 0 }
  in
  let hot_fn =
    { Seed_mir.name = "hot";
      instance = instance 2;
      params = [| param |];
      locals = [| i64; i64; i64; i64; i64; Type_repr.Bool |];
      blocks =
        [| (* bb0: i = 0; acc = 0; goto bb1 *)
           { Seed_mir.id = 0;
             statements = [ assign 2 (Seed_mir.Use (int_op 0)); assign 3 (Seed_mir.Use (int_op 0)) ];
             terminator = Seed_mir.Goto 1 };
           (* bb1: arithmetic body; then the per-iteration call in bb3 *)
           { Seed_mir.id = 1;
             statements =
               [ assign 3 (binop Seed_mir.Add 3 2);      (* acc = acc + i *)
                 assign 4 (binop Seed_mir.Mul 3 2);      (* tmp = acc * i *)
                 assign 5 (binop Seed_mir.Sub 4 2);      (* j = tmp - i *)
                 assign 3 (binop Seed_mir.Add 5 4);      (* acc = j + tmp *)
                 assign 4 (Seed_mir.Use (copy 3));       (* tmp = acc *)
                 Seed_mir.Assign (loc 5, Seed_mir.Use (Seed_mir.Copy (loc 4)));
                 assign 3 (binop Seed_mir.Add 3 4) ];    (* acc = acc + tmp *)
             terminator = Seed_mir.Goto 3 };
           (* bb2: _0 = move acc; Ret *)
           { Seed_mir.id = 2;
             statements = [ assign 0 (Seed_mir.Use (Seed_mir.Copy (loc 3))) ];
             terminator = Seed_mir.Ret };
           (* bb3: tmp = step(acc) — the user-call boundary *)
           { Seed_mir.id = 3;
             statements = [];
             terminator =
               Seed_mir.Call
                 ( loc 4,
                   Seed_mir.User (instance 1),
                   [| { Seed_mir.effect_ = Access_effect.Read; value = copy 3 } |],
                   4,
                   None ) };
           (* bb4: i = i + 1; cond = i < n; loop *)
           { Seed_mir.id = 4;
             statements =
               [ assign 2 (Seed_mir.BinaryOp (Seed_mir.Add, copy 2, int_op 1));
                 assign 5 (binop Seed_mir.Lt 2 1) ];
             terminator = Seed_mir.SwitchInt (copy 5, [ (1L, 1) ], 2) } |];
      entry = 0 }
  in
  (* main: call hot(n) -> _0; Ret *)
  let main_fn =
    { Seed_mir.name = "main";
      instance = instance 0;
      params = [||];
      locals = [| i64; i64 |];
      blocks =
        [| { Seed_mir.id = 0;
             statements = [ assign 1 (Seed_mir.Use (int_op !iterations)) ];
             terminator =
               Seed_mir.Call
                 ( loc 0,
                   Seed_mir.User (instance 2),
                   [| { Seed_mir.effect_ = Access_effect.Read; value = copy 1 } |],
                   1,
                   None ) };
           { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Ret } |];
      entry = 0 }
  in
  { Seed_mir.functions = [| main_fn; step_fn; hot_fn |]; statics = [||]; types = [||] }

(* ── fields: struct-field read/write walk ─────────────────────────── *)

let field_tid = Ids.Type_id.make 1
let fid a = Ids.Field_id.make a

let field_defs : Seed_mir.type_def =
  Seed_mir.StructDef
    { sd_id = field_tid;
      sd_fields =
        [ { Seed_mir.fd_id = fid 10; fd_index = Ids.Field_index.make 0; fd_ty = i64 };
          { Seed_mir.fd_id = fid 11; fd_index = Ids.Field_index.make 1; fd_ty = i64 };
          { Seed_mir.fd_id = fid 12; fd_index = Ids.Field_index.make 2; fd_ty = i64 } ] }

let proj (l : int) (f : int) : Seed_mir.place =
  { Seed_mir.root = Seed_mir.Local l; projections = [ Seed_mir.Field (fid f) ] }

let fields_program () : Seed_mir.program =
  (* dummy defs *before* the live struct make find_def's linear scan walk
     them on every field lookup, mirroring a closure with many types *)
  let dummies =
    Array.init !dummy_types (fun i ->
        Seed_mir.StructDef
          { sd_id = Ids.Type_id.make (1000 + i); sd_fields = [] })
  in
  let types = Array.append dummies [| field_defs |] in
  let hot_fn =
    { Seed_mir.name = "hot";
      instance = instance 2;
      params = [| param |];
      locals = [| i64; i64; i64; i64; Type_repr.Bool; Type_repr.Named (field_tid, [||]) |];
      blocks =
        [| (* bb0: s = {0,0,0}; i = 0; goto bb1 *)
           { Seed_mir.id = 0;
             statements =
               [ assign 5
                   (Seed_mir.Aggregate
                      ( Seed_mir.StructCtor
                          ( field_tid,
                            [| Ids.Field_index.make 0; Ids.Field_index.make 1; Ids.Field_index.make 2 |] ),
                        [ int_op 0; int_op 0; int_op 0 ] ));
                 assign 2 (Seed_mir.Use (int_op 0)) ];
             terminator = Seed_mir.Goto 1 };
           (* bb1: read two fields, write one back, bump i, loop *)
           { Seed_mir.id = 1;
             statements =
               [ assign 3
                   (Seed_mir.BinaryOp
                      ( Seed_mir.Add,
                        Seed_mir.Copy (proj 5 10),
                        Seed_mir.Copy (proj 5 11) ));
                 Seed_mir.Assign (proj 5 12, Seed_mir.Use (copy 3));
                 assign 3 (binop Seed_mir.Mul 3 2);
                 Seed_mir.Assign (proj 5 10, Seed_mir.Use (copy 3));
                 assign 2 (Seed_mir.BinaryOp (Seed_mir.Add, copy 2, int_op 1));
                 assign 4 (binop Seed_mir.Lt 2 1) ];
             terminator = Seed_mir.SwitchInt (copy 4, [ (1L, 1) ], 2) };
           { Seed_mir.id = 2;
             statements = [ assign 0 (Seed_mir.Use (copy 3)) ];
             terminator = Seed_mir.Ret } |];
      entry = 0 }
  in
  let main_fn =
    { Seed_mir.name = "main";
      instance = instance 0;
      params = [||];
      locals = [| i64; i64 |];
      blocks =
        [| { Seed_mir.id = 0;
             statements = [ assign 1 (Seed_mir.Use (int_op !iterations)) ];
             terminator =
               Seed_mir.Call
                 ( loc 0,
                   Seed_mir.User (instance 2),
                   [| { Seed_mir.effect_ = Access_effect.Read; value = copy 1 } |],
                   1,
                   None ) };
           { Seed_mir.id = 1; statements = []; terminator = Seed_mir.Ret } |];
      entry = 0 }
  in
  { Seed_mir.functions = [| main_fn; hot_fn |]; statics = [||]; types }

let () =
  let args = Array.to_list Sys.argv in
  (match args with
   | _ :: m :: rest ->
       mode := m;
       (match rest with
        | n :: _ -> ( match int_of_string_opt n with Some x -> iterations := x | None -> ())
        | [] -> ())
   | _ -> ());
  (match Sys.getenv_opt "VMBENCH_DUMMY_TYPES" with
   | Some s -> ( match int_of_string_opt s with Some x -> dummy_types := x | None -> ())
   | None -> ());
  (match Sys.getenv_opt "VMBENCH_BLOCKS" with
   | Some s -> ( match int_of_string_opt s with Some x -> dummy_blocks := x | None -> ())
   | None -> ());
  (match Sys.getenv_opt "VMBENCH_BOXES" with
   | Some s -> ( match int_of_string_opt s with Some x -> boxes := x | None -> ())
   | None -> ());
  let prog = if !mode = "fields" then fields_program () else arith_program () in
  let limits : Vm.limits = { Vm.default_limits with max_steps = max_int } in
  let box_instances =
    Array.to_list (Array.init !boxes (fun i -> Ids.Type_id.make (6000 + i)))
  in
  match
    Vm.entry_frame_of_li ~limits ~lang_items:Lang_items.seed_defaults ~box_instances
      ~program:prog ~entry:(instance 0) ~argv:[||]
  with
  | Error m -> Printf.printf "setup error: %s\n" m; exit 1
  | Ok (vm, frame) ->
      let t0 = Unix.gettimeofday () in
      (match Vm.run_inspect vm frame with
       | Ok r -> Printf.printf "ret=%s " r
       | Error m -> Printf.printf "trap=%s " m);
      let dt = Unix.gettimeofday () -. t0 in
      let steps = vm.Vm.steps in
      Printf.printf
        "mode=%s iterations=%d blocks=%d boxes=%d dummy_types=%d steps=%d wall=%.3fs ns/step=%.1f\n"
        !mode !iterations !dummy_blocks !boxes !dummy_types steps dt
        (dt *. 1e9 /. float_of_int steps)
