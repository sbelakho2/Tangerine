(* seed_mir.ml — Concrete Seed MIR (audit §33).

   The post-monomorphization MIR of the OCaml bootstrap seed.  The module
   is deliberately concrete: there is no Unknown, no string-keyed callee
   and no name-based dispatch.  Strong semantic IDs (Ids) are used
   everywhere; the Seed VM executes IDs and concrete types, never strings.

   ────────────────────────────────────────────────────────────────────────
   Type-definition contract (program.types)

   Each entry maps a Named Type_id to its definition shape.  Entries are
   concrete (post-mono): they never contain Type_param.

   - a struct is recorded as `Tuple` of its field types (declaration
     order); a Field projection's Field_id is the declaration-order index
     of the field in the owner def — the "field owner matches the def"
     rule is index-in-bounds over the projected base's def;
   - an enum is recorded as `Function` whose return type is `Never` and
     whose parameter list is the variant payloads (declaration order; a
     payload is `Tuple` for multi-field variants and `Unit` for none).
     Discriminants ARE the variant indices (0-based declaration order) —
     the seed model collapses the reference's explicit discriminant table;
   - a closure object is recorded as
     `Tuple [Function (ptys, ret); Tuple (env types)]` — the code pointer
     first, the capture tuple second.  ClosureAgg (inst, env_ops) builds a
     value of this shape.

   Local convention (canonical): Local 0 is the RETURN SLOT, holding the
   function's return type (the reference's "_ret" convention);
   parameters occupy locals 1..n — local _(i+1) is the type slot of
   parameter i.  A function always has at least one local.

   Block convention: block ids are unique per function; the blocks array
   is indexed by block id — ids must be exactly 0..n-1 and the array
   position equals the id.  The verifier enforces this invariant: the
   blocks array length equals the max id+1 and every id 0..n-1 is
   present exactly once.

   Drop/Deinit payload: (place, continuation block, unwind block) — the
   int is the continuation target exactly like a Call's success block;
   the drop-glue function is implied by the destroyed place's concrete
   type (the Seed VM resolves it), never named here.  Intrinsic/Extern
   callee payloads are registry indices owned by the Seed VM layer; they
   are opaque to this module. *)

(* The typed-bitvector integer authority (audit §38). *)
type int_value = Int_value.t

type constant =
  | Unit
  | Bool of bool
  | Integer of int_value
  | Float32 of int32
  | Float64 of int64
  | Char of Uchar.t
  | String of string
  | Function of Instance_id.t

type projection =
  | Deref
  | Field of Ids.Field_index.t
  | Index of int            (* dynamic-index form: the payload is the LOCAL
                               whose value is the runtime index *)
  | ConstantIndex of int
  | Downcast of Ids.Variant_index.t

type place = { local : int; projections : projection list }

type operand =
  | Copy of place
  | Move of place
  | Read of place
  | Consume of place
  | Constant of constant

type callee =
  | User of Instance_id.t
  | Intrinsic of int
  | Extern of int

(* NOTE: the audit contract spells the access-effect field `effect`; OCaml
   5.4 reserves `effect` as a keyword, so the field is spelled `effect_`. *)

type call_arg = { effect_ : Access_effect.read_effect; value : operand }

type bin_op =
  | Add | Sub | Mul | Div | Rem
  | Eq | Ne | Lt | Le | Gt | Ge
  | And | Or
  | BitAnd | BitOr | BitXor | Shl | Shr

type un_op = Neg | Not

type aggregate_kind =
  | TupleAgg
  | ArrayAgg
  | StructCtor of Ids.Type_id.t * Ids.Field_index.t array
  | EnumCtor of Ids.Type_id.t * Ids.Variant_index.t
  | ClosureAgg of Instance_id.t

type rvalue =
  | Use of operand
  | Ref of place
  | RefMut of place
  | Aggregate of aggregate_kind * operand list
  | BinaryOp of bin_op * operand * operand
  | UnaryOp of un_op * operand
  | Discriminant of place
  | Len of place
  | Cast of operand * Type_repr.t

type statement =
  | Assign of place * rvalue
  | StorageLive of int
  | StorageDead of int
  | SetDiscriminant of place * Ids.Variant_index.t
  | Nop

type terminator =
  | Goto of int
  | Ret
  | SwitchInt of operand * (int64 * int) list * int
  | Call of place * callee * call_arg array * int * int option
  | Drop of place * int * int option
  | Deinit of place * int * int option
  | Assert of operand * bool * string * int
  | Unreachable
  | Abort

type block = {
  id : int;
  statements : statement list;
  terminator : terminator;
}

type function_ = {
  name : string;
  instance : Instance_id.t;
  params : Type_repr.param_type array;
  locals : Type_repr.t array;
  blocks : block array;
  entry : int;
}

(* ── Type definitions ────────────────────────────────────────────────
   program.types holds explicit definitions (audit): a struct is a
   StructDef whose fields carry the semantic Field_id, the local
   Field_index and the field type; an enum is an EnumDef whose variants
   carry the semantic Variant_id, the declaration-order Variant_index
   and the payload type (Tuple for multi-field payloads, Unit for none).
   def_repr reconstructs the historical Type_repr encoding (Tuple for
   structs, Function(payloads, Never) for enums) so type-shape checks
   that consumed the old encoding keep their semantics. *)

type field_def = {
  fd_id : Ids.Field_id.t;        (* semantic field identity *)
  fd_index : Ids.Field_index.t;  (* declaration-order position within the owner def *)
  fd_ty : Type_repr.t;
}

type variant_def = {
  vd_id : Ids.Variant_id.t;      (* semantic variant identity *)
  vd_index : Ids.Variant_index.t; (* declaration-order tag = discriminant *)
  vd_payload : Type_repr.t;      (* Tuple of payload types; Unit when none *)
}

type type_def =
  | StructDef of { sd_id : Ids.Type_id.t; sd_fields : field_def list }
  | EnumDef of { ed_id : Ids.Type_id.t; ed_variants : variant_def list }

let def_id = function
  | StructDef { sd_id; _ } -> sd_id
  | EnumDef { ed_id; _ } -> ed_id

let def_repr (d : type_def) : Type_repr.t =
  match d with
  | StructDef { sd_fields; _ } ->
      Type_repr.Tuple
        (Array.of_list
           (List.map
              (fun f -> f.fd_ty)
              (List.sort
                 (fun a b -> Ids.Field_index.compare a.fd_index b.fd_index)
                 sd_fields)))
  | EnumDef { ed_variants; _ } ->
      Type_repr.Function
        ( Array.of_list
            (List.map
               (fun v ->
                 { Type_repr.pt_convention = Access_effect.Let; pt_type = v.vd_payload })
               (List.sort
                  (fun a b -> Ids.Variant_index.compare a.vd_index b.vd_index)
                  ed_variants)),
          Type_repr.Never )

type program = {
  functions : function_ array;
  statics : (string * Type_repr.t * constant option) array;
  types : type_def array;
}

(* ────────────────────────────────────────────────────────────────────
   Pretty printer — simple and deterministic. *)

let rec print_type (t : Type_repr.t) : string =
  match t with
  | Type_repr.Unit -> "()"
  | Type_repr.Bool -> "Bool"
  | Type_repr.Char -> "Char"
  | Type_repr.Int k -> print_int_kind k
  | Type_repr.Float f -> (match f with Type_repr.F32 -> "Float32" | Type_repr.F64 -> "Float64")
  | Type_repr.String -> "String"
  | Type_repr.Raw_ptr (m, inner) ->
      Printf.sprintf "*%s%s" (print_mut m) (print_type inner)
  | Type_repr.Ref_internal (m, inner) ->
      Printf.sprintf "&%s%s" (print_mut m) (print_type inner)
  | Type_repr.Tuple elems ->
      "(" ^ String.concat ", " (Array.to_list (Array.map print_type elems)) ^ ")"
  | Type_repr.Fixed_array (inner, n) ->
      Printf.sprintf "[%s; %d]" (print_type inner) n
  | Type_repr.Named (id, args) ->
      Printf.sprintf "type#%d%s"
        (Ids.Type_id.to_int id)
        (if Array.length args = 0 then ""
         else
           "[" ^ String.concat ", " (Array.to_list (Array.map print_type args)) ^ "]")
  | Type_repr.Function (params, ret) ->
      Printf.sprintf "fn(%s) -> %s"
        (String.concat ", "
           (Array.to_list
              (Array.map (fun p -> print_type p.Type_repr.pt_type) params)))
        (print_type ret)
  | Type_repr.Type_param id -> Printf.sprintf "T%d" (Ids.Generic_param_id.to_int id)
  | Type_repr.Infer_var v -> Printf.sprintf "?#%d" v
  | Type_repr.Int_literal _ -> "int-literal"
  | Type_repr.Error -> "error"
  | Type_repr.Never -> "!"

and print_int_kind = function
  | Type_repr.I8 -> "I8" | Type_repr.I16 -> "I16" | Type_repr.I32 -> "I32"
  | Type_repr.I64 -> "I64" | Type_repr.I128 -> "I128"
  | Type_repr.U8 -> "U8" | Type_repr.U16 -> "U16" | Type_repr.U32 -> "U32"
  | Type_repr.U64 -> "U64" | Type_repr.U128 -> "U128"
  | Type_repr.Int -> "Int" | Type_repr.UInt -> "UInt"

and print_mut = function
  | Type_repr.Immutable -> ""
  | Type_repr.Mutable -> "mut "

let print_int_value (v : int_value) : string =
  if v.bits_hi <> 0L then
    Printf.sprintf "0x%Lx_%Lx" v.bits_hi v.bits_lo
  else if v.signed then Int64.to_string v.bits_lo
  else Printf.sprintf "%Lu" v.bits_lo

let print_effect (e : Access_effect.read_effect) : string =
  match e with
  | Access_effect.Read -> "read"
  | Access_effect.Modify -> "modify"
  | Access_effect.Consume -> "consume"
  | Access_effect.Initialize -> "init"

let rec print_constant (c : constant) : string =
  match c with
  | Unit -> "()"
  | Bool b -> if b then "true" else "false"
  | Integer v -> print_int_value v
  | Float32 f -> Printf.sprintf "0x%lxf32" f
  | Float64 f -> Printf.sprintf "0x%Lxf64" f
  | Char ch -> Printf.sprintf "'U+%04X'" (Uchar.to_int ch)
  | String s -> Printf.sprintf "\"%s\"" s
  | Function inst -> "fn " ^ print_instance inst

and print_instance (inst : Instance_id.t) : string =
  Printf.sprintf "inst{callable#%d; [%s]}"
    (Ids.Callable_id.to_int (Instance_id.callable inst))
    (String.concat ", " (Array.to_list (Array.map print_type (Instance_id.type_args inst))))

let print_place (p : place) : string =
  let s = ref (Printf.sprintf "_%d" p.local) in
  List.iter
    (function
      | Deref -> s := "(*" ^ !s ^ ")"
      | Field f -> s := !s ^ "." ^ string_of_int (Ids.Field_index.to_int f)
      | Index li -> s := !s ^ Printf.sprintf "[_%d]" li
      | ConstantIndex i -> s := !s ^ Printf.sprintf "[%d]" i
      | Downcast v -> s := !s ^ Printf.sprintf " as variant#%d" (Ids.Variant_index.to_int v))
    p.projections;
  !s

let print_operand (op : operand) : string =
  match op with
  | Copy p -> print_place p
  | Move p -> "move " ^ print_place p
  | Read p -> "read " ^ print_place p
  | Consume p -> "consume " ^ print_place p
  | Constant c -> print_constant c

let print_bin_op = function
  | Add -> "+" | Sub -> "-" | Mul -> "*" | Div -> "/" | Rem -> "%"
  | Eq -> "==" | Ne -> "!=" | Lt -> "<" | Le -> "<=" | Gt -> ">" | Ge -> ">="
  | And -> "&&" | Or -> "||"
  | BitAnd -> "&" | BitOr -> "|" | BitXor -> "^" | Shl -> "<<" | Shr -> ">>"

let print_un_op = function Neg -> "Neg" | Not -> "Not"

let print_callee = function
  | User inst -> print_instance inst
  | Intrinsic i -> Printf.sprintf "intrinsic#%d" i
  | Extern i -> Printf.sprintf "extern#%d" i

let print_rvalue (rv : rvalue) : string =
  match rv with
  | Use op -> print_operand op
  | Ref p -> "&" ^ print_place p
  | RefMut p -> "&mut " ^ print_place p
  | Aggregate (kind, ops) -> (
      let ops_s = String.concat ", " (List.map print_operand ops) in
      match kind with
      | TupleAgg -> "(" ^ ops_s ^ ")"
      | ArrayAgg -> "[" ^ ops_s ^ "]"
      | StructCtor (tid, _) ->
          Printf.sprintf "type#%d { %s }" (Ids.Type_id.to_int tid) ops_s
      | EnumCtor (tid, vid) ->
          Printf.sprintf "type#%d::variant#%d(%s)" (Ids.Type_id.to_int tid)
            (Ids.Variant_index.to_int vid) ops_s
      | ClosureAgg inst -> Printf.sprintf "closure(%s, [%s])" (print_instance inst) ops_s)
  | BinaryOp (op, l, r) ->
      print_operand l ^ " " ^ print_bin_op op ^ " " ^ print_operand r
  | UnaryOp (op, v) -> print_un_op op ^ "(" ^ print_operand v ^ ")"
  | Discriminant p -> "discriminant(" ^ print_place p ^ ")"
  | Len p -> "len(" ^ print_place p ^ ")"
  | Cast (op, t) -> print_operand op ^ " as " ^ print_type t

let print_statement (st : statement) : string =
  match st with
  | Assign (p, rv) -> print_place p ^ " = " ^ print_rvalue rv ^ ";"
  | StorageLive id -> Printf.sprintf "StorageLive(_%d);" id
  | StorageDead id -> Printf.sprintf "StorageDead(_%d);" id
  | SetDiscriminant (p, d) ->
      Printf.sprintf "SetDiscriminant(%s, variant#%d);" (print_place p)
        (Ids.Variant_index.to_int d)
  | Nop -> "nop;"

let print_terminator (t : terminator) : string =
  match t with
  | Goto b -> Printf.sprintf "goto -> bb%d;" b
  | Ret -> "return;"
  | SwitchInt (op, targets, otherwise) ->
      let arms =
        String.concat ", "
          (List.map (fun (v, b) -> Printf.sprintf "%Ld: bb%d" v b) targets)
      in
      Printf.sprintf "switchInt(%s) -> [%s, otherwise: bb%d];" (print_operand op)
        arms otherwise
  | Call (dest, callee, args, next, unwind) ->
      let args_s =
        String.concat ", "
          (Array.to_list
             (Array.map
                (fun a -> print_effect a.effect_ ^ ": " ^ print_operand a.value)
                args))
      in
      let unwind_s = match unwind with Some u -> Printf.sprintf ", unwind: bb%d" u | None -> "" in
      Printf.sprintf "%s = %s(%s) -> [bb%d%s];" (print_place dest)
        (print_callee callee) args_s next unwind_s
  | Drop (p, next, unwind) ->
      let unwind_s = match unwind with Some u -> Printf.sprintf ", unwind: bb%d" u | None -> "" in
      Printf.sprintf "drop(%s) -> bb%d%s;" (print_place p) next unwind_s
  | Deinit (p, next, unwind) ->
      let unwind_s = match unwind with Some u -> Printf.sprintf ", unwind: bb%d" u | None -> "" in
      Printf.sprintf "deinit(%s) -> bb%d%s;" (print_place p) next unwind_s
  | Assert (op, expected, msg, target) ->
      Printf.sprintf "assert(%s, %b, \"%s\") -> bb%d;" (print_operand op) expected
        msg target
  | Unreachable -> "unreachable;"
  | Abort -> "abort;"

let print_function (fn : function_) : string =
  let buf = Buffer.create 256 in
  (* local convention: _0 is the return slot, parameter i lives at
     local _i+1 (seed_mir.ml's documented contract) *)
  let params =
    String.concat ", "
      (Array.to_list
         (Array.mapi
            (fun i p ->
              Printf.sprintf "_%d: %s" (i + 1) (print_type p.Type_repr.pt_type))
            fn.params))
  in
  Buffer.add_string buf
    (Printf.sprintf "fn %s(_0: %s, %s) { instance = %s;\n" fn.name
       (match Array.length fn.locals with
        | 0 -> "_"
        | _ -> print_type fn.locals.(0))
       params (print_instance fn.instance));
  Array.iteri
    (fun i ty ->
      if i > Array.length fn.params then
        Buffer.add_string buf (Printf.sprintf "    let _%d: %s;\n" i (print_type ty)))
    fn.locals;
  if Array.length fn.locals > Array.length fn.params then Buffer.add_char buf '\n';
  Array.iter
    (fun b ->
      Buffer.add_string buf (Printf.sprintf "    bb%d: {\n" b.id);
      List.iter
        (fun st -> Buffer.add_string buf ("        " ^ print_statement st ^ "\n"))
        b.statements;
      Buffer.add_string buf ("        " ^ print_terminator b.terminator ^ "\n");
      Buffer.add_string buf "    }\n")
    fn.blocks;
  Buffer.add_string buf "}\n";
  Buffer.contents buf

let print_static (name : string) (ty : Type_repr.t) (init : constant option) : string =
  match init with
  | Some c ->
      Printf.sprintf "static %s: %s = %s;" name (print_type ty) (print_constant c)
  | None -> Printf.sprintf "static %s: %s;" name (print_type ty)

let print_program (prog : program) : string =
  let buf = Buffer.create 512 in
  Array.iter
    (fun d ->
      match d with
      | StructDef { sd_id; sd_fields } ->
          Buffer.add_string buf
            (Printf.sprintf "struct type#%d { %s }\n" (Ids.Type_id.to_int sd_id)
               (String.concat "; "
                  (List.map
                     (fun f ->
                       Printf.sprintf "%s: %s" (string_of_int (Ids.Field_id.to_int f.fd_id))
                         (print_type f.fd_ty))
                     sd_fields)))
      | EnumDef { ed_id; ed_variants } ->
          Buffer.add_string buf
            (Printf.sprintf "enum type#%d { %s }\n" (Ids.Type_id.to_int ed_id)
               (String.concat "; "
                  (List.map
                     (fun v ->
                       Printf.sprintf "%s: %s" (string_of_int (Ids.Variant_id.to_int v.vd_id))
                         (print_type v.vd_payload))
                     ed_variants))))
    prog.types;
  if Array.length prog.types > 0 then Buffer.add_char buf '\n';
  Array.iter
    (fun (name, ty, init) ->
      Buffer.add_string buf (print_static name ty init ^ "\n"))
    prog.statics;
  if Array.length prog.statics > 0 then Buffer.add_char buf '\n';
  Array.iter
    (fun fn -> Buffer.add_string buf (print_function fn ^ "\n"))
    prog.functions;
  Buffer.contents buf
