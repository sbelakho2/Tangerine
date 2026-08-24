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

let () =
  sha256_suite ();
  Test_utf8.suite ();
  Test_span_source.suite ();
  Test_literals.suite ();
  Test_lexer.suite ();
  Test_parser.suite ();
  let (p, f) = Test_util.counts () in
  Printf.printf "\n%d passed, %d failed\n" p f;
  if f > 0 then exit 1
