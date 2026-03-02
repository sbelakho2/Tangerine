(** Compiler driver for Tangerine *)

(** Compilation output *)
type output =
  | Ast
  | TypedAst
  | Mir
  | Asm
  | Object
  | Executable
[@@deriving show, eq]

(** Compilation options *)
type options = {
  input_files : string list;
  output_file : string option;
  output_kind : output;
  dump_ast : bool;
  dump_mir : bool;
  colors : bool;
  verbose : bool;
  opt_level : int;  (* 0-3 *)
  debug_info : bool;
  edition : int option;
}

let default_options = {
  input_files = [];
  output_file = None;
  output_kind = Executable;
  dump_ast = false;
  dump_mir = false;
  colors = true;
  verbose = false;
  opt_level = 0;
  debug_info = false;
  edition = None;
}

(** Parse a single source file *)
let parse_file path =
  try
    let src = Source.read_file path in
    let lexbuf = Source.lexbuf_of_source src in
    try
      let ast = Parser.program Lexer.token lexbuf in
      Ok ast
    with
    | Parser.Error ->
      let pos = Lexing.lexeme_start_p lexbuf in
      let loc = Location.{
        file = path;
        start = { line = pos.pos_lnum; column = pos.pos_cnum - pos.pos_bol; offset = pos.pos_cnum };
        stop = { line = pos.pos_lnum; column = pos.pos_cnum - pos.pos_bol + 1; offset = pos.pos_cnum + 1 };
      } in
      Error [Diagnostics.error "syntax error" loc]
    | Lexer.Lexer_error (msg, pos) ->
      let loc = Location.{
        file = path;
        start = { line = pos.Lexing.pos_lnum; column = pos.pos_cnum - pos.pos_bol; offset = pos.pos_cnum };
        stop = { line = pos.pos_lnum; column = pos.pos_cnum - pos.pos_bol + 1; offset = pos.pos_cnum + 1 };
      } in
      Error [Diagnostics.error msg loc]
  with
  | Sys_error msg ->
    let loc = Location.dummy in
    Error [Diagnostics.error (Printf.sprintf "cannot read file: %s" msg) loc]

(** Type check an AST *)
let typecheck ast =
  let errors = Typecheck.check_program ast in
  if errors = [] then Ok ast
  else Error (List.map Diagnostics.of_type_error errors)

(** Lower to MIR *)
let lower_to_mir ast =
  let mir = Lower.lower_program ast in
  Ok mir

(** Full compilation pipeline *)
let compile opts =
  Diagnostics.reset_stats ();
  
  (* Parse all input files *)
  let parse_results = List.map (fun path ->
    if opts.verbose then
      Printf.eprintf "Parsing %s...\n%!" path;
    (path, parse_file path)
  ) opts.input_files in
  
  (* Check for parse errors *)
  let asts = List.filter_map (fun (path, result) ->
    match result with
    | Ok ast -> Some (path, ast)
    | Error diags ->
      List.iter (Diagnostics.emit_and_count ~colors:opts.colors) diags;
      None
  ) parse_results in
  
  if Diagnostics.has_errors () then begin
    Diagnostics.summary ();
    exit 1
  end;
  
  (* Dump AST if requested *)
  if opts.dump_ast then begin
    List.iter (fun (_path, ast) ->
      Format.printf "%a\n" Ast.pp_program ast
    ) asts
  end;
  
  if opts.output_kind = Ast then
    exit 0;
  
  (* Type check *)
  let typed_results = List.map (fun (path, ast) ->
    if opts.verbose then
      Printf.eprintf "Type checking %s...\n%!" path;
    (path, typecheck ast)
  ) asts in
  
  let typed_asts = List.filter_map (fun (path, result) ->
    match result with
    | Ok ast -> Some (path, ast)
    | Error diags ->
      List.iter (Diagnostics.emit_and_count ~colors:opts.colors) diags;
      None
  ) typed_results in
  
  if Diagnostics.has_errors () then begin
    Diagnostics.summary ();
    exit 1
  end;
  
  if opts.output_kind = TypedAst then
    exit 0;
  
  (* Lower to MIR *)
  let mir_results = List.map (fun (path, ast) ->
    if opts.verbose then
      Printf.eprintf "Lowering %s...\n%!" path;
    (path, lower_to_mir ast)
  ) typed_asts in
  
  let mirs = List.filter_map (fun (path, result) ->
    match result with
    | Ok mir -> Some (path, mir)
    | Error diags ->
      List.iter (Diagnostics.emit_and_count ~colors:opts.colors) diags;
      None
  ) mir_results in
  
  (* Dump MIR if requested *)
  if opts.dump_mir then begin
    List.iter (fun (_path, mir) ->
      Mir.Pp.pp_mir_module Format.std_formatter mir
    ) mirs
  end;
  
  if opts.output_kind = Mir then
    exit 0;
  
  (* Further stages would go here:
     - Borrow checking
     - Optimization passes
     - Code generation
     - Linking
  *)
  
  if opts.verbose then
    Printf.eprintf "Compilation successful (MIR stage complete)\n%!";
  
  ignore mirs;
  0
