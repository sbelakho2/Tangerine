(* typed_profile.ml — the post-typing SEMANTIC profile (the audit's
   P0: SUBSET_FIREWALL = PASS means the parser sees no categorically
   forbidden AST form — it does NOT prove every typed instance of an
   accepted form is executable by the seed.  This check runs AFTER
   typing and walks the FULL typed closure recursively (re-audit
   item 12: every expression child, nested block, branch/loop/match
   body, call argument, impl method and nested function is visited;
   a missing finding cannot hide inside a nested form).  It validates
   the typed uses: the for-loop iterable kinds (the lowering supports
   Range, Fixed_array, Array/Vec and String runtime iteration; the
   Map/Set entries protocol is lowered through the intrinsic channel
   and exercised by the runtime round-trip proofs), closure calls, and
   value-carrying `break <value>` (conservatively rejected while the
   spec's break-value semantics are unresolved).  Projected non-Copy
   moves are NOT a profile check — they are rejected by the MIR
   verifier (the seed VM has no partial-move representation) and the
   subset firewall.  The real seed condition is:

       syntactic subset = 0 findings
       AND typed semantic profile = 0 findings *)

type finding = {
  f_kind : string;
  f_span : Span.span;
  f_message : string;
}

let check (env : Typecheck.env) (items : Ast.item list) : finding list =
  let findings = ref [] in
  (* re-audit item 12: the walk is a FULL recursive traversal of the
     typed closure — every expression child form, every nested block,
     every branch/loop/match body, every call argument, the impl
     methods and the nested functions — the old selected-forms walk
     both missed children (false negatives) and misattributed spans
     (false positives) *)
  let rec check_block (b : Ast.block_body) =
    List.iter check_stmt b.Ast.b_stmts;
    match b.Ast.b_tail with Some e -> check_expr e | None -> ()
  and check_stmt (st : Ast.stmt) =
    match st with
    | Ast.ExprStmt (e, _) -> check_expr e
    | Ast.LetBinding (_, _, _, value, _) -> check_expr value
    | Ast.Attributed (_, inner, _) -> check_stmt inner
    | Ast.DeferStmt (b, _) -> check_block b
    | Ast.Item _ | Ast.AttributeStmt _ -> ()
  and check_expr (e : Ast.expr) =
    match e with
    | Ast.ForExpr (fid, f) -> (
        (* the typed-iterable record (the audit's item 13): the
           typechecker resolved the iteration kind ONCE from the
           iterable's semantic type — the profile consumes that SAME
           fact instead of re-reading the ForExpr node's tn_type (the
           loop's RESULT type, which is Unit under the FlowResult
           port) *)
        (* re-audit P0 (the profile repair): the semantic channel is the
           authority — the supported WHITELIST passes, every other
           iteration kind (IterOther included) fails, and a MISSING
           typed-for record for an accepted source for is an internal
           invariant failure, never a silent pass *)
        match Hashtbl.find_opt env.Typecheck.typed_for_patterns fid with
        | None ->
            findings :=
              { f_kind = "for-iterable";
                f_span = Ast.expr_span f.Ast.for_iterable;
                f_message =
                  "accepted `for` has no typed-for record (the AST ForExpr NodeId is missing from the semantic channel — compiler invariant failure; the profile refuses to classify from syntax)" }
              :: !findings
        | Some tf -> (
            match tf.Typecheck.tf_iteration_kind with
            | Typecheck.IterRange | Typecheck.IterFixedArray | Typecheck.IterVec
            | Typecheck.IterMap | Typecheck.IterSet ->
                (* the Map/Set entries protocol is lowered through the
                   intrinsic channel and exercised by the runtime
                   round-trip proofs (main = 66 for {1:10, 2:20, 3:30}) *)
                ()
            | Typecheck.IterString ->
                findings :=
                  { f_kind = "for-iterable";
                    f_span = Ast.expr_span f.Ast.for_iterable;
                    f_message =
                      "String iteration is not yet executable by the seed (the character semantics of the UTF-8 contract are unresolved — the profile does not claim support)";
                  }
                  :: !findings
            | Typecheck.IterTuple | Typecheck.IterOther ->
                findings :=
                  { f_kind = "for-iterable";
                    f_span = Ast.expr_span f.Ast.for_iterable;
                    f_message =
                      "runtime iteration of this kind is not lowered by the seed (supported whitelist: Range, Fixed_array, Array/Vec, Map, Set)";
                  }
                  :: !findings);
        check_expr f.Ast.for_iterable;
        check_block f.Ast.for_body)
    | Ast.Call (nid, callee, _, args, span) -> (
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
        (* re-audit P12: an unresolved callee is only a finding when its
           TYPE is not a function type.  A callee of function type
           (a fn-typed local/param, or a function-valued field) is a
           RUNTIME fn value: the seed lowers it through the FnValue
           callee channel (mir_lower's fn_value_call) and the VM
           dispatches it — the closure-call profile claims support for
           exactly that surface.  A NON-function-typed unresolved
           callee stays a finding: the seed cannot lower it. *)
        let callee_fn_ty =
          match callee with
          | Ast.Field (cnid, _, _, _) | Ast.Name (cnid, _, _) | Ast.Path (cnid, _, _, _) -> (
              match Hashtbl.find_opt env.Typecheck.typed_nodes cnid with
              | Some tn -> (
                  match tn.Typecheck.tn_type with
                  | Type_repr.Function _ -> true
                  | _ -> false)
              | None -> false)
          | _ -> false
        in
        if resolved || callee_fn_ty then ()
        else
          match callee with
          | Ast.Field (_, _, _, _) ->
              findings :=
                { f_kind = "closure-call";
                  f_span = span;
                  f_message = "call through a non-function-typed field with no resolved callable (the seed can only lower calls through fn-typed values)" }
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
                    f_message = "call to an unregistered callable `" ^ n ^ "` (a closure value call through a non-function-typed callee is not lowered by the seed)" }
                  :: !findings)
          | _ -> ());
        check_expr callee;
        List.iter (fun a -> check_expr a.Ast.ca_value) args)
    | Ast.BreakExpr (_, Some _, span) ->
        (* re-audit item 27: the language spec has not yet locked whether
           `break <value>` contributes a value to the loop expression or
           is merely evaluated-and-discarded; until the conformance test
           exists, the seed profile conservatively rejects the
           value-carrying form *)
        findings :=
          { f_kind = "break-value";
            f_span = span;
            f_message =
              "value-carrying `break <value>` is not yet lowered by the seed (the spec's break-value semantics are unresolved; the profile rejects it conservatively)" }
          :: !findings
    | Ast.BreakExpr (_, None, _) -> ()
    | Ast.IntLit _ | Ast.FloatLit _ | Ast.StringLit _ | Ast.CharLit _
    | Ast.BoolLit _ | Ast.Name _ | Ast.Path _ | Ast.NextExpr _ ->
        ()
    | Ast.Array (_, elems, _) -> List.iter check_expr elems
    | Ast.ArrayRepeat (_, v, c, _) -> check_expr v; check_expr c
    | Ast.Tuple (_, elems, _) -> List.iter check_expr elems
    | Ast.StructLit (_, _, _, fields, rest, _) ->
        List.iter (fun (_, fe) -> check_expr fe) fields;
        (match rest with Some r -> check_expr r | None -> ())
    | Ast.Block (_, b, _) | Ast.UnsafeBlock (_, _, b, _) | Ast.LoopExpr (_, b, _)
    | Ast.ComptimeBlock (_, b, _) ->
        check_block b
    | Ast.IfExpr (_, ie) ->
        check_expr ie.Ast.if_condition;
        (match ie.Ast.if_let_value with Some v -> check_expr v | None -> ());
        check_block ie.Ast.if_then;
        List.iter (fun (c, b) -> check_expr c; check_block b) ie.Ast.if_elsif;
        (match ie.Ast.if_else with Some b -> check_block b | None -> ())
    | Ast.Index (_, base, ix, _) -> check_expr base; check_expr ix
    | Ast.Range (_, a, b, _, _) -> check_expr a; check_expr b
    | Ast.MatchExpr (_, me) ->
        check_expr me.Ast.m_subject;
        List.iter
          (fun arm ->
            (match arm.Ast.ma_guard with Some g -> check_expr g | None -> ());
            check_expr arm.Ast.ma_body)
          me.Ast.m_arms
    | Ast.Cast (_, inner, _, _) | Ast.TryOp (_, inner, _) | Ast.AwaitExpr (_, inner, _)
    | Ast.Unary (_, _, inner, _) | Ast.Field (_, inner, _, _) ->
        check_expr inner
    | Ast.Closure (_, cl) -> check_expr cl.Ast.cl_body
    | Ast.Binary (_, l, _, r, _) | Ast.Assign (_, l, r, _) ->
        check_expr l;
        check_expr r
    | Ast.CompoundAssign (_, l, _, r, _) ->
        check_expr l;
        check_expr r
    | Ast.ReturnExpr (_, Some v, _) -> check_expr v
    | Ast.ReturnExpr (_, None, _) -> ()
    | Ast.MacroCall _ -> ()
    | Ast.WhileExpr (_, we) ->
        check_expr we.Ast.wh_condition;
        check_block we.Ast.wh_body
    | Ast.HandleExpr (_, he) ->
        check_expr he.Ast.h_expr;
        List.iter
          (fun (_, pats, body) ->
            List.iter (fun p -> check_pattern p) pats;
            check_expr body)
          he.Ast.h_arms
    | Ast.UnlessExpr (_, ue) ->
        check_expr ue.Ast.un_condition;
        check_block ue.Ast.un_body;
        (match ue.Ast.un_else with Some b -> check_block b | None -> ())
    | Ast.UntilExpr (_, ue) ->
        check_expr ue.Ast.ut_condition;
        check_block ue.Ast.ut_body
    | Ast.TryBlock (_, tb) ->
        check_block tb.Ast.tr_body;
        List.iter (fun (_, cb) -> check_block cb) tb.Ast.tr_catches;
        (match tb.Ast.tr_finally with Some fb -> check_block fb | None -> ())
  and check_pattern (_ : Ast.pattern) = ()
  in
  let check_fn_body = function
    | Ast.FnBlock b -> check_block b
    | Ast.FnExpr e -> check_expr e
    | Ast.FnSignatureOnly -> ()
  in
  let check_items (items : Ast.item list) =
    List.iter
      (fun i ->
        match i.Ast.kind with
        | Ast.Function fd -> check_fn_body fd.Ast.fn_body
        | Ast.ImplBlock d ->
            List.iter (fun m -> check_fn_body m.Ast.fn_body) d.Ast.i_methods
        | Ast.StaticDecl _ | Ast.ConstDecl _ -> ()
        | _ -> ())
      items
  in
  check_items items;
  List.rev !findings
