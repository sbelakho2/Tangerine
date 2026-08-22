# Tangerine Coverage Oracles

The coverage-oracle layer: the compiler's variant universes, the grammar
productions, and the std public API are exercised by the tests —
ENFORCED by machine-checked oracles, never claimed. Every oracle below
prints the coverage table and exits non-zero on any uncovered entity.

## 1. The variant-coverage oracle (`scripts/check_variant_coverage.sh`)

Three domains, one script:

| Domain | Enumerated from | Variants | Exercising suites |
|---|---|---|---|
| `mir` | `tg_compiler/mir.tg` (`MirRvalueKind`, `MirTerminatorKind`, `Projection`) | 24 | `tests/mir_variant_coverage_tests.tg` (the unit layer — every variant constructed, duplicated, identity-asserted), `tests/mir_variant_specimens.tg` (the source-level producers) |
| `ast` | `tg_compiler/ast.tg` (`StmtKind`, `ExprKind`, `TypeExprKind`) | 70 | `tests/ast_variant_coverage_tests.tg` (inline compile-positive specimens + parse-level statements + unit constructions for the no-source-producer forms) |
| `type` | `tg_compiler/types.tg` (`Type`) | 33 | `tests/type_variant_coverage_tests.tg` (inline specimens + the all-33 unit construction) |

The oracle derives the variant facts FROM THE COMPILER SOURCE (the enum
bodies), so the enumeration can never drift; every variant carries a
fingerprint lexicon (the producing operation, the specimen marker, the
unit-construction token), and a variant with no fingerprint entry — or
no exercising test — fails the gate. The kind-name functions inside the
test suites are exhaustive matches (no default arm): a variant missing
from them is a compile error, pinning the tests to the enums.

### 1a. MirRvalueKind (10/10)

| Variant | Exercising test |
|---|---|
| `MirMove` | `tests/mir_variant_coverage_tests.tg` (unit), `tests/mir_variant_specimens.tg` (the `let b = a` move) |
| `MirRef` | unit; `tests/mir_variant_specimens.tg` (the `&counter` access marker) |
| `MirAggregate` | unit (all five `AggregateKind` payloads); specimens (struct/array literals) |
| `MirBinOp` | unit; specimens (arithmetic/comparison operators) |
| `MirUnOp` | unit; specimens (`-x`, `!flag`, `~x`) |
| `MirDiscriminant` | unit; specimens (enum match) |
| `MirLen` | unit; specimens (`.len()`) |
| `MirCast` | unit; specimens (`as` casts) |
| `MirRepeat` | unit (no source-level producer — the repeat literal is not lowered; the unit layer closes it) |
| `MirPhi` | unit; specimens (loop back-edge) |

### 1b. MirTerminatorKind (8/8)

| Variant | Exercising test |
|---|---|
| `MirGoto` | unit; specimens (if branch) |
| `MirReturn` | unit; specimens (`return 42`) |
| `MirUnreachable` | unit (the placeholder terminator) |
| `MirSwitchInt` | unit; specimens (int match) |
| `MirCall` | unit; specimens (direct call) |
| `MirAssert` | unit (all six `AssertMessage` payloads); specimens (index bounds-check) |
| `MirAbort` | unit; specimens (`panic`) |
| `MirDeinit` | unit; specimens (resource `deinit`) |

### 1c. Projection (6/6)

| Variant | Exercising test |
|---|---|
| `ProjDeref` | unit; specimens (`*p` raw deref) |
| `Field` | unit; specimens (struct field access) |
| `Variant` | unit; specimens (enum payload match) |
| `TupleIndex` | unit; specimens (`t.0`) |
| `ProjIndex` | unit; specimens (variable-index Vec access) |
| `ProjConstantIndex` | unit; specimens (constant array index) |

### 1d. StmtKind (18/18 — 15 compile-positive inline, 3 parse-positive)

`StmtTry` / `StmtWith` / `StmtHandleWith` parse and the AST keeps them,
but the pipeline REJECTS them after parsing by design ("exceptions are
not supported — no throwing path may bypass teardown"); their specimens
are parse-level (a snippet with zero parse errors whose AST contains the
variant), exercised in `tests/ast_variant_coverage_tests.tg`
(`test_parse_only_statement_variants`).

### 1e. ExprKind (38/38 — 36 compile-positive inline, 2 unit-constructed)

`ExprAssign` and `ExprError` have no parser producer (macro-expansion
forms); they are constructed by hand in
`tests/ast_variant_coverage_tests.tg` (`test_unit_constructed_variants`).

### 1f. TypeExprKind (14/14 — 12 compile-positive inline, 2 unit-constructed)

`TypeExprKind::Never` and `TypeExprKind::Effect` have no parser
construction site; they are unit-constructed.

### 1g. Type (33/33)

The primitives, the sized integers, `Adt`, `FixedArray`, `FnPtr`,
`Closure`, `RefInternal` (the `__intrinsic_`-scoped extern ABI), `Ptr`,
`PtrMut`, `Dyn`, `Tuple` are exercised by the inline specimens; the
checker/MIR-internal forms (`StaticStrPtr`, `Never`, `IntLiteral`,
`Effect`, `Var`, `Param`, `Error`) are constructed and named by
`tests/type_variant_coverage_tests.tg`'s unit test. The layout tests
(`tests/layout/`, `tests/layout_tests.tg`) exercise the same universe
from the layout engine's side.

## 2. Gate F — the grammar-production coverage

- The facts: `docs/current/grammar_facts.toml` — the 108-production
  enumeration derived from `docs/current/grammar.md`'s EBNF rule set
  (the syntactic non-terminals), each with its rule text and its
  `verify` mode (`check`, or `parse` for `try_expr` /
  `handle_with_expr` — pipeline-rejected after parsing by design).
- The specimens: `tests/grammar_f/` — for every production, four
  specimens generated by `scripts/gen_grammar_f_specimens.py`:
  `pos/<prod>_minimal.tg`, `pos/<prod>_nested.tg`,
  `neg/<prod>_before.tg`, `neg/<prod>_after.tg`. The negative specimens
  are the minimal positive with a parse-error line inserted BEFORE /
  AFTER the construct — the parser must still reject the program, so a
  production that swallows an error (or the rest of the file) fails.
- The gate: `scripts/check_grammar_f_gate.sh` — facts↔files parity,
  regenerate-then-diff parity, the positional specimen structure
  (the error line sits before/after the construct's marker), and —
  when a current-grammar compiler binary exists — the compiler
  verdicts (positives pass, negatives produce a diagnostic).
- 108/108 productions covered (216 positive + 216 negative specimens).

## 3. The std public-API coverage (oracle #5)

- The per-symbol associations: `scripts/api_manifest_associator.py`
  attributes every public callable (function / method / constructor) to
  the tests that reference it (`tests/**/*.tg`, excluding the generated
  sweep suite) and embeds the associations per callable in
  `build/public_api_manifest.json`. The honest bounded uncovered
  enumeration — the callables of the behavior-family modules
  (native/lane, non-experimental) referenced by no test — is listed per
  module in `gates.uncovered_callables` and fails the release check.
- The tests-added layer: `scripts/gen_api_manifest_sweep.py` generates
  `tests/api_manifest/<module>_symbol_sweep.tg` for every module with
  uncovered callables — the uncovered functions are use-imported, bound
  as function values, and called when zero-argument (real code
  references; the files must compile). The methods/constructors are
  enumerated in the file headers as the honest remaining gap.
- The extractor's health: `scripts/check_api_manifest_extractor.sh` —
  fixture-based: the structural extraction is compared EXACTLY against
  the expected records (and the health failures — unterminated block /
  no public item / unparsable opener — must be detected), the
  per-symbol associations are compared exactly (including the bounded
  exclusions), and the sweep suite's closure (regeneration parity +
  every uncovered callable referenced + compile when a usable binary
  exists) is enforced.
- The current honest state (regenerated from the tree):
  **6465 public callables, 1406 referenced by behavior tests, 1586
  uncovered (bounded)**; the sweep suite (50 files) references all 1586
  in code; the methods/constructors inside them are the documented
  remaining behavior-test gap.

## 4. The compiler-source coverage (oracle #6)

- The oracle: `scripts/check_compiler_file_coverage.sh` — every
  `tg_compiler/*.tg` file is attributed to the tests that reference it
  (`tg_compiler::<module>` in tests/**/*.tg, `<file>.tg` in the
  tests/*.sh tool lanes); a file with no exercising test fails the
  gate.
- The tests-added layer: `tests/compiler_module_sweep_tests.tg`
  references every compiler module by qualified path (including the
  entry points and the tool modules — all 35 previously-uncovered
  files), so the attribution is closed: **49/49 compiler files
  exercised**.
