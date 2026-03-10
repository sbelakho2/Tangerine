type type_expr =
  | TInt
  | TBool
  | TUnit
  | TFloat
  | TString
  | TChar
  | TNamed of string

module Expr = struct
  type t =
    | Unit
    | Int of int64
    | Float of string
    | Bool of bool
    | String of string
    | Char of string
    | Var of string
    | Variant of string * string * t list
    | StructLit of string * (string * t) list
    | Binary of string * t * t
    | Unary of string * t
    | Call of t * t list
    | MethodCall of t * string * t list
    | FieldAccess of t * string
    | Cast of t * type_expr
    | Try of t
    | If of t * block * block option
    | Match of t * match_arm list
    | Lambda of string list * t  (* closure: |params| body *)

  and assign_target =
    | TargetVar of string
    | TargetField of t * string

  and match_arm =
    { pattern : pattern
    ; body : block
    }

  and pattern =
    | PVariant of string * string * pattern list
    | PInt of int64
    | PBool of bool
    | PString of string
    | PChar of string
    | PVar of string
    | PWildcard

  and stmt =
    | Let of string * bool * t
    | LetTuple of string list * bool * t
    | Assign of assign_target * t
    | While of t * block
    | For of string * t * t * block
    | Return of t option
    | Expr of t

  and block = stmt list
end

type param =
  { name : string
  ; ty : type_expr option
  }

type function_decl =
  { name : string
  ; method_of : string option
  ; params : param list
  ; ret_type : type_expr option
  ; body : Expr.block
  }

type enum_variant =
  { name : string
  ; payload : type_expr list
  }

type enum_decl =
  { name : string
  ; variants : enum_variant list
  }

type struct_field =
  { name : string
  ; ty : type_expr
  }

type struct_decl =
  { name : string
  ; fields : struct_field list
  }

type trait_decl =
  { name : string
  }

type const_decl =
  { name : string
  ; ty : type_expr option
  ; value : Expr.t
  }

type global_decl =
  { name : string
  ; is_mutable : bool
  ; ty : type_expr option
  ; value : Expr.t
  }

type item =
  | Function of function_decl
  | Enum of enum_decl
  | Struct of struct_decl
  | Trait of trait_decl
  | Const of const_decl
  | Global of global_decl
  | Ignored

type program = item list
