(* source_loader.ml — Source loading with the E9029 UTF-8 gate (INV-PARSE-002). *)

type load_error = Unreadable of string | NotUTF8 of string

let load (path : string) : (string, load_error) result =
  try
    let ic = open_in_bin path in
    let n = in_channel_length ic in
    let s = really_input_string ic n in
    close_in ic;
    if Lexer.is_valid_utf8 s then Ok s else Error (NotUTF8 path)
  with Sys_error _ -> Error (Unreadable path)
