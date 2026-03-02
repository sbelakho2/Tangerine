(** Abstract Syntax Tree for Tangerine *)

(** Identifiers with location *)
type ident = {
  name : string;
  loc : Location.t;
}
[@@deriving show, eq]

(** Visibility modifier *)
type visibility =
  | Public
  | Private
[@@deriving show, eq]

(** Mutability *)
type mutability =
  | Immutable
  | Mutable
[@@deriving show, eq]

(** Integer literal base *)
type int_base =
  | Dec
  | Hex
  | Bin
  | Oct
[@@deriving show, eq]

(** Literal values *)
type literal =
  | LitInt of int64 * int_base
  | LitFloat of float
  | LitString of string
  | LitChar of char
  | LitBool of bool
  | LitUnit
[@@deriving show, eq]

(** Binary operators *)
type binop =
  (* Arithmetic *)
  | OpAdd | OpSub | OpMul | OpDiv | OpMod
  (* Comparison *)
  | OpEq | OpNe | OpLt | OpGt | OpLe | OpGe
  (* Logical *)
  | OpAnd | OpOr
  (* Bitwise *)
  | OpBitAnd | OpBitOr | OpBitXor | OpShl | OpShr
  (* Assignment (in expressions) *)
  | OpAssign | OpAddAssign | OpSubAssign | OpMulAssign | OpDivAssign | OpModAssign
  (* Range *)
  | OpRange | OpRangeInclusive
[@@deriving show, eq]

(** Unary operators *)
type unop =
  | OpNeg    (* - *)
  | OpNot    (* ! *)
  | OpRef    (* & *)
  | OpRefMut (* &mut *)
  | OpDeref  (* * *)
[@@deriving show, eq]

(** Type expressions *)
type type_expr = {
  ty_desc : type_desc;
  ty_loc : Location.t;
}
[@@deriving show, eq]

and type_desc =
  | TyName of path * type_expr list              (* Named type possibly with type args *)
  | TyTuple of type_expr list                    (* Tuple type *)
  | TyUnit                                        (* Unit type () *)
  | TyRef of mutability * type_expr              (* &T or &mut T *)
  | TyPtr of mutability * type_expr              (* *T or *mut T *)
  | TyArray of type_expr * expr                  (* [T; N] *)
  | TySlice of type_expr                          (* [T] *)
  | TyFn of type_expr list * type_expr           (* fn(T1, T2) -> R *)
  | TyOption of type_expr                         (* T? shorthand *)
  | TySelf                                        (* Self *)
  | TyInfer                                       (* _ for inference *)
[@@deriving show, eq]

(** Path expression (e.g., std::collections::Vec) *)
and path = {
  segments : ident list;
  path_loc : Location.t;
}
[@@deriving show, eq]

(** Pattern for matching *)
and pattern = {
  pat_desc : pattern_desc;
  pat_loc : Location.t;
}
[@@deriving show, eq]

and pattern_desc =
  | PatWildcard                                    (* _ *)
  | PatIdent of mutability * ident                (* x or mut x *)
  | PatRef of mutability * pattern                (* ref x or ref mut x *)
  | PatLiteral of literal                         (* literal patterns *)
  | PatTuple of pattern list                      (* (p1, p2, ...) *)
  | PatStruct of path * field_pattern list        (* Point { x, y } *)
  | PatEnum of path * pattern list option         (* Color::RGB(r, g, b) *)
  | PatOr of pattern * pattern                    (* p1 | p2 *)
  | PatRange of literal * literal                 (* 1..10 *)
[@@deriving show, eq]

and field_pattern = {
  fp_name : ident;
  fp_pattern : pattern option;  (* None for shorthand `x` instead of `x: x` *)
  fp_loc : Location.t;
}
[@@deriving show, eq]

(** Expression *)
and expr = {
  expr_desc : expr_desc;
  expr_loc : Location.t;
}
[@@deriving show, eq]

and expr_desc =
  (* Literals *)
  | ExprLit of literal
  (* Variables and paths *)
  | ExprPath of path
  (* Operations *)
  | ExprBinop of binop * expr * expr
  | ExprUnop of unop * expr
  (* Control flow *)
  | ExprIf of expr * block * elsif list * block option
  | ExprMatch of expr * match_arm list
  | ExprWhile of expr * block
  | ExprFor of ident * expr * block
  | ExprLoop of block
  (* Blocks and closures *)
  | ExprBlock of block
  | ExprClosure of closure_param list * type_expr option * expr
  (* Function/method calls *)
  | ExprCall of expr * expr list
  | ExprMethodCall of expr * ident * type_expr list * expr list
  (* Field/index access *)
  | ExprField of expr * ident
  | ExprIndex of expr * expr
  (* Constructors *)
  | ExprStruct of path * field_init list
  | ExprTuple of expr list
  | ExprArray of expr list
  (* Special expressions *)
  | ExprReturn of expr option
  | ExprBreak of expr option
  | ExprNext
  | ExprTry of expr                               (* expr? *)
  | ExprCast of expr * type_expr                  (* expr as Type *)
  | ExprRange of expr option * expr option * bool (* a..b or a..=b *)
  (* Handle expression for effects *)
  | ExprHandle of expr * ident * handler_arm list
  (* Try/catch/finally *)
  | ExprTryCatch of block * catch_arm list * block option
  (* Macro invocation *)
  | ExprMacro of ident * expr list
  (* Unsafe block *)
  | ExprUnsafe of string option * block
[@@deriving show, eq]

and elsif = {
  elsif_cond : expr;
  elsif_body : block;
  elsif_loc : Location.t;
}
[@@deriving show, eq]

and match_arm = {
  arm_pattern : pattern;
  arm_guard : expr option;
  arm_body : expr;
  arm_loc : Location.t;
}
[@@deriving show, eq]

and handler_arm = {
  handler_name : ident;
  handler_params : pattern list;
  handler_body : expr;
  handler_loc : Location.t;
}
[@@deriving show, eq]

and catch_arm = {
  catch_pattern : pattern;
  catch_body : block;
  catch_loc : Location.t;
}
[@@deriving show, eq]

and field_init = {
  fi_name : ident;
  fi_value : expr option;  (* None for shorthand `x` instead of `x: x` *)
  fi_loc : Location.t;
}
[@@deriving show, eq]

and closure_param = {
  cp_mut : mutability;
  cp_name : ident;
  cp_type : type_expr option;
}
[@@deriving show, eq]

(** Block (sequence of statements with optional trailing expression) *)
and block = {
  block_stmts : stmt list;
  block_expr : expr option;
  block_loc : Location.t;
}
[@@deriving show, eq]

(** Statement *)
and stmt = {
  stmt_desc : stmt_desc;
  stmt_loc : Location.t;
}
[@@deriving show, eq]

and stmt_desc =
  | StmtLet of mutability * pattern * type_expr option * expr
  | StmtExpr of expr
  | StmtItem of item
[@@deriving show, eq]

(** Type parameter *)
and type_param = {
  tp_name : ident;
  tp_bounds : path list;
  tp_loc : Location.t;
}
[@@deriving show, eq]

(** Where predicate *)
and where_pred = {
  wp_type : type_expr;
  wp_bounds : path list;
  wp_loc : Location.t;
}
[@@deriving show, eq]

(** Function parameter *)
and param = {
  param_mut : mutability;
  param_name : ident;
  param_type : type_expr;
  param_loc : Location.t;
}
[@@deriving show, eq]

(** Contract clause *)
and contract = {
  contract_kind : contract_kind;
  contract_expr : expr;
  contract_msg : string option;
  contract_loc : Location.t;
}
[@@deriving show, eq]

and contract_kind =
  | Pre
  | Post
  | Invariant
[@@deriving show, eq]

(** Guard clause *)
and guard_clause = {
  guard_cond : guard_cond;
  guard_action : guard_action;
  guard_loc : Location.t;
}
[@@deriving show, eq]

and guard_cond =
  | GuardExpr of expr
  | GuardLet of pattern * expr
[@@deriving show, eq]

and guard_action =
  | GuardReturn of expr option
  | GuardBreak of ident option
  | GuardNext of ident option
  | GuardPanic of expr
[@@deriving show, eq]

(** Budget entry *)
and budget_entry = {
  budget_name : ident;
  budget_amount : budget_amount;
  budget_loc : Location.t;
}
[@@deriving show, eq]

and budget_amount =
  | BudgetInt of int64 * ident option   (* 1000 or 1000 KB *)
  | BudgetString of string
[@@deriving show, eq]

(** Function definition *)
and func_def = {
  fn_vis : visibility;
  fn_name : ident;
  fn_type_params : type_param list;
  fn_params : param list;
  fn_return : type_expr option;
  fn_where : where_pred list;
  fn_requires : requires_item list;
  fn_effects : (ident * type_expr list) list;
  fn_budgets : budget_entry list;
  fn_contracts : contract list;
  fn_guards : guard_clause list;
  fn_body : func_body;
  fn_pure : bool;
  fn_inline : bool;
  fn_async : bool;
  fn_loc : Location.t;
}
[@@deriving show, eq]

and requires_item = {
  req_negated : bool;
  req_name : ident;
  req_loc : Location.t;
}
[@@deriving show, eq]

and func_body =
  | FnBlock of block
  | FnExpr of expr
  | FnSig                              (* function signature only, no body *)
[@@deriving show, eq]

(** Struct field definition *)
and field_def = {
  field_vis : visibility;
  field_name : ident;
  field_type : type_expr;
  field_loc : Location.t;
}
[@@deriving show, eq]

(** Struct definition *)
and struct_def = {
  struct_vis : visibility;
  struct_name : ident;
  struct_type_params : type_param list;
  struct_fields : field_def list;
  struct_invariants : contract list;
  struct_loc : Location.t;
}
[@@deriving show, eq]

(** Enum variant *)
and variant_def = {
  variant_name : ident;
  variant_fields : variant_fields;
  variant_loc : Location.t;
}
[@@deriving show, eq]

and variant_fields =
  | VariantUnit                          (* No fields *)
  | VariantTuple of type_expr list       (* RGB(Int, Int, Int) *)
  | VariantStruct of field_def list      (* Named { x: Int, y: Int } *)
[@@deriving show, eq]

(** Enum definition *)
and enum_def = {
  enum_vis : visibility;
  enum_name : ident;
  enum_type_params : type_param list;
  enum_variants : variant_def list;
  enum_loc : Location.t;
}
[@@deriving show, eq]

(** Trait item *)
and trait_item =
  | TraitFn of func_def
[@@deriving show, eq]

(** Trait definition *)
and trait_def = {
  trait_vis : visibility;
  trait_name : ident;
  trait_type_params : type_param list;
  trait_super : path list;
  trait_items : trait_item list;
  trait_loc : Location.t;
}
[@@deriving show, eq]

(** Impl block *)
and impl_def = {
  impl_type_params : type_param list;
  impl_trait : path option;
  impl_for_type : type_expr;
  impl_where : where_pred list;
  impl_items : func_def list;
  impl_loc : Location.t;
}
[@@deriving show, eq]

(** Use declaration *)
and use_tree =
  | UsePath of ident list                  (* use std::io *)
  | UseGlob of ident list                  (* use std::io::* *)
  | UseGroup of ident list * use_item list (* use std::io::{Read, Write} *)
[@@deriving show, eq]

and use_item = {
  use_name : ident;
  use_alias : ident option;
}
[@@deriving show, eq]

and use_decl = {
  use_tree : use_tree;
  use_loc : Location.t;
}
[@@deriving show, eq]

(** Const declaration *)
and const_decl = {
  const_vis : visibility;
  const_name : ident;
  const_type : type_expr;
  const_value : expr;
  const_loc : Location.t;
}
[@@deriving show, eq]

(** Type alias *)
and type_alias = {
  alias_vis : visibility;
  alias_name : ident;
  alias_type_params : type_param list;
  alias_type : type_expr;
  alias_loc : Location.t;
}
[@@deriving show, eq]

(** Extern function signature *)
and extern_fn = {
  extern_name : ident;
  extern_type_params : type_param list;
  extern_params : param list;
  extern_return : type_expr option;
  extern_loc : Location.t;
}
[@@deriving show, eq]

(** Extern block *)
and extern_block = {
  extern_abi : string option;
  extern_fns : extern_fn list;
  extern_loc : Location.t;
}
[@@deriving show, eq]

(** Module definition *)
and module_def = {
  mod_vis : visibility;
  mod_name : ident;
  mod_items : item list option;   (* None for file-based module *)
  mod_loc : Location.t;
}
[@@deriving show, eq]

(** Capability declaration *)
and cap_decl = {
  cap_name : ident;
  cap_implies : ident list;
  cap_loc : Location.t;
}
[@@deriving show, eq]

(** Effect operation signature *)
and effect_op = {
  eop_name : ident;
  eop_params : param list;
  eop_return : type_expr option;
  eop_loc : Location.t;
}
[@@deriving show, eq]

(** Effect declaration *)
and effect_decl = {
  effect_name : ident;
  effect_type_params : type_param list;
  effect_ops : effect_op list;
  effect_loc : Location.t;
}
[@@deriving show, eq]

(** Rationale block *)
and rationale_field = {
  rat_name : ident;
  rat_value : rationale_value;
  rat_loc : Location.t;
}
[@@deriving show, eq]

and rationale_value =
  | RatString of string
  | RatExpr of expr
[@@deriving show, eq]

and rationale_block = {
  rationale_fields : rationale_field list;
  rationale_loc : Location.t;
}
[@@deriving show, eq]

(** Macro definition *)
and macro_def = {
  macro_name : ident;
  macro_params : macro_param list;
  macro_body : block;
  macro_loc : Location.t;
}
[@@deriving show, eq]

and macro_param = {
  mp_name : ident;
  mp_type : macro_type;
}
[@@deriving show, eq]

and macro_type =
  | MacroExpr
  | MacroIdent
  | MacroType
  | MacroBlock
  | MacroPattern
[@@deriving show, eq]

(** Attribute *)
and attribute = {
  attr_name : ident;
  attr_args : attr_arg list;
  attr_loc : Location.t;
}
[@@deriving show, eq]

and attr_arg =
  | AttrLit of literal
  | AttrIdent of ident
  | AttrKeyValue of ident * literal
[@@deriving show, eq]

(** Top-level item *)
and item = {
  item_attrs : attribute list;
  item_desc : item_desc;
  item_loc : Location.t;
}
[@@deriving show, eq]

and item_desc =
  | ItemFn of func_def
  | ItemStruct of struct_def
  | ItemEnum of enum_def
  | ItemTrait of trait_def
  | ItemImpl of impl_def
  | ItemUse of use_decl
  | ItemConst of const_decl
  | ItemTypeAlias of type_alias
  | ItemExtern of extern_block
  | ItemModule of module_def
  | ItemCap of cap_decl
  | ItemEffect of effect_decl
  | ItemRationale of rationale_block
  | ItemMacro of macro_def
[@@deriving show, eq]

(** Program (compilation unit) *)
type program = {
  prog_edition : int option;
  prog_items : item list;
  prog_loc : Location.t;
}
[@@deriving show, eq]

(** Smart constructors *)

let mk_ident ?(loc = Location.dummy) name =
  { name; loc }

let mk_path ?(loc = Location.dummy) segments =
  { segments; path_loc = loc }

let mk_type_expr ?(loc = Location.dummy) desc =
  { ty_desc = desc; ty_loc = loc }

let mk_expr ?(loc = Location.dummy) desc =
  { expr_desc = desc; expr_loc = loc }

let mk_pattern ?(loc = Location.dummy) desc =
  { pat_desc = desc; pat_loc = loc }

let mk_stmt ?(loc = Location.dummy) desc =
  { stmt_desc = desc; stmt_loc = loc }

let mk_block ?(loc = Location.dummy) ?(expr = None) stmts =
  { block_stmts = stmts; block_expr = expr; block_loc = loc }
