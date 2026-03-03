type severity = Error | Warning

type t = {
  severity : severity;
  code : string;
  file : string;
  line : int;
  col : int;
  message : string;
}

let make ?(severity = Error) ?(code = "E100") ~file ~line ~col message =
  { severity; code; file; line; col; message }

let is_error d = d.severity = Error

let render d =
  let prefix =
    match d.severity with
    | Error -> Printf.sprintf "error[%s]" d.code
    | Warning -> Printf.sprintf "warning[%s]" d.code
  in
  Printf.sprintf "%s: %s\n  --> %s:%d:%d" prefix d.message d.file d.line d.col

let print d = print_endline (render d)

let print_all ds = List.iter print ds

let count_errors ds = List.fold_left (fun acc d -> if is_error d then acc + 1 else acc) 0 ds
let count_warnings ds = List.fold_left (fun acc d -> if is_error d then acc else acc + 1) 0 ds
