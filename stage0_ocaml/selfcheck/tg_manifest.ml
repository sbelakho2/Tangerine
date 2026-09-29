(* tg_manifest.ml — bootstrap manifest trust-root self-check.

   Asserts:
   (a) the real manifest (bootstrap/compiler_kernel.manifest, repo root
       ..) declares a supported version and its modules load;
   (b) a manifest text with no version field is rejected;
   (c) a manifest declaring an unsupported version (9999) is rejected;
   (d) Bootstrap_manifest.single returns Error when the module source
       fails to load (no fabricated empty source/hash snapshot);
   (e) a manifest registering the same logical module path twice is
       rejected (logical-path uniqueness, separate from file
       uniqueness);
   (f) the REAL manifest is the exact recorded stage-1 closure:
       45 records = 14 std + 31 compiler, bootstrap_main.tg exactly
       once (the same closure the self-host preflight asserts). *)

let fail fmt = Printf.ksprintf (fun s -> Printf.printf "FAIL: %s\n" s; exit 1) fmt

let write_file (path : string) (content : string) : unit =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)

let tmp_dir () : string =
  let d = Filename.temp_file "tg_manifest" "" in
  Sys.remove d;
  Unix.mkdir d 0o755;
  d

let expect_rejected ~(name : string) ~(repo_root : string) ~(manifest : string) =
  match Bootstrap_manifest.load ~repo_root ~manifest_path:manifest with
  | Error _ -> Printf.printf "  reject %s: PASS\n" name
  | Ok _ -> fail "manifest with %s was accepted" name

let () =
  Printf.printf "TG MANIFEST SELF-CHECK\n";
  let dir = tmp_dir () in
  let repo = Filename.concat dir "repo" in
  Unix.mkdir repo 0o755;
  Unix.mkdir (Filename.concat repo "std") 0o755;
  write_file (Filename.concat repo "std/core.tg") "def f() -> Int\n  1\nend\n";
  write_file (Filename.concat repo "std/core") "def f() -> Int\n  1\nend\n";
  let m_no_version = Filename.concat dir "no_version.manifest" in
  let m_9999 = Filename.concat dir "v9999.manifest" in
  let m_dup = Filename.concat dir "dup_path.manifest" in
  (* (b) no version field *)
  write_file m_no_version "std: core.tg\n";
  expect_rejected ~name:"missing version field" ~repo_root:repo ~manifest:m_no_version;
  (* (c) unsupported version *)
  write_file m_9999 "version: 9999\nstd: core.tg\n";
  expect_rejected ~name:"unsupported version 9999" ~repo_root:repo ~manifest:m_9999;
  (* (e) duplicate logical path (distinct files, same logical path) *)
  write_file m_dup "version: 1\nstd: core\nstd: core.tg\n";
  expect_rejected ~name:"duplicate logical module path" ~repo_root:repo ~manifest:m_dup;
  (* (a) real manifest: version accepted, modules load *)
  (match
     Bootstrap_manifest.load ~repo_root:".." ~manifest_path:"bootstrap/compiler_kernel.manifest"
   with
   | Error m -> fail "real manifest rejected: %s" m
   | Ok manifest ->
       let v =
         match Bootstrap_manifest.version_of manifest with
         | Some v -> v
         | None -> fail "real manifest has no version"
       in
       let entries = Bootstrap_manifest.entries manifest in
       let n = List.length entries in
       (* the EXACT kernel closure composition (audit P1-11 manifest
          structure): 45 records = 14 std + 31 compiler, and the kernel
          entry point exactly once.  This pins the recorded stage1
          closure the self-host preflight also asserts. *)
       if n <> 45 then
         fail "real manifest has %d entries, expected exactly 45 (14 std + 31 compiler)" n;
       let count_prefix p =
         List.length
           (List.filter
              (fun (e : Bootstrap_manifest.module_entry) ->
                String.starts_with ~prefix:p e.Bootstrap_manifest.file)
              entries)
       in
       let std_n = count_prefix "std/" in
       let compiler_n = count_prefix "tg_compiler/" in
       if std_n <> 14 then fail "real manifest has %d std entries, expected 14" std_n;
       if compiler_n <> 31 then
         fail "real manifest has %d compiler entries, expected 31" compiler_n;
       let main_n =
         List.length
           (List.filter
              (fun (e : Bootstrap_manifest.module_entry) ->
                e.Bootstrap_manifest.file = "tg_compiler/bootstrap_main.tg")
              entries)
       in
       if main_n <> 1 then
         fail "bootstrap_main.tg must appear exactly once in the kernel manifest (found %d)" main_n;
       Printf.printf
         "  real manifest version %s, %d entries (14 std + 31 compiler), bootstrap_main exactly once: PASS\n"
         v n);
  (* (d) single: source-load failure is an Error, never an empty snapshot *)
  (match
     Bootstrap_manifest.single
       ~version:(List.hd Bootstrap_manifest.supported_versions)
       ~file:(Filename.concat dir "does_not_exist.tg")
       ~path:[ "corpus"; "x" ] ()
   with
   | Error _ -> Printf.printf "  single source-load failure: PASS\n"
   | Ok m -> fail "single fabricated an empty source/hash for a missing file: %d entries" (List.length (Bootstrap_manifest.entries m)));
  (* single success carries the source snapshot and an explicit version *)
  (match
     Bootstrap_manifest.single
       ~version:(List.hd Bootstrap_manifest.supported_versions)
       ~file:(Filename.concat repo "std/core.tg") ~path:[ "std"; "core" ] ()
   with
   | Error m -> fail "single rejected a loadable source: %s" m
   | Ok m ->
       let e = List.hd (Bootstrap_manifest.entries m) in
       if e.Bootstrap_manifest.source = "" then fail "single dropped the source bytes";
       if e.Bootstrap_manifest.source_hash <> Sha256.digest e.Bootstrap_manifest.source then
         fail "single source hash mismatch";
       if Bootstrap_manifest.version_of m <> Some "1" then
         fail "single must carry an explicit supported version");
  Printf.printf "  single success carries snapshot + version: PASS\n";
  Sys.remove m_no_version;
  Sys.remove m_9999;
  Sys.remove m_dup;
  Sys.remove (Filename.concat repo "std/core.tg");
  Sys.remove (Filename.concat repo "std/core");
  Unix.rmdir (Filename.concat repo "std");
  Unix.rmdir repo;
  Unix.rmdir dir;
  Printf.printf "ALL MANIFEST PASS\n";
  Selfcheck_sentinel.emit_and_exit "tg_manifest"
