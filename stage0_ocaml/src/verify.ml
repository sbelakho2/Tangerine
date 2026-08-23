(* verify.ml — AST span verifier (V0001, INV-PARSE-007/008).

   Walks the entire AST and validates every non-synthetic span is well
   ordered (start >= 0 && end >= start). *)

let verify_span (diags : Diagnostic.bag) (span : Span.span) (context : string) =
  if not (Span.is_synthetic span) && not (Span.is_well_ordered span) then begin
    let reason =
      if span.Span.start < 0 then
        Printf.sprintf "span start (%d) is negative" span.Span.start
      else
        Printf.sprintf "span start (%d) > end (%d)" span.Span.start span.Span.end_
    in
    Diagnostic.error diags "V0001"
      (Printf.sprintf "INV-PARSE-007/INV-PARSE-008 violated: %s in %s" reason context)
      span
  end

let rec verify_expr diags ctx (e : Ast.expr) =
  verify_span diags (Ast.expr_span e) ctx;
  match e with
  | Ast.IntLit _ | Ast.FloatLit _ | Ast.StringLit _ | Ast.CharLit _ | Ast.BoolLit _
  | Ast.Name _ | Ast.NextExpr _ ->
      ()
  | Ast.Path (_, _, _) -> ()
  | Ast.Array (elems, _) -> List.iter (verify_expr diags ctx) elems
  | Ast.ArrayRepeat (v, c, _) ->
      verify_expr diags ctx v;
      verify_expr diags ctx c
  | Ast.Tuple (elems, _) -> List.iter (verify_expr diags ctx) elems
  | Ast.StructLit (_, targs, fields, rest, _) ->
      List.iter (verify_type diags ctx) targs;
      List.iter (fun (_, v) -> verify_expr diags ctx v) fields;
      Option.iter (verify_expr diags ctx) rest
  | Ast.Block (b, _) -> verify_block diags ctx b
  | Ast.UnsafeBlock (_, b, _) -> verify_block diags ctx b
  | Ast.IfExpr i ->
      verify_span diags i.Ast.if_span "if expr";
      verify_expr diags ctx i.Ast.if_condition;
      verify_block diags ctx i.Ast.if_then;
      List.iter
        (fun (c, b) ->
          verify_expr diags ctx c;
          verify_block diags ctx b)
        i.Ast.if_elsif;
      Option.iter (verify_block diags ctx) i.Ast.if_else;
      Option.iter (verify_pattern diags ctx) i.Ast.if_let_pattern;
      Option.iter (verify_expr diags ctx) i.Ast.if_let_value
  | Ast.Call (callee, targs, args, _) ->
      verify_expr diags ctx callee;
      List.iter (verify_type diags ctx) targs;
      List.iter (fun a -> verify_expr diags ctx a.Ast.ca_value) args
  | Ast.Index (b, i, _) ->
      verify_expr diags ctx b;
      verify_expr diags ctx i
  | Ast.Range (s, e, _, _) ->
      verify_expr diags ctx s;
      verify_expr diags ctx e
  | Ast.MatchExpr m ->
      verify_span diags m.Ast.m_span "match expr";
      verify_expr diags ctx m.Ast.m_subject;
      List.iter
        (fun arm ->
          verify_span diags arm.Ast.ma_span "match arm";
          verify_pattern diags ctx arm.Ast.ma_pattern;
          Option.iter (verify_expr diags ctx) arm.Ast.ma_guard;
          verify_expr diags ctx arm.Ast.ma_body)
        m.Ast.m_arms
  | Ast.Cast (e, t, _) ->
      verify_expr diags ctx e;
      verify_type diags ctx t
  | Ast.TryOp (e, _) -> verify_expr diags ctx e
  | Ast.Closure c ->
      verify_span diags c.Ast.cl_span "closure";
      List.iter (fun p -> verify_span diags p.Ast.cp_span "closure") c.Ast.cl_params;
      Option.iter (verify_type diags ctx) c.Ast.cl_return;
      verify_expr diags ctx c.Ast.cl_body
  | Ast.Unary (_, e, _) -> verify_expr diags ctx e
  | Ast.Field (b, _, _) -> verify_expr diags ctx b
  | Ast.Binary (l, _, r, _) ->
      verify_expr diags ctx l;
      verify_expr diags ctx r
  | Ast.AwaitExpr (e, _) -> verify_expr diags ctx e
  | Ast.MacroCall (_, args, _) ->
      List.iter
        (function
          | Ast.MacroExpr e -> verify_expr diags ctx e
          | Ast.MacroTokens (_, s) -> verify_span diags s "macro token tree")
        args
  | Ast.Assign (t, v, _) ->
      verify_expr diags ctx t;
      verify_expr diags ctx v
  | Ast.CompoundAssign (t, _, v, _) ->
      verify_expr diags ctx t;
      verify_expr diags ctx v
  | Ast.ReturnExpr (e, _) | Ast.BreakExpr (e, _) -> Option.iter (verify_expr diags ctx) e
  | Ast.ForExpr f ->
      verify_span diags f.Ast.for_span "for expr";
      verify_pattern diags ctx f.Ast.for_pattern;
      verify_expr diags ctx f.Ast.for_iterable;
      verify_block diags ctx f.Ast.for_body
  | Ast.WhileExpr w ->
      verify_span diags w.Ast.wh_span "while expr";
      verify_expr diags ctx w.Ast.wh_condition;
      verify_block diags ctx w.Ast.wh_body
  | Ast.LoopExpr (b, _) -> verify_block diags ctx b
  | Ast.HandleExpr h ->
      verify_span diags h.Ast.h_span "handle expr";
      verify_expr diags ctx h.Ast.h_expr;
      List.iter
        (fun (_, params, body) ->
          List.iter (verify_pattern diags ctx) params;
          verify_expr diags ctx body)
        h.Ast.h_arms
  | Ast.UnlessExpr u ->
      verify_span diags u.Ast.un_span "unless expr";
      verify_expr diags ctx u.Ast.un_condition;
      verify_block diags ctx u.Ast.un_body;
      Option.iter (verify_block diags ctx) u.Ast.un_else
  | Ast.UntilExpr u ->
      verify_span diags u.Ast.ut_span "until expr";
      verify_expr diags ctx u.Ast.ut_condition;
      verify_block diags ctx u.Ast.ut_body
  | Ast.TryBlock t ->
      verify_span diags t.Ast.tr_span "try block";
      verify_block diags ctx t.Ast.tr_body;
      List.iter
        (fun (p, b) ->
          verify_pattern diags ctx p;
          verify_block diags ctx b)
        t.Ast.tr_catches;
      Option.iter (verify_block diags ctx) t.Ast.tr_finally
  | Ast.ComptimeBlock (b, _) -> verify_block diags ctx b

and verify_block diags ctx (b : Ast.block_body) =
  verify_span diags b.Ast.b_span "block body";
  List.iter (verify_stmt diags ctx) b.Ast.b_stmts;
  Option.iter (verify_expr diags ctx) b.Ast.b_tail

and verify_stmt diags ctx (s : Ast.stmt) =
  verify_span diags (stmt_span s) "statement";
  match s with
  | Ast.LetBinding (p, _, ty, v, _) ->
      verify_pattern diags ctx p;
      Option.iter (verify_type diags ctx) ty;
      verify_expr diags ctx v
  | Ast.ExprStmt (e, _) -> verify_expr diags ctx e
  | Ast.AttributeStmt (attrs, _) -> List.iter (verify_attr diags) attrs
  | Ast.Attributed (attrs, inner, _) ->
      List.iter (verify_attr diags) attrs;
      verify_stmt diags ctx inner
  | Ast.DeferStmt (b, _) -> verify_block diags ctx b
  | Ast.Item i -> verify_item diags ctx i

and stmt_span (s : Ast.stmt) : Span.span =
  match s with
  | Ast.LetBinding (_, _, _, _, sp) | Ast.ExprStmt (_, sp)
  | Ast.AttributeStmt (_, sp) | Ast.Attributed (_, _, sp) | Ast.DeferStmt (_, sp) ->
      sp
  | Ast.Item i -> i.Ast.span

and verify_attr diags (a : Ast.attribute) =
  verify_span diags a.Ast.a_span (Printf.sprintf "attribute @%s" a.Ast.a_name)

and verify_type diags ctx (t : Ast.type_expr) =
  verify_span diags (Ast.type_span t) "type expression";
  match t with
  | Ast.Named (_, args, _) -> List.iter (verify_type diags ctx) args
  | Ast.AssocBinding (_, v, _) -> verify_type diags ctx v
  | Ast.ConstExpr (e, _) -> verify_expr diags ctx e
  | Ast.Never _ | Ast.Unit _ | Ast.SelfType _ | Ast.Inferred _ -> ()
  | Ast.TTuple (elems, _) -> List.iter (verify_type diags ctx) elems
  | Ast.Ref (inner, _, _) | Ast.RawPtr (inner, _, _) | Ast.Slice (inner, _)
  | Ast.DynTrait (inner, _) | Ast.ImplTrait (inner, _) | Ast.Option (inner, _) ->
      verify_type diags ctx inner
  | Ast.FnPtr (params, ret, _) ->
      List.iter (verify_type diags ctx) params;
      verify_type diags ctx ret
  | Ast.TArray (elem, len, _) ->
      verify_type diags ctx elem;
      Option.iter (verify_expr diags ctx) len
  | Ast.Bounded (base, bounds, _) ->
      verify_type diags ctx base;
      List.iter (verify_type diags ctx) bounds

and verify_pattern diags ctx (p : Ast.pattern) =
  verify_span diags (Ast.pattern_span p) "pattern";
  match p with
  | Ast.Wildcard _ | Ast.PatIdent _ | Ast.RefPattern _ | Ast.RefMutPattern _ -> ()
  | Ast.PatLiteral (e, _) -> verify_expr diags ctx e
  | Ast.PatVariant (_, _, fields, _) -> List.iter (verify_pattern diags ctx) fields
  | Ast.StructPattern (_, fields, _) ->
      List.iter
        (fun (_, opt) -> Option.iter (verify_pattern diags ctx) opt)
        fields
  | Ast.PatTuple (pats, _) -> List.iter (verify_pattern diags ctx) pats
  | Ast.OrPattern (a, b, _) ->
      verify_pattern diags ctx a;
      verify_pattern diags ctx b
  | Ast.RangePattern (a, b, _) ->
      verify_pattern diags ctx a;
      verify_pattern diags ctx b

and verify_item diags ctx (i : Ast.item) =
  verify_span diags i.Ast.span (Printf.sprintf "item %s" (Ast.item_summary i.Ast.kind));
  List.iter (verify_attr diags) i.Ast.attributes;
  match i.Ast.kind with
  | Ast.Function d -> verify_function diags ctx d
  | Ast.TestDecl d ->
      verify_span diags d.Ast.test_span (Printf.sprintf "test %s" d.Ast.test_name);
      verify_block diags ctx d.Ast.test_body
  | Ast.StructDef d ->
      verify_span diags d.Ast.s_span (Printf.sprintf "struct %s" d.Ast.s_name);
      List.iter
        (fun f ->
          verify_span diags f.Ast.f_span (Printf.sprintf "field %s" f.Ast.f_name);
          verify_type diags ctx f.Ast.f_type;
          Option.iter (verify_expr diags ctx) f.Ast.f_default)
        d.Ast.s_fields;
      List.iter (verify_function diags ctx) d.Ast.s_methods
  | Ast.EnumDef d ->
      verify_span diags d.Ast.e_span (Printf.sprintf "enum %s" d.Ast.e_name);
      List.iter
        (fun v ->
          verify_span diags v.Ast.v_span (Printf.sprintf "variant %s" v.Ast.v_name);
          List.iter (fun f -> verify_type diags ctx f.Ast.vf_type) v.Ast.v_fields)
        d.Ast.e_variants
  | Ast.TraitDef d ->
      verify_span diags d.Ast.t_span (Printf.sprintf "trait %s" d.Ast.t_name);
      List.iter (verify_function diags ctx) d.Ast.t_methods;
      List.iter (fun a -> verify_type diags ctx a.Ast.ta_value) d.Ast.t_associated_types
  | Ast.ImplBlock d ->
      verify_span diags d.Ast.i_span "impl block";
      List.iter (verify_function diags ctx) d.Ast.i_methods;
      Option.iter (verify_type diags ctx) d.Ast.i_for_type;
      List.iter
        (fun c ->
          verify_type diags ctx c.Ast.c_type;
          verify_expr diags ctx c.Ast.c_value)
        d.Ast.i_consts
  | Ast.UseDecl d -> verify_span diags d.Ast.u_span "use"
  | Ast.ConstDecl d ->
      verify_span diags d.Ast.c_span (Printf.sprintf "const %s" d.Ast.c_name);
      verify_type diags ctx d.Ast.c_type;
      verify_expr diags ctx d.Ast.c_value
  | Ast.StaticDecl d ->
      verify_span diags d.Ast.st_span (Printf.sprintf "static %s" d.Ast.st_name);
      verify_type diags ctx d.Ast.st_type;
      verify_expr diags ctx d.Ast.st_value
  | Ast.TypeAlias d ->
      verify_span diags d.Ast.ta_span (Printf.sprintf "type %s" d.Ast.ta_name);
      verify_type diags ctx d.Ast.ta_value
  | Ast.ExternBlock d ->
      verify_span diags d.Ast.ex_span "extern block";
      List.iter (verify_item diags ctx) d.Ast.ex_items
  | Ast.ModuleDef d ->
      verify_span diags d.Ast.md_span (Printf.sprintf "module %s" d.Ast.m_name);
      Option.iter (List.iter (verify_item diags ctx)) d.Ast.m_items
  | Ast.CapabilityDecl d -> verify_span diags d.Ast.cap_span (Printf.sprintf "cap %s" d.Ast.cap_name)
  | Ast.EffectDecl d -> verify_span diags d.Ast.ef_span (Printf.sprintf "effect %s" d.Ast.ef_name)
  | Ast.RationaleBlock d -> verify_span diags d.Ast.r_span "rationale"
  | Ast.MacroDecl d ->
      verify_span diags d.Ast.mac_span (Printf.sprintf "macro %s" d.Ast.mac_name);
      verify_block diags ctx d.Ast.mac_body
  | Ast.EditionDecl d -> verify_span diags d.Ast.ed_span (Printf.sprintf "edition %s" d.Ast.ed_version)

and verify_function diags ctx (d : Ast.function_decl) =
  verify_span diags d.Ast.fn_span (Printf.sprintf "function %s" d.Ast.fn_sig.Ast.sig_name);
  verify_sig diags ctx d.Ast.fn_sig;
  List.iter
    (function
      | Ast.Requires r -> verify_span diags r.Ast.req_span "requires clause"
      | Ast.Effect e -> verify_span diags e.Ast.eff_span "effect clause"
      | Ast.Budget b -> verify_span diags b.Ast.bud_span "budget clause"
      | Ast.Contract c ->
          verify_span diags c.Ast.con_span "contract clause";
          verify_expr diags ctx c.Ast.con_condition
      | Ast.GuardClause g ->
          verify_span diags g.Ast.g_span "guard clause";
          Option.iter (verify_expr diags ctx) g.Ast.g_condition;
          Option.iter (verify_pattern diags ctx) g.Ast.g_pattern;
          Option.iter (verify_expr diags ctx) g.Ast.g_value)
    d.Ast.fn_clauses;
  (match d.Ast.fn_body with
   | Ast.FnBlock b -> verify_block diags ctx b
   | Ast.FnExpr e -> verify_expr diags ctx e
   | Ast.FnSignatureOnly -> ())

and verify_sig diags ctx (sig_ : Ast.function_sig) =
  verify_span diags sig_.Ast.sig_span (Printf.sprintf "function sig %s" sig_.Ast.sig_name);
  List.iter
    (fun p ->
      verify_span diags p.Ast.p_span (Printf.sprintf "param %s" p.Ast.p_name);
      verify_type diags ctx p.Ast.p_type;
      Option.iter (verify_expr diags ctx) p.Ast.p_default)
    sig_.Ast.sig_params;
  Option.iter (verify_type diags ctx) sig_.Ast.sig_return;
  List.iter
    (fun wp ->
      verify_span diags wp.Ast.wp_span "where clause";
      verify_type diags ctx wp.Ast.wp_type)
    sig_.Ast.sig_where

let verify (diags : Diagnostic.bag) (program : Ast.program) =
  verify_span diags program.Ast.prog_span "program";
  List.iter (verify_item diags "item") program.Ast.items
