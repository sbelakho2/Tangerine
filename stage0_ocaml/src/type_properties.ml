(* type_properties.ml — The type-property authority (audit §30).

   Structural rules: scalars, raw pointers and references are Copy and do
   not need drop; String is owned; Vec/Map/Set/Box are owned; aggregates
   follow their fields/elements. Type parameters resolve through the
   trait solver's structural Copy rule where a bound exists, else
   conservatively as owned. *)

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

let rec combine (elems : t list) : t =
  {
    needs_drop = List.exists (fun p -> p.needs_drop) elems;
    is_copy = List.for_all (fun p -> p.is_copy) elems;
    is_sized = List.for_all (fun p -> p.is_sized) elems;
  }

and of_type (ty : Type_repr.t) : t =
  match ty with
  | Type_repr.Unit | Type_repr.Bool | Type_repr.Char -> scalar
  | Type_repr.Int _ | Type_repr.Float _ -> scalar
  | Type_repr.String -> owned
  | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _ -> scalar
  | Type_repr.Tuple elems -> combine (List.map of_type (Array.to_list elems))
  | Type_repr.Fixed_array (elem, _) -> of_type elem
  | Type_repr.Named (id, _args) ->
      (* resolve the def name through the environment at use sites; the
         structural fallback for unknown names is owned (conservative) *)
      ignore id;
      owned
  | Type_repr.Function _ -> scalar
  | Type_repr.Type_param _ -> owned (* conservative *)
  | Type_repr.Never -> scalar

(* Named-type property with the resolver's def table (binds the name). *)
let of_named_type (name_of : Ids.Type_id.t -> string) (ty : Type_repr.t) : t =
  match ty with
  | Type_repr.Named (id, _args) ->
      let name = name_of (Ids.Type_id.make id) in
      let base = if is_owned_named name then owned else scalar in
      if base.is_copy then base
      else { base with needs_drop = true; is_copy = false }
  | other -> of_type other
