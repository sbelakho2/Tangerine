(** Tangerine stage0 compiler library *)

(** {1 Core modules} *)

module Location = Location
module Ast = Ast
module Types = Types
module Env = Env

(** {1 Frontend} *)

module Lexer = Lexer
module Parser = Parser
module Source = Source

(** {1 Type System} *)

module Typecheck = Typecheck

(** {1 Mid-level IR} *)

module Mir = Mir
module Lower = Lower

(** {1 Diagnostics} *)

module Diagnostics = Diagnostics

(** {1 Driver} *)

module Driver = Driver

(** {1 Version info} *)

let version = "0.1.0"
let edition = 2026

(** Quick compile function for simple use cases *)
let compile_file ?(verbose = false) ?(dump_ast = false) ?(dump_mir = false) filename =
  let opts = Driver.{
    input_files = [filename];
    output_file = None;
    output_kind = Mir;
    dump_ast;
    dump_mir;
    colors = true;
    verbose;
    opt_level = 0;
    debug_info = false;
    edition = Some 2026;
  } in
  Driver.compile opts
