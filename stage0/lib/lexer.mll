{
(** Lexer for Tangerine *)

open Parser

exception Lexer_error of string * Lexing.position

let error lexbuf msg =
  raise (Lexer_error (msg, Lexing.lexeme_start_p lexbuf))

let keyword_table = Hashtbl.create 64

let () =
  List.iter (fun (kw, tok) -> Hashtbl.add keyword_table kw tok) [
    (* Core keywords *)
    ("def", DEF);
    ("end", END);
    ("if", IF);
    ("then", THEN);
    ("else", ELSE);
    ("elsif", ELSIF);
    ("while", WHILE);
    ("for", FOR);
    ("in", IN);
    ("do", DO);
    ("let", LET);
    ("mut", MUT);
    ("return", RETURN);
    ("break", BREAK);
    ("next", NEXT);
    ("match", MATCH);
    ("when", WHEN);
    ("struct", STRUCT);
    ("enum", ENUM);
    ("trait", TRAIT);
    ("impl", IMPL);
    ("use", USE);
    ("pub", PUB);
    ("module", MODULE);
    ("mod", MODULE);  (* Alias *)
    ("fn", FN);
    ("self", SELF_LOWER);
    ("Self", SELF_UPPER);
    ("true", TRUE);
    ("false", FALSE);
    ("unsafe", UNSAFE);
    ("where", WHERE);
    ("as", AS);
    ("type", TYPE);
    ("const", CONST);
    ("extern", EXTERN);
    ("super", SUPER);
    ("crate", CRATE);
    ("yield", YIELD);
    ("async", ASYNC);
    ("await", AWAIT);
    ("edition", EDITION);
    
    (* Agentic/contract keywords *)
    ("cap", CAP);
    ("effect", EFFECT);
    ("requires", REQUIRES);
    ("implies", IMPLIES);
    ("handle", HANDLE);
    ("with", WITH);
    ("rationale", RATIONALE);
    ("budget", BUDGET);
    ("pre", PRE);
    ("post", POST);
    ("invariant", INVARIANT);
    ("guard", GUARD);
    
    (* Control flow *)
    ("try", TRY);
    ("catch", CATCH);
    ("finally", FINALLY);
    ("loop", LOOP);
    
    (* Other *)
    ("macro", MACRO);
    ("comptime", COMPTIME);
    ("pure", PURE);
    ("inline", INLINE);
    ("ref", REF);
    ("own", OWN);
    ("move", MOVE);
    ("copy", COPY);
  ]

let lookup_ident s =
  try Hashtbl.find keyword_table s
  with Not_found -> IDENT s

(* For tracking nested block comments *)
let comment_depth = ref 0

(* String buffer for string/char literals *)
let string_buf = Buffer.create 256

(* Convert escape sequence to character *)
let escape_char = function
  | 'n' -> '\n'
  | 'r' -> '\r'
  | 't' -> '\t'
  | '\\' -> '\\'
  | '"' -> '"'
  | '\'' -> '\''
  | '0' -> '\000'
  | c -> c

(* Parse hex digit *)
let hex_digit c =
  match c with
  | '0'..'9' -> Char.code c - Char.code '0'
  | 'a'..'f' -> Char.code c - Char.code 'a' + 10
  | 'A'..'F' -> Char.code c - Char.code 'A' + 10
  | _ -> failwith "Invalid hex digit"

(* Parse \xNN escape *)
let hex_escape c1 c2 =
  Char.chr (hex_digit c1 * 16 + hex_digit c2)

}

let whitespace = [' ' '\t']+
let newline = '\r'? '\n'
let digit = ['0'-'9']
let hex_digit = ['0'-'9' 'a'-'f' 'A'-'F']
let bin_digit = ['0'-'1']
let oct_digit = ['0'-'7']
let alpha = ['a'-'z' 'A'-'Z']
let ident_start = alpha | '_'
let ident_char = alpha | digit | '_'
let ident = ident_start ident_char*

let int_dec = digit (digit | '_')*
let int_hex = "0x" hex_digit (hex_digit | '_')*
let int_bin = "0b" bin_digit (bin_digit | '_')*
let int_oct = "0o" oct_digit (oct_digit | '_')*

let exponent = ['e' 'E'] ['+' '-']? digit+
let float_lit = digit+ '.' digit+ exponent?
               | digit+ exponent

rule token = parse
  (* Whitespace *)
  | whitespace    { token lexbuf }
  | newline       { Lexing.new_line lexbuf; token lexbuf }
  
  (* Comments *)
  | '#' [^'|' '\n']* { token lexbuf }  (* Line comment *)
  | "##" [^'\n']*     { token lexbuf }  (* Doc comment - could capture later *)
  | "#|"              { comment_depth := 1; block_comment lexbuf }
  
  (* Literals *)
  | int_hex as s  { INT_LIT (Int64.of_string s, `Hex) }
  | int_bin as s  { INT_LIT (Int64.of_string s, `Bin) }
  | int_oct as s  { INT_LIT (Int64.of_string s, `Oct) }
  | int_dec as s  { INT_LIT (Int64.of_string (String.concat "" (String.split_on_char '_' s)), `Dec) }
  | float_lit as s { FLOAT_LIT (float_of_string (String.concat "" (String.split_on_char '_' s))) }
  
  | '"'           { Buffer.clear string_buf; string lexbuf }
  | '\''          { char_lit lexbuf }
  
  (* Operators - multi-char first *)
  | "&&"          { AMP_AMP }
  | "||"          { PIPE_PIPE }
  | "=="          { EQ_EQ }
  | "!="          { BANG_EQ }
  | "<="          { LT_EQ }
  | ">="          { GT_EQ }
  | "<<"          { SHL }
  | ">>"          { SHR }
  | "->"          { ARROW }
  | "=>"          { FAT_ARROW }
  | "::"          { COLON_COLON }
  | ".."          { DOT_DOT }
  | "..="         { DOT_DOT_EQ }
  | "+="          { PLUS_EQ }
  | "-="          { MINUS_EQ }
  | "*="          { STAR_EQ }
  | "/="          { SLASH_EQ }
  | "%="          { PERCENT_EQ }
  
  (* Single-char operators *)
  | '+'           { PLUS }
  | '-'           { MINUS }
  | '*'           { STAR }
  | '/'           { SLASH }
  | '%'           { PERCENT }
  | '<'           { LT }
  | '>'           { GT }
  | '='           { EQ }
  | '!'           { BANG }
  | '&'           { AMP }
  | '|'           { PIPE }
  | '^'           { CARET }
  | '~'           { TILDE }
  | '?'           { QUESTION }
  | '@'           { AT }
  
  (* Delimiters *)
  | '('           { LPAREN }
  | ')'           { RPAREN }
  | '['           { LBRACKET }
  | ']'           { RBRACKET }
  | '{'           { LBRACE }
  | '}'           { RBRACE }
  | ':'           { COLON }
  | ','           { COMMA }
  | '.'           { DOT }
  | ';'           { SEMICOL }
  
  (* Attribute syntax #[...] *)
  | "#["          { HASH_LBRACKET }
  
  (* Identifiers *)
  | ident as s    { lookup_ident s }
  
  (* End of file *)
  | eof           { EOF }
  
  (* Catch-all error *)
  | _ as c        { error lexbuf (Printf.sprintf "Unexpected character: %c" c) }

and block_comment = parse
  | "#|"          { incr comment_depth; block_comment lexbuf }
  | "|#"          { decr comment_depth;
                    if !comment_depth = 0 then token lexbuf
                    else block_comment lexbuf }
  | newline       { Lexing.new_line lexbuf; block_comment lexbuf }
  | eof           { error lexbuf "Unterminated block comment" }
  | _             { block_comment lexbuf }

and string = parse
  | '"'           { STRING_LIT (Buffer.contents string_buf) }
  | '\\' (['n' 'r' 't' '\\' '"' '0'] as c)
                  { Buffer.add_char string_buf (escape_char c); string lexbuf }
  | "\\x" (hex_digit as c1) (hex_digit as c2)
                  { Buffer.add_char string_buf (hex_escape c1 c2); string lexbuf }
  | "\\u{" (hex_digit+ as s) '}'
                  { (* Unicode escape - simplified, just add as UTF-8 *)
                    let code = int_of_string ("0x" ^ s) in
                    if code <= 0x7F then
                      Buffer.add_char string_buf (Char.chr code)
                    else if code <= 0x7FF then begin
                      Buffer.add_char string_buf (Char.chr (0xC0 lor (code lsr 6)));
                      Buffer.add_char string_buf (Char.chr (0x80 lor (code land 0x3F)))
                    end else if code <= 0xFFFF then begin
                      Buffer.add_char string_buf (Char.chr (0xE0 lor (code lsr 12)));
                      Buffer.add_char string_buf (Char.chr (0x80 lor ((code lsr 6) land 0x3F)));
                      Buffer.add_char string_buf (Char.chr (0x80 lor (code land 0x3F)))
                    end else begin
                      Buffer.add_char string_buf (Char.chr (0xF0 lor (code lsr 18)));
                      Buffer.add_char string_buf (Char.chr (0x80 lor ((code lsr 12) land 0x3F)));
                      Buffer.add_char string_buf (Char.chr (0x80 lor ((code lsr 6) land 0x3F)));
                      Buffer.add_char string_buf (Char.chr (0x80 lor (code land 0x3F)))
                    end;
                    string lexbuf }
  | newline       { error lexbuf "Newline in string literal" }
  | eof           { error lexbuf "Unterminated string literal" }
  | _ as c        { Buffer.add_char string_buf c; string lexbuf }

and char_lit = parse
  | '\\' (['n' 'r' 't' '\\' '\'' '0'] as c) '\''
                  { CHAR_LIT (escape_char c) }
  | "\\x" (hex_digit as c1) (hex_digit as c2) '\''
                  { CHAR_LIT (hex_escape c1 c2) }
  | ([^ '\\' '\'' '\n' '\r'] as c) '\''
                  { CHAR_LIT c }
  | _             { error lexbuf "Invalid character literal" }

{
(* Helper to get current location *)
let current_loc lexbuf file =
  let start = Lexing.lexeme_start_p lexbuf in
  let stop = Lexing.lexeme_end_p lexbuf in
  Location.of_lexing_positions ~file start stop
}
