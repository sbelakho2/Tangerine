(* tg_fingerprint.ml — bootstrap manifest fingerprint self-check.

   Asserts:
   (a) the real manifest (../bootstrap/compiler_kernel.manifest, repo root
       ..) loads and its fingerprint is 64 hex characters;
   (b) mutating one entry's source bytes IN MEMORY (first entry, one
       appended newline) changes the fingerprint;
   (c) the manifest rejects entries that escape the root: `..` segments,
       absolute paths, and a symlink inside the root resolving into a
       sibling directory whose name shares the root's path prefix. *)

let fail fmt = Printf.ksprintf (fun s -> Printf.printf "FAIL: %s\n" s; exit 1) fmt

let write_file (path : string) (content : string) : unit =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)

let tmp_dir () : string =
  let d = Filename.temp_file "tg_fp" "" in
  Sys.remove d;
  Unix.mkdir d 0o755;
  d

let expect_rejected ~(name : string) ~(repo_root : string) ~(manifest : string) =
  match Bootstrap_manifest.load ~repo_root ~manifest_path:manifest with
  | Error _ -> Printf.printf "  reject %s: PASS\n" name
  | Ok _ -> fail "manifest with %s was accepted" name

let () =
  Printf.printf "TG FINGERPRINT SELF-CHECK\n";
  let manifest_path = "bootstrap/compiler_kernel.manifest" in
  let repo_root = ".." in
  (match Bootstrap_manifest.load ~repo_root ~manifest_path with
   | Error m -> fail "cannot load manifest: %s" m
   | Ok manifest ->
       let fp = Bootstrap_manifest.fingerprint manifest in
       Printf.printf "  fingerprint: %s\n" fp;
       Printf.printf "  fingerprint length: %d\n" (String.length fp);
       if String.length fp <> 64 then
         fail "fingerprint length is %d, expected 64 hex chars" (String.length fp);
       let n = List.length (Bootstrap_manifest.entries manifest) in
       Printf.printf "  manifest: %d entries\n" n;
       let first = List.hd (Bootstrap_manifest.entries manifest) in
       let mutated =
         Bootstrap_manifest.with_entry_source manifest first.Bootstrap_manifest.path
           (first.Bootstrap_manifest.source ^ "\n")
       in
       let fp2 = Bootstrap_manifest.fingerprint mutated in
       Printf.printf "  mutated fingerprint: %s\n" fp2;
       if fp2 = fp then fail "fingerprint unchanged after mutating a source byte";
       Printf.printf "  source mutation changes fingerprint: PASS\n");
  let dir = tmp_dir () in
  let repo = Filename.concat dir "repo" in
  let evil = Filename.concat dir "repo_evil" in
  Unix.mkdir repo 0o755;
  Unix.mkdir evil 0o755;
  write_file (Filename.concat evil "x.tg") "def f() -> Int\n  1\nend\n";
  Unix.symlink (Filename.concat evil "x.tg") (Filename.concat repo "link.tg");
  let m1 = Filename.concat dir "m1.manifest" in
  write_file m1 "compiler: ../evil.tg\n";
  expect_rejected ~name:".. escape" ~repo_root:repo ~manifest:m1;
  let m2 = Filename.concat dir "m2.manifest" in
  write_file m2 "compiler: /etc/passwd\n";
  expect_rejected ~name:"absolute path" ~repo_root:repo ~manifest:m2;
  let m3 = Filename.concat dir "m3.manifest" in
  write_file m3 "compiler: link.tg\n";
  expect_rejected ~name:"sibling-dir symlink escape (root boundary)" ~repo_root:repo ~manifest:m3;
  Sys.remove (Filename.concat repo "link.tg");
  Sys.remove (Filename.concat evil "x.tg");
  Sys.remove m1;
  Sys.remove m2;
  Sys.remove m3;
  Unix.rmdir repo;
  Unix.rmdir evil;
  Unix.rmdir dir;
  Printf.printf "PASS: fingerprint self-check\n";
  exit 0
