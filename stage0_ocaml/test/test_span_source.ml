(* test_span_source.ml — Position authority and source-map identity
   (audit §57, §58).

   Newline semantics: LF, CR, and CRLF each begin exactly one new line.
   Spans at EOF, empty files, final CR/LF, and BOM handling (BOM skipped
   semantically, absolute byte offsets preserved) are pinned here. The
   source-map regression adds A/B/C into one map with known offsets, then
   adds D and re-verifies that every earlier id still resolves to its own
   file. *)

open Test_util

let position_of (src : string) (off : int) : int * int =
  let s = Source.of_bytes ~name:"t" ~bytes:src in
  Source.position s off

let assert_position (label : string) (src : string) (off : int)
    (line : int) (col : int) : unit =
  let (l, c) = position_of src off in
  assert_equal (label ^ " line") (string_of_int line) (string_of_int l);
  assert_equal (label ^ " column") (string_of_int col) (string_of_int c)

let suite () =
  run
    [
      ("span LF: b after a\\nb is line 2 col 1", fun () -> assert_position "a\\nb" "a\nb" 2 2 1);
      ("span CR: b after a\\rb is line 2 col 1", fun () -> assert_position "a\\rb" "a\rb" 2 2 1);
      ("span CRLF: b after a\\r\\nb is line 2 col 1", fun () -> assert_position "a\\r\\nb" "a\r\nb" 3 2 1);
      ("span CRLF counts one line, not two", fun () ->
          let s = Source.of_bytes ~name:"t" ~bytes:"a\r\nb\r\nc" in
          let n = Array.length s.Source.line_starts in
          assert_equal "line starts count" "3" (string_of_int n);
          let (l, c) = Source.position s 6 in
          assert_equal "third line" "3" (string_of_int l);
          assert_equal "third line col" "1" (string_of_int c));
      ("span empty file at offset 0", fun () -> assert_position "empty" "" 0 1 1);
      ("span EOF of abc", fun () -> assert_position "abc eof" "abc" 3 1 4);
      ("span final LF", fun () -> assert_position "a\\n eof" "a\n" 2 2 1);
      ("span final CR", fun () -> assert_position "a\\r eof" "a\r" 2 2 1);
      ("span final CRLF", fun () -> assert_position "a\\r\\n eof" "a\r\n" 3 2 1);
      ("span multi-line", fun () -> assert_position "line1\\nline2\\n" "line1\nline2\n" 6 2 1);
      ("span line 3 col 1", fun () -> assert_position "line1\\nline2\\n" "line1\nline2\n" 12 3 1);
      ("span column 6 of line 2", fun () -> assert_position "line1\\nline2\\n" "line1\nline2\n" 11 2 6);
      ("bom bom_len is 3", fun () ->
          let s = Source.of_bytes ~name:"bom.tg" ~bytes:"\xEF\xBB\xBFdef\n" in
          assert_equal "bom_len" "3" (string_of_int s.Source.bom_len));
      ("bom first token offset preserved", fun () ->
          let s = Source.of_bytes ~name:"bom.tg" ~bytes:"\xEF\xBB\xBFdef\n" in
          let (l, c) = Source.position s 3 in
          assert_equal "bom line" "1" (string_of_int l);
          assert_equal "bom column" "4" (string_of_int c));
      ("bom lexer skips BOM, span starts at byte 3", fun () ->
          let diags = Diagnostic.create_bag () in
          let lx = Lexer.create "\xEF\xBB\xBFdef" 0 diags in
          let tokens = Lexer.lex lx in
          match tokens with
          | t :: _ ->
              (match t.Token.kind with
               | Token.KwDef -> ()
               | _ -> fail "bom: first token is not 'def'");
              assert_equal "bom token span start" "3"
                (string_of_int t.Token.span.Span.start)
          | [] -> fail "bom: no tokens");
      ("source map A/B/C resolve to own files", fun () ->
          let sm = Span.create () in
          let a = Source.of_bytes ~name:"A.tg" ~bytes:"alpha\nbeta\n" in
          let b = Source.of_bytes ~name:"B.tg" ~bytes:"hello\nworld\n" in
          let c = Source.of_bytes ~name:"C.tg" ~bytes:"abc\ndef\n" in
          let id_a = Span.add_file sm "A.tg" a in
          let id_b = Span.add_file sm "B.tg" b in
          let id_c = Span.add_file sm "C.tg" c in
          assert_equal "stable ids" "0 1 2"
            (Printf.sprintf "%d %d %d" id_a id_b id_c);
          (match Span.resolve sm (Span.make 6 10 id_a) with
           | Some (f, l, c) ->
               assert_equal "A file" "A.tg" f;
               assert_equal "A line" "2" (string_of_int l);
               assert_equal "A col" "1" (string_of_int c)
           | None -> fail "A span unresolved");
          (match Span.resolve sm (Span.make 6 11 id_b) with
           | Some (f, l, c) ->
               assert_equal "B file" "B.tg" f;
               assert_equal "B line" "2" (string_of_int l);
               assert_equal "B col" "1" (string_of_int c)
           | None -> fail "B span unresolved");
          (match Span.resolve sm (Span.make 4 7 id_c) with
           | Some (f, l, c) ->
               assert_equal "C file" "C.tg" f;
               assert_equal "C line" "2" (string_of_int l);
               assert_equal "C col" "1" (string_of_int c)
           | None -> fail "C span unresolved");
          let d = Source.of_bytes ~name:"D.tg" ~bytes:"zzz\n" in
          let id_d = Span.add_file sm "D.tg" d in
          assert_equal "D id stays next" "3" (string_of_int id_d);
          (match Span.resolve sm (Span.make 6 10 id_a) with
           | Some (f, _, _) -> assert_equal "A still resolves" "A.tg" f
           | None -> fail "A unresolved after D");
          (match Span.resolve sm (Span.make 6 11 id_b) with
           | Some (f, _, _) -> assert_equal "B still resolves" "B.tg" f
           | None -> fail "B unresolved after D");
          (match Span.resolve sm (Span.make 4 7 id_c) with
           | Some (f, _, _) -> assert_equal "C still resolves" "C.tg" f
           | None -> fail "C unresolved after D");
          (match Span.resolve sm (Span.make 1 2 id_d) with
           | Some (f, l, c) ->
               assert_equal "D file" "D.tg" f;
               assert_equal "D line" "1" (string_of_int l);
               assert_equal "D col" "2" (string_of_int c)
           | None -> fail "D unresolved");
          (match Span.file_of_id sm id_a with
           | Some s -> assert_equal "file_of_id A" "A.tg" s.Source.name
           | None -> fail "file_of_id A missing"));
      ("source map synthetic spans never resolve", fun () ->
          let sm = Span.create () in
          assert_true (Span.resolve sm Span.synthetic = None)
            "synthetic span must not resolve");
      ("source map cross-file merge rejected", fun () ->
          let sm = Span.create () in
          let a = Source.of_bytes ~name:"A.tg" ~bytes:"aaaa" in
          let b = Source.of_bytes ~name:"B.tg" ~bytes:"bbbb" in
          let id_a = Span.add_file sm "A.tg" a in
          let id_b = Span.add_file sm "B.tg" b in
          match Span.merged (Span.make 0 1 id_a) (Span.make 0 1 id_b) with
          | Ok _ -> fail "cross-file merge must be rejected"
          | Error msg ->
              assert_true (String.length msg > 0) "merge error message empty");
    ]
