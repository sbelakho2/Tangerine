# Tangerine Differential Corpus — OCaml seed vs stage3 semantic parity

The reviewer's item 6: the stage0 fixed-point is not semantic-parity proof.
The OCaml seed (`stage0_ocaml/`) and the self-host front end
(`tg_compiler/`) are independent implementations; this corpus and the
harness that consumes it turn that independence into a mechanically
checkable equivalence over the **bootstrap subset**. The retired Swift
stage0 (`stage0_swift/`) is no longer a participant.

## What is compared

For every corpus file, the harness (`scripts/run_differential.sh`) compares
the OCaml seed's per-file verdicts against the self-hosted stage3 baseline:

| Phase | OCaml seed side | Stage3 side | Comparison |
|-------|-----------------|-------------|------------|
| typecheck | `tg_pipeline_smoke.exe --repo-root ROOT <file>` (the per-file corpus path) | `<stage3> check <file>` exit status | AGREE = identical accept/reject verdict |
| lower-mir | `tg_stage0.exe lower <file>` (check + Seed MIR + verifier + dump) | no pinned MIR projection | NOT-IMPLEMENTED (reported, never PASS) |
| vm | the smoke's corpus-path VM run (exit code + returned value) | no observable execution baseline (`check` is compile-only) | NOT-IMPLEMENTED (reported, never PASS) |

`NOT-IMPLEMENTED` is a distinct verdict that fails the run — never a
silent skip. The legacy `tg_stage0 diff` token/AST normalization harness
was retired with the Swift stage0; the OCaml seed's own `lex`/`dump-ast`
surfaces are exercised by its selfchecks.

## Verdicts and exit codes

| Verdict | Meaning |
|---------|---------|
| AGREE | the implemented comparison point agrees with the stage3 baseline |
| DISAGREE | the verdicts differ (the divergence dominates the exit code) |
| NOT-IMPLEMENTED | a required comparison point has no baseline on one side |

Exit codes of `scripts/run_differential.sh`:
`0` every implemented comparison point agreed; `1` any implemented point
disagreed or a file had no usable OCaml verdict; `2` a required comparison
point is NOT-IMPLEMENTED, a required binary is missing, or a retired
`--swift-only`/`--three-way` mode was requested.

## The corpus gate

Every positive corpus file is checked by the OCaml seed (`check` / `lower`
via the harness); the corpus's negative cases carry their expected codes in
`corpus.manifest` and are exercised by the seed's selfchecks and the
stage3 test runner. The Swift-era `--self-check` / `--probe` pre-flight
flags were retired with the Swift stage0.

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
scripts/run_differential.sh                # the OCaml-seed-vs-stage3 gate
                                           # (needs the OCaml seed binaries
                                           # and a ladder-produced stage3)
scripts/run_differential.sh --ocaml-only   # explicit form of the default
TG_STAGE3_BIN=/path/to/tg_stageN scripts/run_differential.sh
TG_OCAML_STAGE0_BIN=/path/to/tg_stage0.exe scripts/run_differential.sh
```

The stage3 side requires a ladder-produced binary (the self-hosted
`build/tg_stage1` by default, or `TG_STAGE3_BIN`). A missing binary makes
the run fail with exit 2 — parity is never claimed against a front end
that cannot be compared. The `--swift-only` and `--three-way` modes are
retired and exit 2 with an explicit message.

## Typed-program / MIR parity (documented extension)

The reviewer's corpus mandate names TypedProgram and MIR comparisons as
well. The stage3 dump surface already exposes the phase hooks
(`--dump-resolved-ast`, `--dump-mir-lowered`, `--dump-mir-mono`,
`--dump-mir-opt`; the OCaml seed side has `lower`), but the normalized
comparison of those phases is NOT part of this harness yet: the harness
currently pins the typecheck verdict (plus per-file lower-mir / VM
reporting) of the current parity phases. Adding the resolved-ast and
MIR agreement points means adding the two missing stage3 baselines and
the per-file comparison rows — the gate semantics do not change.
