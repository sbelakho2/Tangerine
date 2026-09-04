(* tg_evidence.ml — deterministic per-phase pipeline evidence record.

   Calls the SAME canonical closure entry the driver's bootstrap-check /
   compile use — Driver.run_closure_pipeline (src/driver.ml) — and
   serializes the resulting closure_ctx.  ONE implementation, ONE
   measurement: the evidence typecheck count, the debt report and the
   phase counts come from the driver's own closure pipeline (manifest ->
   fingerprint -> module graph -> @cfg elimination -> resolver -> the
   declaration fixpoint + one body pass), NOT from a locally replicated
   pipeline.  The driver's helpers print their detail lines to stdout
   (manifest, module graph, @cfg, resolver, identity handoff, the
   accumulated debt blocks); the last debt block printed by
   Typecheck.record_module_debt is the closure's final debt report and is
   serialized here from the ctx's own accumulated accounting
   (ctx_env.state.debt_by_module), so the evidence lines are exactly the
   pipeline's numbers.

   Serialized from the closure_ctx:
     manifest fingerprint (re-verified from the canonical sequence)
     graph modules / item count (ctx_graph — the post-@cfg graph the
       resolver/typechecker measure)
     resolver counts (ctx_resolved)
     typecheck errors / items (ctx_type_errors, ctx_items)
     declaration fixpoint iterations + body passes (ctx_decl_rounds:
       the driver's MEASURED declaration-fixpoint iteration counter from
       run_closure_pipeline's fixpoint loop — re-audit finding 2, no
       hard-coded 2; the body pass runs exactly once — audit Fix 3
       deterministic phase split)
     the real debt report: per-category buckets, total, primaries,
       secondaries (the pipeline's accumulated debt_by_module)
     the lowering/mono gates the driver itself would run (lower_closure,
       Mono.build, residual Type_param walk, Mir_verify — the same
       helpers bootstrap-check uses; skipped when the typecheck gate
       failed, exactly as the driver skips them)

   Emits one `evidence <phase> ...` line per phase on stdout, in a fixed
   order, byte-identical across runs EXCEPT the run= line (unix epoch
   seconds), and exits 0 even when the gates fail (evidence is recorded,
   not gated).

   Phase fingerprint contract: every line is a canonical, order-stable
   hash/count.  The Swift seed (stage1-S) is expected to emit the
   equivalent lines for its own pipeline; the audit's Swift->OCaml
   migration comparison requires the phase fingerprints to MATCH between
   seeds for equivalent phases — the manifest line in particular, because
   both seeds consume the same bootstrap/compiler_kernel.manifest closure.

   Usage: tg_evidence.exe <repo-root>  (defaults to ".." when omitted). *)

let die fmt = Printf.ksprintf (fun s -> prerr_endline ("tg_evidence: " ^ s); exit 1) fmt

let repo_root =
  match Array.to_list Sys.argv with _ :: r :: _ -> r | _ -> ".."

let manifest_path = "bootstrap/compiler_kernel.manifest"

(* ── manifest -> fingerprint ────────────────────────────────────── *)

let manifest =
  match Bootstrap_manifest.load ~repo_root ~manifest_path with
  | Error m -> die "manifest load: %s" m
  | Ok m -> m

(* The evidence fingerprint is the loaded record's fingerprint, which is
   SHA-256 over the canonical manifest sequence (src/bootstrap_manifest.ml
   fingerprint_of): manifest content, "\n\000", version, "\n\000", then per
   entry in manifest order, '\000'-separated: logical module path, '\001',
   relative source path, '\001', source byte length, '\001', source SHA-256.
   Recompute it here with Sha256 to prove the evidence value is exactly the
   canonical-sequence hash (and that the loaded record agrees). *)
let verify_canonical_fingerprint (m : Bootstrap_manifest.t) (content : string) : bool =
  let buf = Buffer.create (String.length content + 64) in
  Buffer.add_string buf content;
  Buffer.add_string buf "\n\000";
  Buffer.add_string buf (match Bootstrap_manifest.version_of m with Some v -> v | None -> "");
  Buffer.add_string buf "\n\000";
  List.iteri
    (fun i e ->
      if i > 0 then Buffer.add_char buf '\000';
      Buffer.add_string buf (String.concat "::" e.Bootstrap_manifest.path);
      Buffer.add_char buf '\001';
      Buffer.add_string buf e.Bootstrap_manifest.file;
      Buffer.add_char buf '\001';
      Buffer.add_string buf (string_of_int (String.length e.Bootstrap_manifest.source));
      Buffer.add_char buf '\001';
      Buffer.add_string buf e.Bootstrap_manifest.source_hash)
    (Bootstrap_manifest.entries m);
  Sha256.digest (Buffer.contents buf) = Bootstrap_manifest.fingerprint m

let () =
  let manifest_content =
    let p =
      if Filename.is_relative manifest_path then Filename.concat repo_root manifest_path
      else manifest_path
    in
    match Source_loader.load p with
    | Error _ -> die "cannot re-read manifest for fingerprint verification: %s" p
    | Ok s -> s.Source.bytes
  in
  let fp = Bootstrap_manifest.fingerprint manifest in
  if not (verify_canonical_fingerprint manifest manifest_content) then
    die "fingerprint mismatch: canonical-sequence SHA-256 differs from the loaded record";
  Printf.printf "evidence manifest=%s\n" fp;

  (* ── the driver's canonical closure pipeline (bootstrap-check parity) *)
  let target =
    match Target.unsupported_triple "aarch64-apple-darwin" with
    | Error m -> die "target: %s" m
    | Ok t -> t
  in
  match
    Driver.run_closure_pipeline ~repo_root ~manifest_path ~target
  with
  | Error m -> die "closure pipeline: %s" m
  | Ok ctx ->
      let graph = ctx.Driver.ctx_graph in
      Printf.printf "evidence graph modules=%d items=%d\n" graph.Module_graph.node_count
        graph.Module_graph.item_count;
      let n_entries = List.length (Bootstrap_manifest.entries manifest) in
      let expr = List.length ctx.Driver.ctx_resolved.Resolver.expr_defs in
      let type_ = List.length ctx.Driver.ctx_resolved.Resolver.type_defs in
      let field = List.length ctx.Driver.ctx_resolved.Resolver.field_defs in
      let variant = List.length ctx.Driver.ctx_resolved.Resolver.variant_defs in
      let calls = List.length ctx.Driver.ctx_resolved.Resolver.call_candidates in
      Printf.printf "evidence resolver entries=%d defs=%d expr=%d type=%d field=%d variant=%d calls=%d\n"
        n_entries (expr + type_ + field + variant) expr type_ field variant calls;

      (* ── the ctx's own typecheck measurement ───────────────────── *)
      let n_errors = List.length ctx.Driver.ctx_type_errors in
      (* ctx_items is the driver's file-deduped item count (what
         bootstrap-check prints: "typecheck: 56 modules, 4496 items,
         N errors (2 rounds)").  The graph line above is the closure_ctx
         graph — the POST-@cfg graph the resolver and typechecker
         measure (the driver's raw "module graph:" line prints the
         pre-@cfg count including eliminated items). *)
      Printf.printf "evidence typecheck errors=%d items=%d\n" n_errors ctx.Driver.ctx_items;
      (* Phase counts (re-audit finding 2): the closure_ctx carries the
         driver's MEASURED declaration-fixpoint iteration count
         (ctx_decl_rounds = !decl_rounds from run_closure_pipeline's
         fixpoint loop — the hard-coded 2 is gone; audit Fix 3 split the
         old retry loop into declare-to-fixpoint then check bodies
         exactly once against the frozen env).  Reported as
         declaration_fixpoint_iterations = ctx_decl_rounds and
         body_passes = 1, the audit's semantic. *)
      Printf.printf "evidence declaration_fixpoint_iterations=%d body_passes=1\n"
        ctx.Driver.ctx_decl_rounds;

      (* ── the real debt report (per-category, total, primaries,
            secondaries): the pipeline's OWN accumulated accounting
            (Typecheck.state.debt_by_module — what
            Typecheck.record_module_debt prints block by block; the last
            printed block is the closure's final debt report).  NOT a
            re-classification of the driver's flattened error list: the
            driver prepends "<module>: " to every error, which would
            hide the "[secondary] " prefix and misreport the
            primary/secondary split. *)
      let debt =
        Debt_report.sum_reports
          (List.map snd ctx.Driver.ctx_env.Typecheck.state.debt_by_module)
      in
      List.iter
        (fun (c, n) -> Printf.printf "evidence debt_%s=%d\n" c n)
        debt.Debt_report.buckets;
      Printf.printf "evidence debt_total=%d debt_primary=%d debt_secondary=%d\n"
        debt.Debt_report.total debt.Debt_report.primaries debt.Debt_report.secondaries;

      (* ── lowering + mono counts (the driver's own helpers; skipped
            when the typecheck gate failed, as the driver skips them) *)
      let frontend = if n_errors = 0 then "PASS" else "FAIL" in
      let structural, mono_gate, pre, post, residual =
        if n_errors = 0 then begin
          let prog = Driver.lower_closure ctx in
          let query_sigs =
            Driver.closure_query_sigs ~lowered:(Some prog) ctx.Driver.ctx_env
          in
          let registered_only (c : Ids.Callable_id.t) : int option =
            List.find_opt
              (fun (q : Mir_verify.query_sig) ->
                Ids.Callable_id.compare q.Mir_verify.qs_callable c = 0)
              query_sigs
            |> Option.map (fun q -> Array.length q.Mir_verify.qs_decl)
          in
          match Mir_verify.require_valid prog with
          | Error _ -> ("FAIL", "SKIPPED", 0, 0, 0)
          | Ok () -> (
              match Driver.resolve_bootstrap_entry prog None with
              | None -> ("PASS", "SKIPPED", 0, 0, 0)
              | Some (_, entry) -> (
                  match Mono.build ~entry ~registered_only prog with
                  | Error _ -> ("PASS", "FAIL", Array.length prog.Seed_mir.functions, 0, 0)
                  | Ok fns ->
                      let mono_prog = { prog with Seed_mir.functions = fns } in
                      let pre = Array.length prog.Seed_mir.functions in
                      let post = Array.length fns in
                      let residual = Driver.count_residual_type_params mono_prog in
                      (match
                         Mir_verify.require_valid_concrete ~query_sigs mono_prog
                       with
                       | Error _ -> ("PASS", "FAIL", pre, post, residual)
                       | Ok () -> ("PASS", "PASS", pre, post, residual))))
        end
        else ("SKIPPED", "SKIPPED", 0, 0, 0)
      in
      Printf.printf "evidence mono pre=%d post=%d residual=%d skipped=%d\n" pre post residual
        (if n_errors = 0 then 0 else 1);
      Printf.printf "evidence gates frontend=%s structural=%s mono=%s\n" frontend structural mono_gate;

      (* ── run stamp (the only non-deterministic line) ───────────── *)
      Printf.printf "evidence run=%d\n" (int_of_float (Unix.time ()));
      exit 0
