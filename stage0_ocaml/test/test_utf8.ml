(* test_utf8.ml — Byte-level UTF-8 tests (audit §56).

   Every rejection asserts the EXACT failing byte offset via Utf8.validate;
   accepts are asserted as Ok. The loader and lexer paths are driven
   directly: Source_loader.load_string must return NotUTF8 for invalid
   input, and the lexer must produce no non-trivia tokens plus a
   diagnostic. *)

open Test_util

let reject_at (label : string) (src : string) (offset : int) : unit =
  match Utf8.validate (Bytes.of_string src) with
  | Ok () -> fail (label ^ ": expected rejection, got Ok")
  | Error e ->
      assert_equal (label ^ " failing offset") (string_of_int offset)
        (string_of_int e.Utf8.offset)

let accept (label : string) (src : string) : unit =
  match Utf8.validate (Bytes.of_string src) with
  | Ok () -> ()
  | Error e ->
      fail
        (Printf.sprintf "%s: expected acceptance, got %s at byte %d" label
           (Utf8.error_string e.Utf8.kind) e.Utf8.offset)

let lex_invalid (label : string) (src : string) : unit =
  let diags = Diagnostic.create_bag () in
  let lx = Lexer.create src 0 diags in
  let tokens = Lexer.lex lx in
  let only_eof =
    List.length tokens = 1
    && match (List.hd tokens).Token.kind with Token.Eof -> true | _ -> false
  in
  assert_true only_eof (label ^ ": lexing invalid UTF-8 must yield no non-trivia tokens");
  assert_true (Diagnostic.has_errors diags)
    (label ^ ": lexing invalid UTF-8 must produce a diagnostic")

let suite () =
  run
    [
      ("utf8 reject overlong C0 AF", fun () -> reject_at "C0 AF" "\xC0\xAF" 0);
      ("utf8 reject unexpected continuation 80", fun () -> reject_at "80" "\x80" 0);
      ("utf8 reject truncated E2 82", fun () -> reject_at "E2 82" "\xE2\x82" 0);
      ("utf8 reject surrogate ED A0 80", fun () -> reject_at "ED A0 80" "\xED\xA0\x80" 0);
      ("utf8 reject above max F4 90 80 80", fun () -> reject_at "F4 90 80 80" "\xF4\x90\x80\x80" 0);
      ("utf8 reject invalid lead F5 80 80 80", fun () -> reject_at "F5 80 80 80" "\xF5\x80\x80\x80" 0);
      ("utf8 reject invalid lead FF", fun () -> reject_at "FF" "\xFF" 0);
      ("utf8 reject at nonzero offset abc + C0 AF", fun () -> reject_at "abc C0 AF" "abc\xC0\xAF" 3);
      ("utf8 reject at nonzero offset x + E2 82", fun () -> reject_at "x E2 82" "x\xE2\x82" 1);
      ("utf8 reject non-continuation after E2", fun () -> reject_at "E2 41 82" "\xE2\x41\x82" 0);
      ("utf8 accept 00", fun () -> accept "00" "\x00");
      ("utf8 accept 7F", fun () -> accept "7F" "\x7F");
      ("utf8 accept C2 80", fun () -> accept "C2 80" "\xC2\x80");
      ("utf8 accept DF BF", fun () -> accept "DF BF" "\xDF\xBF");
      ("utf8 accept E0 A0 80", fun () -> accept "E0 A0 80" "\xE0\xA0\x80");
      ("utf8 accept ED 9F BF", fun () -> accept "ED 9F BF" "\xED\x9F\xBF");
      ("utf8 accept EE 80 80", fun () -> accept "EE 80 80" "\xEE\x80\x80");
      ("utf8 accept F0 90 80 80", fun () -> accept "F0 90 80 80" "\xF0\x90\x80\x80");
      ("utf8 accept F4 8F BF BF", fun () -> accept "F4 8F BF BF" "\xF4\x8F\xBF\xBF");
      ("utf8 decode_at U+1F600", fun () ->
          match Utf8.decode_at (Bytes.of_string "\xF0\x9F\x98\x80") 0 with
          | Ok (u, next) ->
              assert_equal "scalar" "128512" (string_of_int (Uchar.to_int u));
              assert_equal "next offset" "4" (string_of_int next)
          | Error _ -> fail "decode_at U+1F600 failed");
      ("utf8 decode_at truncated", fun () ->
          match Utf8.decode_at (Bytes.of_string "\xE2\x82") 0 with
          | Ok _ -> fail "decode_at truncated: expected error"
          | Error e -> assert_equal "truncated offset" "0" (string_of_int e.Utf8.offset));
      ("utf8 validate_string", fun () ->
          assert_true (Utf8.is_valid_utf8 "café") "café should be valid";
          assert_true (not (Utf8.is_valid_utf8 "\xC0\xAF")) "C0 AF should be invalid");
      ("loader reject invalid utf8 as NotUTF8", fun () ->
          let r = Source_loader.load_string "bad.tg" "\xC0\xAF" in
          match r with
          | Error (Source_loader.NotUTF8 (name, e)) ->
              assert_equal "loader name" "bad.tg" name;
              assert_equal "loader offset" "0" (string_of_int e.Utf8.offset)
          | Error _ -> fail "loader: expected NotUTF8, got a different error"
          | Ok _ -> fail "loader: expected NotUTF8, got Ok");
      ("loader accepts valid utf8", fun () ->
          match Source_loader.load_string "ok.tg" "def f()\n  café\nend\n" with
          | Ok src -> assert_equal "loader name" "ok.tg" src.Source.name
          | Error _ -> fail "loader: valid input rejected");
      ("lexer invalid FF produces no tokens + error", fun () -> lex_invalid "FF" "\xFF");
      ("lexer invalid C0 AF produces no tokens + error", fun () -> lex_invalid "C0 AF" "\xC0\xAF");
    ]
