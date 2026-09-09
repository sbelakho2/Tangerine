(* resource_check.ml — Ownership/cleanup planning (audit §30, §65).

   A per-local state lattice over the function's control flow, producing a
   cleanup plan and proving: exactly one terminal drop per owned lineage,
   no double drops, no use-after-consume, no live leaked resource.

   ── projected-place ownership (native resource_check.tg parity, the
   chain-aware lattice — P0-5 Stage0 half): the per-place chain state
   mirrors the native checker's ResFrame.place_moves row model over the
   Seed MIR's SEMANTIC place projections.  A chain is the projection list
   of a place (Field ids, Downcast variant ids, ConstantIndex positions —
   NEVER a dynamic Index or Deref, which are the whole-value boundary).
   THE STATIC-PLACE RULE (the native parity split): a place is exact
   exactly when every projection is a struct field, an enum-payload
   position or a CONSTANT index over a tuple / fixed-array base — the
   lattice tracks those positions individually (an in-range ConstantIndex
   over a Fixed_array is a chain key); a runtime index (Vec[i] / Map[k])
   or a deref is the OWNERSHIP BOUNDARY — the container's elements are
   the ownership unit, no per-slot state exists there, and a raw sink
   extraction through the boundary is rejected by the element-state rule,
   whose diagnostic names the sanctioned ownership-safe container
   operations (Vec pop / remove(index), Map remove(key), the fixed
   containers' pop / pop_front, `with c[i] as inout` bindings).  No
   runtime ownership metadata ever backs the lattice: per-slot state is a
   compile-time artifact (chain rows + masked drop glue), never a stored
   tag or bitmap beside the data.
   The lattice records ONLY the deviations: an absent chain is Live; a
   chain recorded Consumed was moved out (the root stays Live and its
   cleanup excludes the dead chain); a chain recorded Maybe_live was
   consumed on one control-flow path only (a join).  The effective state
   of a chain consults its prefixes in order — a consumed prefix (or a
   Consumed/Uninitialized/Maybe_live root) makes everything under it dead
   or indeterminate (`take(p.a)` then `take(p.a.b)` is a use of consumed
   storage).  Whole-value operations over a partially-moved root are
   rejected (the dead chains' storage cannot be masked); consuming moves
   through dynamic Index/Deref projections are rejected by the
   element-state rule; assignment over a live owning chain is the
   EXACT-PLACE replacement (the audit's canonical model): the old value
   of the TARGET PLACE itself is destroyed — masked to its own consumed
   extensions — and the sibling chains (live or consumed) are NEVER
   touched by a projected replacement.  A chain whose own row is Consumed
   re-lives without a drop; a chain under a CONSUMED proper prefix (the
   containing value was moved out) rejects the assignment (a write
   through the moved-out value); the same-root RHS guard rejects only an
   RHS operand whose storage OVERLAPS the target chain (the drop would
   destroy the operand's source before it materializes) — a disjoint
   sibling chain RHS is accepted.  The whole-root store is the one
   remaining whole-value masked-drop form, applying only to the
   whole-root replacement itself. *)

module IntMap = Map.Make (Int)
module IntSet = Set.Make (Int)

type resource_state = Uninitialized | Live | Consumed | Maybe_live

let state_to_string = function
  | Uninitialized -> "uninitialized"
  | Live -> "live"
  | Consumed -> "consumed"
  | Maybe_live -> "maybe_live"

type action = Drop | Deinit

type cleanup_action = {
  local : int;
  action : action;
}

type plan = {
  actions : cleanup_action list;
  final_states : (int * resource_state) list;
}

(* ── THE ONE type-property authority (audit item 3) ────────────────
   This pass never re-derives a type property recursion of its own:
   every Copy/owned decision routes through the ONE engine
   (Type_properties, P1-25 / P0-2 — the same authority the typechecker
   mirrors pre-MIR, mir_verify.is_copy, mir_lower's copyability, the
   Drop_plan construction and the VM consume).  The cfg entries below
   receive the engine's nominal resolver for THIS program (the def
   table's def_repr shapes with the compilation's LangItems overlay —
   the mir_verify.nominal_resolver / Drop_plan.engine_resolve shape)
   and the engine answers with a per-program cache (one cache per def
   table, exactly like the verifier's per-ctx copy_cache).  A Named
   type whose def cannot be resolved answers conservatively OWNED (the
   engine's Unknown) — the same conservative non-Copy rule the
   verifier and drop planner apply to an unresolvable nominal. *)

type env = {
  owned : int list;             (* locals that own a needs_drop value *)
  mutable states : (int * resource_state) list;
  mutable actions : cleanup_action list;
  mutable errors : string list;
}

let create_env owned = { owned; states = List.map (fun l -> (l, Uninitialized)) owned; actions = []; errors = [] }

let state_of (env : env) (local : int) : resource_state =
  match List.assoc_opt local env.states with
  | Some s -> s
  | None -> Uninitialized

let set_state (env : env) (local : int) (s : resource_state) =
  env.states <- List.map (fun (l, st) -> if l = local then (l, s) else (l, st)) env.states

let is_owned (env : env) (local : int) = List.mem local env.owned

(* Reads require Live (or Maybe_live). *)
let check_read (env : env) (local : int) (ctx : string) =
  if is_owned env local then
    match state_of env local with
    | Uninitialized -> env.errors <- Printf.sprintf "%s: read of uninitialized owned local _%d" ctx local :: env.errors
    | Consumed -> env.errors <- Printf.sprintf "%s: use-after-consume of owned local _%d" ctx local :: env.errors
    | Live | Maybe_live -> ()

(* Moves require Live; move of a Copy value is a copy. *)
let check_move (env : env) (local : int) (is_copy : bool) (ctx : string) =
  if is_owned env local then begin
    match state_of env local with
    | Uninitialized -> env.errors <- Printf.sprintf "%s: move of uninitialized owned local _%d" ctx local :: env.errors
    | Consumed -> env.errors <- Printf.sprintf "%s: double-move of owned local _%d" ctx local :: env.errors
    | Live -> if not is_copy then set_state env local Consumed
    | Maybe_live -> set_state env local Maybe_live
  end

let check_initialize (env : env) (local : int) (ctx : string) =
  if is_owned env local then begin
    match state_of env local with
    | Live -> env.errors <- Printf.sprintf "%s: re-initialization of live owned local _%d" ctx local :: env.errors
    | _ -> set_state env local Live
  end

(* Drop: Live -> Dropped (removed from tracking); double-drop is an error. *)
let check_drop (env : env) (local : int) (ctx : string) =
  if is_owned env local then begin
    match state_of env local with
    | Uninitialized -> env.errors <- Printf.sprintf "%s: drop of uninitialized owned local _%d" ctx local :: env.errors
    | Consumed -> env.errors <- Printf.sprintf "%s: double-drop of owned local _%d" ctx local :: env.errors
    | Live | Maybe_live ->
        set_state env local Consumed;
        env.actions <- { local; action = Drop } :: env.actions
  end

(* Branch merge: join two states.

   The lattice row Consumed + Consumed -> Consumed is deliberate: a value
   consumed on EVERY predecessor is still consumed at the join.  Merging
   it to Maybe_live would make finalize (below) believe a drop is still
   due and schedule one, producing a double-drop plan. *)
let join (a : resource_state) (b : resource_state) : resource_state =
  match a, b with
  | Uninitialized, x | x, Uninitialized -> (
      match x with Uninitialized -> Uninitialized | _ -> Maybe_live)
  | Live, Live -> Live
  | Consumed, Consumed -> Consumed
  | Live, Consumed | Consumed, Live -> Maybe_live
  | Maybe_live, _ | _, Maybe_live -> Maybe_live

(* Merge the state of `from` into the state snapshot taken at a join point. *)
let merge_state (env : env) (snapshot : (int * resource_state) list) =
  env.states <-
    List.map
      (fun (l, s) ->
        match List.assoc_opt l snapshot with
        | Some s0 -> (l, join s0 s)
        | None -> (l, s))
      env.states

(* Finalize a function: drop every still-Live owned local; report leaks.

   DEFENSIVE INVARIANT: finalize must NEVER schedule a Drop for a
   Consumed local — a consumed value must not be dropped again.  This is
   exactly why the merge row is Consumed + Consumed -> Consumed: after
   the join, a value consumed on both branches stays Consumed, so the
   fixed row cannot produce a double-drop plan (finalize sees Consumed
   and schedules nothing).

   Maybe_live is likewise NOT treated as Live here: planning an
   unconditional final drop for a maybe-live value would double-drop it
   on the branch where it was already consumed.  A Maybe_live local is
   left in final_states as a conditional-cleanup signal for the caller;
   no silent drop is planned. *)
let finalize (env : env) (ctx : string) : plan =
  List.iter
    (fun l ->
      match state_of env l with
      | Live ->
          env.actions <- { local = l; action = Drop } :: env.actions;
          set_state env l Consumed
      | Uninitialized ->
          env.errors <- Printf.sprintf "%s: owned local _%d never initialized" ctx l :: env.errors
      | Consumed | Maybe_live -> ())
    env.owned;
  { actions = List.rev env.actions; final_states = env.states }

(* ── the CFG resource dataflow (re-audit P0-E): the path-sensitive
   lattice over the MIR control flow — the merge points JOIN their
   predecessors' out-states (the meet: a local live on one path and
   consumed on another is Maybe_live, so the downstream read/use is a
   conditional-use error, not silently accepted), the loop backedges
   iterate to the fixpoint, and reads/moves are checked per path.  This
   is the authoritative ownership/cleanup stage the audit requires —
   the linear access-sanity replay remains an additional diagnostic. *)

let meet (a : resource_state) (b : resource_state) : resource_state =
  match a, b with
  | Uninitialized, x | x, Uninitialized -> x
  | Live, Consumed | Consumed, Live -> Maybe_live
  | Maybe_live, _ | _, Maybe_live -> Maybe_live
  | Live, Live -> Live
  | Consumed, Consumed -> Consumed

let states_join (a : (int * resource_state) list) (b : (int * resource_state) list) :
    (int * resource_state) list =
  let bm = List.fold_left (fun m (l, s) -> IntMap.add l s m) IntMap.empty b in
  let rec go = function
    | [] -> IntMap.bindings bm
    | (l, s) :: rest -> (
        match IntMap.find_opt l bm with
        | None -> (l, s) :: go rest
        | Some s' -> (l, meet s s') :: go rest)
  in
  List.sort compare (go a)

(* ────────────────────────────────────────────────────────────────
   The projected-place chain lattice (native resource_check.tg's
   place_moves rows, ported over the Seed MIR's semantic projections).

   A chain row records a DEVIATION from the default Live: (root local,
   projection chain, Consumed | Maybe_live).  Absent = Live, so a store
   that re-lives a chain simply removes the row (the native frame's
   frame_place_clear + mark-Live commit is the pure clear here).  A row
   (l, C, st) makes every chain C' extending C dead or indeterminate via
   the prefix rule (chain_effective_state scans C' prefixes
   shortest-first).

   The Seed MIR place model already carries the semantic projection
   chains (Field ids, Downcast variant ids, ConstantIndex positions for
   tuple payloads and fixed arrays); the type walk below resolves the
   chain's value type through program.types so a chain is consumed only
   when the value is owning (a move of a Copy field is a read).
   ──────────────────────────────────────────────────────────────── *)

type chain_row = int * Seed_mir.projection list * resource_state

(* Render a chain for diagnostics (the Seed MIR pretty-printer's
   projection forms, without the root prefix). *)
let chain_to_string (ch : Seed_mir.projection list) : string =
  String.concat ""
    (List.map
       (function
         | Seed_mir.Deref -> "(*)"
         | Seed_mir.Field f -> Printf.sprintf ".field#%d" (Ids.Field_id.to_int f)
         | Seed_mir.Index li -> Printf.sprintf "[_%d]" li
         | Seed_mir.ConstantIndex i -> Printf.sprintf "[%d]" i
         | Seed_mir.Downcast v ->
             Printf.sprintf " as variant#%d" (Ids.Variant_id.to_int v))
       ch)

let chain_row_find (rows : chain_row list) (l : int) (ch : Seed_mir.projection list) :
    resource_state option =
  match List.find_opt (fun (l', ch', _) -> l' = l && ch' = ch) rows with
  | Some (_, _, st) -> Some st
  | None -> None

(* Does `ch` extend `base` (ch == base or ch shares base as a prefix)? *)
let chain_extends (ch : Seed_mir.projection list) (base : Seed_mir.projection list) : bool =
  let nb = List.length base in
  List.length ch >= nb
  &&
  let rec same k = k >= nb || (List.nth ch k = List.nth base k && same (k + 1)) in
  same 0

let chain_row_set (rows : chain_row list) (l : int) (ch : Seed_mir.projection list)
    (st : resource_state) : chain_row list =
  (l, ch, st) :: List.filter (fun (l', ch', _) -> not (l' = l && ch' = ch)) rows

(* Remove the chain and every extension of it (a store re-lives the
   target; the nested consumptions under it die with the
   re-initialization — the native frame_place_clear). *)
let chain_rows_clear_at (rows : chain_row list) (l : int) (ch : Seed_mir.projection list) :
    chain_row list =
  List.filter (fun (l', ch', _) -> not (l' = l && chain_extends ch' ch)) rows

let chain_rows_clear_root (rows : chain_row list) (l : int) : chain_row list =
  List.filter (fun (l', _, _) -> l' <> l) rows

(* Does the root carry ANY recorded chain (a partial move, definite or
   path-conditional)?  The whole-value operations (whole-root consume /
   read) consult this: a whole-value op over a partially-moved root
   cannot mask the dead chains. *)
let chain_root_has_moves (rows : chain_row list) (l : int) : bool =
  List.exists (fun (l', _, _) -> l' = l) rows

(* The effective state of a chain under a Live root: the chain's
   prefixes in order — the first recorded Consumed prefix makes the rest
   dead, the first recorded Maybe_live prefix makes the rest
   indeterminate.  Absent = Live.  (A Consumed/Uninitialized root makes
   every chain dead and a Maybe_live root makes every chain
   indeterminate — the callers fold that in through the root row.) *)
let chain_prefix_state (rows : chain_row list) (l : int)
    (ch : Seed_mir.projection list) : resource_state =
  let n = List.length ch in
  let take k = List.filteri (fun i _ -> i < k) ch in
  let rec scan k =
    if k > n then Live
    else (
      match chain_row_find rows l (take k) with
      | Some Consumed -> Consumed
      | Some Maybe_live -> Maybe_live
      | Some Live | Some Uninitialized | None -> scan (k + 1))
  in
  scan 1

(* The per-chain lattice join (the native merge_frames place_moves
   half): a chain recorded in some arms only joins to Maybe_live (absent
   = Live on the other paths — a field consumed on one path is live on
   the other, and the cleanup cannot be conditional); a chain recorded in
   every arm keeps its state when the arms agree, else Maybe_live. *)
let chain_rows_join (a : chain_row list) (b : chain_row list) : chain_row list =
  let from_a =
    List.fold_left
      (fun acc (l, ch, st) ->
        match chain_row_find b l ch with
        | Some stb when stb = st -> (l, ch, st) :: acc
        | Some _ | None -> (l, ch, Maybe_live) :: acc)
      [] a
  in
  let from_b_only =
    List.fold_left
      (fun acc (l, ch, _) ->
        if chain_row_find a l ch = None then (l, ch, Maybe_live) :: acc else acc)
      [] b
  in
  from_a @ from_b_only

(* ── place classification over the Seed MIR (the type walk) ─────────
   classify_place decides how a place rooted at an owned local behaves:

   - PWhole: no projections — the whole-value lattice (the root's own
     availability is the state authority);
   - PChain (chain, value type): every projection is a trackable static
     key (Field / Downcast / ConstantIndex over a tuple payload or an
     in-bounds fixed array) — the per-chain lattice applies, and the
     chain is tracked only when the resolved value type owns;
   - PBoundary: the place passes through a dynamic Index or a Deref (or
     an unresolvable projection) — the whole-value boundary: element /
     pointee state is not tracked (the container's elements are the
     ownership unit). *)

type place_kind =
  | PWhole
  | PChain of Seed_mir.projection list * Type_repr.t
  | PBoundary

let type_def_of (prog : Seed_mir.program) (tid : Ids.Type_id.t) : Seed_mir.type_def option =
  Array.find_opt (fun d -> Ids.Type_id.compare (Seed_mir.def_id d) tid = 0) prog.Seed_mir.types

let resolve_named (prog : Seed_mir.program) (tid : Ids.Type_id.t) : Type_repr.t option =
  match type_def_of prog tid with
  | Some d -> Some (Seed_mir.def_repr d)
  | None -> None

(* The semantic FieldId -> field type, resolved through the owner
   StructDef (the native identity rule: the projected FieldId's owner def
   must equal the projected base's def). *)
let struct_field_ty (prog : Seed_mir.program) (tid : Ids.Type_id.t) (fid : Ids.Field_id.t) :
    Type_repr.t option =
  match type_def_of prog tid with
  | Some (Seed_mir.StructDef { sd_fields; _ }) -> (
      match
        List.find_opt
          (fun f -> Ids.Field_id.compare f.Seed_mir.fd_id fid = 0)
          sd_fields
      with
      | Some f -> Some f.Seed_mir.fd_ty
      | None -> None)
  | _ -> None

(* The semantic VariantId -> payload type, resolved through the owner
   EnumDef. *)
let enum_variant_payload (prog : Seed_mir.program) (tid : Ids.Type_id.t)
    (vid : Ids.Variant_id.t) : Type_repr.t option =
  match type_def_of prog tid with
  | Some (Seed_mir.EnumDef { ed_variants; _ }) -> (
      match
        List.find_opt
          (fun v -> Ids.Variant_id.compare v.Seed_mir.vd_id vid = 0)
          ed_variants
      with
      | Some v -> Some v.Seed_mir.vd_payload
      | None -> None)
  | _ -> None

let classify_place (prog : Seed_mir.program) (root_ty : Type_repr.t)
    (projs : Seed_mir.projection list) : place_kind =
  let rec go ty acc = function
    | [] -> PChain (List.rev acc, ty)
    | Seed_mir.Deref :: _ | Seed_mir.Index _ :: _ -> PBoundary
    | Seed_mir.Field fid :: rest -> (
        match ty with
        | Type_repr.Named (tid, _) -> (
            match struct_field_ty prog tid fid with
            | Some fty -> go fty (Seed_mir.Field fid :: acc) rest
            | None -> PBoundary)
        | _ -> PBoundary)
    | Seed_mir.Downcast vid :: rest -> (
        match ty with
        | Type_repr.Named (tid, _) -> (
            match enum_variant_payload prog tid vid with
            | Some pty -> go pty (Seed_mir.Downcast vid :: acc) rest
            | None -> PBoundary)
        | _ -> PBoundary)
    | Seed_mir.ConstantIndex i :: rest -> (
        match ty with
        | Type_repr.Tuple elems when i >= 0 && i < Array.length elems ->
            go elems.(i) (Seed_mir.ConstantIndex i :: acc) rest
        | Type_repr.Fixed_array (elem, n) when i >= 0 && i < n ->
            go elem (Seed_mir.ConstantIndex i :: acc) rest
        | _ -> PBoundary)
  in
  match projs with [] -> PWhole | _ -> go root_ty [] projs

(* Is the target CHAIN's own recorded row Consumed (the chain itself was
   moved out — its storage is dead and a store re-lives it without a
   drop)?  A Consumed PROPER PREFIX (a containing field moved out) is the
   write-through case — chain_prefix_state reports Consumed for both, and
   the assign-target validation consults this exact row to tell them
   apart. *)
let chain_self_consumed (rows : chain_row list) (l : int)
    (ch : Seed_mir.projection list) : bool =
  chain_row_find rows l ch = Some Consumed

(* Do two static chains overlap — equal, or one a prefix of the other?
   The exact-place drop of the target chain destroys an operand's storage
   when the operand chain equals the target, extends it (a sub-value
   inside the replaced value) or prefixes it (an ancestor value containing
   the replaced place). *)
let chains_overlap (a : Seed_mir.projection list) (b : Seed_mir.projection list) : bool =
  chain_extends a b || chain_extends b a

(* cfg_check_function — the path-sensitive lattice over one function.
   `cache` is the Type_properties instance cache and `resolve` the
   engine's nominal resolver, both bound to `prog`'s def table by the
   entry point below (one cache per program — never shared across two
   def tables).  Every owned-root and owning-chain decision in the
   dataflow answers through this ONE engine. *)
let cfg_check_function (cache : Type_properties.cache)
    (resolve : Type_properties.def_resolver) (prog : Seed_mir.program)
    (f : Seed_mir.function_) : string list =
  let nb = Array.length f.Seed_mir.blocks in
  if nb = 0 then [] else begin
    (* predecessors from the terminators *)
    let preds : int list array = Array.make nb [] in
    let add_pred p b =
      if b >= 0 && b < nb && not (List.mem p preds.(b)) then preds.(b) <- p :: preds.(b)
    in
    Array.iteri
      (fun i b ->
        match b.Seed_mir.terminator with
        | Seed_mir.Goto t | Seed_mir.Call (_, _, _, t, _) | Seed_mir.Drop (_, t, _)
        | Seed_mir.Deinit (_, t, _) | Seed_mir.Assert (_, _, _, t) ->
            add_pred i t
        | Seed_mir.SwitchInt (_, targets, d) ->
            List.iter (fun (_, t) -> add_pred i t) targets;
            add_pred i d
        | Seed_mir.Ret | Seed_mir.Unreachable | Seed_mir.Abort -> ())
      f.Seed_mir.blocks;
    (* the owned locals (the non-Copy roots) — the ONE authority answers
       each root's copyability through the threaded cache + resolver; a
       nominal whose def cannot be resolved answers conservatively owned
       (the engine's Unknown), exactly the verifier/drop-plan answer *)
    let owned =
      List.filter
        (fun l ->
          not
            (Type_properties.is_trivially_copyable ~cache ~resolve
               f.Seed_mir.locals.(l)))
        (List.init (Array.length f.Seed_mir.locals) (fun i -> i))
    in
    let owned_set = IntSet.of_list owned in
    let in_states : (int * resource_state) list array = Array.make nb [] in
    let out_states : (int * resource_state) list array = Array.make nb [] in
    let in_chains : chain_row list array = Array.make nb [] in
    let out_chains : chain_row list array = Array.make nb [] in
    (* the entry: the owned params are Live (the caller owns them); the
       return slot is Uninitialized.  Only the IN state is seeded — the
       out state starts empty so the entry block's FIRST processing is
       always a change and the worklist propagates to its successors
       (seeding the out state too made a statement-less entry silently
       skip every downstream block). *)
    let entry_init =
      List.map
        (fun l -> (l, if l = 0 then Uninitialized else Live))
        owned
    in
    in_states.(f.Seed_mir.entry) <- entry_init;
    in_chains.(f.Seed_mir.entry) <- [];
    let work = Queue.create () in
    Queue.push f.Seed_mir.entry work;
    let in_work = Hashtbl.create 16 in
    Hashtbl.add in_work f.Seed_mir.entry ();
    let errors = ref [] in
    let err fmt = Printf.ksprintf (fun m -> errors := m :: !errors) fmt in
    let state_of states l = List.assoc_opt l states |> Option.value ~default:Uninitialized in
    let set_state states l s =
      (l, s) :: List.filter (fun (l', _) -> l' <> l) states
    in

    (* the root local of a place, when owned *)
    let root_local (p : Seed_mir.place) : int option =
      match p.Seed_mir.root with
      | Seed_mir.Local l when IntSet.mem l owned_set -> Some l
      | _ -> None
    in
    let operand_place (op : Seed_mir.operand) : Seed_mir.place option =
      match op with
      | Seed_mir.Copy p | Seed_mir.Read p | Seed_mir.Move p | Seed_mir.Consume p -> Some p
      | Seed_mir.Constant _ -> None
    in
    let chain_of_place (l : int) (p : Seed_mir.place) : place_kind =
      classify_place prog f.Seed_mir.locals.(l) p.Seed_mir.projections
    in
    (* a chain's value type owns when the authority says it is not
       trivially copyable — the same answer (def-resolved, LangItems
       direct properties, conservative Unknown) the verifier and drop
       planner give the identical concrete type *)
    let chain_owning (cty : Type_repr.t) : bool =
      not (Type_properties.is_trivially_copyable ~cache ~resolve cty)
    in

    (* the rvalue operand list (the existing walk sites) *)
    let rv_operands (rv : Seed_mir.rvalue) : Seed_mir.operand list =
      match rv with
      | Seed_mir.Use op -> [ op ]
      | Seed_mir.Discriminant p -> [ Seed_mir.Copy p ]
      | Seed_mir.Cast (op, _) -> [ op ]
      | Seed_mir.BinaryOp (_, a, b) -> [ a; b ]
      | Seed_mir.UnaryOp (_, a) -> [ a ]
      | Seed_mir.Ref p | Seed_mir.RefMut p -> [ Seed_mir.Copy p ]
      | Seed_mir.Aggregate (_, ops) -> ops
      | Seed_mir.Len p -> [ Seed_mir.Copy p ]
    in
    (* Does any RHS operand place rooted at local l read or move storage
       that the exact-place drop of the target chain `tgt` destroys?  The
       exact drop destroys the target chain's own value (masked to its
       already-consumed extensions) BEFORE the RHS materializes; an
       operand whose static chain equals the target, extends it (a
       sub-value of the replaced value) or prefixes it (an ancestor value
       containing the replaced place) is destroyed before its source is
       read or moved — the same-root overlap guard.  A disjoint chain (a
       sibling) is untouched by the drop — accepted.  A whole-value
       operand of the same root and a boundary (indexed / deref) operand
       of the same root are unclassifiable — conservative overlap. *)
    let rhs_overlaps (rv : Seed_mir.rvalue) (l : int) (tgt : Seed_mir.projection list) :
        bool =
      List.exists
        (fun op ->
          match operand_place op with
          | None -> false
          | Some p -> (
              match root_local p with
              | Some l' when l' = l -> (
                  match chain_of_place l' p with
                  | PWhole -> true
                  | PBoundary -> true
                  | PChain (op_ch, _) -> chains_overlap op_ch tgt)
              | _ -> false))
        (rv_operands rv)
    in
    (* the root-level availability errors (the existing texts — a read /
       move of a Consumed/Uninitialized owned root). *)
    let check_root_available states l =
      match state_of states l with
      | Uninitialized -> err "_%d: read of uninitialized owned local" l
      | Consumed -> err "_%d: use-after-consume" l
      | Live | Maybe_live -> ()
    in

    (* a READ of a place (pure — never mutates state).  A whole-value
       read of a partially-moved root is rejected (the dead chains'
       storage cannot be copied as a whole); a chain read consults the
       chain's effective state (a consumed chain — or a dead prefix — is
       a use-after-move); a boundary (indexed/deref) read is a plain read
       of the root. *)
    let read_place states rows (l : int) (p : Seed_mir.place) : unit =
      match chain_of_place l p with
      | PWhole ->
          if chain_root_has_moves rows l then
            err "_%d: cannot use owned local as a whole: fields of the resource were moved out" l
          else check_root_available states l
      | PChain (ch, _) -> (
          match state_of states l with
          | Uninitialized -> err "_%d: read of uninitialized owned local" l
          | Consumed -> err "_%d: use-after-consume" l
          | Maybe_live -> err "_%d: owned local may be consumed on one path" l
          | Live -> (
              match chain_prefix_state rows l ch with
              | Consumed ->
                  err "_%d: read of moved-out owned field %s" l (chain_to_string ch)
              | Maybe_live ->
                  err "_%d: owned field %s may be consumed on one path" l
                    (chain_to_string ch)
              | Live | Uninitialized -> ()))
      | PBoundary -> check_root_available states l
    in

    while not (Queue.is_empty work) do
      let bid = Queue.pop work in
      Hashtbl.remove in_work bid;
      let in_s =
        match preds.(bid) with
        | [] -> in_states.(bid)
        | ps -> List.fold_left (fun acc p -> states_join acc out_states.(p)) [] ps
      in
      let in_c =
        match preds.(bid) with
        | [] -> in_chains.(bid)
        | ps -> List.fold_left (fun acc p -> chain_rows_join acc out_chains.(p)) [] ps
      in
      in_states.(bid) <- in_s;
      in_chains.(bid) <- in_c;
      let st = ref in_s in
      let rows = ref in_c in

      (* ── the per-block op semantics (closures over the block state) ─
         a CONSUMING transfer (Move/Consume operand):
         - a whole-value consume of a partially-moved root is rejected
           without a commit; otherwise the root dies (Consumed), the
           rows die with it;
         - a chain consume commits the chain Consumed (the projected
           move — the native apply_projected_consume: the permission and
           effective-state errors first, the commit after);
         - a boundary (dynamic index / deref) consume is rejected by the
           element-state rule and the root becomes Maybe_live (the
           elements' state is indeterminate — the native whole-boundary
           commit). *)
      let consume_place (l : int) (p : Seed_mir.place) : unit =
        match chain_of_place l p with
        | PWhole ->
            if chain_root_has_moves !rows l then
              err "_%d: cannot consume owned local as a whole: fields of the resource were moved out" l
            else begin
              (match state_of !st l with
               | Uninitialized -> err "_%d: read of uninitialized owned local" l
               | Consumed -> err "_%d: use-after-consume" l
               | Live | Maybe_live -> ());
              (match state_of !st l with
               | Live ->
                   st := set_state !st l Consumed;
                   rows := chain_rows_clear_root !rows l
               | Uninitialized | Consumed | Maybe_live -> ())
            end
        | PChain (ch, cty) ->
            if not (chain_owning cty) then
              (* a consuming transfer of a Copy value is a copy — a read *)
              read_place !st !rows l p
            else begin
              (match state_of !st l with
               | Uninitialized -> err "_%d: read of uninitialized owned local" l
               | Consumed -> err "_%d: use-after-consume" l
               | Maybe_live ->
                   err "_%d: owned local may be consumed on one path" l
               | Live -> (
                   match chain_prefix_state !rows l ch with
                   | Consumed ->
                       err "_%d: double-move of owned field %s" l (chain_to_string ch)
                   | Maybe_live ->
                       err "_%d: owned field %s may be consumed on one path" l
                         (chain_to_string ch)
                   | Live | Uninitialized -> ()));
              (* the projected consume commits: the chain becomes
                 Consumed (its consumed extensions die with the
                 whole-chain move) *)
              rows := chain_row_set (chain_rows_clear_at !rows l ch) l ch Consumed
            end
        | PBoundary ->
            check_root_available !st l;
            err "_%d: cannot consume through a dynamic index or deref place: element-level state is not tracked (the container's elements are the ownership unit); extract through the ownership-safe container operations instead — Vec pop / remove(index), Map remove(key), the fixed containers' pop / pop_front, or a `with c[i] as inout` binding (a constant index over a fixed-array base is a static chain and is tracked exactly)" l;
            st := set_state !st l Maybe_live;
            rows := chain_rows_clear_root !rows l
      in

      (* step one operand *)
      let step_op (op : Seed_mir.operand) : unit =
        match operand_place op with
        | None -> ()
        | Some p -> (
            match root_local p with
            | None -> ()
            | Some l -> (
                match op with
                | Seed_mir.Copy _ | Seed_mir.Read _ -> read_place !st !rows l p
                | Seed_mir.Move _ | Seed_mir.Consume _ -> consume_place l p
                | Seed_mir.Constant _ -> ()))
      in

      List.iter
        (fun s ->
          match s with
          | Seed_mir.Assign (p, rv) -> (
              (* 1. the target validation against the PRE-assignment state
                 (never mutates; the drop decision reads the TRUE
                 pre-assignment state).  A non-owned destination is not
                 tracked, but the RHS is still walked.

                 ── the EXACT-PLACE replacement model (the canonical
                 replacement semantics — a projected assignment destroys
                 exactly the old value of the TARGET PLACE, never the
                 whole root and never the siblings): the target chain's
                 OWN row decides the dead-storage re-live form; a CONSUMED
                 PROPER PREFIX of the target chain (a containing field was
                 moved out) makes the assignment a write through the
                 moved-out value — rejected; a Live owning chain accepts
                 the exact replacement (the sibling chains — live or
                 consumed — are untouched and stay usable). *)
              let target =
                match root_local p with
                | None -> None
                | Some l -> (
                    match chain_of_place l p with
                    | PWhole -> Some (l, None)
                    | PBoundary -> Some (l, None)
                    | PChain (ch, cty) ->
                        let pre_rows = !rows in
                        let root_st = state_of !st l in
                        let owning = chain_owning cty in
                        (match root_st with
                         | Uninitialized ->
                             err "_%d: read of uninitialized owned local" l
                         | Consumed -> err "_%d: use-after-consume" l
                         | Maybe_live ->
                             err "_%d: assign into owned local that may be consumed on one path" l
                         | Live -> (
                             match chain_prefix_state pre_rows l ch with
                             | Consumed ->
                                 (* the chain's own row Consumed = dead
                                    field storage: the store re-lives the
                                    field without a drop (the
                                    re-assignment of a moved-out field).  A
                                    Consumed PROPER PREFIX = the target
                                    storage lies inside a moved-out value —
                                    the assignment would write through it
                                    — rejected. *)
                                 if chain_self_consumed pre_rows l ch then ()
                                 else
                                   err "_%d: cannot assign into owned field %s: the containing value was moved out (the assignment would write through the moved-out value)" l
                                     (chain_to_string ch)
                             | Maybe_live ->
                                 err "_%d: owned field %s may be consumed on one path" l
                                   (chain_to_string ch)
                             | Live | Uninitialized ->
                                 if owning then begin
                                   (* the old owning value's EXACT
                                      drop-before-store (any chain depth —
                                      there is no depth-1 whole-root form).
                                      The same-root RHS guard rejects an
                                      RHS operand whose storage OVERLAPS
                                      the target chain (the operand is the
                                      target chain itself, an extension of
                                      it, or an ancestor containing it —
                                      the exact drop destroys the
                                      operand's source before it
                                      materializes); a disjoint sibling
                                      chain RHS is accepted — the exact
                                      drop never touches the sibling. *)
                                   if rhs_overlaps rv l ch then
                                     err "_%d: cannot assign over an owning projected place: the value reads or moves out of the replaced value's own storage (the drop-before-store would destroy its source)" l
                                 end));
                        Some (l, Some ch))
              in
              (* 2. the RHS reads/moves *)
              List.iter step_op (rv_operands rv);
              (* 3. the store commits *)
              (match target with
               | None -> ()
               | Some (l, chain_info) -> (
                   match chain_info with
                   | None -> (
                       (* a whole-value store re-lives the root — or an
                          indexed store records nothing *)
                       match chain_of_place l p with
                       | PWhole ->
                           st := set_state !st l Live;
                           rows := chain_rows_clear_root !rows l
                       | PChain _ | PBoundary -> ())
                   | Some ch ->
                       (* the exact-place commit: the store re-lives the
                          target chain and its extensions (the old value's
                          drop destroyed exactly the chain's own state,
                          masked to its consumed extensions).  The sibling
                          chains were NEVER touched — each keeps its own
                          record (a live sibling stays live; a consumed
                          sibling stays dead). *)
                       rows := chain_rows_clear_at !rows l ch)))
          | Seed_mir.StorageLive _ | Seed_mir.StorageDead _ | Seed_mir.SetDiscriminant _
          | Seed_mir.Nop -> ())
        f.Seed_mir.blocks.(bid).Seed_mir.statements;
      (* the terminator: Call args / dest, Drop/Deinit, SwitchInt/Assert
         reads *)
      (match f.Seed_mir.blocks.(bid).Seed_mir.terminator with
       | Seed_mir.Call (dest, _callee, args, _, _) ->
           Array.iter
             (fun a ->
               match a.Seed_mir.value with
               | Seed_mir.Constant _ -> ()
               | op -> step_op op)
             args;
           (match dest.Seed_mir.root with
            | Seed_mir.Local l when IntSet.mem l owned_set -> (
                match chain_of_place l dest with
                | PWhole ->
                    (* a call result store: dead storage re-lives; a
                       replacement commits Live *)
                    st := set_state !st l Live;
                    rows := chain_rows_clear_root !rows l
                | PChain (ch, _) ->
                    (* a call into a projected destination: the CHAIN's
                       state decides — the store re-lives the chain (the
                       old value's drop authority is the caller's
                       assign-drop chain).  The exact-place target rule
                       mirrors the Assign arm: dead storage (the chain's
                       own row Consumed) re-lives; a CONSUMED proper
                       prefix (a containing value moved out) rejects the
                       write-through. *)
                    (match state_of !st l with
                     | Uninitialized -> err "_%d: read of uninitialized owned local" l
                     | Consumed -> err "_%d: use-after-consume" l
                     | Maybe_live ->
                         err "_%d: assign into owned local that may be consumed on one path" l
                     | Live -> (
                         match chain_prefix_state !rows l ch with
                         | Maybe_live ->
                             err "_%d: owned field %s may be consumed on one path" l
                               (chain_to_string ch)
                         | Consumed ->
                             if not (chain_self_consumed !rows l ch) then
                               err "_%d: cannot assign into owned field %s: the containing value was moved out (the assignment would write through the moved-out value)" l
                                 (chain_to_string ch)
                         | Live | Uninitialized -> ()));
                    rows := chain_rows_clear_at !rows l ch
                | PBoundary -> ())
            | _ -> ())
       | Seed_mir.Drop (p, _, _) | Seed_mir.Deinit (p, _, _) -> (
           match root_local p with
           | None -> ()
           | Some l -> (
               match chain_of_place l p with
               | PWhole ->
                   (* a whole-root drop/destroy of a partially-moved root
                      is the MASKED drop: the dead chains' storage is
                      skipped; the root dies *)
                   st := set_state !st l Consumed;
                   rows := chain_rows_clear_root !rows l
               | PChain (ch, cty) ->
                   (* a projected drop/destroy: the CHAIN's value is
                      destroyed — deinit of a moved-out field is a
                      double-drop (the root stays live) *)
                   if chain_owning cty then begin
                     (match state_of !st l with
                      | Uninitialized -> err "_%d: read of uninitialized owned local" l
                      | Consumed -> err "_%d: use-after-consume" l
                      | Maybe_live ->
                          err "_%d: owned local may be consumed on one path" l
                      | Live -> (
                          match chain_prefix_state !rows l ch with
                          | Consumed ->
                              err "_%d: double-drop of owned field %s" l
                                (chain_to_string ch)
                          | Maybe_live ->
                              err "_%d: owned field %s may be consumed on one path" l
                                (chain_to_string ch)
                          | Live | Uninitialized -> ()));
                     rows := chain_row_set !rows l ch Consumed
                   end
                | PBoundary ->
                    err "_%d: cannot drop through a dynamic index or deref place: element-level state is not tracked (the container's elements are the ownership unit); destroy through the container's own ownership operations (clear / drain / remove) — never through an indexed place" l))
       | Seed_mir.SwitchInt (op, _, _) -> (
           match operand_place op with
           | Some p -> (
               match root_local p with
               | Some l -> read_place !st !rows l p
               | None -> ())
           | None -> ())
       | Seed_mir.Assert (op, _, _, _) -> (
           match operand_place op with
           | Some p -> (
               match root_local p with
               | Some l -> read_place !st !rows l p
               | None -> ())
           | None -> ())
       | Seed_mir.Goto _ | Seed_mir.Ret | Seed_mir.Unreachable | Seed_mir.Abort -> ());
      let out_s = !st in
      let out_c = !rows in
      let roots_same =
        List.length out_s = List.length out_states.(bid)
        && List.for_all2 (fun (_, s) (_, s') -> s = s') out_s out_states.(bid)
      in
      let chains_same =
        List.length out_c = List.length out_chains.(bid)
        && List.for_all2
             (fun (_, c, s) (_, c', s') -> c = c' && s = s')
             out_c out_chains.(bid)
      in
      if not (roots_same && chains_same) then begin
        out_states.(bid) <- out_s;
        out_chains.(bid) <- out_c;
        List.iter
          (fun succ ->
            if not (Hashtbl.mem in_work succ) then begin
              Hashtbl.add in_work succ ();
              Queue.push succ work
            end)
          (match f.Seed_mir.blocks.(bid).Seed_mir.terminator with
           | Seed_mir.Goto t | Seed_mir.Call (_, _, _, t, _) | Seed_mir.Drop (_, t, _)
           | Seed_mir.Deinit (_, t, _) | Seed_mir.Assert (_, _, _, t) ->
               [ t ]
           | Seed_mir.SwitchInt (_, targets, d) -> d :: List.map snd targets
           | Seed_mir.Ret | Seed_mir.Unreachable | Seed_mir.Abort -> [])
      end
    done;
    List.rev !errors
  end

(* cfg_check_program — the CFG resource dataflow over a whole program.
   ?lang_items is the compilation's LangItems record (optional: raw-MIR
   fixtures may omit it — a def-less owning LangItem then answers
   through the def table or the engine's conservative Unknown).  The
   engine's nominal resolver is built HERE over THIS program's def
   table (resolve_named — def_repr shapes, the same table
   Drop_plan.engine_resolve and mir_verify's find_type resolve) with
   the LangItems overlay, and the property cache is created per entry
   — one cache per def table, never shared across two tables, exactly
   like Mir_verify.require_valid_* / Drop_plan.of_program. *)
let cfg_check_program ?(lang_items : Lang_items.t option = None)
    (prog : Seed_mir.program) : string list =
  let cache = Type_properties.create_cache () in
  let resolve =
    Type_properties.with_lang_items lang_items
      (Type_properties.structural_resolver (resolve_named prog))
  in
  List.concat_map (cfg_check_function cache resolve prog) (Array.to_list prog.Seed_mir.functions)
