(** Diagnostic reporting for the Tangerine compiler *)

type severity =
  | Error
  | Warning
  | Note
  | Help
[@@deriving show, eq]

type diagnostic = {
  severity : severity;
  message : string;
  location : Location.t;
  notes : (Location.t option * string) list;
  suggestions : (Location.t * string * string) list;  (* loc, label, replacement *)
}

let create ?(notes = []) ?(suggestions = []) severity message location =
  { severity; message; location; notes; suggestions }

let error = create Error
let warning = create Warning
let note = create Note

(** ANSI color codes *)
module Color = struct
  let reset = "\027[0m"
  let bold = "\027[1m"
  let red = "\027[31m"
  let yellow = "\027[33m"
  let blue = "\027[34m"
  let cyan = "\027[36m"
  let white = "\027[37m"
  
  let colorize ~enable color text =
    if enable then color ^ text ^ reset else text
end

(** Format severity with color *)
let pp_severity ~colors fmt sev =
  let (color, text) = match sev with
    | Error -> (Color.red, "error")
    | Warning -> (Color.yellow, "warning")
    | Note -> (Color.blue, "note")
    | Help -> (Color.cyan, "help")
  in
  Format.fprintf fmt "%s%s%s: "
    (if colors then Color.bold ^ color else "")
    text
    (if colors then Color.reset else "")

(** Read a line from a file *)
let read_line_from_file filename line_num =
  try
    let ic = open_in filename in
    let rec read_until n =
      let line = input_line ic in
      if n = line_num then (close_in ic; Some line)
      else read_until (n + 1)
    in
    try read_until 1
    with End_of_file -> close_in ic; None
  with Sys_error _ -> None

(** Print source snippet with caret *)
let pp_source_snippet ~colors fmt loc =
  match read_line_from_file loc.Location.file loc.start.line with
  | None -> ()
  | Some line ->
    let line_num_str = string_of_int loc.start.line in
    let padding = String.make (String.length line_num_str) ' ' in
    
    (* Print line number and source *)
    Format.fprintf fmt "%s%s |%s\n" 
      (if colors then Color.blue else "") line_num_str
      (if colors then Color.reset else "");
    Format.fprintf fmt "%s | %s\n" padding line;
    
    (* Print caret *)
    let caret_pos = loc.start.column in
    let caret_len = max 1 (loc.stop.column - loc.start.column) in
    Format.fprintf fmt "%s | %s%s%s%s\n"
      padding
      (String.make caret_pos ' ')
      (if colors then Color.bold ^ Color.red else "")
      (String.make caret_len '^')
      (if colors then Color.reset else "")

(** Pretty print a diagnostic *)
let pp ~colors fmt diag =
  (* Main error message *)
  pp_severity ~colors fmt diag.severity;
  Format.fprintf fmt "%s%s%s\n"
    (if colors then Color.bold else "")
    diag.message
    (if colors then Color.reset else "");
  
  (* Location *)
  Format.fprintf fmt "%s  --> %s:%d:%d%s\n"
    (if colors then Color.blue else "")
    diag.location.file
    diag.location.start.line
    diag.location.start.column
    (if colors then Color.reset else "");
  
  (* Source snippet *)
  pp_source_snippet ~colors fmt diag.location;
  
  (* Additional notes *)
  List.iter (fun (loc_opt, msg) ->
    Format.fprintf fmt "%s   = %s%s: %s\n"
      (if colors then Color.blue else "")
      (if colors then Color.reset else "")
      "note"
      msg;
    match loc_opt with
    | Some loc -> pp_source_snippet ~colors fmt loc
    | None -> ()
  ) diag.notes;
  
  (* Suggestions *)
  List.iter (fun (loc, label, replacement) ->
    Format.fprintf fmt "%s   = %shelp%s: %s\n"
      (if colors then Color.cyan else "")
      (if colors then Color.reset else "")
      (if colors then Color.reset else "")
      label;
    ignore (loc, replacement)
  ) diag.suggestions;
  
  Format.fprintf fmt "\n"

(** Print diagnostic to stderr *)
let emit ?(colors = true) diag =
  pp ~colors Format.err_formatter diag;
  Format.pp_print_flush Format.err_formatter ()

(** Convert type check error to diagnostic *)
let of_type_error err : diagnostic =
  match err with
  | Typecheck.UnboundVariable (name, loc) ->
    error (Printf.sprintf "cannot find value `%s` in this scope" name) loc
  | Typecheck.UnboundType (name, loc) ->
    error (Printf.sprintf "cannot find type `%s` in this scope" name) loc
  | Typecheck.UnboundFunction (name, loc) ->
    error (Printf.sprintf "cannot find function `%s` in this scope" name) loc
  | Typecheck.TypeMismatch (t1, t2, loc) ->
    error 
      (Printf.sprintf "mismatched types: expected `%s`, found `%s`"
        (Types.to_string t1) (Types.to_string t2)) 
      loc
  | Typecheck.OccursCheck (_, ty, loc) ->
    error 
      (Printf.sprintf "cyclic type detected involving `%s`" (Types.to_string ty))
      loc
  | Typecheck.ArityMismatch (expected, got, loc) ->
    error
      (Printf.sprintf "wrong number of arguments: expected %d, found %d" expected got)
      loc
  | Typecheck.NotAFunction (ty, loc) ->
    error 
      (Printf.sprintf "expected function, found `%s`" (Types.to_string ty))
      loc
  | Typecheck.NotAStruct (ty, loc) ->
    error
      (Printf.sprintf "expected struct, found `%s`" (Types.to_string ty))
      loc
  | Typecheck.NotAnEnum (ty, loc) ->
    error
      (Printf.sprintf "expected enum, found `%s`" (Types.to_string ty))
      loc
  | Typecheck.UnknownField (field, struct_name, loc) ->
    error
      (Printf.sprintf "struct `%s` has no field named `%s`" struct_name field)
      loc
  | Typecheck.UnknownVariant (variant, enum_name, loc) ->
    error
      (Printf.sprintf "enum `%s` has no variant named `%s`" enum_name variant)
      loc
  | Typecheck.MissingField (field, struct_name, loc) ->
    error
      (Printf.sprintf "missing field `%s` in initializer of `%s`" field struct_name)
      loc
  | Typecheck.DuplicateField (field, loc) ->
    error
      (Printf.sprintf "field `%s` is initialized more than once" field)
      loc
  | Typecheck.CannotMutate (name, loc) ->
    error
      (Printf.sprintf "cannot mutate immutable variable `%s`" name)
      loc
  | Typecheck.MissingCapability (cap, loc) ->
    error
      (Printf.sprintf "missing required capability `%s`" cap)
      loc
  | Typecheck.MissingEffect (eff, loc) ->
    error
      (Printf.sprintf "effect `%s` is not handled" eff)
      loc
  | Typecheck.GuardMustDiverge loc ->
    error "guard else action must diverge (return, break, next, or panic)" loc
  | Typecheck.PureViolation (reason, loc) ->
    error
      (Printf.sprintf "pure function violation: %s" reason)
      loc
  | Typecheck.ContractError (msg, loc) ->
    error
      (Printf.sprintf "contract error: %s" msg)
      loc

(** Statistics *)
type stats = {
  mutable errors : int;
  mutable warnings : int;
}

let stats = { errors = 0; warnings = 0 }

let reset_stats () =
  stats.errors <- 0;
  stats.warnings <- 0

let emit_and_count ?(colors = true) diag =
  begin match diag.severity with
  | Error -> stats.errors <- stats.errors + 1
  | Warning -> stats.warnings <- stats.warnings + 1
  | Note | Help -> ()
  end;
  emit ~colors diag

let has_errors () = stats.errors > 0

let summary () =
  if stats.errors > 0 || stats.warnings > 0 then
    Printf.eprintf "error: aborting due to %d error%s and %d warning%s\n"
      stats.errors (if stats.errors = 1 then "" else "s")
      stats.warnings (if stats.warnings = 1 then "" else "s")
