(** Source location tracking for error reporting *)

type position = {
  line : int;
  column : int;
  offset : int;
}
[@@deriving show, eq, ord]

type t = {
  file : string;
  start : position;
  stop : position;
}
[@@deriving show, eq, ord]

let dummy = {
  file = "<dummy>";
  start = { line = 0; column = 0; offset = 0 };
  stop = { line = 0; column = 0; offset = 0 };
}

let create ~file ~start_line ~start_col ~end_line ~end_col =
  {
    file;
    start = { line = start_line; column = start_col; offset = 0 };
    stop = { line = end_line; column = end_col; offset = 0 };
  }

let of_lexing_positions ~file start_pos end_pos =
  let open Lexing in
  {
    file;
    start = {
      line = start_pos.pos_lnum;
      column = start_pos.pos_cnum - start_pos.pos_bol;
      offset = start_pos.pos_cnum;
    };
    stop = {
      line = end_pos.pos_lnum;
      column = end_pos.pos_cnum - end_pos.pos_bol;
      offset = end_pos.pos_cnum;
    };
  }

let merge loc1 loc2 =
  { file = loc1.file; start = loc1.start; stop = loc2.stop }

let pp_short fmt loc =
  Format.fprintf fmt "%s:%d:%d" loc.file loc.start.line loc.start.column

let to_string loc =
  Format.asprintf "%a" pp_short loc
