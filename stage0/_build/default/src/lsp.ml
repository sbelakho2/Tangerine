(* Tangerine Stage0 Bootstrap Compiler - LSP Server
   Implements the Language Server Protocol for IDE integration *)

open Ast

(* JSON-RPC types *)
type json = Yojson.Safe.t

(* LSP data structures *)
type position = { line: int; character: int }
type range = { start: position; end_: position }
type location = { uri: string; range: range }

type diagnostic_severity = SevError | SevWarning | SevInfo | SevHint

type lsp_diagnostic = {
  lsp_range: range;
  lsp_severity: diagnostic_severity;
  lsp_message: string;
  lsp_source: string;
  lsp_code: string option;
}

type completion_item = {
  comp_label: string;
  comp_kind: int;  (* 1=Text, 2=Method, 3=Function, 6=Variable, 7=Class, 8=Interface, etc. *)
  comp_detail: string option;
  comp_documentation: string option;
}

type hover_result = {
  hover_contents: string;
  hover_range: range option;
}

(* Document state *)
type document = {
  doc_uri: string;
  doc_content: string;
  doc_version: int;
  mutable doc_ast: Ast.program option;
  mutable doc_diagnostics: Typecheck.diagnostic list;
  mutable doc_env: Typecheck.type_env option;
}

type server_state = {
  documents: (string, document) Hashtbl.t;
  mutable initialized: bool;
  mutable shutdown: bool;
}

let state = {
  documents = Hashtbl.create 32;
  initialized = false;
  shutdown = false;
}

(* JSON helpers *)
let json_string s = `String s
let json_int i = `Int i
let json_bool b = `Bool b
let json_null = `Null
let json_array l = `List l
let json_obj l = `Assoc l

let get_string json key =
  match json with
  | `Assoc l -> (match List.assoc_opt key l with Some (`String s) -> Some s | _ -> None)
  | _ -> None

let get_int json key =
  match json with
  | `Assoc l -> (match List.assoc_opt key l with Some (`Int i) -> Some i | _ -> None)
  | _ -> None

let get_obj json key =
  match json with
  | `Assoc l -> List.assoc_opt key l
  | _ -> None

(* Position/Range conversion *)
let span_to_range (span: Ast.span) : range =
  { start = { line = span.start_line - 1; character = span.start_col - 1 };
    end_ = { line = span.end_line - 1; character = span.end_col - 1 } }

let range_to_json r =
  json_obj [
    ("start", json_obj [("line", json_int r.start.line); ("character", json_int r.start.character)]);
    ("end", json_obj [("line", json_int r.end_.line); ("character", json_int r.end_.character)])
  ]

let diagnostic_to_json d =
  json_obj [
    ("range", range_to_json d.lsp_range);
    ("severity", json_int (match d.lsp_severity with
      | SevError -> 1 | SevWarning -> 2 | SevInfo -> 3 | SevHint -> 4));
    ("source", json_string d.lsp_source);
    ("message", json_string d.lsp_message);
  ]

(* Parse document and run type checking *)
let analyze_document doc =
  Ast.current_file := doc.doc_uri;
  Lexer.reset ();
  try
    let lexbuf = Lexing.from_string doc.doc_content in
    let ast = Parser.program Lexer.token lexbuf in
    doc.doc_ast <- Some ast;
    let diagnostics = Typecheck.check_program ast in
    doc.doc_diagnostics <- diagnostics;
    let env = Typecheck.new_env () in
    doc.doc_env <- Some env;
    (* Convert to LSP diagnostics *)
    List.map (fun (d: Typecheck.diagnostic) ->
      { lsp_range = span_to_range d.diag_span;
        lsp_severity = (match d.diag_level with
          | Typecheck.Error -> SevError
          | Typecheck.Warning -> SevWarning
          | Typecheck.Info -> SevInfo
          | Typecheck.Hint -> SevHint);
        lsp_message = d.diag_message;
        lsp_source = "tg";
        lsp_code = None }
    ) diagnostics
  with
  | Lexer.Lexer_error (msg, line, col) ->
      [{ lsp_range = { start = { line = line - 1; character = col - 1 };
                       end_ = { line = line - 1; character = col } };
         lsp_severity = SevError;
         lsp_message = msg;
         lsp_source = "tg";
         lsp_code = Some "E0001" }]
  | Parser.Error ->
      let line = !Lexer.line in
      let col = !Lexer.col in
      [{ lsp_range = { start = { line = line - 1; character = col - 1 };
                       end_ = { line = line - 1; character = col } };
         lsp_severity = SevError;
         lsp_message = "Syntax error";
         lsp_source = "tg";
         lsp_code = Some "E0002" }]
  | e ->
      [{ lsp_range = { start = { line = 0; character = 0 };
                       end_ = { line = 0; character = 1 } };
         lsp_severity = SevError;
         lsp_message = "Internal error: " ^ Printexc.to_string e;
         lsp_source = "tg";
         lsp_code = Some "E9999" }]

(* Publish diagnostics notification *)
let publish_diagnostics uri diagnostics =
  let diag_json = json_array (List.map diagnostic_to_json diagnostics) in
  let notification = json_obj [
    ("jsonrpc", json_string "2.0");
    ("method", json_string "textDocument/publishDiagnostics");
    ("params", json_obj [
      ("uri", json_string uri);
      ("diagnostics", diag_json)
    ])
  ] in
  let content = Yojson.Safe.to_string notification in
  let header = Printf.sprintf "Content-Length: %d\r\n\r\n" (String.length content) in
  print_string header;
  print_string content;
  flush stdout

(* Handle textDocument/didOpen *)
let handle_did_open params =
  match get_obj params "textDocument" with
  | Some td ->
      let uri = Option.value ~default:"" (get_string td "uri") in
      let text = Option.value ~default:"" (get_string td "text") in
      let version = Option.value ~default:0 (get_int td "version") in
      let doc = { doc_uri = uri; doc_content = text; doc_version = version;
                  doc_ast = None; doc_diagnostics = []; doc_env = None } in
      Hashtbl.replace state.documents uri doc;
      let diagnostics = analyze_document doc in
      publish_diagnostics uri diagnostics
  | None -> ()

(* Handle textDocument/didChange *)
let handle_did_change params =
  match get_obj params "textDocument" with
  | Some td ->
      let uri = Option.value ~default:"" (get_string td "uri") in
      let version = Option.value ~default:0 (get_int td "version") in
      (match get_obj params "contentChanges" with
       | Some (`List changes) ->
           (match List.hd changes with
            | `Assoc l ->
                let text = match List.assoc_opt "text" l with
                  | Some (`String s) -> s | _ -> "" in
                (match Hashtbl.find_opt state.documents uri with
                 | Some doc ->
                     let doc = { doc with doc_content = text; doc_version = version } in
                     Hashtbl.replace state.documents uri doc;
                     let diagnostics = analyze_document doc in
                     publish_diagnostics uri diagnostics
                 | None -> ())
            | _ -> ())
       | _ -> ())
  | None -> ()

(* Handle textDocument/didClose *)
let handle_did_close params =
  match get_obj params "textDocument" with
  | Some td ->
      let uri = Option.value ~default:"" (get_string td "uri") in
      Hashtbl.remove state.documents uri;
      publish_diagnostics uri []
  | None -> ()

(* Get word at position *)
let get_word_at_position content line col =
  let lines = String.split_on_char '\n' content in
  if line >= 0 && line < List.length lines then
    let line_content = List.nth lines line in
    (* Find word boundaries *)
    let is_ident_char c = 
      (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || 
      (c >= '0' && c <= '9') || c = '_' in
    let len = String.length line_content in
    if col >= 0 && col < len then
      let rec find_start i = if i <= 0 || not (is_ident_char line_content.[i-1]) then i else find_start (i-1) in
      let rec find_end i = if i >= len || not (is_ident_char line_content.[i]) then i else find_end (i+1) in
      let start = find_start col in
      let end_ = find_end col in
      if start < end_ then Some (String.sub line_content start (end_ - start))
      else None
    else None
  else None

(* Handle textDocument/hover *)
let handle_hover params =
  match get_obj params "textDocument", get_obj params "position" with
  | Some td, Some pos ->
      let uri = Option.value ~default:"" (get_string td "uri") in
      let line = Option.value ~default:0 (get_int pos "line") in
      let col = Option.value ~default:0 (get_int pos "character") in
      (match Hashtbl.find_opt state.documents uri with
       | Some doc ->
           (match get_word_at_position doc.doc_content line col with
            | Some word ->
                (* Look up word in environment *)
                let hover_text = 
                  match doc.doc_env with
                  | Some env ->
                      (match Typecheck.lookup_var env word with
                       | Some ty -> Some (word ^ ": " ^ Typecheck.type_to_string ty)
                       | None ->
                           match Typecheck.lookup_fn env word with
                           | Some (params, ret) ->
                               let params_str = String.concat ", " (List.map Typecheck.type_to_string params) in
                               Some (Printf.sprintf "def %s(%s) -> %s" word params_str (Typecheck.type_to_string ret))
                           | None ->
                               match Typecheck.lookup_type env word with
                               | Some ty -> Some (word ^ " = " ^ Typecheck.type_to_string ty)
                               | None -> None)
                  | None -> None
                in
                (match hover_text with
                 | Some text ->
                     Some (json_obj [
                       ("contents", json_obj [
                         ("kind", json_string "markdown");
                         ("value", json_string ("```tangerine\n" ^ text ^ "\n```"))
                       ])
                     ])
                 | None -> None)
            | None -> None)
       | None -> None)
  | _ -> None

(* Handle textDocument/completion *)
let handle_completion params =
  match get_obj params "textDocument", get_obj params "position" with
  | Some td, Some pos ->
      let uri = Option.value ~default:"" (get_string td "uri") in
      let line = Option.value ~default:0 (get_int pos "line") in
      let col = Option.value ~default:0 (get_int pos "character") in
      (match Hashtbl.find_opt state.documents uri with
       | Some doc ->
           let prefix = match get_word_at_position doc.doc_content line col with
             | Some w -> w | None -> "" in
           let items = ref [] in
           (* Add keywords *)
           let keywords = [
             "def"; "end"; "if"; "then"; "else"; "elsif"; "while"; "for"; "in"; "do";
             "let"; "mut"; "return"; "break"; "continue"; "match"; "when";
             "struct"; "enum"; "trait"; "impl"; "use"; "pub"; "module";
             "true"; "false"; "self"; "Self"; "unsafe"; "where"; "as";
             "type"; "const"; "loop"; "try"; "catch"; "finally";
             "requires"; "effect"; "budget"; "pre"; "post"; "invariant"; "guard"
           ] in
           List.iter (fun kw ->
             if String.length prefix = 0 || String.sub kw 0 (min (String.length prefix) (String.length kw)) = prefix then
               items := json_obj [
                 ("label", json_string kw);
                 ("kind", json_int 14);  (* Keyword *)
                 ("detail", json_string "keyword")
               ] :: !items
           ) keywords;
           (* Add built-in types *)
           let types = ["Int"; "Int8"; "Int16"; "Int32"; "Int64"; 
                        "UInt8"; "UInt16"; "UInt32"; "UInt64";
                        "Float32"; "Float64"; "Bool"; "Char"; "String";
                        "Vec"; "Map"; "Set"; "Option"; "Result"] in
           List.iter (fun ty ->
             if String.length prefix = 0 || String.sub ty 0 (min (String.length prefix) (String.length ty)) = prefix then
               items := json_obj [
                 ("label", json_string ty);
                 ("kind", json_int 7);  (* Class/Type *)
                 ("detail", json_string "type")
               ] :: !items
           ) types;
           (* Add symbols from environment *)
           (match doc.doc_env with
            | Some env ->
                Hashtbl.iter (fun name ty ->
                  if String.length prefix = 0 || String.sub name 0 (min (String.length prefix) (String.length name)) = prefix then
                    items := json_obj [
                      ("label", json_string name);
                      ("kind", json_int 6);  (* Variable *)
                      ("detail", json_string (Typecheck.type_to_string ty))
                    ] :: !items
                ) env.Typecheck.variables;
                Hashtbl.iter (fun name (params, ret) ->
                  if String.length prefix = 0 || String.sub name 0 (min (String.length prefix) (String.length name)) = prefix then
                    let params_str = String.concat ", " (List.map Typecheck.type_to_string params) in
                    items := json_obj [
                      ("label", json_string name);
                      ("kind", json_int 3);  (* Function *)
                      ("detail", json_string (Printf.sprintf "(%s) -> %s" params_str (Typecheck.type_to_string ret)))
                    ] :: !items
                ) env.Typecheck.functions
            | None -> ());
           Some (json_obj [("isIncomplete", json_bool false); ("items", json_array !items)])
       | None -> Some (json_obj [("isIncomplete", json_bool false); ("items", json_array [])]))
  | _ -> None

(* Handle textDocument/definition *)
let handle_definition params =
  match get_obj params "textDocument", get_obj params "position" with
  | Some td, Some pos ->
      let uri = Option.value ~default:"" (get_string td "uri") in
      let line = Option.value ~default:0 (get_int pos "line") in
      let col = Option.value ~default:0 (get_int pos "character") in
      (match Hashtbl.find_opt state.documents uri with
       | Some doc ->
           (match get_word_at_position doc.doc_content line col with
            | Some word ->
                (* Search AST for definition *)
                (match doc.doc_ast with
                 | Some ast ->
                     let def_span = ref None in
                     List.iter (fun item ->
                       match item with
                       | ItemFn fn when fn.fn_name = word -> def_span := Some fn.fn_span
                       | ItemStruct s when s.struct_name = word -> def_span := Some s.struct_span
                       | ItemEnum e when e.enum_name = word -> def_span := Some e.enum_span
                       | ItemTrait t when t.trait_name = word -> def_span := Some t.trait_span
                       | _ -> ()
                     ) ast.items;
                     (match !def_span with
                      | Some span ->
                          Some (json_obj [
                            ("uri", json_string uri);
                            ("range", range_to_json (span_to_range span))
                          ])
                      | None -> None)
                 | None -> None)
            | None -> None)
       | None -> None)
  | _ -> None

(* Handle textDocument/formatting *)
let handle_formatting params =
  match get_obj params "textDocument" with
  | Some td ->
      let uri = Option.value ~default:"" (get_string td "uri") in
      (match Hashtbl.find_opt state.documents uri with
       | Some doc ->
           (* Simple formatting: normalize indentation *)
           let lines = String.split_on_char '\n' doc.doc_content in
           let indent_keywords = ["def"; "struct"; "enum"; "trait"; "impl"; "if"; "while"; "for"; "match"; "loop"; "do"; "unsafe"; "module"] in
           let dedent_keywords = ["end"; "else"; "elsif"; "when"; "catch"; "finally"] in
           let formatted = ref [] in
           let indent = ref 0 in
           List.iter (fun line ->
             let trimmed = String.trim line in
             if trimmed = "" then
               formatted := "" :: !formatted
             else begin
               (* Check for dedent first *)
               let should_dedent = List.exists (fun kw -> 
                 String.length trimmed >= String.length kw &&
                 String.sub trimmed 0 (String.length kw) = kw
               ) dedent_keywords in
               if should_dedent && !indent > 0 then indent := !indent - 1;
               
               formatted := (String.make (!indent * 2) ' ' ^ trimmed) :: !formatted;
               
               (* Check for indent increase *)
               let should_indent = List.exists (fun kw ->
                 String.length trimmed >= String.length kw &&
                 String.sub trimmed 0 (String.length kw) = kw
               ) indent_keywords in
               if should_indent then indent := !indent + 1
             end
           ) lines;
           let new_text = String.concat "\n" (List.rev !formatted) in
           let line_count = List.length lines in
           Some (json_array [
             json_obj [
               ("range", json_obj [
                 ("start", json_obj [("line", json_int 0); ("character", json_int 0)]);
                 ("end", json_obj [("line", json_int line_count); ("character", json_int 0)])
               ]);
               ("newText", json_string new_text)
             ]
           ])
       | None -> None)
  | None -> None

(* Initialize response *)
let initialize_response =
  json_obj [
    ("capabilities", json_obj [
      ("textDocumentSync", json_obj [
        ("openClose", json_bool true);
        ("change", json_int 1);  (* Full sync *)
        ("save", json_obj [("includeText", json_bool true)])
      ]);
      ("completionProvider", json_obj [
        ("triggerCharacters", json_array [json_string "."; json_string ":"]);
        ("resolveProvider", json_bool false)
      ]);
      ("hoverProvider", json_bool true);
      ("definitionProvider", json_bool true);
      ("referencesProvider", json_bool true);
      ("documentFormattingProvider", json_bool true);
      ("renameProvider", json_bool true);
      ("signatureHelpProvider", json_obj [
        ("triggerCharacters", json_array [json_string "("; json_string ","])
      ]);
      ("codeActionProvider", json_bool true)
    ]);
    ("serverInfo", json_obj [
      ("name", json_string "Tangerine Language Server");
      ("version", json_string "0.1.0")
    ])
  ]

(* Process a JSON-RPC message *)
let process_message content =
  try
    let json = Yojson.Safe.from_string content in
    let id = get_int json "id" in
    let method_ = get_string json "method" in
    let params = get_obj json "params" in
    
    match method_ with
    | Some "initialize" ->
        state.initialized <- true;
        let response = json_obj [
          ("jsonrpc", json_string "2.0");
          ("id", json_int (Option.value ~default:0 id));
          ("result", initialize_response)
        ] in
        Some response
    
    | Some "initialized" -> None
    
    | Some "shutdown" ->
        state.shutdown <- true;
        let response = json_obj [
          ("jsonrpc", json_string "2.0");
          ("id", json_int (Option.value ~default:0 id));
          ("result", json_null)
        ] in
        Some response
    
    | Some "exit" ->
        exit (if state.shutdown then 0 else 1)
    
    | Some "textDocument/didOpen" ->
        Option.iter handle_did_open params;
        None
    
    | Some "textDocument/didChange" ->
        Option.iter handle_did_change params;
        None
    
    | Some "textDocument/didClose" ->
        Option.iter handle_did_close params;
        None
    
    | Some "textDocument/hover" ->
        let result = Option.bind params handle_hover in
        let response = json_obj [
          ("jsonrpc", json_string "2.0");
          ("id", json_int (Option.value ~default:0 id));
          ("result", Option.value ~default:json_null result)
        ] in
        Some response
    
    | Some "textDocument/completion" ->
        let result = Option.bind params handle_completion in
        let response = json_obj [
          ("jsonrpc", json_string "2.0");
          ("id", json_int (Option.value ~default:0 id));
          ("result", Option.value ~default:json_null result)
        ] in
        Some response
    
    | Some "textDocument/definition" ->
        let result = Option.bind params handle_definition in
        let response = json_obj [
          ("jsonrpc", json_string "2.0");
          ("id", json_int (Option.value ~default:0 id));
          ("result", Option.value ~default:json_null result)
        ] in
        Some response
    
    | Some "textDocument/formatting" ->
        let result = Option.bind params handle_formatting in
        let response = json_obj [
          ("jsonrpc", json_string "2.0");
          ("id", json_int (Option.value ~default:0 id));
          ("result", Option.value ~default:json_null result)
        ] in
        Some response
    
    | Some m when String.sub m 0 2 = "$/" ->
        (* Ignore $/... notifications *)
        None
    
    | _ -> None
  with e ->
    prerr_endline ("Error processing message: " ^ Printexc.to_string e);
    None

(* Main LSP loop *)
let run_lsp () =
  (* Read Content-Length header *)
  let rec read_loop () =
    let header = input_line stdin in
    if String.length header >= 16 && String.sub header 0 16 = "Content-Length: " then
      let len = int_of_string (String.trim (String.sub header 16 (String.length header - 16))) in
      (* Read blank line *)
      let _ = input_line stdin in
      (* Read content *)
      let content = Bytes.create len in
      really_input stdin content 0 len;
      let content_str = Bytes.to_string content in
      
      (* Process and respond *)
      (match process_message content_str with
       | Some response ->
           let response_str = Yojson.Safe.to_string response in
           let header = Printf.sprintf "Content-Length: %d\r\n\r\n" (String.length response_str) in
           print_string header;
           print_string response_str;
           flush stdout
       | None -> ());
      
      read_loop ()
    else if String.trim header = "" then
      read_loop ()
    else
      read_loop ()
  in
  read_loop ()
