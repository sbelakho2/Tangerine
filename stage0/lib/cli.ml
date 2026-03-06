let usage () =
  print_endline "Tangerine stage0";
  print_endline "Usage:";
  print_endline "  main.exe help";
  print_endline "  main.exe version";
  print_endline "  main.exe lsp";
  print_endline "  main.exe lex <file>";
  print_endline "  main.exe parse <file>";
  print_endline "  main.exe analyze <file...>";
  print_endline "  main.exe strict <file...>";
  print_endline "  main.exe compile [--lib <file>] [--entry <file>] [-o <out>] [--cc <compiler>] <file...>";
  print_endline "  main.exe build [--lib <file>] [--entry <file>] [-o <out>] <file...>"

let read_file path =
  let ch = open_in_bin path in
  try
    let len = in_channel_length ch in
    let content = really_input_string ch len in
    close_in ch;
    content
  with exn ->
    close_in_noerr ch;
    raise exn

let make_abs path =
  if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path else path

let dirname path =
  try Filename.dirname path with _ -> "."

let write_wrapper ~output =
  let exe = make_abs Sys.executable_name in
  let wrapper =
    "#!/usr/bin/env bash\n" ^
    "exec \"" ^ exe ^ "\" \"$@\"\n"
  in
  let out_dir = dirname output in
  if out_dir <> "." then (try Unix.mkdir out_dir 0o755 with _ -> ());
  let ch = open_out output in
  output_string ch wrapper;
  close_out ch;
  Unix.chmod output 0o755

(* ── Multi-file C transpilation pipeline ──────────────────────────── *)

let find_runtime_dir () =
  (* Look relative to the executable for the runtime directory *)
  let exe_dir = Filename.dirname (make_abs Sys.executable_name) in
  let candidates = [
    Filename.concat exe_dir "../runtime";
    Filename.concat exe_dir "../../stage0/runtime";
    Filename.concat exe_dir "../stage0/runtime";
    "stage0/runtime";
    "runtime";
  ] in
  List.find_opt (fun d ->
    Sys.file_exists (Filename.concat d "tg_runtime.h")
  ) candidates

let compile_multi_file ~files ~output ~cc =
  (* Parse all files *)
  let file_programs = ref [] in
  let all_diags = ref [] in
  let skipped = ref 0 in
  List.iter (fun f ->
    let source = read_file f in
    let lexed = Lexer.lex ~file:f source in
    let parsed = Parser.parse ~file:f lexed.tokens in
    let file_errors = Diagnostics.count_errors (lexed.diagnostics @ parsed.parse_diags) in
    if file_errors > 0 then begin
      Printf.eprintf "warning: skipping %s (%d parse errors)\n" f file_errors;
      all_diags := !all_diags @ lexed.diagnostics @ parsed.parse_diags;
      skipped := !skipped + 1
    end else begin
      all_diags := !all_diags @ lexed.diagnostics @ parsed.parse_diags;
      file_programs := (f, parsed.program) :: !file_programs
    end
  ) files;

  if !file_programs = [] then begin
    Printf.eprintf "error: no files parsed successfully\n";
    1
  end else begin
    if !skipped > 0 then
      Printf.eprintf "note: skipped %d file(s) with parse errors, compiling %d file(s)\n"
        !skipped (List.length !file_programs);
    (* Check if any file defines a 'main' function *)
    let has_main_fn = List.exists (fun (_, prog) ->
      List.exists (fun item -> match item with
        | Ast.IFn { name = "main"; _ } -> true
        | _ -> false
      ) prog.Ast.items
    ) (List.rev !file_programs) in

    (* Generate C code *)
    let c_code = C_codegen.compile_program_to_c
      (List.rev !file_programs) ~has_main:has_main_fn in

    (* Write C code next to the output *)
    let abs_output = make_abs output in
    let c_file = abs_output ^ ".c" in
    let ch = open_out c_file in
    output_string ch c_code;
    close_out ch;

    (* Find runtime directory — always use absolute paths *)
    let runtime_dir = match find_runtime_dir () with
      | Some d -> make_abs d
      | None ->
        prerr_endline "warning: runtime directory not found, using 'stage0/runtime'";
        make_abs "stage0/runtime"
    in
    let runtime_c = Filename.concat runtime_dir "tg_runtime.c" in
    let runtime_h_dir = runtime_dir in

    (* Ensure output directory exists *)
    let out_dir = dirname output in
    if out_dir <> "." then (try Unix.mkdir out_dir 0o755 with _ -> ());

    (* Compile with cc *)
    let link_flag = if has_main_fn then Printf.sprintf "-o %s" (Filename.quote output)
                    else Printf.sprintf "-c -o %s.o" (Filename.quote output) in
    let cmd = Printf.sprintf "%s -O2 -w -std=c11 -I%s %s %s %s -lm 2>&1"
      (Filename.quote cc) (Filename.quote runtime_h_dir) link_flag
      (Filename.quote c_file)
      (if has_main_fn then Filename.quote runtime_c else "") in
    Printf.printf "  CC  %s\n" output;
    let exit_code = Sys.command cmd in
    if exit_code <> 0 then begin
      Printf.eprintf "error: C compilation failed (exit %d)\n" exit_code;
      Printf.eprintf "  command: %s\n" cmd;
      1
    end else begin
      (* Clean up generated C file on success *)
      (try Sys.remove c_file with _ -> ());
      0
    end
  end

let lex_file path =
  let source = read_file path in
  let lexed = Lexer.lex ~file:path source in
  List.iter (fun t -> print_endline (Token.to_string t)) lexed.tokens;
  Diagnostics.print_all lexed.diagnostics;
  if Diagnostics.count_errors lexed.diagnostics > 0 then 1 else 0

let parse_file path =
  let source = read_file path in
  let lexed = Lexer.lex ~file:path source in
  let parsed = Parser.parse ~file:path lexed.tokens in
  let all = lexed.diagnostics @ parsed.parse_diags in
  Diagnostics.print_all all;
  let e = Diagnostics.count_errors all in
  let w = Diagnostics.count_warnings all in
  Printf.printf "\n%d error(s), %d warning(s)\n" e w;
  if e = 0 then 0 else 1

let analyze_files ~fail_on_warning files =
  let rec loop errs warns = function
    | [] ->
        Printf.printf "\n%d error(s), %d warning(s)\n" errs warns;
        if errs > 0 || (fail_on_warning && warns > 0) then 1 else 0
    | f :: rest ->
        let source = read_file f in
        let lexed = Lexer.lex ~file:f source in
        let parsed = Parser.parse ~file:f lexed.tokens in
        let analyzed = Analyzer.analyze_source ~file:f source in
        let all = lexed.diagnostics @ parsed.parse_diags @ analyzed.diagnostics in
        let e = Diagnostics.count_errors all in
        let w = Diagnostics.count_warnings all in
        if e > 0 || w > 0 then begin
          Printf.printf "\n[%s]\n" f;
          Diagnostics.print_all all
        end;
        loop (errs + e) (warns + w) rest
  in
  loop 0 0 files

let compile_files files =
  let rec loop errs warns = function
    | [] ->
        Printf.printf "\n%d error(s), %d warning(s)\n" errs warns;
        if errs = 0 then 0 else 1
    | f :: rest ->
        let source = read_file f in
        let lexed = Lexer.lex ~file:f source in
        let parsed = Parser.parse ~file:f lexed.tokens in
        let all = lexed.diagnostics @ parsed.parse_diags in
        let e = Diagnostics.count_errors all in
        let w = Diagnostics.count_warnings all in
        if e > 0 then begin
          Printf.printf "\n[%s]\n" f;
          Diagnostics.print_all all
        end;
        loop (errs + e) (warns + w) rest
  in
  loop 0 0 files

type compile_opts = {
  output : string option;
  inputs : string list;
  cc : string;
  saw_lib_or_entry : bool;
}

let parse_compile_args args =
  let rec loop output inputs cc saw_lib_or_entry = function
    | [] -> { output; inputs = List.rev inputs; cc; saw_lib_or_entry }
    | "-o" :: path :: rest -> loop (Some path) inputs cc saw_lib_or_entry rest
    | "--output" :: path :: rest -> loop (Some path) inputs cc saw_lib_or_entry rest
    | "--cc" :: tool :: rest -> loop output inputs tool saw_lib_or_entry rest
    | "--entry" :: path :: rest -> loop output (path :: inputs) cc true rest
    | "--lib" :: path :: rest -> loop output (path :: inputs) cc true rest
    | "--verbose" :: rest -> loop output inputs cc saw_lib_or_entry rest
    | flag :: rest when String.length flag > 0 && flag.[0] = '-' -> loop output inputs cc saw_lib_or_entry rest
    | file :: rest -> loop output (file :: inputs) cc saw_lib_or_entry rest
  in
  loop None [] "cc" false args

let file_exists path =
  try Sys.file_exists path with _ -> false

let default_build_inputs () =
  let candidates = [ "tg_compiler/lib.tg"; "tg_compiler/driver.tg" ] in
  if List.for_all file_exists candidates then candidates else []

let run_compile ~allow_defaults args =
  let opts = parse_compile_args args in
  let inputs =
    if opts.inputs = [] && allow_defaults then default_build_inputs ()
    else opts.inputs
  in
  if inputs = [] then begin
    prerr_endline "error[E001]: no input files provided";
    usage ();
    2
  end else begin
    match opts.output with
    | Some out when List.length inputs = 1 && (not opts.saw_lib_or_entry) ->
      (* Single file native compilation (original path) *)
      let file = List.hd inputs in
      let source = read_file file in
      let lexed = Lexer.lex ~file source in
      let parsed = Parser.parse_structural ~file lexed.tokens in
      let all = lexed.diagnostics @ parsed.diagnostics in
      let e = Diagnostics.count_errors all in
      if e > 0 then begin
        Diagnostics.print_all all;
        1
      end else begin
        let native_code, native_diags =
          Codegen.compile_tg_to_native ~file ~source ~output:out ~cc:opts.cc
        in
        Diagnostics.print_all native_diags;
        if native_code = 0 then 0 else 1
      end
    | Some out ->
      (* Multi-file: use C transpiler pipeline *)
      compile_multi_file ~files:inputs ~output:out ~cc:opts.cc
    | None ->
      (* No output — just check compilation *)
      let code = compile_files inputs in
      code
  end

let version_string = "tgc0 0.1.0-clean"

let run argv =
  match Array.to_list argv with
  | [ _ ] | [ _; "help" ] -> usage (); 0
  | [ _; "version" ] | [ _; "--version" ] | [ _; "-V" ] -> print_endline version_string; 0
  | [ _; "lsp" ] -> Lsp.run ()
  | [ _; "lex"; file ] -> lex_file file
  | [ _; "parse"; file ] -> parse_file file
  | _ :: "analyze" :: files when files <> [] -> analyze_files ~fail_on_warning:false files
  | _ :: "strict" :: files when files <> [] -> analyze_files ~fail_on_warning:true files
  | _ :: "compile" :: args -> run_compile ~allow_defaults:false args
  | _ :: "build" :: args -> run_compile ~allow_defaults:true args
  | _ -> usage (); 2
