{
(* Tangerine Stage0 Bootstrap Compiler - Lexer *)

open Parser

exception Lexer_error of string * int * int

let keywords = Hashtbl.create 64
let () = List.iter (fun (k, v) -> Hashtbl.add keywords k v) [
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
  ("continue", CONTINUE);
  ("match", MATCH);
  ("when", WHEN);
  ("struct", STRUCT);
  ("enum", ENUM);
  ("trait", TRAIT);
  ("impl", IMPL);
  ("use", USE);
  ("pub", PUB);
  ("module", MODULE);
  ("mod", MODULE);  (* alias *)
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
  ("loop", LOOP);
  ("try", TRY);
  ("catch", CATCH);
  ("finally", FINALLY);
  ("pure", PURE);
  ("inline", INLINE);
  
  (* Contract/capability keywords *)
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
  ("macro", MACRO);
  ("comptime", COMPTIME);
  
  (* nil/None *)
  ("nil", NIL);
  ("None", NONE);
]

let line = ref 1
let col = ref 1

let newline _lexbuf =
  line := !line + 1;
  col := 1

let advance _lexbuf n =
  col := !col + n

let current_pos () = (!line, !col)

let make_span start_line start_col end_line end_col file =
  Ast.{ file; start_line; start_col; end_line; end_col }
}

let digit = ['0'-'9']
let hex_digit = ['0'-'9' 'a'-'f' 'A'-'F']
let bin_digit = ['0' '1']
let oct_digit = ['0'-'7']
let alpha = ['a'-'z' 'A'-'Z']
let ident_start = alpha | '_'
let ident_char = alpha | digit | '_'
let ident = ident_start ident_char*

let whitespace = [' ' '\t' '\r']
let newline = '\n'

let int_literal = digit (digit | '_')*
let hex_literal = "0x" hex_digit (hex_digit | '_')*
let bin_literal = "0b" bin_digit (bin_digit | '_')*
let oct_literal = "0o" oct_digit (oct_digit | '_')*
let float_literal = digit+ '.' digit+ (['e' 'E'] ['+' '-']? digit+)?

rule token = parse
  | whitespace+   { advance lexbuf (Lexing.lexeme_end lexbuf - Lexing.lexeme_start lexbuf); token lexbuf }
  | newline       { newline lexbuf; token lexbuf }
  
  (* Comments *)
  | '#' [^ '\n' '|']* { token lexbuf }  (* Line comment *)
  | "##" [^ '\n']*    { token lexbuf }  (* Doc comment - for now treat same *)
  | "#|"              { block_comment lexbuf; token lexbuf }
  
  (* Literals *)
  | hex_literal as s  { advance lexbuf (String.length s); INT_LIT (Int64.of_string s) }
  | bin_literal as s  { advance lexbuf (String.length s); INT_LIT (Int64.of_string s) }
  | oct_literal as s  { advance lexbuf (String.length s); INT_LIT (Int64.of_string s) }
  | float_literal as s { advance lexbuf (String.length s); FLOAT_LIT (float_of_string s) }
  | int_literal as s  { advance lexbuf (String.length s); INT_LIT (Int64.of_string (String.concat "" (String.split_on_char '_' s))) }
  
  | '"'               { advance lexbuf 1; string_literal (Buffer.create 64) lexbuf }
  | '\''              { advance lexbuf 1; char_literal lexbuf }
  
  (* Identifiers and keywords *)
  | ident as s        { 
      advance lexbuf (String.length s);
      try Hashtbl.find keywords s
      with Not_found -> IDENT s
    }
  
  (* Multi-char operators *)
  | "->"  { advance lexbuf 2; ARROW }
  | "=>"  { advance lexbuf 2; FAT_ARROW }
  | "::"  { advance lexbuf 2; COLON_COLON }
  | ".."  { advance lexbuf 2; DOT_DOT }
  | "..=" { advance lexbuf 3; DOT_DOT_EQ }
  | "=="  { advance lexbuf 2; EQ_EQ }
  | "!="  { advance lexbuf 2; BANG_EQ }
  | "<="  { advance lexbuf 2; LT_EQ }
  | ">="  { advance lexbuf 2; GT_EQ }
  | "&&"  { advance lexbuf 2; AMP_AMP }
  | "||"  { advance lexbuf 2; PIPE_PIPE }
  | "<<"  { advance lexbuf 2; SHL }
  | ">>"  { advance lexbuf 2; SHR }
  | "+="  { advance lexbuf 2; PLUS_EQ }
  | "-="  { advance lexbuf 2; MINUS_EQ }
  | "*="  { advance lexbuf 2; STAR_EQ }
  | "/="  { advance lexbuf 2; SLASH_EQ }
  | "%="  { advance lexbuf 2; PERCENT_EQ }
  
  (* Single-char operators and punctuation *)
  | '+'  { advance lexbuf 1; PLUS }
  | '-'  { advance lexbuf 1; MINUS }
  | '*'  { advance lexbuf 1; STAR }
  | '/'  { advance lexbuf 1; SLASH }
  | '%'  { advance lexbuf 1; PERCENT }
  | '='  { advance lexbuf 1; EQ }
  | '<'  { advance lexbuf 1; LT }
  | '>'  { advance lexbuf 1; GT }
  | '!'  { advance lexbuf 1; BANG }
  | '&'  { advance lexbuf 1; AMP }
  | '|'  { advance lexbuf 1; PIPE }
  | '^'  { advance lexbuf 1; CARET }
  | '~'  { advance lexbuf 1; TILDE }
  | '('  { advance lexbuf 1; LPAREN }
  | ')'  { advance lexbuf 1; RPAREN }
  | '['  { advance lexbuf 1; LBRACKET }
  | ']'  { advance lexbuf 1; RBRACKET }
  | '{'  { advance lexbuf 1; LBRACE }
  | '}'  { advance lexbuf 1; RBRACE }
  | ':'  { advance lexbuf 1; COLON }
  | ','  { advance lexbuf 1; COMMA }
  | '.'  { advance lexbuf 1; DOT }
  | ';'  { advance lexbuf 1; SEMICOL }
  | '?'  { advance lexbuf 1; QUESTION }
  | '@'  { advance lexbuf 1; AT }
  
  | eof  { EOF }
  | _ as c { raise (Lexer_error (Printf.sprintf "Unexpected character: %c" c, !line, !col)) }

and block_comment = parse
  | "|#"  { advance lexbuf 2 }
  | "#|"  { advance lexbuf 2; block_comment lexbuf; block_comment lexbuf }
  | newline { newline lexbuf; block_comment lexbuf }
  | _     { advance lexbuf 1; block_comment lexbuf }
  | eof   { raise (Lexer_error ("Unterminated block comment", !line, !col)) }

and string_literal buf = parse
  | '"'       { advance lexbuf 1; STRING_LIT (Buffer.contents buf) }
  | "\\n"     { advance lexbuf 2; Buffer.add_char buf '\n'; string_literal buf lexbuf }
  | "\\r"     { advance lexbuf 2; Buffer.add_char buf '\r'; string_literal buf lexbuf }
  | "\\t"     { advance lexbuf 2; Buffer.add_char buf '\t'; string_literal buf lexbuf }
  | "\\\\"    { advance lexbuf 2; Buffer.add_char buf '\\'; string_literal buf lexbuf }
  | "\\\""    { advance lexbuf 2; Buffer.add_char buf '"'; string_literal buf lexbuf }
  | "\\0"     { advance lexbuf 2; Buffer.add_char buf '\000'; string_literal buf lexbuf }
  | "\\x" (hex_digit hex_digit as s) { 
      advance lexbuf 4; 
      Buffer.add_char buf (Char.chr (int_of_string ("0x" ^ s))); 
      string_literal buf lexbuf 
    }
  | newline   { newline lexbuf; Buffer.add_char buf '\n'; string_literal buf lexbuf }
  | [^ '"' '\\' '\n']+ as s { 
      advance lexbuf (String.length s); 
      Buffer.add_string buf s; 
      string_literal buf lexbuf 
    }
  | eof       { raise (Lexer_error ("Unterminated string literal", !line, !col)) }
  | _ as c    { advance lexbuf 1; Buffer.add_char buf c; string_literal buf lexbuf }

and char_literal = parse
  | "\\n'"    { advance lexbuf 3; CHAR_LIT '\n' }
  | "\\r'"    { advance lexbuf 3; CHAR_LIT '\r' }
  | "\\t'"    { advance lexbuf 3; CHAR_LIT '\t' }
  | "\\\\'"   { advance lexbuf 3; CHAR_LIT '\\' }
  | "\\''"    { advance lexbuf 3; CHAR_LIT '\'' }
  | "\\0'"    { advance lexbuf 3; CHAR_LIT '\000' }
  | ([^ '\\' '\'' '\n'] as c) '\'' { advance lexbuf 2; CHAR_LIT c }
  | eof       { raise (Lexer_error ("Unterminated character literal", !line, !col)) }
  | _         { raise (Lexer_error ("Invalid character literal", !line, !col)) }

{
let reset () =
  line := 1;
  col := 1

let tokenize_string content =
  reset ();
  let lexbuf = Lexing.from_string content in
  let rec collect acc =
    match token lexbuf with
    | EOF -> List.rev (EOF :: acc)
    | tok -> collect (tok :: acc)
  in
  collect []
}
