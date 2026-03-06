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

(* ────────────────────────────────────────────────────────────────────────
   Keyword table — canonical list of all HARD reserved words.
   These are ALWAYS treated as keywords and can NEVER be identifiers.
   Keep sorted by category.  When adding keywords here, also update:
     • parser.ml  is_soft_keyword list
     • tg_compiler/token.tg  TokenKind enum & keyword_from_str
     • docs/grammar.md keyword production
   NOTE: soft keywords are NOT in this table — they appear only in
   soft_keyword_set and can be used as identifiers in some positions.
   ──────────────────────────────────────────────────────────────────────── *)
let keyword_set =
  let tbl = Hashtbl.create 128 in
  List.iter (fun k -> Hashtbl.replace tbl k true)
    [ (* ── control-flow ────────────────────────────────────────────── *)
      "if"; "elsif"; "else"; "then"; "match"; "when";
      "while"; "for"; "in"; "loop"; "do"; "end";
      "unless"; "until"; "break"; "return";
      (* ── definitions & declarations ──────────────────────────────── *)
      "let"; "mut"; "struct"; "enum"; "trait"; "impl";
      "use"; "as"; "pub";
      (* ── values / literals ───────────────────────────────────────── *)
      "true"; "false"; "nil"; "self"; "Self";
      (* ── logical / boolean ────────────────────────────────────────── *)
      "and"; "or"; "not" ];
  tbl

let is_keyword s = Hashtbl.mem keyword_set s

(* ────────────────────────────────────────────────────────────────────────
   Soft keywords — keywords that may be used as identifiers in some
   positions (e.g. struct field names, variable names). NOT hard reserved.
   These are emitted as Ident tokens by the lexer and only treated
   as keywords when the parser expects them in keyword position.
   Maintained as the single source of truth; parser.ml references this.
   ──────────────────────────────────────────────────────────────────────── *)
let soft_keyword_set =
  let tbl = Hashtbl.create 64 in
  List.iter (fun k -> Hashtbl.replace tbl k true)
    [ (* ── definitions — soft because they're common in other contexts *)
      "def"; "fn"; "var"; "const"; "static"; "type"; "alias";
      "macro"; "where"; "extern"; "inline"; "module"; "mod";
      "private"; "test";
      (* ── control flow — soft *)
      "next"; "yield"; "defer";
      (* ── values *)
      "crate"; "super";
      (* ── ownership & borrowing *)
      "move"; "copy"; "drop"; "own"; "ref"; "dyn";
      (* ── contracts & capabilities *)
      "pre"; "post"; "invariant"; "cap"; "unsafe"; "rationale"; "budget";
      "edition"; "requires"; "ensures"; "effect"; "pure";
      (* ── concurrency *)
      "async"; "await";
      (* ── error handling *)
      "try"; "catch"; "finally"; "guard"; "handle"; "with";
      (* ── misc *)
      "is"; "implies"; "comptime" ];
  tbl

let is_soft_keyword s = Hashtbl.mem soft_keyword_set s
let is_any_keyword s = is_keyword s || is_soft_keyword s
