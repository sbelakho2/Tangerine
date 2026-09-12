(* extern_registry.ml — the extern table (audit §70).

   Pre-populated with the extern declarations of the manifest closure:
   std/ffi.tg's extern blocks (the Ruby C API, the __sync_* primitives,
   and the dl* loader family). tg_compiler/asm.tg declares no externs
   (x64_call_extern is a plain function). Signatures are transcribed
   exactly from the extern declarations; the table is the
   declared-host-symbol side of the closure check (Host.closure_check). *)

(* Abstract id type: see Intrinsic_registry.Id — an extern id is its own
   type, constructed only here, so it can never be confused with an
   intrinsic id or a raw index. *)
module Id = struct
  type t = int

  let make (i : int) : t = i
  let to_int (id : t) : int = id
end

type signature = Intrinsic_registry.signature

type t = {
  by_name : (string * (Id.t * signature)) list;
}

let empty : t = { by_name = [] }

let register (t : t) ~name ~(id : Id.t) (sig_ : signature) : t =
  { by_name = (name, (id, sig_)) :: t.by_name }

let lookup (t : t) ~name : (Id.t * signature) option =
  List.assoc_opt name t.by_name

let names (t : t) : string list =
  List.sort compare (List.map fst t.by_name)

let manifest : t =
  let sig_ = Intrinsic_registry.sig_ in
  let ty_unit = Intrinsic_registry.ty_unit in
  let ty_bool = Intrinsic_registry.ty_bool in
  let ty_int = Intrinsic_registry.ty_int in
  let ty_uint = Intrinsic_registry.ty_uint in
  let ty_u8 = Intrinsic_registry.ty_u8 in
  let ty_i32 = Intrinsic_registry.ty_i32 in
  let ty_float = Intrinsic_registry.ty_float in
  let ty_string = Intrinsic_registry.ty_string in
  let ptr = Intrinsic_registry.ptr in
  let ptr_u8 = Intrinsic_registry.ptr_u8 in
  (* the NAMED Ptr placeholder family: source `Ptr[T]` / `PtrMut[T]`
     annotations resolve to the checker's LangItem nominals, so a
     declaration transcribed from the source spelling must use the named
     placeholders (the shared adoption table maps them onto the checker
     ids); the structural Raw_ptr form never matches a checker-side
     `Ptr[T]`. *)
  let ptr_named = Intrinsic_registry.ptr_named in
  let ptrmut_named = Intrinsic_registry.ptrmut_named in
  let vec_of = Intrinsic_registry.vec_of in
  let ruby_value = Intrinsic_registry.ruby_value in
  let ruby_id = Intrinsic_registry.ruby_id in
  let e name params ret = (name, sig_ ~params ~ret) in
  let entries =
    [
      (* std/ffi.tg — Ruby C API block, in declaration order. *)
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
      (* std/ffi.tg — __sync primitives (Ruby runtime lock).  The atomic
         CAS takes `Ptr[u8]` (the named LangItem pointer), transcribed
         with the named placeholder so the checker's `Ptr[u8]` call
         signature matches. *)
      e "__sync_bool_compare_and_swap_1" [| ptr_named ty_u8; ty_u8; ty_u8 |] ty_bool;
      e "__sync_synchronize" [||] ty_unit;
      (* std/alloc.tg — the allocator's libc/thread surface: the byte
         copy and the scheduler yield. *)
      e "memcpy" [| ptr_named ty_u8; ptr_named ty_u8; ty_uint |] (ptr_named ty_u8);
      e "sched_yield" [||] ty_i32;
      (* std/ffi.tg — dynamic library loading. *)
      e "dlopen" [| ptr_u8; ty_int |] ptr_u8;
      e "dlsym" [| ptr_u8; ptr_u8 |] ptr_u8;
      e "dlclose" [| ptr_u8 |] ty_i32;
      e "dlerror" [||] ptr_u8;
      (* std/ffi.tg — shared refcount primitives. *)
      e "__sync_fetch_and_add" [| ptr ty_uint; ty_uint |] ty_uint;
      e "__sync_fetch_and_sub" [| ptr ty_uint; ty_uint |] ty_uint;
      (* std/args.tg — the kernel argv channel.  The seed host hands the
         mono'd kernel its argv (Host.argv — the same array Vm.run
         receives); the kernel's argc/argv externs read it through this
         declared surface. *)
      e "tg_get_argc" [||] ty_int;
      e "_tg_arg_copy" [| ty_int |] ty_string;
      (* ── The process / descriptor / environment extern surface (audit
         §70; std/process.tg, std/fs.tg, std/env.tg, and the linker /
         compiler_core io externs).  Signatures are transcribed exactly
         from the source `extern def` declarations; `Ptr[T]/PtrMut[T]`
         use the NAMED wrapper placeholders (the checker's LangItem
         nominals — see Signature_identity.registry_type_to_checker),
         and Vec[u8] uses the vec placeholder (the checker's Array
         nominal).  Ids are appended after the existing surface, never
         renumbered.

         `libc_close` is declared twice in the closure with the SAME
         parameter list but different integer-kind returns
         (std/process.tg: `-> i32`; tg_compiler/linker.tg: `-> Int`).
         The registry carries the std declaration; the checker's
         C-integer-kind adoption (mir_verify.intrinsic_type_compatible's
         rule) lets the linker spelling classify against it — see
         Typecheck.registry_decl_exact_extern. *)
      e "_tg_env_entry" [| ty_int |] (ptr_named ty_u8);
      e "_tg_env_count" [||] ty_int;
      e "_tg_str_skip" [| ptr_named ty_u8; ty_int |] (ptr_named ty_u8);
      e "c_fork" [||] ty_i32;
      e "execvp" [| ptr_named ty_u8; ptr_named (ptr_named ty_u8) |] ty_i32;
      e "c_waitpid" [| ty_i32; ptrmut_named ty_int; ty_i32 |] ty_i32;
      e "_exit" [| ty_int |] Type_repr.Never;
      e "pipe" [| ptrmut_named ty_int |] ty_i32;
      e "dup2" [| ty_int; ty_int |] ty_i32;
      e "libc_close" [| ty_int |] ty_i32;
      e "libc_read" [| ty_int; ptrmut_named ty_u8; ty_uint |] ty_int;
      e "libc_write" [| ty_int; ptr_named ty_u8; ty_uint |] ty_int;
      e "_tg_write_vec_u8" [| ty_int; vec_of ty_u8; ty_uint |] ty_int;
      e "libc_open" [| ptr_named ty_u8; ty_int |] ty_i32;
      e "poll" [| ptr_named ty_u8; ty_uint; ty_int |] ty_i32;
      e "libc_open_path" [| ptr_named ty_u8; ty_int; ty_int |] ty_int;
      e "libc_chmod" [| ptr_named ty_u8; ty_int |] ty_int;
    ]
  in
  let tbl = ref empty in
  List.iteri (fun i (name, s) -> tbl := register !tbl ~name ~id:(Id.make i) s) entries;
  !tbl
