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
  | TyInfer

(* ── Operators ─────────────────────────────────────────────────────── *)

type binop =
  | Add | Sub | Mul | Div | Mod
  | Eq | Neq | Lt | Gt | Le | Ge
  | And | Or
  | BitAnd | BitOr | BitXor | Shl | Shr

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
  | EReturn of expr option * loc
  | EBreak of expr option * loc
  | ENext of loc
  | EAssign of expr * expr * loc
  | EClosure of cparam list * typ option * expr * loc
  | ECast of expr * typ * loc
  | ERange of expr * expr * bool * loc

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

(* ── Statements ────────────────────────────────────────────────────── *)

and stmt =
  | SLet of { mut : bool; name : string; typ : typ option; value : expr; loc : loc }
  | SExpr of expr

(* ── Declarations / items ─────────────────────────────────────────── *)

type param = { p_name : string; p_typ : typ; p_mut : bool; p_default : expr option }

type field_def = { fd_name : string; fd_typ : typ; fd_pub : bool }

type variant_def = { vd_name : string; vd_fields : typ list }

type fn_sig = { fs_name : string; fs_params : param list; fs_ret : typ option }

type item =
  | IFn of {
      pub : bool;
      name : string;
      params : param list;
      ret : typ option;
      body : stmt list;
      loc : loc;
    }
  | IStruct of {
      pub : bool;
      name : string;
      fields : field_def list;
      loc : loc;
    }
  | IEnum of {
      pub : bool;
      name : string;
      variants : variant_def list;
      loc : loc;
    }
  | ITrait of {
      pub : bool;
      name : string;
      items : item list;
      loc : loc;
    }
  | IImpl of {
      target : typ;
      trait_ : string option;
      methods : item list;
      loc : loc;
    }
  | IUse of { path : string list; loc : loc }
  | IConst of { name : string; typ : typ option; value : expr; loc : loc }
  | ITypeAlias of { name : string; typ : typ; loc : loc }
  | IExtern of { abi : string option; sigs : fn_sig list; loc : loc }
  | IModule of { pub : bool; name : string; items : item list; loc : loc }

type program = { items : item list }
