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
  let ptr = Intrinsic_registry.ptr in
  let ptr_u8 = Intrinsic_registry.ptr_u8 in
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
      (* std/ffi.tg — __sync primitives (Ruby runtime lock). *)
      e "__sync_bool_compare_and_swap_1" [| ptr_u8; ty_u8; ty_u8 |] ty_bool;
      e "__sync_synchronize" [||] ty_unit;
      (* std/ffi.tg — dynamic library loading. *)
      e "dlopen" [| ptr_u8; ty_int |] ptr_u8;
      e "dlsym" [| ptr_u8; ptr_u8 |] ptr_u8;
      e "dlclose" [| ptr_u8 |] ty_i32;
      e "dlerror" [||] ptr_u8;
      (* std/ffi.tg — shared refcount primitives. *)
      e "__sync_fetch_and_add" [| ptr ty_uint; ty_uint |] ty_uint;
      e "__sync_fetch_and_sub" [| ptr ty_uint; ty_uint |] ty_uint;
    ]
  in
  let tbl = ref empty in
  List.iteri (fun i (name, s) -> tbl := register !tbl ~name ~id:(Id.make i) s) entries;
  !tbl
