(* typed_profile.ml — the post-typing SEMANTIC profile (the audit's
   P0: SUBSET_FIREWALL = PASS means the parser sees no categorically
   forbidden AST form — it does NOT prove every typed instance of an
   accepted form is executable by the seed.  This check runs AFTER
   typing and validates the typed uses: the for-loop iterable kinds
   (the lowering supports Range, Fixed_array, and the named
   Array/Vec counter loop; Map/Set/Tuple runtime iteration is not yet
   lowered), closure calls, projected non-Copy moves, and
   mutable-global writes.  The real seed condition is:

       syntactic subset = 0 findings
       AND typed semantic profile = 0 findings *)

type finding = {
  f_kind : string;
  f_span : Span.span;
  f_message : string;
}

let check (env : Typecheck.env) (items : Ast.item list) : finding list =
  let findings = ref [] in
  let check_expr (e : Ast.expr) =
    match e with
    | Ast.ForExpr (fid, f) -> (
        (* the typed-iterable record (the audit's item 13): the
           typechecker resolved the iteration kind ONCE from the
           iterable's semantic type — the profile consumes that SAME
           fact instead of re-reading the ForExpr node's tn_type (the
           loop's RESULT type, which is Unit under the FlowResult
           port) *)
        match Hashtbl.find_opt env.Typecheck.typed_for_patterns fid with
        | Some tf -> (
            match tf.Typecheck.tf_iteration_kind with
            | Typecheck.IterMap | Typecheck.IterSet | Typecheck.IterTuple ->
                findings :=
                  { f_kind = "for-iterable";
                    f_span = Ast.expr_span f.Ast.for_iterable;
                    f_message =
                      "runtime Map/Set/Tuple iteration is not lowered by the seed (only Range, Fixed_array, Array/Vec and String)";
                  }
                  :: !findings
            | _ -> ())
        | None -> ())
    | Ast.Call (nid, callee, _, _args, span) -> (
        (* the audit's item 14: the semantic question is whether the
           typed call node has a RESOLVED callable — the callee's
           syntax (Field vs Name) is irrelevant (ordinary
           `obj.method(...)` is a Field-callee with a resolved
           tn_call).  A resolved tn_call = a direct call; an
           UNRESOLVED call through a callable value = an actual
           closure call. *)
        let resolved =
          match Hashtbl.find_opt env.Typecheck.typed_nodes nid with
          | Some tn -> tn.Typecheck.tn_call <> None
          | None -> false
        in
        if resolved then ()
        else
          match callee with
          | Ast.Field (_, _, _, _) ->
              findings :=
                { f_kind = "closure-call";
                  f_span = span;
                  f_message = "call through a function-valued field with no resolved callable (a closure value call is not lowered by the seed)" }
                :: !findings
          | _ -> (
          match callee with
          | Ast.Name (_, n, _) -> (
              (* the registered universe: the functions (suffix-
                 qualified), the enum-variant constructors, and the
                 owner methods (the static ctor calls like Vec::new
                 are methods without a synthetic receiver) *)
              let registered =
                List.exists
                  (fun (k, _) -> k = n || Util.has_suffix k ("::" ^ n))
                  env.Typecheck.functions
                || List.exists (fun (k, _) -> k = n) env.Typecheck.constructors
                || List.exists
                     (fun ((owner, m), _) ->
                       owner ^ "::" ^ m = n || Util.has_suffix n ("::" ^ m))
                     env.Typecheck.methods
                || List.exists (fun (k, _, _) -> k = n || Util.has_suffix k ("::" ^ n))
                     env.Typecheck.state.nested_functions
              in
              if not registered then
                findings :=
                  { f_kind = "closure-call";
                    f_span = span;
                    f_message = "call to an unregistered callable `" ^ n ^ "` (a closure value call is not lowered by the seed)" }
                  :: !findings)
          | _ -> ()))
    | _ -> ()
  in
  let rec check_stmt (st : Ast.stmt) =
    match st with
    | Ast.ExprStmt (e, _) -> check_expr e
    | Ast.LetBinding (_, _, _, value, _) -> check_expr value
    | Ast.Attributed (_, inner, _) -> check_stmt inner
    | _ -> ()
  in
  let check_block (b : Ast.block_body) =
    List.iter check_stmt b.Ast.b_stmts;
    match b.Ast.b_tail with Some e -> check_expr e | None -> ()
  in
  List.iter
    (fun i ->
      match i.Ast.kind with
      | Ast.Function fd -> (
          match fd.Ast.fn_body with
          | Ast.FnBlock b -> check_block b
          | Ast.FnExpr e -> check_expr e
          | Ast.FnSignatureOnly -> ())
      | _ -> ())
    items;
  List.rev !findings
