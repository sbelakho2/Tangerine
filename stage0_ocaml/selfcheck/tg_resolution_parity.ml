(* tg_resolution_parity.ml — kernel resolution-parity gate.

   The bootstrap authority is the KERNEL resolver (tg_compiler/resolver.tg)
   as produced by the OCaml seed; the closure it must resolve is
   bootstrap/compiler_kernel.manifest. A resolution-policy divergence (the
   per-module import authority for std::time::instant_now / the
   std::gfx_errors ErrorCode class, the nested-definition surfaces
   (table_read, mir_typed_signature_of, mir_signature_param_types), or the
   same-spelled-symbol determinism for size_of/Arch) used to surface only
   after the whole stage1 build — tens of minutes into the ladder.

   This harness runs the REAL kernel front end over every closure source
   inside the seed VM (bootstrap/resolution_parity_mini.manifest, whose
   tg_compiler/resolution_parity_probe.tg entry parses the manifest's
   std:/compiler: entries, merges them into one Program with the per-file
   Module table, assigns node ids, and runs resolve_names). The manifest
   paths are resolved from the same single-source manifest the bootstrap
   resolves, so the gate cannot drift from the closure.

   The VM run must exit 0 with a report that records every file parsed
   clean and ZERO resolver diagnostics; any resolution error (unresolved
   name/type, ambiguity, unsupported construct other than the known
   pre-resolution debug_assert macro artifact) fails the lane. *)

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

let () =
  let repo_root =
    match Array.to_list Sys.argv with
    | _ :: r :: _ -> r
    | _ -> ".."
  in
  ensure_dir (Filename.concat repo_root "build");
  let target =
    match Target.unsupported_triple "aarch64-apple-darwin" with
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
      ~entry:(Some "main") ~kernel_args:[ "resolution-parity" ]
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
          if not report_exists then
            fail
              "VM exit 0 but the expected probe report %s is missing — the probe did not reach the write"
              report_path;
          if not (contains_sub report "resolver diagnostics 0") then
            fail
              "VM exit 0 but the probe report does not record zero resolver diagnostics — stale probe binary? rebuild the lane";
          Printf.printf
            "tg_resolution_parity: PASS — every bootstrap/compiler_kernel.manifest source parsed clean by the kernel front end and resolve_names reported ZERO diagnostics (VM exit 0)\n";
          exit 0
      | Some code ->
          fail
            "kernel resolution-parity FAILED: the kernel resolver reported diagnostics over the closure (VM exit %d)"
            code
      | None ->
          fail "the kernel VM run did not complete — an upstream closure stage failed")
