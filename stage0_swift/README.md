# Tangerine Stage 0 Bootstrap Compiler (Swift)

The Swift front end of the Tangerine bootstrap: a from-scratch lexer,
parser, AST verifier, subset checker, MIR lowering, and MIR interpreter
that compiles the compiler kernel (`bootstrap/compiler_kernel.manifest`)
and runs it via interpretation. It is the stage0 of the four-stage ladder
(stage0 Swift → stage1 → stage2 → stage3, see `run_bootstrap.sh`).

## Build & test

```sh
make              # release build (.build/release/tg_stage0)
make test         # swift test-runner suites (.build/debug/TangerineTestRunner)
swift build       # debug build
```

## The supported subset (the subset manifest)

The stage0 front end enforces the **bootstrap subset**: the language
surface the compiler kernel is written in. The subset is enforced by the
`SubsetChecker` walk (diagnostics E9001–E9032) after every parse, and by
the semantic gates below. A construct outside the subset is a diagnostic,
never a silent acceptance.

### In the subset (supported)

- Items: `def` functions (incl. `unsafe`, `extern`-tagged), `test "name"
  do ... end`, `struct` (fields, methods, `pub`, `resource`), `enum`
  (payload variants), `trait`, `impl` (inherent and `impl Trait for T`),
  `use` declarations, `const`, `static` (incl. `mut`), `type` aliases,
  `extern "ABI"` blocks, `module` (inline + nested), `macro` declarations,
  `edition` declarations.
- Expressions: literals (int incl. 0x/0b/0o and suffixes, float, string
  with escapes, char, bool), names, paths (`a::b`), struct literals (incl.
  shorthand and `..rest`), arrays `[a, b]` and `[v; n]`, tuples, indexing,
  field access, calls (incl. labels), method calls, turbofish, if/elsif/
  else, `match` (variant/literal/tuple/or/range/wildcard patterns, guards,
  `else`), while/for/`loop`, break/next (incl. break values), blocks with
  tail values, closures (`|x: T| body`, `|x| do ... end`), unary/binary
  operators, casts (`as`), assignments + compound assignments, `return`,
  `await`-less try-op, macro calls (`name!(...)`), unsafe blocks, ranges
  `a..b` / `a..=b`.
- Types: named, generics `[T; N]` fixed arrays, tuples, `Option[T]` /
  `T?`, `Result[T, E]`, `Ptr[T]` / `PtrMut[T]`, `fn(...) -> R`, slices,
  `Self`, type bounds, const type args, `&T`/`&mut T` parameter
  conventions (inout/let/sink/set access conventions).
- Attributes: the kernel's own set (`@test` and the macro-driving
  attributes the kernel files use).

### Out of the subset (rejected, E9001–E9032)

| Code | Construct |
|------|-----------|
| E9001 | capability declarations |
| E9002 | effect declarations |
| E9003 | rationale blocks |
| E9005 | edition declarations (stage0 parses `edition` for the kernel; the declaration item is rejected) |
| E9006 | `comptime` blocks |
| E9007 | `async` functions |
| E9008 | `requires` clauses |
| E9009 | `effect` clauses |
| E9010 | `budget` clauses |
| E9011 | contract clauses (pre/post/invariant) |
| E9012 | guard clauses |
| E9013 | `pure` modifier |
| E9014 | `inline` modifier |
| E9015 | `await` expressions |
| E9016 | `handle`/`with` expressions |
| E9017 | `unless` expressions |
| E9018 | `until` expressions |
| E9019 | try/catch/finally blocks |
| E9021–E9028 | rejected attributes (`@bench`, `@inline`, `@derive`, `@allow`/`@deny`, `@deprecated`, `@stable`, `@feature`, `@capability`) |
| E9029 | source files that are not valid UTF-8 (INV-PARSE-002 gate) |
| E9030 | integer literals that do not fit the host Int range (INV-PARSE-003 gate) |
| E9032 | trait-object types — `dyn Trait` / `impl Trait` in type position (INV-TYPE-010 / INV-ABI-007 scoping) |

### Semantic gates (the assertion surface)

The subset is enforced not only by rejection codes but by three gates that
back the invariant registry (`invariants.toml`):

- `SourceLoader` (`SemanticGates.swift`) — E9029: the UTF-8 gate. The
  byte-level decode happens here; the lexer operates on the decoded
  String, which is valid UTF-8 by construction (INV-PARSE-002).
- `NumericLiteralGuard` (`SemanticGates.swift`) — E9030: integer literals
  are range-checked at parse time (decimal/hex/binary/octal, separators,
  suffixes); an overflow is a diagnostic, never the silent `?? 0` truncation
  of `MIRLowering.parseInt` (INV-PARSE-003).
- `ASTVerifier.verifySpan` — V0001: every non-synthetic AST span must
  satisfy `0 <= start <= end` (INV-PARSE-007/008).
- `SubsetChecker` — E9032: `dyn`/`impl` in type position are rejected, so
  no bootstrap program can construct a trait-object surface
  (INV-TYPE-010/INV-ABI-007). The kernel is `dyn`-free; the stage3 parser
  desugars `dyn Trait`/`impl Trait` to the plain trait type, so the
  dialect has no trait-object type at all.

## The differential harness (reviewer item 6)

`tg_stage0 diff` is the stage0-vs-stage3 differential parity harness:

```
tg_stage0 diff --corpus tests/differential \
    [--stage3-bin build/tg_stage1] [--probe] [--self-check] [--no-stage3]
```

It compares the normalized `lex`/`dump` projections against the stage3
`--dump-tokens`/`--dump-ast` projections over the corpus in
`tests/differential/` (ids and spans stripped; see
`tests/differential/README.md` for the canonical vocabularies). The
stage3 side requires a dump-capable ladder binary (dump hooks landed in
commit a14eeca); the probe fails honestly otherwise. Corpus gates run with
or without a stage3 binary (`--self-check`).

## Stage-0 invariant linkage

Each gate maps to registry rows in `invariants.toml` and is exercised by
positive corpus files (`tests/differential/corpus/`), negative files
(`tests/differential/negative/`), and mutation tests in
`TangerineTestRunner/main.swift` (Suites 43–45).
