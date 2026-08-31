(* resource_check.ml — Ownership/cleanup planning (audit §30, §65).

   A per-local state lattice over the function's control flow, producing a
   cleanup plan and proving: exactly one terminal drop per owned lineage,
   no double drops, no use-after-consume, no live leaked resource. *)

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

let cfg_check_function (_prog : Seed_mir.program) (f : Seed_mir.function_) : string list =
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
    (* the owned locals (the non-Copy roots) *)
    let owned =
      List.filter
        (fun l -> not (is_copy (fun _ -> None) [] f.Seed_mir.locals.(l)))
        (List.init (Array.length f.Seed_mir.locals) (fun i -> i))
    in
    let owned_set = List.fold_left (fun s l -> IntSet.add l s) IntSet.empty owned in
    let in_states : (int * resource_state) list array = Array.make nb [] in
    let out_states : (int * resource_state) list array = Array.make nb [] in
    (* the entry: the owned params are Live (the caller owns them) *)
    let entry_init =
      List.map
        (fun l -> (l, if l = 0 then Uninitialized else Live))
        owned
    in
    in_states.(f.Seed_mir.entry) <- entry_init;
    out_states.(f.Seed_mir.entry) <- entry_init;
    let work = Queue.create () in
    Queue.push f.Seed_mir.entry work;
    let in_work = Hashtbl.create 16 in
    Hashtbl.add in_work f.Seed_mir.entry ();
    let errors = ref [] in
    let state_of states l = List.assoc_opt l states |> Option.value ~default:Uninitialized in
    let set_state states l s =
      (l, s) :: List.filter (fun (l', _) -> l' <> l) states
    in

    let owned_roots = List.map (fun l -> Seed_mir.Local l) owned in
    let operand_read states op =
      match op with
      | Seed_mir.Copy p | Seed_mir.Read p | Seed_mir.Move p | Seed_mir.Consume p
        when List.mem p.Seed_mir.root owned_roots -> (
          match p.Seed_mir.root with
          | Seed_mir.Local l -> (
              match state_of states l with
              | Uninitialized ->
                  errors :=
                    Printf.sprintf "_%d: read of uninitialized owned local" l :: !errors
              | Consumed ->
                  errors := Printf.sprintf "_%d: use-after-consume" l :: !errors
              | _ -> ())
          | _ -> ())
      | _ -> ()
    in
    while not (Queue.is_empty work) do
      let bid = Queue.pop work in
      Hashtbl.remove in_work bid;
      let in_s =
        match preds.(bid) with
        | [] -> in_states.(bid)
        | ps ->
            List.fold_left
              (fun acc p -> states_join acc out_states.(p))
              [] ps
      in
      in_states.(bid) <- in_s;
      let st = ref in_s in
      List.iter
        (fun s ->
          match s with
          | Seed_mir.Assign (p, rv) -> (
              let rv_reads =
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
              List.iter (fun op -> operand_read !st op) rv_reads;
              (match p.Seed_mir.root with
               | Seed_mir.Local l when IntSet.mem l owned_set ->
                   st := set_state !st l Live
               | _ -> ()))
          | Seed_mir.StorageLive _ | Seed_mir.StorageDead _ | Seed_mir.SetDiscriminant _
          | Seed_mir.Nop -> ())
        f.Seed_mir.blocks.(bid).Seed_mir.statements;
      (match f.Seed_mir.blocks.(bid).Seed_mir.terminator with
       | Seed_mir.Drop (p, _, _) | Seed_mir.Deinit (p, _, _) -> (
           match p.Seed_mir.root with
           | Seed_mir.Local l when IntSet.mem l owned_set ->
               st := set_state !st l Consumed
           | _ -> ())
       | _ -> ());
      let out_s = !st in
      if not (List.length out_s = List.length out_states.(bid)
              && List.for_all2 (fun (_, s) (_, s') -> s = s') out_s out_states.(bid))
      then begin
        out_states.(bid) <- out_s;
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
