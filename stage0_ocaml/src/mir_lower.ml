(* mir_lower.ml — Typed AST → Seed MIR lowering (audit §34, §35).

   Lowering operates on the syntax AST plus a name→type environment
   produced by the type checker; every lowered construct is typed. If a
   construct is reached with an unknown type, lowering raises Seed_bug
   (never produces Nop).

   Seed-surface constructs implemented here:

   - Variant match arms (Ast.PatVariant): the subject is an enum value.
     The Seed VM represents an enum as `Vm_value.Enum (tag, payload)` —
     tag = variant index in declaration order, payload = the variant's
     field array (see vm_value.ml).  Lowering emits the subject into a
     local, computes the discriminant with the `Discriminant` rvalue
     (the VM returns the tag as an Int), dispatches with one SwitchInt
     whose targets are the per-variant tags (0-based declaration order,
     matching EnumCtor's tags), and binds each arm's payload fields by
     projecting the subject with [Downcast vid; Field i] (the VM's
     Downcast turns the payload into a Struct, Field picks field i).
     Payload binding locals are Copy-read when the payload type is
     copyable (non-copy payload binding fails closed: the seed VM's Move
     operand ignores projections, so a projected move would be wrong).

   - `?` (Ast.TryOp): the subject is an Option/Result.  The success
     variant (tag 0) supplies the expression value (the payload read
     via the Downcast/Field projection above); the failure variant
     early-returns from the enclosing function: the subject is copied
     into the return slot (enum values are copyable under the verifier
     since their def is Function (_, Never)) and `Ret` is emitted, with
     the function-level defer bodies running first.  The subject's type
     must equal the enclosing function's return type (fail-closed
     otherwise).

   - `for x in [..] do` (Ast.ForExpr): a for-loop over a compile-time
     Array literal is UNROLLED into per-element body copies with
     ConstantIndex element reads; any other iterable lowers to a runtime
     counter loop — the container is evaluated once into a local, a
     counter local counts from 0 to Len(container), and each iteration
     reads the element through the dynamic `Seed_mir.Index <counter>`
     projection (the VM executes it and bounds-checks the runtime index
     at execution).

   - defer (Ast.DeferStmt): each function accumulates a defer stack
     (function level; nested scopes are flattened to function level for
     the seed).  Every return terminator — explicit `return`, the `?`
     failure path, and the function's final implicit return — first
     lowers the collected defer bodies inline in reverse declaration
     order (LIFO), then assigns the return slot, then emits Ret.

   - Statics/consts: there is AST plumbing (Ast.ConstDecl/Ast.StaticDecl
     and a Typecheck `consts` registry), but the Mir_lower API carries
     no const/static table and the driver passes `statics = [||]`, so
     names that resolve only to consts/statics fail closed at lowering
     with Seed_bug.  See the statics TODO at the bottom of the file. *)

exception Seed_bug of string

let seed_bug fmt = Printf.ksprintf (fun m -> raise (Seed_bug m)) fmt

(* ── Environment ──────────────────────────────────────────────── *)

type callable_entry = {
  ce_callable : int;                    (* resolved callable id *)
  ce_template_args : Type_repr.t array; (* declaration-order template params for generic defs *)
}

type func_env = {
  types : (string * Type_repr.t) list;               (* type name -> repr *)
  values : (string * Type_repr.t) list;              (* global value name -> type *)
  callables : (string * callable_entry) list;        (* function name -> resolved entry *)
  methods : ((string * string) * Instance_id.t) list;  (* (receiver type name, method) -> instance *)
  fn_ret : Type_repr.t;
}

(* ── Variant tables ──────────────────────────────────────────────

   The seed representation of an enum value is
   `Vm_value.Enum (variant_index_in_declaration_order, payload)`
   (vm_value.ml), constructed by EnumCtor and read by Discriminant /
   Downcast / Field projections.  Variant indices must therefore be
   consistent across construction sites and match arms within one
   program.  The builtin enums Option (Some=0, None=1) and Result
   (Ok=0, Err=1) are hardcoded (their payloads come from the enum's
   type arguments); user enums are declared by the caller through a
   variant_table (see lower_function_with_variants).  The plain
   lower_function API (used by the driver) lowers with the builtin
   table only, so user-defined enum constructs fail closed there with a
   Seed_bug pointing at lower_function_with_variants. *)

type variant_spec = {
  vs_index : int;                   (* tag = declaration-order variant index *)
  vs_fields : Type_repr.t list;     (* payload field types (concrete) *)
}

type variant_table = {
  vt_enums : (string * (string * variant_spec) list) list;  (* enum name -> variant name -> spec *)
  vt_ctors : (string * (string * string)) list;  (* ctor name -> (enum name, variant name) *)
}

let builtin_variant_spec (enum_name : string) (vname : string) (repr : Type_repr.t) :
    variant_spec option =
  let index_of =
    match enum_name, vname with
    | "Option", "Some" -> Some 0
    | "Option", "None" -> Some 1
    | "Result", "Ok" -> Some 0
    | "Result", "Err" -> Some 1
    | _ -> None
  in
  match index_of with
  | None -> None
  | Some idx ->
      let args = match repr with Type_repr.Named (_, args) -> args | _ -> [||] in
      let fields =
        match vname with
        | "Some" | "Ok" -> if Array.length args > 0 then [ args.(0) ] else []
        | "Err" -> if Array.length args > 1 then [ args.(1) ] else []
        | _ -> []
      in
      Some { vs_index = idx; vs_fields = fields }

let variant_spec_of (_env : func_env) (tbl : variant_table) ~(enum_name : string)
    ~(vname : string) ~(repr : Type_repr.t) : variant_spec =
  match List.assoc_opt enum_name tbl.vt_enums with
  | Some varmap -> (
      match List.assoc_opt vname varmap with
      | Some spec -> spec
      | None ->
          seed_bug "unknown variant `%s` of enum `%s` (no variant table entry)" vname enum_name)
  | None -> (
      match builtin_variant_spec enum_name vname repr with
      | Some spec -> spec
      | None ->
          seed_bug
            "unknown variant `%s` of enum `%s` in lowering (user enums require lower_function_with_variants)"
            vname enum_name)

let ctor_of (tbl : variant_table) (n : string) : (string * string) option =
  match List.assoc_opt n tbl.vt_ctors with
  | Some pair -> Some pair
  | None -> (
      match n with
      | "Some" | "Option::Some" -> Some ("Option", "Some")
      | "None" | "Option::None" -> Some ("Option", "None")
      | "Ok" | "Result::Ok" -> Some ("Result", "Ok")
      | "Err" | "Result::Err" -> Some ("Result", "Err")
      | _ -> None)

let enum_tid_of (env : func_env) (enum_name : string) : Ids.Type_id.t =
  match List.assoc_opt enum_name env.types with
  | Some (Type_repr.Named (tid, _)) -> tid
  | _ -> seed_bug "enum `%s` has no type identity in the lowering env" enum_name

let enum_name_of_ty (env : func_env) (t : Type_repr.t) : string =
  match t with
  | Type_repr.Named (tid, _) -> (
      match
        List.find_opt
          (fun (_, r) ->
            match r with
            | Type_repr.Named (tid2, _) ->
                Ids.Type_id.compare tid tid2 = 0
            | _ -> false)
          env.types
      with
      | Some (n, _) -> n
      | None -> seed_bug "the match subject's enum type has no name in the lowering env")
  | _ -> seed_bug "variant match subject is not an enum value"

let default_variant_table : variant_table = { vt_enums = []; vt_ctors = [] }

type lower_state = {
  mutable next_local : int;
  mutable next_block : int;
  mutable locals : Type_repr.t array;
  mutable local_names : (int * string) list;
  mutable scope : (string * int) list;      (* name -> local id *)
  mutable blocks : Seed_mir.block list;   (* reversed *)
  mutable cur_block : int;
  mutable cur_stmts : Seed_mir.statement list;  (* reversed *)
  mutable break_target : int option;
  mutable continue_target : int option;
  variants : variant_table;              (* enum variant/constructor identity *)
  mutable defer_stack : Ast.block_body list;  (* function-level defer bodies; head = most recent *)
}

let new_block (st : lower_state) : int =
  let id = st.next_block in
  st.next_block <- st.next_block + 1;
  id

let push_block (st : lower_state) (id : int) : unit =
  (* close the current block with a goto to id, then switch *)
  st.blocks <- { Seed_mir.id = st.cur_block; statements = List.rev st.cur_stmts; terminator = Seed_mir.Goto id } :: st.blocks;
  st.cur_stmts <- [];
  st.cur_block <- id

let fresh_local (st : lower_state) (ty : Type_repr.t) : int =
  let id = st.next_local in
  st.next_local <- st.next_local + 1;
  if id >= Array.length st.locals then
    st.locals <- Array.append st.locals [| ty |]
  else st.locals.(id) <- ty;
  id

let cur_place (_st : lower_state) (id : int) : Seed_mir.place =
  { Seed_mir.local = id; projections = [] }

let local_type (st : lower_state) (id : int) : Type_repr.t option =
  if id >= 0 && id < Array.length st.locals then Some st.locals.(id) else None

let emit (st : lower_state) (s : Seed_mir.statement) : unit =
  st.cur_stmts <- s :: st.cur_stmts

let set_terminator (st : lower_state) (t : Seed_mir.terminator) : unit =
  st.blocks <- { Seed_mir.id = st.cur_block; statements = List.rev st.cur_stmts; terminator = t } :: st.blocks;
  st.cur_stmts <- [];
  st.cur_block <- new_block st

(* Close the current block with a terminator whose continuation is a
   specific block (no stray intermediate block). *)
let set_terminator_to (st : lower_state) (t : Seed_mir.terminator) (cont : int) : unit =
  st.blocks <- { Seed_mir.id = st.cur_block; statements = List.rev st.cur_stmts; terminator = t } :: st.blocks;
  st.cur_stmts <- [];
  st.cur_block <- cont

(* ── Small operand/place helpers ──────────────────────────────── *)

let constant_type_of (c : Seed_mir.constant) : Type_repr.t =
  match c with
  | Seed_mir.Unit -> Type_repr.Unit
  | Seed_mir.Bool _ -> Type_repr.Bool
  | Seed_mir.Integer v ->
      let width = v.Int_value.width and signed = v.Int_value.signed in
      let kind =
        match width, signed with
        | 8, true -> Type_repr.I8 | 16, true -> Type_repr.I16 | 32, true -> Type_repr.I32
        | 64, true -> Type_repr.Int | 128, true -> Type_repr.I128
        | 8, false -> Type_repr.U8 | 16, false -> Type_repr.U16 | 32, false -> Type_repr.U32
        | 64, false -> Type_repr.UInt | 128, false -> Type_repr.U128
        | _ -> Type_repr.Int
      in
      Type_repr.Int kind
  | Seed_mir.Float32 _ -> Type_repr.Float Type_repr.F32
  | Seed_mir.Float64 _ -> Type_repr.Float Type_repr.F64
  | Seed_mir.Char _ -> Type_repr.Char
  | Seed_mir.String _ -> Type_repr.String
  | Seed_mir.Function _ -> Type_repr.Function ([||], Type_repr.Unit)

(* Turn an operand into a place (materializing constants into a local). *)
let materialize_place (st : lower_state) (op : Seed_mir.operand) : Seed_mir.place =
  match op with
  | Seed_mir.Copy p | Seed_mir.Read p | Seed_mir.Move p | Seed_mir.Consume p -> p
  | Seed_mir.Constant c ->
      let id = fresh_local st (constant_type_of c) in
      emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Use (Seed_mir.Constant c)));
      cur_place st id

(* The element type of an iterable/indexable type.  Named array types
   (Vec/Array nominals) fail closed: the lowering env carries no
   type-substituted element lookup for them (their element reads lower
   to a dynamic Seed_mir.Index projection, which the verifier only
   admits on Fixed_array bases). *)
let element_type_of (t : Type_repr.t) : Type_repr.t =
  match t with
  | Type_repr.Fixed_array (e, _) -> e
  | Type_repr.String -> Type_repr.Char
  | Type_repr.Tuple _ -> Type_repr.Int Type_repr.Int
  | _ -> seed_bug "element access on a non-iterable type %s (the lowering env carries no type-substituted element lookup for named Vec/Array types; the dynamic Seed_mir.Index projection itself is executable — the verifier only admits it on Fixed_array bases)"
           (Seed_mir.print_type t)

(* Conservative copyability for payload binding: enums resolve to
   Function (_, Never) defs which the verifier treats as Copy, but the
   lowering has no def table, so Named values are conservatively
   non-copy (a projected Move is wrong: the seed VM's Move ignores
   projections, so non-copy payload binding fails closed). *)
let rec copyable_ty (t : Type_repr.t) : bool =
  match t with
  | Type_repr.Unit | Type_repr.Bool | Type_repr.Char | Type_repr.Int _
  | Type_repr.Float _ | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _
  | Type_repr.Function _ | Type_repr.Never ->
      true
  | Type_repr.String -> false
  | Type_repr.Tuple elems -> Array.for_all copyable_ty elems
  | Type_repr.Fixed_array (e, _) -> copyable_ty e
  | Type_repr.Named _ | Type_repr.Type_param _ -> false

(* ── Defer machinery ─────────────────────────────────────────────

   Function-level defer stack: every DeferStmt pushes its body; every
   exit edge (explicit return, `?` failure early-return, final implicit
   return) re-lowers the collected bodies inline in reverse declaration
   order (LIFO) BEFORE the return slot is assigned, so mutations made by
   the defers are observable in the returned value.  Nested scopes are
   flattened to function level (the seed's lowering never pops scope),
   so a defer declared inside a conditional still runs on every exit —
   documented seed approximation of per-scope cleanup.  emit_defers is
   part of the mutually recursive expression-lowering group because it
   re-lowers defer bodies through lower_block. *)

(* Structural scanners used to fail closed on constructs that would be
   unsound when re-lowered inline (a return inside a defer body would
   recurse at lowering time; break/next inside an unrolled loop would
   target the wrong loop). *)

let rec expr_has_return (e : Ast.expr) : bool =
  match e with
  | Ast.ReturnExpr _ -> true
  | Ast.Block (b, _) -> block_has_return b
  | Ast.IfExpr i ->
      expr_has_return i.Ast.if_condition
      || block_has_return i.Ast.if_then
      || List.exists (fun (_, b) -> block_has_return b) i.Ast.if_elsif
      || (match i.Ast.if_else with Some b -> block_has_return b | None -> false)
      || (match i.Ast.if_let_value with Some v -> expr_has_return v | None -> false)
  | Ast.MatchExpr m ->
      expr_has_return m.Ast.m_subject
      || List.exists
           (fun arm ->
             expr_has_return arm.Ast.ma_body
             || (match arm.Ast.ma_guard with Some g -> expr_has_return g | None -> false))
           m.Ast.m_arms
  | Ast.WhileExpr w -> expr_has_return w.Ast.wh_condition || block_has_return w.Ast.wh_body
  | Ast.LoopExpr (b, _) -> block_has_return b
  | Ast.ForExpr f -> expr_has_return f.Ast.for_iterable || block_has_return f.Ast.for_body
  | Ast.UntilExpr u -> expr_has_return u.Ast.ut_condition || block_has_return u.Ast.ut_body
  | Ast.UnlessExpr u ->
      expr_has_return u.Ast.un_condition
      || block_has_return u.Ast.un_body
      || (match u.Ast.un_else with Some b -> block_has_return b | None -> false)
  | Ast.Call (c, _, args, _) ->
      expr_has_return c || List.exists (fun a -> expr_has_return a.Ast.ca_value) args
  | Ast.Index (b, i, _) | Ast.Binary (b, _, i, _) | Ast.CompoundAssign (b, _, i, _) ->
      expr_has_return b || expr_has_return i
  | Ast.Unary (_, e, _) | Ast.TryOp (e, _) | Ast.Cast (e, _, _) | Ast.AwaitExpr (e, _) ->
      expr_has_return e
  | Ast.Field (b, _, _) | Ast.Assign (b, _, _) ->
      expr_has_return b
  | Ast.BreakExpr (Some e, _) -> expr_has_return e
  | Ast.BreakExpr (None, _) -> false
  | Ast.Tuple (es, _) | Ast.Array (es, _) -> List.exists expr_has_return es
  | Ast.ArrayRepeat (e1, e2, _) -> expr_has_return e1 || expr_has_return e2
  | Ast.Range (e1, e2, _, _) -> expr_has_return e1 || expr_has_return e2
  | _ -> false

and block_has_return (b : Ast.block_body) : bool =
  List.exists stmt_has_return b.Ast.b_stmts
  || (match b.Ast.b_tail with Some t -> expr_has_return t | None -> false)

and stmt_has_return (s : Ast.stmt) : bool =
  match s with
  | Ast.ExprStmt (e, _) -> expr_has_return e
  | Ast.LetBinding (_, _, _, v, _) -> expr_has_return v
  | Ast.DeferStmt (b, _) -> block_has_return b
  | Ast.Attributed (_, inner, _) -> stmt_has_return inner
  | Ast.Item _ | Ast.AttributeStmt _ -> false

let rec expr_has_loop_exit (e : Ast.expr) : bool =
  match e with
  | Ast.BreakExpr _ | Ast.NextExpr _ -> true
  | Ast.Block (b, _) -> block_has_loop_exit b
  | Ast.IfExpr i ->
      expr_has_loop_exit i.Ast.if_condition
      || block_has_loop_exit i.Ast.if_then
      || List.exists (fun (_, b) -> block_has_loop_exit b) i.Ast.if_elsif
      || (match i.Ast.if_else with Some b -> block_has_loop_exit b | None -> false)
  | Ast.MatchExpr m ->
      expr_has_loop_exit m.Ast.m_subject
      || List.exists
           (fun arm ->
             expr_has_loop_exit arm.Ast.ma_body
             || (match arm.Ast.ma_guard with Some g -> expr_has_loop_exit g | None -> false))
           m.Ast.m_arms
  | Ast.WhileExpr w -> expr_has_loop_exit w.Ast.wh_condition || block_has_loop_exit w.Ast.wh_body
  | Ast.LoopExpr (b, _) -> block_has_loop_exit b
  | Ast.ForExpr f -> expr_has_loop_exit f.Ast.for_iterable || block_has_loop_exit f.Ast.for_body
  | Ast.UntilExpr u -> expr_has_loop_exit u.Ast.ut_condition || block_has_loop_exit u.Ast.ut_body
  | Ast.UnlessExpr u ->
      expr_has_loop_exit u.Ast.un_condition
      || block_has_loop_exit u.Ast.un_body
      || (match u.Ast.un_else with Some b -> block_has_loop_exit b | None -> false)
  | Ast.Call (c, _, args, _) ->
      expr_has_loop_exit c || List.exists (fun a -> expr_has_loop_exit a.Ast.ca_value) args
  | Ast.Index (b, i, _) | Ast.Binary (b, _, i, _) | Ast.CompoundAssign (b, _, i, _) ->
      expr_has_loop_exit b || expr_has_loop_exit i
  | Ast.Unary (_, e, _) | Ast.TryOp (e, _) | Ast.Cast (e, _, _) | Ast.AwaitExpr (e, _) ->
      expr_has_loop_exit e
  | Ast.Field (b, _, _) | Ast.Assign (b, _, _) ->
      expr_has_loop_exit b
  | Ast.Tuple (es, _) | Ast.Array (es, _) -> List.exists expr_has_loop_exit es
  | Ast.ArrayRepeat (e1, e2, _) -> expr_has_loop_exit e1 || expr_has_loop_exit e2
  | Ast.Range (e1, e2, _, _) -> expr_has_loop_exit e1 || expr_has_loop_exit e2
  | _ -> false

and block_has_loop_exit (b : Ast.block_body) : bool =
  List.exists stmt_has_loop_exit b.Ast.b_stmts
  || (match b.Ast.b_tail with Some t -> expr_has_loop_exit t | None -> false)

and stmt_has_loop_exit (s : Ast.stmt) : bool =
  match s with
  | Ast.ExprStmt (e, _) -> expr_has_loop_exit e
  | Ast.LetBinding (_, _, _, v, _) -> expr_has_loop_exit v
  | Ast.DeferStmt (b, _) -> block_has_loop_exit b
  | Ast.Attributed (_, inner, _) -> stmt_has_loop_exit inner
  | Ast.Item _ | Ast.AttributeStmt _ -> false

(* ── Type mapping (syntax type → repr) ────────────────────────── *)

let rec type_of_syntax (env : func_env) (t : Ast.type_expr) : Type_repr.t =
  match t with
  | Ast.Named (name, args, _) -> (
      match List.assoc_opt name env.types with
      | Some r ->
          let subst =
            List.mapi
              (fun i _ -> (Ids.Generic_param_id.make i, type_of_syntax env (List.nth args i)))
              args
          in
          Type_repr.substitute subst r
      | None -> (
          match name with
          | "Int" -> Type_repr.Int Type_repr.Int
          | "UInt" -> Type_repr.Int Type_repr.UInt
          | "Bool" -> Type_repr.Bool
          | "String" -> Type_repr.String
          | "Char" -> Type_repr.Char
          | "Unit" | "()" -> Type_repr.Unit
          | "Never" -> Type_repr.Never
          | "u8" -> Type_repr.Int Type_repr.U8
          | "i32" -> Type_repr.Int Type_repr.I32
          | "f32" -> Type_repr.Float Type_repr.F32
          | "f64" -> Type_repr.Float Type_repr.F64
          | _ -> seed_bug "unknown type name '%s' in lowering" name))
  | Ast.Unit _ -> Type_repr.Unit
  | Ast.TTuple (elems, _) -> Type_repr.Tuple (Array.of_list (List.map (type_of_syntax env) elems))
  | Ast.TArray (inner, _, _) -> Type_repr.Fixed_array (type_of_syntax env inner, 0)
  | Ast.Slice (inner, _) -> Type_repr.Fixed_array (type_of_syntax env inner, 0)
  | Ast.Option (inner, _) -> (
      match List.assoc_opt "Option" env.types with
      | Some r -> Type_repr.substitute [ (Ids.Generic_param_id.make 0, type_of_syntax env inner) ] r
      | None -> seed_bug "Option type not in env")
  | Ast.Ref (inner, m, _) -> Type_repr.Ref_internal ((if m then Type_repr.Mutable else Type_repr.Immutable), type_of_syntax env inner)
  | Ast.RawPtr (inner, m, _) -> Type_repr.Raw_ptr ((if m then Type_repr.Mutable else Type_repr.Immutable), type_of_syntax env inner)
  | Ast.SelfType _ -> Type_repr.Unit
  | Ast.Inferred _ -> seed_bug "inferred type in lowering position"
  | other -> seed_bug "unsupported type form in lowering: %s" (type_form_name other)

and type_form_name (t : Ast.type_expr) : string =
  match t with
  | Ast.Named (n, _, _) -> "Named " ^ n
  | Ast.Unit _ -> "Unit"
  | Ast.TTuple _ -> "Tuple"
  | Ast.TArray _ -> "Array"
  | Ast.Slice _ -> "Slice"
  | Ast.Option _ -> "Option"
  | Ast.Ref _ -> "Ref"
  | Ast.RawPtr _ -> "RawPtr"
  | Ast.SelfType _ -> "Self"
  | Ast.Inferred _ -> "_"
  | Ast.FnPtr _ -> "FnPtr"
  | Ast.Bounded _ -> "Bounded"
  | Ast.ConstExpr _ -> "ConstExpr"
  | Ast.AssocBinding _ -> "AssocBinding"
  | Ast.Never _ -> "Never"
  | Ast.DynTrait _ -> "dyn"
  | Ast.ImplTrait _ -> "impl"

(* ── Operand/place helpers ────────────────────────────────────── *)

let operand_of_value (_st : lower_state) (v : Seed_mir.constant) : Seed_mir.operand =
  Seed_mir.Constant v

let copy_place (_st : lower_state) (p : Seed_mir.place) : Seed_mir.operand =
  Seed_mir.Copy p

(* Map an AST binary operator to Seed MIR. *)
let bin_op_of (op : Ast.binary_op) : Seed_mir.bin_op =
  match op with
  | Ast.BOr -> Seed_mir.Or
  | Ast.BAnd -> Seed_mir.And
  | Ast.BitOr -> Seed_mir.BitOr
  | Ast.BitXor -> Seed_mir.BitXor
  | Ast.BitAnd -> Seed_mir.BitAnd
  | Ast.Shl -> Seed_mir.Shl
  | Ast.Shr -> Seed_mir.Shr
  | Ast.Add -> Seed_mir.Add
  | Ast.Sub -> Seed_mir.Sub
  | Ast.Mul -> Seed_mir.Mul
  | Ast.Div -> Seed_mir.Div
  | Ast.Mod -> Seed_mir.Rem
  | Ast.Eq -> Seed_mir.Eq
  | Ast.NotEq -> Seed_mir.Ne
  | Ast.Lt -> Seed_mir.Lt
  | Ast.LtEq -> Seed_mir.Le
  | Ast.Gt -> Seed_mir.Gt
  | Ast.GtEq -> Seed_mir.Ge

let int_width_of (k : Type_repr.int_kind) : int =
  match k with
  | Type_repr.I8 | Type_repr.U8 -> 8
  | Type_repr.I16 | Type_repr.U16 -> 16
  | Type_repr.I32 | Type_repr.U32 -> 32
  | Type_repr.I64 | Type_repr.U64 | Type_repr.Int | Type_repr.UInt -> 64
  | Type_repr.I128 | Type_repr.U128 -> 128

let int_signed_of (k : Type_repr.int_kind) : bool =
  match k with
  | Type_repr.I8 | Type_repr.I16 | Type_repr.I32 | Type_repr.I64 | Type_repr.I128
  | Type_repr.Int -> true
  | _ -> false

let int_constant_of (k : Type_repr.int_kind) (i : int64) : Seed_mir.constant =
  Seed_mir.Integer (Int_value.of_int64 ~width:(int_width_of k) ~signed:(int_signed_of k) i)

let int_constant_of_words (k : Type_repr.int_kind) (lo : int64) (hi : int64) : Seed_mir.constant =
  Seed_mir.Integer
    (Int_value.of_words ~width:(int_width_of k) ~signed:(int_signed_of k) ~bits_lo:lo ~bits_hi:hi)

(* ── Expression lowering ──────────────────────────────────────── *)

(* Returns (place-or-constant operand, type). *)
let rec lower_expr (env : func_env) (st : lower_state) (e : Ast.expr) :
    Seed_mir.operand * Type_repr.t =
  match e with
  | Ast.IntLit (lit, _) -> (
      match Literal.parse_integer ~span:Span.synthetic lit with
      | Some p -> (
          let kind =
            match p.Literal.suffix with
            | Literal.I8 -> Type_repr.I8 | Literal.I16 -> Type_repr.I16
            | Literal.I32 -> Type_repr.I32 | Literal.I64 -> Type_repr.I64
            | Literal.I128 -> Type_repr.I128
            | Literal.U8 -> Type_repr.U8 | Literal.U16 -> Type_repr.U16
            | Literal.U32 -> Type_repr.U32 | Literal.U64 -> Type_repr.U64
            | Literal.U128 -> Type_repr.U128
            | Literal.Int -> Type_repr.Int | Literal.UInt -> Type_repr.UInt
            | Literal.No_int_suffix -> Type_repr.Int
          in
          let magnitude = p.Literal.magnitude in
          if Big_nat.fits_ocaml_int magnitude then
            (Seed_mir.Constant (int_constant_of kind (Int64.of_int (Big_nat.to_ocaml_int magnitude))),
             Type_repr.Int kind)
          else if Big_nat.fits_unsigned magnitude 128 then
            let lo, hi = Big_nat.to_words_128 magnitude in
            (Seed_mir.Constant (int_constant_of_words kind lo hi), Type_repr.Int kind)
          else seed_bug "integer literal exceeds 128 bits in lowering")
      | None -> seed_bug "unparseable integer literal '%s'" lit)
  | Ast.FloatLit (lit, _) -> (
      match float_of_string_opt lit with
      | Some f -> (Seed_mir.Constant (Seed_mir.Float64 (Int64.bits_of_float f)), Type_repr.Float Type_repr.F64)
      | None -> seed_bug "unparseable float literal '%s'" lit)
  | Ast.StringLit (s, _) -> (Seed_mir.Constant (Seed_mir.String s), Type_repr.String)
  | Ast.CharLit (c, _) -> (
      let b = Bytes.of_string c in
      match Utf8.decode_at b 0 with
      | Ok (u, _) -> (Seed_mir.Constant (Seed_mir.Char u), Type_repr.Char)
      | Error _ -> seed_bug "invalid char literal")
  | Ast.BoolLit (b, _) -> (Seed_mir.Constant (Seed_mir.Bool b), Type_repr.Bool)
  | Ast.Name (n, _) -> (
      match List.assoc_opt n st.scope with
      | Some id -> (
          match local_type st id with
          | Some ty -> (copy_place st (cur_place st id), ty)
          | None -> seed_bug "local _%d has no type in lowering" id)
      | None -> (
          match ctor_of st.variants n with
          | Some (enum_name, vname) ->
              (* a nullary enum constructor in value position, e.g. `None` *)
              let ty =
                match List.assoc_opt n env.values with
                | Some t -> t
                | None ->
                    seed_bug "enum constructor `%s` has no registered result type in the lowering env" n
              in
              let spec = variant_spec_of env st.variants ~enum_name ~vname ~repr:ty in
              let id = fresh_local st ty in
              emit st
                (Seed_mir.Assign
                   ( cur_place st id,
                     Seed_mir.Aggregate
                       ( Seed_mir.EnumCtor (enum_tid_of env enum_name, Ids.Variant_index.make spec.vs_index),
                         [] ) ));
              (copy_place st (cur_place st id), ty)
          | None -> (
              match List.assoc_opt n env.values with
              | Some _ ->
                  seed_bug "function value `%s` reached lowering without a resolved callable identity" n
              | None -> seed_bug "unknown value '%s' in lowering" n)))
  | Ast.Path (a, b, span) -> (
      ignore span;
      seed_bug "path value `%s::%s` reached lowering without a resolved callable identity" a b)
  | Ast.Binary (l, op, r, _) ->
      let lo, lt = lower_expr env st l in
      let ro, _rt = lower_expr env st r in
      let result_ty =
        match op with
        | Ast.Eq | Ast.NotEq | Ast.Lt | Ast.LtEq | Ast.Gt | Ast.GtEq | Ast.BOr | Ast.BAnd ->
            Type_repr.Bool
        | _ -> lt
      in
      let id = fresh_local st result_ty in
      emit st
        (Seed_mir.Assign
           (cur_place st id, Seed_mir.BinaryOp (bin_op_of op, lo, ro)));
      (copy_place st (cur_place st id), result_ty)
  | Ast.Unary (op, inner, _) -> (
      match op with
      | Ast.Neg ->
          let io, it = lower_expr env st inner in
          let id = fresh_local st it in
          emit st (Seed_mir.Assign (cur_place st id, Seed_mir.UnaryOp (Seed_mir.Neg, io)));
          (copy_place st (cur_place st id), it)
      | Ast.Not ->
          let io, _ = lower_expr env st inner in
          let id = fresh_local st Type_repr.Bool in
          emit st (Seed_mir.Assign (cur_place st id, Seed_mir.UnaryOp (Seed_mir.Not, io)));
          (copy_place st (cur_place st id), Type_repr.Bool)
      | Ast.BitNot ->
          let io, it = lower_expr env st inner in
          let id = fresh_local st it in
          (* ~x = x xor all-ones *)
          let all_ones = Seed_mir.Constant (int_constant_of (int_kind_of it) (-1L)) in
          emit st
            (Seed_mir.Assign (cur_place st id, Seed_mir.BinaryOp (Seed_mir.BitXor, io, all_ones)));
          (copy_place st (cur_place st id), it)
      | Ast.Deref | Ast.Borrow | Ast.BorrowMut ->
          lower_expr env st inner)
  | Ast.Cast (inner, ty, _) ->
      let io, _ = lower_expr env st inner in
      let rt = type_of_syntax env ty in
      let id = fresh_local st rt in
      emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Cast (io, rt)));
      (copy_place st (cur_place st id), rt)
  | Ast.Tuple (elems, _) ->
      (* each element is lowered exactly once *)
      let lowered = List.map (fun e -> lower_expr env st e) elems in
      let ops = List.map fst lowered in
      let tys = List.map snd lowered in
      let rt = Type_repr.Tuple (Array.of_list tys) in
      let id = fresh_local st rt in
      emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Aggregate (Seed_mir.TupleAgg, ops)));
      (copy_place st (cur_place st id), rt)
  | Ast.Array (elems, _) ->
      let lowered = List.map (fun e -> lower_expr env st e) elems in
      let ops = List.map fst lowered in
      let tys = List.map snd lowered in
      let elem_ty =
        match tys with
        | t :: _ -> t
        | [] -> Type_repr.Unit
      in
      let rt = Type_repr.Fixed_array (elem_ty, List.length elems) in
      let id = fresh_local st rt in
      emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Aggregate (Seed_mir.ArrayAgg, ops)));
      (copy_place st (cur_place st id), rt)
  | Ast.Index (base, idx, _) -> (
      let base_op, base_ty = lower_expr env st base in
      let bp = materialize_place st base_op in
      let elem_ty = element_type_of base_ty in
      match idx with
      | Ast.IntLit (s, _) -> (
          match Literal.parse_integer ~span:Span.synthetic s with
          | Some p when Big_nat.fits_ocaml_int p.Literal.magnitude ->
              let k = Big_nat.to_ocaml_int p.Literal.magnitude in
              if k < 0 then seed_bug "negative constant index in lowering";
              let p =
                { bp with Seed_mir.projections = bp.Seed_mir.projections @ [ Seed_mir.ConstantIndex k ] }
              in
              (Seed_mir.Copy p, elem_ty)
          | _ -> seed_bug "index expression is not a constant integer")
      | _ ->
          (* nonconstant index: evaluate the index expression exactly
             once into a fresh local and emit the dynamic
             `Seed_mir.Index <index_local>` projection — the payload is
             the LOCAL whose runtime integer value is the index.  The VM
             executes this form and bounds-checks the runtime index
             value at execution; the verifier checks the index local's
             existence/initialization/type. *)
          let idx_op, idx_ty = lower_expr env st idx in
          let iid = fresh_local st idx_ty in
          emit st (Seed_mir.Assign (cur_place st iid, Seed_mir.Use idx_op));
          let p =
            { bp with Seed_mir.projections = bp.Seed_mir.projections @ [ Seed_mir.Index iid ] }
          in
          (Seed_mir.Copy p, elem_ty))
  | Ast.Field (_, _, span) ->
      ignore span;
      seed_bug "Field access reached MIR lowering without a typed place (FieldId) rule"
  | Ast.IfExpr i -> lower_if env st i
  | Ast.MatchExpr m -> lower_match env st m
  | Ast.WhileExpr w -> lower_while env st w
  | Ast.LoopExpr (b, _) -> lower_loop env st b
  | Ast.Block (b, _) -> lower_block env st b
  | Ast.ReturnExpr (Some e, _) ->
      let vo, _ = lower_expr env st e in
      emit_defers env st;
      emit st (Seed_mir.Assign (cur_place st 0, Seed_mir.Use vo));
      set_terminator st Seed_mir.Ret;
      (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)
  | Ast.ReturnExpr (None, _) ->
      emit_defers env st;
      set_terminator st Seed_mir.Ret;
      (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)
  | Ast.BreakExpr (v, _) -> (
      match st.break_target with
      | Some b ->
          let _ = v in
          set_terminator st (Seed_mir.Goto b);
          (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)
      | None -> seed_bug "break outside loop in lowering")
  | Ast.NextExpr _ -> (
      match st.continue_target with
      | Some b ->
          set_terminator st (Seed_mir.Goto b);
          (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)
      | None -> seed_bug "next outside loop in lowering")
  | Ast.Assign (target, value, _) ->
      let vo, vt = lower_expr env st value in
      (match target with
       | Ast.Name (n, _) -> (
           match List.assoc_opt n st.scope with
           | Some id -> (
               emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Use vo));
               match local_type st id with
               | Some ty -> (copy_place st (cur_place st id), ty)
               | None -> (vo, vt))
           | None -> (
               match List.assoc_opt n env.values with
               | Some ty ->
                   let id = fresh_local st ty in
                   emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Use vo));
                   (copy_place st (cur_place st id), ty)
               | None -> seed_bug "assignment to unknown value '%s'" n))
       | _ ->
           ignore (vo, vt);
           seed_bug "projected assignment reached MIR lowering without a typed-place writeback rule")
  | Ast.CompoundAssign (_, _, _, span) ->
      ignore span;
      seed_bug "CompoundAssign reached MIR lowering without a typed-place writeback rule"
  | Ast.Call (callee, _, args, _) -> lower_call env st callee args
  | Ast.TryOp (inner, _) -> (
      (* `?`: match the Option/Result subject; the success variant (tag
         0) supplies the payload as the expression value; the failure
         variant early-returns from the enclosing function with the
         subject itself (the failure enum value) in the return slot,
         after running the function-level defers (LIFO).  The seed
         representation is Vm_value.Enum (tag, payload); the payload is
         read via [Downcast 0; Field 0]. *)
      let subj_op, subj_ty = lower_expr env st inner in
      let sid = fresh_local st subj_ty in
      emit st (Seed_mir.Assign (cur_place st sid, Seed_mir.Use subj_op));
      (* the error channel is the identity: for Result[T, E] the
         enclosing function's return must be Result[_, E] (the success
         types may differ); for Option[T] the return must be Option[_] *)
      let is_result, err_payload_ty =
        match subj_ty with
        | Type_repr.Named (_, [| _; e |]) -> (true, Some e)
        | Type_repr.Named (_, [| _ |]) -> (false, None)
        | _ -> seed_bug "`?` subject is not an Option/Result (found %s)" (Seed_mir.print_type subj_ty)
      in
      (match env.fn_ret, is_result with
       | Type_repr.Named (_, [| _; e2 |]), true ->
           if
             (match err_payload_ty with
              | Some e1 -> Type_repr.compare e1 e2 <> 0
              | None -> true)
           then
             seed_bug
               "`?` error channel mismatch: subject error %s vs enclosing return error %s"
               (Seed_mir.print_type (Option.get err_payload_ty)) (Seed_mir.print_type e2)
       | Type_repr.Named (_, [| _ |]), false -> ()
       | Type_repr.Named (_, [| _; _ |]), false ->
           seed_bug "`?` Option subject inside a Result-returning function"
       | Type_repr.Named (_, [| _ |]), true ->
           seed_bug "`?` Result subject inside an Option-returning function"
       | _, _ -> seed_bug "`?` enclosing function does not return an Option/Result (found %s)"
                    (Seed_mir.print_type env.fn_ret));
      let payload_ty =
        match subj_ty with
        | Type_repr.Named (_, args) when Array.length args > 0 -> args.(0)
        | _ -> seed_bug "`?` subject has no payload type"
      in
      let did = fresh_local st (Type_repr.Int Type_repr.UInt) in
      emit st (Seed_mir.Assign (cur_place st did, Seed_mir.Discriminant (cur_place st sid)));
      let fail = new_block st in
      let success = new_block st in
      let join = new_block st in
      set_terminator_to st
        (Seed_mir.SwitchInt (copy_place st (cur_place st did), [ (0L, success) ], fail))
        fail;
      (* failure path: defers, then the failure value into the return
         slot, then Ret.  For Option the None is the subject itself; for
         Result the Err(error) is reconstructed from the subject's error
         payload so the enclosing function's (possibly different)
         success type does not matter. *)
      emit_defers env st;
      (match is_result, err_payload_ty with
       | false, _ ->
           emit st (Seed_mir.Assign (cur_place st 0, Seed_mir.Use (Seed_mir.Copy (cur_place st sid))))
       | true, Some e ->
           let eid = fresh_local st e in
           emit st
             (Seed_mir.Assign
                ( cur_place st eid,
                  Seed_mir.Use
                    (Seed_mir.Copy
                       { Seed_mir.local = sid;
                         projections =
                           [ Seed_mir.Downcast (Ids.Variant_index.make 1);
                             Seed_mir.Field (Ids.Field_index.make 0) ] }) ));
           (match env.fn_ret with
            | Type_repr.Named (ret_tid, _) ->
                emit st
                  (Seed_mir.Assign
                     ( cur_place st 0,
                       Seed_mir.Aggregate
                         ( Seed_mir.EnumCtor (ret_tid, Ids.Variant_index.make 1),
                           [ Seed_mir.Copy (cur_place st eid) ] ) ))
            | _ -> seed_bug "`?` Result failure reconstruction: enclosing return is not a nominal")
       | true, None -> seed_bug "`?` Result subject without an error payload");
      set_terminator st Seed_mir.Ret;
      push_block st success;
      set_terminator_to st (Seed_mir.Goto join) join;
      ( Seed_mir.Copy
          { Seed_mir.local = sid; projections = [ Seed_mir.Downcast (Ids.Variant_index.make 0); Seed_mir.Field (Ids.Field_index.make 0) ] },
        payload_ty ))
  | Ast.ForExpr f -> (
      (* A for-loop over a compile-time Array literal is UNROLLED into
         per-element body copies with ConstantIndex element reads.
         Any other iterable lowers to a runtime counter loop: the
         container is evaluated once into a local, a counter local
         counts from 0 to Len(container), and each iteration reads the
         element through the dynamic `Seed_mir.Index <counter>`
         projection — the VM executes the dynamic Index form and
         bounds-checks the runtime index value at execution. *)
      match f.Ast.for_iterable with
      | Ast.Array (elems, _) ->
          if block_has_loop_exit f.Ast.for_body then
            seed_bug
              "break/next inside a literal-unrolled for loop (the unrolled seed form has no loop structure to target)";
          let arr_op, arr_ty = lower_expr env st f.Ast.for_iterable in
          let arr_id = materialize_place st arr_op in
          let elem_ty = element_type_of arr_ty in
          let bindings =
            match f.Ast.for_pattern with
            | Ast.PatIdent (n, _, _) -> [ (n, fresh_local st elem_ty) ]
            | Ast.Wildcard _ -> []
            | _ -> seed_bug "unsupported for-loop pattern in lowering (bind by name or _)"
          in
          List.iter (fun (n, id) -> st.scope <- (n, id) :: st.scope) bindings;
          List.iteri
            (fun i _ ->
              List.iter
                (fun (_, id) ->
                  emit st
                    (Seed_mir.Assign
                       ( cur_place st id,
                         Seed_mir.Use
                           (Seed_mir.Copy
                              { Seed_mir.local = arr_id.Seed_mir.local;
                                projections = [ Seed_mir.ConstantIndex i ] }) )))
                bindings;
              ignore (lower_block env st f.Ast.for_body))
            elems;
          (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)
      | _ -> (
          let arr_op, arr_ty = lower_expr env st f.Ast.for_iterable in
          match arr_ty with
          | Type_repr.Fixed_array (elem_ty, _) ->
              let arr_id = materialize_place st arr_op in
              (* counter local: UInt so the Len comparison is well-typed
                 (the verifier types Len as UInt) and UInt is an allowed
                 dynamic-index type *)
              let cid = fresh_local st (Type_repr.Int Type_repr.UInt) in
              emit st
                (Seed_mir.Assign
                   ( cur_place st cid,
                     Seed_mir.Use
                       (Seed_mir.Constant (int_constant_of Type_repr.UInt 0L)) ));
              let len_id = fresh_local st (Type_repr.Int Type_repr.UInt) in
              emit st (Seed_mir.Assign (cur_place st len_id, Seed_mir.Len arr_id));
              let head_b = new_block st in
              let body_b = new_block st in
              let incr_b = new_block st in
              let join_b = new_block st in
              set_terminator st (Seed_mir.Goto head_b);
              push_block st head_b;
              let cnd_id = fresh_local st Type_repr.Bool in
              emit st
                (Seed_mir.Assign
                   ( cur_place st cnd_id,
                     Seed_mir.BinaryOp
                       ( Seed_mir.Lt,
                         copy_place st (cur_place st cid),
                         copy_place st (cur_place st len_id) ) ));
              set_terminator st
                (Seed_mir.SwitchInt
                   (copy_place st (cur_place st cnd_id), [ (1L, body_b) ], join_b));
              push_block st body_b;
              let bindings =
                match f.Ast.for_pattern with
                | Ast.PatIdent (n, _, _) -> [ (n, fresh_local st elem_ty) ]
                | Ast.Wildcard _ -> []
                | _ -> seed_bug "unsupported for-loop pattern in lowering (bind by name or _)"
              in
              List.iter (fun (n, id) -> st.scope <- (n, id) :: st.scope) bindings;
              List.iter
                (fun (_, id) ->
                  emit st
                    (Seed_mir.Assign
                       ( cur_place st id,
                         Seed_mir.Use
                           (Seed_mir.Copy
                              { Seed_mir.local = arr_id.Seed_mir.local;
                                projections = [ Seed_mir.Index cid ] }) )))
                bindings;
              let saved_break = st.break_target in
              let saved_continue = st.continue_target in
              st.break_target <- Some join_b;
              st.continue_target <- Some incr_b;
              ignore (lower_block env st f.Ast.for_body);
              st.break_target <- saved_break;
              st.continue_target <- saved_continue;
              set_terminator st (Seed_mir.Goto incr_b);
              push_block st incr_b;
              emit st
                (Seed_mir.Assign
                   ( cur_place st cid,
                     Seed_mir.BinaryOp
                       ( Seed_mir.Add,
                         copy_place st (cur_place st cid),
                         Seed_mir.Constant (int_constant_of Type_repr.UInt 1L) ) ));
              set_terminator st (Seed_mir.Goto head_b);
              push_block st join_b;
              (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)
          | _ ->
              seed_bug
                "runtime for-loop over a non-array iterable of type %s is not lowered (the seed verifier admits dynamic Index/Len only on Fixed_array bases; lower it to an Array literal for the unrolled path)"
                (Seed_mir.print_type arr_ty)))
  | other -> seed_bug "unhandled supported expression form: %s" (expr_form_name other)

and int_kind_of (t : Type_repr.t) : Type_repr.int_kind =
  match t with
  | Type_repr.Int k -> k
  | _ -> Type_repr.Int

and expr_form_name (e : Ast.expr) : string =
  match e with
  | Ast.IntLit _ -> "IntLit"
  | Ast.FloatLit _ -> "FloatLit"
  | Ast.StringLit _ -> "StringLit"
  | Ast.CharLit _ -> "CharLit"
  | Ast.BoolLit _ -> "BoolLit"
  | Ast.Name (n, _) -> "Name " ^ n
  | Ast.Path _ -> "Path"
  | Ast.Array _ -> "Array"
  | Ast.ArrayRepeat _ -> "ArrayRepeat"
  | Ast.Tuple _ -> "Tuple"
  | Ast.StructLit _ -> "StructLit"
  | Ast.Block _ -> "Block"
  | Ast.UnsafeBlock _ -> "UnsafeBlock"
  | Ast.IfExpr _ -> "If"
  | Ast.Call _ -> "Call"
  | Ast.Index _ -> "Index"
  | Ast.Range _ -> "Range"
  | Ast.MatchExpr _ -> "Match"
  | Ast.Cast _ -> "Cast"
  | Ast.TryOp _ -> "TryOp"
  | Ast.Closure _ -> "Closure"
  | Ast.Unary _ -> "Unary"
  | Ast.Field _ -> "Field"
  | Ast.Binary _ -> "Binary"
  | Ast.AwaitExpr _ -> "Await"
  | Ast.MacroCall (n, _, _) -> "MacroCall " ^ n
  | Ast.Assign _ -> "Assign"
  | Ast.CompoundAssign _ -> "CompoundAssign"
  | Ast.ReturnExpr _ -> "Return"
  | Ast.BreakExpr _ -> "Break"
  | Ast.NextExpr _ -> "Next"
  | Ast.ForExpr _ -> "For"
  | Ast.WhileExpr _ -> "While"
  | Ast.LoopExpr _ -> "Loop"
  | Ast.HandleExpr _ -> "Handle"
  | Ast.UnlessExpr _ -> "Unless"
  | Ast.UntilExpr _ -> "Until"
  | Ast.TryBlock _ -> "Try"
  | Ast.ComptimeBlock _ -> "Comptime"

and field_type_of (base : Type_repr.t) (fname : string) : Type_repr.t =
  match base with
  | Type_repr.Named _ -> (
      match int_of_string_opt fname with
      | Some _ -> Type_repr.Int Type_repr.Int
      | None -> Type_repr.Unit)
  | Type_repr.Tuple _ -> Type_repr.Unit
  | _ -> Type_repr.Unit

and target_type (env : func_env) (target : Ast.expr) : Type_repr.t =
  match target with
  | Ast.Name (n, _) -> (
      match List.assoc_opt n env.values with
      | Some ty -> ty
      | None -> seed_bug "assignment target '%s' unknown" n)
  | _ -> Type_repr.Unit

and lower_block (env : func_env) (st : lower_state) (b : Ast.block_body) : Seed_mir.operand * Type_repr.t =
  List.iter (fun s -> lower_stmt env st s) b.Ast.b_stmts;
  match b.Ast.b_tail with
  | Some t -> lower_expr env st t
  | None -> (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)

and lower_stmt (env : func_env) (st : lower_state) (s : Ast.stmt) : unit =
  match s with
  | Ast.ExprStmt (e, _) ->
      ignore (lower_expr env st e)
  | Ast.LetBinding (pat, _, _ty, value, _) ->
      let vo, vt = lower_expr env st value in
      let name =
        match pat with
        | Ast.PatIdent (n, _, _) -> Some n
        | _ -> None
      in
      let id = fresh_local st vt in
      emit st (Seed_mir.Assign (cur_place st id, Seed_mir.Use vo));
      (match name with
       | Some n ->
           st.local_names <- (id, n) :: st.local_names;
           st.scope <- (n, id) :: st.scope
       | None -> ())
  | Ast.DeferStmt (b, _) ->
      (* FRONTEND-SUPPORTED (not yet executable-seed-supported per the
         audit): the function-level LIFO stack is an approximation —
         conditional/loop scopes flatten to function level, so a defer
         inside an untaken branch would still run. The audit's exact
         scope-tree + CFG-exit-edge cleanup model is the required
         redesign; until then this construct is documented as
         frontend-supported and its lowering is approximate. *)
      if block_has_return b then seed_bug "defer bodies may not contain `return`";
      st.defer_stack <- b :: st.defer_stack
  | Ast.Item _ -> ()
  | Ast.AttributeStmt _ | Ast.Attributed _ -> ()

and lower_if (env : func_env) (st : lower_state) (i : Ast.if_expr) : Seed_mir.operand * Type_repr.t =
  let arms = (i.Ast.if_condition, i.Ast.if_then) :: i.Ast.if_elsif in
  let join_b = new_block st in
  let result_ty = ref Type_repr.Unit in
  let result_id = ref 0 in
  let has_result = ref false in
  (* Emit an arm chain; returns the block where the else/join continues. *)
  let rec emit_arms arms (fall_b : int) : int =
    match arms with
    | [] -> fall_b
    | (c, b) :: rest ->
        let then_b = new_block st in
        let cnd, _ = lower_expr env st c in
        let cid = fresh_local st Type_repr.Bool in
        emit st (Seed_mir.Assign (cur_place st cid, Seed_mir.Use cnd));
        let next_fall = new_block st in
        set_terminator_to st
          (Seed_mir.SwitchInt (copy_place st (cur_place st cid), [ (1L, then_b) ], next_fall))
          then_b;
        let bval, bty = lower_block env st b in
        if not !has_result then begin
          result_ty := bty;
          result_id := fresh_local st bty;
          has_result := true
        end;
        emit st (Seed_mir.Assign (cur_place st !result_id, Seed_mir.Use bval));
        set_terminator_to st (Seed_mir.Goto join_b) next_fall;
        emit_arms rest next_fall
  in
  let else_cont = emit_arms arms join_b in
  (match i.Ast.if_else with
   | Some eb ->
       if st.cur_block <> else_cont then
         set_terminator_to st (Seed_mir.Goto else_cont) else_cont;
       let eb_val, eb_ty = lower_block env st eb in
       if not !has_result then begin
         result_ty := eb_ty;
         result_id := fresh_local st eb_ty;
         has_result := true
       end;
       emit st (Seed_mir.Assign (cur_place st !result_id, Seed_mir.Use eb_val));
       set_terminator_to st (Seed_mir.Goto join_b) join_b
   | None ->
       if st.cur_block <> join_b then
         set_terminator_to st (Seed_mir.Goto join_b) join_b);
  (* the join block stays open for the continuation *)
  if !has_result then (copy_place st (cur_place st !result_id), !result_ty)
  else (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)

and lower_match (env : func_env) (st : lower_state) (m : Ast.match_expr) :
    Seed_mir.operand * Type_repr.t =
  let subj_op, subj_ty = lower_expr env st m.Ast.m_subject in
  let sid = fresh_local st subj_ty in
  emit st (Seed_mir.Assign (cur_place st sid, Seed_mir.Use subj_op));
  let join_b = new_block st in
  (* one result local shared by every arm (the typechecker unifies arm
     bodies, so the first body's type is the match's type) *)
  let result_id = ref 0 in
  let result_ty : Type_repr.t option ref = ref None in
  let ensure_result ty =
    match !result_ty with
    | None ->
        result_id := fresh_local st ty;
        result_ty := Some ty
    | Some _ -> ()
  in
  if
    List.length
      (List.filter (fun (a : Ast.match_arm) -> match a.Ast.ma_pattern with Ast.Wildcard _ -> true | _ -> false) m.Ast.m_arms)
    > 1
  then seed_bug "multiple wildcard arms in match lowering";
  if List.exists (fun (a : Ast.match_arm) -> a.Ast.ma_guard <> None) m.Ast.m_arms then
    seed_bug "match arm guards are not supported in seed lowering";
  let arm_blocks = Array.of_list (List.map (fun _ -> new_block st) m.Ast.m_arms) in
  let wildcard_idx =
    let rec go i = function
      | [] -> None
      | (a : Ast.match_arm) :: rest -> (
          match a.Ast.ma_pattern with
          | Ast.Wildcard _ -> Some i
          | _ -> go (i + 1) rest)
    in
    go 0 m.Ast.m_arms
  in
  (* The switch's otherwise: the wildcard arm's block when one exists,
     else a dedicated Abort block.  The Abort form is important for the
     verifier's definite-initialization dataflow: the switch's otherwise
     target is a JOIN predecessor, so routing the fallthrough to the
     join block itself would make the match result look
     possibly-uninitialized there.  An Abort block has no successors, so
     the join's only predecessors are the arms (each of which assigns
     the result).  Reaching the Abort at runtime means the match was
     non-exhaustive — a deterministic trap, never silent. *)
  let abort_block = ref None in
  let otherwise =
    match wildcard_idx with
    | Some i -> arm_blocks.(i)
    | None ->
        let b = new_block st in
        abort_block := Some b;
        b
  in
  let has_variant =
    List.exists (fun (a : Ast.match_arm) -> match a.Ast.ma_pattern with Ast.PatVariant _ -> true | _ -> false) m.Ast.m_arms
  in
  let switch_op =
    if has_variant then begin
      (* enum subject: the discriminant test over the variant tags *)
      let did = fresh_local st (Type_repr.Int Type_repr.UInt) in
      emit st (Seed_mir.Assign (cur_place st did, Seed_mir.Discriminant (cur_place st sid)));
      cur_place st did
    end
    else cur_place st sid
  in
  let targets = ref [] in
  List.iteri
    (fun i (a : Ast.match_arm) ->
      match a.Ast.ma_pattern with
      | Ast.PatVariant (seg1, seg2, _, _) -> (
          let enum_name =
            if seg1 = "" then enum_name_of_ty env subj_ty
            else begin
              (* qualified `Enum::Variant`: trust the qualifier *)
              if List.assoc_opt seg1 env.types = None then
                seed_bug "variant qualifier `%s` is not a known type in lowering" seg1;
              seg1
            end
          in
          let spec = variant_spec_of env st.variants ~enum_name ~vname:seg2 ~repr:subj_ty in
          targets := (Int64.of_int spec.vs_index, arm_blocks.(i)) :: !targets)
      | Ast.PatLiteral (Ast.IntLit (s, _), _) -> (
          match int_of_string_opt s with
          | Some v -> targets := (Int64.of_int v, arm_blocks.(i)) :: !targets
          | None -> seed_bug "non-integer literal match arm in lowering")
      | Ast.Wildcard _ -> ()
      | _ -> seed_bug "unsupported match pattern in lowering")
    m.Ast.m_arms;
  set_terminator_to st
    (Seed_mir.SwitchInt (copy_place st switch_op, List.rev !targets, otherwise))
    arm_blocks.(0);
  (* lower each arm body into its block *)
  List.iteri
    (fun i (a : Ast.match_arm) ->
      if i > 0 then push_block st arm_blocks.(i);
      (match a.Ast.ma_pattern with
       | Ast.PatVariant (seg1, seg2, pats, _) -> (
           let enum_name =
             if seg1 = "" then enum_name_of_ty env subj_ty
             else begin
               if List.assoc_opt seg1 env.types = None then
                 seed_bug "variant qualifier `%s` is not a known type in lowering" seg1;
               seg1
             end
           in
           let spec = variant_spec_of env st.variants ~enum_name ~vname:seg2 ~repr:subj_ty in
           (* bind the payload fields by projecting the subject; the
              seed VM's Downcast turns the payload into a Struct and
              Field picks field i *)
           List.iteri
             (fun j pat ->
               match pat with
               | Ast.PatIdent (name, _, _) -> (
                   let fty =
                     match List.nth_opt spec.vs_fields j with
                     | Some t -> t
                     | None -> seed_bug "variant `%s` payload pattern has more fields than the variant" seg2
                   in
                   if not (copyable_ty fty) then
                     seed_bug
                       "non-Copy payload binding in a variant match arm is not supported by the seed VM (a projected Move is not executable; payload type %s)"
                       (Seed_mir.print_type fty);
                   let id = fresh_local st fty in
                   emit st
                     (Seed_mir.Assign
                        ( cur_place st id,
                          Seed_mir.Use
                            (Seed_mir.Copy
                               { Seed_mir.local = sid;
                                 projections =
                                   [
                                     Seed_mir.Downcast (Ids.Variant_index.make spec.vs_index);
                                     Seed_mir.Field (Ids.Field_index.make j);
                                   ] }) ));
                   st.scope <- (name, id) :: st.scope)
               | Ast.Wildcard _ -> ()
               | _ -> seed_bug "unsupported variant payload pattern in lowering")
             pats)
       | Ast.Wildcard _ | Ast.PatLiteral _ -> ()
       | _ -> seed_bug "unsupported match arm pattern in lowering");
      let bval, bty = lower_expr env st a.Ast.ma_body in
      ensure_result bty;
      emit st (Seed_mir.Assign (cur_place st !result_id, Seed_mir.Use bval));
      if i = Array.length arm_blocks - 1 then begin
        match !abort_block with
        | Some abort_b ->
            (* close the arm block; fill the Abort fallthrough through
               the dead-block pattern; leave the join open *)
            set_terminator st (Seed_mir.Goto join_b);
            push_block st abort_b;
            set_terminator st Seed_mir.Abort;
            push_block st join_b
        | None -> set_terminator_to st (Seed_mir.Goto join_b) join_b
      end
      else set_terminator st (Seed_mir.Goto join_b))
    m.Ast.m_arms;
  (* join block stays open for the continuation *)
  match !result_ty with
  | Some ty -> (copy_place st (cur_place st !result_id), ty)
  | None -> (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)

and lower_while (env : func_env) (st : lower_state) (w : Ast.while_expr) :
    Seed_mir.operand * Type_repr.t =
  let head_b = new_block st in
  let body_b = new_block st in
  let join_b = new_block st in
  set_terminator st (Seed_mir.Goto head_b);
  push_block st head_b;
  let cond, _ = lower_expr env st w.Ast.wh_condition in
  let cid = fresh_local st Type_repr.Bool in
  emit st (Seed_mir.Assign (cur_place st cid, Seed_mir.Use cond));
  set_terminator st (Seed_mir.SwitchInt (copy_place st (cur_place st cid), [ (1L, body_b) ], join_b));
  push_block st body_b;
  let saved_break = st.break_target in
  let saved_continue = st.continue_target in
  st.break_target <- Some join_b;
  st.continue_target <- Some head_b;
  ignore (lower_block env st w.Ast.wh_body);
  st.break_target <- saved_break;
  st.continue_target <- saved_continue;
  set_terminator st (Seed_mir.Goto head_b);
  push_block st join_b;
  (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)

and lower_loop (env : func_env) (st : lower_state) (b : Ast.block_body) :
    Seed_mir.operand * Type_repr.t =
  let body_b = new_block st in
  let join_b = new_block st in
  set_terminator st (Seed_mir.Goto body_b);
  push_block st body_b;
  let saved_break = st.break_target in
  let saved_continue = st.continue_target in
  st.break_target <- Some join_b;
  st.continue_target <- Some body_b;
  ignore (lower_block env st b);
  st.break_target <- saved_break;
  st.continue_target <- saved_continue;
  set_terminator st (Seed_mir.Goto body_b);
  push_block st join_b;
  (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)

and lower_call (env : func_env) (st : lower_state) (callee : Ast.expr)
    (args : Ast.call_arg list) : Seed_mir.operand * Type_repr.t =
  match callee with
  | Ast.Name (n, _) -> (
      match ctor_of st.variants n with
      | Some (enum_name, vname) ->
          (* an enum variant constructor call: `Some(x)`, `Green(7)`,
             `Err("...")` — built as an EnumCtor aggregate with the
             declaration-order variant index as the tag *)
          let ty =
            match List.assoc_opt n env.values with
            | Some t -> t
            | None ->
                seed_bug "enum constructor `%s` has no registered result type in the lowering env" n
          in
          let spec = variant_spec_of env st.variants ~enum_name ~vname ~repr:ty in
          let arg_ops = List.map (fun a -> fst (lower_expr env st a.Ast.ca_value)) args in
          let id = fresh_local st ty in
          emit st
            (Seed_mir.Assign
               ( cur_place st id,
                 Seed_mir.Aggregate
                   ( Seed_mir.EnumCtor (enum_tid_of env enum_name, Ids.Variant_index.make spec.vs_index),
                     arg_ops ) ));
          (copy_place st (cur_place st id), ty)
      | None -> (
          match List.assoc_opt n env.callables with
          | Some entry ->
              let cid = entry.ce_callable in
              let ty =
                match List.assoc_opt n env.values with Some t -> t | None -> Type_repr.Unit
              in
              let arg_ops = List.map (fun a -> fst (lower_expr env st a.Ast.ca_value)) args in
              let id = fresh_local st ty in
              let rp = cur_place st id in
              let arg_vals =
                Array.of_list
                  (List.map
                     (fun op -> { Seed_mir.effect_ = Access_effect.Read; value = op })
                     arg_ops)
              in
              let next_b = new_block st in
              (* the concrete call-substitution arrives with the typed
                 lowering channel; until then, non-generic calls (the
                 kernel closure has zero generic defs) carry [||] and the
                 mono arity pairing stays exact. *)
              set_terminator_to st
                (Seed_mir.Call (rp, Seed_mir.User (Instance_id.make ~callable:(Ids.Callable_id.make cid) ~type_args:[||]), arg_vals, next_b, None))
                next_b;
              (copy_place st rp, ty)
          | None -> seed_bug "unknown callee '%s' in lowering" n))
  | Ast.Field (_, mname, span) -> (
      ignore span;
      seed_bug "method call `%s` reached lowering without a resolved receiver-typed instance" mname)
  | _ -> seed_bug "unsupported callee form in lowering"

and emit_defers (env : func_env) (st : lower_state) : unit =
  List.iter (fun b -> ignore (lower_block env st b)) st.defer_stack

(* ── Function lowering ────────────────────────────────────────── *)

let lower_function_with_variants (variants : variant_table) (env : func_env) (name : string)
    (callable : int) (template_args : Type_repr.t array) (fn : Ast.function_decl) :
    Seed_mir.function_ =
  let st =
    {
      next_local = 0;
      next_block = 0;
      locals = [||];
      local_names = [];
      scope = [];
      blocks = [];
      cur_block = 0;
      cur_stmts = [];
      break_target = None;
      continue_target = None;
      variants;
      defer_stack = [];
    }
  in
  (* local 0 = return slot *)
  let ret_ty = env.fn_ret in
  ignore (fresh_local st ret_ty);
  (* params *)
  let param_tys =
    List.map
      (fun (p : Ast.param) -> type_of_syntax env p.Ast.p_type)
      fn.Ast.fn_sig.Ast.sig_params
  in
  let param_ids =
    List.map
      (fun ty -> fresh_local st ty)
      param_tys
  in
  List.iter2
    (fun (p : Ast.param) id -> st.scope <- (p.Ast.p_name, id) :: st.scope)
    fn.Ast.fn_sig.Ast.sig_params param_ids;
  (* pre-entry block: the initial empty bb0 routes to the real entry *)
  ignore (new_block st);
  let entry = new_block st in
  push_block st entry;
  let result =
    match fn.Ast.fn_body with
    | Ast.FnBlock b -> Some (lower_block env st b)
    | Ast.FnExpr e -> Some (lower_expr env st e)
    | Ast.FnSignatureOnly -> None
  in
  (* the function's final implicit return runs the defers (LIFO) BEFORE
     the return slot is assigned, so mutations made by the defers are
     observable in the returned value (explicit returns lower the same
     order) *)
  emit_defers env st;
  (match result with
   | Some (vo, _) -> emit st (Seed_mir.Assign (cur_place st 0, Seed_mir.Use vo))
   | None -> ());
  set_terminator st Seed_mir.Ret;
  let params = Array.of_list (List.map (fun ty -> (None, ty)) param_tys) in
  {
    Seed_mir.name;
    (* the template instance carries the declaration-order generic params,
       so monomorphization can build exact substitutions *)
    instance =
      Instance_id.make ~callable:(Ids.Callable_id.make callable) ~type_args:template_args;
    params;
    locals = st.locals;
    blocks =
      Array.of_list
        (List.sort (fun a b -> compare a.Seed_mir.id b.Seed_mir.id) (List.rev st.blocks));
    entry;
  }

(* The public entry point used by the driver: lowers with the builtin
   variant table (Option/Result) only.  User-defined enums need
   lower_function_with_variants. *)
let lower_function (env : func_env) (name : string) (callable : int) (fn : Ast.function_decl) :
    Seed_mir.function_ =
  lower_function_with_variants default_variant_table env name callable [||] fn

(* ── Statics/consts (audit §35) ─────────────────────────────────
   TODO: Ast.ConstDecl/Ast.StaticDecl exist and the typechecker keeps a
   `consts` registry, but the Mir_lower API carries no const/static
   value table and every caller (driver.ml) passes `statics = [||]`.
   A const/static reference in lowering position therefore reaches
   lower_expr's Name case without a scope/callable/constructor entry and
   fails closed with `unknown value` — the seed does not invent a
   representation for typechecker-registered consts it cannot lower
   soundly (a const is a value, not an addressable global, and the
   seed's operands have no init/load form).  Wiring real consts into
   func_env (name -> (repr, constant)) and lowering Name references to
   Constant operands is the follow-up; it requires extending the
   Mir_lower API and the driver's lowering_env_of together. *)
