(* mir.ml — MIR data model and pretty printer.

   The data model mirrors the reference stage0 MIR (the `lower` command
   output contract is byte-identical). Structural equality is derived. *)

type mir_type =
  | Unit
  | Bool
  | Int
  | Float
  | Char
  | String
  | Named of string
  | RefInternal of mir_type * bool   (* &T / &mut T — the internal ABI *)
  | RawPtr of mir_type               (* *T / *mut T *)
  | Array of mir_type * int option   (* [T; N] or [T] *)
  | Slice of mir_type
  | Tuple of mir_type list
  | Fn of mir_type list * mir_type
  | Unknown

type mir_typedef_kind =
  | StructDef of (string * mir_type) list   (* (field name, type) in order *)
  | EnumDef of (string * mir_type list) list (* (variant name, payload types) *)

type mir_typedef = { td_name : string; td_kind : mir_typedef_kind }

type access_effect = Read | Modify | Consume | Initialize

type mir_local = {
  l_id : int;
  l_name : string option;   (* None for temporaries; "_return" for local 0 *)
  l_type : mir_type;
  l_mutable : bool;
}

type mir_place = { p_local : int; p_projections : mir_projection list }

and mir_projection =
  | ProjDeref
  | Field of int
  | NamedField of string
  | Index of int          (* the index is a local id *)
  | ConstantIndex of int
  | Downcast of int       (* enum variant index *)

type mir_operand =
  | MirCopy of mir_place
  | MirMovePlace of mir_place
  | MirRead of mir_place
  | MirConsume of mir_place
  | MirConstant of mir_constant

and mir_constant =
  | Unit
  | Bool of bool
  | Int of int64
  | Float of float
  | Char of string
  | Str of string
  | FnItem of string
  | ZeroSized

type mir_call_value = CallValue of mir_operand | CallPlace of mir_place

type mir_call_arg = { ca_effect : access_effect; ca_value : mir_call_value }

type mir_bin_op =
  | Add | Sub | Mul | Div | Rem | Eq | Ne | Lt | Le | Gt | Ge
  | And | Or | BitAnd | BitOr | BitXor | Shl | Shr

type mir_un_op = Neg | Not

type aggregate_kind =
  | TupleAgg
  | ArrayAgg
  | StructCtor of string * string list   (* type name, field names *)
  | EnumCtor of string * int             (* type name, variant index *)
  | ClosureAgg of string                 (* closure function name *)

type mir_rvalue =
  | Use of mir_operand
  | MirRef of mir_place
  | MirRefMut of mir_place
  | Aggregate of aggregate_kind * mir_operand list
  | BinaryOp of mir_bin_op * mir_operand * mir_operand
  | UnaryOp of mir_un_op * mir_operand
  | Discriminant of mir_place
  | Len of mir_place
  | Cast of mir_operand * mir_type

type mir_statement =
  | Assign of mir_place * mir_rvalue
  | StorageLive of int
  | StorageDead of int
  | SetDiscriminant of mir_place * int
  | Nop

type mir_terminator =
  | Goto of int
  | Ret
  | SwitchInt of mir_operand * (int * int) list * int
  | Call of mir_place * mir_operand * mir_call_arg list * int * int option
  | Drop of mir_place * int * int option
  | Deinit of mir_place * int * int option
  | Assert of mir_operand * bool * string * int
  | Unreachable
  | Abort

type mir_block = {
  b_id : int;
  b_statements : mir_statement list;
  b_terminator : mir_terminator;
}

type mir_function = {
  f_name : string;
  f_params : mir_local list;
  f_return : mir_type;
  f_locals : mir_local list;
  f_blocks : mir_block list;
  f_entry : int;
  f_async : bool;
  f_unsafe : bool;
  f_extern : bool;
}

type mir_static = {
  st_name : string;
  st_type : mir_type;
  st_initializer : mir_constant option;
  st_mutable : bool;
}

type mir_program = {
  prog_functions : mir_function list;
  prog_statics : mir_static list;
  prog_typedefs : mir_typedef list;
}

let empty_program = { prog_functions = []; prog_statics = []; prog_typedefs = [] }

(* ────────────────────────────────────────────────────────────────
   Pretty printer — the `lower` command output contract.

   Format per the reference MIRPrettyPrinter: only functions print
   (statics and type defs are omitted); each function is followed by a
   blank line. *)

(* Swift-style shortest-round-trip float formatting. *)
let format_float (x : float) : string =
  if x <> x then "nan"
  else if x = infinity then "inf"
  else if x = neg_infinity then "-inf"
  else if x = 0.0 then (if 1.0 /. x < 0.0 then "-0.0" else "0.0")
  else begin
    (* shortest digits that round-trip *)
    let digits = ref "" in
    let prec = ref 1 in
    let found = ref false in
    while not !found && !prec <= 17 do
      let s = Printf.sprintf "%.*g" !prec x in
      if float_of_string s = x then begin
        digits := s;
        found := true
      end
      else incr prec
    done;
    if not !found then digits := Printf.sprintf "%.17g" x;
    let s = !digits in
    (* split mantissa/exponent *)
    let epos = ref (-1) in
    String.iteri
      (fun i c -> if c = 'e' || c = 'E' then epos := i)
      s;
    let mant, exp =
      if !epos >= 0 then
        (String.sub s 0 !epos, int_of_string (String.sub s (!epos + 1) (String.length s - !epos - 1)))
      else (s, 0)
    in
    if exp < -4 || exp >= 17 then begin
      (* scientific: d.dddde±XX — Swift: mantissa with one leading digit,
         at least one fraction digit, exponent sign and 2+ digits *)
      let sign, body =
        if String.length mant > 0 && mant.[0] = '-' then ("-", String.sub mant 1 (String.length mant - 1))
        else ("", mant)
      in
      let e2 = exp - (String.length body - 1) in
      let frac =
        if String.length body = 1 then "0"
        else String.sub body 1 (String.length body - 1)
      in
      let esign = if e2 < 0 then "-" else "+" in
      let eabs = abs e2 in
      let edigits =
        if eabs < 10 then "0" ^ string_of_int eabs
        else string_of_int eabs
      in
      Printf.sprintf "%s%s.%se%s%s" sign (String.make 1 body.[0]) frac esign edigits
    end
    else begin
      (* fixed notation *)
      if String.contains mant '.' then begin
        (* trim trailing zeros *)
        let rec trim i =
          if i > 0 && mant.[i] = '0' then trim (i - 1)
          else if i > 0 && mant.[i] = '.' then i - 1
          else i
        in
        let n = trim (String.length mant - 1) in
        String.sub mant 0 (n + 1)
      end
      else mant ^ ".0"
    end
  end

let rec print_type (t : mir_type) : string =
  match t with
  | Unit -> "()"
  | Bool -> "Bool"
  | Int -> "Int"
  | Float -> "Float"
  | Char -> "Char"
  | String -> "String"
  | Named n -> n
  | RefInternal (inner, true) -> "&mut " ^ print_type inner
  | RefInternal (inner, false) -> "&" ^ print_type inner
  | RawPtr inner -> "*" ^ print_type inner
  | Array (inner, Some n) -> Printf.sprintf "[%s; %d]" (print_type inner) n
  | Array (inner, None) -> "[" ^ print_type inner ^ "]"
  | Slice inner -> "[" ^ print_type inner ^ "]"
  | Tuple elems -> "(" ^ String.concat ", " (List.map print_type elems) ^ ")"
  | Fn (params, ret) ->
      Printf.sprintf "fn(%s) -> %s"
        (String.concat ", " (List.map print_type params))
        (print_type ret)
  | Unknown -> "?"

let print_effect = function
  | Read -> "read"
  | Modify -> "modify"
  | Consume -> "consume"
  | Initialize -> "init"

let rec print_place (p : mir_place) : string =
  let s = ref (Printf.sprintf "_%d" p.p_local) in
  List.iter
    (function
      | ProjDeref -> s := "(*" ^ !s ^ ")"
      | Field i -> s := !s ^ "." ^ string_of_int i
      | NamedField n -> s := !s ^ "." ^ n
      | Index id -> s := !s ^ Printf.sprintf "[_%d]" id
      | ConstantIndex i -> s := !s ^ Printf.sprintf "[%d]" i
      | Downcast v -> s := !s ^ Printf.sprintf " as variant#%d" v)
    p.p_projections;
  !s

let print_constant (c : mir_constant) : string =
  match c with
  | Unit -> "()"
  | Bool b -> if b then "true" else "false"
  | Int i -> Int64.to_string i
  | Float f -> format_float f
  | Char c -> "'" ^ c ^ "'"
  | Str s -> "\"" ^ s ^ "\""
  | FnItem n -> n
  | ZeroSized -> "zst"

let rec print_operand (op : mir_operand) : string =
  match op with
  | MirCopy p -> print_place p
  | MirMovePlace p -> "move " ^ print_place p
  | MirRead p -> "read " ^ print_place p
  | MirConsume p -> "consume " ^ print_place p
  | MirConstant c -> print_constant c

let print_bin_op = function
  | Add -> "+" | Sub -> "-" | Mul -> "*" | Div -> "/" | Rem -> "%"
  | Eq -> "==" | Ne -> "!=" | Lt -> "<" | Le -> "<=" | Gt -> ">" | Ge -> ">="
  | And -> "&&" | Or -> "||"
  | BitAnd -> "&" | BitOr -> "|" | BitXor -> "^" | Shl -> "<<" | Shr -> ">>"

let print_un_op = function Neg -> "Neg" | Not -> "Not"

let print_call_value (v : mir_call_value) : string =
  match v with
  | CallValue op -> print_operand op
  | CallPlace p -> print_place p

let print_rvalue (rv : mir_rvalue) : string =
  match rv with
  | Use op -> print_operand op
  | MirRef p -> "&" ^ print_place p
  | MirRefMut p -> "&mut " ^ print_place p
  | Aggregate (kind, ops) -> (
      let ops_s = String.concat ", " (List.map print_operand ops) in
      match kind with
      | TupleAgg -> "(" ^ ops_s ^ ")"
      | ArrayAgg -> "[" ^ ops_s ^ "]"
      | StructCtor (name, fields) ->
          if fields = [] then name ^ " { " ^ ops_s ^ " }"
          else
            let pairs =
              String.concat ", "
                (List.map2 (fun f op -> f ^ ": " ^ print_operand op) fields ops)
            in
            name ^ " { " ^ pairs ^ " }"
      | EnumCtor (name, idx) -> Printf.sprintf "%s::%d(%s)" name idx ops_s
      | ClosureAgg name -> "closure(" ^ name ^ ")")
  | BinaryOp (op, l, r) ->
      print_operand l ^ " " ^ print_bin_op op ^ " " ^ print_operand r
  | UnaryOp (op, v) -> print_un_op op ^ "(" ^ print_operand v ^ ")"
  | Discriminant p -> "discriminant(" ^ print_place p ^ ")"
  | Len p -> "Len(" ^ print_place p ^ ")"
  | Cast (op, t) -> print_operand op ^ " as " ^ print_type t

let print_statement (st : mir_statement) : string =
  match st with
  | Assign (p, rv) -> print_place p ^ " = " ^ print_rvalue rv ^ ";"
  | StorageLive id -> Printf.sprintf "StorageLive(_%d);" id
  | StorageDead id -> Printf.sprintf "StorageDead(_%d);" id
  | SetDiscriminant (p, d) -> Printf.sprintf "SetDiscriminant(%s, %d);" (print_place p) d
  | Nop -> "nop;"

let print_terminator (t : mir_terminator) : string =
  match t with
  | Goto b -> Printf.sprintf "goto -> bb%d;" b
  | Ret -> "return;"
  | SwitchInt (op, targets, otherwise) ->
      let arms =
        String.concat ", "
          (List.map (fun (v, b) -> Printf.sprintf "%d: bb%d" v b) targets)
      in
      Printf.sprintf "switchInt(%s) -> [%s, otherwise: bb%d];" (print_operand op) arms
        otherwise
  | Call (dest, callee, args, next, unwind) ->
      let args_s =
        String.concat ", "
          (List.map
             (fun a ->
               match a.ca_value with
               | CallValue op -> print_effect a.ca_effect ^ ": " ^ print_operand op
               | CallPlace p -> print_effect a.ca_effect ^ ":" ^ print_place p)
             args)
      in
      let unwind_s = match unwind with Some u -> Printf.sprintf ", unwind: bb%d" u | None -> "" in
      Printf.sprintf "%s = %s(%s) -> [bb%d%s];" (print_place dest) (print_operand callee)
        args_s next unwind_s
  | Drop (p, next, unwind) ->
      let unwind_s = match unwind with Some u -> Printf.sprintf ", unwind: bb%d" u | None -> "" in
      Printf.sprintf "drop(%s) -> bb%d%s;" (print_place p) next unwind_s
  | Deinit (p, next, unwind) ->
      let unwind_s = match unwind with Some u -> Printf.sprintf ", unwind: bb%d" u | None -> "" in
      Printf.sprintf "deinit(%s) -> bb%d%s;" (print_place p) next unwind_s
  | Assert (op, expected, msg, target) ->
      Printf.sprintf "assert(%s, %b, \"%s\") -> bb%d;" (print_operand op) expected msg
        target
  | Unreachable -> "unreachable;"
  | Abort -> "abort;"

let print_function (fn : mir_function) : string =
  let buf = Buffer.create 256 in
  let params =
    String.concat ", "
      (List.map
         (fun p ->
           let name = match p.l_name with Some n -> n | None -> Printf.sprintf "_%d" p.l_id in
           Printf.sprintf "%s: %s" name (print_type p.l_type))
         fn.f_params)
  in
  Buffer.add_string buf
    (Printf.sprintf "fn %s(%s) -> %s {\n" fn.f_name params (print_type fn.f_return));
  let param_ids = List.map (fun p -> p.l_id) fn.f_params in
  List.iter
    (fun local ->
      if not (List.mem local.l_id param_ids) then begin
        Buffer.add_string buf "    let ";
        if local.l_mutable then Buffer.add_string buf "mut ";
        Buffer.add_string buf (Printf.sprintf "_%d" local.l_id);
        (match local.l_name with
         | Some n -> Buffer.add_string buf (Printf.sprintf " /* %s */" n)
         | None -> ());
        Buffer.add_string buf (Printf.sprintf ": %s;\n" (print_type local.l_type))
      end)
    fn.f_locals;
  if fn.f_locals <> [] then Buffer.add_char buf '\n';
  List.iter
    (fun block ->
      Buffer.add_string buf (Printf.sprintf "    bb%d: {\n" block.b_id);
      List.iter
        (fun st -> Buffer.add_string buf ("        " ^ print_statement st ^ "\n"))
        block.b_statements;
      Buffer.add_string buf ("        " ^ print_terminator block.b_terminator ^ "\n");
      Buffer.add_string buf "    }\n")
    fn.f_blocks;
  Buffer.add_string buf "}\n";
  Buffer.contents buf

let print_program (prog : mir_program) : string =
  String.concat "\n" (List.map print_function prog.prog_functions)
