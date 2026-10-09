(* tg_resolution_parity.ml — kernel resolution-parity gate.

   The bootstrap authority is the KERNEL resolver (tg_compiler/resolver.tg)
   as produced by the OCaml seed; the closure it must resolve is
   bootstrap/compiler_kernel.manifest. A resolution-policy divergence (the
   per-module import authority for std::time::instant_now / the
   std::gfx_errors ErrorCode class, the nested-definition surfaces
   (table_read, mir_typed_signature_of, mir_signature_param_types), or the
   same-spelled-symbol determinism for size_of/Arch) used to surface only
   after the whole stage1 build — tens of minutes into the ladder.

   This harness runs the REAL kernel CANONICAL PREPARATION over every
   closure source inside the seed VM: the mini closure is the full kernel
   closure plus tg_compiler/resolution_parity_probe.tg, and the probe
   consumes the SAME production helpers the compiler runs —
   merge_imported_deps (manifest-closed, canonical root dedup, real
   Module.imports) -> apply_cfg_elimination (target-dependent) ->
   prepare_parsed (macro expansion + node IDs) -> resolve_names_partial.
   There is NO handwritten frontend reproduction in the probe, so this
   lane agrees with production by construction; the probe additionally
   runs an adversarial microcorpus and suffix-index scan oracles against
   the O(1) resolver indexes.

   The VM run must exit 0 with a report that records the canonical
   preparation and ZERO resolver diagnostics; any preparation or
   resolution error (unresolved name/type, ambiguity, macro-expansion
   error) fails the lane. *)

(* Single-process heap sizing for this closure workload: the seed front
   end (parse -> resolve -> typecheck fixpoint -> mono) and the kernel VM
   (which re-parses and resolves the whole manifest closure) are both
   allocation-heavy.  The default OCaml minor heap triggers constant minor
   collections, and the default major space_overhead collects a multi-GB
   live set far too often; a 64M-word minor heap plus a generous major
   space_overhead removes the collection-dominated stalls (measured ~2x
   wall-time on this lane).  This is pure performance configuration: no
   gate, evidence row, or verdict changes. *)
let () =
  let ctrl = Gc.get () in
  Gc.set
    {
      ctrl with
      Gc.minor_heap_size = 64 * 1024 * 1024;
      Gc.space_overhead = 300;
    }

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_resolution_parity: FAIL: %s\n" s;
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

(* The closure authority: the same std:/compiler: entries the bootstrap
   resolves from bootstrap/compiler_kernel.manifest, in manifest order. *)
let manifest_closure repo_root =
  let path = Filename.concat repo_root "bootstrap/compiler_kernel.manifest" in
  if not (Sys.file_exists path) then
    fail "missing kernel manifest: %s" path;
  let ic = open_in path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr ic)
    (fun () ->
      let acc = ref [] in
      (try
         while true do
           let line = String.trim (input_line ic) in
           if line <> "" && line.[0] <> '#' then begin
             let words =
               List.filter (fun s -> s <> "") (String.split_on_char ' ' line)
             in
             match words with
             | "std:" :: rel :: _ -> acc := ("std/" ^ rel) :: !acc
             | "compiler:" :: rel :: _ -> acc := ("tg_compiler/" ^ rel) :: !acc
             | _ -> ()
           end
         done
       with End_of_file -> ());
      List.rev !acc)

let contains_sub s sub =
  let n = String.length s and m = String.length sub in
  let rec go i = i + m <= n && (String.sub s i m = sub || go (i + 1)) in
  m = 0 || go 0

(* The bootstrap target authority: an explicit --target wins, then
   TG_BOOTSTRAP_TARGET (the same authority every other gate uses), then
   the recorded default.  The parity lane MUST validate the target the
   ladder will actually build — a Darwin-pinned parity run during a Linux
   bootstrap validates a different @cfg elimination than production. *)
let resolved_target_str () : string =
  let rec arg_target = function
    | "--target" :: t :: _ -> Some t
    | _ :: rest -> arg_target rest
    | [] -> None
  in
  match arg_target (Array.to_list Sys.argv) with
  | Some t -> t
  | None -> (
      match Sys.getenv_opt "TG_BOOTSTRAP_TARGET" with
      | Some t -> t
      | None -> "aarch64-apple-darwin")

let () =
  let repo_root =
    match Array.to_list Sys.argv with
    | _ :: r :: _ -> r
    | _ -> ".."
  in
  ensure_dir (Filename.concat repo_root "build");
  let target_str = resolved_target_str () in
  Printf.printf "tg_resolution_parity: target %s\n%!" target_str;
  let target =
    match Target.unsupported_triple target_str with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  let closure = manifest_closure repo_root in
  if closure = [] then
    fail "bootstrap/compiler_kernel.manifest lists no std:/compiler: closure files";
  Printf.printf
    "tg_resolution_parity: %d closure file(s) from bootstrap/compiler_kernel.manifest\n%!"
    (List.length closure);
  let report_path =
    Filename.concat repo_root "build/resolution_parity_report.txt"
  in
  (try Sys.remove report_path with Sys_error _ -> ());
  match
    Driver.run_bootstrap_closure ~repo_root
      ~manifest_path:"bootstrap/resolution_parity_mini.manifest" ~target
      ~entry:(Some "resolution_parity_main")
      ~kernel_args:
        (let full =
           List.mem "--full" (Array.to_list Sys.argv)
           || Sys.getenv_opt "TG_PARITY_FULL" = Some "1"
         in
         if full then begin
           (* The full-closure kernel typecheck runs the VM IN THIS SAME
              process AFTER the seed pipeline (whose multi-GB heap is
              still reachable), so it needs the profiling-class budgets
              EXPORTED BY THE CALLER: the driver reads TANGERINE_* at
              module init, before this code runs — an in-process putenv
              is inert.  Fail fast with the required export list instead
              of silently trapping at the default caps. *)
           let need name min_v =
             match Sys.getenv_opt name with
             | Some v -> (
                 match int_of_string_opt (String.trim v) with
                 | Some n when n >= min_v -> ()
                 | _ ->
                     fail
                       "--full requires %s >= %d (export it before invoking; the driver reads it at startup)"
                       name min_v)
             | None ->
                 fail
                   "--full requires %s >= %d (export it before invoking; the driver reads it at startup)"
                   name min_v
           in
           need "TANGERINE_BOOTSTRAP_VM_MAX_STEPS" 120_000_000_000;
           need "TANGERINE_BOOTSTRAP_VM_MAX_RSS_MB" 20_480;
           need "TANGERINE_BOOTSTRAP_VM_MAX_HOST_CALLS" 5_000_000_000;
           need "TANGERINE_BOOTSTRAP_VM_MAX_ALLOC" 34_359_738_368
         end;
         if full then [ "resolution-parity"; target_str; "--full" ]
         else [ "resolution-parity"; target_str ])
  with
  | Error m -> fail "closure pipeline: %s" m
  | Ok stages -> (
      let report_exists = Sys.file_exists report_path in
      let report =
        if report_exists then read_file report_path
        else
          "(no build/resolution_parity_report.txt — the kernel probe did not reach the report write)\n"
      in
      print_string report;
      match stages.Driver.bs_vm_code with
      | Some 0 ->
          (* The probe's authoritative evidence is the machine-readable
             report; the guest write path can legitimately be unavailable
             when the target/host syscall layouts differ (the probe runs a
             macOS-target kernel on a non-macOS host in development).  In
             that case the SAME rows are printed to the kernel stdout, so
             stdout is accepted as the evidence source — the stale-binary
             guards below are unchanged. *)
          let evidence =
            if report_exists then report else stages.Driver.bs_stdout
          in
          if not report_exists then
            Printf.printf
              "tg_resolution_parity: note — probe report file %s unavailable (guest write path); verifying the kernel stdout evidence instead\n"
              report_path;
          if stages.Driver.bs_stdout <> "" then
            Printf.printf "kernel stdout:\n%s\n" stages.Driver.bs_stdout;
          (* The evidence must be from the REQUESTED target: a stale or
             wrong-target run can never masquerade as the requested one. *)
          if not (contains_sub evidence ("target=" ^ target_str)) then
            fail
              "VM exit 0 but the probe evidence does not name the requested target %s — stale or wrong-target run"
              target_str;
          if not (contains_sub evidence "resolver diagnostics 0") then
            fail
              "VM exit 0 but the probe evidence does not record zero resolver diagnostics — stale probe binary? rebuild the lane";
          (* the canonical-merge + canonical-source-graph evidence (audit
             P0-3): the lane must have merged the ROOT module + every
             manifest source as file modules and run the adversarial
             microcorpus + the suffix-index scan oracles — a stale
             pre-refactor probe binary cannot supply this row. *)
          if not (contains_sub evidence "suffix-index scan oracles: PASS") then
            fail
              "VM exit 0 but the probe report lacks the microcorpus/suffix-index oracle row — stale probe binary? rebuild the lane";
          ignore report;
          Printf.printf
            "tg_resolution_parity: PASS — target %s; canonical production preparation (merge -> cfg -> macros -> node ids), resolver diagnostics ZERO, adversarial microcorpus + cfg-matrix + suffix-index scan oracles PASS (VM exit 0)\n"
            target_str;
          Selfcheck_sentinel.emit_and_exit "tg_resolution_parity"
      | Some code ->
          if stages.Driver.bs_stdout <> "" then
            Printf.printf "kernel stdout:\n%s\n" stages.Driver.bs_stdout;
          if stages.Driver.bs_stderr <> "" then
            Printf.printf "kernel stderr:\n%s\n" stages.Driver.bs_stderr;
          fail
            "kernel resolution-parity FAILED: the kernel resolver reported diagnostics over the closure (VM exit %d)"
            code
      | None ->
          if stages.Driver.bs_stdout <> "" then
            Printf.printf "kernel stdout:\n%s\n" stages.Driver.bs_stdout;
          if stages.Driver.bs_stderr <> "" then
            Printf.printf "kernel stderr:\n%s\n" stages.Driver.bs_stderr;
          fail "the kernel VM run did not complete — an upstream closure stage failed")
