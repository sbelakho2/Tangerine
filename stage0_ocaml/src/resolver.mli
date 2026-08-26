(* resolver.mli — public surface of the name resolver (audit §24, §62). *)

(* Lookup outcome: the Ambiguous/Unknown distinction.  `Unknown` means no
   candidate; `Ambiguous` carries the reason (never a silent first-wins). *)
type 'a resolution = Unknown | Ambiguous of string | Resolved of 'a

(* What a module-qualified path names. *)
type path_target =
  | PTModule of Ids.Module_id.t
  | PTItem of Ids.def_id
  | PTVariant of Ids.def_id * Ids.Variant_id.t

type resolved_program = {
  graph : Module_graph.t;
  expr_defs : (Ids.Module_id.t * int) list;
      (* value definitions (functions, tests, consts, statics, extern
         items); DefId = { module_id; index = item index } *)
  type_defs : (Ids.Module_id.t * int) list;
      (* type definitions (structs, enums, traits, type aliases) *)
  field_defs : (Ids.Module_id.t * int * int) list;
      (* (module, struct item index, field index); the k-th entry is
         FieldId k *)
  variant_defs : (Ids.Module_id.t * int * int) list;
      (* (module, enum item index, variant index); the k-th entry is
         VariantId k *)
  call_candidates : (Ids.Module_id.t * int) list;
      (* free-function call targets (DefId pairs) in CallableId order *)
  state : state;
}

and state

(* Resolve a compilation: iterate modules in manifest order, items in
   source order; build per-module symbol tables, resolve imports
   (E2001), report ambiguous names (E2002) and unresolved mandatory
   names (E2003, impl targets/traits and trait supertraits).  strict
   disables the flat/global unique-name recovery (the future compiler
   mode's per-module ModuleId/DefId authority): wrong module ->
   unresolved import. *)
val resolve : ?strict:bool -> Bootstrap_manifest.t -> Module_graph.t -> Diagnostic.bag -> resolved_program

(* Bare-name lookups.  Authority order: explicit/aliased/group imports,
   then glob imports, then the module's own items; a glob colliding with
   an explicit import or a local item is AMBIGUOUS. *)
val resolve_value_name : resolved_program -> Ids.Module_id.t -> string -> Ids.def_id resolution
val resolve_type_name : resolved_program -> Ids.Module_id.t -> string -> Ids.def_id resolution

(* Member lookups: the struct/enum/target-type name resolves in the
   module's scope (imports included), then the member is looked up on
   the resolved definition. *)
val resolve_field : resolved_program -> Ids.Module_id.t -> string -> string -> Ids.Field_id.t resolution
val resolve_variant : resolved_program -> Ids.Module_id.t -> string -> string -> Ids.Variant_id.t resolution
val resolve_method : resolved_program -> Ids.Module_id.t -> string -> string -> Ids.Callable_id.t resolution

(* Module-qualified path lookup (std::core::Option,
   geometry::shapes::Circle, Option::Some). *)
val resolve_qualified : resolved_program -> Ids.Module_id.t -> string list -> path_target resolution
