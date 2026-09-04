let () =
  let path = Sys.argv.(1) in
  let ic = open_in path in
  let n = in_channel_length ic in
  let bytes = really_input_string ic n in
  close_in ic;
  match Source_loader.load_string path bytes with
  | Error _ -> print_endline "load error"
  | Ok src2 ->
      let sm = Span.create () in
      let fid = Span.add_file sm src2.Source.name src2 in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create src2.Source.bytes fid diags in
      let toks = Lexer.lex lx in
      let prog = Parser.parse toks src2.Source.bytes fid diags [ path ] in
      Printf.printf "parsed %d items, %d tokens\n" (List.length prog.Ast.items)
        (List.length toks)
