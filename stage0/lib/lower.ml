(** Lower AST to MIR *)

open Ast

(** MIR builder state *)
type builder = {
  mutable locals : Mir.local_decl list;
  mutable blocks : Mir.basic_block list;
  mutable current_block : Mir.statement list;
  mutable next_local : int;
  mutable env : (string * Mir.local) list;
}

let create_builder () = {
  locals = [];
  blocks = [];
  current_block = [];
  next_local = 0;
  env = [];
}

(** Allocate a new local variable *)
let alloc_local builder name ty mutable_ =
  let local = builder.next_local in
  builder.next_local <- builder.next_local + 1;
  builder.locals <- builder.locals @ [{
    Mir.ld_name = name;
    ld_ty = ty;
    ld_mutable = mutable_;
  }];
  local

(** Create a temporary local *)
let alloc_temp builder ty =
  alloc_local builder None ty false

(** Add a statement to current block *)
let add_stmt builder stmt =
  builder.current_block <- builder.current_block @ [stmt]

(** Finish current block with terminator *)
let finish_block builder term =
  let block = {
    Mir.bb_statements = builder.current_block;
    bb_terminator = term;
  } in
  let block_id = List.length builder.blocks in
  builder.blocks <- builder.blocks @ [block];
  builder.current_block <- [];
  block_id

(** Start a new block (for control flow) *)
let new_block builder =
  List.length builder.blocks + 1

(** Place for a local variable *)
let place_of_local local =
  { Mir.local; projection = [] }

(** Convert AST binop to MIR binop *)
let lower_binop = function
  | OpAdd -> Mir.BinAdd
  | OpSub -> Mir.BinSub
  | OpMul -> Mir.BinMul
  | OpDiv -> Mir.BinDiv
  | OpMod -> Mir.BinRem
  | OpEq -> Mir.BinEq
  | OpNe -> Mir.BinNe
  | OpLt -> Mir.BinLt
  | OpGt -> Mir.BinGt
  | OpLe -> Mir.BinLe
  | OpGe -> Mir.BinGe
  | OpAnd -> Mir.BinAnd
  | OpOr -> Mir.BinOr
  | OpBitAnd -> Mir.BinBitAnd
  | OpBitOr -> Mir.BinBitOr
  | OpBitXor -> Mir.BinBitXor
  | OpShl -> Mir.BinShl
  | OpShr -> Mir.BinShr
  | _ -> Mir.BinAdd  (* Assignments handled separately *)

(** Convert AST unop to MIR unop *)
let lower_unop = function
  | OpNeg -> Some Mir.UnNeg
  | OpNot -> Some Mir.UnNot
  | _ -> None

(** Lower a literal to MIR constant *)
let lower_literal = function
  | LitInt (n, _) -> Mir.ConstInt n
  | LitFloat f -> Mir.ConstFloat f
  | LitBool b -> Mir.ConstBool b
  | LitChar c -> Mir.ConstChar c
  | LitString s -> Mir.ConstString s
  | LitUnit -> Mir.ConstUnit

(** Lower expression, returns place where result is stored *)
let rec lower_expr builder (e : expr) : Mir.place =
  match e.expr_desc with
  | ExprLit lit ->
    let result = alloc_temp builder (Types.TPrim Types.TInt) in (* TODO: proper type *)
    add_stmt builder (Mir.StmtAssign (
      place_of_local result,
      Mir.RvUse (Mir.OpConst (lower_literal lit))
    ));
    place_of_local result
    
  | ExprPath path ->
    let name = String.concat "::" (List.map (fun i -> i.name) path.segments) in
    begin match List.assoc_opt name builder.env with
    | Some local -> place_of_local local
    | None ->
      (* Unknown variable - create error placeholder *)
      let result = alloc_temp builder Types.TError in
      place_of_local result
    end
    
  | ExprBinop (op, e1, e2) ->
    let p1 = lower_expr builder e1 in
    let p2 = lower_expr builder e2 in
    let result = alloc_temp builder (Types.TPrim Types.TInt) in
    add_stmt builder (Mir.StmtAssign (
      place_of_local result,
      Mir.RvBinaryOp (lower_binop op, Mir.OpMove p1, Mir.OpMove p2)
    ));
    place_of_local result
    
  | ExprUnop (OpRef, e1) ->
    let p1 = lower_expr builder e1 in
    let result = alloc_temp builder (Types.TRef (Types.Immutable, Types.TError)) in
    add_stmt builder (Mir.StmtAssign (
      place_of_local result,
      Mir.RvRef (false, p1)
    ));
    place_of_local result
    
  | ExprUnop (OpRefMut, e1) ->
    let p1 = lower_expr builder e1 in
    let result = alloc_temp builder (Types.TRef (Types.Mutable, Types.TError)) in
    add_stmt builder (Mir.StmtAssign (
      place_of_local result,
      Mir.RvRef (true, p1)
    ));
    place_of_local result
    
  | ExprUnop (OpDeref, e1) ->
    let p1 = lower_expr builder e1 in
    { p1 with projection = p1.projection @ [Mir.ProjDeref] }
    
  | ExprUnop (op, e1) ->
    let p1 = lower_expr builder e1 in
    begin match lower_unop op with
    | Some mir_op ->
      let result = alloc_temp builder (Types.TPrim Types.TInt) in
      add_stmt builder (Mir.StmtAssign (
        place_of_local result,
        Mir.RvUnaryOp (mir_op, Mir.OpMove p1)
      ));
      place_of_local result
    | None ->
      p1  (* OpRef/OpDeref handled above *)
    end
    
  | ExprCall (fn_expr, args) ->
    let fn_place = lower_expr builder fn_expr in
    let arg_ops = List.map (fun arg ->
      let p = lower_expr builder arg in
      Mir.OpMove p
    ) args in
    let result = alloc_temp builder Types.TError in
    let next_block = new_block builder in
    let _ = finish_block builder (Mir.TermCall {
      func = Mir.OpMove fn_place;
      args = arg_ops;
      dest = Some (place_of_local result);
      target = Some next_block;
      unwind = None;
    }) in
    place_of_local result
    
  | ExprField (obj_expr, field) ->
    let obj_place = lower_expr builder obj_expr in
    { obj_place with projection = obj_place.projection @ [Mir.ProjField field.name] }
    
  | ExprIndex (arr_expr, idx_expr) ->
    let arr_place = lower_expr builder arr_expr in
    let idx_place = lower_expr builder idx_expr in
    { arr_place with projection = arr_place.projection @ [Mir.ProjIndex (Mir.OpCopy idx_place)] }
    
  | ExprStruct (path, fields) ->
    let name = String.concat "::" (List.map (fun i -> i.name) path.segments) in
    let ops = List.map (fun fi ->
      match fi.fi_value with
      | Some e -> Mir.OpMove (lower_expr builder e)
      | None ->
        (* Shorthand: use variable with same name *)
        begin match List.assoc_opt fi.fi_name.name builder.env with
        | Some local -> Mir.OpCopy (place_of_local local)
        | None -> Mir.OpConst Mir.ConstUnit  (* Error *)
        end
    ) fields in
    let result = alloc_temp builder (Types.TNamed (name, [])) in
    add_stmt builder (Mir.StmtAssign (
      place_of_local result,
      Mir.RvAggregate (Mir.AggStruct name, ops)
    ));
    place_of_local result
    
  | ExprTuple exprs ->
    let ops = List.map (fun e -> Mir.OpMove (lower_expr builder e)) exprs in
    let result = alloc_temp builder (Types.TTuple []) in
    add_stmt builder (Mir.StmtAssign (
      place_of_local result,
      Mir.RvAggregate (Mir.AggTuple, ops)
    ));
    place_of_local result
    
  | ExprArray exprs ->
    let ops = List.map (fun e -> Mir.OpMove (lower_expr builder e)) exprs in
    let result = alloc_temp builder (Types.TSlice Types.TError) in
    add_stmt builder (Mir.StmtAssign (
      place_of_local result,
      Mir.RvAggregate (Mir.AggArray, ops)
    ));
    place_of_local result
    
  | ExprIf (cond, then_block, elsifs, else_block) ->
    lower_if builder cond then_block elsifs else_block
    
  | ExprMatch (scrutinee, arms) ->
    lower_match builder scrutinee arms
    
  | ExprWhile (cond, body) ->
    lower_while builder cond body
    
  | ExprFor (var, iter, body) ->
    lower_for builder var iter body
    
  | ExprLoop body ->
    lower_loop builder body
    
  | ExprBlock block ->
    lower_block builder block
    
  | ExprReturn ret_expr_opt ->
    begin match ret_expr_opt with
    | Some e ->
      let p = lower_expr builder e in
      add_stmt builder (Mir.StmtAssign (place_of_local 0, Mir.RvUse (Mir.OpMove p)))
    | None ->
      add_stmt builder (Mir.StmtAssign (
        place_of_local 0,
        Mir.RvUse (Mir.OpConst Mir.ConstUnit)
      ))
    end;
    let _ = finish_block builder Mir.TermReturn in
    place_of_local 0  (* Unreachable, but need to return something *)
    
  | ExprBreak _ | ExprNext ->
    (* These need special handling in loop context *)
    place_of_local 0
    
  | ExprTry inner ->
    (* Lower to match on Result/Option *)
    lower_expr builder inner  (* Simplified *)
    
  | ExprCast (inner, target_ty) ->
    let p = lower_expr builder inner in
    let ty = Types.TPrim Types.TInt in  (* TODO: resolve type *)
    let result = alloc_temp builder ty in
    add_stmt builder (Mir.StmtAssign (
      place_of_local result,
      Mir.RvCast (Mir.OpMove p, ty)
    ));
    ignore target_ty;
    place_of_local result
    
  | ExprClosure _ ->
    (* Closures need special handling *)
    let result = alloc_temp builder Types.TError in
    place_of_local result
    
  | ExprMethodCall (receiver, _method_name, _targs, args) ->
    (* Lower to regular function call *)
    let recv_place = lower_expr builder receiver in
    let arg_ops = Mir.OpMove recv_place :: List.map (fun arg ->
      Mir.OpMove (lower_expr builder arg)
    ) args in
    let result = alloc_temp builder Types.TError in
    let next_block = new_block builder in
    let fn_place = alloc_temp builder Types.TError in
    let _ = finish_block builder (Mir.TermCall {
      func = Mir.OpCopy (place_of_local fn_place);
      args = arg_ops;
      dest = Some (place_of_local result);
      target = Some next_block;
      unwind = None;
    }) in
    place_of_local result
    
  | ExprRange _ | ExprHandle _ | ExprTryCatch _ | ExprMacro _ | ExprUnsafe _ ->
    (* These need special handling *)
    let result = alloc_temp builder Types.TError in
    place_of_local result

and lower_if builder cond then_block elsifs else_block =
  let cond_place = lower_expr builder cond in
  let result = alloc_temp builder Types.TError in
  
  (* Create blocks *)
  let then_target = new_block builder in
  let else_target = new_block builder in
  let join_target = new_block builder in
  
  (* Switch on condition *)
  let _ = finish_block builder (Mir.TermSwitch (
    Mir.OpMove cond_place,
    [(Mir.ConstBool true, then_target)],
    else_target
  )) in
  
  (* Then branch *)
  let then_val = lower_block builder then_block in
  add_stmt builder (Mir.StmtAssign (place_of_local result, Mir.RvUse (Mir.OpMove then_val)));
  let _ = finish_block builder (Mir.TermGoto join_target) in
  
  (* Handle elsif and else *)
  ignore elsifs;
  begin match else_block with
  | Some eb ->
    let else_val = lower_block builder eb in
    add_stmt builder (Mir.StmtAssign (place_of_local result, Mir.RvUse (Mir.OpMove else_val)));
    let _ = finish_block builder (Mir.TermGoto join_target) in
    ()
  | None ->
    add_stmt builder (Mir.StmtAssign (place_of_local result, Mir.RvUse (Mir.OpConst Mir.ConstUnit)));
    let _ = finish_block builder (Mir.TermGoto join_target) in
    ()
  end;
  
  place_of_local result

and lower_match builder scrutinee arms =
  let scrut_place = lower_expr builder scrutinee in
  let result = alloc_temp builder Types.TError in
  
  (* For simplicity, lower to chained if-else (proper lowering needs pattern compilation) *)
  ignore scrut_place;
  ignore arms;
  
  place_of_local result

and lower_while builder cond body =
  let loop_header = new_block builder in
  let _ = finish_block builder (Mir.TermGoto loop_header) in
  
  let cond_place = lower_expr builder cond in
  let body_block = new_block builder in
  let exit_block = new_block builder in
  
  let _ = finish_block builder (Mir.TermSwitch (
    Mir.OpMove cond_place,
    [(Mir.ConstBool true, body_block)],
    exit_block
  )) in
  
  (* Loop body *)
  let _ = lower_block builder body in
  let _ = finish_block builder (Mir.TermGoto loop_header) in
  
  (* Result is unit *)
  let result = alloc_temp builder (Types.TPrim Types.TUnit) in
  add_stmt builder (Mir.StmtAssign (
    place_of_local result,
    Mir.RvUse (Mir.OpConst Mir.ConstUnit)
  ));
  place_of_local result

and lower_for builder var iter body =
  (* For now, lower to while with iterator *)
  let iter_place = lower_expr builder iter in
  ignore iter_place;
  
  (* Create iterator and loop *)
  let loop_header = new_block builder in
  let _ = finish_block builder (Mir.TermGoto loop_header) in
  
  (* Bind loop variable *)
  let var_local = alloc_local builder (Some var.name) Types.TError false in
  builder.env <- (var.name, var_local) :: builder.env;
  
  (* Loop body *)
  let _ = lower_block builder body in
  let _ = finish_block builder (Mir.TermGoto loop_header) in
  
  let result = alloc_temp builder (Types.TPrim Types.TUnit) in
  place_of_local result

and lower_loop builder body =
  let loop_header = new_block builder in
  let _ = finish_block builder (Mir.TermGoto loop_header) in
  
  let _ = lower_block builder body in
  let _ = finish_block builder (Mir.TermGoto loop_header) in
  
  (* Never returns (unless break) *)
  let result = alloc_temp builder Types.TNever in
  place_of_local result

and lower_block builder (block : block) : Mir.place =
  List.iter (lower_stmt builder) block.block_stmts;
  match block.block_expr with
  | Some e -> lower_expr builder e
  | None ->
    let result = alloc_temp builder (Types.TPrim Types.TUnit) in
    add_stmt builder (Mir.StmtAssign (
      place_of_local result,
      Mir.RvUse (Mir.OpConst Mir.ConstUnit)
    ));
    place_of_local result

and lower_stmt builder (s : stmt) =
  match s.stmt_desc with
  | StmtLet (mut, pat, _ty_opt, init) ->
    let init_place = lower_expr builder init in
    lower_pattern_binding builder pat init_place (mut = Ast.Mutable)
  | StmtExpr e ->
    let _ = lower_expr builder e in
    ()
  | StmtItem _item ->
    ()  (* Items in blocks handled separately *)

and lower_pattern_binding builder (pat : pattern) init_place mutable_ =
  match pat.pat_desc with
  | PatIdent (_, id) ->
    let local = alloc_local builder (Some id.name) Types.TError mutable_ in
    builder.env <- (id.name, local) :: builder.env;
    add_stmt builder (Mir.StmtStorageLive local);
    add_stmt builder (Mir.StmtAssign (
      place_of_local local,
      Mir.RvUse (Mir.OpMove init_place)
    ))
  | PatWildcard ->
    ()  (* Ignore value *)
  | PatTuple pats ->
    List.iteri (fun i p ->
      let proj_place = { init_place with
        projection = init_place.projection @ [Mir.ProjField (string_of_int i)]
      } in
      lower_pattern_binding builder p proj_place mutable_
    ) pats
  | _ ->
    ()  (* TODO: other patterns *)

(** Lower a function definition to MIR *)
let lower_function (fn : func_def) : Mir.mir_fn =
  let builder = create_builder () in
  
  (* Allocate return place (_0) *)
  let ret_ty = match fn.fn_return with
    | Some te -> Types.TPrim Types.TInt  (* TODO: resolve type *)
    | None -> Types.TPrim Types.TUnit
  in
  ignore (alloc_local builder (Some "_0") ret_ty true);
  
  (* Allocate parameters *)
  let params = List.map (fun p ->
    let ty = Types.TPrim Types.TInt in  (* TODO: resolve type *)
    let local = alloc_local builder (Some p.param_name.name) ty
      (p.param_mut = Ast.Mutable) in
    builder.env <- (p.param_name.name, local) :: builder.env;
    (p.param_name.name, ty)
  ) fn.fn_params in
  
  (* Lower function body *)
  let body_opt = match fn.fn_body with
    | FnBlock block ->
      let result_place = lower_block builder block in
      add_stmt builder (Mir.StmtAssign (
        place_of_local 0,
        Mir.RvUse (Mir.OpMove result_place)
      ));
      let _ = finish_block builder Mir.TermReturn in
      Some {
        Mir.locals = builder.locals;
        arg_count = List.length params;
        blocks = builder.blocks;
        span = fn.fn_loc;
      }
    | FnExpr e ->
      let result_place = lower_expr builder e in
      add_stmt builder (Mir.StmtAssign (
        place_of_local 0,
        Mir.RvUse (Mir.OpMove result_place)
      ));
      let _ = finish_block builder Mir.TermReturn in
      Some {
        Mir.locals = builder.locals;
        arg_count = List.length params;
        blocks = builder.blocks;
        span = fn.fn_loc;
      }
    | FnSig ->
      None
  in
  
  {
    Mir.name = fn.fn_name.name;
    ty_params = [];
    params;
    return_ty = ret_ty;
    body = body_opt;
  }

(** Lower a program to MIR *)
let lower_program (prog : program) : Mir.mir_module =
  let functions = List.filter_map (fun item ->
    match item.item_desc with
    | ItemFn fn -> Some (lower_function fn)
    | _ -> None
  ) prog.prog_items in
  {
    Mir.name = "main";
    functions;
  }
