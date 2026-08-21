# Tangerine Language Spec — the Normative Grammar Facts (generated)

> **GENERATED EVIDENCE — do not edit by hand.** This document is
> rendered by `scripts/gen_spec_docs.sh` from
> [`language_spec.toml`](language_spec.toml), the machine-readable
> normative grammar facts (the keywords, the operators, the precedence,
> the access conventions, the syntax forms). The CI evidence-gate job
> regenerates it and runs `git diff --exit-code` — a stale hand-edited
> grammar fact cannot merge. The facts are sourced from the compiler's
> own authority: tg_compiler/token.tg (`keyword_from_str`),
> tg_compiler/lexer.tg, grammar.md §4.1 (the precedence-climbing chain)
> and language.md §"Access Conventions".

## Lexical facts

- **identifier**: XID_Start followed by XID_Continue scalars; the identifier identity is the NFC-normalized form (the original spelling stays available through the token span)
- **keywords**: pure ASCII; a keyword is recognized by exact match in the keyword table below (token.tg keyword_from_str) — keywords are never identifiers
- **newline**: LF -> one Newline token; CRLF -> one Newline token (both bytes); CR alone -> one Newline token
- **comments**: # to end of line; ## starts a doc comment

## The keywords

| Keyword | Token kind | Category |
|---|---|---|
| `def` | `Def` | declarations |
| `end` | `End` | declarations |
| `do` | `Do` | declarations |
| `if` | `If` | control-flow |
| `elsif` | `Elsif` | control-flow |
| `else` | `Else` | control-flow |
| `unless` | `Unless` | control-flow |
| `while` | `While` | control-flow |
| `for` | `For` | control-flow |
| `in` | `In` | control-flow |
| `loop` | `Loop` | control-flow |
| `match` | `Match` | control-flow |
| `when` | `When` | control-flow |
| `then` | `Then` | control-flow |
| `until` | `Until` | control-flow |
| `let` | `Let` | bindings |
| `mut` | `Mut` | bindings |
| `var` | `Mut` | bindings |
| `inout` | `Inout` | access |
| `sink` | `Sink` | access |
| `set` | `Set` | access |
| `resource` | `Resource` | declarations |
| `deinit` | `Deinit` | declarations |
| `return` | `Return` | control-flow |
| `break` | `Break` | control-flow |
| `continue` | `Next` | control-flow |
| `next` | `Next` | control-flow |
| `struct` | `Struct` | declarations |
| `enum` | `Enum` | declarations |
| `trait` | `Trait` | declarations |
| `impl` | `Impl` | declarations |
| `module` | `Module` | declarations |
| `mod` | `Module` | declarations |
| `use` | `Use` | modules |
| `as` | `As` | modules |
| `pub` | `Pub` | visibility |
| `private` | `Private` | visibility |
| `macro` | `Macro` | metaprogramming |
| `where` | `Where` | declarations |
| `true` | `True` | literals |
| `false` | `False` | literals |
| `nil` | `Nil` | literals |
| `self` | `Self_` | declarations |
| `Self` | `SelfType` | declarations |
| `super` | `Ident (the reserved word is lexed as an identifier — not a keyword token)` | modules |
| `crate` | `Ident (the reserved word is lexed as an identifier — not a keyword token)` | modules |
| `move` | `TkMove` | access |
| `copy` | `TkCopy` | access |
| `drop` | `TkDrop` | access |
| `own` | `TkOwn` | access |
| `ref` | `TkRef` | access |
| `pre` | `Pre` | contracts |
| `post` | `Post` | contracts |
| `invariant` | `Invariant` | contracts |
| `cap` | `Cap` | capabilities |
| `unsafe` | `Unsafe` | capabilities |
| `rationale` | `Rationale` | capabilities |
| `budget` | `Budget` | capabilities |
| `edition` | `Edition` | capabilities |
| `requires` | `Requires` | contracts |
| `ensures` | `Ensures` | contracts |
| `effect` | `Effect` | capabilities |
| `pure` | `Pure` | capabilities |
| `async` | `Async` | concurrency |
| `await` | `Await` | concurrency |
| `defer` | `Defer` | control-flow |
| `try` | `Try` | control-flow |
| `catch` | `Catch` | control-flow |
| `finally` | `Finally` | control-flow |
| `guard` | `Guard` | control-flow |
| `handle` | `Handle` | concurrency |
| `with` | `With` | concurrency |
| `is` | `Is` | control-flow |
| `implies` | `Implies` | contracts |
| `comptime` | `Comptime` | metaprogramming |
| `const` | `Const` | declarations |
| `static` | `Static` | declarations |
| `type` | `Type` | declarations |
| `typealias` | `Type` | declarations |
| `alias` | `Alias` | declarations |
| `extern` | `Extern` | declarations |
| `inline` | `Inline` | declarations |

## The expression precedence (lowest to highest)

| Level | Constructs | Associativity |
|---|---|---|
| 1 | `\|\|` | left |
| 2 | `&&` | left |
| 3 | `.. ..=` | none |
| 4 | `== !=` | left |
| 5 | `< > <= >=` | left |
| 6 | `\|` | left |
| 7 | `^` | left |
| 8 | `&` | left |
| 9 | `<< >>` | left |
| 10 | `+ -` | left |
| 11 | `* / % **` | left |
| 12 | `prefix: - ! ~ & &mut * ** await move copy` | right |
| 13 | `postfix: ? . () [] is as \|>` | left |

Assignment is **not** part of the expression grammar; it is a statement
form (grammar.md §6).

## The operators

| Symbol | Name | Position | Precedence | Associativity | Arity |
|---|---|---|---|---|---|
| `\|\|` | logical-or | infix | 1 | left | binary |
| `&&` | logical-and | infix | 2 | left | binary |
| `..` | range | infix | 3 | none | binary |
| `..=` | inclusive-range | infix | 3 | none | binary |
| `!=` | not-equal | infix | 4 | left | binary |
| `==` | equal | infix | 4 | left | binary |
| `<` | less | infix | 5 | left | binary |
| `<=` | less-equal | infix | 5 | left | binary |
| `>` | greater | infix | 5 | left | binary |
| `>=` | greater-equal | infix | 5 | left | binary |
| `\|` | bitwise-or | infix | 6 | left | binary |
| `^` | bitwise-xor | infix | 7 | left | binary |
| `&` | bitwise-and | infix | 8 | left | binary |
| `<<` | shift-left | infix | 9 | left | binary |
| `>>` | shift-right | infix | 9 | left | binary |
| `+` | add | infix | 10 | left | binary |
| `-` | subtract | infix | 10 | left | binary |
| `%` | modulo | infix | 11 | left | binary |
| `*` | multiply | infix | 11 | left | binary |
| `**` | power | infix | 11 | left | binary |
| `/` | divide | infix | 11 | left | binary |
| `!` | logical-not | prefix | 12 | right | unary |
| `&` | access-marker-borrow | prefix | 12 | right | unary |
| `&mut` | access-marker-borrow-mut | prefix | 12 | right | unary |
| `*` | deref | prefix | 12 | right | unary |
| `**` | raw-deref | prefix | 12 | right | unary |
| `-` | negate | prefix | 12 | right | unary |
| `await` | await | prefix | 12 | right | unary |
| `copy` | copy | prefix | 12 | right | unary |
| `move` | move | prefix | 12 | right | unary |
| `~` | bitwise-not | prefix | 12 | right | unary |
| `()` | call | postfix | 13 | left | binary |
| `.` | field-access | postfix | 13 | left | binary |
| `?` | try | postfix | 13 | left | unary |
| `[]` | index | postfix | 13 | left | binary |
| `as` | as | postfix | 13 | left | binary |
| `is` | is | postfix | 13 | left | binary |
| `\|>` | pipe | postfix | 13 | left | binary |
| `%=` | modulo-assign | statement | 0 | none | binary |
| `&=` | bitand-assign | statement | 0 | none | binary |
| `*=` | multiply-assign | statement | 0 | none | binary |
| `+=` | add-assign | statement | 0 | none | binary |
| `-=` | subtract-assign | statement | 0 | none | binary |
| `/=` | divide-assign | statement | 0 | none | binary |
| `<<=` | shl-assign | statement | 0 | none | binary |
| `=` | assign | statement | 0 | right | binary |
| `>>=` | shr-assign | statement | 0 | none | binary |
| `^=` | bitxor-assign | statement | 0 | none | binary |
| `\|=` | bitor-assign | statement | 0 | none | binary |
| `->` | arrow | signature | 0 | none | binary |
| `=>` | fat-arrow | declaration | 0 | none | binary |
| `::` | path-separator | path | 0 | none | binary |

## The access conventions

| Convention | Keyword | Typed effect | Meaning |
|---|---|---|---|
| `let` | `none (the default)` | Read | observe — read-only access to the caller's value: no move, no consume, never finalized by the callee |
| `inout` | `inout` | Modify | exclusive mutation — the callee may read and write the caller's place |
| `sink` | `sink` | Consume | by-value move — ownership transfers into the callee; the callee finalizes it if still live |
| `set` | `set` | Initialize | initialize dead storage — the callee writes into an uninitialized place |

Every parameter and receiver carries an explicit access convention; the
default (no prefix) is `let` — the argument is **observed** (read-only
access, no move). The distinction is critical: **`let` observes; `sink`
moves.**

### Access markers at call sites

| Marker | Meaning | Fact |
|---|---|---|
| `&place` | selects the callee-side convention and lowers to a MIR Place argument; ONLY valid as a call argument — the type checker rejects it anywhere else | the access marker '&' is only valid as a call argument |
| `&mut place` | selects the mutable callee-side convention (Modify); ONLY valid as a call argument |  |
| `trailing inout receiver` | mutating methods use the trailing `inout` receiver convention: `def set_name(self, name: String) -> Unit inout` |  |
| `&T / &mut T in type position` | the E106 hard error — first-class reference types do not exist in the dialect; access is expressed with parameter conventions and access markers only |  |

## The syntax forms

| Form | Spelling | Meaning |
|---|---|---|
| `def` | `def name(params) -> ReturnType ... end` | function item; params carry the access conventions; `-> Type` optional |
| `struct` | `struct Name ... end` | nominal record item; fields in declaration order (F6 — no reordering) |
| `resource` | `resource Name ... end` | resource item (the deinit-carrying nominal form) |
| `enum` | `enum Name ... end` | tagged enum item; tag at offset 0 (8 bytes), payload at offset 8 (F3) |
| `trait` | `trait Name ... end` | trait item (the one trait solver) |
| `impl` | `impl Name ... end` | implementation block for a nominal type or trait |
| `module / mod` | `module Path ... end` | module item (the crate module graph is keyed by ModuleId) |
| `use` | `use std::path::{a, b}` | import declaration |
| `const / static` | `const NAME: T = expr` | constant / static item (static supports @thread_local for TLS) |
| `typealias / type / alias` | `typealias Name = T` | type alias item |
| `extern` | `extern "C" def name(...) -> T` | foreign-function declaration / extern block |
| `let / var / mut` | `let x = expr; var x = expr` | binding statement; `mut`/`var` marks the binding mutable |
| `if` | `if cond then ... elsif cond then ... else ... end` | conditional statement/expression |
| `unless` | `unless cond then ... end` | negative conditional (if !cond) |
| `while` | `while cond do ... end` | pre-test loop |
| `until` | `until cond do ... end` | negative pre-test loop (while !cond) |
| `for` | `for i in 0..n do ... end` | iteration loop over a range/collection |
| `loop` | `loop ... end` | infinite loop |
| `match` | `match expr ... when pat then ... end` | pattern match with `when` arms |
| `return / break / next` | `return expr; break; next` | transfer statements |
| `defer` | `defer expr` | deferred action registered at the edge |
| `try / catch / finally` | `try ... catch e ... finally ... end` | error-handling form |
| `guard` | `guard cond else ... end` | early-exit guard |
| `async / await` | `async { ... }; await expr` | concurrency forms (the executor's virtual time in the deterministic run) |
| `contracts` | `pre ... / post ... / invariant ... / requires ... / ensures ...` | contract clauses attached to functions |
| `attributes` | `@name(args)` | item attributes (@export, @repr(C), @ffi(alloc = "tangerine"), @thread_local, ...) |
| `doc comments` | `## ...` | doc-comment lines (compiler-doctested, see docs/current/doctests.md policy in check_doctests.sh) |
| `macro` | `macro ... end` | macro item (the E105 expansion-fixpoint contract) |
| `comptime` | `comptime ...` | compile-time evaluation form |
| `cap / effect / pure / unsafe / budget / rationale / edition` | `cap ... / effect ... / pure / unsafe ... / budget ... / rationale ... / edition ...` | capability/effect/edition declaration forms |

---

*Generated from `docs/current/language_spec.toml`.*
