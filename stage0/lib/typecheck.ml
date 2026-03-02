(** Type checker for Tangerine *)

open Ast

module StringMap = Map.Make(String)

(** Type checking errors *)
type error =
  | UnboundVariable of string * Location.t
  | UnboundType of string * Location.t
  | UnboundFunction of string * Location.t
  | TypeMismatch of Types.ty * Types.ty * Location.t
  | OccursCheck of Types.type_id * Types.ty * Location.t
  | ArityMismatch of int * int * Location.t
  | NotAFunction of Types.ty * Location.t
  | NotAStruct of Types.ty * Location.t
  | NotAnEnum of Types.ty * Location.t
  | UnknownField of string * string * Location.t
  | UnknownVariant of string * string * Location.t
  | MissingField of string * string * Location.t
  | DuplicateField of string * Location.t
  | CannotMutate of string * Location.t
  | MissingCapability of string * Location.t
  | MissingEffect of string * Location.t
  | GuardMustDiverge of Location.t
  | PureViolation of string * Location.t
  | ContractError of string * Location.t
[@@deriving show]

(** Type check result *)
type 'a result = ('a, error list) Result.t

(** Type checker state *)
type state = {
  env : Env.t;
  errors : error list;
}

let initial_state = {
  env = Env.with_builtins Env.empty;
  errors = [];
}

let add_error err state =
  { state with errors = err :: state.errors }

let with_env env state =
  { state with env }

(** Convert AST type expression to internal type *)
let rec resolve_type_expr state (te : type_expr) : Types.ty =
  match te.ty_desc with
  | TyName (path, args) ->
    let name = String.concat "::" (List.map (fun i -> i.name) path.segments) in
    let args' = List.map (resolve_type_expr state) args in
    begin match Env.lookup_alias name state.env with
    | Some alias_info when alias_info.al_type_params = [] ->
      (* Simple alias without type params *)
      alias_info.al_type
    | Some _ ->
      (* Alias with type params - substitute *)
      Types.TNamed (name, args')
    | None ->
      (* Could be a struct, enum, or unknown type *)
      if Env.lookup_struct name state.env <> None
         || Env.lookup_enum name state.env <> None then
        Types.TNamed (name, args')
      else
        Types.TNamed (name, args')  (* Will be caught later if truly unknown *)
    end
  | TyTuple tys ->
    Types.TTuple (List.map (resolve_type_expr state) tys)
  | TyUnit ->
    Types.TPrim Types.TUnit
  | TyRef (Ast.Mutable, t) ->
    Types.TRef (Types.Mutable, resolve_type_expr state t)
  | TyRef (Ast.Immutable, t) ->
    Types.TRef (Types.Immutable, resolve_type_expr state t)
  | TyPtr (Ast.Mutable, t) ->
    Types.TPtr (Types.Mutable, resolve_type_expr state t)
  | TyPtr (Ast.Immutable, t) ->
    Types.TPtr (Types.Immutable, resolve_type_expr state t)
  | TyArray (t, size_expr) ->
    (* For now, assume array size is a literal *)
    let size = match size_expr.expr_desc with
      | ExprLit (LitInt (n, _)) -> Int64.to_int n
      | _ -> 0  (* TODO: const evaluation *)
    in
    Types.TArray (resolve_type_expr state t, size)
  | TySlice t ->
    Types.TSlice (resolve_type_expr state t)
  | TyFn (params, ret) ->
    Types.TFn (List.map (resolve_type_expr state) params, resolve_type_expr state ret)
  | TyOption t ->
    Types.TOption (resolve_type_expr state t)
  | TySelf ->
    begin match state.env.self_type with
    | Some ty -> ty
    | None -> Types.TSelf
    end
  | TyInfer ->
    Types.fresh_tvar state.env.current_level

(** Unify with error handling *)
let unify_types t1 t2 loc state =
  match Types.unify t1 t2 with
  | Ok () -> state
  | Error (`Mismatch (a, b)) -> add_error (TypeMismatch (a, b, loc)) state
  | Error (`OccursCheck (id, ty)) -> add_error (OccursCheck (id, ty, loc)) state
  | Error `ArityMismatch -> add_error (ArityMismatch (0, 0, loc)) state

(** Infer type of literal *)
let infer_literal = function
  | LitInt _ -> Types.TPrim Types.TInt
  | LitFloat _ -> Types.TPrim Types.TFloat
  | LitString _ -> Types.TPrim Types.TString
  | LitChar _ -> Types.TPrim Types.TChar
  | LitBool _ -> Types.TPrim Types.TBool
  | LitUnit -> Types.TPrim Types.TUnit

(** Infer type of binary operation result *)
let infer_binop_result op t1 t2 =
  match op with
  (* Arithmetic: operands and result are same numeric type *)
  | OpAdd | OpSub | OpMul | OpDiv | OpMod
  | OpAddAssign | OpSubAssign | OpMulAssign | OpDivAssign | OpModAssign ->
    t1  (* Assume t1 and t2 unified to same numeric type *)
  (* Comparison: result is Bool *)
  | OpEq | OpNe | OpLt | OpGt | OpLe | OpGe ->
    Types.TPrim Types.TBool
  (* Logical: operands and result are Bool *)
  | OpAnd | OpOr ->
    Types.TPrim Types.TBool
  (* Bitwise: operands and result are integers *)
  | OpBitAnd | OpBitOr | OpBitXor | OpShl | OpShr ->
    t1
  (* Assignment: returns unit *)
  | OpAssign ->
    Types.TPrim Types.TUnit
  (* Range: returns Range type *)
  | OpRange | OpRangeInclusive ->
    Types.TNamed ("Range", [t1])

(** Infer type of unary operation result *)
let infer_unop_result op t =
  match op with
  | OpNeg -> t
  | OpNot -> Types.TPrim Types.TBool
  | OpRef -> Types.TRef (Types.Immutable, t)
  | OpRefMut -> Types.TRef (Types.Mutable, t)
  | OpDeref ->
    match Types.repr t with
    | Types.TRef (_, inner) | Types.TPtr (_, inner) -> inner
    | _ -> t  (* Error case, will be caught elsewhere *)

(** Infer expression type and check *)
let rec infer_expr state (e : expr) : Types.ty * state =
  match e.expr_desc with
  | ExprLit lit ->
    (infer_literal lit, state)
    
  | ExprPath path ->
    let name = String.concat "::" (List.map (fun i -> i.name) path.segments) in
    begin match Env.lookup_var name state.env with
    | Some vi ->
      let ty = Types.instantiate state.env.current_level vi.vi_type in
      (ty, state)
    | None ->
      begin match Env.lookup_fn name state.env with
      | Some fi ->
        let ty = Types.TFn (fi.fi_param_types, fi.fi_return_type) in
        (ty, state)
      | None ->
        let state = add_error (UnboundVariable (name, e.expr_loc)) state in
        (Types.TError, state)
      end
    end
    
  | ExprBinop (op, e1, e2) ->
    let (t1, state) = infer_expr state e1 in
    let (t2, state) = infer_expr state e2 in
    let state = unify_types t1 t2 e.expr_loc state in
    (infer_binop_result op t1 t2, state)
    
  | ExprUnop (op, e1) ->
    let (t1, state) = infer_expr state e1 in
    (infer_unop_result op t1, state)
    
  | ExprIf (cond, then_block, elsifs, else_block) ->
    let (cond_ty, state) = infer_expr state cond in
    let state = unify_types cond_ty (Types.TPrim Types.TBool) cond.expr_loc state in
    let (then_ty, state) = infer_block state then_block in
    let (state, result_ty) = List.fold_left (fun (state, ty) elsif ->
      let (c_ty, state) = infer_expr state elsif.elsif_cond in
      let state = unify_types c_ty (Types.TPrim Types.TBool) elsif.elsif_loc state in
      let (b_ty, state) = infer_block state elsif.elsif_body in
      let state = unify_types ty b_ty elsif.elsif_loc state in
      (state, ty)
    ) (state, then_ty) elsifs in
    begin match else_block with
    | Some eb ->
      let (else_ty, state) = infer_block state eb in
      let state = unify_types result_ty else_ty e.expr_loc state in
      (result_ty, state)
    | None ->
      (* Without else, result is unit *)
      (Types.TPrim Types.TUnit, state)
    end
    
  | ExprMatch (scrutinee, arms) ->
    let (scrut_ty, state) = infer_expr state scrutinee in
    let result_ty = Types.fresh_tvar state.env.current_level in
    let state = List.fold_left (fun state arm ->
      let state = check_pattern state arm.arm_pattern scrut_ty in
      let (arm_ty, state) = infer_expr state arm.arm_body in
      unify_types result_ty arm_ty arm.arm_loc state
    ) state arms in
    (result_ty, state)
    
  | ExprWhile (cond, body) ->
    let (cond_ty, state) = infer_expr state cond in
    let state = unify_types cond_ty (Types.TPrim Types.TBool) cond.expr_loc state in
    let (_, state) = infer_block state body in
    (Types.TPrim Types.TUnit, state)
    
  | ExprFor (var, iter, body) ->
    let (iter_ty, state) = infer_expr state iter in
    (* Extract element type from iterator *)
    let elem_ty = match Types.repr iter_ty with
      | Types.TSlice t | Types.TArray (t, _) -> t
      | Types.TNamed ("Range", [t]) -> t
      | _ -> Types.fresh_tvar state.env.current_level
    in
    let scheme = { Types.sch_vars = []; sch_type = elem_ty } in
    let vi = { Env.vi_type = scheme; vi_mutable = false; vi_loc = var.loc } in
    let env' = Env.add_var var.name vi state.env in
    let (_, state) = infer_block { state with env = env' } body in
    (Types.TPrim Types.TUnit, { state with env = state.env })
    
  | ExprLoop body ->
    let (_, state) = infer_block state body in
    (* Loop returns Never unless broken *)
    (Types.TNever, state)
    
  | ExprBlock block ->
    let (ty, state) = infer_block state block in
    (ty, state)
    
  | ExprClosure (params, ret_ty_opt, body) ->
    let param_tys = List.map (fun p ->
      match p.cp_type with
      | Some te -> resolve_type_expr state te
      | None -> Types.fresh_tvar state.env.current_level
    ) params in
    let env' = List.fold_left2 (fun env param ty ->
      let scheme = { Types.sch_vars = []; sch_type = ty } in
      let vi = { Env.vi_type = scheme;
                 vi_mutable = param.cp_mut = Ast.Mutable;
                 vi_loc = param.cp_name.loc } in
      Env.add_var param.cp_name.name vi env
    ) state.env params param_tys in
    let (body_ty, state) = infer_expr { state with env = env' } body in
    let ret_ty = match ret_ty_opt with
      | Some te ->
        let rt = resolve_type_expr state te in
        let state = unify_types body_ty rt body.expr_loc state in
        rt
      | None -> body_ty
    in
    (Types.TFn (param_tys, ret_ty), { state with env = state.env })
    
  | ExprCall (fn_expr, args) ->
    let (fn_ty, state) = infer_expr state fn_expr in
    let (arg_tys, state) = List.fold_left_map (fun state arg ->
      infer_expr state arg
    ) state args in
    let ret_ty = Types.fresh_tvar state.env.current_level in
    let expected_fn_ty = Types.TFn (arg_tys, ret_ty) in
    let state = unify_types fn_ty expected_fn_ty e.expr_loc state in
    (ret_ty, state)
    
  | ExprMethodCall (receiver, method_name, _targs, args) ->
    let (recv_ty, state) = infer_expr state receiver in
    let (arg_tys, state) = List.fold_left_map (fun state arg ->
      infer_expr state arg
    ) state args in
    (* TODO: Proper method resolution through impls *)
    let ret_ty = Types.fresh_tvar state.env.current_level in
    ignore (recv_ty, method_name, arg_tys);
    (ret_ty, state)
    
  | ExprField (obj, field) ->
    let (obj_ty, state) = infer_expr state obj in
    begin match Types.repr obj_ty with
    | Types.TNamed (struct_name, _targs) ->
      begin match Env.lookup_struct struct_name state.env with
      | Some si ->
        begin match Env.StringMap.find_opt field.name si.st_fields with
        | Some fi -> (fi.fld_type, state)
        | None ->
          let state = add_error (UnknownField (field.name, struct_name, field.loc)) state in
          (Types.TError, state)
        end
      | None ->
        let state = add_error (NotAStruct (obj_ty, e.expr_loc)) state in
        (Types.TError, state)
      end
    | Types.TTuple tys ->
      let idx = try int_of_string field.name with _ -> -1 in
      if idx >= 0 && idx < List.length tys then
        (List.nth tys idx, state)
      else
        let state = add_error (UnknownField (field.name, "tuple", field.loc)) state in
        (Types.TError, state)
    | _ ->
      let state = add_error (NotAStruct (obj_ty, e.expr_loc)) state in
      (Types.TError, state)
    end
    
  | ExprIndex (arr, idx) ->
    let (arr_ty, state) = infer_expr state arr in
    let (idx_ty, state) = infer_expr state idx in
    let state = unify_types idx_ty (Types.TPrim Types.TInt) idx.expr_loc state in
    let elem_ty = match Types.repr arr_ty with
      | Types.TArray (t, _) | Types.TSlice t -> t
      | _ -> Types.fresh_tvar state.env.current_level
    in
    (elem_ty, state)
    
  | ExprStruct (path, fields) ->
    let name = String.concat "::" (List.map (fun i -> i.name) path.segments) in
    begin match Env.lookup_struct name state.env with
    | Some si ->
      let state = List.fold_left (fun state fi ->
        match fi.fi_value with
        | Some val_expr ->
          begin match Env.StringMap.find_opt fi.fi_name.name si.st_fields with
          | Some field_info ->
            let (val_ty, state) = infer_expr state val_expr in
            unify_types val_ty field_info.fld_type val_expr.expr_loc state
          | None ->
            add_error (UnknownField (fi.fi_name.name, name, fi.fi_loc)) state
          end
        | None ->
          (* Shorthand: field name = variable *)
          begin match Env.lookup_var fi.fi_name.name state.env with
          | Some vi ->
            begin match Env.StringMap.find_opt fi.fi_name.name si.st_fields with
            | Some field_info ->
              let var_ty = Types.instantiate state.env.current_level vi.vi_type in
              unify_types var_ty field_info.fld_type fi.fi_loc state
            | None ->
              add_error (UnknownField (fi.fi_name.name, name, fi.fi_loc)) state
            end
          | None ->
            add_error (UnboundVariable (fi.fi_name.name, fi.fi_loc)) state
          end
      ) state fields in
      (Types.TNamed (name, []), state)
    | None ->
      let state = add_error (UnboundType (name, e.expr_loc)) state in
      (Types.TError, state)
    end
    
  | ExprTuple exprs ->
    let (tys, state) = List.fold_left_map (fun state e ->
      infer_expr state e
    ) state exprs in
    (Types.TTuple tys, state)
    
  | ExprArray exprs ->
    let elem_ty = Types.fresh_tvar state.env.current_level in
    let state = List.fold_left (fun state e ->
      let (ty, state) = infer_expr state e in
      unify_types elem_ty ty e.expr_loc state
    ) state exprs in
    (Types.TArray (elem_ty, List.length exprs), state)
    
  | ExprReturn ret_expr_opt ->
    begin match ret_expr_opt with
    | Some ret_expr ->
      let (ret_ty, state) = infer_expr state ret_expr in
      begin match state.env.current_fn with
      | Some fi -> 
        let state = unify_types ret_ty fi.fi_return_type ret_expr.expr_loc state in
        (Types.TNever, state)
      | None -> (Types.TNever, state)
      end
    | None ->
      begin match state.env.current_fn with
      | Some fi -> 
        let state = unify_types (Types.TPrim Types.TUnit) fi.fi_return_type e.expr_loc state in
        (Types.TNever, state)
      | None -> (Types.TNever, state)
      end
    end
    
  | ExprBreak _ ->
    (Types.TNever, state)
    
  | ExprNext ->
    (Types.TNever, state)
    
  | ExprTry inner ->
    let (inner_ty, state) = infer_expr state inner in
    (* Result[T, E]? returns T (and early returns Err(E)) *)
    begin match Types.repr inner_ty with
    | Types.TResult (ok_ty, _) -> (ok_ty, state)
    | Types.TOption inner -> (inner, state)
    | _ -> (inner_ty, state)
    end
    
  | ExprCast (inner, target_ty) ->
    let (_, state) = infer_expr state inner in
    let ty = resolve_type_expr state target_ty in
    (ty, state)
    
  | ExprRange (start_opt, end_opt, _inclusive) ->
    let elem_ty = Types.fresh_tvar state.env.current_level in
    let state = match start_opt with
      | Some s ->
        let (ty, state) = infer_expr state s in
        unify_types elem_ty ty s.expr_loc state
      | None -> state
    in
    let state = match end_opt with
      | Some e ->
        let (ty, state) = infer_expr state e in
        unify_types elem_ty ty e.expr_loc state
      | None -> state
    in
    (Types.TNamed ("Range", [elem_ty]), state)
    
  | ExprHandle (inner, _handler_name, _arms) ->
    let (inner_ty, state) = infer_expr state inner in
    (* TODO: proper effect handling *)
    (inner_ty, state)
    
  | ExprTryCatch (body, catches, finally_opt) ->
    let (body_ty, state) = infer_block state body in
    let state = List.fold_left (fun state catch ->
      let (_, state) = infer_block state catch.catch_body in
      state
    ) state catches in
    let state = match finally_opt with
      | Some fb -> let (_, s) = infer_block state fb in s
      | None -> state
    in
    (body_ty, state)
    
  | ExprMacro (_name, _args) ->
    (* Macro expansion happens before type checking *)
    (Types.fresh_tvar state.env.current_level, state)
    
  | ExprUnsafe (_reason, body) ->
    infer_block state body

(** Infer block type *)
and infer_block state (block : block) : Types.ty * state =
  let state = List.fold_left (fun state stmt ->
    check_stmt state stmt
  ) state block.block_stmts in
  match block.block_expr with
  | Some e -> infer_expr state e
  | None -> (Types.TPrim Types.TUnit, state)

(** Check a statement *)
and check_stmt state (s : stmt) : state =
  match s.stmt_desc with
  | StmtLet (mut, pat, ty_opt, init) ->
    let (init_ty, state) = infer_expr state init in
    let ty = match ty_opt with
      | Some te ->
        let declared_ty = resolve_type_expr state te in
        let state = unify_types init_ty declared_ty init.expr_loc state in
        ignore state;
        declared_ty
      | None -> init_ty
    in
    let scheme = Types.generalize (state.env.current_level - 1) ty in
    let state = bind_pattern state pat scheme (mut = Ast.Mutable) in
    state
  | StmtExpr e ->
    let (_, state) = infer_expr state e in
    state
  | StmtItem item ->
    check_item state item

(** Bind pattern variables *)
and bind_pattern state (pat : pattern) scheme mutable_ : state =
  match pat.pat_desc with
  | PatWildcard -> state
  | PatIdent (_, id) ->
    let vi = { Env.vi_type = scheme; vi_mutable = mutable_; vi_loc = id.loc } in
    { state with env = Env.add_var id.name vi state.env }
  | PatRef (_, inner) ->
    bind_pattern state inner scheme mutable_
  | PatLiteral _ -> state
  | PatTuple pats ->
    (* TODO: decompose scheme *)
    List.fold_left (fun s p -> bind_pattern s p scheme mutable_) state pats
  | PatStruct (_, field_pats) ->
    List.fold_left (fun s fp ->
      match fp.fp_pattern with
      | Some p -> bind_pattern s p scheme mutable_
      | None ->
        let vi = { Env.vi_type = scheme; vi_mutable = mutable_; vi_loc = fp.fp_name.loc } in
        { s with env = Env.add_var fp.fp_name.name vi s.env }
    ) state field_pats
  | PatEnum (_, Some pats) ->
    List.fold_left (fun s p -> bind_pattern s p scheme mutable_) state pats
  | PatEnum (_, None) -> state
  | PatOr (p1, p2) ->
    let state = bind_pattern state p1 scheme mutable_ in
    bind_pattern state p2 scheme mutable_
  | PatRange _ -> state

(** Check pattern against type *)
and check_pattern state (pat : pattern) ty : state =
  match pat.pat_desc with
  | PatWildcard -> state
  | PatIdent _ -> state
  | PatRef (_, inner) ->
    begin match Types.repr ty with
    | Types.TRef (_, inner_ty) -> check_pattern state inner inner_ty
    | _ -> add_error (TypeMismatch (ty, Types.TRef (Types.Immutable, ty), pat.pat_loc)) state
    end
  | PatLiteral lit ->
    let lit_ty = infer_literal lit in
    unify_types lit_ty ty pat.pat_loc state
  | PatTuple pats ->
    begin match Types.repr ty with
    | Types.TTuple tys when List.length tys = List.length pats ->
      List.fold_left2 check_pattern state pats tys
    | _ -> add_error (TypeMismatch (ty, Types.TTuple [], pat.pat_loc)) state
    end
  | PatStruct _ -> state  (* TODO *)
  | PatEnum _ -> state    (* TODO *)
  | PatOr (p1, p2) ->
    let state = check_pattern state p1 ty in
    check_pattern state p2 ty
  | PatRange (l1, l2) ->
    let t1 = infer_literal l1 in
    let t2 = infer_literal l2 in
    let state = unify_types t1 ty pat.pat_loc state in
    unify_types t2 ty pat.pat_loc state

(** Check an item *)
and check_item state (item : item) : state =
  match item.item_desc with
  | ItemFn fn_def ->
    check_function state fn_def
  | ItemStruct struct_def ->
    check_struct state struct_def
  | ItemEnum enum_def ->
    check_enum state enum_def
  | ItemTrait trait_def ->
    check_trait state trait_def
  | ItemImpl impl_def ->
    check_impl state impl_def
  | ItemUse _ -> state  (* Handled in name resolution *)
  | ItemConst const_decl ->
    check_const state const_decl
  | ItemTypeAlias alias ->
    check_type_alias state alias
  | ItemExtern extern_block ->
    check_extern state extern_block
  | ItemModule mod_def ->
    check_module state mod_def
  | ItemCap cap_decl ->
    check_cap state cap_decl
  | ItemEffect effect_decl ->
    check_effect state effect_decl
  | ItemRationale _ -> state
  | ItemMacro _ -> state

(** Check function definition *)
and check_function state (fn : func_def) : state =
  let param_tys = List.map (fun p ->
    resolve_type_expr state p.param_type
  ) fn.fn_params in
  
  let ret_ty = match fn.fn_return with
    | Some te -> resolve_type_expr state te
    | None -> Types.TPrim Types.TUnit
  in
  
  let fi : Env.fn_info = {
    fi_type_params = [];  (* TODO *)
    fi_param_types = param_tys;
    fi_return_type = ret_ty;
    fi_pure = fn.fn_pure;
    fi_effects = List.map (fun (e, _) -> e.name) fn.fn_effects;
    fi_loc = fn.fn_loc;
  } in
  
  let state = { state with env = Env.add_fn fn.fn_name.name fi state.env } in
  
  (* Add params to local env *)
  let local_env = List.fold_left2 (fun env param ty ->
    let scheme = { Types.sch_vars = []; sch_type = ty } in
    let vi = { Env.vi_type = scheme;
               vi_mutable = param.param_mut = Ast.Mutable;
               vi_loc = param.param_loc } in
    Env.add_var param.param_name.name vi env
  ) state.env fn.fn_params param_tys in
  
  let local_env = Env.with_fn fi local_env in
  
  match fn.fn_body with
  | FnBlock body ->
    let (body_ty, state) = infer_block { state with env = local_env } body in
    let state = unify_types body_ty ret_ty fn.fn_loc state in
    { state with env = state.env }
  | FnExpr e ->
    let (body_ty, state) = infer_expr { state with env = local_env } e in
    let state = unify_types body_ty ret_ty fn.fn_loc state in
    { state with env = state.env }
  | FnSig ->
    state  (* Signature only *)

(** Check struct definition *)
and check_struct state (s : struct_def) : state =
  let fields = List.mapi (fun i field ->
    let ty = resolve_type_expr state field.field_type in
    (field.field_name.name, {
      Env.fld_type = ty;
      fld_public = field.field_vis = Public;
      fld_index = i;
    })
  ) s.struct_fields in
  let si : Env.struct_info = {
    st_type_params = [];  (* TODO *)
    st_fields = List.fold_left (fun m (n, f) ->
      Env.StringMap.add n f m
    ) Env.StringMap.empty fields;
    st_loc = s.struct_loc;
  } in
  { state with env = Env.add_struct s.struct_name.name si state.env }

(** Check enum definition *)
and check_enum state (e : enum_def) : state =
  let variants = List.mapi (fun i var ->
    let fields = match var.variant_fields with
      | VariantUnit -> []
      | VariantTuple tys -> List.map (resolve_type_expr state) tys
      | VariantStruct _ -> []  (* TODO *)
    in
    (var.variant_name.name, { Env.var_fields = fields; var_index = i })
  ) e.enum_variants in
  let ei : Env.enum_info = {
    en_type_params = [];  (* TODO *)
    en_variants = List.fold_left (fun m (n, v) ->
      Env.StringMap.add n v m
    ) Env.StringMap.empty variants;
    en_loc = e.enum_loc;
  } in
  { state with env = Env.add_enum e.enum_name.name ei state.env }

(** Check trait definition *)
and check_trait state (t : trait_def) : state =
  let methods = List.filter_map (fun ti ->
    match ti with
    | TraitFn fn ->
      let param_tys = List.map (fun p ->
        resolve_type_expr state p.param_type
      ) fn.fn_params in
      let ret_ty = match fn.fn_return with
        | Some te -> resolve_type_expr state te
        | None -> Types.TPrim Types.TUnit
      in
      Some (fn.fn_name.name, {
        Env.ms_type_params = [];
        ms_param_types = param_tys;
        ms_return_type = ret_ty;
        ms_has_default = fn.fn_body <> FnSig;
      })
  ) t.trait_items in
  let ti : Env.trait_info = {
    tr_type_params = [];  (* TODO *)
    tr_super = List.map (fun p ->
      String.concat "::" (List.map (fun i -> i.name) p.segments)
    ) t.trait_super;
    tr_methods = List.fold_left (fun m (n, ms) ->
      Env.StringMap.add n ms m
    ) Env.StringMap.empty methods;
    tr_loc = t.trait_loc;
  } in
  { state with env = Env.add_trait t.trait_name.name ti state.env }

(** Check impl block *)
and check_impl state (impl : impl_def) : state =
  let for_ty = resolve_type_expr state impl.impl_for_type in
  let local_env = Env.with_self_type for_ty state.env in
  let state = { state with env = local_env } in
  let state = List.fold_left check_function state impl.impl_items in
  { state with env = state.env }

(** Check const declaration *)
and check_const state (c : const_decl) : state =
  let declared_ty = resolve_type_expr state c.const_type in
  let (init_ty, state) = infer_expr state c.const_value in
  unify_types declared_ty init_ty c.const_loc state

(** Check type alias *)
and check_type_alias state (a : type_alias) : state =
  let ty = resolve_type_expr state a.alias_type in
  let ai = { Env.al_type_params = []; al_type = ty } in
  { state with env = Env.add_alias a.alias_name.name ai state.env }

(** Check extern block *)
and check_extern state (e : extern_block) : state =
  List.fold_left (fun state fn ->
    let param_tys = List.map (fun p ->
      resolve_type_expr state p.param_type
    ) fn.extern_params in
    let ret_ty = match fn.extern_return with
      | Some te -> resolve_type_expr state te
      | None -> Types.TPrim Types.TUnit
    in
    let fi : Env.fn_info = {
      fi_type_params = [];
      fi_param_types = param_tys;
      fi_return_type = ret_ty;
      fi_pure = false;
      fi_effects = [];
      fi_loc = fn.extern_loc;
    } in
    { state with env = Env.add_fn fn.extern_name.name fi state.env }
  ) state e.extern_fns

(** Check module *)
and check_module state (m : module_def) : state =
  match m.mod_items with
  | Some items ->
    List.fold_left check_item state items
  | None -> state

(** Check capability declaration *)
and check_cap state (c : cap_decl) : state =
  let ci = { Env.cap_implies = List.map (fun i -> i.name) c.cap_implies } in
  { state with env = Env.add_cap c.cap_name.name ci state.env }

(** Check effect declaration *)
and check_effect state (e : effect_decl) : state =
  let ops = List.map (fun op ->
    let param_tys = List.map (fun p ->
      resolve_type_expr state p.param_type
    ) op.eop_params in
    let ret_ty = match op.eop_return with
      | Some te -> resolve_type_expr state te
      | None -> Types.TPrim Types.TUnit
    in
    (op.eop_name.name, {
      Env.eop_param_types = param_tys;
      eop_return_type = ret_ty;
    })
  ) e.effect_ops in
  let ei : Env.effect_info = {
    eff_type_params = [];
    eff_ops = List.fold_left (fun m (n, o) ->
      Env.StringMap.add n o m
    ) Env.StringMap.empty ops;
  } in
  { state with env = Env.add_effect e.effect_name.name ei state.env }

(** Check a program *)
let check_program (prog : program) : error list =
  let state = List.fold_left check_item initial_state prog.prog_items in
  List.rev state.errors
