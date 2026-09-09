(* type_properties.ml — The type-property authority (audit §30 / P1-25,
   audit P0-2: representation vs ownership).

   ONE engine for the recursive type properties the seed stages consume
   (needs_drop / is_copy / is_sized) — the canonical copyability engine
   (P1-25) every consumer routes its Copy decisions through:
   mir_verify.is_copy, mir_lower.copyable_ty, and the drop-plan
   construction (drop_plan.ml) all call Type_properties; no consumer
   re-implements the recursion.

   ── Representation vs ownership (audit P0-2) ───────────────────────
   The engine distinguishes WHAT a type's value is (its representation)
   from whether the value OWNS memory (its drop/copy properties):

     type representation =
       | Immediate      — scalars / fn pointers / internal references:
                         values with no ownership (Copy, no drop)
       | Raw_pointer    — address handles (Ptr/PtrMut, *T): Copy, no drop
       | Owning_handle  — handle nominals that own memory (Vec/Map/Set/
                         String/Box/Rc/Arc/...): move + clone, NEVER
                         bit-Copy; drop = true
       | Structural     — aggregates whose properties are elementwise
                         (tuples, fixed arrays, structs, enums)

   The property triple is `direct_properties` (is_copy / needs_drop /
   is_sized).  A named type resolves through the caller's
   `resolved_nominal` hook, which answers THREE ways:

     type resolved_nominal =
       | Structural_def of Type_repr.t   (* resolve through this def shape *)
       | Direct_properties of t          (* a LangItem leaf — no def shape *)
       | Unknown                         (* conservative owned *)

   The owned LangItems of the language rule (the collection nominals,
   Box/Rc/Arc — the seed ownership model) and the pointer class are
   answered as Direct_properties from the caller's Lang_items record
   (lang_items.ml) — NEVER faked as tuple def shapes and never keyed on
   numeric builtin ids inside this engine.  Vec/Map/Set/String/Box/
   Rc/Arc → { copy = false; drop = true }; Ptr/PtrMut → { copy = true;
   drop = false }; FnPtr (a Function whose return is not Never) is an
   Immediate.  Option/Result are NOT direct-property LangItems: they are
   enums and resolve through their defs (Copy iff every variant payload
   is Copy).  A Named with no def and no LangItem identity resolves
   conservatively as owned (Unknown), exactly the pre-P0-2 no-def rule.

   Structural rules (canonical, unchanged): scalars (Unit/Bool/Char/
   Int/Float), raw pointers, internal references and genuine function
   pointers (Function with a non-Never return) are Copy and do not need
   drop; String is owned; an ENUM (the def_repr'd Function(payloads,
   Never) shape) is Copy iff EVERY variant payload is Copy and needs
   drop iff any payload does; a struct is Copy iff every field is Copy;
   tuples and fixed arrays are elementwise.  Named types resolve through
   the def-table hook supplied by the caller (the resolver maps a TypeId
   to its definition shape or its direct LangItem answer); when the def
   cannot be resolved the conservative answer is owned.  Type parameters
   and inference variables resolve conservatively as owned.

   CACHING (P1-25 / audit P0-2): results are memoized per canonical NAMED
   instance under a STRUCTURAL key — the key is the full type spine
   (KNamed of (TypeId, key array), KTuple, KArray, KInt of int_kind, ...),
   NEVER a pretty-printed string and NEVER TypeId alone: the same generic
   nominal at different substitutions can answer differently (Wrapper[Int]
   vs Wrapper[String] are different canonical instances and must never
   share one entry).  A cache instance is bound to ONE def table /
   program phase; never share one cache across two tables. *)

(* ── Representation and the property triple ───────────────────────── *)

type representation =
  | Immediate
  | Raw_pointer
  | Owning_handle
  | Structural

type direct_properties = {
  needs_drop : bool;
  is_copy : bool;
  is_sized : bool;
}

(* `t` is the property triple (historical name kept for consumers). *)
type t = direct_properties

(* Immediate / raw-pointer values: Copy, never dropped, sized. *)
let scalar = { needs_drop = false; is_copy = true; is_sized = true }

(* The raw-pointer class (Ptr/PtrMut): Copy, no drop — a first-class
   address value, never an owned allocation. *)
let raw_pointer = { needs_drop = false; is_copy = true; is_sized = true }

(* An owning handle (Vec/Map/Set/String/Box/Rc/Arc/...): owns memory —
   move + clone, never bit-Copy; dropping it releases the memory. *)
let owning_handle = { needs_drop = true; is_copy = false; is_sized = true }

(* The conservative no-information answer (a def-less, non-LangItem
   Named, a residual Type_param/Infer_var/Int_literal/Error): owned. *)
let conservative_owned = owning_handle

(* ── The nominal resolver (audit P0-2) ─────────────────────────────── *)
type resolved_nominal =
  | Structural_def of Type_repr.t
  | Direct_properties of t
  | Unknown

type def_resolver = Ids.Type_id.t -> resolved_nominal

(* The def-table hook: resolve a Named TypeId to its definition shape
   (seed_mir.def_repr: a struct as its field tuple, an enum as
   Function(payloads, Never)); None when the table has no entry. *)
let structural_resolver (find_def : Ids.Type_id.t -> Type_repr.t option) : def_resolver =
  fun tid ->
    match find_def tid with
    | Some def -> Structural_def def
    | None -> Unknown

(* The LangItems overlay: an owning-handle LangItem answers its direct
   properties FIRST (its def — a field-less container declaration — must
   never be misread as an empty structural shape), then a raw-pointer
   LangItem answers Copy; anything else falls through to the def
   resolver.  This is the whole P0-2 direct-property routing — no
   numeric builtin-id knowledge lives in the engine. *)
let direct_properties_of_langitem (li : Lang_items.t) (tid : Ids.Type_id.t) :
    direct_properties option =
  if Lang_items.is_owning_handle li tid then Some owning_handle
  else if Lang_items.is_raw_pointer li tid then Some raw_pointer
  else None

let with_lang_items (li : Lang_items.t option) (r : def_resolver) : def_resolver =
  match li with
  | None -> r
  | Some li ->
      fun tid ->
        match direct_properties_of_langitem li tid with
        | Some p -> Direct_properties p
        | None -> r tid

(* ── The canonical instance cache (P1-25 / audit P0-2) ───────────────
   Keyed by a STRUCTURAL key over the canonical spelling of the full
   type (Named (TypeId, canonical args), with tuples/arrays/pointers/
   functions as spine nodes — never a rendered string): two mentions of
   one generic nominal at different substitutions never collide. *)

type key =
  | KUnit
  | KBool
  | KChar
  | KInt of Type_repr.int_kind
  | KFloat of Type_repr.float_kind
  | KString
  | KPtr of Type_repr.mutability * key
  | KRef of Type_repr.mutability * key
  | KTuple of key array
  | KArray of key * int
  | KNamed of Ids.Type_id.t * key array
  | KFunction of (Type_repr.param_type * key) array * key
  | KTypeParam of Ids.Generic_param_id.t
  | KInfer of int
  | KIntLit of Big_nat.t
  | KError
  | KNever

let rec key_of_type (ty : Type_repr.t) : key =
  match ty with
  | Type_repr.Unit -> KUnit
  | Type_repr.Bool -> KBool
  | Type_repr.Char -> KChar
  | Type_repr.Int k -> KInt k
  | Type_repr.Float k -> KFloat k
  | Type_repr.String -> KString
  | Type_repr.Raw_ptr (m, t) -> KPtr (m, key_of_type t)
  | Type_repr.Ref_internal (m, t) -> KRef (m, key_of_type t)
  | Type_repr.Tuple elems -> KTuple (Array.map key_of_type elems)
  | Type_repr.Fixed_array (e, n) -> KArray (key_of_type e, n)
  | Type_repr.Named (tid, args) -> KNamed (tid, Array.map key_of_type args)
  | Type_repr.Function (params, ret) ->
      KFunction
        ( Array.map (fun (p : Type_repr.param_type) -> (p, key_of_type p.Type_repr.pt_type)) params,
          key_of_type ret )
  | Type_repr.Type_param pid -> KTypeParam pid
  | Type_repr.Infer_var v -> KInfer v
  | Type_repr.Int_literal m -> KIntLit m
  | Type_repr.Error -> KError
  | Type_repr.Never -> KNever

let compare_key_arrays (cmp : 'a -> 'a -> int) (a : 'a array) (b : 'a array) : int =
  let n = Array.length a and m = Array.length b in
  let rec go i =
    if i >= n && i >= m then 0
    else if i >= n then -1
    else if i >= m then 1
    else
      let c = cmp a.(i) b.(i) in
      if c <> 0 then c else go (i + 1)
  in
  go 0

let rec compare_key (a : key) (b : key) : int =
  match a, b with
  | KUnit, KUnit -> 0
  | KBool, KBool -> 0
  | KChar, KChar -> 0
  | KInt k1, KInt k2 -> Stdlib.compare k1 k2
  | KFloat k1, KFloat k2 -> Stdlib.compare k1 k2
  | KString, KString -> 0
  | KPtr (m1, t1), KPtr (m2, t2) ->
      let c = Stdlib.compare m1 m2 in if c <> 0 then c else compare_key t1 t2
  | KRef (m1, t1), KRef (m2, t2) ->
      let c = Stdlib.compare m1 m2 in if c <> 0 then c else compare_key t1 t2
  | KTuple a1, KTuple a2 -> compare_key_arrays compare_key a1 a2
  | KArray (t1, n1), KArray (t2, n2) ->
      let c = Stdlib.compare n1 n2 in if c <> 0 then c else compare_key t1 t2
  | KNamed (i1, a1), KNamed (i2, a2) ->
      let c = Ids.Type_id.compare i1 i2 in
      if c <> 0 then c else compare_key_arrays compare_key a1 a2
  | KFunction (p1, r1), KFunction (p2, r2) ->
      let c =
        compare_key_arrays
          (fun (p1 : Type_repr.param_type * key) (p2 : Type_repr.param_type * key) ->
            let a = fst p1 and b = fst p2 in
            let c = Access_effect.compare a.Type_repr.pt_convention b.Type_repr.pt_convention in
            if c <> 0 then c else compare_key (snd p1) (snd p2))
          p1 p2
      in
      if c <> 0 then c else compare_key r1 r2
  | KTypeParam i1, KTypeParam i2 -> Ids.Generic_param_id.compare i1 i2
  | KInfer i1, KInfer i2 -> Stdlib.compare i1 i2
  | KIntLit v1, KIntLit v2 -> Big_nat.compare v1 v2
  | KError, KError -> 0
  | KNever, KNever -> 0
  | KUnit, _ -> -1 | _, KUnit -> 1
  | KBool, _ -> -1 | _, KBool -> 1
  | KChar, _ -> -1 | _, KChar -> 1
  | KInt _, _ -> -1 | _, KInt _ -> 1
  | KFloat _, _ -> -1 | _, KFloat _ -> 1
  | KString, _ -> -1 | _, KString -> 1
  | KPtr _, _ -> -1 | _, KPtr _ -> 1
  | KRef _, _ -> -1 | _, KRef _ -> 1
  | KTuple _, _ -> -1 | _, KTuple _ -> 1
  | KArray _, _ -> -1 | _, KArray _ -> 1
  | KNamed _, _ -> -1 | _, KNamed _ -> 1
  | KFunction _, _ -> -1 | _, KFunction _ -> 1
  | KTypeParam _, _ -> -1 | _, KTypeParam _ -> 1
  | KInfer _, _ -> -1 | _, KInfer _ -> 1
  | KIntLit _, _ -> -1 | _, KIntLit _ -> 1
  | KError, _ -> -1 | _, KError -> 1

(* Content-stable hash over the key spine (every leaf is int-/variant-/
   int-array-backed — Type_repr carries no float VALUES — so the mixing
   below is deterministic and equal keys always hash alike; the same
   technique canonical_type_instance.ml uses). *)
let hash_key (k : key) : int =
  let h = ref 0x9e3779b9 in
  let mix (v : int) = h := ((!h lxor v) * 1000003) land 0x3FFFFFFF in
  let rec go (k : key) : unit =
    match k with
    | KUnit -> mix 1
    | KBool -> mix 2
    | KChar -> mix 3
    | KInt kd -> mix (4 + Hashtbl.hash kd)
    | KFloat kd -> mix (5 + Hashtbl.hash kd)
    | KString -> mix 6
    | KPtr (m, t) ->
        mix (7 + Hashtbl.hash m);
        go t
    | KRef (m, t) ->
        mix (8 + Hashtbl.hash m);
        go t
    | KTuple elems ->
        mix 9;
        Array.iter go elems
    | KArray (t, n) ->
        mix (10 + n);
        go t
    | KNamed (tid, args) ->
        mix (11 + Ids.Type_id.to_int tid);
        Array.iter go args
    | KFunction (params, ret) ->
        mix 12;
        Array.iter
          (fun (p : Type_repr.param_type * key) ->
            mix (Hashtbl.hash (fst p).Type_repr.pt_convention);
            go (snd p))
          params;
        go ret
    | KTypeParam pid -> mix (13 + Ids.Generic_param_id.to_int pid)
    | KInfer v -> mix (14 + v)
    | KIntLit m ->
        mix 15;
        Array.iter (fun limb -> mix limb) m
    | KError -> mix 16
    | KNever -> mix 17
  in
  go k;
  !h

module Key_tbl = Hashtbl.Make (struct
  type t = key
  let equal (a : key) (b : key) : bool = compare_key a b = 0
  let hash = hash_key
end)

type cache = direct_properties Key_tbl.t

let create_cache () : cache = Key_tbl.create 127

(* ── The recursion ─────────────────────────────────────────────────── *)

let rec combine (elems : direct_properties list) : direct_properties =
  {
    needs_drop = List.exists (fun p -> p.needs_drop) elems;
    is_copy = List.for_all (fun p -> p.is_copy) elems;
    is_sized = List.for_all (fun p -> p.is_sized) elems;
  }

(* The property of one Named INSTANCE (id, args): its def's property
   (the def's own param scope is the def table's business — materialized
   defs are already substituted; template defs mentioning their own
   params resolve those params conservatively) or its direct LangItem
   answer.  The instance answer is cached under the structural
   (TypeId, canonical args) key. *)
and instance_property (resolve : def_resolver option) (cache : cache option)
    (seen : Ids.Type_id.t list) (id : Ids.Type_id.t) : direct_properties =
  match resolve with
  | Some f -> (
      match f id with
      | Structural_def def -> of_type resolve cache (id :: seen) def
      | Direct_properties p -> p
      | Unknown -> conservative_owned)
  | None -> conservative_owned

and of_type (resolve : def_resolver option) (cache : cache option)
    (seen : Ids.Type_id.t list) (ty : Type_repr.t) : direct_properties =
  match ty with
  | Type_repr.Unit | Type_repr.Bool | Type_repr.Char -> scalar
  | Type_repr.Int _ | Type_repr.Float _ -> scalar
  | Type_repr.String -> owning_handle (* the owned String primitive *)
  | Type_repr.Raw_ptr _ -> raw_pointer
  | Type_repr.Ref_internal _ -> scalar
  | Type_repr.Tuple elems ->
      combine
        (List.map (of_type resolve cache seen) (Array.to_list elems))
  | Type_repr.Fixed_array (elem, _) -> of_type resolve cache seen elem
  | Type_repr.Function (params, ret) -> (
      match ret with
      | Type_repr.Never ->
          (* the def_repr'd ENUM encoding: Function(payloads, Never).
             An enum is Copy iff EVERY variant payload is Copy — an enum
             with an owning payload (Result[Int, String]) is NOT
             trivially copyable; it must be moved, consumed or passed by
             place, never bitwise-copied. *)
          combine
            (List.map
               (fun p -> of_type resolve cache seen p.Type_repr.pt_type)
               (Array.to_list params))
      | _ ->
          (* a genuine function pointer is an Immediate value (code
             identity) — the FnPtr LangItem class *)
          scalar)
  | Type_repr.Named (id, _args) ->
      if List.mem id seen then conservative_owned
      else (
        match cache with
        | Some tbl ->
            let key = key_of_type ty in
            (match Key_tbl.find_opt tbl key with
             | Some p -> p
             | None ->
                 let p = instance_property resolve cache seen id in
                 Key_tbl.replace tbl key p;
                 p)
        | None -> instance_property resolve cache seen id)
  | Type_repr.Type_param _ | Type_repr.Infer_var _ | Type_repr.Int_literal _ | Type_repr.Error ->
      conservative_owned (* residual forms: conservative *)
  | Type_repr.Never -> scalar

(* ── The P1-25 / P0-2 public API ───────────────────────────────────

   of_type_cached(cache, resolver, ty): the property triple of the
   (concrete) type under the caller's nominal resolver (a def-table
   resolver lifted with structural_resolver, usually overlaid with the
   LangItems record via with_lang_items).  With a cache the query is
   memoized by the structural canonical (TypeId, args) instance key.

   is_trivially_copyable(~cache, ~resolve, ty): the ONE answer to "is
   this type Copy?" under the caller's resolver. *)

let of_type_cached (cache : cache) (resolve : def_resolver option) (ty : Type_repr.t) :
    direct_properties =
  of_type resolve (Some cache) [] ty

let of_type_uncached (resolve : def_resolver option) (ty : Type_repr.t) : direct_properties =
  of_type resolve None [] ty

let is_trivially_copyable ?(cache : cache option) ?(resolve : def_resolver option)
    (ty : Type_repr.t) : bool =
  let p = of_type resolve cache [] ty in
  p.is_copy
