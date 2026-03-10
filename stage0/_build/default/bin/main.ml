let version = "tgc0 0.1.0-clean-slate"

let wrapper_script =
  String.concat
    "\n"
    [ "#!/bin/sh"
    ; "set -eu"
    ; "self_path=$0"
    ; "case \"$self_path\" in"
    ; "  /*) ;;"
    ; "  *) self_path=\"$(pwd)/$self_path\" ;;"
    ; "esac"
    ; "script_dir=\"$(CDPATH= cd -- \"$(dirname -- \"$self_path\")\" && pwd)\""
    ; "find_stage0() {"
    ; "  current=\"$script_dir\""
    ; "  while :; do"
    ; "    if [ -x \"$current/stage0/_build/default/bin/main.exe\" ]; then"
    ; "      printf '%s\\n' \"$current/stage0/_build/default/bin/main.exe\""
    ; "      return 0"
    ; "    fi"
    ; "    parent=\"$(dirname -- \"$current\")\""
    ; "    if [ \"$parent\" = \"$current\" ]; then"
    ; "      return 1"
    ; "    fi"
    ; "    current=\"$parent\""
    ; "  done"
    ; "}"
    ; "stage0_bin=\"$(find_stage0 || true)\""
    ; "if [ -z \"${stage0_bin:-}\" ]; then"
    ; "  echo \"error: unable to locate stage0/_build/default/bin/main.exe from $0\" >&2"
    ; "  exit 1"
    ; "fi"
    ; "exec \"$stage0_bin\" \"$@\""
    ; ""
    ]

let write_executable path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc;
  Unix.chmod path 0o755

let write_file path content =
  let oc = open_out_bin path in
  output_string oc content;
  close_out oc

let read_file path =
  let ic = open_in_bin path in
  let len = in_channel_length ic in
  let data = really_input_string ic len in
  close_in ic;
  data

let starts_with text prefix =
  let prefix_len = String.length prefix in
  String.length text >= prefix_len && String.sub text 0 prefix_len = prefix

let trim = String.trim

let split_lines text = String.split_on_char '\n' text

let module_name_of_path path =
  path |> Filename.basename |> Filename.chop_extension

let scan_mod_declarations source =
  let parse_line prefix line =
    let rest = String.sub line (String.length prefix) (String.length line - String.length prefix) |> trim in
    match String.split_on_char ' ' rest with
    | name :: _ when name <> "" -> Some name
    | _ -> None
  in
  split_lines source
  |> List.filter_map (fun raw_line ->
    let line = trim raw_line in
    if starts_with line "pub mod " then parse_line "pub mod " line
    else if starts_with line "mod " then parse_line "mod " line
    else None)

let qualify_type_expr module_name = function
  | Ast.TNamed name when String.contains name ':' -> Ast.TNamed name
  | Ast.TNamed name -> Ast.TNamed (module_name ^ "::" ^ name)
  | ty -> ty

let qualify_param module_name (param : Ast.param) =
  { param with ty = Option.map (qualify_type_expr module_name) param.ty }

let qualify_function module_name (decl : Ast.function_decl) =
  { decl with
    name = module_name ^ "::" ^ decl.name
  ; method_of = Option.map (fun owner -> module_name ^ "::" ^ owner) decl.method_of
  ; params = List.map (qualify_param module_name) decl.params
  ; ret_type = Option.map (qualify_type_expr module_name) decl.ret_type
  }

let qualify_enum module_name (decl : Ast.enum_decl) =
  { Ast.name = module_name ^ "::" ^ decl.name
  ; variants =
      List.map
        (fun (variant : Ast.enum_variant) ->
          { Ast.name = variant.name
          ; payload = List.map (qualify_type_expr module_name) variant.payload
          })
        decl.variants
  }

let qualify_struct module_name (decl : Ast.struct_decl) =
  { Ast.name = module_name ^ "::" ^ decl.name
  ; fields =
      List.map
        (fun (field : Ast.struct_field) ->
          { Ast.name = field.name; ty = qualify_type_expr module_name field.ty })
        decl.fields
  }

let qualify_const module_name (decl : Ast.const_decl) =
  { decl with
    name = module_name ^ "::" ^ decl.name
  ; ty = Option.map (qualify_type_expr module_name) decl.ty
  }

let qualify_global module_name (decl : Ast.global_decl) =
  { Ast.name = module_name ^ "::" ^ decl.name
  ; is_mutable = decl.is_mutable
  ; ty = Option.map (qualify_type_expr module_name) decl.ty
  ; value = decl.value
  }

let qualify_trait module_name (decl : Ast.trait_decl) =
  { Ast.name = module_name ^ "::" ^ decl.name }

let qualify_item module_name = function
  | Ast.Function decl -> Some (Ast.Function (qualify_function module_name decl))
  | Ast.Enum decl -> Some (Ast.Enum (qualify_enum module_name decl))
  | Ast.Struct decl -> Some (Ast.Struct (qualify_struct module_name decl))
  | Ast.Const decl -> Some (Ast.Const (qualify_const module_name decl))
  | Ast.Global decl -> Some (Ast.Global (qualify_global module_name decl))
  | Ast.Trait decl -> Some (Ast.Trait (qualify_trait module_name decl))
  | Ast.Ignored -> None

let resolve_module_file ~current_file module_name =
  let current_dir = Filename.dirname current_file in
  let candidates =
    [ Filename.concat current_dir (module_name ^ ".tg")
    ; Filename.concat (Filename.concat current_dir module_name) "lib.tg"
    ]
  in
  List.find_opt Sys.file_exists candidates

let shell_quote text =
  let parts = String.split_on_char '\'' text in
  "'" ^ String.concat "'\\''" parts ^ "'"

let default_output_for_input input_path =
  try Filename.chop_extension input_path with
  | Invalid_argument _ -> input_path ^ ".out"

let take_output_path = function
  | [] -> Error "missing required -o <output>"
  | ["-o"] -> Error "missing path after -o"
  | "-o" :: path :: rest -> Ok (path, rest)
  | flag :: _ -> Error ("unexpected argument: " ^ flag)

let command_wrap args =
  match take_output_path args with
  | Error message ->
      prerr_endline ("error: wrap: " ^ message);
      2
  | Ok (output_path, rest) ->
      if rest <> [] then (
        prerr_endline "error: wrap: unexpected trailing arguments";
        2)
      else (
        write_executable output_path wrapper_script;
        0)

type build_options =
  { output_path : string
  ; target : string option
  }

let default_build_options = { output_path = "build/tg"; target = None }

let rec parse_build_options options = function
  | [] -> Ok options
  | "--wrapper" :: rest -> parse_build_options options rest
  | ["-o"] -> Error "missing path after -o"
  | "-o" :: path :: rest ->
      parse_build_options { options with output_path = path } rest
  | ["--target"] -> Error "missing target triple after --target"
  | "--target" :: triple :: rest ->
      parse_build_options { options with target = Some triple } rest
  | flag :: _ -> Error ("unexpected argument: " ^ flag)

let command_build args =
  match parse_build_options default_build_options args with
  | Error message ->
      prerr_endline ("error: build: " ^ message);
      2
  | Ok options ->
      let _ = options.target in
      write_executable options.output_path wrapper_script;
      0

type compile_options =
  { input_paths : string list
  ; output_path : string
  }

let parse_compile_options args =
  let rec loop input_paths output_path = function
    | [] ->
        begin match List.rev input_paths with
        | path :: _ ->
            let output_path =
              match output_path with
              | Some path -> path
              | None -> default_output_for_input path
            in
            Ok { input_paths = List.rev input_paths; output_path }
        | [] -> Error "missing input file"
        end
    | ["-o"] -> Error "missing path after -o"
    | "-o" :: path :: rest -> loop input_paths (Some path) rest
    | flag :: _ when String.length flag > 0 && flag.[0] = '-' ->
        Error ("unexpected argument: " ^ flag)
    | path :: rest -> loop (path :: input_paths) output_path rest
  in
  loop [] None args

let parse_program_files input_paths =
  let visited = Hashtbl.create 64 in
  let rec load_file ?qualify_as input_path =
    let absolute_path =
      if Filename.is_relative input_path then Filename.concat (Sys.getcwd ()) input_path else input_path
    in
    if Hashtbl.mem visited absolute_path then
      []
    else (
      Hashtbl.replace visited absolute_path ();
      let source = read_file absolute_path in
      let nested_program =
        scan_mod_declarations source
        |> List.filter_map (resolve_module_file ~current_file:absolute_path)
        |> List.concat_map (fun path -> load_file ~qualify_as:(module_name_of_path path) path)
      in
      let tokens = Lexer.tokenize source in
      let program = Parser.parse tokens in
      let qualified_aliases =
        match qualify_as with
        | Some module_name -> List.filter_map (qualify_item module_name) program
        | None -> []
      in
      nested_program @ program @ qualified_aliases)
  in
  input_paths |> List.concat_map load_file

let command_parse args =
  match args with
  | [] ->
      prerr_endline "error: parse: missing input file";
      2
  | input_paths ->
      begin
        try
          let program = parse_program_files input_paths in
          print_endline (Printf.sprintf "parsed %d items" (List.length program));
          0
        with
        | Sys_error message ->
            prerr_endline ("error: parse: " ^ message);
            2
        | Lexer.Error (message, line, column) ->
            prerr_endline (Printf.sprintf "error: parse: %s at %d:%d" message line column);
            2
        | Parser.Error (message, tok) ->
            prerr_endline
              (Printf.sprintf "error: parse: %s at %d:%d near %s" message tok.line tok.column
                 (Token.string_of_kind tok.kind));
            2
      end

let run_command command =
  match Unix.system command with
  | Unix.WEXITED 0 -> Ok ()
  | Unix.WEXITED code -> Error (Printf.sprintf "command failed with exit code %d" code)
  | Unix.WSIGNALED signal -> Error (Printf.sprintf "command killed by signal %d" signal)
  | Unix.WSTOPPED signal -> Error (Printf.sprintf "command stopped by signal %d" signal)

let command_compile args =
  match parse_compile_options args with
  | Error message ->
      prerr_endline ("error: compile: " ^ message);
      2
  | Ok options ->
      begin
        try
          let program = parse_program_files options.input_paths in
          let _ = Sema.analyze program in
          let generated = Codegen.emit_program program in
          let ml_path = "/tmp/tgc0_debug.ml" in
          write_file ml_path generated;
          let command =
            if Sys.command "command -v ocamlopt >/dev/null 2>&1" = 0 then
              Printf.sprintf "ocamlopt -o %s %s" (shell_quote options.output_path) (shell_quote ml_path)
            else if Sys.command "command -v opam >/dev/null 2>&1" = 0 then
              Printf.sprintf "opam exec -- ocamlopt -o %s %s" (shell_quote options.output_path)
                (shell_quote ml_path)
            else
              raise (Failure "unable to locate ocamlopt or opam for native code generation")
          in
          let exit_code =
            match run_command command with
            | Ok () ->
                Unix.chmod options.output_path 0o755;
                Sys.remove ml_path;
                0
            | Error message ->
                prerr_endline ("error: compile: " ^ message);
                prerr_endline ("debug: generated OCaml saved to: " ^ ml_path);
                2
          in
          exit_code
        with
        | Sys_error message ->
            prerr_endline ("error: compile: " ^ message);
            2
        | Lexer.Error (message, line, column) ->
            prerr_endline (Printf.sprintf "error: compile: %s at %d:%d" message line column);
            2
        | Parser.Error (message, tok) ->
            prerr_endline
              (Printf.sprintf "error: compile: %s at %d:%d near %s" message tok.line tok.column
                 (Token.string_of_kind tok.kind));
            2
        | Sema.Error message ->
            prerr_endline ("error: compile: " ^ message);
            2
        | Failure message ->
            prerr_endline ("error: compile: " ^ message);
            2
        | exn ->
            prerr_endline (Printf.sprintf "error: compile: %s" (Printexc.to_string exn));
            2
      end

let usage () =
  print_endline "Usage:";
  print_endline "  main.exe --version";
  print_endline "  main.exe wrap -o <output>";
  print_endline "  main.exe build [--wrapper] [-o <output>] [--target <triple>]";
  print_endline "  main.exe parse <input.tg> [more.tg ...]";
  print_endline "  main.exe compile <input.tg> [more.tg ...] [-o <output>]"

let () =
  match Array.to_list Sys.argv with
  | [_] ->
      usage ();
      exit 0
  | [_; "--version"] ->
      print_endline version;
      exit 0
  | [_; "wrap"; rest1; rest2]
    when rest1 = "-o" ->
      exit (command_wrap [rest1; rest2])
  | _ :: "wrap" :: rest -> exit (command_wrap rest)
  | _ :: "build" :: rest -> exit (command_build rest)
  | _ :: "parse" :: rest -> exit (command_parse rest)
  | _ :: "compile" :: rest -> exit (command_compile rest)
  | _ ->
      usage ();
      exit 2
