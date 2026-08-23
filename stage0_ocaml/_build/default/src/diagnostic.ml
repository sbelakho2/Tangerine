(* diagnostic.ml — Diagnostics and the diagnostic bag.

   Rendered format (per diagnostic, two lines):
     severity[code]: message
       --> file:line:column
   where file:line:column resolve through the source map, or <unknown> for
   synthetic/unresolvable spans. *)

type severity = Error | Warning | Note

let severity_string = function
  | Error -> "error"
  | Warning -> "warning"
  | Note -> "note"

type diagnostic = {
  severity : severity;
  code : string;
  message : string;
  span : Span.span;
}

type bag = {
  mutable diagnostics : diagnostic list;  (* reversed; emission order *)
}

let create_bag () = { diagnostics = [] }

let emit (b : bag) sev code message span =
  b.diagnostics <- { severity = sev; code; message; span } :: b.diagnostics

let error b code message span = emit b Error code message span
let warning b code message span = emit b Warning code message span

let error_count b =
  List.fold_left (fun n d -> if d.severity = Error then n + 1 else n) 0 b.diagnostics

let warning_count b =
  List.fold_left (fun n d -> if d.severity = Warning then n + 1 else n) 0 b.diagnostics

let has_errors b = error_count b > 0
let has_warnings b = warning_count b > 0

let codes b =
  let module SSet = Set.Make (String) in
  let set =
    List.fold_left
      (fun s d -> if d.severity = Error then SSet.add d.code s else s)
      SSet.empty b.diagnostics
  in
  SSet.elements set

let render_one sm d =
  let loc =
    match Span.resolve sm d.span with
    | Some (file, line, col) -> Printf.sprintf "%s:%d:%d" file line col
    | None -> "<unknown>"
  in
  Printf.sprintf "%s[%s]: %s\n  --> %s"
    (severity_string d.severity) d.code d.message loc

let render sm b =
  (* Emission order: the bag stores reversed, so restore. *)
  let ds = List.rev b.diagnostics in
  String.concat "\n" (List.map (render_one sm) ds)
