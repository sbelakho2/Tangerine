(* tg_resolver_scale.ml — resolver bare-name scaling gate.

   The kernel resolver (tg_compiler/resolver.tg) resolves a bare name against
   the DISTINCT module-qualified definitions in SymbolTable.module_symbols.
   Before the bare-name index, every unresolved identifier materialized and
   scanned the WHOLE symbol map (bare_name_resolve), and module_path_of did
   the same per type-path, so resolution cost grew with symbols x references
   and the stage1 kernel compile exhausted the seed VM step budget inside
   bare_name_resolve.

   This lane runs the REAL kernel front end (bootstrap/
   resolver_scale_mini.manifest: lexer + parser + resolver +
   tg_compiler/resolver_scale_probe.tg) inside the seed VM. The probe
   generates a synthetic single-module program with N functions and Q bare
   call references, parses it with the kernel parser and resolves it with
   the kernel resolver, asserting every generated reference resolved.

   The run is executed under a CALIBRATED VM step budget chosen between the
   measured unindexed and indexed step counts of this fixture: a regression
   back to the full-map scan exceeds the budget (the unindexed resolver
   needs far more steps) and fails the gate, while the indexed resolver
   passes with a large margin.

   The seed reads TANGERINE_BOOTSTRAP_VM_MAX_STEPS at process start, so the
   lane re-execs itself once with the calibrated budget in the environment;
   the child process performs the actual closure run. Set
   TG_RESOLVER_SCALE_BUDGET to override the calibrated value. *)

let child_env = "TG_RESOLVER_SCALE_CHILD"

(* Calibrated for the 3000-symbol / 3-refs fixture below, seed VM, macOS
   arm64 (step counts are deterministic): the unindexed resolver measured
   3,508,430,487 steps (87,149,703 host calls), the fixed resolver
   305,390,638 steps (3,241,263 host calls). This budget sits between them:
   a regression back to the full-map scan exceeds it (3.5e9 > 1.5e9), the
   fixed resolver passes with ~4.9x headroom. *)
let default_budget = "1500000000"

let symbols = "3000"
let refs = "3"

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_resolver_scale: FAIL: %s\n" s;
      exit 1)
    fmt

let ensure_dir path =
  let rec go p =
    if p = "" || p = "." || p = "/" || Sys.file_exists p then ()
    else begin
      go (Filename.dirname p);
      try Unix.mkdir p 0o755 with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> ()
      | Unix.Unix_error (e, _, _) ->
          fail "cannot create the output directory %s: %s" p
            (Unix.error_message e)
    end
  in
  go path

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let run_probe repo_root budget =
  ensure_dir (Filename.concat repo_root "build");
  let target =
    match Target.unsupported_triple "aarch64-apple-darwin" with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  let report_path =
    Filename.concat repo_root "build/resolver_scale_report.txt"
  in
  (try Sys.remove report_path with Sys_error _ -> ());
  let kernel_args = [ "resolver-scale"; symbols; refs ] in
  let t0 = Unix.gettimeofday () in
  match
    Driver.run_bootstrap_closure ~repo_root
      ~manifest_path:"bootstrap/resolver_scale_mini.manifest" ~target
      ~entry:(Some "main") ~kernel_args
  with
  | Error m -> fail "closure pipeline: %s" m
  | Ok stages ->
      let dt = Unix.gettimeofday () -. t0 in
      let report_exists = Sys.file_exists report_path in
      let report =
        if report_exists then read_file report_path
        else
          "(no build/resolver_scale_report.txt — the kernel probe did not reach the report write)\n"
      in
      print_string report;
      (match stages.Driver.bs_vm_code with
      | Some 0 ->
          if not report_exists then
            fail
              "VM exit 0 but the expected probe report %s is missing — the probe did not reach the write"
              report_path;
          if not (String.starts_with ~prefix:"OK" report) then
            fail "probe VM exit 0 but the report is not an OK row: %s"
              (String.trim report);
          Printf.printf
            "tg_resolver_scale: PASS — %s symbols x %s refs resolved by the kernel resolver under the calibrated %s-step VM budget (wall %.1fs)\n"
            symbols refs budget dt;
          Selfcheck_sentinel.emit_and_exit "tg_resolver_scale"
      | Some code ->
          fail
            "kernel resolver scale probe FAILED: VM exit %d (see build/resolver_scale_report.txt)"
            code
      | None ->
          fail
            "the kernel VM run did not complete under the calibrated %s-step budget — a full-symbol-map resolver regression exceeds it (trap), or an upstream closure stage failed"
            budget)

let () =
  let repo_root =
    match Array.to_list Sys.argv with
    | _ :: r :: _ -> r
    | _ -> ".."
  in
  match Sys.getenv_opt child_env with
  | Some "1" ->
      let budget =
        match Sys.getenv_opt "TANGERINE_BOOTSTRAP_VM_MAX_STEPS" with
        | Some b -> b
        | None -> default_budget
      in
      run_probe repo_root budget
  | _ ->
      let budget =
        match Sys.getenv_opt "TG_RESOLVER_SCALE_BUDGET" with
        | Some b -> b
        | None -> default_budget
      in
      Printf.printf
        "tg_resolver_scale: re-exec with VM step budget %s (TANGERINE_BOOTSTRAP_VM_MAX_STEPS)\n%!"
        budget;
      Unix.putenv "TANGERINE_BOOTSTRAP_VM_MAX_STEPS" budget;
      Unix.putenv child_env "1";
      let exe =
        if Filename.is_relative Sys.executable_name then
          try Unix.realpath Sys.executable_name
          with Unix.Unix_error _ -> Sys.executable_name
        else Sys.executable_name
      in
      (try Unix.execv exe Sys.argv
       with Unix.Unix_error (e, _, _) ->
         fail "cannot re-exec %s with the calibrated VM step budget: %s" exe
           (Unix.error_message e))
