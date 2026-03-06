let () =
  let code =
    try Tangerine_stage0.Cli.run Sys.argv
    with exn ->
      Printf.eprintf "internal error: %s\n" (Printexc.to_string exn);
      1
  in
  exit code
