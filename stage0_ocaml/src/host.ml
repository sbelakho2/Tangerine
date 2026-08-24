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

(* Host symbol ids: the VM dispatches registry indices
   (Seed_mir.Intrinsic n / Seed_mir.Extern n); the binding table is keyed
   by the same ids, namespaced by kind so the two registries cannot
   collide. *)
type host_id =
  | Intrinsic of int
  | Extern of int

(* One binding table for the whole host surface. A symbol WITHOUT an
   `invoke` is not implemented — the record type requires the function, so
   "bound" and "has an executable invoke" are the same predicate. *)
type binding = {
  id : host_id;
  name : string;
  arity : int;
  invoke : t -> Vm_value.t array -> (Vm_value.t, string) result;
}

and t = {
  intrinsics : Intrinsic_registry.t;
  externs : Extern_registry.t;
  bindings : binding list;
  fs : Host_fs.t;
  process : unit;
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

let expect_one_arg (name : string) (args : Vm_value.t array) : (Vm_value.t, string) result =
  match args with
  | [| v |] -> Ok v
  | _ ->
      Error
        (Printf.sprintf "%s: expected exactly 1 argument, got %d" name
           (Array.length args))

let invoke_print (t : t) (args : Vm_value.t array) : (Vm_value.t, string) result =
  match expect_one_arg "print" args with
  | Error e -> Error e
  | Ok (Vm_value.String s) ->
      emit_stdout t s;
      Ok Vm_value.Unit
  | Ok _ -> Error "print: expected a String argument"

let invoke_println (t : t) (args : Vm_value.t array) : (Vm_value.t, string) result =
  match expect_one_arg "println" args with
  | Error e -> Error e
  | Ok (Vm_value.String s) ->
      emit_stdout t s;
      emit_stdout t "\n";
      Ok Vm_value.Unit
  | Ok _ -> Error "println: expected a String argument"

(* Deterministic host error: the VM turns the Error into a trap. *)
let invoke_panic (_t : t) (args : Vm_value.t array) : (Vm_value.t, string) result =
  match expect_one_arg "panic" args with
  | Error e -> Error e
  | Ok (Vm_value.String s) -> Error (Printf.sprintf "panic: %s" s)
  | Ok _ -> Error "panic: expected a String argument"

let invoke_abort (_t : t) (args : Vm_value.t array) : (Vm_value.t, string) result =
  match args with
  | [||] -> Error "__intrinsic_abort: process aborted"
  | _ -> Error "__intrinsic_abort: expected no arguments"

let invoke_int_to_string (_t : t) (args : Vm_value.t array) : (Vm_value.t, string) result =
  match expect_one_arg "__intrinsic_int_to_string" args with
  | Error e -> Error e
  | Ok (Vm_value.Int i) -> Ok (Vm_value.String (Int_value.to_string i))
  | Ok _ -> Error "__intrinsic_int_to_string: expected an Int argument"

let invoke_bool_to_string (_t : t) (args : Vm_value.t array) : (Vm_value.t, string) result =
  match expect_one_arg "__intrinsic_bool_to_string" args with
  | Error e -> Error e
  | Ok (Vm_value.Bool b) -> Ok (Vm_value.String (if b then "true" else "false"))
  | Ok _ -> Error "__intrinsic_bool_to_string: expected a Bool argument"

let invoke_char_to_string (_t : t) (args : Vm_value.t array) : (Vm_value.t, string) result =
  match expect_one_arg "__intrinsic_char_to_string" args with
  | Error e -> Error e
  | Ok (Vm_value.Char c) -> Ok (Vm_value.String (String.make 1 (Uchar.to_char c)))
  | Ok _ -> Error "__intrinsic_char_to_string: expected a Char argument"

let invoke_string_len (_t : t) (args : Vm_value.t array) : (Vm_value.t, string) result =
  match expect_one_arg "__intrinsic_string_len" args with
  | Error e -> Error e
  | Ok (Vm_value.String s) ->
      Ok
        (Vm_value.Int
           (Int_value.of_int64 ~width:64 ~signed:true (Int64.of_int (String.length s))))
  | Ok _ -> Error "__intrinsic_string_len: expected a String argument"

(* __sync_synchronize is a full memory barrier; on the single-threaded
   seed host there is nothing to order, so the correct implementation is
   a no-op. This is the real semantic, not a fabricated value. *)
let invoke_sync_synchronize (_t : t) (args : Vm_value.t array) : (Vm_value.t, string) result =
  match args with
  | [||] -> Ok Vm_value.Unit
  | _ -> Error "__sync_synchronize: expected no arguments"

(* Binding ids are derived from the declared registries by name, so the
   executable closure and the declarations can never drift apart. *)
let intrinsic_binding (name : string) (arity : int)
    (invoke : t -> Vm_value.t array -> (Vm_value.t, string) result) : binding =
  match Intrinsic_registry.lookup Intrinsic_registry.manifest ~name with
  | Some (id, _) -> { id = Intrinsic id; name; arity; invoke }
  | None -> failwith (Printf.sprintf "host binding '%s': not a declared intrinsic" name)

let extern_binding (name : string) (arity : int)
    (invoke : t -> Vm_value.t array -> (Vm_value.t, string) result) : binding =
  match Extern_registry.lookup Extern_registry.manifest ~name with
  | Some (id, _) -> { id = Extern id; name; arity; invoke }
  | None -> failwith (Printf.sprintf "host binding '%s': not a declared extern" name)

let binding_manifest : binding list =
  [
    intrinsic_binding "print" 1 invoke_print;
    intrinsic_binding "println" 1 invoke_println;
    intrinsic_binding "panic" 1 invoke_panic;
    intrinsic_binding "__intrinsic_abort" 0 invoke_abort;
    intrinsic_binding "__intrinsic_int_to_string" 1 invoke_int_to_string;
    intrinsic_binding "__intrinsic_bool_to_string" 1 invoke_bool_to_string;
    intrinsic_binding "__intrinsic_char_to_string" 1 invoke_char_to_string;
    intrinsic_binding "__intrinsic_string_len" 1 invoke_string_len;
    extern_binding "__sync_synchronize" 0 invoke_sync_synchronize;
  ]

let binding_of_manifest (name : string) : binding option =
  List.find_opt (fun b -> b.name = name) binding_manifest

(* ── Construction ─────────────────────────────────────────────────── *)

(* Build a host from explicit registries (declared surface) and an
   explicit binding table (executable closure). *)
let create_with ~repo_root ~(argv : string array) ~(intrinsics : Intrinsic_registry.t)
    ~(externs : Extern_registry.t) ~(bindings : binding list) : t =
  {
    intrinsics;
    externs;
    bindings;
    fs = Host_fs.create ~repo_root;
    process = ();
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
   the check and is named; an arity disagreement with the declared
   signature also fails; bound-but-undeclared extras fail. The report
   carries the implemented-vs-declared counts. *)

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
          if Array.length dsig.Intrinsic_registry.params <> b.arity then
            problem "arity mismatch for %s: declared %d params, binding arity %d"
              name (Array.length dsig.Intrinsic_registry.params) b.arity)
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
