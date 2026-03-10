open Ast

type env =
  { enums : (string, enum_decl) Hashtbl.t
  ; structs : (string, struct_decl) Hashtbl.t
  ; methods : (string, function_decl) Hashtbl.t
  ; functions : (string, function_decl) Hashtbl.t
  ; constants : (string, const_decl) Hashtbl.t
  ; globals : (string, global_decl) Hashtbl.t
  }

type local_info =
  { ty : type_expr
  ; is_mutable : bool
  }

type locals = (string * local_info) list

let sanitize_identifier name =
  let buffer = Buffer.create (String.length name + 8) in
  String.iteri
    (fun index ch ->
      let valid =
        match ch with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> true
        | _ -> false
      in
      let ch = if valid then ch else '_' in
      if index = 0 then
        match ch with
        | 'a' .. 'z' | 'A' .. 'Z' | '_' -> Buffer.add_char buffer ch
        | '0' .. '9' ->
            Buffer.add_char buffer '_';
            Buffer.add_char buffer ch
        | _ -> Buffer.add_char buffer '_'
      else
        Buffer.add_char buffer ch)
    name;
  match Buffer.contents buffer with
  | "type" -> "tg_type"
  | "match" -> "tg_match"
  | "end" -> "tg_end"
  | "module" -> "tg_module"
  | "let" -> "tg_let"
  | "method" -> "tg_method"
  | "val" -> "tg_val"
  | "in" -> "tg_in"
  | "if" -> "tg_if"
  | "then" -> "tg_then"
  | "else" -> "tg_else"
  | "for" -> "tg_for"
  | "to" -> "tg_to"
  | "do" -> "tg_do"
  | "done" -> "tg_done"
  | "while" -> "tg_while"
  | "function" -> "tg_function"
  | "fun" -> "tg_fun"
  | "raise" -> "tg_raise"
  | "try" -> "tg_try"
  | "with" -> "tg_with"
  | "of" -> "tg_of"
  | "and" -> "tg_and"
  | "rec" -> "tg_rec"
  | "true" -> "tg_true"
  | "false" -> "tg_false"
  | "begin" -> "tg_begin"
  | "sig" -> "tg_sig"
  | "struct" -> "tg_struct"
  | "open" -> "tg_open"
  | "include" -> "tg_include"
  | "ref" -> "tg_ref"
  | "not" -> "tg_not"
  | "mod" -> "tg_mod"
  | "mode" -> "tg_mode"
  | "land" -> "tg_land"
  | "lor" -> "tg_lor"
  | "lxor" -> "tg_lxor"
  | "lsl" -> "tg_lsl"
  | "lsr" -> "tg_lsr"
  | "asr" -> "tg_asr"
  | "unit" -> "tg_unit"
  | "int" -> "tg_int"
  | "float" -> "tg_float"
  | "bool" -> "tg_bool"
  | "char" -> "tg_char"
  | "string" -> "tg_string"
  | "list" -> "tg_list"
  | "array" -> "tg_array"
  | "option" -> "tg_option"
  | "some" -> "tg_some"
  | "none" -> "tg_none"
  | "ok" -> "tg_ok"
  | "error" -> "tg_error"
  | "result" -> "tg_result"
  | text -> text

let type_name name =
  let sanitized = sanitize_identifier name in
  let lowercased = String.uncapitalize_ascii sanitized in
  (* Check for OCaml keywords after lowercasing *)
  match lowercased with
  | "mode" -> "tg_mode"
  | "mod" -> "tg_mod"
  | "land" -> "tg_land"
  | "lor" -> "tg_lor"
  | "lxor" -> "tg_lxor"
  | "lsl" -> "tg_lsl"
  | "lsr" -> "tg_lsr"
  | "asr" -> "tg_asr"
  | _ -> lowercased

let record_field_label struct_name field_name =
  sanitize_identifier (type_name struct_name ^ "__" ^ field_name)

let function_name ?method_of name =
  let base_name = sanitize_identifier name in
  (* OCaml requires function names to start with lowercase *)
  let base_name = String.uncapitalize_ascii base_name in
  match method_of with
  | Some struct_name -> sanitize_identifier (type_name struct_name ^ "__" ^ name)
  | None -> base_name

let value_name name = String.uncapitalize_ascii (sanitize_identifier name)

let ocaml_constructor_name enum_name variant_name =
  match enum_name, variant_name with
  | "Option", "Some" -> "Some"
  | "Option", "None" -> "None"
  | "Result", "Ok" -> "Ok"
  | "Result", "Err" -> "Error"
  | _ ->
      let text = sanitize_identifier (enum_name ^ "_" ^ variant_name) in
      String.capitalize_ascii text

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

let current_return_exception : string option ref = ref None

let current_return_type : type_expr option ref = ref None

(* Track if we're inside a loop that needs break support *)
let current_break_exception : string option ref = ref None

(* Check if a block contains a break statement *)
let rec has_break_in_block block =
  List.exists has_break_in_stmt block

and has_break_in_stmt = function
  | Expr.Expr (Expr.Var "break") -> true
  | Expr.Let (_, _, e) -> has_break_in_expr e
  | Expr.LetTuple (_, _, e) -> has_break_in_expr e
  | Expr.Assign (_, e) -> has_break_in_expr e
  | Expr.While (cond, body) -> has_break_in_expr cond || has_break_in_block body
  | Expr.For (_, start, stop, body) -> has_break_in_expr start || has_break_in_expr stop || has_break_in_block body
  | Expr.Return None -> false
  | Expr.Return (Some e) -> has_break_in_expr e
  | Expr.Expr e -> has_break_in_expr e

and has_break_in_expr = function
  | Expr.If (_, then_block, else_opt) ->
      has_break_in_block then_block ||
      (match else_opt with Some else_block -> has_break_in_block else_block | None -> false)
  | Expr.Match (_, arms) ->
      List.exists (fun arm -> has_break_in_block arm.Expr.body) arms
  | Expr.Lambda (_, body) -> has_break_in_expr body
  | Expr.Call (callee, args) -> has_break_in_expr callee || List.exists has_break_in_expr args
  | Expr.MethodCall (receiver, _, args) -> has_break_in_expr receiver || List.exists has_break_in_expr args
  | Expr.Binary (_, lhs, rhs) -> has_break_in_expr lhs || has_break_in_expr rhs
  | Expr.Unary (_, e) -> has_break_in_expr e
  | Expr.FieldAccess (receiver, _) -> has_break_in_expr receiver
  | Expr.Cast (e, _) -> has_break_in_expr e
  | Expr.Try e -> has_break_in_expr e
  | _ -> false

let build_env program =
  let env =
    { enums = Hashtbl.create 32
    ; structs = Hashtbl.create 16
    ; methods = Hashtbl.create 16
    ; functions = Hashtbl.create 16
    ; constants = Hashtbl.create 16
    ; globals = Hashtbl.create 16
    }
  in
  List.iter
    (function
      | Enum decl -> Hashtbl.replace env.enums decl.name decl
      | Struct decl -> Hashtbl.replace env.structs decl.name decl
      | Trait _ -> ()
      | Const decl -> Hashtbl.replace env.constants decl.name decl
      | Global decl -> Hashtbl.replace env.globals decl.name decl
      | Function decl ->
          begin match decl.method_of with
          | Some struct_name -> 
              Hashtbl.replace env.methods (struct_name ^ "." ^ decl.name) decl;
              (* Also add by unqualified method name for direct calls *)
              Hashtbl.replace env.methods decl.name decl
              (* Don't add methods to functions - let them be treated as external *)
          | None -> Hashtbl.replace env.functions decl.name decl
          end
      | Ignored -> ())
    program;
  env

let is_known_enum env name = Hashtbl.mem env.enums name

(* Case-insensitive hashtbl lookup for struct names *)
let find_struct_ci env name =
  let lower = String.lowercase_ascii name in
  let result = ref None in
  Hashtbl.iter (fun k v ->
    if String.lowercase_ascii k = lower then
      result := Some (k, v)
  ) env.structs;
  !result

(* Case-insensitive hashtbl lookup for enum names *)
let find_enum_ci env name =
  let lower = String.lowercase_ascii name in
  let result = ref None in
  Hashtbl.iter (fun k v ->
    if String.lowercase_ascii k = lower then
      result := Some (k, v)
  ) env.enums;
  !result

let ocaml_type_of env = function
  | TInt -> "int64"
  | TBool -> "bool"
  | TUnit -> "unit"
  | TFloat -> "float"
  | TString -> "string"
  | TChar -> "string"
  | TNamed name ->
      if has_prefix name "Vec[" || has_prefix name "List[" then
        "(* " ^ name ^ " *) unit list"
      else if has_prefix name "Map[" then
        "(* " ^ name ^ " *) (string * unit) list"
      else if has_prefix name "Option[" then
        "(* " ^ name ^ " *) unit option"
      else if has_prefix name "Result[" then
        "(* " ^ name ^ " *) (unit, unit) result"
      else if Hashtbl.mem env.structs name then
        type_name name
      else if is_known_enum env name then
        type_name name
      else
        (* Try case-insensitive lookup *)
        match find_struct_ci env name with
        | Some (actual_name, _) -> 
            (* prerr_endline ("DEBUG: ocaml_type_of " ^ name ^ " found ci struct " ^ actual_name); *)
            type_name actual_name
        | None ->
            match find_enum_ci env name with
            | Some (actual_name, _) -> type_name actual_name
            | None -> 
                (* prerr_endline ("DEBUG: ocaml_type_of " ^ name ^ " NOT FOUND, using Obj.t"); *)
                "Obj.t"

(* Strip reference/pointer type wrappers *)
let strip_reference = function
  | TNamed name when String.length name > 1 && name.[0] = '&' -> 
      TNamed (String.sub name 1 (String.length name - 1))
  | TNamed name when String.length name > 1 && name.[0] = '*' -> 
      TNamed (String.sub name 1 (String.length name - 1))
  | other -> other

let parameter_type decl index (param : param) =
  match param.ty, decl.method_of, index, param.name with
  | Some ty, _, _, _ -> strip_reference ty
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

let find_enum_variant env enum_name variant_name =
  match Hashtbl.find_opt env.enums enum_name with
  | None -> None
  | Some decl -> List.find_opt (fun (variant : enum_variant) -> variant.name = variant_name) decl.variants

let rec emit_default_value env = function
  | TInt -> "Int64.zero"
  | TBool -> "false"
  | TUnit -> "()"
  | TFloat -> "0.0"
  | TString -> "\"\""
  | TChar -> "\"\\000\""
  | TNamed name ->
      if has_prefix name "Vec[" || has_prefix name "List[" then
        "[]"
      else if has_prefix name "Map[" then
        "[]"
      else if has_prefix name "Option[" then
        "None"
      else if has_prefix name "Result[" then
        "Error ()"
      else
        begin match Hashtbl.find_opt env.structs name with
        | Some decl ->
            let field_text =
              decl.fields
              |> List.map (fun (field : struct_field) ->
                Printf.sprintf "%s = %s" (record_field_label decl.name field.name) (emit_default_value env field.ty))
              |> String.concat "; "
            in
            Printf.sprintf "{ %s }" field_text
        | None ->
            begin match Hashtbl.find_opt env.enums name with
            | Some decl ->
                begin match decl.variants with
                | variant :: _ -> emit_variant env name variant.name (List.map (emit_default_value env) variant.payload)
                | [] -> "\"\""
                end
            | None -> "Obj.magic ()"  (* External type - use magic placeholder *)
            end
        end

and emit_variant _env enum_name variant_name payload_values =
  let ctor = ocaml_constructor_name enum_name variant_name in
  match payload_values with
  | [] -> ctor
  | [value] -> Printf.sprintf "%s (%s)" ctor value
  | _ -> Printf.sprintf "%s (%s)" ctor (String.concat ", " payload_values)

(* Normalize type names - convert "Bool" to TBool etc. *)
let normalize_type = function
  | TNamed "Bool" -> TBool
  | TNamed "Int" -> TInt
  | TNamed "Float" -> TFloat
  | TNamed "String" -> TString
  | TNamed "Char" -> TChar
  | TNamed "Unit" -> TUnit
  | other -> other

let external_call_result = function
  | "fmt::format" -> TString
  | "has_errors" -> TBool
  | "has_warnings" -> TBool
  | name when String.length name >= 10 && String.sub name (String.length name - 10) 10 = "::to_string" -> TString
  | name when String.length name >= 10 && String.sub name (String.length name - 10) 10 = "::of_string" -> TInt
  | name when String.length name >= 7 && String.sub name (String.length name - 7) 7 = "::to_int" -> TInt
  | name when String.length name >= 7 && String.sub name (String.length name - 7) 7 = "::of_int" -> TInt
  | name when String.length name >= 9 && String.sub name (String.length name - 9) 9 = "::to_float" -> TFloat
  | name when String.length name >= 9 && String.sub name (String.length name - 9) 9 = "::of_float" -> TInt
  | name when String.length name >= 5 && String.sub name (String.length name - 5) 5 = "::len" -> TInt
  | name when String.length name >= 9 && String.sub name (String.length name - 9) 9 = "::length" -> TInt
  | name when String.length name >= 10 && String.sub name (String.length name - 10) 10 = "::is_empty" -> TBool
  | name when String.length name >= 10 && String.sub name (String.length name - 10) 10 = "::is_some" -> TBool
  | name when String.length name >= 10 && String.sub name (String.length name - 10) 10 = "::is_none" -> TBool
  | name when String.length name >= 8 && String.sub name (String.length name - 8) 8 = "::is_ok" -> TBool
  | name when String.length name >= 9 && String.sub name (String.length name - 9) 9 = "::is_err" -> TBool
  | name when has_prefix name "Option::" -> TNamed "Option"
  | name when has_prefix name "Result::" -> TNamed "Result"
  | _ -> TNamed "__external"

let external_method_result receiver_ty method_name =
  match method_name with
  | "to_string" -> TString
  | "poll_event" -> TNamed "Option"
  | "window_new" | "surface" | "begin_frame" -> TNamed "Result"
  | "default" -> receiver_ty
  | _ -> TNamed "__external"

let require_return_context () =
  match !current_return_exception, !current_return_type with
  | Some exception_name, Some return_ty -> exception_name, return_ty
  | _ -> failwith "missing return context"

let rec infer_expr_type env locals = function
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
      | Some info -> info.ty
      | None ->
        begin match Hashtbl.find_opt env.constants name with
        | Some decl -> Option.value decl.ty ~default:(infer_expr_type env locals decl.value)
        | None ->
          begin match Hashtbl.find_opt env.functions name with
          | Some decl -> Option.value decl.ret_type ~default:TUnit
          | None -> TNamed "__external"
          end
        end
      end
  | Expr.Variant (enum_name, variant_name, _) ->
      begin match find_enum_variant env enum_name variant_name with
      | Some _ -> TNamed enum_name
      | None -> TNamed enum_name
      end
  | Expr.StructLit (struct_name, _) -> TNamed struct_name
  | Expr.Binary (op, lhs, rhs) ->
      begin match op with
      | "+" ->
          (* For +, check for string concatenation *)
          let lhs_ty = infer_expr_type env locals lhs in
          let rhs_ty = infer_expr_type env locals rhs in
          if lhs_ty = TString || rhs_ty = TString then TString
          else if lhs_ty = TFloat || rhs_ty = TFloat then TFloat 
          else TInt
      | "-" | "*" | "/" | "mod" ->
          (* Arithmetic ops - result is numeric *)
          let lhs_ty = infer_expr_type env locals lhs in
          let rhs_ty = infer_expr_type env locals rhs in
          if lhs_ty = TFloat || rhs_ty = TFloat then TFloat 
          else TInt
      | _ -> TBool
      end
  | Expr.Unary (op, expr) ->
      begin match op with
      | "not" -> TBool
      | _ -> infer_expr_type env locals expr
      end
  | Expr.Call (Expr.Var name, _) ->
      begin match Hashtbl.find_opt env.functions name with
      | Some decl -> 
          let ret = Option.value decl.ret_type ~default:TUnit |> resolve_self_type decl |> normalize_type in
          ret
      | None -> 
          external_call_result name
      end
  | Expr.Call (_, _) -> TNamed "__external"
  | Expr.MethodCall (receiver, method_name, _) ->
      begin match infer_expr_type env locals receiver with
      | TNamed struct_name when Hashtbl.mem env.structs struct_name ->
          begin match Hashtbl.find_opt env.methods (struct_name ^ "." ^ method_name) with
          | Some decl -> Option.value decl.ret_type ~default:TUnit |> resolve_self_type decl
          | None -> external_method_result (TNamed struct_name) method_name
          end
      | receiver_ty -> external_method_result receiver_ty method_name
      end
  | Expr.FieldAccess (receiver, field_name) ->
      begin match infer_expr_type env locals receiver with
      | TNamed struct_name when Hashtbl.mem env.structs struct_name ->
          let decl = Hashtbl.find env.structs struct_name in
          let field = List.find (fun (candidate : struct_field) -> candidate.name = field_name) decl.fields in
          field.ty
      | _ -> TNamed "__external"
      end
  | Expr.Cast (_, ty) -> ty
  | Expr.Try expr ->
      begin match result_payload_types (infer_expr_type env locals expr) with
      | Some (ok_ty, _) -> ok_ty
      | None ->
        begin match option_payload_type (infer_expr_type env locals expr) with
        | Some payload_ty -> payload_ty
        | None -> TNamed "__external"
        end
      end
  | Expr.If (_, then_block, _) -> infer_block_type env locals then_block
  | Expr.Match (subject, arms) ->
      begin match infer_expr_type env locals subject with
      | TNamed enum_name when Hashtbl.mem env.enums enum_name ->
          begin match arms with
          | arm :: _ -> infer_block_type env locals arm.Expr.body
          | [] -> TUnit
          end
      | _ ->
          begin match List.rev arms with
          | arm :: _ -> infer_block_type env locals arm.Expr.body
          | [] -> TUnit
          end
      end
  | Expr.Lambda (_, _) -> TNamed "__external"  (* closure type *)

and infer_block_type env locals block =
  match block with
  | [] -> TUnit
  | _ ->
      let rec loop current_locals = function
        | [] -> TUnit
        | [Expr.Let (name, is_mutable, expr)] ->
            let ty = infer_expr_type env current_locals expr in
            let info = { ty; is_mutable } in
            loop ((name, info) :: current_locals) []
        | [Expr.LetTuple (names, is_mutable, expr)] ->
          let _ = infer_expr_type env current_locals expr in
          let next_locals =
            List.fold_right
            (fun name acc -> (name, { ty = TNamed "__external"; is_mutable }) :: acc)
            names current_locals
          in
          loop next_locals []
        | [Expr.Assign _] | [Expr.While _] | [Expr.For _] -> TUnit
        | [Expr.Return None] -> TUnit
        | [Expr.Return (Some expr)] -> infer_expr_type env current_locals expr
        | [Expr.Expr expr] -> infer_expr_type env current_locals expr
        | Expr.Let (name, is_mutable, expr) :: rest ->
            let ty = infer_expr_type env current_locals expr in
            let info = { ty; is_mutable } in
            loop ((name, info) :: current_locals) rest
        | Expr.LetTuple (names, is_mutable, expr) :: rest ->
          let _ = infer_expr_type env current_locals expr in
          let next_locals =
            List.fold_right
            (fun name acc -> (name, { ty = TNamed "__external"; is_mutable }) :: acc)
            names current_locals
          in
          loop next_locals rest
        | Expr.Assign _ :: rest -> loop current_locals rest
        | Expr.While _ :: rest -> loop current_locals rest
        | Expr.For _ :: rest -> loop current_locals rest
        | Expr.Return None :: _ -> TUnit
        | Expr.Return (Some expr) :: _ -> infer_expr_type env current_locals expr
        | Expr.Expr _ :: rest -> loop current_locals rest
      in
      loop locals block

let emit_string_literal text = Printf.sprintf "%S" text

let emit_char_literal ch = emit_string_literal ch

let emit_float_literal text =
  if String.contains text '.' then text else text ^ ".0"

let pattern_uses_variant = function
  | Expr.PVariant _ -> true
  | _ -> false

let rec emit_return_raise env locals expr_opt =
  let exception_name, return_ty = require_return_context () in
  let ret_type_text = ocaml_type_of env return_ty in
  if ret_type_text = "unit" then
    Printf.sprintf "raise %s" exception_name
  else
    let value_text =
      match expr_opt with
      | Some expr -> emit_expr env locals expr
      | None -> "()"
    in
    Printf.sprintf "raise (%s (%s))" exception_name value_text

and emit_try_propagation env locals expr =
  let exception_name, return_ty = require_return_context () in
  match result_payload_types (infer_expr_type env locals expr) with
  | Some _ ->
      begin match result_payload_types return_ty with
      | Some _ ->
          let ok_ctor = ocaml_constructor_name "Result" "Ok" in
          let err_ctor = ocaml_constructor_name "Result" "Err" in
          Printf.sprintf "(match %s with %s value -> value | %s err -> raise (%s (%s err)))"
            (emit_expr env locals expr) ok_ctor err_ctor exception_name err_ctor
      | None -> failwith "result propagation requires Result return type"
      end
  | None ->
      begin match option_payload_type (infer_expr_type env locals expr), option_payload_type return_ty with
      | Some _, Some _ ->
          let some_ctor = ocaml_constructor_name "Option" "Some" in
          let none_ctor = ocaml_constructor_name "Option" "None" in
          Printf.sprintf "(match %s with %s value -> value | %s -> raise (%s %s))"
            (emit_expr env locals expr) some_ctor none_ctor exception_name none_ctor
      | _ -> failwith "option propagation requires Option return type"
      end

and emit_string_conversion env locals expr =
  let emitted = emit_expr env locals expr in
  match infer_expr_type env locals expr with
  | TString -> emitted
  | TBool -> Printf.sprintf "string_of_bool (%s)" emitted
  | TFloat -> Printf.sprintf "string_of_float (%s)" emitted
  | TChar -> emitted
  | TInt -> Printf.sprintf "Int64.to_string (%s)" emitted
  | _ -> 
      (* For external types, use Obj.magic to coerce to string *)
      Printf.sprintf "(Obj.magic %s : string)" emitted

and is_external_type = function
  | TNamed n -> n = "__external"
  | _ -> false

and emit_expr env locals = function
  | Expr.Unit -> "()"
  | Expr.Int n -> 
      if n >= 0L && n < 2147483647L then 
        Printf.sprintf "Int64.of_int %s" (Int64.to_string n)
      else 
        Printf.sprintf "Int64.of_string \"%s\"" (Int64.to_string n)
  | Expr.Float text -> emit_float_literal text
  | Expr.Bool b -> if b then "true" else "false"
  | Expr.String text -> emit_string_literal text
  | Expr.Char ch -> emit_char_literal ch
  | Expr.Var "break" ->
      (* Break statement - raise break exception if inside a loop *)
      (match !current_break_exception with
       | Some exc_name -> Printf.sprintf "raise %s" exc_name
       | None -> "()")  (* No loop context, ignore *)
  | Expr.Var "next" -> "()"
  | Expr.Var name ->
      begin match lookup_local locals name with
      | Some { is_mutable = true; _ } -> Printf.sprintf "!%s" (sanitize_identifier name)
      | _ ->
        if Hashtbl.mem env.constants name then value_name name
        else if Hashtbl.mem env.globals name then
          let decl = Hashtbl.find env.globals name in
          if decl.is_mutable then Printf.sprintf "!%s" (value_name name) else value_name name
        else sanitize_identifier name
      end
  | Expr.Variant (enum_name, variant_name, args) ->
      begin match find_enum_variant env enum_name variant_name with
      | Some _ -> emit_variant env enum_name variant_name (List.map (emit_expr env locals) args)
      | None -> emit_default_value env (infer_expr_type env locals (Expr.Variant (enum_name, variant_name, args)))
      end
  | Expr.StructLit (struct_name, fields) ->
      begin match Hashtbl.find_opt env.structs struct_name with
      | Some decl ->
          let provided_fields = List.to_seq fields |> Hashtbl.of_seq in
          let field_text =
            decl.fields
            |> List.map (fun (field : struct_field) ->
              let value_text =
                match Hashtbl.find_opt provided_fields field.name with
                | Some value -> emit_expr env locals value
                | None -> emit_default_value env field.ty
              in
              Printf.sprintf "%s = %s" (record_field_label struct_name field.name) value_text)
            |> String.concat "; "
          in
          Printf.sprintf "{ %s }" field_text
      | None -> emit_default_value env (TNamed struct_name)
      end
  | Expr.Binary (op, lhs, rhs) ->
      let lhs_ty = infer_expr_type env locals lhs in
      let rhs_ty = infer_expr_type env locals rhs in
      let is_float = lhs_ty = TFloat || rhs_ty = TFloat in
      let is_string ty = ty = TString in
      let is_string_op = is_string lhs_ty || is_string rhs_ty in
      let is_external ty = match ty with TNamed n -> n = "__external" | _ -> false in
      let is_int_or_ext = (lhs_ty = TInt || is_external lhs_ty) && (rhs_ty = TInt || is_external rhs_ty) && not is_float && not is_string_op in
      let use_int64_op = is_int_or_ext && match op with
        | "+" | "-" | "*" | "/" | "mod" | "<" | ">" | "<=" | ">=" | "^" | "&" | "|" | "<<" | ">>" -> true
        | _ -> false
      in
      let emitted_op = match op with
        | "+" -> if is_float then "+." else if is_string_op then "^" else op
        | "-" -> if is_float then "-." else op
        | "*" -> if is_float then "*." else op
        | "/" -> if is_float then "/." else op
        | "==" -> "="
        | _ -> op
      in
      if use_int64_op then
        let int64_op, is_comparison =
          match op with
          | "+" -> "Int64.add", false
          | "-" -> "Int64.sub", false
          | "*" -> "Int64.mul", false
          | "/" -> "Int64.div", false
          | "mod" -> "Int64.rem", false
          | "^" -> "Int64.logxor", false
          | "&" -> "Int64.logand", false
          | "|" -> "Int64.logor", false
          | "<<" -> "Int64.shift_left", false
          | ">>" -> "Int64.shift_right", false
          | "<" -> "Int64.compare", true
          | ">" -> "Int64.compare", true
          | "<=" -> "Int64.compare", true
          | ">=" -> "Int64.compare", true
          | _ -> op, false
        in
        (* Cast external types to int64 for Int64 operations *)
        let emit_int64_expr expr =
          let emitted = emit_expr env locals expr in
          let ty = infer_expr_type env locals expr in
          match ty with
          | TInt -> emitted
          | _ -> Printf.sprintf "(Obj.magic %s : int64)" emitted
        in
        if is_comparison then
          let cmp_op =
            match op with
            | "<" -> "<"
            | ">" -> ">"
            | "<=" -> "<="
            | ">=" -> ">="
            | _ -> "="
          in
          Printf.sprintf "((%s (%s) (%s)) %s 0)" int64_op (emit_int64_expr lhs) (emit_int64_expr rhs) cmp_op
        else
          if op = "<<" || op = ">>" then
            let rhs_shift =
              let emitted = emit_expr env locals rhs in
              let ty = infer_expr_type env locals rhs in
              match ty with
              | TInt -> Printf.sprintf "(Int64.to_int (%s))" emitted
              | _ -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
            in
            Printf.sprintf "(%s (%s) %s)" int64_op (emit_int64_expr lhs) rhs_shift
          else
            Printf.sprintf "(%s (%s) (%s))" int64_op (emit_int64_expr lhs) (emit_int64_expr rhs)
      else if is_string_op && op = "+" then
        (* String concatenation - convert non-string operands to string *)
        let lhs_text = if lhs_ty = TString then emit_expr env locals lhs else emit_string_conversion env locals lhs in
        let rhs_text = if rhs_ty = TString then emit_expr env locals rhs else emit_string_conversion env locals rhs in
        Printf.sprintf "(%s ^ %s)" lhs_text rhs_text
      else
        Printf.sprintf "(%s %s %s)" (emit_expr env locals lhs) emitted_op (emit_expr env locals rhs)
  | Expr.Unary (op, expr) ->
      begin match op with
      | "not" ->
          let expr_ty = infer_expr_type env locals expr in
          if expr_ty = TInt then
            Printf.sprintf "(Int64.lognot (%s))" (emit_expr env locals expr)
          else
            Printf.sprintf "(not (Obj.magic (%s) : bool))" (emit_expr env locals expr)
      | "-" -> 
          let expr_ty = infer_expr_type env locals expr in
          if expr_ty = TInt then
            Printf.sprintf "(Int64.neg (%s))" (emit_expr env locals expr)
          else if expr_ty = TFloat then
            Printf.sprintf "(-. (%s))" (emit_expr env locals expr)
          else
            Printf.sprintf "(-(%s))" (emit_expr env locals expr)
      | "&" | "*" | "&mut" -> emit_expr env locals expr
      | _ -> emit_expr env locals expr
      end
  | Expr.Call (Expr.Var "fmt::format", [Expr.String _; value]) -> emit_string_conversion env locals value
  | Expr.Call (Expr.Var name, args) ->
      begin match Hashtbl.find_opt env.functions name, Hashtbl.find_opt env.methods name with
      | Some decl, _ ->
          let callee = function_name ?method_of:decl.method_of decl.name in
          emit_call callee env locals args
      | None, Some _ ->
          (* Method called directly by unqualified name - use unqualified name for stub matching *)
          let callee = String.uncapitalize_ascii (sanitize_identifier name) in
          emit_call callee env locals args
      | None, None ->
          (* External function - use lowercased sanitized name *)
          let callee = String.uncapitalize_ascii (sanitize_identifier name) in
          emit_call callee env locals args
      end
  | Expr.Call (callee, args) ->
      (* Handle curried calls like f(x)(y) where callee is itself a call *)
      let callee_text = emit_expr env locals callee in
      let emitted_args = List.map (fun arg -> Printf.sprintf "(%s)" (emit_expr env locals arg)) args in
      (match emitted_args with
       | [] -> callee_text
       | _ -> Printf.sprintf "(%s %s)" callee_text (String.concat " " emitted_args))
  | Expr.MethodCall (receiver, method_name, []) when method_name = "to_string" ->
      emit_string_conversion env locals receiver
  | Expr.MethodCall (receiver, method_name, args) ->
      begin match infer_expr_type env locals receiver with
      | TNamed struct_name when Hashtbl.mem env.structs struct_name ->
          begin match Hashtbl.find_opt env.methods (struct_name ^ "." ^ method_name) with
          | Some _ ->
              let method_fn = function_name ~method_of:struct_name method_name in
              emit_call method_fn env locals (receiver :: args)
          | None -> emit_default_value env (infer_expr_type env locals (Expr.MethodCall (receiver, method_name, args)))
          end
      | _ -> emit_default_value env (infer_expr_type env locals (Expr.MethodCall (receiver, method_name, args)))
      end
  | Expr.FieldAccess (receiver, field_name) ->
      begin match infer_expr_type env locals receiver with
      | TNamed struct_name when Hashtbl.mem env.structs struct_name ->
          Printf.sprintf "(%s).%s" (emit_expr env locals receiver) (record_field_label struct_name field_name)
      | _ ->
          (* Try to find a struct with this field name for external types *)
          let found_struct = ref None in
          Hashtbl.iter (fun name decl ->
            if List.exists (fun (f: struct_field) -> f.name = field_name) decl.fields then
              found_struct := Some name
          ) env.structs;
          match !found_struct with
          | Some struct_name ->
              Printf.sprintf "((Obj.magic %s : %s).%s)" (emit_expr env locals receiver) (type_name struct_name) (record_field_label struct_name field_name)
          | None ->
              emit_expr env locals receiver
      end
  | Expr.Cast (expr, ty) ->
      begin match infer_expr_type env locals expr, ty with
      | TInt, TFloat -> Printf.sprintf "Int64.to_float (%s)" (emit_expr env locals expr)
      | TFloat, TInt -> Printf.sprintf "Int64.of_float (%s)" (emit_expr env locals expr)
      | TInt, TString -> Printf.sprintf "Int64.to_string (%s)" (emit_expr env locals expr)
      | TString, TInt -> Printf.sprintf "Int64.of_string (%s)" (emit_expr env locals expr)
      | _, _ -> emit_expr env locals expr
      end
  | Expr.Try expr -> emit_try_propagation env locals expr
  | Expr.If (cond, then_block, None) ->
      let cond_expr = emit_expr env locals cond in
      let cond_ty = infer_expr_type env locals cond in
      let cond_text = match cond_ty with
        | TBool -> cond_expr
        | TNamed n when n = "__external" -> Printf.sprintf "(Obj.magic %s : bool)" cond_expr
        | _ -> cond_expr
      in
      Printf.sprintf "(if %s then (%s) else ())" cond_text (emit_block_unit env locals then_block)
  | Expr.If (cond, then_block, Some else_block) ->
      let cond_expr = emit_expr env locals cond in
      let cond_ty = infer_expr_type env locals cond in
      let cond_text = match cond_ty with
        | TBool -> cond_expr
        | TNamed n when n = "__external" -> Printf.sprintf "(Obj.magic %s : bool)" cond_expr
        | _ -> cond_expr
      in
      let then_expr = emit_block_expr env locals then_block in
      let else_expr = emit_block_expr env locals else_block in
      Printf.sprintf "(if %s then %s else %s)" cond_text then_expr else_expr
  | Expr.Match (subject, arms) ->
      let should_emit_match =
        match infer_expr_type env locals subject with
        | TNamed enum_name when Hashtbl.mem env.enums enum_name -> true
        | _ -> List.exists (fun arm -> pattern_uses_variant arm.Expr.pattern) arms
      in
      if should_emit_match then
          let arm_text =
            arms
            |> List.map (fun arm ->
              Printf.sprintf "| %s -> %s" (emit_pattern env arm.Expr.pattern) (emit_block_expr env locals arm.Expr.body))
            |> String.concat " "
          in
          Printf.sprintf "(match %s with %s)" (emit_expr env locals subject) arm_text
      else
          begin match List.rev arms with
          | arm :: _ -> emit_block_expr env locals arm.Expr.body
          | [] -> "()"
          end
  | Expr.Lambda (params, body) ->
      (* Closure: |a, b| body => fun a b -> body *)
      let param_names = List.map sanitize_identifier params in
      let new_locals = List.fold_right (fun name acc -> (name, { ty = TNamed "__external"; is_mutable = false }) :: acc) params locals in
      Printf.sprintf "(fun %s -> %s)" (String.concat " " param_names) (emit_expr env new_locals body)

and emit_call callee env locals args =
  (* Check if this is a known function to get param types *)
  let func_decl = 
    match Hashtbl.find_opt env.functions callee with
    | Some decl -> Some decl
    | None -> 
        (* Try to find by matching the name without module prefix *)
        let result = ref None in
        Hashtbl.iter (fun _k (v : function_decl) -> 
          let base_name = sanitize_identifier v.name |> String.uncapitalize_ascii in
          if base_name = callee then result := Some v
        ) env.functions;
        !result
  in
  (* Helper to check if a type is a known struct (case-insensitive) *)
  let is_known_struct ty =
    match ty with
    | TNamed name -> 
        (Hashtbl.mem env.structs name) || 
        (match find_struct_ci env name with Some _ -> true | None -> false)
    | _ -> false
  in
  (* Helper to check if param type is external (Obj.t) *)
  let is_external_param param_ty =
    match param_ty with
    | TNamed "__external" -> true
    | TNamed name -> 
        (* Check if this type resolves to Obj.t (not found in structs/enums) *)
        (not (Hashtbl.mem env.structs name)) &&
        (not (Hashtbl.mem env.enums name)) &&
        (match find_struct_ci env name with None -> true | Some _ -> false) &&
        (match find_enum_ci env name with None -> true | Some _ -> false)
    | _ -> false
  in
  let emitted_args = List.mapi (fun index arg ->
    let emitted = emit_expr env locals arg in
    let arg_ty = infer_expr_type env locals arg in
    (* If arg is a struct but function expects external, cast it *)
    match func_decl with
    | Some decl when index < List.length decl.params ->
        let param = List.nth decl.params index in
        let param_ty = parameter_type decl index param in
        if is_external_param param_ty && is_known_struct arg_ty then
          Printf.sprintf "(Obj.magic %s)" emitted
        else
          Printf.sprintf "(%s)" emitted
    | Some _ -> Printf.sprintf "(%s)" emitted
    | None ->
        (* For unknown functions, cast struct args to Obj.t *)
        if is_known_struct arg_ty then
          Printf.sprintf "(Obj.magic %s)" emitted
        else
          Printf.sprintf "(%s)" emitted
  ) args in
  match emitted_args with
  | [] -> Printf.sprintf "%s ()" callee
  | _ -> Printf.sprintf "%s %s" callee (String.concat " " emitted_args)

and emit_pattern env = function
  | Expr.PVariant (enum_name, variant_name, payload_patterns) ->
      let ctor = ocaml_constructor_name enum_name variant_name in
      begin match payload_patterns with
      | [] -> ctor
      | [pattern] -> Printf.sprintf "%s (%s)" ctor (emit_pattern env pattern)
      | _ -> Printf.sprintf "%s (%s)" ctor (String.concat ", " (List.map (emit_pattern env) payload_patterns))
      end
  | Expr.PInt n -> Printf.sprintf "Int64.of_string \"%s\"" (Int64.to_string n)
  | Expr.PBool b -> if b then "true" else "false"
  | Expr.PString text -> emit_string_literal text
  | Expr.PChar ch -> emit_char_literal ch
  | Expr.PVar name -> sanitize_identifier name
  | Expr.PWildcard -> "_"

and emit_assignment env locals target expr =
  match target with
  | Expr.TargetVar name ->
      begin match lookup_local locals name with
      | Some { is_mutable = true; _ } ->
          Printf.sprintf "%s := %s" (sanitize_identifier name) (emit_expr env locals expr)
    | _ ->
      begin match Hashtbl.find_opt env.globals name with
      | Some decl when decl.is_mutable -> Printf.sprintf "%s := %s" (value_name name) (emit_expr env locals expr)
      | _ -> Printf.sprintf "ignore (%s)" (emit_expr env locals expr)
      end
      end
  | Expr.TargetField (receiver, field_name) ->
      begin match infer_expr_type env locals receiver with
      | TNamed struct_name when Hashtbl.mem env.structs struct_name ->
          Printf.sprintf "(%s).%s <- %s" (emit_expr env locals receiver) (record_field_label struct_name field_name)
            (emit_expr env locals expr)
      | _ -> Printf.sprintf "ignore (%s)" (emit_expr env locals expr)
      end

and emit_stmt_expr env locals = function
  | Expr.Let (name, is_mutable, expr) ->
      let expr_text = emit_expr env locals expr in
      if is_mutable then
        Printf.sprintf "let %s = ref (%s) in ()" (sanitize_identifier name) expr_text
      else
        Printf.sprintf "let %s = %s in ()" (sanitize_identifier name) expr_text
  | Expr.LetTuple (names, is_mutable, expr) ->
      let pattern = String.concat ", " (List.map sanitize_identifier names) in
      if is_mutable then
        let refs =
          names
          |> List.map (fun name -> Printf.sprintf "let %s = ref %s in ()" (sanitize_identifier name) (sanitize_identifier name))
          |> String.concat "; "
        in
        Printf.sprintf "let (%s) = (Obj.magic (%s)) in (%s)" pattern (emit_expr env locals expr) refs
      else
        Printf.sprintf "let (%s) = (Obj.magic (%s)) in ()" pattern (emit_expr env locals expr)
  | Expr.Assign (target, expr) -> emit_assignment env locals target expr
  | Expr.While (cond, body) ->
      Printf.sprintf "while %s do %s done" (emit_expr env locals cond) (emit_block_unit env locals body)
  | Expr.Expr (Expr.Var "break") ->
      (* Break statement - raise break exception if inside a loop *)
      (match !current_break_exception with
       | Some exc_name -> Printf.sprintf "raise %s" exc_name
       | None -> "()")  (* No loop context, ignore *)
  | Expr.For (name, iterable, Expr.Unit, body) ->
      (* Iterator-style for loop: for x in items do body end *)
      (* Generate: List.iter (fun name -> body) items *)
      (* Cast iterable to list type for external values *)
      let iterable_expr = emit_expr env locals iterable in
      let iterable_ty = infer_expr_type env locals iterable in
      let iterable_text = match iterable_ty with
        | TNamed n when has_prefix n "Vec[" || has_prefix n "List[" || n = "__external" ->
            Printf.sprintf "(Obj.magic %s)" iterable_expr
        | _ -> iterable_expr
      in
      let body_has_break = has_break_in_block body in
      if body_has_break then
        (* Wrap with break exception handling *)
        let exc_name = "Break__" ^ sanitize_identifier name in
        let prev_break = !current_break_exception in
        current_break_exception := Some exc_name;
        let body_code = emit_block_unit env ((name, { ty = TNamed "__external"; is_mutable = false }) :: locals) body in
        current_break_exception := prev_break;
        Printf.sprintf "(try (List.iter (fun %s -> try %s with %s -> ()) %s) with %s -> ())" 
          (sanitize_identifier name) body_code exc_name iterable_text exc_name
      else
        Printf.sprintf "(List.iter (fun %s -> %s) %s)" (sanitize_identifier name) 
          (emit_block_unit env ((name, { ty = TNamed "__external"; is_mutable = false }) :: locals) body)
          iterable_text
  | Expr.For (name, start_expr, stop_expr, body) ->
      let start_ty = infer_expr_type env locals start_expr in
      let stop_ty = infer_expr_type env locals stop_expr in
      let start_text = 
        let emitted = emit_expr env locals start_expr in
        match start_ty with
        | TInt -> Printf.sprintf "(Int64.to_int (%s))" emitted
        | TNamed n when n = "__external" -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
        | _ -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
      in
      let stop_text = 
        let emitted = emit_expr env locals stop_expr in
        match stop_ty with
        | TInt -> Printf.sprintf "(Int64.to_int (%s))" emitted
        | TNamed n when n = "__external" -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
        | _ -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
      in
      let body_has_break = has_break_in_block body in
      if body_has_break then
        (* Wrap with break exception handling *)
        let exc_name = "Break__" ^ sanitize_identifier name in
        let prev_break = !current_break_exception in
        current_break_exception := Some exc_name;
        let body_code = emit_block_unit env ((name, { ty = TInt; is_mutable = false }) :: locals) body in
        current_break_exception := prev_break;
        Printf.sprintf "(try (for %s = %s to %s do try %s with %s -> () done) with %s -> ())" 
          (sanitize_identifier name) start_text stop_text body_code exc_name exc_name
      else
        Printf.sprintf "for %s = %s to %s do %s done" (sanitize_identifier name) 
          start_text stop_text
          (emit_block_unit env ((name, { ty = TInt; is_mutable = false }) :: locals) body)
  | Expr.Return None -> emit_return_raise env locals None
  | Expr.Return (Some expr) -> emit_return_raise env locals (Some expr)
  | Expr.Expr expr -> emit_expr env locals expr

and emit_block_unit env locals block =
  match block with
  | [] -> "()"
  | Expr.Return None :: _ -> emit_return_raise env locals None
  | Expr.Return (Some expr) :: _ -> emit_return_raise env locals (Some expr)
  | stmt :: rest ->
      begin match stmt with
      | Expr.Let (name, is_mutable, expr) ->
          let expr_text = emit_expr env locals expr in
          let ty = infer_expr_type env locals expr in
          let info = { ty; is_mutable } in
          if is_mutable then
            Printf.sprintf "let %s = ref (%s) in %s" (sanitize_identifier name) expr_text
              (emit_block_unit env ((name, info) :: locals) rest)
          else
            Printf.sprintf "let %s = %s in %s" (sanitize_identifier name) expr_text
              (emit_block_unit env ((name, info) :: locals) rest)
      | Expr.LetTuple (names, is_mutable, expr) ->
          let pattern = String.concat ", " (List.map sanitize_identifier names) in
          let next_locals =
            List.fold_right
              (fun name acc -> (name, { ty = TNamed "__external"; is_mutable }) :: acc)
              names locals
          in
          if is_mutable then
            let refs =
              names
              |> List.map (fun name -> Printf.sprintf "let %s = ref %s in " (sanitize_identifier name) (sanitize_identifier name))
              |> String.concat ""
            in
            let refs_close = String.make (List.length names) ')' in
            Printf.sprintf "let (%s) = (Obj.magic (%s)) in %s%s%s" pattern (emit_expr env locals expr) refs
              (emit_block_unit env next_locals rest) refs_close
          else
            Printf.sprintf "let (%s) = (Obj.magic (%s)) in %s" pattern (emit_expr env locals expr)
              (emit_block_unit env next_locals rest)
      | Expr.Assign (target, expr) ->
          Printf.sprintf "(%s; %s)" (emit_assignment env locals target expr) (emit_block_unit env locals rest)
      | Expr.While (cond, body) ->
          Printf.sprintf "((while %s do %s done); %s)" (emit_expr env locals cond) (emit_block_unit env locals body)
            (emit_block_unit env locals rest)
      | Expr.For (name, start_expr, stop_expr, body) ->
          (match stop_expr with
           | Expr.Unit ->
               (* Iterator-style for loop: for x in items do body end *)
               let iterable_expr = emit_expr env locals start_expr in
               let iterable_ty = infer_expr_type env locals start_expr in
               let iterable_text = match iterable_ty with
                 | TNamed n when has_prefix n "Vec[" || has_prefix n "List[" || n = "__external" ->
                     Printf.sprintf "(Obj.magic %s)" iterable_expr
                 | _ -> iterable_expr
               in
               Printf.sprintf "((List.iter (fun %s -> %s) %s); %s)" (sanitize_identifier name)
                 (emit_block_unit env ((name, { ty = TNamed "__external"; is_mutable = false }) :: locals) body)
                 iterable_text
                 (emit_block_unit env locals rest)
           | _ ->
               let start_ty = infer_expr_type env locals start_expr in
               let stop_ty = infer_expr_type env locals stop_expr in
               let start_text = 
                 let emitted = emit_expr env locals start_expr in
                 match start_ty with
                 | TInt -> Printf.sprintf "(Int64.to_int (%s))" emitted
                 | TNamed n when n = "__external" -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
                 | _ -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
               in
               let stop_text = 
                 let emitted = emit_expr env locals stop_expr in
                 match stop_ty with
                 | TInt -> Printf.sprintf "(Int64.to_int (%s))" emitted
                 | TNamed n when n = "__external" -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
                 | _ -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
               in
               Printf.sprintf "((for %s = %s to %s do %s done); %s)" (sanitize_identifier name)
                 start_text stop_text
                 (emit_block_unit env ((name, { ty = TInt; is_mutable = false }) :: locals) body)
                 (emit_block_unit env locals rest))
      | Expr.Expr expr ->
          Printf.sprintf "(let _ = %s in %s)" (emit_expr env locals expr) (emit_block_unit env locals rest)
      end

and emit_block_expr env locals block =
  match block with
  | [] -> "()"
  | [Expr.Return None] -> emit_return_raise env locals None
  | [Expr.Return (Some expr)] -> emit_return_raise env locals (Some expr)
  | [Expr.Expr expr] -> emit_expr env locals expr
  | [Expr.Assign (target, expr)] -> Printf.sprintf "(%s; ())" (emit_assignment env locals target expr)
  | [Expr.While (cond, body)] -> Printf.sprintf "((while %s do %s done); ())" (emit_expr env locals cond) (emit_block_unit env locals body)
  | [Expr.For (name, start_expr, stop_expr, body)] ->
      let start_ty = infer_expr_type env locals start_expr in
      let stop_ty = infer_expr_type env locals stop_expr in
      let start_text = 
        let emitted = emit_expr env locals start_expr in
        match start_ty with
        | TInt -> Printf.sprintf "(Int64.to_int (%s))" emitted
        | TNamed n when n = "__external" -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
        | _ -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
      in
      let stop_text = 
        let emitted = emit_expr env locals stop_expr in
        match stop_ty with
        | TInt -> Printf.sprintf "(Int64.to_int (%s))" emitted
        | TNamed n when n = "__external" -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
        | _ -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
      in
      Printf.sprintf "((for %s = %s to %s do %s done); ())" (sanitize_identifier name)
        start_text stop_text
        (emit_block_unit env ((name, { ty = TInt; is_mutable = false }) :: locals) body)
  | Expr.Let (name, is_mutable, expr) :: rest ->
      let expr_text = emit_expr env locals expr in
      let ty = infer_expr_type env locals expr in
      let info = { ty; is_mutable } in
      if is_mutable then
        Printf.sprintf "(let %s = ref (%s) in %s)" (sanitize_identifier name) expr_text
          (emit_block_expr env ((name, info) :: locals) rest)
      else
        Printf.sprintf "(let %s = %s in %s)" (sanitize_identifier name) expr_text
          (emit_block_expr env ((name, info) :: locals) rest)
  | Expr.LetTuple (names, is_mutable, expr) :: rest ->
      let pattern = String.concat ", " (List.map sanitize_identifier names) in
      let next_locals =
        List.fold_right
          (fun name acc -> (name, { ty = TNamed "__external"; is_mutable }) :: acc)
          names locals
      in
      if is_mutable then
        let refs =
          names
          |> List.map (fun name -> Printf.sprintf "let %s = ref %s in " (sanitize_identifier name) (sanitize_identifier name))
          |> String.concat ""
        in
        let refs_close = String.make (List.length names) ')' in
        Printf.sprintf "(let (%s) = (Obj.magic (%s)) in %s%s%s)" pattern (emit_expr env locals expr) refs
          (emit_block_expr env next_locals rest) refs_close
      else
        Printf.sprintf "(let (%s) = (Obj.magic (%s)) in %s)" pattern (emit_expr env locals expr)
          (emit_block_expr env next_locals rest)
  | Expr.Assign (target, expr) :: rest ->
      Printf.sprintf "((%s); %s)" (emit_assignment env locals target expr) (emit_block_expr env locals rest)
  | Expr.While (cond, body) :: rest ->
      Printf.sprintf "((while %s do %s done); %s)" (emit_expr env locals cond) (emit_block_unit env locals body)
        (emit_block_expr env locals rest)
  | Expr.For (name, start_expr, stop_expr, body) :: rest ->
      (match stop_expr with
       | Expr.Unit ->
           (* Iterator-style for loop *)
           let iterable_expr = emit_expr env locals start_expr in
           let iterable_ty = infer_expr_type env locals start_expr in
           let iterable_text = match iterable_ty with
             | TNamed n when has_prefix n "Vec[" || has_prefix n "List[" || n = "__external" ->
                 Printf.sprintf "(Obj.magic %s)" iterable_expr
             | _ -> iterable_expr
           in
           Printf.sprintf "((List.iter (fun %s -> %s) %s); %s)" (sanitize_identifier name)
             (emit_block_unit env ((name, { ty = TNamed "__external"; is_mutable = false }) :: locals) body)
             iterable_text
             (emit_block_expr env locals rest)
       | _ ->
           let start_ty = infer_expr_type env locals start_expr in
           let stop_ty = infer_expr_type env locals stop_expr in
           let start_text = 
             let emitted = emit_expr env locals start_expr in
             match start_ty with
             | TInt -> Printf.sprintf "(Int64.to_int (%s))" emitted
             | TNamed n when n = "__external" -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
             | _ -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
           in
           let stop_text = 
             let emitted = emit_expr env locals stop_expr in
             match stop_ty with
             | TInt -> Printf.sprintf "(Int64.to_int (%s))" emitted
             | TNamed n when n = "__external" -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
             | _ -> Printf.sprintf "(Int64.to_int (Obj.magic %s : int64))" emitted
           in
           Printf.sprintf "((for %s = %s to %s do %s done); %s)" (sanitize_identifier name)
             start_text stop_text
             (emit_block_unit env ((name, { ty = TInt; is_mutable = false }) :: locals) body)
             (emit_block_expr env locals rest))
  | Expr.Return None :: _ -> emit_return_raise env locals None
  | Expr.Return (Some expr) :: _ -> emit_return_raise env locals (Some expr)
  | Expr.Expr expr :: rest -> Printf.sprintf "(let _ = %s in %s)" (emit_expr env locals expr) (emit_block_expr env locals rest)

let emit_enum_body env (decl : enum_decl) =
  let constructors =
    decl.variants
    |> List.map (fun (variant : enum_variant) ->
      let ctor = ocaml_constructor_name decl.name variant.name in
      match variant.payload with
      | [] -> "| " ^ ctor
      | payload ->
          let payload_text = payload |> List.map (ocaml_type_of env) |> String.concat " * " in
          Printf.sprintf "| %s of %s" ctor payload_text)
    |> String.concat "\n  "
  in
  Printf.sprintf "%s =\n  %s" (type_name decl.name) constructors

let emit_struct_body env (decl : struct_decl) =
  let fields =
    decl.fields
    |> List.map (fun (field : struct_field) ->
      Printf.sprintf "mutable %s : %s;" (record_field_label decl.name field.name) (ocaml_type_of env field.ty))
    |> String.concat "\n  "
  in
  Printf.sprintf "%s = {\n  %s\n}" (type_name decl.name) fields

let emit_enum env (decl : enum_decl) =
  "type " ^ emit_enum_body env decl ^ "\n"

let emit_struct env (decl : struct_decl) =
  "type " ^ emit_struct_body env decl ^ "\n"

let rec has_return_in_stmt = function
  | Expr.Return _ -> true
  | Expr.Let (_, _, e) -> has_return_in_expr e
  | Expr.LetTuple (_, _, e) -> has_return_in_expr e
  | Expr.Expr e -> has_return_in_expr e
  | Expr.Assign (_, e) -> has_return_in_expr e
  | Expr.While (_, body) -> List.exists (fun s -> has_return_in_stmt s) body
  | Expr.For (_, _, _, body) -> List.exists (fun s -> has_return_in_stmt s) body

and has_return_in_expr = function
  | Expr.If (_, then_block, else_opt) ->
      List.exists (fun s -> has_return_in_stmt s) then_block ||
      (match else_opt with Some else_block -> List.exists (fun s -> has_return_in_stmt s) else_block | None -> false)
  | Expr.Match (_, arms) ->
      List.exists (fun arm -> List.exists (fun s -> has_return_in_stmt s) arm.Expr.body) arms
  | Expr.Lambda (_, body) -> has_return_in_expr body
  | _ -> false

let function_needs_exception body =
  List.exists (fun s -> has_return_in_stmt s) body

let function_is_recursive (decl : function_decl) =
  let target_name = decl.name in
  let rec check_expr = function
    | Expr.Call (Expr.Var name, _) -> name = target_name
    | Expr.Binary (_, lhs, rhs) -> check_expr lhs || check_expr rhs
    | Expr.Unary (_, e) -> check_expr e
    | Expr.If (_, then_block, else_opt) ->
        List.exists (check_stmt) then_block ||
        (match else_opt with Some else_block -> List.exists (check_stmt) else_block | None -> false)
    | Expr.Match (_, arms) ->
        List.exists (fun arm -> List.exists (check_stmt) arm.Expr.body) arms
    | Expr.MethodCall (receiver, _, args) ->
        check_expr receiver || List.exists check_expr args
    | Expr.FieldAccess (receiver, _) -> check_expr receiver
    | Expr.Cast (e, _) -> check_expr e
    | Expr.Try e -> check_expr e
    | Expr.Lambda (_, body) -> check_expr body
    | _ -> false
  and check_stmt = function
    | Expr.Let (_, _, e) -> check_expr e
    | Expr.LetTuple (_, _, e) -> check_expr e
    | Expr.Assign (_, e) -> check_expr e
    | Expr.While (cond, body) -> check_expr cond || List.exists (check_stmt) body
    | Expr.For (_, start, stop, body) -> check_expr start || check_expr stop || List.exists (check_stmt) body
    | Expr.Return None -> false
    | Expr.Return (Some e) -> check_expr e
    | Expr.Expr e -> check_expr e
  in
  List.exists (check_stmt) decl.body

(* Emit function - returns (exception_decl option, function_def) *)
let emit_function_parts env (decl : function_decl) =
  let ret_type = Option.value decl.ret_type ~default:TUnit |> resolve_self_type decl |> normalize_type in
  let params_with_types =
    List.mapi
      (fun index (param : param) ->
        Printf.sprintf "(%s : %s)" (sanitize_identifier param.name) (ocaml_type_of env (parameter_type decl index param)))
      decl.params
  in
  let locals =
    List.mapi
      (fun index (param : param) ->
        (param.name, { ty = parameter_type decl index param; is_mutable = false }))
      decl.params
  in
  let head =
    match params_with_types with
    | [] -> Printf.sprintf "let %s () =" (function_name ?method_of:decl.method_of decl.name)
    | _ ->
        Printf.sprintf "let %s %s =" (function_name ?method_of:decl.method_of decl.name)
          (String.concat " " params_with_types)
  in
  let exception_name = String.capitalize_ascii (sanitize_identifier ((function_name ?method_of:decl.method_of decl.name) ^ "__return")) in
  let previous_exception = !current_return_exception in
  let previous_return_type = !current_return_type in
  current_return_exception := Some exception_name;
  current_return_type := Some ret_type;
  let body = emit_block_expr env locals decl.body in
  current_return_exception := previous_exception;
  current_return_type := previous_return_type;
  if function_needs_exception decl.body then
    let ret_type_text = ocaml_type_of env ret_type in
    let exception_decl = 
      if ret_type_text = "unit" then
        Printf.sprintf "exception %s" exception_name
      else
        Printf.sprintf "exception %s of %s" exception_name ret_type_text
    in
    let func_body =
      if ret_type_text = "unit" then
        Printf.sprintf "%s\n  try %s with\n  | %s -> ()\n" head body exception_name
      else
        Printf.sprintf "%s\n  try %s with\n  | %s value -> value\n" head body exception_name
    in
    (Some exception_decl, func_body)
  else
    (None, Printf.sprintf "%s\n  %s\n" head body)

let collect_external_functions program =
  (* Build environment but only track non-method functions for external detection *)
  let env =
    { enums = Hashtbl.create 32
    ; structs = Hashtbl.create 16
    ; methods = Hashtbl.create 16
    ; functions = Hashtbl.create 16
    ; constants = Hashtbl.create 16
    ; globals = Hashtbl.create 16
    }
  in
  List.iter
    (function
      | Enum decl -> Hashtbl.replace env.enums decl.name decl
      | Struct decl -> Hashtbl.replace env.structs decl.name decl
      | Trait _ -> ()
      | Const decl -> Hashtbl.replace env.constants decl.name decl
      | Global decl -> Hashtbl.replace env.globals decl.name decl
      | Function decl ->
          begin match decl.method_of with
          | Some struct_name -> 
              Hashtbl.replace env.methods (struct_name ^ "." ^ decl.name) decl;
              Hashtbl.replace env.methods decl.name decl
              (* Don't add methods to functions - they need stubs with unqualified names *)
          | None -> Hashtbl.replace env.functions decl.name decl
          end
      | Ignored -> ())
    program;
  let externals = Hashtbl.create 16 in
  let rec check_expr = function
    | Expr.Call (Expr.Var name, _) ->
        (* External only if it's not a non-method function *)
        (* Methods need stubs because calls use unqualified names but definitions use qualified *)
        let is_non_method_function = Hashtbl.mem env.functions name in
        prerr_endline ("DEBUG: Call(Var " ^ name ^ ") is_non_method=" ^ string_of_bool is_non_method_function);
        if not is_non_method_function then
          Hashtbl.replace externals name ()
    | Expr.Call (callee, args) ->
        (* Handle curried calls like f(x)(y) where callee is itself a call *)
        let rec get_innermost_var = function
          | Expr.Var name -> Some name
          | Expr.Call (inner, _) -> get_innermost_var inner
          | _ -> None
        in
        (match get_innermost_var callee with
         | Some name ->
             let is_non_method_function = Hashtbl.mem env.functions name in
             prerr_endline ("DEBUG: Curried Call innermost=" ^ name ^ " is_non_method=" ^ string_of_bool is_non_method_function);
             if not is_non_method_function then
               Hashtbl.replace externals name ()
         | None -> ());
        check_expr callee;
        List.iter check_expr args
    | Expr.MethodCall (_, _, args) ->
        List.iter check_expr args
    | Expr.Binary (_, lhs, rhs) ->
        check_expr lhs; check_expr rhs
    | Expr.Unary (_, e) -> check_expr e
    | Expr.If (cond, then_block, else_opt) ->
        check_expr cond;
        List.iter check_stmt then_block;
        Option.iter (List.iter check_stmt) else_opt
    | Expr.Match (_, arms) ->
        List.iter (fun arm -> List.iter check_stmt arm.Expr.body) arms
    | Expr.Lambda (_, body) -> check_expr body
    | Expr.StructLit (_, fields) ->
        (* Check struct literal field values for external calls *)
        List.iter (fun (_, value) -> check_expr value) fields
    | Expr.Variant (_, _, args) ->
        (* Check variant payload expressions *)
        List.iter check_expr args
    | Expr.FieldAccess (receiver, _) -> check_expr receiver
    | Expr.Cast (e, _) -> check_expr e
    | Expr.Try e -> check_expr e
    | _ -> ()
  and check_stmt = function
    | Expr.Let (_, _, e) -> check_expr e
    | Expr.LetTuple (_, _, e) -> check_expr e
    | Expr.Assign (_, e) -> check_expr e
    | Expr.While (cond, body) -> 
        check_expr cond; List.iter check_stmt body
    | Expr.For (_, start, stop, body) ->
        check_expr start; check_expr stop; List.iter check_stmt body
    | Expr.Return None -> ()
    | Expr.Return (Some e) -> check_expr e
    | Expr.Expr e -> check_expr e
  in
  List.iter (function
    | Function decl -> 
        prerr_endline ("DEBUG: checking function: " ^ decl.name);
        List.iter check_stmt decl.body
    | _ -> ()) program;
  let keys = ref [] in
  Hashtbl.iter (fun k _ -> keys := k :: !keys) externals;
  !keys

let emit_external_stub _env name =
  (* Always use the unqualified lowercased name for external stubs *)
  (* This matches how the call site emits external function calls *)
  let safe_name = sanitize_identifier name in
  let safe_name = String.uncapitalize_ascii safe_name in
  (* Determine the return type for known functions *)
  let return_value = match external_call_result name with
    | TBool -> "false"
    | TInt -> "Int64.zero"
    | TString -> "\"\""
    | TFloat -> "0.0"
    | TUnit -> "()"
    | _ -> "Obj.obj (Obj.repr ())"
  in
  Printf.sprintf "let %s = fun _ -> %s\n" safe_name return_value

let emit_const env (decl : const_decl) =
  Printf.sprintf "let %s = %s\n" (value_name decl.name) (emit_expr env [] decl.value)

let emit_global env (decl : global_decl) =
  if decl.is_mutable then
    Printf.sprintf "let %s = ref (%s)\n" (value_name decl.name) (emit_expr env [] decl.value)
  else
    Printf.sprintf "let %s = %s\n" (value_name decl.name) (emit_expr env [] decl.value)

let emit_program program =
  let env = build_env program in
  (* Collect external function references *)
  let external_funcs = collect_external_functions program in
  (* Debug: print external functions *)
  List.iter (fun name -> prerr_endline ("DEBUG: external func: " ^ name)) external_funcs;
  let external_stubs = List.map (emit_external_stub env) external_funcs in
  let const_decls = List.filter_map (function Const decl -> Some (emit_const env decl) | _ -> None) program in
  let global_decls = List.filter_map (function Global decl -> Some (emit_global env decl) | _ -> None) program in
  (* Emit all types (enums and structs) in a mutually recursive block to handle forward references *)
  let type_decls = List.filter_map (function Enum decl -> Some (emit_enum_body env decl) | Struct decl -> Some (emit_struct_body env decl) | _ -> None) program in
  let types_block = 
    match type_decls with
    | [] -> ""
    | first :: rest ->
        let rest_text = List.map (fun s -> "and " ^ s) rest |> String.concat "\n\n" in
        "type " ^ first ^ (if rest_text = "" then "" else "\n\n" ^ rest_text) ^ "\n"
  in
  (* Get function parts (exceptions and bodies) *)
  let function_parts = List.filter_map (function Function decl -> Some (emit_function_parts env decl) | _ -> None) program in
  (* Separate exceptions and function bodies *)
  let exceptions = List.filter_map (fun (exc_opt, _) -> exc_opt) function_parts in
  let func_bodies = List.map snd function_parts in
  (* Make all functions mutually recursive using let rec ... and ... *)
  let functions_block =
    match func_bodies with
    | [] -> ""
    | first :: rest ->
        (* Transform first function: "let" -> "let rec" *)
        let first_rec = if String.length first >= 4 && String.sub first 0 4 = "let " then
          "let rec " ^ String.sub first 4 (String.length first - 4)
        else if String.length first >= 8 && String.sub first 0 8 = "let rec " then
          first  (* Already has let rec *)
        else first in
        (* Transform rest: "let" -> "and" (but "let rec" -> "and") *)
        let transform_rest s =
          let s = String.trim s in
          if String.length s >= 8 && String.sub s 0 8 = "let rec " then
            "and " ^ String.sub s 8 (String.length s - 8)
          else if String.length s >= 4 && String.sub s 0 4 = "let " then
            "and " ^ String.sub s 4 (String.length s - 4)
          else s
        in
        let rest_text = List.map transform_rest rest |> String.concat "\n\n" in
        first_rec ^ (if rest_text = "" then "" else "\n\n" ^ rest_text) ^ "\n"
  in
  (* Emit exceptions before functions *)
  let exceptions_block = 
    match exceptions with
    | [] -> ""
    | _ -> String.concat "\n" exceptions ^ "\n"
  in
  (* Emit external stubs FIRST, then types, then exceptions, then functions *)
  let sections = external_stubs @ [types_block] @ const_decls @ global_decls @ [exceptions_block] @ [functions_block] in
  let main_entry =
    match Hashtbl.find_opt env.functions "main" with
    | Some decl ->
        begin match Option.value decl.ret_type ~default:TUnit with
        | TInt -> "let () = exit (Int64.to_int (main ()))"
        | _ -> "let () = ignore (main ())"
        end
    | None -> "let () = ()"
  in
  String.concat "\n" (["(* Generated by tgc0 OCaml backend. *)"] @ sections @ [main_entry])
