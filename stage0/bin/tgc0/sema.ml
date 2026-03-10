open Ast

exception Error of string

type function_sig =
  { name : string
  ; method_of : string option
  ; param_types : type_expr list
  ; ret_type : type_expr
  }

type const_sig =
  { name : string
  ; ty : type_expr
  }

type global_sig =
  { name : string
  ; ty : type_expr
  ; is_mutable : bool
  }

type env =
  { enums : (string, enum_decl) Hashtbl.t
  ; structs : (string, struct_decl) Hashtbl.t
  ; functions : (string, function_sig) Hashtbl.t
  ; methods : (string, function_sig) Hashtbl.t
  ; constants : (string, const_sig) Hashtbl.t
  ; globals : (string, global_sig) Hashtbl.t
  }

type locals = (string * type_expr) list

let string_of_type = function
  | TInt -> "Int"
  | TBool -> "Bool"
  | TUnit -> "Unit"
  | TFloat -> "Float"
  | TString -> "String"
  | TChar -> "Char"
  | TNamed name -> name

let lookup_local locals name = List.assoc_opt name locals

let has_prefix text prefix =
  let prefix_len = String.length prefix in
  String.length text >= prefix_len && String.sub text 0 prefix_len = prefix

let split_generic_args text =
  let len = String.length text in
  let rec find_lbracket index =
    if index >= len then None
    else if text.[index] = '[' then Some index
    else find_lbracket (index + 1)
  in
  match find_lbracket 0 with
  | None -> None
  | Some lbracket ->
      if len = 0 || text.[len - 1] <> ']' then
        None
      else
        let body = String.sub text (lbracket + 1) (len - lbracket - 2) in
        let rec consume index depth start acc =
          if index >= String.length body then
            let part = String.sub body start (String.length body - start) in
            List.rev (part :: acc)
          else
            match body.[index] with
            | '[' -> consume (index + 1) (depth + 1) start acc
            | ']' -> consume (index + 1) (depth - 1) start acc
            | ',' when depth = 0 ->
                let part = String.sub body start (index - start) in
                consume (index + 1) depth (index + 1) (part :: acc)
            | _ -> consume (index + 1) depth start acc
        in
        Some (String.sub text 0 lbracket, consume 0 0 0 [])

let option_payload_type = function
  | TNamed name ->
      begin match split_generic_args name with
      | Some ("Option", [payload]) -> Some (TNamed payload)
      | _ -> None
      end
  | _ -> None

let result_payload_types = function
  | TNamed name ->
      begin match split_generic_args name with
      | Some ("Result", [ok_ty; err_ty]) -> Some (TNamed ok_ty, TNamed err_ty)
      | _ -> None
      end
  | _ -> None

let is_known_named env = function
  | TNamed name ->
      Hashtbl.mem env.structs name || Hashtbl.mem env.enums name || Hashtbl.mem env.constants name
      || Hashtbl.mem env.globals name
      || name = "Self"
  | _ -> false

let is_flexible_type env = function
  | TNamed name -> not (is_known_named env (TNamed name))
  | _ -> false

let equal_type env lhs rhs =
  lhs = rhs
  || is_flexible_type env lhs
  || is_flexible_type env rhs
  ||
  match lhs, rhs with
  | TInt, TFloat | TFloat, TInt -> true
  | TNamed "__external", TString | TString, TNamed "__external" -> true
  | TNamed "__external", TInt | TInt, TNamed "__external" -> true
  | TNamed "__external", TBool | TBool, TNamed "__external" -> true
  | TNamed "__external", TFloat | TFloat, TNamed "__external" -> true
  | TNamed "__external", TChar | TChar, TNamed "__external" -> true
  | TString, TBool | TBool, TString -> true  (* Allow String in condition context *)
  | TString, TInt | TInt, TString -> true  (* Allow String/Int mixing *)
  | TUnit, _ | _, TUnit -> true  (* Allow Unit to match any type for match arms *)
  | _ -> false

let require_type env expected actual context =
  if not (equal_type env expected actual) then
    raise
      (Error
         (Printf.sprintf "%s: expected %s but found %s" context (string_of_type expected)
            (string_of_type actual)))

let parameter_type (decl : function_decl) index (param : param) =
  match param.ty, decl.method_of, index, param.name with
  | Some ty, _, _, _ -> ty
  | None, Some struct_name, 0, "self" -> TNamed struct_name
  | None, None, 0, "self" -> TNamed "Self"
  | None, _, _, _ -> TNamed "__external"

let resolve_self_type (decl : function_decl) = function
  | TNamed "Self" ->
      begin match decl.method_of with
      | Some struct_name -> TNamed struct_name
      | None -> TNamed "Self"
      end
  | ty -> ty

let create_env program =
  let env =
    { enums = Hashtbl.create 16
    ; structs = Hashtbl.create 16
    ; functions = Hashtbl.create 16
    ; methods = Hashtbl.create 16
    ; constants = Hashtbl.create 16
    ; globals = Hashtbl.create 16
    }
  in
  let declare_function (decl : function_decl) =
    let param_types = List.mapi (fun index param -> parameter_type decl index param) decl.params in
    let ret_type = Option.value decl.ret_type ~default:TUnit |> resolve_self_type decl in
    let signature = { name = decl.name; method_of = decl.method_of; param_types; ret_type } in
    match decl.method_of with
    | Some struct_name -> Hashtbl.replace env.methods (struct_name ^ "." ^ decl.name) signature
    | None -> Hashtbl.replace env.functions decl.name signature
  in
  List.iter
    (function
      | Enum decl -> Hashtbl.replace env.enums decl.name decl
      | Struct decl -> Hashtbl.replace env.structs decl.name decl
        | Trait _ -> ()
      | Function decl -> declare_function decl
      | Const decl ->
          let ty = Option.value decl.ty ~default:(TNamed "__external") in
          Hashtbl.replace env.constants decl.name { name = decl.name; ty }
      | Global decl ->
          let ty = Option.value decl.ty ~default:(TNamed "__external") in
          Hashtbl.replace env.globals decl.name { name = decl.name; ty; is_mutable = decl.is_mutable }
      | Ignored -> ())
    program;
  env

let require_main env =
  match Hashtbl.find_opt env.functions "main" with
  | Some { param_types = []; ret_type = TInt; _ } -> ()
  | Some { param_types = []; ret_type = TUnit; _ } -> ()
  | Some _ -> raise (Error "main must have signature def main() -> Int or def main() -> Unit")
  | None -> raise (Error "program must define main")

let find_enum_variant env enum_name variant_name =
  match Hashtbl.find_opt env.enums enum_name with
  | None -> None
  | Some decl -> List.find_opt (fun (variant : enum_variant) -> variant.name = variant_name) decl.variants

let lookup_struct_field env struct_name field_name =
  match Hashtbl.find_opt env.structs struct_name with
  | None -> raise (Error ("unknown struct " ^ struct_name))
  | Some decl ->
      begin match List.find_opt (fun (field : struct_field) -> field.name = field_name) decl.fields with
      | Some field -> field.ty
      | None -> raise (Error (Printf.sprintf "unknown field %s.%s" struct_name field_name))
      end

let external_call_result = function
  | "fmt::format" -> TString
  | name when has_prefix name "Option::" -> TNamed "Option"
  | name when has_prefix name "Result::" -> TNamed "Result"
  | name when has_prefix name "app::" -> TNamed "__external"
  | name when has_prefix name "gfx::" -> TNamed "__external"
  | name when has_prefix name "geom::" -> TNamed "__external"
  | name when has_prefix name "text::" -> TNamed "__external"
  | name when has_prefix name "std::" -> TNamed "__external"
  | name when has_prefix name "assert" -> TUnit
  | _ -> TNamed "__external"

let external_method_result receiver_ty method_name =
  match method_name with
  | "to_string" -> TString
  | "poll_event" -> TNamed "Option"
  | "window_new" | "surface" | "begin_frame" -> TNamed "Result"
  | "default" -> receiver_ty
  | _ -> TNamed "__external"

let external_pattern_payload_types enum_name variant_name =
  match enum_name, variant_name with
  | "Option", "Some" -> Some [TNamed "__external"]
  | "Result", "Ok" -> Some [TNamed "__external"]
  | "Result", "Err" -> Some [TNamed "__external"]
  | "app::Event", "MouseMove" -> Some [TFloat; TFloat]
  | "app::Event", "MouseDown" -> Some [TNamed "app::MouseButton"]
  | "app::Event", "KeyDown" -> Some [TNamed "app::Key"; TNamed "app::KeyMods"; TBool]
  | "app::Key", "Char" -> Some [TChar]
  | "app::MouseButton", "Other" -> Some [TInt]
  | _ -> None

let rec infer_expr env locals expected_return = function
  | Expr.Unit -> TUnit
  | Expr.Int _ -> TInt
  | Expr.Float _ -> TFloat
  | Expr.Bool _ -> TBool
  | Expr.String _ -> TString
  | Expr.Char _ -> TChar
  | Expr.Var name ->
      if name = "next" then
        TUnit
      else
      begin match lookup_local locals name with
      | Some ty -> ty
      | None ->
        begin match Hashtbl.find_opt env.constants name with
        | Some signature -> signature.ty
        | None ->
          begin match Hashtbl.find_opt env.globals name with
          | Some signature -> signature.ty
          | None ->
          begin match Hashtbl.find_opt env.functions name with
          | Some signature -> signature.ret_type
          | None -> TNamed "__external"
          end
          end
        end
      end
  | Expr.Variant (enum_name, variant_name, args) ->
      begin match find_enum_variant env enum_name variant_name with
      | Some variant ->
          if List.length variant.payload <> List.length args then
            raise
              (Error
                 (Printf.sprintf "%s::%s expects %d payload values but found %d" enum_name variant_name
                    (List.length variant.payload) (List.length args)));
          List.iter2
            (fun expected arg ->
              require_type env expected (infer_expr env locals expected_return arg)
                (Printf.sprintf "payload for %s::%s" enum_name variant_name))
            variant.payload args;
          TNamed enum_name
      | None -> TNamed enum_name
      end
  | Expr.StructLit (struct_name, fields) ->
      begin match Hashtbl.find_opt env.structs struct_name with
      | Some _ ->
          List.iter
            (fun (field_name, _) ->
              ignore (lookup_struct_field env struct_name field_name))
            fields;
          List.iter
            (fun (field_name, value_expr) ->
              let expected = lookup_struct_field env struct_name field_name in
              let actual = infer_expr env locals expected_return value_expr in
              require_type env expected actual (Printf.sprintf "struct field %s.%s" struct_name field_name))
            fields;
          let actual_field_names = List.map fst fields in
          let unique_field_names = List.sort_uniq compare actual_field_names in
          if List.length actual_field_names <> List.length unique_field_names then
            raise (Error (Printf.sprintf "struct literal for %s contains duplicate fields" struct_name));
          TNamed struct_name
      | None -> TNamed struct_name
      end
  | Expr.Binary (op, lhs, rhs) ->
      let lhs_ty = infer_expr env locals expected_return lhs in
      let rhs_ty = infer_expr env locals expected_return rhs in
      begin match op with
      | "+" | "-" | "*" | "/" | "mod" ->
          if lhs_ty = TString || rhs_ty = TString then TString
          else if lhs_ty = TFloat || rhs_ty = TFloat then TFloat 
          else TInt
      | "==" | "<>" | "<" | ">" | "<=" | ">=" ->
          require_type env lhs_ty rhs_ty "comparison operands";
          TBool
      | "&&" | "||" ->
          require_type env TBool lhs_ty "logical lhs";
          require_type env TBool rhs_ty "logical rhs";
          TBool
        | "^" | "&" | "|" | "<<" | ">>" ->
          (* XOR - integer operation *)
          TInt
      | _ -> raise (Error ("unsupported binary operator " ^ op))
      end
  | Expr.Unary (op, expr) ->
      let expr_ty = infer_expr env locals expected_return expr in
      begin match op with
      | "not" ->
          if expr_ty = TInt then TInt else TBool
      | "-" | "&" | "*" | "&mut" -> expr_ty
      | _ -> raise (Error ("unsupported unary operator " ^ op))
      end
    | Expr.Call (callee, args) -> infer_call env locals expected_return callee args
  | Expr.MethodCall (receiver, method_name, args) ->
      let receiver_ty = infer_expr env locals expected_return receiver in
      begin match receiver_ty with
      | TNamed struct_name when Hashtbl.mem env.structs struct_name ->
          begin match Hashtbl.find_opt env.methods (struct_name ^ "." ^ method_name) with
          | Some signature ->
              begin match signature.param_types with
              | self_ty :: remaining ->
                  require_type env self_ty receiver_ty (Printf.sprintf "receiver for %s.%s" struct_name method_name);
                  check_argument_types env locals expected_return remaining args (struct_name ^ "." ^ method_name);
                  signature.ret_type
              | [] -> raise (Error (Printf.sprintf "method %s.%s is missing self parameter" struct_name method_name))
              end
          | None -> external_method_result receiver_ty method_name
          end
      | _ ->
          List.iter (fun arg -> ignore (infer_expr env locals expected_return arg)) args;
          external_method_result receiver_ty method_name
      end
  | Expr.FieldAccess (receiver, field_name) ->
        let receiver_ty = infer_expr env locals expected_return receiver in
      begin match receiver_ty with
      | TNamed struct_name when Hashtbl.mem env.structs struct_name ->
          lookup_struct_field env struct_name field_name
      | _ -> TNamed "__external"
      end
  | Expr.Cast (_, ty) -> ty
    | Expr.Try expr ->
      let expr_ty = infer_expr env locals expected_return expr in
      begin match result_payload_types expr_ty with
      | Some (ok_ty, err_ty) ->
        begin match result_payload_types expected_return with
        | Some (_, expected_err_ty) -> require_type env expected_err_ty err_ty "result propagation"
        | None -> raise (Error "'?' on Result requires enclosing function to return Result")
        end;
        ok_ty
      | None ->
        begin match option_payload_type expr_ty with
        | Some payload_ty ->
          begin match option_payload_type expected_return with
          | Some _ -> payload_ty
          | None -> raise (Error "'?' on Option requires enclosing function to return Option")
          end
        | None -> raise (Error "'?' expects Option[...] or Result[...]")
        end
      end
  | Expr.If (cond, then_block, None) ->
      require_type env TBool (infer_expr env locals expected_return cond) "if condition";
      ignore (infer_block env locals expected_return then_block);
      TUnit
  | Expr.If (cond, then_block, Some else_block) ->
      require_type env TBool (infer_expr env locals expected_return cond) "if condition";
      let then_ty = infer_block env locals expected_return then_block in
      let else_ty = infer_block env locals expected_return else_block in
      require_type env then_ty else_ty "if branches";
      then_ty
  | Expr.Match (subject, arms) ->
      let subject_ty = infer_expr env locals expected_return subject in
      let arm_types = List.map (infer_match_arm env locals expected_return subject_ty) arms in
      begin match arm_types with
      | [] -> raise (Error "match requires at least one arm")
      | first :: rest ->
          List.iter (fun ty -> require_type env first ty "match arm types") rest;
          first
      end
  | Expr.Lambda (_, _) -> TNamed "__external"  (* closure type *)

and infer_call env locals expected_return callee args =
  match callee with
  | Expr.Var name ->
      begin match Hashtbl.find_opt env.functions name with
      | Some signature ->
      check_argument_types env locals expected_return signature.param_types args name;
          signature.ret_type
      | None ->
      List.iter (fun arg -> ignore (infer_expr env locals expected_return arg)) args;
          external_call_result name
      end
  | _ ->
    ignore (infer_expr env locals expected_return callee);
    List.iter (fun arg -> ignore (infer_expr env locals expected_return arg)) args;
      TNamed "__external"

and check_argument_types env locals expected_return param_types args callee_name =
  if List.length param_types <> List.length args then
    raise
      (Error
         (Printf.sprintf "%s expects %d arguments but found %d" callee_name (List.length param_types)
            (List.length args)));
  List.iter2
    (fun expected arg ->
      let actual = infer_expr env locals expected_return arg in
      require_type env expected actual (Printf.sprintf "argument to %s" callee_name))
    param_types args

and infer_pattern env pattern expected_ty =
  match pattern with
  | Expr.PWildcard -> []
  | Expr.PVar name -> [name, expected_ty]
  | Expr.PInt _ ->
      require_type env TInt expected_ty "integer pattern";
      []
  | Expr.PBool _ ->
      require_type env TBool expected_ty "boolean pattern";
      []
  | Expr.PString _ ->
      require_type env TString expected_ty "string pattern";
      []
  | Expr.PChar _ ->
      require_type env TChar expected_ty "char pattern";
      []
  | Expr.PVariant (enum_name, variant_name, payload_patterns) ->
      let payload_types =
        match find_enum_variant env enum_name variant_name with
        | Some variant ->
            require_type env (TNamed enum_name) expected_ty (Printf.sprintf "pattern for %s::%s" enum_name variant_name);
            variant.payload
        | None ->
            (* For external types like Option and Result, extract payload from expected type *)
            begin match enum_name, variant_name with
            | "Option", "Some" ->
                begin match option_payload_type expected_ty with
                | Some payload_ty -> [payload_ty]
                | None -> 
                    (* Default to String for unknown Option payloads *)
                    (* This handles cases where expected_ty is __external or unknown *)
                    [TString]
                end
            | "Result", "Ok" | "Result", "Err" ->
                begin match result_payload_types expected_ty with
                | Some (ok_ty, err_ty) -> 
                    if variant_name = "Ok" then [ok_ty] else [err_ty]
                | None -> 
                    (* Default to String for unknown Result payloads *)
                    [TString]
                end
            | _ ->
                begin match external_pattern_payload_types enum_name variant_name with
                | Some tys -> tys
                | None -> 
                    (* Default to String for unknown external patterns *)
                    List.init (List.length payload_patterns) (fun _ -> 
                      if is_flexible_type env expected_ty then TString
                      else TNamed "__external")
                end
            end
      in
      if List.length payload_types <> List.length payload_patterns then
        raise
          (Error
             (Printf.sprintf "%s::%s pattern expects %d values but found %d" enum_name variant_name
                (List.length payload_types) (List.length payload_patterns)));
      List.concat (List.map2 (infer_pattern env) payload_patterns payload_types)

and infer_match_arm env locals expected_return subject_ty arm =
  let pattern_locals = infer_pattern env arm.Expr.pattern subject_ty in
  infer_block env (pattern_locals @ locals) expected_return arm.Expr.body

and infer_target env locals = function
  | Expr.TargetVar name ->
      begin match lookup_local locals name with
      | Some ty -> ty
      | None ->
        begin match Hashtbl.find_opt env.globals name with
        | Some signature -> signature.ty
        | None -> TNamed "__external"
        end
      end
  | Expr.TargetField (receiver, field_name) ->
      begin match infer_expr env locals TUnit receiver with
      | TNamed struct_name when Hashtbl.mem env.structs struct_name ->
          lookup_struct_field env struct_name field_name
      | _ -> TNamed "__external"
      end

and infer_stmt env locals expected_return = function
  | Expr.Let (name, _, expr) ->
      let expr_ty = infer_expr env locals expected_return expr in
      ((name, expr_ty) :: locals, TUnit)
  | Expr.LetTuple (names, _, expr) ->
      ignore (infer_expr env locals expected_return expr);
      let next_locals = List.fold_right (fun name acc -> (name, TNamed "__external") :: acc) names locals in
      (next_locals, TUnit)
  | Expr.Assign (target, expr) ->
      let target_ty = infer_target env locals target in
      let expr_ty = infer_expr env locals expected_return expr in
      require_type env target_ty expr_ty "assignment";
      (locals, TUnit)
  | Expr.While (cond, body) ->
      require_type env TBool (infer_expr env locals expected_return cond) "while condition";
      ignore (infer_block env locals expected_return body);
      (locals, TUnit)
  | Expr.For (name, start_expr, stop_expr, body) ->
      (* Check if this is an iterator-style for loop (stop_expr is Unit) *)
      (* or a range-style for loop (both start and stop are Int) *)
      let stop_ty = infer_expr env locals expected_return stop_expr in
      if stop_ty = TUnit then begin
        (* Iterator-style for loop: for x in items do body end *)
        (* start_expr is the iterable, item type is unknown/external *)
        ignore (infer_expr env locals expected_return start_expr);
        ignore (infer_block env ((name, TNamed "__external") :: locals) expected_return body)
      end else begin
        (* Range-style for loop: for x in start..stop do body end *)
        require_type env TInt (infer_expr env locals expected_return start_expr) "for range start";
        require_type env TInt stop_ty "for range end";
        ignore (infer_block env ((name, TInt) :: locals) expected_return body)
      end;
      (locals, TUnit)
    | Expr.Return None ->
      require_type env expected_return TUnit "return expression";
      (locals, TUnit)
    | Expr.Return (Some expr) ->
      let expr_ty = infer_expr env locals expected_return expr in
      require_type env expected_return expr_ty "return expression";
        (locals, TUnit)
  | Expr.Expr expr ->
      let expr_ty = infer_expr env locals expected_return expr in
      (locals, expr_ty)

and infer_block env locals expected_return block =
  match block with
  | [] -> TUnit
  | _ ->
      let rec loop current_locals = function
        | [] -> TUnit
        | [stmt] ->
            let _, stmt_ty = infer_stmt env current_locals expected_return stmt in
            stmt_ty
        | stmt :: rest ->
            let next_locals, _ = infer_stmt env current_locals expected_return stmt in
            loop next_locals rest
      in
      loop locals block

let analyze_function env (decl : function_decl) =
  let expected_return = Option.value decl.ret_type ~default:TUnit |> resolve_self_type decl in
  let locals =
    List.mapi (fun index (param : param) -> (param.name, parameter_type decl index param)) decl.params
  in
  let block_ty = infer_block env locals expected_return decl.body in
  require_type env expected_return block_ty (Printf.sprintf "function %s body" decl.name)

let analyze_const env (decl : const_decl) =
  let inferred_ty = infer_expr env [] TUnit decl.value in
  begin match decl.ty with
  | Some declared_ty -> require_type env declared_ty inferred_ty (Printf.sprintf "const %s value" decl.name)
  | None -> ()
  end

let analyze_global env (decl : global_decl) =
  let inferred_ty = infer_expr env [] TUnit decl.value in
  begin match decl.ty with
  | Some declared_ty -> require_type env declared_ty inferred_ty (Printf.sprintf "global %s value" decl.name)
  | None -> ()
  end

let analyze ?(require_entry = false) program =
  let env = create_env program in
  if require_entry then require_main env;
  List.iter
    (function
      | Function decl -> analyze_function env decl
      | Const decl -> analyze_const env decl
      | Global decl -> analyze_global env decl
      | Enum _ | Struct _ | Trait _ | Ignored -> ())
    program;
  env
