(* tg_bootstrap_gate.ml — the aggregate bootstrap-completeness gate.

   Runs the ACTUAL bootstrap/compiler_kernel.manifest closure through
   every stage of the seed compiler with NO fallback program and no
   informational DIFF escape hatch:

     [0] executable-subset firewall self-proof (Subset.check rejections
         must fire on their AST forms — each proof is replaced by an
         executable positive test when the corresponding semantics land)
     [1] manifest load
     [2] module graph
     [3] @cfg elimination
     [4] resolver
     [5] typechecker (fixpoint) — no-regression debt gate
     [6] access/resource checks
     [7] lowering
     [8] MIR verify (structural gate)
     [9] mono: reachable-function closure from the bootstrap entry +
         second MIR verify
    [10] reachable-host closure, VM run, artifact production

   Typecheck-debt policy (audit P1 + re-audit findings 3/5): the debt
   policy has ONE authority — this gate — running NO-REGRESSION against
   the accepted baseline captured from a real `tg_stage0.exe
   bootstrap-check` run on the checked tree and pinned in the accepted
   pointer bootstrap/evidence/ocaml/accepted.json + its evidence record
   (SHA-256 verified); the hardcoded scalars in baseline_typecheck_debt
   below are only the explicitly overridden development fallback
   (TG_BOOTSTRAP_ACCEPTED_OVERRIDE=1):

     accepted baseline: read from the verified accepted record (the
     pointer's debt facts; per-category buckets are diagnostic context
     only — the gate enforces the three monotonic scalars, never the
     buckets); the accepted record currently names debt_total 172,
     debt_primary 89, debt_secondary 83
     hardcoded development fallback: debt_total 160, debt_primary 77,
     debt_secondary 83 — used only under the explicit override

   The MONOTONIC gate fails (exit 1) exactly when a scalar rises:
   total > baseline total, primary > baseline primary, or secondary >
   baseline secondary — a scalar ceiling cannot mask a redistribution.
   Per-category comparisons are a DIAGNOSTIC REPORT, not a hard fail: a
   category may rise while the total falls (the audit's obligation 3 -> 4
   inside a falling total), so an individual category increase is
   printed as a redistribution note and never fails the gate by itself.
   At or below the baseline, the semantic stages are reported as
   deferred and the gate exits 0 ONLY because the debt is at its checked
   baseline.  The day the count is 0, stages 6-10 run and every one of
   them must succeed for the gate to print PASS. *)

(* The checked baseline: Debt_report.t with the per-category buckets in
   Debt_report.categories order (the order of_errors emits), the total,
   the primary count and the secondary count.  The MONOTONIC scalars
   moving UP fails the gate; moving down is progress, not a regression.
   The per-category buckets are diagnostic context only (a category may
   rise while the total falls — re-audit finding 5).

   Re-audit item 30 + audit items 18-20: the hardcoded baseline below is
   ONLY the explicitly overridden development fallback; the SINGLE
   machine-readable pointer is bootstrap/evidence/ocaml/accepted.json
   (the tested record + its REAL SHA-256), which the gate and the
   health script both read — the two can no longer drift.  When the
   accepted record is present and verified, its debt facts replace the
   fallback scalars, including a 0/0/0 record (the intended final
   accepted baseline).

   The pointer/record verification is fail-closed (audit item 20): a
   missing or malformed pointer, a pointer whose record is missing, a
   SHA-256 mismatch, or malformed/inconsistent debt facts are hard
   bootstrap-infrastructure errors.  The one documented escape is
   TG_BOOTSTRAP_ACCEPTED_OVERRIDE=1 (see Bootstrap_accepted.load),
   which restores the old warning + hardcoded-baseline behaviour for
   development only. *)
let baseline_typecheck_debt : Debt_report.t =
  {
    Debt_report.buckets =
      [
        ("unresolved_type", 0);
        ("unresolved_callable", 0);
        ("unresolved_module", 0);
        ("cannot_infer_generic", 0);
        ("type_mismatch", 0);
        ("obligation", 0);
        ("duplicate_decl", 0);
        ("other", 0);
      ];
    total = 160;
    primaries = 77;
    secondaries = 83;
  }

let fail fmt = Printf.ksprintf (fun s -> Printf.printf "BOOTSTRAP GATE: FAIL: %s\n" s; exit 1) fmt

(* ── Self-host preflight helpers (audit P0-2) ─────────────────────
   The preflight asks the prepared kernel to `check` its own stage1
   source graph.  Two machine-checkable facts are required beyond the
   kernel exit code: the exact manifest closure size (the recorded
   stage1 closure is 45 sources: 14 std + 31 compiler) and the kernel's
   own TG_CHECK_OK summary naming `tg_compiler/bootstrap_main.tg`. *)

(* The recorded stage-1 closure size.  The manifest remains the single
   source of truth: this constant pins the exact size the manifold gate
   authorizes, and the extracted manifest count must agree with it. *)
let expected_manifest_sources = 45

let manifest_closure_count ~(repo_root : string) : int =
  let path = Filename.concat repo_root "bootstrap/compiler_kernel.manifest" in
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let count = ref 0 in
      (try
         while true do
           let line = String.trim (input_line ic) in
           let is_entry =
             String.length line > 0
             && line.[0] <> '#'
             && (String.starts_with ~prefix:"std:" line
                || String.starts_with ~prefix:"compiler:" line)
           in
           if is_entry then incr count
         done
       with End_of_file -> ());
      !count)

(* Extract `name=value` from the TG_CHECK_OK summary line (space-separated
   fields).  Returns None when the field is absent or empty. *)
let summary_field (row : string) (name : string) : string option =
  let prefix = name ^ "=" in
  let fields = List.filter (fun s -> s <> "") (String.split_on_char ' ' row) in
  match List.find_opt (fun f -> String.starts_with ~prefix f) fields with
  | None -> None
  | Some f -> Some (String.sub f (String.length prefix) (String.length f - String.length prefix))

let parse_int_field (row : string) (name : string) : int option =
  match summary_field row name with Some v -> int_of_string_opt v | None -> None

(* ── Stage 0: the executable-subset firewall proof ─────────────── *)

(* Each entry: (name, expected code, source).  The source must parse
   cleanly; Subset.check must then emit the expected code.  When a
   subset rejection is deleted because its semantics landed, replace
   this entry with an executable POSITIVE test of the landed
   semantics. *)
let subset_proofs : (string * string * string) list =
  [
    ( "function-scoped defer",
      "E9033",
      {|def f() -> Int
  var acc = 0
  defer
    acc = acc + 1
  end
  acc
end
|} );
    ( "static declaration (literal initializer accepted; the static-ctor forms landed — see the E9034 deletion note below)",
      "ACCEPT",
      {|static LIMIT: Int = 100
def f() -> Int
  LIMIT
end
|} );
    ( "const declaration (literal initializer accepted)",
      "ACCEPT",
      {|const LIMIT: Int = 100
def f() -> Int
  LIMIT
end
|} );
    (* the user-enum E9035 gate is RETIRED: the VariantId fix landed
       (specs carry the registry-minted vs_id) and the positive
       driver-path end-to-end proof exists in tg_lowersurface (the
       three-variant enum round-trip with payload binding) *)
    (* field-projection E9036 was DELETED 2026-08-27: the typed-place
       (FieldId) rule landed in mir_lower — p.x now lowers and is VM
       proven in tg_lowersurface's struct-field proof (the positive
       parse -> typecheck -> lower -> verify -> execute replacement).
       The NAME/Field/Index writeback targets were likewise retired
       2026-08-28 (the typed-place writeback rule — proven in
       tg_lowersurface's writeback proof); E9036 remains only for the
       target forms with NO typed-place rule — the deref target here
       (the same specimen tg_subset's Assign reject-path uses). *)
    ( "projected assignment writeback (deref target accepted)",
      "ACCEPT",
      {|def f(p: Ptr[Int]) -> Int
  *p = 1
  0
end
|} );
  ]

let verify_subset_rejection (name : string) (code : string) (src : string) : unit =
  match Source_loader.load_string name src with
  | Error _ -> fail "subset firewall proof `%s`: source load failed" name
  | Ok source ->
      let sm = Span.create () in
      let file_id = Span.add_file sm source.Source.name source in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create source.Source.bytes file_id diags in
      let tokens = Lexer.lex lx in
      let program = Parser.parse tokens source.Source.bytes file_id diags [ "gate-proof" ] in
      if Diagnostic.has_errors diags then
        fail "subset firewall proof `%s`: parse errors:\n%s" name (Diagnostic.render sm diags);
      Subset.check diags program;
      let got = Diagnostic.codes diags in
      if code = "ACCEPT" then begin
        if got <> [] then
          fail "subset firewall proof `%s`: expected ACCEPT, got [%s]" name
            (String.concat "; " got)
      end
      else if not (List.mem code got) then
        fail "subset firewall proof `%s`: expected code %s, got [%s]" name code
          (String.concat "; " got);
      Printf.printf "  subset firewall: `%s` -> %s: PASS\n" name code

(* The first integrated access/resource semantic pass (re-audit P0-11),
   now a CFG-dataflow consumer (re-audit alignment): the driver composes
   the lane as (a) the per-call access-effect matrix over the closure
   env's RECORDED typed channels (one access record per checked call
   argument — place path + callee-side read effect) and (b) the
   authoritative path-sensitive CFG resource dataflow results
   (resource_check.ml over the lowered MIR), which already checks every
   call argument's Move/Consume operands per path.  The old linear
   per-item replay is NOT consumed: its recorded root identity is not
   unique within a bucket (sibling scopes restart LocalIds; impl-block
   methods share an item key; declaration rounds duplicate records), so
   it reported branch/bucket artifacts on the closure.  findings are
   reported, nothing is rewritten.

   HONEST NOTE: the CFG half is present exactly when the closure lowered
   (zero typecheck debt) — the same condition under which the gate
   enforces this lane; while debt remains the semantic stages are
   deferred and the gate exits before the lane's hard check. *)

let run_and_report_access_resource (ctx : Driver.closure_ctx) : int =
  let findings = Driver.run_access_resource_pass ctx in
  let status = if findings = [] then "PASS" else "FAIL" in
  Printf.printf "  ACCESS_RESOURCE_PASS = %s (%d finding(s))\n" status (List.length findings);
  let printed = ref 0 in
  List.iter
    (fun (f : Access_check.finding) ->
      if !printed < 10 then begin
        Printf.printf "    %s: %s\n" f.Access_check.f_kind f.Access_check.f_message;
        incr printed
      end)
    findings;
  if List.length findings > 10 then
    Printf.printf "    ... (%d more findings suppressed)\n" (List.length findings - 10);
  List.length findings

(* The no-regression policy (re-audit finding 5): the MONOTONIC gate is
   total <= baseline total, primary <= baseline primary, secondary <=
   baseline secondary.  The per-category buckets are compared only for a
   DIAGNOSTIC report — every category's baseline vs current is printed,
   and a category that rose while the total fell is noted — because a
   category may rise while the total falls (the audit's obligation 3 -> 4
   example); no individual category increase is a gate failure.  The
   buckets are compared positionally (both sides are emitted in
   Debt_report.categories order); a bucket-length mismatch is an
   internal error. *)
let check_no_regression (measured : Debt_report.t) (baseline : Debt_report.t) : unit =
  let violations = ref [] in
  if measured.Debt_report.total > baseline.Debt_report.total then
    violations :=
      Printf.sprintf "total %d > baseline %d" measured.Debt_report.total baseline.Debt_report.total
      :: !violations;
  if measured.Debt_report.primaries > baseline.Debt_report.primaries then
    violations :=
      Printf.sprintf "primary %d > baseline %d" measured.Debt_report.primaries
        baseline.Debt_report.primaries
      :: !violations;
  if measured.Debt_report.secondaries > baseline.Debt_report.secondaries then
    violations :=
      Printf.sprintf "secondary %d > baseline %d" measured.Debt_report.secondaries
        baseline.Debt_report.secondaries
      :: !violations;
  (try
     List.iter2
       (fun _ _ -> ())
       measured.Debt_report.buckets baseline.Debt_report.buckets
   with Invalid_argument _ ->
     fail "debt bucket alignment: measured %d buckets, baseline %d"
       (List.length measured.Debt_report.buckets)
       (List.length baseline.Debt_report.buckets));
  (* DIAGNOSTIC report: baseline vs current per category.  A category
     that rose while the scalars held (or fell) is a redistribution
     note, never a failure. *)
  let rose =
    List.filter_map
      (fun ((c, n), (_, b)) -> if n > b then Some (c, n, b) else None)
      (List.combine measured.Debt_report.buckets baseline.Debt_report.buckets)
  in
  Printf.printf "  debt categories (current vs checked baseline):\n";
  List.iter2
    (fun (c, n) (_, b) ->
      let mark = if n > b then "  (above baseline — diagnostic note)" else "" in
      Printf.printf "    %s: %d vs %d%s\n" c n b mark)
    measured.Debt_report.buckets baseline.Debt_report.buckets;
  if rose <> [] then
    Printf.printf
      "  NOTE: category redistribution (a category may rise while the total falls; \
       the monotonic gate is total/primary/secondary only): %s\n"
      (String.concat "; "
         (List.map (fun (c, n, b) -> Printf.sprintf "%s %d -> %d" c b n) rose));
  match List.rev !violations with
  | [] -> ()
  | vs ->
      List.iter (fun v -> Printf.printf "  BOOTSTRAP GATE: debt regression: %s\n" v) vs;
      fail
        "typecheck debt REGRESSED against the checked baseline — total, primary or \
         secondary increased"

(* ── The gate ───────────────────────────────────────────────────── *)

let () =
  let repo_root, target_str =
    match Array.to_list Sys.argv with
    | _ :: "--repo-root" :: r :: "--target" :: t :: _ -> (r, t)
    | _ :: "--repo-root" :: r :: _ -> (r, "aarch64-apple-darwin")
    | _ :: "--target" :: t :: _ -> ("..", t)
    | _ -> ("..", "aarch64-apple-darwin")
  in
  Printf.printf "TANGERINE OCAML SEED — BOOTSTRAP COMPLETENESS GATE (tg_bootstrap_gate)\n";
  Printf.printf "  repo-root: %s; target: %s\n" repo_root target_str;
  let baseline =
    match Bootstrap_accepted.load ~repo_root ~hardcoded:baseline_typecheck_debt with
    | Ok { Bootstrap_accepted.baseline = b; source = Bootstrap_accepted.Accepted_record record_name }
      ->
        Printf.printf
          "  checked typecheck-debt baseline (bootstrap/evidence/ocaml/accepted.json -> %s, REAL SHA-256 verified): total %d, primary %d, secondary %d\n"
          record_name b.Debt_report.total b.Debt_report.primaries b.Debt_report.secondaries;
        b
    | Ok { Bootstrap_accepted.baseline = b; source = Bootstrap_accepted.Hardcoded_fallback reason }
      ->
        Printf.printf
          "  WARNING: accepted bootstrap evidence unusable (%s); %s=1 is set — using the hardcoded development fallback: total %d, primary %d, secondary %d\n"
          reason Bootstrap_accepted.override_env b.Debt_report.total b.Debt_report.primaries
          b.Debt_report.secondaries;
        b
    | Error m -> fail "accepted bootstrap evidence: %s" m
  in
  List.iter
    (fun (c, n) -> Printf.printf "    baseline %s: %d\n" c n)
    baseline.Debt_report.buckets;
  let target =
    match Target.unsupported_triple target_str with
    | Ok t -> t
    | Error m -> fail "target: %s" m
  in
  (* [0] subset firewall self-proof — independent of the typecheck debt *)
  Printf.printf "  [0/10] executable-subset firewall (Subset.check rejections)\n";
  List.iter
    (fun (name, code, src) -> verify_subset_rejection name code src)
    subset_proofs;
  (* [1]-[5]: the driver's closure pipeline — manifest -> module graph
     -> @cfg elimination -> resolver -> typecheck fixpoint.  The driver
     prints its own detail lines; the gate adds the stage markers. *)
  Printf.printf "  [1/10] manifest load\n";
  Printf.printf "  [2/10] module graph\n";
  Printf.printf "  [3/10] @cfg elimination\n";
  Printf.printf "  [4/10] resolver (strict)\n";
  Printf.printf "  [5/10] typechecker (fixpoint)\n";
  (* THE canonical closure: the gate consumes Driver.run_bootstrap_closure
     (strict resolution + subset scan + template verify + mono with the
     generic registry + concrete verify + static reachable-host proof +
     VM + artifact) — the gate no longer reconstructs the pipeline.

     REPOSITORY-ARTIFACT HYGIENE (audit P0-1): the VM artifact lands in
     build/bootstrap/, never at the repository root.  The path is
     PID-unique so concurrent gates cannot clobber each other, any stale
     copy is removed BEFORE the VM run (existence after the run is
     therefore proof of a fresh artifact, never a leftover), and the
     artifact is removed again afterwards unless evidence retention is
     explicitly requested with TG_BOOTSTRAP_KEEP_GATE_ARTIFACT=1. *)
  let gate_artifact =
    Printf.sprintf "build/bootstrap/gate_probe.%d" (Unix.getpid ())
  in
  let ensure_dir path =
    let rec go p =
      if p = "" || p = "." || p = "/" || Sys.file_exists p then ()
      else begin
        go (Filename.dirname p);
        try Unix.mkdir p 0o755 with
        | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
        | Unix.Unix_error (e, _, _) ->
            fail "cannot create the gate artifact directory %s: %s" p
              (Unix.error_message e)
      end
    in
    go path
  in
  let artifact_abs = Filename.concat repo_root gate_artifact in
  ensure_dir (Filename.dirname artifact_abs);
  (try Sys.remove artifact_abs with Sys_error _ -> ());
  let kernel_args =
    [ "compile"; "tests/differential/corpus/01_defs_arith.tg"; "-o"; gate_artifact;
      "--target"; target_str ]
  in
  (match
     Driver.run_bootstrap_closure ~repo_root ~manifest_path:"bootstrap/compiler_kernel.manifest"
       ~target ~entry:None ~kernel_args
   with
   | Error m -> fail "closure pipeline: %s" m
   | Ok stages ->
       let ctx = stages.Driver.bs_ctx in
       let n_errs = List.length ctx.ctx_type_errors in
       Printf.printf "  typecheck: %d errors across %d modules / %d items (%d rounds)\n" n_errs
         ctx.ctx_graph.Module_graph.node_count ctx.ctx_items ctx.ctx_decl_rounds;
       (* The measured debt is the pipeline's OWN accumulated accounting
          (Typecheck.state.debt_by_module — what record_module_debt
          prints block by block), not a re-classification of the driver's
          flattened error list: the driver prepends "<module>: " to every
          error, which would hide the "[secondary] " prefix and misreport
          the primary/secondary split. *)
       let measured_debt =
         Debt_report.sum_reports
           (List.map snd ctx.ctx_env.Typecheck.state.debt_by_module)
       in
       Printf.printf "  measured debt: total %d, primary %d, secondary %d\n"
         measured_debt.Debt_report.total measured_debt.Debt_report.primaries
         measured_debt.Debt_report.secondaries;
       check_no_regression measured_debt baseline;
       (* re-audit P0s: the manifest subset firewall and the strict
          resolution are HARD gates on the actual closure result (never
          merely printed) *)
       if ctx.ctx_subset.Driver.sr_total <> 0 then
         fail
           "manifest subset firewall: %d unsupported construct(s) in the compiler manifest — \
            the aggregate gate requires zero" ctx.ctx_subset.Driver.sr_total;
       (* the TYPED-PROFILE firewall (the audit's P0): the syntactic
          subset says the parser sees no categorically forbidden form;
          the typed profile says every TYPED use of an accepted form is
          executable — the aggregate gate requires BOTH zero *)
       if ctx.ctx_profile_findings <> 0 then
         fail
           "typed semantic profile: %d not-yet-executable typed use(s) in the compiler manifest —             the aggregate gate requires zero (the audit: subset-zero does not mean executable closure)"
           ctx.ctx_profile_findings;
       if ctx.ctx_strict_fallbacks <> 0 then
         fail
           "strict resolution: %d compatibility-fallback activation(s) — the aggregate gate \
            requires zero (the seed-swap condition)" ctx.ctx_strict_fallbacks;
       (* [6/10] the integrated access/resource pass: RUNS over the
          closure env's recorded typed channels (additive reporting —
          it cannot change the debt numbers above) *)
       Printf.printf "  [6/10] access/resource: integrated pass over recorded typed channels\n";
       let n_access_findings = run_and_report_access_resource ctx in
       if n_errs > 0 then begin
         (* At the checked baseline: report the deferred semantic stages
            explicitly; exit 0 ONLY because the debt is unchanged and at
            (or below) the baseline. *)
         Printf.printf "  [6/10] access/resource checks: deferred (typecheck debt)\n";
         Printf.printf "  [7/10] lowering: deferred (typecheck debt)\n";
         Printf.printf "  [8/10] MIR verify: deferred (typecheck debt)\n";
         Printf.printf "  [9/10] mono + second MIR verify: deferred (typecheck debt)\n";
         Printf.printf "  [10/10] host closure + VM + artifacts: deferred (typecheck debt)\n";
         Printf.printf "BOOTSTRAP GATE: typecheck debt %d (at/below the checked baseline) — semantic stages deferred\n"
           n_errs;
         Printf.printf "BOOTSTRAP GATE: RESULT: DEVELOPMENT DEBT GATE: PASS (no regression vs the checked baseline; FULL COMPLETENESS: NOT RUN / DEFERRED — the typecheck debt is nonzero)\n";
         exit 0
       end;
       (* Zero typecheck debt: the full semantic closure must succeed —
          inspecting the ONE canonical result (the stages were computed
          by Driver.run_bootstrap_closure with strict resolution, the
          subset scan, the template verifier + generic registry, mono
          with the registry, the concrete verifier, the static
          reachable-host proof, the VM and the artifact). *)
       Printf.printf "  [6/10] call-argument access sanity\n";
       if n_access_findings > 0 then
         fail
           "call-argument access findings on the closure (%d) — the lane must be clean \
            before closure PASS: the recorded-channel access matrix plus the authoritative \
            path-sensitive CFG resource dataflow (resource_check.ml over the lowered MIR, \
            which checks every call argument's Move/Consume operands per path)"
           n_access_findings;
       (match stages.Driver.bs_prog with
        | None -> fail "lowering produced no program"
        | Some prog ->
            Printf.printf "  [7/10] lowering: PASS (%d functions lowered)\n"
              (Array.length prog.Seed_mir.functions);
            if not stages.Driver.bs_mir_verify_ok then fail "template MIR verify";
            Printf.printf "  [8/10] template MIR verify: PASS (%d functions)\n"
              (Array.length prog.Seed_mir.functions);
            if stages.Driver.bs_oracle_incomplete then
              fail "oracle DIFF rows present — completeness is not closed";
            (match stages.Driver.bs_mono with
             | None -> fail "mono phase"
             | Some mo ->
                 if mo.Driver.mo_residual_type_params > 0 then
                   fail "%d residual Type_param after mono" mo.Driver.mo_residual_type_params;
                 Printf.printf
                   "  [9/10] mono (reachable closure): PASS — pre %d -> post %d instances\n"
                   mo.Driver.mo_pre_functions mo.Driver.mo_post_functions;
                 Printf.printf "  [10/10] reachable-host closure + VM run + artifact production\n";
                  (match stages.Driver.bs_host_report with
                   | None -> fail "static reachable-host closure proof missing"
                   | Some _ ->
                       Printf.printf "  REACHABLE_HOST_CLOSURE = PASS\n";
                       (match stages.Driver.bs_vm_code with
                        | None -> fail "VM bootstrap run missing"
                        | Some code ->
                            Printf.printf "  VM bootstrap run: exit %d\n" code;
                            if code <> 0 then fail "nonzero exit from the kernel";
                            (match stages.Driver.bs_artifact with
                             | None ->
                                 fail
                                   "VM exited 0 but produced no artifact at %s (stale copies are \
                                    removed before the run — a missing file is a real failure, \
                                    never masked by a leftover)"
                                   gate_artifact
                             | Some out_path ->
                                 if out_path <> gate_artifact then
                                   fail "artifact path mismatch: kernel wrote %s, expected %s"
                                     out_path gate_artifact;
                                 if not (Sys.file_exists artifact_abs) then
                                   fail
                                     "artifact path %s reported but the file does not exist \
                                      under the repo root"
                                     gate_artifact;
                                 Printf.printf "  artifact produced: %s\n" out_path)))));
        (* ── [11/11] the self-host preflight (audit P0-2) ───────────
           The artifact run proves the kernel can compile a small
           program.  This stage proves the kernel can consume its OWN
           stage1 source graph: the same prepared kernel program is
           executed in a FRESH VM with `check --strict-resolution
           tg_compiler/bootstrap_main.tg`.  The check stops after MIR
           verification (no native codegen/link), and the kernel emits
           the machine-readable TG_CHECK_OK summary carrying the exact
           manifest closure size.  Exit 0 in strict mode subsumes zero
           resolver and zero type diagnostics (the kernel check fails
           closed on any of them); the gate additionally requires the
           summary to name bootstrap_main.tg and the exact 45-source
           closure, so a stale/other input can never false-green. *)
        Printf.printf
          "  [11/11] self-host preflight: kernel checks tg_compiler/bootstrap_main.tg (strict resolution, stop after MIR)\n";
        let manifest_count = manifest_closure_count ~repo_root in
        if manifest_count <> expected_manifest_sources then
          fail
            "manifest closure size changed: bootstrap/compiler_kernel.manifest lists %d sources, \
             the recorded stage1 closure is %d — update expected_manifest_sources deliberately \
             (and every pinned count) when the kernel closure grows"
            manifest_count expected_manifest_sources;
        let preflight_args =
          [ "check"; "--strict-resolution"; "tg_compiler/bootstrap_main.tg";
            "--target"; target_str ]
        in
        let pre =
          match stages.Driver.bs_mono with
          | None -> fail "mono phase missing for the self-host preflight"
          | Some mo ->
              (* instrumented: the preflight is a SECOND kernel VM run and
                 the gate's timeout cap must be re-pinned from its real
                 duration (never a blind increase). *)
              let t0 = Unix.gettimeofday () in
              let r =
                Driver.run_prepared_vm ~repo_root ~kernel_args:preflight_args
                  ~program:(Driver.vm_program_with_folded_queries ctx mo)
                  ~entry:mo.Driver.mo_entry
                  ~lang_items:(Typecheck.lang_items_of_env ctx.ctx_env)
                  ~cache_hit:false ~target
              in
              Printf.printf "  phase] self-host preflight VM run: %.1fs\n%!"
                (Unix.gettimeofday () -. t0);
              r
        in
        (match pre.Driver.bvr_vm_code with
         | None ->
             fail
               "self-host preflight did not complete: %s\nkernel stderr:\n%s"
               (Option.value ~default:"no VM exit (step/alloc budget or an upstream stage)"
                  pre.Driver.bvr_trap)
               pre.Driver.bvr_stderr
         | Some code when code <> 0 ->
             fail
               "self-host preflight FAILED (kernel check exit %d) — the kernel cannot consume \
                tg_compiler/bootstrap_main.tg\nkernel stdout:\n%s\nkernel stderr:\n%s"
               code pre.Driver.bvr_stdout pre.Driver.bvr_stderr
         | Some _ ->
             let rows =
               List.filter
                 (fun l -> String.starts_with ~prefix:"TG_CHECK_OK " l)
                 (String.split_on_char '\n' pre.Driver.bvr_stdout)
             in
             (match rows with
              | [] ->
                  fail
                    "self-host preflight exited 0 without the TG_CHECK_OK summary — refusing \
                     the false green (stale or wrong kernel binary); stdout:\n%s"
                    pre.Driver.bvr_stdout
              | row :: extra -> (
                  if extra <> [] then
                    fail "self-host preflight emitted %d TG_CHECK_OK rows (exactly one expected)"
                      (List.length rows);
                  (match summary_field row "file" with
                  | Some f when f = "tg_compiler/bootstrap_main.tg" -> ()
                  | Some f ->
                      fail "self-host preflight checked `%s`, not `tg_compiler/bootstrap_main.tg`" f
                  | None -> fail "self-host preflight summary has no file= field: %s" row);
                  (match parse_int_field row "sources" with
                  | Some n when n = expected_manifest_sources -> ()
                  | Some n ->
                      fail
                        "self-host preflight consumed %d source(s), the manifest closure is %d \
                         — the kernel did not load the exact stage1 source graph"
                        n expected_manifest_sources
                  | None -> fail "self-host preflight summary has no sources= field: %s" row);
                  Printf.printf
                    "  SELF-HOST PREFLIGHT: PASS — kernel check of tg_compiler/bootstrap_main.tg \
                     exit 0 over the exact %d-source manifest closure (resolver 0, type 0; \
                     strict, stop after MIR)\n"
                    manifest_count)));
        (* hygiene: never leave the generated probe in the working tree *)
        if Sys.getenv_opt "TG_BOOTSTRAP_KEEP_GATE_ARTIFACT" = Some "1" then
          Printf.printf
            "  artifact retained (TG_BOOTSTRAP_KEEP_GATE_ARTIFACT=1): %s\n"
            gate_artifact
        else begin
          (try Sys.remove artifact_abs with Sys_error _ -> ());
          Printf.printf "  artifact removed: %s (set TG_BOOTSTRAP_KEEP_GATE_ARTIFACT=1 to retain)\n"
            gate_artifact
        end;
        Printf.printf "BOOTSTRAP GATE: PASS — full closure through every stage\n";
        Selfcheck_sentinel.emit_and_exit "tg_bootstrap_gate")
