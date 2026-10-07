(* tg_hir_complete.ml — the mandatory typed-channel completeness verifier
   on the seed side (plan Step 3+4).

   The kernel's late failure class at ~78e9 steps is a soup of
   `unresolved Type::Error` readiness findings plus
   `argument N has no typed HIR record` assembly errors: the checker
   accepted nodes whose lowering-required typed channel entry is missing
   or still unresolved.  This selfcheck pins the seed's side of the same
   invariant and the reproducer shape directly on the channels:

     A. POSITIVE — a small program (a generic constructor whose type
        parameter is only solvable from a LATER use, mirroring
        `rs_resolve_imports`'s `var keys = Vec::new()` + `.push(..)`)
        typechecks, and `Typecheck.verify_typed_channel_completeness`
        returns None (complete).

     B. THE REPRODUCER — by EXACT NodeId: the constructor call node
        exists; its finalized type and solved substitution are concrete
        (no Infer_var, no Error); every call-argument child has a
        typed_nodes record; the parent call has a typed_nodes record
        with tn_call = Some.  The assertions inspect the channels
        directly, never `errors = 0`.

     C. NEGATIVE MUTATION — after checking, DELETE one call-argument's
        typed_nodes entry from the env and re-run the verifier: it must
        fail with the EXACT HIR_MISSING fingerprint naming that NodeId
        (a verifier that were removed or false-green cannot pass this
        branch). *)

let starts_with (s : string) (prefix : string) : bool =
  String.length s >= String.length prefix
  && String.sub s 0 (String.length prefix) = prefix

(* Parse + resolve + typecheck a single-module program to the finalized
   env the lowering consumes (the same declaration fixpoint the driver
   runs).  Returns the env, the error list, and the parsed program. *)
let check_source (source : string) (file : string) :
    (Typecheck.env * string list * Ast.program, string) result =
  let sm = Span.create () in
  let diags = Diagnostic.create_bag () in
  let src = Source.of_bytes ~name:file ~bytes:source in
  let file_id = Span.add_file sm file src in
  let lx = Lexer.create src.Source.bytes file_id diags in
  let tokens = Lexer.lex lx in
  let program = Parser.parse tokens src.Source.bytes file_id diags [ "user" ] in
  if Diagnostic.has_errors diags then Error ("parse: " ^ Diagnostic.render sm diags)
  else
    let rec fix env n =
      match Typecheck.check_program env program with
      | Error m -> Error m
      | Ok (env', errors) -> if errors = [] || n = 0 then Ok (env', errors, program) else fix env' (n - 1)
    in
    fix (Typecheck.initial_env ()) 6

let fail fmt = Printf.ksprintf (fun m -> Printf.printf "FAIL: %s\n" m; exit 1) fmt

(* ── min traversal: locate the call/argument node ids by syntax -------- *)

let rec iter_expr (f : Ast.expr -> unit) (e : Ast.expr) : unit =
  f e;
  match e with
  | Ast.IntLit _ | Ast.FloatLit _ | Ast.StringLit _ | Ast.CharLit _
  | Ast.BoolLit _ | Ast.Name _ | Ast.Path _ | Ast.NextExpr _ ->
      ()
  | Ast.Array (_, elems, _) | Ast.Tuple (_, elems, _) -> List.iter (iter_expr f) elems
  | Ast.ArrayRepeat (_, v, c, _) ->
      iter_expr f v;
      iter_expr f c
  | Ast.StructLit (_, _, _, fields, rest, _) ->
      List.iter (fun (_, fe) -> iter_expr f fe) fields;
      (match rest with Some r -> iter_expr f r | None -> ())
  | Ast.Block (_, b, _) | Ast.UnsafeBlock (_, _, b, _) | Ast.LoopExpr (_, b, _)
  | Ast.ComptimeBlock (_, b, _) ->
      iter_block f b
  | Ast.IfExpr (_, ie) ->
      iter_expr f ie.Ast.if_condition;
      (match ie.Ast.if_let_value with Some v -> iter_expr f v | None -> ());
      iter_block f ie.Ast.if_then;
      List.iter (fun (c, b) -> iter_expr f c; iter_block f b) ie.Ast.if_elsif;
      (match ie.Ast.if_else with Some b -> iter_block f b | None -> ())
  | Ast.Call (_, callee, _, args, _) ->
      iter_expr f callee;
      List.iter (fun a -> iter_expr f a.Ast.ca_value) args
  | Ast.Index (_, base, ix, _) ->
      iter_expr f base;
      iter_expr f ix
  | Ast.Range (_, a, b, _, _) ->
      iter_expr f a;
      iter_expr f b
  | Ast.MatchExpr (_, me) ->
      iter_expr f me.Ast.m_subject;
      List.iter (fun arm -> (match arm.Ast.ma_guard with Some g -> iter_expr f g | None -> ()); iter_expr f arm.Ast.ma_body) me.Ast.m_arms
  | Ast.Cast (_, inner, _, _) | Ast.TryOp (_, inner, _) | Ast.AwaitExpr (_, inner, _)
  | Ast.Unary (_, _, inner, _) | Ast.Field (_, inner, _, _) ->
      iter_expr f inner
  | Ast.Closure (_, cl) -> iter_expr f cl.Ast.cl_body
  | Ast.Binary (_, l, _, r, _) | Ast.Assign (_, l, r, _) ->
      iter_expr f l;
      iter_expr f r
  | Ast.CompoundAssign (_, l, _, r, _) ->
      iter_expr f l;
      iter_expr f r
  | Ast.ReturnExpr (_, v, _) | Ast.BreakExpr (_, v, _) -> (
      match v with Some v -> iter_expr f v | None -> ())
  | Ast.MacroCall _ -> ()
  | Ast.WhileExpr (_, we) ->
      iter_expr f we.Ast.wh_condition;
      iter_block f we.Ast.wh_body
  | Ast.ForExpr (_, fe) ->
      iter_expr f fe.Ast.for_iterable;
      iter_block f fe.Ast.for_body
  | Ast.HandleExpr (_, he) ->
      iter_expr f he.Ast.h_expr;
      List.iter (fun (_, _, body) -> iter_expr f body) he.Ast.h_arms
  | Ast.UnlessExpr (_, ue) ->
      iter_expr f ue.Ast.un_condition;
      iter_block f ue.Ast.un_body;
      (match ue.Ast.un_else with Some b -> iter_block f b | None -> ())
  | Ast.UntilExpr (_, ue) ->
      iter_expr f ue.Ast.ut_condition;
      iter_block f ue.Ast.ut_body
  | Ast.TryBlock (_, tb) ->
      iter_block f tb.Ast.tr_body;
      List.iter (fun (_, b) -> iter_block f b) tb.Ast.tr_catches;
      (match tb.Ast.tr_finally with Some b -> iter_block f b | None -> ())

and iter_stmt (f : Ast.expr -> unit) (st : Ast.stmt) : unit =
  match st with
  | Ast.ExprStmt (e, _) -> iter_expr f e
  | Ast.LetBinding (_, _, _, value, _) -> iter_expr f value
  | Ast.Attributed (_, inner, _) -> iter_stmt f inner
  | Ast.DeferStmt (b, _) -> iter_block f b
  | Ast.Item _ | Ast.AttributeStmt _ -> ()

and iter_block (f : Ast.expr -> unit) (b : Ast.block_body) : unit =
  List.iter (iter_stmt f) b.Ast.b_stmts;
  match b.Ast.b_tail with Some e -> iter_expr f e | None -> ()

let fn_body_of (program : Ast.program) (name : string) : Ast.function_body option =
  List.find_map
    (fun (i : Ast.item) ->
      match i.Ast.kind with
      | Ast.Function fd when fd.Ast.fn_sig.Ast.sig_name = name -> Some fd.Ast.fn_body
      | _ -> None)
    program.Ast.items

let exprs_of_body (body : Ast.function_body) : Ast.expr list =
  let out = ref [] in
  (match body with
  | Ast.FnBlock b -> iter_block (fun e -> out := e :: !out) b
  | Ast.FnExpr e -> iter_expr (fun e -> out := e :: !out) e
  | Ast.FnSignatureOnly -> ());
  List.rev !out

let find_call (name : string) (exprs : Ast.expr list) :
    (Ids.Node_id.t * Ast.call_arg list * Span.span) option =
  List.find_map
    (fun e ->
      match e with
      | Ast.Call (nid, Ast.Name (_, n, _), _, args, sp) when n = name ->
          Some (nid, args, sp)
      | _ -> None)
    exprs

(* The channel predicates (the direct assertions; never errors == 0). *)
let rec ty_concrete (ty : Type_repr.t) : bool =
  match ty with
  | Type_repr.Error | Type_repr.Infer_var _ -> false
  | Type_repr.Raw_ptr (_, t) | Type_repr.Ref_internal (_, t) -> ty_concrete t
  | Type_repr.Tuple ts -> Array.for_all ty_concrete ts
  | Type_repr.Fixed_array (t, _) -> ty_concrete t
  | Type_repr.Named (_, ts) -> Array.for_all ty_concrete ts
  | Type_repr.Function (ps, r) ->
      Array.for_all (fun (p : Type_repr.param_type) -> ty_concrete p.Type_repr.pt_type) ps
      && ty_concrete r
  | Type_repr.Unit | Type_repr.Bool | Type_repr.Char | Type_repr.Int _
  | Type_repr.Float _ | Type_repr.String | Type_repr.Type_param _
  | Type_repr.Int_literal _ | Type_repr.Never ->
      true

let callee_targs_concrete (c : Typecheck.typed_callee) : bool =
  let targs =
    match c with
    | Typecheck.TC_user (_, a) | Typecheck.TC_intrinsic (_, a)
    | Typecheck.TC_extern (_, a) | Typecheck.TC_derived (_, a)
    | Typecheck.TC_type_query (_, a) -> a
  in
  Array.for_all ty_concrete targs

(* The reproducer source: a generic constructor whose type parameter is
   only solved by a LATER use — the `var keys = Vec::new()` + `push(x)`
   shape of `rs_resolve_imports` (the 78B frontier's named site),
   expressed with a program-local generic so the selfcheck needs no std
   prelude (bag_new()/bag_push(keys, i) mirror Vec::new()/keys.push(i)). *)
let repro_src =
  "struct Bag[T]\n\
  \  count: Int = 0\n\
   end\n\n\
   def bag_new[T]() -> Bag[T]\n\
  \  Bag { count: 0 }\n\
   end\n\n\
   def bag_push[T](inout b: Bag[T], v: T) -> Unit\n\
   end\n\n\
   def collect(n: Int) -> Int\n\
  \  var keys = bag_new()\n\
  \  var i = 0\n\
  \  while i < n do\n\
  \    bag_push(keys, i)\n\
  \    i = i + 1\n\
  \  end\n\
  \  keys.count\n\
   end\n\n\
   def main() -> Int\n\
  \  collect(3)\n\
   end\n"

let () =
  (* ── A. POSITIVE: the verifier passes on the accepted shape ──────── *)
  let env, errors, program =
    match check_source repro_src "hir_complete_repro.tg" with
    | Error m -> fail "reproducer program did not check: %s" m
    | Ok v -> v
  in
  if errors <> [] then begin
    Printf.printf "FAIL A: the reproducer program is not accepted (errors=%d)\n"
      (List.length errors);
    List.iter (Printf.printf "    %s\n") errors;
    exit 1
  end;
  (match Typecheck.verify_typed_channel_completeness env program with
  | None -> Printf.printf "PASS A: the verifier passes on the accepted reproducer shape\n"
  | Some fp ->
      fail "the completeness verifier fired on an accepted program: %s" fp);

  (* ── B. REPRODUCER: the channels, by exact NodeId ────────────────── *)
  let body =
    match fn_body_of program "collect" with
    | Some b -> b
    | None -> fail "no `collect` body in the reproducer program"
  in
  let exprs = exprs_of_body body in
  let new_nid, _new_args, _new_sp =
    match find_call "bag_new" exprs with
    | Some v -> v
    | None -> fail "the generic constructor call `bag_new()` node was not found"
  in
  let push_nid, push_args, _push_sp =
    match find_call "bag_push" exprs with
    | Some v -> v
    | None -> fail "the later-use call `bag_push(keys, i)` node was not found"
  in
  (* (1) the constructor call node exists with a concrete finalized type
     and solved substitution. *)
  (match Hashtbl.find_opt env.Typecheck.typed_nodes new_nid with
  | None -> fail "the constructor call node %d has no typed_nodes record" (Ids.Node_id.to_int new_nid)
  | Some tn ->
      if not (ty_concrete tn.Typecheck.tn_type) then
        fail "the constructor call node %d has a non-concrete finalized type %s"
          (Ids.Node_id.to_int new_nid) (Typecheck.type_to_string tn.Typecheck.tn_type);
      (match tn.Typecheck.tn_call with
      | Some c ->
          if not (callee_targs_concrete c) then
            fail "the constructor call node %d has a non-concrete solved substitution"
              (Ids.Node_id.to_int new_nid)
      | None ->
          fail "the constructor call node %d has no resolved callee class (tn_call=None)"
            (Ids.Node_id.to_int new_nid));
      Printf.printf
        "PASS B1: constructor call node %d exists; finalized type + substitution concrete (%s)\n"
        (Ids.Node_id.to_int new_nid) (Typecheck.type_to_string tn.Typecheck.tn_type));
  (* (2) the parent later-use call node has a typed record with tn_call. *)
  (match Hashtbl.find_opt env.Typecheck.typed_nodes push_nid with
  | None -> fail "the parent call node %d has no typed_nodes record" (Ids.Node_id.to_int push_nid)
  | Some tn -> (
      match tn.Typecheck.tn_call with
      | Some _ ->
          Printf.printf "PASS B2: parent call node %d has a typed record with tn_call=Some\n"
            (Ids.Node_id.to_int push_nid)
      | None ->
          fail "the parent call node %d has a typed record but tn_call=None"
            (Ids.Node_id.to_int push_nid)));
  (* (3) every argument child of the parent call has a typed record. *)
  List.iteri
    (fun i (a : Ast.call_arg) ->
      let anid = Ast.expr_node_id a.Ast.ca_value in
      if not (Hashtbl.mem env.Typecheck.typed_nodes anid) then
        fail "parent call argument %d (node %d) has no typed_nodes record" i
          (Ids.Node_id.to_int anid))
    push_args;
  Printf.printf "PASS B3: all %d parent-call argument child node(s) have typed records\n"
    (List.length push_args);

  (* ── C. NEGATIVE MUTATION: delete one argument's typed entry ─────── *)
  let victim =
    match push_args with
    | a :: _ -> a
    | [] -> fail "the parent call has no argument to mutate"
  in
  let victim_nid = Ast.expr_node_id victim.Ast.ca_value in
  let victim_span = Ast.expr_span victim.Ast.ca_value in
  Hashtbl.remove env.Typecheck.typed_nodes victim_nid;
  (match Typecheck.verify_typed_channel_completeness env program with
  | None ->
      fail
        "the completeness verifier PASSED after deleting the typed_nodes entry of argument node %d (false green)"
        (Ids.Node_id.to_int victim_nid)
  | Some fp ->
      let expected =
        Printf.sprintf
          "HIR_MISSING|user|collect|Node=%d|name|no typed channel record for this node (the seed lowering's typed_nodes consumption requires one) at %d:%d"
          (Ids.Node_id.to_int victim_nid) victim_span.Span.file_id
          victim_span.Span.start
      in
      if fp <> expected then
        fail "mutation fingerprint mismatch:\n  expected %s\n  got      %s" expected fp;
      if not (starts_with fp "HIR_MISSING|") then
        fail "mutation fingerprint does not carry the HIR_MISSING prefix: %s" fp;
      Printf.printf
        "PASS C: deleting argument node %d's typed_nodes entry fails with the exact fingerprint %s\n"
        (Ids.Node_id.to_int victim_nid) fp);
  Selfcheck_sentinel.emit_and_exit "tg_hir_complete"
