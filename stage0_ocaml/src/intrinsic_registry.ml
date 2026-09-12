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
  (* re-audit P0-C: the intrinsic/extern signature carries the full
     ParamType (convention + type), so MIR verification can enforce
     argument effects and types with the same strength as User calls *)
  params : Type_repr.param_type array;
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

(* re-audit P0 (intrinsic MIR verification): the id-based lookup — the
   manifest's declaration order is the id domain the lowerer mints
   (Intrinsic_registry.Id.to_int of the lookup result), so the verifier
   can resolve a raw id back to its declared signature and check arity,
   argument effects and the destination *)
let by_id (t : t) (i : int) : (string * Id.t * signature) option =
  let rec go = function
    | [] -> None
    | (n, (id, s)) :: rest ->
        if Id.to_int id = i then Some (n, id, s) else go rest
  in
  go t.by_name

let names (t : t) : string list =
  List.sort compare (List.map fst t.by_name)

(* ── The sanctioned record-visit names (the ref-alpha exception) ─────
   The five `__intrinsic_{map,set}_visit_*` declarations in
   std/collections.tg are the kernel's documented internal
   address/reference ABI — the only `&T` / `Option[&K]` positions in the
   tree.  They ARE expressible on the seed value model (the Host's
   record-visit adapters), so exactly these declarations classify and
   verify with the standard alpha rules for `Ref_internal` rather than
   the strict structural ref escape:
     - typecheck.ml's registry_decl_exact (the classification gate),
     - mir_verify.ml's intrinsic bind (the MIR signature check).
   Every other ref/pointer-bearing declaration keeps the strict escape;
   this is ONE closed name list, never a blanket weakening. *)
let record_visit_names : string list =
  [
    "__intrinsic_map_visit_begin";
    "__intrinsic_map_visit_next";
    "__intrinsic_map_visit_value";
    "__intrinsic_set_visit_begin";
    "__intrinsic_set_visit_next";
  ]

let is_record_visit_name (name : string) : bool = List.mem name record_visit_names

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
  (* The Result / raw-Ptr / PtrMut families of the called __intrinsic_*
     wrapper surface (the std parse_int Result returns, the as_ptr /
     mem_alloc pointer returns).  These placeholders live OUTSIDE the
     legacy 1..7 ids and are adopted onto the checker LangItem ids by the
     ONE table (Signature_identity.registry_type_to_checker), exactly
     like option_/vec/map/set. *)
  let result_ = Ids.Type_id.make 8
  let ptr_ = Ids.Type_id.make 9
  let ptrmut_ = Ids.Type_id.make 10
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
let ty_u64 : Type_repr.t = Type_repr.Int Type_repr.U64
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
let tuple_of (elems : Type_repr.t array) : Type_repr.t = Type_repr.Tuple elems
let map_of (k : Type_repr.t) (v : Type_repr.t) : Type_repr.t = named Type_id.map [| k; v |]
let set_of (t : Type_repr.t) : Type_repr.t = named Type_id.set [| t |]
let result_of (a : Type_repr.t) (b : Type_repr.t) : Type_repr.t =
  named Type_id.result_ [| a; b |]
(* The NAMED raw-pointer families: source `Ptr[T]` / `PtrMut[T]` resolve
   to the checker's LangItem nominals (Typecheck.b_ptr/b_ptrmut), not to
   the structural Raw_ptr form — the closures compare them exactly after
   the shared adoption table maps these placeholders onto those ids. *)
let ptr_named (t : Type_repr.t) : Type_repr.t = named Type_id.ptr_ [| t |]
let ptrmut_named (t : Type_repr.t) : Type_repr.t = named Type_id.ptrmut_ [| t |]
(* `fn() -> T` — the zero-argument function type (__intrinsic_try_invoke). *)
let fn0 (ret : Type_repr.t) : Type_repr.t = Type_repr.Function ([||], ret)
let ruby_value : Type_repr.t = named Type_id.ruby_value [||]
let ruby_id : Type_repr.t = named Type_id.ruby_id [||]
let param (id : Ids.Generic_param_id.t) : Type_repr.t = Type_repr.Type_param id

let sig_ ~(params : Type_repr.t array) ~(ret : Type_repr.t) : signature =
  { params = Array.map (fun t -> { Type_repr.pt_type = t; pt_convention = Access_effect.Let }) params;
    ret }

(* the convention-aware signature: the collection self-args and the
   inout intrinsics declare their exact access conventions *)
let sig_conv ~(params : (Access_effect.t * Type_repr.t) array)
    ~(ret : Type_repr.t) : signature =
  {
    params =
      Array.map
        (fun (c, t) -> { Type_repr.pt_type = t; pt_convention = c })
        params;
    ret;
  }

(* Structural equality and rendering (used by the closure check's
   signature-mismatch reporting). *)
let signature_equal (a : signature) (b : signature) : bool =
  Array.length a.params = Array.length b.params
  && Type_repr.compare a.ret b.ret = 0
  && Array.for_all2
       (fun x y -> Type_repr.compare x.Type_repr.pt_type y.Type_repr.pt_type = 0)
       a.params b.params

let named_name (id : Ids.Type_id.t) : string =
  let n = Ids.Type_id.to_int id in
  if n = Ids.Type_id.to_int Type_id.option_ then "Option"
  else if n = Ids.Type_id.to_int Type_id.vec then "Vec"
  else if n = Ids.Type_id.to_int Type_id.map then "Map"
  else if n = Ids.Type_id.to_int Type_id.set then "Set"
  else if n = Ids.Type_id.to_int Type_id.array_ then "Array"
  else if n = Ids.Type_id.to_int Type_id.ruby_value then "RubyValue"
  else if n = Ids.Type_id.to_int Type_id.ruby_id then "RubyID"
  else if n = Ids.Type_id.to_int Type_id.result_ then "Result"
  else if n = Ids.Type_id.to_int Type_id.ptr_ then "Ptr"
  else if n = Ids.Type_id.to_int Type_id.ptrmut_ then "PtrMut"
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
  | Type_repr.Infer_var v -> Printf.sprintf "?#%d" v
  | Type_repr.Int_literal _ -> "int-literal"
  | Type_repr.Error -> "error"
  | Type_repr.Never -> "!"

let signature_to_string (s : signature) : string =
  "(" ^ String.concat ", " (Array.to_list (Array.map (fun p -> ty_to_string p.Type_repr.pt_type) s.params))
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
      ( "__intrinsic_map_new",
        sig_ ~params:[||] ~ret:(map_of (param Type_param.k) (param Type_param.v)) );
      ( "__intrinsic_map_get",
        sig_
          ~params:[| map_of (param Type_param.k) (param Type_param.v); param Type_param.k |]
          ~ret:(option_of (param Type_param.v)) );
      ( "__intrinsic_map_insert",
        sig_conv
          ~params:
            [| (Access_effect.Inout, map_of (param Type_param.k) (param Type_param.v));
               (Access_effect.Sink, param Type_param.k);
               (Access_effect.Sink, param Type_param.v) |]
          ~ret:(option_of (param Type_param.v)) );
      ( "__intrinsic_map_contains_key",
        sig_
          ~params:[| map_of (param Type_param.k) (param Type_param.v); param Type_param.k |]
          ~ret:ty_bool );
      ( "__intrinsic_map_len",
        sig_ ~params:[| map_of (param Type_param.k) (param Type_param.v) |] ~ret:ty_int );
      ( "__intrinsic_map_entries",
        sig_
          ~params:[| map_of (param Type_param.k) (param Type_param.v) |]
          ~ret:(vec_of (tuple_of [| param Type_param.k; param Type_param.v |])) );
      ( "__intrinsic_set_new",
        sig_ ~params:[||] ~ret:(set_of (param Type_param.t)) );
      ( "__intrinsic_set_insert",
        sig_conv
          ~params:
            [| (Access_effect.Inout, set_of (param Type_param.t));
               (Access_effect.Sink, param Type_param.t) |]
          ~ret:ty_bool );
      ( "__intrinsic_set_contains",
        sig_ ~params:[| set_of (param Type_param.t); param Type_param.t |] ~ret:ty_bool );
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
        sig_conv
          ~params:
            [| (Access_effect.Inout, set_of (param Type_param.t));
               (Access_effect.Let, param Type_param.t) |]
          ~ret:ty_bool );
      ( "__intrinsic_set_drain_one",
        sig_conv
          ~params:[| (Access_effect.Inout, set_of (param Type_param.t)) |]
          ~ret:(option_of (param Type_param.t)) );
      ( "__intrinsic_set_len",
        sig_ ~params:[| set_of (param Type_param.t) |] ~ret:ty_int );
      ( "__intrinsic_set_clear",
        sig_conv
          ~params:[| (Access_effect.Inout, set_of (param Type_param.t)) |]
          ~ret:ty_unit );
      ( "__intrinsic_set_entries",
        sig_ ~params:[| set_of (param Type_param.t) |] ~ret:(vec_of (param Type_param.t)) );
      (* The Vec/Array host surface (std/collections.tg + std/core.tg's
         extern declarations — the growable-array family).  The runtime
         form is the checker's Array nominal (Vec/Array/List are name
         aliases of the same nominal), so the declared signatures use the
         `vec` placeholder, which the verifier maps onto the checker's
         Array id (mir_verify.registry_type_to_checker).  The pop/get
         VALUE ABIs and the inout mutation conventions transcribe the
         extern declarations exactly (pop -> Option[T] via the runtime
         empty/Some contract; get is the CHECKED value read — the std
         OOB policy is a panic, which the host binding enforces as a
         deterministic trap). *)
      ( "__intrinsic_array_new",
        sig_ ~params:[||] ~ret:(vec_of (param Type_param.t)) );
      ( "__intrinsic_array_with_capacity",
        sig_ ~params:[| ty_int |] ~ret:(vec_of (param Type_param.t)) );
      ( "__intrinsic_array_len",
        sig_ ~params:[| vec_of (param Type_param.t) |] ~ret:ty_int );
      ( "__intrinsic_array_capacity",
        sig_ ~params:[| vec_of (param Type_param.t) |] ~ret:ty_int );
      ( "__intrinsic_array_push",
        sig_conv
          ~params:
            [| (Access_effect.Inout, vec_of (param Type_param.t));
               (Access_effect.Sink, param Type_param.t) |]
          ~ret:ty_unit );
      ( "__intrinsic_array_pop",
        sig_conv
          ~params:[| (Access_effect.Inout, vec_of (param Type_param.t)) |]
          ~ret:(option_of (param Type_param.t)) );
      ( "__intrinsic_array_get",
        sig_
          ~params:[| vec_of (param Type_param.t); ty_int |]
          ~ret:(param Type_param.t) );
      ( "__intrinsic_array_set",
        sig_conv
          ~params:
            [| (Access_effect.Inout, vec_of (param Type_param.t));
               (Access_effect.Let, ty_int);
               (Access_effect.Sink, param Type_param.t) |]
          ~ret:ty_unit );
      ( "__intrinsic_array_remove",
        sig_conv
          ~params:
            [| (Access_effect.Inout, vec_of (param Type_param.t));
               (Access_effect.Let, ty_int) |]
          ~ret:(param Type_param.t) );
      ( "__intrinsic_array_insert",
        sig_conv
          ~params:
            [| (Access_effect.Inout, vec_of (param Type_param.t));
               (Access_effect.Let, ty_int);
               (Access_effect.Sink, param Type_param.t) |]
          ~ret:ty_unit );
      ( "__intrinsic_array_clear",
        sig_conv
          ~params:[| (Access_effect.Inout, vec_of (param Type_param.t)) |]
          ~ret:ty_unit );
      ( "__intrinsic_array_contains",
        sig_
          ~params:[| vec_of (param Type_param.t); param Type_param.t |]
          ~ret:ty_bool );
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
      (* The borrowed `str` view surface (std/core.tg's impl str block).
         `str::to_string` produces the owned String from the borrowed
         view; on the seed's value model `str` and String are the ONE
         String value (the owned conversion is the identity on the
         immutable value), so the declaration is the exact source
         transcription.  New ids are appended, never renumbered. *)
      ("__intrinsic_str_to_string", sig_ ~params:[| ty_string |] ~ret:ty_string);
      (* ── The called kernel wrapper surface (std/core.tg, alloc.tg,
         collections.tg, taint.tg declarations, transcribed exactly).
         Every entry here is a real source `extern def` name the checker
         registers with this exact signature; the host binding table
         implements each one (Host.binding_manifest).  Appended after
         the legacy surface so existing ids never move. *)

      (* the borrowed `str` view: len/find/slice on the same String value
         the owned surface uses; parse_int returns the Result pair
         (Ok parsed / Err message). *)
      ("__intrinsic_str_len", sig_ ~params:[| ty_string |] ~ret:ty_int);
      ("__intrinsic_str_find",
        sig_ ~params:[| ty_string; ty_string |] ~ret:(option_of ty_int));
      ("__intrinsic_str_slice",
        sig_ ~params:[| ty_string; ty_int; ty_int |] ~ret:ty_string);
      ("__intrinsic_str_parse_int",
        sig_ ~params:[| ty_string |] ~ret:(result_of ty_int ty_string));

      (* the owned String surface: view conversions, search/slice,
         parsing, growth (inout), transformation, splitting, bytes. *)
      ("__intrinsic_string_as_str", sig_ ~params:[| ty_string |] ~ret:ty_string);
      ("__intrinsic_string_from_static",
        sig_ ~params:[| ty_string |] ~ret:ty_string);
      ("__intrinsic_string_find",
        sig_ ~params:[| ty_string; ty_string |] ~ret:(option_of ty_int));
      ("__intrinsic_string_slice",
        sig_ ~params:[| ty_string; ty_int; ty_int |] ~ret:ty_string);
      ("__intrinsic_string_parse_int",
        sig_ ~params:[| ty_string |] ~ret:(result_of ty_int ty_string));
      ("__intrinsic_string_parse_float",
        sig_ ~params:[| ty_string |] ~ret:(option_of ty_float));
      ("__intrinsic_string_reserve",
        sig_conv
          ~params:[| (Access_effect.Inout, ty_string); (Access_effect.Let, ty_int) |]
          ~ret:ty_unit);
      ("__intrinsic_string_push",
        sig_conv
          ~params:
            [| (Access_effect.Inout, ty_string); (Access_effect.Let, Type_repr.Char) |]
          ~ret:ty_unit);
      ("__intrinsic_string_push_str",
        sig_conv
          ~params:[| (Access_effect.Inout, ty_string); (Access_effect.Let, ty_string) |]
          ~ret:ty_unit);
      ("__intrinsic_string_replace",
        sig_ ~params:[| ty_string; ty_string; ty_string |] ~ret:ty_string);
      ("__intrinsic_string_trim", sig_ ~params:[| ty_string |] ~ret:ty_string);
      ("__intrinsic_string_trim_matches",
        sig_ ~params:[| ty_string; ty_string |] ~ret:ty_string);
      ("__intrinsic_string_to_lowercase",
        sig_ ~params:[| ty_string |] ~ret:ty_string);
      ("__intrinsic_string_to_uppercase",
        sig_ ~params:[| ty_string |] ~ret:ty_string);
      ("__intrinsic_string_split",
        sig_ ~params:[| ty_string; ty_string |] ~ret:(vec_of ty_string));
      ("__intrinsic_string_lines", sig_ ~params:[| ty_string |] ~ret:(vec_of ty_string));
      ("__intrinsic_string_as_bytes",
        sig_ ~params:[| ty_string |] ~ret:(vec_of ty_u8));
      ("__intrinsic_string_as_ptr",
        sig_ ~params:[| ty_string |] ~ret:(ptr_named ty_u8));

      (* the Float conversion/formatting surface. *)
      ("__intrinsic_float_to_string",
        sig_ ~params:[| ty_float |] ~ret:ty_string);
      ("__intrinsic_float_to_bits", sig_ ~params:[| ty_float |] ~ret:ty_u64);
      ("__intrinsic_int_to_float", sig_ ~params:[| ty_int |] ~ret:ty_float);
      ("__intrinsic_float_to_int", sig_ ~params:[| ty_float |] ~ret:ty_int);
      ("__intrinsic_pow",
        sig_ ~params:[| ty_float; ty_float |] ~ret:ty_float);
      ("__intrinsic_exp", sig_ ~params:[| ty_float |] ~ret:ty_float);

      (* the growable-array family's remaining operations. *)
      ("__intrinsic_array_destroy",
        sig_conv ~params:[| (Access_effect.Inout, vec_of (param Type_param.t)) |]
          ~ret:ty_unit);
      ("__intrinsic_array_extend",
        sig_conv
          ~params:
            [| (Access_effect.Inout, vec_of (param Type_param.t));
               (Access_effect.Let, vec_of (param Type_param.t)) |]
          ~ret:ty_unit);
      ("__intrinsic_array_from_list",
        sig_ ~params:[| vec_of (param Type_param.t) |]
          ~ret:(vec_of (param Type_param.t)));
      ("__intrinsic_array_slice",
        sig_
          ~params:[| vec_of (param Type_param.t); ty_int; ty_int |]
          ~ret:(vec_of (param Type_param.t)));
      ("__intrinsic_array_as_ptr",
        sig_ ~params:[| vec_of (param Type_param.t) |]
          ~ret:(ptr_named (param Type_param.t)));
      ("__intrinsic_array_as_mut_ptr",
        sig_conv ~params:[| (Access_effect.Inout, vec_of (param Type_param.t)) |]
          ~ret:(ptrmut_named (param Type_param.t)));

      (* the Map removal/drain/destroy surface. *)
      ("__intrinsic_map_remove",
        sig_conv
          ~params:
            [| (Access_effect.Inout, map_of (param Type_param.k) (param Type_param.v));
               (Access_effect.Let, param Type_param.k) |]
          ~ret:(option_of (param Type_param.v)));
      ("__intrinsic_map_clear",
        sig_conv
          ~params:[| (Access_effect.Inout, map_of (param Type_param.k) (param Type_param.v)) |]
          ~ret:ty_unit);
      ("__intrinsic_map_drain_one",
        sig_conv
          ~params:[| (Access_effect.Inout, map_of (param Type_param.k) (param Type_param.v)) |]
          ~ret:
            (option_of
               (tuple_of [| param Type_param.k; param Type_param.v |])));
      ("__intrinsic_map_destroy",
        sig_conv
          ~params:[| (Access_effect.Inout, map_of (param Type_param.k) (param Type_param.v)) |]
          ~ret:ty_unit);

      (* the Set destroy surface. *)
      ("__intrinsic_set_destroy",
        sig_conv ~params:[| (Access_effect.Inout, set_of (param Type_param.t)) |]
          ~ret:ty_unit);

      (* the raw-memory, syscall, control-flow and regex wrapper surface. *)
      ("__intrinsic_mem_alloc",
        sig_ ~params:[| ty_uint |] ~ret:(ptr_named ty_u8));
      ("__intrinsic_mem_free",
        sig_ ~params:[| ptr_named ty_u8; ty_uint |] ~ret:ty_unit);
      ("__intrinsic_syscall1", sig_ ~params:[| ty_int; ty_int |] ~ret:ty_int);
      ("__intrinsic_syscall2",
        sig_ ~params:[| ty_int; ty_int; ty_int |] ~ret:ty_int);
      ("__intrinsic_syscall3",
        sig_ ~params:[| ty_int; ty_int; ty_int; ty_int |] ~ret:ty_int);
      ("__intrinsic_syscall4",
        sig_ ~params:[| ty_int; ty_int; ty_int; ty_int; ty_int |] ~ret:ty_int);
      ("__intrinsic_syscall5",
        sig_ ~params:[| ty_int; ty_int; ty_int; ty_int; ty_int; ty_int |]
          ~ret:ty_int);
      ("__intrinsic_syscall6",
        sig_
          ~params:[| ty_int; ty_int; ty_int; ty_int; ty_int; ty_int; ty_int |]
          ~ret:ty_int);
      ("__intrinsic_try_invoke",
        sig_ ~params:[| fn0 (param Type_param.t) |]
          ~ret:(option_of (param Type_param.t)));
      ("__intrinsic_longjmp", sig_ ~params:[| ty_int |] ~ret:ty_unit);
      (* std/taint.tg's checker-registered pattern validator: the
         documented literal-substring matcher subset (the runtime's
         _tg_regex_match). *)
      ("__intrinsic_regex_match",
        sig_ ~params:[| ty_string; ty_string |] ~ret:ty_bool);

      (* ── The builtin-method class (the checker's builtin method
         tables and compiler-registered free builtins that carried no
         registry binding, so every call classified User and the mono
         audit kept a body-less callee).  Each declaration transcribes
         the checker's registered signature EXACTLY (receiver first,
         same access conventions); the host binding table implements
         each one on the seed's value model with the same observable
         semantics as the direct kernel (codegen intrinsic arms /
         runtime helpers where they exist, deterministic traps where
         the seed host genuinely has no executable surface).  Appended
         after every existing entry so ids never move. *)

      (* Vec/Array receiver methods (m_vec/m_array builtin tables). *)
      ("__intrinsic_array_is_empty",
        sig_ ~params:[| vec_of (param Type_param.t) |] ~ret:ty_bool);
      ("__intrinsic_array_first",
        sig_ ~params:[| vec_of (param Type_param.t) |]
          ~ret:(option_of (param Type_param.t)));
      ("__intrinsic_array_last",
        sig_ ~params:[| vec_of (param Type_param.t) |]
          ~ret:(option_of (param Type_param.t)));
      ("__intrinsic_array_resize",
        sig_conv
          ~params:
            [| (Access_effect.Inout, vec_of (param Type_param.t));
               (Access_effect.Let, ty_int);
               (Access_effect.Sink, param Type_param.t) |]
          ~ret:ty_unit);
      ("__intrinsic_array_sort",
        sig_conv ~params:[| (Access_effect.Inout, vec_of (param Type_param.t)) |]
          ~ret:ty_unit);
      ("__intrinsic_array_truncate",
        sig_conv
          ~params:
            [| (Access_effect.Inout, vec_of (param Type_param.t));
               (Access_effect.Let, ty_int) |]
          ~ret:ty_unit);

      (* String char/iteration/construction surface. *)
      ("__intrinsic_string_char_at",
        sig_ ~params:[| ty_string; ty_int |] ~ret:Type_repr.Char);
      ("__intrinsic_string_chars",
        sig_ ~params:[| ty_string |] ~ret:(vec_of Type_repr.Char));
      (* the constructor is declared under its bare checker name: the
         qualified `String::new(...)` form resolves to the free
         `string_new` builtin (the checker's mangled fallback) and
         classifies through host_binding_of_name — never through the
         owner/method alias channel, so a user-defined `impl String`
         `new` method is not shadowed. *)
      ("string_new", sig_ ~params:[||] ~ret:ty_string);
      ("__intrinsic_string_from_chars",
        sig_ ~params:[| vec_of Type_repr.Char |] ~ret:ty_string);
      ("__intrinsic_string_from_bytes",
        sig_ ~params:[| vec_of ty_u8 |] ~ret:ty_string);
      (* the clone builtin is declared under its bare checker name: the
         source `impl String { def clone }` body's `string_clone(self)`
         call is the registered-only free function; declaring it under
         the owner/method alias name (`__intrinsic_string_clone`) would
         shadow the source `String::clone` method itself. *)
      ("string_clone", sig_ ~params:[| ty_string |] ~ret:ty_string);

      (* the integer to_string surface (m_int/m_uint/m_small_int). *)
      ("__intrinsic_uint_to_string", sig_ ~params:[| ty_uint |] ~ret:ty_string);
      ("__intrinsic_i8_to_string",
        sig_ ~params:[| Type_repr.Int Type_repr.I8 |] ~ret:ty_string);
      ("__intrinsic_i16_to_string",
        sig_ ~params:[| Type_repr.Int Type_repr.I16 |] ~ret:ty_string);
      ("__intrinsic_i32_to_string",
        sig_ ~params:[| Type_repr.Int Type_repr.I32 |] ~ret:ty_string);
      ("__intrinsic_i64_to_string",
        sig_ ~params:[| Type_repr.Int Type_repr.I64 |] ~ret:ty_string);
      ("__intrinsic_i128_to_string",
        sig_ ~params:[| Type_repr.Int Type_repr.I128 |] ~ret:ty_string);
      ("__intrinsic_u8_to_string",
        sig_ ~params:[| Type_repr.Int Type_repr.U8 |] ~ret:ty_string);
      ("__intrinsic_u16_to_string",
        sig_ ~params:[| Type_repr.Int Type_repr.U16 |] ~ret:ty_string);
      ("__intrinsic_u32_to_string",
        sig_ ~params:[| Type_repr.Int Type_repr.U32 |] ~ret:ty_string);
      ("__intrinsic_u64_to_string",
        sig_ ~params:[| Type_repr.Int Type_repr.U64 |] ~ret:ty_string);
      ("__intrinsic_u128_to_string",
        sig_ ~params:[| Type_repr.Int Type_repr.U128 |] ~ret:ty_string);

      (* Char predicates/conversions (m_char builtin table). *)
      ("__intrinsic_char_is_digit",
        sig_ ~params:[| Type_repr.Char |] ~ret:ty_bool);
      ("__intrinsic_char_to_int",
        sig_ ~params:[| Type_repr.Char |] ~ret:ty_int);

      (* the raw-pointer receiver methods (the checker registers their
         typed sigs; the seed host has no VM memory handle, so the
         dereferencing ops are deterministic traps — as_mut is the
         address-preserving cast). *)
      ("__intrinsic_ptr_write",
        sig_conv
          ~params:
            [| (Access_effect.Let, ptr_named (param Type_param.t));
               (Access_effect.Sink, param Type_param.t) |]
          ~ret:ty_unit);
      ("__intrinsic_ptr_read",
        sig_ ~params:[| ptr_named (param Type_param.t) |]
          ~ret:(param Type_param.t));
      ("__intrinsic_ptr_as_mut",
        sig_ ~params:[| ptr_named (param Type_param.t) |]
          ~ret:(ptrmut_named (param Type_param.t)));

      (* Option::expect (the None case is the std panic). *)
      ("__intrinsic_option_expect",
        sig_conv
          ~params:
            [| (Access_effect.Sink, option_of (param Type_param.t));
               (Access_effect.Let, ty_string) |]
          ~ret:(param Type_param.t));

      (* compiler-registered free builtins: the a64 condition-code
         constant and Vec::filled.  (memcpy / sched_yield /
         __sync_bool_compare_and_swap_1 are source `extern` declarations
         and live in Extern_registry, exactly as spelled in the
         closure.) *)
      ("__intrinsic_a64_cc_hi",
        sig_ ~params:[||] ~ret:(Type_repr.Int Type_repr.U32));
      ("__intrinsic_vec_filled",
        sig_ ~params:[| ty_int; param Type_param.t |]
          ~ret:(vec_of (param Type_param.t)));
    ]
  in
  let tbl = ref empty in
  List.iteri (fun i (name, s) -> tbl := register !tbl ~name ~id:(Id.make i) s) entries;
  !tbl
