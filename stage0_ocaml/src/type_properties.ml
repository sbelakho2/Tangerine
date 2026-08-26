(* type_properties.ml — The type-property authority (audit §30).

   One authority for the recursive type properties the seed stages
   consume (currently: needs_drop / is_copy / is_sized).

   Structural rules: scalars, raw pointers, references and genuine
   function pointers (Function with a non-Never return) are Copy and do
   not need drop; String is owned; an ENUM (the def_repr'd
   Function(payloads, Never) shape) is Copy iff every variant payload is
   Copy and needs drop iff any payload does; a struct is Copy iff every
   field is Copy; aggregates follow their fields/elements.  Named types
   resolve through the def-table hook supplied by the caller (the
   resolver maps a TypeId to its definition shape); when the def cannot
   be resolved the conservative answer is owned.  Type parameters and
   inference variables resolve through the trait solver's structural
   Copy rule where a bound exists, else conservatively as owned. *)

type t = {
  needs_drop : bool;
  is_copy : bool;
  is_sized : bool;
}

let scalar = { needs_drop = false; is_copy = true; is_sized = true }

let owned = { needs_drop = true; is_copy = false; is_sized = true }

(* std::collections owned names (Vec/Map/Set/Box + aliases the resolver
   binds; no string aliasing of Vec<->Array is performed). *)
let is_owned_named (name : string) : bool =
  match name with
  | "Vec" | "Map" | "Set" | "Box" | "HashMap" | "String" -> true
  | _ -> false

(* The def-table hook: resolve a Named TypeId to its definition shape
   (seed_mir.def_repr: a struct as its field tuple, an enum as
   Function(payloads, Never)); None when the table has no entry. *)
type def_resolver = Ids.Type_id.t -> Type_repr.t option

let rec combine (elems : t list) : t =
  {
    needs_drop = List.exists (fun p -> p.needs_drop) elems;
    is_copy = List.for_all (fun p -> p.is_copy) elems;
    is_sized = List.for_all (fun p -> p.is_sized) elems;
  }

and of_type ?(resolve_def : def_resolver option) ?(seen : Ids.Type_id.t list = [])
    (ty : Type_repr.t) : t =
  match ty with
  | Type_repr.Unit | Type_repr.Bool | Type_repr.Char -> scalar
  | Type_repr.Int _ | Type_repr.Float _ -> scalar
  | Type_repr.String -> owned
  | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _ -> scalar
  | Type_repr.Tuple elems ->
      combine (List.map (of_type ?resolve_def ~seen) (Array.to_list elems))
  | Type_repr.Fixed_array (elem, _) -> of_type ?resolve_def ~seen elem
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
               (fun p -> of_type ?resolve_def ~seen p.Type_repr.pt_type)
               (Array.to_list params))
      | _ ->
          (* a genuine function pointer is a value (code identity) *)
          scalar)
  | Type_repr.Named (id, _args) ->
      if List.mem id seen then owned
      else (
        match resolve_def with
        | Some f -> (
            match f id with
            | Some def -> of_type ?resolve_def ~seen:(id :: seen) def
            | None -> owned)
        | None -> owned)
  | Type_repr.Type_param _ | Type_repr.Infer_var _ | Type_repr.Int_literal _ | Type_repr.Error ->
      owned (* conservative *)
  | Type_repr.Never -> scalar

(* Named-type property with the resolver's def table (binds the name). *)
let of_named_type (name_of : Ids.Type_id.t -> string) (ty : Type_repr.t) : t =
  match ty with
  | Type_repr.Named (id, _args) ->
      let name = name_of id in
      let base = if is_owned_named name then owned else scalar in
      if base.is_copy then base
      else { base with needs_drop = true; is_copy = false }
  | other -> of_type other
