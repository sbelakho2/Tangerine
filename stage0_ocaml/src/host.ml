(* host.ml — the host aggregate (audit §42, §70).

   The host is everything the stage0 VM talks to: the intrinsic and extern
   registries (declared-host symbols), the virtual filesystem, process
   spawning, the program argument vector, the normalized environment, and
   the output buffers the VM's printf/intrinsic path writes to
   (emit_stdout/emit_stderr — audit §45).

   THE EXECUTABLE CLOSURE (audit §70): a host symbol is *implemented* only
   when the binding table (bindings / binding_manifest) carries an entry
   with an executable `invoke`. A symbol that the registries declare but
   that has no binding is NOT implemented: closure_check fails and names
   it, and the VM's host dispatch traps — fail-closed. There is no
   metadata-only "implementation". *)

(* Host symbol ids: the VM dispatches registry ids (Seed_mir.Intrinsic n
   / Seed_mir.Extern n, converted at the dispatch boundary); the binding
   table is keyed by the same ids, namespaced by kind so the two
   registries cannot collide. The ids are the registries' ABSTRACT id
   types — not raw ints — so an intrinsic id can never be used where an
   extern id belongs, and vice versa. *)
type host_id =
  | Intrinsic of Intrinsic_registry.Id.t
  | Extern of Extern_registry.Id.t

(* One binding table for the whole host surface. A symbol WITHOUT an
   `invoke` is not implemented — the record type requires the function, so
   "bound" and "has an executable invoke" are the same predicate. *)
(* Canonical type key for signature comparison. *)
let rec type_key (ty : Type_repr.t) : string =
  match ty with
  | Type_repr.Unit -> "Unit"
  | Type_repr.Bool -> "Bool"
  | Type_repr.Int k -> (
      match k with
      | Type_repr.I8 -> "i8" | Type_repr.I16 -> "i16" | Type_repr.I32 -> "i32"
      | Type_repr.I64 -> "i64" | Type_repr.I128 -> "i128"
      | Type_repr.U8 -> "u8" | Type_repr.U16 -> "u16" | Type_repr.U32 -> "u32"
      | Type_repr.U64 -> "u64" | Type_repr.U128 -> "u128"
      | Type_repr.Int -> "Int" | Type_repr.UInt -> "UInt")
  | Type_repr.Float k -> (match k with Type_repr.F32 -> "f32" | Type_repr.F64 -> "f64")
  | Type_repr.Char -> "Char"
  | Type_repr.String -> "String"
  | Type_repr.Tuple elems -> "(" ^ String.concat "," (Array.to_list (Array.map type_key elems)) ^ ")"
  | Type_repr.Named (id, args) ->
      "T#" ^ string_of_int (Ids.Type_id.to_int id)
      ^ (if Array.length args = 0 then ""
         else "[" ^ String.concat "," (Array.to_list (Array.map type_key args)) ^ "]")
  | Type_repr.Fixed_array (t, _) -> "[" ^ type_key t ^ "]"
  | Type_repr.Raw_ptr (_, t) -> "ptr<" ^ type_key t ^ ">"
  | Type_repr.Ref_internal (_, t) -> "ref<" ^ type_key t ^ ">"
  | Type_repr.Type_param id -> "P#" ^ string_of_int (Ids.Generic_param_id.to_int id)
  | Type_repr.Function (ps, r) ->
      "fn(" ^ String.concat "," (Array.to_list (Array.map (fun p -> type_key p.Type_repr.pt_type) ps)) ^ ")->" ^ type_key r
  | Type_repr.Never -> "!"

type signature = {
  param_types : string list;
  return_type : string;
}

type binding = {
  id : host_id;
  name : string;
  signature : signature;
  invoke : t -> Vm_value.t array -> (Vm_value.t, string) result;
}

(* The process surface (audit §44): real spawning through
   Host_process, wired into the host aggregate so source-derived process
   symbols have a single place to call. A cwd supplied by Tangerine is a
   VIRTUAL path: it goes through the Host_fs resolver first, and only a
   path that resolves inside the canonical root is handed to the child. *)
and process_api = {
  spawn :
    executable:string -> argv:string array -> env:string array -> cwd:string option
    -> (Host_process.status, string) result;
  spawn_nocapture :
    executable:string -> argv:string array -> env:string array -> (int, string) result;
}

and t = {
  intrinsics : Intrinsic_registry.t;
  externs : Extern_registry.t;
  bindings : binding list;
  fs : Host_fs.t;
  process : process_api;
  argv : string array;
  mutable env : (string * string) list;
  mutable stdout : Buffer.t;
  mutable stderr : Buffer.t;
}

(* Output helpers (the VM's printf/intrinsic path — audit §45). *)
let emit_stdout (t : t) (s : string) : unit = Buffer.add_string t.stdout s
let emit_stderr (t : t) (s : string) : unit = Buffer.add_string t.stderr s
let stdout_contents (t : t) : string = Buffer.contents t.stdout
let stderr_contents (t : t) : string = Buffer.contents t.stderr

(* ── The single binding table (audit §70) ────────────────────────────

   Every entry below carries a REAL executable implementation. Symbols the
   closure declares but that are NOT in this table — the map/set record
   traversal intrinsics, the Ruby C API externs, the dl* loader family,
   the __sync arithmetic primitives — are deliberately unbound: their real
   semantics are not implementable on this seed host, so no stub is
   shipped. closure_check fails on them and the VM traps. *)

(* ── Independent typed binding adapters (host P1) ───────────────────

   Each executable binding is declared through a typed ADAPTER that
   independently encodes the symbol's signature. The OCaml function type
   the adapter accepts fixes the argument/result conversion, and the
   signature strings are written ONCE at the adapter — never copied from
   the registry declaration. `intrinsic_binding`/`extern_binding` then
   pair the adapter with the registry-declared id, and closure_check
   compares the ADAPTER's signature against the registry's
   source-derived declaration: a drift between the two is a real,
   caught error, not a self-comparison. *)

type adapter = {
  signature : signature;
  invoke : t -> Vm_value.t array -> (Vm_value.t, string) result;
}

let arg_mismatch expected : (Vm_value.t, string) result =
  Error ("argument mismatch: expected " ^ expected)

(* () -> Unit *)
let adapter_ret_unit (f : t -> unit) : adapter =
  {
    signature = { param_types = []; return_type = type_key Type_repr.Unit };
    invoke =
      (fun t args ->
        match args with
        | [||] ->
            f t;
            Ok Vm_value.Unit
        | _ -> arg_mismatch "no arguments");
  }

(* () -> Never: f produces the deterministic host error message. *)
let adapter_ret_never (f : t -> string) : adapter =
  {
    signature = { param_types = []; return_type = type_key Type_repr.Never };
    invoke =
      (fun t args ->
        match args with
        | [||] -> Error (f t)
        | _ -> arg_mismatch "no arguments");
  }

(* String -> Unit *)
let adapter_string_ret_unit (f : t -> string -> unit) : adapter =
  {
    signature =
      { param_types = [ type_key Type_repr.String ];
        return_type = type_key Type_repr.Unit };
    invoke =
      (fun t args ->
        match args with
        | [| Vm_value.String s |] ->
            f t s;
            Ok Vm_value.Unit
        | _ -> arg_mismatch "String");
  }

(* String -> Never: f produces the deterministic host error message. *)
let adapter_string_ret_never (f : t -> string -> string) : adapter =
  {
    signature =
      { param_types = [ type_key Type_repr.String ];
        return_type = type_key Type_repr.Never };
    invoke =
      (fun t args ->
        match args with
        | [| Vm_value.String s |] -> Error (f t s)
        | _ -> arg_mismatch "String");
  }

(* Int -> String *)
let adapter_int_ret_string (f : t -> Int_value.t -> string) : adapter =
  {
    signature =
      { param_types = [ type_key (Type_repr.Int Type_repr.Int) ];
        return_type = type_key Type_repr.String };
    invoke =
      (fun t args ->
        match args with
        | [| Vm_value.Int i |] -> Ok (Vm_value.String (f t i))
        | _ -> arg_mismatch "Int");
  }

(* Bool -> String *)
let adapter_bool_ret_string (f : t -> bool -> string) : adapter =
  {
    signature =
      { param_types = [ type_key Type_repr.Bool ];
        return_type = type_key Type_repr.String };
    invoke =
      (fun t args ->
        match args with
        | [| Vm_value.Bool b |] -> Ok (Vm_value.String (f t b))
        | _ -> arg_mismatch "Bool");
  }

(* Char -> String *)
let adapter_char_ret_string (f : t -> Uchar.t -> string) : adapter =
  {
    signature =
      { param_types = [ type_key Type_repr.Char ];
        return_type = type_key Type_repr.String };
    invoke =
      (fun t args ->
        match args with
        | [| Vm_value.Char c |] -> Ok (Vm_value.String (f t c))
        | _ -> arg_mismatch "Char");
  }

(* String -> Int *)
let adapter_string_ret_int (f : t -> string -> Int_value.t) : adapter =
  {
    signature =
      { param_types = [ type_key Type_repr.String ];
        return_type = type_key (Type_repr.Int Type_repr.Int) };
    invoke =
      (fun t args ->
        match args with
        | [| Vm_value.String s |] -> Ok (Vm_value.Int (f t s))
        | _ -> arg_mismatch "String");
  }

(* Binding ids are resolved from the declared registries by name, so the
   executable closure and the declarations can never drift apart in
   identity; the SIGNATURE is the adapter's independent declaration. *)
let intrinsic_binding (name : string) (a : adapter) : binding =
  match Intrinsic_registry.lookup Intrinsic_registry.manifest ~name with
  | Some (id, _) -> { id = Intrinsic id; name; signature = a.signature; invoke = a.invoke }
  | None -> failwith (Printf.sprintf "host binding '%s': not a declared intrinsic" name)

let extern_binding (name : string) (a : adapter) : binding =
  match Extern_registry.lookup Extern_registry.manifest ~name with
  | Some (id, _) -> { id = Extern id; name; signature = a.signature; invoke = a.invoke }
  | None -> failwith (Printf.sprintf "host binding '%s': not a declared extern" name)

let binding_manifest : binding list =
  [
    intrinsic_binding "print"
      (adapter_string_ret_unit (fun t s -> emit_stdout t s));
    intrinsic_binding "println"
      (adapter_string_ret_unit (fun t s ->
           emit_stdout t s;
           emit_stdout t "\n"));
    intrinsic_binding "panic"
      (adapter_string_ret_never (fun _ s -> Printf.sprintf "panic: %s" s));
    intrinsic_binding "__intrinsic_abort"
      (adapter_ret_never (fun _ -> "__intrinsic_abort: process aborted"));
    intrinsic_binding "__intrinsic_int_to_string"
      (adapter_int_ret_string (fun _ i -> Int_value.to_string i));
    intrinsic_binding "__intrinsic_bool_to_string"
      (adapter_bool_ret_string (fun _ b -> if b then "true" else "false"));
    intrinsic_binding "__intrinsic_char_to_string"
      (adapter_char_ret_string (fun _ c -> Bytes.to_string (Utf8.encode_scalar c)));
    intrinsic_binding "__intrinsic_string_len"
      (adapter_string_ret_int (fun _ s ->
           Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int (String.length s))));
    (* __sync_synchronize is a full memory barrier; on the single-threaded
       seed host there is nothing to order, so the correct implementation
       is a no-op. This is the real semantic, not a fabricated value. *)
    extern_binding "__sync_synchronize"
      (adapter_ret_unit (fun _ -> ()));
  ]

let binding_of_manifest (name : string) : binding option =
  List.find_opt (fun b -> b.name = name) binding_manifest

(* ── Construction ─────────────────────────────────────────────────── *)

(* The process capability is built ONCE per host from Host_process,
   bound to the host's virtual filesystem: a Tangerine-supplied cwd is a
   virtual path, resolved through Host_fs (canonicalized + containment)
   before a child is chdir'd onto it. *)
let default_process_api (fs : Host_fs.t) : process_api =
  let resolve_virtual_cwd (cwd : string option) : (string option, string) result =
    match cwd with
    | None -> Ok None
    | Some dir ->
        let segs =
          String.split_on_char '/' dir |> List.filter (fun s -> s <> "")
        in
        (match Host_fs.resolve fs segs with
        | Ok real -> Ok (Some real)
        | Error e -> Error e)
  in
  {
    spawn =
      (fun ~executable ~argv ~env ~cwd ->
        match resolve_virtual_cwd cwd with
        | Error e -> Error e
        | Ok cwd' -> Host_process.spawn ~executable ~argv ~env ~cwd:cwd');
    spawn_nocapture = Host_process.spawn_nocapture;
  }

(* Build a host from explicit registries (declared surface) and an
   explicit binding table (executable closure). *)
let create_with ~repo_root ~(argv : string array) ~(intrinsics : Intrinsic_registry.t)
    ~(externs : Extern_registry.t) ~(bindings : binding list) : t =
  let fs = Host_fs.create ~repo_root in
  {
    intrinsics;
    externs;
    bindings;
    fs;
    process = default_process_api fs;
    argv;
    env = [];
    stdout = Buffer.create 4096;
    stderr = Buffer.create 4096;
  }

(* The default host: manifest registries and the manifest binding table. *)
let create ~repo_root ~(argv : string array) : t =
  create_with ~repo_root ~argv ~intrinsics:Intrinsic_registry.manifest
    ~externs:Extern_registry.manifest ~bindings:binding_manifest

(* Normalize the process environment for spawned children: LC_ALL=C and
   TZ=UTC are forced through Unix.putenv, then the recorded environment is
   captured and sorted by key for determinism. *)
let with_normalized_env (t : t) : t =
  Unix.putenv "LC_ALL" "C";
  Unix.putenv "TZ" "UTC";
  let env =
    Unix.environment ()
    |> Array.to_list
    |> List.map (fun entry ->
           match String.index_opt entry '=' with
           | Some i ->
               ( String.sub entry 0 i,
                 String.sub entry (i + 1) (String.length entry - i - 1) )
           | None -> (entry, ""))
    |> List.sort (fun (a, _) (b, _) -> String.compare a b)
  in
  t.env <- env;
  t

(* ── Binding lookup (the VM's dispatch path) ───────────────────────── *)

let lookup_binding (t : t) (id : host_id) : binding option =
  List.find_opt (fun b -> b.id = id) t.bindings

let lookup_binding_by_name (t : t) (name : string) : binding option =
  List.find_opt (fun b -> b.name = name) t.bindings

(* Resolve a dispatch id back to its declared name (for diagnostics). *)
let name_of_host_id (t : t) (id : host_id) : string option =
  match id with
  | Intrinsic i ->
      List.find_map
        (fun (name, (iid, _)) -> if iid = i then Some name else None)
        t.intrinsics.Intrinsic_registry.by_name
  | Extern i ->
      List.find_map
        (fun (name, (eid, _)) -> if eid = i then Some name else None)
        t.externs.Extern_registry.by_name

(* ────────────────────────────────────────────────────────────────────
   Closure check (audit §70). The declared surface (the registries) is
   compared against the EXACT SAME binding table the VM dispatches
   through (t.bindings). PASS requires every declared symbol to carry a
   binding — an executable invoke. Any declared-but-unbound symbol FAILS
   the check and is named; a signature disagreement between the
   binding's INDEPENDENT adapter declaration and the registry's
   source-derived declaration also fails; bound-but-undeclared extras
   fail. The report carries the implemented-vs-declared counts. *)

type closure_report = {
  declared : int;
  implemented : int;
  bound : string list;
}

let closure_check (t : t) : (closure_report, string list) result =
  let module SS = Set.Make (String) in
  let problems = ref [] in
  let problem fmt = Printf.ksprintf (fun s -> problems := s :: !problems) fmt in
  let declared =
    List.map
      (fun name -> (name, snd (Option.get (Intrinsic_registry.lookup t.intrinsics ~name))))
      (Intrinsic_registry.names t.intrinsics)
    @ List.map
        (fun name ->
          (name, snd (Option.get (Extern_registry.lookup t.externs ~name))))
        (Extern_registry.names t.externs)
  in
  let decl_names = SS.of_list (List.map fst declared) in
  let impl_names = SS.of_list (List.map (fun b -> b.name) t.bindings) in
  let missing = SS.diff decl_names impl_names in
  if not (SS.is_empty missing) then
    problem "declared but not bound (no invoke): %s" (String.concat ", " (SS.elements missing));
  List.iter
    (fun (name, dsig) ->
      match List.find_opt (fun b -> b.name = name) t.bindings with
      | None -> ()
      | Some b ->
          let decl_params = Array.to_list (Array.map type_key dsig.Intrinsic_registry.params) in
          let decl_ret = type_key dsig.Intrinsic_registry.ret in
          if decl_params <> b.signature.param_types then
            problem "signature mismatch for %s: declared params [%s], binding params [%s]"
              name (String.concat ", " decl_params) (String.concat ", " b.signature.param_types);
          if decl_ret <> b.signature.return_type then
            problem "return mismatch for %s: declared %s, binding %s" name decl_ret b.signature.return_type)
    declared;
  let extras = SS.diff impl_names decl_names in
  if not (SS.is_empty extras) then
    problem "bound but not declared: %s" (String.concat ", " (SS.elements extras));
  match List.rev !problems with
  | [] ->
      Ok
        { declared = SS.cardinal decl_names;
          implemented = SS.cardinal impl_names;
          bound = List.sort compare (List.map (fun b -> b.name) t.bindings) }
  | ps -> Error ps
