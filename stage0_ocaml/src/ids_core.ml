(* ids_core.ml — Primitive strong semantic IDs (audit §12).

   The primitive ID domains with NO dependency on Type_repr (or anything
   else): Type_repr depends on this module, never the other way around.

   Distinct abstract ID domains so that ModuleId, TypeId, FieldId,
   VariantId and CallableId can never be mixed accidentally: each `t` is
   a separate type path even though every domain is int-backed, so e.g.
   `Type_repr.Named (Callable_id.make 1, [||])` is a compile error while
   `Type_repr.Named (Type_id.make 1, [||])` is not.

   Ids re-exports these modules so the `Ids.` prefix keeps working. *)

module Module_id = struct
  type t = int
  let make (i : int) : t = i
  let compare (a : t) (b : t) = compare a b
  let to_int (t : t) = t
  let of_int (i : int) : t = i
  let to_string (t : t) = Printf.sprintf "module#%d" t
end

module Item_id = struct
  type t = int
  let make (i : int) : t = i
  let compare (a : t) (b : t) = compare a b
  let to_int (t : t) = t
  let of_int (i : int) : t = i
end

module Type_id = struct
  type t = int
  let make (i : int) : t = i
  let compare (a : t) (b : t) = compare a b
  let to_int (t : t) = t
  let of_int (i : int) : t = i
end

module Trait_id = struct
  type t = int
  let make (i : int) : t = i
  let compare (a : t) (b : t) = compare a b
  let to_int (t : t) = t
  let of_int (i : int) : t = i
end

module Field_id = struct
  type t = int
  let make (i : int) : t = i
  let compare (a : t) (b : t) = compare a b
  let to_int (t : t) = t
  let of_int (i : int) : t = i
end

module Variant_id = struct
  type t = int
  let make (i : int) : t = i
  let compare (a : t) (b : t) = compare a b
  let to_int (t : t) = t
  let of_int (i : int) : t = i
end

module Callable_id = struct
  type t = int
  let make (i : int) : t = i
  let compare (a : t) (b : t) = compare a b
  let to_int (t : t) = t
  let of_int (i : int) : t = i
end

module Generic_param_id = struct
  type t = int
  let make (i : int) : t = i
  let compare (a : t) (b : t) = compare a b
  let to_int (t : t) = t
  let of_int (i : int) : t = i
end

(* Per-struct / per-enum declaration-order positions (Seed MIR
   projections and discriminant tags): 0..n-1 within the owner. *)
module Field_index = struct
  type t = int
  let make (i : int) : t = i
  let compare (a : t) (b : t) = compare a b
  let to_int (t : t) = t
  let of_int (i : int) : t = i
end

module Variant_index = struct
  type t = int
  let make (i : int) : t = i
  let compare (a : t) (b : t) = compare a b
  let to_int (t : t) = t
  let of_int (i : int) : t = i
end
