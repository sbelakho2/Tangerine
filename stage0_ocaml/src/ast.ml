(* ast.ml — Abstract Syntax Tree for the Tangerine language (Edition 2026).

   Mirrors the stage0 Swift AST with every node carrying its span (half-open
   byte range), which the span verifier and diagnostics rely on. *)

type program = {
  items : item list;
  prog_span : Span.span;
  prog_module_path : string list;
}

and item = {
  kind : item_kind;
  attributes : attribute list;
  span : Span.span;
  module_path : string list;
}

and item_kind =
  | Function of function_decl
  | TestDecl of test_decl
  | StructDef of struct_decl
  | EnumDef of enum_decl
  | TraitDef of trait_decl
  | ImplBlock of impl_decl
  | UseDecl of use_decl
  | ConstDecl of const_decl
  | StaticDecl of static_decl
  | TypeAlias of type_alias_decl
  | ExternBlock of extern_block_decl
  | ModuleDef of module_decl
  | CapabilityDecl of capability_decl
  | EffectDecl of effect_decl
  | RationaleBlock of rationale_decl
  | MacroDecl of macro_decl
  | EditionDecl of edition_decl

and test_decl = { test_name : string; test_body : block_body; test_span : Span.span }

and function_decl = {
  fn_sig : function_sig;
  fn_clauses : function_clause list;
  fn_body : function_body;
  fn_span : Span.span;
}

and function_sig = {
  sig_name : string;
  sig_public : bool;
  sig_async : bool;
  sig_unsafe : bool;
  sig_const : bool;
  sig_pure : bool;
  sig_inline : bool;
  sig_extern : bool;
  sig_type_params : type_param list;
  sig_params : param list;
  sig_return : type_expr option;
  sig_where : where_predicate list;
  sig_span : Span.span;
}

and param = {
  p_name : string;
  p_mutable : bool;
  p_convention : access_convention;
  p_modifier : param_modifier option;
  p_type : type_expr;
  p_default : expr option;
  p_span : Span.span;
}

and param_modifier = ModMut | ModRef | ModRefMut | ModMove | ModOwn

and access_convention = LetAccess | InoutAccess | Sink | Set

and type_param = { tp_name : string; tp_bounds : string list; tp_span : Span.span }

and where_predicate = { wp_type : type_expr; wp_bounds : string list; wp_span : Span.span }

and function_body = FnBlock of block_body | FnExpr of expr | FnSignatureOnly

and function_clause =
  | Requires of requires_clause
  | Effect of effect_clause
  | Budget of budget_clause
  | Contract of contract_clause
  | GuardClause of guard_clause

and requires_clause = { req_capabilities : (string * bool) list; req_span : Span.span }

and effect_clause = {
  eff_name : string;
  eff_type_args : type_expr list;
  eff_span : Span.span;
}

and budget_clause = { bud_entries : (string * string) list; bud_span : Span.span }

and contract_clause = {
  con_kind : contract_kind;
  con_condition : expr;
  con_message : string option;
  con_span : Span.span;
}

and contract_kind = CPre | CPost | CInvariant

and guard_clause = {
  g_condition : expr option;
  g_pattern : pattern option;
  g_value : expr option;
  g_action : guard_action;
  g_span : Span.span;
}

and guard_action =
  | GuardReturn of expr option
  | GuardBreak of string option
  | GuardNext of string option
  | GuardPanic of expr

and struct_decl = {
  s_name : string;
  s_public : bool;
  s_type_params : type_param list;
  s_where : where_predicate list;
  s_fields : field_decl list;
  s_methods : function_decl list;
  s_kind : nominal_kind;
  s_span : Span.span;
}

and nominal_kind = NominalValue | NominalResource

and field_decl = {
  f_name : string;
  f_public : bool;
  f_type : type_expr;
  f_default : expr option;
  f_span : Span.span;
}

and enum_decl = {
  e_name : string;
  e_public : bool;
  e_type_params : type_param list;
  e_where : where_predicate list;
  e_variants : variant_decl list;
  e_span : Span.span;
}

and variant_decl = { v_name : string; v_fields : variant_field list; v_span : Span.span }

and variant_field = { vf_name : string option; vf_type : type_expr; vf_span : Span.span }

and trait_decl = {
  t_name : string;
  t_public : bool;
  t_type_params : type_param list;
  t_supertraits : string list;
  t_where : where_predicate list;
  t_methods : function_decl list;
  t_associated_types : type_alias_decl list;
  t_span : Span.span;
}

and impl_decl = {
  i_type_params : type_param list;
  i_trait_name : string option;
  i_target_type : string;
  i_for_type : type_expr option;
  i_where : where_predicate list;
  i_methods : function_decl list;
  i_associated_types : type_alias_decl list;
  i_consts : const_decl list;
  i_span : Span.span;
}

and use_decl = { u_path : use_path; u_span : Span.span }

and use_path =
  | UseSimple of string list
  | UseAliased of string list * string
  | UseGlob of string list
  | UseGroup of string list * use_item list

and use_item = { ui_name : string; ui_alias : string option; ui_span : Span.span }

and const_decl = {
  c_name : string;
  c_public : bool;
  c_type : type_expr;
  c_value : expr;
  c_span : Span.span;
}

and static_decl = {
  st_name : string;
  st_public : bool;
  st_mutable : bool;
  st_type : type_expr;
  st_value : expr;
  st_span : Span.span;
}

and type_alias_decl = {
  ta_name : string;
  ta_public : bool;
  ta_type_params : type_param list;
  ta_value : type_expr;
  ta_span : Span.span;
}

and extern_block_decl = { ex_abi : string option; ex_items : item list; ex_span : Span.span }

and module_decl = { m_name : string; m_public : bool; m_items : item list option; md_span : Span.span }

and capability_decl = { cap_name : string; cap_implies : string list; cap_span : Span.span }

and effect_decl = {
  ef_name : string;
  ef_type_params : type_param list;
  ef_operations : function_sig list;
  ef_span : Span.span;
}

and rationale_decl = { r_fields : (string * string) list; r_span : Span.span }

and macro_decl = {
  mac_name : string;
  mac_params : (string * string) list;
  mac_body : block_body;
  mac_span : Span.span;
}

and edition_decl = { ed_version : string; ed_items : item list option; ed_span : Span.span }

and attribute = { a_name : string; a_args : attribute_arg list; a_span : Span.span }

and attribute_arg =
  | AttrIdent of string
  | AttrString of string
  | AttrInt of string
  | AttrKeyValue of string * string
  | AttrNested of string * attribute_arg list

and type_expr =
  | Named of string * type_expr list * Span.span
  | AssocBinding of string * type_expr * Span.span
  | ConstExpr of expr * Span.span
  | Never of Span.span
  | TTuple of type_expr list * Span.span
  | Unit of Span.span
  | Ref of type_expr * bool * Span.span
  | RawPtr of type_expr * bool * Span.span
  | FnPtr of type_expr list * type_expr * Span.span
  | TArray of type_expr * expr option * Span.span
  | Slice of type_expr * Span.span
  | SelfType of Span.span
  | DynTrait of type_expr * Span.span
  | ImplTrait of type_expr * Span.span
  | Bounded of type_expr * type_expr list * Span.span
  | Option of type_expr * Span.span
  | Inferred of Span.span

and macro_arg =
  | MacroExpr of expr
  | MacroTokens of string * Span.span

and expr =
  | IntLit of string * Span.span
  | FloatLit of string * Span.span
  | StringLit of string * Span.span
  | CharLit of string * Span.span
  | BoolLit of bool * Span.span
  | Name of string * Span.span
  | Path of string * string * Span.span
  | Array of expr list * Span.span
  | ArrayRepeat of expr * expr * Span.span
  | Tuple of expr list * Span.span
  | StructLit of string * type_expr list * (string * expr) list * expr option * Span.span
  | Block of block_body * Span.span
  | UnsafeBlock of string * block_body * Span.span
  | IfExpr of if_expr
  | Call of expr * type_expr list * call_arg list * Span.span
  | Index of expr * expr * Span.span
  | Range of expr * expr * bool * Span.span
  | MatchExpr of match_expr
  | Cast of expr * type_expr * Span.span
  | TryOp of expr * Span.span
  | Closure of closure_expr
  | Unary of unary_op * expr * Span.span
  | Field of expr * string * Span.span
  | Binary of expr * binary_op * expr * Span.span
  | AwaitExpr of expr * Span.span
  | MacroCall of string * macro_arg list * Span.span
  | Assign of expr * expr * Span.span
  | CompoundAssign of expr * binary_op * expr * Span.span
  | ReturnExpr of expr option * Span.span
  | BreakExpr of expr option * Span.span
  | NextExpr of Span.span
  | ForExpr of for_expr
  | WhileExpr of while_expr
  | LoopExpr of block_body * Span.span
  | HandleExpr of handle_expr
  | UnlessExpr of unless_expr
  | UntilExpr of until_expr
  | TryBlock of try_block
  | ComptimeBlock of block_body * Span.span

and binary_op =
  | BOr | BAnd | BitOr | BitXor | BitAnd | Shl | Shr | Add | Sub | Mul | Div
  | Mod | Eq | NotEq | Lt | LtEq | Gt | GtEq

and unary_op = Not | BitNot | Neg | Deref | Borrow | BorrowMut

and call_arg = { ca_label : string option; ca_value : expr; ca_span : Span.span }

and block_body = { b_stmts : stmt list; b_tail : expr option; b_span : Span.span }

and stmt =
  | LetBinding of pattern * bool * type_expr option * expr * Span.span
  | ExprStmt of expr * Span.span
  | AttributeStmt of attribute list * Span.span
  | Attributed of attribute list * stmt * Span.span
  | DeferStmt of block_body * Span.span
  | Item of item

and if_expr = {
  if_condition : expr;
  if_then : block_body;
  if_elsif : (expr * block_body) list;
  if_else : block_body option;
  if_let_pattern : pattern option;
  if_let_value : expr option;
  if_span : Span.span;
}

and match_expr = { m_subject : expr; m_arms : match_arm list; m_span : Span.span }

and match_arm = { ma_pattern : pattern; ma_guard : expr option; ma_body : expr; ma_span : Span.span }

and for_expr = { for_pattern : pattern; for_iterable : expr; for_body : block_body; for_span : Span.span }

and while_expr = { wh_condition : expr; wh_body : block_body; wh_span : Span.span }

and closure_expr = {
  cl_params : closure_param list;
  cl_return : type_expr option;
  cl_body : expr;
  cl_span : Span.span;
}

and closure_param = { cp_name : string; cp_mutable : bool; cp_type : type_expr option; cp_span : Span.span }

and handle_expr = {
  h_expr : expr;
  h_effect_name : string;
  h_arms : (string * pattern list * expr) list;
  h_span : Span.span;
}

and unless_expr = { un_condition : expr; un_body : block_body; un_else : block_body option; un_span : Span.span }

and until_expr = { ut_condition : expr; ut_body : block_body; ut_span : Span.span }

and try_block = {
  tr_body : block_body;
  tr_catches : (pattern * block_body) list;
  tr_finally : block_body option;
  tr_span : Span.span;
}

and pattern =
  | Wildcard of Span.span
  | PatIdent of string * bool * Span.span
  | RefPattern of string * Span.span
  | RefMutPattern of string * Span.span
  | PatLiteral of expr * Span.span
  | PatVariant of string * string * pattern list * Span.span
  | StructPattern of string * (string * pattern option) list * Span.span
  | PatTuple of pattern list * Span.span
  | OrPattern of pattern * pattern * Span.span
  | RangePattern of pattern * pattern * Span.span

(* ── Accessors ──────────────────────────────────────────────── *)

let expr_span (e : expr) : Span.span =
  match e with
  | IntLit (_, s) | FloatLit (_, s) | StringLit (_, s) | CharLit (_, s)
  | BoolLit (_, s) | Name (_, s) | Path (_, _, s) | Array (_, s)
  | ArrayRepeat (_, _, s) | Tuple (_, s) | StructLit (_, _, _, _, s)
  | Block (_, s) | UnsafeBlock (_, _, s) | Call (_, _, _, s) | Index (_, _, s)
  | Range (_, _, _, s) | Cast (_, _, s) | TryOp (_, s) | Unary (_, _, s)
  | Field (_, _, s) | Binary (_, _, _, s) | AwaitExpr (_, s)
  | MacroCall (_, _, s) | Assign (_, _, s) | CompoundAssign (_, _, _, s)
  | ReturnExpr (_, s) | BreakExpr (_, s) | NextExpr s | LoopExpr (_, s)
  | ComptimeBlock (_, s) -> s
  | IfExpr e -> e.if_span
  | MatchExpr e -> e.m_span
  | Closure e -> e.cl_span
  | ForExpr e -> e.for_span
  | WhileExpr e -> e.wh_span
  | HandleExpr e -> e.h_span
  | UnlessExpr e -> e.un_span
  | UntilExpr e -> e.ut_span
  | TryBlock e -> e.tr_span

let type_span (t : type_expr) : Span.span =
  match t with
  | Named (_, _, s) | AssocBinding (_, _, s) | ConstExpr (_, s) | Never s
  | TTuple (_, s) | Unit s | Ref (_, _, s) | RawPtr (_, _, s)
  | FnPtr (_, _, s) | TArray (_, _, s) | Slice (_, s) | SelfType s
  | DynTrait (_, s) | ImplTrait (_, s) | Bounded (_, _, s) | Option (_, s)
  | Inferred s -> s

let pattern_span (p : pattern) : Span.span =
  match p with
  | Wildcard s | PatIdent (_, _, s) | RefPattern (_, s) | RefMutPattern (_, s)
  | PatLiteral (_, s) | PatVariant (_, _, _, s) | StructPattern (_, _, s)
  | PatTuple (_, s) | OrPattern (_, _, s) | RangePattern (_, _, s) -> s

let rec item_summary (k : item_kind) : string =
  match k with
  | Function d -> "def " ^ d.fn_sig.sig_name
  | TestDecl d -> "test \"" ^ d.test_name ^ "\""
  | StructDef d -> "struct " ^ d.s_name
  | EnumDef d -> "enum " ^ d.e_name
  | TraitDef d -> "trait " ^ d.t_name
  | ImplBlock d -> (
      match d.i_trait_name with
      | Some t -> "impl " ^ t ^ " for " ^ d.i_target_type
      | None -> "impl " ^ d.i_target_type)
  | UseDecl d -> "use " ^ use_path_string d.u_path
  | ConstDecl d -> "const " ^ d.c_name
  | StaticDecl d -> "static " ^ d.st_name
  | TypeAlias d -> "type " ^ d.ta_name
  | ExternBlock _ -> "extern block"
  | ModuleDef d -> "module " ^ d.m_name
  | CapabilityDecl d -> "cap " ^ d.cap_name
  | EffectDecl d -> "effect " ^ d.ef_name
  | RationaleBlock _ -> "rationale"
  | MacroDecl d -> "macro " ^ d.mac_name
  | EditionDecl d -> "edition " ^ d.ed_version

and use_path_string (p : use_path) : string =
  match p with
  | UseSimple segs -> String.concat "::" segs
  | UseAliased (segs, alias) -> String.concat "::" segs ^ " as " ^ alias
  | UseGlob segs -> String.concat "::" segs ^ "::*"
  | UseGroup (segs, items) ->
      let items_str =
        String.concat ", "
          (List.map
             (fun i ->
               match i.ui_alias with
               | Some a -> i.ui_name ^ " as " ^ a
               | None -> i.ui_name)
             items)
      in
      String.concat "::" segs ^ "::" ^ items_str

let qualified_key (module_path : string list) (name : string) : string =
  match module_path with
  | [] -> name
  | segs -> String.concat "::" segs ^ "::" ^ name
