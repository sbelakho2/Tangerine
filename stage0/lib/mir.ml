(** Mid-level Intermediate Representation (MIR) for Tangerine
    
    MIR is a control-flow graph representation suitable for:
    - Borrow checking
    - Optimization passes
    - Code generation
*)

(** Local variable index *)
type local = int
[@@deriving show, eq, ord]

(** Basic block index *)
type block_id = int
[@@deriving show, eq, ord]

(** Constant values *)
type constant =
  | ConstInt of int64
  | ConstFloat of float
  | ConstBool of bool
  | ConstChar of char
  | ConstString of string
  | ConstUnit
[@@deriving show, eq]

(** Places (lvalues) *)
type place = {
  local : local;
  projection : projection list;
}
[@@deriving show, eq]

and projection =
  | ProjField of string            (* .field *)
  | ProjIndex of operand           (* [index] *)
  | ProjDeref                       (* * *)
[@@deriving show, eq]

(** Operands (rvalues that don't consume resources) *)
and operand =
  | OpCopy of place                (* Copy (for Copy types) *)
  | OpMove of place                (* Move (ownership transfer) *)
  | OpConst of constant            (* Constant value *)
[@@deriving show, eq]

(** Binary operators *)
type binop =
  | BinAdd | BinSub | BinMul | BinDiv | BinRem
  | BinEq | BinNe | BinLt | BinGt | BinLe | BinGe
  | BinAnd | BinOr
  | BinBitAnd | BinBitOr | BinBitXor | BinShl | BinShr
[@@deriving show, eq]

(** Unary operators *)
type unop =
  | UnNeg | UnNot | UnBitNot
[@@deriving show, eq]

(** Rvalues (expressions that produce values) *)
type rvalue =
  | RvUse of operand                              (* Just use an operand *)
  | RvBinaryOp of binop * operand * operand       (* Binary operation *)
  | RvUnaryOp of unop * operand                   (* Unary operation *)
  | RvRef of bool * place                         (* &[mut] place *)
  | RvAddrOf of bool * place                      (* &raw [mut] place *)
  | RvLen of place                                (* len(slice) *)
  | RvCast of operand * Types.ty                  (* operand as Type *)
  | RvAggregate of aggregate_kind * operand list  (* Struct/tuple construction *)
  | RvDiscriminant of place                       (* Which variant of enum *)
[@@deriving show, eq]

and aggregate_kind =
  | AggTuple
  | AggArray
  | AggStruct of string
  | AggEnum of string * string  (* enum name, variant name *)
[@@deriving show, eq]

(** Statement (side effect, then continue to next) *)
type statement =
  | StmtAssign of place * rvalue          (* place = rvalue *)
  | StmtSetDiscriminant of place * int    (* Set enum discriminant *)
  | StmtStorageLive of local              (* Local comes into scope *)
  | StmtStorageDead of local              (* Local goes out of scope *)
  | StmtNop                                (* No-op *)
[@@deriving show, eq]

(** Terminator (exits basic block) *)
type terminator =
  | TermGoto of block_id
  | TermSwitch of operand * (constant * block_id) list * block_id  (* branches, otherwise *)
  | TermReturn
  | TermCall of {
      func : operand;
      args : operand list;
      dest : place option;
      target : block_id option;    (* where to go on success *)
      unwind : block_id option;    (* where to go on panic *)
    }
  | TermDrop of place * block_id option * block_id option  (* drop, target, unwind *)
  | TermAssert of operand * bool * string * block_id * block_id option  (* cond, expected, msg, target, cleanup *)
  | TermUnreachable
  | TermResume  (* Resume unwinding *)
[@@deriving show, eq]

(** Basic block *)
type basic_block = {
  bb_statements : statement list;
  bb_terminator : terminator;
}
[@@deriving show, eq]

(** Local variable declaration *)
type local_decl = {
  ld_name : string option;  (* Debug name, if any *)
  ld_ty : Types.ty;
  ld_mutable : bool;
}
[@@deriving show, eq]

(** Function body in MIR *)
type body = {
  (* _0 is return place, _1..n are args, rest are temps *)
  locals : local_decl list;
  arg_count : int;
  blocks : basic_block list;
  (* Source spans for debugging *)
  span : Location.t;
}
[@@deriving show, eq]

(** MIR function *)
type mir_fn = {
  name : string;
  ty_params : string list;
  params : (string * Types.ty) list;
  return_ty : Types.ty;
  body : body option;  (* None for extern/abstract *)
}
[@@deriving show, eq]

(** MIR for a complete module *)
type mir_module = {
  name : string;
  functions : mir_fn list;
  (* We'll add more later: statics, constants, etc. *)
}
[@@deriving show, eq]

(** Pretty printing *)
module Pp = struct
  let pp_local fmt l = Format.fprintf fmt "__%d" l
  
  let rec pp_place fmt p =
    pp_local fmt p.local;
    List.iter (fun proj ->
      match proj with
      | ProjField f -> Format.fprintf fmt ".%s" f
      | ProjIndex op -> Format.fprintf fmt "[%a]" pp_operand op
      | ProjDeref -> Format.fprintf fmt "[*]"
    ) p.projection
  
  and pp_operand fmt = function
    | OpCopy p -> Format.fprintf fmt "copy %a" pp_place p
    | OpMove p -> Format.fprintf fmt "move %a" pp_place p
    | OpConst c -> pp_constant fmt c
  
  and pp_constant fmt = function
    | ConstInt n -> Format.fprintf fmt "%Ld" n
    | ConstFloat f -> Format.fprintf fmt "%f" f
    | ConstBool b -> Format.fprintf fmt "%b" b
    | ConstChar c -> Format.fprintf fmt "'%c'" c
    | ConstString s -> Format.fprintf fmt "\"%s\"" (String.escaped s)
    | ConstUnit -> Format.fprintf fmt "()"
  
  let pp_binop fmt = function
    | BinAdd -> Format.fprintf fmt "+"
    | BinSub -> Format.fprintf fmt "-"
    | BinMul -> Format.fprintf fmt "*"
    | BinDiv -> Format.fprintf fmt "/"
    | BinRem -> Format.fprintf fmt "%%"
    | BinEq -> Format.fprintf fmt "=="
    | BinNe -> Format.fprintf fmt "!="
    | BinLt -> Format.fprintf fmt "<"
    | BinGt -> Format.fprintf fmt ">"
    | BinLe -> Format.fprintf fmt "<="
    | BinGe -> Format.fprintf fmt ">="
    | BinAnd -> Format.fprintf fmt "&&"
    | BinOr -> Format.fprintf fmt "||"
    | BinBitAnd -> Format.fprintf fmt "&"
    | BinBitOr -> Format.fprintf fmt "|"
    | BinBitXor -> Format.fprintf fmt "^"
    | BinShl -> Format.fprintf fmt "<<"
    | BinShr -> Format.fprintf fmt ">>"
  
  let pp_unop fmt = function
    | UnNeg -> Format.fprintf fmt "-"
    | UnNot -> Format.fprintf fmt "!"
    | UnBitNot -> Format.fprintf fmt "~"
  
  let pp_rvalue fmt = function
    | RvUse op -> pp_operand fmt op
    | RvBinaryOp (op, l, r) ->
      Format.fprintf fmt "%a %a %a" pp_operand l pp_binop op pp_operand r
    | RvUnaryOp (op, v) ->
      Format.fprintf fmt "%a%a" pp_unop op pp_operand v
    | RvRef (m, p) ->
      Format.fprintf fmt "&%s%a" (if m then "mut " else "") pp_place p
    | RvAddrOf (m, p) ->
      Format.fprintf fmt "&raw %s%a" (if m then "mut " else "") pp_place p
    | RvLen p ->
      Format.fprintf fmt "len(%a)" pp_place p
    | RvCast (op, ty) ->
      Format.fprintf fmt "%a as %a" pp_operand op Types.pp_ty ty
    | RvAggregate (kind, ops) ->
      begin match kind with
      | AggTuple -> Format.fprintf fmt "(%a)" (Format.pp_print_list ~pp_sep:(fun f () -> Format.fprintf f ", ") pp_operand) ops
      | AggArray -> Format.fprintf fmt "[%a]" (Format.pp_print_list ~pp_sep:(fun f () -> Format.fprintf f ", ") pp_operand) ops
      | AggStruct name -> Format.fprintf fmt "%s { %a }" name (Format.pp_print_list ~pp_sep:(fun f () -> Format.fprintf f ", ") pp_operand) ops
      | AggEnum (e, v) -> Format.fprintf fmt "%s::%s(%a)" e v (Format.pp_print_list ~pp_sep:(fun f () -> Format.fprintf f ", ") pp_operand) ops
      end
    | RvDiscriminant p ->
      Format.fprintf fmt "discriminant(%a)" pp_place p
  
  let pp_statement fmt = function
    | StmtAssign (p, rv) ->
      Format.fprintf fmt "%a = %a" pp_place p pp_rvalue rv
    | StmtSetDiscriminant (p, d) ->
      Format.fprintf fmt "set_discriminant(%a, %d)" pp_place p d
    | StmtStorageLive l ->
      Format.fprintf fmt "storage_live(%a)" pp_local l
    | StmtStorageDead l ->
      Format.fprintf fmt "storage_dead(%a)" pp_local l
    | StmtNop ->
      Format.fprintf fmt "nop"
  
  let pp_terminator fmt = function
    | TermGoto bb ->
      Format.fprintf fmt "goto -> bb%d" bb
    | TermSwitch (op, cases, otherwise) ->
      Format.fprintf fmt "switch %a {" pp_operand op;
      List.iter (fun (c, bb) ->
        Format.fprintf fmt " %a -> bb%d," pp_constant c bb
      ) cases;
      Format.fprintf fmt " otherwise -> bb%d }" otherwise
    | TermReturn ->
      Format.fprintf fmt "return"
    | TermCall { func; args; dest; target; unwind = _ } ->
      Format.fprintf fmt "%a = call %a(%a)"
        (fun fmt dest -> match dest with
          | Some p -> pp_place fmt p
          | None -> Format.fprintf fmt "_") dest
        pp_operand func
        (Format.pp_print_list ~pp_sep:(fun f () -> Format.fprintf f ", ") pp_operand) args;
      begin match target with
      | Some bb -> Format.fprintf fmt " -> bb%d" bb
      | None -> ()
      end
    | TermDrop (p, target, _) ->
      Format.fprintf fmt "drop(%a)" pp_place p;
      begin match target with
      | Some bb -> Format.fprintf fmt " -> bb%d" bb
      | None -> ()
      end
    | TermAssert (cond, expected, msg, target, _) ->
      Format.fprintf fmt "assert(%a, %b, \"%s\") -> bb%d"
        pp_operand cond expected (String.escaped msg) target
    | TermUnreachable ->
      Format.fprintf fmt "unreachable"
    | TermResume ->
      Format.fprintf fmt "resume"
  
  let pp_basic_block fmt (idx, bb) =
    Format.fprintf fmt "bb%d: {\n" idx;
    List.iter (fun stmt ->
      Format.fprintf fmt "    %a;\n" pp_statement stmt
    ) bb.bb_statements;
    Format.fprintf fmt "    %a\n" pp_terminator bb.bb_terminator;
    Format.fprintf fmt "}\n"
  
  let pp_mir_fn fmt fn =
    Format.fprintf fmt "fn %s(" fn.name;
    Format.pp_print_list ~pp_sep:(fun f () -> Format.fprintf f ", ")
      (fun fmt (name, ty) -> Format.fprintf fmt "%s: %a" name Types.pp_ty ty)
      fmt fn.params;
    Format.fprintf fmt ") -> %a {\n" Types.pp_ty fn.return_ty;
    begin match fn.body with
    | Some body ->
      List.iteri (fun i local ->
        let name = match local.ld_name with Some n -> n | None -> "" in
        Format.fprintf fmt "  let %s__%d: %a;\n"
          (if local.ld_mutable then "mut " else "") i Types.pp_ty local.ld_ty;
        ignore name
      ) body.locals;
      Format.fprintf fmt "\n";
      List.iteri (fun i bb ->
        pp_basic_block fmt (i, bb)
      ) body.blocks
    | None ->
      Format.fprintf fmt "  // extern\n"
    end;
    Format.fprintf fmt "}\n\n"
  
  let pp_mir_module fmt m =
    Format.fprintf fmt "// MIR Module: %s\n\n" m.name;
    List.iter (pp_mir_fn fmt) m.functions
end
