(* Tangerine Stage0 Bootstrap Compiler - Main Driver *)

open Cmdliner

(* Version info *)
let version = "0.1.0"

(* Commands *)

(* Check command - parse and type check files *)
let check_cmd =
  let files = Arg.(non_empty & pos_all file [] & info [] ~docv:"FILE" ~doc:"Tangerine source files to check") in
  let check files =
    let has_error = ref false in
    List.iter (fun filename ->
      let content = 
        let ic = open_in filename in
        let n = in_channel_length ic in
        let s = Bytes.create n in
        really_input ic s 0 n;
        close_in ic;
        Bytes.to_string s
      in
      Ast.current_file := filename;
      Lexer.reset ();
      try
        let lexbuf = Lexing.from_string content in
        let ast = Parser.program Lexer.token lexbuf in
        let diagnostics = Typecheck.check_program ast in
        List.iter (fun (d: Typecheck.diagnostic) ->
          let level_str = match d.diag_level with
            | Typecheck.Error -> "\027[31merror\027[0m"
            | Typecheck.Warning -> "\027[33mwarning\027[0m"
            | Typecheck.Info -> "\027[34minfo\027[0m"
            | Typecheck.Hint -> "\027[36mhint\027[0m"
          in
          Printf.eprintf "%s:%d:%d: %s: %s\n"
            d.diag_span.Ast.file d.diag_span.Ast.start_line d.diag_span.Ast.start_col
            level_str d.diag_message;
          if d.diag_level = Typecheck.Error then has_error := true
        ) diagnostics;
        if diagnostics = [] then
          Printf.printf "%s: \027[32mOK\027[0m\n" filename
      with
      | Lexer.Lexer_error (msg, line, col) ->
          Printf.eprintf "%s:%d:%d: \027[31merror\027[0m: %s\n" filename line col msg;
          has_error := true
      | Parser.Error ->
          Printf.eprintf "%s:%d:%d: \027[31merror\027[0m: Syntax error\n" 
            filename !Lexer.line !Lexer.col;
          has_error := true
    ) files;
    if !has_error then exit 1 else exit 0
  in
  let doc = "Check Tangerine source files for errors" in
  let info = Cmd.info "check" ~doc in
  Cmd.v info Term.(const check $ files)

(* Build command - compile files (placeholder) *)
let build_cmd =
  let files = Arg.(non_empty & pos_all file [] & info [] ~docv:"FILE" ~doc:"Tangerine source files to compile") in
  let output = Arg.(value & opt (some string) None & info ["o"; "output"] ~docv:"FILE" ~doc:"Output file") in
  let build files output =
    Printf.printf "Building %d files...\n" (List.length files);
    let out = match output with Some o -> o | None -> "a.out" in
    Printf.printf "Output: %s\n" out;
    (* For now, just check *)
    List.iter (fun filename ->
      let content = 
        let ic = open_in filename in
        let n = in_channel_length ic in
        let s = Bytes.create n in
        really_input ic s 0 n;
        close_in ic;
        Bytes.to_string s
      in
      Ast.current_file := filename;
      Lexer.reset ();
      try
        let lexbuf = Lexing.from_string content in
        let _ast = Parser.program Lexer.token lexbuf in
        Printf.printf "  Parsed: %s\n" filename
      with e ->
        Printf.eprintf "  Error parsing %s: %s\n" filename (Printexc.to_string e);
        exit 1
    ) files;
    Printf.printf "Build complete (codegen not yet implemented in Stage0)\n"
  in
  let doc = "Compile Tangerine source files" in
  let info = Cmd.info "build" ~doc in
  Cmd.v info Term.(const build $ files $ output)

(* Run command - run a file (placeholder) *)
let run_cmd =
  let file = Arg.(required & pos 0 (some file) None & info [] ~docv:"FILE" ~doc:"Tangerine source file to run") in
  let run file =
    Printf.printf "Running %s...\n" file;
    Printf.printf "(interpreter not yet implemented in Stage0)\n"
  in
  let doc = "Run a Tangerine source file" in
  let info = Cmd.info "run" ~doc in
  Cmd.v info Term.(const run $ file)

(* Test command *)
let test_cmd =
  let files = Arg.(non_empty & pos_all file [] & info [] ~docv:"FILE" ~doc:"Test files to run") in
  let test files =
    Printf.printf "Running %d test files...\n" (List.length files);
    List.iter (fun filename ->
      Printf.printf "  %s: " filename;
      let content = 
        let ic = open_in filename in
        let n = in_channel_length ic in
        let s = Bytes.create n in
        really_input ic s 0 n;
        close_in ic;
        Bytes.to_string s
      in
      Ast.current_file := filename;
      Lexer.reset ();
      try
        let lexbuf = Lexing.from_string content in
        let ast = Parser.program Lexer.token lexbuf in
        let diagnostics = Typecheck.check_program ast in
        let errors = List.filter (fun d -> d.Typecheck.diag_level = Typecheck.Error) diagnostics in
        if errors = [] then
          Printf.printf "\027[32mPASS\027[0m\n"
        else begin
          Printf.printf "\027[31mFAIL\027[0m (%d errors)\n" (List.length errors);
          List.iter (fun d ->
            Printf.eprintf "    %s:%d: %s\n" d.Typecheck.diag_span.Ast.file 
              d.Typecheck.diag_span.Ast.start_line d.Typecheck.diag_message
          ) errors
        end
      with e ->
        Printf.printf "\027[31mFAIL\027[0m (parse error: %s)\n" (Printexc.to_string e)
    ) files;
    Printf.printf "Test run complete.\n"
  in
  let doc = "Run Tangerine test files" in
  let info = Cmd.info "test" ~doc in
  Cmd.v info Term.(const test $ files)

(* LSP command *)
let lsp_cmd =
  let lsp () =
    Lsp.run_lsp ()
  in
  let doc = "Start the Language Server Protocol server" in
  let info = Cmd.info "lsp" ~doc in
  Cmd.v info Term.(const lsp $ const ())

(* Format command *)
let fmt_cmd =
  let files = Arg.(non_empty & pos_all file [] & info [] ~docv:"FILE" ~doc:"Files to format") in
  let check_only = Arg.(value & flag & info ["check"] ~doc:"Check formatting without modifying files") in
  let fmt files check_only =
    List.iter (fun filename ->
      let content = 
        let ic = open_in filename in
        let n = in_channel_length ic in
        let s = Bytes.create n in
        really_input ic s 0 n;
        close_in ic;
        Bytes.to_string s
      in
      (* Simple formatting *)
      let lines = String.split_on_char '\n' content in
      let indent_keywords = ["def"; "struct"; "enum"; "trait"; "impl"; "if"; "while"; "for"; "match"; "loop"; "do"; "unsafe"; "module"] in
      let dedent_keywords = ["end"; "else"; "elsif"; "when"; "catch"; "finally"] in
      let formatted = ref [] in
      let indent = ref 0 in
      List.iter (fun line ->
        let trimmed = String.trim line in
        if trimmed = "" then
          formatted := "" :: !formatted
        else begin
          let should_dedent = List.exists (fun kw -> 
            String.length trimmed >= String.length kw &&
            String.sub trimmed 0 (String.length kw) = kw
          ) dedent_keywords in
          if should_dedent && !indent > 0 then indent := !indent - 1;
          
          formatted := (String.make (!indent * 2) ' ' ^ trimmed) :: !formatted;
          
          let should_indent = List.exists (fun kw ->
            String.length trimmed >= String.length kw &&
            String.sub trimmed 0 (String.length kw) = kw
          ) indent_keywords in
          if should_indent then indent := !indent + 1
        end
      ) lines;
      let new_content = String.concat "\n" (List.rev !formatted) in
      if check_only then begin
        if content <> new_content then begin
          Printf.printf "%s: needs formatting\n" filename;
          exit 1
        end else
          Printf.printf "%s: OK\n" filename
      end else begin
        let oc = open_out filename in
        output_string oc new_content;
        close_out oc;
        Printf.printf "Formatted: %s\n" filename
      end
    ) files
  in
  let doc = "Format Tangerine source files" in
  let info = Cmd.info "fmt" ~doc in
  Cmd.v info Term.(const fmt $ files $ check_only)

(* Lint command *)
let lint_cmd =
  let files = Arg.(non_empty & pos_all file [] & info [] ~docv:"FILE" ~doc:"Files to lint") in
  let lint files =
    List.iter (fun filename ->
      let content = 
        let ic = open_in filename in
        let n = in_channel_length ic in
        let s = Bytes.create n in
        really_input ic s 0 n;
        close_in ic;
        Bytes.to_string s
      in
      Ast.current_file := filename;
      Lexer.reset ();
      try
        let lexbuf = Lexing.from_string content in
        let ast = Parser.program Lexer.token lexbuf in
        let diagnostics = Typecheck.check_program ast in
        if diagnostics = [] then
          Printf.printf "%s: \027[32mNo issues\027[0m\n" filename
        else begin
          Printf.printf "%s: %d issues\n" filename (List.length diagnostics);
          List.iter (fun d ->
            let level_str = match d.Typecheck.diag_level with
              | Typecheck.Error -> "error"
              | Typecheck.Warning -> "warning"
              | Typecheck.Info -> "info"
              | Typecheck.Hint -> "hint"
            in
            Printf.printf "  %d:%d %s: %s\n"
              d.Typecheck.diag_span.Ast.start_line d.Typecheck.diag_span.Ast.start_col
              level_str d.Typecheck.diag_message
          ) diagnostics
        end
      with e ->
        Printf.eprintf "%s: parse error: %s\n" filename (Printexc.to_string e)
    ) files
  in
  let doc = "Lint Tangerine source files" in
  let info = Cmd.info "lint" ~doc in
  Cmd.v info Term.(const lint $ files)

(* Version command *)
let version_cmd =
  let print_version () =
    Printf.printf "Tangerine Stage0 Bootstrap Compiler %s\n" version;
    Printf.printf "OCaml %s\n" Sys.ocaml_version
  in
  let doc = "Print version information" in
  let info = Cmd.info "version" ~doc in
  Cmd.v info Term.(const print_version $ const ())

(* Main command group *)
let main_cmd =
  let doc = "Tangerine programming language compiler" in
  let man = [
    `S Manpage.s_description;
    `P "The Tangerine compiler (Stage0 bootstrap version).";
    `P "Use $(b,tg check) to check files for errors.";
    `P "Use $(b,tg lsp) to start the language server for IDE integration.";
  ] in
  let info = Cmd.info "tg" ~version ~doc ~man in
  Cmd.group info [
    check_cmd;
    build_cmd;
    run_cmd;
    test_cmd;
    lsp_cmd;
    fmt_cmd;
    lint_cmd;
    version_cmd;
  ]

let () = exit (Cmd.eval main_cmd)
