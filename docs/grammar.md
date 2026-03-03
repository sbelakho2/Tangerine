# Tangerine Formal Grammar Specification
# Version: 0.1.0 (Edition 2026)

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

```
def    end    if     then   else   elsif  while  for    in     do
let    mut    return break  next   match  when   struct enum   trait
impl   use    pub    module fn     self   Self   true   false  unsafe
where  as     type   const  extern super  crate  yield  async  await edition
cap    effect requires implies handle with rationale budget pre post invariant
guard  try    catch  finally macro  comptime loop   pure   inline
unless until  mod
```

**Notes:**
- `def` declares functions. `fn` appears only in type expressions (`fn(T) -> U` for function pointers).
- `guard` is the precondition-based early-return keyword (see §2.2a).
- `yield` is reserved for future generator support.
- Use `elsif` (not `else if`) for chained conditions.
- `then` and `do` are optional in multi-line `if`/`while`/`for` expressions.
- `pure` marks functions with no side effects (see language.md §Functions).
- `module` is the canonical spelling; `mod` is accepted as a compatibility alias.
- `unless` is sugar for `if !(cond)` — the body executes when the condition is *false*.
- `until` is sugar for `while !(cond)` — the loop runs while the condition is *false*.

### 1.4 Literals

```ebnf
INT_LITERAL    = DIGIT { DIGIT | '_' }
                 | '0x' HEX_DIGIT { HEX_DIGIT | '_' }
                 | '0b' BIN_DIGIT { BIN_DIGIT | '_' }
                 | '0o' OCT_DIGIT { OCT_DIGIT | '_' }

FLOAT_LITERAL  = DIGIT { DIGIT } '.' DIGIT { DIGIT } [ EXPONENT ]
EXPONENT       = ( 'e' | 'E' ) [ '+' | '-' ] DIGIT { DIGIT }

STRING_LITERAL = '"' { STRING_CHAR | ESCAPE_SEQ } '"'
STRING_CHAR    = any_char_except_quote_backslash_newline
ESCAPE_SEQ     = '\' ( 'n' | 'r' | 't' | '\\' | '"' | '0' | 'x' HEX_DIGIT HEX_DIGIT
                       | 'u' '{' HEX_DIGIT { HEX_DIGIT } '}' )

CHAR_LITERAL   = "'" ( CHAR_CHAR | ESCAPE_SEQ ) "'"
CHAR_CHAR      = any_char_except_quote_backslash_newline

HEX_DIGIT      = '0'..'9' | 'a'..'f' | 'A'..'F'
BIN_DIGIT      = '0' | '1'
OCT_DIGIT      = '0'..'7'
```

### 1.5 Operators and Punctuation

```ebnf
// Arithmetic
PLUS     = '+'    MINUS    = '-'    STAR     = '*'    SLASH    = '/'    PERCENT  = '%'

// Comparison
EQ_EQ    = '=='   BANG_EQ  = '!='   LT       = '<'    GT       = '>'
LT_EQ    = '<='   GT_EQ    = '>='

// Logical
AMP_AMP  = '&&'   PIPE_PIPE = '||'  BANG     = '!'

// Bitwise
AMP      = '&'    PIPE     = '|'    CARET    = '^'    TILDE    = '~'
SHL      = '<<'   SHR      = '>>'

// Assignment
EQ       = '='    PLUS_EQ  = '+='   MINUS_EQ = '-='   STAR_EQ  = '*='
SLASH_EQ = '/='   PERCENT_EQ = '%='

// Delimiters
LPAREN   = '('    RPAREN   = ')'    LBRACKET = '['    RBRACKET = ']'
LBRACE   = '{'    RBRACE   = '}'

// Other
ARROW    = '->'   FAT_ARROW = '=>'  COLON_COLON = '::'
COLON    = ':'    COMMA    = ','    DOT      = '.'    DOT_DOT  = '..'   DOT_DOT_EQ = '..='
SEMICOL  = ';'    QUESTION = '?'    HASH     = '#'    AT       = '@'
```

## 2. Syntactic Grammar

### 2.1 Program Structure

```ebnf
program        = ( [ edition_decl ] { item } )
               | edition_block

edition_decl   = 'edition' INT_LITERAL
edition_block  = 'edition' INT_LITERAL { item } 'end'

item           = function_def
               | async_function
               | struct_def
               | enum_def
               | trait_def
               | impl_block
               | use_decl
               | const_decl
               | type_alias
               | extern_block
               | mod_decl
               | capability_decl
               | effect_decl
               | rationale_block
```

### 2.2 Functions

```ebnf
function_def   = [ 'pub' ] 'def' IDENT [ type_params ] '(' [ param_list ] ')'
                 [ '->' type_expr ] [ where_clause ]
                 ( { fn_clause } block 'end'
                 | '=' expr )

fn_clause      = requires_clause
               | effect_clause
               | budget_clause
               | contract_clause
               | guard_clause

requires_clause = 'requires' requires_item { ',' requires_item }
requires_item   = [ '!' ] IDENT

effect_clause   = 'effect' IDENT [ type_args ]

budget_clause   = 'budget' budget_entry { ',' budget_entry }
budget_entry    = IDENT ':' budget_amount
budget_amount   = INT_LITERAL [ IDENT ]
                | STRING_LITERAL

contract_clause = 'pre' expr [ ',' STRING_LITERAL ]
                | 'post' expr [ ',' STRING_LITERAL ]
                | 'invariant' expr [ ',' STRING_LITERAL ]

guard_clause   = 'guard' expr 'else' guard_action
               | 'guard' 'let' pattern '=' expr 'else' guard_action

guard_action   = 'return' [ expr ]
               | 'break' [ IDENT ]
               | 'next' [ IDENT ]
               | 'panic' '(' expr ')'

param_list     = param { ',' param } [ ',' ]
param          = [ 'mut' ] IDENT ':' type_expr [ '=' expr ]

type_params    = '[' type_param { ',' type_param } ']'
type_param     = IDENT [ ':' type_bound ]

type_bound     = IDENT { '+' IDENT }

where_clause   = 'where' where_pred { ',' where_pred }
where_pred     = type_expr ':' type_bound
```

### 2.3 Structs

```ebnf
struct_def     = [ 'pub' ] 'struct' IDENT [ type_params ]
                 { field_def }
                 'end'

field_def      = [ 'pub' ] IDENT ':' type_expr [ ',' ]
```

### 2.4 Enums

```ebnf
enum_def       = [ 'pub' ] 'enum' IDENT [ type_params ]
                 { variant_def }
                 'end'

variant_def    = IDENT [ '(' variant_fields ')' ]
variant_fields = variant_field { ',' variant_field }
variant_field  = [ IDENT ':' ] type_expr
```

### 2.5 Traits

```ebnf
trait_def      = [ 'pub' ] 'trait' IDENT [ type_params ] [ ':' type_bound ]
                 { trait_item }
                 'end'

trait_item     = function_sig
               | function_def    // default implementation

function_sig   = 'def' IDENT [ type_params ] '(' [ param_list ] ')' [ '->' type_expr ]
```

### 2.6 Implementations

```ebnf
impl_block     = 'impl' [ type_params ] [ IDENT 'for' ] type_expr [ where_clause ]
                 { function_def }
                 'end'
```

### 2.7 Use Declarations

```ebnf
use_decl       = 'use' use_path

use_path       = use_segment { '::' use_segment }
               | use_segment { '::' use_segment } '::' '*'
               | use_segment { '::' use_segment } '::' '{' use_list '}'

use_segment    = IDENT | 'crate' | 'super' | 'self'

use_list       = use_item { ',' use_item }
use_item       = IDENT [ 'as' IDENT ]
```

### 2.8 Constants and Type Aliases

```ebnf
const_decl     = [ 'pub' ] 'const' IDENT ':' type_expr '=' expr

type_alias     = [ 'pub' ] 'type' IDENT [ type_params ] '=' type_expr
```

### 2.9 Extern Blocks

```ebnf
extern_block   = 'extern' [ STRING_LITERAL ] function_sig
               | 'extern' [ STRING_LITERAL ] [ 'do' ]
                 { function_sig }
                 'end'
               | 'extern' [ STRING_LITERAL ] '{'
                 { function_sig }
                 '}'
```

### 2.10 Modules

```ebnf
mod_decl       = [ 'pub' ] 'module' IDENT
                 { item }
                 'end'
               | [ 'pub' ] 'module' IDENT    // file-based module

capability_decl = 'cap' IDENT [ 'implies' IDENT { ',' IDENT } ] 'end'

effect_decl     = 'effect' IDENT [ type_params ]
                  { effect_op_sig }
                  'end'

effect_op_sig   = IDENT '(' [ param_list ] ')' [ '->' type_expr ]

rationale_block = 'rationale'
                  { rationale_field }
                  'end'

rationale_field = IDENT ':' ( STRING_LITERAL | expr )
```

### 2.11 Async Functions

```ebnf
async_function  = [ 'pub' ] 'async' 'def' IDENT [ type_params ] '(' [ param_list ] ')'
                  [ '->' type_expr ]
                  block
                  'end'
```

### 2.12 Try/Catch/Finally

```ebnf
try_expr       = 'try'
                 block
                 { 'catch' pattern 'then' block }
                 [ 'finally' block ]
                 'end'
```

### 2.13 Macro Declarations

```ebnf
macro_decl     = 'macro' IDENT '(' [ macro_params ] ')'
                 block
                 'end'

macro_params     = macro_param { ',' macro_param }
macro_param      = IDENT ':' macro_type
macro_type       = 'Expr' | 'Ident' | 'Type' | 'Block' | 'Pattern'
macro_invocation = IDENT '!' '(' [ arg_list ] ')'
```

### 2.14 Compile-time Evaluation

```ebnf
comptime_block = 'comptime'
                 block
                 'end'
```

## 3. Type Expressions

```ebnf
type_expr      = type_primary { '?' }  // Option shorthand: T? = Option[T]

type_primary   = IDENT [ type_args ]                    // Named type
               | '(' [ type_expr { ',' type_expr } ] ')'  // Tuple or Unit
               | '&' [ 'mut' ] type_expr                // Reference
               | '*' [ 'mut' ] type_expr                // Raw pointer
               | 'fn' '(' [ type_list ] ')' '->' type_expr  // Function pointer
               | '[' type_expr ';' expr ']'             // Fixed-size array type
               | '[' type_expr ']'                       // Slice type
               | 'Self'                                  // Self type in traits/impls

type_args      = '[' type_expr { ',' type_expr } ']'
type_list      = type_expr { ',' type_expr }
```

## 4. Expressions

### 4.1 Expression Precedence (lowest to highest)

| Level | Operators            | Associativity |
|-------|---------------------|---------------|
| 1     | `=` `+=` `-=` `*=`  | Right         |
| 2     | `\|\|`              | Left          |
| 3     | `&&`                | Left          |
| 4     | `==` `!=`           | Left          |
| 5     | `<` `>` `<=` `>=`   | Left          |
| 6     | `\|`                | Left          |
| 7     | `^`                 | Left          |
| 8     | `&`                 | Left          |
| 9     | `<<` `>>`           | Left          |
| 10    | `+` `-`             | Left          |
| 11    | `*` `/` `%`         | Left          |
| 12    | Prefix: `-` `!` `&` `*` | Right     |
| 13    | Postfix: `?` `.` `()` `[]` | Left   |

### 4.2 Expression Grammar

```ebnf
expr           = assignment

assignment     = range [ ( '=' | '+=' | '-=' | '*=' | '/=' | '%=' ) assignment ]
range          = logical_or [ ( '..' | '..=' ) logical_or ]

logical_or     = logical_and { '||' logical_and }
logical_and    = equality { '&&' equality }
equality       = comparison { ( '==' | '!=' ) comparison }
comparison     = bitwise_or { ( '<' | '>' | '<=' | '>=' ) bitwise_or }
bitwise_or     = bitwise_xor { '|' bitwise_xor }
bitwise_xor    = bitwise_and { '^' bitwise_and }
bitwise_and    = shift { '&' shift }
shift          = addition { ( '<<' | '>>' ) addition }
addition       = multiplication { ( '+' | '-' ) multiplication }
multiplication = unary { ( '*' | '/' | '%' ) unary }

unary          = ( '-' | '!' | '&' [ 'mut' ] | '*' ) unary
               | postfix

postfix        = primary { postfix_op }
postfix_op     = '.' IDENT [ '(' [ arg_list ] ')' ]   // Method call / field access
               | '(' [ arg_list ] ')'                   // Function call
               | '[' expr ']'                            // Index
               | '?'                                     // Try operator
               | 'as' type_expr                          // Type cast

primary        = INT_LITERAL
               | FLOAT_LITERAL
               | STRING_LITERAL
               | CHAR_LITERAL
               | 'true' | 'false'
               | macro_invocation
               | IDENT [ '::' IDENT ] [ type_args ]     // Path expression
               | IDENT '{' field_init_list '}'           // Struct literal
               | '(' [ expr { ',' expr } ] ')'          // Tuple / grouping
               | '[' [ expr { ',' expr } ] ']'          // Array literal
               | block_expr
               | if_expr
               | unless_expr
               | match_expr
               | for_expr
               | while_expr
               | until_expr
               | loop_expr
               | handle_expr
               | closure_expr
               | return_expr
               | break_expr
               | unsafe_block

arg_list       = expr { ',' expr } [ ',' ]
field_init_list = field_init { ',' field_init } [ ',' ]
field_init     = IDENT [ ':' expr ]
```

### 4.3 Block Expression

```ebnf
block_expr     = 'do'
                 { statement }
                 [ expr ]     // implicit return value
                 'end'

block          = { statement }
               | { statement } expr
```

### 4.4 Control Flow

```ebnf
if_expr        = 'if' expr [ 'then' ]
                 block
                 { 'elsif' expr [ 'then' ] block }
                 [ 'else' block ]
                 'end'

match_expr     = 'match' expr
                 { match_arm }
                 'end'

match_arm      = 'when' pattern [ 'if' expr ] 'then' ( expr | block )

for_expr       = 'for' IDENT 'in' expr [ 'do' ]
                 block
                 'end'

while_expr     = 'while' expr [ 'do' ]
                 block
                 'end'

unless_expr    = 'unless' expr [ 'then' ]
                 block
                 [ 'else' block ]
                 'end'
                 // Desugars to: if !(expr) then block [else block] end

until_expr     = 'until' expr [ 'do' ]
                 block
                 'end'
                 // Desugars to: while !(expr) do block end

loop_expr      = 'loop' block 'end'

return_expr    = 'return' [ expr ]
break_expr     = 'break' [ expr ]

handle_expr    = 'handle' expr
                 'with' IDENT
                 { handler_arm }
                 'end'

handler_arm    = IDENT '(' [ pattern_list ] ')' '=>' expr

unsafe_block   = 'unsafe' [ STRING_LITERAL ]
                 block
                 'end'
```

### 4.5 Closures

```ebnf
closure_expr   = '|' [ closure_params ] '|' [ '->' type_expr ] ( expr | block 'end' )
closure_params = closure_param { ',' closure_param }
closure_param  = [ 'mut' ] IDENT [ ':' type_expr ]
```

Zero-parameter closures use an empty parameter list with two pipe tokens:
`| | expr` (or `||expr` when the parser is in closure position), which disambiguates from logical OR `||`.

## 5. Patterns

```ebnf
pattern        = '_'                                    // Wildcard
               | IDENT                                  // Binding
               | 'mut' IDENT                            // Mutable binding
               | 'ref' IDENT                            // Reference binding
               | 'ref' 'mut' IDENT                      // Mutable reference binding
               | literal_pattern                         // Literal
               | IDENT '::' IDENT [ '(' pattern_list ')' ]  // Enum variant
               | IDENT '{' field_pattern_list '}'       // Struct destructure
               | '(' [ pattern { ',' pattern } ] ')'    // Tuple
               | pattern '|' pattern                     // Or-pattern
               | pattern '..' pattern                    // Range pattern

literal_pattern = INT_LITERAL | FLOAT_LITERAL | STRING_LITERAL
               | CHAR_LITERAL | 'true' | 'false'

pattern_list   = pattern { ',' pattern }
field_pattern_list = field_pattern { ',' field_pattern }
field_pattern  = IDENT [ ':' pattern ]
```

## 6. Statements

```ebnf
statement      = let_statement
               | expr_statement
               | item                // Items can appear inside functions

let_statement  = ( 'let' [ 'mut' ] pattern [ ':' type_expr ] '=' expr
                 | 'mut' pattern [ ':' type_expr ] '=' expr )

expr_statement = expr
```

## 7. Attributes

Tangerine supports **two equivalent attribute syntaxes**:

```ebnf
attribute      = '#[' attr_inner ']'
               | '@' attr_inner [ '(' attr_args ')' ]

attr_inner     = IDENT [ '(' attr_args ')' ]
attr_args      = attr_arg { ',' attr_arg }
attr_arg       = IDENT [ '=' literal ]
               | literal
```

Both `#[test]` and `@test` are accepted and identical in meaning.
The `@` form is preferred in idiomatic Tangerine code. The `#[...]` form is
supported for familiarity and compatibility.

Common attributes:
- `@test` / `#[test]` — Mark function as a test
- `@bench` / `#[bench]` — Mark function as a benchmark
- `@inline` / `#[inline]` — Suggest inlining
- `@allow(lint_name)` — Suppress a lint
- `@deny(lint_name)` — Treat lint as error
- `@deprecated(since = "0.2.0", note = "use new_api instead")`
- `@stable(since = "0.1.0")`
- `@feature(name)` — Enable experimental feature
- `@derive(Clone, Debug)` — Derive trait implementations
- `@export("symbol_name")` — Export symbol for FFI
- `@repr(C)` — Use C-compatible memory layout
- `@capability(Unsafe)` — Require capability to call

## 8. Evaluation Semantics

### 8.1 Evaluation Order

- Tangerine uses **strict (eager) evaluation**: all arguments are evaluated
  before a function is called.
- Arguments are evaluated left-to-right.
- Short-circuit evaluation applies to `&&` and `||`.

### 8.2 Variable Binding

- `let` creates an immutable binding.
- `let mut` creates a mutable binding.
- Variables are block-scoped (lexical scoping).
- Shadowing is permitted within the same scope.

### 8.3 Ownership Model

- Every value has exactly one owner.
- When the owner goes out of scope, the value is dropped.
- Values can be moved (transferring ownership) or borrowed (temporary access).
- Shared borrows (`&T`) allow multiple simultaneous readers.
- Mutable borrows (`&mut T`) allow exactly one writer, excluding all readers.
- Drop order is reverse declaration order (LIFO) within a scope.

### 8.4 Function Calls

- Function arguments are passed by value (with move semantics) unless borrowed.
- The last expression in a function body is the implicit return value.
- `return` can be used for early exit.

### 8.5 Error Model

- **`Result[T, E]`**: Explicit success/failure. Propagated with `?` operator.
- **`Option[T]`**: Explicit presence/absence. Propagated with `?` (returns `None`).
- **`panic`**: Unrecoverable error. Default strategy is abort.
- Panic strategy is compile-time selected (`abort` or `unwind`); unwinding is profile-dependent.

### 8.6 Concurrency Model

- No data races: enforced via `Send`/`Sync` traits at compile time.
- `Send`: A type that can be transferred between threads.
- `Sync`: A type that can be shared between threads via `&T`.
- `unsafe` is required to opt out of thread-safety checks.

---

## See Also

- [Language Reference](language.md) - Language overview and standard library
- [Style Guide](style_guide.md) - Code formatting conventions
- [Interoperability Guide](interop.md) - FFI and foreign language binding
- [Unicode Policy](unicode_policy.md) - Unicode handling in source code and strings
