(* ids_core.mli — Primitive strong semantic IDs (audit §12), ABSTRACT.

   Each `t` is a DISTINCT abstract type: the underlying representation
   (an int) lives in ids_core.ml and is hidden behind this interface, so
   Type_id.t, Field_id.t, Variant_id.t, Callable_id.t and Module_id.t can
   never be mixed accidentally.  (With a manifest `type t = int` these
   would all collapse to plain int — a transparent abbreviation — and the
   whole point of the strong-ID boundary would be lost.)

   This module has NO dependency on Type_repr: Type_repr depends on it,
   never the other way around.  Ids re-exports these modules so the
   `Ids.` prefix keeps working. *)

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

(* Per-expression AST node identity, minted by the parser. *)
module Node_id : sig
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
