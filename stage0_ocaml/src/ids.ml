(* ids.ml — Strong semantic IDs (audit §12).

   Thin re-export of the primitive ID domains from Ids_core (which has
   no dependency on Type_repr), plus the def_id pair.  Instance_id moved
   to its own module (instance_id.ml): it is the only ID domain that
   carries Type_repr values, so it must live ABOVE Type_repr, not
   underneath it. *)

module Module_id = Ids_core.Module_id
module Item_id = Ids_core.Item_id
module Type_id = Ids_core.Type_id
module Trait_id = Ids_core.Trait_id
module Field_id = Ids_core.Field_id
module Variant_id = Ids_core.Variant_id
module Callable_id = Ids_core.Callable_id
module Generic_param_id = Ids_core.Generic_param_id

(* Per-struct / per-enum declaration-order positions used by Seed MIR
   projections and discriminant tags (0..n-1). *)
module Field_index = Ids_core.Field_index
module Variant_index = Ids_core.Variant_index

type def_id = {
  module_id : Module_id.t;
  index : int;
}

let compare_def_id (a : def_id) (b : def_id) =
  let c = Module_id.compare a.module_id b.module_id in
  if c <> 0 then c else compare a.index b.index
