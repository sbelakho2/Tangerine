(* Tangerine → C Transpiler – stage0
   Translates a multi-file Tangerine AST to C code that links with tg_runtime.
   All values are int64_t. Structs/enums are heap-allocated.
   This enables the self-hosting bootstrap. *)

open Ast

(* ── Code generation context ───────────────────────────────────────── *)

type var_info = {
  v_type : string;   (* type name for method resolution *)
  v_is_mut : bool;
}

type cctx = {
  mutable buf : Buffer.t;
  decl_buf : Buffer.t;           (* forward declarations *)
  mutable indent : int;
  mutable temp_cnt : int;
  mutable closure_cnt : int;
  mutable closures : (string * string) list;  (* closure func name, closure code *)
  mutable var_types : (string * var_info) list; (* variable name → type info *)
  mutable self_type : string;    (* current impl target type *)
  mutable current_module : string;  (* current file's module name *)
  type_map : (string, string) Hashtbl.t;  (* raw type name → C type name *)
  res : Resolve.resolved;
}

(* ── Emission helpers ──────────────────────────────────────────────── *)

let emit ctx s = Buffer.add_string ctx.buf s
let emitn ctx s = Buffer.add_string ctx.buf s; Buffer.add_char ctx.buf '\n'
let emit_indent ctx =
  for _ = 1 to ctx.indent do Buffer.add_string ctx.buf "    " done

let emitf ctx fmt = Printf.ksprintf (emit ctx) fmt
let emitfn ctx fmt = Printf.ksprintf (fun s -> emit ctx s; emit ctx "\n") fmt

let nl ctx = emit ctx "\n"
let indent ctx = ctx.indent <- ctx.indent + 1
let dedent ctx = ctx.indent <- ctx.indent - 1; if ctx.indent < 0 then ctx.indent <- 0

let fresh_temp ctx =
  ctx.temp_cnt <- ctx.temp_cnt + 1;
  Printf.sprintf "_t%d" ctx.temp_cnt

let fresh_closure_name ctx =
  ctx.closure_cnt <- ctx.closure_cnt + 1;
  Printf.sprintf "_closure_%d" ctx.closure_cnt

(* ── Type tracking ─────────────────────────────────────────────────── *)

let set_var_type ctx name typ_name =
  ctx.var_types <- (name, { v_type = typ_name; v_is_mut = false }) :: ctx.var_types

let get_var_type ctx name =
  try Some (List.assoc name ctx.var_types).v_type
  with Not_found -> None

let push_scope _ctx = () (* simplified: no scope stack for bootstrap *)

(* ── Type name resolution ──────────────────────────────────────────── *)

(* Register a type (struct/enum) with its C name *)
let register_type ctx raw_name c_name =
  Hashtbl.replace ctx.type_map raw_name c_name;
  (* Also register the C name itself so module-qualified lookups work *)
  if raw_name <> c_name then
    Hashtbl.replace ctx.type_map c_name c_name

(* Resolve a Tangerine type name to its C name *)
let resolve_type ctx name =
  match Hashtbl.find_opt ctx.type_map name with
  | Some c_name -> c_name
  | None -> Resolve.sanitize_ident name

(* Resolve enum C type name from variant_info, using module to avoid collisions *)
let resolve_enum_type ctx (vi : Resolve.variant_info) =
  if vi.vi_module <> "" then
    let qualified = Resolve.sanitize_ident (vi.vi_module ^ "__" ^ vi.vi_enum) in
    match Hashtbl.find_opt ctx.type_map qualified with
    | Some c_name -> c_name
    | None -> qualified
  else resolve_type ctx vi.vi_enum

let pop_scope _ctx = ()

(* Infer type name from an expression *)
let rec expr_type_name ctx = function
  | EIdent (name, _) ->
    (match get_var_type ctx name with
     | Some t -> t
     | None ->
       if Resolve.is_struct ctx.res name then name
       else if Resolve.is_enum ctx.res name then name
       else "")
  | EStr _ -> "String"
  | EInt _ -> "Int"
  | EFloat _ -> "Float"
  | EBool _ -> "Bool"
  | EChar _ -> "Char"
  | EStructLit (name, _, _) -> name
  | ECall (EIdent (name, _), _, _) ->
    if Resolve.is_variant ctx.res name then begin
      match Resolve.find_variant ctx.res name with
      | Some vi -> vi.vi_enum
      | None -> ""
    end else begin
      (* Check return type of function *)
      match Resolve.find_symbol ctx.res name with
      | Some { sym_kind = Resolve.SkFunction (_, Some ret); _ } ->
        Resolve.type_name_string_of_typ ret
      | _ -> ""
    end
  | EMethodCall (obj, meth, _, _) ->
    let obj_type = expr_type_name ctx obj in
    (match Resolve.find_method ctx.res obj_type meth with
     | Some { sym_kind = Resolve.SkMethod (_, _, Some ret); _ } ->
       Resolve.type_name_string_of_typ ret
     | _ -> "")
  | EFieldAccess (obj, field, _) ->
    let obj_type = expr_type_name ctx obj in
    let fields = Resolve.struct_fields ctx.res obj_type in
    (try
       let f = List.find (fun fd -> fd.fd_name = field) fields in
       Resolve.type_name_string_of_typ f.fd_typ
     with Not_found -> "")
  | _ -> ""

(* Check if a type name is a string type *)
let is_string_type t =
  t = "String" || t = "string" || t = "str"

(* Check if type is a known container *)
let is_vec_type t = t = "Vec" || t = "Array"
let is_map_type t = t = "Map" || t = "HashMap"
let is_set_type t = t = "Set" || t = "HashSet"

(* ── C name escaping ──────────────────────────────────────────────── *)

let c_ident name = Resolve.sanitize_ident name

let c_method_name type_name method_name =
  Resolve.sanitize_ident (type_name ^ "__" ^ method_name)

(* Resolve a method name to its fully-qualified C identifier.
   First tries Type__method, then searches the qualified table
   for module__Type__method. *)
let resolve_method_name ctx type_name method_name =
  let bare = c_method_name type_name method_name in
  (* Check if bare name exists in qualified table *)
  if Hashtbl.mem ctx.res.Resolve.qualified bare then bare
  else begin
    (* Search qualified table for *__Type__method *)
    let suffix = "__" ^ Resolve.sanitize_ident type_name ^ "__" ^ Resolve.sanitize_ident method_name in
    let found = ref "" in
    Hashtbl.iter (fun k _v ->
      if !found = "" && String.length k > String.length suffix &&
         String.sub k (String.length k - String.length suffix) (String.length suffix) = suffix then
        found := k
    ) ctx.res.Resolve.qualified;
    if !found <> "" then !found
    else begin
      (* Try method_map: Type.method *)
      match Resolve.find_method ctx.res type_name method_name with
      | Some sym -> sym.Resolve.sym_mangled
      | None -> bare  (* fallback to bare name *)
    end
  end

(* Resolve a function name to its C identifier, considering module context *)
let resolve_fn_name ctx name =
  if name = "main" && ctx.current_module = "driver" then "tg_main"
  else begin
    (* Try current module first *)
    let mangled = Resolve.mangle_name ctx.current_module name in
    let key = Resolve.sanitize_ident mangled in
    if Hashtbl.mem ctx.res.Resolve.qualified key then key
    else begin
      (* Look up in symbols table — use its module's mangled name *)
      match Resolve.find_symbol ctx.res name with
      | Some sym -> sym.Resolve.sym_mangled
      | None -> c_ident name
    end
  end

(* ── Escape string for C literal ───────────────────────────────────── *)

(* Split a qualified variant name like "ItemKind::Function" into ("ItemKind", "Function").
   Unqualified names like "Function" return ("", "Function"). *)
let split_qualified_variant vname =
  match String.split_on_char ':' vname with
  | [enum_part; ""; variant_part] -> (enum_part, variant_part)
  | _ -> ("", vname)

let c_string_escape s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter (fun c ->
    match c with
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | '\\' -> Buffer.add_string buf "\\\\"
    | '"' -> Buffer.add_string buf "\\\""
    | '\x00'..'\x1f' ->
      Buffer.add_string buf (Printf.sprintf "\\x%02x" (Char.code c))
    | _ -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

(* ── Emit struct type definition ───────────────────────────────────── *)

let emit_struct_def ctx name fields =
  let c_name = if ctx.current_module <> "" then
    c_ident (ctx.current_module ^ "__" ^ name)
  else c_ident name in
  register_type ctx name c_name;
  emitfn ctx "/* struct %s */" name;
  emitfn ctx "typedef struct %s {" c_name;
  indent ctx;
  List.iter (fun fd ->
    emit_indent ctx;
    emitfn ctx "TgVal %s;" (c_ident fd.fd_name)
  ) fields;
  dedent ctx;
  emitfn ctx "} %s;" c_name;
  nl ctx;
  (* Allocator function *)
  emitfn ctx "static TgVal %s__alloc(void) {" c_name;
  indent ctx;
  emit_indent ctx;
  emitfn ctx "%s* _p = (%s*)tg_alloc(sizeof(%s));" c_name c_name c_name;
  emit_indent ctx;
  emitfn ctx "return tg_from_ptr(_p);";
  dedent ctx;
  emitfn ctx "}";
  nl ctx

(* ── Emit enum type definition ─────────────────────────────────────── *)

let emit_enum_def ctx name variants =
  let c_name = if ctx.current_module <> "" then
    c_ident (ctx.current_module ^ "__" ^ name)
  else c_ident name in
  register_type ctx name c_name;
  emitfn ctx "/* enum %s */" name;
  (* Tag constants *)
  List.iteri (fun tag vd ->
    emitfn ctx "#define TAG_%s_%s ((TgVal)%d)" c_name (c_ident vd.vd_name) tag
  ) variants;
  nl ctx;
  (* Enum struct: tag + max payload fields, padded to at least 4 for cast safety *)
  let max_fields = List.fold_left (fun mx vd ->
    max mx (List.length vd.vd_fields)
  ) 0 variants in
  let padded_fields = max max_fields 4 in
  emitfn ctx "typedef struct %s {" c_name;
  indent ctx;
  emit_indent ctx; emitfn ctx "TgVal _tag;";
  for i = 0 to padded_fields - 1 do
    emit_indent ctx; emitfn ctx "TgVal _f%d;" i
  done;
  dedent ctx;
  emitfn ctx "} %s;" c_name;
  nl ctx;
  (* Constructor functions for each variant *)
  List.iteri (fun tag vd ->
    let params = List.mapi (fun i _ ->
      Printf.sprintf "TgVal _%d" i
    ) vd.vd_fields in
    let param_str = if params = [] then "void"
      else String.concat ", " params in
    (* Forward declaration for variant constructor *)
    Buffer.add_string ctx.decl_buf
      (Printf.sprintf "static TgVal %s_%s__new(%s);\n"
         c_name (c_ident vd.vd_name) param_str);
    emitfn ctx "static TgVal %s_%s__new(%s) {"
      c_name (c_ident vd.vd_name) param_str;
    indent ctx;
    emit_indent ctx;
    emitfn ctx "%s* _p = (%s*)tg_alloc(sizeof(%s));"
      c_name c_name c_name;
    emit_indent ctx;
    emitfn ctx "_p->_tag = %d;" tag;
    List.iteri (fun i _ ->
      emit_indent ctx;
      emitfn ctx "_p->_f%d = _%d;" i i
    ) vd.vd_fields;
    emit_indent ctx;
    emitfn ctx "return tg_from_ptr(_p);";
    dedent ctx;
    emitfn ctx "}";
    nl ctx
  ) variants

(* ── Emit expression ───────────────────────────────────────────────── *)

let rec emit_expr ctx expr =
  match expr with
  | EInt (v, _) ->
    emitf ctx "((TgVal)%dLL)" v

  | EFloat (f, _) ->
    emitf ctx "tg_from_double(%g)" f

  | EStr (s, _) ->
    emitf ctx "tg_str_from_cstr(\"%s\")" (c_string_escape s)

  | EChar (s, _) ->
    if String.length s > 0 then
      emitf ctx "((TgVal)%d)" (Char.code s.[0])
    else
      emit ctx "((TgVal)0)"

  | EBool (true, _) -> emit ctx "TG_TRUE"
  | EBool (false, _) -> emit ctx "TG_FALSE"
  | ENil _ -> emit ctx "TG_NIL"

  | EIdent ("self", _) ->
    emit ctx "_self"

  | EIdent (name, _) ->
    (* Local variables ALWAYS take priority over global symbols *)
    if get_var_type ctx name <> None then
      emit ctx (c_ident name)
    (* Check for known constants/enum variants *)
    else if Resolve.is_variant ctx.res name then begin
      match Resolve.find_variant ctx.res name with
      | Some vi when vi.vi_fields = [] ->
        (* Unit variant: call constructor with no args *)
        emitf ctx "%s_%s__new()" (resolve_enum_type ctx vi) (c_ident name)
      | _ -> emit ctx (c_ident name)
    end else begin
      (* Check if it's a known function or constant — use module-scoped name *)
      match Resolve.find_symbol ctx.res name with
      | Some { sym_kind = Resolve.SkFunction _; _ } ->
        emit ctx (resolve_fn_name ctx name)
      | Some { sym_kind = Resolve.SkConst; sym_module; _ } ->
        if sym_module <> "" then
          emit ctx (c_ident (sym_module ^ "__" ^ name))
        else
          emit ctx (c_ident name)
      | _ -> emit ctx (c_ident name)
    end

  | EBinOp (Add, left, right, _) ->
    let lt = expr_type_name ctx left in
    let rt = expr_type_name ctx right in
    if is_string_type lt || is_string_type rt then begin
      (* String concatenation *)
      emit ctx "tg_str_concat(";
      if not (is_string_type lt) then begin
        emit ctx "_generic_to_string("; emit_expr ctx left; emit ctx ")"
      end else
        emit_expr ctx left;
      emit ctx ", ";
      if not (is_string_type rt) then begin
        emit ctx "_generic_to_string("; emit_expr ctx right; emit ctx ")"
      end else
        emit_expr ctx right;
      emit ctx ")"
    end else begin
      emit ctx "("; emit_expr ctx left; emit ctx " + "; emit_expr ctx right; emit ctx ")"
    end

  | EBinOp (Sub, left, right, _) ->
    emit ctx "("; emit_expr ctx left; emit ctx " - "; emit_expr ctx right; emit ctx ")"

  | EBinOp (Mul, left, right, _) ->
    emit ctx "("; emit_expr ctx left; emit ctx " * "; emit_expr ctx right; emit ctx ")"

  | EBinOp (Div, left, right, _) ->
    emit ctx "("; emit_expr ctx left; emit ctx " / "; emit_expr ctx right; emit ctx ")"

  | EBinOp (Mod, left, right, _) ->
    emit ctx "("; emit_expr ctx left; emit ctx " % "; emit_expr ctx right; emit ctx ")"

  | EBinOp (Eq, left, right, _) ->
    let lt = expr_type_name ctx left in
    if is_string_type lt then begin
      emit ctx "tg_str_eq("; emit_expr ctx left; emit ctx ", "; emit_expr ctx right; emit ctx ")"
    end else begin
      emit ctx "("; emit_expr ctx left; emit ctx " == "; emit_expr ctx right; emit ctx ")"
    end

  | EBinOp (Neq, left, right, _) ->
    let lt = expr_type_name ctx left in
    if is_string_type lt then begin
      emit ctx "tg_str_neq("; emit_expr ctx left; emit ctx ", "; emit_expr ctx right; emit ctx ")"
    end else begin
      emit ctx "("; emit_expr ctx left; emit ctx " != "; emit_expr ctx right; emit ctx ")"
    end

  | EBinOp (Lt, l, r, _) ->
    emit ctx "("; emit_expr ctx l; emit ctx " < "; emit_expr ctx r; emit ctx ")"
  | EBinOp (Gt, l, r, _) ->
    emit ctx "("; emit_expr ctx l; emit ctx " > "; emit_expr ctx r; emit ctx ")"
  | EBinOp (Le, l, r, _) ->
    emit ctx "("; emit_expr ctx l; emit ctx " <= "; emit_expr ctx r; emit ctx ")"
  | EBinOp (Ge, l, r, _) ->
    emit ctx "("; emit_expr ctx l; emit ctx " >= "; emit_expr ctx r; emit ctx ")"

  | EBinOp (And, l, r, _) ->
    emit ctx "("; emit_expr ctx l; emit ctx " && "; emit_expr ctx r; emit ctx ")"
  | EBinOp (Or, l, r, _) ->
    emit ctx "("; emit_expr ctx l; emit ctx " || "; emit_expr ctx r; emit ctx ")"

  | EBinOp (BitAnd, l, r, _) ->
    emit ctx "("; emit_expr ctx l; emit ctx " & "; emit_expr ctx r; emit ctx ")"
  | EBinOp (BitOr, l, r, _) ->
    emit ctx "("; emit_expr ctx l; emit ctx " | "; emit_expr ctx r; emit ctx ")"
  | EBinOp (BitXor, l, r, _) ->
    emit ctx "("; emit_expr ctx l; emit ctx " ^ "; emit_expr ctx r; emit ctx ")"
  | EBinOp (Shl, l, r, _) ->
    emit ctx "("; emit_expr ctx l; emit ctx " << "; emit_expr ctx r; emit ctx ")"
  | EBinOp (Shr, l, r, _) ->
    emit ctx "("; emit_expr ctx l; emit ctx " >> "; emit_expr ctx r; emit ctx ")"

  | EUnOp (Neg, inner, _) ->
    emit ctx "(-("; emit_expr ctx inner; emit ctx "))"

  | EUnOp (Not, inner, _) ->
    emit ctx "(!("; emit_expr ctx inner; emit ctx "))"

  | EUnOp (AddrOf, inner, _) ->
    (* & in Tangerine → pass as-is for bootstrap (all vals are 8 bytes) *)
    emit_expr ctx inner

  | EUnOp (AddrMut, inner, _) ->
    emit_expr ctx inner

  | EUnOp (Deref, inner, _) ->
    emit ctx "(*((TgVal*)tg_as_ptr("; emit_expr ctx inner; emit ctx ")))"

  | ECall (EIdent ("println", _), [arg], _) ->
    emit ctx "tg_println("; emit_expr ctx arg; emit ctx ")"

  | ECall (EIdent ("print", _), [arg], _) ->
    emit ctx "tg_print("; emit_expr ctx arg; emit ctx ")"

  | ECall (EIdent ("eprintln", _), [arg], _) ->
    emit ctx "tg_eprintln("; emit_expr ctx arg; emit ctx ")"

  | ECall (EIdent ("eprint", _), [arg], _) ->
    emit ctx "tg_eprint("; emit_expr ctx arg; emit ctx ")"

  | ECall (EIdent ("exit", _), [arg], _) ->
    emit ctx "tg_exit("; emit_expr ctx arg; emit ctx ")"

  | ECall (EIdent ("panic", _), [arg], _) ->
    emit ctx "(tg_panic(tg_str_cstr("; emit_expr ctx arg; emit ctx ")), TG_NIL)"

  | ECall (EIdent ("assert", _), [cond; msg], _) ->
    emit ctx "tg_assert("; emit_expr ctx cond; emit ctx ", tg_str_cstr(";
    emit_expr ctx msg; emit ctx "))"

  | ECall (EIdent ("assert", _), [cond], _) ->
    emit ctx "tg_assert("; emit_expr ctx cond; emit ctx ", \"assertion failed\")"

  (* Qualified calls: Vec::new(), Map::new(), etc. *)
  | ECall (EFieldAccess (EIdent (("Vec" | "Array"), _), "new", _), [], _) ->
    emit ctx "tg_vec_new()"
  | ECall (EFieldAccess (EIdent (("Vec" | "Array"), _), "with_capacity", _), [cap], _) ->
    emit ctx "tg_vec_with_capacity("; emit_expr ctx cap; emit ctx ")"
  | ECall (EFieldAccess (EIdent (("Vec" | "Array"), _), "from", _), [arr], _) ->
    emit ctx "tg_vec_clone("; emit_expr ctx arr; emit ctx ")"

  | ECall (EFieldAccess (EIdent (("Map" | "HashMap"), _), "new", _), [], _) ->
    emit ctx "tg_map_new_string_keys()"

  | ECall (EFieldAccess (EIdent (("Set" | "HashSet"), _), "new", _), [], _) ->
    emit ctx "tg_set_new_string_keys()"

  | ECall (EFieldAccess (EIdent ("String", _), "new", _), [], _) ->
    emit ctx "tg_str_new()"

  | ECall (EFieldAccess (EIdent ("Option", _), "Some", _), [val_], _)
  | ECall (EIdent ("Some", _), [val_], _) ->
    emit ctx "tg_option_some("; emit_expr ctx val_; emit ctx ")"

  | ECall (EFieldAccess (EIdent ("Option", _), "None", _), [], _)
  | ECall (EIdent ("None", _), [], _) ->
    emit ctx "tg_option_none()"

  | ECall (EFieldAccess (EIdent ("Result", _), "Ok", _), [val_], _)
  | ECall (EIdent ("Ok", _), [val_], _) ->
    emit ctx "tg_result_ok("; emit_expr ctx val_; emit ctx ")"

  | ECall (EFieldAccess (EIdent ("Result", _), "Err", _), [val_], _)
  | ECall (EIdent ("Err", _), [val_], _) ->
    emit ctx "tg_result_err("; emit_expr ctx val_; emit ctx ")"

  | ECall (EFieldAccess (EIdent ("Box", _), "new", _), [val_], _) ->
    emit ctx "tg_box_new("; emit_expr ctx val_; emit ctx ")"

  (* Bare new() call — default to vec since most common *)
  | ECall (EIdent ("new", _), [], _) ->
    emit ctx "tg_vec_new()"

  | ECall (EIdent (name, _), args, _) ->
    (* Check if it's an enum variant constructor — use arity-based lookup *)
    if Resolve.is_variant ctx.res name then begin
      match Resolve.find_variant_by_arity ctx.res name (List.length args) with
      | Some vi ->
        emitf ctx "%s_%s__new(" (resolve_enum_type ctx vi) (c_ident name);
        emit_args ctx args;
        emit ctx ")"
      | None ->
        emitf ctx "%s(" (resolve_fn_name ctx name);
        emit_args ctx args;
        emit ctx ")"
    end
    (* Check if it's a local variable (likely a closure) — use tg_closure_call *)
    else if (not (Resolve.is_function ctx.res name)) &&
            (match get_var_type ctx name with Some _ -> true | None -> false) then begin
      (match args with
       | [a] ->
         emitf ctx "tg_closure_call1(%s, " (c_ident name);
         emit_expr ctx a;
         emit ctx ")"
       | [] ->
         emitf ctx "tg_closure_call1(%s, TG_NIL)" (c_ident name)
       | _ ->
         (* Multi-arg: pack into tuple *)
         let n = List.length args in
         if n <= 3 then begin
           emitf ctx "tg_closure_call1(%s, tg_tuple_new%d(" (c_ident name) n;
           emit_args ctx args;
           emit ctx "))"
         end else begin
           emitf ctx "({ TgVal _ca = tg_vec_new(); ";
           List.iter (fun a ->
             emit ctx "tg_vec_push(_ca, ";
             emit_expr ctx a;
             emit ctx "); "
           ) args;
           emitf ctx "tg_closure_call1(%s, _ca); })" (c_ident name)
         end)
    end else begin
      (* Regular function call — use module-scoped name *)
      emitf ctx "%s(" (resolve_fn_name ctx name);
      emit_args ctx args;
      emit ctx ")"
    end

  | ECall (EFieldAccess (EIdent (type_name, _), method_name, _), args, _)
    when Resolve.is_enum ctx.res type_name ->
    (* Qualified enum variant constructor: EnumName::VariantName(args) *)
    (match Resolve.find_variant_in_enum ctx.res type_name method_name with
     | Some vi ->
       emitf ctx "%s_%s__new(" (resolve_enum_type ctx vi) (c_ident method_name);
       emit_args ctx args;
       emit ctx ")"
     | None ->
       (* Variant not found in the resolved enum — try variant table directly *)
       (match Resolve.find_variant_by_arity ctx.res method_name (List.length args) with
        | Some vi ->
          emitf ctx "%s_%s__new(" (resolve_enum_type ctx vi) (c_ident method_name);
          emit_args ctx args;
          emit ctx ")"
        | None ->
          (* Might be a static method on the enum type *)
          emitf ctx "%s(" (c_method_name type_name method_name);
          emit_args ctx args;
          emit ctx ")"))

  | ECall (EFieldAccess (EIdent (mod_name, _), func_name, _), args, _)
    when not (Resolve.is_struct ctx.res mod_name) && not (Resolve.is_enum ctx.res mod_name) ->
    (* Module-qualified call: Module::func(args) — resolve to module__func *)
    if func_name = "main" && String.lowercase_ascii mod_name = "driver" then begin
      emitf ctx "tg_main(";
      emit_args ctx args;
      emit ctx ")"
    end else begin
      let mangled = Resolve.mangle_name (Resolve.sanitize_ident (String.lowercase_ascii mod_name)) func_name in
      let key = Resolve.sanitize_ident mangled in
      if Hashtbl.mem ctx.res.Resolve.qualified key then begin
        emitf ctx "%s(" key;
        emit_args ctx args;
        emit ctx ")"
      end else begin
        (* Try as a plain function name *)
        emitf ctx "%s(" (resolve_fn_name ctx func_name);
        emit_args ctx args;
        emit ctx ")"
      end
    end

  | ECall (EFieldAccess (obj, method_name, _), args, _) ->
    (* Qualified method call like Type::method(args) or obj.method(args) *)
    let type_name = expr_type_name ctx obj in
    if Resolve.is_enum ctx.res type_name then begin
      (* Check if method_name is a variant of this enum *)
      match Resolve.find_variant_in_enum ctx.res type_name method_name with
      | Some vi ->
        emitf ctx "%s_%s__new(" (resolve_enum_type ctx vi) (c_ident method_name);
        emit_args ctx args;
        emit ctx ")"
      | None ->
        (* Variant not found in resolved enum — try variant table *)
        (match Resolve.find_variant_by_arity ctx.res method_name (List.length args) with
         | Some vi ->
           emitf ctx "%s_%s__new(" (resolve_enum_type ctx vi) (c_ident method_name);
           emit_args ctx args;
           emit ctx ")"
         | None ->
           emitf ctx "%s(" (c_method_name type_name method_name);
           emit_args ctx args;
           emit ctx ")")
    end else begin
      emitf ctx "%s(" (c_method_name type_name method_name);
      emit_args ctx args;
      emit ctx ")"
    end

  | ECall (callee, args, _) ->
    (* General call - emit as closure call for now *)
    emit ctx "tg_closure_call1(";
    emit_expr ctx callee;
    emit ctx ", ";
    (match args with
     | [a] -> emit_expr ctx a
     | _ -> emit ctx "TG_NIL");
    emit ctx ")"

  | EMethodCall (obj, method_name, args, _) ->
    emit_method_call ctx obj method_name args

  (* Builtin Option/Result bare references *)
  | EFieldAccess (EIdent ("Option", _), "None", _) ->
    emit ctx "tg_option_none()"
  | EFieldAccess (EIdent ("Option", _), "Some", _) ->
    emit ctx "tg_option_some"
  | EFieldAccess (EIdent ("Result", _), "Ok", _) ->
    emit ctx "tg_result_ok"
  | EFieldAccess (EIdent ("Result", _), "Err", _) ->
    emit ctx "tg_result_err"

  | EFieldAccess (EIdent (type_name, _), field, _) when Resolve.is_enum ctx.res type_name ->
    (* Qualified enum variant reference: EnumName::VariantName *)
    (match Resolve.find_variant_in_enum ctx.res type_name field with
     | Some vi when vi.vi_fields = [] ->
       (* Unit variant: emit constructor call *)
       emitf ctx "%s_%s__new()" (resolve_enum_type ctx vi) (c_ident field)
     | Some vi ->
       (* Variant with fields — emit as function reference *)
       emitf ctx "%s_%s__new" (resolve_enum_type ctx vi) (c_ident field)
     | None ->
       (* Not a known variant — might be a method *)
       emitf ctx "%s(" (c_method_name type_name field);
       emit ctx ")")

  | EFieldAccess (obj, field, _) ->
    let obj_type = expr_type_name ctx obj in
    if obj_type <> "" && Resolve.is_struct ctx.res obj_type then begin
      let fidx = Resolve.struct_field_index ctx.res obj_type field in
      if fidx >= 0 then begin
        emitf ctx "((%s*)tg_as_ptr(" (resolve_type ctx obj_type);
        emit_expr ctx obj;
        emitf ctx "))->%s" (c_ident field)
      end else begin
        (* Field not found in primary struct — search ALL module-qualified structs for the field *)
        let found = ref false in
        Hashtbl.iter (fun qname sym ->
          if not !found then
            match sym.Resolve.sym_kind with
            | Resolve.SkStruct fields when List.exists (fun f -> f.fd_name = field) fields ->
              let alt_c_name = qname in  (* qualified table keys are already sanitized C names *)
              emitf ctx "((%s*)tg_as_ptr(" alt_c_name;
              emit_expr ctx obj;
              emitf ctx "))->%s" (c_ident field);
              found := true
            | _ -> ()
        ) ctx.res.Resolve.qualified;
        if not !found then begin
          emitf ctx "((%s*)tg_as_ptr(" (resolve_type ctx obj_type);
          emit_expr ctx obj;
          emitf ctx "))->%s" (c_ident field)
        end
      end
    end else if obj_type <> "" && Resolve.is_enum ctx.res obj_type then begin
      (* Enum field access — check if field is a variant name *)
      (match Resolve.find_variant_in_enum ctx.res obj_type field with
       | Some vi when vi.vi_fields = [] ->
         emitf ctx "%s_%s__new()" (resolve_enum_type ctx vi) (c_ident field)
       | _ ->
         emitf ctx "((%s*)tg_as_ptr(" (resolve_type ctx obj_type);
         emit_expr ctx obj;
         emitf ctx "))->%s" (c_ident field))
    end else begin
      (* Unknown type — try generic access *)
      emit ctx "/* unknown field access */ tg_field_get(";
      emit_expr ctx obj;
      emitf ctx ", 0) /* .%s */" field
    end

  | EIndex (obj, idx, _) ->
    let obj_type = expr_type_name ctx obj in
    if obj_type = "Vec" || is_vec_type obj_type then begin
      emit ctx "tg_vec_get("; emit_expr ctx obj; emit ctx ", ";
      emit_expr ctx idx; emit ctx ")"
    end else if is_string_type obj_type then begin
      emit ctx "tg_str_char_at("; emit_expr ctx obj; emit ctx ", ";
      emit_expr ctx idx; emit ctx ")"
    end else begin
      emit ctx "tg_vec_get("; emit_expr ctx obj; emit ctx ", ";
      emit_expr ctx idx; emit ctx ")"
    end

  | EStructLit (name, fields, _) ->
    if Resolve.is_struct ctx.res name then begin
      (* Check if the resolved struct has all the fields we need *)
      let resolved = resolve_type ctx name in
      let struct_fields = Resolve.struct_fields ctx.res name in
      let all_found = List.for_all (fun (fname, _) ->
        List.exists (fun f -> f.fd_name = fname) struct_fields
      ) fields in
      let c_name = if all_found then resolved
        else begin
          (* Try to find a struct that has ALL the fields *)
          let alt = ref resolved in
          Hashtbl.iter (fun qname sym ->
            if !alt = resolved then
              match sym.Resolve.sym_kind with
              | Resolve.SkStruct sfields when sym.Resolve.sym_name = name
                && List.for_all (fun (fname, _) ->
                     List.exists (fun f -> f.fd_name = fname) sfields) fields ->
                alt := qname
              | _ -> ()
          ) ctx.res.Resolve.qualified;
          !alt
        end in
      emit ctx "({ ";
      emitf ctx "%s* _sl = (%s*)tg_alloc(sizeof(%s)); " c_name c_name c_name;
      List.iter (fun (fname, fexpr) ->
        emitf ctx "_sl->%s = " (c_ident fname);
        emit_expr ctx fexpr;
        emit ctx "; ";
      ) fields;
      emit ctx "tg_from_ptr(_sl); })"
    end else begin
      (* Unknown struct — use generic allocation *)
      emitf ctx "/* struct %s */ tg_struct_alloc(%d)" name (List.length fields)
    end

  | ETuple (elems, _) ->
    (match elems with
     | [a; b] ->
       emit ctx "tg_tuple_new2(";
       emit_expr ctx a; emit ctx ", "; emit_expr ctx b; emit ctx ")"
     | [a; b; c] ->
       emit ctx "tg_tuple_new3(";
       emit_expr ctx a; emit ctx ", "; emit_expr ctx b;
       emit ctx ", "; emit_expr ctx c; emit ctx ")"
     | _ ->
       emit ctx "tg_tuple_new2(TG_NIL, TG_NIL)")

  | EArray (elems, _) ->
    let tmp = fresh_temp ctx in
    emitf ctx "({ TgVal %s = tg_vec_new(); " tmp;
    List.iter (fun e ->
      emitf ctx "tg_vec_push(%s, " tmp;
      emit_expr ctx e;
      emit ctx "); "
    ) elems;
    emitf ctx "%s; })" tmp

  | EIf (branches, else_body, _) ->
    (* Check if any branch has multi-statement body or control flow needing if/else *)
    let needs_block body = match body with
      | [] -> false
      | [SExpr (EReturn _)] | [SExpr (EBreak _)] | [SExpr (ENext _)] -> true
      | [SExpr _] -> false
      | _ -> true
    in
    let needs_if_else = List.exists (fun b -> needs_block b.body) branches
      || (match else_body with Some s -> needs_block s | None -> false) in
    if needs_if_else then begin
      let tmp = fresh_temp ctx in
      emitf ctx "({ TgVal %s_if = TG_NIL; " tmp;
      List.iteri (fun i br ->
        if i = 0 then emit ctx "if (" else emit ctx " else if (";
        emit_expr ctx br.cond;
        emit ctx ") { ";
        emit_block_expr_to ctx br.body (tmp ^ "_if");
        emit ctx "}"
      ) branches;
      (match else_body with
       | Some stmts ->
         emit ctx " else { ";
         emit_block_expr_to ctx stmts (tmp ^ "_if");
         emit ctx "}"
       | None -> ());
      emitf ctx " %s_if; })" tmp
    end else begin
      emit ctx "(";
      let rec emit_branches = function
        | [] ->
          (match else_body with
           | Some stmts -> emit_block_expr ctx stmts
           | None -> emit ctx "TG_NIL")
        | { cond; body } :: rest ->
          emit ctx "("; emit_expr ctx cond; emit ctx ") ? (";
          emit_block_expr ctx body;
          emit ctx ") : (";
          emit_branches rest;
          emit ctx ")"
      in
      emit_branches branches;
      emit ctx ")"
    end

  | EMatch (scrutinee, arms, _) ->
    let tmp = fresh_temp ctx in
    emitf ctx "({ TgVal %s_scrut = " tmp;
    emit_expr ctx scrutinee;
    emitf ctx "; TgVal %s_res = TG_NIL; " tmp;
    (* Track scrutinee type for correct enum casts in match arms *)
    let scrut_tname = expr_type_name ctx scrutinee in
    if scrut_tname <> "" then set_var_type ctx (tmp ^ "_scrut") scrut_tname;
    emit_match_expr ctx tmp arms;
    emitf ctx "%s_res; })" tmp

  | EWhile (_, _, _) | EFor (_, _, _, _) | ELoop (_, _) ->
    (* These should be emitted as statements, not expressions *)
    emit ctx "TG_NIL"

  | EBlock (stmts, _) ->
    emit ctx "({ ";
    emit_block_expr ctx stmts;
    emit ctx "; })"

  | EReturn (Some (EBlock (stmts, _)), _) ->
    (* Wrap block in statement expression for return *)
    emit ctx "return ({";
    emit_block_expr ctx stmts;
    emit ctx ";})"

  | EReturn (Some e, _) ->
    emit ctx "return "; emit_expr ctx e

  | EReturn (None, _) ->
    emit ctx "return TG_NIL"

  | EBreak (_, _) ->
    emit ctx "break"

  | ENext _ ->
    (* In expression position, 'next' is likely a variable name, not loop control *)
    (* Loop control 'next' is handled in SExpr (ENext _) at statement level *)
    emit ctx "next_"

  | EAssign (lhs, rhs, _) ->
    emit_assign_expr ctx lhs rhs

  | EClosure (params, _ret, body, _) ->
    emit_closure ctx params body

  | ECast (inner, typ, _) ->
    (match typ with
     | TyName ("u8", []) -> emit ctx "((TgVal)(uint8_t)("; emit_expr ctx inner; emit ctx "))"
     | TyName ("u16", []) -> emit ctx "((TgVal)(uint16_t)("; emit_expr ctx inner; emit ctx "))"
     | TyName ("u32", []) -> emit ctx "((TgVal)(uint32_t)("; emit_expr ctx inner; emit ctx "))"
     | TyName ("u64", []) -> emit ctx "((TgVal)(uint64_t)("; emit_expr ctx inner; emit ctx "))"
     | TyName ("i8", []) -> emit ctx "((TgVal)(int8_t)("; emit_expr ctx inner; emit ctx "))"
     | TyName ("i16", []) -> emit ctx "((TgVal)(int16_t)("; emit_expr ctx inner; emit ctx "))"
     | TyName ("i32", []) -> emit ctx "((TgVal)(int32_t)("; emit_expr ctx inner; emit ctx "))"
     | TyName ("i64", []) | TyName ("Int", []) -> emit ctx "((TgVal)("; emit_expr ctx inner; emit ctx "))"
     | TyName ("UInt", []) -> emit ctx "((TgVal)(uint64_t)("; emit_expr ctx inner; emit ctx "))"
     | TyName ("Float", []) -> emit ctx "tg_from_double((double)("; emit_expr ctx inner; emit ctx "))"
     | TyName ("String", []) -> emit ctx "_generic_to_string("; emit_expr ctx inner; emit ctx ")"
     | _ -> emit ctx "("; emit_expr ctx inner; emit ctx ")")

  | ERange (start, end_, inclusive, _) ->
    (* Create a range object — typically used in for loops *)
    let tmp = fresh_temp ctx in
    emitf ctx "({ TgVal %s = tg_vec_new(); " tmp;
    emitf ctx "for (TgVal _ri = "; emit_expr ctx start;
    emitf ctx "; _ri %s " (if inclusive then "<=" else "<");
    emit_expr ctx end_;
    emitf ctx "; _ri++) tg_vec_push(%s, _ri); %s; })" tmp tmp

and emit_args ctx args =
  let first = ref true in
  List.iter (fun arg ->
    if !first then first := false else emit ctx ", ";
    emit_expr ctx arg
  ) args

and emit_block_expr ctx stmts =
  match stmts with
  | [] -> emit ctx "TG_NIL"
  | [SExpr e] -> emit_expr ctx e
  | _ ->
    let last_idx = List.length stmts - 1 in
    List.iteri (fun i s ->
      if i = last_idx then begin
        match s with
        | SExpr e -> emit_expr ctx e
        | SLet { name; value; typ; _ } ->
          emitf ctx "TgVal %s = " (c_ident name);
          emit_expr ctx value;
          emit ctx "; ";
          (* Track type *)
          let tname = match typ with
            | Some t -> Resolve.type_name_string_of_typ t
            | None -> expr_type_name ctx value
          in
          if tname <> "" then set_var_type ctx name tname;
          emit ctx "TG_NIL"
      end else begin
        emit_stmt_inline ctx s;
        emit ctx " "
      end
    ) stmts

and emit_block_expr_to ctx stmts target =
  (* Like emit_block_expr, but assigns the final value to [target] *)
  match stmts with
  | [] -> emitf ctx "%s = TG_NIL; " target
  | [SExpr (EReturn _ as e)] | [SExpr (EBreak _ as e)] ->
    emit_expr ctx e; emit ctx "; "
  | [SExpr (ENext _)] ->
    emit ctx "continue; "
  | [SExpr e] ->
    emitf ctx "%s = " target; emit_expr ctx e; emit ctx "; "
  | _ ->
    let last_idx = List.length stmts - 1 in
    List.iteri (fun i s ->
      if i = last_idx then begin
        match s with
        | SExpr (EReturn _ as e) | SExpr (EBreak _ as e) ->
          emit_expr ctx e; emit ctx "; "
        | SExpr (ENext _) ->
          emit ctx "continue; "
        | SExpr e ->
          emitf ctx "%s = " target; emit_expr ctx e; emit ctx "; "
        | SLet { name; value; typ; _ } ->
          emitf ctx "TgVal %s = " (c_ident name);
          emit_expr ctx value; emit ctx "; ";
          let tname = match typ with
            | Some t -> Resolve.type_name_string_of_typ t
            | None -> expr_type_name ctx value
          in
          if tname <> "" then set_var_type ctx name tname;
          emitf ctx "%s = TG_NIL; " target
      end else begin
        emit_stmt_inline ctx s;
        emit ctx " "
      end
    ) stmts

and emit_stmt_inline ctx = function
  | SLet { name; value; typ; _ } ->
    emitf ctx "TgVal %s = " (c_ident name);
    emit_expr ctx value;
    emit ctx ";";
    let tname = match typ with
      | Some t -> Resolve.type_name_string_of_typ t
      | None -> expr_type_name ctx value
    in
    if tname <> "" then set_var_type ctx name tname
  | SExpr e ->
    emit_expr ctx e; emit ctx ";"

(* ── Method call resolution ────────────────────────────────────────── *)

and emit_method_call ctx obj method_name args =
  let obj_type = expr_type_name ctx obj in
  (* Built-in methods for known types *)
  if is_string_type obj_type then
    emit_string_method ctx obj method_name args
  else if obj_type = "Vec" || is_vec_type obj_type then
    emit_vec_method ctx obj method_name args
  else if obj_type = "Map" || is_map_type obj_type then
    emit_map_method ctx obj method_name args
  else if obj_type = "Set" || is_set_type obj_type then
    emit_set_method ctx obj method_name args
  else if obj_type = "Option" then
    emit_option_method ctx obj method_name args
  else if obj_type = "Result" then
    emit_result_method ctx obj method_name args
  else if obj_type = "Int" || obj_type = "i64" || obj_type = "i32"
       || obj_type = "UInt" || obj_type = "u64" || obj_type = "u32" then
    emit_int_method ctx obj method_name args
  else if obj_type = "Float" || obj_type = "f64" || obj_type = "f32" then
    emit_float_method ctx obj method_name args
  else if obj_type = "Bool" then
    emit_bool_method ctx obj method_name args
  else if obj_type = "Char" then
    emit_char_method ctx obj method_name args
  else begin
    (* User-defined method — first check for universal methods *)
    match method_name with
    | "clone" -> emit ctx "_generic_clone("; emit_expr ctx obj; emit ctx ")"
    | "to_string" | "display" -> emit ctx "_generic_to_string("; emit_expr ctx obj; emit ctx ")"
    | "len" -> emit ctx "tg_vec_len("; emit_expr ctx obj; emit ctx ")"
    | "is_empty" -> emit ctx "tg_vec_is_empty("; emit_expr ctx obj; emit ctx ")"
    | "push" ->
      emit ctx "(tg_vec_push("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx "), TG_NIL)"
    | "pop" -> emit ctx "tg_vec_pop("; emit_expr ctx obj; emit ctx ")"
    | "iter" | "into_iter" -> emit ctx "/* .iter() */ ("; emit_expr ctx obj; emit ctx ")"
    | "unwrap" -> emit ctx "tg_option_unwrap("; emit_expr ctx obj; emit ctx ")"
    | "unwrap_or" ->
      emit ctx "tg_option_unwrap_or("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "unwrap_or_else" ->
      emit ctx "tg_option_unwrap_or("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit ctx "tg_closure_call1("; emit_expr ctx a; emit ctx ", TG_NIL)" | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "is_some" -> emit ctx "tg_option_is_some("; emit_expr ctx obj; emit ctx ")"
    | "is_none" -> emit ctx "tg_option_is_none("; emit_expr ctx obj; emit ctx ")"
    | "is_ok" -> emit ctx "tg_result_is_ok("; emit_expr ctx obj; emit ctx ")"
    | "is_err" -> emit ctx "tg_result_is_err("; emit_expr ctx obj; emit ctx ")"
    | "unwrap_err" -> emit ctx "tg_result_unwrap_err("; emit_expr ctx obj; emit ctx ")"
    | "map" ->
      emit ctx "tg_option_map("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "map_err" ->
      emit ctx "/* .map_err() */ ("; emit_expr ctx obj; emit ctx ")"
    | "and_then" ->
      emit ctx "tg_option_map("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "as_str" | "as_string" ->
      emit ctx "_generic_to_string("; emit_expr ctx obj; emit ctx ")"
    | "insert" ->
      (match args with
       | [k] -> (* Set insert *)
         emit ctx "tg_set_insert("; emit_expr ctx obj; emit ctx ", ";
         emit_expr ctx k; emit ctx ")"
       | [k; v] ->
         emit ctx "tg_map_insert("; emit_expr ctx obj; emit ctx ", ";
         emit_expr ctx k; emit ctx ", "; emit_expr ctx v; emit ctx ")"
       | _ ->
         emit ctx "tg_map_insert("; emit_expr ctx obj;
         List.iter (fun a -> emit ctx ", "; emit_expr ctx a) args;
         emit ctx ")")
    | "get" ->
      emit ctx "tg_map_get("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "contains" ->
      emit ctx "tg_str_contains("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "contains_key" ->
      emit ctx "tg_map_contains("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "starts_with" ->
      emit ctx "tg_str_starts_with("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "ends_with" ->
      emit ctx "tg_str_ends_with("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "split" ->
      emit ctx "tg_str_split("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "split_once" ->
      emit ctx "tg_str_split("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "trim" -> emit ctx "tg_str_trim("; emit_expr ctx obj; emit ctx ")"
    | "trim_end" -> emit ctx "tg_str_trim("; emit_expr ctx obj; emit ctx ")"
    | "replace" ->
      emit ctx "tg_str_replace("; emit_expr ctx obj;
      List.iter (fun a -> emit ctx ", "; emit_expr ctx a) args;
      emit ctx ")"
    | "join" ->
      emit ctx "tg_str_join("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "lines" -> emit ctx "tg_str_split("; emit_expr ctx obj; emit ctx ", tg_str_from_cstr(\"\\n\"))"
    | "chars" -> emit ctx "/* .chars() */ ("; emit_expr ctx obj; emit ctx ")"
    | "bytes" -> emit ctx "/* .bytes() */ ("; emit_expr ctx obj; emit ctx ")"
    | "parse_int" | "parse" -> emit ctx "tg_str_parse_int("; emit_expr ctx obj; emit ctx ")"
    | "to_lowercase" -> emit ctx "tg_str_to_lowercase("; emit_expr ctx obj; emit ctx ")"
    | "to_uppercase" -> emit ctx "tg_str_to_uppercase("; emit_expr ctx obj; emit ctx ")"
    | "is_lowercase" -> emit ctx "tg_str_is_lowercase("; emit_expr ctx obj; emit ctx ")"
    | "collect" -> emit ctx "/* .collect() */ ("; emit_expr ctx obj; emit ctx ")"
    | "sorted" -> emit ctx "/* .sorted() */ _generic_clone("; emit_expr ctx obj; emit ctx ")"
    | "reverse" | "reversed" -> emit ctx "/* .reverse() */ ("; emit_expr ctx obj; emit ctx ")"
    | "extend" | "extend_from_slice" ->
      emit ctx "tg_vec_extend("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "substring" | "slice" ->
      emit ctx "tg_str_slice("; emit_expr ctx obj;
      List.iter (fun a -> emit ctx ", "; emit_expr ctx a) args;
      emit ctx ")"
    | "remove" ->
      emit ctx "tg_map_remove("; emit_expr ctx obj; emit ctx ", ";
      (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
      emit ctx ")"
    | "first" -> emit ctx "tg_vec_get("; emit_expr ctx obj; emit ctx ", 0)"
    | "last" -> emit ctx "tg_vec_get("; emit_expr ctx obj; emit ctx ", tg_vec_len("; emit_expr ctx obj; emit ctx ") - 1)"
    | "flat_map" | "filter" | "find" | "any" | "all" | "count" | "zip"
    | "enumerate" | "skip" | "take" | "for_each" | "fold" | "reduce"
    | "max" | "min" | "sum" | "product" | "position" | "nth" | "chain"
    | "inspect" | "collect_into" | "peekable" | "fuse" ->
      (* Iterator methods — just pass through for now *)
      emit ctx "/* ."; emit ctx method_name; emit ctx "() */ ("; emit_expr ctx obj; emit ctx ")"
    | "or_insert" | "or_default" ->
      emit ctx "/* ."; emit ctx method_name; emit ctx "() */ ("; emit_expr ctx obj; emit ctx ")"
    | "entry" ->
      emit ctx "/* .entry() */ ("; emit_expr ctx obj; emit ctx ")"
    | "values" -> emit ctx "tg_map_values("; emit_expr ctx obj; emit ctx ")"
    | "keys" -> emit ctx "tg_map_keys("; emit_expr ctx obj; emit ctx ")"
    | "into_vec" -> emit ctx "_generic_clone("; emit_expr ctx obj; emit ctx ")"
    | "truncate" ->
      emit ctx "/* .truncate() */ ("; emit_expr ctx obj; emit ctx ")"
    | "name" | "description" | "to_source" | "default_level"
    | "has_binding" | "is_mutated_in" | "is_copy" | "run" | "eval"
    | "get_int" | "get_env" ->
      (* User methods — try module dispatch *)
      let resolved_type = if obj_type = "" then ctx.self_type else obj_type in
      if resolved_type <> "" then begin
        emitf ctx "%s(" (resolve_method_name ctx resolved_type method_name);
        emit_expr ctx obj;
        List.iter (fun a -> emit ctx ", "; emit_expr ctx a) args;
        emit ctx ")"
      end else begin
        emitf ctx "/* .%s() */ (" method_name;
        emit_expr ctx obj;
        emit ctx ")"
      end
    | _ ->
      (* Generic fallback — try method dispatch as module_type__method *)
      let resolved_type = if obj_type = "" then ctx.self_type else obj_type in
      if resolved_type <> "" then begin
        emitf ctx "%s(" (resolve_method_name ctx resolved_type method_name);
        emit_expr ctx obj;
        List.iter (fun a -> emit ctx ", "; emit_expr ctx a) args;
        emit ctx ")"
      end else begin
        emitf ctx "/* .%s() */ (" method_name;
        emit_expr ctx obj;
        emit ctx ")"
      end
  end

and emit_string_method ctx obj meth args =
  match meth with
  | "len" -> emit ctx "tg_str_len("; emit_expr ctx obj; emit ctx ")"
  | "is_empty" -> emit ctx "tg_str_is_empty("; emit_expr ctx obj; emit ctx ")"
  | "clone" -> emit ctx "tg_str_clone("; emit_expr ctx obj; emit ctx ")"
  | "contains" ->
    emit ctx "tg_str_contains("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "starts_with" ->
    emit ctx "tg_str_starts_with("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "ends_with" ->
    emit ctx "tg_str_ends_with("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "find" ->
    emit ctx "tg_str_find("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "slice" ->
    emit ctx "tg_str_slice("; emit_expr ctx obj; emit ctx ", ";
    (match args with
     | [a; b] -> emit_expr ctx a; emit ctx ", "; emit_expr ctx b
     | _ -> emit ctx "0, 0");
    emit ctx ")"
  | "char_at" ->
    emit ctx "tg_str_char_at("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "0");
    emit ctx ")"
  | "to_lowercase" -> emit ctx "tg_str_to_lowercase("; emit_expr ctx obj; emit ctx ")"
  | "to_uppercase" -> emit ctx "tg_str_to_uppercase("; emit_expr ctx obj; emit ctx ")"
  | "trim" -> emit ctx "tg_str_trim("; emit_expr ctx obj; emit ctx ")"
  | "replace" ->
    emit ctx "tg_str_replace("; emit_expr ctx obj; emit ctx ", ";
    (match args with
     | [a; b] -> emit_expr ctx a; emit ctx ", "; emit_expr ctx b
     | _ -> emit ctx "TG_NIL, TG_NIL");
    emit ctx ")"
  | "split" ->
    emit ctx "tg_str_split("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "lines" -> emit ctx "tg_str_lines("; emit_expr ctx obj; emit ctx ")"
  | "bytes" -> emit ctx "tg_str_bytes("; emit_expr ctx obj; emit ctx ")"
  | "chars" -> emit ctx "tg_str_chars("; emit_expr ctx obj; emit ctx ")"
  | "to_string" -> emit_expr ctx obj
  | "to_int" -> emit ctx "tg_str_to_int("; emit_expr ctx obj; emit ctx ")"
  | "parse_float" -> emit ctx "tg_str_parse_float("; emit_expr ctx obj; emit ctx ")"
  | "push_str" | "push" ->
    emit ctx "tg_str_push_str("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "push_char" ->
    emit ctx "tg_str_push_char("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "0");
    emit ctx ")"
  | "eq" ->
    emit ctx "tg_str_eq("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "cmp" ->
    emit ctx "tg_str_cmp("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "hash" -> emitf ctx "tg_str_hash("; emit_expr ctx obj; emit ctx ")"
  | "capitalize" ->
    (* capitalize = uppercase first char + rest *)
    let t = fresh_temp ctx in
    emitf ctx "({ TgVal %s = tg_str_clone(" t;
    emit_expr ctx obj;
    emitf ctx "); TgString* _cs = (TgString*)tg_as_ptr(%s); " t;
    emitf ctx "if (_cs && _cs->len > 0) _cs->data[0] = toupper(_cs->data[0]); %s; })" t
  | _ ->
    emitf ctx "/* String.%s */ TG_NIL" meth

and emit_vec_method ctx obj meth args =
  match meth with
  | "new" -> emit ctx "tg_vec_new()"
  | "len" -> emit ctx "tg_vec_len("; emit_expr ctx obj; emit ctx ")"
  | "is_empty" -> emit ctx "tg_vec_is_empty("; emit_expr ctx obj; emit ctx ")"
  | "push" ->
    emit ctx "(tg_vec_push("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx "), TG_NIL)"
  | "pop" -> emit ctx "tg_vec_pop("; emit_expr ctx obj; emit ctx ")"
  | "get" ->
    emit ctx "tg_vec_get("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "0");
    emit ctx ")"
  | "get_mut" ->
    emit ctx "tg_vec_get("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "0");
    emit ctx ")"
  | "set" ->
    emit ctx "tg_vec_set("; emit_expr ctx obj; emit ctx ", ";
    (match args with
     | [a; b] -> emit_expr ctx a; emit ctx ", "; emit_expr ctx b
     | _ -> emit ctx "0, TG_NIL");
    emit ctx ")"
  | "last" -> emit ctx "tg_vec_last("; emit_expr ctx obj; emit ctx ")"
  | "clear" -> emit ctx "tg_vec_clear("; emit_expr ctx obj; emit ctx ")"
  | "truncate" ->
    emit ctx "tg_vec_truncate("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "0");
    emit ctx ")"
  | "reverse" -> emit ctx "tg_vec_reverse("; emit_expr ctx obj; emit ctx ")"
  | "extend" | "extend_from_slice" ->
    emit ctx "tg_vec_extend("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "contains" ->
    emit ctx "tg_vec_contains("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "sort" -> emit ctx "tg_vec_sort("; emit_expr ctx obj; emit ctx ")"
  | "sort_by" ->
    emit ctx "tg_vec_sort_by("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "remove" ->
    emit ctx "tg_vec_remove("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "0");
    emit ctx ")"
  | "insert" ->
    emit ctx "tg_vec_insert("; emit_expr ctx obj; emit ctx ", ";
    (match args with
     | [a; b] -> emit_expr ctx a; emit ctx ", "; emit_expr ctx b
     | _ -> emit ctx "0, TG_NIL");
    emit ctx ")"
  | "clone" -> emit ctx "tg_vec_clone("; emit_expr ctx obj; emit ctx ")"
  | "iter" -> emit_expr ctx obj  (* identity *)
  | "collect" -> emit_expr ctx obj  (* identity *)
  | "map" ->
    emit ctx "tg_vec_map("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "filter" ->
    emit ctx "tg_vec_filter("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "filter_map" ->
    emit ctx "tg_vec_filter_map("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "any" ->
    emit ctx "tg_vec_any("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "all" ->
    emit ctx "tg_vec_all("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "find" ->
    emit ctx "tg_vec_find("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "enumerate" -> emit ctx "tg_vec_enumerate("; emit_expr ctx obj; emit ctx ")"
  | "for_each" ->
    emit ctx "tg_vec_for_each("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "join" ->
    emit ctx "tg_vec_join("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "tg_str_new()");
    emit ctx ")"
  | "to_string" -> emit ctx "tg_int_to_string(tg_vec_len("; emit_expr ctx obj; emit ctx "))"
  | _ ->
    emitf ctx "/* Vec.%s */ TG_NIL" meth

and emit_map_method ctx obj meth args =
  match meth with
  | "new" -> emit ctx "tg_map_new_string_keys()"
  | "len" -> emit ctx "tg_map_len("; emit_expr ctx obj; emit ctx ")"
  | "is_empty" -> emit ctx "tg_map_is_empty("; emit_expr ctx obj; emit ctx ")"
  | "insert" ->
    emit ctx "tg_map_insert("; emit_expr ctx obj; emit ctx ", ";
    (match args with
     | [a; b] -> emit_expr ctx a; emit ctx ", "; emit_expr ctx b
     | _ -> emit ctx "TG_NIL, TG_NIL");
    emit ctx ")"
  | "get" ->
    emit ctx "tg_map_get("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "get_mut" ->
    emit ctx "tg_map_get("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "contains_key" | "contains" ->
    emit ctx "tg_map_contains_key("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "remove" ->
    emit ctx "tg_map_remove("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "entries" -> emit ctx "tg_map_entries("; emit_expr ctx obj; emit ctx ")"
  | "keys" -> emit ctx "tg_map_keys("; emit_expr ctx obj; emit ctx ")"
  | "values" -> emit ctx "tg_map_values("; emit_expr ctx obj; emit ctx ")"
  | "clone" -> emit ctx "tg_map_clone("; emit_expr ctx obj; emit ctx ")"
  | _ ->
    emitf ctx "/* Map.%s */ TG_NIL" meth

and emit_set_method ctx obj meth args =
  match meth with
  | "new" -> emit ctx "tg_set_new_string_keys()"
  | "len" -> emit ctx "tg_set_len("; emit_expr ctx obj; emit ctx ")"
  | "is_empty" -> emit ctx "tg_set_is_empty("; emit_expr ctx obj; emit ctx ")"
  | "insert" ->
    emit ctx "tg_set_insert("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "remove" ->
    emit ctx "tg_set_remove("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "contains" ->
    emit ctx "tg_set_contains("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "to_vec" | "into_vec" ->
    emit ctx "tg_set_to_vec("; emit_expr ctx obj; emit ctx ")"
  | "clone" -> emit ctx "tg_set_clone("; emit_expr ctx obj; emit ctx ")"
  | _ ->
    emitf ctx "/* Set.%s */ TG_NIL" meth

and emit_option_method ctx obj meth args =
  match meth with
  | "is_some" -> emit ctx "tg_option_is_some("; emit_expr ctx obj; emit ctx ")"
  | "is_none" -> emit ctx "tg_option_is_none("; emit_expr ctx obj; emit ctx ")"
  | "unwrap" -> emit ctx "tg_option_unwrap("; emit_expr ctx obj; emit ctx ")"
  | "unwrap_or" ->
    emit ctx "tg_option_unwrap_or("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | "map" ->
    emit ctx "tg_option_map("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | _ ->
    emitf ctx "/* Option.%s */ TG_NIL" meth

and emit_result_method ctx obj meth args =
  match meth with
  | "is_ok" -> emit ctx "tg_result_is_ok("; emit_expr ctx obj; emit ctx ")"
  | "is_err" -> emit ctx "tg_result_is_err("; emit_expr ctx obj; emit ctx ")"
  | "unwrap" -> emit ctx "tg_result_unwrap("; emit_expr ctx obj; emit ctx ")"
  | "unwrap_err" -> emit ctx "tg_result_unwrap_err("; emit_expr ctx obj; emit ctx ")"
  | "map_err" ->
    emit ctx "tg_result_map_err("; emit_expr ctx obj; emit ctx ", ";
    (match args with [a] -> emit_expr ctx a | _ -> emit ctx "TG_NIL");
    emit ctx ")"
  | _ ->
    emitf ctx "/* Result.%s */ TG_NIL" meth

(* ── Int/UInt method resolution ────────────────────────────────────── *)

and emit_int_method ctx obj meth _args =
  match meth with
  | "to_string" -> emit ctx "tg_int_to_string("; emit_expr ctx obj; emit ctx ")"
  | "abs" -> emit ctx "({ TgVal _iv = "; emit_expr ctx obj; emit ctx "; _iv < 0 ? -_iv : _iv; })"
  | "min" ->
    emit ctx "({ TgVal _a = "; emit_expr ctx obj; emit ctx "; TgVal _b = ";
    (match _args with [a] -> emit_expr ctx a | _ -> emit ctx "0"); emit ctx "; _a < _b ? _a : _b; })"
  | "max" ->
    emit ctx "({ TgVal _a = "; emit_expr ctx obj; emit ctx "; TgVal _b = ";
    (match _args with [a] -> emit_expr ctx a | _ -> emit ctx "0"); emit ctx "; _a > _b ? _a : _b; })"
  | "clone" -> emit_expr ctx obj
  | "clamp" ->
    emit ctx "({ TgVal _v = "; emit_expr ctx obj;
    emit ctx "; TgVal _lo = ";
    (match _args with a :: _ -> emit_expr ctx a | _ -> emit ctx "0");
    emit ctx "; TgVal _hi = ";
    (match _args with _ :: b :: _ -> emit_expr ctx b | _ -> emit ctx "0");
    emit ctx "; _v < _lo ? _lo : _v > _hi ? _hi : _v; })"
  | "pow" ->
    emit ctx "tg_int_pow("; emit_expr ctx obj; emit ctx ", ";
    (match _args with [a] -> emit_expr ctx a | _ -> emit ctx "1"); emit ctx ")"
  | _ ->
    emitf ctx "/* Int.%s */ TG_NIL" meth

(* ── Float method resolution ──────────────────────────────────────── *)

and emit_float_method ctx obj meth _args =
  match meth with
  | "to_string" -> emit ctx "tg_float_to_string("; emit_expr ctx obj; emit ctx ")"
  | "floor" -> emit ctx "tg_from_double(floor(tg_to_double("; emit_expr ctx obj; emit ctx ")))"
  | "ceil" -> emit ctx "tg_from_double(ceil(tg_to_double("; emit_expr ctx obj; emit ctx ")))"
  | "round" -> emit ctx "tg_from_double(round(tg_to_double("; emit_expr ctx obj; emit ctx ")))"
  | "abs" -> emit ctx "tg_from_double(fabs(tg_to_double("; emit_expr ctx obj; emit ctx ")))"
  | "sqrt" -> emit ctx "tg_from_double(sqrt(tg_to_double("; emit_expr ctx obj; emit ctx ")))"
  | "clone" -> emit_expr ctx obj
  | "to_int" -> emit ctx "((TgVal)(int64_t)tg_to_double("; emit_expr ctx obj; emit ctx "))"
  | _ ->
    emitf ctx "/* Float.%s */ TG_NIL" meth

(* ── Bool method resolution ───────────────────────────────────────── *)

and emit_bool_method ctx obj meth _args =
  match meth with
  | "to_string" -> emit ctx "("; emit_expr ctx obj; emit ctx " ? tg_str_from_cstr(\"true\") : tg_str_from_cstr(\"false\"))"
  | "clone" -> emit_expr ctx obj
  | _ ->
    emitf ctx "/* Bool.%s */ TG_NIL" meth

(* ── Char method resolution ───────────────────────────────────────── *)

and emit_char_method ctx obj meth _args =
  match meth with
  | "to_string" -> emit ctx "tg_char_to_string("; emit_expr ctx obj; emit ctx ")"
  | "is_alphabetic" -> emit ctx "((TgVal)isalpha((int)("; emit_expr ctx obj; emit ctx ")))"
  | "is_digit" | "is_numeric" -> emit ctx "((TgVal)isdigit((int)("; emit_expr ctx obj; emit ctx ")))"
  | "is_whitespace" -> emit ctx "((TgVal)isspace((int)("; emit_expr ctx obj; emit ctx ")))"
  | "is_alphanumeric" -> emit ctx "((TgVal)isalnum((int)("; emit_expr ctx obj; emit ctx ")))"
  | "to_uppercase" -> emit ctx "((TgVal)toupper((int)("; emit_expr ctx obj; emit ctx ")))"
  | "to_lowercase" -> emit ctx "((TgVal)tolower((int)("; emit_expr ctx obj; emit ctx ")))"
  | "clone" -> emit_expr ctx obj
  | _ ->
    emitf ctx "/* Char.%s */ TG_NIL" meth

(* ── Assign expression ─────────────────────────────────────────────── *)

and emit_assign_expr ctx lhs rhs =
  match lhs with
  | EIdent ("self", _) ->
    emit ctx "_self = "; emit_expr ctx rhs

  | EIdent (name, _) ->
    emitf ctx "%s = " (c_ident name); emit_expr ctx rhs

  | EFieldAccess (obj, field, _) ->
    let obj_type = expr_type_name ctx obj in
    if obj_type <> "" && Resolve.is_struct ctx.res obj_type then begin
      emitf ctx "((%s*)tg_as_ptr(" (resolve_type ctx obj_type);
      emit_expr ctx obj;
      emitf ctx "))->%s = " (c_ident field);
      emit_expr ctx rhs
    end else begin
      emit ctx "/* assign field */ ";
      emit_expr ctx obj;
      emitf ctx "/* .%s = */ " field
    end

  | EIndex (obj, idx, _) ->
    emit ctx "tg_vec_set("; emit_expr ctx obj; emit ctx ", ";
    emit_expr ctx idx; emit ctx ", "; emit_expr ctx rhs; emit ctx ")"

  | _ ->
    emit ctx "/* assign */ TG_NIL"

(* ── Match expression codegen ──────────────────────────────────────── *)

(* Emit bindings for a nested pattern given an already-unwrapped value.
   mode = "expr" uses " " separator, "stmt" uses "\n" separator *)
and emit_nested_pattern_bindings_expr ctx unwrapped_var sub_pats =
  match sub_pats with
  | [PatBind (n, _)] ->
    emitf ctx "TgVal %s = %s; " (c_ident n) unwrapped_var;
    set_var_type ctx n ""
  | [PatMut (n, _)] ->
    emitf ctx "TgVal %s = %s; " (c_ident n) unwrapped_var
  | [PatWild _] | [] -> ()
  | [PatTuple (inner_pats, _)] ->
    List.iteri (fun i pat ->
      match pat with
      | PatBind (n, _) | PatMut (n, _) ->
        emitf ctx "TgVal %s = tg_tuple_get(%s, %d); " (c_ident n) unwrapped_var i;
        set_var_type ctx n ""
      | PatWild _ -> ()
      | _ -> ()
    ) inner_pats
  | [PatVariant (inner_vname_raw, inner_sub, _)] ->
    let (_eh, inner_vname) = split_qualified_variant inner_vname_raw in
    (* For nested variant like Some(Register(x)), unwrap the inner variant *)
    (match inner_sub with
     | [PatBind (n, _)] | [PatMut (n, _)] ->
       (* Assume single-field variant: field is _f0 *)
       let _ = inner_vname in
       emitf ctx "TgVal %s = tg_field_get(%s, 0); " (c_ident n) unwrapped_var;
       set_var_type ctx n ""
     | _ ->
       List.iteri (fun i sub ->
         match sub with
         | PatBind (n, _) | PatMut (n, _) ->
           emitf ctx "TgVal %s = tg_field_get(%s, %d); " (c_ident n) unwrapped_var i;
           set_var_type ctx n ""
         | _ -> ()
       ) inner_sub)
  | [PatStruct (_, fields, _)] ->
    List.iter (fun (fname, pat_opt) ->
      match pat_opt with
      | Some (PatBind (n, _)) | Some (PatMut (n, _)) ->
        emitf ctx "TgVal %s = tg_field_get_named(%s, \"%s\"); " (c_ident n) unwrapped_var fname;
        set_var_type ctx n ""
      | None ->
        emitf ctx "TgVal %s = tg_field_get_named(%s, \"%s\"); " (c_ident fname) unwrapped_var fname;
        set_var_type ctx fname ""
      | _ -> ()
    ) fields
  | _ ->
    (* Fallback: try to bind any PatBind found *)
    List.iter (fun sub ->
      match sub with
      | PatBind (n, _) ->
        emitf ctx "TgVal %s = %s; " (c_ident n) unwrapped_var;
        set_var_type ctx n ""
      | _ -> ()
    ) sub_pats

and emit_nested_pattern_bindings_stmt ctx unwrapped_var sub_pats =
  match sub_pats with
  | [PatBind (n, _)] ->
    emit_indent ctx;
    emitf ctx "TgVal %s = %s;\n" (c_ident n) unwrapped_var;
    set_var_type ctx n ""
  | [PatMut (n, _)] ->
    emit_indent ctx;
    emitf ctx "TgVal %s = %s;\n" (c_ident n) unwrapped_var
  | [PatWild _] | [] -> ()
  | [PatTuple (inner_pats, _)] ->
    List.iteri (fun i pat ->
      match pat with
      | PatBind (n, _) | PatMut (n, _) ->
        emit_indent ctx;
        emitf ctx "TgVal %s = tg_tuple_get(%s, %d);\n" (c_ident n) unwrapped_var i;
        set_var_type ctx n ""
      | PatWild _ -> ()
      | _ -> ()
    ) inner_pats
  | [PatVariant (inner_vname_raw, inner_sub, _)] ->
    let (_eh, inner_vname) = split_qualified_variant inner_vname_raw in
    (match inner_sub with
     | [PatBind (n, _)] | [PatMut (n, _)] ->
       let _ = inner_vname in
       emit_indent ctx;
       emitf ctx "TgVal %s = tg_field_get(%s, 0);\n" (c_ident n) unwrapped_var;
       set_var_type ctx n ""
     | _ ->
       List.iteri (fun i sub ->
         match sub with
         | PatBind (n, _) | PatMut (n, _) ->
           emit_indent ctx;
           emitf ctx "TgVal %s = tg_field_get(%s, %d);\n" (c_ident n) unwrapped_var i;
           set_var_type ctx n ""
         | _ -> ()
       ) inner_sub)
  | [PatStruct (_, fields, _)] ->
    List.iter (fun (fname, pat_opt) ->
      match pat_opt with
      | Some (PatBind (n, _)) | Some (PatMut (n, _)) ->
        emit_indent ctx;
        emitf ctx "TgVal %s = tg_field_get_named(%s, \"%s\");\n" (c_ident n) unwrapped_var fname;
        set_var_type ctx n ""
      | None ->
        emit_indent ctx;
        emitf ctx "TgVal %s = tg_field_get_named(%s, \"%s\");\n" (c_ident fname) unwrapped_var fname;
        set_var_type ctx fname ""
      | _ -> ()
    ) fields
  | _ ->
    List.iter (fun sub ->
      match sub with
      | PatBind (n, _) ->
        emit_indent ctx;
        emitf ctx "TgVal %s = %s;\n" (c_ident n) unwrapped_var;
        set_var_type ctx n ""
      | _ -> ()
    ) sub_pats

and emit_match_expr ctx tmp arms =
  List.iter (fun arm ->
    emit_match_arm_expr ctx tmp arm
  ) arms

and emit_match_arm_expr ctx tmp arm =
  let res = tmp ^ "_res" in
  match arm.pat with
  | PatWild _ ->
    emit_block_expr_to ctx arm.arm_body res

  | PatBind (name, _) when String.contains name ':' ->
    (* Qualified 0-arity variant: EnumName::VariantName *)
    let (enum_hint, vname) = split_qualified_variant name in
    let prefer = if enum_hint <> "" then enum_hint
      else get_var_type ctx (tmp ^ "_scrut") |> Option.value ~default:"" in
    (match Resolve.find_variant_prefer_enum ctx.res vname 0 ~prefer_enum:prefer with
     | Some vi ->
       emitf ctx "if (((%s*)tg_as_ptr(%s_scrut))->_tag == %d) { "
         (resolve_enum_type ctx vi) tmp vi.vi_tag;
       emit_block_expr_to ctx arm.arm_body res;
       emit ctx "} "
     | None ->
       emitf ctx "/* unknown 0-arity variant %s */ " name)

  | PatBind (name, _) ->
    emitf ctx "{ TgVal %s = %s_scrut; " (c_ident name) tmp;
    set_var_type ctx name (get_var_type ctx (tmp ^ "_scrut") |> Option.value ~default:"");
    emit_block_expr_to ctx arm.arm_body res;
    emit ctx "} "

  | PatMut (name, _) ->
    emitf ctx "{ TgVal %s = %s_scrut; " (c_ident name) tmp;
    emit_block_expr_to ctx arm.arm_body res;
    emit ctx "} "

  | PatLit lit ->
    emit ctx "if (";
    emitf ctx "%s_scrut == " tmp;
    emit_expr ctx lit;
    emit ctx ") { ";
    emit_block_expr_to ctx arm.arm_body res;
    emit ctx "} "

  | PatVariant (vname_raw, sub_pats, _) ->
    let (enum_hint, vname) = split_qualified_variant vname_raw in
    (* Handle builtin Option/Result variants first *)
    if vname = "Some" then begin
      emitf ctx "if (tg_option_is_some(%s_scrut)) { " tmp;
      let unwrapped = tmp ^ "_unwrapped" in
      emitf ctx "TgVal %s = tg_option_unwrap(%s_scrut); " unwrapped tmp;
      emit_nested_pattern_bindings_expr ctx unwrapped sub_pats;
      emit_block_expr_to ctx arm.arm_body res;
      emit ctx "} "
    end else if vname = "None" then begin
      emitf ctx "if (tg_option_is_none(%s_scrut)) { " tmp;
      emit_block_expr_to ctx arm.arm_body res;
      emit ctx "} "
    end else if vname = "Ok" then begin
      emitf ctx "if (tg_result_is_ok(%s_scrut)) { " tmp;
      let unwrapped = tmp ^ "_ok_unwrapped" in
      emitf ctx "TgVal %s = tg_result_unwrap(%s_scrut); " unwrapped tmp;
      emit_nested_pattern_bindings_expr ctx unwrapped sub_pats;
      emit_block_expr_to ctx arm.arm_body res;
      emit ctx "} "
    end else if vname = "Err" then begin
      emitf ctx "if (tg_result_is_err(%s_scrut)) { " tmp;
      let unwrapped = tmp ^ "_err_unwrapped" in
      emitf ctx "TgVal %s = tg_result_unwrap_err(%s_scrut); " unwrapped tmp;
      emit_nested_pattern_bindings_expr ctx unwrapped sub_pats;
      emit_block_expr_to ctx arm.arm_body res;
      emit ctx "} "
    end else begin
    (* Regular enum variant pattern — use arity-based lookup, preferring qualifier or scrutinee type *)
    let scrut_type = get_var_type ctx (tmp ^ "_scrut") |> Option.value ~default:"" in
    let prefer = if enum_hint <> "" then enum_hint else scrut_type in
    (match Resolve.find_variant_prefer_enum ctx.res vname (List.length sub_pats) ~prefer_enum:prefer with
     | Some vi ->
       emitf ctx "if (((%s*)tg_as_ptr(%s_scrut))->_tag == %d) { "
         (resolve_enum_type ctx vi) tmp vi.vi_tag;
       List.iteri (fun i sub ->
         match sub with
         | PatBind (n, _) ->
           emitf ctx "TgVal %s = ((%s*)tg_as_ptr(%s_scrut))->_f%d; "
             (c_ident n) (resolve_enum_type ctx vi) tmp i;
           (* Try to infer type from variant field *)
           if i < List.length vi.vi_fields then begin
             let ft = Resolve.type_name_string_of_typ (List.nth vi.vi_fields i) in
             if ft <> "" then set_var_type ctx n ft
           end
         | PatWild _ -> ()
         | PatMut (n, _) ->
           emitf ctx "TgVal %s = ((%s*)tg_as_ptr(%s_scrut))->_f%d; "
             (c_ident n) (resolve_enum_type ctx vi) tmp i
         | PatVariant (inner_vname, inner_sub, _) ->
           (* Nested variant pattern: extract field, then check tag *)
           let field_var = Printf.sprintf "_nested_%d" i in
           emitf ctx "TgVal %s = ((%s*)tg_as_ptr(%s_scrut))->_f%d; "
             field_var (resolve_enum_type ctx vi) tmp i;
           (match Resolve.find_variant_by_arity ctx.res inner_vname (List.length inner_sub) with
            | Some ivi ->
              List.iteri (fun j sub2 ->
                match sub2 with
                | PatBind (n, _) ->
                  emitf ctx "TgVal %s = ((%s*)tg_as_ptr(%s))->_f%d; "
                    (c_ident n) (resolve_enum_type ctx ivi) field_var j
                | _ -> ()
              ) inner_sub
            | None ->
              (* Nested variant not found — just bind field *)
              List.iteri (fun _j sub2 ->
                match sub2 with
                | PatBind (n, _) ->
                  emitf ctx "TgVal %s = %s; " (c_ident n) field_var
                | _ -> ()
              ) inner_sub)
         | _ -> ()
       ) sub_pats;
       emit_block_expr_to ctx arm.arm_body res;
       emit ctx "} "
     | None ->
       emitf ctx "/* unknown variant %s */ " vname)
    end

  | PatStruct (sname, field_pats, _) ->
    (* Check if sname is actually an enum variant with named fields *)
    if Resolve.is_variant ctx.res sname then begin
      match Resolve.find_variant ctx.res sname with
      | Some vi ->
        let tag_val = Printf.sprintf "%s_%s__new" (resolve_enum_type ctx vi) (c_ident sname) in
        emitf ctx "if ((((%s*)tg_as_ptr(%s_scrut))->_tag) == (TgVal)(intptr_t)%s) { "
          (resolve_enum_type ctx vi) tmp tag_val;
        emitf ctx "%s* _ps = (%s*)tg_as_ptr(%s_scrut); "
          (resolve_enum_type ctx vi) (resolve_enum_type ctx vi) tmp;
        List.iteri (fun i (fname, pat_opt) ->
          let _ = fname in
          match pat_opt with
          | Some (PatBind (n, _)) ->
            emitf ctx "TgVal %s = _ps->_f%d; " (c_ident n) i
          | None ->
            emitf ctx "TgVal %s = _ps->_f%d; " (c_ident fname) i
          | _ -> ()
        ) field_pats;
        emit_block_expr_to ctx arm.arm_body res;
        emit ctx "} "
      | None ->
        emitf ctx "{ %s* _ps = (%s*)tg_as_ptr(%s_scrut); "
          (resolve_type ctx sname) (resolve_type ctx sname) tmp;
        List.iter (fun (fname, pat_opt) ->
          match pat_opt with
          | Some (PatBind (n, _)) ->
            emitf ctx "TgVal %s = _ps->%s; " (c_ident n) (c_ident fname)
          | None ->
            emitf ctx "TgVal %s = _ps->%s; " (c_ident fname) (c_ident fname)
          | _ -> ()
        ) field_pats;
        emit_block_expr_to ctx arm.arm_body res;
        emit ctx "} "
    end else begin
      emitf ctx "{ %s* _ps = (%s*)tg_as_ptr(%s_scrut); "
        (resolve_type ctx sname) (resolve_type ctx sname) tmp;
      List.iter (fun (fname, pat_opt) ->
        match pat_opt with
        | Some (PatBind (n, _)) ->
          emitf ctx "TgVal %s = _ps->%s; " (c_ident n) (c_ident fname)
        | None ->
          emitf ctx "TgVal %s = _ps->%s; " (c_ident fname) (c_ident fname)
        | _ -> ()
      ) field_pats;
      emit_block_expr_to ctx arm.arm_body res;
      emit ctx "} "
    end

  | PatTuple (pats, _) ->
    List.iteri (fun i sub ->
      match sub with
      | PatBind (n, _) when String.contains n ':' ->
        (* Qualified 0-arity variant in tuple, e.g. Type::Unit — skip binding *)
        ()
      | PatBind (n, _) when Resolve.is_variant ctx.res n ->
        (* 0-arity variant in tuple — just skip (it's a match check, not a binding) *)
        ()
      | PatBind (n, _) ->
        emitf ctx "TgVal %s = tg_tuple_get(%s_scrut, %d); " (c_ident n) tmp i
      | PatMut (n, _) ->
        emitf ctx "TgVal %s = tg_tuple_get(%s_scrut, %d); " (c_ident n) tmp i
      | PatWild _ -> ()
      | PatVariant (vname, inner_pats, _) ->
        (* Nested variant in tuple — extract tuple element, then destructure *)
        let elem_var = Printf.sprintf "_tup_%d" i in
        emitf ctx "TgVal %s = tg_tuple_get(%s_scrut, %d); " elem_var tmp i;
        (if vname = "Some" then begin
          match inner_pats with
          | [PatBind (n, _)] ->
            emitf ctx "TgVal %s = tg_option_unwrap(%s); " (c_ident n) elem_var
          | _ -> ()
        end else
          match Resolve.find_variant_by_arity ctx.res vname (List.length inner_pats) with
          | Some vi ->
            List.iteri (fun j sub2 ->
              match sub2 with
              | PatBind (n, _) ->
                emitf ctx "TgVal %s = ((%s*)tg_as_ptr(%s))->_f%d; "
                  (c_ident n) (resolve_enum_type ctx vi) elem_var j
              | _ -> ()
            ) inner_pats
          | None ->
            List.iteri (fun _j sub2 ->
              match sub2 with
              | PatBind (n, _) ->
                emitf ctx "TgVal %s = %s; " (c_ident n) elem_var
              | _ -> ()
            ) inner_pats)
      | PatLit _ -> () (* literal pattern in tuple — skip for now *)
      | _ -> ()
    ) pats;
    emit_block_expr_to ctx arm.arm_body res

  | PatOr (p1, p2, _loc) ->
    (* Desugar: try p1, then p2 *)
    emit_match_arm_expr ctx tmp { arm with pat = p1 };
    emit_match_arm_expr ctx tmp { arm with pat = p2 }

(* ── Closure codegen ───────────────────────────────────────────────── *)

(* Collect free variables from an expression that aren't in the local scope *)
and collect_free_vars_expr ctx bound = function
  | EIdent (name, _) ->
    if List.mem name bound then []
    else if Resolve.is_function ctx.res name || Resolve.is_struct ctx.res name
            || Resolve.is_enum ctx.res name || Resolve.is_variant ctx.res name then []
    else if name = "true" || name = "false" || name = "nil" || name = "_"
            || name = "self" || name = "continue" || name = "break" then []
    else [name]
  | EInt _ | EFloat _ | EStr _ | EBool _ | EChar _ | ENil _ -> []
  | EBinOp (_, l, r, _) -> collect_free_vars_expr ctx bound l @ collect_free_vars_expr ctx bound r
  | EUnOp (_, e, _) | EReturn (Some e, _) -> collect_free_vars_expr ctx bound e
  | EReturn (None, _) | EBreak (_, _) | ENext _ -> []
  | ECall (f, args, _) ->
    collect_free_vars_expr ctx bound f @ List.concat_map (collect_free_vars_expr ctx bound) args
  | EMethodCall (obj, _, args, _) ->
    collect_free_vars_expr ctx bound obj @ List.concat_map (collect_free_vars_expr ctx bound) args
  | EFieldAccess (obj, _, _) -> collect_free_vars_expr ctx bound obj
  | EIndex (obj, idx, _) ->
    collect_free_vars_expr ctx bound obj @ collect_free_vars_expr ctx bound idx
  | EIf (branches, else_opt, _) ->
    List.concat_map (fun (br : if_branch) ->
      collect_free_vars_expr ctx bound br.cond @
      List.concat_map (collect_free_vars_stmt ctx bound) br.body
    ) branches @
    (match else_opt with Some stmts -> List.concat_map (collect_free_vars_stmt ctx bound) stmts | None -> [])
  | EBlock (stmts, _) -> collect_free_vars_stmts ctx bound stmts
  | EMatch (scrut, arms, _) ->
    collect_free_vars_expr ctx bound scrut @
    List.concat_map (fun arm ->
      let arm_bound = collect_pattern_bindings arm.pat @ bound in
      List.concat_map (collect_free_vars_stmt ctx arm_bound) arm.arm_body
    ) arms
  | ETuple (elems, _) | EArray (elems, _) ->
    List.concat_map (collect_free_vars_expr ctx bound) elems
  | EStructLit (_, fields, _) ->
    List.concat_map (fun (_, e) -> collect_free_vars_expr ctx bound e) fields
  | EClosure (params, _ret_ty, body, _) ->
    let inner_bound = List.map (fun p -> p.cp_name) params @ bound in
    collect_free_vars_expr ctx inner_bound body
  | EAssign (l, r, _) ->
    collect_free_vars_expr ctx bound l @ collect_free_vars_expr ctx bound r
  | ERange (a, b, _, _) ->
    collect_free_vars_expr ctx bound a @ collect_free_vars_expr ctx bound b
  | EWhile (c, body, _) ->
    collect_free_vars_expr ctx bound c @ List.concat_map (collect_free_vars_stmt ctx bound) body
  | EFor (var, iter, body, _) ->
    collect_free_vars_expr ctx bound iter @
    List.concat_map (collect_free_vars_stmt ctx (var :: bound)) body
  | ELoop (body, _) ->
    List.concat_map (collect_free_vars_stmt ctx bound) body
  | ECast (e, _, _) -> collect_free_vars_expr ctx bound e

and collect_free_vars_stmt ctx bound = function
  | SExpr e -> collect_free_vars_expr ctx bound e
  | SLet { name = _; value; _ } ->
    collect_free_vars_expr ctx bound value  (* name NOT yet in scope for value *)

and collect_free_vars_stmts ctx bound stmts =
  let _bound = ref bound in
  List.concat_map (fun s ->
    let fvs = collect_free_vars_stmt ctx !_bound s in
    (match s with
     | SLet { name; _ } -> _bound := name :: !_bound
     | _ -> ());
    fvs
  ) stmts

and collect_pattern_bindings = function
  | PatBind (n, _) | PatMut (n, _) -> [n]
  | PatVariant (_, subs, _) -> List.concat_map collect_pattern_bindings subs
  | PatTuple (subs, _) -> List.concat_map collect_pattern_bindings subs
  | PatStruct (_, fps, _) ->
    List.concat_map (fun (_, po) ->
      match po with Some p -> collect_pattern_bindings p | None -> []
    ) fps
  | PatOr (p1, p2, _) -> collect_pattern_bindings p1 @ collect_pattern_bindings p2
  | PatWild _ | PatLit _ -> []

and emit_closure ctx params body =
  let cname = fresh_closure_name ctx in

  (* Collect free variables from the closure body *)
  let param_names = List.map (fun p -> p.cp_name) params in
  let free_vars_raw = collect_free_vars_expr ctx param_names body in
  (* Deduplicate and filter to only variables that exist in the enclosing scope *)
  let seen = Hashtbl.create 16 in
  let free_vars = List.filter (fun v ->
    if Hashtbl.mem seen v then false
    else begin
      Hashtbl.replace seen v true;
      (* Only capture vars that exist in the enclosing scope *)
      match get_var_type ctx v with
      | Some _ -> true
      | None -> false
    end
  ) free_vars_raw in

  let fn_body = Buffer.create 256 in
  Buffer.add_string fn_body (Printf.sprintf "static TgVal %s(TgVal _env, TgVal _arg) {\n" cname);

  (* Unpack captured variables from _env *)
  if free_vars <> [] then begin
    let nfv = List.length free_vars in
    if nfv = 1 then
      Buffer.add_string fn_body
        (Printf.sprintf "    TgVal %s = _env;\n" (c_ident (List.hd free_vars)))
    else if nfv <= 3 then
      List.iteri (fun i v ->
        Buffer.add_string fn_body
          (Printf.sprintf "    TgVal %s = tg_tuple_get(_env, %d);\n" (c_ident v) i)
      ) free_vars
    else
      List.iteri (fun i v ->
        Buffer.add_string fn_body
          (Printf.sprintf "    TgVal %s = tg_vec_get(_env, %d);\n" (c_ident v) i)
      ) free_vars
  end;

  (* Unpack params from _arg *)
  (match params with
   | [] -> ()
   | [{cp_name; _}] ->
     Buffer.add_string fn_body (Printf.sprintf "    TgVal %s = _arg;\n" (c_ident cp_name));
     set_var_type ctx cp_name "";
     (* Handle tuple destructuring: _destructure_a,b or a_b names *)
     let is_destructure = (String.length cp_name > 13 && String.sub cp_name 0 13 = "_destructure_") in
     if is_destructure then begin
       let suffix = String.sub cp_name 13 (String.length cp_name - 13) in
       let parts = String.split_on_char ',' suffix in
       List.iteri (fun i part ->
         if part <> "_" then begin
           Buffer.add_string fn_body
             (Printf.sprintf "    TgVal %s = tg_tuple_get(%s, %d);\n"
                (c_ident part) (c_ident cp_name) i);
           set_var_type ctx part ""
         end
       ) parts
     end
   | _ ->
     List.iteri (fun i p ->
       Buffer.add_string fn_body
         (Printf.sprintf "    TgVal %s = tg_tuple_get(_arg, %d);\n" (c_ident p.cp_name) i);
       set_var_type ctx p.cp_name ""
     ) params);
  (* Emit body into the function buffer *)
  let saved_buf = ctx.buf in
  ctx.buf <- fn_body;
  (match body with
   | EBlock (stmts, _) when List.length stmts > 1 ->
     (* Multi-statement body: emit statements, return last value *)
     let last_idx = List.length stmts - 1 in
     List.iteri (fun i s ->
       if i = last_idx then begin
         match s with
         | SExpr (EReturn _ as e) | SExpr (EBreak _ as e) ->
           Buffer.add_string fn_body "    ";
           emit_expr ctx e;
           Buffer.add_string fn_body ";\n"
         | SExpr (ENext _) ->
           Buffer.add_string fn_body "    continue;\n"
         | SExpr e ->
           Buffer.add_string fn_body "    return ";
           emit_expr ctx e;
           Buffer.add_string fn_body ";\n"
         | SLet { name; value; typ; _ } ->
           Buffer.add_string fn_body (Printf.sprintf "    TgVal %s = " (c_ident name));
           emit_expr ctx value;
           Buffer.add_string fn_body ";\n";
           let tname = match typ with
             | Some t -> Resolve.type_name_string_of_typ t
             | None -> expr_type_name ctx value in
           set_var_type ctx name tname;
           Buffer.add_string fn_body "    return TG_NIL;\n"
       end else begin
         Buffer.add_string fn_body "    ";
         emit_stmt_inline ctx s;
         Buffer.add_string fn_body "\n"
       end
     ) stmts
   | EBlock ([SExpr e], _) ->
     Buffer.add_string fn_body "    return ";
     emit_expr ctx e;
     Buffer.add_string fn_body ";\n"
   | _ ->
     Buffer.add_string fn_body "    return ";
     emit_expr ctx body;
     Buffer.add_string fn_body ";\n");
  ctx.buf <- saved_buf;
  Buffer.add_string fn_body "}\n\n";

  ctx.closures <- (cname, Buffer.contents fn_body) :: ctx.closures;

  (* Emit the closure construction at the call site, packing free vars *)
  if free_vars = [] then
    emitf ctx "tg_closure_new(%s, TG_NIL)" cname
  else begin
    let nfv = List.length free_vars in
    if nfv = 1 then begin
      (* Single free var: just pass it directly *)
      emitf ctx "tg_closure_new(%s, %s)" cname (c_ident (List.hd free_vars))
    end else if nfv <= 3 then begin
      emitf ctx "tg_closure_new(%s, tg_tuple_new%d(" cname nfv;
      List.iteri (fun i v ->
        if i > 0 then emit ctx ", ";
        emit ctx (c_ident v)
      ) free_vars;
      emit ctx "))"
    end else begin
      (* For >3 free vars, build a vec *)
      emit ctx "({ TgVal _cv = tg_vec_new(); ";
      List.iter (fun v ->
        emitf ctx "tg_vec_push(_cv, %s); " (c_ident v)
      ) free_vars;
      emitf ctx "tg_closure_new(%s, _cv); })" cname
    end
  end

(* ── Statement codegen ─────────────────────────────────────────────── *)

let rec emit_stmt ctx stmt =
  emit_indent ctx;
  (match stmt with
  | SLet { name; value; typ = _; _ } when String.length name > 13 && String.sub name 0 13 = "_destructure_" ->
    (* Tuple destructuring: let (a, b) = expr → let _tup = expr; let a = tg_tuple_get(_tup, 0); ... *)
    let suffix = String.sub name 13 (String.length name - 13) in
    let parts = String.split_on_char ',' suffix in
    let tmp = fresh_temp ctx in
    emitf ctx "TgVal %s_tup = " tmp;
    emit_expr ctx value;
    emit ctx ";\n";
    List.iteri (fun i part ->
      if part <> "_" then begin
        emit_indent ctx;
        emitf ctx "TgVal %s = tg_tuple_get(%s_tup, %d);\n" (c_ident part) tmp i
      end
    ) parts
  | SLet { name; value; typ; _ } ->
    emitf ctx "TgVal %s = " (c_ident name);
    emit_expr ctx value;
    emit ctx ";\n";
    let tname = match typ with
      | Some t -> Resolve.type_name_string_of_typ t
      | None -> expr_type_name ctx value
    in
    set_var_type ctx name tname

  | SExpr (EIf (branches, else_body, _)) ->
    emit_if_stmt ctx branches else_body

  | SExpr (EWhile (cond, body, _)) ->
    emit ctx "while (";
    emit_expr ctx cond;
    emit ctx ") {\n";
    indent ctx;
    emit_stmts ctx body;
    dedent ctx;
    emit_indent ctx;
    emit ctx "}\n"

  | SExpr (EFor (var, ERange (start, end_, inclusive, _), body, _)) ->
    (* Optimized for-in-range *)
    emitf ctx "for (TgVal %s = " (c_ident var);
    emit_expr ctx start;
    emitf ctx "; %s %s " (c_ident var) (if inclusive then "<=" else "<");
    emit_expr ctx end_;
    emitf ctx "; %s++) {\n" (c_ident var);
    set_var_type ctx var "Int";
    indent ctx;
    emit_stmts ctx body;
    dedent ctx;
    emit_indent ctx;
    emit ctx "}\n"

  | SExpr (EFor (var, iter_expr, body, _)) ->
    (* General for-in: iterate over collection *)
    let tmp = fresh_temp ctx in
    emitf ctx "{ TgVec* %s_v = (TgVec*)tg_as_ptr(" tmp;
    emit_expr ctx iter_expr;
    emitf ctx ");\n";
    emit_indent ctx;
    emitf ctx "  if (%s_v) for (int64_t %s_i = 0; %s_i < %s_v->len; %s_i++) {\n"
      tmp tmp tmp tmp tmp;
    indent ctx;
    emit_indent ctx;
    emitf ctx "TgVal %s = %s_v->data[%s_i];\n" (c_ident var) tmp tmp;
    set_var_type ctx var "";
    (* Handle tuple destructuring in for loops *)
    (let is_destructure = (String.length var > 13 && String.sub var 0 13 = "_destructure_") in
    let has_comma = String.contains var ',' in
    if is_destructure || has_comma then begin
      let suffix = if is_destructure then
        String.sub var 13 (String.length var - 13)
      else var in
      let parts = String.split_on_char ',' suffix in
      List.iteri (fun i part ->
        if part <> "_" then begin
          emit_indent ctx;
          emitf ctx "TgVal %s = tg_tuple_get(%s, %d);\n" (c_ident part) (c_ident var) i
        end
      ) parts
    end);
    emit_stmts ctx body;
    dedent ctx;
    emit_indent ctx;
    emit ctx "  }\n";
    emit_indent ctx;
    emit ctx "}\n"

  | SExpr (ELoop (body, _)) ->
    emit ctx "while (1) {\n";
    indent ctx;
    emit_stmts ctx body;
    dedent ctx;
    emit_indent ctx;
    emit ctx "}\n"

  | SExpr (EMatch (scrutinee, arms, _)) ->
    emit_match_stmt ctx scrutinee arms

  | SExpr (EBlock (body, _)) ->
    emit ctx "{\n";
    indent ctx;
    emit_stmts ctx body;
    dedent ctx;
    emit_indent ctx;
    emit ctx "}\n"

  | SExpr (EReturn (Some e, _)) ->
    emit ctx "return ";
    emit_expr ctx e;
    emit ctx ";\n"

  | SExpr (EReturn (None, _)) ->
    emit ctx "return TG_NIL;\n"

  | SExpr (EBreak (_, _)) ->
    emit ctx "break;\n"

  | SExpr ENext _ ->
    emit ctx "continue;\n"

  | SExpr (EIdent ("continue", _)) ->
    emit ctx "continue;\n"

  | SExpr (EIdent ("break", _)) ->
    emit ctx "break;\n"

  | SExpr (EAssign (lhs, rhs, _)) ->
    emit_assign_expr ctx lhs rhs;
    emit ctx ";\n"

  | SExpr e ->
    emit_expr ctx e;
    emit ctx ";\n")

and emit_stmts ctx stmts =
  List.iter (emit_stmt ctx) stmts

and emit_if_stmt ctx branches else_body =
  let rec emit_branches first = function
    | [] ->
      (match else_body with
       | Some stmts ->
         emit_indent ctx;
         emit ctx "} else {\n";
         indent ctx;
         emit_stmts ctx stmts;
         dedent ctx;
         emit_indent ctx;
         emit ctx "}\n"
       | None ->
         emit_indent ctx;
         emit ctx "}\n")
    | { cond; body } :: rest ->
      if not first then (emit_indent ctx; emit ctx "} else ");
      emit ctx "if (";
      emit_expr ctx cond;
      emit ctx ") {\n";
      indent ctx;
      emit_stmts ctx body;
      dedent ctx;
      emit_branches false rest
  in
  emit_branches true branches

and emit_match_stmt ctx scrutinee arms =
  let tmp = fresh_temp ctx in
  emitf ctx "{ TgVal %s_scrut = " tmp;
  emit_expr ctx scrutinee;
  emit ctx ";\n";
  (* Track scrutinee type for correct enum casts in match arms *)
  let scrut_tname = expr_type_name ctx scrutinee in
  if scrut_tname <> "" then set_var_type ctx (tmp ^ "_scrut") scrut_tname;
  indent ctx;
  List.iter (fun arm ->
    emit_match_arm_stmt ctx tmp arm
  ) arms;
  dedent ctx;
  emit_indent ctx;
  emit ctx "}\n"

and emit_match_arm_stmt ctx tmp arm =
  match arm.pat with
  | PatWild _ ->
    emit_indent ctx;
    emit ctx "{\n";
    indent ctx;
    emit_stmts ctx arm.arm_body;
    dedent ctx;
    emit_indent ctx;
    emit ctx "}\n"

  | PatBind (name, _) when String.contains name ':' ->
    (* Qualified 0-arity variant: EnumName::VariantName *)
    let (enum_hint, vname) = split_qualified_variant name in
    let prefer = if enum_hint <> "" then enum_hint
      else get_var_type ctx (tmp ^ "_scrut") |> Option.value ~default:"" in
    (match Resolve.find_variant_prefer_enum ctx.res vname 0 ~prefer_enum:prefer with
     | Some vi ->
       emit_indent ctx;
       emitf ctx "if (((%s*)tg_as_ptr(%s_scrut))->_tag == %d) {\n"
         (resolve_enum_type ctx vi) tmp vi.vi_tag;
       indent ctx;
       emit_stmts ctx arm.arm_body;
       dedent ctx;
       emit_indent ctx;
       emit ctx "}\n"
     | None ->
       emit_indent ctx;
       emitf ctx "/* unknown 0-arity variant %s */\n" name)

  | PatBind (name, _) ->
    emit_indent ctx;
    emit ctx "{\n";
    indent ctx;
    emit_indent ctx;
    emitf ctx "TgVal %s = %s_scrut;\n" (c_ident name) tmp;
    emit_stmts ctx arm.arm_body;
    dedent ctx;
    emit_indent ctx;
    emit ctx "}\n"

  | PatMut (name, _) ->
    emit_indent ctx;
    emit ctx "{\n";
    indent ctx;
    emit_indent ctx;
    emitf ctx "TgVal %s = %s_scrut;\n" (c_ident name) tmp;
    emit_stmts ctx arm.arm_body;
    dedent ctx;
    emit_indent ctx;
    emit ctx "}\n"

  | PatLit lit ->
    emit_indent ctx;
    emitf ctx "if (%s_scrut == " tmp;
    emit_expr ctx lit;
    emit ctx ") {\n";
    indent ctx;
    emit_stmts ctx arm.arm_body;
    dedent ctx;
    emit_indent ctx;
    emit ctx "}\n"

  | PatVariant (vname_raw, sub_pats, _) ->
    let (enum_hint, vname) = split_qualified_variant vname_raw in
    (* Handle builtin Option/Result variants first *)
    if vname = "Some" then begin
      emit_indent ctx;
      emitf ctx "if (tg_option_is_some(%s_scrut)) {\n" tmp;
      indent ctx;
      let unwrapped = tmp ^ "_unwrapped" in
      emit_indent ctx;
      emitf ctx "TgVal %s = tg_option_unwrap(%s_scrut);\n" unwrapped tmp;
      emit_nested_pattern_bindings_stmt ctx unwrapped sub_pats;
      emit_stmts ctx arm.arm_body;
      dedent ctx;
      emit_indent ctx;
      emit ctx "}\n"
    end else if vname = "None" then begin
      emit_indent ctx;
      emitf ctx "if (tg_option_is_none(%s_scrut)) {\n" tmp;
      indent ctx;
      emit_stmts ctx arm.arm_body;
      dedent ctx;
      emit_indent ctx;
      emit ctx "}\n"
    end else if vname = "Ok" then begin
      emit_indent ctx;
      emitf ctx "if (tg_result_is_ok(%s_scrut)) {\n" tmp;
      indent ctx;
      let unwrapped = tmp ^ "_ok_unwrapped" in
      emit_indent ctx;
      emitf ctx "TgVal %s = tg_result_unwrap(%s_scrut);\n" unwrapped tmp;
      emit_nested_pattern_bindings_stmt ctx unwrapped sub_pats;
      emit_stmts ctx arm.arm_body;
      dedent ctx;
      emit_indent ctx;
      emit ctx "}\n"
    end else if vname = "Err" then begin
      emit_indent ctx;
      emitf ctx "if (tg_result_is_err(%s_scrut)) {\n" tmp;
      indent ctx;
      let unwrapped = tmp ^ "_err_unwrapped" in
      emit_indent ctx;
      emitf ctx "TgVal %s = tg_result_unwrap_err(%s_scrut);\n" unwrapped tmp;
      emit_nested_pattern_bindings_stmt ctx unwrapped sub_pats;
      emit_stmts ctx arm.arm_body;
      dedent ctx;
      emit_indent ctx;
      emit ctx "}\n"
    end else begin
    (* Regular enum variant — use arity-based lookup, preferring qualifier or scrutinee type *)
    let scrut_type = get_var_type ctx (tmp ^ "_scrut") |> Option.value ~default:"" in
    let prefer = if enum_hint <> "" then enum_hint else scrut_type in
    (match Resolve.find_variant_prefer_enum ctx.res vname (List.length sub_pats) ~prefer_enum:prefer with
     | Some vi ->
       emit_indent ctx;
       emitf ctx "if (((%s*)tg_as_ptr(%s_scrut))->_tag == %d) {\n"
         (resolve_enum_type ctx vi) tmp vi.vi_tag;
       indent ctx;
       List.iteri (fun i sub ->
         match sub with
         | PatBind (n, _) ->
           emit_indent ctx;
           emitf ctx "TgVal %s = ((%s*)tg_as_ptr(%s_scrut))->_f%d;\n"
             (c_ident n) (resolve_enum_type ctx vi) tmp i;
           if i < List.length vi.vi_fields then begin
             let ft = Resolve.type_name_string_of_typ (List.nth vi.vi_fields i) in
             if ft <> "" then set_var_type ctx n ft
           end
         | PatMut (n, _) ->
           emit_indent ctx;
           emitf ctx "TgVal %s = ((%s*)tg_as_ptr(%s_scrut))->_f%d;\n"
             (c_ident n) (resolve_enum_type ctx vi) tmp i
         | PatWild _ -> ()
         | PatVariant (inner_vname, inner_sub, _) ->
           let field_var = Printf.sprintf "_nested_%d" i in
           emit_indent ctx;
           emitf ctx "TgVal %s = ((%s*)tg_as_ptr(%s_scrut))->_f%d;\n"
             field_var (resolve_enum_type ctx vi) tmp i;
           (match Resolve.find_variant_by_arity ctx.res inner_vname (List.length inner_sub) with
            | Some ivi ->
              List.iteri (fun j sub2 ->
                match sub2 with
                | PatBind (n, _) ->
                  emit_indent ctx;
                  emitf ctx "TgVal %s = ((%s*)tg_as_ptr(%s))->_f%d;\n"
                    (c_ident n) (resolve_enum_type ctx ivi) field_var j
                | _ -> ()
              ) inner_sub
            | None ->
              List.iteri (fun _j sub2 ->
                match sub2 with
                | PatBind (n, _) ->
                  emit_indent ctx;
                  emitf ctx "TgVal %s = %s;\n" (c_ident n) field_var
                | _ -> ()
              ) inner_sub)
         | PatLit lit ->
           emit_indent ctx;
           emitf ctx "if (((%s*)tg_as_ptr(%s_scrut))->_f%d != "
             (resolve_enum_type ctx vi) tmp i;
           emit_expr ctx lit;
           emit ctx ") goto _next_arm;\n"
         | _ -> ()
       ) sub_pats;
       emit_stmts ctx arm.arm_body;
       dedent ctx;
       emit_indent ctx;
       emit ctx "}\n"
     | None ->
       emit_indent ctx;
       emitf ctx "/* unknown variant %s */\n" vname)
    end

  | PatStruct (sname, field_pats, _) ->
    (* Check if sname is actually an enum variant with named fields *)
    if Resolve.is_variant ctx.res sname then begin
      match Resolve.find_variant ctx.res sname with
      | Some vi ->
        let tag_val = Printf.sprintf "%s_%s__new" (resolve_enum_type ctx vi) (c_ident sname) in
        emit_indent ctx;
        emitf ctx "if ((((%s*)tg_as_ptr(%s_scrut))->_tag) == (TgVal)(intptr_t)%s) {\n"
          (resolve_enum_type ctx vi) tmp tag_val;
        indent ctx;
        emit_indent ctx;
        emitf ctx "%s* _ps = (%s*)tg_as_ptr(%s_scrut);\n"
          (resolve_enum_type ctx vi) (resolve_enum_type ctx vi) tmp;
        List.iteri (fun i (fname, pat_opt) ->
          let _ = fname in
          emit_indent ctx;
          match pat_opt with
          | Some (PatBind (n, _)) ->
            emitf ctx "TgVal %s = _ps->_f%d;\n" (c_ident n) i
          | None ->
            emitf ctx "TgVal %s = _ps->_f%d;\n" (c_ident fname) i
          | _ -> ()
        ) field_pats;
        emit_stmts ctx arm.arm_body;
        dedent ctx;
        emit_indent ctx;
        emit ctx "}\n"
      | None ->
        emit_indent ctx;
        emit ctx "{\n";
        indent ctx;
        emit_indent ctx;
        emitf ctx "%s* _ps = (%s*)tg_as_ptr(%s_scrut);\n"
          (resolve_type ctx sname) (resolve_type ctx sname) tmp;
        List.iter (fun (fname, pat_opt) ->
          emit_indent ctx;
          match pat_opt with
          | Some (PatBind (n, _)) ->
            emitf ctx "TgVal %s = _ps->%s;\n" (c_ident n) (c_ident fname)
          | None ->
            emitf ctx "TgVal %s = _ps->%s;\n" (c_ident fname) (c_ident fname)
          | _ -> ()
        ) field_pats;
        emit_stmts ctx arm.arm_body;
        dedent ctx;
        emit_indent ctx;
        emit ctx "}\n"
    end else begin
      emit_indent ctx;
      emit ctx "{\n";
      indent ctx;
      emit_indent ctx;
      emitf ctx "%s* _ps = (%s*)tg_as_ptr(%s_scrut);\n"
        (resolve_type ctx sname) (resolve_type ctx sname) tmp;
      List.iter (fun (fname, pat_opt) ->
        emit_indent ctx;
        match pat_opt with
        | Some (PatBind (n, _)) ->
          emitf ctx "TgVal %s = _ps->%s;\n" (c_ident n) (c_ident fname)
        | None ->
          emitf ctx "TgVal %s = _ps->%s;\n" (c_ident fname) (c_ident fname)
        | _ -> ()
      ) field_pats;
      emit_stmts ctx arm.arm_body;
      dedent ctx;
      emit_indent ctx;
      emit ctx "}\n"
    end

  | PatTuple (pats, _) ->
    emit_indent ctx;
    emit ctx "{\n";
    indent ctx;
    List.iteri (fun i sub ->
      match sub with
      | PatBind (n, _) when String.contains n ':' ->
        (* Qualified 0-arity variant in tuple, e.g. Type::Unit — skip binding *)
        ()
      | PatBind (n, _) when Resolve.is_variant ctx.res n ->
        (* 0-arity variant in tuple — just skip *)
        ()
      | PatBind (n, _) ->
        emit_indent ctx;
        emitf ctx "TgVal %s = tg_tuple_get(%s_scrut, %d);\n" (c_ident n) tmp i
      | PatMut (n, _) ->
        emit_indent ctx;
        emitf ctx "TgVal %s = tg_tuple_get(%s_scrut, %d);\n" (c_ident n) tmp i
      | PatWild _ -> ()
      | PatVariant (vname, inner_pats, _) ->
        let elem_var = Printf.sprintf "_tup_%d" i in
        emit_indent ctx;
        emitf ctx "TgVal %s = tg_tuple_get(%s_scrut, %d);\n" elem_var tmp i;
        (if vname = "Some" then begin
          match inner_pats with
          | [PatBind (n, _)] ->
            emit_indent ctx;
            emitf ctx "TgVal %s = tg_option_unwrap(%s);\n" (c_ident n) elem_var
          | _ -> ()
        end else
          match Resolve.find_variant_by_arity ctx.res vname (List.length inner_pats) with
          | Some vi ->
            List.iteri (fun j sub2 ->
              match sub2 with
              | PatBind (n, _) ->
                emit_indent ctx;
                emitf ctx "TgVal %s = ((%s*)tg_as_ptr(%s))->_f%d;\n"
                  (c_ident n) (resolve_enum_type ctx vi) elem_var j
              | _ -> ()
            ) inner_pats
          | None ->
            List.iteri (fun _j sub2 ->
              match sub2 with
              | PatBind (n, _) ->
                emit_indent ctx;
                emitf ctx "TgVal %s = %s;\n" (c_ident n) elem_var
              | _ -> ()
            ) inner_pats)
      | _ -> ()
    ) pats;
    emit_stmts ctx arm.arm_body;
    dedent ctx;
    emit_indent ctx;
    emit ctx "}\n"

  | PatOr (p1, p2, _) ->
    emit_match_arm_stmt ctx tmp { arm with pat = p1 };
    emit_match_arm_stmt ctx tmp { arm with pat = p2 }

(* ── Top-level item codegen ────────────────────────────────────────── *)

let emit_function_def ctx name params _ret body ~is_method ~self_type_name =
  let old_self = ctx.self_type in
  if self_type_name <> "" then ctx.self_type <- self_type_name;
  let old_vars = ctx.var_types in

  (* Function signature *)
  let c_name = if is_method then
    c_method_name self_type_name name
  else if name = "main" && ctx.current_module = "driver" then
    "tg_main"
  else
    (* Use module-prefixed name to avoid cross-module conflicts *)
    let mangled = Resolve.mangle_name ctx.current_module name in
    Resolve.sanitize_ident mangled in

  let param_list = ref [] in
  if is_method then begin
    (* Check if first param is self *)
    match params with
    | p :: rest when p.p_name = "self" ->
      param_list := "TgVal _self" :: !param_list;
      set_var_type ctx "self" self_type_name;
      List.iter (fun p2 ->
        param_list := (Printf.sprintf "TgVal %s" (c_ident p2.p_name)) :: !param_list;
        let tname = Resolve.type_name_string_of_typ p2.p_typ in
        set_var_type ctx p2.p_name tname
      ) rest
    | _ ->
      (* No explicit self param — static/associated function, no _self *)
      List.iter (fun p2 ->
        param_list := (Printf.sprintf "TgVal %s" (c_ident p2.p_name)) :: !param_list;
        let tname = Resolve.type_name_string_of_typ p2.p_typ in
        set_var_type ctx p2.p_name tname
      ) params
  end else begin
    List.iter (fun p ->
      param_list := (Printf.sprintf "TgVal %s" (c_ident p.p_name)) :: !param_list;
      let tname = Resolve.type_name_string_of_typ p.p_typ in
      set_var_type ctx p.p_name tname
    ) params
  end;

  let params_str = if !param_list = [] then "void"
    else String.concat ", " (List.rev !param_list) in

  (* Forward declaration *)
  Buffer.add_string ctx.decl_buf
    (Printf.sprintf "TgVal %s(%s);\n" c_name params_str);

  (* Function definition *)
  emitfn ctx "TgVal %s(%s) {" c_name params_str;
  indent ctx;
  emit_stmts ctx body;
  (* Default return *)
  emit_indent ctx;
  emitfn ctx "return TG_NIL;";
  dedent ctx;
  emitfn ctx "}";
  nl ctx;

  ctx.self_type <- old_self;
  ctx.var_types <- old_vars

let rec emit_item ctx item =
  match item with
  | IFn { name; params; ret; body; _ } ->
    emit_function_def ctx name params ret body
      ~is_method:false ~self_type_name:""

  | IStruct { name; fields; _ } ->
    emit_struct_def ctx name fields

  | IEnum { name; variants; _ } ->
    emit_enum_def ctx name variants

  | ITrait { name; items = trait_items; _ } ->
    (* Emit trait as comments — the methods are emitted via impl blocks *)
    emitfn ctx "/* trait %s */" name;
    (* Emit default method implementations if any have bodies *)
    List.iter (fun ti ->
      match ti with
      | IFn { name = mname; params; ret; body; _ } when body <> [] ->
        emitfn ctx "/* default method %s::%s */" name mname;
        emit_function_def ctx mname params ret body
          ~is_method:true ~self_type_name:name
      | _ -> ()
    ) trait_items

  | IImpl { target; trait_; methods; _ } ->
    let tname = Resolve.target_name_of_typ target in
    emitfn ctx "/* impl %s%s */"
      (match trait_ with Some t -> t ^ " for " | None -> "")
      tname;
    List.iter (fun m ->
      match m with
      | IFn { name; params; ret; body; _ } ->
        emit_function_def ctx name params ret body
          ~is_method:true ~self_type_name:tname
      | _ -> ()
    ) methods

  | IConst { name; value; _ } ->
    let cname = if ctx.current_module <> "" then
      c_ident (ctx.current_module ^ "__" ^ name)
    else c_ident name in
    emitf ctx "static TgVal %s = " cname;
    (match value with
     | EInt (v, _) -> emitf ctx "%dLL" v
     | EFloat (f, _) -> emitf ctx "0 /* %g */" f
     | EStr (s, _) -> emitf ctx "0 /* \"%s\" */" (c_string_escape s)
     | EBool (true, _) -> emit ctx "1"
     | EBool (false, _) -> emit ctx "0"
     | _ -> emit ctx "0");
    emitn ctx ";"

  | ITypeAlias { name; typ; _ } ->
    emitfn ctx "/* type %s = %s */" name
      (match typ with TyName (n, _) -> n | _ -> "?")

  | IExtern { sigs; _ } ->
    List.iter (fun sig_ ->
      let params = List.map (fun p ->
        Printf.sprintf "TgVal %s" (c_ident p.p_name)
      ) sig_.fs_params in
      let ps = if params = [] then "void" else String.concat ", " params in
      emitfn ctx "/* extern */ TgVal %s(%s);" (c_ident sig_.fs_name) ps
    ) sigs

  | IModule { name; items; _ } ->
    emitfn ctx "/* module %s */" name;
    List.iter (emit_item ctx) items

  | IUse _ -> ()  (* resolved at linking time *)

(* ── Main entry: compile resolved program to C ─────────────────────── *)

let compile_to_c (res : Resolve.resolved) ~has_main : string =
  let ctx = {
    buf = Buffer.create (256 * 1024);
    decl_buf = Buffer.create (16 * 1024);
    indent = 0;
    temp_cnt = 0;
    closure_cnt = 0;
    closures = [];
    var_types = [];
    self_type = "";
    current_module = "";
    type_map = Hashtbl.create 256;
    res;
  } in

  (* Preamble *)
  emitn ctx "/* Generated by Tangerine stage0 C transpiler */";
  emitn ctx "/* This file is auto-generated — do not edit */";
  nl ctx;
  emitn ctx "#include <stdint.h>";
  emitn ctx "#include <stdbool.h>";
  emitn ctx "#include <string.h>";
  emitn ctx "#include <ctype.h>";
  emitn ctx "#include <math.h>";
  emitn ctx "#include \"tg_runtime.h\"";
  nl ctx;

  (* Builtin stubs for common Tangerine functions not in the runtime *)
  emitn ctx "/* -- Builtin stubs -- */";
  emitn ctx "static TgVal tg_int_pow(TgVal base, TgVal exp) { TgVal r=1; for(TgVal i=0;i<exp;i++) r*=base; return r; }";
  nl ctx;

  (* External/stdlib function stubs *)
  emitn ctx "/* -- External function stubs -- */";
  emitn ctx "static TgVal read_file(TgVal path) { return tg_str_from_cstr(\"/* read_file stub */\"); }";
  emitn ctx "static TgVal write_file(TgVal path, TgVal content) { (void)path; (void)content; return TG_NIL; }";
  emitn ctx "static TgVal read_to_string(TgVal path) { return tg_str_from_cstr(\"\"); }";
  emitn ctx "static TgVal create_dir_all(TgVal path) { (void)path; return TG_NIL; }";
  emitn ctx "static TgVal path_exists(TgVal path) { (void)path; return TG_FALSE; }";
  emitn ctx "static TgVal run_command(TgVal cmd, TgVal args) { (void)cmd; (void)args; return ((TgVal)0); }";
  emitn ctx "static TgVal tokenize(TgVal src) { (void)src; return tg_vec_new(); }";
  emitn ctx "static TgVal get_env(TgVal name) { (void)name; return tg_str_from_cstr(\"\"); }";
  emitn ctx "static TgVal current_dir(void) { return tg_str_from_cstr(\".\"); }";
  emitn ctx "static TgVal exit_process(TgVal code) { exit((int)code); return TG_NIL; }";
  emitn ctx "static TgVal write_string(TgVal path, TgVal content) { (void)path; (void)content; return TG_NIL; }";
  emitn ctx "static TgVal mkdir_p(TgVal path) { (void)path; return TG_NIL; }";
  emitn ctx "static TgVal __read_dir(TgVal path) { (void)path; return tg_vec_new(); }";
  emitn ctx "static TgVal __home_dir(void) { return tg_str_from_cstr(\"/tmp\"); }";
  emitn ctx "static TgVal __get(TgVal url) { (void)url; return tg_str_from_cstr(\"\"); }";
  emitn ctx "static TgVal __get_env(TgVal name) { (void)name; return tg_str_from_cstr(\"\"); }";
  emitn ctx "static TgVal __parse(TgVal src) { (void)src; return TG_NIL; }";
  emitn ctx "static TgVal __run(TgVal cmd, TgVal args) { (void)cmd; (void)args; return TG_NIL; }";
  emitn ctx "static TgVal __create_dir(TgVal path) { (void)path; return TG_NIL; }";
  emitn ctx "static TgVal __create_dir_all(TgVal path) { (void)path; return TG_NIL; }";
  emitn ctx "static TgVal list_directory(TgVal path) { (void)path; return tg_vec_new(); }";
  emitn ctx "static TgVal read_dir(TgVal path) { (void)path; return tg_vec_new(); }";
  emitn ctx "static TgVal write_file_bytes(TgVal path, TgVal data) { (void)path; (void)data; return TG_NIL; }";
  emitn ctx "static TgVal write_file_string(TgVal path, TgVal data) { (void)path; (void)data; return TG_NIL; }";
  emitn ctx "static TgVal read_file_string(TgVal path) { (void)path; return tg_str_from_cstr(\"\"); }";
  emitn ctx "static TgVal dir_exists(TgVal path) { (void)path; return TG_FALSE; }";
  emitn ctx "static TgVal file_exists(TgVal path) { (void)path; return TG_FALSE; }";
  emitn ctx "static TgVal delete_file(TgVal path) { (void)path; return TG_NIL; }";
  emitn ctx "static TgVal remove_file(TgVal path) { (void)path; return TG_NIL; }";
  emitn ctx "static TgVal home_dir(void) { return tg_str_from_cstr(\"/tmp\"); }";
  emitn ctx "static TgVal args(void) { return tg_vec_new(); }";
  emitn ctx "static TgVal time(TgVal a) { (void)a; return ((TgVal)0); }";
  emitn ctx "static TgVal fnv1a_hash(TgVal data) { (void)data; return ((TgVal)0); }";
  emitn ctx "static TgVal which(TgVal cmd) { (void)cmd; return tg_option_none(); }";
  emitn ctx "static TgVal syscall_write(TgVal fd, TgVal data, TgVal len) { (void)fd; (void)data; (void)len; return TG_NIL; }";
  emitn ctx "static TgVal tg_map_contains(TgVal map, TgVal key) { (void)map; (void)key; return TG_FALSE; }";
  emitn ctx "static TgVal from_u32(TgVal val) { (void)val; return val; }";
  emitn ctx "static TgVal from_bits(TgVal val) { (void)val; return val; }";
  emitn ctx "static TgVal filled(TgVal val, TgVal count) { (void)val; (void)count; return tg_vec_new(); }";
  emitn ctx "static TgVal println(TgVal msg, ...) { tg_println(msg); return TG_NIL; }";
  emitn ctx "static TgVal new(TgVal a, TgVal b, TgVal c) { (void)a; (void)b; (void)c; return TG_NIL; }";
  emitn ctx "static TgVal is_callee_saved(TgVal reg) { (void)reg; return TG_FALSE; }";
  emitn ctx "static TgVal format_type_expr_to_string(TgVal expr) { (void)expr; return tg_str_from_cstr(\"\"); }";
  emitn ctx "static TgVal generate_docs(TgVal a, TgVal b) { (void)a; (void)b; return TG_NIL; }";
  emitn ctx "static TgVal default_doc_config(void) { return TG_NIL; }";
  emitn ctx "static TgVal parse_test_args(TgVal args) { (void)args; return TG_NIL; }";
  emitn ctx "static TgVal parse_bench_args(TgVal args) { (void)args; return TG_NIL; }";
  emitn ctx "static TgVal run_tests(TgVal suite, TgVal config) { (void)suite; (void)config; return TG_NIL; }";
  emitn ctx "static TgVal run_benchmarks(TgVal suite, TgVal config) { (void)suite; (void)config; return TG_NIL; }";
  emitn ctx "static TgVal test_suite_new(void) { return TG_NIL; }";
  emitn ctx "static TgVal bench_suite_new(void) { return TG_NIL; }";
  emitn ctx "static TgVal bench_case_new(TgVal name, TgVal fn) { (void)name; (void)fn; return TG_NIL; }";
  emitn ctx "static TgVal substitute_operand(TgVal a, TgVal b) { (void)a; (void)b; return TG_NIL; }";
  emitn ctx "static TgVal substitute_place(TgVal a, TgVal b) { (void)a; (void)b; return TG_NIL; }";
  nl ctx;

  (* Generic clone/to_string stub using identity/placeholder *)
  emitn ctx "/* -- Generic method stubs -- */";
  emitn ctx "static TgVal _generic_clone(TgVal v) { return v; }";
  emitn ctx "static TgVal _generic_to_string(TgVal v) { return tg_int_to_string(v); }";
  emitn ctx "/* -- Missing string method stubs -- */";
  emitn ctx "static TgVal tg_str_join(TgVal vec, TgVal sep) { (void)sep; return tg_str_concat(tg_str_from_cstr(\"\"), vec); }";
  emitn ctx "static TgVal tg_str_parse_int(TgVal s) { return tg_str_parse_float(s); }";
  emitn ctx "static TgVal tg_str_is_lowercase(TgVal s) { (void)s; return TG_FALSE; }";
  emitn ctx "static TgVal tg_str_is_uppercase(TgVal s) { (void)s; return TG_FALSE; }";
  emitn ctx "/* -- Format/intrinsic stubs -- */";
  emitn ctx "static TgVal __intrinsic_pow(TgVal a, TgVal b) { (void)a; (void)b; return ((TgVal)0); }";
  emitn ctx "static TgVal __intrinsic_exp(TgVal a) { (void)a; return ((TgVal)0); }";
  emitn ctx "static TgVal __intrinsic_int_to_float(TgVal v) { return v; }";
  emitn ctx "static TgVal __intrinsic_float_to_int(TgVal v) { return v; }";
  emitn ctx "/* -- Architecture stubs -- */";
  emitn ctx "static TgVal a64_add_imm(TgVal a, TgVal b, TgVal c, TgVal d) { (void)a;(void)b;(void)c;(void)d; return TG_NIL; }";
  emitn ctx "static TgVal a64_sub_imm(TgVal a, TgVal b, TgVal c, TgVal d) { (void)a;(void)b;(void)c;(void)d; return TG_NIL; }";
  emitn ctx "static TgVal a64_and_ri(TgVal a, TgVal b, TgVal c) { (void)a;(void)b;(void)c; return TG_NIL; }";
  emitn ctx "static TgVal a64_mov_w(TgVal a, TgVal b, TgVal c) { (void)a;(void)b;(void)c; return TG_NIL; }";
  emitn ctx "static TgVal a64_sxtw(TgVal a, TgVal b, TgVal c) { (void)a;(void)b;(void)c; return TG_NIL; }";
  emitn ctx "static TgVal x64_and_ri(TgVal a, TgVal b, TgVal c) { (void)a;(void)b;(void)c; return TG_NIL; }";
  emitn ctx "static TgVal x64_mov_r32(TgVal a, TgVal b, TgVal c) { (void)a;(void)b;(void)c; return TG_NIL; }";
  emitn ctx "static TgVal x64_movsxd(TgVal a, TgVal b, TgVal c) { (void)a;(void)b;(void)c; return TG_NIL; }";
  nl ctx;

  (* Placeholder for forward declarations — will be inserted later *)
  let fwd_marker = "/* __FORWARD_DECLARATIONS__ */" in
  emitn ctx fwd_marker;
  nl ctx;

  (* Emit all items from all modules *)
  (* First pass: collect struct/enum definitions, tagged with module *)
  let struct_enums = ref [] in
  let functions = ref [] in
  let other_items = ref [] in

  List.iter (fun (mod_info : Resolve.module_info) ->
    let mname = mod_info.mod_name in
    let rec collect_items items =
      List.iter (fun item ->
        match item with
        | IStruct _ | IEnum _ -> struct_enums := (mname, item) :: !struct_enums
        | IFn _ | IImpl _ -> functions := (mname, item) :: !functions
        | IModule { items = sub; _ } -> collect_items sub
        | _ -> other_items := (mname, item) :: !other_items
      ) items
    in
    collect_items mod_info.mod_items
  ) res.modules;

  (* Emit struct/enum definitions first *)
  List.iter (fun (mname, item) ->
    ctx.current_module <- mname;
    emit_item ctx item
  ) (List.rev !struct_enums);

  (* Emit other items (consts, type aliases, etc.) *)
  List.iter (fun (mname, item) ->
    ctx.current_module <- mname;
    emit_item ctx item
  ) (List.rev !other_items);

  (* Insert marker for remaining closures — AFTER struct/enum defs *)
  let closure_marker = "/* __CLOSURE_INSERTION_POINT__ */" in
  emitn ctx closure_marker;

  (* Emit closures collected so far *)
  List.iter (fun (_, code) ->
    emit ctx code
  ) ctx.closures;
  ctx.closures <- [];

  (* Emit functions and impl methods *)
  List.iter (fun (mname, item) ->
    ctx.current_module <- mname;
    emit_item ctx item
  ) (List.rev !functions);

  (* Emit any remaining closures *)
  let remaining_closures = ctx.closures in

  (* Emit stubs for known undefined functions from unparsed/trait modules *)
  nl ctx;
  emitn ctx "/* ── Stubs for undefined functions ─────────────────── */";
  let emit_stub name params =
    let param_str = if params = 0 then "void"
      else String.concat ", " (List.init params (fun i -> Printf.sprintf "TgVal _%d" i)) in
    (* Forward declaration *)
    Buffer.add_string ctx.decl_buf (Printf.sprintf "TgVal %s(%s);\n" name param_str);
    (* Definition *)
    emitfn ctx "TgVal %s(%s) { return TG_NIL; }" name param_str
  in
  (* 0-arg stubs *)
  List.iter (fun name -> emit_stub name 0) ["A64__X29"; "A64__X30"];
  (* 1-arg stubs *)
  List.iter (fun name -> emit_stub name 1)
    ["Box__name"; "Box__version";
     "LocalRegistry__into_bytes"; "LocalRegistry__ok";
     "TypeExpr__Tuple"; "types__Struct"];
  (* 2-arg stubs *)
  List.iter (fun name -> emit_stub name 2)
    ["TypeEnv__lookup"; "HttpRegistry__ok_or"; "PluginRegistry__pre_parse";
     "PluginRegistry__post_parse"; "PkgManager__resolve"; "Requirement__matches";
     "ScopeMap__scopes_containing"; "SymbolGraph__query_all_references";
     "TypeExpr__Named"; "types__Enum"; "Box__fetch_versions";
     "BuildPlan__filter_map"; "LocalRegistry__filter_map"];
  (* 3-arg stubs *)
  List.iter (fun name -> emit_stub name 3)
    ["LintRunner__check_item"; "LintRunner__check_function";
     "LintRunner__check_stmt"; "LintRunner__check_expr";
     "Box__fetch_package"];
  nl ctx;

  (* Generate main function *)
  if has_main then begin
    nl ctx;
    emitn ctx "int main(int argc, char** argv) {";
    indent ctx;
    emit_indent ctx;
    emitn ctx "tg_init(argc, argv);";
    (* Call the Tangerine main function *)
    emit_indent ctx;
    emitn ctx "TgVal _exit_code = tg_main();";
    emit_indent ctx;
    emitn ctx "return (int)_exit_code;";
    dedent ctx;
    emitn ctx "}";
  end;

  (* Assemble final output *)
  let body = Buffer.contents ctx.buf in
  let decls = Buffer.contents ctx.decl_buf in

  (* Collect remaining closures *)
  let closure_code = Buffer.create 4096 in
  List.iter (fun (_, code) ->
    Buffer.add_string closure_code code
  ) remaining_closures;

  (* First: insert forward declarations at the fwd marker *)
  let fwd_marker_len = String.length fwd_marker in
  let body_len = String.length body in
  let rec find_marker_pos marker marker_len s len i =
    if i > len - marker_len then None
    else if String.sub s i marker_len = marker then Some i
    else find_marker_pos marker marker_len s len (i + 1)
  in
  let body_with_fwd =
    match find_marker_pos fwd_marker fwd_marker_len body body_len 0 with
    | Some pos ->
      let before = String.sub body 0 pos in
      let after = String.sub body (pos + fwd_marker_len) (body_len - pos - fwd_marker_len) in
      before ^ "/* Forward declarations */\n" ^ decls ^ "\n" ^ after
    | None -> decls ^ "\n" ^ body
  in
  (* Then: insert remaining closures at the closure marker *)
  let closure_marker_len = String.length closure_marker in
  let bwf_len = String.length body_with_fwd in
  match find_marker_pos closure_marker closure_marker_len body_with_fwd bwf_len 0 with
  | Some pos ->
    let before = String.sub body_with_fwd 0 pos in
    let after = String.sub body_with_fwd (pos + closure_marker_len + 1) (bwf_len - pos - closure_marker_len - 1) in
    before ^ Buffer.contents closure_code ^ after
  | None ->
    body_with_fwd ^ "\n" ^ Buffer.contents closure_code

(* ── Public API ────────────────────────────────────────────────────── *)

let compile_program_to_c (file_programs : (string * Ast.program) list) ~has_main =
  let res = Resolve.resolve_files file_programs in
  compile_to_c res ~has_main
