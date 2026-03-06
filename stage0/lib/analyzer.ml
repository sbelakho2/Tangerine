type result = {
  diagnostics : Diagnostics.t list;
}

let trim_left s =
  let n = String.length s in
  let rec loop i =
    if i >= n then n
    else
      match s.[i] with
      | ' ' | '\t' -> loop (i + 1)
      | _ -> i
  in
  let i = loop 0 in
  if i = 0 then s else String.sub s i (n - i)

let starts_with s prefix =
  let n = String.length s and m = String.length prefix in
  n >= m && String.sub s 0 m = prefix

let extract_name line prefix =
  if not (starts_with line prefix) then None
  else
    let rest = String.sub line (String.length prefix) (String.length line - String.length prefix) in
    let rest = trim_left rest in
    let n = String.length rest in
    let rec end_idx i =
      if i >= n then i
      else
        match rest.[i] with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> end_idx (i + 1)
        | _ -> i
    in
    let k = end_idx 0 in
    if k = 0 then None else Some (String.sub rest 0 k)

let is_top_level raw_line =
  String.length raw_line > 0 && raw_line.[0] <> ' ' && raw_line.[0] <> '\t'

let indent_of raw_line =
  let n = String.length raw_line in
  let rec loop i =
    if i >= n then n
    else
      match raw_line.[i] with
      | ' ' | '\t' -> loop (i + 1)
      | _ -> i
  in
  loop 0

let lower s = String.lowercase_ascii s

let first_word line =
  let t = trim_left line in
  let n = String.length t in
  let rec end_idx i =
    if i >= n then i
    else
      match t.[i] with
      | 'a' .. 'z' | 'A' .. 'Z' | '_' -> end_idx (i + 1)
      | _ -> i
  in
  let k = end_idx 0 in
  if k = 0 then "" else String.sub t 0 k

let is_end_line line =
  let t = trim_left line in
  starts_with t "end"

let is_doc_or_comment line =
  let t = trim_left line in
  starts_with t "#"

let enum_variant_name line =
  let t = trim_left line in
  if t = "" || is_doc_or_comment t then None
  else if starts_with t "end" then None
  else
    let n = String.length t in
    let rec end_idx i =
      if i >= n then i
      else
        match t.[i] with
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> end_idx (i + 1)
        | _ -> i
    in
    let k = end_idx 0 in
    if k = 0 then None
    else
      let name = String.sub t 0 k in
      if lower name = "when" then None else Some name

let struct_field_name line =
  let t = trim_left line in
  if t = "" || is_doc_or_comment t || starts_with t "end" then None
  else
    let t = if starts_with t "pub " then String.sub t 4 (String.length t - 4) |> trim_left else t in
    let t = if starts_with t "mut " then String.sub t 4 (String.length t - 4) |> trim_left else t in
    let n = String.length t in
    let rec sep i =
      if i >= n then -1
      else if t.[i] = ':' then i
      else sep (i + 1)
    in
    let c = sep 0 in
    if c <= 0 then None
    else
      let raw = String.sub t 0 c |> trim_left in
      let m = String.length raw in
      let rec end_idx i =
        if i >= m then i
        else
          match raw.[i] with
          | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' -> end_idx (i + 1)
          | _ -> i
      in
      let k = end_idx 0 in
      if k = 0 then None else Some (String.sub raw 0 k)

let match_literal_key line =
  let t = trim_left line in
  if not (starts_with t "when ") then None
  else
    let after = String.sub t 5 (String.length t - 5) |> trim_left in
    let n = String.length after in
    let rec find_then i =
      if i + 5 > n then -1
      else if after.[i] = '"' then
        (* Skip past closing quote, handling escapes *)
        let rec skip_str j =
          if j >= n then j
          else if after.[j] = '\\' then skip_str (j + 2)
          else if after.[j] = '"' then j + 1
          else skip_str (j + 1)
        in
        find_then (skip_str (i + 1))
      else if after.[i] = '\'' then
        (* Skip past closing single quote *)
        let rec skip_char j =
          if j >= n then j
          else if after.[j] = '\\' then skip_char (j + 2)
          else if after.[j] = '\'' then j + 1
          else skip_char (j + 1)
        in
        find_then (skip_char (i + 1))
      else if String.sub after i 5 = " then " then i
      else find_then (i + 1)
    in
    let p =
      if n >= 5 && String.sub after 0 5 = "_ then" then 1
      else find_then 0
    in
    if p < 0 then None
    else
      let pat =
        if p = 1 then "_"
        else String.sub after 0 p |> trim_left
      in
      let pat =
        if String.length pat > 0 && pat.[String.length pat - 1] = ' ' then String.trim pat else pat
      in
      if pat = "" then None
      else
        let is_literal =
          pat = "true" || pat = "false" || pat = "nil"
          || (String.length pat > 1 && pat.[0] = '"' && pat.[String.length pat - 1] = '"')
          || (String.length pat > 2 && pat.[0] = '\'' && pat.[String.length pat - 1] = '\'')
          ||
          let c0 = pat.[0] in
          (c0 >= '0' && c0 <= '9') || c0 = '-'
        in
        if is_literal then Some pat else None

type scope =
  | ScopeEnum of int * string * (string, int) Hashtbl.t
  | ScopeStruct of int * string * (string, int) Hashtbl.t
  | ScopeMatch of int * (string, int) Hashtbl.t
  | ScopeOther of int

let analyze_source ~file (source : string) : result =
  let lines = String.split_on_char '\n' source in
  let seen : (string, (string, int) Hashtbl.t) Hashtbl.t = Hashtbl.create 8 in
  let diagnostics = ref [] in
  let scopes : scope list ref = ref [] in

  let warn ~code ~line ~col msg =
    diagnostics :=
      Diagnostics.make ~severity:Diagnostics.Warning ~code ~file ~line ~col msg
      :: !diagnostics
  in

  let note_decl kind name line =
    let kind_map =
      match Hashtbl.find_opt seen kind with
      | Some m -> m
      | None ->
          let m = Hashtbl.create 64 in
          Hashtbl.replace seen kind m;
          m
    in
    match Hashtbl.find_opt kind_map name with
    | Some prev_line ->
        warn ~code:"W210" ~line ~col:1
          (Printf.sprintf "duplicate top-level %s '%s' (previous at line %d)" kind name prev_line)
    | None -> Hashtbl.replace kind_map name line
  in

  let push_scope s = scopes := s :: !scopes in

  let pop_scope_by_indent indent =
    let rec loop acc = function
      | [] -> List.rev acc
      | (ScopeEnum (i, _, _) as s) :: tl ->
        if i >= indent then loop acc tl else List.rev_append acc (s :: tl)
      | (ScopeStruct (i, _, _) as s) :: tl ->
        if i >= indent then loop acc tl else List.rev_append acc (s :: tl)
      | (ScopeMatch (i, _) as s) :: tl ->
        if i >= indent then loop acc tl else List.rev_append acc (s :: tl)
      | (ScopeOther i as s) :: tl ->
        if i >= indent then loop acc tl else List.rev_append acc (s :: tl)
    in
    scopes := loop [] !scopes
  in

  let has_tabs = ref false in
  let has_spaces_indent = ref false in

  List.iteri
    (fun idx raw_line ->
      let line_no = idx + 1 in
      let indent = indent_of raw_line in
      let trimmed = trim_left raw_line in

      if is_end_line trimmed then pop_scope_by_indent indent;

      if String.length raw_line > 0 then begin
        if raw_line.[0] = '\t' then has_tabs := true;
        if raw_line.[0] = ' ' then has_spaces_indent := true;
      end;

      (match !scopes with
       | ScopeEnum (_, enum_name, seen_variants) :: _ ->
           (match enum_variant_name raw_line with
            | Some name ->
                (match Hashtbl.find_opt seen_variants name with
                 | Some prev ->
                     warn ~code:"W212" ~line:line_no ~col:1
                       (Printf.sprintf "duplicate enum variant '%s' in enum '%s' (previous at line %d)" name enum_name prev)
                 | None -> Hashtbl.replace seen_variants name line_no)
            | None -> ())
       | ScopeStruct (_, struct_name, seen_fields) :: _ ->
           (match struct_field_name raw_line with
            | Some name ->
                (match Hashtbl.find_opt seen_fields name with
                 | Some prev ->
                     warn ~code:"W213" ~line:line_no ~col:1
                       (Printf.sprintf "duplicate struct field '%s' in struct '%s' (previous at line %d)" name struct_name prev)
                 | None -> Hashtbl.replace seen_fields name line_no)
            | None -> ())
       | ScopeMatch (_, seen_literals) :: _ ->
           (match match_literal_key raw_line with
            | Some lit ->
                (match Hashtbl.find_opt seen_literals lit with
                 | Some prev ->
                     warn ~code:"W214" ~line:line_no ~col:1
                       (Printf.sprintf "duplicate literal match arm '%s' (previous at line %d)" lit prev)
                 | None -> Hashtbl.replace seen_literals lit line_no)
            | None -> ())
       | _ -> ());

      if is_top_level raw_line then begin
        let line = trimmed in
        let opened_decl, opened_name =
          let try_one kind prefix =
            match extract_name line prefix with
            | Some name ->
                note_decl kind name line_no;
                Some (kind, name)
            | None -> None
          in
          match try_one "module" "module " with
          | Some (k, n) -> (Some k, Some n)
          | None ->
              (match try_one "def" "def " with
               | Some (k, n) -> (Some k, Some n)
               | None ->
                   (match try_one "struct" "struct " with
                    | Some (k, n) -> (Some k, Some n)
                    | None ->
                        (match try_one "enum" "enum " with
                         | Some (k, n) -> (Some k, Some n)
                         | None ->
                             (match try_one "trait" "trait " with
                              | Some (k, n) -> (Some k, Some n)
                              | None -> (None, None)))))
        in
        (match opened_decl with
         | Some "enum" ->
             let name = Option.value ~default:"<anonymous>" opened_name in
             push_scope (ScopeEnum (indent, name, Hashtbl.create 64))
         | Some "struct" ->
             let name = Option.value ~default:"<anonymous>" opened_name in
             push_scope (ScopeStruct (indent, name, Hashtbl.create 64))
         | Some _ -> push_scope (ScopeOther indent)
         | None ->
             let w = first_word line in
             if w = "match" then push_scope (ScopeMatch (indent, Hashtbl.create 32))
             else if w <> "" && w <> "end" then push_scope (ScopeOther indent));
      end else begin
        let w = first_word trimmed in
        if w = "match" then push_scope (ScopeMatch (indent, Hashtbl.create 32));
      end)
    lines;

  if !has_tabs && !has_spaces_indent then
    warn ~code:"W211" ~line:1 ~col:1
      "mixed indentation style detected (tabs and spaces at line starts)";

  { diagnostics = List.rev !diagnostics }
