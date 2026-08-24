(* resolver.ml — Name resolution for the OCaml Tangerine bootstrap seed
   (audit §24, §62).

   Model
   -----
   Each top-level item of module M at index i (its position in the
   module's item list, source order) gets a DefId { module_id = M;
   index = i }.  Struct fields get FieldIds (module, struct item index,
   field index); enum variants get VariantIds (module, enum item index,
   variant index); methods get CallableIds (module, impl/struct/trait
   item index, method index) plus a lookup from (target type def, method
   name).  Inline `module ... end` declarations are modules with their
   own item-index space; the resolver iterates modules in manifest order
   and items in source order.

   Value namespace: functions, tests, consts, statics, extern
   functions/statics.  Type namespace: structs, enums, traits, type
   aliases.

   Bare-name resolution (no Swift-style post-lowering normalization, no
   Vec<->Array aliases): local scope is not modeled (the resolver binds
   ITEM names; expressions resolve at typecheck).  Candidates are
   gathered from (1) use-imports (explicit/aliased/group, then glob), (2)
   the module's own items, with the 0/1/>1 rule: a glob import colliding
   with an explicit import or a local item is AMBIGUOUS, never silently
   first-wins.  Module-qualified paths (std::core::Option,
   geometry::shapes::Circle) resolve through the module graph.

   Diagnostics: E2001 unresolved import, E2002 ambiguous name, E2003
   unresolved name.  All iteration is deterministic (lists in manifest/
   source order, Map iteration); no Hashtbl iteration anywhere. *)

module SMap = Util.StringMap
module IntMap = Map.Make (Int)

module DefMap = Map.Make (struct
  type t = Ids.def_id

  let compare = Ids.compare_def_id
end)

(* ── Namespaces ─────────────────────────────────────────────── *)

type namespace = Value | Type

type def_kind = DValue | DType

(* The target of an import binding. *)
type import_target = ITModule of Ids.Module_id.t | ITItem of Ids.def_id

(* What a module-qualified path names. *)
type path_target =
  | PTModule of Ids.Module_id.t
  | PTItem of Ids.def_id
  | PTVariant of Ids.def_id * Ids.Variant_id.t

(* Lookup outcome: the Ambiguous/Unknown distinction. *)
type 'a resolution = Unknown | Ambiguous of string | Resolved of 'a

type import_binding = {
  ib_name : string;
  ib_target : import_target;
  ib_ns : namespace option;   (* None for module targets *)
  ib_span : Span.span;
}

type glob_import = { gi_module : Ids.Module_id.t; gi_span : Span.span }

(* Per-module scope: own items, resolved imports, glob sources,
   child-module (inline) names. *)
type scope = {
  sc_own_values : Ids.def_id SMap.t;
  sc_own_types : Ids.def_id SMap.t;
  sc_imports : import_binding list SMap.t;  (* name -> bindings, source order *)
  sc_globs : glob_import list;            (* source order *)
  sc_submodules : Ids.Module_id.t SMap.t;   (* child module name -> id *)
}

type tables = {
  tb_scopes : scope IntMap.t;
  tb_def_kinds : def_kind DefMap.t;
  tb_fields : Ids.Field_id.t SMap.t DefMap.t;
  tb_variants : Ids.Variant_id.t SMap.t DefMap.t;
  tb_methods : Ids.Callable_id.t SMap.t DefMap.t;
}

type callable = CFree of Ids.Module_id.t * int | CMethod of Ids.Module_id.t * int * int

type state = {
  st_tables : tables;
  st_callables : callable list;   (* dense CallableId enumeration order *)
}

type resolved_program = {
  graph : Module_graph.t;
  expr_defs : (Ids.Module_id.t * int) list;
  type_defs : (Ids.Module_id.t * int) list;
  field_defs : (Ids.Module_id.t * int * int) list;
  variant_defs : (Ids.Module_id.t * int * int) list;
  call_candidates : (Ids.Module_id.t * int) list;
  state : state;
}

(* ── Small helpers ──────────────────────────────────────────── *)

let join_path (p : string list) : string = String.concat "::" p

let last_seg (l : string list) : string =
  match List.rev l with x :: _ -> x | [] -> ""

let rec take (n : int) (l : 'a list) : 'a list =
  if n <= 0 then [] else match l with [] -> [] | x :: xs -> x :: take (n - 1) xs

let rec drop (n : int) (l : 'a list) : 'a list =
  if n <= 0 then l else match l with [] -> [] | _ :: xs -> drop (n - 1) xs

let module_name_segments (name : string) : string list =
  String.split_on_char ':' name |> List.filter (fun s -> s <> "")

let empty_scope () : scope =
  {
    sc_own_values = SMap.empty;
    sc_own_types = SMap.empty;
    sc_imports = SMap.empty;
    sc_globs = [];
    sc_submodules = SMap.empty;
  }

let def_kind_of (tables : tables) (def : Ids.def_id) : namespace option =
  match DefMap.find_opt def tables.tb_def_kinds with
  | Some DValue -> Some Value
  | Some DType -> Some Type
  | None -> None

(* ── Candidate collection (deterministic) ───────────────────── *)

let scope_of (tables : tables) (m : Ids.Module_id.t) : scope option =
  IntMap.find_opt (Ids.Module_id.to_int m) tables.tb_scopes

let own_candidates (tables : tables) (m : Ids.Module_id.t) (ns : namespace) (name : string) :
    Ids.def_id option =
  match scope_of tables m with
  | None -> None
  | Some sc -> (
      match ns with
      | Value -> SMap.find_opt name sc.sc_own_values
      | Type -> SMap.find_opt name sc.sc_own_types)

(* Explicit/aliased/group imports binding `name` as an item of `ns`. *)
let explicit_candidates (tables : tables) (m : Ids.Module_id.t) (ns : namespace) (name : string) :
    Ids.def_id list =
  match scope_of tables m with
  | None -> []
  | Some sc -> (
      match SMap.find_opt name sc.sc_imports with
      | None -> []
      | Some bs ->
          List.filter_map
            (fun b ->
              match (b.ib_target, b.ib_ns) with
              | ITItem def, Some ns' when ns' = ns -> Some def
              | _ -> None)
            bs)

(* Glob imports: the source module's own items of `ns` named `name`. *)
let glob_candidates (tables : tables) (m : Ids.Module_id.t) (ns : namespace) (name : string) :
    Ids.def_id list =
  match scope_of tables m with
  | None -> []
  | Some sc ->
      List.filter_map
        (fun g ->
          match scope_of tables g.gi_module with
          | None -> None
          | Some src -> (
              match ns with
              | Value -> SMap.find_opt name src.sc_own_values
              | Type -> SMap.find_opt name src.sc_own_types))
        sc.sc_globs

let dedup_defs (ds : Ids.def_id list) : Ids.def_id list =
  List.rev
    (List.fold_left
       (fun acc d -> if List.exists (fun d' -> Ids.compare_def_id d d' = 0) acc then acc else d :: acc)
       [] ds)

(* The bare-name 0/1/>1 rule (authority order: explicit imports, then
   glob imports, then the module's own items; a glob colliding with an
   explicit import or a local item is AMBIGUOUS — never first-wins). *)
let bare_name_resolve (tables : tables) (m : Ids.Module_id.t) (ns : namespace) (name : string) :
    Ids.def_id resolution =
  let expl = dedup_defs (explicit_candidates tables m ns name) in
  let globs = dedup_defs (glob_candidates tables m ns name) in
  let own = own_candidates tables m ns name in
  match expl with
  | _ :: _ ->
      if globs <> [] then
        Ambiguous (Printf.sprintf "glob import collides with explicit import of '%s'" name)
      else
        (match expl with
         | [ d ] -> Resolved d
         | _ -> Ambiguous (Printf.sprintf "name '%s' is bound by multiple explicit imports" name))
  | [] -> (
      match globs with
      | _ :: _ -> (
          match own with
          | Some _ -> Ambiguous (Printf.sprintf "glob import collides with local item '%s'" name)
          | None -> (
              match globs with
              | [ d ] -> Resolved d
              | _ ->
                  Ambiguous (Printf.sprintf "name '%s' is provided by multiple glob imports" name)))
      | [] -> (
          match own with
          | Some d -> Resolved d
          | None -> Unknown))

(* Item lookup within a module's own items. *)
let item_target (tables : tables) (m : Ids.Module_id.t) (name : string) : path_target list =
  match scope_of tables m with
  | None -> []
  | Some sc ->
      let vs =
        match SMap.find_opt name sc.sc_own_values with Some d -> [ PTItem d ] | None -> []
      in
      let ts =
        match SMap.find_opt name sc.sc_own_types with Some d -> [ PTItem d ] | None -> []
      in
      vs @ ts

(* Variant lookup: enum (own item of m) + variant name. *)
let variant_target (tables : tables) (m : Ids.Module_id.t) (enum_name : string)
    (variant_name : string) : path_target list =
  match scope_of tables m with
  | None -> []
  | Some sc -> (
      match SMap.find_opt enum_name sc.sc_own_types with
      | None -> []
      | Some def -> (
          match DefMap.find_opt def tables.tb_variants with
          | None -> []
          | Some vs -> (
              match SMap.find_opt variant_name vs with
              | Some vid -> [ PTVariant (def, vid) ]
              | None -> [])))

let module_path_of (graph : Module_graph.t) (m : Ids.Module_id.t) : string list option =
  match Module_graph.find_module_by_id graph m with
  | Some n -> Some n.Module_graph.node_path
  | None -> None

(* Targets a concrete path can name: the path is a module, or a module
   prefix followed by one item name, or a module prefix followed by an
   enum name and a variant name. *)
let targets_of_path (graph : Module_graph.t) (tables : tables) (p : string list) : path_target list =
  match Module_graph.find_module_by_path graph p with
  | Some n -> [ PTModule n.Module_graph.node_id ]
  | None -> (
      match p with
      | [] | [ _ ] -> []
      | _ ->
          let rec walk (k : int) : path_target list =
            if k < 1 then []
            else
              let prefix = take k p in
              let rest = drop k p in
              match Module_graph.find_module_by_path graph prefix with
              | None -> walk (k - 1)
              | Some mnode -> (
                  match rest with
                  | [ item_name ] -> (
                      match item_target tables mnode.Module_graph.node_id item_name with
                      | [] -> walk (k - 1)
                      | ts -> ts)
                  | [ enum_name; variant_name ] -> (
                      match variant_target tables mnode.Module_graph.node_id enum_name variant_name with
                      | [] -> walk (k - 1)
                      | ts -> ts)
                  | _ -> walk (k - 1))
          in
          walk (List.length p - 1))

(* Resolve a module-qualified path from module m.  Candidates are
   enumerated deterministically: crate-relative, super-relative, the
   current module's own subtree, absolute paths, then module-import
   bindings of the first segment. *)
let resolve_path_target (graph : Module_graph.t) (tables : tables) (m : Ids.Module_id.t)
    (segs : string list) : path_target resolution =
  match segs with
  | [] -> Unknown
  | [ single ] -> (
      match bare_name_resolve tables m Type single with
      | Resolved def -> Resolved (PTItem def)
      | Ambiguous a -> Ambiguous a
      | Unknown -> (
          match bare_name_resolve tables m Value single with
          | Resolved def -> Resolved (PTItem def)
          | Ambiguous a -> Ambiguous a
          | Unknown -> Unknown))
  | _ ->
      let current_path = match module_path_of graph m with Some p -> p | None -> [] in
      let cands = ref [] in
      let add_path (p : string list) = if not (List.mem p !cands) then cands := p :: !cands in
      (match segs with
       | "crate" :: rest -> add_path rest
       | "super" :: rest -> (
           let parent = match current_path with _ :: t -> t | [] -> [] in
           add_path (parent @ rest))
       | _ ->
           add_path (current_path @ segs);
           add_path segs;
           (* the first segment bound as a module import *)
           (match scope_of tables m with
            | Some sc -> (
                match SMap.find_opt (List.hd segs) sc.sc_imports with
                | Some bs ->
                    List.iter
                      (fun b ->
                        match b.ib_target with
                        | ITModule mid -> (
                            match module_path_of graph mid with
                            | Some p -> add_path (p @ List.tl segs)
                            | None -> ())
                        | _ -> ())
                      bs
                | None -> ())
            | None -> ()));
      let targets = ref [] in
      List.iter
        (fun p ->
          List.iter
            (fun t -> if not (List.mem t !targets) then targets := t :: !targets)
            (targets_of_path graph tables p))
        !cands;
      (match List.rev !targets with
       | [] -> (
           (* 2-segment enum-variant fallback: Option::Some *)
           match segs with
           | [ e; v ] -> (
               match bare_name_resolve tables m Type e with
               | Resolved def -> (
                   match DefMap.find_opt def tables.tb_variants with
                   | Some vs -> (
                       match SMap.find_opt v vs with
                       | Some vid -> Resolved (PTVariant (def, vid))
                       | None -> Unknown)
                   | None -> Unknown)
               | Ambiguous a -> Ambiguous a
               | Unknown -> Unknown)
           | _ -> Unknown)
       | [ t ] -> Resolved t
       | ts ->
           Ambiguous
             (Printf.sprintf "path '%s' is ambiguous (%d distinct candidates)" (join_path segs)
                (List.length ts)))

(* ── The resolution pipeline ────────────────────────────────── *)

(* Accumulating state; all lists reversed during construction. *)
type st = {
  mutable scopes : scope IntMap.t;
  mutable def_kinds : def_kind DefMap.t;
  mutable fields : Ids.Field_id.t SMap.t DefMap.t;
  mutable variants : Ids.Variant_id.t SMap.t DefMap.t;
  mutable methods : Ids.Callable_id.t SMap.t DefMap.t;
  mutable callables : callable list;
  mutable expr_defs : (Ids.Module_id.t * int) list;
  mutable type_defs : (Ids.Module_id.t * int) list;
  mutable field_defs : (Ids.Module_id.t * int * int) list;
  mutable variant_defs : (Ids.Module_id.t * int * int) list;
  mutable call_candidates : (Ids.Module_id.t * int) list;
  mutable next_field : int;
  mutable next_variant : int;
  mutable next_callable : int;
}

let tables_of (st : st) : tables =
  {
    tb_scopes = st.scopes;
    tb_def_kinds = st.def_kinds;
    tb_fields = st.fields;
    tb_variants = st.variants;
    tb_methods = st.methods;
  }

(* Register a value definition (first-wins per module). *)
let register_value (st : st) (sc : scope) (m : Ids.Module_id.t) (idx : int) (name : string) : scope =
  let def : Ids.def_id = { Ids.module_id = m; index = idx } in
  if SMap.mem name sc.sc_own_values then sc
  else begin
    st.expr_defs <- (m, idx) :: st.expr_defs;
    st.def_kinds <- DefMap.add def DValue st.def_kinds;
    { sc with sc_own_values = SMap.add name def sc.sc_own_values }
  end

(* Register a type definition (first-wins per module). *)
let register_type (st : st) (sc : scope) (m : Ids.Module_id.t) (idx : int) (name : string) : scope =
  let def : Ids.def_id = { Ids.module_id = m; index = idx } in
  if SMap.mem name sc.sc_own_types then sc
  else begin
    st.type_defs <- (m, idx) :: st.type_defs;
    st.def_kinds <- DefMap.add def DType st.def_kinds;
    { sc with sc_own_types = SMap.add name def sc.sc_own_types }
  end

let register_free (st : st) (m : Ids.Module_id.t) (idx : int) : unit =
  ignore (Ids.Callable_id.make st.next_callable);
  st.next_callable <- st.next_callable + 1;
  st.callables <- CFree (m, idx) :: st.callables;
  st.call_candidates <- (m, idx) :: st.call_candidates

let register_fields (st : st) (def : Ids.def_id) (fields : Ast.field_decl list) : unit =
  List.iteri
    (fun j f ->
      let fid = Ids.Field_id.make st.next_field in
      st.next_field <- st.next_field + 1;
      st.field_defs <- (def.Ids.module_id, def.Ids.index, j) :: st.field_defs;
      let cur = match DefMap.find_opt def st.fields with Some t -> t | None -> SMap.empty in
      st.fields <- DefMap.add def (SMap.add f.Ast.f_name fid cur) st.fields)
    fields

let register_variants (st : st) (def : Ids.def_id) (variants : Ast.variant_decl list) : unit =
  List.iteri
    (fun j v ->
      let vid = Ids.Variant_id.make st.next_variant in
      st.next_variant <- st.next_variant + 1;
      st.variant_defs <- (def.Ids.module_id, def.Ids.index, j) :: st.variant_defs;
      let cur = match DefMap.find_opt def st.variants with Some t -> t | None -> SMap.empty in
      st.variants <- DefMap.add def (SMap.add v.Ast.v_name vid cur) st.variants)
    variants

(* Register a method under its target type's DefId (first-wins per
   (def, method name); the CallableId counter advances for every method). *)
let register_method (st : st) (def : Ids.def_id) (m : Ids.Module_id.t) (idx : int) (midx : int)
    (mname : string) : unit =
  let cid = Ids.Callable_id.make st.next_callable in
  st.next_callable <- st.next_callable + 1;
  st.callables <- CMethod (m, idx, midx) :: st.callables;
  let cur = match DefMap.find_opt def st.methods with Some t -> t | None -> SMap.empty in
  st.methods <- DefMap.add def (SMap.add mname cid cur) st.methods

(* Phase 1 — symbol-table construction: register every top-level item of
   the node's module, build the scope, bind inline submodules. *)
let phase1_node (st : st) (graph : Module_graph.t) (n : Module_graph.module_node) : unit =
  let m = n.Module_graph.node_id in
  let items = n.Module_graph.node_items in
  let ext_idx = ref (List.length items) in
  let sc =
    List.fold_left
      (fun sc (i, it) ->
        match it.Ast.kind with
        | Ast.Function d ->
            register_free st m i;
            register_value st sc m i d.Ast.fn_sig.sig_name
        | Ast.TestDecl d ->
            register_free st m i;
            register_value st sc m i d.Ast.test_name
        | Ast.StructDef d ->
            let sc = register_type st sc m i d.Ast.s_name in
            let def : Ids.def_id = { Ids.module_id = m; index = i } in
            register_fields st def d.Ast.s_fields;
            List.iteri
              (fun j fn -> register_method st def m i j fn.Ast.fn_sig.sig_name)
              d.Ast.s_methods;
            sc
        | Ast.EnumDef d ->
            let sc = register_type st sc m i d.Ast.e_name in
            let def : Ids.def_id = { Ids.module_id = m; index = i } in
            register_variants st def d.Ast.e_variants;
            sc
        | Ast.TraitDef d ->
            let sc = register_type st sc m i d.Ast.t_name in
            let def : Ids.def_id = { Ids.module_id = m; index = i } in
            List.iteri
              (fun j fn -> register_method st def m i j fn.Ast.fn_sig.sig_name)
              d.Ast.t_methods;
            sc
        | Ast.ImplBlock _ -> sc
        | Ast.ConstDecl d -> register_value st sc m i d.Ast.c_name
        | Ast.StaticDecl d -> register_value st sc m i d.Ast.st_name
        | Ast.TypeAlias d -> register_type st sc m i d.Ast.ta_name
        | Ast.UseDecl _ -> sc
        | Ast.ModuleDef d -> (
            match module_name_segments d.Ast.m_name with
            | head :: _ -> (
                match
                  Module_graph.find_module_by_path graph
                    (n.Module_graph.node_path @ module_name_segments d.Ast.m_name)
                with
                | Some cnode ->
                    { sc with sc_submodules = SMap.add head cnode.Module_graph.node_id sc.sc_submodules }
                | None -> sc)
            | [] -> sc)
        | Ast.ExternBlock d ->
            List.fold_left
              (fun sc ex ->
                let idx = !ext_idx in
                incr ext_idx;
                match ex.Ast.kind with
                | Ast.Function f ->
                    register_free st m idx;
                    register_value st sc m idx f.Ast.fn_sig.sig_name
                | Ast.StaticDecl s -> register_value st sc m idx s.Ast.st_name
                | _ -> sc)
              sc d.Ast.ex_items
        | Ast.CapabilityDecl _ | Ast.EffectDecl _ | Ast.RationaleBlock _ | Ast.MacroDecl _
        | Ast.EditionDecl _ ->
            sc)
      (empty_scope ())
      (List.mapi (fun i it -> (i, it)) items)
  in
  st.scopes <- IntMap.add (Ids.Module_id.to_int m) sc st.scopes

(* Add an import binding (append, so duplicates never overwrite). *)
let add_import_binding (sc : scope) (b : import_binding) : scope =
  let cur = match SMap.find_opt b.ib_name sc.sc_imports with Some l -> l | None -> [] in
  { sc with sc_imports = SMap.add b.ib_name (b :: cur) sc.sc_imports }

(* Bind one imported name to a resolved target; E2001/E2002 on failure. *)
let bind_import (graph : Module_graph.t) (diags : Diagnostic.bag)
    (tables : tables) (m : Ids.Module_id.t) (sc : scope) (name : string) (segs : string list)
    (span : Span.span) : scope =
  match resolve_path_target graph tables m segs with
  | Resolved (PTModule mid) ->
      add_import_binding sc { ib_name = name; ib_target = ITModule mid; ib_ns = None; ib_span = span }
  | Resolved (PTItem def) ->
      add_import_binding sc
        { ib_name = name; ib_target = ITItem def; ib_ns = def_kind_of tables def; ib_span = span }
  | Resolved (PTVariant _) ->
      Diagnostic.error diags "E2001"
        (Printf.sprintf "unresolved import '%s' (enum variants are not importable items)"
           (join_path segs))
        span;
      sc
  | Ambiguous msg ->
      Diagnostic.error diags "E2002" msg span;
      sc
  | Unknown ->
      Diagnostic.error diags "E2001" (Printf.sprintf "unresolved import '%s'" (join_path segs)) span;
      sc

(* Item or child module of `mid` named `name`. *)
let item_or_child (tables : tables) (mid : Ids.Module_id.t) (name : string) : import_target option =
  match scope_of tables mid with
  | None -> None
  | Some sc -> (
      match SMap.find_opt name sc.sc_own_values with
      | Some d -> Some (ITItem d)
      | None -> (
          match SMap.find_opt name sc.sc_own_types with
          | Some d -> Some (ITItem d)
          | None -> (
              match SMap.find_opt name sc.sc_submodules with
              | Some cid -> Some (ITModule cid)
              | None -> None)))

(* Phase 2 — import resolution: resolve every use declaration in the
   module, filling the scope's import bindings and glob sources in
   source order. *)
let phase2_node (st : st) (graph : Module_graph.t) (diags : Diagnostic.bag)
    (n : Module_graph.module_node) : unit =
  let m = n.Module_graph.node_id in
  let sc = match IntMap.find_opt (Ids.Module_id.to_int m) st.scopes with Some sc -> sc | None -> empty_scope () in
  let tables = tables_of st in
  let sc =
    List.fold_left
      (fun sc (_, it) ->
        match it.Ast.kind with
        | Ast.UseDecl d -> (
            let span = d.Ast.u_span in
            match d.Ast.u_path with
            | Ast.UseSimple segs -> bind_import graph diags tables m sc (last_seg segs) segs span
            | Ast.UseAliased (segs, alias) -> bind_import graph diags tables m sc alias segs span
            | Ast.UseGroup (segs, uitems) -> (
                match resolve_path_target graph tables m segs with
                | Resolved (PTModule mid) ->
                    List.fold_left
                      (fun sc ui ->
                        let name =
                          match ui.Ast.ui_alias with Some a -> a | None -> ui.Ast.ui_name
                        in
                        match item_or_child tables mid ui.Ast.ui_name with
                        | Some (ITItem def) ->
                            add_import_binding sc
                              { ib_name = name;
                                ib_target = ITItem def;
                                ib_ns = def_kind_of tables def;
                                ib_span = ui.Ast.ui_span }
                        | Some (ITModule cid) ->
                            add_import_binding sc
                              { ib_name = name; ib_target = ITModule cid; ib_ns = None; ib_span = ui.Ast.ui_span }
                        | None ->
                            Diagnostic.error diags "E2001"
                              (Printf.sprintf "unresolved import '%s'" (join_path (segs @ [ ui.Ast.ui_name ])))
                              ui.Ast.ui_span;
                            sc)
                      sc uitems
                | Resolved _ ->
                    Diagnostic.error diags "E2001"
                      (Printf.sprintf "import group prefix '%s' is not a module" (join_path segs))
                      span;
                    sc
                | Ambiguous msg ->
                    Diagnostic.error diags "E2002" msg span;
                    sc
                | Unknown ->
                    Diagnostic.error diags "E2001"
                      (Printf.sprintf "unresolved import '%s'" (join_path segs))
                      span;
                    sc)
            | Ast.UseGlob segs -> (
                match resolve_path_target graph tables m segs with
                | Resolved (PTModule mid) ->
                    { sc with sc_globs = { gi_module = mid; gi_span = span } :: sc.sc_globs }
                | Resolved _ ->
                    Diagnostic.error diags "E2001"
                      (Printf.sprintf "glob prefix '%s' is not a module" (join_path segs))
                      span;
                    sc
                | Ambiguous msg ->
                    Diagnostic.error diags "E2002" msg span;
                    sc
                | Unknown ->
                    Diagnostic.error diags "E2001"
                      (Printf.sprintf "unresolved import '%s'" (join_path segs))
                      span;
                    sc))
        | _ -> sc)
      sc
      (List.mapi (fun i it -> (i, it)) n.Module_graph.node_items)
  in
  st.scopes <- IntMap.add (Ids.Module_id.to_int m) sc st.scopes

(* Phase 3 — impl and supertrait resolution: impl target types and trait
   names, and trait supertraits, are mandatory names; register impl
   methods under the resolved target type's DefId. *)
let phase3_node (st : st) (diags : Diagnostic.bag) (n : Module_graph.module_node) : unit =
  let m = n.Module_graph.node_id in
  let tables = tables_of st in
  List.iter
    (fun (i, it) ->
      match it.Ast.kind with
      | Ast.ImplBlock d ->
          let target = d.Ast.i_target_type in
          let def_opt =
            if target = "" then None
            else
              match bare_name_resolve tables m Type target with
              | Resolved def -> Some def
              | Unknown ->
                  Diagnostic.error diags "E2003"
                    (Printf.sprintf "unresolved impl target type '%s'" target)
                    d.Ast.i_span;
                  None
              | Ambiguous msg ->
                  Diagnostic.error diags "E2002" msg d.Ast.i_span;
                  None
          in
          (match d.Ast.i_trait_name with
           | Some tname -> (
               match bare_name_resolve tables m Type tname with
               | Resolved _ -> ()
               | Unknown ->
                   Diagnostic.error diags "E2003"
                     (Printf.sprintf "unresolved trait '%s' in impl" tname)
                     d.Ast.i_span
               | Ambiguous msg -> Diagnostic.error diags "E2002" msg d.Ast.i_span)
           | None -> ());
          List.iteri
            (fun j fn ->
              let cid = Ids.Callable_id.make st.next_callable in
              st.next_callable <- st.next_callable + 1;
              st.callables <- CMethod (m, i, j) :: st.callables;
              match def_opt with
              | Some def ->
                  let cur =
                    match DefMap.find_opt def st.methods with Some t -> t | None -> SMap.empty
                  in
                  st.methods <-
                    DefMap.add def (SMap.add fn.Ast.fn_sig.sig_name cid cur) st.methods
              | None -> ())
            d.Ast.i_methods
      | Ast.TraitDef d ->
          List.iter
            (fun stname ->
              match bare_name_resolve tables m Type stname with
              | Resolved _ -> ()
              | Unknown ->
                  Diagnostic.error diags "E2003"
                    (Printf.sprintf "unresolved supertrait '%s'" stname)
                    d.Ast.t_span
              | Ambiguous msg -> Diagnostic.error diags "E2002" msg d.Ast.t_span)
            d.Ast.t_supertraits
      | _ -> ())
    (List.mapi (fun i it -> (i, it)) n.Module_graph.node_items)

(* Visit every module in manifest order; file modules then their inline
   subtrees in pre-order. *)
let iter_nodes (manifest : Bootstrap_manifest.t) (graph : Module_graph.t)
    (f : Module_graph.module_node -> unit) : unit =
  List.iter
    (fun entry ->
      match Module_graph.find_module_by_path graph entry.Bootstrap_manifest.path with
      | None -> ()
      | Some file_node ->
          let rec visit (n : Module_graph.module_node) =
            f n;
            List.iter
              (fun cid ->
                match Module_graph.find_module_by_id graph cid with
                | Some c -> visit c
                | None -> ())
              (Module_graph.children_of graph n.Module_graph.node_id)
          in
          visit file_node)
    (Bootstrap_manifest.entries manifest)

let resolve (manifest : Bootstrap_manifest.t) (graph : Module_graph.t)
    (diags : Diagnostic.bag) : resolved_program =
  let st : st =
    {
      scopes = IntMap.empty;
      def_kinds = DefMap.empty;
      fields = DefMap.empty;
      variants = DefMap.empty;
      methods = DefMap.empty;
      callables = [];
      expr_defs = [];
      type_defs = [];
      field_defs = [];
      variant_defs = [];
      call_candidates = [];
      next_field = 0;
      next_variant = 0;
      next_callable = 0;
    }
  in
  iter_nodes manifest graph (phase1_node st graph);
  iter_nodes manifest graph (phase2_node st graph diags);
  iter_nodes manifest graph (phase3_node st diags);
  let tables = tables_of st in
  {
    graph;
    expr_defs = List.rev st.expr_defs;
    type_defs = List.rev st.type_defs;
    field_defs = List.rev st.field_defs;
    variant_defs = List.rev st.variant_defs;
    call_candidates = List.rev st.call_candidates;
    state = { st_tables = tables; st_callables = List.rev st.callables };
  }

(* ── Public lookups ─────────────────────────────────────────── *)

let resolve_value_name (rp : resolved_program) (m : Ids.Module_id.t) (name : string) :
    Ids.def_id resolution =
  bare_name_resolve rp.state.st_tables m Value name

let resolve_type_name (rp : resolved_program) (m : Ids.Module_id.t) (name : string) :
    Ids.def_id resolution =
  bare_name_resolve rp.state.st_tables m Type name

let resolve_field (rp : resolved_program) (m : Ids.Module_id.t) (struct_name : string)
    (field_name : string) : Ids.Field_id.t resolution =
  match bare_name_resolve rp.state.st_tables m Type struct_name with
  | Unknown -> Unknown
  | Ambiguous a -> Ambiguous a
  | Resolved def -> (
      match DefMap.find_opt def rp.state.st_tables.tb_fields with
      | None -> Unknown
      | Some fs -> (
          match SMap.find_opt field_name fs with
          | Some fid -> Resolved fid
          | None -> Unknown))

let resolve_variant (rp : resolved_program) (m : Ids.Module_id.t) (enum_name : string)
    (variant_name : string) : Ids.Variant_id.t resolution =
  match bare_name_resolve rp.state.st_tables m Type enum_name with
  | Unknown -> Unknown
  | Ambiguous a -> Ambiguous a
  | Resolved def -> (
      match DefMap.find_opt def rp.state.st_tables.tb_variants with
      | None -> Unknown
      | Some vs -> (
          match SMap.find_opt variant_name vs with
          | Some vid -> Resolved vid
          | None -> Unknown))

let resolve_method (rp : resolved_program) (m : Ids.Module_id.t) (target_type : string)
    (method_name : string) : Ids.Callable_id.t resolution =
  match bare_name_resolve rp.state.st_tables m Type target_type with
  | Unknown -> Unknown
  | Ambiguous a -> Ambiguous a
  | Resolved def -> (
      match DefMap.find_opt def rp.state.st_tables.tb_methods with
      | None -> Unknown
      | Some ms -> (
          match SMap.find_opt method_name ms with
          | Some cid -> Resolved cid
          | None -> Unknown))

let resolve_qualified (rp : resolved_program) (m : Ids.Module_id.t) (segs : string list) :
    path_target resolution =
  resolve_path_target rp.graph rp.state.st_tables m segs
