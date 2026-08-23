(* driver.ml — CLI driver for the OCaml stage0 bootstrap compiler.

   Command surface (drop-in with the reference stage0):
     lex <file>        Lex a .tg file and print tokens
     parse <file>      Parse a .tg file and print AST summary
     check <file>      Parse + subset check a .tg file
     scan <dir>        Scan a directory of .tg files (parse + subset check)
     dump <file>       Parse + dump deterministic AST tree
     hash <file>       Parse + print normalized AST hash
     lower <file>      Parse + lower to MIR and pretty-print
     passes            Print the compiler pass manifest
     version / help *)

let usage =
  {|Usage: tg_stage0 <command> [args]

Commands:
  lex <file>       Lex a .tg file and print tokens
  parse <file>     Parse a .tg file and print AST summary
  check <file>     Parse + subset check a .tg file
  scan <dir>       Scan a directory of .tg files (parse + subset check)
  dump <file>      Parse + dump deterministic AST tree
  hash <file>      Parse + print normalized AST hash
  lower <file>     Parse + lower to MIR and pretty-print
  passes           Print the compiler pass manifest
  version          Print version info
  help             Print this help message
|}

let load_source_or_report (path : string) : string option =
  match Source_loader.load path with
  | Ok s -> Some s
  | Error e ->
      (match e with
       | Source_loader.Unreadable p ->
           prerr_endline ("error: cannot read file '" ^ p ^ "'")
       | Source_loader.NotUTF8 p ->
           prerr_endline ("error: E9029: source file is not valid UTF-8: '" ^ p ^ "'"));
      None

let front_end (path : string) : (Diagnostic.bag * Span.source_map * Ast.program) option =
  match load_source_or_report path with
  | None -> None
  | Some source ->
      let sm = Span.create () in
      let file_id = Span.add_file sm path source in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create source file_id diags in
      let tokens = Lexer.lex lx in
      let module_path = Parser.module_path_of_file path in
      let program = Parser.parse tokens source file_id diags module_path in
      if not (Diagnostic.has_errors diags) then Verify.verify diags program;
      if not (Diagnostic.has_errors diags) then Subset.check diags program;
      Some (diags, sm, program)

let render_errors diags sm =
  prerr_string ("\n" ^ Diagnostic.render sm diags ^ "\n")

let cmd_lex (path : string) : int =
  match load_source_or_report path with
  | None -> 1
  | Some source ->
      let sm = Span.create () in
      let file_id = Span.add_file sm path source in
      let diags = Diagnostic.create_bag () in
      let lx = Lexer.create source file_id diags in
      let tokens = Lexer.lex lx in
      List.iter
        (fun t ->
          match Span.resolve sm t.Token.span with
          | Some (_, line, col) -> Printf.printf "%d:%d  %s\n" line col (Token.display_name t.Token.kind)
          | None -> Printf.printf "?:?  %s\n" (Token.display_name t.Token.kind))
        tokens;
      if Diagnostic.has_errors diags then begin
        prerr_string ("\n" ^ Diagnostic.render sm diags ^ "\n");
        1
      end
      else begin
        Printf.printf "\n%d tokens, 0 errors\n" (List.length tokens);
        0
      end

let cmd_parse_or_check (path : string) (check : bool) : int =
  match front_end path with
  | None -> 1
  | Some (diags, sm, program) ->
      Printf.printf "Parsed %d top-level items\n" (List.length program.Ast.items);
      List.iter (fun i -> Printf.printf "  %s\n" (Ast.item_summary i.Ast.kind)) program.Ast.items;
      if Diagnostic.has_errors diags then begin
        render_errors diags sm;
        1
      end
      else begin
        if Diagnostic.has_warnings diags then print_string (Diagnostic.render sm diags);
        Printf.printf "\n0 errors, %d warnings\n" (Diagnostic.warning_count diags);
        0
      end

let cmd_scan (dir : string) : int =
  let files =
    try
      Sys.readdir dir |> Array.to_list |> List.filter (fun f -> Util.has_suffix f ".tg")
      |> List.map (fun f -> dir ^ "/" ^ f) |> List.sort compare
    with Sys_error _ ->
      prerr_endline ("error: cannot open directory '" ^ dir ^ "'");
      []
  in
  let total_errors = ref 0 in
  let total_files = ref 0 in
  List.iter
    (fun file ->
      incr total_files;
      match front_end file with
      | None -> incr total_errors
      | Some (diags, sm, _) ->
          if Diagnostic.has_errors diags then begin
            prerr_string ("FAIL " ^ file ^ ": " ^ string_of_int (Diagnostic.error_count diags) ^ " errors\n");
            prerr_string (Diagnostic.render sm diags ^ "\n");
            total_errors := !total_errors + Diagnostic.error_count diags
          end
          else if Diagnostic.has_warnings diags then
            Printf.printf "WARN %s: %d warnings\n" file (Diagnostic.warning_count diags)
          else Printf.printf "OK   %s\n" file)
    files;
  Printf.printf "\nScanned %d files, %d total errors\n" !total_files !total_errors;
  if !total_errors > 0 then 1 else 0

let cmd_dump (path : string) : int =
  match front_end path with
  | None -> 1
  | Some (diags, sm, program) ->
      if Diagnostic.has_errors diags then begin
        prerr_string (Diagnostic.render sm diags ^ "\n");
        1
      end
      else begin
        print_string (Dump.dump program);
        print_newline ();
        0
      end

let cmd_hash (path : string) : int =
  match front_end path with
  | None -> 1
  | Some (diags, sm, program) ->
      if Diagnostic.has_errors diags then begin
        prerr_string (Diagnostic.render sm diags ^ "\n");
        1
      end
      else begin
        Printf.printf "parse:%s  %s\n" (Dump.hash_hex program) path;
        0
      end

let cmd_passes () : int =
  print_string
    "Pass manifest:\n  lex\n  parse\n  verify (V0001 span ordering)\n  subset (E9001-E9032 bootstrap gates)\n  lower (AST -> MIR)\n";
  0

let cmd_version () : int =
  print_string "tg_stage0 0.1.0 (OCaml bootstrap)\n";
  0

let main () : int =
  let args = Array.to_list Sys.argv in
  match args with
  | _ :: cmd :: rest -> (
      match cmd with
      | "lex" -> (
          match rest with path :: _ -> cmd_lex path | [] -> prerr_endline "error: 'lex' requires a file path"; 1)
      | "parse" -> (
          match rest with path :: _ -> cmd_parse_or_check path false | [] -> prerr_endline "error: 'parse' requires a file path"; 1)
      | "check" -> (
          match rest with path :: _ -> cmd_parse_or_check path true | [] -> prerr_endline "error: 'check' requires a file path"; 1)
      | "scan" -> (
          match rest with dir :: _ -> cmd_scan dir | [] -> prerr_endline "error: 'scan' requires a directory path"; 1)
      | "dump" -> (
          match rest with path :: _ -> cmd_dump path | [] -> prerr_endline "error: 'dump' requires a file path"; 1)
      | "hash" -> (
          match rest with path :: _ -> cmd_hash path | [] -> prerr_endline "error: 'hash' requires a file path"; 1)
      | "passes" -> cmd_passes ()
      | "version" -> cmd_version ()
      | "help" ->
          print_string usage;
          0
      | _ ->
          prerr_endline ("error: unknown command '" ^ cmd ^ "'");
          print_string usage;
          1)
  | _ ->
      print_string usage;
      0
