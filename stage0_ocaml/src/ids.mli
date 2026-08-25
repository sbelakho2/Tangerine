(* ids.mli — Strong semantic IDs (audit §12), ABSTRACT at the OCaml
   boundary.

   Every ID domain is a DISTINCT abstract type: the underlying
   representation (an int) lives in ids.ml and is hidden behind this
   interface, so Type_id.t, Field_id.t, Variant_id.t, Callable_id.t and
   Module_id.t can never be mixed accidentally.  The only way to produce
   or consume a value is through the exposed constructors/accessors.

   Field_index.t and Variant_index.t are deliberately SEPARATE from
   Field_id.t / Variant_id.t: they are the per-struct / per-enum
   declaration-order POSITION (0..n-1) used by the Seed MIR's field
   projections, variant projections, EnumCtor tags and SetDiscriminant,
   whereas Field_id / Variant_id are the globally-unique semantic
   declaration identities.  See seed_mir.ml's type-definition contract
   for the concrete distinction. *)

module Module_id : sig
  type t
  val make : int -> t
  val compare : t -> t -> int
  val to_int : t -> int
  val of_int : int -> t
  val to_string : t -> string
end

module Item_id : sig
  type t
  val make : int -> t
  val compare : t -> t -> int
  val to_int : t -> int
  val of_int : int -> t
end

module Type_id : sig
  type t
  val make : int -> t
  val compare : t -> t -> int
  val to_int : t -> int
  val of_int : int -> t
end

module Trait_id : sig
  type t
  val make : int -> t
  val compare : t -> t -> int
  val to_int : t -> int
  val of_int : int -> t
end

module Field_id : sig
  type t
  val make : int -> t
  val compare : t -> t -> int
  val to_int : t -> int
  val of_int : int -> t
end

module Variant_id : sig
  type t
  val make : int -> t
  val compare : t -> t -> int
  val to_int : t -> int
  val of_int : int -> t
end

module Callable_id : sig
  type t
  val make : int -> t
  val compare : t -> t -> int
  val to_int : t -> int
  val of_int : int -> t
end

module Generic_param_id : sig
  type t
  val make : int -> t
  val compare : t -> t -> int
  val to_int : t -> int
  val of_int : int -> t
end

(* Per-struct / per-enum declaration-order positions used by Seed MIR
   projections and discriminant tags (0..n-1). *)
module Field_index : sig
  type t
  val make : int -> t
  val compare : t -> t -> int
  val to_int : t -> int
  val of_int : int -> t
end

module Variant_index : sig
  type t
  val make : int -> t
  val compare : t -> t -> int
  val to_int : t -> int
  val of_int : int -> t
end

module Instance_id : sig
  type t
  val make : callable:Callable_id.t -> type_args:Type_repr.t array -> t
  val callable : t -> Callable_id.t
  val type_args : t -> Type_repr.t array
  val compare : t -> t -> int
end

type def_id = {
  module_id : Module_id.t;
  index : int;
}

val compare_def_id : def_id -> def_id -> int
