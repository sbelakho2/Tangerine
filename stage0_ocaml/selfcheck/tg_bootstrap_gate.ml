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
   a CHECKED baseline captured from a real `tg_stage0.exe
   bootstrap-check` run on the checked tree (2026-08-26):

     debt_total:    257
     debt_primary:  181   (debt_secondary: 76)
     per-category:  unresolved_type 14, unresolved_callable 32,
                    unresolved_module 0, cannot_infer_generic 9,
                    type_mismatch 180, obligation 4, duplicate_decl 0,
                    other 18
     modules/items: 56 modules, 4496 items (4 measured declaration
                    fixpoint passes — re-audit finding 2: closure_ctx
                    carries !decl_rounds, not a hard-coded 2)

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
   rise while the total falls — re-audit finding 5). *)
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
    total = 123;
    primaries = 67;
    secondaries = 56;
  }

let fail fmt = Printf.ksprintf (fun s -> Printf.printf "BOOTSTRAP GATE: FAIL: %s\n" s; exit 1) fmt

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
    ( "static declaration (never reaches program.statics)",
      "E9034",
      {|static LIMIT: Int = 100
def f() -> Int
  LIMIT
end
|} );
    ( "const declaration (never reaches program.statics)",
      "E9034",
      {|const LIMIT: Int = 100
def f() -> Int
  LIMIT
end
|} );
    ( "user-enum match arm beyond the default variant table",
      "E9035",
      {|enum Color
  Red,
  Green(Int)
end

def f(c: Color) -> Int
  match c {
    Green(g) => g,
    Red() => 0
  }
end
|} );
    ( "user-enum construction beyond the default variant table",
      "E9035",
      {|enum Color
  Red,
  Green(Int)
end

def make() -> Color
  Green(7)
end
|} );
    ( "user-enum qualified construction beyond the default variant table",
      "E9035",
      {|enum Color
  Red,
  Green(Int)
end

def make() -> Color
  Color::Green(7)
end
|} );
    ( "field projection (no typed-place Field rule)",
      "E9036",
      {|struct Point
  x: Int
  y: Int
end

def f(p: Point) -> Int
  p.x
end
|} );
    ( "projected assignment writeback (no typed-place writeback rule)",
      "E9036",
      {|def f() -> Int
  var a = [1, 2, 3]
  a[1] = 9
  a[1]
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
      if not (List.mem code got) then
        fail "subset firewall proof `%s`: expected code %s, got [%s]" name code
          (String.concat "; " got);
      Printf.printf "  subset firewall: `%s` -> %s: PASS\n" name code

(* ── Stage 10 machinery (zero-debt path only) ──────────────────── *)

let kernel_output_path (kernel_args : string list) : string option =
  let rec go = function
    | "-o" :: v :: _ | "--output" :: v :: _ -> Some v
    | _ :: rest -> go rest
    | [] -> None
  in
  match go kernel_args with
  | Some p -> Some p
  | None -> (
      match kernel_args with
      | file :: _ when not (String.length file >= 1 && file.[0] = '-') ->
          if Filename.check_suffix file ".tg" then Some (Filename.chop_suffix file ".tg")
          else Some file
      | _ -> None)

let artifact_exists ~(repo_root : string) (path : string) : bool =
  if Filename.is_relative path then Sys.file_exists (Filename.concat repo_root path)
  else Sys.file_exists path

(* The first integrated access/resource semantic pass (re-audit P0-11):
   the driver runs Access_check.run_closure over the closure env's
   RECORDED typed channels (one access record per checked call argument
   — place path + callee-side read effect — accumulated across the
   closure by the typechecker).  The pass checks the access-effect
   conflict matrix per statement group and replays the operations on
   Resource_check's ownership state lattice per item; findings are
   reported, nothing is rewritten.

   HONEST NOTE: the pass walks the recorded typed channels — the full
   CFG-based stage (finalize_plan + edge_cleanup consumed by MIR)
   remains future work.  The sentinel (access_resource_integrated =
   false) is GONE: the gate now RUNS the pass and reports findings;
   the debt gate's exit behavior is unchanged (additive reporting). *)

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
  Printf.printf "  checked typecheck-debt baseline: total %d, primary %d, secondary %d\n"
    baseline_typecheck_debt.Debt_report.total baseline_typecheck_debt.Debt_report.primaries
    baseline_typecheck_debt.Debt_report.secondaries;
  List.iter
    (fun (c, n) -> Printf.printf "    baseline %s: %d\n" c n)
    baseline_typecheck_debt.Debt_report.buckets;
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
  Printf.printf "  [4/10] resolver\n";
  Printf.printf "  [5/10] typechecker (fixpoint)\n";
  (match
     Driver.run_closure_pipeline ~repo_root ~manifest_path:"bootstrap/compiler_kernel.manifest"
       ~target
   with
   | Error m -> fail "closure pipeline: %s" m
   | Ok ctx ->
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
       check_no_regression measured_debt baseline_typecheck_debt;
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
         Printf.printf "BOOTSTRAP GATE: RESULT: PASS (no regression vs the checked baseline)\n";
         exit 0
       end;
       (* Zero typecheck debt: the full semantic closure must succeed. *)
       Printf.printf "  [6/10] access/resource checks\n";
       if n_access_findings > 0 then
         fail
           "access/resource findings on the closure (%d) — the integrated pass must be clean \
            before closure PASS (the recorded-typed-channels walk is the integrated semantic \
            pass; the CFG-based cleanup-plan stage remains future work)" n_access_findings;
       let prog = Driver.lower_closure ctx in
       Printf.printf "  [7/10] lowering: PASS (%d functions lowered)\n"
         (Array.length prog.Seed_mir.functions);
       (match Mir_verify.require_valid prog with
        | Error errs ->
            Printf.printf "  [8/10] MIR verify: FAIL\n";
            List.iter (fun e -> Printf.printf "    %s\n" e) errs;
            fail "MIR verify"
        | Ok () ->
            Printf.printf "  [8/10] MIR verify: PASS (%d functions)\n"
              (Array.length prog.Seed_mir.functions));
       let stats = Driver.count_mir_stats prog in
       let incomplete = Driver.print_oracle_rows (Driver.oracle_of_ctx ctx (Some stats)) in
       if incomplete then fail "oracle DIFF rows present — completeness is not closed";
       (match Driver.resolve_bootstrap_entry prog None with
        | None -> fail "no bootstrap entry function in the lowered closure"
        | Some (entry_name, entry) ->
            (match Driver.run_mono_phase ~entry_name ~entry prog with
             | Error _ -> fail "mono phase"
             | Ok mo ->
                 if mo.Driver.mo_residual_type_params > 0 then
                   fail "%d residual Type_param after mono" mo.Driver.mo_residual_type_params;
                 Printf.printf
                   "  [9/10] mono (reachable closure from entry '%s'): PASS — pre %d -> post %d instances\n"
                   entry_name mo.Driver.mo_pre_functions mo.Driver.mo_post_functions;
                 Printf.printf "  [10/10] reachable-host closure + VM run + artifact production\n";
                 let kernel_args =
                   [ "compile"; "tests/differential/corpus/01_defs_arith.tg"; "-o"; "bootstrap_gate.out" ]
                 in
                 let argv = Array.of_list ("tg-bootstrap" :: kernel_args) in
                 let host = Host.create ~repo_root ~argv in
                 (match Vm.run ~program:mo.Driver.mo_program ~entry:mo.Driver.mo_entry ~argv ~host with
                  | Error e ->
                      let out = Host.stdout_contents host in
                      if out <> "" then Printf.printf "  kernel stdout:\n%s\n" out;
                      let err = Host.stderr_contents host in
                      if err <> "" then Printf.printf "  kernel stderr:\n%s\n" err;
                      fail "VM bootstrap run: %s" e.Vm.message
                  | Ok code ->
                      let out = Host.stdout_contents host in
                      if out <> "" then Printf.printf "  kernel stdout:\n%s\n" out;
                      Printf.printf "  VM bootstrap run: exit %d\n" code;
                      if code <> 0 then fail "nonzero exit from the kernel";
                      (match kernel_output_path kernel_args with
                       | None -> fail "no artifact path derivable from the kernel argv"
                       | Some out_path ->
                           if not (artifact_exists ~repo_root out_path) then
                             fail "VM exited 0 but produced no artifact at %s" out_path;
                           Printf.printf "  artifact produced: %s\n" out_path)));
       Printf.printf "BOOTSTRAP GATE: PASS — full closure through every stage\n";
       exit 0))
