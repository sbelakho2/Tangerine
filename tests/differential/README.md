# Tangerine Differential Corpus — stage0 vs stage3 semantic parity

The reviewer's item 6: the stage0 fixed-point is not semantic-parity proof.
The Swift front end (`stage0_swift/`) and the self-host front end
(`tg_compiler/`) are independent implementations; this corpus and the
harness that consumes it turn that independence into a mechanically
checkable equivalence over the **bootstrap subset**.

## What is compared

For every corpus file, the harness (`scripts/run_differential.sh` →
`tg_stage0 diff`) compares two normalized projections:

| Phase | Stage0 side | Stage3 side | Normalization |
|-------|-------------|-------------|---------------|
| tokens | `tg_stage0 lex <file>` (in-process) | `<stage3> check <file> --dump-tokens` | positions / ` @ start..end` spans stripped; both sides projected onto ONE canonical token vocabulary |
| ast | `tg_stage0 dump <file>` (in-process) | `<stage3> check <file> --dump-ast` | ids and spans stripped (the dumps are id/span-free by construction); both sides projected onto the canonical top-level item-kind sequence |

The normalization is **per-side and isolated**: `Stage0Normalizer` consumes
the stage0 CLI formats; `Stage3Normalizer` consumes the stage3 dump formats.
When the stage3 dumps grow richer, only the stage3 normalizer changes —
the comparison contract stays.

## The canonical vocabularies

Tokens: keywords and punctuation by spelling (`def`, `+`, `(`, `::`),
`&mut` fused (the stage0 lexer emits `&` `mut` as two tokens; the stage3
lexer emits the single `AmpMut`), identifiers payload-bearing
(`ident:name`), literals kind-only (`int`, `float`, `str`, `char` — the two
dumps render literal payloads differently), trivia dropped by both sides,
`eof` terminator.

AST: the ordered top-level item-kind sequence (`fn`, `struct`, `enum`,
`trait`, `impl`, `module`, `use`, `macro`, `type-alias`, `const`, `static`,
`capability`, `effect`, `rationale`, `edition`, `extern`, `test`).

**Granularity limit (documented, not hidden):** the stage3 `--dump-ast`
exposes only top-level items (`Item: ...` lines in `print_ast`), so the AST
parity is the top-level item-kind sequence. Deeper structure (bodies,
nested items, type shapes) is beyond the stage3 dump's granularity today;
the token stream carries the finer-grained evidence (every identifier and
literal is compared). A token or item kind with no vocabulary entry is a
**NORMALIZATION-GAP** — a distinct verdict that fails the run — never a
silent skip.

## Verdicts and exit codes

| Verdict | Meaning |
|---------|---------|
| MATCH | normalized projections identical |
| DIVERGENT | projections differ (count mismatch or first divergent element) |
| NORMALIZATION-GAP | an unmapped canonical element on either side |

Exit codes of `tg_stage0 diff` / `scripts/run_differential.sh`:
`0` all matched and gates clean; `1` divergence or gap; `2` stage3 probe
failure (the stage3 binary cannot dump — parity cannot be claimed, the run
fails honestly); `3` a corpus gate failure.

## The corpus gate (runs with or without a stage3 binary)

Every positive corpus file MUST pass the stage0 front end: the E9029 UTF-8
source gate, the parse, the V0001 span-order verifier (INV-PARSE-007/008),
and the E9xxx subset checker. Every `negative/` file MUST produce exactly
the `expect` code declared in `corpus.manifest` (E9002/E9006/E9007/E9011/
E9029/E9030/E9032). `--self-check` runs gates + stage0 normalization only —
a CI pre-flight that needs no ladder product.

## Coverage

The corpus exercises the constructs the bootstrap needs, file by file
(the `coverage` tags in `corpus.manifest`):

| File | Constructs |
|------|-----------|
| corpus/01_defs_arith.tg | defs, params, returns, arith, calls, recursion, literals |
| corpus/02_strings.tg | strings, chars, escapes, concatenation, comparison |
| corpus/03_structs.tg | structs, fields, struct literals, field access, pub, rest syntax |
| corpus/04_enums_matches.tg | enums, variants, matches, patterns, or-patterns, ranges |
| corpus/05_loops.tg | while/for/loop, break/next, nested loops |
| corpus/06_generics.tg | generic defs/structs/enums, generic impls, type args |
| corpus/07_closures.tg | closures, capture, higher-order, fn types |
| corpus/08_collections.tg | Vec/Map/Set, method calls, indexing, iteration, use |
| corpus/09_impls_traits.tg | impls, traits, Self, receivers, associated methods |
| corpus/10_consts_statics_aliases.tg | consts, statics, type aliases, const exprs, literal forms |
| corpus/11_modules.tg | inline modules, nested modules, qualified paths |
| corpus/12_options_results.tg | Option/Result, Some/None/Ok/Err, nesting, option sugar |
| corpus/13_control_flow.tg | if/elsif/else, blocks, early returns, compound assign |
| corpus/14_extern_unsafe.tg | extern blocks, unsafe fns, Ptr/PtrMut, casts |
| corpus/15_arrays_tuples_slices.tg | fixed arrays, tuples, tuple patterns, ranges, slices |

## Running

```sh
scripts/run_differential.sh                # full differential (needs a
                                           # dump-capable stage3 binary:
                                           # dump hooks landed in a14eeca)
scripts/run_differential.sh --self-check   # stage0-side gates + normalization
scripts/run_differential.sh --probe        # probe the stage3 dump surface
TG_STAGE3_BIN=/path/to/tg_stageN scripts/run_differential.sh
```

The stage3 side requires a ladder-produced binary that supports
`check --dump-tokens` / `check --dump-ast` (the full driver) or
`compile --dump-tokens` / `compile --dump-ast` (the bootstrap entry). The
harness probes both invocation shapes first; a stale binary makes the run
fail with exit 2 — parity is never claimed against a front end that cannot
be compared.

## Typed-program / MIR parity (documented extension)

The reviewer's corpus mandate names TypedProgram and MIR comparisons as
well. The stage3 dump surface already exposes the phase hooks
(`--dump-resolved-ast`, `--dump-mir-lowered`, `--dump-mir-mono`,
`--dump-mir-opt`; the stage0 side has `lower`/`interpret`), but the
normalized comparison of those phases is NOT part of this harness yet:
the stage0 `dump` and the stage3 `--dump-ast`/`--dump-tokens` are the
pinned, documented formats of the current parity phases (tokens, ast).
The normalizers are per-side and isolated, so adding the resolved-ast and
MIR phases means adding two `Stage0Normalizer`/`Stage3Normalizer`
projections and two phases in `corpus.manifest` — the comparison contract
and the gate semantics do not change.
