(* intrinsic_registry.ml — the intrinsic table (audit §70).

   Records every intrinsic the bootstrap closure declares, transcribed by
   name and signature from the extern declarations in the closure sources
   (std/collections.tg's map/set record-visit and set algebra surface).
   The table is the declared-host-symbol side of the closure check
   (Host.closure_check). Ids are stable 0-based manifest-order indices;
   the name is the sole identity. *)

(* Abstract id type: the host ids are distinct from bare ints, so a host
   binding keyed on Intrinsic_registry.Id.t can never be confused with an
   Extern_registry id or with Seed_mir's raw index ints. The .ml keeps
   `type t = int` (structural equality works); only this module can
   construct ids (make), and the VM dispatch converts back with to_int. *)
module Id = struct
  type t = int

  let make (i : int) : t = i
  let to_int (id : t) : int = id
end

type signature = {
  params : Type_repr.t array;
  ret : Type_repr.t;
}

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

(* ———————————————————————————————————————————————————————————————
   Signature building blocks, shared with Extern_registry and Host.
   Named types are keyed by placeholder Type_ids that are consistent
   across the registries and the host binding table; these signatures are
   never unified with typechecker-assigned ids. *)

module Type_id = struct
  let option_ = Ids.Type_id.make 1
  let vec = Ids.Type_id.make 2
  let map = Ids.Type_id.make 3
  let set = Ids.Type_id.make 4
  let array_ = Ids.Type_id.make 5
  let ruby_value = Ids.Type_id.make 6
  let ruby_id = Ids.Type_id.make 7
end

module Type_param = struct
  (* Generic parameter placeholders: K/V for the map surface, T for the
     set surface. The ids only need to be self-consistent. *)
  let k = Ids.Generic_param_id.make 0
  let v = Ids.Generic_param_id.make 1
  let t = Ids.Generic_param_id.make 0
end

let ty_unit : Type_repr.t = Type_repr.Unit
let ty_bool : Type_repr.t = Type_repr.Bool
let ty_int : Type_repr.t = Type_repr.Int Type_repr.Int
let ty_uint : Type_repr.t = Type_repr.Int Type_repr.UInt
let ty_u8 : Type_repr.t = Type_repr.Int Type_repr.U8
let ty_i32 : Type_repr.t = Type_repr.Int Type_repr.I32
let ty_float : Type_repr.t = Type_repr.Float Type_repr.F64
let ty_string : Type_repr.t = Type_repr.String

let ptr (t : Type_repr.t) : Type_repr.t = Type_repr.Raw_ptr (Type_repr.Immutable, t)
let ptr_u8 : Type_repr.t = ptr ty_u8
let ref_ (t : Type_repr.t) : Type_repr.t = Type_repr.Ref_internal (Type_repr.Immutable, t)
let named (id : Ids.Type_id.t) (args : Type_repr.t array) : Type_repr.t =
  Type_repr.Named (id, args)
let option_of (t : Type_repr.t) : Type_repr.t = named Type_id.option_ [| t |]
let vec_of (t : Type_repr.t) : Type_repr.t = named Type_id.vec [| t |]
let map_of (k : Type_repr.t) (v : Type_repr.t) : Type_repr.t = named Type_id.map [| k; v |]
let set_of (t : Type_repr.t) : Type_repr.t = named Type_id.set [| t |]
let ruby_value : Type_repr.t = named Type_id.ruby_value [||]
let ruby_id : Type_repr.t = named Type_id.ruby_id [||]
let param (id : Ids.Generic_param_id.t) : Type_repr.t = Type_repr.Type_param id

let sig_ ~(params : Type_repr.t array) ~(ret : Type_repr.t) : signature =
  { params; ret }

(* Structural equality and rendering (used by the closure check's
   signature-mismatch reporting). *)
let signature_equal (a : signature) (b : signature) : bool =
  Array.length a.params = Array.length b.params
  && Type_repr.compare a.ret b.ret = 0
  && Array.for_all2 (fun x y -> Type_repr.compare x y = 0) a.params b.params

let named_name (id : Ids.Type_id.t) : string =
  let n = Ids.Type_id.to_int id in
  if n = Ids.Type_id.to_int Type_id.option_ then "Option"
  else if n = Ids.Type_id.to_int Type_id.vec then "Vec"
  else if n = Ids.Type_id.to_int Type_id.map then "Map"
  else if n = Ids.Type_id.to_int Type_id.set then "Set"
  else if n = Ids.Type_id.to_int Type_id.array_ then "Array"
  else if n = Ids.Type_id.to_int Type_id.ruby_value then "RubyValue"
  else if n = Ids.Type_id.to_int Type_id.ruby_id then "RubyID"
  else Printf.sprintf "type#%d" n

let rec ty_to_string (ty : Type_repr.t) : string =
  match ty with
  | Type_repr.Unit -> "Unit"
  | Type_repr.Bool -> "Bool"
  | Type_repr.Char -> "Char"
  | Type_repr.Int k -> (
      match k with
      | Type_repr.I8 -> "i8"
      | Type_repr.I16 -> "i16"
      | Type_repr.I32 -> "i32"
      | Type_repr.I64 -> "i64"
      | Type_repr.I128 -> "i128"
      | Type_repr.U8 -> "u8"
      | Type_repr.U16 -> "u16"
      | Type_repr.U32 -> "u32"
      | Type_repr.U64 -> "u64"
      | Type_repr.U128 -> "u128"
      | Type_repr.Int -> "Int"
      | Type_repr.UInt -> "UInt")
  | Type_repr.Float Type_repr.F32 -> "f32"
  | Type_repr.Float Type_repr.F64 -> "Float"
  | Type_repr.String -> "String"
  | Type_repr.Raw_ptr (Type_repr.Immutable, inner) ->
      Printf.sprintf "Ptr[%s]" (ty_to_string inner)
  | Type_repr.Raw_ptr (Type_repr.Mutable, inner) ->
      Printf.sprintf "PtrMut[%s]" (ty_to_string inner)
  | Type_repr.Ref_internal (Type_repr.Immutable, inner) ->
      Printf.sprintf "&%s" (ty_to_string inner)
  | Type_repr.Ref_internal (Type_repr.Mutable, inner) ->
      Printf.sprintf "&mut %s" (ty_to_string inner)
  | Type_repr.Tuple elems ->
      "(" ^ String.concat ", " (Array.to_list (Array.map ty_to_string elems)) ^ ")"
  | Type_repr.Fixed_array (inner, n) ->
      Printf.sprintf "[%s; %d]" (ty_to_string inner) n
  | Type_repr.Named (id, args) ->
      named_name id
      ^ (if Array.length args > 0 then
           "[" ^ String.concat ", " (Array.to_list (Array.map ty_to_string args)) ^ "]"
         else "")
  | Type_repr.Function (params, ret) ->
      let render (p : Type_repr.param_type) =
        Access_effect.to_string p.Type_repr.pt_convention
        ^ ": " ^ ty_to_string p.Type_repr.pt_type
      in
      Printf.sprintf "fn(%s) -> %s"
        (String.concat ", " (Array.to_list (Array.map render params)))
        (ty_to_string ret)
  | Type_repr.Type_param id -> Printf.sprintf "T%d" (Ids.Generic_param_id.to_int id)
  | Type_repr.Never -> "!"

let signature_to_string (s : signature) : string =
  "(" ^ String.concat ", " (Array.to_list (Array.map ty_to_string s.params))
  ^ ") -> " ^ ty_to_string s.ret

(* ———————————————————————————————————————————————————————————————
   The manifest closure's intrinsic surface: std/collections.tg's extern
   declarations for the map/set record-visit traversal and the set
   algebra, plus the I/O and scalar-conversion surface that the host
   binding table implements (std/io.tg print/println conventions,
   std/core.tg's __intrinsic_* string conversions and abort).
   Signatures transcribed exactly (inout/sink access qualifiers are
   source-level only and have no place in the signature type).

   Ids are stable 0-based manifest-order indices. Existing ids are
   appended to, never renumbered: a host program's intrinsic callee
   indices remain valid across registry edits. *)

let manifest : t =
  let entries =
    [
      ( "__intrinsic_map_visit_begin",
        sig_
          ~params:[| map_of (param Type_param.k) (param Type_param.v) |]
          ~ret:(option_of (ref_ (param Type_param.k))) );
      ( "__intrinsic_map_visit_next",
        sig_
          ~params:
            [| map_of (param Type_param.k) (param Type_param.v); param Type_param.k |]
          ~ret:(option_of (ref_ (param Type_param.k))) );
      ( "__intrinsic_map_visit_value",
        sig_
          ~params:
            [| map_of (param Type_param.k) (param Type_param.v); param Type_param.k |]
          ~ret:(ref_ (param Type_param.v)) );
      ( "__intrinsic_set_visit_begin",
        sig_
          ~params:[| set_of (param Type_param.t) |]
          ~ret:(option_of (ref_ (param Type_param.t))) );
      ( "__intrinsic_set_visit_next",
        sig_
          ~params:[| set_of (param Type_param.t); param Type_param.t |]
          ~ret:(option_of (ref_ (param Type_param.t))) );
      ( "__intrinsic_set_remove",
        sig_ ~params:[| set_of (param Type_param.t); param Type_param.t |] ~ret:ty_bool );
      ( "__intrinsic_set_drain_one",
        sig_
          ~params:[| set_of (param Type_param.t) |]
          ~ret:(option_of (param Type_param.t)) );
      ( "__intrinsic_set_len",
        sig_ ~params:[| set_of (param Type_param.t) |] ~ret:ty_int );
      ( "__intrinsic_set_clear",
        sig_ ~params:[| set_of (param Type_param.t) |] ~ret:ty_unit );
      ( "__intrinsic_set_entries",
        sig_ ~params:[| set_of (param Type_param.t) |] ~ret:(vec_of (param Type_param.t)) );
      (* I/O and conversion surface with real host semantics; the host
         binding table (Host.binding_manifest) implements every one of
         these. panic/abort raise a deterministic host error. *)
      ("print", sig_ ~params:[| ty_string |] ~ret:ty_unit);
      ("println", sig_ ~params:[| ty_string |] ~ret:ty_unit);
      ("panic", sig_ ~params:[| ty_string |] ~ret:Type_repr.Never);
      ("__intrinsic_abort", sig_ ~params:[||] ~ret:ty_unit);
      ("__intrinsic_int_to_string", sig_ ~params:[| ty_int |] ~ret:ty_string);
      ("__intrinsic_bool_to_string", sig_ ~params:[| ty_bool |] ~ret:ty_string);
      ("__intrinsic_char_to_string", sig_ ~params:[| Type_repr.Char |] ~ret:ty_string);
      ("__intrinsic_string_len", sig_ ~params:[| ty_string |] ~ret:ty_int);
    ]
  in
  let tbl = ref empty in
  List.iteri (fun i (name, s) -> tbl := register !tbl ~name ~id:(Id.make i) s) entries;
  !tbl
