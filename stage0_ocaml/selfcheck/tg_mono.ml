let let_param (ty : Type_repr.t) : Type_repr.param_type = { Type_repr.pt_convention = Access_effect.Let; pt_type = ty }
(* tg_mono.ml — Monomorphizer exact-arity and specialization self-check
   (audit P0: "Preserve generic substitutions through lowering").

   Hand-constructed Seed_mir programs (same construction style as
   tg_vmsem.ml / tg_verify.ml) exercising the monomorphizer's side of
   the audit: Mono.build is the public entry (driver.ml calls it after
   lowering); a template is a function whose instance carries its
   generic parameters in declaration order ([Type_param 0; Type_param 1]
   for f[T,U]) and whose body types reference those parameters; a call
   instance carries the concrete substitutes positionally.

     (a) TWO CONCRETE INSTANTIATIONS OF ONE TEMPLATE: f[T] specialized
         at T:=Int and T:=String yields two distinct specializations;
         both execute under the Seed VM and the mono output verifies;
     (b) DUPLICATE SPECIALIZATION: the same instance discovered twice
         reuses one specialization — the output holds the instance
         exactly once (the seen-set/cache dedup; the template lookup is
         first-wins over the immutable input program, so a
         re-discovered instance would re-specialize to the identical
         body and the re-specialization is skipped);
     (c) EXACT-ARITY ENFORCEMENT: a template declaring 2 parameters with
         a call instance carrying 1 argument, and a 1-parameter template
         with a 2-argument instance, fail Mono.build with the internal
         error "template arity N != instance arity M for callable C";
     (d) GENERIC CALLS FROM GENERIC CALLERS (nested-substitution
         chaining): outer[T] calls mid[T] calls inner[T] — the callee
         instances carry the CALLER's Type_param; the caller's
         substitution must be applied to the callee instance args
         before matching/specializing, and the specialization cache is
         memoized by the SUBSTITUTED args (outer[Int] -> mid[Int] ->
         inner[Int], outer[String] -> mid[String] -> inner[String]);
   (e) NESTED GENERIC TYPE ARGUMENTS: inner is instantiated with
       Named(type#7,[T]) where T is the caller's parameter — the
       substitution recurses through the generic type's arguments;
   (f) POST-MONO CONCRETE TYPE-INSTANCE MATERIALIZATION (the re-audit
       finding: "generic nominal type definitions disappear before
       MIR"): a generic struct Pair[T] { first: T; second: T } (the
       template def whose fields carry Type_param) instantiated at
       Pair[Int] and Pair[String] through the CALL instances — the
       monomorphizer queues (pair_tid, [Int]) and (pair_tid, [String])
       as required concrete type definitions, and the driver's post-mono
       materialization produces BOTH concrete StructDefs (fields
       substituted Int,Int / String,String) with the semantic FieldIds
       preserved from the original def, mints a distinct fresh TypeId
       per instance, rewrites every Named mention (bodies, call
       instances, aggregate kinds) to the fresh identities, and the
       final program verifies and executes.

   Generic method calls are NOT representable in Seed MIR: the MIR has
   no method-call form (lowering of a method call is a seed_bug in
   mir_lower.ml), so the same substitution mechanics are covered by
   (d)/(e) instead.

   Prints PASS/FAIL per check and a final ALL MONO PASS line. *)

let failures = ref 0

let fail fmt = Printf.ksprintf (fun s -> Printf.printf "FAIL: %s\n" s; incr failures) fmt
let pass fmt = Printf.ksprintf (fun s -> Printf.printf "PASS: %s\n" s) fmt

(* Substring test (same as tg_vmsem's). *)
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

(* ── construction helpers ─────────────────────────────────────────── *)

let i64 = Type_repr.Int Type_repr.Int
let string_ty = Type_repr.String
let bool_ty = Type_repr.Bool

let int_value (n : int64) : Seed_mir.constant =
  Seed_mir.Integer (Int_value.of_int64 ~width:64 ~signed:true n)

let int_op (n : int) : Seed_mir.operand = Seed_mir.Constant (int_value (Int64.of_int n))
let str_op (s : string) : Seed_mir.operand = Seed_mir.Constant (Seed_mir.String s)

let tparam (n : int) : Type_repr.t = Type_repr.Type_param (Ids.Generic_param_id.make n)

let inst (callable : int) (args : Type_repr.t array) : Instance_id.t =
  Instance_id.make ~callable:(Ids.Callable_id.make callable) ~type_args:args

let place (l : int) : Seed_mir.place = { Seed_mir.root = Seed_mir.Local l; projections = [] }

let copy (l : int) : Seed_mir.operand = Seed_mir.Copy (place l)
let move_ (l : int) : Seed_mir.operand = Seed_mir.Move (place l)

let assign (l : int) (rv : Seed_mir.rvalue) : Seed_mir.statement =
  Seed_mir.Assign (place l, rv)

let call_arg (op : Seed_mir.operand) : Seed_mir.call_arg =
  { Seed_mir.effect_ = Access_effect.Read; value = op }

let call (dest : int) (callee : Seed_mir.callee) (args : Seed_mir.call_arg array)
    (next : int) : Seed_mir.terminator =
  Seed_mir.Call (place dest, callee, args, next, None)

let mk_fn (name : string) (instance : Instance_id.t) (params : Type_repr.t array)
    (locals : Type_repr.t array) (blocks : Seed_mir.block array) (entry : int) :
    Seed_mir.function_ =
  { Seed_mir.name;
    instance;
    params = Array.map (fun ty -> let_param(ty)) params;
    locals;
    blocks;
    entry }

(* A generic identity template f[T] -> T: _0 is the return slot, _1 the
   parameter slot.  The body MOVES the parameter into the return slot
   (a Copy would be illegal once T := String — the verifier rejects
   copies of non-Copy values). *)
let identity_template (name : string) (callable : int) : Seed_mir.function_ =
  mk_fn name (inst callable [| tparam 0 |]) [| tparam 0 |] [| tparam 0; tparam 0 |]
    [|
      { Seed_mir.id = 0;
        statements = [ assign 0 (Seed_mir.Use (move_ 1)) ];
        terminator = Seed_mir.Ret };
    |]
    0

let mk_prog (fns : Seed_mir.function_ array) (types : Seed_mir.type_def array) :
    Seed_mir.program =
  { Seed_mir.functions = fns; statics = [||]; types }

let mono_of (prog : Seed_mir.program) : (Seed_mir.program, string list) result =
  let entry = prog.Seed_mir.functions.(0).Seed_mir.instance in
  match Mono.build ~entry prog with
  | Error errs -> Error errs
  | Ok fns -> Ok { prog with Seed_mir.functions = fns }

let find_by_callable (prog : Seed_mir.program) (c : int) : Seed_mir.function_ list =
  Array.to_list prog.Seed_mir.functions
  |> List.filter (fun f ->
         Ids.Callable_id.to_int (Instance_id.callable f.Seed_mir.instance) = c)

let fn_is_concrete (f : Seed_mir.function_) : bool =
  not (Array.exists Type_repr.has_type_param (Instance_id.type_args f.Seed_mir.instance))
  && Array.for_all (fun p -> not (Type_repr.has_type_param p.Type_repr.pt_type)) f.Seed_mir.params
  && not (Array.exists Type_repr.has_type_param f.Seed_mir.locals)

(* ── (a) two concrete instantiations of one template ──────────────── *)

let check_two_instantiations () =
  let f = identity_template "f" 1 in
  (* main returns the f[String] result (moved) so the verifier accepts
     the String value (no copies of non-Copy values); the f[Int] result
     is asserted equal to 42, so both specializations demonstrably run *)
  let main =
    mk_fn "main" (inst 0 [||]) [||]
      [| string_ty; i64; i64; string_ty; bool_ty |]
      [|
        { Seed_mir.id = 0;
          statements = [];
          terminator =
            call 2 (Seed_mir.User (inst 1 [| i64 |])) [| call_arg (int_op 42) |] 1 };
        { Seed_mir.id = 1;
          statements = [];
          terminator =
            call 3 (Seed_mir.User (inst 1 [| string_ty |])) [| call_arg (str_op "hi") |] 2 };
        { Seed_mir.id = 2;
          statements =
            [ assign 4 (Seed_mir.BinaryOp (Seed_mir.Eq, copy 2, int_op 42)) ];
          terminator = Seed_mir.Assert (copy 4, true, "f[Int] result mismatch", 3) };
        { Seed_mir.id = 3;
          statements = [ assign 0 (Seed_mir.Use (move_ 3)) ];
          terminator = Seed_mir.Ret };
      |]
      0
  in
  (match mono_of (mk_prog [| main; f |] [||]) with
   | Error errs ->
       fail "two instantiations: mono build failed: %s" (String.concat "; " errs)
   | Ok mono_prog ->
       let f_ints = find_by_callable mono_prog 1 in
       if List.length f_ints <> 2 then
         fail "two instantiations: expected 2 specializations of callable 1, got %d"
           (List.length f_ints)
       else if not (List.for_all fn_is_concrete f_ints) then
         fail "two instantiations: a specialized body still carries a Type_param"
       else
         let has_int =
           List.exists (fun f ->
               Instance_id.type_args f.Seed_mir.instance = [| i64 |]
               && f.Seed_mir.params.(0).Type_repr.pt_type = i64)
             f_ints
         in
         let has_str =
           List.exists (fun f ->
               Instance_id.type_args f.Seed_mir.instance = [| string_ty |]
               && f.Seed_mir.params.(0).Type_repr.pt_type = string_ty)
             f_ints
         in
         if not (has_int && has_str) then
           fail "two instantiations: expected f[Int] and f[String] specializations"
         else
           (match Mir_verify.require_valid mono_prog with
            | Error errs ->
                fail "two instantiations: mono output fails Mir_verify: %s"
                  (String.concat "; " errs)
            | Ok () -> (
                match
                  Vm.entry_frame_of ~program:mono_prog ~entry:(mono_prog.Seed_mir.functions.(0).Seed_mir.instance)
                    ~argv:[||]
                with
                | Error m -> fail "two instantiations: entry_frame_of: %s" m
                | Ok (vm, frame) -> (
                    match Vm.run_inspect vm frame with
                    | Ok "hi" ->
                        pass "two instantiations: f[Int] and f[String] both specialize and execute (Int assert passes, String returns \"hi\")"
                    | Ok other ->
                        fail "two instantiations: unexpected return %s (expected hi)" other
                    | Error m -> fail "two instantiations: vm: %s" m))))

(* ── (b) duplicate specialization dedups ───────────────────────────── *)

let check_duplicate_specialization () =
  let f = identity_template "f" 1 in
  let main =
    mk_fn "main" (inst 0 [||]) [||] [| i64; i64; i64; i64 |]
      [|
        { Seed_mir.id = 0;
          statements = [ assign 1 (Seed_mir.Use (int_op 7)) ];
          terminator =
            call 2 (Seed_mir.User (inst 1 [| i64 |])) [| call_arg (copy 1) |] 1 };
        { Seed_mir.id = 1;
          statements = [];
          terminator =
            call 3 (Seed_mir.User (inst 1 [| i64 |])) [| call_arg (int_op 7) |] 2 };
        { Seed_mir.id = 2;
          statements = [ assign 0 (Seed_mir.Use (copy 2)) ];
          terminator = Seed_mir.Ret };
      |]
      0
  in
  (match mono_of (mk_prog [| main; f |] [||]) with
   | Error errs ->
       fail "duplicate specialization: mono build failed: %s" (String.concat "; " errs)
   | Ok mono_prog ->
       let n = Array.length mono_prog.Seed_mir.functions in
       let f_count = List.length (find_by_callable mono_prog 1) in
       if n <> 2 then
         fail "duplicate specialization: expected 2 output functions (main + one f[Int]), got %d" n
       else if f_count <> 1 then
         fail "duplicate specialization: f[Int] was specialized %d times (expected once)" f_count
       else begin
         (* the two calls in main's body must reference the same instance *)
         let calls =
           Array.to_list mono_prog.Seed_mir.functions.(0).Seed_mir.blocks
           |> List.concat_map (fun b ->
                  match b.Seed_mir.terminator with
                  | Seed_mir.Call (_, Seed_mir.User i, _, _, _) -> [ i ]
                  | _ -> [])
         in
         match calls with
         | [ a; b ] when Instance_id.compare a b = 0 ->
             pass "duplicate specialization: the repeated f[Int] instance is specialized once and shared by both call sites"
         | _ ->
             fail "duplicate specialization: expected 2 identical call instances in main, found %d"
               (List.length calls)
       end)

(* ── (c) exact-arity enforcement ───────────────────────────────────── *)

let check_arity_mismatch () =
  (* template f[T,U] (2 params) called with a 1-argument instance *)
  let g =
    mk_fn "g" (inst 2 [| tparam 0; tparam 1 |]) [| tparam 0; tparam 1 |]
      [| tparam 0; tparam 0; tparam 1 |]
      [|
        { Seed_mir.id = 0;
          statements = [ assign 0 (Seed_mir.Use (copy 1)) ];
          terminator = Seed_mir.Ret };
      |]
      0
  in
  let main1 =
    mk_fn "main" (inst 0 [||]) [||] [| i64; i64 |]
      [|
        { Seed_mir.id = 0;
          statements = [];
          terminator = call 1 (Seed_mir.User (inst 2 [| i64 |])) [| call_arg (int_op 1) |] 1 };
        { Seed_mir.id = 1;
          statements = [ assign 0 (Seed_mir.Use (copy 1)) ];
          terminator = Seed_mir.Ret };
      |]
      0
  in
  (match mono_of (mk_prog [| main1; g |] [||]) with
   | Error errs ->
       let hit =
         List.exists
           (fun e -> contains e "monomorphization internal error: template arity 2 != instance arity 1 for callable 2")
           errs
       in
       if hit then
         pass "arity mismatch: template f[T,U] with a 1-argument instance fails with the exact-arity internal error"
       else
         fail "arity mismatch: wrong errors: %s" (String.concat "; " errs)
   | Ok _ -> fail "arity mismatch: template f[T,U] with a 1-argument instance was NOT rejected");
  (* extra argument: template f[T] (1 param) called with a 2-argument instance *)
  let f = identity_template "f" 1 in
  let main2 =
    mk_fn "main" (inst 0 [||]) [||] [| i64; i64 |]
      [|
        { Seed_mir.id = 0;
          statements = [];
          terminator =
            call 1 (Seed_mir.User (inst 1 [| i64; i64 |])) [| call_arg (int_op 1); call_arg (int_op 2) |] 1 };
        { Seed_mir.id = 1;
          statements = [ assign 0 (Seed_mir.Use (copy 1)) ];
          terminator = Seed_mir.Ret };
      |]
      0
  in
  (match mono_of (mk_prog [| main2; f |] [||]) with
   | Error errs ->
       let hit =
         List.exists
           (fun e -> contains e "monomorphization internal error: template arity 1 != instance arity 2 for callable 1")
           errs
       in
       if hit then
         pass "arity mismatch: template f[T] with a 2-argument instance fails with the exact-arity internal error"
       else
         fail "arity mismatch (extra arg): wrong errors: %s" (String.concat "; " errs)
   | Ok _ -> fail "arity mismatch: template f[T] with a 2-argument instance was NOT rejected")

(* ── (d) generic calls from generic callers (chaining) ────────────── *)

let check_generic_callers () =
  let inner = identity_template "inner" 3 in
  let mid =
    mk_fn "mid" (inst 2 [| tparam 0 |]) [| tparam 0 |] [| tparam 0; tparam 0; tparam 0 |]
      [|
        { Seed_mir.id = 0;
          statements = [];
          terminator =
            call 2 (Seed_mir.User (inst 3 [| tparam 0 |])) [| call_arg (move_ 1) |] 1 };
        { Seed_mir.id = 1;
          statements = [ assign 0 (Seed_mir.Use (move_ 2)) ];
          terminator = Seed_mir.Ret };
      |]
      0
  in
  let outer =
    mk_fn "outer" (inst 1 [| tparam 0 |]) [| tparam 0 |] [| tparam 0; tparam 0; tparam 0 |]
      [|
        { Seed_mir.id = 0;
          statements = [];
          terminator =
            call 2 (Seed_mir.User (inst 2 [| tparam 0 |])) [| call_arg (move_ 1) |] 1 };
        { Seed_mir.id = 1;
          statements = [ assign 0 (Seed_mir.Use (move_ 2)) ];
          terminator = Seed_mir.Ret };
      |]
      0
  in
  let main =
    mk_fn "main" (inst 0 [||]) [||] [| i64; i64; i64; string_ty; string_ty |]
      [|
        { Seed_mir.id = 0;
          statements = [];
          terminator =
            call 1 (Seed_mir.User (inst 1 [| i64 |])) [| call_arg (int_op 42) |] 1 };
        { Seed_mir.id = 1;
          statements = [];
          terminator =
            call 3 (Seed_mir.User (inst 1 [| string_ty |])) [| call_arg (str_op "hi") |] 2 };
        { Seed_mir.id = 2;
          statements = [ assign 0 (Seed_mir.Use (copy 1)) ];
          terminator = Seed_mir.Ret };
      |]
      0
  in
  (match mono_of (mk_prog [| main; outer; mid; inner |] [||]) with
   | Error errs ->
       fail "generic callers: mono build failed: %s" (String.concat "; " errs)
   | Ok mono_prog ->
       let n = Array.length mono_prog.Seed_mir.functions in
       let names = List.map (fun f -> f.Seed_mir.name) (Array.to_list mono_prog.Seed_mir.functions) in
       let c1 = List.length (find_by_callable mono_prog 1) in
       let c2 = List.length (find_by_callable mono_prog 2) in
       let c3 = List.length (find_by_callable mono_prog 3) in
       if n <> 7 then
         fail "generic callers: expected 7 functions (main + outer/mid/inner x Int/String), got %d (%s)"
           n (String.concat "," names)
       else if c1 <> 2 || c2 <> 2 || c3 <> 2 then
         fail "generic callers: outer=%d mid=%d inner=%d (expected 2 each)" c1 c2 c3
       else if not (List.for_all fn_is_concrete (Array.to_list mono_prog.Seed_mir.functions)) then
         fail "generic callers: a specialized body still carries a Type_param"
       else
         (* the chained instances must carry the SUBSTITUTED arguments:
            inner[Int] with a concrete Int param, inner[String] with a
            concrete String param — the caller's Type_param was applied
            to the callee instance args before memoization *)
         let inner_ints = find_by_callable mono_prog 3 in
         let has_int =
           List.exists (fun f ->
               Instance_id.type_args f.Seed_mir.instance = [| i64 |]
               && f.Seed_mir.params.(0).Type_repr.pt_type = i64)
             inner_ints
         in
         let has_str =
           List.exists (fun f ->
               Instance_id.type_args f.Seed_mir.instance = [| string_ty |]
               && f.Seed_mir.params.(0).Type_repr.pt_type = string_ty)
             inner_ints
         in
         (match Mir_verify.require_valid mono_prog with
          | Error errs ->
              fail "generic callers: mono output fails Mir_verify: %s" (String.concat "; " errs)
          | Ok () ->
              if has_int && has_str then
                pass "generic callers: outer[T] -> mid[T] -> inner[T] chains (outer[Int] -> mid[Int] -> inner[Int], outer[String] -> mid[String] -> inner[String]); all bodies concrete and verified"
              else
                fail "generic callers: chained inner instances do not carry the substituted args"))

(* ── (e) nested generic type arguments ────────────────────────────── *)

let check_nested_generics () =
  let vec_ty (t : Type_repr.t) : Type_repr.t = Type_repr.Named (Ids.Type_id.make 7, [| t |]) in
  let inner = identity_template "inner" 3 in
  let outer =
    mk_fn "outer" (inst 1 [| tparam 0 |]) [| vec_ty (tparam 0) |]
      [| vec_ty (tparam 0); vec_ty (tparam 0); vec_ty (tparam 0) |]
      [|
        { Seed_mir.id = 0;
          statements = [];
          terminator =
            call 2 (Seed_mir.User (inst 3 [| vec_ty (tparam 0) |])) [| call_arg (move_ 1) |] 1 };
        { Seed_mir.id = 1;
          statements = [ assign 0 (Seed_mir.Use (copy 2)) ];
          terminator = Seed_mir.Ret };
      |]
      0
  in
  let main =
    mk_fn "main" (inst 0 [||]) [||] [| i64; i64 |]
      [|
        { Seed_mir.id = 0;
          statements = [];
          terminator =
            call 1 (Seed_mir.User (inst 1 [| i64 |])) [| call_arg (int_op 1) |] 1 };
        { Seed_mir.id = 1;
          statements = [ assign 0 (Seed_mir.Use (copy 1)) ];
          terminator = Seed_mir.Ret };
      |]
      0
  in
  (match mono_of (mk_prog [| main; outer; inner |] [|
    Seed_mir.StructDef
      {
        sd_id = Ids.Type_id.make 7;
        sd_fields =
          [ { Seed_mir.fd_id = Ids.Field_id.make 0; fd_index = Ids.Field_index.make 0; fd_ty = i64 } ];
      }
  |]) with
   | Error errs ->
       fail "nested generics: mono build failed: %s" (String.concat "; " errs)
   | Ok mono_prog ->
       let outer_fns = find_by_callable mono_prog 1 in
       let inner_fns = find_by_callable mono_prog 3 in
       let outer_ok =
         List.exists (fun f ->
             Instance_id.type_args f.Seed_mir.instance = [| i64 |]
             && f.Seed_mir.params.(0).Type_repr.pt_type = vec_ty i64)
           outer_fns
       in
       let inner_ok =
         List.exists (fun f ->
             Instance_id.type_args f.Seed_mir.instance = [| vec_ty i64 |]
             && f.Seed_mir.params.(0).Type_repr.pt_type = vec_ty i64)
           inner_fns
       in
       let all_concrete = List.for_all fn_is_concrete (Array.to_list mono_prog.Seed_mir.functions) in
       if not all_concrete then
         fail "nested generics: a specialized body still carries a Type_param"
       else if outer_ok && inner_ok then
         pass "nested generics: outer[Int] param is Vec[Int] and inner is instantiated at Vec[Int] (substitution recurses through Named type args)"
       else
         fail "nested generics: expected outer[Int] with param Vec[Int] and inner[Vec[Int]] with param Vec[Int]")

(* ── (f) post-mono concrete type-instance materialization ───────────
   The re-audit finding: the mono phase specializes functions only —
   a generic struct Pair[T] { first: T; second: T } instantiated at
   Pair[Int] and Pair[String] has no real post-mono StructDef
   specialization mechanism.  This check runs the FULL post-mono
   assembly: Mono.build with the generic registry (the monomorphizer
   queues the concrete instances alongside the function instances),
   then Driver.materialize_type_instances (the driver's post-mono type
   materialization).  It asserts:
     - the queue carries (pair_tid, [Int]) and (pair_tid, [String])
       exactly once each, in discovery order;
     - the final types table carries BOTH concrete StructDefs — fields
       substituted Int,Int and String,String — with the semantic
       FieldIds (and declaration-order indices) preserved from the
       original def, under DISTINCT fresh TypeIds (never the generic
       tid);
     - every Named mention is rewritten to the fresh identity (the
       specialized f's signature/body and main's call instances);
     - the final program passes Mir_verify and executes under the Seed
       VM. *)

let type_eq (a : Type_repr.t) (b : Type_repr.t) : bool = Type_repr.compare a b = 0

(* Mono + the driver's post-mono type materialization, mirroring
   run_mono_phase: returns the final program and the queued instances. *)
let mono_with_types ~(generic_types : Mono.generic_def array)
    (prog : Seed_mir.program) : (Seed_mir.program * Mono.type_instance list, string list) result =
  let entry = prog.Seed_mir.functions.(0).Seed_mir.instance in
  let collected = ref [] in
  match
    Mono.build ~entry ~generic_types
      ~on_type_instance:(fun ti -> collected := ti :: !collected)
      prog
  with
  | Error errs -> Error errs
  | Ok fns ->
      let mono_prog = { prog with Seed_mir.functions = fns } in
      let queued = List.rev !collected in
      (match
         Driver.materialize_type_instances ~generic_types ~type_instances:queued mono_prog
       with
       | Error errs -> Error errs
       | Ok (final_prog, _) -> Ok (final_prog, queued))

let check_type_instances () =
  let pair_tid = Ids.Type_id.make 8 in
  let fid_first = Ids.Field_id.make 21 and fid_second = Ids.Field_id.make 22 in
  let pair_ty (t : Type_repr.t) : Type_repr.t = Type_repr.Named (pair_tid, [| t |]) in
  (* the generic template def: fields carry the declared Type_param; the
     semantic FieldIds belong to the ORIGINAL def and must survive the
     materialization *)
  let pair_def =
    Seed_mir.StructDef
      {
        sd_id = pair_tid;
        sd_fields =
          [ { Seed_mir.fd_id = fid_first; fd_index = Ids.Field_index.make 0; fd_ty = tparam 0 };
            { Seed_mir.fd_id = fid_second; fd_index = Ids.Field_index.make 1; fd_ty = tparam 0 } ];
      }
  in
  let generic_types =
    [|
      { Mono.gd_tid = pair_tid;
        gd_params = [| Ids.Generic_param_id.make 0 |];
        gd_def = pair_def };
    |]
  in
  (* f[T] -> T: identity over a Pair[T].  main CALLS f with the concrete
     instances — the callee instances are f[Pair[Int]] and
     f[Pair[String]] ("the calls with the concrete instances"), so the
     specialized signatures AND bodies mention Pair[Int]/Pair[String]. *)
  let f = identity_template "f" 1 in
  let main =
    mk_fn "main" (inst 0 [||]) [||]
      [| Type_repr.Unit;
         pair_ty i64;
         pair_ty i64;
         pair_ty string_ty;
         pair_ty string_ty;
         bool_ty |]
      [|
        { Seed_mir.id = 0;
          statements =
            [ assign 1
                (Seed_mir.Aggregate
                   ( Seed_mir.StructCtor (pair_tid, [| Ids.Field_index.make 0; Ids.Field_index.make 1 |]),
                     [ int_op 1; int_op 2 ] )) ];
          terminator =
            call 2 (Seed_mir.User (inst 1 [| pair_ty i64 |])) [| call_arg (move_ 1) |] 1 };
        { Seed_mir.id = 1;
          statements =
            [ assign 3
                (Seed_mir.Aggregate
                   ( Seed_mir.StructCtor (pair_tid, [| Ids.Field_index.make 0; Ids.Field_index.make 1 |]),
                     [ str_op "a"; str_op "b" ] )) ];
          terminator =
            call 4 (Seed_mir.User (inst 1 [| pair_ty string_ty |])) [| call_arg (move_ 3) |] 2 };
        { Seed_mir.id = 2;
          statements =
            [ assign 5
                (Seed_mir.BinaryOp
                   ( Seed_mir.Eq,
                     Seed_mir.Copy { root = Seed_mir.Local 2; projections = [ Seed_mir.Field fid_first ] },
                     int_op 1 )) ];
          terminator = Seed_mir.Assert (copy 5, true, "Pair[Int].first != 1", 3) };
        { Seed_mir.id = 3;
          statements = [ assign 0 (Seed_mir.Use (Seed_mir.Constant Seed_mir.Unit)) ];
          terminator = Seed_mir.Ret };
      |]
      0
  in
  (match mono_with_types ~generic_types (mk_prog [| main; f |] [||]) with
   | Error errs ->
       fail "type instances: mono/materialize failed: %s" (String.concat "; " errs)
   | Ok (final_prog, queued) ->
       (* ── 1. the queue: (pair_tid, [Int]) then (pair_tid, [String]),
             exactly once each *)
       let queued_tids =
         List.map (fun (ti : Mono.type_instance) -> Ids.Type_id.to_int ti.Mono.ti_tid) queued
       in
       let queued_args =
         List.map
           (fun (ti : Mono.type_instance) ->
             if Array.length ti.Mono.ti_args = 1 then ti.Mono.ti_args.(0) else Type_repr.Unit)
           queued
       in
       let has_int = List.exists (fun t -> type_eq t i64) queued_args in
       let has_str = List.exists (fun t -> type_eq t string_ty) queued_args in
       if queued_tids <> [ 8; 8 ] || not (has_int && has_str) || List.length queued <> 2 then
         fail "type instances: queue = [%s] (expected type#8[Int], type#8[String] exactly once)"
           (String.concat ", "
              (List.map
                 (fun (ti : Mono.type_instance) ->
                   Seed_mir.print_type
                     (if Array.length ti.Mono.ti_args = 1 then ti.Mono.ti_args.(0)
                      else Type_repr.Unit))
                 queued))
       else
         (* ── 2. the materialized defs *)
         let field_tys (d : Seed_mir.type_def) : Type_repr.t list option =
           match d with
           | Seed_mir.StructDef { sd_fields; _ } -> Some (List.map (fun f -> f.Seed_mir.fd_ty) sd_fields)
           | _ -> None
         in
         let field_ids (d : Seed_mir.type_def) : Ids.Field_id.t list option =
           match d with
           | Seed_mir.StructDef { sd_fields; _ } -> Some (List.map (fun f -> f.Seed_mir.fd_id) sd_fields)
           | _ -> None
         in
         let field_indices (d : Seed_mir.type_def) : int list option =
           match d with
           | Seed_mir.StructDef { sd_fields; _ } ->
               Some (List.map (fun f -> Ids.Field_index.to_int f.Seed_mir.fd_index) sd_fields)
           | _ -> None
         in
         let defs = Array.to_list final_prog.Seed_mir.types in
         let def_int =
           List.find_opt
             (fun d ->
               match field_tys d with
               | Some [ a; b ] -> type_eq a i64 && type_eq b i64
               | _ -> false)
             defs
         in
         let def_str =
           List.find_opt
             (fun d ->
               match field_tys d with
               | Some [ a; b ] -> type_eq a string_ty && type_eq b string_ty
               | _ -> false)
             defs
         in
         let n_defs = List.length defs in
         let generic_gone =
           not
             (List.exists
                (fun d ->
                  match d with
                  | Seed_mir.StructDef { sd_id; _ } -> Ids.Type_id.compare sd_id pair_tid = 0
                  | _ -> false)
                defs)
         in
         let def_int_id, def_str_id =
           match def_int, def_str with
           | Some (Seed_mir.StructDef { sd_id = a; _ }), Some (Seed_mir.StructDef { sd_id = b; _ })
             ->
               (a, b)
           | _ -> (Ids.Type_id.make 0, Ids.Type_id.make 0)
         in
         let ids_ok =
           match def_int, def_str with
           | Some di, Some ds ->
               List.length defs = 2
               && field_ids di = Some [ fid_first; fid_second ]
               && field_ids ds = Some [ fid_first; fid_second ]
               && field_indices di = Some [ 0; 1 ]
               && field_indices ds = Some [ 0; 1 ]
               && Ids.Type_id.compare def_int_id def_str_id <> 0
               && generic_gone
           | _ -> false
         in
         if n_defs <> 2 || not ids_ok then begin
           fail "type instances: expected 2 concrete StructDefs (Pair[Int]: Int,Int / Pair[String]: String,String with FieldIds %d,%d indices 0,1 under distinct fresh TypeIds, generic type#%d absent); got %d def(s): %s"
             (Ids.Field_id.to_int fid_first) (Ids.Field_id.to_int fid_second)
             (Ids.Type_id.to_int pair_tid) n_defs
             (String.concat " | "
                (List.map
                   (fun d ->
                     match d with
                   | Seed_mir.StructDef { sd_id; sd_fields } ->
                       Printf.sprintf "struct type#%d { %s }" (Ids.Type_id.to_int sd_id)
                         (String.concat "; "
                            (List.map
                               (fun f ->
                                 Printf.sprintf "%d: %s" (Ids.Field_id.to_int f.Seed_mir.fd_id)
                                   (Seed_mir.print_type f.Seed_mir.fd_ty))
                               sd_fields))
                   | Seed_mir.EnumDef { ed_id; _ } ->
                       Printf.sprintf "enum type#%d" (Ids.Type_id.to_int ed_id))
                   defs))
         end
         else
           (* ── 3. the rewrite: the specialized f's signature/body and
                 main's call instances reference the fresh TypeIds *)
           let f_instances =
             Array.to_list final_prog.Seed_mir.functions
             |> List.filter (fun fn ->
                    Ids.Callable_id.to_int (Instance_id.callable fn.Seed_mir.instance) = 1)
           in
           let f_ok =
             List.length f_instances = 2
             && List.exists
                  (fun fn ->
                    let args = Instance_id.type_args fn.Seed_mir.instance in
                    Array.length args = 1
                    && (match args.(0) with
                       | Type_repr.Named (tid, a) ->
                           Ids.Type_id.compare tid def_int_id = 0
                           && Array.length a = 1 && type_eq a.(0) i64
                       | _ -> false)
                    && (match fn.Seed_mir.params.(0).Type_repr.pt_type with
                       | Type_repr.Named (tid, a) ->
                           Ids.Type_id.compare tid def_int_id = 0
                           && Array.length a = 1 && type_eq a.(0) i64
                       | _ -> false))
                  f_instances
             && List.exists
                  (fun fn ->
                    let args = Instance_id.type_args fn.Seed_mir.instance in
                    Array.length args = 1
                    && (match args.(0) with
                       | Type_repr.Named (tid, a) ->
                           Ids.Type_id.compare tid def_str_id = 0
                           && Array.length a = 1 && type_eq a.(0) string_ty
                       | _ -> false)
                    && (match fn.Seed_mir.params.(0).Type_repr.pt_type with
                       | Type_repr.Named (tid, a) ->
                           Ids.Type_id.compare tid def_str_id = 0
                           && Array.length a = 1 && type_eq a.(0) string_ty
                       | _ -> false))
                  f_instances
           in
           let call_instances =
             Array.to_list final_prog.Seed_mir.functions.(0).Seed_mir.blocks
             |> List.concat_map (fun b ->
                    match b.Seed_mir.terminator with
                    | Seed_mir.Call (_, Seed_mir.User i, _, _, _) -> [ i ]
                    | _ -> [])
           in
           let calls_ok =
             List.length call_instances = 2
             && List.exists
                  (fun inst ->
                    let args = Instance_id.type_args inst in
                    Array.length args = 1
                    && (match args.(0) with
                       | Type_repr.Named (tid, a) ->
                           Ids.Type_id.compare tid def_int_id = 0
                           && Array.length a = 1 && type_eq a.(0) i64
                       | _ -> false))
                  call_instances
             && List.exists
                  (fun inst ->
                    let args = Instance_id.type_args inst in
                    Array.length args = 1
                    && (match args.(0) with
                       | Type_repr.Named (tid, a) ->
                           Ids.Type_id.compare tid def_str_id = 0
                           && Array.length a = 1 && type_eq a.(0) string_ty
                       | _ -> false))
                  call_instances
           in
           if not (f_ok && calls_ok) then
             fail "type instances: the fresh TypeId rewrite missed a mention (specialized signatures/bodies or main's call instances)"
           else
             (* ── 4/5. the final program verifies and executes *)
             (match Mir_verify.require_valid final_prog with
              | Error errs ->
                  fail "type instances: final program fails Mir_verify: %s"
                    (String.concat "; " errs)
              | Ok () -> (
                  match
                    Vm.entry_frame_of ~program:final_prog
                      ~entry:(final_prog.Seed_mir.functions.(0).Seed_mir.instance)
                      ~argv:[||]
                  with
                  | Error m -> fail "type instances: entry_frame_of: %s" m
                  | Ok (vm, frame) -> (
                      match Vm.run_inspect vm frame with
                      | Ok "()" ->
                          pass
                            "type instances: Pair[Int] and Pair[String] queued, materialized as concrete StructDefs (Int,Int / String,String) with the semantic FieldIds preserved, fresh TypeIds per instance, all Named mentions rewritten; verifies and executes"
                      | Ok other ->
                          fail "type instances: unexpected VM return %s" other
                      | Error m -> fail "type instances: vm: %s" m))))

let () =
  Printf.printf "Monomorphizer exact-arity and specialization self-check\n";
  check_two_instantiations ();
  check_duplicate_specialization ();
  check_arity_mismatch ();
  check_generic_callers ();
  check_nested_generics ();
  check_type_instances ();
  if !failures = 0 then begin
    Printf.printf "ALL MONO PASS\n";
    exit 0
  end
  else begin
    Printf.printf "%d FAILURE(S)\n" !failures;
    exit 1
  end
