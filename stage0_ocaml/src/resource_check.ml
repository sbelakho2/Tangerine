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
   element-state rule; assignment over a live owning field runs the
   masked drop-before-store semantics (a depth-1 target of a fully-live
   root destroys the sibling direct fields — marked Consumed; a nested
   target is an exact-place replacement). *)

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

(* The Copy property (mirror of mir_verify.is_copy, read-only reference):
   scalars, references and function values are Copy; String is owning; a
   tuple/fixed-array is Copy iff every element is; a nominal is Copy iff
   every field (struct) or every payload (enum) is.  `resolve` maps a
   nominal type id to its definition shape (the caller supplies the
   typecheck env's nominal registry); anything unknown or unresolvable is
   CONSERVATIVELY non-Copy (an owned lattice root, moved not copied). *)
let rec is_copy (resolve : Ids.Type_id.t -> Type_repr.t option) (seen : Ids.Type_id.t list)
    (ty : Type_repr.t) : bool =
  match ty with
  | Type_repr.Unit | Type_repr.Bool | Type_repr.Char | Type_repr.Int _
  | Type_repr.Float _ | Type_repr.Raw_ptr _ | Type_repr.Ref_internal _
  | Type_repr.Function _ | Type_repr.Never ->
      true
  | Type_repr.String -> false
  | Type_repr.Tuple elems -> Array.for_all (is_copy resolve seen) elems
  | Type_repr.Fixed_array (elem, _) -> is_copy resolve seen elem
  | Type_repr.Named (tid, _) ->
      if List.mem tid seen then false
      else (
        match resolve tid with
        | None -> false
        | Some def -> is_copy resolve (tid :: seen) def)
  | Type_repr.Type_param _ | Type_repr.Infer_var _ | Type_repr.Int_literal _ | Type_repr.Error ->
      false

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

(* The root's DIRECT-FIELD shape (the sibling-masking of the whole-root
   assign-drop case needs the direct field keys).  A struct resolves
   through its def to the semantic Field ids; a tuple / fixed array is
   the positional ConstantIndex domain; anything else (an enum, an
   unresolvable nominal) is unknown — the native root_direct_shape_known
   gate. *)
let root_direct_field_keys (prog : Seed_mir.program) (root_ty : Type_repr.t) :
    Seed_mir.projection list option =
  match root_ty with
  | Type_repr.Tuple elems ->
      Some (List.init (Array.length elems) (fun i -> Seed_mir.ConstantIndex i))
  | Type_repr.Fixed_array (_, n) when n > 0 ->
      Some (List.init n (fun i -> Seed_mir.ConstantIndex i))
  | Type_repr.Named (tid, _) -> (
      match type_def_of prog tid with
      | Some (Seed_mir.StructDef { sd_fields; _ }) when sd_fields <> [] ->
          Some (List.map (fun f -> Seed_mir.Field f.Seed_mir.fd_id) sd_fields)
      | _ -> None)
  | _ -> None

let cfg_check_function (prog : Seed_mir.program) (f : Seed_mir.function_) : string list =
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
    (* the owned locals (the non-Copy roots) — the root-ownedness rule of
       the current pass is kept (conservative: a nominal that cannot be
       resolved is owning), so the existing root-level behavior is
       unchanged wherever chains do not apply *)
    let owned =
      List.filter
        (fun l -> not (is_copy (fun _ -> None) [] f.Seed_mir.locals.(l)))
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
    let chain_owning (cty : Type_repr.t) : bool =
      not (is_copy (resolve_named prog) [] cty)
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
    (* does any operand of the rvalue root at local l? (the same-root
       drop-before-store guard) *)
    let rv_roots_at (rv : Seed_mir.rvalue) (l : int) : bool =
      List.exists
        (fun op ->
          match operand_place op with
          | Some p -> p.Seed_mir.root = Seed_mir.Local l
          | None -> false)
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
            err "_%d: cannot consume through a dynamic index or deref place: element-level state is not tracked (the container's elements are the ownership unit)" l;
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
                 tracked, but the RHS is still walked. *)
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
                                 (* dead field storage: the store re-lives
                                    the field without a drop *)
                                 ()
                             | Maybe_live ->
                                 err "_%d: owned field %s may be consumed on one path" l
                                   (chain_to_string ch)
                             | Live | Uninitialized ->
                                 if owning then begin
                                   (* the old owning value's
                                      drop-before-store — the PREFIX RULE
                                      decides the representable form: a
                                      depth-1 target of a fully-live root
                                      is the whole-root masked drop (the
                                      sibling fields must be markable); a
                                      nested target is the exact-place
                                      replacement. *)
                                   if List.length ch = 1
                                      && chain_root_has_moves pre_rows l then
                                     err "_%d: cannot assign over owned field %s: the root is partially moved out (the masked drop-before-store is not representable)" l
                                       (chain_to_string ch)
                                   else if List.length ch = 1
                                           && root_direct_field_keys prog
                                                f.Seed_mir.locals.(l)
                                              = None then
                                     err "_%d: cannot assign over owned field %s: the root's field shape is unknown (the sibling fields cannot be masked)" l
                                       (chain_to_string ch)
                                   else if rv_roots_at rv l then
                                     err "_%d: cannot assign over an owning projected place: the value moves out of the same root (the drop-before-store would destroy its source)" l
                                 end));
                        (* the commit decision comes from the PRE-RHS rows
                           (the RHS walk must not change the drop form) *)
                        let drops_siblings =
                          root_st = Live
                          && chain_prefix_state pre_rows l ch = Live
                          && List.length ch = 1
                          && owning
                          && not (chain_root_has_moves pre_rows l)
                          && root_direct_field_keys prog f.Seed_mir.locals.(l) <> None
                        in
                        let sibling_keys =
                          if drops_siblings
                          then root_direct_field_keys prog f.Seed_mir.locals.(l)
                          else None
                        in
                        Some (l, Some (ch, sibling_keys)))
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
                   | Some (ch, sibling_keys) ->
                       (* the sibling DIRECT fields die with the whole-root
                          drop chain — marked Consumed so the cleanup skips
                          them; the store re-lives the target chain and its
                          extensions *)
                       (match sibling_keys with
                        | Some keys ->
                            List.iter
                              (fun sk ->
                                if sk <> List.hd ch then
                                  rows := chain_row_set !rows l [ sk ] Consumed)
                              keys
                        | None -> ());
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
                       assign-drop chain) *)
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
                         | Consumed | Live | Uninitialized -> ()));
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
                   err "_%d: cannot drop through a dynamic index or deref place: element-level state is not tracked (the container's elements are the ownership unit)" l))
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

let cfg_check_program (prog : Seed_mir.program) : string list =
  List.concat_map (cfg_check_function prog) (Array.to_list prog.Seed_mir.functions)
