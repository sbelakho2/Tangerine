type kind =
  | Kw of string
  | Ident of string
  | IntLit of string
  | FloatLit of string
  | StringLit of string
  | CharLit of string
  | Symbol of string
  | Newline
  | Eof
  | Error of string

type t = {
  kind : kind;
  lexeme : string;
  line : int;
  col : int;
}

let make kind lexeme line col = { kind; lexeme; line; col }

let kind_to_string = function
  | Kw s -> "KW(" ^ s ^ ")"
  | Ident s -> "IDENT(" ^ s ^ ")"
  | IntLit s -> "INT(" ^ s ^ ")"
  | FloatLit s -> "FLOAT(" ^ s ^ ")"
  | StringLit _ -> "STRING"
  | CharLit _ -> "CHAR"
  | Symbol s -> "SYM(" ^ s ^ ")"
  | Newline -> "NEWLINE"
  | Eof -> "EOF"
  | Error s -> "ERROR(" ^ s ^ ")"

let to_string t =
  Printf.sprintf "%d:%d %s" t.line t.col (kind_to_string t.kind)

let keyword_set =
  let tbl = Hashtbl.create 128 in
  List.iter (fun k -> Hashtbl.replace tbl k true)
    [ "def"; "end"; "do"; "if"; "elsif"; "else"; "then"; "while"; "for"; "in";
      "loop"; "match"; "when"; "let"; "mut"; "var"; "return"; "break"; "next";
      "struct"; "enum"; "trait"; "impl"; "dyn"; "module"; "mod"; "use"; "as";
      "pub"; "private"; "macro"; "where"; "true"; "false"; "nil"; "self";
      "Self"; "crate"; "super"; "move"; "copy"; "drop"; "own"; "ref";
      "pre"; "post"; "invariant"; "cap"; "unsafe"; "rationale"; "budget";
      "edition"; "requires"; "ensures"; "effect"; "pure"; "async"; "await";
      "yield"; "defer"; "try"; "catch"; "finally"; "guard"; "handle"; "with";
      "is"; "implies"; "comptime"; "const"; "static"; "type"; "alias";
      "extern"; "inline"; "fn"; "unless"; "until" ];
  tbl

let is_keyword s = Hashtbl.mem keyword_set s
