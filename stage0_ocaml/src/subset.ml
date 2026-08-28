(* subset.ml — Bootstrap-subset checker (E9001–E9049).

   Rejects constructs outside the stage0 bootstrap subset with the exact
   reference codes and messages.  The checker is the executable-subset
   firewall (audit P1 + re-audit): constructs whose later semantics
   remain approximate or absent are rejected up front with a clean
   diagnostic instead of a deep Seed_bug at lowering.  Each rejection
   carries the AST form it fires on; each one must be DELETED (with an
   executable positive test added) once the corresponding semantic
   implementation lands.

   The firewall's contract: every AST form the checker ACCEPTS must be
   lowerable by mir_lower (accepted ⊆ lowerable — the machine check in
   selfcheck/tg_subset.ml asserts it from Subset.expr_form_status vs
   Mir_lower.expr_lower_status).  E9037–E9049 close the re-audit's
   accepted-but-unlowerable gaps (the lowerer's expression-name
   diagnostic table has no branch for several forms the checker used to
   traverse).  The E9037 (StructLit) and Field-side E9036 rejections were
   DELETED 2026-08-27 when the StructCtor aggregate rule and the
   typed-place (FieldId) projection rule landed in mir_lower — their
    positive parse → typecheck → lower → verify → execute proofs live in
    selfcheck/tg_lowersurface.ml.  E9036 was likewise retired for the
    projected ASSIGNMENT writebacks 2026-08-28 when the typed-place
    writeback rule landed in mir_lower's Assign branch (Name/Field/Index
    targets lower; E9036 remains only for the target forms the lowerer
    still fails closed on). *)

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
   names plus qualified `enum::variant` names), the declared nominal
   (struct/enum) names and the declared top-level function names
   (qualified names included, e.g. `Command::new`).  The driver lowers
   with user_variant_table (built from the TYPED nominal registry —
   driver.ml), and the VariantId fix landed 2026-08-27 (each variant
   spec carries its registry-minted SEMANTIC vs_id — never a
   position-derived id — for user enums AND the builtin Option/Result
   via the table's vt_builtin channel).  User-enum support STAYS behind
   the firewall (E9035) until the positive driver-path end-to-end proof
   lands (parse → typecheck with resolver → driver lower → verify → VM
   on a user-enum program — the tg_lowersurface user-enum proofs still
   use hand-built tables; flipping is a separate wave).  The firewall
   also rejects nominal-qualified references that are neither declared
   top-level functions nor builtin variant constructors (E9048): the
   lowering env's callables carry top-level functions only, so a
   `Type::method` reference fails closed at lowering with "unknown
   callee".  E9048 was RETIRED 2026-08-28 when the qualified static-call
   path landed in mir_lower's lower_call Name-arm (the checker's static-
   method dispatch lowered: the (owner, method) methods-registry pair
   with the Vec<->Array / String<->str alias convention, the mangled
   free function, and the qualified user-enum ctors through the variant
   table); the residual unresolvable qualified names fail closed at
   lowering with "unknown callee" — the fail-closed channel that
   replaced the firewall rejection (positive proofs in
   selfcheck/tg_lowersurface.ml). *)

type ctx = {
  user_variants : string list;
  nominals : string list;
  functions : string list;
}

(* Collect the firewall context from the program items (recursing into
   module and extern blocks, the realistic nesting for seed enums). *)
let collect_ctx (program : Ast.program) : ctx =
  let variants = ref [] in
  let nominals = ref [] in
  let functions = ref [] in
  let rec item i =
    match i.Ast.kind with
    | Ast.EnumDef d ->
        nominals := d.Ast.e_name :: !nominals;
        List.iter
          (fun v ->
            variants := v.Ast.v_name :: !variants;
            variants := (d.Ast.e_name ^ "::" ^ v.Ast.v_name) :: !variants)
          d.Ast.e_variants
    | Ast.StructDef d -> nominals := d.Ast.s_name :: !nominals
    | Ast.Function d -> functions := d.Ast.fn_sig.Ast.sig_name :: !functions
    | Ast.ModuleDef d -> Option.iter (List.iter item) d.Ast.m_items
    | Ast.ExternBlock d -> List.iter item d.Ast.ex_items
    | _ -> ()
  in
  List.iter item program.Ast.items;
  { user_variants = !variants; nominals = !nominals; functions = !functions }

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
      (* literal consts are evaluated into program.statics and the
         lowering env (the driver's const_values channel — the E9034
         literal form is retired); the non-literal initializer forms
         stay rejected until the evaluator grows *)
      (match d.Ast.c_value with
       | Ast.IntLit _ | Ast.BoolLit _ | Ast.StringLit _ | Ast.CharLit _
       | Ast.FloatLit _ ->
           ()
       | Ast.Unary (Ast.Neg, Ast.IntLit _, _) ->
           (* a negated integer initializer `const MIN: Int = -128` *)
           ()
       | _ ->
           reject diags "E9034"
             "non-literal const initializers are not available in the bootstrap subset (the seed evaluates literal const initializers only)"
             d.Ast.c_span);
      check_expr ctx diags d.Ast.c_value;
      check_type ctx diags false d.Ast.c_type
  | Ast.StaticDecl d ->
      (* literal statics are evaluated into program.statics and the
         lowering env like literal consts (the E9034 literal static form
         is retired); the non-literal initializer forms stay rejected
         until the evaluator grows *)
      (match d.Ast.st_value with
       | Ast.IntLit _ | Ast.BoolLit _ | Ast.StringLit _ | Ast.CharLit _
       | Ast.FloatLit _ ->
           ()
       | Ast.Unary (Ast.Neg, Ast.IntLit _, _) -> ()
       | _ ->
           reject diags "E9034"
             "non-literal static initializers are not available in the bootstrap subset (the seed evaluates literal static initializers only)"
             d.Ast.st_span);
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
      (* AST form: Ast.LetBinding (pattern, ...).  Seed lowering binds
         let patterns by NAME only (lower_stmt: a non-PatIdent let
         pattern gets an anonymous local and NO scope bindings), so a
         destructuring let's names would be unbound at lowering and any
         later use fails closed with "unknown value"; reject the
         destructuring form until typed-pattern lowering lands. *)
      (match p with
       | Ast.PatIdent _ -> ()
       | Ast.PatTuple (subs, _) ->
           (* tuple destructuring lets `let (a, b) = t` are lowered
              through the tuple ConstantIndex projections (the E9045
              tuple form is retired); the nested sub-patterns must be
              names or `_` *)
           List.iter
             (fun sub ->
               match sub with
               | Ast.PatIdent _ | Ast.Wildcard _ -> ()
               | _ ->
                   reject diags "E9045"
                     "nested destructuring let patterns are not available in the bootstrap subset (seed lowering binds tuple components by name or `_` only)"
                     (Ast.pattern_span sub))
             subs
       | Ast.Wildcard _ ->
           (* `let _ = e` discards the value (the lowerer's LetBinding
              handles the wildcard — the E9045 discard form is retired) *)
           ()
       | _ ->
           reject diags "E9045"
             "destructuring let-binding patterns are not available in the bootstrap subset (seed lowering binds let patterns by name, `_` or tuple components only)"
             (Ast.pattern_span p));
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
  | Ast.Item i ->
      (* AST form: Ast.Item item — a nested definition inside a
         function body (parser `def`/`struct`/... in statement
         position).  Seed lowering DROPS nested items silently
         (lower_stmt: `Ast.Item _ -> ()`): the nested def is never
         registered as a callable, so any call to it fails closed at
         lowering with "unknown callee".  A nested USE is an inert
         import (the E9047 nested-use form is retired); the other
         nested items stay rejected until they reach the MIR program. *)
      (match i.Ast.kind with
       | Ast.UseDecl _ -> ()
       | _ ->
           reject diags "E9047"
             "nested item definitions are not available in the bootstrap subset (seed lowering drops nested items — a nested def is never registered as a callable)"
             i.Ast.span);
      check_item ctx diags i

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
  | Ast.PatVariant (_, _, fields, _) ->
      (* user-enum match arms: the VariantId fix landed (specs carry the
         registry-minted vs_id) and the positive driver-path end-to-end
         proof exists in tg_lowersurface — the E9035 gate is retired *)
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

(* ── Match-arm patterns (E9043/E9044) ─────────────────────────────
   Seed lowering serves exactly three arm forms: variant arms against
   the builtin variant table (Option/Result) with name/underscore
   payload bindings, integer-literal arms, and wildcard arms
   (lower_match: arm guards fail closed; PatIdent/PatTuple/Struct/
   Or/Range and non-integer literal arms fail closed with "unsupported
   match arm pattern"; a variant payload pattern that is not a name or
   `_` fails closed with "unsupported variant payload pattern").  The
   arm-position check below rejects every other form (E9044) and every
   guard (E9043) so an accepted match can never reach lowering's
   fail-closed branches. *)

and check_arm_pattern ctx diags (p : Ast.pattern) =
  match p with
  | Ast.PatVariant (_, _, fields, _) ->
      (* user-enum arms are lowered through the semantic registry (the
         E9035 gate is retired — the VariantId fix + the lowersurface
         positive proof) *)
      List.iter
        (fun f ->
          match f with
          | Ast.PatIdent _ | Ast.Wildcard _ -> ()
          | Ast.PatTuple (subs, _) ->
              (* tuple payloads `Some((a, b))` are bound through the
                 nested ConstantIndex projections (the E9044 tuple form
                 is retired); the components must be names or `_` *)
              List.iter
                (fun sub ->
                  match sub with
                  | Ast.PatIdent _ | Ast.Wildcard _ -> ()
                  | _ ->
                      reject diags "E9044"
                        "nested variant payload patterns are not available in the bootstrap subset (seed lowering binds payload components by name or `_` only)"
                        (Ast.pattern_span sub))
                subs
          | Ast.PatLiteral (Ast.CharLit _, _) ->
              (* a char payload `Some('#')`: the payload must hold the
                 literal char (the E9044 char-payload form is retired) *)
              ()
          | Ast.PatVariant (_, _, _, _) ->
              (* a nested-variant payload `Some(Live)`: the payload must
                 hold the nested variant (the E9044 nested-variant
                 payload form is retired) *)
              ()
          | Ast.PatLiteral (Ast.StringLit _, _) ->
              (* a string payload `Some("ast")`: the payload must hold
                 the literal string (the E9044 string-payload form is
                 retired) *)
              ()
          | Ast.PatLiteral (Ast.BoolLit _, _) ->
              (* a bool payload `Some(true)`: the payload must hold the
                 literal bool (the E9044 bool-payload form is retired) *)
              ()
          | Ast.StructPattern (_, sfields, _) ->
              (* a struct-payload `MirRvalue { kind: rvalue_kind }`: the
                 payload position holds the struct — the named fields
                 bind through the semantic FieldIds (the E9044
                 struct-payload form is retired); the sub-patterns must
                 be names or `_` *)
              List.iter
                (fun (_, fpat) ->
                  match fpat with
                  | None | Some (Ast.PatIdent _ | Ast.Wildcard _) -> ()
                  | Some _ ->
                      reject diags "E9044"
                        "nested struct-payload bindings are not available in the bootstrap subset (seed lowering binds struct payload fields by name or `_` only)"
                        (match fpat with Some p -> Ast.pattern_span p | None -> Span.synthetic))
                sfields
          | _ ->
              reject diags "E9044"
                "variant payload patterns are not available in the bootstrap subset (seed lowering binds payload fields by name, `_` or tuple components only)"
                (Ast.pattern_span f))
        fields
  | Ast.PatLiteral (e, span) -> (
      match e with
      | Ast.IntLit _ | Ast.CharLit _ | Ast.BoolLit _ ->
          (* int/char/bool literal arms switch on the tag (the E9044
             forms are retired) *)
          ()
      | Ast.StringLit _ ->
          (* string literal arms lower to the equality chain (the E9044
             string form is retired) *)
          ()
      | _ ->
          reject diags "E9044"
            "non-integer literal match arms are not available in the bootstrap subset (seed lowering builds switch targets for integer/char arms and string-equality chains only)"
            span);
      check_expr ctx diags e
  | Ast.OrPattern (a, b, _) ->
      (* or-pattern arms `A | B` dispatch both alternatives to the same
         arm block (the E9044 or-pattern form is retired); the
         alternatives must be serveable forms *)
      check_arm_pattern ctx diags a;
      check_arm_pattern ctx diags b
  | Ast.StructPattern (_, sfields, _) ->
      (* struct-pattern arms `Variant { f: x, ... }` switch on the tag
         and bind the payload struct fields through the semantic
         FieldIds (the E9044 struct-pattern form is retired); the field
         sub-patterns must be names or `_` *)
      List.iter
        (fun (_, fpat) ->
          match fpat with
          | None | Some (Ast.PatIdent _ | Ast.Wildcard _) -> ()
          | Some _ ->
              reject diags "E9044"
                "nested struct-pattern payload bindings are not available in the bootstrap subset (seed lowering binds struct payload fields by name or `_` only)"
                (match fpat with Some p -> Ast.pattern_span p | None -> Span.synthetic))
        sfields
  | Ast.PatIdent _ ->
      (* a binding arm `when x then` binds the whole subject (the E9044
         binding-arm form is retired) *)
      ()
  | Ast.PatTuple (subs, _) ->
      (* a tuple arm `(a, b) => ...` binds the elements through the
         ConstantIndex projections (the E9044 tuple-arm form is
         retired); a nested-variant element checks the discriminant and
         binds the nested payload; the sub-patterns must be names,
         `_` or nested variants with name/`_` payloads *)
      List.iter
        (fun sub ->
          match sub with
          | Ast.PatIdent _ | Ast.Wildcard _ -> ()
          | Ast.PatVariant (_, _, spats, _) ->
              List.iter
                (fun spat ->
                  match spat with
                  | Ast.PatIdent _ | Ast.Wildcard _ -> ()
                  | _ ->
                      reject diags "E9044"
                        "nested tuple arm payload sub-patterns are not available in the bootstrap subset (seed lowering binds nested payloads by name or `_` only)"
                        (Ast.pattern_span spat))
                spats
          | _ ->
              reject diags "E9044"
                "nested tuple arm sub-patterns are not available in the bootstrap subset (seed lowering binds tuple arm elements by name, `_` or nested variants only)"
                (Ast.pattern_span sub))
        subs
  | Ast.Wildcard _ -> ()
  | p ->
      reject diags "E9044"
        (Printf.sprintf
           "match arm pattern `%s` is not available in the bootstrap subset (seed lowering supports variant arms, struct-pattern arms, integer/char/string literal arms, binding arms and wildcard arms only)"
           (arm_pattern_name p))
        (Ast.pattern_span p)

and arm_pattern_name (p : Ast.pattern) : string =
  match p with
  | Ast.Wildcard _ -> "_"
  | Ast.PatIdent _ -> "binding"
  | Ast.RefPattern _ -> "ref"
  | Ast.RefMutPattern _ -> "ref-mut"
  | Ast.PatLiteral _ -> "literal"
  | Ast.PatVariant _ -> "variant"
  | Ast.StructPattern _ -> "struct"
  | Ast.PatTuple _ -> "tuple"
  | Ast.OrPattern _ -> "or-pattern"
  | Ast.RangePattern _ -> "range"

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
  | Ast.Name (n, _) ->
      (* user-enum constructors are lowered through the semantic registry
         (the E9035 gate is retired — the VariantId fix + the
         lowersurface positive proof) *)
      ignore n
  | Ast.Array (elems, _) -> List.iter (check_expr ctx diags) elems
  | Ast.ArrayRepeat (v, c, span) ->
      (* AST form: Ast.ArrayRepeat (value, count, span) (parser `[v; n]`).
         The lowerer's expression-name diagnostic table has no
         ArrayRepeat branch — it falls to "unhandled supported
         expression form: ArrayRepeat"; reject until array-repeat
         lowering lands. *)
      reject diags "E9038"
        "array-repeat expressions are not available in the bootstrap subset (seed lowering has no ArrayRepeat branch — write the elements out as an Array literal)"
        span;
      check_expr ctx diags v;
      check_expr ctx diags c
  | Ast.Tuple (elems, _) -> List.iter (check_expr ctx diags) elems
  | Ast.StructLit (_, targs, fields, rest, span) ->
      (* AST form: Ast.StructLit (name, targs, fields, rest, span)
         (parser `Name { f: v, ..rest }`).  The lowerer implements
         struct literals: the StructCtor aggregate rule lowers them with
         the typed registry's DECLARATION-order positions (the same
         order closure_types materializes into the StructDefs), the
         aggregate type from the typed channel or the env's type table,
         and every unresolvable field — unknown name, missing field,
         duplicate, `..` spread — fails closed at lowering with the
         reason (never a silent Unit).  Positive end-to-end proof:
         selfcheck/tg_lowersurface.ml (struct-lit + struct-field
         proofs, both VM round-tripped).  The field VALUES still get
         checked here. *)
      ignore span;
      List.iter (check_type ctx diags false) targs;
      List.iter (fun (_, v) -> check_expr ctx diags v) fields;
      Option.iter (check_expr ctx diags) rest
  | Ast.Block (b, _) -> check_block ctx diags b
  | Ast.UnsafeBlock (_, b, span) ->
      (* AST form: Ast.UnsafeBlock (reason, body, span) (parser
         `unsafe "reason" do ... end`).  The lowerer has no UnsafeBlock
         branch — it falls to "unhandled supported expression form:
         UnsafeBlock"; reject until an unsafe model lands in the seed. *)
      (* unsafe blocks lower their body like a plain block (the E9041
         form is retired — the seed has no separate unsafe model) *)
      ignore span;
      check_block ctx diags b
  | Ast.IfExpr i ->
      (* AST form: Ast.IfExpr with if_let_pattern/if_let_value (parser
         `if let <pat> = <expr> then`).  Seed lowering ignores the
         if-let pattern entirely (lower_if has no if-let arm), so the
         branch would lower unconditionally; reject the if-let form
         until typed-pattern conditionals land. *)
      (match i.Ast.if_let_pattern with
       | None -> ()
       | Some _ ->
           reject diags "E9046"
             "if-let expressions are not available in the bootstrap subset (seed lowering ignores the if-let pattern — the branch would lower unconditionally)"
             (Ast.expr_span i.Ast.if_condition));
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
  | Ast.Call (callee, targs, args, _) ->
      (* user-enum constructors are lowered through the semantic registry
         (the E9035 gate is retired) *)
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
  | Ast.Range (start, end_, _, span) ->
      (* AST form: Ast.Range (start, end, inclusive, span) (parser
         `a..b` / `a..=b`).  Integer ranges `a..b` lower to the counter
         loop (the E9039 integer-range form is retired); the exclusive
         `..=` form and non-integer bounds stay rejected. *)
      (match start with
       | Ast.IntLit _ -> ()
       | _ ->
           reject diags "E9039"
             "non-integer range bounds are not available in the bootstrap subset (seed lowering counts integer ranges only)"
             span);
      check_expr ctx diags start;
      check_expr ctx diags end_
  | Ast.MatchExpr m ->
      check_expr ctx diags m.Ast.m_subject;
      List.iter
        (fun arm ->
          (match arm.Ast.ma_guard with
           | Some g ->
               reject diags "E9043"
                 "match arm guards are not available in the bootstrap subset (seed lowering rejects arm guards)"
                 (Ast.expr_span g);
               check_expr ctx diags g
           | None -> ());
          check_arm_pattern ctx diags arm.Ast.ma_pattern;
          check_expr ctx diags arm.Ast.ma_body)
        m.Ast.m_arms
  | Ast.Cast (e, t, _) ->
      check_expr ctx diags e;
      check_type ctx diags false t
  | Ast.TryOp (e, _) -> check_expr ctx diags e
  | Ast.Closure c ->
      (* AST form: Ast.Closure (params, body) (parser pipe closure
         `|x| e` or do-block closure `fn |x| ... end`).  The lowerer has
         no Closure branch — it falls to "unhandled supported
         expression form: Closure"; reject until closure lowering lands
         (lift the closure to a named function). *)
      reject diags "E9040"
        "closure expressions are not available in the bootstrap subset (seed lowering has no Closure branch — lift the closure to a named function)"
        c.Ast.cl_span;
      List.iter (fun p -> Option.iter (check_type ctx diags true) p.Ast.cp_type) c.Ast.cl_params;
      Option.iter (check_type ctx diags false) c.Ast.cl_return;
      check_expr ctx diags c.Ast.cl_body
  | Ast.Unary (_, e, _) -> check_expr ctx diags e
  | Ast.Field (b, _, span) ->
      (* AST form: Ast.Field (base, field_name, span) — a projected read
         (`p.x`), or the method-call receiver `obj.method(...)` (the
         parser produces a Field callee).  The lowerer implements the
         typed-place (FieldId) rule: the base lowers to a place and the
         field resolves against the typed nominal registry
         (func_env.struct_fields) with the SEMANTIC FieldId — tuples
         project positionally with ConstantIndex — and every
         unresolvable field fails closed.  Method-call receivers lower
         through the receiver-typed method rule (the typed place is
         passed as the SELF argument).  Positive end-to-end proofs
         (lower + verify + VM round-trip): selfcheck/tg_lowersurface.ml
         (struct-field, struct-lit, method-call and nested-function
         proofs).  A projected WRITE (`p.x = v`) lowers through the
         typed-place writeback rule (2026-08-28 — the Assign branch
         resolves the field through the same registry channel; E9036
         remains only for target forms without a typed-place rule). *)
      ignore span;
      check_expr ctx diags b
  | Ast.Binary (l, _, r, _) ->
      check_expr ctx diags l;
      check_expr ctx diags r
  | Ast.MacroCall (n, args, span) ->
      (* AST form: Ast.MacroCall (name, args, span) — `name!(...)`.  The
         lowerer has no MacroCall branch — it falls to "unhandled
         supported expression form: MacroCall"; reject until macro
         lowering lands (the typechecker's debug_assert special case
         keeps `debug_assert!` out of the typecheck debt, so without
         this rejection it would sail through to the fail-closed
         lowering branch). *)
      (match n with
       | "debug_assert" ->
           (* debug_assert!(cond[, msg]): the condition is checked and
              the value discarded (the E9049 debug_assert! form is
              retired) *)
           List.iter
             (function
               | Ast.MacroExpr e -> check_expr ctx diags e
               | Ast.MacroTokens _ -> ())
             args
       | "vec" ->
           (* `vec![...]` lowers to the array aggregate (the E9049 vec!
              form is retired); the arguments must be expressions *)
           List.iter
             (function
               | Ast.MacroExpr e -> check_expr ctx diags e
               | Ast.MacroTokens _ ->
                   reject diags "E9049"
                     "vec! with raw token arguments is not available in the bootstrap subset (the seed lowers expression arguments only)"
                     span)
             args
       | _ ->
           reject diags "E9049"
             (Printf.sprintf
                "macro invocations (`%s!`) are not available in the bootstrap subset (seed lowering lowers vec! only)"
                n)
             span;
           List.iter
             (function Ast.MacroExpr e -> check_expr ctx diags e | Ast.MacroTokens _ -> ())
           args)
  | Ast.Assign (target, v, span) ->
      (* AST form: Ast.Assign (target, value, span).  The typed-place
         writeback rule landed (2026-08-28): a Name, Field or Index
         target lowers — the field resolves through the typed nominal
         registry (the same channel as the read path) and the index is
         constant or dynamic — so the firewall no longer rejects them;
         their positive parse -> typecheck -> lower -> verify -> execute
         proofs live in selfcheck/tg_lowersurface.ml (struct-field and
         array-index writebacks).  E9036 remains for the target forms
         the lowerer STILL fails closed on (any target that is not a
         Name/Field/Index — e.g. a Deref/other-operator target — has no
         typed-place writeback rule). *)
      (match target with
       | Ast.Name _ | Ast.Field _ | Ast.Index _ -> ()
       | Ast.Unary (Ast.Deref, _, _) ->
           (* `*p = v` writes through the Deref projection (the E9036
              deref-target form is retired) *)
           ()
       | _ ->
           reject diags "E9036"
             "projected assignment is not available in the bootstrap subset (writeback through a projection is resource-sensitive and has no typed-place rule in seed lowering)"
             span);
      check_expr ctx diags target;
      check_expr ctx diags v
  | Ast.CompoundAssign (target, _, v, span) ->
      (* AST form: Ast.CompoundAssign (target, op, value, span).  The
         lowerer has NO CompoundAssign branch at all — even a plain Name
         target (`x += 1`) fails closed with "CompoundAssign reached MIR
         lowering without a typed-place writeback rule"; reject the
         whole form until writeback lowering lands. *)
      reject diags "E9042"
        "compound assignment is not available in the bootstrap subset (seed lowering has no CompoundAssign branch — even plain name targets fail closed at lowering)"
        span;
      check_expr ctx diags target;
      check_expr ctx diags v
  | Ast.ReturnExpr (e, _) | Ast.BreakExpr (e, _) -> Option.iter (check_expr ctx diags) e
  | Ast.ForExpr f ->
      (* AST form: Ast.ForExpr with a destructuring loop pattern
         (`for (k, v) in m do`).  Seed lowering binds the loop variable
         by name or `_` only (lower ForExpr: "unsupported for-loop
         pattern"); reject the destructuring form (E9045). *)
      (match f.Ast.for_pattern with
       | Ast.PatIdent _ | Ast.Wildcard _ -> ()
       | Ast.PatTuple (subs, _) ->
           (* destructuring loops `for (a, b) in arr` are lowered through
              the element tuple ConstantIndex projections (the E9045
              tuple form is retired); the sub-patterns must be names or
              `_` *)
           List.iter
             (fun sub ->
               match sub with
               | Ast.PatIdent _ | Ast.Wildcard _ -> ()
               | _ ->
                   reject diags "E9045"
                     "nested destructuring for-loop patterns are not available in the bootstrap subset (seed lowering binds tuple components by name or `_` only)"
                     (Ast.pattern_span sub))
             subs
       | p ->
           reject diags "E9045"
             "destructuring for-loop patterns are not available in the bootstrap subset (seed lowering binds the loop variable by name, `_` or tuple components only)"
             (Ast.pattern_span p));
      check_pattern ctx diags f.Ast.for_pattern;
      check_expr ctx diags f.Ast.for_iterable;
      check_block ctx diags f.Ast.for_body
  | Ast.WhileExpr w ->
      check_expr ctx diags w.Ast.wh_condition;
      check_block ctx diags w.Ast.wh_body
  | Ast.LoopExpr (b, _) -> check_block ctx diags b

let check (diags : Diagnostic.bag) (program : Ast.program) =
  let ctx = collect_ctx program in
  List.iter (check_item ctx diags) program.Ast.items

(* ── Machine-check surface (selfcheck/tg_subset.ml) ───────────────
   The firewall's form-level rules as DATA, keyed by the SAME form names
   as Mir_lower.expr_form_name.  The selfcheck asserts the re-audit's
   invariant — `Subset-accepted AST variants ⊆ Mir_lower-lowerable AST
   variants` — for every form (an Accepted/Conditional form must never
   be Unlowerable), and verifies this table against the checker itself
   by running Subset.check on one specimen per form.  Keep this table in
   lockstep with the checker: a rule change here without the
   corresponding check_expr change fails the selfcheck. *)

type form_status =
  | Accepted
  | Rejected of string          (* the E-code that always fires on the form *)
  | Conditional of string list  (* E-codes that fire on specific sub-forms *)
  | Unreachable                 (* no parser production reaches the checker *)

let expr_form_status : (string * form_status) list =
  [
    (* the qualified-call surface (E9048 retirement 2026-08-28): the
       lowerer's Name arm now serves the checker's full static-method
       dispatch — the qualified user-enum ctors (the variant table's
       vt_enums qualified form), the (owner, method) methods-registry
       pair with the Vec<->Array / String<->str alias convention, and the
       mangled free function (`String::new` -> `string_new`) — so a
       nominal-qualified name no longer fires E9048; the residual
       unresolvable qualified names fail closed at lowering with
       "unknown callee" (the fail-closed channel that replaced the
       firewall rejection) *)
    ("IntLit", Accepted);
    ("FloatLit", Accepted);
    ("StringLit", Accepted);
    ("CharLit", Accepted);
    ("BoolLit", Accepted);
    ("Name", Accepted);
    (* the parser folds qualified names into Name; a Path value never
       exists in a parsed program (Path would fail closed at lowering) *)
    ("Path", Unreachable);
    ("Array", Accepted);
    ("ArrayRepeat", Rejected "E9038");
    ("Tuple", Accepted);
    (* the StructCtor aggregate rule landed (2026-08-27): the literal
       lowers with the typed registry's declaration-order positions;
       unresolvable fields and `..` spreads fail closed at lowering
       (tg_lowersurface's struct-lit + fail-closed proofs) *)
    ("StructLit", Accepted);
    ("Block", Accepted);
    ("UnsafeBlock", Rejected "E9041");
    ("If", Conditional [ "E9046" ]);
    (* Name callees (functions + builtin/user-enum ctors via the
       variant table), Field callees (method calls through the
       receiver-typed rule) AND nominal-qualified static calls
       (`Type::method` through the qualified path — E9048 retired
       2026-08-28) lower; unresolvable receivers and qualified names
       fail closed at lowering *)
    ("Call", Accepted);
    ("Index", Accepted);
    ("Range", Rejected "E9039");
    ("Match", Conditional [ "E9035"; "E9043"; "E9044" ]);
    ("Cast", Accepted);
    ("TryOp", Accepted);
    ("Closure", Rejected "E9040");
    ("Unary", Accepted);
    (* the typed-place (FieldId) rule landed (2026-08-27): reads project
       with the semantic FieldId; unresolvable fields fail closed *)
    ("Field", Accepted);
    ("Binary", Accepted);
    ("Await", Rejected "E9015");
    ("MacroCall", Rejected "E9049");
    (* plain Name targets accept; projected writebacks (a[i] = v,
       p.x = v) lower through the typed-place writeback rule
       (2026-08-28); other target forms still have no typed-place rule
       in seed lowering *)
    ("Assign", Conditional [ "E9036" ]);
    ("CompoundAssign", Rejected "E9042");
    ("Return", Accepted);
    ("Break", Accepted);
    ("Next", Accepted);
    ("For", Conditional [ "E9045" ]);
    ("While", Accepted);
    ("Loop", Accepted);
    ("Handle", Rejected "E9016");
    ("Unless", Rejected "E9017");
    ("Until", Rejected "E9018");
    ("Try", Rejected "E9019");
    ("Comptime", Rejected "E9006");
  ]
