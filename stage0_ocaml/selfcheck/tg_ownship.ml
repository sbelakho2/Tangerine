(* tg_ownship.ml — resource_check lattice self-check (audit §30, §65).

   Constructs the resource states directly (the module's types are
   exposed since the library is unwrapped) and checks the merge rows and
   the finalize plan:

   (a) branch A consumes x, branch B consumes x -> join must be Consumed
       and finalize must schedule NO drop for it (no double-drop plan);
   (b) branch A leaves x Live, branch B consumes x -> the join must NOT
       be Live-with-unconditional-drop: the result is Maybe_live and
       finalize must not silently plan a drop for it (Maybe_live must
       not be treated as Live);
   (c) a plain Live+Live merge still schedules exactly one drop. *)

let failures = ref 0

let check (name : string) (ok : bool) : unit =
  Printf.printf "%s: %s\n" (if ok then "PASS" else "FAIL") name;
  if not ok then incr failures

let () =
  (* ── (a) consume on both branches ──────────────────────────────── *)
  let env = Resource_check.create_env [ 1 ] in
  Resource_check.check_initialize env 1 "a: init";        (* _1 Live at the branch point *)
  Resource_check.check_move env 1 false "a: branch A";    (* A consumes _1 -> Consumed *)
  let states_a = env.Resource_check.states in
  Resource_check.set_state env 1 Resource_check.Live;     (* reset to the branch point *)
  Resource_check.check_move env 1 false "a: branch B";    (* B consumes _1 -> Consumed *)
  Resource_check.merge_state env states_a;                (* join(Consumed, Consumed) *)
  check "a: join(Consumed, Consumed) is Consumed"
    (Resource_check.state_of env 1 = Resource_check.Consumed);
  let plan = Resource_check.finalize env "a: fn" in
  check "a: finalize schedules NO drop for the joined Consumed"
    (plan.Resource_check.actions = []);
  check "a: the merged plan cannot double-drop (no Drop action at all)"
    (List.length plan.Resource_check.actions = 0);

  (* ── (b) live on one branch, consume on the other ──────────────── *)
  let env = Resource_check.create_env [ 1 ] in
  Resource_check.check_initialize env 1 "b: init";        (* _1 Live at the branch point *)
  Resource_check.set_state env 1 Resource_check.Live;     (* A leaves _1 Live *)
  let states_a = env.Resource_check.states in
  Resource_check.set_state env 1 Resource_check.Consumed; (* B consumes _1 *)
  Resource_check.merge_state env states_a;                (* join(Live, Consumed) *)
  let merged = Resource_check.state_of env 1 in
  Printf.printf "  b: branch A Live, branch B Consumed -> joined state: %s\n"
    (Resource_check.state_to_string merged);
  check "b: join(Live, Consumed) is NOT Live (no unconditional-drop state)"
    (merged <> Resource_check.Live);
  check "b: join(Live, Consumed) is Maybe_live"
    (merged = Resource_check.Maybe_live);
  let plan = Resource_check.finalize env "b: fn" in
  check "b: finalize schedules NO silent drop for the joined Maybe_live"
    (plan.Resource_check.actions = []);
  check "b: final_states reports the Maybe_live (conditional-cleanup signal)"
    (List.mem (1, Resource_check.Maybe_live) plan.Resource_check.final_states);

  (* ── (c) live on both branches ─────────────────────────────────── *)
  let env = Resource_check.create_env [ 1 ] in
  Resource_check.check_initialize env 1 "c: init";        (* _1 Live at the branch point *)
  let states_a = env.Resource_check.states in
  Resource_check.set_state env 1 Resource_check.Live;     (* B leaves _1 Live *)
  Resource_check.merge_state env states_a;                (* join(Live, Live) *)
  check "c: join(Live, Live) is Live"
    (Resource_check.state_of env 1 = Resource_check.Live);
  let plan = Resource_check.finalize env "c: fn" in
  check "c: finalize schedules exactly one drop"
    (plan.Resource_check.actions
     = [ { Resource_check.local = 1; Resource_check.action = Resource_check.Drop } ]);

  if !failures = 0 then begin
    Printf.printf "tg_ownship: ALL PASS\n";
    exit 0
  end
  else begin
    Printf.printf "tg_ownship: %d FAILURE(S)\n" !failures;
    exit 1
  end
