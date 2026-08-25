(* subset.ml — Bootstrap-subset checker (E9001–E9036).

   Rejects constructs outside the stage0 bootstrap subset with the exact
   reference codes and messages.  The checker is the executable-subset
   firewall (audit P1): constructs whose later semantics remain
   approximate or absent are rejected up front with a clean diagnostic
   instead of a deep Seed_bug at lowering.  Each rejection carries the
   AST form it fires on; each one must be DELETED (with an executable
   positive test added) once the corresponding semantic implementation
   lands. *)

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

(* ── Firewall context ──────────────────────────────────────────────

   Carries the user-defined enum surface of the program (bare variant
   names plus qualified `enum::variant` names).  The driver lowers with
   the default variant table — the builtin Option/Result table only
   (mir_lower.default_variant_table + the builtin ctor_of fallback), so
   any user-enum construct or match arm fails closed at lowering with
   Seed_bug.  The firewall rejects that usage up front (E9035). *)

type ctx = { user_variants : string list }

(* Collect user-enum ctor names from the program items (recursing into
   module and extern blocks, the realistic nesting for seed enums). *)
let collect_user_variants (program : Ast.program) : string list =
  let acc = ref [] in
  let rec item i =
    match i.Ast.kind with
    | Ast.EnumDef d ->
        List.iter
          (fun v ->
            acc := v.Ast.v_name :: !acc;
            acc := (d.Ast.e_name ^ "::" ^ v.Ast.v_name) :: !acc)
          d.Ast.e_variants
    | Ast.ModuleDef d -> Option.iter (List.iter item) d.Ast.m_items
    | Ast.ExternBlock d -> List.iter item d.Ast.ex_items
    | _ -> ()
  in
  List.iter item program.Ast.items;
  !acc

(* A variant pattern the default variant table can serve: the builtin
   enums Option (Some=0, None=1) and Result (Ok=0, Err=1), in bare or
   qualified form.  Anything else is a user-enum match arm. *)
let builtin_variant_of (seg1 : string) (seg2 : string) : bool =
  match seg1 with
  | "" -> List.mem seg2 [ "Some"; "None"; "Ok"; "Err" ]
  | "Option" -> seg2 = "Some" || seg2 = "None"
  | "Result" -> seg2 = "Ok" || seg2 = "Err"
  | _ -> false

let rec check_item ctx diags (i : Ast.item) =
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
      check_sig ctx diags d.Ast.fn_sig;
      List.iter (check_clause diags) d.Ast.fn_clauses;
      (match d.Ast.fn_body with
       | Ast.FnBlock b -> check_block ctx diags b
       | Ast.FnExpr e -> check_expr ctx diags e
       | Ast.FnSignatureOnly -> ())
  | Ast.TestDecl d -> check_block ctx diags d.Ast.test_body
  | Ast.StructDef d ->
      List.iter (fun f -> check_type ctx diags false f.Ast.f_type) d.Ast.s_fields;
      List.iter (check_function ctx diags) d.Ast.s_methods
  | Ast.EnumDef d ->
      List.iter
        (fun v -> List.iter (fun f -> check_type ctx diags false f.Ast.vf_type) v.Ast.v_fields)
        d.Ast.e_variants
  | Ast.TraitDef d ->
      List.iter (check_function ctx diags) d.Ast.t_methods;
      List.iter (fun a -> check_type ctx diags false a.Ast.ta_value) d.Ast.t_associated_types
  | Ast.ImplBlock d ->
      List.iter (check_function ctx diags) d.Ast.i_methods;
      List.iter
        (fun a -> check_type ctx diags false a.Ast.ta_value)
        d.Ast.i_associated_types;
      List.iter
        (fun c ->
          (* associated consts are consts: they never reach
             program.statics either (driver passes statics = [||]) *)
          reject diags "E9034"
            "const declarations are not available in the bootstrap subset (consts never reach program.statics in the seed lowering)"
            c.Ast.c_span;
          check_expr ctx diags c.Ast.c_value;
          check_type ctx diags false c.Ast.c_type)
        d.Ast.i_consts
  | Ast.ConstDecl d ->
      (* AST form: Ast.ConstDecl (parser `const NAME: T = e`); the
         lowering API carries no const table and every driver caller
         passes `statics = [||]` (mir_lower §35 TODO), so consts never
         reach program.statics — reject until real const lowering lands. *)
      reject diags "E9034"
        "const declarations are not available in the bootstrap subset (consts never reach program.statics in the seed lowering)"
        d.Ast.c_span;
      check_expr ctx diags d.Ast.c_value;
      check_type ctx diags false d.Ast.c_type
  | Ast.StaticDecl d ->
      reject diags "E9034"
        "static declarations are not available in the bootstrap subset (statics never reach program.statics in the seed lowering)"
        d.Ast.st_span;
      check_expr ctx diags d.Ast.st_value;
      check_type ctx diags false d.Ast.st_type
  | Ast.TypeAlias d -> check_type ctx diags false d.Ast.ta_value
  | Ast.ExternBlock d -> List.iter (check_item ctx diags) d.Ast.ex_items
  | Ast.ModuleDef d -> Option.iter (List.iter (check_item ctx diags)) d.Ast.m_items
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
  | Ast.MacroDecl d -> check_block ctx diags d.Ast.mac_body
  | Ast.UseDecl _ -> ()

and check_function ctx diags (d : Ast.function_decl) =
  check_sig ctx diags d.Ast.fn_sig;
  List.iter (check_clause diags) d.Ast.fn_clauses;
  match d.Ast.fn_body with
  | Ast.FnBlock b -> check_block ctx diags b
  | Ast.FnExpr e -> check_expr ctx diags e
  | Ast.FnSignatureOnly -> ()

and check_sig ctx diags (sig_ : Ast.function_sig) =
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
      check_type ctx diags true p.Ast.p_type;
      Option.iter (check_expr ctx diags) p.Ast.p_default)
    sig_.Ast.sig_params;
  Option.iter (check_type ctx diags false) sig_.Ast.sig_return

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

and check_block ctx diags (b : Ast.block_body) =
  List.iter (check_stmt ctx diags) b.Ast.b_stmts;
  Option.iter (check_expr ctx diags) b.Ast.b_tail

and check_stmt ctx diags (s : Ast.stmt) =
  match s with
  | Ast.LetBinding (p, _, ty, v, _) ->
      check_pattern ctx diags p;
      Option.iter (check_type ctx diags false) ty;
      check_expr ctx diags v
  | Ast.ExprStmt (e, _) -> check_expr ctx diags e
  | Ast.AttributeStmt _ -> ()
  | Ast.Attributed (_, inner, _) -> check_stmt ctx diags inner
  | Ast.DeferStmt (b, span) ->
      (* AST form: Ast.DeferStmt (block_body, span) (parser `defer
         <block> end`).  Function-scoped deferral is currently
         approximate — reject until the defer semantics land precisely. *)
      reject diags "E9033"
        "defer statements are not available in the bootstrap subset (function-scoped deferral semantics are not yet precise)"
        span;
      check_block ctx diags b
  | Ast.Item i -> check_item ctx diags i

and check_type ctx diags allows_impl (t : Ast.type_expr) =
  match t with
  | Ast.ConstExpr (e, _) -> check_expr ctx diags e
  | Ast.Ref (inner, _, _) | Ast.RawPtr (inner, _, _) -> check_type ctx diags false inner
  | Ast.FnPtr (params, ret, _) ->
      List.iter (check_type ctx diags true) params;
      check_type ctx diags false ret
  | Ast.TArray (elem, len, _) ->
      check_type ctx diags false elem;
      Option.iter (check_expr ctx diags) len
  | Ast.Slice (inner, _) | Ast.Option (inner, _) -> check_type ctx diags false inner
  | Ast.DynTrait (inner, _) ->
      reject diags "E9032"
        "trait-object types (dyn Trait / impl Trait in type position) are not available in the bootstrap subset"
        (Ast.type_span inner);
      check_type ctx diags false inner
  | Ast.ImplTrait (inner, _) ->
      if not allows_impl then
        reject diags "E9032"
          "trait-object types (dyn Trait / impl Trait in type position) are not available in the bootstrap subset"
          (Ast.type_span inner);
      check_type ctx diags false inner
  | Ast.TTuple (elems, _) -> List.iter (check_type ctx diags false) elems
  | Ast.Named (_, args, _) -> List.iter (check_type ctx diags false) args
  | Ast.AssocBinding (_, v, _) -> check_type ctx diags false v
  | Ast.Bounded (base, bounds, _) ->
      check_type ctx diags false base;
      List.iter (check_type ctx diags false) bounds
  | Ast.Never _ | Ast.Unit _ | Ast.SelfType _ | Ast.Inferred _ -> ()

and check_pattern ctx diags (p : Ast.pattern) =
  match p with
  | Ast.Wildcard _ | Ast.PatIdent _ | Ast.RefPattern _ | Ast.RefMutPattern _ -> ()
  | Ast.PatLiteral (e, _) -> check_expr ctx diags e
  | Ast.PatVariant (seg1, seg2, fields, span) ->
      (* AST form: Ast.PatVariant (enum_seg, variant_name, pats, span)
         (parser: `Enum::Variant(...)` qualified, `Variant(...)` bare).
         The driver's default variant table serves only Option/Result —
         a user-enum match arm fails closed at lowering with Seed_bug. *)
      if not (builtin_variant_of seg1 seg2) then
        reject diags "E9035"
          (Printf.sprintf
             "user-defined enum match arm `%s` is not available in the bootstrap subset (the default variant table serves only Option/Result)"
             (if seg1 = "" then seg2 else seg1 ^ "::" ^ seg2))
          span;
      List.iter (check_pattern ctx diags) fields
  | Ast.StructPattern (_, fields, _) ->
      List.iter (fun (_, opt) -> Option.iter (check_pattern ctx diags) opt) fields
  | Ast.PatTuple (pats, _) -> List.iter (check_pattern ctx diags) pats
  | Ast.OrPattern (a, b, _) ->
      check_pattern ctx diags a;
      check_pattern ctx diags b
  | Ast.RangePattern (a, b, _) ->
      check_pattern ctx diags a;
      check_pattern ctx diags b

and check_expr ctx diags (e : Ast.expr) =
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
  | Ast.Path _ | Ast.NextExpr _ ->
      ()
  | Ast.Name (n, span) ->
      (* AST form: Ast.Name (name, span) — a user-enum constructor in
         value position (`Red` nullary, or the qualified `Color::Red` the
         parser folds into a single Name).  The driver's plain
         lower_function carries no user variant table, so these fail
         closed at lowering; reject until real enum lowering lands. *)
      if List.mem n ctx.user_variants then
        reject diags "E9035"
          (Printf.sprintf
             "user-defined enum constructor `%s` is not available in the bootstrap subset (the default variant table serves only Option/Result)"
             n)
          span
  | Ast.Array (elems, _) -> List.iter (check_expr ctx diags) elems
  | Ast.ArrayRepeat (v, c, _) ->
      check_expr ctx diags v;
      check_expr ctx diags c
  | Ast.Tuple (elems, _) -> List.iter (check_expr ctx diags) elems
  | Ast.StructLit (_, targs, fields, rest, _) ->
      List.iter (check_type ctx diags false) targs;
      List.iter (fun (_, v) -> check_expr ctx diags v) fields;
      Option.iter (check_expr ctx diags) rest
  | Ast.Block (b, _) | Ast.UnsafeBlock (_, b, _) -> check_block ctx diags b
  | Ast.IfExpr i ->
      check_expr ctx diags i.Ast.if_condition;
      check_block ctx diags i.Ast.if_then;
      List.iter
        (fun (c, b) ->
          check_expr ctx diags c;
          check_block ctx diags b)
        i.Ast.if_elsif;
      Option.iter (check_block ctx diags) i.Ast.if_else;
      Option.iter (check_pattern ctx diags) i.Ast.if_let_pattern;
      Option.iter (check_expr ctx diags) i.Ast.if_let_value
  | Ast.Call (callee, targs, args, span) ->
      (* AST form: Ast.Call (Ast.Name n, ...) with n a user-enum ctor
         (`Green(7)` bare, `Color::Green(7)` folded qualified name). *)
      (match callee with
       | Ast.Name (n, _) when List.mem n ctx.user_variants ->
           reject diags "E9035"
             (Printf.sprintf
                "user-defined enum constructor `%s` is not available in the bootstrap subset (the default variant table serves only Option/Result)"
                n)
             span
       | _ -> ());
      check_expr ctx diags callee;
      List.iter (check_type ctx diags false) targs;
      List.iter (fun a -> check_expr ctx diags a.Ast.ca_value) args
  | Ast.Index (b, i, _) ->
      (* NOTE: dynamic runtime indexing is NOT rejected — the Index fix
         landed (mir_lower lowers a nonconstant `a[i]` to the dynamic
         Seed_mir.Index <index_local> projection, and the VM executes it
         with bounds checks), so valid runtime `a[i]` lowers and
         verifies. *)
      check_expr ctx diags b;
      check_expr ctx diags i
  | Ast.Range (s, e, _, _) ->
      check_expr ctx diags s;
      check_expr ctx diags e
  | Ast.MatchExpr m ->
      check_expr ctx diags m.Ast.m_subject;
      List.iter
        (fun arm ->
          check_pattern ctx diags arm.Ast.ma_pattern;
          Option.iter (check_expr ctx diags) arm.Ast.ma_guard;
          check_expr ctx diags arm.Ast.ma_body)
        m.Ast.m_arms
  | Ast.Cast (e, t, _) ->
      check_expr ctx diags e;
      check_type ctx diags false t
  | Ast.TryOp (e, _) -> check_expr ctx diags e
  | Ast.Closure c ->
      List.iter (fun p -> Option.iter (check_type ctx diags true) p.Ast.cp_type) c.Ast.cl_params;
      Option.iter (check_type ctx diags false) c.Ast.cl_return;
      check_expr ctx diags c.Ast.cl_body
  | Ast.Unary (_, e, _) -> check_expr ctx diags e
  | Ast.Field (b, _, span) ->
      (* AST form: Ast.Field (base, field_name, span) — a projected read
         (`p.x`, or the method-call receiver `obj.method(...)`).  Seed
         lowering has no typed-place Field rule (mir_lower fails closed
         on every user Field form), and projected operations on places
         are resource-sensitive (they interact with move/consume
         semantics); reject until precise. *)
      reject diags "E9036"
        "field projections are not available in the bootstrap subset (projected operations on places are resource-sensitive and have no typed-place rule in seed lowering)"
        span;
      check_expr ctx diags b
  | Ast.Binary (l, _, r, _) ->
      check_expr ctx diags l;
      check_expr ctx diags r
  | Ast.MacroCall (_, args, _) ->
      List.iter
        (function Ast.MacroExpr e -> check_expr ctx diags e | Ast.MacroTokens _ -> ())
        args
  | Ast.Assign (target, v, span) ->
      (* AST form: Ast.Assign (target, value, span) — a projected
         writeback (`a[i] = v`, `p.x = v`) fails closed at lowering (no
         typed-place writeback rule).  A plain Name target is fine. *)
      (match target with
       | Ast.Name _ -> ()
       | _ ->
           reject diags "E9036"
             "projected assignment is not available in the bootstrap subset (writeback through a projection is resource-sensitive and has no typed-place rule in seed lowering)"
             span);
      check_expr ctx diags target;
      check_expr ctx diags v
  | Ast.CompoundAssign (target, _, v, span) ->
      (* AST form: Ast.CompoundAssign (target, op, value, span) — the
         projected forms fail closed at lowering like Assign; plain Name
         targets are left to the existing lowering surface. *)
      (match target with
       | Ast.Name _ -> ()
       | _ ->
           reject diags "E9036"
             "projected compound assignment is not available in the bootstrap subset (writeback through a projection is resource-sensitive and has no typed-place rule in seed lowering)"
             span);
      check_expr ctx diags target;
      check_expr ctx diags v
  | Ast.ReturnExpr (e, _) | Ast.BreakExpr (e, _) -> Option.iter (check_expr ctx diags) e
  | Ast.ForExpr f ->
      check_pattern ctx diags f.Ast.for_pattern;
      check_expr ctx diags f.Ast.for_iterable;
      check_block ctx diags f.Ast.for_body
  | Ast.WhileExpr w ->
      check_expr ctx diags w.Ast.wh_condition;
      check_block ctx diags w.Ast.wh_body
  | Ast.LoopExpr (b, _) -> check_block ctx diags b

let check (diags : Diagnostic.bag) (program : Ast.program) =
  let ctx = { user_variants = collect_user_variants program } in
  List.iter (check_item ctx diags) program.Ast.items
