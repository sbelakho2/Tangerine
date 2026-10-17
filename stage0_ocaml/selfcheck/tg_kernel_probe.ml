(* tg_kernel_probe.ml — NON-AUTHORIZING diagnostic runner.

   Loads the prepared kernel VM program from
   build/bootstrap_selfcheck.vmcache (the same artifact the self-host
   preflight executes) and runs it with ARBITRARY kernel arguments.  This
   exists only to shorten the resource-checker edit loop: a small source
   file can be `check`ed by the exact kernel build in seconds instead of
   re-running the whole 45-source closure.

   It is NOT evidence: it emits no PASS sentinel and is never invoked by
   the bootstrap gate, the ladder, or CI.

   Usage:
     tg_kernel_probe.exe --repo-root .. --target TARGET -- <kernel args...> *)

let fail fmt = Printf.ksprintf (fun s -> prerr_endline ("kernel-probe: " ^ s); exit 2) fmt

let () =
  let rec parse args repo_root target stale kernel_args =
    match args with
    | "--repo-root" :: r :: rest -> parse rest r target stale kernel_args
    | "--target" :: t :: rest -> parse rest repo_root t stale kernel_args
    | "--stale" :: rest -> parse rest repo_root target true kernel_args
    | "--" :: rest -> (repo_root, target, stale, rest)
    | a :: rest -> parse rest repo_root target stale (kernel_args @ [ a ])
    | [] -> (repo_root, target, stale, kernel_args)
  in
  let repo_root, target_str, stale, kernel_args =
    match Array.to_list Sys.argv with
    | _ :: args -> parse args ".." "aarch64-apple-darwin" false []
    | [] -> ("..", "aarch64-apple-darwin", false, [])
  in
  if kernel_args = [] then fail "no kernel arguments (usage: ... -- <kernel args>)";
  let target =
    match Target.unsupported_triple target_str with
    | Ok t -> t
    | Error m -> fail "target: %s" m
  in
  let path = Filename.concat repo_root "build/bootstrap_selfcheck.vmcache" in
  let fingerprint =
    match Driver.vm_cache_fingerprint ~repo_root
            ~manifest_path:"bootstrap/compiler_kernel.manifest" with
    | Some fp -> fp
    | None -> fail "cannot fingerprint the kernel manifest"
  in
  let loaded =
    match
      Driver.vm_cache_load ~path ~fingerprint
        ~target:(Target.to_string target) ~entry:None
    with
    | Some v -> Some v
    | None when stale ->
        (try
           let ic = open_in_bin path in
           let c : Driver.vm_program_cache = Marshal.from_channel ic in
           close_in ic;
           Some (c.Driver.vpc_program, c.Driver.vpc_entry_instance, c.Driver.vpc_lang_items)
         with _ -> None)
    | None -> None
  in
  match loaded with
  | None ->
      fail
        "no usable prepared-kernel cache at %s (fingerprint %s) — rebuild it with tg_bootstrap_selfcheck.exe --no-cache (slow)"
        path fingerprint
  | Some (program, entry, lang_items) ->
      let run =
        Driver.run_prepared_vm ~repo_root ~kernel_args ~program ~entry
          ~lang_items ~cache_hit:true ~target
      in
      (match run.Driver.bvr_vm_code with
       | Some code -> Printf.printf "kernel exit: %d\n" code
       | None ->
           Printf.printf "kernel trap: %s\n"
             (Option.value ~default:"(no code)" run.Driver.bvr_trap));
      if run.Driver.bvr_stdout <> "" then
        Printf.printf "--- kernel stdout ---\n%s\n" run.Driver.bvr_stdout;
      if run.Driver.bvr_stderr <> "" then
        Printf.printf "--- kernel stderr ---\n%s\n" run.Driver.bvr_stderr;
      match run.Driver.bvr_vm_code with Some 0 -> exit 0 | _ -> exit 1
