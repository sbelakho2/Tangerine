(* vmbench.ml — focused Seed VM dispatch-loop micro-benchmark.

   The stage0 seed's only VM tuning harness (kept out of selfcheck/dune:
   a benchmark is not a gate).  Build with plain `dune build`, then:
     _build/default/bench/vmbench.exe <arith|fields> [iterations]
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
   accounting is semantic); the ns/step is the tuning metric.

   push   — a hot loop calling the REAL `__intrinsic_array_push` host
            binding on a local Vec, N times (the kernel's
            CodeBuffer/emit8 shape).  Reports the total element copy
            count the growth path performed (sum of pre-push lengths)
            so the quadratic copy cost is visible directly. *)

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

(* ── push: the real __intrinsic_array_push host binding in a hot loop ─ *)

let push_id () : int =
  match Intrinsic_registry.lookup Intrinsic_registry.manifest ~name:"__intrinsic_array_push" with
  | Some (id, _) -> Intrinsic_registry.Id.to_int id
  | None -> failwith "vmbench: __intrinsic_array_push is not registered"

let push_program () : Seed_mir.program =
  let i64 = Type_repr.Int Type_repr.Int in
  let vec_t = Intrinsic_registry.vec_of i64 in
  let main_fn =
    { Seed_mir.name = "main";
      instance = instance 0;
      params = [||];
      locals = [| i64; vec_t; i64; Type_repr.Bool |];
      blocks =
        [| (* bb0: v = []; i = 0; goto bb1 *)
           { Seed_mir.id = 0;
             statements =
               [ assign 1 (Seed_mir.Aggregate (Seed_mir.ArrayAgg, []));
                 assign 2 (Seed_mir.Use (int_op 0)) ];
             terminator = Seed_mir.Goto 1 };
           (* bb1: v.push(i) — the Modify writeback channel *)
           { Seed_mir.id = 1;
             statements = [];
             terminator =
               Seed_mir.Call
                 ( loc 0,
                   Seed_mir.Intrinsic (push_id (), [| i64 |]),
                   [| { Seed_mir.effect_ = Access_effect.Modify; value = copy 1 };
                      { Seed_mir.effect_ = Access_effect.Consume; value = Seed_mir.Constant (Seed_mir.Integer (Int_value.of_int64 ~width:64 ~signed:true 1L)) } |],
                   2,
                   None ) };
           (* bb2: i = i + 1; cond = i < n; loop *)
           { Seed_mir.id = 2;
             statements =
               [ assign 2 (Seed_mir.BinaryOp (Seed_mir.Add, copy 2, int_op 1));
                 assign 3 (Seed_mir.BinaryOp (Seed_mir.Lt, copy 2, int_op !iterations)) ];
             terminator = Seed_mir.SwitchInt (copy 3, [ (1L, 1) ], 3) };
           (* bb3: _0 = len(v); Ret *)
           { Seed_mir.id = 3;
             statements = [ assign 0 (Seed_mir.Len (loc 1)) ];
             terminator = Seed_mir.Ret } |];
      entry = 0 }
  in
  { Seed_mir.functions = [| main_fn |]; statics = [||]; types = [||] }

(* ── sets: the byte-at-a-time fill loop (`v[i] = x`), the read_to_vec
   shape.  After a resize grows the vec to N, N direct element writes
   run; `sets_shared` first passes the vec to a Read host call (len),
   which clears the cell's owned status — the old whole-array copy per
   write. *)

let sets_program (shared : bool) : Seed_mir.program =
  let i64 = Type_repr.Int Type_repr.Int in
  let vec_t = Intrinsic_registry.vec_of i64 in
  let intrin name =
    match Intrinsic_registry.lookup Intrinsic_registry.manifest ~name with
    | Some (id, _) -> Intrinsic_registry.Id.to_int id
    | None -> failwith ("vmbench: " ^ name ^ " is not registered")
  in
  let resize_id = intrin "__intrinsic_array_resize" in
  let vec_param : Type_repr.param_type =
    { pt_convention = Access_effect.Let; pt_type = vec_t }
  in
  let touch_fn =
    { Seed_mir.name = "touch";
      instance = instance 1;
      params = [| vec_param |];
      locals = [| i64; vec_t |];
      blocks =
        [| { Seed_mir.id = 0;
             statements = [ assign 0 (Seed_mir.Use (int_op 0)) ];
             terminator = Seed_mir.Ret } |];
      entry = 0 }
  in
  let main_fn =
    { Seed_mir.name = "main";
      instance = instance 0;
      params = [||];
      locals = [| i64; vec_t; i64; i64; Type_repr.Bool |];
      blocks =
        [| (* bb0: v = []; v.resize(N, 0) *)
           { Seed_mir.id = 0;
             statements = [ assign 1 (Seed_mir.Aggregate (Seed_mir.ArrayAgg, [])) ];
             terminator =
               Seed_mir.Call
                 ( loc 0,
                   Seed_mir.Intrinsic (resize_id, [| i64 |]),
                   [| { Seed_mir.effect_ = Access_effect.Modify; value = copy 1 };
                      { Seed_mir.effect_ = Access_effect.Read; value = int_op !iterations };
                      { Seed_mir.effect_ = Access_effect.Consume;
                        value = Seed_mir.Constant
                                  (Seed_mir.Integer
                                     (Int_value.of_int64 ~width:64 ~signed:true 0L)) } |],
                   1,
                   None ) };
           (* bb1: (optional shared-marking len read) ; i = 0 *)
           { Seed_mir.id = 1;
             statements = [];
             terminator =
               (if shared then
                  Seed_mir.Call
                    ( loc 0,
                      Seed_mir.User (instance 1),
                      [| { Seed_mir.effect_ = Access_effect.Read; value = copy 1 } |],
                      2,
                      None )
                else Seed_mir.Goto 2) };
           (* bb2: i = 0; goto bb3 *)
           { Seed_mir.id = 2;
             statements = [ assign 2 (Seed_mir.Use (int_op 0)) ];
             terminator = Seed_mir.Goto 3 };
           (* bb3: v[i] = i (the direct element write) ; i = i + 1 *)
           { Seed_mir.id = 3;
             statements =
               [ Seed_mir.Assign
                   ( { Seed_mir.root = Seed_mir.Local 1;
                       projections = [ Seed_mir.Index 2 ] },
                     Seed_mir.Use (copy 2) );
                 assign 2 (Seed_mir.BinaryOp (Seed_mir.Add, copy 2, int_op 1));
                 assign 4 (Seed_mir.BinaryOp (Seed_mir.Lt, copy 2, int_op !iterations)) ];
             terminator = Seed_mir.SwitchInt (copy 4, [ (1L, 3) ], 4) };
           (* bb4: _0 = v.len(); Ret *)
           { Seed_mir.id = 4;
             statements = [ assign 0 (Seed_mir.Len (loc 1)) ];
             terminator = Seed_mir.Ret } |];
      entry = 0 }
  in
  { Seed_mir.functions = [| main_fn; touch_fn |]; statics = [||]; types = [||] }

(* ── arrcheck: randomized differential check of the growable-array
   algebra against a list model.  Every live view's content is compared
   after every operation, so an in-place mutation leaking into a view
   that must keep its old content is caught. *)

let arrcheck () : unit =
  let st = Random.State.make [| 20260926 |] in
  let views : (int, (Vm_value.arr * Vm_value.t list)) Hashtbl.t = Hashtbl.create 64 in
  let next_id = ref 0 in
  let add (a : Vm_value.arr) (model : Vm_value.t list) : int =
    incr next_id;
    Hashtbl.replace views !next_id (a, model);
    !next_id
  in
  let live () = Hashtbl.fold (fun k v acc -> (k, v) :: acc) views [] in
  let check_all (what : string) : unit =
    List.iter
      (fun (k, (a, model)) ->
        let got = Vm_value.arr_to_list a in
        if got <> model then begin
          Printf.printf "ARRCHECK FAIL after %s: view %d content mismatch\n" what k;
          exit 1
        end)
      (live ())
  in
  let pick () =
    let l = live () in
    fst (List.nth l (Random.State.int st (List.length l)))
  in
  let int i = Vm_value.Int (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int i)) in
  let tag (v : Vm_value.t) : int =
    match v with Vm_value.Int i -> Int64.to_int (Int_value.to_int64 i) | _ -> -1
  in
  let ensure () = Hashtbl.replace views (pick ()) (Hashtbl.find views (pick ())) in
  ignore ensure;
  let root = add (Vm_value.arr_empty) [] in
  ignore root;
  for step = 1 to 200_000 do
    (match Random.State.int st 10 with
     | 0 | 1 | 2 ->
         let k = pick () in
         let a, model = Hashtbl.find views k in
         let v = int step in
         Hashtbl.replace views k (Vm_value.arr_push a v, model @ [ v ])
     | 3 ->
         let k = pick () in
         let a, model = Hashtbl.find views k in
         (match Vm_value.arr_pop a with
          | None, a' ->
              if model <> [] then failwith "arrcheck: pop empty model";
              Hashtbl.replace views k (a', model)
          | Some v, a' -> (
              match List.rev model with
              | last :: rest ->
                  if tag v <> tag last then failwith "arrcheck: pop element mismatch";
                  Hashtbl.replace views k (a', List.rev rest)
              | [] -> failwith "arrcheck: pop from empty view"))
     | 4 | 5 ->
         let k = pick () in
         let a, model = Hashtbl.find views k in
         let n = Vm_value.arr_length a in
         if n > 0 then begin
           let i = Random.State.int st n in
           let v = int (step + 1000000) in
           let model' = List.mapi (fun j x -> if j = i then v else x) model in
           Hashtbl.replace views k (Vm_value.arr_set a i v, model')
         end
     | 6 ->
         (* a snapshot: a second holder of the same value — the VM marks
            the cell shared at every Read binding; model it *)
         let k = pick () in
         let a, model = Hashtbl.find views k in
         Vm_value.arr_mark_shared a;
         ignore (add a model)
     | 7 ->
         let k = pick () in
         let a, model = Hashtbl.find views k in
         let n = Vm_value.arr_length a in
         if n > 0 then begin
           let i = Random.State.int st n in
           let v = int (step + 2000000) in
           let model' = List.mapi (fun j x -> if j = i then v else x) model in
           Hashtbl.replace views k (Vm_value.arr_set_direct a i v, model')
         end
     | 8 ->
         let k = pick () in
         let a, model = Hashtbl.find views k in
         let b = Vm_value.arr_sub a 0 (Vm_value.arr_length a) in
         ignore (add b model)
     | _ ->
         let k = pick () in
         let a, model = Hashtbl.find views k in
         Hashtbl.replace views k (a, model));
    if step mod 1000 = 0 then check_all (Printf.sprintf "step %d" step)
  done;
  check_all "final";
  Printf.printf "ARRCHECK PASS (200000 ops)\n"

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
  if !mode = "arrcheck" then begin
    arrcheck ();
    exit 0
  end;
  let prog =
    if !mode = "fields" then fields_program ()
    else if !mode = "push" then push_program ()
    else if !mode = "sets" then sets_program false
    else if !mode = "sets_shared" then sets_program true
    else arith_program ()
  in
  let limits : Vm.limits =
    { Vm.default_limits with max_steps = max_int; max_host_calls = max_int }
  in
  match
    Vm.entry_frame_of_li ~limits ~lang_items:Lang_items.seed_defaults ~program:prog
      ~entry:(instance 0) ~argv:[||]
  with
  | Error m -> Printf.printf "setup error: %s\n" m; exit 1
   | Ok (vm, frame) ->
       let alloc0 = Gc.allocated_bytes () in
       let t0 = Unix.gettimeofday () in
       (match Vm.run_inspect vm frame with
        | Ok r -> Printf.printf "ret=%s " r
        | Error m -> Printf.printf "trap=%s " m);
       let dt = Unix.gettimeofday () -. t0 in
       let alloc = Gc.allocated_bytes () -. alloc0 in
       let steps = vm.Vm.steps in
       Printf.printf
         "mode=%s iterations=%d blocks=%d boxes=%d dummy_types=%d steps=%d wall=%.3fs ns/step=%.1f alloc=%.1fMB set_copies=%d\n"
         !mode !iterations !dummy_blocks !boxes !dummy_types steps dt
         (dt *. 1e9 /. float_of_int steps) (alloc /. 1048576.)
         !Vm_value.prof_set_copies
