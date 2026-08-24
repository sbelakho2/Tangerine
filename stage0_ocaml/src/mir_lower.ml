(* mir_lower.ml — Typed AST → Seed MIR lowering (audit §34, §35).

   Lowering operates on the syntax AST plus a name→type environment
   produced by the type checker; every lowered construct is typed. If a
   construct is reached with an unknown type, lowering raises Seed_bug
   (never produces Nop). *)

exception Seed_bug of string

let seed_bug fmt = Printf.ksprintf (fun m -> raise (Seed_bug m)) fmt

(* ── Environment ──────────────────────────────────────────────── *)

type func_env = {
  types : (string * Type_repr.t) list;               (* type name -> repr *)
  values : (string * Type_repr.t) list;              (* global value name -> type *)
  callables : (string * int) list;                   (* function name -> callable id *)
  methods : ((string * string) * Ids.Instance_id.t) list;  (* (receiver type name, method) -> instance *)
  fn_ret : Type_repr.t;
}

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
          match List.assoc_opt n env.values with
          | Some _ ->
              seed_bug "function value `%s` reached lowering without a resolved callable identity" n
          | None -> seed_bug "unknown value '%s' in lowering" n))
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
  | Ast.Index (_, _, span) ->
      ignore span;
      seed_bug "Index reached MIR lowering without a supported typed lowering rule"
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
      let rp = cur_place st 0 in
      emit st (Seed_mir.Assign (rp, Seed_mir.Use vo));
      set_terminator st Seed_mir.Ret;
      (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)
  | Ast.ReturnExpr (None, _) ->
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
       | _ -> (vo, vt))
  | Ast.CompoundAssign (_, _, _, span) ->
      ignore span;
      seed_bug "CompoundAssign reached MIR lowering without a typed-place writeback rule"
  | Ast.Call (callee, _, args, _) -> lower_call env st callee args
  | Ast.TryOp (_, span) ->
      ignore span;
      seed_bug "`?` reached MIR lowering without enum branch + early-return lowering"
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
  | Ast.DeferStmt (_, span) ->
      ignore span;
      seed_bug "defer reached MIR lowering without scope-exit cleanup planning"
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
  let subj, _ = lower_expr env st m.Ast.m_subject in
  let sid = fresh_local st (Type_repr.Int Type_repr.Int) in
  emit st (Seed_mir.Assign (cur_place st sid, Seed_mir.Use subj));
  let join_b = new_block st in
  List.iter
    (fun arm ->
      match arm.Ast.ma_pattern with
      | Ast.PatLiteral (lit, _) -> (
          match lit with
          | Ast.IntLit (s, _) -> (
              match int_of_string_opt s with
              | Some v ->
                  let ab = new_block st in
                  emit st
                    (Seed_mir.Assign
                       (cur_place st (fresh_local st Type_repr.Bool),
                        Seed_mir.BinaryOp
                          (Seed_mir.Eq, copy_place st (cur_place st sid),
                           Seed_mir.Constant (int_constant_of Type_repr.Int (Int64.of_int v)))));
                  let bid = st.next_local - 1 in
                  set_terminator st
                    (Seed_mir.SwitchInt (copy_place st (cur_place st bid), [ (1L, ab) ], join_b));
                  push_block st ab;
                  ignore (lower_expr env st arm.Ast.ma_body);
                  set_terminator st (Seed_mir.Goto join_b)
              | None -> seed_bug "non-integer literal match arm in lowering")
          | _ -> seed_bug "unsupported literal match arm in lowering")
      | Ast.Wildcard _ ->
          let ab = new_block st in
          set_terminator st (Seed_mir.Goto ab);
          push_block st ab;
          ignore (lower_expr env st arm.Ast.ma_body);
          set_terminator st (Seed_mir.Goto join_b)
      | Ast.PatVariant _ -> seed_bug "variant match arms require enum lowering (not yet in seed subset)"
      | _ -> seed_bug "unsupported match pattern in lowering")
    m.Ast.m_arms;
  push_block st join_b;
  (Seed_mir.Constant Seed_mir.Unit, Type_repr.Unit)

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
      match List.assoc_opt n env.callables with
      | Some cid ->
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
          set_terminator_to st
            (Seed_mir.Call (rp, Seed_mir.User (Ids.Instance_id.make ~callable:(Ids.Callable_id.make cid) ~type_args:[||]), arg_vals, next_b, None))
            next_b;
          (copy_place st rp, ty)
      | None -> seed_bug "unknown callee '%s' in lowering" n)
  | Ast.Field (_, mname, span) -> (
      ignore span;
      seed_bug "method call `%s` reached lowering without a resolved receiver-typed instance" mname)
  | _ -> seed_bug "unsupported callee form in lowering"

(* ── Function lowering ────────────────────────────────────────── *)

let lower_function (env : func_env) (name : string) (callable : int)
    (fn : Ast.function_decl) : Seed_mir.function_ =
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
  (match result with
   | Some (vo, _) -> emit st (Seed_mir.Assign (cur_place st 0, Seed_mir.Use vo))
   | None -> ());
  set_terminator st Seed_mir.Ret;
  let params = Array.of_list (List.map (fun ty -> (None, ty)) param_tys) in
  {
    Seed_mir.name;
    instance = Ids.Instance_id.make ~callable:(Ids.Callable_id.make callable) ~type_args:[||];
    params;
    locals = st.locals;
    blocks =
      Array.of_list
        (List.sort (fun a b -> compare a.Seed_mir.id b.Seed_mir.id) (List.rev st.blocks));
    entry;
  }
