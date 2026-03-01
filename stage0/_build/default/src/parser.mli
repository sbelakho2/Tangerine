
(* The type of tokens. *)

type token = 
  | YIELD
  | WITH
  | WHILE
  | WHERE
  | WHEN
  | USE
  | UNSAFE
  | TYPE
  | TRY
  | TRUE
  | TRAIT
  | TILDE
  | THEN
  | SUPER
  | STRUCT
  | STRING_LIT of (string)
  | STAR_EQ
  | STAR
  | SLASH_EQ
  | SLASH
  | SHR
  | SHL
  | SEMICOL
  | SELF_UPPER
  | SELF_LOWER
  | RPAREN
  | RETURN
  | REQUIRES
  | RBRACKET
  | RBRACE
  | RATIONALE
  | QUESTION
  | PURE
  | PUB
  | PRE
  | POST
  | PLUS_EQ
  | PLUS
  | PIPE_PIPE
  | PIPE
  | PERCENT_EQ
  | PERCENT
  | NONE
  | NIL
  | NEXT
  | MUT
  | MODULE
  | MINUS_EQ
  | MINUS
  | MATCH
  | MACRO
  | LT_EQ
  | LT
  | LPAREN
  | LOOP
  | LET
  | LBRACKET
  | LBRACE
  | INVARIANT
  | INT_LIT of (int64)
  | INLINE
  | IN
  | IMPLIES
  | IMPL
  | IF
  | IDENT of (string)
  | HANDLE
  | GUARD
  | GT_EQ
  | GT
  | FOR
  | FN
  | FLOAT_LIT of (float)
  | FINALLY
  | FAT_ARROW
  | FALSE
  | EXTERN
  | EQ_EQ
  | EQ
  | EOF
  | ENUM
  | END
  | ELSIF
  | ELSE
  | EFFECT
  | DOT_DOT_EQ
  | DOT_DOT
  | DOT
  | DO
  | DEF
  | CRATE
  | CONTINUE
  | CONST
  | COMPTIME
  | COMMA
  | COLON_COLON
  | COLON
  | CHAR_LIT of (char)
  | CATCH
  | CARET
  | CAP
  | BUDGET
  | BREAK
  | BANG_EQ
  | BANG
  | AWAIT
  | AT
  | ASYNC
  | AS
  | ARROW
  | AMP_AMP
  | AMP

(* This exception is raised by the monolithic API functions. *)

exception Error

(* The monolithic API. *)

val program: (Lexing.lexbuf -> token) -> Lexing.lexbuf -> (Ast.program)
