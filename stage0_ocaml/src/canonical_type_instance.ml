(* canonical_type_instance.ml — Canonical generic type-instance interning
   (audit P0-13: canonical generic specialization identity).

   Every consumer that must agree on the identity of a CONCRETE instance
   of a generic nominal — the monomorphizer's type-instance queue
   (Mono.build's discovery), the driver's post-mono type-instance
   materializer (materialize_type_instances) and the concrete verifier's
   specialized-type handling (its registered-sig post_rewrite and its
   exact materialized-instance equality) — interns through ONE table.
   A canonical key

      CanonicalTypeInstance { generic_def_id; canonical_type_args }

   ALWAYS yields the same canonical specialized id: a single TypeId
   minted above the program's own id space.  Same (template, args)
   yields the same id structurally, by key equality — never by
   reconciling materialized def shapes — so no two specialized ids for
   one logically identical instance can exist anywhere in the pipeline.

   Key canonicalization (normalize BEFORE keying):
   - the 64-bit alias pairs collapse (the seed's abi_layout model: "Int
     is the i64 alias", "UInt is the u64 alias"): I64 normalizes to Int,
     U64 to UInt, so one value domain can never mint two instance ids;
   - an unsuffixed Int_literal record — the inference-only form the
     checker keeps when a generic binding was solved by a literal, and
     which the lowering treats as the default-kind constant — normalizes
     to the default kind its magnitude fits (Int when it fits the signed
     64-bit range, UInt when it only fits the unsigned range): the
     literal-solved instance and its integer-kind instance are ONE
     instance, not two fresh defs;
   - an instance whose args still carry an unsolved Infer_var or a rigid
     Type_param is NOT canonical and is never interned (no materializable
     concrete instance can carry them in a valid run; the residual-var
     gates report them fail-closed).

   The table mints canonical ids in FIRST-INTERN order — the mono
   queue's deterministic first-discovery order — so deterministic builds
   get deterministic ids.  intern is the ONLY mint: no consumer ever
   mints an instance TypeId outside the table, so two different
   specialized ids for one instance are unrepresentable.

   The builtin runtime nominals (the checker's semantic ids 0=Vec/Array,
   1=Map, 2=Set, 5=Ptr, 6=PtrMut) are excluded by the default
   materializable policy: the pipeline keys their runtime semantics on
   the ORIGINAL ids (mir_lower's desugaring, the verifier's id-keyed
   rules, the VM's value tags), so their concrete instances are never
   remapped to fresh defs.  Option/Result (3/4) and every user generic
   nominal ARE materialized. *)

(* The interned key: the generic nominal's def id plus its canonicalized
   concrete type arguments (the key's canonical form — the fold below is
   applied before every lookup, so key equality IS structural equality
   on the canonical form). *)
type canonical_type_instance = {
  generic_def_id : Ids.Type_id.t;
  canonical_type_args : Type_repr.t array;
}

let equal_key (a : canonical_type_instance) (b : canonical_type_instance) : bool =
  Ids.Type_id.compare a.generic_def_id b.generic_def_id = 0
  && Array.length a.canonical_type_args = Array.length b.canonical_type_args
  && Array.for_all2
       (fun x y -> Type_repr.compare x y = 0)
       a.canonical_type_args b.canonical_type_args

(* Structural hash over the key spine.  Every leaf is int-, variant- or
   int-array-backed (Type_repr carries no float VALUES — float_kind is a
   nullary variant; Big_nat.t is an int array), so the polymorphic hash
   of a component is content-stable and equal keys always hash alike. *)
let hash_ty (ty : Type_repr.t) : int =
  let h = ref 0x9e3779b9 in
  let mix (v : int) = h := ((!h lxor v) * 1000003) land 0x3FFFFFFF in
  let rec go (ty : Type_repr.t) : unit =
    match ty with
    | Type_repr.Unit -> mix 1
    | Type_repr.Bool -> mix 2
    | Type_repr.Char -> mix 3
    | Type_repr.Int k -> mix (4 + Hashtbl.hash k)
    | Type_repr.Float k -> mix (5 + Hashtbl.hash k)
    | Type_repr.String -> mix 6
    | Type_repr.Raw_ptr (m, t) ->
        mix (7 + Hashtbl.hash m);
        go t
    | Type_repr.Ref_internal (m, t) ->
        mix (8 + Hashtbl.hash m);
        go t
    | Type_repr.Tuple elems ->
        mix 9;
        Array.iter go elems
    | Type_repr.Fixed_array (t, n) ->
        mix (10 + n);
        go t
    | Type_repr.Named (tid, args) ->
        mix (11 + Ids.Type_id.to_int tid);
        Array.iter go args
    | Type_repr.Function (params, ret) ->
        mix 12;
        Array.iter
          (fun p ->
            mix (Hashtbl.hash p.Type_repr.pt_convention);
            go p.Type_repr.pt_type)
          params;
        go ret
    | Type_repr.Type_param pid -> mix (13 + Ids.Generic_param_id.to_int pid)
    | Type_repr.Infer_var v -> mix (14 + v)
    | Type_repr.Int_literal m ->
        mix 15;
        Array.iter (fun limb -> mix limb) m
    | Type_repr.Error -> mix 16
    | Type_repr.Never -> mix 17
  in
  go ty;
  !h

let hash_key (k : canonical_type_instance) : int =
  let h = ref (17 + Ids.Type_id.to_int k.generic_def_id) in
  Array.iter
    (fun ty -> h := ((!h * 1000003) lxor hash_ty ty) land 0x3FFFFFFF)
    k.canonical_type_args;
  !h

module Key_tbl = Hashtbl.Make (struct
  type t = canonical_type_instance
  let equal = equal_key
  let hash = hash_key
end)

(* The interning table: the ONE cache every consumer shares. *)
type t = {
  mint : int ref;                          (* the only fresh-id mint for generic instances *)
  materializable : Ids.Type_id.t -> bool;  (* which generic tids ever intern (builtin exclusion) *)
  table : Ids.Type_id.t Key_tbl.t;
}

(* The default materializable policy — the builtin runtime nominals are
   never remapped (mirror of the driver's pre-canonical exclusion; ids
   3=Option and 4=Result and every user generic nominal intern). *)
let default_materializable (tid : Ids.Type_id.t) : bool =
  let t = Ids.Type_id.to_int tid in
  not (t = 0 || t = 1 || t = 2 || t = 5 || t = 6)

let create ?(materializable : Ids.Type_id.t -> bool = default_materializable)
    ~(mint_from : int) () : t =
  { mint = ref mint_from; materializable; table = Key_tbl.create 64 }

let is_materializable (t : t) (tid : Ids.Type_id.t) : bool = t.materializable tid

let count (t : t) : int = Key_tbl.length t.table

(* ── Canonical argument normalization ────────────────────────────────
   The value-domain collapse applied to every keyed arg (recursively,
   so nested instances canonicalize too): the 64-bit alias pairs and the
   literal defaulting above.  Everything else — including Type_params
   and Infer_vars, which may still appear at TEMPLATE level (a fn's own
   declared binders) where the key is only used for equality, never for
   interning — passes through structurally. *)
let rec canonical_type (ty : Type_repr.t) : Type_repr.t =
  match ty with
  | Type_repr.Int Type_repr.I64 -> Type_repr.Int Type_repr.Int
  | Type_repr.Int Type_repr.U64 -> Type_repr.Int Type_repr.UInt
  | Type_repr.Int_literal m ->
      if Big_nat.fits_signed_positive m 64 then Type_repr.Int Type_repr.Int
      else if Big_nat.fits_unsigned m 64 then Type_repr.Int Type_repr.UInt
      else Type_repr.Int_literal m
  | Type_repr.Raw_ptr (mu, inner) -> Type_repr.Raw_ptr (mu, canonical_type inner)
  | Type_repr.Ref_internal (mu, inner) -> Type_repr.Ref_internal (mu, canonical_type inner)
  | Type_repr.Tuple elems -> Type_repr.Tuple (Array.map canonical_type elems)
  | Type_repr.Fixed_array (inner, n) -> Type_repr.Fixed_array (canonical_type inner, n)
  | Type_repr.Named (tid, args) -> Type_repr.Named (tid, Array.map canonical_type args)
  | Type_repr.Function (params, ret) ->
      Type_repr.Function
        ( Array.map
            (fun (p : Type_repr.param_type) ->
              { p with Type_repr.pt_type = canonical_type p.Type_repr.pt_type })
            params,
          canonical_type ret )
  | Type_repr.Unit | Type_repr.Bool | Type_repr.Char | Type_repr.Int _ | Type_repr.Float _
  | Type_repr.String | Type_repr.Type_param _ | Type_repr.Infer_var _ | Type_repr.Error
  | Type_repr.Never ->
      ty

(* Whether an instance still carries a NON-canonical arg (an unsolved
   Infer_var or a rigid Type_param): such an instance names no
   materializable concrete instance, so it is never interned. *)
let args_canonical (args : Type_repr.t array) : bool =
  not
    (Array.exists
       (fun a -> Type_repr.has_type_param a || Type_repr.has_infer_var a)
       args)

(* The canonical key form of an instance (pure — no mint, no policy):
   used for canonical equality/dedup wherever an instance is observed
   (the mono queue's membership), including instances the policy
   excludes from interning. *)
let key_of (generic_def_id : Ids.Type_id.t) (args : Type_repr.t array) :
    canonical_type_instance =
  { generic_def_id; canonical_type_args = Array.map canonical_type args }

(* Intern an instance: return its single canonical specialized id,
   minting it on FIRST observation of the canonical key.  None when the
   template is not materializable (the builtin runtime nominals) or the
   args are not canonical (unsolved Infer_var / rigid Type_param). *)
let intern (t : t) (generic_def_id : Ids.Type_id.t) (args : Type_repr.t array) :
    (Ids.Type_id.t * bool) option =
  if not (t.materializable generic_def_id) then None
  else if not (args_canonical args) then None
  else
    let key = key_of generic_def_id args in
    match Key_tbl.find_opt t.table key with
    | Some existing -> Some (existing, false)
    | None ->
        let id = Ids.Type_id.make !(t.mint) in
        incr t.mint;
        Key_tbl.add t.table key id;
        Some (id, true)

(* Look up an instance's canonical id WITHOUT minting (the rewrite
   paths — the mention rewrite and the verifier's registered-sig
   post_rewrite — must never fabricate a def-less id). *)
let lookup (t : t) (generic_def_id : Ids.Type_id.t) (args : Type_repr.t array) :
    Ids.Type_id.t option =
  if not (args_canonical args) then None
  else Key_tbl.find_opt t.table (key_of generic_def_id args)
