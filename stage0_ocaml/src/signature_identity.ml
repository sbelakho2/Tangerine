(* signature_identity.ml — signature identity at the typed → MIR / host
   normalization boundary (audit P0-1 .. P0-4).

   Every place a DECLARED signature is compared for semantic identity —
   the driver's host-channel rewrite gate (registry declaration vs the
   checker's registered signature), the host's binding-closure checks
   (registry declaration vs the adapter's independent declaration), the
   typechecker's P4 builtin/registry drift assertion, mir_verify's
   signature comparisons — routes through ONE stateful matcher
   (match_signature / signatures_match) with the SAME rules:

   P0-1  — named types compare by EXACT TypeId equality.  Before the
           comparison a side is canonicalized; the ONLY legitimate
           id-difference reasons are resolved there:
             (a) the registry's placeholder domain → the checker's
                 LangItem ids via registry_type_to_checker — this
                 module's OWN copy of the single adoption table
                 (mir_verify's registry_type_to_checker mirrors it);
             (b) the language-defined builtin-alias universe via
                 canonicalize_builtin_alias.  On the checker side every
                 alias class is ONE TypeId by construction — Vec/Array/
                 List are the Array LangItem nominal, HashSet/Set the
                 Set nominal, HashMap/Map the Map nominal, String/str is
                 Type_repr.String, and `typealias Duration = Timespec`
                 resolves to the Timespec id — so the checker-side
                 canonical form is the identity.  In the registry's
                 placeholder domain the Vec family is spelled twice
                 (`vec` and `array_` placeholders), so the alias step
                 merges the pair onto the vec placeholder before the
                 LangItem adoption maps the whole class onto the
                 checker's Array id.
           Two user nominals with equal generic arity (A[Int] vs B[Int])
           and Vec[Int] vs Set[Int] NEVER match.

   P0-2  — alpha-equivalence over the signature's generic binders is a
           BIJECTION: the matcher keeps both direction maps
           (left binder → right binder, right binder → left binder) for
           the whole signature (params AND return).  The first
           occurrence of a binder pair binds both directions; a later
           occurrence requires the existing mappings to agree both ways.
           fn(T,T)->T vs fn(A,B)->A and fn(T,U)->T vs fn(A,A)->A FAIL.

   P0-4  — access conventions (let/inout/sink/set) are part of
           signature identity: each parameter's convention must agree,
           its type must be alpha-equivalent under the ONE binder map,
           arities must agree, and the return must agree under the SAME
           map (the canonical parameter key is {convention; type}).

   A caller may additionally declare a strict_when predicate: a type
   pair for which it holds is compared with the plain structural
   Type_repr.compare (exact binder ids, no binder binding) instead of
   the alpha rules — the driver uses it to keep the ref-bearing
   signatures fail-closed (their semantics are not implementable on the
   value-model host, so no rewrite may ever be invented for them).

   This module is a leaf of the compiler's dependency graph (it depends
   only on Type_repr/Ids/Access_effect/Intrinsic_registry), so every
   comparison site — including the typechecker, which precedes
   Mir_verify in the module order — can route through it.  The
   registry→checker adoption table therefore lives HERE (one
   implementation); Mir_verify's registry_type_to_checker is kept as
   the verifier's own convenience view of the same four rows. *)

type signature = {
  sig_params : Type_repr.param_type array;
  sig_ret : Type_repr.t;
}

let of_registry (s : Intrinsic_registry.signature) : signature =
  {
    sig_params = s.Intrinsic_registry.params;
    sig_ret = s.Intrinsic_registry.ret;
  }

(* ── P0-1 (a): the registry-placeholder → checker-LangItem adoption
      table (mirror of Mir_verify.registry_type_to_checker; kept HERE so
      the typechecker's P4 drift check and every other pre-Mir_verify
      site can canonicalize without a module edge to Mir_verify).
      Registry placeholder ids: option_=1, vec=2, map=3, set=4 (the
      registry's own domain — Intrinsic_registry.Type_id); checker
      LangItem ids: Array=0, Map=1, Set=2, Option=3 (Typecheck's
      b_array/b_map/b_set/b_option — mir_verify's re-audit P0-C row).
      The registry's `array_` placeholder (id 5) is NOT adopted here: it
      is an ALIAS spelling of `vec` and is folded onto it by
      canonicalize_builtin_alias first (a raw id-5 adoption would
      collide with the checker's Ptr nominal, which owns id 5).  The
      ruby extern placeholders (6/7) have no executable bindings and are
      never compared. *)
let registry_type_to_checker (ty : Type_repr.t) : Type_repr.t =
  let rec go t =
    match t with
    | Type_repr.Named (tid, args) ->
        let tid' =
          if Ids.Type_id.compare tid (Intrinsic_registry.Type_id.option_) = 0 then
            Ids.Type_id.make 3
          else if Ids.Type_id.compare tid (Intrinsic_registry.Type_id.vec) = 0 then
            Ids.Type_id.make 0
          else if Ids.Type_id.compare tid (Intrinsic_registry.Type_id.map) = 0 then
            Ids.Type_id.make 1
          else if Ids.Type_id.compare tid (Intrinsic_registry.Type_id.set) = 0 then
            Ids.Type_id.make 2
          else tid
        in
        Type_repr.Named (tid', Array.map go args)
    | Type_repr.Fixed_array (e, n) -> Type_repr.Fixed_array (go e, n)
    | Type_repr.Tuple elems -> Type_repr.Tuple (Array.map go elems)
    | t -> t
  in
  go ty

(* ── P0-1 (b): the builtin-alias canonicalization ──────────────────
   The language's alias classes are collapsed by the checker itself
   (each class is one TypeId / one Type_repr form — see above), so on a
   checker-domain type this step is the identity.  In the REGISTRY's
   placeholder domain the Vec family is spelled both `vec` and
   `array_`; the fold merges them so the LangItem adoption table can
   map the class onto the checker's Array id.  This function must only
   be applied to registry-placeholder-domain types (checker-side
   types carry their own id 5 = Ptr — never fold those). *)
let rec canonicalize_builtin_alias (ty : Type_repr.t) : Type_repr.t =
  match ty with
  | Type_repr.Named (tid, args) ->
      let tid' =
        if
          Ids.Type_id.compare tid Intrinsic_registry.Type_id.array_ = 0
        then Intrinsic_registry.Type_id.vec
        else tid
      in
      Type_repr.Named (tid', Array.map canonicalize_builtin_alias args)
  | Type_repr.Fixed_array (e, n) -> Type_repr.Fixed_array (canonicalize_builtin_alias e, n)
  | Type_repr.Tuple elems -> Type_repr.Tuple (Array.map canonicalize_builtin_alias elems)
  | Type_repr.Raw_ptr (m, inner) ->
      Type_repr.Raw_ptr (m, canonicalize_builtin_alias inner)
  | Type_repr.Ref_internal (m, inner) ->
      Type_repr.Ref_internal (m, canonicalize_builtin_alias inner)
  | Type_repr.Function (ps, r) ->
      Type_repr.Function
        ( Array.map
            (fun (p : Type_repr.param_type) ->
              { p with Type_repr.pt_type = canonicalize_builtin_alias p.Type_repr.pt_type })
            ps,
          canonicalize_builtin_alias r )
  | _ -> ty

(* ── P0-1 (a) + (b): the full registry-placeholder-domain canonical
      form.  Apply this to every side of a comparison that lives in the
      registry's placeholder domain (the registries' declarations, the
      host adapters written with the registries' building blocks, the
      typechecker's P4 registry entries).  The checker side of a
      comparison is already canonical (each alias class is ONE TypeId by
      construction) and is compared as-is. *)
let canonicalize_registry_placeholder (ty : Type_repr.t) : Type_repr.t =
  registry_type_to_checker (canonicalize_builtin_alias ty)

(* binder maps: both directions, for the duration of one signature
   match (stateful — the signature's whole comparison shares them) *)
module BinderMaps = struct
  type t = {
    left_to_right : (int, Ids.Generic_param_id.t) Hashtbl.t;
    right_to_left : (int, Ids.Generic_param_id.t) Hashtbl.t;
  }

  let create () : t =
    {
      left_to_right = Hashtbl.create 8;
      right_to_left = Hashtbl.create 8;
    }

  (* first occurrence binds both directions; a later occurrence must
     agree with both existing mappings *)
  let bind (m : t) (l : Ids.Generic_param_id.t) (r : Ids.Generic_param_id.t) : bool =
    let li = Ids.Generic_param_id.to_int l and ri = Ids.Generic_param_id.to_int r in
    match Hashtbl.find_opt m.left_to_right li, Hashtbl.find_opt m.right_to_left ri with
    | Some r0, Some l0 ->
        Ids.Generic_param_id.compare r0 r = 0 && Ids.Generic_param_id.compare l0 l = 0
    | Some r0, None ->
        if Ids.Generic_param_id.compare r0 r = 0 then begin
          Hashtbl.replace m.right_to_left ri l;
          true
        end
        else false
    | None, Some l0 ->
        if Ids.Generic_param_id.compare l0 l = 0 then begin
          Hashtbl.replace m.left_to_right li r;
          true
        end
        else false
    | None, None ->
        Hashtbl.replace m.left_to_right li r;
        Hashtbl.replace m.right_to_left ri l;
        true
end

(* The single recursive type-equality used by the boolean matcher
   (match_types / match_signature / signatures_match) and the
   first-mismatch report.  Return = agreement.  `bm` carries the whole
   signature's binder bijection (P0-2); the caller's canonicalization
   (P0-1) is applied BEFORE types reach this function. *)
let rec types_agree (bm : BinderMaps.t) (a : Type_repr.t) (b : Type_repr.t) : bool =
  match a, b with
  | Type_repr.Type_param la, Type_repr.Type_param lb -> BinderMaps.bind bm la lb
  | Type_repr.Named (ta, aa), Type_repr.Named (tb, ab) ->
      Ids.Type_id.compare ta tb = 0
      && Array.length aa = Array.length ab
      && (let ok = ref true in
          Array.iteri
            (fun i t -> if not (types_agree bm aa.(i) t) then ok := false)
            ab;
          !ok)
  | Type_repr.Function (p1, r1), Type_repr.Function (p2, r2) ->
      Array.length p1 = Array.length p2
      && (let ok = ref true in
          Array.iteri
            (fun i (p : Type_repr.param_type) ->
              if
                Access_effect.compare p1.(i).Type_repr.pt_convention
                  p.Type_repr.pt_convention
                <> 0
                || not (types_agree bm p1.(i).Type_repr.pt_type p.Type_repr.pt_type)
              then ok := false)
            p2;
          !ok)
      && types_agree bm r1 r2
  | Type_repr.Fixed_array (e1, n1), Type_repr.Fixed_array (e2, n2) ->
      n1 = n2 && types_agree bm e1 e2
  | Type_repr.Tuple e1, Type_repr.Tuple e2 ->
      Array.length e1 = Array.length e2
      && (let ok = ref true in
          Array.iteri
            (fun i t -> if not (types_agree bm e1.(i) t) then ok := false)
            e2;
          !ok)
  | Type_repr.Raw_ptr (m1, t1), Type_repr.Raw_ptr (m2, t2) ->
      m1 = m2 && types_agree bm t1 t2
  | Type_repr.Ref_internal (m1, t1), Type_repr.Ref_internal (m2, t2) ->
      m1 = m2 && types_agree bm t1 t2
  | a, b -> Type_repr.compare a b = 0

(* ── The shared matcher, raw-piece API ──────────────────────────────

   match_signature ~params_left ~ret_left ~params_right ~ret_right:
     - every parameter's convention must agree exactly (P0-4);
     - arities must agree;
     - per-parameter types and the return agree under ONE binder
       bijection shared across the whole signature (P0-2), exact TypeId
       equality after each side's canonicalization (P0-1 — pass
       ~canon_left/~canon_right for the registry-domain side(s));
     - a pair for which strict_when holds is compared with the plain
       structural Type_repr.compare instead (the ref-kind escape).

   match_types compares ONE type under a FRESH binder bijection (for a
   type that itself carries the whole signature, e.g. a Function type
   with params and return — the recursion shares the one map across the
   fn's params and return). *)
(* Warning 16 (unerasable optional argument) is inherent to the
   all-labeled shape of match_signature — every caller passes the four
   required labeled arguments and the optional canonicalizers are always
   applied at a full application, never partially erased. *)
[@@@warning "-16"]
let match_signature
    ~(params_left : Type_repr.param_type array) ~(ret_left : Type_repr.t)
    ~(params_right : Type_repr.param_type array) ~(ret_right : Type_repr.t)
    ?(canon_left : Type_repr.t -> Type_repr.t = fun t -> t)
    ?(canon_right : Type_repr.t -> Type_repr.t = fun t -> t)
    ?(strict_when : Type_repr.t -> Type_repr.t -> bool = fun _ _ -> false) : bool =
  if Array.length params_left <> Array.length params_right then false
  else begin
    let bm = BinderMaps.create () in
    let ok = ref true in
    let pair (p1 : Type_repr.param_type) (p2 : Type_repr.param_type) =
      if
        Access_effect.compare p1.Type_repr.pt_convention p2.Type_repr.pt_convention <> 0
        || not (types_agree bm (canon_left p1.Type_repr.pt_type) (canon_right p2.Type_repr.pt_type))
      then ok := false
    in
    (* strict_when is a property of the RAW pair (the driver's
       ref-kind rule); the strict comparison itself runs on the
       canonicalized types *)
    Array.iteri
      (fun i (p : Type_repr.param_type) ->
        if !ok then
          let a_raw = params_left.(i) in
          if
            strict_when a_raw.Type_repr.pt_type p.Type_repr.pt_type
          then begin
            if
              Type_repr.compare
                (canon_left a_raw.Type_repr.pt_type)
                (canon_right p.Type_repr.pt_type)
              <> 0
            then ok := false
          end
          else pair a_raw p)
      params_right;
    if not !ok then false
    else if strict_when ret_left ret_right then
      Type_repr.compare (canon_left ret_left) (canon_right ret_right) = 0
    else types_agree bm (canon_left ret_left) (canon_right ret_right)
  end
[@@@warning "+16"]

let match_types
    ?(canon_left : Type_repr.t -> Type_repr.t = fun t -> t)
    ?(canon_right : Type_repr.t -> Type_repr.t = fun t -> t)
    (a : Type_repr.t) (b : Type_repr.t) : bool =
  let bm = BinderMaps.create () in
  types_agree bm (canon_left a) (canon_right b)

(* ── The shared matcher, signature-record wrapper (the host's
      declared-vs-adapter closure checks, the driver's
      host-channel-normalize gate) ────────────────────────────────── *)
let signatures_match
    ?(canon_left : Type_repr.t -> Type_repr.t = fun t -> t)
    ?(canon_right : Type_repr.t -> Type_repr.t = fun t -> t)
    ?(strict_when : Type_repr.t -> Type_repr.t -> bool = fun _ _ -> false)
    (a : signature) (b : signature) : bool =
  match_signature ~canon_left ~canon_right ~strict_when
    ~params_left:a.sig_params ~ret_left:a.sig_ret
    ~params_right:b.sig_params ~ret_right:b.sig_ret

(* ── First-disagreement report (host / P4 diagnostics) ────────────── *)

type mismatch =
  | Mismatch_arity of int * int (* declared count, other count *)
  | Mismatch_param of int       (* first parameter index disagreeing *)
  | Mismatch_return

(* The first place the two signatures disagree under the SAME rules
   (same canonicalization, same strict escape — no binder state is
   retained across calls). *)
let first_mismatch
    ?(canon_left : Type_repr.t -> Type_repr.t = fun t -> t)
    ?(canon_right : Type_repr.t -> Type_repr.t = fun t -> t)
    ?(strict_when : Type_repr.t -> Type_repr.t -> bool = fun _ _ -> false)
    (a : signature) (b : signature) : mismatch option =
  let na = Array.length a.sig_params and nb = Array.length b.sig_params in
  if na <> nb then Some (Mismatch_arity (na, nb))
  else begin
    let bm = BinderMaps.create () in
    let param_pair i (p1 : Type_repr.param_type) (p2 : Type_repr.param_type) =
      if Access_effect.compare p1.Type_repr.pt_convention p2.Type_repr.pt_convention <> 0
      then Some (Mismatch_param i)
      else if
        strict_when p1.Type_repr.pt_type p2.Type_repr.pt_type
      then
        if
          Type_repr.compare
            (canon_left p1.Type_repr.pt_type)
            (canon_right p2.Type_repr.pt_type)
          <> 0
        then Some (Mismatch_param i)
        else None
      else if
        types_agree bm (canon_left p1.Type_repr.pt_type)
          (canon_right p2.Type_repr.pt_type)
      then None
      else Some (Mismatch_param i)
    in
    let rec go i =
      if i >= na then None
      else
        match param_pair i a.sig_params.(i) b.sig_params.(i) with
        | Some m -> Some m
        | None -> go (i + 1)
    in
    match go 0 with
    | Some m -> Some m
    | None ->
        if
          strict_when a.sig_ret b.sig_ret
        then
          if
            Type_repr.compare (canon_left a.sig_ret) (canon_right b.sig_ret) <> 0
          then Some Mismatch_return
          else None
        else if
          types_agree bm (canon_left a.sig_ret) (canon_right b.sig_ret)
        then None
        else Some Mismatch_return
  end

(* A readable rendering of a signature (diagnostics; registry-domain
   placeholder names render as Vec/Map/Set/Option/Array). *)
let to_string (s : signature) : string =
  let render (p : Type_repr.param_type) =
    Access_effect.to_string p.Type_repr.pt_convention
    ^ " "
    ^ Intrinsic_registry.ty_to_string p.Type_repr.pt_type
  in
  "("
  ^ String.concat ", " (Array.to_list (Array.map render s.sig_params))
  ^ ") -> " ^ Intrinsic_registry.ty_to_string s.sig_ret
