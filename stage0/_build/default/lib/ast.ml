(* Tangerine Abstract Syntax Tree – stage0 *)

type loc = { file : string; line : int; col : int }

let no_loc = { file = "<none>"; line = 0; col = 0 }

(* ── Types ─────────────────────────────────────────────────────────── *)

type typ =
  | TyName of string * typ list
  | TyTuple of typ list
  | TyRef of bool * typ
  | TyFn of typ list * typ
  | TySelf
  | TyOption of typ
  | TyArray of typ * int option
  | TyInfer

(* ── Visibility ─────────────────────────────────────────────────────── *)

type visibility =
  | Private
  | Public
  | PubCrate
  | PubSuper
  | PubIn of string

(* ── Attributes / annotations ──────────────────────────────────────── *)

type attribute = {
  attr_name : string;
  attr_args : string list;
  attr_loc : loc;
}

(* ── Operators ─────────────────────────────────────────────────────── *)

type binop =
  | Add | Sub | Mul | Div | Mod
  | Eq | Neq | Lt | Gt | Le | Ge
  | And | Or
  | BitAnd | BitOr | BitXor | Shl | Shr
  | Concat

type unop = Neg | Not | AddrOf | AddrMut | Deref

(* ── Expressions ───────────────────────────────────────────────────── *)

type expr =
  | EInt of int * loc
  | EFloat of float * loc
  | EStr of string * loc
  | EChar of string * loc
  | EBool of bool * loc
  | ENil of loc
  | EIdent of string * loc
  | EBinOp of binop * expr * expr * loc
  | EUnOp of unop * expr * loc
  | ECall of expr * expr list * loc
  | EMethodCall of expr * string * expr list * loc
  | EFieldAccess of expr * string * loc
  | EIndex of expr * expr * loc
  | EStructLit of string * (string * expr) list * loc
  | ETuple of expr list * loc
  | EArray of expr list * loc
  | EIf of if_branch list * stmt list option * loc
  | EMatch of expr * match_arm list * loc
  | EWhile of expr * stmt list * loc
  | EFor of string * expr * stmt list * loc
  | ELoop of stmt list * loc
  | EBlock of stmt list * loc
  | EUnsafe of string option * stmt list * loc
  | EReturn of expr option * loc
  | EBreak of expr option * loc
  | ENext of loc
  | EAssign of expr * expr * loc
  | EClosure of cparam list * typ option * expr * loc
  | ECast of expr * typ * loc
  | ERange of expr * expr * bool * loc
  | EAwait of expr * loc
  | EAsync of stmt list * loc
  | ETry of expr * loc

and if_branch = { cond : expr; body : stmt list }

and match_arm = { pat : pattern; guard : expr option; arm_body : stmt list }

and cparam = { cp_name : string; cp_typ : typ option; cp_mut : bool }

(* ── Patterns ──────────────────────────────────────────────────────── *)

and pattern =
  | PatWild of loc
  | PatBind of string * loc
  | PatMut of string * loc
  | PatLit of expr
  | PatVariant of string * pattern list * loc
  | PatStruct of string * (string * pattern option) list * loc
  | PatTuple of pattern list * loc
  | PatOr of pattern * pattern * loc
  | PatSlice of pattern list * loc
  | PatRange of pattern * pattern * bool * loc  (* lo, hi, inclusive, loc *)
  | PatRest of loc  (* the '..' element inside slice/struct patterns *)

(* ── Statements ────────────────────────────────────────────────────── *)

and stmt =
  | SLet of { mut : bool; name : string; typ : typ option; value : expr; loc : loc }
  | SExpr of expr

(* ── Declarations / items ─────────────────────────────────────────── *)

type param = { p_name : string; p_typ : typ; p_mut : bool; p_default : expr option }

type field_def = { fd_name : string; fd_typ : typ; fd_pub : bool }

type variant_def = { vd_name : string; vd_fields : typ list; vd_field_names : string list }

type fn_sig = { fs_name : string; fs_params : param list; fs_ret : typ option }

type where_bound = { wb_param : string; wb_bounds : string list }

type use_kind = UseSimple | UseGlob | UseMulti of string list

type item =
  | IFn of {
      vis : visibility;
      name : string;
      type_params : string list;
      params : param list;
      ret : typ option;
      body : stmt list;
      is_async : bool;
      where_clauses : where_bound list;
      attrs : attribute list;
      loc : loc;
    }
  | IStruct of {
      vis : visibility;
      name : string;
      type_params : string list;
      fields : field_def list;
      where_clauses : where_bound list;
      attrs : attribute list;
      loc : loc;
    }
  | IEnum of {
      vis : visibility;
      name : string;
      type_params : string list;
      variants : variant_def list;
      attrs : attribute list;
      loc : loc;
    }
  | ITrait of {
      vis : visibility;
      name : string;
      type_params : string list;
      supers : string list;
      items : item list;
      where_clauses : where_bound list;
      attrs : attribute list;
      loc : loc;
    }
  | IImpl of {
      target : typ;
      trait_ : string option;
      type_params : string list;
      methods : item list;
      where_clauses : where_bound list;
      attrs : attribute list;
      loc : loc;
    }
  | IUse of { path : string list; use_kind : use_kind; alias : string option; loc : loc }
  | IConst of { name : string; typ : typ option; value : expr; loc : loc }
  | ITypeAlias of { name : string; type_params : string list; typ : typ; loc : loc }
  (* abi: None = default, Some "C" = C ABI, Some "stdcall" = stdcall, etc.
     Supported ABI values: "C", "stdcall", "fastcall", "system", "Tangerine" *)
  | IExtern of { abi : string option; sigs : fn_sig list; loc : loc }
  | IModule of { vis : visibility; name : string; items : item list; attrs : attribute list; loc : loc }

type program = { items : item list }

(* ── Match exhaustiveness helpers ─────────────────────────────────── *)

(** Returns true if a pattern is a wildcard or catch-all *)
let rec is_catch_all = function
  | PatWild _ | PatBind _ | PatMut _ -> true
  | PatOr (a, b, _) -> is_catch_all a || is_catch_all b
  | _ -> false

(** Returns true if the arm list contains a wildcard or catch-all binding pattern *)
let has_wildcard_arm arms =
  List.exists (fun arm -> is_catch_all arm.pat) arms

(** Recursively extract all variant names covered by a pattern *)
let rec variants_of_pattern = function
  | PatVariant (name, _, _) -> [name]
  | PatOr (a, b, _) -> variants_of_pattern a @ variants_of_pattern b
  | PatTuple (pats, _) ->
    List.concat_map variants_of_pattern pats
  | _ -> []

(** Returns the set of variant names covered by the match arms *)
let covered_variants arms =
  List.fold_left (fun acc arm ->
    variants_of_pattern arm.pat @ acc
  ) [] arms

(** Check if a match expression is trivially non-exhaustive.
    Returns Some missing_info if gaps are detected, None if ok.
    For full check, the caller must supply the variant list. *)
let check_match_coverage ~variant_names arms =
  if has_wildcard_arm arms then None
  else
    let covered = covered_variants arms in
    let missing = List.filter (fun v -> not (List.mem v covered)) variant_names in
    if missing = [] then None
    else Some missing
