(* test_main.ml — Runs every front-end suite in order and reports totals.

   The SHA-256 NIST vectors (audit §21) live here: the empty string, "abc",
   the two-block "abcdbcdecdef..." message, and the one-million-'a' vector. *)

let sha256_suite () =
  Test_util.run
    [
      ("sha256 empty string", fun () ->
          Test_util.assert_equal "empty" "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
            (Sha256.digest ""));
      ("sha256 abc", fun () ->
          Test_util.assert_equal "abc" "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
            (Sha256.digest "abc"));
      ("sha256 two-block message", fun () ->
          Test_util.assert_equal "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
            (Sha256.digest "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"));
      ("sha256 one million a", fun () ->
          let million = Bytes.make 1_000_000 (Char.chr 0x61) in
          Test_util.assert_equal "million a" "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0"
            (Sha256.digest_bytes million));
      ("sha256 length is 64 lowercase hex", fun () ->
          let d = Sha256.digest "The quick brown fox jumps over the lazy dog" in
          Test_util.assert_equal "length" "64" (string_of_int (String.length d));
          let all_hex =
            String.for_all
              (fun c ->
                (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
              d
          in
          Test_util.assert_true all_hex "digest must be lowercase hex");
      ("sha256 digest_bytes agrees with digest", fun () ->
          Test_util.assert_equal "digest_bytes" (Sha256.digest "abc")
            (Sha256.digest_bytes (Bytes.of_string "abc")));
      ("sha256 known second vector", fun () ->
          Test_util.assert_equal "brown fox"
            "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592"
            (Sha256.digest "The quick brown fox jumps over the lazy dog"));
    ]

(* ── Manifest trust-root suite ───────────────────────────────────
   Version policy (supported_versions), logical-path uniqueness, and
   single-module failure propagation (bootstrap_manifest.ml). *)

let manifest_dirs : string list ref = ref []

let tmp_repo () : string =
  let dir = Filename.temp_file "manifest_test" "" in
  Sys.remove dir;
  Unix.mkdir dir 0o755;
  let repo = Filename.concat dir "repo" in
  Unix.mkdir repo 0o755;
  Unix.mkdir (Filename.concat repo "std") 0o755;
  manifest_dirs := dir :: !manifest_dirs;
  repo

let write_file (path : string) (content : string) : unit =
  let oc = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out_noerr oc) (fun () -> output_string oc content)

(* Write a manifest text next to the temp repo and load it. *)
let load_manifest (repo : string) (content : string) : (Bootstrap_manifest.t, string) result =
  let mp = Filename.concat (Filename.dirname repo) "m.manifest" in
  write_file mp content;
  Bootstrap_manifest.load ~repo_root:repo ~manifest_path:mp

let manifest_cleanup () : unit =
  List.iter
    (fun dir ->
      let repo = Filename.concat dir "repo" in
      (try Sys.remove (Filename.concat repo "std/core.tg") with _ -> ());
      (try Sys.remove (Filename.concat repo "std/core") with _ -> ());
      (try Sys.remove (Filename.concat dir "m.manifest") with _ -> ());
      (try Unix.rmdir (Filename.concat repo "std") with _ -> ());
      (try Unix.rmdir repo with _ -> ());
      try Unix.rmdir dir with _ -> ())
    !manifest_dirs

let manifest_suite () =
  Test_util.run
    [
      ("manifest version: supported version 1 accepted", fun () ->
          let repo = tmp_repo () in
          write_file (Filename.concat repo "std/core.tg") "def f() -> Int\n  1\nend\n";
          let m =
            Test_util.assert_result_ok (load_manifest repo "version: 1\nstd: core.tg\n") "load"
          in
          Test_util.assert_equal "version" "1"
            (match Bootstrap_manifest.version_of m with Some v -> v | None -> "");
          Test_util.assert_equal "entries" "1"
            (string_of_int (List.length (Bootstrap_manifest.entries m))));
      ("manifest version: missing version field rejected", fun () ->
          let repo = tmp_repo () in
          write_file (Filename.concat repo "std/core.tg") "def f() -> Int\n  1\nend\n";
          let e = Test_util.assert_result_err (load_manifest repo "std: core.tg\n") "load" in
          Test_util.assert_true (String.length e > 0) "error message");
      ("manifest version: unsupported version 9999 rejected", fun () ->
          let repo = tmp_repo () in
          write_file (Filename.concat repo "std/core.tg") "def f() -> Int\n  1\nend\n";
          let e =
            Test_util.assert_result_err (load_manifest repo "version: 9999\nstd: core.tg\n") "load"
          in
          Test_util.assert_true (String.length e > 0) "error message");
      ("manifest version: non-numeric version rejected", fun () ->
          let repo = tmp_repo () in
          write_file (Filename.concat repo "std/core.tg") "def f() -> Int\n  1\nend\n";
          let e =
            Test_util.assert_result_err (load_manifest repo "version: one\nstd: core.tg\n") "load"
          in
          Test_util.assert_true (String.length e > 0) "error message");
      ("manifest uniqueness: duplicate logical path rejected", fun () ->
          let repo = tmp_repo () in
          write_file (Filename.concat repo "std/core.tg") "def f() -> Int\n  1\nend\n";
          write_file (Filename.concat repo "std/core") "def f() -> Int\n  1\nend\n";
          let e =
            Test_util.assert_result_err (load_manifest repo "version: 1\nstd: core\nstd: core.tg\n")
              "load"
          in
          Test_util.assert_true (String.length e > 0) "error message");
      ("manifest uniqueness: duplicate file path rejected", fun () ->
          let repo = tmp_repo () in
          write_file (Filename.concat repo "std/core.tg") "def f() -> Int\n  1\nend\n";
          let e =
            Test_util.assert_result_err (load_manifest repo "version: 1\nstd: core.tg\nstd: core.tg\n")
              "load"
          in
          Test_util.assert_true (String.length e > 0) "error message");
      ("manifest single: source-load failure returns Error", fun () ->
          let _ =
            Test_util.assert_result_err
              (Bootstrap_manifest.single ~file:"/nonexistent/core.tg" ~path:[ "std"; "core" ] ())
              "single"
          in
          ());
      ("manifest single: success carries snapshot, hash and version", fun () ->
          let repo = tmp_repo () in
          let file = Filename.concat repo "std/core.tg" in
          write_file file "def f() -> Int\n  1\nend\n";
          let m =
            Test_util.assert_result_ok
              (Bootstrap_manifest.single ~file ~path:[ "std"; "core" ] ())
              "single"
          in
          let e = List.hd (Bootstrap_manifest.entries m) in
          Test_util.assert_true (e.Bootstrap_manifest.source <> "") "source snapshot retained";
          Test_util.assert_equal "source hash"
            (Sha256.digest e.Bootstrap_manifest.source)
            e.Bootstrap_manifest.source_hash;
          Test_util.assert_equal "version" "1"
            (match Bootstrap_manifest.version_of m with Some v -> v | None -> ""));
      ("manifest real: compiler_kernel.manifest loads with version 1", fun () ->
          let m =
            Test_util.assert_result_ok
              (Bootstrap_manifest.load ~repo_root:".." ~manifest_path:"bootstrap/compiler_kernel.manifest")
              "load"
          in
          Test_util.assert_equal "version" "1"
            (match Bootstrap_manifest.version_of m with Some v -> v | None -> "");
          Test_util.assert_true
            (List.length (Bootstrap_manifest.entries m) > 0)
            "real manifest has entries");
      ("module graph: duplicate logical path hard-fails", fun () ->
          let repo = tmp_repo () in
          write_file (Filename.concat repo "std/core.tg") "module x end\nmodule x end\n";
          let manifest =
            Test_util.assert_result_ok (load_manifest repo "version: 1\nstd: core.tg\n") "load"
          in
          let diags = Diagnostic.create_bag () in
          (try
             let _ = Module_graph.create_with_sources manifest diags in
             Test_util.fail "duplicate inline module path was accepted silently"
           with Invalid_argument msg ->
             Test_util.assert_true (String.length msg > 0) "raise message"));
    ]

let () =
  Test_typecheck_regressions.suite ();
  sha256_suite ();
  Test_utf8.suite ();
  Test_span_source.suite ();
  Test_literals.suite ();
  Test_lexer.suite ();
  Test_parser.suite ();
  manifest_suite ();
  manifest_cleanup ();
  let (p, f) = Test_util.counts () in
  Printf.printf "\n%d passed, %d failed\n" p f;
  if f > 0 then exit 1
