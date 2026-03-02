(** Menhir parser for Tangerine *)

%{
open Ast

let mk_loc startpos endpos =
  Location.of_lexing_positions ~file:"" startpos endpos

let loc_of_pos pos =
  let open Lexing in
  Location.{
    file = "";
    start = { line = pos.pos_lnum; column = pos.pos_cnum - pos.pos_bol; offset = pos.pos_cnum };
    stop = { line = pos.pos_lnum; column = pos.pos_cnum - pos.pos_bol; offset = pos.pos_cnum };
  }

%}

(* Tokens *)

(* Literals *)
%token <int64 * [`Dec | `Hex | `Bin | `Oct]> INT_LIT
%token <float> FLOAT_LIT
%token <string> STRING_LIT
%token <char> CHAR_LIT

(* Identifiers *)
%token <string> IDENT

(* Keywords *)
%token DEF END IF THEN ELSE ELSIF WHILE FOR IN DO
%token LET MUT RETURN BREAK NEXT MATCH WHEN
%token STRUCT ENUM TRAIT IMPL USE PUB MODULE
%token FN SELF_LOWER SELF_UPPER TRUE FALSE UNSAFE
%token WHERE AS TYPE CONST EXTERN SUPER CRATE YIELD ASYNC AWAIT EDITION
%token CAP EFFECT REQUIRES IMPLIES HANDLE WITH RATIONALE BUDGET
%token PRE POST INVARIANT GUARD
%token TRY CATCH FINALLY LOOP
%token MACRO COMPTIME PURE INLINE REF OWN MOVE COPY

(* Operators *)
%token PLUS MINUS STAR SLASH PERCENT
%token EQ_EQ BANG_EQ LT GT LT_EQ GT_EQ
%token AMP_AMP PIPE_PIPE BANG
%token AMP PIPE CARET TILDE SHL SHR
%token EQ PLUS_EQ MINUS_EQ STAR_EQ SLASH_EQ PERCENT_EQ
%token ARROW FAT_ARROW COLON_COLON
%token DOT_DOT DOT_DOT_EQ
%token QUESTION AT

(* Delimiters *)
%token LPAREN RPAREN LBRACKET RBRACKET LBRACE RBRACE
%token COLON COMMA DOT SEMICOL
%token HASH_LBRACKET

(* End of file *)
%token EOF

(* Precedence - lowest to highest *)
%right EQ PLUS_EQ MINUS_EQ STAR_EQ SLASH_EQ PERCENT_EQ
%left PIPE_PIPE
%left AMP_AMP
%left EQ_EQ BANG_EQ
%left LT GT LT_EQ GT_EQ
%left PIPE
%left CARET
%left AMP
%left SHL SHR
%left PLUS MINUS
%left STAR SLASH PERCENT
%right BANG TILDE UMINUS UREF UDEREF
%left DOT LBRACKET LPAREN QUESTION AS

(* Entry point *)
%start <Ast.program> program

%%

(* ===== Program Structure ===== *)

program:
  | edition = option(edition_decl) items = list(item) EOF
    { { prog_edition = edition;
        prog_items = items;
        prog_loc = mk_loc $startpos $endpos } }

edition_decl:
  | EDITION n = INT_LIT
    { let (v, _) = n in Int64.to_int v }

(* ===== Items ===== *)

item:
  | attrs = list(attribute) desc = item_desc
    { { item_attrs = attrs;
        item_desc = desc;
        item_loc = mk_loc $startpos $endpos } }

item_desc:
  | f = function_def       { ItemFn f }
  | s = struct_def         { ItemStruct s }
  | e = enum_def           { ItemEnum e }
  | t = trait_def          { ItemTrait t }
  | i = impl_def           { ItemImpl i }
  | u = use_decl           { ItemUse u }
  | c = const_decl         { ItemConst c }
  | a = type_alias         { ItemTypeAlias a }
  | e = extern_block       { ItemExtern e }
  | m = module_def         { ItemModule m }
  | c = cap_decl           { ItemCap c }
  | e = effect_decl        { ItemEffect e }
  | r = rationale_block    { ItemRationale r }
  | m = macro_def          { ItemMacro m }

(* ===== Attributes ===== *)

attribute:
  | HASH_LBRACKET name = ident args = option(attr_args) RBRACKET
    { { attr_name = name;
        attr_args = Option.value ~default:[] args;
        attr_loc = mk_loc $startpos $endpos } }
  | AT name = ident args = option(paren_attr_args)
    { { attr_name = name;
        attr_args = Option.value ~default:[] args;
        attr_loc = mk_loc $startpos $endpos } }

attr_args:
  | LPAREN args = separated_list(COMMA, attr_arg) RPAREN { args }

paren_attr_args:
  | LPAREN args = separated_list(COMMA, attr_arg) RPAREN { args }

attr_arg:
  | name = ident EQ lit = literal { AttrKeyValue (name, lit) }
  | name = ident                   { AttrIdent name }
  | lit = literal                  { AttrLit lit }

(* ===== Functions ===== *)

function_def:
  | vis = visibility pure = boption(PURE) inl = boption(INLINE) async = boption(ASYNC)
    DEF name = ident
    tparams = option(type_params)
    LPAREN params = separated_list(COMMA, param) RPAREN
    ret = option(return_type)
    wc = option(where_clause)
    clauses = list(fn_clause)
    body = fn_body
    { { fn_vis = vis;
        fn_name = name;
        fn_type_params = Option.value ~default:[] tparams;
        fn_params = params;
        fn_return = ret;
        fn_where = Option.value ~default:[] wc;
        fn_requires = List.concat_map (function `Req r -> r | _ -> []) clauses;
        fn_effects = List.concat_map (function `Eff e -> [e] | _ -> []) clauses;
        fn_budgets = List.concat_map (function `Bud b -> b | _ -> []) clauses;
        fn_contracts = List.concat_map (function `Con c -> [c] | _ -> []) clauses;
        fn_guards = List.concat_map (function `Gua g -> [g] | _ -> []) clauses;
        fn_body = body;
        fn_pure = pure;
        fn_inline = inl;
        fn_async = async;
        fn_loc = mk_loc $startpos $endpos } }

visibility:
  | PUB { Public }
  |     { Private }

return_type:
  | ARROW t = type_expr { t }

fn_body:
  | block = block END { FnBlock block }
  | EQ e = expr        { FnExpr e }

fn_clause:
  | r = requires_clause  { `Req r }
  | e = effect_clause    { `Eff e }
  | b = budget_clause    { `Bud b }
  | c = contract_clause  { `Con c }
  | g = guard_clause     { `Gua g }

requires_clause:
  | REQUIRES items = separated_nonempty_list(COMMA, requires_item)
    { items }

requires_item:
  | neg = boption(BANG) name = ident
    { { req_negated = neg;
        req_name = name;
        req_loc = mk_loc $startpos $endpos } }

effect_clause:
  | EFFECT name = ident targs = option(type_args)
    { (name, Option.value ~default:[] targs) }

budget_clause:
  | BUDGET entries = separated_nonempty_list(COMMA, budget_entry)
    { entries }

budget_entry:
  | name = ident COLON amt = budget_amount
    { { budget_name = name;
        budget_amount = amt;
        budget_loc = mk_loc $startpos $endpos } }

budget_amount:
  | n = INT_LIT unit = option(ident)
    { let (v, _) = n in BudgetInt (v, unit) }
  | s = STRING_LIT
    { BudgetString s }

contract_clause:
  | PRE e = expr msg = option(preceded(COMMA, STRING_LIT))
    { { contract_kind = Pre;
        contract_expr = e;
        contract_msg = msg;
        contract_loc = mk_loc $startpos $endpos } }
  | POST e = expr msg = option(preceded(COMMA, STRING_LIT))
    { { contract_kind = Post;
        contract_expr = e;
        contract_msg = msg;
        contract_loc = mk_loc $startpos $endpos } }
  | INVARIANT e = expr msg = option(preceded(COMMA, STRING_LIT))
    { { contract_kind = Invariant;
        contract_expr = e;
        contract_msg = msg;
        contract_loc = mk_loc $startpos $endpos } }

guard_clause:
  | GUARD cond = expr ELSE action = guard_action
    { { guard_cond = GuardExpr cond;
        guard_action = action;
        guard_loc = mk_loc $startpos $endpos } }
  | GUARD LET pat = pattern EQ e = expr ELSE action = guard_action
    { { guard_cond = GuardLet (pat, e);
        guard_action = action;
        guard_loc = mk_loc $startpos $endpos } }

guard_action:
  | RETURN e = option(expr) { GuardReturn e }
  | BREAK lbl = option(ident) { GuardBreak lbl }
  | NEXT lbl = option(ident) { GuardNext lbl }
  | PANIC LPAREN e = expr RPAREN { GuardPanic e }

PANIC:
  | i = IDENT { if i <> "panic" then $syntaxerror else () }

(* ===== Parameters ===== *)

param:
  | m = boption(MUT) name = ident COLON t = type_expr
    { { param_mut = if m then Mutable else Immutable;
        param_name = name;
        param_type = t;
        param_loc = mk_loc $startpos $endpos } }

type_params:
  | LBRACKET params = separated_nonempty_list(COMMA, type_param) RBRACKET
    { params }

type_param:
  | name = ident bounds = option(type_bounds)
    { { tp_name = name;
        tp_bounds = Option.value ~default:[] bounds;
        tp_loc = mk_loc $startpos $endpos } }

type_bounds:
  | COLON bounds = separated_nonempty_list(PLUS, simple_path)
    { bounds }

type_args:
  | LBRACKET args = separated_nonempty_list(COMMA, type_expr) RBRACKET
    { args }

where_clause:
  | WHERE preds = separated_nonempty_list(COMMA, where_pred)
    { preds }

where_pred:
  | t = type_expr COLON bounds = separated_nonempty_list(PLUS, simple_path)
    { { wp_type = t;
        wp_bounds = bounds;
        wp_loc = mk_loc $startpos $endpos } }

(* ===== Structs ===== *)

struct_def:
  | vis = visibility STRUCT name = ident tparams = option(type_params)
    fields = list(field_def)
    invs = list(struct_invariant)
    END
    { { struct_vis = vis;
        struct_name = name;
        struct_type_params = Option.value ~default:[] tparams;
        struct_fields = fields;
        struct_invariants = invs;
        struct_loc = mk_loc $startpos $endpos } }

field_def:
  | vis = visibility name = ident COLON t = type_expr option(COMMA)
    { { field_vis = vis;
        field_name = name;
        field_type = t;
        field_loc = mk_loc $startpos $endpos } }

struct_invariant:
  | INVARIANT e = expr msg = option(preceded(COMMA, STRING_LIT))
    { { contract_kind = Invariant;
        contract_expr = e;
        contract_msg = msg;
        contract_loc = mk_loc $startpos $endpos } }

(* ===== Enums ===== *)

enum_def:
  | vis = visibility ENUM name = ident tparams = option(type_params)
    variants = list(variant_def)
    END
    { { enum_vis = vis;
        enum_name = name;
        enum_type_params = Option.value ~default:[] tparams;
        enum_variants = variants;
        enum_loc = mk_loc $startpos $endpos } }

variant_def:
  | name = ident fields = variant_fields
    { { variant_name = name;
        variant_fields = fields;
        variant_loc = mk_loc $startpos $endpos } }

variant_fields:
  |                                                    { VariantUnit }
  | LPAREN ts = separated_list(COMMA, type_expr) RPAREN { VariantTuple ts }

(* ===== Traits ===== *)

trait_def:
  | vis = visibility TRAIT name = ident tparams = option(type_params)
    super = option(preceded(COLON, type_bounds_path))
    items = list(trait_item)
    END
    { { trait_vis = vis;
        trait_name = name;
        trait_type_params = Option.value ~default:[] tparams;
        trait_super = Option.value ~default:[] super;
        trait_items = items;
        trait_loc = mk_loc $startpos $endpos } }

type_bounds_path:
  | bounds = separated_nonempty_list(PLUS, simple_path)
    { bounds }

trait_item:
  | f = function_def { TraitFn f }
  | s = function_sig { TraitFn s }

function_sig:
  | DEF name = ident
    tparams = option(type_params)
    LPAREN params = separated_list(COMMA, param) RPAREN
    ret = option(return_type)
    { { fn_vis = Private;
        fn_name = name;
        fn_type_params = Option.value ~default:[] tparams;
        fn_params = params;
        fn_return = ret;
        fn_where = [];
        fn_requires = [];
        fn_effects = [];
        fn_budgets = [];
        fn_contracts = [];
        fn_guards = [];
        fn_body = FnSig;
        fn_pure = false;
        fn_inline = false;
        fn_async = false;
        fn_loc = mk_loc $startpos $endpos } }

(* ===== Implementations ===== *)

impl_def:
  | IMPL tparams = option(type_params)
    tr = option(terminated(ident, FOR))
    ty = type_expr
    wc = option(where_clause)
    items = list(function_def)
    END
    { { impl_type_params = Option.value ~default:[] tparams;
        impl_trait = Option.map (fun i -> { segments = [i]; path_loc = i.loc }) tr;
        impl_for_type = ty;
        impl_where = Option.value ~default:[] wc;
        impl_items = items;
        impl_loc = mk_loc $startpos $endpos } }

(* ===== Use Declarations ===== *)

use_decl:
  | USE tree = use_tree
    { { use_tree = tree;
        use_loc = mk_loc $startpos $endpos } }

use_tree:
  | segs = use_path COLON_COLON STAR
    { UseGlob segs }
  | segs = use_path COLON_COLON LBRACE items = separated_list(COMMA, use_item) RBRACE
    { UseGroup (segs, items) }
  | segs = use_path
    { UsePath segs }

use_path:
  | segs = separated_nonempty_list(COLON_COLON, ident)
    { segs }

use_item:
  | name = ident alias = option(preceded(AS, ident))
    { { use_name = name; use_alias = alias } }

(* ===== Constants and Type Aliases ===== *)

const_decl:
  | vis = visibility CONST name = ident COLON t = type_expr EQ e = expr
    { { const_vis = vis;
        const_name = name;
        const_type = t;
        const_value = e;
        const_loc = mk_loc $startpos $endpos } }

type_alias:
  | vis = visibility TYPE name = ident tparams = option(type_params) EQ t = type_expr
    { { alias_vis = vis;
        alias_name = name;
        alias_type_params = Option.value ~default:[] tparams;
        alias_type = t;
        alias_loc = mk_loc $startpos $endpos } }

(* ===== Extern Blocks ===== *)

extern_block:
  | EXTERN abi = option(STRING_LIT) fns = extern_fns
    { { extern_abi = abi;
        extern_fns = fns;
        extern_loc = mk_loc $startpos $endpos } }

extern_fns:
  | f = extern_fn { [f] }
  | option(DO) fns = list(extern_fn) END { fns }
  | LBRACE fns = list(extern_fn) RBRACE { fns }

extern_fn:
  | DEF name = ident
    tparams = option(type_params)
    LPAREN params = separated_list(COMMA, param) RPAREN
    ret = option(return_type)
    { { extern_name = name;
        extern_type_params = Option.value ~default:[] tparams;
        extern_params = params;
        extern_return = ret;
        extern_loc = mk_loc $startpos $endpos } }

(* ===== Modules ===== *)

module_def:
  | vis = visibility MODULE name = ident items = module_items
    { { mod_vis = vis;
        mod_name = name;
        mod_items = items;
        mod_loc = mk_loc $startpos $endpos } }

module_items:
  | END { None }  (* empty module *)
  | items = nonempty_list(item) END { Some items }
  |       { None } (* file-based module *)

(* ===== Capabilities ===== *)

cap_decl:
  | CAP name = ident implied = option(cap_implies) END
    { { cap_name = name;
        cap_implies = Option.value ~default:[] implied;
        cap_loc = mk_loc $startpos $endpos } }

cap_implies:
  | IMPLIES names = separated_nonempty_list(COMMA, ident)
    { names }

(* ===== Effects ===== *)

effect_decl:
  | EFFECT name = ident tparams = option(type_params)
    ops = list(effect_op)
    END
    { { effect_name = name;
        effect_type_params = Option.value ~default:[] tparams;
        effect_ops = ops;
        effect_loc = mk_loc $startpos $endpos } }

effect_op:
  | name = ident LPAREN params = separated_list(COMMA, param) RPAREN ret = option(return_type)
    { { eop_name = name;
        eop_params = params;
        eop_return = ret;
        eop_loc = mk_loc $startpos $endpos } }

(* ===== Rationale ===== *)

rationale_block:
  | RATIONALE fields = list(rationale_field) END
    { { rationale_fields = fields;
        rationale_loc = mk_loc $startpos $endpos } }

rationale_field:
  | name = ident COLON value = rationale_value
    { { rat_name = name;
        rat_value = value;
        rat_loc = mk_loc $startpos $endpos } }

rationale_value:
  | s = STRING_LIT { RatString s }
  | e = expr       { RatExpr e }

(* ===== Macros ===== *)

macro_def:
  | MACRO name = ident LPAREN params = separated_list(COMMA, macro_param) RPAREN
    body = block
    END
    { { macro_name = name;
        macro_params = params;
        macro_body = body;
        macro_loc = mk_loc $startpos $endpos } }

macro_param:
  | name = ident COLON ty = macro_type
    { { mp_name = name; mp_type = ty } }

macro_type:
  | i = IDENT
    { match i with
      | "Expr" -> MacroExpr
      | "Ident" -> MacroIdent
      | "Type" -> MacroType
      | "Block" -> MacroBlock
      | "Pattern" -> MacroPattern
      | _ -> $syntaxerror }

(* ===== Types ===== *)

type_expr:
  | t = type_primary QUESTION
    { { ty_desc = TyOption t;
        ty_loc = mk_loc $startpos $endpos } }
  | t = type_primary
    { t }

type_primary:
  | path = simple_path targs = option(type_args)
    { { ty_desc = TyName (path, Option.value ~default:[] targs);
        ty_loc = mk_loc $startpos $endpos } }
  | LPAREN RPAREN
    { { ty_desc = TyUnit; ty_loc = mk_loc $startpos $endpos } }
  | LPAREN ts = separated_nonempty_list(COMMA, type_expr) RPAREN
    { { ty_desc = TyTuple ts; ty_loc = mk_loc $startpos $endpos } }
  | AMP m = boption(MUT) t = type_expr
    { { ty_desc = TyRef ((if m then Mutable else Immutable), t);
        ty_loc = mk_loc $startpos $endpos } }
  | STAR m = boption(MUT) t = type_expr
    { { ty_desc = TyPtr ((if m then Mutable else Immutable), t);
        ty_loc = mk_loc $startpos $endpos } }
  | LBRACKET t = type_expr SEMICOL n = expr RBRACKET
    { { ty_desc = TyArray (t, n); ty_loc = mk_loc $startpos $endpos } }
  | LBRACKET t = type_expr RBRACKET
    { { ty_desc = TySlice t; ty_loc = mk_loc $startpos $endpos } }
  | FN LPAREN ts = separated_list(COMMA, type_expr) RPAREN ARROW r = type_expr
    { { ty_desc = TyFn (ts, r); ty_loc = mk_loc $startpos $endpos } }
  | SELF_UPPER
    { { ty_desc = TySelf; ty_loc = mk_loc $startpos $endpos } }

(* ===== Expressions ===== *)

expr:
  | e = assignment_expr { e }

assignment_expr:
  | lhs = range_expr op = assign_op rhs = assignment_expr
    { { expr_desc = ExprBinop (op, lhs, rhs);
        expr_loc = mk_loc $startpos $endpos } }
  | e = range_expr { e }

%inline assign_op:
  | EQ { OpAssign }
  | PLUS_EQ { OpAddAssign }
  | MINUS_EQ { OpSubAssign }
  | STAR_EQ { OpMulAssign }
  | SLASH_EQ { OpDivAssign }
  | PERCENT_EQ { OpModAssign }

range_expr:
  | e1 = or_expr DOT_DOT e2 = or_expr
    { { expr_desc = ExprRange (Some e1, Some e2, false);
        expr_loc = mk_loc $startpos $endpos } }
  | e1 = or_expr DOT_DOT_EQ e2 = or_expr
    { { expr_desc = ExprRange (Some e1, Some e2, true);
        expr_loc = mk_loc $startpos $endpos } }
  | e = or_expr { e }

or_expr:
  | e1 = or_expr PIPE_PIPE e2 = and_expr
    { { expr_desc = ExprBinop (OpOr, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e = and_expr { e }

and_expr:
  | e1 = and_expr AMP_AMP e2 = eq_expr
    { { expr_desc = ExprBinop (OpAnd, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e = eq_expr { e }

eq_expr:
  | e1 = eq_expr EQ_EQ e2 = cmp_expr
    { { expr_desc = ExprBinop (OpEq, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e1 = eq_expr BANG_EQ e2 = cmp_expr
    { { expr_desc = ExprBinop (OpNe, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e = cmp_expr { e }

cmp_expr:
  | e1 = cmp_expr LT e2 = bitor_expr
    { { expr_desc = ExprBinop (OpLt, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e1 = cmp_expr GT e2 = bitor_expr
    { { expr_desc = ExprBinop (OpGt, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e1 = cmp_expr LT_EQ e2 = bitor_expr
    { { expr_desc = ExprBinop (OpLe, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e1 = cmp_expr GT_EQ e2 = bitor_expr
    { { expr_desc = ExprBinop (OpGe, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e = bitor_expr { e }

bitor_expr:
  | e1 = bitor_expr PIPE e2 = bitxor_expr
    { { expr_desc = ExprBinop (OpBitOr, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e = bitxor_expr { e }

bitxor_expr:
  | e1 = bitxor_expr CARET e2 = bitand_expr
    { { expr_desc = ExprBinop (OpBitXor, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e = bitand_expr { e }

bitand_expr:
  | e1 = bitand_expr AMP e2 = shift_expr
    { { expr_desc = ExprBinop (OpBitAnd, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e = shift_expr { e }

shift_expr:
  | e1 = shift_expr SHL e2 = add_expr
    { { expr_desc = ExprBinop (OpShl, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e1 = shift_expr SHR e2 = add_expr
    { { expr_desc = ExprBinop (OpShr, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e = add_expr { e }

add_expr:
  | e1 = add_expr PLUS e2 = mul_expr
    { { expr_desc = ExprBinop (OpAdd, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e1 = add_expr MINUS e2 = mul_expr
    { { expr_desc = ExprBinop (OpSub, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e = mul_expr { e }

mul_expr:
  | e1 = mul_expr STAR e2 = unary_expr
    { { expr_desc = ExprBinop (OpMul, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e1 = mul_expr SLASH e2 = unary_expr
    { { expr_desc = ExprBinop (OpDiv, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e1 = mul_expr PERCENT e2 = unary_expr
    { { expr_desc = ExprBinop (OpMod, e1, e2);
        expr_loc = mk_loc $startpos $endpos } }
  | e = unary_expr { e }

unary_expr:
  | MINUS e = unary_expr %prec UMINUS
    { { expr_desc = ExprUnop (OpNeg, e);
        expr_loc = mk_loc $startpos $endpos } }
  | BANG e = unary_expr
    { { expr_desc = ExprUnop (OpNot, e);
        expr_loc = mk_loc $startpos $endpos } }
  | AMP e = unary_expr %prec UREF
    { { expr_desc = ExprUnop (OpRef, e);
        expr_loc = mk_loc $startpos $endpos } }
  | AMP MUT e = unary_expr %prec UREF
    { { expr_desc = ExprUnop (OpRefMut, e);
        expr_loc = mk_loc $startpos $endpos } }
  | STAR e = unary_expr %prec UDEREF
    { { expr_desc = ExprUnop (OpDeref, e);
        expr_loc = mk_loc $startpos $endpos } }
  | e = postfix_expr { e }

postfix_expr:
  | e = postfix_expr DOT name = ident LPAREN args = separated_list(COMMA, expr) RPAREN
    { { expr_desc = ExprMethodCall (e, name, [], args);
        expr_loc = mk_loc $startpos $endpos } }
  | e = postfix_expr DOT name = ident
    { { expr_desc = ExprField (e, name);
        expr_loc = mk_loc $startpos $endpos } }
  | e = postfix_expr LPAREN args = separated_list(COMMA, expr) RPAREN
    { { expr_desc = ExprCall (e, args);
        expr_loc = mk_loc $startpos $endpos } }
  | e = postfix_expr LBRACKET idx = expr RBRACKET
    { { expr_desc = ExprIndex (e, idx);
        expr_loc = mk_loc $startpos $endpos } }
  | e = postfix_expr QUESTION
    { { expr_desc = ExprTry e;
        expr_loc = mk_loc $startpos $endpos } }
  | e = postfix_expr AS t = type_expr
    { { expr_desc = ExprCast (e, t);
        expr_loc = mk_loc $startpos $endpos } }
  | e = primary_expr { e }

primary_expr:
  | lit = literal
    { { expr_desc = ExprLit lit;
        expr_loc = mk_loc $startpos $endpos } }
  | path = expr_path
    { { expr_desc = ExprPath path;
        expr_loc = mk_loc $startpos $endpos } }
  | path = simple_path LBRACE fields = separated_list(COMMA, field_init) RBRACE
    { { expr_desc = ExprStruct (path, fields);
        expr_loc = mk_loc $startpos $endpos } }
  | LPAREN RPAREN
    { { expr_desc = ExprLit LitUnit;
        expr_loc = mk_loc $startpos $endpos } }
  | LPAREN e = expr RPAREN
    { e }
  | LPAREN e = expr COMMA es = separated_nonempty_list(COMMA, expr) RPAREN
    { { expr_desc = ExprTuple (e :: es);
        expr_loc = mk_loc $startpos $endpos } }
  | LBRACKET es = separated_list(COMMA, expr) RBRACKET
    { { expr_desc = ExprArray es;
        expr_loc = mk_loc $startpos $endpos } }
  | e = if_expr { e }
  | e = match_expr { e }
  | e = while_expr { e }
  | e = for_expr { e }
  | e = loop_expr { e }
  | e = block_expr { e }
  | e = closure_expr { e }
  | e = return_expr { e }
  | e = break_expr { e }
  | NEXT
    { { expr_desc = ExprNext;
        expr_loc = mk_loc $startpos $endpos } }
  | e = handle_expr { e }
  | e = try_expr { e }
  | e = unsafe_expr { e }
  | name = ident BANG LPAREN args = separated_list(COMMA, expr) RPAREN
    { { expr_desc = ExprMacro (name, args);
        expr_loc = mk_loc $startpos $endpos } }

literal:
  | n = INT_LIT
    { let (v, base) = n in
      let b = match base with
        | `Dec -> Dec | `Hex -> Hex | `Bin -> Bin | `Oct -> Oct
      in LitInt (v, b) }
  | f = FLOAT_LIT { LitFloat f }
  | s = STRING_LIT { LitString s }
  | c = CHAR_LIT { LitChar c }
  | TRUE { LitBool true }
  | FALSE { LitBool false }

field_init:
  | name = ident COLON e = expr
    { { fi_name = name;
        fi_value = Some e;
        fi_loc = mk_loc $startpos $endpos } }
  | name = ident
    { { fi_name = name;
        fi_value = None;
        fi_loc = mk_loc $startpos $endpos } }

if_expr:
  | IF cond = expr option(THEN) then_block = block
    elsifs = list(elsif)
    else_block = option(else_block)
    END
    { { expr_desc = ExprIf (cond, then_block, elsifs, else_block);
        expr_loc = mk_loc $startpos $endpos } }

elsif:
  | ELSIF cond = expr option(THEN) body = block
    { { elsif_cond = cond;
        elsif_body = body;
        elsif_loc = mk_loc $startpos $endpos } }

else_block:
  | ELSE b = block { b }

match_expr:
  | MATCH e = expr arms = list(match_arm) END
    { { expr_desc = ExprMatch (e, arms);
        expr_loc = mk_loc $startpos $endpos } }

match_arm:
  | WHEN pat = pattern guard = option(preceded(IF, expr)) THEN body = arm_body
    { { arm_pattern = pat;
        arm_guard = guard;
        arm_body = body;
        arm_loc = mk_loc $startpos $endpos } }

arm_body:
  | e = expr { e }
  | b = block END
    { { expr_desc = ExprBlock b;
        expr_loc = mk_loc $startpos $endpos } }

while_expr:
  | WHILE cond = expr option(DO) body = block END
    { { expr_desc = ExprWhile (cond, body);
        expr_loc = mk_loc $startpos $endpos } }

for_expr:
  | FOR var = ident IN iter = expr option(DO) body = block END
    { { expr_desc = ExprFor (var, iter, body);
        expr_loc = mk_loc $startpos $endpos } }

loop_expr:
  | LOOP body = block END
    { { expr_desc = ExprLoop body;
        expr_loc = mk_loc $startpos $endpos } }

block_expr:
  | DO body = block END
    { { expr_desc = ExprBlock body;
        expr_loc = mk_loc $startpos $endpos } }

block:
  | stmts = list(stmt) final = option(expr)
    { { block_stmts = stmts;
        block_expr = final;
        block_loc = mk_loc $startpos $endpos } }

stmt:
  | LET m = boption(MUT) pat = pattern ty = option(preceded(COLON, type_expr)) EQ e = expr
    { { stmt_desc = StmtLet ((if m then Mutable else Immutable), pat, ty, e);
        stmt_loc = mk_loc $startpos $endpos } }
  | MUT pat = pattern ty = option(preceded(COLON, type_expr)) EQ e = expr
    { { stmt_desc = StmtLet (Mutable, pat, ty, e);
        stmt_loc = mk_loc $startpos $endpos } }
  | e = expr_stmt
    { { stmt_desc = StmtExpr e;
        stmt_loc = mk_loc $startpos $endpos } }

expr_stmt:
  (* Statements that don't need terminators *)
  | e = if_expr { e }
  | e = match_expr { e }
  | e = while_expr { e }
  | e = for_expr { e }
  | e = loop_expr { e }
  (* Simple expressions - can appear as statements *)
  | e = assignment_expr { e }

closure_expr:
  | PIPE params = separated_list(COMMA, closure_param) PIPE
    ret = option(preceded(ARROW, type_expr))
    body = closure_body
    { { expr_desc = ExprClosure (params, ret, body);
        expr_loc = mk_loc $startpos $endpos } }

closure_param:
  | m = boption(MUT) name = ident ty = option(preceded(COLON, type_expr))
    { { cp_mut = if m then Mutable else Immutable;
        cp_name = name;
        cp_type = ty } }

closure_body:
  | e = expr { e }
  | b = block END
    { { expr_desc = ExprBlock b;
        expr_loc = mk_loc $startpos $endpos } }

return_expr:
  | RETURN e = option(expr)
    { { expr_desc = ExprReturn e;
        expr_loc = mk_loc $startpos $endpos } }

break_expr:
  | BREAK e = option(expr)
    { { expr_desc = ExprBreak e;
        expr_loc = mk_loc $startpos $endpos } }

handle_expr:
  | HANDLE e = expr WITH name = ident arms = list(handler_arm) END
    { { expr_desc = ExprHandle (e, name, arms);
        expr_loc = mk_loc $startpos $endpos } }

handler_arm:
  | name = ident LPAREN params = separated_list(COMMA, pattern) RPAREN FAT_ARROW body = expr
    { { handler_name = name;
        handler_params = params;
        handler_body = body;
        handler_loc = mk_loc $startpos $endpos } }

try_expr:
  | TRY body = block catches = list(catch_arm) finally = option(finally_block) END
    { { expr_desc = ExprTryCatch (body, catches, finally);
        expr_loc = mk_loc $startpos $endpos } }

catch_arm:
  | CATCH pat = pattern THEN body = block
    { { catch_pattern = pat;
        catch_body = body;
        catch_loc = mk_loc $startpos $endpos } }

finally_block:
  | FINALLY b = block { b }

unsafe_expr:
  | UNSAFE reason = option(STRING_LIT) body = block END
    { { expr_desc = ExprUnsafe (reason, body);
        expr_loc = mk_loc $startpos $endpos } }

(* ===== Patterns ===== *)

pattern:
  | p1 = pattern_primary PIPE p2 = pattern
    { { pat_desc = PatOr (p1, p2);
        pat_loc = mk_loc $startpos $endpos } }
  | p = pattern_primary { p }

pattern_primary:
  | UNDERSCORE
    { { pat_desc = PatWildcard; pat_loc = mk_loc $startpos $endpos } }
  | name = ident
    { { pat_desc = PatIdent (Immutable, name);
        pat_loc = mk_loc $startpos $endpos } }
  | MUT name = ident
    { { pat_desc = PatIdent (Mutable, name);
        pat_loc = mk_loc $startpos $endpos } }
  | REF name = ident
    { { pat_desc = PatRef (Immutable, { pat_desc = PatIdent (Immutable, name);
                                         pat_loc = mk_loc $startpos $endpos });
        pat_loc = mk_loc $startpos $endpos } }
  | REF MUT name = ident
    { { pat_desc = PatRef (Mutable, { pat_desc = PatIdent (Immutable, name);
                                       pat_loc = mk_loc $startpos $endpos });
        pat_loc = mk_loc $startpos $endpos } }
  | lit = literal
    { { pat_desc = PatLiteral lit;
        pat_loc = mk_loc $startpos $endpos } }
  | LPAREN RPAREN
    { { pat_desc = PatTuple [];
        pat_loc = mk_loc $startpos $endpos } }
  | LPAREN ps = separated_nonempty_list(COMMA, pattern) RPAREN
    { { pat_desc = PatTuple ps;
        pat_loc = mk_loc $startpos $endpos } }
  | path = simple_path LBRACE fields = separated_list(COMMA, field_pattern) RBRACE
    { { pat_desc = PatStruct (path, fields);
        pat_loc = mk_loc $startpos $endpos } }
  | path = simple_path LPAREN ps = separated_list(COMMA, pattern) RPAREN
    { { pat_desc = PatEnum (path, Some ps);
        pat_loc = mk_loc $startpos $endpos } }
  | path = qualified_path
    { { pat_desc = PatEnum (path, None);
        pat_loc = mk_loc $startpos $endpos } }

UNDERSCORE:
  | i = IDENT { if i <> "_" then $syntaxerror else () }

field_pattern:
  | name = ident COLON pat = pattern
    { { fp_name = name;
        fp_pattern = Some pat;
        fp_loc = mk_loc $startpos $endpos } }
  | name = ident
    { { fp_name = name;
        fp_pattern = None;
        fp_loc = mk_loc $startpos $endpos } }

(* ===== Paths ===== *)

ident:
  | s = IDENT
    { { name = s; loc = mk_loc $startpos $endpos } }
  | SELF_LOWER
    { { name = "self"; loc = mk_loc $startpos $endpos } }

simple_path:
  | segs = separated_nonempty_list(COLON_COLON, ident)
    { { segments = segs; path_loc = mk_loc $startpos $endpos } }

qualified_path:
  | seg1 = ident COLON_COLON seg2 = ident
    { { segments = [seg1; seg2]; path_loc = mk_loc $startpos $endpos } }

expr_path:
  | segs = separated_nonempty_list(COLON_COLON, ident)
    { { segments = segs; path_loc = mk_loc $startpos $endpos } }
