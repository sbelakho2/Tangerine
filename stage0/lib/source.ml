(** Source file reading and handling *)

type source_file = {
  path : string;
  content : string;
  lines : string array;
}

let read_file path =
  let ic = open_in path in
  let n = in_channel_length ic in
  let content = really_input_string ic n in
  close_in ic;
  let lines = String.split_on_char '\n' content |> Array.of_list in
  { path; content; lines }

let get_line src line_num =
  if line_num >= 1 && line_num <= Array.length src.lines then
    Some src.lines.(line_num - 1)
  else
    None

let lexbuf_of_source src =
  let lexbuf = Lexing.from_string src.content in
  lexbuf.Lexing.lex_curr_p <- {
    Lexing.pos_fname = src.path;
    pos_lnum = 1;
    pos_bol = 0;
    pos_cnum = 0;
  };
  lexbuf
