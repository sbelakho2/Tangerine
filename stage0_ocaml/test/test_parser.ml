(* test_parser.ml — Parser progress proof (audit §60).

   Malformed inputs (truncated blocks, unmatched delimiters, stray
   tokens) must terminate — no infinite loop — and produce at least one
   diagnostic. The differential corpus files (read from the repo path)
   must parse with zero diagnostics. *)

open Test_util

let corpus_dir = "/Users/sabelakhoua/IdeaProjects/Tangerine/tests/differential/corpus"

let parse_source (label : string) (src : string) :
    Diagnostic.bag * Ast.program =
  let diags = Diagnostic.create_bag () in
  let file_id = 0 in
  let lx = Lexer.create src file_id diags in
  let tokens = Lexer.lex lx in
  let module_path = Parser.module_path_of_file label in
  let program = Parser.parse tokens src file_id diags module_path in
  (diags, program)

let assert_errors (label : string) (src : string) : unit =
  let (diags, _) = parse_source label src in
  assert_true (Diagnostic.has_errors diags)
    (Printf.sprintf "%s: malformed input must produce at least one diagnostic" label)

let malformed : (string * string) list =
  [ ("truncated param list", "def f(");
    ("truncated param type", "def f(a: Int");
    ("truncated return type", "def f(a: Int) ->");
    ("truncated function body", "def f()\n  return");
    ("stray rparen in body", "def f() -> Int\n  )");
    ("stray rbrace in body", "def f()\n  }");
    ("unmatched paren", "def f()\n  (1 + 2");
    ("unmatched bracket", "def f()\n  x[0");
    ("unmatched brace", "def f()\n  { 1 2");
    ("trailing dot", "def f() -> Int\n  a.b.");
    ("truncated let value", "let x = ");
    ("stray token as value", "let x = )");
    ("truncated addition", "let x = 5 +");
    ("truncated struct", "struct S");
    ("truncated enum", "enum E");
    ("truncated impl", "impl Trait for Foo");
    ("truncated use", "use a::");
    ("truncated match", "def f()\n  match x");
    ("truncated for", "def f()\n  for x in");
    ("truncated while", "def f()\n  while x do");
    ("truncated test", "test \"name\" do");
    ("truncated macro", "macro m!(x: Int)");
    ("truncated module", "module m\n  def f()");
    ("truncated capability", "cap IO implies");
    ("truncated effect", "effect E\n  op(");
    ("truncated extern", "extern \"C\" do\n  def f(");
    ("truncated type alias", "type Alias =");
    ("truncated const", "const C: Int =");
    ("double exponent", "let x = 1ee") ]

let suite () =
  run
    (List.map (fun (label, src) -> ("parser malformed " ^ label, fun () -> assert_errors label src)) malformed
    @ [
        ("parser corpus parses cleanly", fun () ->
            let files =
              Sys.readdir corpus_dir |> Array.to_list
              |> List.filter (fun f -> Util.has_suffix f ".tg")
              |> List.sort String.compare
            in
            assert_true (List.length files > 0) "corpus directory is empty or missing";
            List.iter
              (fun f ->
                let path = corpus_dir ^ "/" ^ f in
                let content =
                  let ic = open_in_bin path in
                  Fun.protect
                    ~finally:(fun () -> close_in_noerr ic)
                    (fun () -> really_input_string ic (in_channel_length ic))
                in
                let (diags, _) = parse_source path content in
                assert_true (not (Diagnostic.has_errors diags))
                  (Printf.sprintf "%s: corpus file must parse with zero diagnostics" f))
              files);
      ])
