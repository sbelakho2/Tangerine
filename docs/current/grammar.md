# Tangerine Formal Grammar Specification

**Version:** 2.0.0 (Edition 2026)

This document describes the grammar as **implemented** by the self-hosting
compiler (`tg_compiler/parser.tg`, `tg_compiler/lexer.tg`,
`tg_compiler/token.tg`). It supersedes version 0.1.0, which described a
planned reference-borrowing language (`&T` / `&mut T` safe references) that
was never implemented. The implemented language has no safe reference types;
access is expressed through **parameter conventions** (`inout`, `sink`, `set`,
`let`) and explicit **access markers** (`&place`) at call sites.

## Notation

This grammar uses Extended Backus-Naur Form (EBNF) with the following conventions:

- `'keyword'` — Terminal (keyword or symbol)
- `UPPER_CASE` — Token produced by the lexer
- `lower_case` — Non-terminal (grammar rule)
- `( ... )` — Grouping
- `[ ... ]` — Optional (zero or one)
- `{ ... }` — Repetition (zero or more)
- `|` — Alternative
- `//` — Comment

## 1. Lexical Grammar

### 1.1 Whitespace and Comments

```ebnf
WHITESPACE     = ' ' | '\t' | '\r' | '\n'
NEWLINE        = '\n'
COMMENT        = '#' { any_char_except_newline } NEWLINE
DOC_COMMENT    = '##' { any_char_except_newline } NEWLINE
BLOCK_COMMENT  = '#|' { BLOCK_COMMENT | any_char_except_block_comment_close } '|#'
```

### 1.2 Identifiers

```ebnf
IDENT          = ( ALPHA | '_' ) { ALPHA | DIGIT | '_' }
ALPHA          = 'a'..'z' | 'A'..'Z'
DIGIT          = '0'..'9'
```

### 1.3 Keywords

The lexer recognizes the following keywords (`token.tg` `init_keyword_map`):

```text
def    end    do     if     elsif  else   while  for    in     loop
match  when   then   unless until  let    mut    var    return break
next   struct enum   trait  impl   module mod    use    as     pub
private macro  where  true   false  nil    self   fn     Self   super
crate  move   copy   drop   own    ref    inout  sink   set    resource
deinit pre    post   invariant cap   unsafe rationale budget edition
requires ensures effect pure   async  await  defer  try    catch
finally guard  handle with   is     implies comptime const  static type
typealias alias  extern inline
```

**Canonical spellings and aliases:**

- `var` is the canonical mutable-local keyword; `mut` in local position is a
  legacy alias and both lex to the same token. In PARAMETER position `mut`
  is a legacy spelling that is REJECTED (E100, see §2.3); `mut` also
  appears in the `*mut T` marker.
- `fn` is accepted as an alias for `def` (both lex to `Def`). `def` is the
  canonical function keyword; `fn` additionally appears in function-pointer
  type spellings.
- `module` is canonical; `mod` is accepted as a compatibility alias.
- `typealias` and `alias` are accepted aliases of `type` (item position).
- `next` and `continue` are aliases (both lex to `Next`).
- `move` and `own` were legacy aliases for the `sink` convention; in
  parameter position they are REJECTED (E100, see §2.3) — the `sink`
  keyword is the only canonical form.
- `super` and `crate` are contextual identifiers usable inside paths.
- `self` is the receiver identifier; `Self` is the receiver type.

### 1.4 Literals

```ebnf
INT_LITERAL    = DEC_NUM | '0x' HEX_NUM | '0b' BIN_NUM | '0o' OCT_NUM
DEC_NUM        = DIGIT { DIGIT | '_' } [ NUM_SUFFIX ]
HEX_NUM        = HEX_DIGIT { HEX_DIGIT | '_' }
BIN_NUM        = '0' | '1' { '0' | '1' | '_' }
OCT_NUM        = '0'..'7' { '0'..'7' | '_' }
NUM_SUFFIX     = 'u' | 'u8' | 'u16' | 'u32' | 'u64'
               | 'i8' | 'i16' | 'i32' | 'i64'
               | 'f32' | 'f64' | 'usize' | 'isize'

FLOAT_LITERAL  = DEC_NUM '.' DIGIT { DIGIT | '_' } [ EXPONENT ] [ FLOAT_SUFFIX ]
               | DEC_NUM EXPONENT [ FLOAT_SUFFIX ]
FLOAT_SUFFIX   = 'f32' | 'f64'
EXPONENT       = ( 'e' | 'E' ) [ '+' | '-' ] DIGIT { DIGIT | '_' }

STRING_LITERAL = '"' { STRING_CHAR | ESCAPE_SEQ } '"'
STRING_CHAR    = any_char_except_quote_backslash_newline
ESCAPE_SEQ     = '\' ( 'n' | 'r' | 't' | '\\' | '"' | '0'
                       | 'x' HEX_DIGIT HEX_DIGIT
                       | 'u' '{' HEX_DIGIT { HEX_DIGIT } '}' )

CHAR_LITERAL   = "'" ( CHAR_CHAR | ESCAPE_SEQ ) "'"
CHAR_CHAR      = any_char_except_quote_backslash_newline

HEX_DIGIT      = '0'..'9' | 'a'..'f' | 'A'..'F'
```

### 1.5 Operators and Punctuation

```ebnf
// Arithmetic
PLUS     = '+'    MINUS    = '-'    STAR     = '*'    DOUBLE_STAR = '**'
SLASH    = '/'    PERCENT  = '%'

// Comparison
EQ_EQ    = '=='   BANG_EQ  = '!='   LT       = '<'    GT       = '>'
LT_EQ    = '<='   GT_EQ    = '>='

// Logical
AND      = '&&'   OR       = '||'   BANG     = '!'

// Bitwise
AMP      = '&'    AMP_MUT  = '&mut' PIPE     = '|'    CARET    = '^'
TILDE    = '~'    SHL      = '<<'   SHR      = '>>'

// Assignment (statement position only)
EQ       = '='    PLUS_EQ  = '+='   MINUS_EQ = '-='   STAR_EQ  = '*='
SLASH_EQ = '/='   PERCENT_EQ = '%='

// Delimiters
LPAREN   = '('    RPAREN   = ')'    LBRACKET = '['    RBRACKET = ']'
LBRACE   = '{'    RBRACE   = '}'

// Other
ARROW    = '->'   FAT_ARROW = '=>'  COLON_COLON = '::'
COLON    = ':'    COMMA    = ','    DOT      = '.'    DOT_DOT  = '..'
DOT_DOT_EQ = '..=' SEMICOL = ';'    QUESTION = '?'    HASH     = '#'
AT       = '@'    PIPE_ARROW = '|>'
```

## 2. Items

### 2.1 Program Structure

```ebnf
program        = { item }

item           = [ vis ] ( function_def
               | use_decl
               | module_decl
               | struct_def
               | resource_def
               | enum_def
               | trait_def
               | impl_block
               | type_alias
               | const_decl
               | static_decl
               | capability_decl
               | extern_item
               | edition_decl
               | macro_decl
               | rationale_block )

vis            = 'pub' | 'private'
```

Items are separated by newlines; a trailing `;` after an item is optional
(`eat_optional_semi`). `struct`, `resource`, `enum`, `impl`, `def`, `use`,
and `@attr`-prefixed functions may also appear in statement position inside
function bodies (`parser.tg` `parse_stmt`).

### 2.2 Functions

```ebnf
function_def   = { fn_modifier } 'def' IDENT [ type_params ]
                 '(' [ param_list ] ')'
                 [ '->' type_expr ]
                 [ 'where' where_pred { ',' where_pred } ]
                 [ 'inout' ]                    // trailing receiver convention
                 { fn_clause }
                 ( '=' expr | block 'end' )

fn_modifier    = 'async' | 'unsafe' | 'pure' | 'inline'

fn_clause      = 'pre' expr [ ',' STRING_LITERAL ]
               | 'post' expr [ ',' STRING_LITERAL ]
               | 'ensures' expr [ ',' STRING_LITERAL ]
               | 'invariant' expr [ ',' STRING_LITERAL ]
               | 'requires' IDENT { ',' IDENT }
               | 'effect' IDENT { ',' IDENT }
               | ( 'budget' | '@budget' ) IDENT ':' budget_amount { ',' IDENT ':' budget_amount }

budget_amount  = STRING_LITERAL

type_params    = '[' type_param { ',' type_param } ']'
type_param     = IDENT [ ':' type_bound ] [ '=' type_expr ]

type_bound     = type_expr { '+' type_expr }

where_clause   = 'where' where_pred { ',' where_pred }
where_pred     = type_expr ':' type_bound

param_list     = param { ',' param } [ ',' ]
param          = [ 'inout' | 'sink' | 'set' ] IDENT [ ':' type_expr ] [ '=' expr ]
```

**Notes:**

- `def Type::method(...)` is accepted and becomes `Type__method`
  (`parser.tg:1142-1150`).
- The trailing `inout` after the return type (and where clause) sets the
  convention of the `self` parameter to `Inout`
  (`parser.tg:1261`, `consume_trailing_receiver_convention` `parser.tg:1594-1604`).
  This is the canonical way to write mutating methods:
  `def set_name(self, name: String) -> Unit inout`.
- A parameter whose name is `self` and which has no type is given the type
  `Self` (`parser.tg:1687-1692`). The former `&self` / `&mut self`
  spellings are REJECTED (E100) — write `self` (default `let`), `inout
  self`, or use the trailing `inout` receiver convention.
- `fn` may be used in place of `def` as a defensive fallback.
- Budget clauses accept the bare `budget` keyword or the `@budget`
  attribute (`parser.tg:1363-1377`, `parse_budget_annotation`
  `parser.tg:2505`); the bound is a STRING_LITERAL — a non-string bound is
  silently dropped from the constraint list, not an error. The
  `__tg_budget_*` data symbols have no definitions: enforcement is pending
  (see language.md §Budgets).

### 2.3 Parameter Conventions and Legacy Rejection

The canonical parameter grammar is:

```ebnf
param = [ 'inout' | 'sink' | 'set' ] IDENT [ ':' type_expr ] [ '=' expr ]
```

with default convention `let` (observe — read-only access to the
caller's value: no move, no consume; the by-value move is the `sink`
convention). The legacy Rust-style
spellings are **NOT normalized — they are REJECTED** (`parser.tg`
`parse_param`, `parser.tg:1614-1700`): the E100 diagnostic
("legacy parameter spelling `X` is removed; use the explicit access
convention `let`/`inout`/`sink`/`set`") is recorded, the legacy token is
consumed **only for error recovery** (the convention it denoted is used
so the surrounding parameter list keeps parsing), and the compilation
fails. There is no acceptance path.

| Written                                  | Result                                  |
|------------------------------------------|-----------------------------------------|
| `inout name`                             | legal — `Inout`                         |
| `sink name`                              | legal — `Sink`                          |
| `set name`                               | legal — `Set`                           |
| `name` (no prefix)                       | legal — `Let` (default)                 |
| `mut name` (prefix)                      | **E100**, recovered as `Inout`          |
| `& name` / `&mut name` (prefix)          | **E100**, recovered as `Let` / `Inout`  |
| `move name` / `own name` (prefix)        | **E100**, recovered as `Sink`           |
| `name: &T` / `name: &mut T` (marker)     | **E100**, recovered as `Let` / `Inout`  |
| `&self` / `&mut self` (receiver prefix)  | **E100**, recovered with implicit `Self`|
| `self` (no type)                         | legal — typed `Self`; `let` by default  |

The type-position markers `&T` / `&mut T` in a parameter are consumed by
`parse_param` BEFORE `parse_type` runs, so they are the E100 legacy
spelling family, not the E106 first-class-reference error (which applies
to every other type position — see §3). `&self` / `&mut self` receivers
are part of the same rejection. The five `__intrinsic_`-named extern
signatures in `std/collections.tg`—the kernel's only remaining reference
positions—are the documented extern-ABI exception (see §3).

### 2.4 Structs

```ebnf
struct_def     = 'struct' IDENT [ type_params ]
                 { field_def }
                 'end'

field_def      = [ vis ] IDENT ':' type_expr [ ',' ]
```

`{}` blocks are not supported for structs; the body is newline-separated and
terminated by `end`.

### 2.5 Resources

```ebnf
resource_def   = 'resource' IDENT [ type_params ]
                 { field_def | function_def }   // methods use the impl path
                 'end'
```

A `resource` is a nominal type (`NominalKind::Resource`) whose body may
contain both fields and methods (`parser.tg` `parse_resource_decl` /
`parse_struct_decl_kind`, `parser.tg:1649-1717`). Methods are declared with
the ordinary `def` syntax; the destructor is a method named `deinit`:

```ebnf
resource_def   = 'resource' NAME { field | method } 'end'
deinit_def     = 'def' 'deinit' '(' 'sink' 'self' ':' 'Self' ')' [ '->' type_expr ] block 'end'
```

`deinit` is a keyword that `expect_ident` accepts as a method name
(`parser.tg:1008-1010`); the `sink` prefix gives the `self` parameter the
`Sink` convention, and lowering wires it to `NAME__deinit` (mir.tg/codegen.tg).

### 2.6 Enums

```ebnf
enum_def       = 'enum' IDENT [ type_params ]
                 { variant_def }
                 'end'

variant_def    = IDENT [ '(' variant_field { ',' variant_field } ')' ]
variant_field  = [ IDENT ':' ] type_expr
```

### 2.7 Traits

```ebnf
trait_def      = 'trait' IDENT [ type_params ] [ ':' supertrait_list ]
                 { trait_item }
                 'end'

supertrait_list = type_expr { '+' type_expr }

trait_item     = function_sig [ body ]       // body = default implementation
               | 'type' IDENT [ ':' type_bound ] [ '=' type_expr ]

function_sig   = { fn_modifier } 'def' IDENT [ type_params ]
                 '(' [ param_list ] ')' [ '->' type_expr ]
```

Trait bodies may also use `{ ... }` as an alternative to `end`
(`parser.tg:1903-1908`). A `function_sig` followed by a block (rather than
another item or `end`) is a default method body (`parser.tg:1916-1944`).

### 2.8 Implementations

```ebnf
impl_block     = 'impl' [ type_params ]
                 ( type_expr                              // inherent
                 | type_expr 'for' type_expr )            // trait impl
                 [ 'where' where_pred { ',' where_pred } ]
                 ( 'do' { impl_item } 'end'
                 | '{' { impl_item } '}' )

impl_item      = function_def
               | 'type' IDENT '=' type_expr
```

`impl TraitName[T] for Type` derives the impl's generic parameters from the
trait's type arguments unless leading `impl[A, B]` generics are given
(`parser.tg:2029-2100`). Both `do ... end` and `{ ... }` block styles are
accepted (`parse_impl_body_with_where`, `parser.tg:2102-2176`).

### 2.9 Use Declarations

```ebnf
use_decl       = 'use' path [ '::' ( '*' | '{' name_list '}' ) ] [ 'as' IDENT ]

path           = path_segment { '::' path_segment }
path_segment   = IDENT | 'super' | 'crate'
name_list      = IDENT { ',' IDENT }
```

### 2.10 Constants, Statics, Type Aliases

```ebnf
const_decl     = ( 'const' | 'let' ) IDENT [ ':' type_expr ] '=' expr
static_decl    = 'static' [ 'mut' ] IDENT ':' type_expr '=' expr
type_alias     = ( 'type' | 'typealias' | 'alias' ) IDENT [ type_params ] '=' type_expr
```

A top-level `let NAME = expr` (no pattern, no type required) is parsed as a
constant item (`parser.tg:707-713`); `mut NAME = expr` at item level parses
as a static (`parser.tg:721-727`).

### 2.11 Capabilities, Effects, Edition, Extern, Macro, Rationale

```ebnf
capability_decl = 'cap' IDENT [ 'implies' IDENT { ',' IDENT } ] 'end'

effect_decl     = 'effect' IDENT [ type_params ] { effect_op_sig } 'end'
effect_op_sig   = IDENT '(' [ IDENT { ',' IDENT } ] ')' [ '->' type_expr ]

edition_decl    = 'edition' STRING_LITERAL

extern_item     = 'extern' [ STRING_LITERAL ] 'def' IDENT [ type_params ]
                  '(' [ param_list ] ')' [ '->' type_expr ] [ 'end' ]
                | 'extern' [ STRING_LITERAL ] { 'def' IDENT ... 'end' }
                | 'extern' [ STRING_LITERAL ] 'static' [ 'mut' ] IDENT ':' type_expr

macro_decl      = 'macro' IDENT '(' [ macro_param { ',' macro_param } ] ')'
                  block
                  'end'
macro_param     = IDENT ':' macro_type
macro_type      = 'Expr' | 'Ident' | 'Type' | 'Block' | 'Pattern'

rationale_block = 'rationale' { rationale_field } 'end'
rationale_field = IDENT ':' ( STRING_LITERAL | expr )
```

## 3. Type Expressions

There are **no safe reference types**. `&T` / `&mut T` / `&&T` in a general
type position — return types, struct fields, variable annotations, tuple
members, generic arguments, container elements — are a **hard error** (E106,
`parser.tg` `diag_safe_ref_not_first_class`): `parse_type` consumes the `&`
constructor, records the error, and fails the parse (it never returns the
inner type). The ONLY `&` spellings that parse in type positions are:

- **`&T` / `&mut T` inside an `extern` declaration whose name carries the
  `__intrinsic_` prefix** (including nested positions such as
  `Option[&K]`) — the internal address/reference ABI (typed `RefInternal`).
  The extern-ABI context is scoped by name (`parser.tg` `parse_extern_fn` /
  `parse_extern_static`: `p.extern_abi_context = is_intrinsic_extern_name(&name)`,
  `tg_compiler/ids.tg` `is_intrinsic_extern_name` = the `__intrinsic_`
  prefix). An ordinary user extern is the strict FFI boundary: its `&` type
  positions hit the E106 rejection, and the interop guidance is raw
  pointers / view structs. The kernel's five record-visit signatures in
  `std/collections.tg` are the only such positions in the tree.
- The **`&place` / `&mut place` expression access markers** — call-argument
  only, not types (see §4.2).

Everything else ampersand-like in a type is rejected: the parameter
spelling family (`x: &T` / `x: &mut T` markers, `&self` / `&mut self`
receivers, `fn(&T)` / `fn(mut T)` / `fn(move T)` fn-type conventions) is
consumed before `parse_type` runs and fails with **E100** (see §2.3); the
general type positions fail with **E106**. Raw pointer types `*T` and
`*mut T` are the legal unsafe-pointer forms.

```ebnf
type_expr      = type_primary [ '?' ]      // T? desugars to Option[T]

type_primary   = IDENT [ type_args ]                    // Named type / generic
               | path [ type_args ]                     // a::b::C
               | 'Self' [ '::' IDENT { '::' IDENT } ]   // Self and associated
               | '(' ')'                                // Unit
               | '(' type_expr { ',' type_expr } ')'    // Tuple (1 elem = group)
               | '[' type_expr ';' expr ']'             // Fixed-size array
               | '[' type_expr ']'                      // Slice
               | '&' type_primary                       // HARD ERROR (E106); the only accepted `&` type forms are the __intrinsic_-scoped extern ABI positions (see the note above)
               | '&mut' type_primary                    // HARD ERROR (E106); same __intrinsic_-scoped extern exception
               | '&&' type_primary                      // HARD ERROR (E106)
               | '*' [ 'mut' ] type_primary             // *T / *mut T raw pointer
               | 'async' type_primary                   // Async wrapper
               | 'impl' type_primary                    // desugars to the trait
               | 'dyn' type_primary                     // desugars to the trait
               | '_'                                    // inferred type
               | fn_type

fn_type        = 'fn' '(' [ fn_type_param { ',' fn_type_param } ] ')' [ '->' type_expr ]
               | '(' [ fn_type_param { ',' fn_type_param } ] ')' '->' type_expr
               | '(' ')' '->' type_expr                 // () -> R
               | 'Fn' '(' [ fn_type_param { ',' fn_type_param } ] ')' [ '->' type_expr ]

fn_type_param  = [ convention ] type_expr
convention     = 'inout' | 'sink' | 'set'   // default 'let'; the legacy prefixes (mut/&mut/&/move/own) are E100

type_args      = '[' type_expr { ',' type_expr } ']'
```

**Notes:**

- Function types carry a per-parameter access convention
  (`parse_fn_type_param`, `parser.tg:2950-2992`): `inout`, `sink`, `set`,
  and the default `let` are legal; the legacy prefixes `mut` / `&mut` /
  `&` / `move` / `own` are **E100 hard errors** ("legacy parameter spelling
  … is removed") — they are consumed only for error recovery, never
  converted. A plain `(A, B) -> R` is a function type whose parameters all
  have the default `let` convention.
- The `fn` keyword and the `Fn`/`FnOnce`/`FnMut` identifier spellings are all
  accepted (`parser.tg:2816-2843`, `parser.tg:2966-2995`); `fn`/`def` fall
  back to identifiers when keyword lookup fails during bootstrap.
- `(T)` with a single element and no arrow is just a grouping; `(T, U)` is a
  tuple; `(T) -> R` and `() -> R` are function types (lookahead via
  `fn_type_arrow_ahead`, `parser.tg:2748-2772`).
- **Canonical builtins** (`types.tg`): primitives `Unit`, `Bool`, `Int`,
  `UInt`, `Float`, `Char`, `String`; builtin generics `Option[T]`,
  `Result[T, E]`, `Vec[T]` (= `Array[T]`, the heap vector — a handle to
  the stride-carrying 32-byte heap header `{data, len, cap, stride}`),
  `Map[K: Hash + Eq, V]` and `Set[T: Hash + Eq]` (= `Map[T, Unit]`; the
  96-byte header carrying the concrete layout plus concrete Hash/Eq
  dispatch), `Slice[T]` (the non-owning 16-byte `{ptr, len}` view),
  `Box[T]`, `Rc[T]`, `Ptr[T]`, `PtrMut[T]`. Collection insertion
  (`push`/`insert`/`set_insert`) takes the inserted value **by sink** —
  ownership transfers into the container; the containers own their
  backing storage (`needs_drop`). The storage/layout contracts live in
  `std/collections.tg` and `tg_compiler/layout_engine.tg`.

## 4. Expressions

### 4.1 Expression Precedence (lowest to highest)

The expression parser is a precedence-climbing chain (`parser.tg:4404-4780`):

| Level | Construct            | Associativity |
|-------|----------------------|---------------|
| 1     | `\|\|`               | Left          |
| 2     | `&&`                 | Left          |
| 3     | `..` `..=` (ranges)  | —             |
| 4     | `==` `!=`            | Left          |
| 5     | `<` `>` `<=` `>=`    | Left          |
| 6     | `\|`                 | Left          |
| 7     | `^`                  | Left          |
| 8     | `&`                  | Left          |
| 9     | `<<` `>>`            | Left          |
| 10    | `+` `-`              | Left          |
| 11    | `*` `/` `%` `**`     | Left          |
| 12    | Prefix: `-` `!` `~` `&` `&mut` `*` `**` `await` `move` `copy` | Right |
| 13    | Postfix: `?` `.` `()` `[]` `is` `as` `\|>` | Left |

Assignment is **not** part of the expression grammar; it is a statement form
(see §6).

```ebnf
expr           = logical_or

logical_or     = logical_and { '||' logical_and }
logical_and    = range { '&&' range }
range          = equality [ ( '..' | '..=' ) [ equality ] ]
equality       = comparison { ( '==' | '!=' ) comparison }
comparison     = bitwise_or { ( '<' | '>' | '<=' | '>=' ) bitwise_or }
bitwise_or     = bitwise_xor { '|' bitwise_xor }
bitwise_xor    = bitwise_and { '^' bitwise_and }
bitwise_and    = shift { '&' shift }
shift          = term { ( '<<' | '>>' ) term }
term           = factor { ( '+' | '-' ) factor }
factor         = unary { ( '*' | '/' | '%' | '**' ) unary }

unary          = ( '-' | '!' | '~' ) unary
               | ( '&' | '&mut' ) unary        // access marker (see 4.2)
               | ( '*' | '**' ) unary          // raw deref (see 4.3)
               | 'await' unary
               | ( 'move' | 'copy' ) unary     // legacy no-ops
               | postfix
```

### 4.2 Access Markers

```ebnf
access_marker  = '&' unary | '&mut' unary
```

`&place` / `&mut place` produce an `ExprAccess` node
(`parser.tg:4804-4817`). It is **only valid as a call argument**: the
type checker reports `access marker '&' is only valid as a call argument`
whenever an access marker appears outside a call argument list
(`types.tg:4209-4212`). Inside an argument list the marker selects the
callee-side convention (`inout`/`sink`/`set`/`let`) and lowers to a MIR
`Place` argument (`mir.tg` `lower_call_arg`). The mutability of the marker is
not tracked; the effect comes from the callee's parameter convention.

### 4.3 Raw Pointer Dereference

```ebnf
raw_deref      = '*' unary | '**' unary
```

`*ptr` produces `ExprRawDeref` (`parser.tg:4839-4846`), the unsafe raw
pointer dereference; `**ptr` is double dereference. `*` at the start of a
line is never treated as binary multiplication continuation
(`parser.tg:4722-4729`).

### 4.4 Postfix

```ebnf
postfix        = primary { postfix_op }

postfix_op     = '?'                                        // try / propagate
               | '.' ( IDENT | INT_LITERAL )                // field or tuple .0
                 [ '[' type_expr { ',' type_expr } ']' ]    // method type args
                 [ '(' [ arg_list ] ')' ]                   // method call
                 [ trailing_block ]                         // { |x| body }
               | '(' [ arg_list ] ')'                       // function call
               | '[' expr ']'                               // subscript (place)
               | 'is' type_expr                             // type check
               | 'as' type_expr                             // cast
               | '|>' postfix                               // pipeline

arg_list       = [ named_arg | expr ] { ',' [ named_arg | expr ] } [ ',' ]
named_arg      = IDENT ':' expr        // label consumed and discarded
trailing_block = '{' [ '|' closure_params '|' ] expr '}'
```

Subscripts `a[i]`, `m[k]` are **places**: they appear in
`derive_access_path`/`expr_root_id` and may be assigned to, passed with an
access marker, or consumed by a `sink` parameter.

### 4.5 Primary Expressions

```ebnf
primary        = INT_LITERAL
               | FLOAT_LITERAL
               | STRING_LITERAL
               | CHAR_LITERAL
               | 'true' | 'false' | 'nil'
               | 'self'
               | IDENT                                   // identifier
               | path                                    // a::b
               | path '(' [ arg_list ] ')'               // enum variant ctor
               | IDENT '!' ( '[' [ expr_list ] ']' | '(' [ arg_list ] ')' )  // macro call
               | struct_literal
               | '(' ')' | '(' expr { ',' expr } ')'     // unit / tuple
               | '[' [ expr { ',' expr } ] ']'           // array literal
               | '{' expr '}'                            // expr block
               | '{' '|' closure_params '|' expr '}'     // closure
               | '{' expr '=>' expr { ',' expr '=>' expr } '}'  // map literal
               | block_expr
               | closure_expr
               | if_expr | unless_expr | match_expr
               | for_expr | while_expr | until_expr | loop_expr
               | try_expr | guard_stmt | handle_with_expr
               | unsafe_block | defer_block | async_block | comptime_block
               | return_expr | break_expr

struct_literal = IDENT '{' field_init_list '}'          // Name { f: v }
               | path '{' field_init_list '}'           // a::B { f: v }
               | IDENT '[' type_args ']' '{' field_init_list '}'  // Foo[T] { ... }
               | IDENT '[' type_args ']' '::' IDENT '(' [ arg_list ] ')'  // Vec[u8]::new(...)

field_init_list = field_init { ',' field_init } [ ',' ]
field_init     = IDENT [ ':' expr ]

block_expr     = 'do' [ '|' closure_params '|' ] { statement } 'end'
```

### 4.6 Control Flow

```ebnf
if_expr        = 'if' expr [ 'then' ]
                 block
                 { 'elsif' expr [ 'then' ] block }
                 [ 'else' block ]
                 [ 'end' ]                    // end optional in short form

if_let         = 'if' 'let' pattern '=' expr block
                 { 'elsif' 'let' pattern '=' expr block }
                 [ 'else' block ] 'end'       // desugars to match

unless_expr    = 'unless' expr [ 'then' ] block [ 'else' block ] 'end'
                 // Desugars to: if !(expr) then block [else block] end

match_expr     = 'match' expr
                 { match_arm }
                 [ 'else' block ]             // catch-all arm
                 'end'

match_arm      = 'when' pattern [ 'if' expr ] [ 'then' ] block
               | pattern [ 'if' expr ] '=>' ( expr | block )

for_expr       = 'for' pattern 'in' expr [ 'do' ] block 'end'

while_expr     = 'while' expr [ 'do' ] block 'end'
until_expr     = 'until' expr [ 'do' ] block 'end'
                 // Desugars to: while !(expr) do block end

loop_expr      = 'loop' [ 'do' ] block 'end'

try_expr       = 'try' block { 'catch' pattern block } [ 'finally' block ] 'end'

guard_stmt     = 'guard' expr 'else' ( 'return' [ expr ]
                                     | 'break' [ expr ]
                                     | 'continue'
                                     | 'panic' '(' STRING_LITERAL ')' )

handle_with_expr = 'handle' expr { 'with' IDENT
                     { IDENT '(' [ IDENT { ',' IDENT } ] ')' '=>' expr } }
                   'end'

unsafe_block   = 'unsafe' [ STRING_LITERAL ] ( 'do' block 'end' | '{' block '}' )

defer_block    = 'defer' block 'end'

async_block    = 'async' block 'end'
comptime_block = 'comptime' block 'end'

return_expr    = 'return' [ expr ]
break_expr     = 'break' [ expr ]
```

### 4.7 Closures

```ebnf
closure_expr   = '|' [ closure_params ] '|' [ '->' type_expr ] expr
               | '||' [ '->' type_expr ] expr
               | '{' '|' [ closure_params ] '|' [ '->' type_expr ] expr '}'
               | 'do' '|' [ closure_params ] '|' [ '->' type_expr ] block 'end'

closure_params = closure_param { ',' closure_param }
closure_param  = pattern [ ':' type_expr ]
```

Zero-parameter closures are written `|| expr` (the `Or` token);
`| |` with a space also works. `|...|` after a method call (trailing block) is
a closure passed as the final argument, as in `list.map { |x| x * 2 }`.

## 5. Patterns

```ebnf
pattern        = single_pattern { '|' single_pattern }   // or-pattern

single_pattern = '_'                                        // wildcard
               | IDENT                                     // binding
               | 'mut' IDENT                               // mutable binding
               | literal_pattern
               | IDENT '(' [ pattern { ',' pattern } ] ')' // variant
               | path '(' [ pattern { ',' pattern } ] ')'  // qualified variant
               | IDENT '{' field_pattern_list '}'          // struct destructure
               | path '{' field_pattern_list '}'           // qualified struct
               | '(' [ pattern { ',' pattern } ] ')'       // tuple
               | '[' [ pattern { ',' pattern } ] ']'       // array
               | range_pattern
               | ( '&' | '&mut' | 'ref' ) single_pattern   // REJECTED: E106 "ref patterns are not supported"

range_pattern  = ( INT_LITERAL | CHAR_LITERAL ) [ ( '..' | '..=' ) ( INT_LITERAL | CHAR_LITERAL ) ]

literal_pattern = INT_LITERAL | FLOAT_LITERAL | STRING_LITERAL
                | CHAR_LITERAL | 'true' | 'false' | 'nil'

field_pattern_list = field_pattern { ',' field_pattern }
field_pattern  = IDENT [ ':' pattern ]
```

The `&` / `&mut` / `ref` pattern binders are **rejected** — the parser
consumes them and records the E106 diagnostic
(`parser.tg` `diag_ref_pattern_not_supported`, three sites in
`parse_single_pattern`); the parse fails, the binder is never silently
stripped. Pattern bindings are **by value**; a mutable binding is written
`mut name`.

## 6. Statements

```ebnf
statement      = local_decl
               | assignment
               | expr_statement
               | 'use' use_decl
               | 'def' function_def
               | 'struct' struct_def | 'resource' resource_def
               | 'enum' enum_def | 'impl' impl_block
               | '@' attribute_body
               | control_flow_statement

local_decl     = 'let' [ 'mut' ] pattern [ ':' type_expr ] '=' expr
               | 'var' pattern [ ':' type_expr ] '=' expr     // var = mut alias
               | 'mut' IDENT [ ':' type_expr ] '=' expr       // LEGACY var alias

assignment     = expr ( '=' | '+=' | '-=' | '*=' | '/=' | '%=' ) expr

expr_statement = expr
```

**Notes:**

- `var` and `mut` lex to the same token (`token.tg:271,363`); `var name = e`
  and `mut name = e` both produce a mutable `StmtLet` (`parser.tg:3123-3141`),
  so `mut` in local position is a legacy alias for `var`.
- `let mut name = e` is also supported (`parser.tg:3099-3106`).
- Assignment exists only as a statement (`parser.tg:3417-3464`); assignment
  expressions are not part of the expression grammar.

## 7. Attributes

Attributes use the `@` form only; the `#[...]` form is **not** implemented.

```ebnf
attribute      = '@' IDENT [ '(' attribute_args ')' ]
attribute_args = { IDENT | STRING_LITERAL | any_token }   // tokens collected raw

item           = { attribute } item_body
```

Attribute arguments are collected at the token level (identifiers and string
literals are retained; other tokens are skipped) — `parser.tg` `parse_attributes`.
Common attributes: `@derive(...)`, `@test`, `@bench`, `@inline`,
`@budget(...)`, `@intrinsic(...)`, etc.

## 8. Legacy Forms Summary

### Accepted aliases (normalized)

| Feature                          | Legacy spelling | Implemented canonical form |
|----------------------------------|-----------------|----------------------------|
| Mutable local                    | `mut x = e`     | `var x = e` (or `let mut x = e`) |
| Function keyword                 | `fn`            | `def`                     |
| Module keyword                   | `mod`           | `module`                  |
| Continue keyword                 | `continue`      | `next` (both accepted)    |
| Type alias keyword               | `typealias`, `alias` | `type`              |

### Rejected legacy forms (hard errors — no normalization)

| Feature                          | Legacy spelling | Result |
|----------------------------------|-----------------|--------|
| `sink` parameter                 | `move x`, `own x` | **E100** — "legacy parameter spelling … is removed"; write `sink x` |
| `inout` parameter                | `mut x`, `&mut x` | **E100**; write `inout x` |
| `let` parameter                  | `&x`, `x: &T`   | **E100**; write `x` (default `let`) |
| Mutable reference parameter type | `x: &mut T`     | **E100**; write `inout x: T` |
| Reference receiver               | `&self`, `&mut self` | **E100**; write `self`, `inout self`, or trailing `inout` |
| fn-type convention               | `fn(&T)`, `fn(mut T)`, `fn(move T)` | **E100**; write `fn(inout T)` / `fn(sink T)` / `fn(set T)` |
| Safe reference type              | `&T`, `&mut T`, `&&T` in general type positions | **E106** — rejected by `parse_type`; the only `&` type forms are the `__intrinsic_`-scoped extern ABI positions (typed `RefInternal`) and the `&place` call-argument markers |
| Ref pattern binder               | `ref x`, `&x` in a pattern | **E106** — "ref patterns are not supported"; bind by value |

There are no safe reference types in the language. `&T` / `&mut T` in type
position are rejected (E106 in general positions, E100 at the parameter
spelling sites described in §2.3 and §3) and survive only as the
`__intrinsic_`-scoped extern-ABI exception and the `&place` call-argument
access markers.

## See Also

- [Language Reference](language.md) - Language overview and standard library
- [Style Guide](style_guide.md) - Code formatting conventions
- [Interoperability Guide](interop.md) - FFI and foreign language binding
- [Unicode Policy](unicode_policy.md) - Unicode handling in source code and strings
