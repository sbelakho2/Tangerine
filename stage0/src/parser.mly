%{
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
%}

(* Tokens *)
%token <int64> INT_LIT
%token <float> FLOAT_LIT
%token <string> STRING_LIT
%token <char> CHAR_LIT
%token <string> IDENT

%token DEF END IF THEN ELSE ELSIF WHILE FOR IN DO
%token LET MUT RETURN BREAK NEXT CONTINUE
%token MATCH WHEN STRUCT ENUM TRAIT IMPL USE PUB MODULE
%token FN SELF_LOWER SELF_UPPER TRUE FALSE UNSAFE WHERE AS TYPE CONST
%token EXTERN SUPER CRATE YIELD ASYNC AWAIT LOOP TRY CATCH FINALLY
%token PURE INLINE CAP EFFECT REQUIRES IMPLIES HANDLE WITH
%token RATIONALE BUDGET PRE POST INVARIANT GUARD MACRO COMPTIME
%token NIL NONE

%token PLUS MINUS STAR SLASH PERCENT
%token EQ_EQ BANG_EQ LT GT LT_EQ GT_EQ
%token AMP_AMP PIPE_PIPE BANG
%token AMP PIPE CARET TILDE SHL SHR
%token EQ PLUS_EQ MINUS_EQ STAR_EQ SLASH_EQ PERCENT_EQ
%token LPAREN RPAREN LBRACKET RBRACKET LBRACE RBRACE
%token ARROW FAT_ARROW COLON_COLON COLON COMMA DOT DOT_DOT DOT_DOT_EQ
%token SEMICOL QUESTION AT
%token EOF

(* Precedence - lowest to highest *)
%nonassoc TRAILING_EXPR  (* lowest precedence for trailing expressions *)
%right EQ PLUS_EQ MINUS_EQ STAR_EQ SLASH_EQ PERCENT_EQ
%left PIPE_PIPE
%left AMP_AMP
%left PIPE
%left CARET
%left AMP
%left EQ_EQ BANG_EQ
%left LT GT LT_EQ GT_EQ
%left SHL SHR
%left PLUS MINUS
%left STAR SLASH PERCENT
%right BANG TILDE
%left DOT LBRACKET LPAREN
%nonassoc SEMICOL  (* higher precedence to prefer stmt over trailing *)

%start <Ast.program> program

%%

program:
  | items=item* EOF { { items; file = !current_file } }

item:
  | f=function_def { ItemFn f }
  | s=struct_def { ItemStruct s }
  | e=enum_def { ItemEnum e }
  | t=trait_def { ItemTrait t }
  | i=impl_block { ItemImpl i }
  | u=use_decl { ItemUse u }
  | c=const_decl { ItemConst c }
  | t=type_alias { ItemTypeAlias t }
  | m=module_decl { ItemModule m }

visibility:
  | PUB { Public }
  | { Private }

function_def:
  | vis=visibility DEF name=IDENT 
    type_params=type_params?
    LPAREN params=separated_list(COMMA, param) RPAREN
    ret=return_type?
    where_clause=where_clause?
    contracts=contract*
    requires_list=requires_clause*
    effects=effect_clause?
    budget=budget_clause?
    body=block
    END
    { { fn_vis = vis;
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
        fn_span = make_span $startpos $endpos !current_file;
      } }

return_type:
  | ARROW t=type_expr { t }

type_params:
  | LBRACKET params=separated_nonempty_list(COMMA, type_param) RBRACKET { params }

type_param:
  | name=IDENT bounds=type_bounds? 
    { { tp_name = name; 
        tp_bounds = Option.value ~default:[] bounds;
        tp_span = make_span $startpos $endpos !current_file } }

type_bounds:
  | COLON bounds=separated_nonempty_list(PLUS, IDENT) { bounds }

where_clause:
  | WHERE preds=separated_nonempty_list(COMMA, where_pred) { preds }

where_pred:
  | t=type_expr COLON bounds=separated_nonempty_list(PLUS, IDENT)
    { { wp_type = t; wp_bounds = bounds; wp_span = make_span $startpos $endpos !current_file } }

param:
  | m=MUT? name=IDENT COLON t=type_expr
    { { param_mut = (if Option.is_some m then Mutable else Immutable);
        param_name = name;
        param_type = t;
        param_span = make_span $startpos $endpos !current_file } }

contract:
  | PRE e=expr msg=contract_msg? { ContractPre (e, msg, make_span $startpos $endpos !current_file) }
  | POST e=expr msg=contract_msg? { ContractPost (e, msg, make_span $startpos $endpos !current_file) }
  | INVARIANT e=expr msg=contract_msg? { ContractInvariant (e, msg, make_span $startpos $endpos !current_file) }

contract_msg:
  | COMMA s=STRING_LIT { s }

requires_clause:
  | REQUIRES items=separated_nonempty_list(COMMA, requires_item) { items }

requires_item:
  | neg=BANG? cap=IDENT 
    { { req_negated = Option.is_some neg; 
        req_cap = cap; 
        req_span = make_span $startpos $endpos !current_file } }

effect_clause:
  | EFFECT effects=separated_nonempty_list(COMMA, IDENT) { effects }

budget_clause:
  | BUDGET entries=separated_nonempty_list(COMMA, budget_entry) { entries }

budget_entry:
  | resource=IDENT COLON amount=INT_LIT unit=IDENT { (resource, amount, unit) }

block:
  | items=rev_block_items
    { let (stmts, trailing) = items in
      { stmts = List.rev stmts; expr = trailing; span = make_span $startpos $endpos !current_file } }

rev_block_items:
  | (* empty *) { ([], None) }
  | prev=rev_block_items LET m=MUT? p=pattern t=type_annotation? init=initializer_? SEMICOL
    { let s = StmtLet ((if Option.is_some m then Mutable else Immutable), p, t, init, 
                       make_span $startpos $endpos !current_file) in
      ((s :: fst prev), snd prev) }
  | prev=rev_block_items e=expr_with_semi
    { let (ex, has_semi) = e in
      if has_semi then
        let s = StmtExpr (ex, make_span $startpos $endpos !current_file) in
        ((s :: fst prev), snd prev)
      else
        (fst prev, Some ex) }

expr_with_semi:
  | e=expr SEMICOL { (e, true) }
  | e=expr %prec TRAILING_EXPR { (e, false) }

type_annotation:
  | COLON t=type_expr { t }

initializer_:
  | EQ e=expr { e }

(* Type expressions *)
type_expr:
  | name=IDENT { TyName (name, []) }
  | name=IDENT LBRACKET args=separated_nonempty_list(COMMA, type_expr) RBRACKET 
    { TyName (name, args) }
  | FN LPAREN params=separated_list(COMMA, type_expr) RPAREN ARROW ret=type_expr
    { TyFn (params, ret) }
  | LPAREN types=separated_list(COMMA, type_expr) RPAREN { TyTuple types }
  | AMP t=type_expr { TyRef (Immutable, t) }
  | AMP MUT t=type_expr { TyRef (Mutable, t) }
  | QUESTION t=type_expr { TyOption t }
  | SELF_UPPER { TySelf }
  | BANG { TyNever }

(* Patterns *)
pattern:
  | m=MUT? name=IDENT 
    { PatIdent ((if Option.is_some m then Mutable else Immutable), name, 
                make_span $startpos $endpos !current_file) }
  | LPAREN pats=separated_list(COMMA, pattern) RPAREN 
    { PatTuple (pats, make_span $startpos $endpos !current_file) }
  | name=IDENT LBRACE fields=separated_list(COMMA, pattern_field) RBRACE
    { PatStruct (name, fields, make_span $startpos $endpos !current_file) }
  | ty=IDENT COLON_COLON variant=IDENT args=enum_pattern_args?
    { PatEnum (ty, variant, Option.value ~default:[] args, 
               make_span $startpos $endpos !current_file) }
  | l=literal { PatLiteral (l, make_span $startpos $endpos !current_file) }

pattern_field:
  | name=IDENT COLON p=pattern { (name, p) }
  | name=IDENT { (name, PatIdent (Immutable, name, make_span $startpos $endpos !current_file)) }

enum_pattern_args:
  | LPAREN pats=separated_list(COMMA, pattern) RPAREN { pats }

(* Expressions *)
expr:
  | e=assignment_expr { e }

assignment_expr:
  | lhs=or_expr EQ rhs=assignment_expr 
    { ExprAssign (lhs, rhs, make_span $startpos $endpos !current_file) }
  | lhs=or_expr PLUS_EQ rhs=assignment_expr
    { ExprCompoundAssign (Add, lhs, rhs, make_span $startpos $endpos !current_file) }
  | lhs=or_expr MINUS_EQ rhs=assignment_expr
    { ExprCompoundAssign (Sub, lhs, rhs, make_span $startpos $endpos !current_file) }
  | lhs=or_expr STAR_EQ rhs=assignment_expr
    { ExprCompoundAssign (Mul, lhs, rhs, make_span $startpos $endpos !current_file) }
  | lhs=or_expr SLASH_EQ rhs=assignment_expr
    { ExprCompoundAssign (Div, lhs, rhs, make_span $startpos $endpos !current_file) }
  | lhs=or_expr PERCENT_EQ rhs=assignment_expr
    { ExprCompoundAssign (Mod, lhs, rhs, make_span $startpos $endpos !current_file) }
  | e=or_expr { e }

or_expr:
  | l=or_expr PIPE_PIPE r=and_expr { ExprBinary (Or, l, r, make_span $startpos $endpos !current_file) }
  | e=and_expr { e }

and_expr:
  | l=and_expr AMP_AMP r=bitor_expr { ExprBinary (And, l, r, make_span $startpos $endpos !current_file) }
  | e=bitor_expr { e }

bitor_expr:
  | l=bitor_expr PIPE r=bitxor_expr { ExprBinary (BitOr, l, r, make_span $startpos $endpos !current_file) }
  | e=bitxor_expr { e }

bitxor_expr:
  | l=bitxor_expr CARET r=bitand_expr { ExprBinary (BitXor, l, r, make_span $startpos $endpos !current_file) }
  | e=bitand_expr { e }

bitand_expr:
  | l=bitand_expr AMP r=equality_expr { ExprBinary (BitAnd, l, r, make_span $startpos $endpos !current_file) }
  | e=equality_expr { e }

equality_expr:
  | l=equality_expr EQ_EQ r=comparison_expr { ExprBinary (Eq, l, r, make_span $startpos $endpos !current_file) }
  | l=equality_expr BANG_EQ r=comparison_expr { ExprBinary (Ne, l, r, make_span $startpos $endpos !current_file) }
  | e=comparison_expr { e }

comparison_expr:
  | l=comparison_expr LT r=shift_expr { ExprBinary (Lt, l, r, make_span $startpos $endpos !current_file) }
  | l=comparison_expr GT r=shift_expr { ExprBinary (Gt, l, r, make_span $startpos $endpos !current_file) }
  | l=comparison_expr LT_EQ r=shift_expr { ExprBinary (Le, l, r, make_span $startpos $endpos !current_file) }
  | l=comparison_expr GT_EQ r=shift_expr { ExprBinary (Ge, l, r, make_span $startpos $endpos !current_file) }
  | e=shift_expr { e }

shift_expr:
  | l=shift_expr SHL r=additive_expr { ExprBinary (Shl, l, r, make_span $startpos $endpos !current_file) }
  | l=shift_expr SHR r=additive_expr { ExprBinary (Shr, l, r, make_span $startpos $endpos !current_file) }
  | e=additive_expr { e }

additive_expr:
  | l=additive_expr PLUS r=multiplicative_expr { ExprBinary (Add, l, r, make_span $startpos $endpos !current_file) }
  | l=additive_expr MINUS r=multiplicative_expr { ExprBinary (Sub, l, r, make_span $startpos $endpos !current_file) }
  | e=multiplicative_expr { e }

multiplicative_expr:
  | l=multiplicative_expr STAR r=unary_expr { ExprBinary (Mul, l, r, make_span $startpos $endpos !current_file) }
  | l=multiplicative_expr SLASH r=unary_expr { ExprBinary (Div, l, r, make_span $startpos $endpos !current_file) }
  | l=multiplicative_expr PERCENT r=unary_expr { ExprBinary (Mod, l, r, make_span $startpos $endpos !current_file) }
  | e=unary_expr { e }

unary_expr:
  | MINUS e=unary_expr { ExprUnary (Neg, e, make_span $startpos $endpos !current_file) }
  | BANG e=unary_expr { ExprUnary (Not, e, make_span $startpos $endpos !current_file) }
  | TILDE e=unary_expr { ExprUnary (BitNot, e, make_span $startpos $endpos !current_file) }
  | AMP e=unary_expr { ExprUnary (Ref, e, make_span $startpos $endpos !current_file) }
  | AMP MUT e=unary_expr { ExprUnary (RefMut, e, make_span $startpos $endpos !current_file) }
  | STAR e=unary_expr { ExprUnary (Deref, e, make_span $startpos $endpos !current_file) }
  | e=postfix_expr { e }

postfix_expr:
  | e=postfix_expr LPAREN args=separated_list(COMMA, expr) RPAREN
    { ExprCall (e, args, make_span $startpos $endpos !current_file) }
  | e=postfix_expr DOT name=IDENT LPAREN args=separated_list(COMMA, expr) RPAREN
    { ExprMethodCall (e, name, args, make_span $startpos $endpos !current_file) }
  | e=postfix_expr DOT name=IDENT
    { ExprField (e, name, make_span $startpos $endpos !current_file) }
  | e=postfix_expr DOT idx=INT_LIT
    { ExprTupleIndex (e, Int64.to_int idx, make_span $startpos $endpos !current_file) }
  | e=postfix_expr LBRACKET idx=expr RBRACKET
    { ExprIndex (e, idx, make_span $startpos $endpos !current_file) }
  | e=postfix_expr QUESTION
    { ExprTry (e, make_span $startpos $endpos !current_file) }
  | e=postfix_expr AS t=type_expr
    { ExprCast (e, t, make_span $startpos $endpos !current_file) }
  | e=primary_expr { e }

primary_expr:
  | l=literal { ExprLiteral (l, make_span $startpos $endpos !current_file) }
  | name=IDENT { ExprIdent (name, make_span $startpos $endpos !current_file) }
  | SELF_LOWER { ExprIdent ("self", make_span $startpos $endpos !current_file) }
  | path=path_expr { path }
  | LPAREN exprs=separated_list(COMMA, expr) RPAREN 
    { match exprs with
      | [e] -> e
      | _ -> ExprTuple (exprs, make_span $startpos $endpos !current_file) }
  | LBRACKET exprs=separated_list(COMMA, expr) RBRACKET
    { ExprArray (exprs, make_span $startpos $endpos !current_file) }
  | name=IDENT LBRACE fields=separated_list(COMMA, struct_field) RBRACE
    { ExprStruct (name, fields, make_span $startpos $endpos !current_file) }
  | if_expr { $1 }
  | match_expr { $1 }
  | while_expr { $1 }
  | for_expr { $1 }
  | loop_expr { $1 }
  | block_expr { $1 }
  | return_expr { $1 }
  | break_expr { $1 }
  | continue_expr { $1 }
  | unsafe_expr { $1 }

path_expr:
  | first=IDENT COLON_COLON rest=separated_nonempty_list(COLON_COLON, IDENT)
    { ExprPath (first :: rest, make_span $startpos $endpos !current_file) }

struct_field:
  | name=IDENT COLON e=expr { (name, e) }
  | name=IDENT { (name, ExprIdent (name, make_span $startpos $endpos !current_file)) }

if_expr:
  | IF cond=expr THEN? body=block elsifs=elsif* else_=else_? END
    { ExprIf (cond, body, elsifs, else_, make_span $startpos $endpos !current_file) }

elsif:
  | ELSIF cond=expr THEN? body=block { (cond, body) }

else_:
  | ELSE body=block { body }

match_expr:
  | MATCH e=expr DO? arms=match_arm* END
    { ExprMatch (e, arms, make_span $startpos $endpos !current_file) }

match_arm:
  | WHEN p=pattern guard=match_guard? FAT_ARROW body=expr SEMICOL?
    { { pattern = p; guard; body; arm_span = make_span $startpos $endpos !current_file } }

match_guard:
  | IF e=expr { e }

while_expr:
  | WHILE cond=expr DO? body=block END
    { ExprWhile (cond, body, make_span $startpos $endpos !current_file) }

for_expr:
  | FOR p=pattern IN iter=expr DO? body=block END
    { ExprFor (p, iter, body, make_span $startpos $endpos !current_file) }

loop_expr:
  | LOOP body=block END
    { ExprLoop (body, make_span $startpos $endpos !current_file) }

block_expr:
  | DO body=block END
    { ExprBlock (body, make_span $startpos $endpos !current_file) }

return_expr:
  | RETURN e=expr? { ExprReturn (e, make_span $startpos $endpos !current_file) }

break_expr:
  | BREAK label=IDENT? e=expr? { ExprBreak (label, e, make_span $startpos $endpos !current_file) }

continue_expr:
  | CONTINUE label=IDENT? { ExprContinue (label, make_span $startpos $endpos !current_file) }
  | NEXT label=IDENT? { ExprContinue (label, make_span $startpos $endpos !current_file) }

unsafe_expr:
  | UNSAFE body=block END
    { ExprUnsafe (body, make_span $startpos $endpos !current_file) }

literal:
  | i=INT_LIT { LitInt i }
  | f=FLOAT_LIT { LitFloat f }
  | s=STRING_LIT { LitString s }
  | c=CHAR_LIT { LitChar c }
  | TRUE { LitBool true }
  | FALSE { LitBool false }

(* Struct definition *)
struct_def:
  | vis=visibility STRUCT name=IDENT type_params=type_params?
    fields=field_def*
    END
    { { struct_vis = vis;
        struct_name = name;
        struct_type_params = Option.value ~default:[] type_params;
        struct_fields = fields;
        struct_span = make_span $startpos $endpos !current_file } }

field_def:
  | vis=visibility name=IDENT COLON t=type_expr
    { { field_vis = vis;
        field_name = name;
        field_type = t;
        field_span = make_span $startpos $endpos !current_file } }

(* Enum definition *)
enum_def:
  | vis=visibility ENUM name=IDENT type_params=type_params?
    variants=variant_def*
    END
    { { enum_vis = vis;
        enum_name = name;
        enum_type_params = Option.value ~default:[] type_params;
        enum_variants = variants;
        enum_span = make_span $startpos $endpos !current_file } }

variant_def:
  | name=IDENT fields=variant_fields?
    { { variant_name = name;
        variant_fields = Option.value ~default:[] fields;
        variant_span = make_span $startpos $endpos !current_file } }

variant_fields:
  | LPAREN fields=separated_nonempty_list(COMMA, variant_field) RPAREN { fields }

variant_field:
  | name=IDENT COLON t=type_expr 
    { { vf_name = Some name; vf_type = t; vf_span = make_span $startpos $endpos !current_file } }
  | t=type_expr 
    { { vf_name = None; vf_type = t; vf_span = make_span $startpos $endpos !current_file } }

(* Trait definition *)
trait_def:
  | vis=visibility TRAIT name=IDENT type_params=type_params?
    super=trait_super?
    items=trait_item*
    END
    { { trait_vis = vis;
        trait_name = name;
        trait_type_params = Option.value ~default:[] type_params;
        trait_super = Option.value ~default:[] super;
        trait_items = items;
        trait_span = make_span $startpos $endpos !current_file } }

trait_super:
  | COLON traits=separated_nonempty_list(PLUS, IDENT) { traits }

trait_item:
  | f=trait_method { TraitMethod f }
  | TYPE name=IDENT bounds=type_bounds? 
    { TraitType (name, Option.value ~default:[] bounds, make_span $startpos $endpos !current_file) }

trait_method:
  | DEF name=IDENT type_params=type_params?
    LPAREN params=separated_list(COMMA, param) RPAREN
    ret=return_type?
    body=trait_method_body?
    END?
    { { fn_vis = Public;
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
        fn_span = make_span $startpos $endpos !current_file } }

trait_method_body:
  | block END { $1 }

(* Impl block *)
impl_block:
  | IMPL type_params=type_params? trait_=impl_trait? FOR? for_type=type_expr
    where_clause=where_clause?
    items=impl_item*
    END
    { { impl_type_params = Option.value ~default:[] type_params;
        impl_trait = trait_;
        impl_for_type = for_type;
        impl_where_clause = Option.value ~default:[] where_clause;
        impl_items = items;
        impl_span = make_span $startpos $endpos !current_file } }

impl_trait:
  | name=IDENT args=type_args? FOR { (name, Option.value ~default:[] args) }

type_args:
  | LBRACKET args=separated_nonempty_list(COMMA, type_expr) RBRACKET { args }

impl_item:
  | f=function_def { ImplMethod f }
  | TYPE name=IDENT EQ t=type_expr { ImplType (name, t, make_span $startpos $endpos !current_file) }

(* Use declaration - handle path::path::{items} syntax *)
use_decl:
  | vis=visibility USE first=IDENT rest=use_path_rest
    { let (path, alias, glob, items) = rest first in
      { use_vis = vis;
        use_path = path;
        use_alias = alias;
        use_glob = glob;
        use_items = items;
        use_span = make_span $startpos $endpos !current_file } }

use_path_rest:
  | AS alias=IDENT 
    { fun first -> ([first], Some alias, false, []) }
  | COLON_COLON STAR 
    { fun first -> ([first], None, true, []) }
  | COLON_COLON LBRACE items=use_items RBRACE 
    { fun first -> ([first], None, false, items) }
  | COLON_COLON next=IDENT rest=use_path_rest 
    { fun first -> let (path, alias, glob, items) = rest next in (first :: path, alias, glob, items) }
  | 
    { fun first -> ([first], None, false, []) }

use_items:
  | items=separated_nonempty_list(COMMA, use_item) { items }

use_item:
  | name=IDENT AS alias=IDENT { (name, Some alias) }
  | name=IDENT { (name, None) }

(* Const declaration *)
const_decl:
  | vis=visibility CONST name=IDENT COLON t=type_expr EQ e=expr
    { { const_vis = vis;
        const_name = name;
        const_type = t;
        const_value = e;
        const_span = make_span $startpos $endpos !current_file } }

(* Type alias *)
type_alias:
  | vis=visibility TYPE name=IDENT type_params=type_params? EQ t=type_expr
    { { alias_vis = vis;
        alias_name = name;
        alias_type_params = Option.value ~default:[] type_params;
        alias_type = t;
        alias_span = make_span $startpos $endpos !current_file } }

(* Module declaration *)
module_decl:
  | vis=visibility MODULE name=IDENT items=item* END
    { { mod_vis = vis;
        mod_name = name;
        mod_items = Some items;
        mod_span = make_span $startpos $endpos !current_file } }
  | vis=visibility MODULE name=IDENT
    { { mod_vis = vis;
        mod_name = name;
        mod_items = None;
        mod_span = make_span $startpos $endpos !current_file } }

%%
