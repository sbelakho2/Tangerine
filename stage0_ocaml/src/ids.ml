(* ids.ml — Strong semantic IDs (audit §12).

   Distinct abstract ID domains so that ModuleId, TypeId, FieldId,
   VariantId and CallableId can never be mixed accidentally. *)

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

module Instance_id = struct
  type t = { callable : Callable_id.t; type_args : Type_repr.t array }
  let make ~callable ~type_args = { callable; type_args }
  let callable (t : t) = t.callable
  let type_args (t : t) = t.type_args
  let compare (a : t) (b : t) =
    let c = Callable_id.compare a.callable b.callable in
    if c <> 0 then c
    else
      let n = Array.length a.type_args in
      let m = Array.length b.type_args in
      let rec cmp i =
        if i >= n && i >= m then 0
        else if i >= n then -1
        else if i >= m then 1
        else
          let c = Type_repr.compare a.type_args.(i) b.type_args.(i) in
          if c <> 0 then c else cmp (i + 1)
      in
      cmp 0
end

type def_id = {
  module_id : Module_id.t;
  index : int;
}

let compare_def_id (a : def_id) (b : def_id) =
  let c = Module_id.compare a.module_id b.module_id in
  if c <> 0 then c else compare a.index b.index
