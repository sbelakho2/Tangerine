(* host.ml — the host aggregate (audit §42, §70).

   The host is everything the stage0 VM talks to: the intrinsic and extern
   registries (declared-host symbols), the virtual filesystem, process
   spawning, the program argument vector, the normalized environment, and
   the output buffers the VM's printf/intrinsic path writes to
   (emit_stdout/emit_stderr — audit §45). *)

type t = {
  intrinsics : Intrinsic_registry.t;
  externs : Extern_registry.t;
  fs : Host_fs.t;
  process : unit;
  argv : string array;
  mutable env : (string * string) list;
  mutable stdout : Buffer.t;
  mutable stderr : Buffer.t;
}

let create ~repo_root ~(argv : string array) : t =
  {
    intrinsics = Intrinsic_registry.manifest;
    externs = Extern_registry.manifest;
    fs = Host_fs.create ~repo_root;
    process = ();
    argv;
    env = [];
    stdout = Buffer.create 4096;
    stderr = Buffer.create 4096;
  }

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

(* Output helpers (the VM's printf/intrinsic path — audit §45). *)
let emit_stdout (t : t) (s : string) : unit = Buffer.add_string t.stdout s
let emit_stderr (t : t) (s : string) : unit = Buffer.add_string t.stderr s

(* ———————————————————————————————————————————————————————————————
   Closure check (audit §70): the host's actual binding surface. This
   table is transcribed independently from the closure sources, so the
   check has teeth: the registries (declared) and this table
   (implemented) must agree on names and signatures. *)

let implemented_host_symbols : (string * Intrinsic_registry.signature) list =
  let open Intrinsic_registry in
  let e name params ret = (name, sig_ ~params ~ret) in
  [
    (* std/collections.tg intrinsics. *)
    e "__intrinsic_map_visit_begin"
      [| map_of (param Type_param.k) (param Type_param.v) |]
      (option_of (ref_ (param Type_param.k)));
    e "__intrinsic_map_visit_next"
      [| map_of (param Type_param.k) (param Type_param.v); param Type_param.k |]
      (option_of (ref_ (param Type_param.k)));
    e "__intrinsic_map_visit_value"
      [| map_of (param Type_param.k) (param Type_param.v); param Type_param.k |]
      (ref_ (param Type_param.v));
    e "__intrinsic_set_visit_begin"
      [| set_of (param Type_param.t) |]
      (option_of (ref_ (param Type_param.t)));
    e "__intrinsic_set_visit_next"
      [| set_of (param Type_param.t); param Type_param.t |]
      (option_of (ref_ (param Type_param.t)));
    e "__intrinsic_set_remove"
      [| set_of (param Type_param.t); param Type_param.t |]
      ty_bool;
    e "__intrinsic_set_drain_one"
      [| set_of (param Type_param.t) |]
      (option_of (param Type_param.t));
    e "__intrinsic_set_len" [| set_of (param Type_param.t) |] ty_int;
    e "__intrinsic_set_clear" [| set_of (param Type_param.t) |] ty_unit;
    e "__intrinsic_set_entries" [| set_of (param Type_param.t) |] (vec_of (param Type_param.t));
    (* std/ffi.tg externs: Ruby C API. *)
    e "ruby_init" [||] ty_unit;
    e "ruby_init_loadpath" [||] ty_unit;
    e "ruby_finalize" [||] ty_unit;
    e "rb_define_module" [| ptr_u8 |] ruby_value;
    e "rb_define_class" [| ptr_u8; ruby_value |] ruby_value;
    e "rb_define_class_under" [| ruby_value; ptr_u8; ruby_value |] ruby_value;
    e "rb_define_module_under" [| ruby_value; ptr_u8 |] ruby_value;
    e "rb_define_method" [| ruby_value; ptr_u8; ptr_u8; ty_int |] ty_unit;
    e "rb_define_singleton_method" [| ruby_value; ptr_u8; ptr_u8; ty_int |] ty_unit;
    e "rb_define_module_function" [| ruby_value; ptr_u8; ptr_u8; ty_int |] ty_unit;
    e "rb_funcall" [| ruby_value; ruby_id; ty_int |] ruby_value;
    e "rb_funcall2" [| ruby_value; ruby_id; ty_int; ptr ruby_value |] ruby_value;
    e "rb_intern" [| ptr_u8 |] ruby_id;
    e "rb_id2name" [| ruby_id |] ptr_u8;
    e "rb_id2sym" [| ruby_id |] ruby_value;
    e "rb_sym2id" [| ruby_value |] ruby_id;
    e "rb_str_new" [| ptr_u8; ty_int |] ruby_value;
    e "rb_str_new_cstr" [| ptr_u8 |] ruby_value;
    e "rb_string_value_cstr" [| ptr ruby_value |] ptr_u8;
    e "rb_str_cat" [| ruby_value; ptr_u8; ty_int |] ruby_value;
    e "rb_str_to_str" [| ruby_value |] ruby_value;
    e "rb_ary_new" [||] ruby_value;
    e "rb_ary_new_capa" [| ty_int |] ruby_value;
    e "rb_ary_push" [| ruby_value; ruby_value |] ruby_value;
    e "rb_ary_pop" [| ruby_value |] ruby_value;
    e "rb_ary_entry" [| ruby_value; ty_int |] ruby_value;
    e "rb_ary_store" [| ruby_value; ty_int; ruby_value |] ty_unit;
    e "rb_ary_len" [| ruby_value |] ty_int;
    e "rb_hash_new" [||] ruby_value;
    e "rb_hash_aset" [| ruby_value; ruby_value; ruby_value |] ruby_value;
    e "rb_hash_aref" [| ruby_value; ruby_value |] ruby_value;
    e "rb_hash_delete" [| ruby_value; ruby_value |] ruby_value;
    e "rb_num2int" [| ruby_value |] ty_int;
    e "rb_int2num" [| ty_int |] ruby_value;
    e "rb_num2dbl" [| ruby_value |] ty_float;
    e "rb_float_new" [| ty_float |] ruby_value;
    e "rb_obj_is_kind_of" [| ruby_value; ruby_value |] ruby_value;
    e "rb_type" [| ruby_value |] ty_int;
    e "rb_obj_classname" [| ruby_value |] ptr_u8;
    e "rb_cObject" [||] ruby_value;
    e "rb_cArray" [||] ruby_value;
    e "rb_cHash" [||] ruby_value;
    e "rb_cString" [||] ruby_value;
    e "rb_cInteger" [||] ruby_value;
    e "rb_cFloat" [||] ruby_value;
    e "rb_cNilClass" [||] ruby_value;
    e "rb_cTrueClass" [||] ruby_value;
    e "rb_cFalseClass" [||] ruby_value;
    e "rb_cSymbol" [||] ruby_value;
    e "rb_mKernel" [||] ruby_value;
    e "rb_raise" [| ruby_value; ptr_u8 |] ty_unit;
    e "rb_exc_new_str" [| ruby_value; ruby_value |] ruby_value;
    e "rb_eRuntimeError" [||] ruby_value;
    e "rb_eTypeError" [||] ruby_value;
    e "rb_eArgError" [||] ruby_value;
    e "rb_eStandardError" [||] ruby_value;
    e "rb_eval_string" [| ptr_u8 |] ruby_value;
    e "rb_eval_string_protect" [| ptr_u8; ptr ty_int |] ruby_value;
    e "rb_require" [| ptr_u8 |] ruby_value;
    e "rb_gc_register_address" [| ptr ruby_value |] ty_unit;
    e "rb_gc_unregister_address" [| ptr ruby_value |] ty_unit;
    e "rb_gv_set" [| ptr_u8; ruby_value |] ruby_value;
    e "rb_gv_get" [| ptr_u8 |] ruby_value;
    (* std/ffi.tg externs: __sync primitives, dl*, shared refcounts. *)
    e "__sync_bool_compare_and_swap_1" [| ptr_u8; ty_u8; ty_u8 |] ty_bool;
    e "__sync_synchronize" [||] ty_unit;
    e "dlopen" [| ptr_u8; ty_int |] ptr_u8;
    e "dlsym" [| ptr_u8; ptr_u8 |] ptr_u8;
    e "dlclose" [| ptr_u8 |] ty_i32;
    e "dlerror" [||] ptr_u8;
    e "__sync_fetch_and_add" [| ptr ty_uint; ty_uint |] ty_uint;
    e "__sync_fetch_and_sub" [| ptr ty_uint; ty_uint |] ty_uint;
  ]

(* Extra implementations beyond the closure declarations must be listed
   here explicitly; the closure check rejects any other extra. *)
let implemented_allowlist : string list = []

(* Audit §70: collect the host-bound declarations and compare them against
   the implemented binding surface. Requires declared − implemented = {}
   (missing bindings), no signature mismatches, and no un-allowlisted
   extras. Ok = the sorted list of bound symbols; Error = problems. *)
let closure_check (t : t) : (string list, string list) result =
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
  let impl_names = SS.of_list (List.map fst implemented_host_symbols) in
  let missing = SS.diff decl_names impl_names in
  if not (SS.is_empty missing) then
    problem "declared but not implemented: %s" (String.concat ", " (SS.elements missing));
  List.iter
    (fun (name, dsig) ->
      match List.assoc_opt name implemented_host_symbols with
      | None -> ()
      | Some isig ->
          if not (Intrinsic_registry.signature_equal dsig isig) then
            problem "signature mismatch for %s: declared %s vs implemented %s" name
              (Intrinsic_registry.signature_to_string dsig)
              (Intrinsic_registry.signature_to_string isig))
    declared;
  let extras = SS.diff impl_names decl_names in
  let allowlisted = SS.of_list implemented_allowlist in
  let unallowlisted = SS.diff extras allowlisted in
  if not (SS.is_empty unallowlisted) then
    problem "implemented but not declared (not allowlisted): %s"
      (String.concat ", " (SS.elements unallowlisted));
  match List.rev !problems with
  | [] -> Ok (SS.elements (SS.union (SS.inter decl_names impl_names) extras))
  | ps -> Error ps
