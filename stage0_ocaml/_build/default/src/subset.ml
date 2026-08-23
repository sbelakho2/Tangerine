(* subset.ml — Bootstrap-subset checker (E9001–E9032).

   Rejects constructs outside the stage0 bootstrap subset with the exact
   reference codes and messages. *)

let rejected_attributes =
  [
    ("bench", "E9021");
    ("inline", "E9022");
    ("derive", "E9023");
    ("allow", "E9024");
    ("deny", "E9024");
    ("deprecated", "E9025");
    ("stable", "E9026");
    ("feature", "E9027");
    ("capability", "E9028");
  ]

let reject (diags : Diagnostic.bag) code msg span =
  Diagnostic.error diags code msg span

let rec check_item diags (i : Ast.item) =
  List.iter
    (fun a ->
      match List.assoc_opt a.Ast.a_name rejected_attributes with
      | Some code ->
          reject diags code
            (Printf.sprintf "@%s attribute is not available in the bootstrap subset" a.Ast.a_name)
            a.Ast.a_span
      | None -> ())
    i.Ast.attributes;
  match i.Ast.kind with
  | Ast.Function d ->
      check_sig diags d.Ast.fn_sig;
      List.iter (check_clause diags) d.Ast.fn_clauses;
      (match d.Ast.fn_body with
       | Ast.FnBlock b -> check_block diags b
       | Ast.FnExpr e -> check_expr diags e
       | Ast.FnSignatureOnly -> ())
  | Ast.TestDecl d -> check_block diags d.Ast.test_body
  | Ast.StructDef d ->
      List.iter (fun f -> check_type diags false f.Ast.f_type) d.Ast.s_fields;
      List.iter (check_function diags) d.Ast.s_methods
  | Ast.EnumDef d ->
      List.iter
        (fun v -> List.iter (fun f -> check_type diags false f.Ast.vf_type) v.Ast.v_fields)
        d.Ast.e_variants
  | Ast.TraitDef d ->
      List.iter (check_function diags) d.Ast.t_methods;
      List.iter (fun a -> check_type diags false a.Ast.ta_value) d.Ast.t_associated_types
  | Ast.ImplBlock d ->
      List.iter (check_function diags) d.Ast.i_methods;
      List.iter
        (fun a -> check_type diags false a.Ast.ta_value)
        d.Ast.i_associated_types;
      List.iter
        (fun c ->
          check_expr diags c.Ast.c_value;
          check_type diags false c.Ast.c_type)
        d.Ast.i_consts
  | Ast.ConstDecl d ->
      check_expr diags d.Ast.c_value;
      check_type diags false d.Ast.c_type
  | Ast.StaticDecl d ->
      check_expr diags d.Ast.st_value;
      check_type diags false d.Ast.st_type
  | Ast.TypeAlias d -> check_type diags false d.Ast.ta_value
  | Ast.ExternBlock d -> List.iter (check_item diags) d.Ast.ex_items
  | Ast.ModuleDef d -> Option.iter (List.iter (check_item diags)) d.Ast.m_items
  | Ast.CapabilityDecl d ->
      reject diags "E9001" "capability declarations are not available in the bootstrap subset"
        d.Ast.cap_span
  | Ast.EffectDecl d ->
      reject diags "E9002" "effect declarations are not available in the bootstrap subset"
        d.Ast.ef_span
  | Ast.RationaleBlock d ->
      reject diags "E9003" "rationale blocks are not available in the bootstrap subset"
        d.Ast.r_span
  | Ast.EditionDecl d ->
      reject diags "E9005" "edition declarations are not available in the bootstrap subset"
        d.Ast.ed_span
  | Ast.MacroDecl d -> check_block diags d.Ast.mac_body
  | Ast.UseDecl _ -> ()

and check_function diags (d : Ast.function_decl) =
  check_sig diags d.Ast.fn_sig;
  List.iter (check_clause diags) d.Ast.fn_clauses;
  match d.Ast.fn_body with
  | Ast.FnBlock b -> check_block diags b
  | Ast.FnExpr e -> check_expr diags e
  | Ast.FnSignatureOnly -> ()

and check_sig diags (sig_ : Ast.function_sig) =
  if sig_.Ast.sig_async then
    reject diags "E9007" "async functions are not available in the bootstrap subset"
      sig_.Ast.sig_span;
  if sig_.Ast.sig_const then
    reject diags "E9021" "const function modifier is not available in the bootstrap subset"
      sig_.Ast.sig_span;
  if sig_.Ast.sig_pure then
    reject diags "E9013" "pure function modifier is not available in the bootstrap subset"
      sig_.Ast.sig_span;
  if sig_.Ast.sig_inline then
    reject diags "E9014" "inline function modifier is not available in the bootstrap subset"
      sig_.Ast.sig_span;
  List.iter
    (fun p ->
      check_type diags true p.Ast.p_type;
      Option.iter (check_expr diags) p.Ast.p_default)
    sig_.Ast.sig_params;
  Option.iter (check_type diags false) sig_.Ast.sig_return

and check_clause diags (c : Ast.function_clause) =
  match c with
  | Ast.Requires r ->
      reject diags "E9008" "requires clauses are not available in the bootstrap subset"
        r.Ast.req_span
  | Ast.Effect e ->
      reject diags "E9009" "effect clauses on functions are not available in the bootstrap subset"
        e.Ast.eff_span
  | Ast.Budget b ->
      reject diags "E9010" "budget clauses are not available in the bootstrap subset"
        b.Ast.bud_span
  | Ast.Contract c ->
      reject diags "E9011" "contract clauses (pre/post/invariant) are not available in the bootstrap subset"
        c.Ast.con_span
  | Ast.GuardClause g ->
      reject diags "E9012" "guard clauses are not available in the bootstrap subset"
        g.Ast.g_span

and check_block diags (b : Ast.block_body) =
  List.iter (check_stmt diags) b.Ast.b_stmts;
  Option.iter (check_expr diags) b.Ast.b_tail

and check_stmt diags (s : Ast.stmt) =
  match s with
  | Ast.LetBinding (p, _, ty, v, _) ->
      check_pattern diags p;
      Option.iter (check_type diags false) ty;
      check_expr diags v
  | Ast.ExprStmt (e, _) -> check_expr diags e
  | Ast.AttributeStmt _ -> ()
  | Ast.Attributed (_, inner, _) -> check_stmt diags inner
  | Ast.DeferStmt (b, _) -> check_block diags b
  | Ast.Item i -> check_item diags i

and check_type diags allows_impl (t : Ast.type_expr) =
  match t with
  | Ast.ConstExpr (e, _) -> check_expr diags e
  | Ast.Ref (inner, _, _) | Ast.RawPtr (inner, _, _) -> check_type diags false inner
  | Ast.FnPtr (params, ret, _) ->
      List.iter (check_type diags true) params;
      check_type diags false ret
  | Ast.TArray (elem, len, _) ->
      check_type diags false elem;
      Option.iter (check_expr diags) len
  | Ast.Slice (inner, _) | Ast.Option (inner, _) -> check_type diags false inner
  | Ast.DynTrait (inner, _) ->
      reject diags "E9032"
        "trait-object types (dyn Trait / impl Trait in type position) are not available in the bootstrap subset"
        (Ast.type_span inner);
      check_type diags false inner
  | Ast.ImplTrait (inner, _) ->
      if not allows_impl then
        reject diags "E9032"
          "trait-object types (dyn Trait / impl Trait in type position) are not available in the bootstrap subset"
          (Ast.type_span inner);
      check_type diags false inner
  | Ast.TTuple (elems, _) -> List.iter (check_type diags false) elems
  | Ast.Named (_, args, _) -> List.iter (check_type diags false) args
  | Ast.AssocBinding (_, v, _) -> check_type diags false v
  | Ast.Bounded (base, bounds, _) ->
      check_type diags false base;
      List.iter (check_type diags false) bounds
  | Ast.Never _ | Ast.Unit _ | Ast.SelfType _ | Ast.Inferred _ -> ()

and check_pattern diags (p : Ast.pattern) =
  match p with
  | Ast.Wildcard _ | Ast.PatIdent _ | Ast.RefPattern _ | Ast.RefMutPattern _ -> ()
  | Ast.PatLiteral (e, _) -> check_expr diags e
  | Ast.PatVariant (_, _, fields, _) -> List.iter (check_pattern diags) fields
  | Ast.StructPattern (_, fields, _) ->
      List.iter (fun (_, opt) -> Option.iter (check_pattern diags) opt) fields
  | Ast.PatTuple (pats, _) -> List.iter (check_pattern diags) pats
  | Ast.OrPattern (a, b, _) ->
      check_pattern diags a;
      check_pattern diags b
  | Ast.RangePattern (a, b, _) ->
      check_pattern diags a;
      check_pattern diags b

and check_expr diags (e : Ast.expr) =
  match e with
  | Ast.AwaitExpr (_, s) ->
      reject diags "E9015" "await expressions are not available in the bootstrap subset" s
  | Ast.HandleExpr h ->
      reject diags "E9016" "handle/with expressions are not available in the bootstrap subset"
        h.Ast.h_span
  | Ast.UnlessExpr u ->
      reject diags "E9017" "unless expressions are not available in the bootstrap subset"
        u.Ast.un_span
  | Ast.UntilExpr u ->
      reject diags "E9018" "until expressions are not available in the bootstrap subset"
        u.Ast.ut_span
  | Ast.TryBlock t ->
      reject diags "E9019" "try/catch/finally blocks are not available in the bootstrap subset"
        t.Ast.tr_span
  | Ast.ComptimeBlock (_, s) ->
      reject diags "E9006" "comptime blocks are not available in the bootstrap subset" s
  | Ast.IntLit _ | Ast.FloatLit _ | Ast.StringLit _ | Ast.CharLit _ | Ast.BoolLit _
  | Ast.Name _ | Ast.Path _ | Ast.NextExpr _ ->
      ()
  | Ast.Array (elems, _) -> List.iter (check_expr diags) elems
  | Ast.ArrayRepeat (v, c, _) ->
      check_expr diags v;
      check_expr diags c
  | Ast.Tuple (elems, _) -> List.iter (check_expr diags) elems
  | Ast.StructLit (_, targs, fields, rest, _) ->
      List.iter (check_type diags false) targs;
      List.iter (fun (_, v) -> check_expr diags v) fields;
      Option.iter (check_expr diags) rest
  | Ast.Block (b, _) | Ast.UnsafeBlock (_, b, _) -> check_block diags b
  | Ast.IfExpr i ->
      check_expr diags i.Ast.if_condition;
      check_block diags i.Ast.if_then;
      List.iter
        (fun (c, b) ->
          check_expr diags c;
          check_block diags b)
        i.Ast.if_elsif;
      Option.iter (check_block diags) i.Ast.if_else;
      Option.iter (check_pattern diags) i.Ast.if_let_pattern;
      Option.iter (check_expr diags) i.Ast.if_let_value
  | Ast.Call (callee, targs, args, _) ->
      check_expr diags callee;
      List.iter (check_type diags false) targs;
      List.iter (fun a -> check_expr diags a.Ast.ca_value) args
  | Ast.Index (b, i, _) ->
      check_expr diags b;
      check_expr diags i
  | Ast.Range (s, e, _, _) ->
      check_expr diags s;
      check_expr diags e
  | Ast.MatchExpr m ->
      check_expr diags m.Ast.m_subject;
      List.iter
        (fun arm ->
          check_pattern diags arm.Ast.ma_pattern;
          Option.iter (check_expr diags) arm.Ast.ma_guard;
          check_expr diags arm.Ast.ma_body)
        m.Ast.m_arms
  | Ast.Cast (e, t, _) ->
      check_expr diags e;
      check_type diags false t
  | Ast.TryOp (e, _) -> check_expr diags e
  | Ast.Closure c ->
      List.iter (fun p -> Option.iter (check_type diags true) p.Ast.cp_type) c.Ast.cl_params;
      Option.iter (check_type diags false) c.Ast.cl_return;
      check_expr diags c.Ast.cl_body
  | Ast.Unary (_, e, _) -> check_expr diags e
  | Ast.Field (b, _, _) -> check_expr diags b
  | Ast.Binary (l, _, r, _) ->
      check_expr diags l;
      check_expr diags r
  | Ast.MacroCall (_, args, _) ->
      List.iter
        (function Ast.MacroExpr e -> check_expr diags e | Ast.MacroTokens _ -> ())
        args
  | Ast.Assign (t, v, _) ->
      check_expr diags t;
      check_expr diags v
  | Ast.CompoundAssign (t, _, v, _) ->
      check_expr diags t;
      check_expr diags v
  | Ast.ReturnExpr (e, _) | Ast.BreakExpr (e, _) -> Option.iter (check_expr diags) e
  | Ast.ForExpr f ->
      check_pattern diags f.Ast.for_pattern;
      check_expr diags f.Ast.for_iterable;
      check_block diags f.Ast.for_body
  | Ast.WhileExpr w ->
      check_expr diags w.Ast.wh_condition;
      check_block diags w.Ast.wh_body
  | Ast.LoopExpr (b, _) -> check_block diags b

let check (diags : Diagnostic.bag) (program : Ast.program) =
  List.iter (check_item diags) program.Ast.items
