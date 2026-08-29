(* test_typecheck_regressions.ml — the re-audit P0 focused typechecking
   regressions.  Each program must typecheck with ZERO errors; a failure
   means a previously-fixed soundness/typing bug regressed. *)

let check_clean (src : string) : bool =
  let sm = Span.create () in
  let diags = Diagnostic.create_bag () in
  let module_path = [] in
  let src0 = Source.of_bytes ~name:"typecheck_regression.tg" ~bytes:src in
  let file_id = Span.add_file sm "typecheck_regression.tg" src0 in
  let lx = Lexer.create src0.Source.bytes file_id diags in
  let tokens = Lexer.lex lx in
  let program = Parser.parse tokens src0.Source.bytes file_id diags module_path in
  let env = Typecheck.initial_env () in
  match Typecheck.check_program env program with
  | Error _ -> false
  | Ok (_, errors) -> errors = []

let t name src msg = (name, fun () -> Test_util.assert_true (check_clean src) msg)

let suite () =
  Test_util.run
    [
      t "pop-statement"
        {|def f(xs: Vec[Int]) -> Int
  xs.push(1)
  xs.pop()
  0
end
|}
        "a zero-argument .pop() as a statement must typecheck cleanly (was misparsed as pop()())";
      t "pop-unit-tail"
        {|def f(xs: Vec[Int]) -> Unit
  xs.pop()
end
|}
        "a .pop() as the tail of a Unit fn must typecheck cleanly (was rejected: expected (), found Option[...])";
      t "pop-generic-map"
        {|def f(m: Vec[Map[String, Int]]) -> Unit
  m.pop()
end
|}
        "a .pop() on Vec[Map[...]] must typecheck cleanly";
      t "pop-scope-shape"
        {|def f(xs: Vec[Int], ids: Vec[Int]) -> Unit
  xs.pop()
  ids.pop()
  ()
end
|}
        "the pop_scope shape (two .pop() statements then ()) must typecheck cleanly";
    ]
