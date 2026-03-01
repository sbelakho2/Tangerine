(* Tangerine Stage0 Bootstrap Compiler - Type Checker *)

open Ast

(* Type representation for type checking *)
type tg_type =
  | TInt
  | TInt8 | TInt16 | TInt32 | TInt64
  | TUInt8 | TUInt16 | TUInt32 | TUInt64
  | TFloat32 | TFloat64
  | TBool
  | TChar
  | TString
  | TUnit
  | TNever
  | TArray of tg_type
  | TVec of tg_type
  | TMap of tg_type * tg_type
  | TSet of tg_type
  | TOption of tg_type
  | TResult of tg_type * tg_type
  | TTuple of tg_type list
  | TFn of tg_type list * tg_type
  | TRef of bool * tg_type  (* is_mut, inner_type *)
  | TStruct of string * (string * tg_type) list
  | TEnum of string * (string * tg_type list) list
  | TTrait of string
  | TGeneric of string
  | TApp of string * tg_type list  (* Generic type application *)
  | TUnknown
  | TError

(* Type environment *)
type type_env = {
  variables: (string, tg_type) Hashtbl.t;
  types: (string, tg_type) Hashtbl.t;
  functions: (string, tg_type list * tg_type) Hashtbl.t;
  traits: (string, string list) Hashtbl.t;  (* trait -> method names *)
  parent: type_env option;
}

(* Diagnostic *)
type diagnostic = {
  diag_level: diag_level;
  diag_message: string;
  diag_span: span;
  diag_notes: string list;
  diag_suggestions: (string * string * span) list;  (* message, replacement, span *)
}

and diag_level = Error | Warning | Info | Hint

let diagnostics : diagnostic list ref = ref []

let add_diagnostic level message span =
  diagnostics := { diag_level = level; diag_message = message; diag_span = span; 
                   diag_notes = []; diag_suggestions = [] } :: !diagnostics

let add_error = add_diagnostic Error
let add_warning = add_diagnostic Warning
let add_hint = add_diagnostic Hint

let clear_diagnostics () = diagnostics := []
let get_diagnostics () = List.rev !diagnostics

(* Create a new environment *)
let new_env ?parent () =
  let env = {
    variables = Hashtbl.create 64;
    types = Hashtbl.create 64;
    functions = Hashtbl.create 64;
    traits = Hashtbl.create 32;
    parent;
  } in
  (* Add built-in types *)
  Hashtbl.add env.types "Int" TInt;
  Hashtbl.add env.types "Int8" TInt8;
  Hashtbl.add env.types "Int16" TInt16;
  Hashtbl.add env.types "Int32" TInt32;
  Hashtbl.add env.types "Int64" TInt64;
  Hashtbl.add env.types "UInt8" TUInt8;
  Hashtbl.add env.types "UInt16" TUInt16;
  Hashtbl.add env.types "UInt32" TUInt32;
  Hashtbl.add env.types "UInt64" TUInt64;
  Hashtbl.add env.types "Float32" TFloat32;
  Hashtbl.add env.types "Float64" TFloat64;
  Hashtbl.add env.types "Bool" TBool;
  Hashtbl.add env.types "Char" TChar;
  Hashtbl.add env.types "String" TString;
  Hashtbl.add env.types "Unit" TUnit;
  env

let rec lookup_var env name =
  try Some (Hashtbl.find env.variables name)
  with Not_found ->
    match env.parent with
    | Some p -> lookup_var p name
    | None -> None

let rec lookup_type env name =
  try Some (Hashtbl.find env.types name)
  with Not_found ->
    match env.parent with
    | Some p -> lookup_type p name
    | None -> None

let rec lookup_fn env name =
  try Some (Hashtbl.find env.functions name)
  with Not_found ->
    match env.parent with
    | Some p -> lookup_fn p name
    | None -> None

(* Convert AST type to internal type *)
let rec resolve_type env (ty: Ast.ty) : tg_type =
  match ty with
  | TyName (name, []) ->
      (match lookup_type env name with
       | Some t -> t
       | None -> 
           (* Check if it's a generic parameter *)
           TGeneric name)
  | TyName (name, args) ->
      let resolved_args = List.map (resolve_type env) args in
      (match name with
       | "Vec" -> (match resolved_args with [t] -> TVec t | _ -> TError)
       | "Option" -> (match resolved_args with [t] -> TOption t | _ -> TError)
       | "Result" -> (match resolved_args with [t; e] -> TResult (t, e) | _ -> TError)
       | "Map" -> (match resolved_args with [k; v] -> TMap (k, v) | _ -> TError)
       | "Set" -> (match resolved_args with [t] -> TSet t | _ -> TError)
       | "Array" -> (match resolved_args with [t] -> TArray t | _ -> TError)
       | _ -> TApp (name, resolved_args))
  | TyFn (params, ret) ->
      TFn (List.map (resolve_type env) params, resolve_type env ret)
  | TyTuple tys ->
      TTuple (List.map (resolve_type env) tys)
  | TyRef (Mutable, ty) -> TRef (true, resolve_type env ty)
  | TyRef (Immutable, ty) -> TRef (false, resolve_type env ty)
  | TyOption ty -> TOption (resolve_type env ty)
  | TyInfer -> TUnknown
  | TyNever -> TNever
  | TySelf -> TGeneric "Self"

(* Type equality check *)
let rec types_equal t1 t2 =
  match t1, t2 with
  | TUnknown, _ | _, TUnknown -> true
  | TGeneric _, _ | _, TGeneric _ -> true  (* Simplified: generics match anything *)
  | TInt, TInt | TBool, TBool | TChar, TChar | TString, TString | TUnit, TUnit -> true
  | TInt8, TInt8 | TInt16, TInt16 | TInt32, TInt32 | TInt64, TInt64 -> true
  | TUInt8, TUInt8 | TUInt16, TUInt16 | TUInt32, TUInt32 | TUInt64, TUInt64 -> true
  | TFloat32, TFloat32 | TFloat64, TFloat64 -> true
  | TNever, _ | _, TNever -> true
  | TVec t1, TVec t2 -> types_equal t1 t2
  | TArray t1, TArray t2 -> types_equal t1 t2
  | TOption t1, TOption t2 -> types_equal t1 t2
  | TResult (t1, e1), TResult (t2, e2) -> types_equal t1 t2 && types_equal e1 e2
  | TMap (k1, v1), TMap (k2, v2) -> types_equal k1 k2 && types_equal v1 v2
  | TSet t1, TSet t2 -> types_equal t1 t2
  | TTuple ts1, TTuple ts2 ->
      List.length ts1 = List.length ts2 && List.for_all2 types_equal ts1 ts2
  | TFn (p1, r1), TFn (p2, r2) ->
      List.length p1 = List.length p2 && 
      List.for_all2 types_equal p1 p2 && types_equal r1 r2
  | TRef (m1, t1), TRef (m2, t2) -> m1 = m2 && types_equal t1 t2
  | TApp (n1, args1), TApp (n2, args2) ->
      n1 = n2 && List.length args1 = List.length args2 && List.for_all2 types_equal args1 args2
  | _ -> false

(* Pretty print type *)
let rec type_to_string = function
  | TInt -> "Int"
  | TInt8 -> "Int8"
  | TInt16 -> "Int16"
  | TInt32 -> "Int32"
  | TInt64 -> "Int64"
  | TUInt8 -> "UInt8"
  | TUInt16 -> "UInt16"
  | TUInt32 -> "UInt32"
  | TUInt64 -> "UInt64"
  | TFloat32 -> "Float32"
  | TFloat64 -> "Float64"
  | TBool -> "Bool"
  | TChar -> "Char"
  | TString -> "String"
  | TUnit -> "()"
  | TNever -> "!"
  | TArray t -> "Array[" ^ type_to_string t ^ "]"
  | TVec t -> "Vec[" ^ type_to_string t ^ "]"
  | TMap (k, v) -> "Map[" ^ type_to_string k ^ ", " ^ type_to_string v ^ "]"
  | TSet t -> "Set[" ^ type_to_string t ^ "]"
  | TOption t -> "Option[" ^ type_to_string t ^ "]"
  | TResult (t, e) -> "Result[" ^ type_to_string t ^ ", " ^ type_to_string e ^ "]"
  | TTuple ts -> "(" ^ String.concat ", " (List.map type_to_string ts) ^ ")"
  | TFn (params, ret) -> 
      "fn(" ^ String.concat ", " (List.map type_to_string params) ^ ") -> " ^ type_to_string ret
  | TRef (false, t) -> "&" ^ type_to_string t
  | TRef (true, t) -> "&mut " ^ type_to_string t
  | TStruct (name, _) -> name
  | TEnum (name, _) -> name
  | TTrait name -> "impl " ^ name
  | TGeneric name -> name
  | TApp (name, args) -> name ^ "[" ^ String.concat ", " (List.map type_to_string args) ^ "]"
  | TUnknown -> "_"
  | TError -> "<error>"

(* Check expression and return its type *)
let rec check_expr env (expr: Ast.expr) : tg_type =
  match expr with
  | ExprLiteral (lit, _) -> check_literal lit
  | ExprIdent (name, span) ->
      (match lookup_var env name with
       | Some t -> t
       | None ->
           (match lookup_fn env name with
            | Some (params, ret) -> TFn (params, ret)
            | None ->
                add_error (Printf.sprintf "Undefined variable: `%s`" name) span;
                TError))
  | ExprPath (path, _span) ->
      (* Simplified: just look up the last component *)
      let name = List.hd (List.rev path) in
      (match lookup_var env name with
       | Some t -> t
       | None ->
           (match lookup_fn env name with
            | Some (params, ret) -> TFn (params, ret)
            | None -> TUnknown))
  | ExprBinary (op, lhs, rhs, span) ->
      let lt = check_expr env lhs in
      let rt = check_expr env rhs in
      check_binary_op op lt rt span
  | ExprUnary (op, e, span) ->
      let t = check_expr env e in
      check_unary_op op t span
  | ExprCall (callee, args, span) ->
      let callee_type = check_expr env callee in
      let arg_types = List.map (check_expr env) args in
      (match callee_type with
       | TFn (params, ret) ->
           if List.length params <> List.length args then begin
             add_error (Printf.sprintf "Expected %d arguments, got %d" 
                         (List.length params) (List.length args)) span;
           end else begin
             List.iteri (fun i (pt, at) ->
               if not (types_equal pt at) then
                 add_error (Printf.sprintf "Argument %d: expected `%s`, got `%s`"
                             (i + 1) (type_to_string pt) (type_to_string at)) span
             ) (List.combine params arg_types)
           end;
           ret
       | TUnknown -> TUnknown
       | _ ->
           add_error (Printf.sprintf "Cannot call non-function type `%s`" 
                       (type_to_string callee_type)) span;
           TError)
  | ExprMethodCall (receiver, _method_name, args, _span) ->
      let _recv_type = check_expr env receiver in
      let _arg_types = List.map (check_expr env) args in
      (* Simplified: we'd need full method resolution here *)
      TUnknown
  | ExprField (e, field, span) ->
      let t = check_expr env e in
      (match t with
       | TStruct (_, fields) ->
           (match List.assoc_opt field fields with
            | Some ft -> ft
            | None ->
                add_error (Printf.sprintf "No field `%s` on struct" field) span;
                TError)
       | TUnknown -> TUnknown
       | _ ->
           add_error (Printf.sprintf "Cannot access field on type `%s`" (type_to_string t)) span;
           TError)
  | ExprIndex (e, idx, span) ->
      let t = check_expr env e in
      let it = check_expr env idx in
      (match t with
       | TVec elem | TArray elem ->
           if not (types_equal it TInt) then
             add_error "Index must be an integer" span;
           elem
       | TMap (k, v) ->
           if not (types_equal it k) then
             add_error (Printf.sprintf "Map key type mismatch: expected `%s`" (type_to_string k)) span;
           v
       | TString -> TChar
       | TUnknown -> TUnknown
       | _ ->
           add_error (Printf.sprintf "Cannot index type `%s`" (type_to_string t)) span;
           TError)
  | ExprStruct (name, fields, span) ->
      (match lookup_type env name with
       | Some (TStruct (_, expected_fields) as st) ->
           List.iter (fun (fname, fexpr) ->
             let ft = check_expr env fexpr in
             match List.assoc_opt fname expected_fields with
             | Some expected_ft ->
                 if not (types_equal ft expected_ft) then
                   add_error (Printf.sprintf "Field `%s`: expected `%s`, got `%s`"
                               fname (type_to_string expected_ft) (type_to_string ft)) span
             | None ->
                 add_error (Printf.sprintf "Unknown field `%s` on struct `%s`" fname name) span
           ) fields;
           st
       | Some _ ->
           add_error (Printf.sprintf "`%s` is not a struct" name) span;
           TError
       | None ->
           add_error (Printf.sprintf "Unknown type `%s`" name) span;
           TError)
  | ExprTuple (exprs, _) ->
      TTuple (List.map (check_expr env) exprs)
  | ExprArray (exprs, span) ->
      (match exprs with
       | [] -> TVec TUnknown
       | e :: rest ->
           let t = check_expr env e in
           List.iter (fun e2 ->
             let t2 = check_expr env e2 in
             if not (types_equal t t2) then
               add_error (Printf.sprintf "Array element type mismatch: expected `%s`, got `%s`"
                           (type_to_string t) (type_to_string t2)) span
           ) rest;
           TVec t)
  | ExprIf (cond, then_block, elsifs, else_block, span) ->
      let ct = check_expr env cond in
      if not (types_equal ct TBool) then
        add_error (Printf.sprintf "Condition must be Bool, got `%s`" (type_to_string ct)) span;
      let then_t = check_block env then_block in
      List.iter (fun (c, b) ->
        let ct = check_expr env c in
        if not (types_equal ct TBool) then
          add_error "Elsif condition must be Bool" span;
        let _ = check_block env b in ()
      ) elsifs;
      (match else_block with
       | Some eb -> 
           let else_t = check_block env eb in
           if not (types_equal then_t else_t) then
             add_warning "If/else branches have different types" span;
           then_t
       | None -> TUnit)
  | ExprMatch (scrutinee, arms, span) ->
      let _st = check_expr env scrutinee in
      let arm_types = List.map (fun arm ->
        (* TODO: pattern binding *)
        check_expr env arm.body
      ) arms in
      (match arm_types with
       | [] -> TUnit
       | t :: rest ->
           List.iter (fun t2 ->
             if not (types_equal t t2) then
               add_warning "Match arms have different types" span
           ) rest;
           t)
  | ExprWhile (cond, body, span) ->
      let ct = check_expr env cond in
      if not (types_equal ct TBool) then
        add_error "While condition must be Bool" span;
      let _ = check_block env body in
      TUnit
  | ExprFor (pattern, iter, body, _) ->
      let it = check_expr env iter in
      let elem_type = match it with
        | TVec t | TArray t | TSet t -> t
        | TMap (k, v) -> TTuple [k; v]
        | TString -> TChar
        | _ -> TUnknown
      in
      let inner_env = { env with variables = Hashtbl.copy env.variables; parent = Some env } in
      bind_pattern inner_env pattern elem_type;
      let _ = check_block inner_env body in
      TUnit
  | ExprLoop (body, _) ->
      let _ = check_block env body in
      TNever  (* loop without break returns never *)
  | ExprBlock (body, _) ->
      check_block env body
  | ExprReturn (e, _) ->
      let _ = Option.map (check_expr env) e in
      TNever
  | ExprBreak (_, e, _) ->
      let _ = Option.map (check_expr env) e in
      TNever
  | ExprContinue (_, _) -> TNever
  | ExprAssign (lhs, rhs, span) ->
      let lt = check_expr env lhs in
      let rt = check_expr env rhs in
      if not (types_equal lt rt) then
        add_error (Printf.sprintf "Cannot assign `%s` to `%s`" 
                    (type_to_string rt) (type_to_string lt)) span;
      TUnit
  | ExprCompoundAssign (op, lhs, rhs, span) ->
      let lt = check_expr env lhs in
      let rt = check_expr env rhs in
      let _ = check_binary_op op lt rt span in
      TUnit
  | ExprTry (e, _) ->
      let t = check_expr env e in
      (match t with
       | TResult (ok, _) | TOption ok -> ok
       | _ -> t)
  | ExprCast (e, ty, _) ->
      let _ = check_expr env e in
      resolve_type env ty
  | ExprClosure (params, ret, body, _) ->
      let inner_env = { env with variables = Hashtbl.copy env.variables; parent = Some env } in
      List.iter (fun p ->
        Hashtbl.add inner_env.variables p.param_name (resolve_type env p.param_type)
      ) params;
      let body_t = check_block inner_env body in
      let param_types = List.map (fun p -> resolve_type env p.param_type) params in
      let ret_t = match ret with Some t -> resolve_type env t | None -> body_t in
      TFn (param_types, ret_t)
  | ExprUnsafe (body, _) ->
      check_block env body
  | ExprTupleIndex (e, idx, span) ->
      let t = check_expr env e in
      (match t with
       | TTuple ts ->
           if idx >= 0 && idx < List.length ts then
             List.nth ts idx
           else begin
             add_error (Printf.sprintf "Tuple index %d out of bounds" idx) span;
             TError
           end
       | _ ->
           add_error "Cannot index non-tuple type" span;
           TError)
  | ExprAwait (e, _) ->
      let t = check_expr env e in
      (* Simplified: assume Future[T] -> T *)
      (match t with
       | TApp ("Future", [inner]) -> inner
       | _ -> t)
  | ExprYield (e, _) ->
      let _ = Option.map (check_expr env) e in
      TUnknown
  | ExprRange (start, end_, _) ->
      let _ = Option.map (check_expr env) start in
      let _ = Option.map (check_expr env) end_ in
      TApp ("Range", [TInt])

and check_literal = function
  | LitInt _ -> TInt
  | LitFloat _ -> TFloat64
  | LitString _ -> TString
  | LitChar _ -> TChar
  | LitBool _ -> TBool

and check_binary_op op lt rt span =
  match op with
  | Add | Sub | Mul | Div | Mod ->
      if not (is_numeric lt && is_numeric rt) then
        add_error (Printf.sprintf "Arithmetic operators require numeric types, got `%s` and `%s`"
                    (type_to_string lt) (type_to_string rt)) span;
      lt
  | Eq | Ne ->
      if not (types_equal lt rt) then
        add_warning (Printf.sprintf "Comparing different types: `%s` and `%s`"
                      (type_to_string lt) (type_to_string rt)) span;
      TBool
  | Lt | Le | Gt | Ge ->
      if not (is_numeric lt && is_numeric rt) then
        add_error "Comparison operators require numeric types" span;
      TBool
  | And | Or ->
      if not (types_equal lt TBool && types_equal rt TBool) then
        add_error "Logical operators require Bool operands" span;
      TBool
  | BitAnd | BitOr | BitXor | Shl | Shr ->
      if not (is_integer lt && is_integer rt) then
        add_error "Bitwise operators require integer types" span;
      lt

and check_unary_op op t span =
  match op with
  | Neg ->
      if not (is_numeric t) then
        add_error "Negation requires numeric type" span;
      t
  | Not ->
      if not (types_equal t TBool) then
        add_error "Logical not requires Bool" span;
      TBool
  | BitNot ->
      if not (is_integer t) then
        add_error "Bitwise not requires integer type" span;
      t
  | Ref -> TRef (false, t)
  | RefMut -> TRef (true, t)
  | Deref ->
      (match t with
       | TRef (_, inner) -> inner
       | _ ->
           add_error "Cannot dereference non-reference type" span;
           TError)

and is_numeric = function
  | TInt | TInt8 | TInt16 | TInt32 | TInt64 
  | TUInt8 | TUInt16 | TUInt32 | TUInt64
  | TFloat32 | TFloat64 | TUnknown -> true
  | _ -> false

and is_integer = function
  | TInt | TInt8 | TInt16 | TInt32 | TInt64 
  | TUInt8 | TUInt16 | TUInt32 | TUInt64 | TUnknown -> true
  | _ -> false

and check_block env block =
  List.iter (check_stmt env) block.stmts;
  match block.expr with
  | Some e -> check_expr env e
  | None -> TUnit

and check_stmt env = function
  | StmtLet (_mut, pattern, ty_annot, init, span) ->
      let init_type = match init with
        | Some e -> check_expr env e
        | None -> TUnknown
      in
      let declared_type = match ty_annot with
        | Some ty -> resolve_type env ty
        | None -> init_type
      in
      if Option.is_some ty_annot && Option.is_some init then begin
        if not (types_equal declared_type init_type) then
          add_error (Printf.sprintf "Type mismatch: declared `%s`, got `%s`"
                      (type_to_string declared_type) (type_to_string init_type)) span
      end;
      bind_pattern env pattern declared_type
  | StmtExpr (e, _) ->
      let _ = check_expr env e in ()
  | StmtItem (item, _) ->
      check_item env item

and bind_pattern env pattern ty =
  match pattern with
  | PatIdent (_, name, _) ->
      Hashtbl.add env.variables name ty
  | PatTuple (pats, _) ->
      (match ty with
       | TTuple ts when List.length ts = List.length pats ->
           List.iter2 (bind_pattern env) pats ts
       | _ -> ())
  | PatStruct (_, fields, _) ->
      (match ty with
       | TStruct (_, field_types) ->
           List.iter (fun (fname, fpat) ->
             match List.assoc_opt fname field_types with
             | Some ft -> bind_pattern env fpat ft
             | None -> ()
           ) fields
       | _ -> ())
  | PatEnum (_, _, pats, _) ->
      List.iter (fun p -> bind_pattern env p TUnknown) pats
  | PatWildcard _ | PatLiteral _ | PatOr _ | PatRange _ -> ()

and check_item env = function
  | ItemFn fn ->
      let inner_env = { env with variables = Hashtbl.copy env.variables; parent = Some env } in
      (* Add parameters *)
      List.iter (fun p ->
        Hashtbl.add inner_env.variables p.param_name (resolve_type env p.param_type)
      ) fn.fn_params;
      (* Add function to environment *)
      let param_types = List.map (fun p -> resolve_type env p.param_type) fn.fn_params in
      let ret_type = match fn.fn_return_type with
        | Some t -> resolve_type env t
        | None -> TUnit
      in
      Hashtbl.add env.functions fn.fn_name (param_types, ret_type);
      (* Check body *)
      (match fn.fn_body with
       | Some body ->
           let body_type = check_block inner_env body in
           if not (types_equal body_type ret_type) && not (types_equal body_type TNever) then
             add_error (Printf.sprintf "Return type mismatch: expected `%s`, got `%s`"
                         (type_to_string ret_type) (type_to_string body_type)) fn.fn_span
       | None -> ())
  | ItemStruct s ->
      let fields = List.map (fun f -> (f.field_name, resolve_type env f.field_type)) s.struct_fields in
      Hashtbl.add env.types s.struct_name (TStruct (s.struct_name, fields))
  | ItemEnum e ->
      let variants = List.map (fun v ->
        (v.variant_name, List.map (fun vf -> resolve_type env vf.vf_type) v.variant_fields)
      ) e.enum_variants in
      Hashtbl.add env.types e.enum_name (TEnum (e.enum_name, variants))
  | ItemTrait t ->
      let methods = List.filter_map (function
        | TraitMethod m -> Some m.fn_name
        | TraitType _ -> None
      ) t.trait_items in
      Hashtbl.add env.traits t.trait_name methods
  | ItemImpl impl ->
      List.iter (fun item ->
        match item with
        | ImplMethod m -> check_item env (ItemFn m)
        | ImplType _ -> ()
      ) impl.impl_items
  | ItemUse _ | ItemConst _ | ItemTypeAlias _ | ItemModule _ | ItemExtern _ -> ()

(* Check a full program *)
let check_program (prog: Ast.program) : diagnostic list =
  clear_diagnostics ();
  let env = new_env () in
  (* First pass: register all types and functions *)
  List.iter (fun item ->
    match item with
    | ItemStruct s ->
        let fields = List.map (fun f -> (f.field_name, resolve_type env f.field_type)) s.struct_fields in
        Hashtbl.add env.types s.struct_name (TStruct (s.struct_name, fields))
    | ItemEnum e ->
        let variants = List.map (fun v ->
          (v.variant_name, List.map (fun vf -> resolve_type env vf.vf_type) v.variant_fields)
        ) e.enum_variants in
        Hashtbl.add env.types e.enum_name (TEnum (e.enum_name, variants))
    | ItemFn fn ->
        let param_types = List.map (fun p -> resolve_type env p.param_type) fn.fn_params in
        let ret_type = match fn.fn_return_type with Some t -> resolve_type env t | None -> TUnit in
        Hashtbl.add env.functions fn.fn_name (param_types, ret_type)
    | _ -> ()
  ) prog.items;
  (* Second pass: check everything *)
  List.iter (check_item env) prog.items;
  get_diagnostics ()

(* Symbol information for LSP *)
type symbol_info = {
  sym_name: string;
  sym_type: tg_type;
  sym_span: span;
  sym_doc: string option;
}

let get_symbols_at_position env _line _col =
  (* Return all visible symbols - simplified for now *)
  let symbols = ref [] in
  Hashtbl.iter (fun name ty ->
    symbols := { sym_name = name; sym_type = ty; sym_span = dummy_span; sym_doc = None } :: !symbols
  ) env.variables;
  Hashtbl.iter (fun name (params, ret) ->
    symbols := { sym_name = name; sym_type = TFn (params, ret); sym_span = dummy_span; sym_doc = None } :: !symbols
  ) env.functions;
  !symbols
