(* drop_plan.ml — Canonical concrete drop plans (audit P1-26).

   The self-hosted model is ConcreteTypeId -> DropPlanId with every
   destruction site referencing the plan.  The seed builds ONE canonical
   drop-plan table for the CONCRETE types (the program's type-definition
   table, post-mono): per TypeId the plan is the ordered list of
   (field/payload path, needs_drop) entries derived structurally ONCE
   from the def — never re-derived recursively per value at a drop site.

   Plan shape: a struct's plan lists each field (declaration order) as
   a component { variant = None; index = fd_index; ty; needs_drop }; an
   enum's plan lists every variant's payload components as { variant =
   Some tag; index = payload position; ... } — the runtime tag selects
   the live variant at destruction time (the seed's Enum value carries
   the declaration-order tag = vd_index).  Tuple/fixed-array values
   have no TypeId in the table: the drop sites fall back to the
   structural value glue for them (and for every type whose plan is not
   materialized), exactly the sanctioned fallback.

   needs_drop per component comes from the ONE type-property engine
   (Type_properties, P1-25) over the same def table — the drop plan and
   the copyability answers can never disagree.  A needs_drop component
   is a component whose type is not trivially copyable (String, an
   owning nominal, an aggregate carrying one, ...); the verifier's drop
   accounting consults the plan's owning paths when a whole-root drop
   destroys a local, so the destroyed lattice records exactly the
   components the type-level plan names.

   Ordering invariant: component order is declaration order (struct
   fields by fd_index, enum variants by vd_index with payload
   components in payload order) — the same order the recursive value
   glue traverses, so a plan-driven drop frees in exactly the order the
   structural glue would. *)

type component = {
  variant : int option;      (* Some tag for an enum payload component;
                                None for a struct field / tuple element *)
  index : int;               (* fd_index / payload position / tuple index *)
  ty : Type_repr.t;          (* the component's concrete type *)
  needs_drop : bool;         (* the type engine's property of ty *)
}

type plan = {
  type_id : Ids.Type_id.t;
  components : component list;   (* declaration order *)
}

type table = {
  by_id : (Ids.Type_id.t, plan) Hashtbl.t;
  types : Seed_mir.type_def array; (* the def table the plans are derived from *)
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

let engine_resolve (tbl : table) (tid : Ids.Type_id.t) : Type_repr.t option =
  match find_def tbl tid with
  | Some d -> Some (Seed_mir.def_repr d)
  | None -> (
      (* the builtin runtime nominals' canonical def shapes — the same
         fallback the pipeline's authoritative copy answers use
         (mir_verify.is_copy): the handle nominals Vec/Map/Set (0/1/2)
         and Ptr/PtrMut (5/6) never materialize (their runtime semantics
         are keyed on the original ids), so their properties are their
         canonical runtime shapes: the pointer-represented containers
         and the address handles are Copy; the owning LangItems that DO
         materialize (Option/Result/Box instances) always carry defs and
         resolve above. *)
      match Ids.Type_id.to_int tid with
      | 0 | 1 | 2 -> Some (Type_repr.Tuple [||])
      | 5 | 6 -> Some (Type_repr.Tuple [| Type_repr.Int Type_repr.UInt |])
      | _ -> None)

let needs_drop_of (tbl : table) (cache : Type_properties.cache) (ty : Type_repr.t) : bool =
  let p =
    Type_properties.of_type_cached cache (Some (engine_resolve tbl)) ty
  in
  p.Type_properties.needs_drop

let components_of_def (tbl : table) (cache : Type_properties.cache)
    (tid : Ids.Type_id.t) (d : Seed_mir.type_def) : plan =
  match d with
  | Seed_mir.StructDef { sd_fields; _ } ->
      let fields =
        List.sort (fun a b -> Ids.Field_index.compare a.Seed_mir.fd_index b.Seed_mir.fd_index)
          sd_fields
      in
      let components =
        List.map
          (fun f ->
            {
              variant = None;
              index = Ids.Field_index.to_int f.Seed_mir.fd_index;
              ty = f.Seed_mir.fd_ty;
              needs_drop = needs_drop_of tbl cache f.Seed_mir.fd_ty;
            })
          fields
      in
      { type_id = tid; components }
  | Seed_mir.EnumDef { ed_variants; _ } ->
      let variants =
        List.sort
          (fun a b -> Ids.Variant_index.compare a.Seed_mir.vd_index b.Seed_mir.vd_index)
          ed_variants
      in
      let components =
        List.concat_map
          (fun v ->
            let tag = Ids.Variant_index.to_int v.Seed_mir.vd_index in
            match v.Seed_mir.vd_payload with
            | Type_repr.Unit -> []
            | Type_repr.Tuple payloads ->
                Array.to_list
                  (Array.mapi
                     (fun j ty ->
                       {
                         variant = Some tag;
                         index = j;
                         ty;
                         needs_drop = needs_drop_of tbl cache ty;
                       })
                     payloads)
            | other ->
                (* a single-component payload spelling (defensive: the
                   materialized defs always wrap payloads in a Tuple) *)
                [
                  {
                    variant = Some tag;
                    index = 0;
                    ty = other;
                    needs_drop = needs_drop_of tbl cache other;
                  };
                ])
          variants
      in
      { type_id = tid; components }

let of_program (prog : Seed_mir.program) : table =
  let tbl =
    {
      by_id = Hashtbl.create 256;
      types = prog.Seed_mir.types;
    }
  in
  let cache = Type_properties.create_cache () in
  Array.iter
    (fun d ->
      let tid = Seed_mir.def_id d in
      if not (Hashtbl.mem tbl.by_id tid) then
        Hashtbl.replace tbl.by_id tid (components_of_def tbl cache tid d))
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
   Fixed arrays contribute per-index keys up to a bound (the lattice
   only needs exact index keys; huge arrays stay approximate — no drop
   emission reaches them today). *)
let owning_paths (tbl : table) (ty : Type_repr.t) : string list =
  let cache = Type_properties.create_cache () in
  let acc = ref [] in
  let seg_of (ty : Type_repr.t) (c : component) : string =
    match c.variant with
    | Some _ -> string_of_int c.index
    | None -> (
        match ty with
        | Type_repr.Named (tid, _) -> (
            match find_def tbl tid with
            | Some (Seed_mir.StructDef { sd_fields; _ }) -> (
                match
                  List.find_opt
                    (fun f ->
                      Ids.Field_index.to_int f.Seed_mir.fd_index = c.index)
                    sd_fields
                with
                | Some f -> Printf.sprintf "field#%d" (Ids.Field_id.to_int f.Seed_mir.fd_id)
                | None -> string_of_int c.index)
            | _ -> string_of_int c.index)
        | _ -> string_of_int c.index)
  in
  let add (prefix : string list) (seg : string) : unit =
    acc := String.concat "." (List.rev (seg :: prefix)) :: !acc
  in
  let rec go (seen_tids : Ids.Type_id.t list) (prefix : string list) (ty : Type_repr.t) : unit =
    match plan_of_type tbl ty with
    | Some plan ->
        if List.exists (fun t -> Ids.Type_id.compare t plan.type_id = 0) seen_tids then ()
          (* def-cycle guard: value-recursive defs are impossible (a def
             mentioning itself would be an infinite value), but the
             guard keeps the flattening total if one ever materializes *)
        else
          let seen_tids' = plan.type_id :: seen_tids in
          List.iter
            (fun (c : component) ->
              if c.needs_drop then begin
                let seg = seg_of ty c in
                add prefix seg;
                (* descend through the owning component: its own plan's
                   owning components die with it *)
                go seen_tids' (seg :: prefix) c.ty
              end)
            plan.components
    | None -> (
        match ty with
        | Type_repr.Tuple elems ->
            Array.iteri
              (fun j e ->
                if needs_drop_of tbl cache e then begin
                  add prefix (string_of_int j);
                  go seen_tids (string_of_int j :: prefix) e
                end)
              elems
        | Type_repr.Fixed_array (elem, n) ->
            if n <= 1024 && needs_drop_of tbl cache elem then
              for i = 0 to n - 1 do
                add prefix (string_of_int i)
              done
        | _ -> ())
  in
  go [] [] ty;
  List.sort_uniq String.compare !acc
