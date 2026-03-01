
module MenhirBasics = struct
  
  exception Error
  
  let _eRR =
    fun _s ->
      raise Error
  
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
    | STRING_LIT of 
# 20 "src/parser.mly"
       (string)
# 30 "src/parser.ml"
  
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
    | INT_LIT of 
# 18 "src/parser.mly"
       (int64)
# 78 "src/parser.ml"
  
    | INLINE
    | IN
    | IMPLIES
    | IMPL
    | IF
    | IDENT of 
# 22 "src/parser.mly"
       (string)
# 88 "src/parser.ml"
  
    | HANDLE
    | GUARD
    | GT_EQ
    | GT
    | FOR
    | FN
    | FLOAT_LIT of 
# 19 "src/parser.mly"
       (float)
# 99 "src/parser.ml"
  
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
    | CHAR_LIT of 
# 21 "src/parser.mly"
       (char)
# 128 "src/parser.ml"
  
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
  
end

include MenhirBasics

# 1 "src/parser.mly"
  
(* Tangerine Stage0 Bootstrap Compiler - Parser *)

open Ast

let make_span startpos endpos file =
  { file;
    start_line = startpos.Lexing.pos_lnum;
    start_col = startpos.Lexing.pos_cnum - startpos.Lexing.pos_bol + 1;
    end_line = endpos.Lexing.pos_lnum;
    end_col = endpos.Lexing.pos_cnum - endpos.Lexing.pos_bol + 1;
  }

let current_file = Ast.current_file

# 165 "src/parser.ml"

type ('s, 'r) _menhir_state = 
  | MenhirState000 : ('s, _menhir_box_program) _menhir_state
    (** State 000.
        Stack shape : <empty>.
        Start symbol: program. *)

  | MenhirState002 : (('s, _menhir_box_program) _menhir_cell1_IMPL, _menhir_box_program) _menhir_state
    (** State 002.
        Stack shape : IMPL.
        Start symbol: program. *)

  | MenhirState003 : (('s, _menhir_box_program) _menhir_cell1_LBRACKET, _menhir_box_program) _menhir_state
    (** State 003.
        Stack shape : LBRACKET.
        Start symbol: program. *)

  | MenhirState004 : (('s, _menhir_box_program) _menhir_cell1_IDENT, _menhir_box_program) _menhir_state
    (** State 004.
        Stack shape : IDENT.
        Start symbol: program. *)

  | MenhirState005 : (('s, _menhir_box_program) _menhir_cell1_COLON, _menhir_box_program) _menhir_state
    (** State 005.
        Stack shape : COLON.
        Start symbol: program. *)

  | MenhirState007 : (('s, _menhir_box_program) _menhir_cell1_IDENT, _menhir_box_program) _menhir_state
    (** State 007.
        Stack shape : IDENT.
        Start symbol: program. *)

  | MenhirState013 : (('s, _menhir_box_program) _menhir_cell1_type_param, _menhir_box_program) _menhir_state
    (** State 013.
        Stack shape : type_param.
        Start symbol: program. *)

  | MenhirState020 : ((('s, _menhir_box_program) _menhir_cell1_IMPL, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_IDENT _menhir_cell0_LBRACKET, _menhir_box_program) _menhir_state
    (** State 020.
        Stack shape : IMPL option(type_params) IDENT LBRACKET.
        Start symbol: program. *)

  | MenhirState022 : (('s, _menhir_box_program) _menhir_cell1_QUESTION, _menhir_box_program) _menhir_state
    (** State 022.
        Stack shape : QUESTION.
        Start symbol: program. *)

  | MenhirState023 : (('s, _menhir_box_program) _menhir_cell1_LPAREN, _menhir_box_program) _menhir_state
    (** State 023.
        Stack shape : LPAREN.
        Start symbol: program. *)

  | MenhirState025 : (('s, _menhir_box_program) _menhir_cell1_IDENT _menhir_cell0_LBRACKET, _menhir_box_program) _menhir_state
    (** State 025.
        Stack shape : IDENT LBRACKET.
        Start symbol: program. *)

  | MenhirState027 : (('s, _menhir_box_program) _menhir_cell1_FN _menhir_cell0_LPAREN, _menhir_box_program) _menhir_state
    (** State 027.
        Stack shape : FN LPAREN.
        Start symbol: program. *)

  | MenhirState029 : (('s, _menhir_box_program) _menhir_cell1_AMP, _menhir_box_program) _menhir_state
    (** State 029.
        Stack shape : AMP.
        Start symbol: program. *)

  | MenhirState030 : ((('s, _menhir_box_program) _menhir_cell1_AMP, _menhir_box_program) _menhir_cell1_MUT, _menhir_box_program) _menhir_state
    (** State 030.
        Stack shape : AMP MUT.
        Start symbol: program. *)

  | MenhirState034 : (('s, _menhir_box_program) _menhir_cell1_type_expr, _menhir_box_program) _menhir_state
    (** State 034.
        Stack shape : type_expr.
        Start symbol: program. *)

  | MenhirState039 : ((('s, _menhir_box_program) _menhir_cell1_FN _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_type_expr__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_state
    (** State 039.
        Stack shape : FN LPAREN loption(separated_nonempty_list(COMMA,type_expr)) RPAREN.
        Start symbol: program. *)

  | MenhirState053 : ((('s, _menhir_box_program) _menhir_cell1_IMPL, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_option_impl_trait_ _menhir_cell0_option_FOR_, _menhir_box_program) _menhir_state
    (** State 053.
        Stack shape : IMPL option(type_params) option(impl_trait) option(FOR).
        Start symbol: program. *)

  | MenhirState054 : (((('s, _menhir_box_program) _menhir_cell1_IMPL, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_option_impl_trait_ _menhir_cell0_option_FOR_, _menhir_box_program) _menhir_cell1_type_expr, _menhir_box_program) _menhir_state
    (** State 054.
        Stack shape : IMPL option(type_params) option(impl_trait) option(FOR) type_expr.
        Start symbol: program. *)

  | MenhirState055 : (('s, _menhir_box_program) _menhir_cell1_WHERE, _menhir_box_program) _menhir_state
    (** State 055.
        Stack shape : WHERE.
        Start symbol: program. *)

  | MenhirState057 : (('s, _menhir_box_program) _menhir_cell1_where_pred, _menhir_box_program) _menhir_state
    (** State 057.
        Stack shape : where_pred.
        Start symbol: program. *)

  | MenhirState059 : (('s, _menhir_box_program) _menhir_cell1_type_expr, _menhir_box_program) _menhir_state
    (** State 059.
        Stack shape : type_expr.
        Start symbol: program. *)

  | MenhirState064 : ((((('s, _menhir_box_program) _menhir_cell1_IMPL, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_option_impl_trait_ _menhir_cell0_option_FOR_, _menhir_box_program) _menhir_cell1_type_expr, _menhir_box_program) _menhir_cell1_option_where_clause_, _menhir_box_program) _menhir_state
    (** State 064.
        Stack shape : IMPL option(type_params) option(impl_trait) option(FOR) type_expr option(where_clause).
        Start symbol: program. *)

  | MenhirState067 : (('s, _menhir_box_program) _menhir_cell1_TYPE _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 067.
        Stack shape : TYPE IDENT.
        Start symbol: program. *)

  | MenhirState071 : (('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 071.
        Stack shape : visibility DEF IDENT.
        Start symbol: program. *)

  | MenhirState073 : ((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_state
    (** State 073.
        Stack shape : visibility DEF IDENT option(type_params) LPAREN.
        Start symbol: program. *)

  | MenhirState077 : (('s, _menhir_box_program) _menhir_cell1_param, _menhir_box_program) _menhir_state
    (** State 077.
        Stack shape : param.
        Start symbol: program. *)

  | MenhirState081 : (('s, _menhir_box_program) _menhir_cell1_option_MUT_ _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 081.
        Stack shape : option(MUT) IDENT.
        Start symbol: program. *)

  | MenhirState084 : (((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_state
    (** State 084.
        Stack shape : visibility DEF IDENT option(type_params) LPAREN loption(separated_nonempty_list(COMMA,param)) RPAREN.
        Start symbol: program. *)

  | MenhirState085 : (((('s _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_ARROW, _menhir_box_program) _menhir_state
    (** State 085.
        Stack shape : IDENT option(type_params) LPAREN loption(separated_nonempty_list(COMMA,param)) RPAREN ARROW.
        Start symbol: program. *)

  | MenhirState088 : ((((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_state
    (** State 088.
        Stack shape : visibility DEF IDENT option(type_params) LPAREN loption(separated_nonempty_list(COMMA,param)) RPAREN option(return_type).
        Start symbol: program. *)

  | MenhirState089 : (((((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_cell1_option_where_clause_, _menhir_box_program) _menhir_state
    (** State 089.
        Stack shape : visibility DEF IDENT option(type_params) LPAREN loption(separated_nonempty_list(COMMA,param)) RPAREN option(return_type) option(where_clause).
        Start symbol: program. *)

  | MenhirState090 : (('s, _menhir_box_program) _menhir_cell1_PRE, _menhir_box_program) _menhir_state
    (** State 090.
        Stack shape : PRE.
        Start symbol: program. *)

  | MenhirState091 : (('s, _menhir_box_program) _menhir_cell1_WHILE, _menhir_box_program) _menhir_state
    (** State 091.
        Stack shape : WHILE.
        Start symbol: program. *)

  | MenhirState092 : (('s, _menhir_box_program) _menhir_cell1_UNSAFE, _menhir_box_program) _menhir_state
    (** State 092.
        Stack shape : UNSAFE.
        Start symbol: program. *)

  | MenhirState093 : (('s, _menhir_box_program) _menhir_cell1_rev_block_items, _menhir_box_program) _menhir_state
    (** State 093.
        Stack shape : rev_block_items.
        Start symbol: program. *)

  | MenhirState095 : (('s, _menhir_box_program) _menhir_cell1_TILDE, _menhir_box_program) _menhir_state
    (** State 095.
        Stack shape : TILDE.
        Start symbol: program. *)

  | MenhirState097 : (('s, _menhir_box_program) _menhir_cell1_STAR, _menhir_box_program) _menhir_state
    (** State 097.
        Stack shape : STAR.
        Start symbol: program. *)

  | MenhirState099 : (('s, _menhir_box_program) _menhir_cell1_RETURN, _menhir_box_program) _menhir_state
    (** State 099.
        Stack shape : RETURN.
        Start symbol: program. *)

  | MenhirState100 : (('s, _menhir_box_program) _menhir_cell1_NEXT, _menhir_box_program) _menhir_state
    (** State 100.
        Stack shape : NEXT.
        Start symbol: program. *)

  | MenhirState103 : (('s, _menhir_box_program) _menhir_cell1_MINUS, _menhir_box_program) _menhir_state
    (** State 103.
        Stack shape : MINUS.
        Start symbol: program. *)

  | MenhirState104 : (('s, _menhir_box_program) _menhir_cell1_MATCH, _menhir_box_program) _menhir_state
    (** State 104.
        Stack shape : MATCH.
        Start symbol: program. *)

  | MenhirState105 : (('s, _menhir_box_program) _menhir_cell1_LPAREN, _menhir_box_program) _menhir_state
    (** State 105.
        Stack shape : LPAREN.
        Start symbol: program. *)

  | MenhirState106 : (('s, _menhir_box_program) _menhir_cell1_LOOP, _menhir_box_program) _menhir_state
    (** State 106.
        Stack shape : LOOP.
        Start symbol: program. *)

  | MenhirState109 : (('s, _menhir_box_program) _menhir_cell1_LBRACKET, _menhir_box_program) _menhir_state
    (** State 109.
        Stack shape : LBRACKET.
        Start symbol: program. *)

  | MenhirState111 : (('s, _menhir_box_program) _menhir_cell1_IF, _menhir_box_program) _menhir_state
    (** State 111.
        Stack shape : IF.
        Start symbol: program. *)

  | MenhirState113 : (('s, _menhir_box_program) _menhir_cell1_IDENT, _menhir_box_program) _menhir_state
    (** State 113.
        Stack shape : IDENT.
        Start symbol: program. *)

  | MenhirState115 : (('s, _menhir_box_program) _menhir_cell1_IDENT, _menhir_box_program) _menhir_state
    (** State 115.
        Stack shape : IDENT.
        Start symbol: program. *)

  | MenhirState116 : (('s, _menhir_box_program) _menhir_cell1_FOR, _menhir_box_program) _menhir_state
    (** State 116.
        Stack shape : FOR.
        Start symbol: program. *)

  | MenhirState117 : (('s, _menhir_box_program) _menhir_cell1_LPAREN, _menhir_box_program) _menhir_state
    (** State 117.
        Stack shape : LPAREN.
        Start symbol: program. *)

  | MenhirState119 : (('s, _menhir_box_program) _menhir_cell1_IDENT, _menhir_box_program) _menhir_state
    (** State 119.
        Stack shape : IDENT.
        Start symbol: program. *)

  | MenhirState121 : (('s, _menhir_box_program) _menhir_cell1_IDENT, _menhir_box_program) _menhir_state
    (** State 121.
        Stack shape : IDENT.
        Start symbol: program. *)

  | MenhirState131 : (('s, _menhir_box_program) _menhir_cell1_pattern_field, _menhir_box_program) _menhir_state
    (** State 131.
        Stack shape : pattern_field.
        Start symbol: program. *)

  | MenhirState137 : (('s, _menhir_box_program) _menhir_cell1_IDENT _menhir_cell0_IDENT _menhir_cell0_LPAREN, _menhir_box_program) _menhir_state
    (** State 137.
        Stack shape : IDENT IDENT LPAREN.
        Start symbol: program. *)

  | MenhirState140 : (('s, _menhir_box_program) _menhir_cell1_pattern, _menhir_box_program) _menhir_state
    (** State 140.
        Stack shape : pattern.
        Start symbol: program. *)

  | MenhirState149 : ((('s, _menhir_box_program) _menhir_cell1_FOR, _menhir_box_program) _menhir_cell1_pattern, _menhir_box_program) _menhir_state
    (** State 149.
        Stack shape : FOR pattern.
        Start symbol: program. *)

  | MenhirState150 : (('s, _menhir_box_program) _menhir_cell1_DO, _menhir_box_program) _menhir_state
    (** State 150.
        Stack shape : DO.
        Start symbol: program. *)

  | MenhirState153 : (('s, _menhir_box_program) _menhir_cell1_CONTINUE, _menhir_box_program) _menhir_state
    (** State 153.
        Stack shape : CONTINUE.
        Start symbol: program. *)

  | MenhirState155 : (('s, _menhir_box_program) _menhir_cell1_BREAK, _menhir_box_program) _menhir_state
    (** State 155.
        Stack shape : BREAK.
        Start symbol: program. *)

  | MenhirState156 : ((('s, _menhir_box_program) _menhir_cell1_BREAK, _menhir_box_program) _menhir_cell1_option_IDENT_, _menhir_box_program) _menhir_state
    (** State 156.
        Stack shape : BREAK option(IDENT).
        Start symbol: program. *)

  | MenhirState157 : (('s, _menhir_box_program) _menhir_cell1_BANG, _menhir_box_program) _menhir_state
    (** State 157.
        Stack shape : BANG.
        Start symbol: program. *)

  | MenhirState158 : (('s, _menhir_box_program) _menhir_cell1_AMP, _menhir_box_program) _menhir_state
    (** State 158.
        Stack shape : AMP.
        Start symbol: program. *)

  | MenhirState159 : ((('s, _menhir_box_program) _menhir_cell1_AMP, _menhir_box_program) _menhir_cell1_MUT, _menhir_box_program) _menhir_state
    (** State 159.
        Stack shape : AMP MUT.
        Start symbol: program. *)

  | MenhirState167 : (('s, _menhir_box_program) _menhir_cell1_postfix_expr _menhir_cell0_LPAREN, _menhir_box_program) _menhir_state
    (** State 167.
        Stack shape : postfix_expr LPAREN.
        Start symbol: program. *)

  | MenhirState170 : (('s, _menhir_box_program) _menhir_cell1_shift_expr, _menhir_box_program) _menhir_state
    (** State 170.
        Stack shape : shift_expr.
        Start symbol: program. *)

  | MenhirState173 : (('s, _menhir_box_program) _menhir_cell1_multiplicative_expr _menhir_cell0_STAR, _menhir_box_program) _menhir_state
    (** State 173.
        Stack shape : multiplicative_expr STAR.
        Start symbol: program. *)

  | MenhirState183 : (('s, _menhir_box_program) _menhir_cell1_multiplicative_expr, _menhir_box_program) _menhir_state
    (** State 183.
        Stack shape : multiplicative_expr.
        Start symbol: program. *)

  | MenhirState185 : (('s, _menhir_box_program) _menhir_cell1_multiplicative_expr, _menhir_box_program) _menhir_state
    (** State 185.
        Stack shape : multiplicative_expr.
        Start symbol: program. *)

  | MenhirState188 : (('s, _menhir_box_program) _menhir_cell1_additive_expr, _menhir_box_program) _menhir_state
    (** State 188.
        Stack shape : additive_expr.
        Start symbol: program. *)

  | MenhirState190 : (('s, _menhir_box_program) _menhir_cell1_additive_expr _menhir_cell0_MINUS, _menhir_box_program) _menhir_state
    (** State 190.
        Stack shape : additive_expr MINUS.
        Start symbol: program. *)

  | MenhirState192 : (('s, _menhir_box_program) _menhir_cell1_shift_expr, _menhir_box_program) _menhir_state
    (** State 192.
        Stack shape : shift_expr.
        Start symbol: program. *)

  | MenhirState196 : (('s, _menhir_box_program) _menhir_cell1_or_expr, _menhir_box_program) _menhir_state
    (** State 196.
        Stack shape : or_expr.
        Start symbol: program. *)

  | MenhirState198 : (('s, _menhir_box_program) _menhir_cell1_equality_expr, _menhir_box_program) _menhir_state
    (** State 198.
        Stack shape : equality_expr.
        Start symbol: program. *)

  | MenhirState200 : (('s, _menhir_box_program) _menhir_cell1_comparison_expr, _menhir_box_program) _menhir_state
    (** State 200.
        Stack shape : comparison_expr.
        Start symbol: program. *)

  | MenhirState203 : (('s, _menhir_box_program) _menhir_cell1_comparison_expr, _menhir_box_program) _menhir_state
    (** State 203.
        Stack shape : comparison_expr.
        Start symbol: program. *)

  | MenhirState205 : (('s, _menhir_box_program) _menhir_cell1_comparison_expr, _menhir_box_program) _menhir_state
    (** State 205.
        Stack shape : comparison_expr.
        Start symbol: program. *)

  | MenhirState207 : (('s, _menhir_box_program) _menhir_cell1_comparison_expr, _menhir_box_program) _menhir_state
    (** State 207.
        Stack shape : comparison_expr.
        Start symbol: program. *)

  | MenhirState209 : (('s, _menhir_box_program) _menhir_cell1_equality_expr, _menhir_box_program) _menhir_state
    (** State 209.
        Stack shape : equality_expr.
        Start symbol: program. *)

  | MenhirState213 : (('s, _menhir_box_program) _menhir_cell1_bitxor_expr, _menhir_box_program) _menhir_state
    (** State 213.
        Stack shape : bitxor_expr.
        Start symbol: program. *)

  | MenhirState215 : (('s, _menhir_box_program) _menhir_cell1_bitand_expr _menhir_cell0_AMP, _menhir_box_program) _menhir_state
    (** State 215.
        Stack shape : bitand_expr AMP.
        Start symbol: program. *)

  | MenhirState218 : (('s, _menhir_box_program) _menhir_cell1_bitor_expr, _menhir_box_program) _menhir_state
    (** State 218.
        Stack shape : bitor_expr.
        Start symbol: program. *)

  | MenhirState223 : (('s, _menhir_box_program) _menhir_cell1_and_expr, _menhir_box_program) _menhir_state
    (** State 223.
        Stack shape : and_expr.
        Start symbol: program. *)

  | MenhirState225 : (('s, _menhir_box_program) _menhir_cell1_or_expr, _menhir_box_program) _menhir_state
    (** State 225.
        Stack shape : or_expr.
        Start symbol: program. *)

  | MenhirState227 : (('s, _menhir_box_program) _menhir_cell1_or_expr, _menhir_box_program) _menhir_state
    (** State 227.
        Stack shape : or_expr.
        Start symbol: program. *)

  | MenhirState229 : (('s, _menhir_box_program) _menhir_cell1_or_expr, _menhir_box_program) _menhir_state
    (** State 229.
        Stack shape : or_expr.
        Start symbol: program. *)

  | MenhirState231 : (('s, _menhir_box_program) _menhir_cell1_or_expr, _menhir_box_program) _menhir_state
    (** State 231.
        Stack shape : or_expr.
        Start symbol: program. *)

  | MenhirState233 : (('s, _menhir_box_program) _menhir_cell1_or_expr, _menhir_box_program) _menhir_state
    (** State 233.
        Stack shape : or_expr.
        Start symbol: program. *)

  | MenhirState235 : (('s, _menhir_box_program) _menhir_cell1_or_expr, _menhir_box_program) _menhir_state
    (** State 235.
        Stack shape : or_expr.
        Start symbol: program. *)

  | MenhirState240 : (('s, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_state
    (** State 240.
        Stack shape : expr.
        Start symbol: program. *)

  | MenhirState243 : (('s, _menhir_box_program) _menhir_cell1_postfix_expr _menhir_cell0_LBRACKET, _menhir_box_program) _menhir_state
    (** State 243.
        Stack shape : postfix_expr LBRACKET.
        Start symbol: program. *)

  | MenhirState249 : (('s, _menhir_box_program) _menhir_cell1_postfix_expr _menhir_cell0_IDENT _menhir_cell0_LPAREN, _menhir_box_program) _menhir_state
    (** State 249.
        Stack shape : postfix_expr IDENT LPAREN.
        Start symbol: program. *)

  | MenhirState252 : (('s, _menhir_box_program) _menhir_cell1_postfix_expr, _menhir_box_program) _menhir_state
    (** State 252.
        Stack shape : postfix_expr.
        Start symbol: program. *)

  | MenhirState258 : (((('s, _menhir_box_program) _menhir_cell1_FOR, _menhir_box_program) _menhir_cell1_pattern, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_state
    (** State 258.
        Stack shape : FOR pattern expr.
        Start symbol: program. *)

  | MenhirState260 : ((((('s, _menhir_box_program) _menhir_cell1_FOR, _menhir_box_program) _menhir_cell1_pattern, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_DO_, _menhir_box_program) _menhir_state
    (** State 260.
        Stack shape : FOR pattern expr option(DO).
        Start symbol: program. *)

  | MenhirState265 : (('s, _menhir_box_program) _menhir_cell1_struct_field, _menhir_box_program) _menhir_state
    (** State 265.
        Stack shape : struct_field.
        Start symbol: program. *)

  | MenhirState270 : (('s, _menhir_box_program) _menhir_cell1_IDENT, _menhir_box_program) _menhir_state
    (** State 270.
        Stack shape : IDENT.
        Start symbol: program. *)

  | MenhirState272 : ((('s, _menhir_box_program) _menhir_cell1_IDENT, _menhir_box_program) _menhir_cell1_IDENT, _menhir_box_program) _menhir_state
    (** State 272.
        Stack shape : IDENT IDENT.
        Start symbol: program. *)

  | MenhirState275 : ((('s, _menhir_box_program) _menhir_cell1_IF, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_state
    (** State 275.
        Stack shape : IF expr.
        Start symbol: program. *)

  | MenhirState277 : (((('s, _menhir_box_program) _menhir_cell1_IF, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_THEN_, _menhir_box_program) _menhir_state
    (** State 277.
        Stack shape : IF expr option(THEN).
        Start symbol: program. *)

  | MenhirState278 : ((((('s, _menhir_box_program) _menhir_cell1_IF, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_THEN_, _menhir_box_program) _menhir_cell1_block, _menhir_box_program) _menhir_state
    (** State 278.
        Stack shape : IF expr option(THEN) block.
        Start symbol: program. *)

  | MenhirState279 : (('s, _menhir_box_program) _menhir_cell1_ELSIF, _menhir_box_program) _menhir_state
    (** State 279.
        Stack shape : ELSIF.
        Start symbol: program. *)

  | MenhirState280 : ((('s, _menhir_box_program) _menhir_cell1_ELSIF, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_state
    (** State 280.
        Stack shape : ELSIF expr.
        Start symbol: program. *)

  | MenhirState281 : (((('s, _menhir_box_program) _menhir_cell1_ELSIF, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_THEN_, _menhir_box_program) _menhir_state
    (** State 281.
        Stack shape : ELSIF expr option(THEN).
        Start symbol: program. *)

  | MenhirState284 : (((((('s, _menhir_box_program) _menhir_cell1_IF, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_THEN_, _menhir_box_program) _menhir_cell1_block, _menhir_box_program) _menhir_cell1_list_elsif_, _menhir_box_program) _menhir_state
    (** State 284.
        Stack shape : IF expr option(THEN) block list(elsif).
        Start symbol: program. *)

  | MenhirState289 : (('s, _menhir_box_program) _menhir_cell1_elsif, _menhir_box_program) _menhir_state
    (** State 289.
        Stack shape : elsif.
        Start symbol: program. *)

  | MenhirState295 : ((('s, _menhir_box_program) _menhir_cell1_MATCH, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_state
    (** State 295.
        Stack shape : MATCH expr.
        Start symbol: program. *)

  | MenhirState296 : (((('s, _menhir_box_program) _menhir_cell1_MATCH, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_DO_, _menhir_box_program) _menhir_state
    (** State 296.
        Stack shape : MATCH expr option(DO).
        Start symbol: program. *)

  | MenhirState297 : (('s, _menhir_box_program) _menhir_cell1_WHEN, _menhir_box_program) _menhir_state
    (** State 297.
        Stack shape : WHEN.
        Start symbol: program. *)

  | MenhirState299 : ((('s, _menhir_box_program) _menhir_cell1_WHEN, _menhir_box_program) _menhir_cell1_pattern _menhir_cell0_IF, _menhir_box_program) _menhir_state
    (** State 299.
        Stack shape : WHEN pattern IF.
        Start symbol: program. *)

  | MenhirState302 : ((('s, _menhir_box_program) _menhir_cell1_WHEN, _menhir_box_program) _menhir_cell1_pattern _menhir_cell0_option_match_guard_, _menhir_box_program) _menhir_state
    (** State 302.
        Stack shape : WHEN pattern option(match_guard).
        Start symbol: program. *)

  | MenhirState307 : (('s, _menhir_box_program) _menhir_cell1_match_arm, _menhir_box_program) _menhir_state
    (** State 307.
        Stack shape : match_arm.
        Start symbol: program. *)

  | MenhirState315 : ((('s, _menhir_box_program) _menhir_cell1_rev_block_items, _menhir_box_program) _menhir_cell1_LET, _menhir_box_program) _menhir_state
    (** State 315.
        Stack shape : rev_block_items LET.
        Start symbol: program. *)

  | MenhirState316 : (((('s, _menhir_box_program) _menhir_cell1_rev_block_items, _menhir_box_program) _menhir_cell1_LET, _menhir_box_program) _menhir_cell1_option_MUT_, _menhir_box_program) _menhir_state
    (** State 316.
        Stack shape : rev_block_items LET option(MUT).
        Start symbol: program. *)

  | MenhirState318 : ((((('s, _menhir_box_program) _menhir_cell1_rev_block_items, _menhir_box_program) _menhir_cell1_LET, _menhir_box_program) _menhir_cell1_option_MUT_, _menhir_box_program) _menhir_cell1_pattern, _menhir_box_program) _menhir_state
    (** State 318.
        Stack shape : rev_block_items LET option(MUT) pattern.
        Start symbol: program. *)

  | MenhirState322 : ((((('s, _menhir_box_program) _menhir_cell1_rev_block_items, _menhir_box_program) _menhir_cell1_LET, _menhir_box_program) _menhir_cell1_option_MUT_, _menhir_box_program) _menhir_cell1_pattern _menhir_cell0_option_type_annotation_, _menhir_box_program) _menhir_state
    (** State 322.
        Stack shape : rev_block_items LET option(MUT) pattern option(type_annotation).
        Start symbol: program. *)

  | MenhirState332 : ((('s, _menhir_box_program) _menhir_cell1_WHILE, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_state
    (** State 332.
        Stack shape : WHILE expr.
        Start symbol: program. *)

  | MenhirState333 : (((('s, _menhir_box_program) _menhir_cell1_WHILE, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_DO_, _menhir_box_program) _menhir_state
    (** State 333.
        Stack shape : WHILE expr option(DO).
        Start symbol: program. *)

  | MenhirState336 : ((('s, _menhir_box_program) _menhir_cell1_PRE, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_state
    (** State 336.
        Stack shape : PRE expr.
        Start symbol: program. *)

  | MenhirState341 : (('s, _menhir_box_program) _menhir_cell1_POST, _menhir_box_program) _menhir_state
    (** State 341.
        Stack shape : POST.
        Start symbol: program. *)

  | MenhirState342 : ((('s, _menhir_box_program) _menhir_cell1_POST, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_state
    (** State 342.
        Stack shape : POST expr.
        Start symbol: program. *)

  | MenhirState344 : (('s, _menhir_box_program) _menhir_cell1_INVARIANT, _menhir_box_program) _menhir_state
    (** State 344.
        Stack shape : INVARIANT.
        Start symbol: program. *)

  | MenhirState345 : ((('s, _menhir_box_program) _menhir_cell1_INVARIANT, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_state
    (** State 345.
        Stack shape : INVARIANT expr.
        Start symbol: program. *)

  | MenhirState347 : ((((((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_cell1_option_where_clause_, _menhir_box_program) _menhir_cell1_list_contract_, _menhir_box_program) _menhir_state
    (** State 347.
        Stack shape : visibility DEF IDENT option(type_params) LPAREN loption(separated_nonempty_list(COMMA,param)) RPAREN option(return_type) option(where_clause) list(contract).
        Start symbol: program. *)

  | MenhirState348 : (('s, _menhir_box_program) _menhir_cell1_REQUIRES, _menhir_box_program) _menhir_state
    (** State 348.
        Stack shape : REQUIRES.
        Start symbol: program. *)

  | MenhirState352 : (('s, _menhir_box_program) _menhir_cell1_requires_item, _menhir_box_program) _menhir_state
    (** State 352.
        Stack shape : requires_item.
        Start symbol: program. *)

  | MenhirState356 : (('s, _menhir_box_program) _menhir_cell1_requires_clause, _menhir_box_program) _menhir_state
    (** State 356.
        Stack shape : requires_clause.
        Start symbol: program. *)

  | MenhirState359 : (((((((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_cell1_option_where_clause_, _menhir_box_program) _menhir_cell1_list_contract_, _menhir_box_program) _menhir_cell1_list_requires_clause_, _menhir_box_program) _menhir_state
    (** State 359.
        Stack shape : visibility DEF IDENT option(type_params) LPAREN loption(separated_nonempty_list(COMMA,param)) RPAREN option(return_type) option(where_clause) list(contract) list(requires_clause).
        Start symbol: program. *)

  | MenhirState361 : (('s, _menhir_box_program) _menhir_cell1_IDENT, _menhir_box_program) _menhir_state
    (** State 361.
        Stack shape : IDENT.
        Start symbol: program. *)

  | MenhirState365 : (((((((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_cell1_option_where_clause_, _menhir_box_program) _menhir_cell1_list_contract_, _menhir_box_program) _menhir_cell1_list_requires_clause_ _menhir_cell0_option_effect_clause_, _menhir_box_program) _menhir_state
    (** State 365.
        Stack shape : visibility DEF IDENT option(type_params) LPAREN loption(separated_nonempty_list(COMMA,param)) RPAREN option(return_type) option(where_clause) list(contract) list(requires_clause) option(effect_clause).
        Start symbol: program. *)

  | MenhirState372 : (('s, _menhir_box_program) _menhir_cell1_budget_entry, _menhir_box_program) _menhir_state
    (** State 372.
        Stack shape : budget_entry.
        Start symbol: program. *)

  | MenhirState374 : (((((((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_cell1_option_where_clause_, _menhir_box_program) _menhir_cell1_list_contract_, _menhir_box_program) _menhir_cell1_list_requires_clause_ _menhir_cell0_option_effect_clause_ _menhir_cell0_option_budget_clause_, _menhir_box_program) _menhir_state
    (** State 374.
        Stack shape : visibility DEF IDENT option(type_params) LPAREN loption(separated_nonempty_list(COMMA,param)) RPAREN option(return_type) option(where_clause) list(contract) list(requires_clause) option(effect_clause) option(budget_clause).
        Start symbol: program. *)

  | MenhirState379 : (('s, _menhir_box_program) _menhir_cell1_contract, _menhir_box_program) _menhir_state
    (** State 379.
        Stack shape : contract.
        Start symbol: program. *)

  | MenhirState383 : (('s, _menhir_box_program) _menhir_cell1_impl_item, _menhir_box_program) _menhir_state
    (** State 383.
        Stack shape : impl_item.
        Start symbol: program. *)

  | MenhirState389 : (('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 389.
        Stack shape : visibility IDENT.
        Start symbol: program. *)

  | MenhirState392 : (('s _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_COLON_COLON, _menhir_box_program) _menhir_state
    (** State 392.
        Stack shape : IDENT COLON_COLON.
        Start symbol: program. *)

  | MenhirState399 : (('s, _menhir_box_program) _menhir_cell1_use_item, _menhir_box_program) _menhir_state
    (** State 399.
        Stack shape : use_item.
        Start symbol: program. *)

  | MenhirState402 : (('s _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_COLON_COLON _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 402.
        Stack shape : IDENT COLON_COLON IDENT.
        Start symbol: program. *)

  | MenhirState408 : (('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_TYPE _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 408.
        Stack shape : visibility TYPE IDENT.
        Start symbol: program. *)

  | MenhirState410 : ((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_TYPE _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_, _menhir_box_program) _menhir_state
    (** State 410.
        Stack shape : visibility TYPE IDENT option(type_params).
        Start symbol: program. *)

  | MenhirState413 : (('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 413.
        Stack shape : visibility IDENT.
        Start symbol: program. *)

  | MenhirState415 : ((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_, _menhir_box_program) _menhir_state
    (** State 415.
        Stack shape : visibility IDENT option(type_params).
        Start symbol: program. *)

  | MenhirState418 : ((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_option_trait_super_, _menhir_box_program) _menhir_state
    (** State 418.
        Stack shape : visibility IDENT option(type_params) option(trait_super).
        Start symbol: program. *)

  | MenhirState420 : (('s, _menhir_box_program) _menhir_cell1_TYPE _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 420.
        Stack shape : TYPE IDENT.
        Start symbol: program. *)

  | MenhirState423 : (('s, _menhir_box_program) _menhir_cell1_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 423.
        Stack shape : DEF IDENT.
        Start symbol: program. *)

  | MenhirState425 : ((('s, _menhir_box_program) _menhir_cell1_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_state
    (** State 425.
        Stack shape : DEF IDENT option(type_params) LPAREN.
        Start symbol: program. *)

  | MenhirState427 : (((('s, _menhir_box_program) _menhir_cell1_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_state
    (** State 427.
        Stack shape : DEF IDENT option(type_params) LPAREN loption(separated_nonempty_list(COMMA,param)) RPAREN.
        Start symbol: program. *)

  | MenhirState428 : ((((('s, _menhir_box_program) _menhir_cell1_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_state
    (** State 428.
        Stack shape : DEF IDENT option(type_params) LPAREN loption(separated_nonempty_list(COMMA,param)) RPAREN option(return_type).
        Start symbol: program. *)

  | MenhirState436 : (('s, _menhir_box_program) _menhir_cell1_trait_item, _menhir_box_program) _menhir_state
    (** State 436.
        Stack shape : trait_item.
        Start symbol: program. *)

  | MenhirState441 : (('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 441.
        Stack shape : visibility IDENT.
        Start symbol: program. *)

  | MenhirState442 : ((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_, _menhir_box_program) _menhir_state
    (** State 442.
        Stack shape : visibility IDENT option(type_params).
        Start symbol: program. *)

  | MenhirState445 : (('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 445.
        Stack shape : visibility IDENT.
        Start symbol: program. *)

  | MenhirState449 : (('s, _menhir_box_program) _menhir_cell1_field_def, _menhir_box_program) _menhir_state
    (** State 449.
        Stack shape : field_def.
        Start symbol: program. *)

  | MenhirState452 : (('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 452.
        Stack shape : visibility IDENT.
        Start symbol: program. *)

  | MenhirState460 : (('s, _menhir_box_program) _menhir_cell1_item, _menhir_box_program) _menhir_state
    (** State 460.
        Stack shape : item.
        Start symbol: program. *)

  | MenhirState467 : (('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 467.
        Stack shape : visibility IDENT.
        Start symbol: program. *)

  | MenhirState468 : ((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_, _menhir_box_program) _menhir_state
    (** State 468.
        Stack shape : visibility IDENT option(type_params).
        Start symbol: program. *)

  | MenhirState470 : (('s, _menhir_box_program) _menhir_cell1_IDENT _menhir_cell0_LPAREN, _menhir_box_program) _menhir_state
    (** State 470.
        Stack shape : IDENT LPAREN.
        Start symbol: program. *)

  | MenhirState472 : (('s, _menhir_box_program) _menhir_cell1_IDENT, _menhir_box_program) _menhir_state
    (** State 472.
        Stack shape : IDENT.
        Start symbol: program. *)

  | MenhirState475 : (('s, _menhir_box_program) _menhir_cell1_variant_field, _menhir_box_program) _menhir_state
    (** State 475.
        Stack shape : variant_field.
        Start symbol: program. *)

  | MenhirState482 : (('s, _menhir_box_program) _menhir_cell1_variant_def, _menhir_box_program) _menhir_state
    (** State 482.
        Stack shape : variant_def.
        Start symbol: program. *)

  | MenhirState488 : (('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_state
    (** State 488.
        Stack shape : visibility IDENT.
        Start symbol: program. *)

  | MenhirState490 : ((('s, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_type_expr, _menhir_box_program) _menhir_state
    (** State 490.
        Stack shape : visibility IDENT type_expr.
        Start symbol: program. *)


and ('s, 'r) _menhir_cell1_additive_expr = 
  | MenhirCell1_additive_expr of 's * ('s, 'r) _menhir_state * (Ast.expr) * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_and_expr = 
  | MenhirCell1_and_expr of 's * ('s, 'r) _menhir_state * (Ast.expr) * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_bitand_expr = 
  | MenhirCell1_bitand_expr of 's * ('s, 'r) _menhir_state * (Ast.expr) * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_bitor_expr = 
  | MenhirCell1_bitor_expr of 's * ('s, 'r) _menhir_state * (Ast.expr) * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_bitxor_expr = 
  | MenhirCell1_bitxor_expr of 's * ('s, 'r) _menhir_state * (Ast.expr) * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_block = 
  | MenhirCell1_block of 's * ('s, 'r) _menhir_state * (Ast.block)

and ('s, 'r) _menhir_cell1_budget_entry = 
  | MenhirCell1_budget_entry of 's * ('s, 'r) _menhir_state * (string * int64 * string)

and ('s, 'r) _menhir_cell1_comparison_expr = 
  | MenhirCell1_comparison_expr of 's * ('s, 'r) _menhir_state * (Ast.expr) * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_contract = 
  | MenhirCell1_contract of 's * ('s, 'r) _menhir_state * (Ast.contract)

and ('s, 'r) _menhir_cell1_elsif = 
  | MenhirCell1_elsif of 's * ('s, 'r) _menhir_state * (Ast.expr * Ast.block)

and ('s, 'r) _menhir_cell1_equality_expr = 
  | MenhirCell1_equality_expr of 's * ('s, 'r) _menhir_state * (Ast.expr) * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_expr = 
  | MenhirCell1_expr of 's * ('s, 'r) _menhir_state * (Ast.expr) * Lexing.position

and ('s, 'r) _menhir_cell1_field_def = 
  | MenhirCell1_field_def of 's * ('s, 'r) _menhir_state * (Ast.field_def)

and ('s, 'r) _menhir_cell1_impl_item = 
  | MenhirCell1_impl_item of 's * ('s, 'r) _menhir_state * (Ast.impl_item)

and ('s, 'r) _menhir_cell1_item = 
  | MenhirCell1_item of 's * ('s, 'r) _menhir_state * (Ast.item)

and ('s, 'r) _menhir_cell1_list_contract_ = 
  | MenhirCell1_list_contract_ of 's * ('s, 'r) _menhir_state * (Ast.contract list)

and ('s, 'r) _menhir_cell1_list_elsif_ = 
  | MenhirCell1_list_elsif_ of 's * ('s, 'r) _menhir_state * ((Ast.expr * Ast.block) list)

and ('s, 'r) _menhir_cell1_list_requires_clause_ = 
  | MenhirCell1_list_requires_clause_ of 's * ('s, 'r) _menhir_state * (Ast.requires_clause list list)

and ('s, 'r) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ = 
  | MenhirCell1_loption_separated_nonempty_list_COMMA_param__ of 's * ('s, 'r) _menhir_state * (Ast.param list)

and ('s, 'r) _menhir_cell1_loption_separated_nonempty_list_COMMA_type_expr__ = 
  | MenhirCell1_loption_separated_nonempty_list_COMMA_type_expr__ of 's * ('s, 'r) _menhir_state * (Ast.ty list)

and ('s, 'r) _menhir_cell1_match_arm = 
  | MenhirCell1_match_arm of 's * ('s, 'r) _menhir_state * (Ast.match_arm)

and ('s, 'r) _menhir_cell1_multiplicative_expr = 
  | MenhirCell1_multiplicative_expr of 's * ('s, 'r) _menhir_state * (Ast.expr) * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_option_DO_ = 
  | MenhirCell1_option_DO_ of 's * ('s, 'r) _menhir_state * (unit option)

and 's _menhir_cell0_option_FOR_ = 
  | MenhirCell0_option_FOR_ of 's * (unit option)

and ('s, 'r) _menhir_cell1_option_IDENT_ = 
  | MenhirCell1_option_IDENT_ of 's * ('s, 'r) _menhir_state * (string option) * Lexing.position

and ('s, 'r) _menhir_cell1_option_MUT_ = 
  | MenhirCell1_option_MUT_ of 's * ('s, 'r) _menhir_state * (unit option) * Lexing.position

and ('s, 'r) _menhir_cell1_option_THEN_ = 
  | MenhirCell1_option_THEN_ of 's * ('s, 'r) _menhir_state * (unit option)

and 's _menhir_cell0_option_budget_clause_ = 
  | MenhirCell0_option_budget_clause_ of 's * ((string * int64 * string) list option)

and 's _menhir_cell0_option_effect_clause_ = 
  | MenhirCell0_option_effect_clause_ of 's * (string list option)

and 's _menhir_cell0_option_impl_trait_ = 
  | MenhirCell0_option_impl_trait_ of 's * ((string * Ast.ty list) option)

and 's _menhir_cell0_option_match_guard_ = 
  | MenhirCell0_option_match_guard_ of 's * (Ast.expr option)

and ('s, 'r) _menhir_cell1_option_return_type_ = 
  | MenhirCell1_option_return_type_ of 's * ('s, 'r) _menhir_state * (Ast.ty option)

and ('s, 'r) _menhir_cell1_option_trait_method_body_ = 
  | MenhirCell1_option_trait_method_body_ of 's * ('s, 'r) _menhir_state * (Ast.block option)

and 's _menhir_cell0_option_trait_super_ = 
  | MenhirCell0_option_trait_super_ of 's * (string list option)

and 's _menhir_cell0_option_type_annotation_ = 
  | MenhirCell0_option_type_annotation_ of 's * (Ast.ty option)

and ('s, 'r) _menhir_cell1_option_type_params_ = 
  | MenhirCell1_option_type_params_ of 's * ('s, 'r) _menhir_state * (Ast.type_param list option)

and ('s, 'r) _menhir_cell1_option_where_clause_ = 
  | MenhirCell1_option_where_clause_ of 's * ('s, 'r) _menhir_state * (Ast.where_pred list option)

and ('s, 'r) _menhir_cell1_or_expr = 
  | MenhirCell1_or_expr of 's * ('s, 'r) _menhir_state * (Ast.expr) * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_param = 
  | MenhirCell1_param of 's * ('s, 'r) _menhir_state * (Ast.param)

and ('s, 'r) _menhir_cell1_pattern = 
  | MenhirCell1_pattern of 's * ('s, 'r) _menhir_state * (Ast.pattern)

and ('s, 'r) _menhir_cell1_pattern_field = 
  | MenhirCell1_pattern_field of 's * ('s, 'r) _menhir_state * (string * Ast.pattern)

and ('s, 'r) _menhir_cell1_postfix_expr = 
  | MenhirCell1_postfix_expr of 's * ('s, 'r) _menhir_state * (Ast.expr) * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_requires_clause = 
  | MenhirCell1_requires_clause of 's * ('s, 'r) _menhir_state * (Ast.requires_clause list)

and ('s, 'r) _menhir_cell1_requires_item = 
  | MenhirCell1_requires_item of 's * ('s, 'r) _menhir_state * (Ast.requires_clause)

and ('s, 'r) _menhir_cell1_rev_block_items = 
  | MenhirCell1_rev_block_items of 's * ('s, 'r) _menhir_state * (Ast.stmt list * Ast.expr option) * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_shift_expr = 
  | MenhirCell1_shift_expr of 's * ('s, 'r) _menhir_state * (Ast.expr) * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_struct_field = 
  | MenhirCell1_struct_field of 's * ('s, 'r) _menhir_state * (string * Ast.expr)

and ('s, 'r) _menhir_cell1_trait_item = 
  | MenhirCell1_trait_item of 's * ('s, 'r) _menhir_state * (Ast.trait_item)

and ('s, 'r) _menhir_cell1_type_expr = 
  | MenhirCell1_type_expr of 's * ('s, 'r) _menhir_state * (Ast.ty) * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_type_param = 
  | MenhirCell1_type_param of 's * ('s, 'r) _menhir_state * (Ast.type_param)

and ('s, 'r) _menhir_cell1_use_item = 
  | MenhirCell1_use_item of 's * ('s, 'r) _menhir_state * (string * string option)

and ('s, 'r) _menhir_cell1_variant_def = 
  | MenhirCell1_variant_def of 's * ('s, 'r) _menhir_state * (Ast.variant_def)

and ('s, 'r) _menhir_cell1_variant_field = 
  | MenhirCell1_variant_field of 's * ('s, 'r) _menhir_state * (Ast.variant_field)

and ('s, 'r) _menhir_cell1_visibility = 
  | MenhirCell1_visibility of 's * ('s, 'r) _menhir_state * (Ast.visibility) * Lexing.position

and ('s, 'r) _menhir_cell1_where_pred = 
  | MenhirCell1_where_pred of 's * ('s, 'r) _menhir_state * (Ast.where_pred)

and ('s, 'r) _menhir_cell1_AMP = 
  | MenhirCell1_AMP of 's * ('s, 'r) _menhir_state * Lexing.position

and 's _menhir_cell0_AMP = 
  | MenhirCell0_AMP of 's * Lexing.position

and ('s, 'r) _menhir_cell1_ARROW = 
  | MenhirCell1_ARROW of 's * ('s, 'r) _menhir_state

and ('s, 'r) _menhir_cell1_BANG = 
  | MenhirCell1_BANG of 's * ('s, 'r) _menhir_state * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_BREAK = 
  | MenhirCell1_BREAK of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_COLON = 
  | MenhirCell1_COLON of 's * ('s, 'r) _menhir_state

and ('s, 'r) _menhir_cell1_COLON_COLON = 
  | MenhirCell1_COLON_COLON of 's * ('s, 'r) _menhir_state

and ('s, 'r) _menhir_cell1_CONTINUE = 
  | MenhirCell1_CONTINUE of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_DEF = 
  | MenhirCell1_DEF of 's * ('s, 'r) _menhir_state * Lexing.position

and 's _menhir_cell0_DEF = 
  | MenhirCell0_DEF of 's * Lexing.position

and ('s, 'r) _menhir_cell1_DO = 
  | MenhirCell1_DO of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_ELSIF = 
  | MenhirCell1_ELSIF of 's * ('s, 'r) _menhir_state

and ('s, 'r) _menhir_cell1_FN = 
  | MenhirCell1_FN of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_FOR = 
  | MenhirCell1_FOR of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_IDENT = 
  | MenhirCell1_IDENT of 's * ('s, 'r) _menhir_state * 
# 22 "src/parser.mly"
       (string)
# 1185 "src/parser.ml"
 * Lexing.position * Lexing.position

and 's _menhir_cell0_IDENT = 
  | MenhirCell0_IDENT of 's * 
# 22 "src/parser.mly"
       (string)
# 1192 "src/parser.ml"
 * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_IF = 
  | MenhirCell1_IF of 's * ('s, 'r) _menhir_state * Lexing.position

and 's _menhir_cell0_IF = 
  | MenhirCell0_IF of 's * Lexing.position

and ('s, 'r) _menhir_cell1_IMPL = 
  | MenhirCell1_IMPL of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_INVARIANT = 
  | MenhirCell1_INVARIANT of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_LBRACKET = 
  | MenhirCell1_LBRACKET of 's * ('s, 'r) _menhir_state * Lexing.position

and 's _menhir_cell0_LBRACKET = 
  | MenhirCell0_LBRACKET of 's * Lexing.position

and ('s, 'r) _menhir_cell1_LET = 
  | MenhirCell1_LET of 's * ('s, 'r) _menhir_state

and ('s, 'r) _menhir_cell1_LOOP = 
  | MenhirCell1_LOOP of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_LPAREN = 
  | MenhirCell1_LPAREN of 's * ('s, 'r) _menhir_state * Lexing.position

and 's _menhir_cell0_LPAREN = 
  | MenhirCell0_LPAREN of 's * Lexing.position

and ('s, 'r) _menhir_cell1_MATCH = 
  | MenhirCell1_MATCH of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_MINUS = 
  | MenhirCell1_MINUS of 's * ('s, 'r) _menhir_state * Lexing.position

and 's _menhir_cell0_MINUS = 
  | MenhirCell0_MINUS of 's * Lexing.position

and ('s, 'r) _menhir_cell1_MUT = 
  | MenhirCell1_MUT of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_NEXT = 
  | MenhirCell1_NEXT of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_POST = 
  | MenhirCell1_POST of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_PRE = 
  | MenhirCell1_PRE of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_QUESTION = 
  | MenhirCell1_QUESTION of 's * ('s, 'r) _menhir_state * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_REQUIRES = 
  | MenhirCell1_REQUIRES of 's * ('s, 'r) _menhir_state

and ('s, 'r) _menhir_cell1_RETURN = 
  | MenhirCell1_RETURN of 's * ('s, 'r) _menhir_state * Lexing.position

and 's _menhir_cell0_RPAREN = 
  | MenhirCell0_RPAREN of 's * Lexing.position

and ('s, 'r) _menhir_cell1_STAR = 
  | MenhirCell1_STAR of 's * ('s, 'r) _menhir_state * Lexing.position * Lexing.position

and 's _menhir_cell0_STAR = 
  | MenhirCell0_STAR of 's * Lexing.position * Lexing.position

and ('s, 'r) _menhir_cell1_TILDE = 
  | MenhirCell1_TILDE of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_TYPE = 
  | MenhirCell1_TYPE of 's * ('s, 'r) _menhir_state * Lexing.position

and 's _menhir_cell0_TYPE = 
  | MenhirCell0_TYPE of 's * Lexing.position

and ('s, 'r) _menhir_cell1_UNSAFE = 
  | MenhirCell1_UNSAFE of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_WHEN = 
  | MenhirCell1_WHEN of 's * ('s, 'r) _menhir_state * Lexing.position

and ('s, 'r) _menhir_cell1_WHERE = 
  | MenhirCell1_WHERE of 's * ('s, 'r) _menhir_state

and ('s, 'r) _menhir_cell1_WHILE = 
  | MenhirCell1_WHILE of 's * ('s, 'r) _menhir_state * Lexing.position

and _menhir_box_program = 
  | MenhirBox_program of (Ast.program) [@@unboxed]

let _menhir_action_001 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 282 "src/parser.mly"
                                               ( ExprBinary (Add, l, r, make_span _startpos _endpos !current_file) )
# 1295 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_002 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 283 "src/parser.mly"
                                                ( ExprBinary (Sub, l, r, make_span _startpos _endpos !current_file) )
# 1305 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_003 =
  fun e ->
    (
# 284 "src/parser.mly"
                          ( e )
# 1313 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_004 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 249 "src/parser.mly"
                                    ( ExprBinary (And, l, r, make_span _startpos _endpos !current_file) )
# 1323 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_005 =
  fun e ->
    (
# 250 "src/parser.mly"
                 ( e )
# 1331 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_006 =
  fun _endpos_rhs_ _startpos_lhs_ lhs rhs ->
    let _endpos = _endpos_rhs_ in
    let _startpos = _startpos_lhs_ in
    (
# 231 "src/parser.mly"
    ( ExprAssign (lhs, rhs, make_span _startpos _endpos !current_file) )
# 1341 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_007 =
  fun _endpos_rhs_ _startpos_lhs_ lhs rhs ->
    let _endpos = _endpos_rhs_ in
    let _startpos = _startpos_lhs_ in
    (
# 233 "src/parser.mly"
    ( ExprCompoundAssign (Add, lhs, rhs, make_span _startpos _endpos !current_file) )
# 1351 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_008 =
  fun _endpos_rhs_ _startpos_lhs_ lhs rhs ->
    let _endpos = _endpos_rhs_ in
    let _startpos = _startpos_lhs_ in
    (
# 235 "src/parser.mly"
    ( ExprCompoundAssign (Sub, lhs, rhs, make_span _startpos _endpos !current_file) )
# 1361 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_009 =
  fun _endpos_rhs_ _startpos_lhs_ lhs rhs ->
    let _endpos = _endpos_rhs_ in
    let _startpos = _startpos_lhs_ in
    (
# 237 "src/parser.mly"
    ( ExprCompoundAssign (Mul, lhs, rhs, make_span _startpos _endpos !current_file) )
# 1371 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_010 =
  fun _endpos_rhs_ _startpos_lhs_ lhs rhs ->
    let _endpos = _endpos_rhs_ in
    let _startpos = _startpos_lhs_ in
    (
# 239 "src/parser.mly"
    ( ExprCompoundAssign (Div, lhs, rhs, make_span _startpos _endpos !current_file) )
# 1381 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_011 =
  fun _endpos_rhs_ _startpos_lhs_ lhs rhs ->
    let _endpos = _endpos_rhs_ in
    let _startpos = _startpos_lhs_ in
    (
# 241 "src/parser.mly"
    ( ExprCompoundAssign (Mod, lhs, rhs, make_span _startpos _endpos !current_file) )
# 1391 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_012 =
  fun e ->
    (
# 242 "src/parser.mly"
              ( e )
# 1399 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_013 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 261 "src/parser.mly"
                                      ( ExprBinary (BitAnd, l, r, make_span _startpos _endpos !current_file) )
# 1409 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_014 =
  fun e ->
    (
# 262 "src/parser.mly"
                    ( e )
# 1417 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_015 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 253 "src/parser.mly"
                                    ( ExprBinary (BitOr, l, r, make_span _startpos _endpos !current_file) )
# 1427 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_016 =
  fun e ->
    (
# 254 "src/parser.mly"
                  ( e )
# 1435 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_017 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 257 "src/parser.mly"
                                      ( ExprBinary (BitXor, l, r, make_span _startpos _endpos !current_file) )
# 1445 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_018 =
  fun e ->
    (
# 258 "src/parser.mly"
                  ( e )
# 1453 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_019 =
  fun _endpos_items_ _startpos_items_ items ->
    let _endpos = _endpos_items_ in
    let _startpos = _startpos_items_ in
    (
# 163 "src/parser.mly"
    ( let (stmts, trailing) = items in
      { stmts = List.rev stmts; expr = trailing; span = make_span _startpos _endpos !current_file } )
# 1464 "src/parser.ml"
     : (Ast.block))

let _menhir_action_020 =
  fun _endpos__3_ _startpos__1_ body ->
    let _endpos = _endpos__3_ in
    let _startpos = _startpos__1_ in
    (
# 385 "src/parser.mly"
    ( ExprBlock (body, make_span _startpos _endpos !current_file) )
# 1474 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_021 =
  fun _endpos_e_ _startpos__1_ e label ->
    let _endpos = _endpos_e_ in
    let _startpos = _startpos__1_ in
    (
# 391 "src/parser.mly"
                               ( ExprBreak (label, e, make_span _startpos _endpos !current_file) )
# 1484 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_022 =
  fun entries ->
    (
# 156 "src/parser.mly"
                                                                ( entries )
# 1492 "src/parser.ml"
     : ((string * int64 * string) list))

let _menhir_action_023 =
  fun amount resource unit ->
    (
# 159 "src/parser.mly"
                                                   ( (resource, amount, unit) )
# 1500 "src/parser.ml"
     : (string * int64 * string))

let _menhir_action_024 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 270 "src/parser.mly"
                                      ( ExprBinary (Lt, l, r, make_span _startpos _endpos !current_file) )
# 1510 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_025 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 271 "src/parser.mly"
                                      ( ExprBinary (Gt, l, r, make_span _startpos _endpos !current_file) )
# 1520 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_026 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 272 "src/parser.mly"
                                         ( ExprBinary (Le, l, r, make_span _startpos _endpos !current_file) )
# 1530 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_027 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 273 "src/parser.mly"
                                         ( ExprBinary (Ge, l, r, make_span _startpos _endpos !current_file) )
# 1540 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_028 =
  fun e ->
    (
# 274 "src/parser.mly"
                 ( e )
# 1548 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_029 =
  fun _endpos_e_ _startpos_vis_ e name t vis ->
    let _endpos = _endpos_e_ in
    let _startpos = _startpos_vis_ in
    (
# 552 "src/parser.mly"
    ( { const_vis = vis;
        const_name = name;
        const_type = t;
        const_value = e;
        const_span = make_span _startpos _endpos !current_file } )
# 1562 "src/parser.ml"
     : (Ast.const_decl))

let _menhir_action_030 =
  fun _endpos_label_ _startpos__1_ label ->
    let _endpos = _endpos_label_ in
    let _startpos = _startpos__1_ in
    (
# 394 "src/parser.mly"
                          ( ExprContinue (label, make_span _startpos _endpos !current_file) )
# 1572 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_031 =
  fun _endpos_label_ _startpos__1_ label ->
    let _endpos = _endpos_label_ in
    let _startpos = _startpos__1_ in
    (
# 395 "src/parser.mly"
                      ( ExprContinue (label, make_span _startpos _endpos !current_file) )
# 1582 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_032 =
  fun _endpos_msg_ _startpos__1_ e msg ->
    let _endpos = _endpos_msg_ in
    let _startpos = _startpos__1_ in
    (
# 136 "src/parser.mly"
                                 ( ContractPre (e, msg, make_span _startpos _endpos !current_file) )
# 1592 "src/parser.ml"
     : (Ast.contract))

let _menhir_action_033 =
  fun _endpos_msg_ _startpos__1_ e msg ->
    let _endpos = _endpos_msg_ in
    let _startpos = _startpos__1_ in
    (
# 137 "src/parser.mly"
                                  ( ContractPost (e, msg, make_span _startpos _endpos !current_file) )
# 1602 "src/parser.ml"
     : (Ast.contract))

let _menhir_action_034 =
  fun _endpos_msg_ _startpos__1_ e msg ->
    let _endpos = _endpos_msg_ in
    let _startpos = _startpos__1_ in
    (
# 138 "src/parser.mly"
                                       ( ContractInvariant (e, msg, make_span _startpos _endpos !current_file) )
# 1612 "src/parser.ml"
     : (Ast.contract))

let _menhir_action_035 =
  fun s ->
    (
# 141 "src/parser.mly"
                       ( s )
# 1620 "src/parser.ml"
     : (string))

let _menhir_action_036 =
  fun effects ->
    (
# 153 "src/parser.mly"
                                                         ( effects )
# 1628 "src/parser.ml"
     : (string list))

let _menhir_action_037 =
  fun body ->
    (
# 358 "src/parser.mly"
                    ( body )
# 1636 "src/parser.ml"
     : (Ast.block))

let _menhir_action_038 =
  fun body cond ->
    (
# 355 "src/parser.mly"
                                     ( (cond, body) )
# 1644 "src/parser.ml"
     : (Ast.expr * Ast.block))

let _menhir_action_039 =
  fun _endpos__6_ _startpos_vis_ name type_params variants vis ->
    let _endpos = _endpos__6_ in
    let _startpos = _startpos_vis_ in
    (
# 432 "src/parser.mly"
    ( { enum_vis = vis;
        enum_name = name;
        enum_type_params = Option.value ~default:[] type_params;
        enum_variants = variants;
        enum_span = make_span _startpos _endpos !current_file } )
# 1658 "src/parser.ml"
     : (Ast.enum_def))

let _menhir_action_040 =
  fun xs ->
    let pats = 
# 241 "<standard.mly>"
    ( xs )
# 1666 "src/parser.ml"
     in
    (
# 223 "src/parser.mly"
                                                      ( pats )
# 1671 "src/parser.ml"
     : (Ast.pattern list))

let _menhir_action_041 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 265 "src/parser.mly"
                                            ( ExprBinary (Eq, l, r, make_span _startpos _endpos !current_file) )
# 1681 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_042 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 266 "src/parser.mly"
                                              ( ExprBinary (Ne, l, r, make_span _startpos _endpos !current_file) )
# 1691 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_043 =
  fun e ->
    (
# 267 "src/parser.mly"
                      ( e )
# 1699 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_044 =
  fun e ->
    (
# 227 "src/parser.mly"
                      ( e )
# 1707 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_045 =
  fun e ->
    (
# 181 "src/parser.mly"
                   ( (e, true) )
# 1715 "src/parser.ml"
     : (Ast.expr * bool))

let _menhir_action_046 =
  fun e ->
    (
# 182 "src/parser.mly"
           ( (e, false) )
# 1723 "src/parser.ml"
     : (Ast.expr * bool))

let _menhir_action_047 =
  fun _endpos_t_ _startpos_vis_ name t vis ->
    let _endpos = _endpos_t_ in
    let _startpos = _startpos_vis_ in
    (
# 422 "src/parser.mly"
    ( { field_vis = vis;
        field_name = name;
        field_type = t;
        field_span = make_span _startpos _endpos !current_file } )
# 1736 "src/parser.ml"
     : (Ast.field_def))

let _menhir_action_048 =
  fun _endpos__7_ _startpos__1_ body iter p ->
    let _endpos = _endpos__7_ in
    let _startpos = _startpos__1_ in
    (
# 377 "src/parser.mly"
    ( ExprFor (p, iter, body, make_span _startpos _endpos !current_file) )
# 1746 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_049 =
  fun _endpos__15_ _startpos_vis_ body budget contracts effects name requires_list ret type_params vis where_clause xs ->
    let params = 
# 241 "<standard.mly>"
    ( xs )
# 1754 "src/parser.ml"
     in
    let _endpos = _endpos__15_ in
    let _startpos = _startpos_vis_ in
    (
# 92 "src/parser.mly"
    ( { fn_vis = vis;
        fn_name = name;
        fn_type_params = Option.value ~default:[] type_params;
        fn_params = params;
        fn_return_type = ret;
        fn_where_clause = Option.value ~default:[] where_clause;
        fn_contracts = contracts;
        fn_requires = List.flatten requires_list;
        fn_effects = Option.value ~default:[] effects;
        fn_budget = Option.value ~default:[] budget;
        fn_body = Some body;
        fn_span = make_span _startpos _endpos !current_file;
      } )
# 1773 "src/parser.ml"
     : (Ast.fn_def))

let _menhir_action_050 =
  fun _endpos__7_ _startpos__1_ body cond else_ elsifs ->
    let _endpos = _endpos__7_ in
    let _startpos = _startpos__1_ in
    (
# 352 "src/parser.mly"
    ( ExprIf (cond, body, elsifs, else_, make_span _startpos _endpos !current_file) )
# 1783 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_051 =
  fun _endpos__8_ _startpos__1_ for_type items trait_ type_params where_clause ->
    let _endpos = _endpos__8_ in
    let _startpos = _startpos__1_ in
    (
# 502 "src/parser.mly"
    ( { impl_type_params = Option.value ~default:[] type_params;
        impl_trait = trait_;
        impl_for_type = for_type;
        impl_where_clause = Option.value ~default:[] where_clause;
        impl_items = items;
        impl_span = make_span _startpos _endpos !current_file } )
# 1798 "src/parser.ml"
     : (Ast.impl_block))

let _menhir_action_052 =
  fun f ->
    (
# 516 "src/parser.mly"
                   ( ImplMethod f )
# 1806 "src/parser.ml"
     : (Ast.impl_item))

let _menhir_action_053 =
  fun _endpos_t_ _startpos__1_ name t ->
    let _endpos = _endpos_t_ in
    let _startpos = _startpos__1_ in
    (
# 517 "src/parser.mly"
                                   ( ImplType (name, t, make_span _startpos _endpos !current_file) )
# 1816 "src/parser.ml"
     : (Ast.impl_item))

let _menhir_action_054 =
  fun args name ->
    (
# 510 "src/parser.mly"
                                   ( (name, Option.value ~default:[] args) )
# 1824 "src/parser.ml"
     : (string * Ast.ty list))

let _menhir_action_055 =
  fun e ->
    (
# 188 "src/parser.mly"
              ( e )
# 1832 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_056 =
  fun f ->
    (
# 66 "src/parser.mly"
                   ( ItemFn f )
# 1840 "src/parser.ml"
     : (Ast.item))

let _menhir_action_057 =
  fun s ->
    (
# 67 "src/parser.mly"
                 ( ItemStruct s )
# 1848 "src/parser.ml"
     : (Ast.item))

let _menhir_action_058 =
  fun e ->
    (
# 68 "src/parser.mly"
               ( ItemEnum e )
# 1856 "src/parser.ml"
     : (Ast.item))

let _menhir_action_059 =
  fun t ->
    (
# 69 "src/parser.mly"
                ( ItemTrait t )
# 1864 "src/parser.ml"
     : (Ast.item))

let _menhir_action_060 =
  fun i ->
    (
# 70 "src/parser.mly"
                 ( ItemImpl i )
# 1872 "src/parser.ml"
     : (Ast.item))

let _menhir_action_061 =
  fun u ->
    (
# 71 "src/parser.mly"
               ( ItemUse u )
# 1880 "src/parser.ml"
     : (Ast.item))

let _menhir_action_062 =
  fun c ->
    (
# 72 "src/parser.mly"
                 ( ItemConst c )
# 1888 "src/parser.ml"
     : (Ast.item))

let _menhir_action_063 =
  fun t ->
    (
# 73 "src/parser.mly"
                 ( ItemTypeAlias t )
# 1896 "src/parser.ml"
     : (Ast.item))

let _menhir_action_064 =
  fun m ->
    (
# 74 "src/parser.mly"
                  ( ItemModule m )
# 1904 "src/parser.ml"
     : (Ast.item))

let _menhir_action_065 =
  fun () ->
    (
# 216 "<standard.mly>"
    ( [] )
# 1912 "src/parser.ml"
     : (Ast.contract list))

let _menhir_action_066 =
  fun x xs ->
    (
# 219 "<standard.mly>"
    ( x :: xs )
# 1920 "src/parser.ml"
     : (Ast.contract list))

let _menhir_action_067 =
  fun () ->
    (
# 216 "<standard.mly>"
    ( [] )
# 1928 "src/parser.ml"
     : ((Ast.expr * Ast.block) list))

let _menhir_action_068 =
  fun x xs ->
    (
# 219 "<standard.mly>"
    ( x :: xs )
# 1936 "src/parser.ml"
     : ((Ast.expr * Ast.block) list))

let _menhir_action_069 =
  fun () ->
    (
# 216 "<standard.mly>"
    ( [] )
# 1944 "src/parser.ml"
     : (Ast.field_def list))

let _menhir_action_070 =
  fun x xs ->
    (
# 219 "<standard.mly>"
    ( x :: xs )
# 1952 "src/parser.ml"
     : (Ast.field_def list))

let _menhir_action_071 =
  fun () ->
    (
# 216 "<standard.mly>"
    ( [] )
# 1960 "src/parser.ml"
     : (Ast.impl_item list))

let _menhir_action_072 =
  fun x xs ->
    (
# 219 "<standard.mly>"
    ( x :: xs )
# 1968 "src/parser.ml"
     : (Ast.impl_item list))

let _menhir_action_073 =
  fun () ->
    (
# 216 "<standard.mly>"
    ( [] )
# 1976 "src/parser.ml"
     : (Ast.item list))

let _menhir_action_074 =
  fun x xs ->
    (
# 219 "<standard.mly>"
    ( x :: xs )
# 1984 "src/parser.ml"
     : (Ast.item list))

let _menhir_action_075 =
  fun () ->
    (
# 216 "<standard.mly>"
    ( [] )
# 1992 "src/parser.ml"
     : (Ast.match_arm list))

let _menhir_action_076 =
  fun x xs ->
    (
# 219 "<standard.mly>"
    ( x :: xs )
# 2000 "src/parser.ml"
     : (Ast.match_arm list))

let _menhir_action_077 =
  fun () ->
    (
# 216 "<standard.mly>"
    ( [] )
# 2008 "src/parser.ml"
     : (Ast.requires_clause list list))

let _menhir_action_078 =
  fun x xs ->
    (
# 219 "<standard.mly>"
    ( x :: xs )
# 2016 "src/parser.ml"
     : (Ast.requires_clause list list))

let _menhir_action_079 =
  fun () ->
    (
# 216 "<standard.mly>"
    ( [] )
# 2024 "src/parser.ml"
     : (Ast.trait_item list))

let _menhir_action_080 =
  fun x xs ->
    (
# 219 "<standard.mly>"
    ( x :: xs )
# 2032 "src/parser.ml"
     : (Ast.trait_item list))

let _menhir_action_081 =
  fun () ->
    (
# 216 "<standard.mly>"
    ( [] )
# 2040 "src/parser.ml"
     : (Ast.variant_def list))

let _menhir_action_082 =
  fun x xs ->
    (
# 219 "<standard.mly>"
    ( x :: xs )
# 2048 "src/parser.ml"
     : (Ast.variant_def list))

let _menhir_action_083 =
  fun i ->
    (
# 402 "src/parser.mly"
              ( LitInt i )
# 2056 "src/parser.ml"
     : (Ast.literal))

let _menhir_action_084 =
  fun f ->
    (
# 403 "src/parser.mly"
                ( LitFloat f )
# 2064 "src/parser.ml"
     : (Ast.literal))

let _menhir_action_085 =
  fun s ->
    (
# 404 "src/parser.mly"
                 ( LitString s )
# 2072 "src/parser.ml"
     : (Ast.literal))

let _menhir_action_086 =
  fun c ->
    (
# 405 "src/parser.mly"
               ( LitChar c )
# 2080 "src/parser.ml"
     : (Ast.literal))

let _menhir_action_087 =
  fun () ->
    (
# 406 "src/parser.mly"
         ( LitBool true )
# 2088 "src/parser.ml"
     : (Ast.literal))

let _menhir_action_088 =
  fun () ->
    (
# 407 "src/parser.mly"
          ( LitBool false )
# 2096 "src/parser.ml"
     : (Ast.literal))

let _menhir_action_089 =
  fun _endpos__3_ _startpos__1_ body ->
    let _endpos = _endpos__3_ in
    let _startpos = _startpos__1_ in
    (
# 381 "src/parser.mly"
    ( ExprLoop (body, make_span _startpos _endpos !current_file) )
# 2106 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_090 =
  fun () ->
    (
# 145 "<standard.mly>"
    ( [] )
# 2114 "src/parser.ml"
     : (Ast.expr list))

let _menhir_action_091 =
  fun x ->
    (
# 148 "<standard.mly>"
    ( x )
# 2122 "src/parser.ml"
     : (Ast.expr list))

let _menhir_action_092 =
  fun () ->
    (
# 145 "<standard.mly>"
    ( [] )
# 2130 "src/parser.ml"
     : (Ast.param list))

let _menhir_action_093 =
  fun x ->
    (
# 148 "<standard.mly>"
    ( x )
# 2138 "src/parser.ml"
     : (Ast.param list))

let _menhir_action_094 =
  fun () ->
    (
# 145 "<standard.mly>"
    ( [] )
# 2146 "src/parser.ml"
     : (Ast.pattern list))

let _menhir_action_095 =
  fun x ->
    (
# 148 "<standard.mly>"
    ( x )
# 2154 "src/parser.ml"
     : (Ast.pattern list))

let _menhir_action_096 =
  fun () ->
    (
# 145 "<standard.mly>"
    ( [] )
# 2162 "src/parser.ml"
     : ((string * Ast.pattern) list))

let _menhir_action_097 =
  fun x ->
    (
# 148 "<standard.mly>"
    ( x )
# 2170 "src/parser.ml"
     : ((string * Ast.pattern) list))

let _menhir_action_098 =
  fun () ->
    (
# 145 "<standard.mly>"
    ( [] )
# 2178 "src/parser.ml"
     : ((string * Ast.expr) list))

let _menhir_action_099 =
  fun x ->
    (
# 148 "<standard.mly>"
    ( x )
# 2186 "src/parser.ml"
     : ((string * Ast.expr) list))

let _menhir_action_100 =
  fun () ->
    (
# 145 "<standard.mly>"
    ( [] )
# 2194 "src/parser.ml"
     : (Ast.ty list))

let _menhir_action_101 =
  fun x ->
    (
# 148 "<standard.mly>"
    ( x )
# 2202 "src/parser.ml"
     : (Ast.ty list))

let _menhir_action_102 =
  fun _endpos__6_ _startpos__1_ body guard p ->
    let _endpos = _endpos__6_ in
    let _startpos = _startpos__1_ in
    (
# 366 "src/parser.mly"
    ( { pattern = p; guard; body; arm_span = make_span _startpos _endpos !current_file } )
# 2212 "src/parser.ml"
     : (Ast.match_arm))

let _menhir_action_103 =
  fun _endpos__5_ _startpos__1_ arms e ->
    let _endpos = _endpos__5_ in
    let _startpos = _startpos__1_ in
    (
# 362 "src/parser.mly"
    ( ExprMatch (e, arms, make_span _startpos _endpos !current_file) )
# 2222 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_104 =
  fun e ->
    (
# 369 "src/parser.mly"
              ( e )
# 2230 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_105 =
  fun _endpos__5_ _startpos_vis_ items name vis ->
    let _endpos = _endpos__5_ in
    let _startpos = _startpos_vis_ in
    (
# 570 "src/parser.mly"
    ( { mod_vis = vis;
        mod_name = name;
        mod_items = Some items;
        mod_span = make_span _startpos _endpos !current_file } )
# 2243 "src/parser.ml"
     : (Ast.module_decl))

let _menhir_action_106 =
  fun _endpos_name_ _startpos_vis_ name vis ->
    let _endpos = _endpos_name_ in
    let _startpos = _startpos_vis_ in
    (
# 575 "src/parser.mly"
    ( { mod_vis = vis;
        mod_name = name;
        mod_items = None;
        mod_span = make_span _startpos _endpos !current_file } )
# 2256 "src/parser.ml"
     : (Ast.module_decl))

let _menhir_action_107 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 287 "src/parser.mly"
                                            ( ExprBinary (Mul, l, r, make_span _startpos _endpos !current_file) )
# 2266 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_108 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 288 "src/parser.mly"
                                             ( ExprBinary (Div, l, r, make_span _startpos _endpos !current_file) )
# 2276 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_109 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 289 "src/parser.mly"
                                               ( ExprBinary (Mod, l, r, make_span _startpos _endpos !current_file) )
# 2286 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_110 =
  fun e ->
    (
# 290 "src/parser.mly"
                 ( e )
# 2294 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_111 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2302 "src/parser.ml"
     : (unit option))

let _menhir_action_112 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2310 "src/parser.ml"
     : (unit option))

let _menhir_action_113 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2318 "src/parser.ml"
     : (unit option))

let _menhir_action_114 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2326 "src/parser.ml"
     : (unit option))

let _menhir_action_115 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2334 "src/parser.ml"
     : (unit option))

let _menhir_action_116 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2342 "src/parser.ml"
     : (unit option))

let _menhir_action_117 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2350 "src/parser.ml"
     : (unit option))

let _menhir_action_118 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2358 "src/parser.ml"
     : (unit option))

let _menhir_action_119 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2366 "src/parser.ml"
     : (string option))

let _menhir_action_120 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2374 "src/parser.ml"
     : (string option))

let _menhir_action_121 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2382 "src/parser.ml"
     : (unit option))

let _menhir_action_122 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2390 "src/parser.ml"
     : (unit option))

let _menhir_action_123 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2398 "src/parser.ml"
     : (unit option))

let _menhir_action_124 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2406 "src/parser.ml"
     : (unit option))

let _menhir_action_125 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2414 "src/parser.ml"
     : (unit option))

let _menhir_action_126 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2422 "src/parser.ml"
     : (unit option))

let _menhir_action_127 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2430 "src/parser.ml"
     : ((string * int64 * string) list option))

let _menhir_action_128 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2438 "src/parser.ml"
     : ((string * int64 * string) list option))

let _menhir_action_129 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2446 "src/parser.ml"
     : (string option))

let _menhir_action_130 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2454 "src/parser.ml"
     : (string option))

let _menhir_action_131 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2462 "src/parser.ml"
     : (string list option))

let _menhir_action_132 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2470 "src/parser.ml"
     : (string list option))

let _menhir_action_133 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2478 "src/parser.ml"
     : (Ast.block option))

let _menhir_action_134 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2486 "src/parser.ml"
     : (Ast.block option))

let _menhir_action_135 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2494 "src/parser.ml"
     : (Ast.pattern list option))

let _menhir_action_136 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2502 "src/parser.ml"
     : (Ast.pattern list option))

let _menhir_action_137 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2510 "src/parser.ml"
     : (Ast.expr option))

let _menhir_action_138 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2518 "src/parser.ml"
     : (Ast.expr option))

let _menhir_action_139 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2526 "src/parser.ml"
     : ((string * Ast.ty list) option))

let _menhir_action_140 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2534 "src/parser.ml"
     : ((string * Ast.ty list) option))

let _menhir_action_141 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2542 "src/parser.ml"
     : (Ast.expr option))

let _menhir_action_142 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2550 "src/parser.ml"
     : (Ast.expr option))

let _menhir_action_143 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2558 "src/parser.ml"
     : (Ast.expr option))

let _menhir_action_144 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2566 "src/parser.ml"
     : (Ast.expr option))

let _menhir_action_145 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2574 "src/parser.ml"
     : (Ast.ty option))

let _menhir_action_146 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2582 "src/parser.ml"
     : (Ast.ty option))

let _menhir_action_147 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2590 "src/parser.ml"
     : (Ast.block option))

let _menhir_action_148 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2598 "src/parser.ml"
     : (Ast.block option))

let _menhir_action_149 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2606 "src/parser.ml"
     : (string list option))

let _menhir_action_150 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2614 "src/parser.ml"
     : (string list option))

let _menhir_action_151 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2622 "src/parser.ml"
     : (Ast.ty option))

let _menhir_action_152 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2630 "src/parser.ml"
     : (Ast.ty option))

let _menhir_action_153 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2638 "src/parser.ml"
     : (Ast.ty list option))

let _menhir_action_154 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2646 "src/parser.ml"
     : (Ast.ty list option))

let _menhir_action_155 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2654 "src/parser.ml"
     : (string list option))

let _menhir_action_156 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2662 "src/parser.ml"
     : (string list option))

let _menhir_action_157 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2670 "src/parser.ml"
     : (Ast.type_param list option))

let _menhir_action_158 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2678 "src/parser.ml"
     : (Ast.type_param list option))

let _menhir_action_159 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2686 "src/parser.ml"
     : (Ast.variant_field list option))

let _menhir_action_160 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2694 "src/parser.ml"
     : (Ast.variant_field list option))

let _menhir_action_161 =
  fun () ->
    (
# 111 "<standard.mly>"
    ( None )
# 2702 "src/parser.ml"
     : (Ast.where_pred list option))

let _menhir_action_162 =
  fun x ->
    (
# 114 "<standard.mly>"
    ( Some x )
# 2710 "src/parser.ml"
     : (Ast.where_pred list option))

let _menhir_action_163 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 245 "src/parser.mly"
                                   ( ExprBinary (Or, l, r, make_span _startpos _endpos !current_file) )
# 2720 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_164 =
  fun e ->
    (
# 246 "src/parser.mly"
               ( e )
# 2728 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_165 =
  fun _endpos_t_ _startpos_m_ m name t ->
    let _endpos = _endpos_t_ in
    let _startpos = _startpos_m_ in
    (
# 130 "src/parser.mly"
    ( { param_mut = (if Option.is_some m then Mutable else Immutable);
        param_name = name;
        param_type = t;
        param_span = make_span _startpos _endpos !current_file } )
# 2741 "src/parser.ml"
     : (Ast.param))

let _menhir_action_166 =
  fun _endpos_rest_ _startpos_first_ first rest ->
    let _endpos = _endpos_rest_ in
    let _startpos = _startpos_first_ in
    (
# 344 "src/parser.mly"
    ( ExprPath (first :: rest, make_span _startpos _endpos !current_file) )
# 2751 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_167 =
  fun _endpos_name_ _startpos_m_ m name ->
    let _endpos = _endpos_name_ in
    let _startpos = _startpos_m_ in
    (
# 207 "src/parser.mly"
    ( PatIdent ((if Option.is_some m then Mutable else Immutable), name, 
                make_span _startpos _endpos !current_file) )
# 2762 "src/parser.ml"
     : (Ast.pattern))

let _menhir_action_168 =
  fun _endpos__3_ _startpos__1_ xs ->
    let pats = 
# 241 "<standard.mly>"
    ( xs )
# 2770 "src/parser.ml"
     in
    let _endpos = _endpos__3_ in
    let _startpos = _startpos__1_ in
    (
# 210 "src/parser.mly"
    ( PatTuple (pats, make_span _startpos _endpos !current_file) )
# 2777 "src/parser.ml"
     : (Ast.pattern))

let _menhir_action_169 =
  fun _endpos__4_ _startpos_name_ name xs ->
    let fields = 
# 241 "<standard.mly>"
    ( xs )
# 2785 "src/parser.ml"
     in
    let _endpos = _endpos__4_ in
    let _startpos = _startpos_name_ in
    (
# 212 "src/parser.mly"
    ( PatStruct (name, fields, make_span _startpos _endpos !current_file) )
# 2792 "src/parser.ml"
     : (Ast.pattern))

let _menhir_action_170 =
  fun _endpos_args_ _startpos_ty_ args ty variant ->
    let _endpos = _endpos_args_ in
    let _startpos = _startpos_ty_ in
    (
# 214 "src/parser.mly"
    ( PatEnum (ty, variant, Option.value ~default:[] args, 
               make_span _startpos _endpos !current_file) )
# 2803 "src/parser.ml"
     : (Ast.pattern))

let _menhir_action_171 =
  fun _endpos_l_ _startpos_l_ l ->
    let _endpos = _endpos_l_ in
    let _startpos = _startpos_l_ in
    (
# 216 "src/parser.mly"
              ( PatLiteral (l, make_span _startpos _endpos !current_file) )
# 2813 "src/parser.ml"
     : (Ast.pattern))

let _menhir_action_172 =
  fun name p ->
    (
# 219 "src/parser.mly"
                               ( (name, p) )
# 2821 "src/parser.ml"
     : (string * Ast.pattern))

let _menhir_action_173 =
  fun _endpos_name_ _startpos_name_ name ->
    let _endpos = _endpos_name_ in
    let _startpos = _startpos_name_ in
    (
# 220 "src/parser.mly"
               ( (name, PatIdent (Immutable, name, make_span _startpos _endpos !current_file)) )
# 2831 "src/parser.ml"
     : (string * Ast.pattern))

let _menhir_action_174 =
  fun _endpos__4_ _startpos_e_ e xs ->
    let args = 
# 241 "<standard.mly>"
    ( xs )
# 2839 "src/parser.ml"
     in
    let _endpos = _endpos__4_ in
    let _startpos = _startpos_e_ in
    (
# 303 "src/parser.mly"
    ( ExprCall (e, args, make_span _startpos _endpos !current_file) )
# 2846 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_175 =
  fun _endpos__6_ _startpos_e_ e name xs ->
    let args = 
# 241 "<standard.mly>"
    ( xs )
# 2854 "src/parser.ml"
     in
    let _endpos = _endpos__6_ in
    let _startpos = _startpos_e_ in
    (
# 305 "src/parser.mly"
    ( ExprMethodCall (e, name, args, make_span _startpos _endpos !current_file) )
# 2861 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_176 =
  fun _endpos_name_ _startpos_e_ e name ->
    let _endpos = _endpos_name_ in
    let _startpos = _startpos_e_ in
    (
# 307 "src/parser.mly"
    ( ExprField (e, name, make_span _startpos _endpos !current_file) )
# 2871 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_177 =
  fun _endpos_idx_ _startpos_e_ e idx ->
    let _endpos = _endpos_idx_ in
    let _startpos = _startpos_e_ in
    (
# 309 "src/parser.mly"
    ( ExprTupleIndex (e, Int64.to_int idx, make_span _startpos _endpos !current_file) )
# 2881 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_178 =
  fun _endpos__4_ _startpos_e_ e idx ->
    let _endpos = _endpos__4_ in
    let _startpos = _startpos_e_ in
    (
# 311 "src/parser.mly"
    ( ExprIndex (e, idx, make_span _startpos _endpos !current_file) )
# 2891 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_179 =
  fun _endpos__2_ _startpos_e_ e ->
    let _endpos = _endpos__2_ in
    let _startpos = _startpos_e_ in
    (
# 313 "src/parser.mly"
    ( ExprTry (e, make_span _startpos _endpos !current_file) )
# 2901 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_180 =
  fun _endpos_t_ _startpos_e_ e t ->
    let _endpos = _endpos_t_ in
    let _startpos = _startpos_e_ in
    (
# 315 "src/parser.mly"
    ( ExprCast (e, t, make_span _startpos _endpos !current_file) )
# 2911 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_181 =
  fun e ->
    (
# 316 "src/parser.mly"
                   ( e )
# 2919 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_182 =
  fun _endpos_l_ _startpos_l_ l ->
    let _endpos = _endpos_l_ in
    let _startpos = _startpos_l_ in
    (
# 319 "src/parser.mly"
              ( ExprLiteral (l, make_span _startpos _endpos !current_file) )
# 2929 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_183 =
  fun _endpos_name_ _startpos_name_ name ->
    let _endpos = _endpos_name_ in
    let _startpos = _startpos_name_ in
    (
# 320 "src/parser.mly"
               ( ExprIdent (name, make_span _startpos _endpos !current_file) )
# 2939 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_184 =
  fun _endpos__1_ _startpos__1_ ->
    let _endpos = _endpos__1_ in
    let _startpos = _startpos__1_ in
    (
# 321 "src/parser.mly"
               ( ExprIdent ("self", make_span _startpos _endpos !current_file) )
# 2949 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_185 =
  fun path ->
    (
# 322 "src/parser.mly"
                   ( path )
# 2957 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_186 =
  fun _endpos__3_ _startpos__1_ xs ->
    let exprs = 
# 241 "<standard.mly>"
    ( xs )
# 2965 "src/parser.ml"
     in
    let _endpos = _endpos__3_ in
    let _startpos = _startpos__1_ in
    (
# 324 "src/parser.mly"
    ( match exprs with
      | [e] -> e
      | _ -> ExprTuple (exprs, make_span _startpos _endpos !current_file) )
# 2974 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_187 =
  fun _endpos__3_ _startpos__1_ xs ->
    let exprs = 
# 241 "<standard.mly>"
    ( xs )
# 2982 "src/parser.ml"
     in
    let _endpos = _endpos__3_ in
    let _startpos = _startpos__1_ in
    (
# 328 "src/parser.mly"
    ( ExprArray (exprs, make_span _startpos _endpos !current_file) )
# 2989 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_188 =
  fun _endpos__4_ _startpos_name_ name xs ->
    let fields = 
# 241 "<standard.mly>"
    ( xs )
# 2997 "src/parser.ml"
     in
    let _endpos = _endpos__4_ in
    let _startpos = _startpos_name_ in
    (
# 330 "src/parser.mly"
    ( ExprStruct (name, fields, make_span _startpos _endpos !current_file) )
# 3004 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_189 =
  fun _1 ->
    (
# 331 "src/parser.mly"
            ( _1 )
# 3012 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_190 =
  fun _1 ->
    (
# 332 "src/parser.mly"
               ( _1 )
# 3020 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_191 =
  fun _1 ->
    (
# 333 "src/parser.mly"
               ( _1 )
# 3028 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_192 =
  fun _1 ->
    (
# 334 "src/parser.mly"
             ( _1 )
# 3036 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_193 =
  fun _1 ->
    (
# 335 "src/parser.mly"
              ( _1 )
# 3044 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_194 =
  fun _1 ->
    (
# 336 "src/parser.mly"
               ( _1 )
# 3052 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_195 =
  fun _1 ->
    (
# 337 "src/parser.mly"
                ( _1 )
# 3060 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_196 =
  fun _1 ->
    (
# 338 "src/parser.mly"
               ( _1 )
# 3068 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_197 =
  fun _1 ->
    (
# 339 "src/parser.mly"
                  ( _1 )
# 3076 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_198 =
  fun _1 ->
    (
# 340 "src/parser.mly"
                ( _1 )
# 3084 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_199 =
  fun items ->
    (
# 63 "src/parser.mly"
                    ( { items; file = !current_file } )
# 3092 "src/parser.ml"
     : (Ast.program))

let _menhir_action_200 =
  fun items ->
    (
# 144 "src/parser.mly"
                                                                 ( items )
# 3100 "src/parser.ml"
     : (Ast.requires_clause list))

let _menhir_action_201 =
  fun _endpos_cap_ _startpos_neg_ cap neg ->
    let _endpos = _endpos_cap_ in
    let _startpos = _startpos_neg_ in
    (
# 148 "src/parser.mly"
    ( { req_negated = Option.is_some neg; 
        req_cap = cap; 
        req_span = make_span _startpos _endpos !current_file } )
# 3112 "src/parser.ml"
     : (Ast.requires_clause))

let _menhir_action_202 =
  fun _endpos_e_ _startpos__1_ e ->
    let _endpos = _endpos_e_ in
    let _startpos = _startpos__1_ in
    (
# 388 "src/parser.mly"
                   ( ExprReturn (e, make_span _startpos _endpos !current_file) )
# 3122 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_203 =
  fun t ->
    (
# 107 "src/parser.mly"
                      ( t )
# 3130 "src/parser.ml"
     : (Ast.ty))

let _menhir_action_204 =
  fun () ->
    (
# 167 "src/parser.mly"
                ( ([], None) )
# 3138 "src/parser.ml"
     : (Ast.stmt list * Ast.expr option))

let _menhir_action_205 =
  fun _endpos__7_ _startpos_prev_ init m p prev t ->
    let _endpos = _endpos__7_ in
    let _startpos = _startpos_prev_ in
    (
# 169 "src/parser.mly"
    ( let s = StmtLet ((if Option.is_some m then Mutable else Immutable), p, t, init, 
                       make_span _startpos _endpos !current_file) in
      ((s :: fst prev), snd prev) )
# 3150 "src/parser.ml"
     : (Ast.stmt list * Ast.expr option))

let _menhir_action_206 =
  fun _endpos_e_ _startpos_prev_ e prev ->
    let _endpos = _endpos_e_ in
    let _startpos = _startpos_prev_ in
    (
# 173 "src/parser.mly"
    ( let (ex, has_semi) = e in
      if has_semi then
        let s = StmtExpr (ex, make_span _startpos _endpos !current_file) in
        ((s :: fst prev), snd prev)
      else
        (fst prev, Some ex) )
# 3165 "src/parser.ml"
     : (Ast.stmt list * Ast.expr option))

let _menhir_action_207 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3173 "src/parser.ml"
     : (string list))

let _menhir_action_208 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3181 "src/parser.ml"
     : (string list))

let _menhir_action_209 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3189 "src/parser.ml"
     : (string list))

let _menhir_action_210 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3197 "src/parser.ml"
     : (string list))

let _menhir_action_211 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3205 "src/parser.ml"
     : ((string * int64 * string) list))

let _menhir_action_212 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3213 "src/parser.ml"
     : ((string * int64 * string) list))

let _menhir_action_213 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3221 "src/parser.ml"
     : (Ast.expr list))

let _menhir_action_214 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3229 "src/parser.ml"
     : (Ast.expr list))

let _menhir_action_215 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3237 "src/parser.ml"
     : (Ast.param list))

let _menhir_action_216 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3245 "src/parser.ml"
     : (Ast.param list))

let _menhir_action_217 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3253 "src/parser.ml"
     : (Ast.pattern list))

let _menhir_action_218 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3261 "src/parser.ml"
     : (Ast.pattern list))

let _menhir_action_219 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3269 "src/parser.ml"
     : ((string * Ast.pattern) list))

let _menhir_action_220 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3277 "src/parser.ml"
     : ((string * Ast.pattern) list))

let _menhir_action_221 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3285 "src/parser.ml"
     : (Ast.requires_clause list))

let _menhir_action_222 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3293 "src/parser.ml"
     : (Ast.requires_clause list))

let _menhir_action_223 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3301 "src/parser.ml"
     : ((string * Ast.expr) list))

let _menhir_action_224 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3309 "src/parser.ml"
     : ((string * Ast.expr) list))

let _menhir_action_225 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3317 "src/parser.ml"
     : (Ast.ty list))

let _menhir_action_226 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3325 "src/parser.ml"
     : (Ast.ty list))

let _menhir_action_227 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3333 "src/parser.ml"
     : (Ast.type_param list))

let _menhir_action_228 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3341 "src/parser.ml"
     : (Ast.type_param list))

let _menhir_action_229 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3349 "src/parser.ml"
     : ((string * string option) list))

let _menhir_action_230 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3357 "src/parser.ml"
     : ((string * string option) list))

let _menhir_action_231 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3365 "src/parser.ml"
     : (Ast.variant_field list))

let _menhir_action_232 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3373 "src/parser.ml"
     : (Ast.variant_field list))

let _menhir_action_233 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3381 "src/parser.ml"
     : (Ast.where_pred list))

let _menhir_action_234 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3389 "src/parser.ml"
     : (Ast.where_pred list))

let _menhir_action_235 =
  fun x ->
    (
# 250 "<standard.mly>"
    ( [ x ] )
# 3397 "src/parser.ml"
     : (string list))

let _menhir_action_236 =
  fun x xs ->
    (
# 253 "<standard.mly>"
    ( x :: xs )
# 3405 "src/parser.ml"
     : (string list))

let _menhir_action_237 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 277 "src/parser.mly"
                                     ( ExprBinary (Shl, l, r, make_span _startpos _endpos !current_file) )
# 3415 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_238 =
  fun _endpos_r_ _startpos_l_ l r ->
    let _endpos = _endpos_r_ in
    let _startpos = _startpos_l_ in
    (
# 278 "src/parser.mly"
                                     ( ExprBinary (Shr, l, r, make_span _startpos _endpos !current_file) )
# 3425 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_239 =
  fun e ->
    (
# 279 "src/parser.mly"
                    ( e )
# 3433 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_240 =
  fun _endpos__6_ _startpos_vis_ fields name type_params vis ->
    let _endpos = _endpos__6_ in
    let _startpos = _startpos_vis_ in
    (
# 414 "src/parser.mly"
    ( { struct_vis = vis;
        struct_name = name;
        struct_type_params = Option.value ~default:[] type_params;
        struct_fields = fields;
        struct_span = make_span _startpos _endpos !current_file } )
# 3447 "src/parser.ml"
     : (Ast.struct_def))

let _menhir_action_241 =
  fun e name ->
    (
# 347 "src/parser.mly"
                            ( (name, e) )
# 3455 "src/parser.ml"
     : (string * Ast.expr))

let _menhir_action_242 =
  fun _endpos_name_ _startpos_name_ name ->
    let _endpos = _endpos_name_ in
    let _startpos = _startpos_name_ in
    (
# 348 "src/parser.mly"
               ( (name, ExprIdent (name, make_span _startpos _endpos !current_file)) )
# 3465 "src/parser.ml"
     : (string * Ast.expr))

let _menhir_action_243 =
  fun _endpos__7_ _startpos_vis_ items name super type_params vis ->
    let _endpos = _endpos__7_ in
    let _startpos = _startpos_vis_ in
    (
# 459 "src/parser.mly"
    ( { trait_vis = vis;
        trait_name = name;
        trait_type_params = Option.value ~default:[] type_params;
        trait_super = Option.value ~default:[] super;
        trait_items = items;
        trait_span = make_span _startpos _endpos !current_file } )
# 3480 "src/parser.ml"
     : (Ast.trait_def))

let _menhir_action_244 =
  fun f ->
    (
# 470 "src/parser.mly"
                   ( TraitMethod f )
# 3488 "src/parser.ml"
     : (Ast.trait_item))

let _menhir_action_245 =
  fun _endpos_bounds_ _startpos__1_ bounds name ->
    let _endpos = _endpos_bounds_ in
    let _startpos = _startpos__1_ in
    (
# 472 "src/parser.mly"
    ( TraitType (name, Option.value ~default:[] bounds, make_span _startpos _endpos !current_file) )
# 3498 "src/parser.ml"
     : (Ast.trait_item))

let _menhir_action_246 =
  fun _endpos__9_ _startpos__1_ body name ret type_params xs ->
    let params = 
# 241 "<standard.mly>"
    ( xs )
# 3506 "src/parser.ml"
     in
    let _endpos = _endpos__9_ in
    let _startpos = _startpos__1_ in
    (
# 480 "src/parser.mly"
    ( { fn_vis = Public;
        fn_name = name;
        fn_type_params = Option.value ~default:[] type_params;
        fn_params = params;
        fn_return_type = ret;
        fn_where_clause = [];
        fn_contracts = [];
        fn_requires = [];
        fn_effects = [];
        fn_budget = [];
        fn_body = body;
        fn_span = make_span _startpos _endpos !current_file } )
# 3524 "src/parser.ml"
     : (Ast.fn_def))

let _menhir_action_247 =
  fun _1 ->
    (
# 494 "src/parser.mly"
              ( _1 )
# 3532 "src/parser.ml"
     : (Ast.block))

let _menhir_action_248 =
  fun traits ->
    (
# 467 "src/parser.mly"
                                                      ( traits )
# 3540 "src/parser.ml"
     : (string list))

let _menhir_action_249 =
  fun _endpos_t_ _startpos_vis_ name t type_params vis ->
    let _endpos = _endpos_t_ in
    let _startpos = _startpos_vis_ in
    (
# 561 "src/parser.mly"
    ( { alias_vis = vis;
        alias_name = name;
        alias_type_params = Option.value ~default:[] type_params;
        alias_type = t;
        alias_span = make_span _startpos _endpos !current_file } )
# 3554 "src/parser.ml"
     : (Ast.type_alias))

let _menhir_action_250 =
  fun t ->
    (
# 185 "src/parser.mly"
                      ( t )
# 3562 "src/parser.ml"
     : (Ast.ty))

let _menhir_action_251 =
  fun args ->
    (
# 513 "src/parser.mly"
                                                                     ( args )
# 3570 "src/parser.ml"
     : (Ast.ty list))

let _menhir_action_252 =
  fun bounds ->
    (
# 119 "src/parser.mly"
                                                      ( bounds )
# 3578 "src/parser.ml"
     : (string list))

let _menhir_action_253 =
  fun name ->
    (
# 192 "src/parser.mly"
               ( TyName (name, []) )
# 3586 "src/parser.ml"
     : (Ast.ty))

let _menhir_action_254 =
  fun args name ->
    (
# 194 "src/parser.mly"
    ( TyName (name, args) )
# 3594 "src/parser.ml"
     : (Ast.ty))

let _menhir_action_255 =
  fun ret xs ->
    let params = 
# 241 "<standard.mly>"
    ( xs )
# 3602 "src/parser.ml"
     in
    (
# 196 "src/parser.mly"
    ( TyFn (params, ret) )
# 3607 "src/parser.ml"
     : (Ast.ty))

let _menhir_action_256 =
  fun xs ->
    let types = 
# 241 "<standard.mly>"
    ( xs )
# 3615 "src/parser.ml"
     in
    (
# 197 "src/parser.mly"
                                                         ( TyTuple types )
# 3620 "src/parser.ml"
     : (Ast.ty))

let _menhir_action_257 =
  fun t ->
    (
# 198 "src/parser.mly"
                    ( TyRef (Immutable, t) )
# 3628 "src/parser.ml"
     : (Ast.ty))

let _menhir_action_258 =
  fun t ->
    (
# 199 "src/parser.mly"
                        ( TyRef (Mutable, t) )
# 3636 "src/parser.ml"
     : (Ast.ty))

let _menhir_action_259 =
  fun t ->
    (
# 200 "src/parser.mly"
                         ( TyOption t )
# 3644 "src/parser.ml"
     : (Ast.ty))

let _menhir_action_260 =
  fun () ->
    (
# 201 "src/parser.mly"
               ( TySelf )
# 3652 "src/parser.ml"
     : (Ast.ty))

let _menhir_action_261 =
  fun () ->
    (
# 202 "src/parser.mly"
         ( TyNever )
# 3660 "src/parser.ml"
     : (Ast.ty))

let _menhir_action_262 =
  fun _endpos_bounds_ _startpos_name_ bounds name ->
    let _endpos = _endpos_bounds_ in
    let _startpos = _startpos_name_ in
    (
# 114 "src/parser.mly"
    ( { tp_name = name; 
        tp_bounds = Option.value ~default:[] bounds;
        tp_span = make_span _startpos _endpos !current_file } )
# 3672 "src/parser.ml"
     : (Ast.type_param))

let _menhir_action_263 =
  fun params ->
    (
# 110 "src/parser.mly"
                                                                        ( params )
# 3680 "src/parser.ml"
     : (Ast.type_param list))

let _menhir_action_264 =
  fun _endpos_e_ _startpos__1_ e ->
    let _endpos = _endpos_e_ in
    let _startpos = _startpos__1_ in
    (
# 293 "src/parser.mly"
                       ( ExprUnary (Neg, e, make_span _startpos _endpos !current_file) )
# 3690 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_265 =
  fun _endpos_e_ _startpos__1_ e ->
    let _endpos = _endpos_e_ in
    let _startpos = _startpos__1_ in
    (
# 294 "src/parser.mly"
                      ( ExprUnary (Not, e, make_span _startpos _endpos !current_file) )
# 3700 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_266 =
  fun _endpos_e_ _startpos__1_ e ->
    let _endpos = _endpos_e_ in
    let _startpos = _startpos__1_ in
    (
# 295 "src/parser.mly"
                       ( ExprUnary (BitNot, e, make_span _startpos _endpos !current_file) )
# 3710 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_267 =
  fun _endpos_e_ _startpos__1_ e ->
    let _endpos = _endpos_e_ in
    let _startpos = _startpos__1_ in
    (
# 296 "src/parser.mly"
                     ( ExprUnary (Ref, e, make_span _startpos _endpos !current_file) )
# 3720 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_268 =
  fun _endpos_e_ _startpos__1_ e ->
    let _endpos = _endpos_e_ in
    let _startpos = _startpos__1_ in
    (
# 297 "src/parser.mly"
                         ( ExprUnary (RefMut, e, make_span _startpos _endpos !current_file) )
# 3730 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_269 =
  fun _endpos_e_ _startpos__1_ e ->
    let _endpos = _endpos_e_ in
    let _startpos = _startpos__1_ in
    (
# 298 "src/parser.mly"
                      ( ExprUnary (Deref, e, make_span _startpos _endpos !current_file) )
# 3740 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_270 =
  fun e ->
    (
# 299 "src/parser.mly"
                   ( e )
# 3748 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_271 =
  fun _endpos__3_ _startpos__1_ body ->
    let _endpos = _endpos__3_ in
    let _startpos = _startpos__1_ in
    (
# 399 "src/parser.mly"
    ( ExprUnsafe (body, make_span _startpos _endpos !current_file) )
# 3758 "src/parser.ml"
     : (Ast.expr))

let _menhir_action_272 =
  fun _endpos_rest_ _startpos_vis_ first rest vis ->
    let _endpos = _endpos_rest_ in
    let _startpos = _startpos_vis_ in
    (
# 522 "src/parser.mly"
    ( let (path, alias, glob, items) = rest first in
      { use_vis = vis;
        use_path = path;
        use_alias = alias;
        use_glob = glob;
        use_items = items;
        use_span = make_span _startpos _endpos !current_file } )
# 3774 "src/parser.ml"
     : (Ast.use_decl))

let _menhir_action_273 =
  fun alias name ->
    (
# 546 "src/parser.mly"
                              ( (name, Some alias) )
# 3782 "src/parser.ml"
     : (string * string option))

let _menhir_action_274 =
  fun name ->
    (
# 547 "src/parser.mly"
               ( (name, None) )
# 3790 "src/parser.ml"
     : (string * string option))

let _menhir_action_275 =
  fun items ->
    (
# 543 "src/parser.mly"
                                                   ( items )
# 3798 "src/parser.ml"
     : ((string * string option) list))

let _menhir_action_276 =
  fun alias ->
    (
# 532 "src/parser.mly"
    ( fun first -> ([first], Some alias, false, []) )
# 3806 "src/parser.ml"
     : (string ->
  string list * string option * bool * (string * string option) list))

let _menhir_action_277 =
  fun () ->
    (
# 534 "src/parser.mly"
    ( fun first -> ([first], None, true, []) )
# 3815 "src/parser.ml"
     : (string ->
  string list * string option * bool * (string * string option) list))

let _menhir_action_278 =
  fun items ->
    (
# 536 "src/parser.mly"
    ( fun first -> ([first], None, false, items) )
# 3824 "src/parser.ml"
     : (string ->
  string list * string option * bool * (string * string option) list))

let _menhir_action_279 =
  fun next rest ->
    (
# 538 "src/parser.mly"
    ( fun first -> let (path, alias, glob, items) = rest next in (first :: path, alias, glob, items) )
# 3833 "src/parser.ml"
     : (string ->
  string list * string option * bool * (string * string option) list))

let _menhir_action_280 =
  fun () ->
    (
# 540 "src/parser.mly"
    ( fun first -> ([first], None, false, []) )
# 3842 "src/parser.ml"
     : (string ->
  string list * string option * bool * (string * string option) list))

let _menhir_action_281 =
  fun _endpos_fields_ _startpos_name_ fields name ->
    let _endpos = _endpos_fields_ in
    let _startpos = _startpos_name_ in
    (
# 440 "src/parser.mly"
    ( { variant_name = name;
        variant_fields = Option.value ~default:[] fields;
        variant_span = make_span _startpos _endpos !current_file } )
# 3855 "src/parser.ml"
     : (Ast.variant_def))

let _menhir_action_282 =
  fun _endpos_t_ _startpos_name_ name t ->
    let _endpos = _endpos_t_ in
    let _startpos = _startpos_name_ in
    (
# 449 "src/parser.mly"
    ( { vf_name = Some name; vf_type = t; vf_span = make_span _startpos _endpos !current_file } )
# 3865 "src/parser.ml"
     : (Ast.variant_field))

let _menhir_action_283 =
  fun _endpos_t_ _startpos_t_ t ->
    let _endpos = _endpos_t_ in
    let _startpos = _startpos_t_ in
    (
# 451 "src/parser.mly"
    ( { vf_name = None; vf_type = t; vf_span = make_span _startpos _endpos !current_file } )
# 3875 "src/parser.ml"
     : (Ast.variant_field))

let _menhir_action_284 =
  fun fields ->
    (
# 445 "src/parser.mly"
                                                                       ( fields )
# 3883 "src/parser.ml"
     : (Ast.variant_field list))

let _menhir_action_285 =
  fun () ->
    (
# 77 "src/parser.mly"
        ( Public )
# 3891 "src/parser.ml"
     : (Ast.visibility))

let _menhir_action_286 =
  fun () ->
    (
# 78 "src/parser.mly"
    ( Private )
# 3899 "src/parser.ml"
     : (Ast.visibility))

let _menhir_action_287 =
  fun preds ->
    (
# 122 "src/parser.mly"
                                                           ( preds )
# 3907 "src/parser.ml"
     : (Ast.where_pred list))

let _menhir_action_288 =
  fun _endpos_bounds_ _startpos_t_ bounds t ->
    let _endpos = _endpos_bounds_ in
    let _startpos = _startpos_t_ in
    (
# 126 "src/parser.mly"
    ( { wp_type = t; wp_bounds = bounds; wp_span = make_span _startpos _endpos !current_file } )
# 3917 "src/parser.ml"
     : (Ast.where_pred))

let _menhir_action_289 =
  fun _endpos__5_ _startpos__1_ body cond ->
    let _endpos = _endpos__5_ in
    let _startpos = _startpos__1_ in
    (
# 373 "src/parser.mly"
    ( ExprWhile (cond, body, make_span _startpos _endpos !current_file) )
# 3927 "src/parser.ml"
     : (Ast.expr))

let _menhir_print_token : token -> string =
  fun _tok ->
    match _tok with
    | YIELD ->
        "YIELD"
    | WITH ->
        "WITH"
    | WHILE ->
        "WHILE"
    | WHERE ->
        "WHERE"
    | WHEN ->
        "WHEN"
    | USE ->
        "USE"
    | UNSAFE ->
        "UNSAFE"
    | TYPE ->
        "TYPE"
    | TRY ->
        "TRY"
    | TRUE ->
        "TRUE"
    | TRAIT ->
        "TRAIT"
    | TILDE ->
        "TILDE"
    | THEN ->
        "THEN"
    | SUPER ->
        "SUPER"
    | STRUCT ->
        "STRUCT"
    | STRING_LIT _ ->
        "STRING_LIT"
    | STAR_EQ ->
        "STAR_EQ"
    | STAR ->
        "STAR"
    | SLASH_EQ ->
        "SLASH_EQ"
    | SLASH ->
        "SLASH"
    | SHR ->
        "SHR"
    | SHL ->
        "SHL"
    | SEMICOL ->
        "SEMICOL"
    | SELF_UPPER ->
        "SELF_UPPER"
    | SELF_LOWER ->
        "SELF_LOWER"
    | RPAREN ->
        "RPAREN"
    | RETURN ->
        "RETURN"
    | REQUIRES ->
        "REQUIRES"
    | RBRACKET ->
        "RBRACKET"
    | RBRACE ->
        "RBRACE"
    | RATIONALE ->
        "RATIONALE"
    | QUESTION ->
        "QUESTION"
    | PURE ->
        "PURE"
    | PUB ->
        "PUB"
    | PRE ->
        "PRE"
    | POST ->
        "POST"
    | PLUS_EQ ->
        "PLUS_EQ"
    | PLUS ->
        "PLUS"
    | PIPE_PIPE ->
        "PIPE_PIPE"
    | PIPE ->
        "PIPE"
    | PERCENT_EQ ->
        "PERCENT_EQ"
    | PERCENT ->
        "PERCENT"
    | NONE ->
        "NONE"
    | NIL ->
        "NIL"
    | NEXT ->
        "NEXT"
    | MUT ->
        "MUT"
    | MODULE ->
        "MODULE"
    | MINUS_EQ ->
        "MINUS_EQ"
    | MINUS ->
        "MINUS"
    | MATCH ->
        "MATCH"
    | MACRO ->
        "MACRO"
    | LT_EQ ->
        "LT_EQ"
    | LT ->
        "LT"
    | LPAREN ->
        "LPAREN"
    | LOOP ->
        "LOOP"
    | LET ->
        "LET"
    | LBRACKET ->
        "LBRACKET"
    | LBRACE ->
        "LBRACE"
    | INVARIANT ->
        "INVARIANT"
    | INT_LIT _ ->
        "INT_LIT"
    | INLINE ->
        "INLINE"
    | IN ->
        "IN"
    | IMPLIES ->
        "IMPLIES"
    | IMPL ->
        "IMPL"
    | IF ->
        "IF"
    | IDENT _ ->
        "IDENT"
    | HANDLE ->
        "HANDLE"
    | GUARD ->
        "GUARD"
    | GT_EQ ->
        "GT_EQ"
    | GT ->
        "GT"
    | FOR ->
        "FOR"
    | FN ->
        "FN"
    | FLOAT_LIT _ ->
        "FLOAT_LIT"
    | FINALLY ->
        "FINALLY"
    | FAT_ARROW ->
        "FAT_ARROW"
    | FALSE ->
        "FALSE"
    | EXTERN ->
        "EXTERN"
    | EQ_EQ ->
        "EQ_EQ"
    | EQ ->
        "EQ"
    | EOF ->
        "EOF"
    | ENUM ->
        "ENUM"
    | END ->
        "END"
    | ELSIF ->
        "ELSIF"
    | ELSE ->
        "ELSE"
    | EFFECT ->
        "EFFECT"
    | DOT_DOT_EQ ->
        "DOT_DOT_EQ"
    | DOT_DOT ->
        "DOT_DOT"
    | DOT ->
        "DOT"
    | DO ->
        "DO"
    | DEF ->
        "DEF"
    | CRATE ->
        "CRATE"
    | CONTINUE ->
        "CONTINUE"
    | CONST ->
        "CONST"
    | COMPTIME ->
        "COMPTIME"
    | COMMA ->
        "COMMA"
    | COLON_COLON ->
        "COLON_COLON"
    | COLON ->
        "COLON"
    | CHAR_LIT _ ->
        "CHAR_LIT"
    | CATCH ->
        "CATCH"
    | CARET ->
        "CARET"
    | CAP ->
        "CAP"
    | BUDGET ->
        "BUDGET"
    | BREAK ->
        "BREAK"
    | BANG_EQ ->
        "BANG_EQ"
    | BANG ->
        "BANG"
    | AWAIT ->
        "AWAIT"
    | AT ->
        "AT"
    | ASYNC ->
        "ASYNC"
    | AS ->
        "AS"
    | ARROW ->
        "ARROW"
    | AMP_AMP ->
        "AMP_AMP"
    | AMP ->
        "AMP"

let _menhir_fail : unit -> 'a =
  fun () ->
    Printf.eprintf "Internal failure -- please contact the parser generator's developers.\n%!";
    assert false

include struct
  
  [@@@ocaml.warning "-4-37"]
  
  let _menhir_run_493 : type  ttv_stack. ttv_stack -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _v _tok ->
      match (_tok : MenhirBasics.token) with
      | EOF ->
          let items = _v in
          let _v = _menhir_action_199 items in
          MenhirBox_program _v
      | _ ->
          _eRR ()
  
  let rec _menhir_run_001 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let _startpos__1_ = _startpos in
      let _v = _menhir_action_285 () in
      _menhir_goto_visibility _menhir_stack _menhir_lexbuf _menhir_lexer _startpos__1_ _v _menhir_s _tok
  
  and _menhir_goto_visibility : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState064 ->
          _menhir_run_069 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState383 ->
          _menhir_run_069 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState000 ->
          _menhir_run_387 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState452 ->
          _menhir_run_387 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState460 ->
          _menhir_run_387 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState442 ->
          _menhir_run_443 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState449 ->
          _menhir_run_443 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_069 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_visibility (_menhir_stack, _menhir_s, _v, _startpos) in
      match (_tok : MenhirBasics.token) with
      | DEF ->
          _menhir_run_070 _menhir_stack _menhir_lexbuf _menhir_lexer
      | _ ->
          _eRR ()
  
  and _menhir_run_070 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_visibility -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell0_DEF (_menhir_stack, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | IDENT _v ->
          let _startpos_0 = _menhir_lexbuf.Lexing.lex_start_p in
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v, _startpos_0, _endpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | LBRACKET ->
              _menhir_run_003 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState071
          | LPAREN ->
              let _v_1 = _menhir_action_157 () in
              _menhir_run_072 _menhir_stack _menhir_lexbuf _menhir_lexer _v_1 MenhirState071 _tok
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_003 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_LBRACKET (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState003 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | IDENT _v ->
          _menhir_run_004 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_004 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_IDENT (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | COLON ->
          _menhir_run_005 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState004
      | COMMA | RBRACKET ->
          let _v_0 = _menhir_action_155 () in
          _menhir_run_011 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_005 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _menhir_stack = MenhirCell1_COLON (_menhir_stack, _menhir_s) in
      let _menhir_s = MenhirState005 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | IDENT _v ->
          _menhir_run_006 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_006 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | PLUS ->
          let _menhir_stack = MenhirCell1_IDENT (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState007 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_006 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | COMMA | CONTINUE | DEF | DO | EFFECT | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | POST | PRE | PUB | RBRACKET | REQUIRES | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | TYPE | UNSAFE | WHILE ->
          let (_endpos_x_, x) = (_endpos, _v) in
          let _v = _menhir_action_235 x in
          _menhir_goto_separated_nonempty_list_PLUS_IDENT_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_x_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_separated_nonempty_list_PLUS_IDENT_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState007 ->
          _menhir_run_008 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState005 ->
          _menhir_run_009 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState059 ->
          _menhir_run_060 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState415 ->
          _menhir_run_416 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_008 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_IDENT (_menhir_stack, _menhir_s, x, _, _) = _menhir_stack in
      let (_endpos_xs_, xs) = (_endpos, _v) in
      let _v = _menhir_action_236 x xs in
      _menhir_goto_separated_nonempty_list_PLUS_IDENT_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_xs_ _v _menhir_s _tok
  
  and _menhir_run_009 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_COLON -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_COLON (_menhir_stack, _menhir_s) = _menhir_stack in
      let (_endpos_bounds_, bounds) = (_endpos, _v) in
      let _v = _menhir_action_252 bounds in
      let _endpos = _endpos_bounds_ in
      let (_endpos_x_, x) = (_endpos, _v) in
      let _v = _menhir_action_156 x in
      _menhir_goto_option_type_bounds_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_x_ _v _menhir_s _tok
  
  and _menhir_goto_option_type_bounds_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState004 ->
          _menhir_run_011 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState420 ->
          _menhir_run_421 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_011 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_IDENT (_menhir_stack, _menhir_s, name, _startpos_name_, _) = _menhir_stack in
      let (_endpos_bounds_, bounds) = (_endpos, _v) in
      let _v = _menhir_action_262 _endpos_bounds_ _startpos_name_ bounds name in
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          let _menhir_stack = MenhirCell1_type_param (_menhir_stack, _menhir_s, _v) in
          let _menhir_s = MenhirState013 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_004 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | RBRACKET ->
          let x = _v in
          let _v = _menhir_action_227 x in
          _menhir_goto_separated_nonempty_list_COMMA_type_param_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_separated_nonempty_list_COMMA_type_param_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState013 ->
          _menhir_run_014 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | MenhirState003 ->
          _menhir_run_015 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_014 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_type_param -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let MenhirCell1_type_param (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_228 x xs in
      _menhir_goto_separated_nonempty_list_COMMA_type_param_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_run_015 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_LBRACKET -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let MenhirCell1_LBRACKET (_menhir_stack, _menhir_s, _) = _menhir_stack in
      let params = _v in
      let _v = _menhir_action_263 params in
      let x = _v in
      let _v = _menhir_action_158 x in
      _menhir_goto_option_type_params_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_goto_option_type_params_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState002 ->
          _menhir_run_018 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState071 ->
          _menhir_run_072 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState408 ->
          _menhir_run_409 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState413 ->
          _menhir_run_414 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState423 ->
          _menhir_run_424 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState441 ->
          _menhir_run_442 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState467 ->
          _menhir_run_468 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_018 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_IMPL as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_type_params_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | IDENT _v_0 ->
          let _v = _v_0 in
          let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v, _startpos, _endpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | LBRACKET ->
              let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
              let _menhir_stack = MenhirCell0_LBRACKET (_menhir_stack, _startpos) in
              let _menhir_s = MenhirState020 in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | SELF_UPPER ->
                  _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | QUESTION ->
                  _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | LPAREN ->
                  _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | IDENT _v ->
                  _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
              | FN ->
                  _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | BANG ->
                  _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | AMP ->
                  _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | _ ->
                  _eRR ())
          | FOR ->
              let _v = _menhir_action_153 () in
              _menhir_goto_option_type_args_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
          | _ ->
              _eRR ())
      | AMP | BANG | FN | FOR | LPAREN | QUESTION | SELF_UPPER ->
          let _v = _menhir_action_139 () in
          _menhir_goto_option_impl_trait_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_021 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let (_endpos__1_, _startpos__1_) = (_endpos, _startpos) in
      let _v = _menhir_action_260 () in
      _menhir_goto_type_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_goto_type_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState030 ->
          _menhir_run_031 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState029 ->
          _menhir_run_032 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState020 ->
          _menhir_run_033 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState023 ->
          _menhir_run_033 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState025 ->
          _menhir_run_033 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState027 ->
          _menhir_run_033 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState034 ->
          _menhir_run_033 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState039 ->
          _menhir_run_040 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState022 ->
          _menhir_run_045 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState053 ->
          _menhir_run_054 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState055 ->
          _menhir_run_058 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState057 ->
          _menhir_run_058 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState067 ->
          _menhir_run_068 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState081 ->
          _menhir_run_082 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState085 ->
          _menhir_run_086 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState252 ->
          _menhir_run_253 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState318 ->
          _menhir_run_319 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState410 ->
          _menhir_run_411 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState445 ->
          _menhir_run_446 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState472 ->
          _menhir_run_473 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState470 ->
          _menhir_run_476 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState475 ->
          _menhir_run_476 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState488 ->
          _menhir_run_489 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_031 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_AMP, _menhir_box_program) _menhir_cell1_MUT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_MUT (_menhir_stack, _, _) = _menhir_stack in
      let MenhirCell1_AMP (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_t_, t) = (_endpos, _v) in
      let _v = _menhir_action_258 t in
      _menhir_goto_type_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_t_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_032 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_AMP -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_AMP (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_t_, t) = (_endpos, _v) in
      let _v = _menhir_action_257 t in
      _menhir_goto_type_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_t_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_033 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          let _menhir_stack = MenhirCell1_type_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState034 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | SELF_UPPER ->
              _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | QUESTION ->
              _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FN ->
              _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | RBRACKET | RPAREN ->
          let x = _v in
          let _v = _menhir_action_225 x in
          _menhir_goto_separated_nonempty_list_COMMA_type_expr_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_022 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_QUESTION (_menhir_stack, _menhir_s, _startpos, _endpos) in
      let _menhir_s = MenhirState022 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | SELF_UPPER ->
          _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | QUESTION ->
          _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FN ->
          _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_023 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_LPAREN (_menhir_stack, _menhir_s, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | SELF_UPPER ->
          _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState023
      | QUESTION ->
          _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState023
      | LPAREN ->
          _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState023
      | IDENT _v ->
          _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState023
      | FN ->
          _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState023
      | BANG ->
          _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState023
      | AMP ->
          _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState023
      | RPAREN ->
          let _v = _menhir_action_100 () in
          _menhir_run_043 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_024 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | LBRACKET ->
          let _menhir_stack = MenhirCell1_IDENT (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_025 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COLON | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHERE | WHILE ->
          let (_endpos_name_, _startpos_name_, name) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_253 name in
          _menhir_goto_type_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_name_ _startpos_name_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_025 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell0_LBRACKET (_menhir_stack, _startpos) in
      let _menhir_s = MenhirState025 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | SELF_UPPER ->
          _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | QUESTION ->
          _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FN ->
          _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_026 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_FN (_menhir_stack, _menhir_s, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | LPAREN ->
          let _startpos_0 = _menhir_lexbuf.Lexing.lex_start_p in
          let _menhir_stack = MenhirCell0_LPAREN (_menhir_stack, _startpos_0) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | SELF_UPPER ->
              _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState027
          | QUESTION ->
              _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState027
          | LPAREN ->
              _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState027
          | IDENT _v ->
              _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState027
          | FN ->
              _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState027
          | BANG ->
              _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState027
          | AMP ->
              _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState027
          | RPAREN ->
              let _v = _menhir_action_100 () in
              _menhir_run_037 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState027 _tok
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_028 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let (_endpos__1_, _startpos__1_) = (_endpos, _startpos) in
      let _v = _menhir_action_261 () in
      _menhir_goto_type_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_029 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_AMP (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState029 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | SELF_UPPER ->
          _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | QUESTION ->
          _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MUT ->
          let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
          let _menhir_stack = MenhirCell1_MUT (_menhir_stack, _menhir_s, _startpos) in
          let _menhir_s = MenhirState030 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | SELF_UPPER ->
              _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | QUESTION ->
              _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FN ->
              _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | LPAREN ->
          _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FN ->
          _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_037 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_FN _menhir_cell0_LPAREN as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_loption_separated_nonempty_list_COMMA_type_expr__ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | RPAREN ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _menhir_stack = MenhirCell0_RPAREN (_menhir_stack, _endpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | ARROW ->
              let _menhir_s = MenhirState039 in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | SELF_UPPER ->
                  _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | QUESTION ->
                  _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | LPAREN ->
                  _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | IDENT _v ->
                  _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
              | FN ->
                  _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | BANG ->
                  _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | AMP ->
                  _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_043 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_LPAREN -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | RPAREN ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell1_LPAREN (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
          let (xs, _endpos__3_) = (_v, _endpos) in
          let _v = _menhir_action_256 xs in
          _menhir_goto_type_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__3_ _startpos__1_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_separated_nonempty_list_COMMA_type_expr_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState034 ->
          _menhir_run_035 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState023 ->
          _menhir_run_036 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState027 ->
          _menhir_run_036 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState025 ->
          _menhir_run_041 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState020 ->
          _menhir_run_046 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_035 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_type_expr -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let MenhirCell1_type_expr (_menhir_stack, _menhir_s, x, _, _) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_226 x xs in
      _menhir_goto_separated_nonempty_list_COMMA_type_expr_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_run_036 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let x = _v in
      let _v = _menhir_action_101 x in
      _menhir_goto_loption_separated_nonempty_list_COMMA_type_expr__ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_goto_loption_separated_nonempty_list_COMMA_type_expr__ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState027 ->
          _menhir_run_037 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState023 ->
          _menhir_run_043 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_041 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT _menhir_cell0_LBRACKET -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | RBRACKET ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell0_LBRACKET (_menhir_stack, _) = _menhir_stack in
          let MenhirCell1_IDENT (_menhir_stack, _menhir_s, name, _startpos_name_, _) = _menhir_stack in
          let (args, _endpos__4_) = (_v, _endpos) in
          let _v = _menhir_action_254 args name in
          _menhir_goto_type_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__4_ _startpos_name_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_046 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_IMPL, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_IDENT _menhir_cell0_LBRACKET -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | RBRACKET ->
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell0_LBRACKET (_menhir_stack, _) = _menhir_stack in
          let args = _v in
          let _v = _menhir_action_251 args in
          let x = _v in
          let _v = _menhir_action_154 x in
          _menhir_goto_option_type_args_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_option_type_args_ : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_IMPL, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_IDENT -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | FOR ->
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
          let args = _v in
          let _v = _menhir_action_054 args name in
          let x = _v in
          let _v = _menhir_action_140 x in
          _menhir_goto_option_impl_trait_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_option_impl_trait_ : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_IMPL, _menhir_box_program) _menhir_cell1_option_type_params_ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let _menhir_stack = MenhirCell0_option_impl_trait_ (_menhir_stack, _v) in
      match (_tok : MenhirBasics.token) with
      | FOR ->
          let _tok = _menhir_lexer _menhir_lexbuf in
          let x = () in
          let _v = _menhir_action_118 x in
          _menhir_goto_option_FOR_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | AMP | BANG | FN | IDENT _ | LPAREN | QUESTION | SELF_UPPER ->
          let _v = _menhir_action_117 () in
          _menhir_goto_option_FOR_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_option_FOR_ : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_IMPL, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_option_impl_trait_ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let _menhir_stack = MenhirCell0_option_FOR_ (_menhir_stack, _v) in
      match (_tok : MenhirBasics.token) with
      | SELF_UPPER ->
          _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState053
      | QUESTION ->
          _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState053
      | LPAREN ->
          _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState053
      | IDENT _v_0 ->
          _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0 MenhirState053
      | FN ->
          _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState053
      | BANG ->
          _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState053
      | AMP ->
          _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState053
      | _ ->
          _eRR ()
  
  and _menhir_run_040 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_FN _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_type_expr__ _menhir_cell0_RPAREN -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell0_RPAREN (_menhir_stack, _) = _menhir_stack in
      let MenhirCell1_loption_separated_nonempty_list_COMMA_type_expr__ (_menhir_stack, _, xs) = _menhir_stack in
      let MenhirCell0_LPAREN (_menhir_stack, _) = _menhir_stack in
      let MenhirCell1_FN (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_ret_, ret) = (_endpos, _v) in
      let _v = _menhir_action_255 ret xs in
      _menhir_goto_type_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_ret_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_045 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_QUESTION -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_QUESTION (_menhir_stack, _menhir_s, _startpos__1_, _) = _menhir_stack in
      let (_endpos_t_, t) = (_endpos, _v) in
      let _v = _menhir_action_259 t in
      _menhir_goto_type_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_t_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_054 : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_IMPL, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_option_impl_trait_ _menhir_cell0_option_FOR_ as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_type_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
      match (_tok : MenhirBasics.token) with
      | WHERE ->
          _menhir_run_055 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState054
      | DEF | END | PUB | TYPE ->
          let _v_0 = _menhir_action_161 () in
          _menhir_run_064 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 MenhirState054 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_055 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _menhir_stack = MenhirCell1_WHERE (_menhir_stack, _menhir_s) in
      let _menhir_s = MenhirState055 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | SELF_UPPER ->
          _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | QUESTION ->
          _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FN ->
          _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_064 : type  ttv_stack. ((((ttv_stack, _menhir_box_program) _menhir_cell1_IMPL, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_option_impl_trait_ _menhir_cell0_option_FOR_, _menhir_box_program) _menhir_cell1_type_expr as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_where_clause_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | TYPE ->
          _menhir_run_065 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState064
      | PUB ->
          _menhir_run_001 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState064
      | END ->
          let _v_0 = _menhir_action_071 () in
          _menhir_run_381 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0
      | DEF ->
          let _v_1 = _menhir_action_286 () in
          _menhir_run_069 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_1 MenhirState064 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_065 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_TYPE (_menhir_stack, _menhir_s, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | IDENT _v ->
          let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v, _startpos, _endpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | EQ ->
              let _menhir_s = MenhirState067 in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | SELF_UPPER ->
                  _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | QUESTION ->
                  _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | LPAREN ->
                  _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | IDENT _v ->
                  _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
              | FN ->
                  _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | BANG ->
                  _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | AMP ->
                  _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_381 : type  ttv_stack. ((((ttv_stack, _menhir_box_program) _menhir_cell1_IMPL, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_option_impl_trait_ _menhir_cell0_option_FOR_, _menhir_box_program) _menhir_cell1_type_expr, _menhir_box_program) _menhir_cell1_option_where_clause_ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let MenhirCell1_option_where_clause_ (_menhir_stack, _, where_clause) = _menhir_stack in
      let MenhirCell1_type_expr (_menhir_stack, _, for_type, _, _) = _menhir_stack in
      let MenhirCell0_option_FOR_ (_menhir_stack, _) = _menhir_stack in
      let MenhirCell0_option_impl_trait_ (_menhir_stack, trait_) = _menhir_stack in
      let MenhirCell1_option_type_params_ (_menhir_stack, _, type_params) = _menhir_stack in
      let MenhirCell1_IMPL (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (items, _endpos__8_) = (_v, _endpos) in
      let _v = _menhir_action_051 _endpos__8_ _startpos__1_ for_type items trait_ type_params where_clause in
      let i = _v in
      let _v = _menhir_action_060 i in
      _menhir_goto_item _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_goto_item : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_item (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | PUB ->
          _menhir_run_001 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState460
      | IMPL ->
          _menhir_run_002 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState460
      | END | EOF ->
          let _v_0 = _menhir_action_073 () in
          _menhir_run_461 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0 _tok
      | CONST | DEF | ENUM | MODULE | STRUCT | TRAIT | TYPE | USE ->
          let _v_1 = _menhir_action_286 () in
          _menhir_run_387 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_1 MenhirState460 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_002 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_IMPL (_menhir_stack, _menhir_s, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | LBRACKET ->
          _menhir_run_003 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState002
      | AMP | BANG | FN | FOR | IDENT _ | LPAREN | QUESTION | SELF_UPPER ->
          let _v = _menhir_action_157 () in
          _menhir_run_018 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState002 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_461 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_item -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let MenhirCell1_item (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_074 x xs in
      _menhir_goto_list_item_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_goto_list_item_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState452 ->
          _menhir_run_458 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState460 ->
          _menhir_run_461 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState000 ->
          _menhir_run_493 _menhir_stack _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_458 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | END ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
          let MenhirCell1_visibility (_menhir_stack, _menhir_s, vis, _startpos_vis_) = _menhir_stack in
          let (_endpos__5_, items) = (_endpos, _v) in
          let _v = _menhir_action_105 _endpos__5_ _startpos_vis_ items name vis in
          _menhir_goto_module_decl _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_module_decl : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let m = _v in
      let _v = _menhir_action_064 m in
      _menhir_goto_item _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_387 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | USE ->
          let _menhir_stack = MenhirCell1_visibility (_menhir_stack, _menhir_s, _v, _startpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v_0 ->
              let _startpos_1 = _menhir_lexbuf.Lexing.lex_start_p in
              let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
              let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v_0, _startpos_1, _endpos) in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | COLON_COLON ->
                  _menhir_run_390 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState389
              | AS ->
                  _menhir_run_403 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState389
              | CONST | DEF | END | ENUM | EOF | IMPL | MODULE | PUB | STRUCT | TRAIT | TYPE | USE ->
                  let _v_2 = _menhir_action_280 () in
                  _menhir_run_406 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_2 _tok
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | TYPE ->
          let _menhir_stack = MenhirCell1_visibility (_menhir_stack, _menhir_s, _v, _startpos) in
          let _startpos_3 = _menhir_lexbuf.Lexing.lex_start_p in
          let _menhir_stack = MenhirCell0_TYPE (_menhir_stack, _startpos_3) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v_4 ->
              let _startpos_5 = _menhir_lexbuf.Lexing.lex_start_p in
              let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
              let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v_4, _startpos_5, _endpos) in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | LBRACKET ->
                  _menhir_run_003 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState408
              | EQ ->
                  let _v_6 = _menhir_action_157 () in
                  _menhir_run_409 _menhir_stack _menhir_lexbuf _menhir_lexer _v_6 MenhirState408 _tok
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | TRAIT ->
          let _menhir_stack = MenhirCell1_visibility (_menhir_stack, _menhir_s, _v, _startpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v_7 ->
              let _startpos_8 = _menhir_lexbuf.Lexing.lex_start_p in
              let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
              let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v_7, _startpos_8, _endpos) in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | LBRACKET ->
                  _menhir_run_003 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState413
              | COLON | DEF | END | TYPE ->
                  let _v_9 = _menhir_action_157 () in
                  _menhir_run_414 _menhir_stack _menhir_lexbuf _menhir_lexer _v_9 MenhirState413 _tok
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | STRUCT ->
          let _menhir_stack = MenhirCell1_visibility (_menhir_stack, _menhir_s, _v, _startpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v_10 ->
              let _startpos_11 = _menhir_lexbuf.Lexing.lex_start_p in
              let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
              let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v_10, _startpos_11, _endpos) in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | LBRACKET ->
                  _menhir_run_003 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState441
              | END | IDENT _ | PUB ->
                  let _v_12 = _menhir_action_157 () in
                  _menhir_run_442 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_12 MenhirState441 _tok
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | MODULE ->
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v_13 ->
              let _startpos_14 = _menhir_lexbuf.Lexing.lex_start_p in
              let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | PUB ->
                  let _menhir_stack = MenhirCell1_visibility (_menhir_stack, _menhir_s, _v, _startpos) in
                  let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v_13, _startpos_14, _endpos) in
                  _menhir_run_001 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState452
              | IMPL ->
                  let _menhir_stack = MenhirCell1_visibility (_menhir_stack, _menhir_s, _v, _startpos) in
                  let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v_13, _startpos_14, _endpos) in
                  _menhir_run_002 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState452
              | END | EOF ->
                  let (_endpos_name_, name, _startpos_vis_, vis) = (_endpos, _v_13, _startpos, _v) in
                  let _v = _menhir_action_106 _endpos_name_ _startpos_vis_ name vis in
                  _menhir_goto_module_decl _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
              | CONST | DEF | ENUM | MODULE | STRUCT | TRAIT | TYPE | USE ->
                  let _menhir_stack = MenhirCell1_visibility (_menhir_stack, _menhir_s, _v, _startpos) in
                  let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v_13, _startpos_14, _endpos) in
                  let _v_15 = _menhir_action_286 () in
                  _menhir_run_387 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_15 MenhirState452 _tok
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | ENUM ->
          let _menhir_stack = MenhirCell1_visibility (_menhir_stack, _menhir_s, _v, _startpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v_16 ->
              let _startpos_17 = _menhir_lexbuf.Lexing.lex_start_p in
              let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
              let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v_16, _startpos_17, _endpos) in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | LBRACKET ->
                  _menhir_run_003 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState467
              | END | IDENT _ ->
                  let _v_18 = _menhir_action_157 () in
                  _menhir_run_468 _menhir_stack _menhir_lexbuf _menhir_lexer _v_18 MenhirState467 _tok
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | DEF ->
          let _menhir_stack = MenhirCell1_visibility (_menhir_stack, _menhir_s, _v, _startpos) in
          _menhir_run_070 _menhir_stack _menhir_lexbuf _menhir_lexer
      | CONST ->
          let _menhir_stack = MenhirCell1_visibility (_menhir_stack, _menhir_s, _v, _startpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
              let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
              let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v, _startpos, _endpos) in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | COLON ->
                  let _menhir_s = MenhirState488 in
                  let _tok = _menhir_lexer _menhir_lexbuf in
                  (match (_tok : MenhirBasics.token) with
                  | SELF_UPPER ->
                      _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
                  | QUESTION ->
                      _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
                  | LPAREN ->
                      _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
                  | IDENT _v ->
                      _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
                  | FN ->
                      _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
                  | BANG ->
                      _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
                  | AMP ->
                      _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
                  | _ ->
                      _eRR ())
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_390 : type  ttv_stack. (ttv_stack _menhir_cell0_IDENT as 'stack) -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | STAR ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let _endpos__2_ = _endpos in
          let _v = _menhir_action_277 () in
          _menhir_goto_use_path_rest _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__2_ _v _menhir_s _tok
      | LBRACE ->
          let _menhir_stack = MenhirCell1_COLON_COLON (_menhir_stack, _menhir_s) in
          let _menhir_s = MenhirState392 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_393 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | IDENT _v ->
          let _menhir_stack = MenhirCell1_COLON_COLON (_menhir_stack, _menhir_s) in
          let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v, _startpos, _endpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | COLON_COLON ->
              _menhir_run_390 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState402
          | AS ->
              _menhir_run_403 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState402
          | CONST | DEF | END | ENUM | EOF | IMPL | MODULE | PUB | STRUCT | TRAIT | TYPE | USE ->
              let _v_0 = _menhir_action_280 () in
              _menhir_run_405 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 _tok
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_goto_use_path_rest : type  ttv_stack. (ttv_stack _menhir_cell0_IDENT as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState402 ->
          _menhir_run_405 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState389 ->
          _menhir_run_406 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_405 : type  ttv_stack. (ttv_stack _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_COLON_COLON _menhir_cell0_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell0_IDENT (_menhir_stack, next, _, _) = _menhir_stack in
      let MenhirCell1_COLON_COLON (_menhir_stack, _menhir_s) = _menhir_stack in
      let (_endpos_rest_, rest) = (_endpos, _v) in
      let _v = _menhir_action_279 next rest in
      _menhir_goto_use_path_rest _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_rest_ _v _menhir_s _tok
  
  and _menhir_run_406 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell0_IDENT (_menhir_stack, first, _, _) = _menhir_stack in
      let MenhirCell1_visibility (_menhir_stack, _menhir_s, vis, _startpos_vis_) = _menhir_stack in
      let (_endpos_rest_, rest) = (_endpos, _v) in
      let _v = _menhir_action_272 _endpos_rest_ _startpos_vis_ first rest vis in
      let u = _v in
      let _v = _menhir_action_061 u in
      _menhir_goto_item _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_393 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | AS ->
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v_0 ->
              let _tok = _menhir_lexer _menhir_lexbuf in
              let (name, alias) = (_v, _v_0) in
              let _v = _menhir_action_273 alias name in
              _menhir_goto_use_item _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
          | _ ->
              _eRR ())
      | COMMA | RBRACE ->
          let name = _v in
          let _v = _menhir_action_274 name in
          _menhir_goto_use_item _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_use_item : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          let _menhir_stack = MenhirCell1_use_item (_menhir_stack, _menhir_s, _v) in
          let _menhir_s = MenhirState399 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_393 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | RBRACE ->
          let x = _v in
          let _v = _menhir_action_229 x in
          _menhir_goto_separated_nonempty_list_COMMA_use_item_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_separated_nonempty_list_COMMA_use_item_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState399 ->
          _menhir_run_400 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | MenhirState392 ->
          _menhir_run_401 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_400 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_use_item -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let MenhirCell1_use_item (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_230 x xs in
      _menhir_goto_separated_nonempty_list_COMMA_use_item_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_run_401 : type  ttv_stack. (ttv_stack _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_COLON_COLON -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let items = _v in
      let _v = _menhir_action_275 items in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let MenhirCell1_COLON_COLON (_menhir_stack, _menhir_s) = _menhir_stack in
      let (items, _endpos__4_) = (_v, _endpos) in
      let _v = _menhir_action_278 items in
      _menhir_goto_use_path_rest _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__4_ _v _menhir_s _tok
  
  and _menhir_run_403 : type  ttv_stack. (ttv_stack _menhir_cell0_IDENT as 'stack) -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | IDENT _v ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let (_endpos_alias_, alias) = (_endpos, _v) in
          let _v = _menhir_action_276 alias in
          _menhir_goto_use_path_rest _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_alias_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_409 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_TYPE _menhir_cell0_IDENT as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_type_params_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | EQ ->
          let _menhir_s = MenhirState410 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | SELF_UPPER ->
              _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | QUESTION ->
              _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FN ->
              _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_414 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_type_params_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | COLON ->
          let _menhir_s = MenhirState415 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_006 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | DEF | END | TYPE ->
          let _v = _menhir_action_149 () in
          _menhir_goto_option_trait_super_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_option_trait_super_ : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let _menhir_stack = MenhirCell0_option_trait_super_ (_menhir_stack, _v) in
      match (_tok : MenhirBasics.token) with
      | TYPE ->
          _menhir_run_419 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState418
      | DEF ->
          _menhir_run_422 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState418
      | END ->
          let _v_0 = _menhir_action_079 () in
          _menhir_run_438 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0
      | _ ->
          _eRR ()
  
  and _menhir_run_419 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_TYPE (_menhir_stack, _menhir_s, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | IDENT _v ->
          let _startpos_0 = _menhir_lexbuf.Lexing.lex_start_p in
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v, _startpos_0, _endpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | COLON ->
              _menhir_run_005 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState420
          | DEF | END | TYPE ->
              let _v_1 = _menhir_action_155 () in
              _menhir_run_421 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_1 _tok
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_421 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_TYPE _menhir_cell0_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
      let MenhirCell1_TYPE (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_bounds_, bounds) = (_endpos, _v) in
      let _v = _menhir_action_245 _endpos_bounds_ _startpos__1_ bounds name in
      _menhir_goto_trait_item _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_goto_trait_item : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_trait_item (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | TYPE ->
          _menhir_run_419 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState436
      | DEF ->
          _menhir_run_422 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState436
      | END ->
          let _v_0 = _menhir_action_079 () in
          _menhir_run_437 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0
      | _ ->
          _eRR ()
  
  and _menhir_run_422 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_DEF (_menhir_stack, _menhir_s, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | IDENT _v ->
          let _startpos_0 = _menhir_lexbuf.Lexing.lex_start_p in
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v, _startpos_0, _endpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | LBRACKET ->
              _menhir_run_003 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState423
          | LPAREN ->
              let _v_1 = _menhir_action_157 () in
              _menhir_run_424 _menhir_stack _menhir_lexbuf _menhir_lexer _v_1 MenhirState423 _tok
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_424 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_DEF _menhir_cell0_IDENT as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_type_params_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | LPAREN ->
          let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _menhir_stack = MenhirCell0_LPAREN (_menhir_stack, _startpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | MUT ->
              _menhir_run_074 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState425
          | RPAREN ->
              let _v_0 = _menhir_action_092 () in
              _menhir_run_426 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0 MenhirState425
          | IDENT _ ->
              let _v_1 = _menhir_action_121 () in
              _menhir_run_079 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_1 MenhirState425 _tok
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_074 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let (_startpos_x_, x) = (_startpos, ()) in
      let _v = _menhir_action_122 x in
      _menhir_goto_option_MUT_ _menhir_stack _menhir_lexbuf _menhir_lexer _startpos_x_ _v _menhir_s _tok
  
  and _menhir_goto_option_MUT_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState073 ->
          _menhir_run_079 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState077 ->
          _menhir_run_079 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState425 ->
          _menhir_run_079 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState116 ->
          _menhir_run_126 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState117 ->
          _menhir_run_126 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState121 ->
          _menhir_run_126 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState137 ->
          _menhir_run_126 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState140 ->
          _menhir_run_126 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState297 ->
          _menhir_run_126 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState316 ->
          _menhir_run_126 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | MenhirState315 ->
          _menhir_run_316 _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_079 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_MUT_ (_menhir_stack, _menhir_s, _v, _startpos) in
      match (_tok : MenhirBasics.token) with
      | IDENT _v_0 ->
          let _v = _v_0 in
          let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v, _startpos, _endpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | COLON ->
              let _menhir_s = MenhirState081 in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | SELF_UPPER ->
                  _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | QUESTION ->
                  _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | LPAREN ->
                  _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | IDENT _v ->
                  _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
              | FN ->
                  _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | BANG ->
                  _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | AMP ->
                  _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_126 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | IDENT _v_0 ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let (_endpos_name_, name, _startpos_m_, m) = (_endpos, _v_0, _startpos, _v) in
          let _v = _menhir_action_167 _endpos_name_ _startpos_m_ m name in
          _menhir_goto_pattern _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_pattern : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState121 ->
          _menhir_run_125 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState117 ->
          _menhir_run_139 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState137 ->
          _menhir_run_139 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState140 ->
          _menhir_run_139 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState116 ->
          _menhir_run_148 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState297 ->
          _menhir_run_298 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState316 ->
          _menhir_run_317 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_125 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let MenhirCell1_IDENT (_menhir_stack, _menhir_s, name, _, _) = _menhir_stack in
      let p = _v in
      let _v = _menhir_action_172 name p in
      _menhir_goto_pattern_field _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_goto_pattern_field : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          let _menhir_stack = MenhirCell1_pattern_field (_menhir_stack, _menhir_s, _v) in
          let _menhir_s = MenhirState131 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_120 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | RBRACE ->
          let x = _v in
          let _v = _menhir_action_219 x in
          _menhir_goto_separated_nonempty_list_COMMA_pattern_field_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_120 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | COLON ->
          let _menhir_stack = MenhirCell1_IDENT (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState121 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | MUT ->
              _menhir_run_074 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_117 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IDENT _v ->
              _menhir_run_118 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | COMMA | RBRACE ->
          let (_endpos_name_, _startpos_name_, name) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_173 _endpos_name_ _startpos_name_ name in
          _menhir_goto_pattern_field _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_094 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let (_endpos__1_, _startpos__1_) = (_endpos, _startpos) in
      let _v = _menhir_action_087 () in
      _menhir_goto_literal _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_goto_literal : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState116 ->
          _menhir_run_128 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState117 ->
          _menhir_run_128 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState121 ->
          _menhir_run_128 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState137 ->
          _menhir_run_128 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState140 ->
          _menhir_run_128 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState297 ->
          _menhir_run_128 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState316 ->
          _menhir_run_128 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState090 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState091 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState093 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState095 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState097 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState099 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState103 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState104 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState105 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState111 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState115 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState149 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState156 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState157 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState158 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState159 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState170 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState173 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState183 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState185 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState188 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState190 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState192 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState196 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState198 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState200 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState203 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState205 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState207 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState209 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState213 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState215 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState218 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState223 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState225 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState227 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState229 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState231 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState233 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState235 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState243 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState279 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState299 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState302 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState322 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState341 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState344 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState490 ->
          _menhir_run_177 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_128 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      let (_endpos_l_, _startpos_l_, l) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_171 _endpos_l_ _startpos_l_ l in
      _menhir_goto_pattern _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_run_177 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      let (_endpos_l_, _startpos_l_, l) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_182 _endpos_l_ _startpos_l_ l in
      _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_l_ _startpos_l_ _v _menhir_s _tok
  
  and _menhir_goto_primary_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      let (_endpos_e_, _startpos_e_, e) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_181 e in
      _menhir_goto_postfix_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos_e_ _v _menhir_s _tok
  
  and _menhir_goto_postfix_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | QUESTION ->
          let _endpos_1 = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let (_endpos__2_, _startpos_e_, e) = (_endpos_1, _startpos, _v) in
          let _v = _menhir_action_179 _endpos__2_ _startpos_e_ e in
          _menhir_goto_postfix_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__2_ _startpos_e_ _v _menhir_s _tok
      | LPAREN ->
          let _menhir_stack = MenhirCell1_postfix_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _startpos_2 = _menhir_lexbuf.Lexing.lex_start_p in
          let _menhir_stack = MenhirCell0_LPAREN (_menhir_stack, _startpos_2) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | STRING_LIT _v_3 ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v_3 MenhirState167
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | INT_LIT _v_4 ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v_4 MenhirState167
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | IDENT _v_5 ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v_5 MenhirState167
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | FLOAT_LIT _v_6 ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v_6 MenhirState167
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | CHAR_LIT _v_7 ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v_7 MenhirState167
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState167
          | RPAREN ->
              let _v_8 = _menhir_action_090 () in
              _menhir_run_237 _menhir_stack _menhir_lexbuf _menhir_lexer _v_8 _tok
          | _ ->
              _eRR ())
      | LBRACKET ->
          let _menhir_stack = MenhirCell1_postfix_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
          let _menhir_stack = MenhirCell0_LBRACKET (_menhir_stack, _startpos) in
          let _menhir_s = MenhirState243 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | DOT ->
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | INT_LIT _v_15 ->
              let _endpos_17 = _menhir_lexbuf.Lexing.lex_curr_p in
              let _tok = _menhir_lexer _menhir_lexbuf in
              let (_startpos_e_, e, _endpos_idx_, idx) = (_startpos, _v, _endpos_17, _v_15) in
              let _v = _menhir_action_177 _endpos_idx_ _startpos_e_ e idx in
              _menhir_goto_postfix_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_idx_ _startpos_e_ _v _menhir_s _tok
          | IDENT _v_18 ->
              let _startpos_19 = _menhir_lexbuf.Lexing.lex_start_p in
              let _endpos_20 = _menhir_lexbuf.Lexing.lex_curr_p in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | LPAREN ->
                  let _menhir_stack = MenhirCell1_postfix_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
                  let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v_18, _startpos_19, _endpos_20) in
                  let _startpos_21 = _menhir_lexbuf.Lexing.lex_start_p in
                  let _menhir_stack = MenhirCell0_LPAREN (_menhir_stack, _startpos_21) in
                  let _tok = _menhir_lexer _menhir_lexbuf in
                  (match (_tok : MenhirBasics.token) with
                  | WHILE ->
                      _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | UNSAFE ->
                      _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | TRUE ->
                      _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | TILDE ->
                      _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | STRING_LIT _v_22 ->
                      _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v_22 MenhirState249
                  | STAR ->
                      _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | SELF_LOWER ->
                      _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | RETURN ->
                      _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | NEXT ->
                      _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | MINUS ->
                      _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | MATCH ->
                      _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | LPAREN ->
                      _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | LOOP ->
                      _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | LBRACKET ->
                      _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | INT_LIT _v_23 ->
                      _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v_23 MenhirState249
                  | IF ->
                      _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | IDENT _v_24 ->
                      _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v_24 MenhirState249
                  | FOR ->
                      _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | FLOAT_LIT _v_25 ->
                      _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v_25 MenhirState249
                  | FALSE ->
                      _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | DO ->
                      _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | CONTINUE ->
                      _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | CHAR_LIT _v_26 ->
                      _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v_26 MenhirState249
                  | BREAK ->
                      _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | BANG ->
                      _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | AMP ->
                      _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState249
                  | RPAREN ->
                      let _v_27 = _menhir_action_090 () in
                      _menhir_run_250 _menhir_stack _menhir_lexbuf _menhir_lexer _v_27 _tok
                  | _ ->
                      _eRR ())
              | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
                  let (_endpos_name_, name, _startpos_e_, e) = (_endpos_20, _v_18, _startpos, _v) in
                  let _v = _menhir_action_176 _endpos_name_ _startpos_e_ e name in
                  _menhir_goto_postfix_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_name_ _startpos_e_ _v _menhir_s _tok
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | AS ->
          let _menhir_stack = MenhirCell1_postfix_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState252 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | SELF_UPPER ->
              _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | QUESTION ->
              _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FN ->
              _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | AMP | AMP_AMP | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LET | LOOP | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let (_endpos_e_, _startpos_e_, e) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_270 e in
          _menhir_goto_unary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos_e_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_091 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_WHILE (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState091 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_092 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_UNSAFE (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState092 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      _menhir_reduce_204 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _menhir_s _tok
  
  and _menhir_reduce_204 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _menhir_s _tok ->
      let _v = _menhir_action_204 () in
      _menhir_goto_rev_block_items _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _endpos _v _menhir_s _tok
  
  and _menhir_goto_rev_block_items : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | UNSAFE ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | TRUE ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | TILDE ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | STRING_LIT _v_0 ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0 MenhirState093
      | STAR ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | SELF_LOWER ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | RETURN ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | NEXT ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | MINUS ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | MATCH ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | LPAREN ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | LOOP ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | LET ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _endpos_1 = _menhir_lexbuf.Lexing.lex_curr_p in
          let _menhir_stack = MenhirCell1_LET (_menhir_stack, MenhirState093) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | MUT ->
              _menhir_run_074 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState315
          | CHAR_LIT _ | FALSE | FLOAT_LIT _ | IDENT _ | INT_LIT _ | LPAREN | STRING_LIT _ | TRUE ->
              let _v_2 = _menhir_action_121 () in
              _menhir_run_316 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_1 _v_2 MenhirState315 _tok
          | _ ->
              _eRR ())
      | LBRACKET ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | INT_LIT _v_3 ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v_3 MenhirState093
      | IF ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | IDENT _v_4 ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v_4 MenhirState093
      | FOR ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | FLOAT_LIT _v_5 ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v_5 MenhirState093
      | FALSE ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | DO ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | CONTINUE ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | CHAR_LIT _v_6 ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v_6 MenhirState093
      | BREAK ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | BANG ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | AMP ->
          let _menhir_stack = MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState093
      | ELSE | ELSIF | END ->
          let (_endpos_items_, _startpos_items_, items) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_019 _endpos_items_ _startpos_items_ items in
          _menhir_goto_block _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_095 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_TILDE (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState095 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_096 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let (_endpos_s_, _startpos_s_, s) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_085 s in
      _menhir_goto_literal _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_s_ _startpos_s_ _v _menhir_s _tok
  
  and _menhir_run_097 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_STAR (_menhir_stack, _menhir_s, _startpos, _endpos) in
      let _menhir_s = MenhirState097 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_098 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let (_endpos__1_, _startpos__1_) = (_endpos, _startpos) in
      let _v = _menhir_action_184 _endpos__1_ _startpos__1_ in
      _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_099 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_RETURN (_menhir_stack, _menhir_s, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState099
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState099
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState099
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState099
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState099
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState099
      | AMP_AMP | AS | BANG_EQ | BUDGET | CARET | COMMA | CONST | DEF | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FAT_ARROW | GT | GT_EQ | IMPL | INVARIANT | LET | LT | LT_EQ | MINUS_EQ | MODULE | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RPAREN | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR_EQ | STRUCT | THEN | TRAIT | TYPE | USE | WHEN ->
          let _v = _menhir_action_137 () in
          _menhir_run_312 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_100 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_NEXT (_menhir_stack, _menhir_s, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | IDENT _v ->
          _menhir_run_101 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState100
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let _v = _menhir_action_119 () in
          _menhir_run_102 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_101 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let (_endpos_x_, x) = (_endpos, _v) in
      let _v = _menhir_action_120 x in
      _menhir_goto_option_IDENT_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_x_ _v _menhir_s _tok
  
  and _menhir_goto_option_IDENT_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState100 ->
          _menhir_run_102 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState153 ->
          _menhir_run_154 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState155 ->
          _menhir_run_156 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_102 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_NEXT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_NEXT (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_label_, label) = (_endpos, _v) in
      let _v = _menhir_action_031 _endpos_label_ _startpos__1_ label in
      _menhir_goto_continue_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_label_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_goto_continue_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      let (_endpos__1_, _startpos__1_, _1) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_197 _1 in
      _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_154 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_CONTINUE -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_CONTINUE (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_label_, label) = (_endpos, _v) in
      let _v = _menhir_action_030 _endpos_label_ _startpos__1_ label in
      _menhir_goto_continue_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_label_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_156 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_BREAK as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_IDENT_ (_menhir_stack, _menhir_s, _v, _endpos) in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | STRING_LIT _v_0 ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0 MenhirState156
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | INT_LIT _v_1 ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v_1 MenhirState156
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | IDENT _v_2 ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v_2 MenhirState156
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | FLOAT_LIT _v_3 ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v_3 MenhirState156
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | CHAR_LIT _v_4 ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v_4 MenhirState156
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState156
      | AMP_AMP | AS | BANG_EQ | BUDGET | CARET | COMMA | CONST | DEF | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FAT_ARROW | GT | GT_EQ | IMPL | INVARIANT | LET | LT | LT_EQ | MINUS_EQ | MODULE | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RPAREN | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR_EQ | STRUCT | THEN | TRAIT | TYPE | USE | WHEN ->
          let _v_5 = _menhir_action_137 () in
          _menhir_run_256 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_5 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_103 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_MINUS (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState103 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_104 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_MATCH (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState104 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_105 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_LPAREN (_menhir_stack, _menhir_s, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState105
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState105
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState105
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState105
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState105
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState105
      | RPAREN ->
          let _v = _menhir_action_090 () in
          _menhir_run_293 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_106 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_LOOP (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState106 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      _menhir_reduce_204 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _menhir_s _tok
  
  and _menhir_run_109 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_LBRACKET (_menhir_stack, _menhir_s, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState109
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState109
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState109
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState109
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState109
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState109
      | RBRACKET ->
          let _v = _menhir_action_090 () in
          _menhir_run_291 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_110 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let (_endpos_i_, _startpos_i_, i) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_083 i in
      _menhir_goto_literal _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_i_ _startpos_i_ _v _menhir_s _tok
  
  and _menhir_run_111 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_IF (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState111 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_112 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | LBRACE ->
          let _menhir_stack = MenhirCell1_IDENT (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState113 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_114 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | RBRACE ->
              let _v = _menhir_action_098 () in
              _menhir_goto_loption_separated_nonempty_list_COMMA_struct_field__ _menhir_stack _menhir_lexbuf _menhir_lexer _v
          | _ ->
              _eRR ())
      | COLON_COLON ->
          let _menhir_stack = MenhirCell1_IDENT (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState270 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_271 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let (_endpos_name_, _startpos_name_, name) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_183 _endpos_name_ _startpos_name_ name in
          _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_name_ _startpos_name_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_114 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | COLON ->
          let _menhir_stack = MenhirCell1_IDENT (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState115 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | COMMA | RBRACE ->
          let (_endpos_name_, _startpos_name_, name) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_242 _endpos_name_ _startpos_name_ name in
          _menhir_goto_struct_field _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_116 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_FOR (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState116 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | MUT ->
          _menhir_run_074 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_117 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IDENT _v ->
          _menhir_run_118 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_117 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_LPAREN (_menhir_stack, _menhir_s, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState117
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState117
      | MUT ->
          _menhir_run_074 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState117
      | LPAREN ->
          _menhir_run_117 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState117
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState117
      | IDENT _v ->
          _menhir_run_118 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState117
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState117
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState117
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState117
      | RPAREN ->
          let _v = _menhir_action_094 () in
          _menhir_run_146 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _eRR ()
  
  and _menhir_run_118 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_IDENT (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | LBRACE ->
          let _menhir_s = MenhirState119 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_120 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | RBRACE ->
              let _v = _menhir_action_096 () in
              _menhir_goto_loption_separated_nonempty_list_COMMA_pattern_field__ _menhir_stack _menhir_lexbuf _menhir_lexer _v
          | _ ->
              _eRR ())
      | COLON_COLON ->
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v_2 ->
              let _startpos_3 = _menhir_lexbuf.Lexing.lex_start_p in
              let _endpos_4 = _menhir_lexbuf.Lexing.lex_curr_p in
              let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v_2, _startpos_3, _endpos_4) in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | LPAREN ->
                  let _startpos_5 = _menhir_lexbuf.Lexing.lex_start_p in
                  let _menhir_stack = MenhirCell0_LPAREN (_menhir_stack, _startpos_5) in
                  let _tok = _menhir_lexer _menhir_lexbuf in
                  (match (_tok : MenhirBasics.token) with
                  | TRUE ->
                      _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState137
                  | STRING_LIT _v_6 ->
                      _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v_6 MenhirState137
                  | MUT ->
                      _menhir_run_074 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState137
                  | LPAREN ->
                      _menhir_run_117 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState137
                  | INT_LIT _v_7 ->
                      _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v_7 MenhirState137
                  | IDENT _v_8 ->
                      _menhir_run_118 _menhir_stack _menhir_lexbuf _menhir_lexer _v_8 MenhirState137
                  | FLOAT_LIT _v_9 ->
                      _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v_9 MenhirState137
                  | FALSE ->
                      _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState137
                  | CHAR_LIT _v_10 ->
                      _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v_10 MenhirState137
                  | RPAREN ->
                      let _v_11 = _menhir_action_094 () in
                      _menhir_run_142 _menhir_stack _menhir_lexbuf _menhir_lexer _v_11
                  | _ ->
                      _eRR ())
              | COLON | COMMA | EQ | FAT_ARROW | IF | IN | RBRACE | RPAREN | SEMICOL ->
                  let _endpos = _endpos_4 in
                  let _v = _menhir_action_135 () in
                  _menhir_goto_option_enum_pattern_args_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_goto_loption_separated_nonempty_list_COMMA_pattern_field__ : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let MenhirCell1_IDENT (_menhir_stack, _menhir_s, name, _startpos_name_, _) = _menhir_stack in
      let (xs, _endpos__4_) = (_v, _endpos) in
      let _v = _menhir_action_169 _endpos__4_ _startpos_name_ name xs in
      _menhir_goto_pattern _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_run_122 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let (_endpos_f_, _startpos_f_, f) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_084 f in
      _menhir_goto_literal _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_f_ _startpos_f_ _v _menhir_s _tok
  
  and _menhir_run_123 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let (_endpos__1_, _startpos__1_) = (_endpos, _startpos) in
      let _v = _menhir_action_088 () in
      _menhir_goto_literal _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_124 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let (_endpos_c_, _startpos_c_, c) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_086 c in
      _menhir_goto_literal _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_c_ _startpos_c_ _v _menhir_s _tok
  
  and _menhir_run_142 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT _menhir_cell0_IDENT _menhir_cell0_LPAREN -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let MenhirCell0_LPAREN (_menhir_stack, _) = _menhir_stack in
      let (xs, _endpos__3_) = (_v, _endpos) in
      let _v = _menhir_action_040 xs in
      let _endpos = _endpos__3_ in
      let (_endpos_x_, x) = (_endpos, _v) in
      let _v = _menhir_action_136 x in
      _menhir_goto_option_enum_pattern_args_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_x_ _v _tok
  
  and _menhir_goto_option_enum_pattern_args_ : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT _menhir_cell0_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell0_IDENT (_menhir_stack, variant, _, _) = _menhir_stack in
      let MenhirCell1_IDENT (_menhir_stack, _menhir_s, ty, _startpos_ty_, _) = _menhir_stack in
      let (_endpos_args_, args) = (_endpos, _v) in
      let _v = _menhir_action_170 _endpos_args_ _startpos_ty_ args ty variant in
      _menhir_goto_pattern _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_run_146 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_LPAREN -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let MenhirCell1_LPAREN (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (xs, _endpos__3_) = (_v, _endpos) in
      let _v = _menhir_action_168 _endpos__3_ _startpos__1_ xs in
      _menhir_goto_pattern _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_run_150 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_DO (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState150 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      _menhir_reduce_204 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _menhir_s _tok
  
  and _menhir_run_153 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_CONTINUE (_menhir_stack, _menhir_s, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | IDENT _v ->
          _menhir_run_101 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState153
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let _v = _menhir_action_119 () in
          _menhir_run_154 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_155 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_BREAK (_menhir_stack, _menhir_s, _startpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | IDENT _v ->
          _menhir_run_101 _menhir_stack _menhir_lexbuf _menhir_lexer _v MenhirState155
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let _v = _menhir_action_119 () in
          _menhir_run_156 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v MenhirState155 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_157 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_BANG (_menhir_stack, _menhir_s, _startpos, _endpos) in
      let _menhir_s = MenhirState157 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_158 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_AMP (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState158 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MUT ->
          let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
          let _menhir_stack = MenhirCell1_MUT (_menhir_stack, _menhir_s, _startpos) in
          let _menhir_s = MenhirState159 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_struct_field : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          let _menhir_stack = MenhirCell1_struct_field (_menhir_stack, _menhir_s, _v) in
          let _menhir_s = MenhirState265 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_114 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | RBRACE ->
          let x = _v in
          let _v = _menhir_action_223 x in
          _menhir_goto_separated_nonempty_list_COMMA_struct_field_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_separated_nonempty_list_COMMA_struct_field_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState265 ->
          _menhir_run_266 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | MenhirState113 ->
          _menhir_run_267 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_266 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_struct_field -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let MenhirCell1_struct_field (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_224 x xs in
      _menhir_goto_separated_nonempty_list_COMMA_struct_field_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_run_267 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let x = _v in
      let _v = _menhir_action_099 x in
      _menhir_goto_loption_separated_nonempty_list_COMMA_struct_field__ _menhir_stack _menhir_lexbuf _menhir_lexer _v
  
  and _menhir_goto_loption_separated_nonempty_list_COMMA_struct_field__ : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let MenhirCell1_IDENT (_menhir_stack, _menhir_s, name, _startpos_name_, _) = _menhir_stack in
      let (xs, _endpos__4_) = (_v, _endpos) in
      let _v = _menhir_action_188 _endpos__4_ _startpos_name_ name xs in
      _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__4_ _startpos_name_ _v _menhir_s _tok
  
  and _menhir_run_271 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_IDENT as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | COLON_COLON ->
          let _menhir_stack = MenhirCell1_IDENT (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState272 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_271 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let (_endpos_x_, x) = (_endpos, _v) in
          let _v = _menhir_action_207 x in
          _menhir_goto_separated_nonempty_list_COLON_COLON_IDENT_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_x_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_separated_nonempty_list_COLON_COLON_IDENT_ : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_IDENT as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState272 ->
          _menhir_run_273 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState270 ->
          _menhir_run_274 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_273 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_IDENT, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_IDENT (_menhir_stack, _menhir_s, x, _, _) = _menhir_stack in
      let (_endpos_xs_, xs) = (_endpos, _v) in
      let _v = _menhir_action_208 x xs in
      _menhir_goto_separated_nonempty_list_COLON_COLON_IDENT_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_xs_ _v _menhir_s _tok
  
  and _menhir_run_274 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_IDENT (_menhir_stack, _menhir_s, first, _startpos_first_, _) = _menhir_stack in
      let (_endpos_rest_, rest) = (_endpos, _v) in
      let _v = _menhir_action_166 _endpos_rest_ _startpos_first_ first rest in
      let (_endpos, _startpos) = (_endpos_rest_, _startpos_first_) in
      let (_endpos_path_, _startpos_path_, path) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_185 path in
      _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_path_ _startpos_path_ _v _menhir_s _tok
  
  and _menhir_run_291 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_LBRACKET -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | RBRACKET ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell1_LBRACKET (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
          let (xs, _endpos__3_) = (_v, _endpos) in
          let _v = _menhir_action_187 _endpos__3_ _startpos__1_ xs in
          _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__3_ _startpos__1_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_293 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_LPAREN -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | RPAREN ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell1_LPAREN (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
          let (xs, _endpos__3_) = (_v, _endpos) in
          let _v = _menhir_action_186 _endpos__3_ _startpos__1_ xs in
          _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__3_ _startpos__1_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_256 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_BREAK, _menhir_box_program) _menhir_cell1_option_IDENT_ -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_option_IDENT_ (_menhir_stack, _, label, _) = _menhir_stack in
      let MenhirCell1_BREAK (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_e_, e) = (_endpos, _v) in
      let _v = _menhir_action_021 _endpos_e_ _startpos__1_ e label in
      let (_endpos, _startpos) = (_endpos_e_, _startpos__1_) in
      let (_endpos__1_, _startpos__1_, _1) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_196 _1 in
      _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_312 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_RETURN -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_RETURN (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_e_, e) = (_endpos, _v) in
      let _v = _menhir_action_202 _endpos_e_ _startpos__1_ e in
      let (_endpos, _startpos) = (_endpos_e_, _startpos__1_) in
      let (_endpos__1_, _startpos__1_, _1) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_195 _1 in
      _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_316 : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_rev_block_items, _menhir_box_program) _menhir_cell1_LET as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_MUT_ (_menhir_stack, _menhir_s, _v, _startpos) in
      match (_tok : MenhirBasics.token) with
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState316
      | STRING_LIT _v_0 ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0 MenhirState316
      | MUT ->
          _menhir_run_074 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState316
      | LPAREN ->
          _menhir_run_117 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState316
      | INT_LIT _v_1 ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v_1 MenhirState316
      | IDENT _v_2 ->
          _menhir_run_118 _menhir_stack _menhir_lexbuf _menhir_lexer _v_2 MenhirState316
      | FLOAT_LIT _v_3 ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v_3 MenhirState316
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState316
      | CHAR_LIT _v_4 ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v_4 MenhirState316
      | _ ->
          _eRR ()
  
  and _menhir_goto_block : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState106 ->
          _menhir_run_107 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState150 ->
          _menhir_run_151 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState260 ->
          _menhir_run_261 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState277 ->
          _menhir_run_278 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState281 ->
          _menhir_run_282 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState284 ->
          _menhir_run_285 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState092 ->
          _menhir_run_330 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState333 ->
          _menhir_run_334 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState374 ->
          _menhir_run_375 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState428 ->
          _menhir_run_433 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_107 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_LOOP -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | END ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell1_LOOP (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
          let (_endpos__3_, body) = (_endpos, _v) in
          let _v = _menhir_action_089 _endpos__3_ _startpos__1_ body in
          let (_endpos, _startpos) = (_endpos__3_, _startpos__1_) in
          let (_endpos__1_, _startpos__1_, _1) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_193 _1 in
          _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_151 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_DO -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | END ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell1_DO (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
          let (_endpos__3_, body) = (_endpos, _v) in
          let _v = _menhir_action_020 _endpos__3_ _startpos__1_ body in
          let (_endpos, _startpos) = (_endpos__3_, _startpos__1_) in
          let (_endpos__1_, _startpos__1_, _1) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_194 _1 in
          _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_261 : type  ttv_stack. ((((ttv_stack, _menhir_box_program) _menhir_cell1_FOR, _menhir_box_program) _menhir_cell1_pattern, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_DO_ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | END ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell1_option_DO_ (_menhir_stack, _, _) = _menhir_stack in
          let MenhirCell1_expr (_menhir_stack, _, iter, _) = _menhir_stack in
          let MenhirCell1_pattern (_menhir_stack, _, p) = _menhir_stack in
          let MenhirCell1_FOR (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
          let (_endpos__7_, body) = (_endpos, _v) in
          let _v = _menhir_action_048 _endpos__7_ _startpos__1_ body iter p in
          let (_endpos, _startpos) = (_endpos__7_, _startpos__1_) in
          let (_endpos__1_, _startpos__1_, _1) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_192 _1 in
          _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_278 : type  ttv_stack. ((((ttv_stack, _menhir_box_program) _menhir_cell1_IF, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_THEN_ as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_block (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | ELSIF ->
          _menhir_run_279 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState278
      | ELSE | END ->
          let _v_0 = _menhir_action_067 () in
          _menhir_run_283 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0 MenhirState278 _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_279 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _menhir_stack = MenhirCell1_ELSIF (_menhir_stack, _menhir_s) in
      let _menhir_s = MenhirState279 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_283 : type  ttv_stack. (((((ttv_stack, _menhir_box_program) _menhir_cell1_IF, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_THEN_, _menhir_box_program) _menhir_cell1_block as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_list_elsif_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | ELSE ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _menhir_s = MenhirState284 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          _menhir_reduce_204 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _menhir_s _tok
      | END ->
          let _v = _menhir_action_133 () in
          _menhir_goto_option_else__ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_goto_option_else__ : type  ttv_stack. (((((ttv_stack, _menhir_box_program) _menhir_cell1_IF, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_THEN_, _menhir_box_program) _menhir_cell1_block, _menhir_box_program) _menhir_cell1_list_elsif_ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | END ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell1_list_elsif_ (_menhir_stack, _, elsifs) = _menhir_stack in
          let MenhirCell1_block (_menhir_stack, _, body) = _menhir_stack in
          let MenhirCell1_option_THEN_ (_menhir_stack, _, _) = _menhir_stack in
          let MenhirCell1_expr (_menhir_stack, _, cond, _) = _menhir_stack in
          let MenhirCell1_IF (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
          let (_endpos__7_, else_) = (_endpos, _v) in
          let _v = _menhir_action_050 _endpos__7_ _startpos__1_ body cond else_ elsifs in
          let (_endpos, _startpos) = (_endpos__7_, _startpos__1_) in
          let (_endpos__1_, _startpos__1_, _1) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_189 _1 in
          _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_282 : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_ELSIF, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_THEN_ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let MenhirCell1_option_THEN_ (_menhir_stack, _, _) = _menhir_stack in
      let MenhirCell1_expr (_menhir_stack, _, cond, _) = _menhir_stack in
      let MenhirCell1_ELSIF (_menhir_stack, _menhir_s) = _menhir_stack in
      let body = _v in
      let _v = _menhir_action_038 body cond in
      let _menhir_stack = MenhirCell1_elsif (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | ELSIF ->
          _menhir_run_279 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState289
      | ELSE | END ->
          let _v_0 = _menhir_action_067 () in
          _menhir_run_290 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0 _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_290 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_elsif -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let MenhirCell1_elsif (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_068 x xs in
      _menhir_goto_list_elsif_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_goto_list_elsif_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState278 ->
          _menhir_run_283 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState289 ->
          _menhir_run_290 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_285 : type  ttv_stack. (((((ttv_stack, _menhir_box_program) _menhir_cell1_IF, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_THEN_, _menhir_box_program) _menhir_cell1_block, _menhir_box_program) _menhir_cell1_list_elsif_ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let body = _v in
      let _v = _menhir_action_037 body in
      let x = _v in
      let _v = _menhir_action_134 x in
      _menhir_goto_option_else__ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
  
  and _menhir_run_330 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_UNSAFE -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | END ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell1_UNSAFE (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
          let (_endpos__3_, body) = (_endpos, _v) in
          let _v = _menhir_action_271 _endpos__3_ _startpos__1_ body in
          let (_endpos, _startpos) = (_endpos__3_, _startpos__1_) in
          let (_endpos__1_, _startpos__1_, _1) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_198 _1 in
          _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_334 : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_WHILE, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_DO_ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | END ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell1_option_DO_ (_menhir_stack, _, _) = _menhir_stack in
          let MenhirCell1_expr (_menhir_stack, _, cond, _) = _menhir_stack in
          let MenhirCell1_WHILE (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
          let (_endpos__5_, body) = (_endpos, _v) in
          let _v = _menhir_action_289 _endpos__5_ _startpos__1_ body cond in
          let (_endpos, _startpos) = (_endpos__5_, _startpos__1_) in
          let (_endpos__1_, _startpos__1_, _1) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_191 _1 in
          _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_375 : type  ttv_stack. (((((((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_cell1_option_where_clause_, _menhir_box_program) _menhir_cell1_list_contract_, _menhir_box_program) _menhir_cell1_list_requires_clause_ _menhir_cell0_option_effect_clause_ _menhir_cell0_option_budget_clause_ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | END ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell0_option_budget_clause_ (_menhir_stack, budget) = _menhir_stack in
          let MenhirCell0_option_effect_clause_ (_menhir_stack, effects) = _menhir_stack in
          let MenhirCell1_list_requires_clause_ (_menhir_stack, _, requires_list) = _menhir_stack in
          let MenhirCell1_list_contract_ (_menhir_stack, _, contracts) = _menhir_stack in
          let MenhirCell1_option_where_clause_ (_menhir_stack, _, where_clause) = _menhir_stack in
          let MenhirCell1_option_return_type_ (_menhir_stack, _, ret) = _menhir_stack in
          let MenhirCell0_RPAREN (_menhir_stack, _) = _menhir_stack in
          let MenhirCell1_loption_separated_nonempty_list_COMMA_param__ (_menhir_stack, _, xs) = _menhir_stack in
          let MenhirCell0_LPAREN (_menhir_stack, _) = _menhir_stack in
          let MenhirCell1_option_type_params_ (_menhir_stack, _, type_params) = _menhir_stack in
          let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
          let MenhirCell0_DEF (_menhir_stack, _) = _menhir_stack in
          let MenhirCell1_visibility (_menhir_stack, _menhir_s, vis, _startpos_vis_) = _menhir_stack in
          let (body, _endpos__15_) = (_v, _endpos) in
          let _v = _menhir_action_049 _endpos__15_ _startpos_vis_ body budget contracts effects name requires_list ret type_params vis where_clause xs in
          _menhir_goto_function_def _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_function_def : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState064 ->
          _menhir_run_385 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState383 ->
          _menhir_run_385 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState000 ->
          _menhir_run_463 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState452 ->
          _menhir_run_463 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState460 ->
          _menhir_run_463 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_385 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let f = _v in
      let _v = _menhir_action_052 f in
      _menhir_goto_impl_item _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_goto_impl_item : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_impl_item (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | TYPE ->
          _menhir_run_065 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState383
      | PUB ->
          _menhir_run_001 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState383
      | END ->
          let _v_0 = _menhir_action_071 () in
          _menhir_run_384 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0
      | DEF ->
          let _v_1 = _menhir_action_286 () in
          _menhir_run_069 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_1 MenhirState383 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_384 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_impl_item -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let MenhirCell1_impl_item (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_072 x xs in
      _menhir_goto_list_impl_item_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_goto_list_impl_item_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState064 ->
          _menhir_run_381 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | MenhirState383 ->
          _menhir_run_384 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_463 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let f = _v in
      let _v = _menhir_action_056 f in
      _menhir_goto_item _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_433 : type  ttv_stack. (((((ttv_stack, _menhir_box_program) _menhir_cell1_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_ as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | END ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let _1 = _v in
          let _v = _menhir_action_247 _1 in
          let x = _v in
          let _v = _menhir_action_148 x in
          _menhir_goto_option_trait_method_body_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_option_trait_method_body_ : type  ttv_stack. (((((ttv_stack, _menhir_box_program) _menhir_cell1_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_ as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_trait_method_body_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | END ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let (_endpos_x_, x) = (_endpos, ()) in
          let _ = _menhir_action_116 x in
          _menhir_goto_option_END_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_x_ _tok
      | DEF | TYPE ->
          let _ = _menhir_action_115 () in
          _menhir_goto_option_END_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_option_END_ : type  ttv_stack. (((((ttv_stack, _menhir_box_program) _menhir_cell1_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_cell1_option_trait_method_body_ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _tok ->
      let MenhirCell1_option_trait_method_body_ (_menhir_stack, _, body) = _menhir_stack in
      let MenhirCell1_option_return_type_ (_menhir_stack, _, ret) = _menhir_stack in
      let MenhirCell0_RPAREN (_menhir_stack, _) = _menhir_stack in
      let MenhirCell1_loption_separated_nonempty_list_COMMA_param__ (_menhir_stack, _, xs) = _menhir_stack in
      let MenhirCell0_LPAREN (_menhir_stack, _) = _menhir_stack in
      let MenhirCell1_option_type_params_ (_menhir_stack, _, type_params) = _menhir_stack in
      let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
      let MenhirCell1_DEF (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let _endpos__9_ = _endpos in
      let _v = _menhir_action_246 _endpos__9_ _startpos__1_ body name ret type_params xs in
      let f = _v in
      let _v = _menhir_action_244 f in
      _menhir_goto_trait_item _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_run_237 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_postfix_expr _menhir_cell0_LPAREN -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | RPAREN ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell0_LPAREN (_menhir_stack, _) = _menhir_stack in
          let MenhirCell1_postfix_expr (_menhir_stack, _menhir_s, e, _startpos_e_, _) = _menhir_stack in
          let (xs, _endpos__4_) = (_v, _endpos) in
          let _v = _menhir_action_174 _endpos__4_ _startpos_e_ e xs in
          _menhir_goto_postfix_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__4_ _startpos_e_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_250 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_postfix_expr _menhir_cell0_IDENT _menhir_cell0_LPAREN -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | RPAREN ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell0_LPAREN (_menhir_stack, _) = _menhir_stack in
          let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
          let MenhirCell1_postfix_expr (_menhir_stack, _menhir_s, e, _startpos_e_, _) = _menhir_stack in
          let (xs, _endpos__6_) = (_v, _endpos) in
          let _v = _menhir_action_175 _endpos__6_ _startpos_e_ e name xs in
          _menhir_goto_postfix_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__6_ _startpos_e_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_unary_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState159 ->
          _menhir_run_162 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState090 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState091 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState093 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState099 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState104 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState105 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState111 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState115 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState149 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState156 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState170 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState188 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState190 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState192 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState196 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState198 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState200 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState203 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState205 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState207 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState209 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState213 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState215 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState218 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState223 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState225 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState227 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState229 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState231 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState233 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState235 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState243 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState279 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState299 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState302 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState322 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState341 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState344 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState490 ->
          _menhir_run_168 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState173 ->
          _menhir_run_174 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState183 ->
          _menhir_run_184 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState185 ->
          _menhir_run_186 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState158 ->
          _menhir_run_254 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState157 ->
          _menhir_run_255 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState103 ->
          _menhir_run_311 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState097 ->
          _menhir_run_313 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState095 ->
          _menhir_run_314 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_162 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_AMP, _menhir_box_program) _menhir_cell1_MUT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_MUT (_menhir_stack, _, _) = _menhir_stack in
      let MenhirCell1_AMP (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_e_, e) = (_endpos, _v) in
      let _v = _menhir_action_268 _endpos_e_ _startpos__1_ e in
      _menhir_goto_unary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_168 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      let (_endpos_e_, _startpos_e_, e) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_110 e in
      _menhir_goto_multiplicative_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos_e_ _v _menhir_s _tok
  
  and _menhir_goto_multiplicative_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState090 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState091 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState093 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState099 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState104 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState105 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState111 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState115 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState149 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState156 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState170 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState192 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState196 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState198 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState200 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState203 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState205 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState207 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState209 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState213 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState215 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState218 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState223 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState225 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState227 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState229 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState231 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState233 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState235 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState243 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState279 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState299 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState302 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState322 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState341 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState344 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState490 ->
          _menhir_run_172 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState188 ->
          _menhir_run_189 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState190 ->
          _menhir_run_191 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_172 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | STAR ->
          let _menhir_stack = MenhirCell1_multiplicative_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_173 _menhir_stack _menhir_lexbuf _menhir_lexer
      | SLASH ->
          let _menhir_stack = MenhirCell1_multiplicative_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_183 _menhir_stack _menhir_lexbuf _menhir_lexer
      | PERCENT ->
          let _menhir_stack = MenhirCell1_multiplicative_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_185 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH_EQ | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let (_endpos_e_, _startpos_e_, e) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_003 e in
          _menhir_goto_additive_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos_e_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_173 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_multiplicative_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell0_STAR (_menhir_stack, _startpos, _endpos) in
      let _menhir_s = MenhirState173 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_183 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_multiplicative_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState183 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_185 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_multiplicative_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState185 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_additive_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState170 ->
          _menhir_run_187 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState192 ->
          _menhir_run_193 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState090 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState091 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState093 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState099 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState104 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState105 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState111 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState115 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState149 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState156 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState196 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState198 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState200 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState203 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState205 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState207 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState209 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState213 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState215 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState218 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState223 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState225 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState227 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState229 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState231 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState233 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState235 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState243 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState279 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState299 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState302 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState322 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState341 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState344 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState490 ->
          _menhir_run_202 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_187 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_shift_expr as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | PLUS ->
          let _menhir_stack = MenhirCell1_additive_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_188 _menhir_stack _menhir_lexbuf _menhir_lexer
      | MINUS ->
          let _menhir_stack = MenhirCell1_additive_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_190 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell1_shift_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_238 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_shift_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_188 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_additive_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState188 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_190 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_additive_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell0_MINUS (_menhir_stack, _startpos) in
      let _menhir_s = MenhirState190 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_shift_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState090 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState091 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState093 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState099 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState104 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState105 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState111 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState115 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState149 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState156 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState196 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState198 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState209 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState213 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState215 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState218 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState223 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState225 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState227 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState229 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState231 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState233 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState235 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState243 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState279 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState299 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState302 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState322 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState341 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState344 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState490 ->
          _menhir_run_169 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState200 ->
          _menhir_run_201 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState203 ->
          _menhir_run_204 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState205 ->
          _menhir_run_206 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState207 ->
          _menhir_run_208 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_169 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | SHR ->
          let _menhir_stack = MenhirCell1_shift_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_170 _menhir_stack _menhir_lexbuf _menhir_lexer
      | SHL ->
          let _menhir_stack = MenhirCell1_shift_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_192 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let (_endpos_e_, _startpos_e_, e) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_028 e in
          _menhir_goto_comparison_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos_e_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_170 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_shift_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState170 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_192 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_shift_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState192 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_comparison_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState198 ->
          _menhir_run_199 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState209 ->
          _menhir_run_210 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState090 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState091 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState093 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState099 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState104 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState105 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState111 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState115 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState149 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState156 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState196 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState213 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState215 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState218 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState223 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState225 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState227 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState229 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState231 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState233 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState235 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState243 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState279 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState299 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState302 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState322 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState341 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState344 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState490 ->
          _menhir_run_211 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_199 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_equality_expr as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | LT_EQ ->
          let _menhir_stack = MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_200 _menhir_stack _menhir_lexbuf _menhir_lexer
      | LT ->
          let _menhir_stack = MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_203 _menhir_stack _menhir_lexbuf _menhir_lexer
      | GT_EQ ->
          let _menhir_stack = MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_205 _menhir_stack _menhir_lexbuf _menhir_lexer
      | GT ->
          let _menhir_stack = MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_207 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell1_equality_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_041 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_equality_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_200 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_comparison_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState200 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_203 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_comparison_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState203 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_205 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_comparison_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState205 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_207 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_comparison_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState207 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_equality_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState090 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState091 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState093 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState099 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState104 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState105 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState111 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState115 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState149 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState156 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState196 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState213 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState218 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState223 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState225 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState227 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState229 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState231 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState233 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState235 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState243 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState279 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState299 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState302 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState322 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState341 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState344 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState490 ->
          _menhir_run_197 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState215 ->
          _menhir_run_216 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_197 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | EQ_EQ ->
          let _menhir_stack = MenhirCell1_equality_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_198 _menhir_stack _menhir_lexbuf _menhir_lexer
      | BANG_EQ ->
          let _menhir_stack = MenhirCell1_equality_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_209 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let (_endpos_e_, _startpos_e_, e) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_014 e in
          _menhir_goto_bitand_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos_e_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_198 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_equality_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState198 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_209 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_equality_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState209 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_bitand_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState213 ->
          _menhir_run_214 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState090 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState091 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState093 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState099 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState104 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState105 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState111 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState115 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState149 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState156 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState196 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState218 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState223 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState225 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState227 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState229 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState231 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState233 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState235 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState243 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState279 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState299 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState302 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState322 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState341 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState344 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState490 ->
          _menhir_run_220 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_214 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_bitxor_expr as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | AMP ->
          let _menhir_stack = MenhirCell1_bitand_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_215 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell1_bitxor_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_017 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_bitxor_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_215 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_bitand_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell0_AMP (_menhir_stack, _startpos) in
      let _menhir_s = MenhirState215 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_bitxor_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState090 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState091 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState093 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState099 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState104 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState105 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState111 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState115 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState149 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState156 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState196 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState223 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState225 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState227 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState229 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState231 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState233 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState235 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState243 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState279 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState299 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState302 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState322 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState341 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState344 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState490 ->
          _menhir_run_212 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState218 ->
          _menhir_run_219 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_212 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | CARET ->
          let _menhir_stack = MenhirCell1_bitxor_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_213 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let (_endpos_e_, _startpos_e_, e) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_016 e in
          _menhir_goto_bitor_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos_e_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_213 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_bitxor_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState213 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_bitor_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState090 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState091 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState093 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState099 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState104 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState105 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState111 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState115 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState149 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState156 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState196 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState225 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState227 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState229 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState231 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState233 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState235 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState243 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState279 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState299 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState302 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState322 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState341 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState344 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState490 ->
          _menhir_run_217 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState223 ->
          _menhir_run_224 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_217 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | PIPE ->
          let _menhir_stack = MenhirCell1_bitor_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_218 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let (_endpos_e_, _startpos_e_, e) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_005 e in
          _menhir_goto_and_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos_e_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_218 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_bitor_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState218 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_and_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState090 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState091 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState093 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState099 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState104 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState105 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState111 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState115 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState149 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState156 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState196 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState225 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState227 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState231 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState233 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState235 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState243 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState279 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState299 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState302 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState322 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState341 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState344 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState490 ->
          _menhir_run_222 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | MenhirState229 ->
          _menhir_run_230 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_222 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | AMP_AMP ->
          let _menhir_stack = MenhirCell1_and_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_223 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let (_endpos_e_, _startpos_e_, e) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_164 e in
          _menhir_goto_or_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos_e_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_223 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_and_expr -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _menhir_s = MenhirState223 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_or_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | STAR_EQ ->
          let _menhir_stack = MenhirCell1_or_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState196 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | SLASH_EQ ->
          let _menhir_stack = MenhirCell1_or_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState225 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | PLUS_EQ ->
          let _menhir_stack = MenhirCell1_or_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState227 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | PIPE_PIPE ->
          let _menhir_stack = MenhirCell1_or_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState229 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | PERCENT_EQ ->
          let _menhir_stack = MenhirCell1_or_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState231 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | MINUS_EQ ->
          let _menhir_stack = MenhirCell1_or_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState233 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | EQ ->
          let _menhir_stack = MenhirCell1_or_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState235 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MODULE | NEXT | PERCENT | PIPE | PLUS | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | STAR | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let (_endpos_e_, e) = (_endpos, _v) in
          let _v = _menhir_action_012 e in
          _menhir_goto_assignment_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_goto_assignment_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState196 ->
          _menhir_run_221 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState225 ->
          _menhir_run_226 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState227 ->
          _menhir_run_228 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState231 ->
          _menhir_run_232 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState233 ->
          _menhir_run_234 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState235 ->
          _menhir_run_236 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState090 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState091 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState093 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState099 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState104 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState105 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState111 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState115 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState149 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState156 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState243 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState279 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState299 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState302 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState322 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState341 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState344 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState490 ->
          _menhir_run_242 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_221 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_or_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_or_expr (_menhir_stack, _menhir_s, lhs, _startpos_lhs_, _) = _menhir_stack in
      let (_endpos_rhs_, rhs) = (_endpos, _v) in
      let _v = _menhir_action_009 _endpos_rhs_ _startpos_lhs_ lhs rhs in
      _menhir_goto_assignment_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_rhs_ _v _menhir_s _tok
  
  and _menhir_run_226 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_or_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_or_expr (_menhir_stack, _menhir_s, lhs, _startpos_lhs_, _) = _menhir_stack in
      let (_endpos_rhs_, rhs) = (_endpos, _v) in
      let _v = _menhir_action_010 _endpos_rhs_ _startpos_lhs_ lhs rhs in
      _menhir_goto_assignment_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_rhs_ _v _menhir_s _tok
  
  and _menhir_run_228 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_or_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_or_expr (_menhir_stack, _menhir_s, lhs, _startpos_lhs_, _) = _menhir_stack in
      let (_endpos_rhs_, rhs) = (_endpos, _v) in
      let _v = _menhir_action_007 _endpos_rhs_ _startpos_lhs_ lhs rhs in
      _menhir_goto_assignment_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_rhs_ _v _menhir_s _tok
  
  and _menhir_run_232 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_or_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_or_expr (_menhir_stack, _menhir_s, lhs, _startpos_lhs_, _) = _menhir_stack in
      let (_endpos_rhs_, rhs) = (_endpos, _v) in
      let _v = _menhir_action_011 _endpos_rhs_ _startpos_lhs_ lhs rhs in
      _menhir_goto_assignment_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_rhs_ _v _menhir_s _tok
  
  and _menhir_run_234 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_or_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_or_expr (_menhir_stack, _menhir_s, lhs, _startpos_lhs_, _) = _menhir_stack in
      let (_endpos_rhs_, rhs) = (_endpos, _v) in
      let _v = _menhir_action_008 _endpos_rhs_ _startpos_lhs_ lhs rhs in
      _menhir_goto_assignment_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_rhs_ _v _menhir_s _tok
  
  and _menhir_run_236 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_or_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_or_expr (_menhir_stack, _menhir_s, lhs, _startpos_lhs_, _) = _menhir_stack in
      let (_endpos_rhs_, rhs) = (_endpos, _v) in
      let _v = _menhir_action_006 _endpos_rhs_ _startpos_lhs_ lhs rhs in
      _menhir_goto_assignment_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_rhs_ _v _menhir_s _tok
  
  and _menhir_run_242 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let (_endpos_e_, e) = (_endpos, _v) in
      let _v = _menhir_action_044 e in
      _menhir_goto_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _v _menhir_s _tok
  
  and _menhir_goto_expr : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState105 ->
          _menhir_run_239 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_239 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_239 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_239 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_239 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState243 ->
          _menhir_run_244 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState099 ->
          _menhir_run_257 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState156 ->
          _menhir_run_257 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState149 ->
          _menhir_run_258 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState115 ->
          _menhir_run_263 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState111 ->
          _menhir_run_275 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState279 ->
          _menhir_run_280 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState104 ->
          _menhir_run_295 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState299 ->
          _menhir_run_300 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState302 ->
          _menhir_run_303 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState322 ->
          _menhir_run_323 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState093 ->
          _menhir_run_328 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState091 ->
          _menhir_run_332 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState090 ->
          _menhir_run_336 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState341 ->
          _menhir_run_342 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState344 ->
          _menhir_run_345 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState490 ->
          _menhir_run_491 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_239 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          let _menhir_stack = MenhirCell1_expr (_menhir_stack, _menhir_s, _v, _endpos) in
          let _menhir_s = MenhirState240 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | RBRACKET | RPAREN ->
          let x = _v in
          let _v = _menhir_action_213 x in
          _menhir_goto_separated_nonempty_list_COMMA_expr_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_separated_nonempty_list_COMMA_expr_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState105 ->
          _menhir_run_194 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState109 ->
          _menhir_run_194 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState167 ->
          _menhir_run_194 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState249 ->
          _menhir_run_194 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState240 ->
          _menhir_run_241 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_194 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let x = _v in
      let _v = _menhir_action_091 x in
      _menhir_goto_loption_separated_nonempty_list_COMMA_expr__ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_goto_loption_separated_nonempty_list_COMMA_expr__ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState167 ->
          _menhir_run_237 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState249 ->
          _menhir_run_250 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState109 ->
          _menhir_run_291 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | MenhirState105 ->
          _menhir_run_293 _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_241 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_expr -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let MenhirCell1_expr (_menhir_stack, _menhir_s, x, _) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_214 x xs in
      _menhir_goto_separated_nonempty_list_COMMA_expr_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_run_244 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_postfix_expr _menhir_cell0_LBRACKET -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | RBRACKET ->
          let _endpos_0 = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell0_LBRACKET (_menhir_stack, _) = _menhir_stack in
          let MenhirCell1_postfix_expr (_menhir_stack, _menhir_s, e, _startpos_e_, _) = _menhir_stack in
          let (_endpos__4_, idx) = (_endpos_0, _v) in
          let _v = _menhir_action_178 _endpos__4_ _startpos_e_ e idx in
          _menhir_goto_postfix_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__4_ _startpos_e_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_257 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let (_endpos_x_, x) = (_endpos, _v) in
      let _v = _menhir_action_138 x in
      _menhir_goto_option_expr_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_x_ _v _menhir_s _tok
  
  and _menhir_goto_option_expr_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState156 ->
          _menhir_run_256 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState099 ->
          _menhir_run_312 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_258 : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_FOR, _menhir_box_program) _menhir_cell1_pattern as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_expr (_menhir_stack, _menhir_s, _v, _endpos) in
      match (_tok : MenhirBasics.token) with
      | DO ->
          _menhir_run_259 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState258
      | AMP | BANG | BREAK | CHAR_LIT _ | CONTINUE | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v_0 = _menhir_action_113 () in
          _menhir_run_260 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 MenhirState258 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_259 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_expr as 'stack) -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let x = () in
      let _v = _menhir_action_114 x in
      _menhir_goto_option_DO_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_goto_option_DO_ : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_expr as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState258 ->
          _menhir_run_260 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState295 ->
          _menhir_run_296 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
      | MenhirState332 ->
          _menhir_run_333 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_260 : type  ttv_stack. ((((ttv_stack, _menhir_box_program) _menhir_cell1_FOR, _menhir_box_program) _menhir_cell1_pattern, _menhir_box_program) _menhir_cell1_expr as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_DO_ (_menhir_stack, _menhir_s, _v) in
      let _menhir_s = MenhirState260 in
      let _v = _menhir_action_204 () in
      _menhir_goto_rev_block_items _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _endpos _v _menhir_s _tok
  
  and _menhir_run_296 : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_MATCH, _menhir_box_program) _menhir_cell1_expr as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_DO_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | WHEN ->
          _menhir_run_297 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState296
      | END ->
          let _v_0 = _menhir_action_075 () in
          _menhir_run_309 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0
      | _ ->
          _eRR ()
  
  and _menhir_run_297 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_WHEN (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState297 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | MUT ->
          _menhir_run_074 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_117 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IDENT _v ->
          _menhir_run_118 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_309 : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_MATCH, _menhir_box_program) _menhir_cell1_expr, _menhir_box_program) _menhir_cell1_option_DO_ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let MenhirCell1_option_DO_ (_menhir_stack, _, _) = _menhir_stack in
      let MenhirCell1_expr (_menhir_stack, _, e, _) = _menhir_stack in
      let MenhirCell1_MATCH (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos__5_, arms) = (_endpos, _v) in
      let _v = _menhir_action_103 _endpos__5_ _startpos__1_ arms e in
      let (_endpos, _startpos) = (_endpos__5_, _startpos__1_) in
      let (_endpos__1_, _startpos__1_, _1) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_190 _1 in
      _menhir_goto_primary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__1_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_333 : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_WHILE, _menhir_box_program) _menhir_cell1_expr as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_DO_ (_menhir_stack, _menhir_s, _v) in
      let _menhir_s = MenhirState333 in
      let _v = _menhir_action_204 () in
      _menhir_goto_rev_block_items _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _endpos _v _menhir_s _tok
  
  and _menhir_run_263 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let MenhirCell1_IDENT (_menhir_stack, _menhir_s, name, _, _) = _menhir_stack in
      let e = _v in
      let _v = _menhir_action_241 e name in
      _menhir_goto_struct_field _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_run_275 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_IF as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_expr (_menhir_stack, _menhir_s, _v, _endpos) in
      match (_tok : MenhirBasics.token) with
      | THEN ->
          _menhir_run_276 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState275
      | AMP | BANG | BREAK | CHAR_LIT _ | CONTINUE | DO | ELSE | ELSIF | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v_0 = _menhir_action_125 () in
          _menhir_run_277 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 MenhirState275 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_276 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_expr as 'stack) -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let x = () in
      let _v = _menhir_action_126 x in
      _menhir_goto_option_THEN_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_goto_option_THEN_ : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_expr as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState275 ->
          _menhir_run_277 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState280 ->
          _menhir_run_281 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_277 : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_IF, _menhir_box_program) _menhir_cell1_expr as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_THEN_ (_menhir_stack, _menhir_s, _v) in
      let _menhir_s = MenhirState277 in
      let _v = _menhir_action_204 () in
      _menhir_goto_rev_block_items _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _endpos _v _menhir_s _tok
  
  and _menhir_run_281 : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_ELSIF, _menhir_box_program) _menhir_cell1_expr as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_THEN_ (_menhir_stack, _menhir_s, _v) in
      let _menhir_s = MenhirState281 in
      let _v = _menhir_action_204 () in
      _menhir_goto_rev_block_items _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _endpos _v _menhir_s _tok
  
  and _menhir_run_280 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_ELSIF as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_expr (_menhir_stack, _menhir_s, _v, _endpos) in
      match (_tok : MenhirBasics.token) with
      | THEN ->
          _menhir_run_276 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState280
      | AMP | BANG | BREAK | CHAR_LIT _ | CONTINUE | DO | ELSE | ELSIF | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v_0 = _menhir_action_125 () in
          _menhir_run_281 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 MenhirState280 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_295 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_MATCH as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_expr (_menhir_stack, _menhir_s, _v, _endpos) in
      match (_tok : MenhirBasics.token) with
      | DO ->
          _menhir_run_259 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState295
      | END | WHEN ->
          let _v_0 = _menhir_action_113 () in
          _menhir_run_296 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0 MenhirState295 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_300 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_WHEN, _menhir_box_program) _menhir_cell1_pattern _menhir_cell0_IF -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let MenhirCell0_IF (_menhir_stack, _) = _menhir_stack in
      let e = _v in
      let _v = _menhir_action_104 e in
      let x = _v in
      let _v = _menhir_action_144 x in
      _menhir_goto_option_match_guard_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
  
  and _menhir_goto_option_match_guard_ : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_WHEN, _menhir_box_program) _menhir_cell1_pattern -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let _menhir_stack = MenhirCell0_option_match_guard_ (_menhir_stack, _v) in
      match (_tok : MenhirBasics.token) with
      | FAT_ARROW ->
          let _menhir_s = MenhirState302 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_303 : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_WHEN, _menhir_box_program) _menhir_cell1_pattern _menhir_cell0_option_match_guard_ as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_expr (_menhir_stack, _menhir_s, _v, _endpos) in
      match (_tok : MenhirBasics.token) with
      | SEMICOL ->
          let _endpos_0 = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let (_endpos_x_, x) = (_endpos_0, ()) in
          let _ = _menhir_action_124 x in
          _menhir_goto_option_SEMICOL_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_x_ _tok
      | END | WHEN ->
          let _ = _menhir_action_123 () in
          _menhir_goto_option_SEMICOL_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_option_SEMICOL_ : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_WHEN, _menhir_box_program) _menhir_cell1_pattern _menhir_cell0_option_match_guard_, _menhir_box_program) _menhir_cell1_expr -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _tok ->
      let MenhirCell1_expr (_menhir_stack, _, body, _) = _menhir_stack in
      let MenhirCell0_option_match_guard_ (_menhir_stack, guard) = _menhir_stack in
      let MenhirCell1_pattern (_menhir_stack, _, p) = _menhir_stack in
      let MenhirCell1_WHEN (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let _endpos__6_ = _endpos in
      let _v = _menhir_action_102 _endpos__6_ _startpos__1_ body guard p in
      let _menhir_stack = MenhirCell1_match_arm (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | WHEN ->
          _menhir_run_297 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState307
      | END ->
          let _v_0 = _menhir_action_075 () in
          _menhir_run_308 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0
      | _ ->
          _eRR ()
  
  and _menhir_run_308 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_match_arm -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let MenhirCell1_match_arm (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_076 x xs in
      _menhir_goto_list_match_arm_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_goto_list_match_arm_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState307 ->
          _menhir_run_308 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | MenhirState296 ->
          _menhir_run_309 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_323 : type  ttv_stack. ((((ttv_stack, _menhir_box_program) _menhir_cell1_rev_block_items, _menhir_box_program) _menhir_cell1_LET, _menhir_box_program) _menhir_cell1_option_MUT_, _menhir_box_program) _menhir_cell1_pattern _menhir_cell0_option_type_annotation_ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let e = _v in
      let _v = _menhir_action_055 e in
      let x = _v in
      let _v = _menhir_action_142 x in
      _menhir_goto_option_initializer__ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
  
  and _menhir_goto_option_initializer__ : type  ttv_stack. ((((ttv_stack, _menhir_box_program) _menhir_cell1_rev_block_items, _menhir_box_program) _menhir_cell1_LET, _menhir_box_program) _menhir_cell1_option_MUT_, _menhir_box_program) _menhir_cell1_pattern _menhir_cell0_option_type_annotation_ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      match (_tok : MenhirBasics.token) with
      | SEMICOL ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let MenhirCell0_option_type_annotation_ (_menhir_stack, t) = _menhir_stack in
          let MenhirCell1_pattern (_menhir_stack, _, p) = _menhir_stack in
          let MenhirCell1_option_MUT_ (_menhir_stack, _, m, _) = _menhir_stack in
          let MenhirCell1_LET (_menhir_stack, _) = _menhir_stack in
          let MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, prev, _startpos_prev_, _) = _menhir_stack in
          let (_endpos__7_, init) = (_endpos, _v) in
          let _v = _menhir_action_205 _endpos__7_ _startpos_prev_ init m p prev t in
          _menhir_goto_rev_block_items _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__7_ _startpos_prev_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_328 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_rev_block_items -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      match (_tok : MenhirBasics.token) with
      | SEMICOL ->
          let _endpos_0 = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let (_endpos__2_, e) = (_endpos_0, _v) in
          let _v = _menhir_action_045 e in
          _menhir_goto_expr_with_semi _menhir_stack _menhir_lexbuf _menhir_lexer _endpos__2_ _v _tok
      | AMP | BANG | BREAK | CHAR_LIT _ | CONTINUE | DO | ELSE | ELSIF | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let (_endpos_e_, e) = (_endpos, _v) in
          let _v = _menhir_action_046 e in
          _menhir_goto_expr_with_semi _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_expr_with_semi : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_rev_block_items -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_rev_block_items (_menhir_stack, _menhir_s, prev, _startpos_prev_, _) = _menhir_stack in
      let (_endpos_e_, e) = (_endpos, _v) in
      let _v = _menhir_action_206 _endpos_e_ _startpos_prev_ e prev in
      _menhir_goto_rev_block_items _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos_prev_ _v _menhir_s _tok
  
  and _menhir_run_332 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_WHILE as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_expr (_menhir_stack, _menhir_s, _v, _endpos) in
      match (_tok : MenhirBasics.token) with
      | DO ->
          _menhir_run_259 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState332
      | AMP | BANG | BREAK | CHAR_LIT _ | CONTINUE | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v_0 = _menhir_action_113 () in
          _menhir_run_333 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 MenhirState332 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_336 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_PRE as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_expr (_menhir_stack, _menhir_s, _v, _endpos) in
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          _menhir_run_337 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState336
      | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | CONTINUE | DO | EFFECT | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | POST | PRE | REQUIRES | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v_0 = _menhir_action_129 () in
          _menhir_run_339 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_337 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_expr as 'stack) -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | STRING_LIT _v ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let (_endpos_s_, s) = (_endpos, _v) in
          let _v = _menhir_action_035 s in
          let _endpos = _endpos_s_ in
          let (_endpos_x_, x) = (_endpos, _v) in
          let _v = _menhir_action_130 x in
          _menhir_goto_option_contract_msg_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_x_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_option_contract_msg_ : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_expr as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState336 ->
          _menhir_run_339 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState342 ->
          _menhir_run_343 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState345 ->
          _menhir_run_346 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_339 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_PRE, _menhir_box_program) _menhir_cell1_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_expr (_menhir_stack, _, e, _) = _menhir_stack in
      let MenhirCell1_PRE (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_msg_, msg) = (_endpos, _v) in
      let _v = _menhir_action_032 _endpos_msg_ _startpos__1_ e msg in
      _menhir_goto_contract _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_goto_contract : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_contract (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | PRE ->
          _menhir_run_090 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState379
      | POST ->
          _menhir_run_341 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState379
      | INVARIANT ->
          _menhir_run_344 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState379
      | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | CONTINUE | DO | EFFECT | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | REQUIRES | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v_0 = _menhir_action_065 () in
          _menhir_run_380 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_090 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_PRE (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState090 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_341 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_POST (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState341 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_344 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _menhir_stack = MenhirCell1_INVARIANT (_menhir_stack, _menhir_s, _startpos) in
      let _menhir_s = MenhirState344 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | WHILE ->
          _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | UNSAFE ->
          _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TRUE ->
          _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | TILDE ->
          _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | STRING_LIT _v ->
          _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | STAR ->
          _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | SELF_LOWER ->
          _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | RETURN ->
          _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | NEXT ->
          _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MINUS ->
          _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | MATCH ->
          _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LOOP ->
          _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LBRACKET ->
          _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | INT_LIT _v ->
          _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | IF ->
          _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FOR ->
          _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | FLOAT_LIT _v ->
          _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FALSE ->
          _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | DO ->
          _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CONTINUE ->
          _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | CHAR_LIT _v ->
          _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | BREAK ->
          _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_380 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_contract -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_contract (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_066 x xs in
      _menhir_goto_list_contract_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_goto_list_contract_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState089 ->
          _menhir_run_347 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState379 ->
          _menhir_run_380 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_347 : type  ttv_stack. ((((((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_cell1_option_where_clause_ as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_list_contract_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | REQUIRES ->
          _menhir_run_348 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState347
      | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | CONTINUE | DO | EFFECT | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v_0 = _menhir_action_077 () in
          _menhir_run_358 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 MenhirState347 _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_348 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_REQUIRES (_menhir_stack, _menhir_s) in
      let _menhir_s = MenhirState348 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | BANG ->
          _menhir_run_349 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _ ->
          _menhir_reduce_111 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_349 : type  ttv_stack. ttv_stack -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let (_startpos_x_, x) = (_startpos, ()) in
      let _v = _menhir_action_112 x in
      _menhir_goto_option_BANG_ _menhir_stack _menhir_lexbuf _menhir_lexer _startpos_x_ _v _menhir_s _tok
  
  and _menhir_goto_option_BANG_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | IDENT _v_0 ->
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          let (_endpos_cap_, cap, _startpos_neg_, neg) = (_endpos, _v_0, _startpos, _v) in
          let _v = _menhir_action_201 _endpos_cap_ _startpos_neg_ cap neg in
          (match (_tok : MenhirBasics.token) with
          | COMMA ->
              let _menhir_stack = MenhirCell1_requires_item (_menhir_stack, _menhir_s, _v) in
              let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
              let _menhir_s = MenhirState352 in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | BANG ->
                  _menhir_run_349 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | IDENT _ ->
                  _menhir_reduce_111 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _menhir_s _tok
              | _ ->
                  _eRR ())
          | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | CONTINUE | DO | EFFECT | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | REQUIRES | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
              let x = _v in
              let _v = _menhir_action_221 x in
              _menhir_goto_separated_nonempty_list_COMMA_requires_item_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_reduce_111 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _menhir_s _tok ->
      let _v = _menhir_action_111 () in
      _menhir_goto_option_BANG_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_goto_separated_nonempty_list_COMMA_requires_item_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState348 ->
          _menhir_run_350 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState352 ->
          _menhir_run_353 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_350 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_REQUIRES -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_REQUIRES (_menhir_stack, _menhir_s) = _menhir_stack in
      let items = _v in
      let _v = _menhir_action_200 items in
      let _menhir_stack = MenhirCell1_requires_clause (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | REQUIRES ->
          _menhir_run_348 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState356
      | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | CONTINUE | DO | EFFECT | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v_0 = _menhir_action_077 () in
          _menhir_run_357 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_357 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_requires_clause -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_requires_clause (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_078 x xs in
      _menhir_goto_list_requires_clause_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_goto_list_requires_clause_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState356 ->
          _menhir_run_357 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState347 ->
          _menhir_run_358 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_358 : type  ttv_stack. (((((((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_cell1_option_where_clause_, _menhir_box_program) _menhir_cell1_list_contract_ as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_list_requires_clause_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | EFFECT ->
          let _menhir_s = MenhirState359 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_360 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | CONTINUE | DO | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v = _menhir_action_131 () in
          _menhir_goto_option_effect_clause_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_360 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          let _menhir_stack = MenhirCell1_IDENT (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState361 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_360 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | CONTINUE | DO | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let x = _v in
          let _v = _menhir_action_209 x in
          _menhir_goto_separated_nonempty_list_COMMA_IDENT_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_separated_nonempty_list_COMMA_IDENT_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState361 ->
          _menhir_run_362 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState359 ->
          _menhir_run_363 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_362 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_IDENT (_menhir_stack, _menhir_s, x, _, _) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_210 x xs in
      _menhir_goto_separated_nonempty_list_COMMA_IDENT_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_363 : type  ttv_stack. (((((((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_cell1_option_where_clause_, _menhir_box_program) _menhir_cell1_list_contract_, _menhir_box_program) _menhir_cell1_list_requires_clause_ -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let effects = _v in
      let _v = _menhir_action_036 effects in
      let x = _v in
      let _v = _menhir_action_132 x in
      _menhir_goto_option_effect_clause_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
  
  and _menhir_goto_option_effect_clause_ : type  ttv_stack. (((((((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_cell1_option_where_clause_, _menhir_box_program) _menhir_cell1_list_contract_, _menhir_box_program) _menhir_cell1_list_requires_clause_ -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let _menhir_stack = MenhirCell0_option_effect_clause_ (_menhir_stack, _v) in
      match (_tok : MenhirBasics.token) with
      | BUDGET ->
          let _menhir_s = MenhirState365 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_366 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | AMP | BANG | BREAK | CHAR_LIT _ | CONTINUE | DO | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v = _menhir_action_127 () in
          _menhir_goto_option_budget_clause_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_366 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | COLON ->
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | INT_LIT _v_0 ->
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | IDENT _v_3 ->
                  let _endpos_5 = _menhir_lexbuf.Lexing.lex_curr_p in
                  let _tok = _menhir_lexer _menhir_lexbuf in
                  let (_endpos, unit, amount, resource) = (_endpos_5, _v_3, _v_0, _v) in
                  let _v = _menhir_action_023 amount resource unit in
                  (match (_tok : MenhirBasics.token) with
                  | COMMA ->
                      let _menhir_stack = MenhirCell1_budget_entry (_menhir_stack, _menhir_s, _v) in
                      let _menhir_s = MenhirState372 in
                      let _tok = _menhir_lexer _menhir_lexbuf in
                      (match (_tok : MenhirBasics.token) with
                      | IDENT _v ->
                          _menhir_run_366 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
                      | _ ->
                          _eRR ())
                  | AMP | BANG | BREAK | CHAR_LIT _ | CONTINUE | DO | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
                      let x = _v in
                      let _v = _menhir_action_211 x in
                      _menhir_goto_separated_nonempty_list_COMMA_budget_entry_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
                  | _ ->
                      _eRR ())
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_goto_separated_nonempty_list_COMMA_budget_entry_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState365 ->
          _menhir_run_370 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState372 ->
          _menhir_run_373 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_370 : type  ttv_stack. (((((((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_cell1_option_where_clause_, _menhir_box_program) _menhir_cell1_list_contract_, _menhir_box_program) _menhir_cell1_list_requires_clause_ _menhir_cell0_option_effect_clause_ -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let entries = _v in
      let _v = _menhir_action_022 entries in
      let x = _v in
      let _v = _menhir_action_128 x in
      _menhir_goto_option_budget_clause_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
  
  and _menhir_goto_option_budget_clause_ : type  ttv_stack. (((((((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_, _menhir_box_program) _menhir_cell1_option_where_clause_, _menhir_box_program) _menhir_cell1_list_contract_, _menhir_box_program) _menhir_cell1_list_requires_clause_ _menhir_cell0_option_effect_clause_ -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let _menhir_stack = MenhirCell0_option_budget_clause_ (_menhir_stack, _v) in
      let _menhir_s = MenhirState374 in
      let _v = _menhir_action_204 () in
      _menhir_goto_rev_block_items _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _endpos _v _menhir_s _tok
  
  and _menhir_run_373 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_budget_entry -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_budget_entry (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_212 x xs in
      _menhir_goto_separated_nonempty_list_COMMA_budget_entry_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_353 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_requires_item -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_requires_item (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_222 x xs in
      _menhir_goto_separated_nonempty_list_COMMA_requires_item_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_343 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_POST, _menhir_box_program) _menhir_cell1_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_expr (_menhir_stack, _, e, _) = _menhir_stack in
      let MenhirCell1_POST (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_msg_, msg) = (_endpos, _v) in
      let _v = _menhir_action_033 _endpos_msg_ _startpos__1_ e msg in
      _menhir_goto_contract _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_346 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_INVARIANT, _menhir_box_program) _menhir_cell1_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_expr (_menhir_stack, _, e, _) = _menhir_stack in
      let MenhirCell1_INVARIANT (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_msg_, msg) = (_endpos, _v) in
      let _v = _menhir_action_034 _endpos_msg_ _startpos__1_ e msg in
      _menhir_goto_contract _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_342 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_POST as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_expr (_menhir_stack, _menhir_s, _v, _endpos) in
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          _menhir_run_337 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState342
      | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | CONTINUE | DO | EFFECT | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | POST | PRE | REQUIRES | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v_0 = _menhir_action_129 () in
          _menhir_run_343 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_345 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_INVARIANT as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_expr (_menhir_stack, _menhir_s, _v, _endpos) in
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          _menhir_run_337 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState345
      | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | CONTINUE | DO | EFFECT | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | POST | PRE | REQUIRES | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v_0 = _menhir_action_129 () in
          _menhir_run_346 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_491 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_type_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_type_expr (_menhir_stack, _, t, _, _) = _menhir_stack in
      let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
      let MenhirCell1_visibility (_menhir_stack, _menhir_s, vis, _startpos_vis_) = _menhir_stack in
      let (_endpos_e_, e) = (_endpos, _v) in
      let _v = _menhir_action_029 _endpos_e_ _startpos_vis_ e name t vis in
      let c = _v in
      let _v = _menhir_action_062 c in
      _menhir_goto_item _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_230 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_or_expr as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | AMP_AMP ->
          let _menhir_stack = MenhirCell1_and_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_223 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell1_or_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_163 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_or_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_224 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_and_expr as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | PIPE ->
          let _menhir_stack = MenhirCell1_bitor_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_218 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell1_and_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_004 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_and_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_219 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_bitor_expr as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | CARET ->
          let _menhir_stack = MenhirCell1_bitxor_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_213 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell1_bitor_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_015 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_bitor_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_220 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | AMP ->
          let _menhir_stack = MenhirCell1_bitand_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_215 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let (_endpos_e_, _startpos_e_, e) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_018 e in
          _menhir_goto_bitxor_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos_e_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_216 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_bitand_expr _menhir_cell0_AMP as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | EQ_EQ ->
          let _menhir_stack = MenhirCell1_equality_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_198 _menhir_stack _menhir_lexbuf _menhir_lexer
      | BANG_EQ ->
          let _menhir_stack = MenhirCell1_equality_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_209 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell0_AMP (_menhir_stack, _) = _menhir_stack in
          let MenhirCell1_bitand_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_013 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_bitand_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_210 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_equality_expr as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | LT_EQ ->
          let _menhir_stack = MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_200 _menhir_stack _menhir_lexbuf _menhir_lexer
      | LT ->
          let _menhir_stack = MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_203 _menhir_stack _menhir_lexbuf _menhir_lexer
      | GT_EQ ->
          let _menhir_stack = MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_205 _menhir_stack _menhir_lexbuf _menhir_lexer
      | GT ->
          let _menhir_stack = MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_207 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell1_equality_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_042 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_equality_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_211 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | LT_EQ ->
          let _menhir_stack = MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_200 _menhir_stack _menhir_lexbuf _menhir_lexer
      | LT ->
          let _menhir_stack = MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_203 _menhir_stack _menhir_lexbuf _menhir_lexer
      | GT_EQ ->
          let _menhir_stack = MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_205 _menhir_stack _menhir_lexbuf _menhir_lexer
      | GT ->
          let _menhir_stack = MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_207 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let (_endpos_e_, _startpos_e_, e) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_043 e in
          _menhir_goto_equality_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos_e_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_201 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_comparison_expr as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | SHR ->
          let _menhir_stack = MenhirCell1_shift_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_170 _menhir_stack _menhir_lexbuf _menhir_lexer
      | SHL ->
          let _menhir_stack = MenhirCell1_shift_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_192 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_026 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_comparison_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_204 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_comparison_expr as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | SHR ->
          let _menhir_stack = MenhirCell1_shift_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_170 _menhir_stack _menhir_lexbuf _menhir_lexer
      | SHL ->
          let _menhir_stack = MenhirCell1_shift_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_192 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_024 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_comparison_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_206 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_comparison_expr as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | SHR ->
          let _menhir_stack = MenhirCell1_shift_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_170 _menhir_stack _menhir_lexbuf _menhir_lexer
      | SHL ->
          let _menhir_stack = MenhirCell1_shift_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_192 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_027 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_comparison_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_208 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_comparison_expr as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | SHR ->
          let _menhir_stack = MenhirCell1_shift_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_170 _menhir_stack _menhir_lexbuf _menhir_lexer
      | SHL ->
          let _menhir_stack = MenhirCell1_shift_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_192 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell1_comparison_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_025 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_comparison_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_193 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_shift_expr as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | PLUS ->
          let _menhir_stack = MenhirCell1_additive_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_188 _menhir_stack _menhir_lexbuf _menhir_lexer
      | MINUS ->
          let _menhir_stack = MenhirCell1_additive_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_190 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell1_shift_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_237 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_shift_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_202 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | PLUS ->
          let _menhir_stack = MenhirCell1_additive_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_188 _menhir_stack _menhir_lexbuf _menhir_lexer
      | MINUS ->
          let _menhir_stack = MenhirCell1_additive_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_190 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS_EQ | MODULE | NEXT | PERCENT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH | SLASH_EQ | STAR | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let (_endpos_e_, _startpos_e_, e) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_239 e in
          _menhir_goto_shift_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos_e_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_189 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_additive_expr as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | STAR ->
          let _menhir_stack = MenhirCell1_multiplicative_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_173 _menhir_stack _menhir_lexbuf _menhir_lexer
      | SLASH ->
          let _menhir_stack = MenhirCell1_multiplicative_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_183 _menhir_stack _menhir_lexbuf _menhir_lexer
      | PERCENT ->
          let _menhir_stack = MenhirCell1_multiplicative_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_185 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH_EQ | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell1_additive_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_001 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_additive_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_191 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_additive_expr _menhir_cell0_MINUS as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | STAR ->
          let _menhir_stack = MenhirCell1_multiplicative_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_173 _menhir_stack _menhir_lexbuf _menhir_lexer
      | SLASH ->
          let _menhir_stack = MenhirCell1_multiplicative_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_183 _menhir_stack _menhir_lexbuf _menhir_lexer
      | PERCENT ->
          let _menhir_stack = MenhirCell1_multiplicative_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_185 _menhir_stack _menhir_lexbuf _menhir_lexer
      | AMP | AMP_AMP | AS | BANG | BANG_EQ | BREAK | BUDGET | CARET | CHAR_LIT _ | COMMA | CONST | CONTINUE | DEF | DO | DOT | EFFECT | ELSE | ELSIF | END | ENUM | EOF | EQ | EQ_EQ | FALSE | FAT_ARROW | FLOAT_LIT _ | FOR | GT | GT_EQ | IDENT _ | IF | IMPL | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | LT | LT_EQ | MATCH | MINUS | MINUS_EQ | MODULE | NEXT | PERCENT_EQ | PIPE | PIPE_PIPE | PLUS | PLUS_EQ | POST | PRE | PUB | QUESTION | RBRACE | RBRACKET | REQUIRES | RETURN | RPAREN | SELF_LOWER | SEMICOL | SHL | SHR | SLASH_EQ | STAR_EQ | STRING_LIT _ | STRUCT | THEN | TILDE | TRAIT | TRUE | TYPE | UNSAFE | USE | WHEN | WHILE ->
          let MenhirCell0_MINUS (_menhir_stack, _) = _menhir_stack in
          let MenhirCell1_additive_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
          let (_endpos_r_, r) = (_endpos, _v) in
          let _v = _menhir_action_002 _endpos_r_ _startpos_l_ l r in
          _menhir_goto_additive_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_174 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_multiplicative_expr _menhir_cell0_STAR -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell0_STAR (_menhir_stack, _, _) = _menhir_stack in
      let MenhirCell1_multiplicative_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
      let (_endpos_r_, r) = (_endpos, _v) in
      let _v = _menhir_action_107 _endpos_r_ _startpos_l_ l r in
      _menhir_goto_multiplicative_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
  
  and _menhir_run_184 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_multiplicative_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_multiplicative_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
      let (_endpos_r_, r) = (_endpos, _v) in
      let _v = _menhir_action_108 _endpos_r_ _startpos_l_ l r in
      _menhir_goto_multiplicative_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
  
  and _menhir_run_186 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_multiplicative_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_multiplicative_expr (_menhir_stack, _menhir_s, l, _startpos_l_, _) = _menhir_stack in
      let (_endpos_r_, r) = (_endpos, _v) in
      let _v = _menhir_action_109 _endpos_r_ _startpos_l_ l r in
      _menhir_goto_multiplicative_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_r_ _startpos_l_ _v _menhir_s _tok
  
  and _menhir_run_254 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_AMP -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_AMP (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_e_, e) = (_endpos, _v) in
      let _v = _menhir_action_267 _endpos_e_ _startpos__1_ e in
      _menhir_goto_unary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_255 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_BANG -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_BANG (_menhir_stack, _menhir_s, _startpos__1_, _) = _menhir_stack in
      let (_endpos_e_, e) = (_endpos, _v) in
      let _v = _menhir_action_265 _endpos_e_ _startpos__1_ e in
      _menhir_goto_unary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_311 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_MINUS -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_MINUS (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_e_, e) = (_endpos, _v) in
      let _v = _menhir_action_264 _endpos_e_ _startpos__1_ e in
      _menhir_goto_unary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_313 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_STAR -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_STAR (_menhir_stack, _menhir_s, _startpos__1_, _) = _menhir_stack in
      let (_endpos_e_, e) = (_endpos, _v) in
      let _v = _menhir_action_269 _endpos_e_ _startpos__1_ e in
      _menhir_goto_unary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_run_314 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_TILDE -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_TILDE (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_e_, e) = (_endpos, _v) in
      let _v = _menhir_action_266 _endpos_e_ _startpos__1_ e in
      _menhir_goto_unary_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_e_ _startpos__1_ _v _menhir_s _tok
  
  and _menhir_goto_separated_nonempty_list_COMMA_pattern_field_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState119 ->
          _menhir_run_129 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | MenhirState131 ->
          _menhir_run_132 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_129 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let x = _v in
      let _v = _menhir_action_097 x in
      _menhir_goto_loption_separated_nonempty_list_COMMA_pattern_field__ _menhir_stack _menhir_lexbuf _menhir_lexer _v
  
  and _menhir_run_132 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_pattern_field -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let MenhirCell1_pattern_field (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_220 x xs in
      _menhir_goto_separated_nonempty_list_COMMA_pattern_field_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_run_139 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          let _menhir_stack = MenhirCell1_pattern (_menhir_stack, _menhir_s, _v) in
          let _menhir_s = MenhirState140 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | MUT ->
              _menhir_run_074 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_117 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IDENT _v ->
              _menhir_run_118 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | RPAREN ->
          let x = _v in
          let _v = _menhir_action_217 x in
          _menhir_goto_separated_nonempty_list_COMMA_pattern_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_separated_nonempty_list_COMMA_pattern_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState117 ->
          _menhir_run_138 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | MenhirState137 ->
          _menhir_run_138 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | MenhirState140 ->
          _menhir_run_141 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_138 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let x = _v in
      let _v = _menhir_action_095 x in
      _menhir_goto_loption_separated_nonempty_list_COMMA_pattern__ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_goto_loption_separated_nonempty_list_COMMA_pattern__ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState137 ->
          _menhir_run_142 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | MenhirState117 ->
          _menhir_run_146 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_141 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_pattern -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let MenhirCell1_pattern (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_218 x xs in
      _menhir_goto_separated_nonempty_list_COMMA_pattern_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_run_148 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_FOR as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_pattern (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | IN ->
          let _menhir_s = MenhirState149 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_298 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_WHEN as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_pattern (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | IF ->
          let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
          let _menhir_stack = MenhirCell0_IF (_menhir_stack, _startpos) in
          let _menhir_s = MenhirState299 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | FAT_ARROW ->
          let _v = _menhir_action_143 () in
          _menhir_goto_option_match_guard_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_317 : type  ttv_stack. ((((ttv_stack, _menhir_box_program) _menhir_cell1_rev_block_items, _menhir_box_program) _menhir_cell1_LET, _menhir_box_program) _menhir_cell1_option_MUT_ as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_pattern (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | COLON ->
          let _menhir_s = MenhirState318 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | SELF_UPPER ->
              _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | QUESTION ->
              _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FN ->
              _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | EQ | SEMICOL ->
          let _v = _menhir_action_151 () in
          _menhir_goto_option_type_annotation_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_option_type_annotation_ : type  ttv_stack. ((((ttv_stack, _menhir_box_program) _menhir_cell1_rev_block_items, _menhir_box_program) _menhir_cell1_LET, _menhir_box_program) _menhir_cell1_option_MUT_, _menhir_box_program) _menhir_cell1_pattern -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let _menhir_stack = MenhirCell0_option_type_annotation_ (_menhir_stack, _v) in
      match (_tok : MenhirBasics.token) with
      | EQ ->
          let _menhir_s = MenhirState322 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | SEMICOL ->
          let _v = _menhir_action_141 () in
          _menhir_goto_option_initializer__ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_426 : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _menhir_stack = MenhirCell1_loption_separated_nonempty_list_COMMA_param__ (_menhir_stack, _menhir_s, _v) in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell0_RPAREN (_menhir_stack, _endpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | ARROW ->
          _menhir_run_085 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState427
      | AMP | BANG | BREAK | CHAR_LIT _ | CONTINUE | DEF | DO | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | TYPE | UNSAFE | WHILE ->
          let _v_0 = _menhir_action_145 () in
          _menhir_run_428 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 MenhirState427 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_085 : type  ttv_stack. (((ttv_stack _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN as 'stack) -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s ->
      let _menhir_stack = MenhirCell1_ARROW (_menhir_stack, _menhir_s) in
      let _menhir_s = MenhirState085 in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | SELF_UPPER ->
          _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | QUESTION ->
          _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | LPAREN ->
          _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | IDENT _v ->
          _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | FN ->
          _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | BANG ->
          _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | AMP ->
          _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_run_428 : type  ttv_stack. ((((ttv_stack, _menhir_box_program) _menhir_cell1_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_return_type_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | DEF | TYPE ->
          let _menhir_s = MenhirState428 in
          let _v = _menhir_action_147 () in
          _menhir_goto_option_trait_method_body_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | AMP | BANG | BREAK | CHAR_LIT _ | CONTINUE | DO | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _menhir_s = MenhirState428 in
          let _v = _menhir_action_204 () in
          _menhir_goto_rev_block_items _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _endpos _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_437 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_trait_item -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let MenhirCell1_trait_item (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_080 x xs in
      _menhir_goto_list_trait_item_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_goto_list_trait_item_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState436 ->
          _menhir_run_437 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | MenhirState418 ->
          _menhir_run_438 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_438 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_option_trait_super_ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let MenhirCell0_option_trait_super_ (_menhir_stack, super) = _menhir_stack in
      let MenhirCell1_option_type_params_ (_menhir_stack, _, type_params) = _menhir_stack in
      let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
      let MenhirCell1_visibility (_menhir_stack, _menhir_s, vis, _startpos_vis_) = _menhir_stack in
      let (items, _endpos__7_) = (_v, _endpos) in
      let _v = _menhir_action_243 _endpos__7_ _startpos_vis_ items name super type_params vis in
      let t = _v in
      let _v = _menhir_action_059 t in
      _menhir_goto_item _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_442 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_type_params_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | PUB ->
          _menhir_run_001 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState442
      | END ->
          let _v_0 = _menhir_action_069 () in
          _menhir_run_447 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0
      | IDENT _ ->
          let _v_1 = _menhir_action_286 () in
          _menhir_run_443 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_1 MenhirState442 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_447 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let MenhirCell1_option_type_params_ (_menhir_stack, _, type_params) = _menhir_stack in
      let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
      let MenhirCell1_visibility (_menhir_stack, _menhir_s, vis, _startpos_vis_) = _menhir_stack in
      let (_endpos__6_, fields) = (_endpos, _v) in
      let _v = _menhir_action_240 _endpos__6_ _startpos_vis_ fields name type_params vis in
      let s = _v in
      let _v = _menhir_action_057 s in
      _menhir_goto_item _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_443 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _startpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_visibility (_menhir_stack, _menhir_s, _v, _startpos) in
      match (_tok : MenhirBasics.token) with
      | IDENT _v_0 ->
          let _v = _v_0 in
          let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _menhir_stack = MenhirCell0_IDENT (_menhir_stack, _v, _startpos, _endpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | COLON ->
              let _menhir_s = MenhirState445 in
              let _tok = _menhir_lexer _menhir_lexbuf in
              (match (_tok : MenhirBasics.token) with
              | SELF_UPPER ->
                  _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | QUESTION ->
                  _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | LPAREN ->
                  _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | IDENT _v ->
                  _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
              | FN ->
                  _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | BANG ->
                  _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | AMP ->
                  _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
              | _ ->
                  _eRR ())
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_468 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_type_params_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | IDENT _v_0 ->
          _menhir_run_469 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0 MenhirState468
      | END ->
          let _v_1 = _menhir_action_081 () in
          _menhir_run_484 _menhir_stack _menhir_lexbuf _menhir_lexer _v_1
      | _ ->
          _eRR ()
  
  and _menhir_run_469 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell1_IDENT (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | LPAREN ->
          let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
          let _menhir_stack = MenhirCell0_LPAREN (_menhir_stack, _startpos) in
          let _menhir_s = MenhirState470 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | SELF_UPPER ->
              _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | QUESTION ->
              _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_471 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FN ->
              _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | END | IDENT _ ->
          let _v = _menhir_action_159 () in
          _menhir_goto_option_variant_fields_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_471 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | LBRACKET ->
          let _menhir_stack = MenhirCell1_IDENT (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          _menhir_run_025 _menhir_stack _menhir_lexbuf _menhir_lexer
      | COLON ->
          let _menhir_stack = MenhirCell1_IDENT (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
          let _menhir_s = MenhirState472 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | SELF_UPPER ->
              _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | QUESTION ->
              _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FN ->
              _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | COMMA | RPAREN ->
          let (_endpos_name_, _startpos_name_, name) = (_endpos, _startpos, _v) in
          let _v = _menhir_action_253 name in
          _menhir_goto_type_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_name_ _startpos_name_ _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_option_variant_fields_ : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_IDENT (_menhir_stack, _menhir_s, name, _startpos_name_, _) = _menhir_stack in
      let (_endpos_fields_, fields) = (_endpos, _v) in
      let _v = _menhir_action_281 _endpos_fields_ _startpos_name_ fields name in
      let _menhir_stack = MenhirCell1_variant_def (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | IDENT _v_0 ->
          _menhir_run_469 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0 MenhirState482
      | END ->
          let _v_1 = _menhir_action_081 () in
          _menhir_run_483 _menhir_stack _menhir_lexbuf _menhir_lexer _v_1
      | _ ->
          _eRR ()
  
  and _menhir_run_483 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_variant_def -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let MenhirCell1_variant_def (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_082 x xs in
      _menhir_goto_list_variant_def_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_goto_list_variant_def_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState482 ->
          _menhir_run_483 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | MenhirState468 ->
          _menhir_run_484 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_484 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let MenhirCell1_option_type_params_ (_menhir_stack, _, type_params) = _menhir_stack in
      let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
      let MenhirCell1_visibility (_menhir_stack, _menhir_s, vis, _startpos_vis_) = _menhir_stack in
      let (_endpos__6_, variants) = (_endpos, _v) in
      let _v = _menhir_action_039 _endpos__6_ _startpos_vis_ name type_params variants vis in
      let e = _v in
      let _v = _menhir_action_058 e in
      _menhir_goto_item _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_058 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_type_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
      match (_tok : MenhirBasics.token) with
      | COLON ->
          let _menhir_s = MenhirState059 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | IDENT _v ->
              _menhir_run_006 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_068 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_TYPE _menhir_cell0_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
      let MenhirCell1_TYPE (_menhir_stack, _menhir_s, _startpos__1_) = _menhir_stack in
      let (_endpos_t_, t) = (_endpos, _v) in
      let _v = _menhir_action_053 _endpos_t_ _startpos__1_ name t in
      _menhir_goto_impl_item _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_082 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_option_MUT_ _menhir_cell0_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
      let MenhirCell1_option_MUT_ (_menhir_stack, _menhir_s, m, _startpos_m_) = _menhir_stack in
      let (_endpos_t_, t) = (_endpos, _v) in
      let _v = _menhir_action_165 _endpos_t_ _startpos_m_ m name t in
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          let _menhir_stack = MenhirCell1_param (_menhir_stack, _menhir_s, _v) in
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | MUT ->
              _menhir_run_074 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState077
          | IDENT _ ->
              let _v_0 = _menhir_action_121 () in
              _menhir_run_079 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 MenhirState077 _tok
          | _ ->
              _eRR ())
      | RPAREN ->
          let x = _v in
          let _v = _menhir_action_215 x in
          _menhir_goto_separated_nonempty_list_COMMA_param_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_separated_nonempty_list_COMMA_param_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState073 ->
          _menhir_run_075 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | MenhirState425 ->
          _menhir_run_075 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | MenhirState077 ->
          _menhir_run_078 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_075 : type  ttv_stack. ((ttv_stack _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let x = _v in
      let _v = _menhir_action_093 x in
      _menhir_goto_loption_separated_nonempty_list_COMMA_param__ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_goto_loption_separated_nonempty_list_COMMA_param__ : type  ttv_stack. ((ttv_stack _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState073 ->
          _menhir_run_083 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | MenhirState425 ->
          _menhir_run_426 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_083 : type  ttv_stack. (((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      let _menhir_stack = MenhirCell1_loption_separated_nonempty_list_COMMA_param__ (_menhir_stack, _menhir_s, _v) in
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _menhir_stack = MenhirCell0_RPAREN (_menhir_stack, _endpos) in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | ARROW ->
          _menhir_run_085 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState084
      | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | CONTINUE | DO | EFFECT | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | POST | PRE | REQUIRES | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHERE | WHILE ->
          let _v_0 = _menhir_action_145 () in
          _menhir_run_088 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 MenhirState084 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_088 : type  ttv_stack. ((((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_return_type_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | WHERE ->
          _menhir_run_055 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState088
      | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | CONTINUE | DO | EFFECT | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | POST | PRE | REQUIRES | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v_0 = _menhir_action_161 () in
          _menhir_run_089 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 MenhirState088 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_089 : type  ttv_stack. (((((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_option_return_type_ as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_where_clause_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | PRE ->
          _menhir_run_090 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState089
      | POST ->
          _menhir_run_341 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState089
      | INVARIANT ->
          _menhir_run_344 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState089
      | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | CONTINUE | DO | EFFECT | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | REQUIRES | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | UNSAFE | WHILE ->
          let _v_0 = _menhir_action_065 () in
          _menhir_run_347 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_0 MenhirState089 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_078 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_param -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let MenhirCell1_param (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_216 x xs in
      _menhir_goto_separated_nonempty_list_COMMA_param_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_run_086 : type  ttv_stack. (((ttv_stack _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN, _menhir_box_program) _menhir_cell1_ARROW -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_ARROW (_menhir_stack, _menhir_s) = _menhir_stack in
      let t = _v in
      let _v = _menhir_action_203 t in
      let x = _v in
      let _v = _menhir_action_146 x in
      _menhir_goto_option_return_type_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_goto_option_return_type_ : type  ttv_stack. (((ttv_stack _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ _menhir_cell0_LPAREN, _menhir_box_program) _menhir_cell1_loption_separated_nonempty_list_COMMA_param__ _menhir_cell0_RPAREN as 'stack) -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState084 ->
          _menhir_run_088 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState427 ->
          _menhir_run_428 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_253 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_postfix_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_postfix_expr (_menhir_stack, _menhir_s, e, _startpos_e_, _) = _menhir_stack in
      let (_endpos_t_, t) = (_endpos, _v) in
      let _v = _menhir_action_180 _endpos_t_ _startpos_e_ e t in
      _menhir_goto_postfix_expr _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_t_ _startpos_e_ _v _menhir_s _tok
  
  and _menhir_run_319 : type  ttv_stack. ((((ttv_stack, _menhir_box_program) _menhir_cell1_rev_block_items, _menhir_box_program) _menhir_cell1_LET, _menhir_box_program) _menhir_cell1_option_MUT_, _menhir_box_program) _menhir_cell1_pattern -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let t = _v in
      let _v = _menhir_action_250 t in
      let x = _v in
      let _v = _menhir_action_152 x in
      _menhir_goto_option_type_annotation_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
  
  and _menhir_run_411 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_TYPE _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_option_type_params_ (_menhir_stack, _, type_params) = _menhir_stack in
      let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
      let MenhirCell0_TYPE (_menhir_stack, _) = _menhir_stack in
      let MenhirCell1_visibility (_menhir_stack, _menhir_s, vis, _startpos_vis_) = _menhir_stack in
      let (_endpos_t_, t) = (_endpos, _v) in
      let _v = _menhir_action_249 _endpos_t_ _startpos_vis_ name t type_params vis in
      let t = _v in
      let _v = _menhir_action_063 t in
      _menhir_goto_item _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_446 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell0_IDENT (_menhir_stack, name, _, _) = _menhir_stack in
      let MenhirCell1_visibility (_menhir_stack, _menhir_s, vis, _startpos_vis_) = _menhir_stack in
      let (_endpos_t_, t) = (_endpos, _v) in
      let _v = _menhir_action_047 _endpos_t_ _startpos_vis_ name t vis in
      let _menhir_stack = MenhirCell1_field_def (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | PUB ->
          _menhir_run_001 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState449
      | END ->
          let _v_0 = _menhir_action_069 () in
          _menhir_run_450 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0
      | IDENT _ ->
          let _v_1 = _menhir_action_286 () in
          _menhir_run_443 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_1 MenhirState449 _tok
      | _ ->
          _eRR ()
  
  and _menhir_run_450 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_field_def -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let MenhirCell1_field_def (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_070 x xs in
      _menhir_goto_list_field_def_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_goto_list_field_def_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState442 ->
          _menhir_run_447 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | MenhirState449 ->
          _menhir_run_450 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_473 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_IDENT (_menhir_stack, _menhir_s, name, _startpos_name_, _) = _menhir_stack in
      let (_endpos_t_, t) = (_endpos, _v) in
      let _v = _menhir_action_282 _endpos_t_ _startpos_name_ name t in
      _menhir_goto_variant_field _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_goto_variant_field : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          let _menhir_stack = MenhirCell1_variant_field (_menhir_stack, _menhir_s, _v) in
          let _menhir_s = MenhirState475 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | SELF_UPPER ->
              _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | QUESTION ->
              _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_471 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FN ->
              _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | RPAREN ->
          let x = _v in
          let _v = _menhir_action_231 x in
          _menhir_goto_separated_nonempty_list_COMMA_variant_field_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
      | _ ->
          _eRR ()
  
  and _menhir_goto_separated_nonempty_list_COMMA_variant_field_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s ->
      match _menhir_s with
      | MenhirState475 ->
          _menhir_run_477 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | MenhirState470 ->
          _menhir_run_478 _menhir_stack _menhir_lexbuf _menhir_lexer _v
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_477 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_variant_field -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let MenhirCell1_variant_field (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_232 x xs in
      _menhir_goto_separated_nonempty_list_COMMA_variant_field_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
  
  and _menhir_run_478 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_IDENT _menhir_cell0_LPAREN -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      let MenhirCell0_LPAREN (_menhir_stack, _) = _menhir_stack in
      let (fields, _endpos__3_) = (_v, _endpos) in
      let _v = _menhir_action_284 fields in
      let _endpos = _endpos__3_ in
      let (_endpos_x_, x) = (_endpos, _v) in
      let _v = _menhir_action_160 x in
      _menhir_goto_option_variant_fields_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos_x_ _v _tok
  
  and _menhir_run_476 : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      let (_endpos_t_, _startpos_t_, t) = (_endpos, _startpos, _v) in
      let _v = _menhir_action_283 _endpos_t_ _startpos_t_ t in
      _menhir_goto_variant_field _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok
  
  and _menhir_run_489 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT as 'stack) -> _ -> _ -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _startpos _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_type_expr (_menhir_stack, _menhir_s, _v, _startpos, _endpos) in
      match (_tok : MenhirBasics.token) with
      | EQ ->
          let _menhir_s = MenhirState490 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | WHILE ->
              _menhir_run_091 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | UNSAFE ->
              _menhir_run_092 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TRUE ->
              _menhir_run_094 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | TILDE ->
              _menhir_run_095 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | STRING_LIT _v ->
              _menhir_run_096 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | STAR ->
              _menhir_run_097 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | SELF_LOWER ->
              _menhir_run_098 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | RETURN ->
              _menhir_run_099 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | NEXT ->
              _menhir_run_100 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MINUS ->
              _menhir_run_103 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | MATCH ->
              _menhir_run_104 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_105 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LOOP ->
              _menhir_run_106 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LBRACKET ->
              _menhir_run_109 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | INT_LIT _v ->
              _menhir_run_110 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | IF ->
              _menhir_run_111 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_112 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FOR ->
              _menhir_run_116 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | FLOAT_LIT _v ->
              _menhir_run_122 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FALSE ->
              _menhir_run_123 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | DO ->
              _menhir_run_150 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CONTINUE ->
              _menhir_run_153 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | CHAR_LIT _v ->
              _menhir_run_124 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | BREAK ->
              _menhir_run_155 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_157 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_158 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_072 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_DEF _menhir_cell0_IDENT as 'stack) -> _ -> _ -> _ -> ('stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s _tok ->
      let _menhir_stack = MenhirCell1_option_type_params_ (_menhir_stack, _menhir_s, _v) in
      match (_tok : MenhirBasics.token) with
      | LPAREN ->
          let _startpos = _menhir_lexbuf.Lexing.lex_start_p in
          let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
          let _menhir_stack = MenhirCell0_LPAREN (_menhir_stack, _startpos) in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | MUT ->
              _menhir_run_074 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState073
          | RPAREN ->
              let _v_0 = _menhir_action_092 () in
              _menhir_run_083 _menhir_stack _menhir_lexbuf _menhir_lexer _v_0 MenhirState073
          | IDENT _ ->
              let _v_1 = _menhir_action_121 () in
              _menhir_run_079 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v_1 MenhirState073 _tok
          | _ ->
              _eRR ())
      | _ ->
          _eRR ()
  
  and _menhir_run_060 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_type_expr -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_type_expr (_menhir_stack, _menhir_s, t, _startpos_t_, _) = _menhir_stack in
      let (_endpos_bounds_, bounds) = (_endpos, _v) in
      let _v = _menhir_action_288 _endpos_bounds_ _startpos_t_ bounds t in
      match (_tok : MenhirBasics.token) with
      | COMMA ->
          let _menhir_stack = MenhirCell1_where_pred (_menhir_stack, _menhir_s, _v) in
          let _menhir_s = MenhirState057 in
          let _tok = _menhir_lexer _menhir_lexbuf in
          (match (_tok : MenhirBasics.token) with
          | SELF_UPPER ->
              _menhir_run_021 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | QUESTION ->
              _menhir_run_022 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | LPAREN ->
              _menhir_run_023 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | IDENT _v ->
              _menhir_run_024 _menhir_stack _menhir_lexbuf _menhir_lexer _v _menhir_s
          | FN ->
              _menhir_run_026 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | BANG ->
              _menhir_run_028 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | AMP ->
              _menhir_run_029 _menhir_stack _menhir_lexbuf _menhir_lexer _menhir_s
          | _ ->
              _eRR ())
      | AMP | BANG | BREAK | BUDGET | CHAR_LIT _ | CONTINUE | DEF | DO | EFFECT | END | FALSE | FLOAT_LIT _ | FOR | IDENT _ | IF | INT_LIT _ | INVARIANT | LBRACKET | LET | LOOP | LPAREN | MATCH | MINUS | NEXT | POST | PRE | PUB | REQUIRES | RETURN | SELF_LOWER | STAR | STRING_LIT _ | TILDE | TRUE | TYPE | UNSAFE | WHILE ->
          let x = _v in
          let _v = _menhir_action_233 x in
          _menhir_goto_separated_nonempty_list_COMMA_where_pred_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | _ ->
          _eRR ()
  
  and _menhir_goto_separated_nonempty_list_COMMA_where_pred_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState057 ->
          _menhir_run_061 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | MenhirState055 ->
          _menhir_run_062 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_061 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_where_pred -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_where_pred (_menhir_stack, _menhir_s, x) = _menhir_stack in
      let xs = _v in
      let _v = _menhir_action_234 x xs in
      _menhir_goto_separated_nonempty_list_COMMA_where_pred_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_run_062 : type  ttv_stack. (ttv_stack, _menhir_box_program) _menhir_cell1_WHERE -> _ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _tok ->
      let MenhirCell1_WHERE (_menhir_stack, _menhir_s) = _menhir_stack in
      let preds = _v in
      let _v = _menhir_action_287 preds in
      let x = _v in
      let _v = _menhir_action_162 x in
      _menhir_goto_option_where_clause_ _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
  
  and _menhir_goto_option_where_clause_ : type  ttv_stack. ttv_stack -> _ -> _ -> _ -> _ -> (ttv_stack, _menhir_box_program) _menhir_state -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok ->
      match _menhir_s with
      | MenhirState054 ->
          _menhir_run_064 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | MenhirState088 ->
          _menhir_run_089 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v _menhir_s _tok
      | _ ->
          _menhir_fail ()
  
  and _menhir_run_416 : type  ttv_stack. ((ttv_stack, _menhir_box_program) _menhir_cell1_visibility _menhir_cell0_IDENT, _menhir_box_program) _menhir_cell1_option_type_params_ -> _ -> _ -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok ->
      let traits = _v in
      let _v = _menhir_action_248 traits in
      let x = _v in
      let _v = _menhir_action_150 x in
      _menhir_goto_option_trait_super_ _menhir_stack _menhir_lexbuf _menhir_lexer _v _tok
  
  let _menhir_run_000 : type  ttv_stack. ttv_stack -> _ -> _ -> _menhir_box_program =
    fun _menhir_stack _menhir_lexbuf _menhir_lexer ->
      let _endpos = _menhir_lexbuf.Lexing.lex_curr_p in
      let _tok = _menhir_lexer _menhir_lexbuf in
      match (_tok : MenhirBasics.token) with
      | PUB ->
          _menhir_run_001 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState000
      | IMPL ->
          _menhir_run_002 _menhir_stack _menhir_lexbuf _menhir_lexer MenhirState000
      | EOF ->
          let _v = _menhir_action_073 () in
          _menhir_run_493 _menhir_stack _v _tok
      | CONST | DEF | ENUM | MODULE | STRUCT | TRAIT | TYPE | USE ->
          let _v = _menhir_action_286 () in
          _menhir_run_387 _menhir_stack _menhir_lexbuf _menhir_lexer _endpos _v MenhirState000 _tok
      | _ ->
          _eRR ()
  
end

let program =
  fun _menhir_lexer _menhir_lexbuf ->
    let _menhir_stack = () in
    let MenhirBox_program v = _menhir_run_000 _menhir_stack _menhir_lexbuf _menhir_lexer in
    v

# 580 "src/parser.mly"
  

# 13119 "src/parser.ml"
