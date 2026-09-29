(* tg_bootstrap_selfcheck.ml — the standalone self-host preflight.

   The cheapest gate that proves the KERNEL (as produced by the seed from
   the manifest closure) can consume its own stage1 source graph:

     seed closure pipeline (front end -> lower -> mono -> reachable-host)
       -> prepared kernel runs in the seed VM
       -> kernel executes `check --strict-resolution tg_compiler/bootstrap_main.tg`
       -> the check stops after MIR verification (no codegen/link)
       -> kernel prints TG_CHECK_OK file=... sources=... modules=... items=...
       -> VM exits 0

   Exit 0 of the kernel check is the strict-resolution proof: the kernel
   fails closed on any resolver/type/MIR diagnostic, so exit 0 subsumes
   "resolver diagnostics 0, type diagnostics 0".  The preflight then
   additionally requires the machine-readable summary to name
   tg_compiler/bootstrap_main.tg and to report EXACTLY the manifest
   closure size (the recorded stage1 closure: 45 sources), so a stale
   kernel or a different input can never false-green.

   This is the last test before the real bootstrap: the actual stage1
   production command happens later in run_bootstrap.sh
   (bh_ocaml_seed_compile), and this preflight exercises exactly the
   boundary that command crosses — without spending on native codegen
   and link.

   The prepared-VM cache (build/bootstrap_selfcheck.vmcache, keyed by the
   manifest closure fingerprint) makes repeated runs re-execute only the
   kernel VM stage (see Driver.run_bootstrap_vm).

   Usage: tg_bootstrap_selfcheck.exe [repo-root]
   Exit: 0 pass (exact PASS sentinel), 1 cannot-prove/failure. *)

let fail fmt =
  Printf.ksprintf
    (fun s ->
      Printf.printf "tg_bootstrap_selfcheck: FAIL: %s\n" s;
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
          fail "cannot create the output directory %s: %s" p (Unix.error_message e)
    end
  in
  go path

(* The recorded stage1 closure size (bootstrap/compiler_kernel.manifest:
   14 std + 31 compiler).  The manifest stays the single source of truth;
   this constant pins the exact size the preflight authorizes. *)
let expected_manifest_sources = 45

let manifest_closure_count ~(repo_root : string) : int =
  let path = Filename.concat repo_root "bootstrap/compiler_kernel.manifest" in
  if not (Sys.file_exists path) then fail "missing kernel manifest: %s" path;
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

let summary_field (row : string) (name : string) : string option =
  let prefix = name ^ "=" in
  match
    List.find_opt
      (fun f -> String.starts_with ~prefix f)
      (List.filter (fun s -> s <> "") (String.split_on_char ' ' row))
  with
  | None -> None
  | Some f -> Some (String.sub f (String.length prefix) (String.length f - String.length prefix))

let () =
  (* --repo-root R --target T, else the bootstrap target authority
     (TG_BOOTSTRAP_TARGET) or the recorded default.  The preflight must
     validate the target the ladder builds: @cfg elimination is
     target-parameterized, and the kernel's check runs the whole closure
     for exactly this target. *)
  let rec parse args repo_root target =
    match args with
    | "--repo-root" :: r :: rest -> parse rest r target
    | "--target" :: t :: rest -> parse rest repo_root t
    | _ :: rest -> parse rest repo_root target
    | [] -> (repo_root, target)
  in
  let default_target =
    match Sys.getenv_opt "TG_BOOTSTRAP_TARGET" with
    | Some t -> t
    | None -> "aarch64-apple-darwin"
  in
  let repo_root, target_str =
    match Array.to_list Sys.argv with
    | _ :: args -> parse args ".." default_target
    | [] -> ("..", default_target)
  in
  ensure_dir (Filename.concat repo_root "build");
  let target =
    match Target.unsupported_triple target_str with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  Printf.printf
    "TG SELF-HOST PREFLIGHT (kernel in the seed VM checks tg_compiler/bootstrap_main.tg)\n%!";
  let manifest_count = manifest_closure_count ~repo_root in
  if manifest_count <> expected_manifest_sources then
    fail
      "manifest closure size changed: bootstrap/compiler_kernel.manifest lists %d sources, the \
       recorded stage1 closure is %d — update expected_manifest_sources deliberately (and every \
       pinned count) when the kernel closure grows"
      manifest_count expected_manifest_sources;
  Printf.printf "  manifest closure: %d source(s) [pinned]\n%!" manifest_count;
  let cache_path = Filename.concat repo_root "build/bootstrap_selfcheck.vmcache" in
  let kernel_args =
    [ "check"; "--strict-resolution"; "tg_compiler/bootstrap_main.tg";
      "--target"; target_str ]
  in
  match
    Driver.run_bootstrap_vm ~repo_root
      ~manifest_path:"bootstrap/compiler_kernel.manifest" ~target ~entry:None
      ~kernel_args ~vm_cache:cache_path ()
  with
  | Error m -> fail "closure pipeline: %s" m
  | Ok run -> (
      match run.Driver.bvr_vm_code with
      | None ->
          (* Cannot prove: the closure did not reach a successful VM stage
             (typecheck debt > 0 or an upstream stage failed).  Fail
             closed; the aggregate gate prints the exact upstream state. *)
          Printf.printf
            "tg_bootstrap_selfcheck: NOT RUN — the kernel VM stage did not complete (typecheck \
             debt or an upstream closure stage failed; run tg_bootstrap_gate for the exact \
             state)\n";
          (match run.Driver.bvr_trap with
           | Some t -> Printf.printf "  trap: %s\n" t
           | None -> ());
          if run.Driver.bvr_stderr <> "" then
            Printf.printf "  kernel stderr:\n%s\n" run.Driver.bvr_stderr;
          exit 1
      | Some code when code <> 0 ->
          fail
            "kernel check of tg_compiler/bootstrap_main.tg exited %d — the kernel cannot consume \
             its own stage1 source graph\nkernel stdout:\n%s\nkernel stderr:\n%s"
            code run.Driver.bvr_stdout run.Driver.bvr_stderr
      | Some _ ->
          let rows =
            List.filter
              (fun l -> String.starts_with ~prefix:"TG_CHECK_OK " l)
              (String.split_on_char '\n' run.Driver.bvr_stdout)
          in
          (match rows with
          | [ row ] -> (
              (match summary_field row "file" with
              | Some f when f = "tg_compiler/bootstrap_main.tg" -> ()
              | Some f ->
                  fail "kernel summary checked `%s`, not `tg_compiler/bootstrap_main.tg`" f
              | None -> fail "kernel summary has no file= field: %s" row);
              (match summary_field row "sources" with
              | Some v when int_of_string_opt v = Some expected_manifest_sources -> ()
              | Some v ->
                  fail
                    "kernel consumed %s source(s), the manifest closure is %d — the kernel did \
                     not load the exact stage1 source graph"
                    v expected_manifest_sources
              | None -> fail "kernel summary has no sources= field: %s" row);
              Printf.printf
                "tg_bootstrap_selfcheck: OK — kernel check exit 0 over the exact %d-source \
                 manifest closure (strict resolution; resolver 0, type 0; stop after MIR; \
                 cache_hit=%b)\n"
                manifest_count run.Driver.bvr_cache_hit;
              Selfcheck_sentinel.emit_and_exit "tg_bootstrap_selfcheck")
          | [] ->
              fail
                "kernel exited 0 without the TG_CHECK_OK summary — refusing the false green \
                 (stale or wrong kernel binary); stdout:\n%s"
                run.Driver.bvr_stdout
          | _ ->
              fail "kernel emitted %d TG_CHECK_OK rows (exactly one expected)" (List.length rows)))
