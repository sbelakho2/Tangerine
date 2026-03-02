(** Type environment for type checking *)

module StringMap = Map.Make(String)

(** Variable binding info *)
type var_info = {
  vi_type : Types.scheme;
  vi_mutable : bool;
  vi_loc : Location.t;
}

(** Function signature info *)
type fn_info = {
  fi_type_params : Types.type_param list;
  fi_param_types : Types.ty list;
  fi_return_type : Types.ty;
  fi_pure : bool;
  fi_effects : string list;
  fi_loc : Location.t;
}

(** Struct field info *)
type field_info = {
  fld_type : Types.ty;
  fld_public : bool;
  fld_index : int;
}

(** Struct info *)
type struct_info = {
  st_type_params : Types.type_param list;
  st_fields : field_info StringMap.t;
  st_loc : Location.t;
}

(** Enum variant info *)
type variant_info = {
  var_fields : Types.ty list;
  var_index : int;
}

(** Enum info *)
type enum_info = {
  en_type_params : Types.type_param list;
  en_variants : variant_info StringMap.t;
  en_loc : Location.t;
}

(** Trait method signature *)
type method_sig = {
  ms_type_params : Types.type_param list;
  ms_param_types : Types.ty list;
  ms_return_type : Types.ty;
  ms_has_default : bool;
}

(** Trait info *)
type trait_info = {
  tr_type_params : Types.type_param list;
  tr_super : string list;
  tr_methods : method_sig StringMap.t;
  tr_loc : Location.t;
}

(** Implementation info *)
type impl_info = {
  im_type_params : Types.type_param list;
  im_for_type : Types.ty;
  im_methods : fn_info StringMap.t;
}

(** Type alias info *)
type alias_info = {
  al_type_params : Types.type_param list;
  al_type : Types.ty;
}

(** Capability info *)
type cap_info = {
  cap_implies : string list;
}

(** Effect operation info *)
type effect_op_info = {
  eop_param_types : Types.ty list;
  eop_return_type : Types.ty;
}

(** Effect info *)
type effect_info = {
  eff_type_params : Types.type_param list;
  eff_ops : effect_op_info StringMap.t;
}

(** Type environment *)
type t = {
  (* Variables in scope *)
  vars : var_info StringMap.t;
  
  (* Functions *)
  functions : fn_info StringMap.t;
  
  (* Type definitions *)
  structs : struct_info StringMap.t;
  enums : enum_info StringMap.t;
  traits : trait_info StringMap.t;
  aliases : alias_info StringMap.t;
  
  (* Trait implementations *)
  impls : impl_info list;
  
  (* Capabilities and effects *)
  capabilities : cap_info StringMap.t;
  effects : effect_info StringMap.t;
  
  (* Current context *)
  current_fn : fn_info option;
  current_level : int;  (* For let-polymorphism *)
  self_type : Types.ty option;
  
  (* Available capabilities in current scope *)
  available_caps : string list;
  
  (* Active effects in current scope *)
  active_effects : string list;
}

(** Empty environment *)
let empty = {
  vars = StringMap.empty;
  functions = StringMap.empty;
  structs = StringMap.empty;
  enums = StringMap.empty;
  traits = StringMap.empty;
  aliases = StringMap.empty;
  impls = [];
  capabilities = StringMap.empty;
  effects = StringMap.empty;
  current_fn = None;
  current_level = 0;
  self_type = None;
  available_caps = [];
  active_effects = [];
}

(** Add builtin types *)
let with_builtins env =
  (* Add primitive type aliases *)
  let add_alias name ty env =
    { env with aliases = StringMap.add name { al_type_params = []; al_type = ty } env.aliases }
  in
  env
  |> add_alias "Unit" (Types.TPrim Types.TUnit)
  |> add_alias "Bool" (Types.TPrim Types.TBool)
  |> add_alias "Int" (Types.TPrim Types.TInt)
  |> add_alias "UInt" (Types.TPrim Types.TUInt)
  |> add_alias "Float" (Types.TPrim Types.TFloat)
  |> add_alias "Char" (Types.TPrim Types.TChar)
  |> add_alias "String" (Types.TPrim Types.TString)
  |> add_alias "i8" (Types.TPrim Types.TI8)
  |> add_alias "u8" (Types.TPrim Types.TU8)
  |> add_alias "i16" (Types.TPrim Types.TI16)
  |> add_alias "u16" (Types.TPrim Types.TU16)
  |> add_alias "i32" (Types.TPrim Types.TI32)
  |> add_alias "u32" (Types.TPrim Types.TU32)
  |> add_alias "i64" (Types.TPrim Types.TI64)
  |> add_alias "u64" (Types.TPrim Types.TU64)
  |> add_alias "f32" (Types.TPrim Types.TF32)
  |> add_alias "f64" (Types.TPrim Types.TF64)

(** Lookup a variable *)
let lookup_var name env =
  StringMap.find_opt name env.vars

(** Lookup a function *)
let lookup_fn name env =
  StringMap.find_opt name env.functions

(** Lookup a struct *)
let lookup_struct name env =
  StringMap.find_opt name env.structs

(** Lookup an enum *)
let lookup_enum name env =
  StringMap.find_opt name env.enums

(** Lookup a trait *)
let lookup_trait name env =
  StringMap.find_opt name env.traits

(** Lookup a type alias *)
let lookup_alias name env =
  StringMap.find_opt name env.aliases

(** Lookup a capability *)
let lookup_cap name env =
  StringMap.find_opt name env.capabilities

(** Lookup an effect *)
let lookup_effect name env =
  StringMap.find_opt name env.effects

(** Add a variable to the environment *)
let add_var name info env =
  { env with vars = StringMap.add name info env.vars }

(** Add a function to the environment *)
let add_fn name info env =
  { env with functions = StringMap.add name info env.functions }

(** Add a struct to the environment *)
let add_struct name info env =
  { env with structs = StringMap.add name info env.structs }

(** Add an enum to the environment *)
let add_enum name info env =
  { env with enums = StringMap.add name info env.enums }

(** Add a trait to the environment *)
let add_trait name info env =
  { env with traits = StringMap.add name info env.traits }

(** Add a type alias to the environment *)
let add_alias name info env =
  { env with aliases = StringMap.add name info env.aliases }

(** Add a capability to the environment *)
let add_cap name info env =
  { env with capabilities = StringMap.add name info env.capabilities }

(** Add an effect to the environment *)
let add_effect name info env =
  { env with effects = StringMap.add name info env.effects }

(** Add an impl *)
let add_impl info env =
  { env with impls = info :: env.impls }

(** Enter a new scope level *)
let enter_level env =
  { env with current_level = env.current_level + 1 }

(** Exit scope level *)
let exit_level env =
  { env with current_level = env.current_level - 1 }

(** Set current function context *)
let with_fn info env =
  { env with current_fn = Some info }

(** Set self type (in impl context) *)
let with_self_type ty env =
  { env with self_type = Some ty }

(** Add capabilities to scope *)
let with_caps caps env =
  { env with available_caps = caps @ env.available_caps }

(** Add effects to scope *)
let with_effects effs env =
  { env with active_effects = effs @ env.active_effects }

(** Check if capability is available *)
let has_cap name env =
  List.mem name env.available_caps

(** Check if effect is active *)
let has_effect name env =
  List.mem name env.active_effects
