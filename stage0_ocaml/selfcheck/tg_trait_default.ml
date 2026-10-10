(* tg_trait_default.ml — audit P0 trait-default typed coverage (seed side:
   the PROVE model).

   The seed checker DOES type-check trait default bodies (check_trait ->
   check_function_body), so the seed lands the invariant by PROOF:
   every expression inside a trait default body must carry the full
   typed-HIR contract (typed_nodes records for calls and their
   arguments, recorded access effects for every call argument) BEFORE
   the access/resource analysis consumes the closure.  This selfcheck
   pins it:

     A. POSITIVE — a trait default body containing a normal typed
        expression, an inout call, a sink (consume) call, a method call
        requiring a resolved receiver effect, and a non-Copy value
        (String) typechecks with 0 errors and
        `Typecheck.verify_typed_channel_completeness` returns None.
     B. EFFECT COVERAGE — the recorded access channel for the trait item
        carries Modify (the inout `&mut self` argument), Consume (the
        sink String argument) and Read (the method receivers) for the
        DEFAULT body — i.e. no effect silently fell back to Read because
        a record was absent (a missing record would leave the Modify/
        Consume classes empty).
     C. NEGATIVE MUTATION — delete one call-argument's typed_nodes entry
        inside the trait default and re-run the verifier: it must fail
        with the exact HIR_MISSING fingerprint naming that NodeId (the
        completeness gate is live for trait defaults too). *)

let failures = ref 0

let check (name : string) (ok : bool) : unit =
  Printf.printf "%s: %s\n" (if ok then "PASS" else "FAIL") name;
  if not ok then incr failures

let contains_sub (haystack : string) (needle : string) : bool =
  let hl = String.length haystack and nl = String.length needle in
  if nl = 0 then true
  else begin
    let found = ref false in
    (try
       for i = 0 to hl - nl do
         if not !found && String.sub haystack i nl = needle then found := true
       done
     with Invalid_argument _ -> ());
    !found
  end

let source =
  "struct TdCtr\n\
  \  n: Int\n\
   end\n\n\
   def td_bump(inout b: TdCtr) -> Unit\n\
  \  b.n = b.n + 1\n\
   end\n\n\
   def td_consume(sink s: String) -> Int\n\
  \  s.len()\n\
   end\n\n\
   trait TdOps\n\
  \  def get_n(self: TdCtr) -> Int\n\
  \  def take(self: TdCtr, sink s: String) -> Int\n\n\
  \  def run(inout self: TdCtr, sink payload: String, extra: Int) -> Int\n\
  \    let name = payload.clone()\n\
  \    let before = self.n\n\
  \    td_bump(&mut self)\n\
  \    let taken = td_consume(name)\n\
  \    let label = extra.to_string()\n\
  \    before + taken + label.len()\n\
  \  end\n\
   end\n\n\
   def main() -> Int\n\
  \  0\n\
   end\n"

(* Parse + resolve + typecheck to the declaration fixpoint (the same
   loop tg_hir_complete uses; the second round lets check_item see the
   trait methods registered by the first round's declaration pass). *)
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

(* The traversal (verbatim from tg_hir_complete.ml). *)
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

let () =
  match check_source source "trait_default.tg" with
  | Error m ->
      Printf.printf "FAIL: trait-default source did not check: %s\n" m;
      incr failures
  | Ok (env, errors, program) ->
      check "A1: trait-default body typechecks with 0 errors" (errors = []);
      if errors <> [] then
        Printf.printf "    errors:\n%s\n" (String.concat "\n    " errors);

      (* A2: typed-channel completeness over the program (trait defaults
         included by the new TraitDef arm of verify_typed_channel_completeness). *)
      (match Typecheck.verify_typed_channel_completeness env program with
       | None -> check "A2: typed-HIR completeness returns None (trait default covered)" true
       | Some fp ->
           Printf.printf "    fingerprint: %s\n" fp;
           check "A2: typed-HIR completeness returns None (trait default covered)" false);

      (* B: the recorded access channel for the trait default carries the
         three effect classes — a missing record would have degraded the
         inout/sink classes to nothing. *)
      let accs =
        List.filter
          (fun (a : Access_check.access) -> contains_sub a.Access_check.a_item "TdOps")
          env.Typecheck.state.Typecheck.oracle.Typecheck.o_accesses
      in
      let effects = List.map (fun (a : Access_check.access) -> a.Access_check.a_effect) accs in
      let count e = List.length (List.filter (fun e' -> e' = e) effects) in
      let n_modify = count Access_effect.Modify in
      let n_consume = count Access_effect.Consume in
      let n_read = count Access_effect.Read in
      Printf.printf
        "    trait-default access records=%d modify=%d consume=%d read=%d\n"
        (List.length effects) n_modify n_consume n_read;
      check "B1: an inout call argument recorded as Modify (no Read fallback)"
        (n_modify >= 1);
      check "B2: a sink call argument recorded as Consume (no Read fallback)"
        (n_consume >= 1);
      check "B3: the method receivers recorded as Read" (n_read >= 1);

      (* C: mutation witness — delete a call-argument typed record inside
         the trait default and require the exact HIR_MISSING fingerprint. *)
      let first_arg_node = ref None in
      List.iter
        (fun (item : Ast.item) ->
          match item.Ast.kind with
          | Ast.TraitDef d ->
              List.iter
                (fun (m : Ast.function_decl) ->
                  let on_expr (e : Ast.expr) =
                    match e with
                    | Ast.Call (_, _, _, a :: _, _) when !first_arg_node = None ->
                        first_arg_node := Some (Ast.expr_node_id a.Ast.ca_value)
                    | _ -> ()
                  in
                  match m.Ast.fn_body with
                  | Ast.FnBlock b -> iter_block on_expr b
                  | Ast.FnExpr e -> iter_expr on_expr e
                  | Ast.FnSignatureOnly -> ())
                d.Ast.t_methods
          | _ -> ())
        program.Ast.items;
      (match !first_arg_node with
       | None -> check "C1: found a call argument in the trait default" false
       | Some nid ->
           check "C1: found a call argument in the trait default" true;
           Hashtbl.remove env.Typecheck.typed_nodes nid;
           (match Typecheck.verify_typed_channel_completeness env program with
            | Some fp ->
                let nid_s = Ids.Node_id.to_int nid |> string_of_int in
                check
                  ("C2: deleted trait-default argument record yields the exact HIR_MISSING fingerprint (node " ^ nid_s ^ ")")
                  (contains_sub fp "HIR_MISSING" && contains_sub fp ("Node=" ^ nid_s))
            | None ->
                check
                  "C2: deleted trait-default argument record yields the exact HIR_MISSING fingerprint"
                  false));

      if !failures = 0 then begin
        Printf.printf "tg_trait_default: ALL PASS\n";
        Selfcheck_sentinel.emit_and_exit "tg_trait_default"
      end
      else begin
        Printf.printf "tg_trait_default: %d FAILURE(S)\n" !failures;
        exit 1
      end
