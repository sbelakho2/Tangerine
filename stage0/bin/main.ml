(** Tangerine compiler CLI *)

open Cmdliner

let version = Tangerine.version

(** Input files argument *)
let input_files =
  let doc = "Tangerine source files to compile" in
  Arg.(value & pos_all file [] & info [] ~docv:"FILE" ~doc)

(** Output file option *)
let output_file =
  let doc = "Write output to $(docv)" in
  Arg.(value & opt (some string) None & info ["o"; "output"] ~docv:"FILE" ~doc)

(** Output kind option *)
let emit =
  let doc = "Specify the type of output" in
  let emit_conv = Arg.enum [
    ("ast", Tangerine.Driver.Ast);
    ("typed-ast", Tangerine.Driver.TypedAst);
    ("mir", Tangerine.Driver.Mir);
    ("asm", Tangerine.Driver.Asm);
    ("obj", Tangerine.Driver.Object);
    ("exe", Tangerine.Driver.Executable);
  ] in
  Arg.(value & opt emit_conv Tangerine.Driver.Executable &
       info ["emit"] ~docv:"KIND" ~doc)

(** Dump AST flag *)
let dump_ast =
  let doc = "Dump the AST to stdout" in
  Arg.(value & flag & info ["dump-ast"] ~doc)

(** Dump MIR flag *)
let dump_mir =
  let doc = "Dump the MIR to stdout" in
  Arg.(value & flag & info ["dump-mir"] ~doc)

(** Verbose flag *)
let verbose =
  let doc = "Enable verbose output" in
  Arg.(value & flag & info ["v"; "verbose"] ~doc)

(** Optimization level *)
let opt_level =
  let doc = "Optimization level (0-3)" in
  Arg.(value & opt int 0 & info ["O"] ~docv:"LEVEL" ~doc)

(** Debug info flag *)
let debug_info =
  let doc = "Generate debug information" in
  Arg.(value & flag & info ["g"] ~doc)

(** No color flag *)
let no_color =
  let doc = "Disable colored output" in
  Arg.(value & flag & info ["no-color"] ~doc)

(** Edition option *)
let edition =
  let doc = "Set the language edition (e.g., 2026)" in
  Arg.(value & opt (some int) None & info ["edition"] ~docv:"YEAR" ~doc)

(** Main compilation function *)
let compile input_files output_file emit dump_ast dump_mir verbose opt_level debug_info no_color edition =
  if input_files = [] then begin
    Printf.eprintf "error: no input files\n";
    `Error (false, "no input files")
  end else begin
    let opts = Tangerine.Driver.{
      input_files;
      output_file;
      output_kind = emit;
      dump_ast;
      dump_mir;
      colors = not no_color;
      verbose;
      opt_level;
      debug_info;
      edition;
    } in
    let exit_code = Tangerine.Driver.compile opts in
    `Ok exit_code
  end

(** Command term *)
let compile_t =
  Term.(ret (const compile $ input_files $ output_file $ emit $ dump_ast $
             dump_mir $ verbose $ opt_level $ debug_info $ no_color $ edition))

(** Command info *)
let info =
  let doc = "The Tangerine compiler (stage0 bootstrap)" in
  let man = [
    `S Manpage.s_description;
    `P "tgc is the stage0 bootstrap compiler for the Tangerine programming language.";
    `P "This compiler is written in OCaml and is used to bootstrap the self-hosted \
        Tangerine compiler.";
    `S Manpage.s_examples;
    `P "Compile a source file:";
    `Pre "  tgc hello.tg";
    `P "Dump the AST:";
    `Pre "  tgc --dump-ast hello.tg";
    `P "Dump the MIR:";
    `Pre "  tgc --dump-mir hello.tg";
    `S Manpage.s_bugs;
    `P "Report bugs at https://github.com/tangerine-lang/tangerine/issues";
  ] in
  Cmd.info "tgc" ~version ~doc ~man

(** Main command *)
let cmd = Cmd.v info compile_t

(** Entry point *)
let () = exit (Cmd.eval_result cmd |> function
  | Ok code -> code
  | Error _ -> 1)
