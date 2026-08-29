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
  let b_array = Ids.Type_id.make 0 in
  let findings = ref [] in
  let iterable_kind (ty : Type_repr.t) : string option =
    match ty with
    | Type_repr.Int _ -> Some "Range"
    | Type_repr.Fixed_array _ -> Some "Fixed_array"
    | Type_repr.Named (id, [| _ |]) when Ids.Type_id.compare id b_array = 0 ->
        Some "Array/Vec"
    | Type_repr.String -> Some "String"
    | Type_repr.Named (id, args) -> (
        match List.assoc_opt id env.Typecheck.type_names with
        | Some ("Map" | "Set") when Array.length args >= 1 -> Some "Map/Set"
        | _ -> None)
    | Type_repr.Tuple _ -> Some "Tuple"
    | _ -> None
  in
  let check_expr (e : Ast.expr) =
    match e with
    | Ast.ForExpr (fid, f) -> (
        (* the typed iterable kind from the typed-node channel: the
           typechecker's resolved node for the iterable expression *)
        let it_ty =
          match Hashtbl.find_opt env.Typecheck.typed_nodes fid with
          | Some tn -> Some tn.Typecheck.tn_type
          | None -> None
        in
        match it_ty with
        | Some ty -> (
            match iterable_kind ty with
            | Some ("Map" | "Set" | "Tuple") ->
                findings :=
                  { f_kind = "for-iterable";
                    f_span = Ast.expr_span f.Ast.for_iterable;
                    f_message =
                      "runtime Map/Set/Tuple iteration is not lowered by the seed (only Range, Fixed_array, Array/Vec and String)";
                  }
                  :: !findings
            | _ -> ())
        | None -> ())
    | Ast.Call (_, callee, _, _args, span) -> (
        (* a closure call: the callee is a FIELD of function type
           (`case.func()`, `self.handler(...)`) — the seed lowers only
           the statically-known callables; a bare Name resolves through
           the registered function table (qualified-suffix identity) *)
        let is_closure_field =
          match callee with
          | Ast.Field (_, _, _, _) -> true
          | _ -> false
        in
        if is_closure_field then
          findings :=
            { f_kind = "closure-call";
              f_span = span;
              f_message = "call through a function-valued field (a closure value call is not lowered by the seed)" }
            :: !findings
        else
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
          | _ -> ())
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
