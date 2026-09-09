(* drop_plan.ml — Canonical concrete drop plans (audit P1-26 / P0-2).

   The self-hosted model is ConcreteTypeId -> DropPlanId with every
   destruction site referencing the plan.  The seed builds ONE canonical
   drop-plan table for the CONCRETE types (the program's type-definition
   table, post-mono): per TypeId the plan is a TREE of drop actions
   derived structurally ONCE from the def — never re-derived recursively
   per value at a drop site:

     type plan_node =
       | NoDrop                                   (* nothing to drop *)
       | DropLeaf                                 (* the whole value drops
                                                     under its own type's
                                                     plan / structural glue *)
       | Fields of field_plan array               (* a tuple/struct value:
                                                     per-position actions *)
       | EnumVariants of variant_plan array       (* an enum value: the
                                                     runtime tag selects
                                                     the live variant *)
       | Repeat of { count : int; element : plan_node }   (* a fixed-array
                                                     value: the ELEMENT plan
                                                     repeats `count` times *)

   A struct's plan is a Fields node with one field_plan per field
   (declaration order, fp_index = fd_index); an enum's plan is an
   EnumVariants node with one variant_plan per variant (vp_tag = the
   declaration-order runtime tag, payload positions in payload order);
   a tuple/fixed-array type has no TypeId in the table — the drop sites
   fall back to the structural value glue for them (and for every type
   whose plan is not materialized), exactly the sanctioned fallback.

   FIXED ARRAYS ARE CONSTANT-SIZE PLANS (audit P0-2): an owning fixed
   array [T; n] inside a def becomes Repeat { count = n; element = ... }
   — a [String; 1_000_000] field is ONE Repeat node, never a materialized
   one-million-element list.  There is NO size cutoff in the plan: the
   plan of any array — however large — is built in constant time and
   space.  Only the VERIFIER's lattice-key expansion (owning_paths,
   below) keeps its documented bound: the destroyed lattice only needs
   exact per-index keys for drop emissions that can actually reach them
   (today none reach arrays beyond the bound); the plan itself never
   gives up.

   needs_drop per component comes from the ONE type-property engine
   (Type_properties, P1-25 / P0-2) over the same def table — the drop
   plan and the copyability answers can never disagree.  The engine's
   nominal resolver overlays the table's Lang_items record (lang_items.ml)
   on the def-table lookup: an owning LangItem (Vec/Map/Set/Box/Rc/Arc/
   ...) answers its DIRECT properties { copy = false; drop = true }
   (never its field-less def shape), a raw pointer (Ptr/PtrMut) answers
   { copy = true; drop = false }.  A needs_drop component is a component
   whose type is not trivially copyable (String, an owning nominal, an
   aggregate carrying one, ...); the verifier's drop accounting consults
   the plan's owning paths when a whole-root drop destroys a local, so
   the destroyed lattice records exactly the components the type-level
   plan names.

   Ordering invariant: component order is declaration order (struct
   fields by fd_index, enum variants by vd_index with payload components
   in payload order) — the same order the recursive value glue
   traverses, so a plan-driven drop frees in exactly the order the
   structural glue would. *)

type plan_node =
  | NoDrop
  | DropLeaf
  | Fields of field_plan array
  | EnumVariants of variant_plan array
  | Repeat of { count : int; element : plan_node }

and field_plan = {
  fp_index : int;           (* fd_index / payload position / tuple position *)
  fp_ty : Type_repr.t;      (* the component's concrete type *)
  fp_node : plan_node;      (* the component's drop action *)
}

and variant_plan = {
  vp_tag : int;             (* declaration-order runtime tag (vd_index) *)
  vp_fields : field_plan array;  (* payload positions, payload order *)
}

type plan = {
  type_id : Ids.Type_id.t;
  node : plan_node;
}

type table = {
  by_id : (Ids.Type_id.t, plan) Hashtbl.t;
  types : Seed_mir.type_def array; (* the def table the plans are derived from *)
  lang_items : Lang_items.t;       (* the compilation's LangItems record *)
}

(* ── Plan construction (per program, once) ─────────────────────────
   The component needs_drop flags are the type engine's answers over
   the same def table; the engine's cache is per-construction, so the
   table build never mixes def tables. *)

let find_def (tbl : table) (tid : Ids.Type_id.t) : Seed_mir.type_def option =
  let found = ref None in
  Array.iter
    (fun d -> if Seed_mir.def_id d = tid && !found = None then found := Some d)
    tbl.types;
  !found

(* The engine's nominal resolver for THIS table: the LangItems overlay
   (direct owning-handle / raw-pointer answers) over the def-table
   resolver (a def resolves to its def_repr shape) — no numeric
   builtin-id knowledge, no fake tuple shapes. *)
let engine_resolve (tbl : table) : Type_properties.def_resolver =
  Type_properties.with_lang_items (Some tbl.lang_items)
    (Type_properties.structural_resolver (fun tid ->
       Option.map Seed_mir.def_repr (find_def tbl tid)))

let needs_drop_of (tbl : table) (cache : Type_properties.cache) (ty : Type_repr.t) : bool =
  let p = Type_properties.of_type_cached cache (Some (engine_resolve tbl)) ty in
  p.Type_properties.needs_drop

(* The drop node of one component TYPE: NoDrop when the type needs no
   drop; a fixed array is a constant-size Repeat; a tuple is a Fields
   node over its positions; every other owning type is a DropLeaf whose
   own recursion runs under its type's plan/glue at the drop site. *)
let rec node_of_type (tbl : table) (cache : Type_properties.cache) (ty : Type_repr.t) :
    plan_node =
  if not (needs_drop_of tbl cache ty) then NoDrop
  else
    match ty with
    | Type_repr.Fixed_array (elem, n) ->
        (* constant-size regardless of n — [Owned; 1_000_000] is ONE
           Repeat (1_000_000, DropLeaf) node *)
        Repeat { count = n; element = node_of_type tbl cache elem }
    | Type_repr.Tuple elems ->
        Fields
          (Array.mapi
             (fun i t ->
               { fp_index = i; fp_ty = t; fp_node = node_of_type tbl cache t })
             elems)
    | _ -> DropLeaf

let plan_of_def (tbl : table) (cache : Type_properties.cache) (tid : Ids.Type_id.t)
    (d : Seed_mir.type_def) : plan =
  match d with
  | Seed_mir.StructDef { sd_fields; _ } ->
      let fields =
        List.sort
          (fun a b -> Ids.Field_index.compare a.Seed_mir.fd_index b.Seed_mir.fd_index)
          sd_fields
      in
      {
        type_id = tid;
        node =
          Fields
            (Array.of_list
               (List.map
                  (fun f ->
                    let fty = f.Seed_mir.fd_ty in
                    {
                      fp_index = Ids.Field_index.to_int f.Seed_mir.fd_index;
                      fp_ty = fty;
                      fp_node = node_of_type tbl cache fty;
                    })
                  fields));
      }
  | Seed_mir.EnumDef { ed_variants; _ } ->
      let variants =
        List.sort
          (fun a b -> Ids.Variant_index.compare a.Seed_mir.vd_index b.Seed_mir.vd_index)
          ed_variants
      in
      {
        type_id = tid;
        node =
          EnumVariants
            (Array.of_list
               (List.map
                  (fun v ->
                    let tag = Ids.Variant_index.to_int v.Seed_mir.vd_index in
                    let fields =
                      match v.Seed_mir.vd_payload with
                      | Type_repr.Unit -> [||]
                      | Type_repr.Tuple payloads ->
                          Array.mapi
                            (fun j ty ->
                              {
                                fp_index = j;
                                fp_ty = ty;
                                fp_node = node_of_type tbl cache ty;
                              })
                            payloads
                      | other ->
                          (* a single-component payload spelling
                             (defensive: the materialized defs always
                             wrap payloads in a Tuple) *)
                          [|
                            {
                              fp_index = 0;
                              fp_ty = other;
                              fp_node = node_of_type tbl cache other;
                            };
                          |]
                    in
                    { vp_tag = tag; vp_fields = fields })
                  variants));
      }

let of_program ?(lang_items : Lang_items.t = Lang_items.seed_defaults)
    (prog : Seed_mir.program) : table =
  let tbl =
    { by_id = Hashtbl.create 256; types = prog.Seed_mir.types; lang_items }
  in
  let cache = Type_properties.create_cache () in
  Array.iter
    (fun d ->
      let tid = Seed_mir.def_id d in
      if not (Hashtbl.mem tbl.by_id tid) then
        Hashtbl.replace tbl.by_id tid (plan_of_def tbl cache tid d))
    prog.Seed_mir.types;
  tbl

(* ── Lookups (the destruction sites' consult) ──────────────────────
   plan_of_type: the canonical plan of a Named type whose def is in the
   table; None when the type has no materialized plan (the caller falls
   back to the structural value glue).  Tuple/fixed-array values have no
   table plan and are always glue-fallback (their recursion is purely
   positional); owning_paths below synthesizes their per-position
   owning paths so the verifier's expansion covers the same paths a
   projected drop would key. *)

let plan_of_type (tbl : table) (ty : Type_repr.t) : plan option =
  match ty with
  | Type_repr.Named (tid, _) -> Hashtbl.find_opt tbl.by_id tid
  | _ -> None

(* The owning component paths of a drop of `ty`, rendered in the
   verifier's place-key segment convention (a struct field contributes
   `field#<fid>`; a tuple/fixed-array/payload position contributes its
   index; an enum's variant contributes NO segment — a Downcast is
   invisible to a place key, so the lattice is keyed per root, exactly
   like the verifier's own place_key).  Returns the RELATIVE keys of
   every component at every depth the type-level plan marks needs_drop —
   the components a recursive drop actually destroys — so the
   destroyed-lattice consult of a whole-root drop records owning
   sub-paths too (a later drop of any of them is a duplicate drop, the
   VM's do_drop traps on any second drop of the same root local).

   The walk mirrors the plan_node structure: a def plan's Fields node
   contributes each owning field's segment then descends the field's
   own node; an EnumVariants node contributes every owning payload
   position of every variant (the runtime tag is invisible to the
   lattice); a Repeat node contributes per-index keys up to
   lattice_array_key_bound — the plan itself is CONSTANT-SIZE for any
   count (audit P0-2), while the lattice only needs exact index keys
   for drop emissions that reach them (huge arrays stay approximate —
   no drop emission reaches them today). *)
let lattice_array_key_bound = 1024

let owning_paths (tbl : table) (ty : Type_repr.t) : string list =
  let cache = Type_properties.create_cache () in
  let acc = ref [] in
  let add (prefix : string list) (seg : string) : unit =
    acc := String.concat "." (List.rev (seg :: prefix)) :: !acc
  in
  let struct_field_seg (parent_ty : Type_repr.t) (index : int) : string =
    match parent_ty with
    | Type_repr.Named (tid, _) -> (
        match find_def tbl tid with
        | Some (Seed_mir.StructDef { sd_fields; _ }) -> (
            match
              List.find_opt
                (fun f -> Ids.Field_index.to_int f.Seed_mir.fd_index = index)
                sd_fields
            with
            | Some f -> Printf.sprintf "field#%d" (Ids.Field_id.to_int f.Seed_mir.fd_id)
            | None -> string_of_int index)
        | _ -> string_of_int index)
    | _ -> string_of_int index
  in
  let rec walk_type (seen_tids : Ids.Type_id.t list) (prefix : string list)
      (ty : Type_repr.t) : unit =
    match plan_of_type tbl ty with
    | Some plan ->
        if List.exists (fun t -> Ids.Type_id.compare t plan.type_id = 0) seen_tids then ()
          (* def-cycle guard: value-recursive defs are impossible (a def
             mentioning itself would be an infinite value), but the
             guard keeps the flattening total if one ever materializes *)
        else
          let seen_tids' = plan.type_id :: seen_tids in
          walk_node seen_tids' prefix ty plan.node
    | None -> (
        match ty with
        | Type_repr.Tuple elems ->
            Array.iteri
              (fun j e ->
                if needs_drop_of tbl cache e then begin
                  add prefix (string_of_int j);
                  walk_type seen_tids (string_of_int j :: prefix) e
                end)
              elems
        | Type_repr.Fixed_array (elem, n) ->
            if n <= lattice_array_key_bound && needs_drop_of tbl cache elem then
              for i = 0 to n - 1 do
                add prefix (string_of_int i)
              done
        | _ -> ())
  and walk_node (seen_tids : Ids.Type_id.t list) (prefix : string list)
      (parent_ty : Type_repr.t) (node : plan_node) : unit =
    match node with
    | NoDrop -> ()
    | DropLeaf ->
        (* the component drops under its own type's plan/glue: descend
           through the type (its def plan / structural fallback) *)
        walk_type seen_tids prefix parent_ty
    | Fields fps ->
        Array.iter
          (fun (fp : field_plan) ->
            if fp.fp_node <> NoDrop then begin
              let seg = struct_field_seg parent_ty fp.fp_index in
              add prefix seg;
              walk_node seen_tids (seg :: prefix) fp.fp_ty fp.fp_node
            end)
          fps
    | Repeat { count; element } ->
        if element <> NoDrop && count <= lattice_array_key_bound then
          for i = 0 to count - 1 do
            add prefix (string_of_int i)
          done
    | EnumVariants vps ->
        Array.iter
          (fun (vp : variant_plan) ->
            Array.iter
              (fun (fp : field_plan) ->
                if fp.fp_node <> NoDrop then begin
                  let seg = string_of_int fp.fp_index in
                  add prefix seg;
                  walk_node seen_tids (seg :: prefix) fp.fp_ty fp.fp_node
                end)
              vp.vp_fields)
          vps
  in
  walk_type [] [] ty;
  List.sort_uniq String.compare !acc
