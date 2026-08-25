(* ids.mli — Strong semantic IDs (audit §12).

   The primitive ID domains are defined in Ids_core (no dependency on
   Type_repr) and re-exported here so the `Ids.` prefix keeps working.
   Each `t` is a DISTINCT type path — Type_id.t, Field_id.t,
   Variant_id.t, Callable_id.t and Module_id.t can never be mixed
   accidentally.  Instance_id moved out to its own module
   (instance_id.ml): it carries Type_repr values, so it depends on
   Type_repr instead of the other way around.

   Field_index.t and Variant_index.t are deliberately SEPARATE from
   Field_id.t / Variant_id.t: they are the per-struct / per-enum
   declaration-order POSITION (0..n-1) used by the Seed MIR's field
   projections, variant projections, EnumCtor tags and SetDiscriminant,
   whereas Field_id / Variant_id are the globally-unique semantic
   declaration identities.  See seed_mir.ml's type-definition contract
   for the concrete distinction. *)

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

val compare_def_id : def_id -> def_id -> int
