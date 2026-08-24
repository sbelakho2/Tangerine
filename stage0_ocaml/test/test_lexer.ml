(* test_lexer.ml — Token-level tests for the manifest closure's syntax
   (audit §55-59 surface): keywords, operators (incl. `->`, `=>`, `..=`,
   `<<=`), strings with escapes, chars with \u{1F600}, comments (#, #| |#,
   ##, //), identifiers with underscores, doc comments, and exact token
   kind sequences for representative inputs. *)

open Test_util

let all_kinds (src : string) : Diagnostic.bag * Token.kind list =
  let diags = Diagnostic.create_bag () in
  let lx = Lexer.create src 0 diags in
  (diags, List.map (fun t -> t.Token.kind) (Lexer.lex_all lx))

let non_trivia_kinds (src : string) : Diagnostic.bag * Token.kind list =
  let diags = Diagnostic.create_bag () in
  let lx = Lexer.create src 0 diags in
  (diags, List.map (fun t -> t.Token.kind) (Lexer.lex lx))

let assert_kinds (label : string) (src : string) (expected : Token.kind list)
    : unit =
  let (diags, actual) = non_trivia_kinds src in
  assert_true (not (Diagnostic.has_errors diags)) (label ^ ": unexpected lexer diagnostic");
  assert_equal label
    (String.concat " " (List.map Token.display_name expected))
    (String.concat " " (List.map Token.display_name actual))

let keyword_pairs : (string * Token.kind) list =
  [ ("def", Token.KwDef); ("fn", Token.KwFn); ("end", Token.KwEnd);
    ("if", Token.KwIf); ("then", Token.KwThen); ("else", Token.KwElse);
    ("elsif", Token.KwElsif); ("while", Token.KwWhile); ("for", Token.KwFor);
    ("in", Token.KwIn); ("do", Token.KwDo); ("let", Token.KwLet);
    ("mut", Token.KwMut); ("var", Token.KwMut); ("return", Token.KwReturn);
    ("break", Token.KwBreak); ("next", Token.KwNext); ("continue", Token.KwNext);
    ("match", Token.KwMatch); ("when", Token.KwWhen); ("struct", Token.KwStruct);
    ("enum", Token.KwEnum); ("trait", Token.KwTrait); ("impl", Token.KwImpl);
    ("use", Token.KwUse); ("pub", Token.KwPub); ("module", Token.KwModule);
    ("mod", Token.KwMod); ("const", Token.KwConst); ("static", Token.KwStatic);
    ("type", Token.KwType); ("typealias", Token.KwTypealias);
    ("alias", Token.KwTypealias); ("extern", Token.KwExtern);
    ("where", Token.KwWhere); ("as", Token.KwAs); ("super", Token.KwSuper);
    ("crate", Token.KwCrate); ("self", Token.KwSelfValue);
    ("Self", Token.KwSelfTy); ("true", Token.KwTrue); ("false", Token.KwFalse);
    ("unsafe", Token.KwUnsafe); ("async", Token.KwAsync); ("await", Token.KwAwait);
    ("cap", Token.KwCap); ("effect", Token.KwEffect); ("requires", Token.KwRequires);
    ("implies", Token.KwImplies); ("handle", Token.KwHandle); ("with", Token.KwWith);
    ("rationale", Token.KwRationale); ("budget", Token.KwBudget);
    ("pre", Token.KwPre); ("post", Token.KwPost); ("invariant", Token.KwInvariant);
    ("guard", Token.KwGuard); ("defer", Token.KwDefer); ("try", Token.KwTry);
    ("catch", Token.KwCatch); ("finally", Token.KwFinally); ("macro", Token.KwMacro);
    ("comptime", Token.KwComptime); ("loop", Token.KwLoop); ("pure", Token.KwPure);
    ("inline", Token.KwInline); ("unless", Token.KwUnless); ("until", Token.KwUntil);
    ("edition", Token.KwEdition); ("test", Token.KwTest); ("dyn", Token.KwDyn);
    ("inout", Token.KwInout); ("sink", Token.KwSink); ("set", Token.KwSet);
    ("resource", Token.KwResource); ("deinit", Token.KwDeinit) ]

let suite () =
  run
    (List.map
       (fun (word, kind) ->
         ("keyword " ^ word, fun () -> assert_kinds word word [ kind; Token.Eof ]))
       keyword_pairs
    @ [
        ("operator arrow ->", fun () -> assert_kinds "->" "->" [ Token.Arrow; Token.Eof ]);
        ("operator fat arrow =>", fun () -> assert_kinds "=>" "=>" [ Token.FatArrow; Token.Eof ]);
        ("operator range ..", fun () -> assert_kinds ".." ".." [ Token.DotDot; Token.Eof ]);
        ("operator inclusive range ..=", fun () -> assert_kinds "..=" "..=" [ Token.DotDotEq; Token.Eof ]);
        ("operator shl <<", fun () -> assert_kinds "<<" "<<" [ Token.Shl; Token.Eof ]);
        ("operator shl assign <<=", fun () -> assert_kinds "<<=" "<<=" [ Token.ShlEq; Token.Eof ]);
        ("operator shr >>", fun () -> assert_kinds ">>" ">>" [ Token.Shr; Token.Eof ]);
        ("operator shr assign >>=", fun () -> assert_kinds ">>=" ">>=" [ Token.ShrEq; Token.Eof ]);
        ("operators exact sequence", fun () ->
            assert_kinds "operators"
              "-> => ..= <<= << >>= >> a + b * c - d / e % f & g | h ^ i == != < <= > >= && || :: .. ... . : , ; ( ) [ ] { } ! ? ~ $ ="
              [ Token.Arrow; Token.FatArrow; Token.DotDotEq; Token.ShlEq; Token.Shl;
                Token.ShrEq; Token.Shr; Token.Ident { spelling = "a"; normalized = "a" };
                Token.Plus; Token.Ident { spelling = "b"; normalized = "b" };
                Token.Star; Token.Ident { spelling = "c"; normalized = "c" };
                Token.Minus; Token.Ident { spelling = "d"; normalized = "d" };
                Token.Slash; Token.Ident { spelling = "e"; normalized = "e" };
                Token.Percent; Token.Ident { spelling = "f"; normalized = "f" };
                Token.Amp; Token.Ident { spelling = "g"; normalized = "g" };
                Token.Pipe; Token.Ident { spelling = "h"; normalized = "h" };
                Token.Caret; Token.Ident { spelling = "i"; normalized = "i" };
                Token.EqEq; Token.BangEq; Token.Lt; Token.LtEq; Token.Gt;
                Token.GtEq; Token.AmpAmp; Token.PipePipe; Token.ColonColon;
                Token.DotDot; Token.DotDotDot; Token.Dot; Token.Colon; Token.Comma;
                Token.Semi; Token.LParen; Token.RParen; Token.LBracket;
                Token.RBracket; Token.LBrace; Token.RBrace; Token.Bang;
                Token.Question; Token.Tilde; Token.Dollar; Token.Eq; Token.Eof ]);
        ("string with escapes", fun () ->
            let (diags, kinds) =
              non_trivia_kinds "\"hello\\n\\t\\\"\\\\\\x41\\u{1F600}\""
            in
            assert_true (not (Diagnostic.has_errors diags)) "string: unexpected diagnostic";
            match kinds with
            | [ Token.String value; Token.Eof ] ->
                assert_equal "string value" "hello\n\t\"\\A\xF0\x9F\x98\x80" value
            | _ -> fail "string: expected String then Eof");
        ("string adjacent escapes u+hex", fun () ->
            let (diags, kinds) = non_trivia_kinds "\"\\u{41}\\u{1F600}\\x42\"" in
            assert_true (not (Diagnostic.has_errors diags)) "string2: unexpected diagnostic";
            match kinds with
            | [ Token.String value; Token.Eof ] ->
                assert_equal "string2 value" "A\xF0\x9F\x98\x80B" value
            | _ -> fail "string2: expected String then Eof");
        ("char with unicode escape", fun () ->
            let (diags, kinds) = non_trivia_kinds "'\\u{1F600}'" in
            assert_true (not (Diagnostic.has_errors diags)) "char: unexpected diagnostic";
            match kinds with
            | [ Token.Char value; Token.Eof ] ->
                assert_equal "char value" "\xF0\x9F\x98\x80" value
            | _ -> fail "char: expected Char then Eof");
        ("char simple escape", fun () ->
            let (diags, kinds) = non_trivia_kinds "'\\n'" in
            assert_true (not (Diagnostic.has_errors diags)) "char2: unexpected diagnostic";
            match kinds with
            | [ Token.Char value; Token.Eof ] ->
                assert_equal "char2 value" "\n" value
            | _ -> fail "char2: expected Char then Eof");
        ("char ascii", fun () ->
            let (diags, kinds) = non_trivia_kinds "'a'" in
            assert_true (not (Diagnostic.has_errors diags)) "char3: unexpected diagnostic";
            match kinds with
            | [ Token.Char value; Token.Eof ] ->
                assert_equal "char3 value" "a" value
            | _ -> fail "char3: expected Char then Eof");
        ("hash comment is trivia", fun () ->
            let (diags, kinds) = non_trivia_kinds "# hello" in
            assert_true (not (Diagnostic.has_errors diags)) "comment: unexpected diagnostic";
            match kinds with [ Token.Eof ] -> () | _ -> fail "comment: expected only Eof");
        ("block comment nested is trivia", fun () ->
            let (diags, kinds) = non_trivia_kinds "#| a #| nested |# b |#" in
            assert_true (not (Diagnostic.has_errors diags)) "block: unexpected diagnostic";
            match kinds with [ Token.Eof ] -> () | _ -> fail "block: expected only Eof");
        ("slash slash comment is trivia", fun () ->
            let (diags, kinds) = non_trivia_kinds "// line" in
            assert_true (not (Diagnostic.has_errors diags)) "slash: unexpected diagnostic";
            match kinds with [ Token.Eof ] -> () | _ -> fail "slash: expected only Eof");
        ("doc comment text captured", fun () ->
            let (diags, kinds) = all_kinds "##  doc text\n" in
            assert_true (not (Diagnostic.has_errors diags)) "doc: unexpected diagnostic";
            match kinds with
            | [ Token.DocComment text; Token.Newline; Token.Eof ] ->
                assert_equal "doc text" "doc text" text
            | _ -> fail "doc: unexpected token sequence");
        ("hash line comment token captured in lex_all", fun () ->
            let (diags, kinds) = all_kinds "# hello\n" in
            assert_true (not (Diagnostic.has_errors diags)) "hash: unexpected diagnostic";
            match kinds with
            | [ Token.Comment; Token.Newline; Token.Eof ] -> ()
            | _ -> fail "hash: unexpected token sequence");
        ("identifiers with underscores", fun () ->
            assert_kinds "underscores" "foo_bar baz2 _priv _"
              [ Token.Ident { spelling = "foo_bar"; normalized = "foo_bar" };
                Token.Ident { spelling = "baz2"; normalized = "baz2" };
                Token.Ident { spelling = "_priv"; normalized = "_priv" };
                Token.Ident { spelling = "_"; normalized = "_" };
                Token.Eof ]);
        ("keyword boundary split enddef", fun () ->
            assert_kinds "enddef" "enddef" [ Token.KwEnd; Token.KwDef; Token.Eof ]);
        ("keyword boundary split endtype", fun () ->
            assert_kinds "endtype" "endtype" [ Token.KwEnd; Token.KwType; Token.Eof ]);
        ("exact sequence let binding", fun () ->
            assert_kinds "let x: Int = 42" "let x: Int = 42"
              [ Token.KwLet; Token.Ident { spelling = "x"; normalized = "x" };
                Token.Colon; Token.Ident { spelling = "Int"; normalized = "Int" };
                Token.Eq; Token.Integer "42"; Token.Eof ]);
        ("exact sequence function signature", fun () ->
            assert_kinds "def add(a: Int, b: Int) -> Int" "def add(a: Int, b: Int) -> Int"
              [ Token.KwDef; Token.Ident { spelling = "add"; normalized = "add" };
                Token.LParen; Token.Ident { spelling = "a"; normalized = "a" };
                Token.Colon; Token.Ident { spelling = "Int"; normalized = "Int" };
                Token.Comma; Token.Ident { spelling = "b"; normalized = "b" };
                Token.Colon; Token.Ident { spelling = "Int"; normalized = "Int" };
                Token.RParen; Token.Arrow; Token.Ident { spelling = "Int"; normalized = "Int" };
                Token.Eof ]);
        ("exact sequence boolean expression", fun () ->
            assert_kinds "x <= 5 && y >= 3 || !flag" "x <= 5 && y >= 3 || !flag"
              [ Token.Ident { spelling = "x"; normalized = "x" }; Token.LtEq;
                Token.Integer "5"; Token.AmpAmp;
                Token.Ident { spelling = "y"; normalized = "y" }; Token.GtEq;
                Token.Integer "3"; Token.PipePipe; Token.Bang;
                Token.Ident { spelling = "flag"; normalized = "flag" }; Token.Eof ]);
        ("exact sequence for loop", fun () ->
            assert_kinds "for i in 0..=10 do x end" "for i in 0..=10 do x end"
              [ Token.KwFor; Token.Ident { spelling = "i"; normalized = "i" };
                Token.KwIn; Token.Integer "0"; Token.DotDotEq; Token.Integer "10";
                Token.KwDo; Token.Ident { spelling = "x"; normalized = "x" };
                Token.KwEnd; Token.Eof ]);
        ("exact sequence if else", fun () ->
            assert_kinds "if x then 1 else 2 end" "if x then 1 else 2 end"
              [ Token.KwIf; Token.Ident { spelling = "x"; normalized = "x" };
                Token.KwThen; Token.Integer "1"; Token.KwElse; Token.Integer "2";
                Token.KwEnd; Token.Eof ]);
        ("trivia stripped around tokens", fun () ->
            assert_kinds "let x = 1 # comment\n// more\n" "let x = 1 # comment\n// more\n"
              [ Token.KwLet; Token.Ident { spelling = "x"; normalized = "x" };
                Token.Eq; Token.Integer "1"; Token.Eof ]);
      ])
