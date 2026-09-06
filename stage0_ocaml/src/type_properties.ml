(* type_properties.ml — The type-property authority (audit §30 / P1-25).

   ONE engine for the recursive type properties the seed stages consume
   (needs_drop / is_copy / is_sized) — the canonical copyability engine
   (P1-25) every consumer routes its Copy decisions through:
   mir_verify.is_copy, mir_lower.copyable_ty, and the drop-plan
   construction (drop_plan.ml) all call Type_properties; no consumer
   re-implements the recursion.

   Structural rules (canonical, unchanged): scalars (Unit/Bool/Char/
   Int/Float), raw pointers, internal references and genuine function
   pointers (Function with a non-Never return) are Copy and do not need
   drop; String is owned; an ENUM (the def_repr'd Function(payloads,
   Never) shape) is Copy iff EVERY variant payload is Copy and needs
   drop iff any payload does; a struct is Copy iff every field is Copy;
   tuples and fixed arrays are elementwise.  Named types resolve through
   the def-table hook supplied by the caller (the resolver maps a TypeId
   to its definition shape); when the def cannot be resolved the
   conservative answer is owned.  Type parameters and inference
   variables resolve through the trait solver's structural Copy rule
   where a bound exists, else conservatively as owned.

   The owned LangItems of the language rule (the collection nominals,
   Box/Arc/Rc, the Ptr-with-region forms) are deliberately NOT
   name-listed here: the seed consumers express them through their def
   tables — a runtime handle nominal (Vec/Map/Set/Ptr/PtrMut) either
   carries no def-table entry (the conservative owned answer) or the
   consumer's canonical def shape (Ptr = { address: UInt } is Copy),
   and an owning LangItem with real payloads (Option/Result/Box
   materialized instances) resolves through its def exactly like any
   user enum.  A name-anchored classification inside the engine would
   disagree with the def-resolved answers the working pipeline already
   produces; the name-anchored OWNED sets that exist (mir_lower's
   pre-mono langitem table) stay at that consumer, as pre-checks, so
   consolidation never changes which types the pipeline treats as Copy.

   CACHING (P1-25): results are memoized per canonical NAMED instance —
   the key is (TypeId, canonical args), NEVER TypeId alone: the same
   generic nominal at different substitutions can answer differently
   (Wrapper[Int] vs Wrapper[File] are different canonical instances and
   must never share one entry).  A cache instance is bound to ONE def
   table / program phase; never share one cache across two tables. *)

type t = {
  needs_drop : bool;
  is_copy : bool;
  is_sized : bool;
}

let scalar = { needs_drop = false; is_copy = true; is_sized = true }

let owned = { needs_drop = true; is_copy = false; is_sized = true }

(* The def-table hook: resolve a Named TypeId to its definition shape
   (seed_mir.def_repr: a struct as its field tuple, an enum as
   Function(payloads, Never)); None when the table has no entry. *)
type def_resolver = Ids.Type_id.t -> Type_repr.t option

(* ── The canonical instance cache (P1-25) ───────────────────────────
   Keyed by the full canonical spelling of (TypeId, args): two mentions
   of one generic nominal at different substitutions never collide. *)
type cache = (string, t) Hashtbl.t

let create_cache () : cache = Hashtbl.create 127

let key_of_type (ty : Type_repr.t) : string =
  let b = Buffer.create 24 in
  let add (s : string) = Buffer.add_string b s in
  (let rec go (ty : Type_repr.t) : unit =
     match ty with
     | Type_repr.Unit -> add "u"
     | Type_repr.Bool -> add "b"
     | Type_repr.Char -> add "c"
     | Type_repr.Int k ->
         add
           (match k with
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
           | Type_repr.Int -> "int"
           | Type_repr.UInt -> "uint")
     | Type_repr.Float k -> add (if k = Type_repr.F32 then "f32" else "f64")
     | Type_repr.String -> add "s"
     | Type_repr.Raw_ptr (m, t) ->
         add (if m = Type_repr.Immutable then "p(" else "pm(");
         go t;
         add ")"
     | Type_repr.Ref_internal (m, t) ->
         add (if m = Type_repr.Immutable then "r(" else "rm(");
         go t;
         add ")"
     | Type_repr.Tuple elems ->
         add "t(";
         Array.iter (fun e -> go e; add ",") elems;
         add ")"
     | Type_repr.Fixed_array (e, n) ->
         add (Printf.sprintf "a%d(" n);
         go e;
         add ")"
     | Type_repr.Named (tid, args) ->
         add (Printf.sprintf "n%d(" (Ids.Type_id.to_int tid));
         Array.iter (fun a -> go a; add ",") args;
         add ")"
     | Type_repr.Function (params, ret) ->
         add "fn(";
         Array.iter (fun p -> go p.Type_repr.pt_type; add ";") params;
         add ")->";
         go ret
     | Type_repr.Type_param p ->
         add (Printf.sprintf "p%d" (Ids.Generic_param_id.to_int p))
     | Type_repr.Infer_var v -> add (Printf.sprintf "v%d" v)
     | Type_repr.Int_literal m -> add ("l" ^ Big_nat.to_bits m)
     | Type_repr.Error -> add "e"
     | Type_repr.Never -> add "n"
   in
   go ty);
  Buffer.contents b

let rec combine (elems : t list) : t =
  {
    needs_drop = List.exists (fun p -> p.needs_drop) elems;
    is_copy = List.for_all (fun p -> p.is_copy) elems;
    is_sized = List.for_all (fun p -> p.is_sized) elems;
  }

(* The property of one Named INSTANCE (id, args): its def's property
   (the def's own param scope is the def table's business — materialized
   defs are already substituted; template defs mentioning their own
   params resolve those params conservatively).  The instance answer is
   cached under the (TypeId, canonical args) key. *)
and instance_property (resolve_def : def_resolver option) (cache : cache option)
    (seen : Ids.Type_id.t list) (id : Ids.Type_id.t) : t =
  match resolve_def with
  | Some f -> (
      match f id with
      | Some def -> of_type resolve_def cache (id :: seen) def
      | None -> owned)
  | None -> owned

and of_type (resolve_def : def_resolver option) (cache : cache option)
    (seen : Ids.Type_id.t list) (ty : Type_repr.t) : t =
  match ty with
  | Type_repr.Unit | Type_repr.Bool | Type_repr.Char -> scalar
  | Type_repr.Int _ | Type_repr.Float _ -> scalar
  | Type_repr.String -> owned
  | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _ -> scalar
  | Type_repr.Tuple elems ->
      combine (List.map (of_type resolve_def cache seen) (Array.to_list elems))
  | Type_repr.Fixed_array (elem, _) -> of_type resolve_def cache seen elem
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
               (fun p -> of_type resolve_def cache seen p.Type_repr.pt_type)
               (Array.to_list params))
      | _ ->
          (* a genuine function pointer is a value (code identity) *)
          scalar)
  | Type_repr.Named (id, _args) ->
      if List.mem id seen then owned
      else (
        match cache with
        | Some tbl ->
            let key = key_of_type ty in
            (match Hashtbl.find_opt tbl key with
             | Some p -> p
             | None ->
                 let p = instance_property resolve_def cache seen id in
                 Hashtbl.replace tbl key p;
                 p)
        | None -> instance_property resolve_def cache seen id)
  | Type_repr.Type_param _ | Type_repr.Infer_var _ | Type_repr.Int_literal _ | Type_repr.Error ->
      owned (* conservative *)
  | Type_repr.Never -> scalar

(* ── The P1-25 public API ──────────────────────────────────────────

   is_trivially_copyable(concrete_type, field_registry): the ONE answer
   to "is this type Copy?".  `ty` is the (concrete) type, `resolve_def`
   is the caller's field/variant registry hook (the def-table: struct ->
   its field tuple, enum -> its payload function, None -> no entry).
   With a cache the query is memoized by the canonical (TypeId, args)
   instance key. *)

let of_type_cached (cache : cache) (resolve_def : def_resolver option) (ty : Type_repr.t) : t =
  of_type resolve_def (Some cache) [] ty

let is_trivially_copyable ?(cache : cache option) ?(resolve_def : def_resolver option)
    (ty : Type_repr.t) : bool =
  let p = of_type resolve_def cache [] ty in
  p.is_copy
