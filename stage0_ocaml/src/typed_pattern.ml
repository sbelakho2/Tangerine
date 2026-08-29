(* typed_pattern.ml — the semantic pattern tree (re-audit P0 #3).

   The typechecker resolves each match arm's pattern ONCE into this
   semantic form (the arm's channel entry, keyed by (match node id, arm
   index)); MIR lowering consumes the semantic identities (VariantId,
   binding names/types, constants, field names) instead of re-interpreting
   the syntactic Ast.pattern.  A TP_or carries the COMMON binding
   interface (the alternative list plus the interface names — the checker
   enforces that every alternative binds the same names with the same
   mutability and compatible types, so lowering needs one binding set). *)

type t =
  | TP_wildcard
  | TP_binding of string * Type_repr.t * bool          (* name, type, is_mut *)
  | TP_literal of Seed_mir.constant * Type_repr.t
  | TP_variant of Ids.Variant_id.t * Type_repr.t * t list
  | TP_struct of Ids.Type_id.t * Type_repr.t * (string * t) list
  | TP_tuple of Type_repr.t * t list
  | TP_or of t list * string list                      (* alternatives + the common binding interface *)
  | TP_range of Type_repr.t * Seed_mir.constant * Seed_mir.constant * bool

(* The binding names of a pattern tree (the or-interface surface). *)
let rec binding_names (p : t) : string list =
  match p with
  | TP_wildcard | TP_literal _ | TP_range _ -> []
  | TP_binding (name, _, _) -> [ name ]
  | TP_variant (_, _, pats) -> List.concat_map binding_names pats
  | TP_struct (_, _, fields) -> List.concat_map (fun (_, p) -> binding_names p) fields
  | TP_tuple (_, pats) -> List.concat_map binding_names pats
  | TP_or (alts, _) -> List.concat_map binding_names alts

(* The full binding surface (name, type, mutability) — the arm scope the
   checker adds and the lowerer fills.  For TP_or the alternatives carry
   the SAME interface (enforced), so the surface is the union. *)
let rec bindings (p : t) : (string * Type_repr.t * bool) list =
  match p with
  | TP_wildcard | TP_literal _ | TP_range _ -> []
  | TP_binding (name, ty, mut_) -> [ (name, ty, mut_) ]
  | TP_variant (_, _, pats) -> List.concat_map bindings pats
  | TP_struct (_, _, fields) -> List.concat_map (fun (_, p) -> bindings p) fields
  | TP_tuple (_, pats) -> List.concat_map bindings pats
  | TP_or (alts, _) -> List.concat_map bindings alts

(* The sorted unique binding names of a pattern — the or-interface
   comparison key (order and duplication are irrelevant to the
   interface). *)
let interface_names (p : t) : string list =
  let names = List.sort_uniq String.compare (binding_names p) in
  names
