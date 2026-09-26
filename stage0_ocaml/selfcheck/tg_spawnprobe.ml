(* tg_spawnprobe.ml — focused regression for the seed VM's child-process
   boundary (fork/execvp/pipe/poll/read/waitpid), the same std::process
   path the kernel's codesign step uses.

   The probe stage0_ocaml/selfcheck/spawnprobe.tg runs `/bin/echo`, a
   `/bin/sh -c` command that writes to stderr and exits 7, and
   `/usr/bin/codesign --verify <missing>` through the REAL
   std::process::run_command, then returns 0 only when:
     - echo: status 0 and stdout captured;
     - sh:   nonzero status and the stderr text captured (VME);
     - codesign: nonzero status and codesign's own non-empty stderr.

   An empty error detail (the kernel-native `codesign failed: ` shape)
   fails this lane.  The full per-command evidence is written by the
   probe to build/spawnprobe_report.txt and repeated here on failure. *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_spawnprobe: FAIL: %s\n" s;
      exit 1)
    fmt

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let () =
  let repo_root =
    match Array.to_list Sys.argv with _ :: r :: _ -> r | _ -> ".."
  in
  let target =
    match Target.unsupported_triple "aarch64-apple-darwin" with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  match
    Driver.run_bootstrap_closure ~repo_root
      ~manifest_path:"bootstrap/spawnprobe_mini.manifest" ~target
      ~entry:(Some "main") ~kernel_args:[ "spawnprobe" ]
  with
  | Error m -> fail "closure pipeline: %s" m
  | Ok stages -> (
      let report_path =
        Filename.concat repo_root "build/spawnprobe_report.txt"
      in
      (match stages.Driver.bs_vm_code with
      | Some 0 ->
          Printf.printf
            "tg_spawnprobe: PASS — echo/stdout, sh/stderr-exit7 and codesign/stderr all crossed the seed VM's process boundary\n";
          exit 0
      | Some code ->
          if Sys.file_exists report_path then
            Printf.printf "spawnprobe report:\n%s"
              (read_file report_path);
          fail
            "probe main returned %d — a process-boundary check failed (see the report above)"
            code
      | None ->
          if Sys.file_exists report_path then
            Printf.printf "spawnprobe report:\n%s"
              (read_file report_path);
          fail
            "the VM run did not complete (the trap text is printed above): the process boundary failed"))
