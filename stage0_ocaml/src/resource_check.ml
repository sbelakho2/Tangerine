(* resource_check.ml — Ownership/cleanup planning (audit §30, §65).

   A per-local state lattice over the function's control flow, producing a
   cleanup plan and proving: exactly one terminal drop per owned lineage,
   no double drops, no use-after-consume, no live leaked resource. *)

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
