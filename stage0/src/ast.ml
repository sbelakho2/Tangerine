(* Tangerine Stage0 Bootstrap Compiler - AST
   Defines the abstract syntax tree for Tangerine *)

type span = {
  file: string;
  start_line: int;
  start_col: int;
  end_line: int;
  end_col: int;
}

let dummy_span = { file = "<unknown>"; start_line = 0; start_col = 0; end_line = 0; end_col = 0 }

(* Current file being parsed - shared between parser and other modules *)
let current_file = ref "<unknown>"

type ident = string

type visibility = Public | Private

type mutability = Mutable | Immutable

(* Type expressions *)
type ty =
  | TyName of ident * ty list          (* Vec[Int], Option[String] *)
  | TyFn of ty list * ty               (* fn(A, B) -> C *)
  | TyTuple of ty list                 (* (A, B, C) *)
  | TyRef of mutability * ty           (* &T, &mut T *)
  | TyOption of ty                     (* ?T sugar for Option[T] *)
  | TyInfer                            (* _ for type inference *)
  | TyNever                            (* ! never type *)
  | TySelf                             (* Self in trait/impl *)

(* Patterns *)
type pattern =
  | PatIdent of mutability * ident * span
  | PatWildcard of span
  | PatTuple of pattern list * span
  | PatStruct of ident * (ident * pattern) list * span
  | PatEnum of ident * ident * pattern list * span  (* Type::Variant(patterns) *)
  | PatLiteral of literal * span
  | PatOr of pattern list * span
  | PatRange of literal * literal * span

and literal =
  | LitInt of int64
  | LitFloat of float
  | LitString of string
  | LitChar of char
  | LitBool of bool

(* Expressions *)
type expr =
  | ExprLiteral of literal * span
  | ExprIdent of ident * span
  | ExprPath of ident list * span           (* std::io::println *)
  | ExprBinary of binop * expr * expr * span
  | ExprUnary of unop * expr * span
  | ExprCall of expr * expr list * span
  | ExprMethodCall of expr * ident * expr list * span
  | ExprIndex of expr * expr * span
  | ExprField of expr * ident * span
  | ExprTupleIndex of expr * int * span
  | ExprStruct of ident * (ident * expr) list * span
  | ExprTuple of expr list * span
  | ExprArray of expr list * span
  | ExprRange of expr option * expr option * span
  | ExprIf of expr * block * (expr * block) list * block option * span
  | ExprMatch of expr * match_arm list * span
  | ExprWhile of expr * block * span
  | ExprFor of pattern * expr * block * span
  | ExprLoop of block * span
  | ExprBlock of block * span
  | ExprReturn of expr option * span
  | ExprBreak of ident option * expr option * span
  | ExprContinue of ident option * span
  | ExprAssign of expr * expr * span
  | ExprCompoundAssign of binop * expr * expr * span
  | ExprClosure of param list * ty option * block * span
  | ExprTry of expr * span                  (* expr? *)
  | ExprAwait of expr * span                (* expr.await *)
  | ExprYield of expr option * span
  | ExprUnsafe of block * span
  | ExprCast of expr * ty * span            (* expr as Type *)

and binop =
  | Add | Sub | Mul | Div | Mod
  | Eq | Ne | Lt | Le | Gt | Ge
  | And | Or
  | BitAnd | BitOr | BitXor | Shl | Shr

and unop =
  | Neg | Not | BitNot | Ref | RefMut | Deref

and block = {
  stmts: stmt list;
  expr: expr option;  (* trailing expression without semicolon *)
  span: span;
}

and stmt =
  | StmtLet of mutability * pattern * ty option * expr option * span
  | StmtExpr of expr * span
  | StmtItem of item * span

and match_arm = {
  pattern: pattern;
  guard: expr option;
  body: expr;
  arm_span: span;
}

and param = {
  param_mut: mutability;
  param_name: ident;
  param_type: ty;
  param_span: span;
}

(* Items (top-level declarations) *)
and item =
  | ItemFn of fn_def
  | ItemStruct of struct_def
  | ItemEnum of enum_def
  | ItemTrait of trait_def
  | ItemImpl of impl_block
  | ItemUse of use_decl
  | ItemConst of const_decl
  | ItemTypeAlias of type_alias
  | ItemModule of module_decl
  | ItemExtern of extern_block

and fn_def = {
  fn_vis: visibility;
  fn_name: ident;
  fn_type_params: type_param list;
  fn_params: param list;
  fn_return_type: ty option;
  fn_where_clause: where_pred list;
  fn_contracts: contract list;
  fn_requires: requires_clause list;
  fn_effects: ident list;
  fn_budget: (ident * int64 * ident) list;  (* resource, amount, unit *)
  fn_body: block option;  (* None for trait methods *)
  fn_span: span;
}

and type_param = {
  tp_name: ident;
  tp_bounds: ident list;
  tp_span: span;
}

and where_pred = {
  wp_type: ty;
  wp_bounds: ident list;
  wp_span: span;
}

and contract =
  | ContractPre of expr * string option * span
  | ContractPost of expr * string option * span
  | ContractInvariant of expr * string option * span

and requires_clause = {
  req_negated: bool;
  req_cap: ident;
  req_span: span;
}

and struct_def = {
  struct_vis: visibility;
  struct_name: ident;
  struct_type_params: type_param list;
  struct_fields: field_def list;
  struct_span: span;
}

and field_def = {
  field_vis: visibility;
  field_name: ident;
  field_type: ty;
  field_span: span;
}

and enum_def = {
  enum_vis: visibility;
  enum_name: ident;
  enum_type_params: type_param list;
  enum_variants: variant_def list;
  enum_span: span;
}

and variant_def = {
  variant_name: ident;
  variant_fields: variant_field list;
  variant_span: span;
}

and variant_field = {
  vf_name: ident option;
  vf_type: ty;
  vf_span: span;
}

and trait_def = {
  trait_vis: visibility;
  trait_name: ident;
  trait_type_params: type_param list;
  trait_super: ident list;
  trait_items: trait_item list;
  trait_span: span;
}

and trait_item =
  | TraitMethod of fn_def
  | TraitType of ident * ident list * span

and impl_block = {
  impl_type_params: type_param list;
  impl_trait: (ident * ty list) option;  (* trait name with type args *)
  impl_for_type: ty;
  impl_where_clause: where_pred list;
  impl_items: impl_item list;
  impl_span: span;
}

and impl_item =
  | ImplMethod of fn_def
  | ImplType of ident * ty * span

and use_decl = {
  use_vis: visibility;
  use_path: ident list;
  use_alias: ident option;
  use_glob: bool;
  use_items: (ident * ident option) list;  (* name, alias *)
  use_span: span;
}

and const_decl = {
  const_vis: visibility;
  const_name: ident;
  const_type: ty;
  const_value: expr;
  const_span: span;
}

and type_alias = {
  alias_vis: visibility;
  alias_name: ident;
  alias_type_params: type_param list;
  alias_type: ty;
  alias_span: span;
}

and module_decl = {
  mod_vis: visibility;
  mod_name: ident;
  mod_items: item list option;  (* None for external module *)
  mod_span: span;
}

and extern_block = {
  extern_abi: string option;
  extern_items: extern_item list;
  extern_span: span;
}

and extern_item =
  | ExternFn of fn_def
  | ExternStatic of visibility * mutability * ident * ty * span

(* Program = list of items *)
type program = {
  items: item list;
  file: string;
}

(* Pretty printing for debugging *)
let rec ty_to_string = function
  | TyName (name, []) -> name
  | TyName (name, args) -> 
      name ^ "[" ^ String.concat ", " (List.map ty_to_string args) ^ "]"
  | TyFn (params, ret) ->
      "fn(" ^ String.concat ", " (List.map ty_to_string params) ^ ") -> " ^ ty_to_string ret
  | TyTuple tys -> "(" ^ String.concat ", " (List.map ty_to_string tys) ^ ")"
  | TyRef (Immutable, ty) -> "&" ^ ty_to_string ty
  | TyRef (Mutable, ty) -> "&mut " ^ ty_to_string ty
  | TyOption ty -> "?" ^ ty_to_string ty
  | TyInfer -> "_"
  | TyNever -> "!"
  | TySelf -> "Self"

let span_to_string (s: span) =
  Printf.sprintf "%s:%d:%d" s.file s.start_line s.start_col
