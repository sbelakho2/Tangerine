type request = {
  id_raw : string option;
  method_name : string option;
  body : string;
}

let starts_with s prefix =
  let n = String.length s and m = String.length prefix in
  n >= m && String.sub s 0 m = prefix

let find_sub s sub from_i =
  let n = String.length s and m = String.length sub in
  let rec loop i =
    if i + m > n then None
    else if String.sub s i m = sub then Some i
    else loop (i + 1)
  in
  loop from_i

let skip_ws body j =
  let n = String.length body in
  let rec loop k =
    if k < n && (body.[k] = ' ' || body.[k] = '\n' || body.[k] = '\r' || body.[k] = '\t') then loop (k + 1)
    else k
  in
  loop j

let extract_json_string_field body field_name =
  let key = Printf.sprintf "\"%s\"" field_name in
  match find_sub body key 0 with
  | None -> None
  | Some i ->
      let n = String.length body in
      let j0 = skip_ws body (i + String.length key) in
      if j0 >= n || body.[j0] <> ':' then None
      else
        let j1 = skip_ws body (j0 + 1) in
        if j1 >= n || body.[j1] <> '"' then None
        else
          let rec scan j escaped =
            if j >= n then None
            else
              let c = body.[j] in
              if escaped then scan (j + 1) false
              else if c = '\\' then scan (j + 1) true
              else if c = '"' then Some j
              else scan (j + 1) false
          in
          match scan (j1 + 1) false with
          | None -> None
          | Some j2 -> Some (String.sub body (j1 + 1) (j2 - j1 - 1))

let extract_json_id_raw body =
  let key = "\"id\"" in
  match find_sub body key 0 with
  | None -> None
  | Some i ->
      let n = String.length body in
      let j0 = skip_ws body (i + String.length key) in
      if j0 >= n || body.[j0] <> ':' then None
      else
      let j = skip_ws body (j0 + 1) in
      if j >= n then None
      else
        if body.[j] = '"' then begin
          let rec scan k escaped =
            if k >= n then None
            else
              let c = body.[k] in
              if escaped then scan (k + 1) false
              else if c = '\\' then scan (k + 1) true
              else if c = '"' then Some k
              else scan (k + 1) false
          in
          match scan (j + 1) false with
          | None -> None
          | Some k -> Some (String.sub body j (k - j + 1))
        end else begin
          let rec end_idx k =
            if k >= n then k
            else
              match body.[k] with
              | ',' | '}' | '\n' | '\r' -> k
              | _ -> end_idx (k + 1)
          in
          let k = end_idx j in
          if k <= j then None else Some (String.trim (String.sub body j (k - j)))
        end

let read_header_content_length ic =
  let max_header_lines = 64 in
  let rec loop content_length remaining =
    if remaining <= 0 then content_length  (* guard against malformed input *)
    else
    let line = input_line ic in
    let line_trimmed = String.trim line in
    if line_trimmed = "" then content_length
    else if starts_with (String.lowercase_ascii line_trimmed) "content-length:" then
      let v = String.trim (String.sub line_trimmed 15 (String.length line_trimmed - 15)) in
      loop (int_of_string_opt v) (remaining - 1)
    else
      loop content_length (remaining - 1)
  in
  try loop None max_header_lines with End_of_file -> None

let read_exact ic n =
  let buf = Bytes.create n in
  really_input ic buf 0 n;
  Bytes.to_string buf

let parse_request body =
  let id_raw = extract_json_id_raw body in
  let method_name = extract_json_string_field body "method" in
  { id_raw; method_name; body }

let send_json oc json =
  let payload = json in
  Printf.fprintf oc "Content-Length: %d\r\n\r\n%s%!" (String.length payload) payload

let send_response oc id_raw result_json =
  let id_part = match id_raw with Some s -> s | None -> "null" in
  let json =
    Printf.sprintf "{\"jsonrpc\":\"2.0\",\"id\":%s,\"result\":%s}" id_part result_json
  in
  send_json oc json

let json_escape_string s =
  let buf = Buffer.create (String.length s * 2) in
  String.iter (fun c ->
    match c with
    | '"' -> Buffer.add_string buf "\\\""
    | '\\' -> Buffer.add_string buf "\\\\"
    | '\n' -> Buffer.add_string buf "\\n"
    | '\r' -> Buffer.add_string buf "\\r"
    | '\t' -> Buffer.add_string buf "\\t"
    | c when Char.code c < 0x20 ->
      Buffer.add_string buf (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char buf c
  ) s;
  Buffer.contents buf

let send_error oc id_raw code message =
  let id_part = match id_raw with Some s -> s | None -> "null" in
  let msg = json_escape_string message in
  let json =
    Printf.sprintf
      "{\"jsonrpc\":\"2.0\",\"id\":%s,\"error\":{\"code\":%d,\"message\":\"%s\"}}"
      id_part code msg
  in
  send_json oc json

let initialize_result =
  "{" ^
  "\"capabilities\":{" ^
    "\"textDocumentSync\":1," ^
    "\"hoverProvider\":true," ^
    "\"definitionProvider\":true," ^
    "\"referencesProvider\":true," ^
    "\"renameProvider\":true," ^
    "\"documentFormattingProvider\":true," ^
    "\"signatureHelpProvider\":{\"triggerCharacters\":[\"(\",\",\"]}," ^
    "\"completionProvider\":{\"resolveProvider\":false,\"triggerCharacters\":[\".\",\":\"]}," ^
    "\"codeActionProvider\":true" ^
  "}," ^
  "\"serverInfo\":{\"name\":\"tgc0-lsp\",\"version\":\"0.1.0\"}" ^
  "}"

let handle_request oc req shutting_down =
  match req.method_name, req.id_raw with
  | Some "initialize", _ ->
      send_response oc req.id_raw initialize_result;
      shutting_down
  | Some "initialized", _ -> shutting_down
  | Some "shutdown", _ ->
      send_response oc req.id_raw "null";
      true
  | Some "exit", _ ->
      raise Exit
  | Some "textDocument/hover", Some _ ->
      send_response oc req.id_raw
      "{\"contents\":{\"kind\":\"markdown\",\"value\":\"Tangerine LSP (stage0): hover is active.\\n\\nSemantic hover details are being expanded.\"}}";
      shutting_down
  | Some "textDocument/definition", Some _ ->
      send_response oc req.id_raw "null";
      shutting_down
  | Some "textDocument/references", Some _ ->
      send_response oc req.id_raw "[]";
      shutting_down
  | Some "textDocument/rename", Some _ ->
      send_response oc req.id_raw "{\"changes\":{}}";
      shutting_down
  | Some "textDocument/signatureHelp", Some _ ->
      send_response oc req.id_raw "null";
      shutting_down
  | Some "textDocument/completion", Some _ ->
      send_response oc req.id_raw "[]";
      shutting_down
  | Some "textDocument/codeAction", Some _ ->
      send_response oc req.id_raw "[]";
      shutting_down
  | Some "textDocument/formatting", Some _ ->
      send_response oc req.id_raw "[]";
      shutting_down
  | Some "workspace/symbol", Some _ ->
      send_response oc req.id_raw "[]";
      shutting_down
  | Some "textDocument/didOpen", _
  | Some "textDocument/didChange", _
  | Some "textDocument/didSave", _
  | Some "textDocument/didClose", _ ->
      shutting_down
  | Some _, Some _ ->
      if shutting_down then send_error oc req.id_raw (-32000) "Server shutting down"
      else send_error oc req.id_raw (-32601) "Method not found";
      shutting_down
  | _ -> shutting_down

let run () =
  let ic = stdin in
  let oc = stdout in
  let rec loop shutting_down =
    match read_header_content_length ic with
    | None -> ()
    | Some content_length ->
        let body =
          try read_exact ic content_length with End_of_file -> ""
        in
        if body = "" then ()
        else
          let req = parse_request body in
          let shutting_down' =
            try handle_request oc req shutting_down with Exit -> raise Exit
          in
          loop shutting_down'
  in
  try loop false; 0 with Exit -> 0
