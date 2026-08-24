(* source_loader.ml — Loading sources with strict validation.

   Open binary, read exact bytes, close under Fun.protect, validate strict
   UTF-8, run a security scan, and construct a Source. The lexer is never
   responsible for validating the file it receives. *)

type load_error =
  | Unreadable of string
  | NotUTF8 of string * Utf8.error
  | Security of string * string

let security_scan (name : string) (bytes : Bytes.t) : (unit, load_error) result =
  let n = Bytes.length bytes in
  let i = ref 0 in
  let bad = ref None in
  while !i < n && !bad = None do
    let b = Char.code (Bytes.get bytes !i) in
    if b = 0 then bad := Some "NUL byte in source"
    else if b = 0x1A then bad := Some "control-Z byte in source"
    else incr i
  done;
  match !bad with
  | Some msg -> Error (Security (name, msg))
  | None -> Ok ()

let load (path : string) : (Source.source, load_error) result =
  try
    let ic = open_in_bin path in
    Fun.protect
      ~finally:(fun () -> close_in_noerr ic)
      (fun () ->
        let n = in_channel_length ic in
        let bytes = really_input_string ic n |> Bytes.of_string in
        match Utf8.validate bytes with
        | Error e -> Error (NotUTF8 (path, e))
        | Ok () -> (
            match security_scan path bytes with
            | Error e -> Error e
            | Ok () ->
                Ok (Source.of_bytes ~name:path ~bytes:(Bytes.to_string bytes))))
  with Sys_error msg -> Error (Unreadable (path ^ ": " ^ msg))

let load_string (name : string) (content : string) : (Source.source, load_error) result =
  let bytes = Bytes.of_string content in
  match Utf8.validate bytes with
  | Error e -> Error (NotUTF8 (name, e))
  | Ok () -> (
      match security_scan name bytes with
      | Error e -> Error e
      | Ok () -> Ok (Source.of_bytes ~name ~bytes:content))
