(* Tangerine Name Resolution – stage0
   Multi-file module resolution, symbol tables, type tracking.
   Used by the C code generator for cross-module compilation. *)

open Ast

(* ── Symbol kinds ──────────────────────────────────────────────────── *)

type sym_kind =
  | SkStruct of field_def list
  | SkEnum of variant_def list
  | SkFunction of param list * typ option
  | SkTrait of fn_sig list
  | SkMethod of string * param list * typ option  (* type_name, params, ret *)
  | SkConst
  | SkTypeAlias of typ
  | SkModule

type symbol = {
  sym_name : string;
  sym_module : string;
  sym_kind : sym_kind;
  sym_mangled : string;
}

(* ── Module info ───────────────────────────────────────────────────── *)

type module_info = {
  mod_name : string;
  mod_file : string;
  mod_items : item list;
}

(* ── Impl info ─────────────────────────────────────────────────────── *)

type impl_info = {
  imp_target : string;
  imp_trait : string option;
  imp_methods : item list;
}

(* ── Variant info ──────────────────────────────────────────────────── *)

type variant_info = {
  vi_enum : string;
  vi_module : string;
  vi_name : string;
  vi_tag : int;
  vi_fields : typ list;
}

(* ── Type tracking for codegen ─────────────────────────────────────── *)

type type_info =
  | TiPrimitive of string  (* "Int", "UInt", "Float", "Bool", "Char", "String" *)
  | TiStruct of string
  | TiEnum of string
  | TiVec
  | TiMap
  | TiSet
  | TiOption
  | TiResult
  | TiBox
  | TiClosure
  | TiUnknown

(* ── Resolved program ─────────────────────────────────────────────── *)

type resolved = {
  modules : module_info list;
  symbols : (string, symbol) Hashtbl.t;    (* simple name → symbol *)
  qualified : (string, symbol) Hashtbl.t;  (* mangled name → symbol *)
  impls : impl_info list;
  variants : (string, variant_info) Hashtbl.t;
  method_map : (string, symbol) Hashtbl.t;  (* "Type.method" → symbol *)
  all_items : item list;
}

(* ── Mangling ──────────────────────────────────────────────────────── *)

let mangle_name modname name =
  if modname = "" then name
  else modname ^ "__" ^ name

let mangle_method typename methname =
  typename ^ "__" ^ methname

let sanitize_ident s =
  let buf = Buffer.create (String.length s) in
  String.iter (fun c ->
    match c with
    | 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' -> Buffer.add_char buf c
    | ':' -> Buffer.add_string buf "_c"
    | '.' -> Buffer.add_string buf "_d"
    | '/' -> Buffer.add_string buf "_s"
    | '-' -> Buffer.add_string buf "_h"
    | _ -> Buffer.add_char buf '_'
  ) s;
  let result = Buffer.contents buf in
  (* Avoid C keywords *)
  match result with
  | "auto" | "break" | "case" | "char" | "const" | "continue"
  | "default" | "do" | "double" | "else" | "enum" | "extern"
  | "float" | "for" | "goto" | "if" | "int" | "long"
  | "register" | "return" | "short" | "signed" | "sizeof" | "static"
  | "struct" | "switch" | "typedef" | "union" | "unsigned" | "void"
  | "volatile" | "while" | "inline" | "restrict"
  | "system" | "next" -> result ^ "_"
  | _ -> result

(* ── Extract type name from AST typ ────────────────────────────────── *)

let rec type_name_of_typ = function
  | TyName ("Vec", _) -> TiVec
  | TyName ("Map", _) -> TiMap
  | TyName ("Set", _) -> TiSet
  | TyName ("Option", [t]) -> type_name_of_typ (TyOption t)
  | TyName ("Result", _) -> TiResult
  | TyName ("Box", _) -> TiBox
  | TyName ("String", []) -> TiPrimitive "String"
  | TyName ("Int", []) | TyName ("i64", []) | TyName ("i32", [])
  | TyName ("i16", []) | TyName ("i8", []) -> TiPrimitive "Int"
  | TyName ("UInt", []) | TyName ("u64", []) | TyName ("u32", [])
  | TyName ("u16", []) | TyName ("u8", []) -> TiPrimitive "UInt"
  | TyName ("Float", []) | TyName ("f64", []) | TyName ("f32", []) -> TiPrimitive "Float"
  | TyName ("Bool", []) -> TiPrimitive "Bool"
  | TyName ("Char", []) -> TiPrimitive "Char"
  | TyName (name, _) -> TiStruct name  (* default: assume struct *)
  | TyArray _ -> TiVec
  | TyRef (_, inner) -> type_name_of_typ inner
  | TySelf -> TiUnknown
  | TyOption _ -> TiOption
  | TyTuple _ -> TiPrimitive "Tuple"
  | TyFn _ -> TiClosure
  | TyInfer -> TiUnknown

let rec type_name_string_of_typ = function
  | TyName (name, _) -> name
  | TyRef (_, TyName (name, _)) -> name
  | TyRef (_, inner) -> type_name_string_of_typ inner
  | TyArray _ -> "Array"
  | TySelf -> "Self"
  | TyOption _ -> "Option"
  | TyTuple _ -> "Tuple"
  | TyFn _ -> "Fn"
  | TyInfer -> ""

(* Extract element type name from a Vec/Array type *)
let vec_element_type_string fields field_name =
  try
    let f = List.find (fun fd -> fd.fd_name = field_name) fields in
    match f.fd_typ with
    | TyName (("Vec" | "Array"), [TyName (elem, _)])
    | TyName (("Vec" | "Array"), [TyRef (_, TyName (elem, _))]) -> elem
    | TyRef (_, TyName (("Vec" | "Array"), [TyName (elem, _)])) -> elem
    | TyRef (_, TyName (("Vec" | "Array"), [TyRef (_, TyName (elem, _))])) -> elem
    | TyArray (TyName (elem, _), _)
    | TyArray (TyRef (_, TyName (elem, _)), _) -> elem
    | TyRef (_, TyArray (TyName (elem, _), _)) -> elem
    | _ -> ""
  with Not_found -> ""

(* Extract Option/Result inner type name from a struct field *)
let option_inner_type_string fields field_name =
  try
    let f = List.find (fun fd -> fd.fd_name = field_name) fields in
    match f.fd_typ with
    | TyOption (TyName (inner, _))
    | TyOption (TyRef (_, TyName (inner, _))) -> inner
    | TyName ("Option", [TyName (inner, _)])
    | TyName ("Option", [TyRef (_, TyName (inner, _))]) -> inner
    | TyRef (_, TyOption (TyName (inner, _)))
    | TyRef (_, TyName ("Option", [TyName (inner, _)])) -> inner
    | _ -> ""
  with Not_found -> ""

(* ── Extract target type name from impl ────────────────────────────── *)

let target_name_of_typ = function
  | TyName (n, _) -> n
  | TyArray _ -> "Array"
  | TySelf -> "Self"
  | _ -> "Unknown"

(* ── Parse module path from use statement ──────────────────────────── *)

let module_from_path path =
  match path with
  | [] -> ""
  | [x] -> x
  | _ ->
    let last = List.nth path (List.length path - 1) in
    let prefix = List.filteri (fun i _ -> i < List.length path - 1) path in
    String.concat "_" prefix ^ "__" ^ last

(* ── Infer module name from filename ───────────────────────────────── *)

let module_name_from_file file =
  let base = Filename.basename file in
  let name = Filename.remove_extension base in
  sanitize_ident name

(* ── Build resolved program ────────────────────────────────────────── *)

let resolve_files (file_programs : (string * program) list) : resolved =
  let symbols = Hashtbl.create 256 in
  let qualified = Hashtbl.create 256 in
  let variant_tbl = Hashtbl.create 256 in
  let method_map = Hashtbl.create 256 in
  let modules = ref [] in
  let impls = ref [] in
  let all_items = ref [] in

  (* First pass: collect all definitions *)
  List.iter (fun (file, prog) ->
    let mod_name = module_name_from_file file in

    let register_symbol name kind =
      let mangled = mangle_name mod_name name in
      let sym = { sym_name = name; sym_module = mod_name;
                  sym_kind = kind; sym_mangled = sanitize_ident mangled } in
      (* Warn on redefinition from a different module *)
      (match Hashtbl.find_opt symbols name with
       | Some prev when prev.sym_module <> mod_name ->
         Printf.eprintf "Warning: symbol '%s' (module %s) shadows definition from module %s\n"
           name mod_name prev.sym_module
       | _ -> ());
      Hashtbl.replace symbols name sym;
      Hashtbl.replace qualified (sanitize_ident mangled) sym
    in

    let rec process_items items =
      List.iter (fun item ->
        all_items := item :: !all_items;
        match item with
        | IFn { name; params; ret; _ } ->
          register_symbol name (SkFunction (params, ret))

        | IStruct { name; fields; _ } ->
          register_symbol name (SkStruct fields)

        | IEnum { name; variants; _ } ->
          register_symbol name (SkEnum variants);
          List.iteri (fun tag vd ->
            let vi = { vi_enum = name; vi_module = mod_name; vi_name = vd.vd_name;
                       vi_tag = tag; vi_fields = vd.vd_fields } in
            (* Use add instead of replace to keep ALL variants with same name *)
            Hashtbl.add variant_tbl vd.vd_name vi;
            (* Register variant as a constructor function, but only if it
               doesn't shadow an existing struct/enum/trait definition *)
            (match Hashtbl.find_opt symbols vd.vd_name with
             | Some { sym_kind = SkStruct _; _ }
             | Some { sym_kind = SkEnum _; _ }
             | Some { sym_kind = SkTrait _; _ } -> ()  (* Don't overwrite type defs *)
             | _ ->
               register_symbol vd.vd_name
                 (SkFunction (
                   List.mapi (fun i t ->
                     let pname = if i < List.length vd.vd_field_names then
                       List.nth vd.vd_field_names i
                     else Printf.sprintf "_%d" i in
                     { p_name = pname; p_typ = t;
                       p_mut = false; p_default = None }
                   ) vd.vd_fields,
                   Some (TyName (name, [])))))
          ) variants

        | ITrait { name; items = trait_items; _ } ->
          let sigs = List.filter_map (fun it ->
            match it with
            | IFn { name = n; params = ps; ret = r; _ } ->
              Some { fs_name = n; fs_params = ps; fs_ret = r }
            | _ -> None
          ) trait_items in
          register_symbol name (SkTrait sigs)

        | IImpl { target; trait_; methods; _ } ->
          let tname = target_name_of_typ target in
          impls := { imp_target = tname; imp_trait = trait_;
                     imp_methods = methods } :: !impls;
          List.iter (fun m ->
            match m with
            | IFn { name = mname; params; ret; _ } ->
              let mangled = mangle_method tname mname in
              let sym = { sym_name = mname; sym_module = mod_name;
                          sym_kind = SkMethod (tname, params, ret);
                          sym_mangled = sanitize_ident mangled } in
              let method_key = tname ^ "." ^ mname in
              (match Hashtbl.find_opt method_map method_key with
               | Some prev when prev.sym_module <> mod_name ->
                 Printf.eprintf "Warning: method '%s' on type '%s' (module %s) shadows definition from module %s\n"
                   mname tname mod_name prev.sym_module
               | _ -> ());
              Hashtbl.replace method_map method_key sym;
              Hashtbl.replace qualified (sanitize_ident mangled) sym;
              (* For trait impls, also register as Trait__Type__method *)
              (match trait_ with
               | Some trait_name ->
                 let tmangled = trait_name ^ "__" ^ tname ^ "__" ^ mname in
                 Hashtbl.replace qualified (sanitize_ident tmangled) sym
               | None -> ())
            | _ -> ()
          ) methods

        | IConst { name; _ } ->
          register_symbol name SkConst

        | ITypeAlias { name; typ; _ } ->
          register_symbol name (SkTypeAlias typ)

        | IModule { items = sub_items; _ } ->
          process_items sub_items

        | IUse _ | IExtern _ -> ()
      ) items
    in

    process_items prog.items;
    modules := { mod_name; mod_file = file; mod_items = prog.items } :: !modules
  ) file_programs;

  { modules = List.rev !modules;
    symbols; qualified; impls = !impls;
    variants = variant_tbl; method_map;
    all_items = List.rev !all_items }

(* ── Lookup helpers ────────────────────────────────────────────────── *)

let find_symbol res name =
  try Some (Hashtbl.find res.symbols name) with Not_found -> None

let find_variant res name =
  let all = Hashtbl.find_all res.variants name in
  match all with
  | [] -> None
  | [single] -> Some single
  | _ :: _ ->
    (* Ambiguous: multiple enums define this variant name.
       Sort deterministically by enum name to avoid Hashtbl ordering dependency. *)
    let sorted = List.sort (fun a b -> String.compare a.vi_enum b.vi_enum) all in
    Printf.eprintf "Warning: variant '%s' is ambiguous (defined in enums: %s), using %s\n"
      name (String.concat ", " (List.map (fun vi -> vi.vi_enum) sorted))
      (List.hd sorted).vi_enum;
    Some (List.hd sorted)

let find_method res type_name method_name =
  let key = type_name ^ "." ^ method_name in
  try Some (Hashtbl.find res.method_map key) with Not_found -> None

let is_function res name =
  match find_symbol res name with
  | Some { sym_kind = SkFunction _; _ } -> true
  | _ -> false

let is_struct res name =
  match find_symbol res name with
  | Some { sym_kind = SkStruct _; _ } -> true
  | _ -> false

let is_enum res name =
  match find_symbol res name with
  | Some { sym_kind = SkEnum _; _ } -> true
  | _ -> false

let is_variant res name =
  Hashtbl.mem res.variants name

(* Find best matching variant by name and argument count *)
let find_variant_by_arity res name num_args =
  let all = Hashtbl.find_all res.variants name in
  (* Try to find one that matches the argument count *)
  match List.find_opt (fun vi -> List.length vi.vi_fields = num_args) all with
  | Some vi -> Some vi
  | None ->
    (* Fall back to first variant with that name *)
    match all with
    | vi :: _ -> Some vi
    | [] -> None

(* Find variant by name, preferring a specific enum type if known *)
let find_variant_prefer_enum res name num_args ~prefer_enum =
  if prefer_enum = "" then find_variant_by_arity res name num_args
  else
    let all = Hashtbl.find_all res.variants name in
    (* First try: match enum AND arity *)
    match List.find_opt (fun vi -> vi.vi_enum = prefer_enum && List.length vi.vi_fields = num_args) all with
    | Some vi -> Some vi
    | None ->
      (* Try: match enum only *)
      match List.find_opt (fun vi -> vi.vi_enum = prefer_enum) all with
      | Some vi -> Some vi
      | None ->
        (* Fall back to arity-only match *)
        find_variant_by_arity res name num_args

let struct_fields res name =
  match find_symbol res name with
  | Some { sym_kind = SkStruct fields; _ } -> fields
  | _ -> []

let enum_variants res name =
  match find_symbol res name with
  | Some { sym_kind = SkEnum variants; _ } -> variants
  | _ -> []

(* Find a variant within a specific enum by enum name and variant name *)
let find_variant_in_enum res enum_name variant_name =
  let variants = enum_variants res enum_name in
  (* Find the module for this enum *)
  let enum_mod = match find_symbol res enum_name with
    | Some s -> s.sym_module | None -> "" in
  let rec find tag = function
    | [] -> None
    | vd :: _ when vd.vd_name = variant_name ->
      Some { vi_enum = enum_name; vi_module = enum_mod; vi_name = variant_name;
             vi_tag = tag; vi_fields = vd.vd_fields }
    | _ :: rest -> find (tag + 1) rest
  in
  match find 0 variants with
  | Some vi -> Some vi
  | None ->
    (* Fallback: search the variants hashtable directly.
       Handles cross-module cases where Hashtbl.replace in symbols
       overwrote the enum definition from the module that has this variant. *)
    let all_vis = Hashtbl.find_all res.variants variant_name in
    List.find_opt (fun vi -> vi.vi_enum = enum_name) all_vis

let struct_field_index res struct_name field_name =
  let fields = struct_fields res struct_name in
  let rec find i = function
    | [] -> -1
    | f :: _ when f.fd_name = field_name -> i
    | _ :: rest -> find (i + 1) rest
  in
  find 0 fields
