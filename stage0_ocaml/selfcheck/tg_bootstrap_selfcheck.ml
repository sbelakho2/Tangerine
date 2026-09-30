(* tg_bootstrap_selfcheck.ml — the standalone self-host preflight.

   The cheapest gate that proves the KERNEL (as produced by the seed from
   the manifest closure) can consume its own stage1 source graph:

     seed closure pipeline (front end -> lower -> mono -> reachable-host)
       -> prepared kernel runs in the seed VM
       -> kernel executes
            `check --strict-resolution --bootstrap-proof --stop-after=mono
             tg_compiler/bootstrap_main.tg`
       -> the check stops after MONO + the type-query fold + the post-mono
          MIR verify + the post-mono completeness oracle (NO optimizer,
          codegen or link)
       -> kernel prints
            TG_CHECK_OK file=... stop=mono manifest_entries=45
                        unique_sources=45 modules=45 items=...
       -> VM exits 0

   Exit 0 of the kernel check is the strict-resolution proof: the kernel
   fails closed on any resolver/type/MIR/post-mono diagnostic, so exit 0
   subsumes "resolver diagnostics 0, type diagnostics 0" at the MONO
   depth.  The preflight then additionally requires the machine-readable
   summary to name stop=mono and tg_compiler/bootstrap_main.tg, and to
   report EXACTLY the same manifest_entries / unique_sources / modules
   counts (the recorded stage1 closure: 45 sources), so a stale kernel or
   a different input can never false-green.  The proof line is emitted
   only under --bootstrap-proof (ordinary `check` never carries proof
   output).

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

(* The manifest authority: exact entry count + the seed fingerprint the
   kernel's closure_sha256 must equal. *)
let manifest_authority ~(repo_root : string) : int * string =
  match
    Bootstrap_manifest.load ~repo_root
      ~manifest_path:"bootstrap/compiler_kernel.manifest"
  with
  | Ok m ->
      ( List.length (Bootstrap_manifest.entries m),
        Bootstrap_manifest.fingerprint m )
  | Error m -> fail "cannot load the kernel manifest: %s" m

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
  let rec parse args repo_root target no_cache =
    match args with
    | "--repo-root" :: r :: rest -> parse rest r target no_cache
    | "--target" :: t :: rest -> parse rest repo_root t no_cache
    | "--no-cache" :: rest -> parse rest repo_root target true
    | _ :: rest -> parse rest repo_root target no_cache
    | [] -> (repo_root, target, no_cache)
  in
  let default_target =
    match Sys.getenv_opt "TG_BOOTSTRAP_TARGET" with
    | Some t -> t
    | None -> "aarch64-apple-darwin"
  in
  let repo_root, target_str, no_cache =
    match Array.to_list Sys.argv with
    | _ :: args -> parse args ".." default_target false
    | [] -> ("..", default_target, false)
  in
  ensure_dir (Filename.concat repo_root "build");
  let target =
    match Target.unsupported_triple target_str with
    | Error m -> fail "target: %s" m
    | Ok t -> t
  in
  Printf.printf
    "TG SELF-HOST PREFLIGHT (kernel in the seed VM checks tg_compiler/bootstrap_main.tg)\n%!";
  let manifest_count, manifest_fingerprint = manifest_authority ~repo_root in
  if manifest_count <> expected_manifest_sources then
    fail
      "manifest closure size changed: bootstrap/compiler_kernel.manifest lists %d sources, the \
       recorded stage1 closure is %d — update expected_manifest_sources deliberately (and every \
       pinned count) when the kernel closure grows"
      manifest_count expected_manifest_sources;
  Printf.printf "  manifest closure: %d source(s) [pinned]\n%!" manifest_count;
  let cache_path = Filename.concat repo_root "build/bootstrap_selfcheck.vmcache" in
  let vm_cache = if no_cache then None else Some cache_path in
  let kernel_args =
    [ "check"; "--strict-resolution"; "--bootstrap-proof"; "--stop-after=mono";
      "tg_compiler/bootstrap_main.tg"; "--target"; target_str ]
  in
  match
    Driver.run_bootstrap_vm ~repo_root
      ~manifest_path:"bootstrap/compiler_kernel.manifest" ~target ~entry:None
      ~kernel_args ?vm_cache ()
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
              (match summary_field row "stop" with
              | Some v when v = "mono" -> ()
              | Some v ->
                  fail
                    "kernel preflight stopped at `%s`, the final authorization requires the                      mono stop (--stop-after=mono)"
                    v
              | None -> fail "kernel summary has no stop= field: %s" row);
              (match summary_field row "file" with
              | Some f when f = "tg_compiler/bootstrap_main.tg" -> ()
              | Some f ->
                  fail "kernel summary checked `%s`, not `tg_compiler/bootstrap_main.tg`" f
              | None -> fail "kernel summary has no file= field: %s" row);
              (* P0 dedup invariant: manifest_entries, unique_sources and
                 modules must all equal the manifest authority's size (a
                 duplicated root historically made modules=46 while the
                 summary claimed 45 sources). *)
              (match summary_field row "manifest_entries" with
              | Some v when int_of_string_opt v = Some expected_manifest_sources -> ()
              | Some v ->
                  fail "kernel reports manifest_entries=%s, the manifest closure is %d" v
                    expected_manifest_sources
              | None -> fail "kernel summary has no manifest_entries= field: %s" row);
              (match summary_field row "unique_sources" with
              | Some v when int_of_string_opt v = Some expected_manifest_sources -> ()
              | Some v ->
                  fail
                    "kernel consumed %s unique source(s), the manifest closure is %d — the                      kernel did not load the exact stage1 source graph (duplicate root?)"
                    v expected_manifest_sources
              | None -> fail "kernel summary has no unique_sources= field: %s" row);
              (match summary_field row "modules" with
              | Some v when int_of_string_opt v = Some expected_manifest_sources -> ()
              | Some v ->
                  fail "kernel merged %s module(s), the deduplicated closure is %d" v
                    expected_manifest_sources
              | None -> fail "kernel summary has no modules= field: %s" row);
              (match summary_field row "closure_sha256" with
              | Some fp when fp = manifest_fingerprint -> ()
              | Some fp ->
                  fail
                    "kernel closure_sha256=%s, the seed fingerprint is %s — the guest did not \
                     process the exact seed closure bytes"
                    fp manifest_fingerprint
              | None -> fail "kernel summary has no closure_sha256= field: %s" row);
              Printf.printf
                "tg_bootstrap_selfcheck: OK — kernel check exit 0 over the exact %d-source \
                 manifest closure (strict resolution; resolver 0, type 0; stop after MONO; \
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
