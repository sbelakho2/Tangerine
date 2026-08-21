# Tangerine Exact Test Requirements (generated)

> **GENERATED EVIDENCE — do not edit by hand.** This document is rendered
> by `scripts/gen_spec_docs.sh` FROM THE SCHEMAS: every normative fact in
> the five machine-readable files carries its required test artifact(s).
> The generator MECHANICALLY verifies that every artifact below exists in
> the tree (a missing artifact FAILS the generation), and the CI
> evidence-gate job regenerates this document and runs `git diff --exit-code`.

## The requirement map

| Requirement | Schema fact | Required artifacts |
|---|---|---|
| the grammar acceptance (the keywords/operators/precedence/syntax forms of language_spec.toml) | language_spec.toml | `scripts/run_selfhost_grammar_gate.sh` ✓ `tests/grammar_gate_fulltree_test.tg` ✓ `tests/run_stdlib_e106_sweep.sh` ✓ |
| the `tg check` stop point (StopAfter::Mir after stage 11) is exercised by every zero-diagnostics sweep | compiler_pipeline.toml [stop_point.tg check] | `tests/run_stdlib_e106_sweep.sh` ✓ |
| the verifier's seven invariants + the verify-everything boundaries | compiler_pipeline.toml [verifier] | `tests/canary` ✓ `tests/canary_neg` ✓ `tests/differential` ✓ |
| the completeness oracles (semantic + MIR layout availability) | compiler_pipeline.toml [oracle] | `tests/canary` ✓ `tests/canary_neg` ✓ |
| the frozen layout facts of abi_schema.toml [layout.frozen] (the golden layout suite) | abi_schema.toml [layout.frozen] | `tests/layout_tests.tg` ✓ `tests/layout/differential_layout_test.tg` ✓ |
| the FFI C-type mappings + the FFI-opaque alignment table | abi_schema.toml [ffi_mapping] + [layout.frozen.ffi_opaque] | `tests/pthread_abi_test.tg` ✓ `tests/layout_tests.tg` ✓ |
| the per-target capability evidence (every ✓ artifact must exist — enforced by the generator) | target_capabilities.toml [target.*] | `tests/run_target_lane_canaries.sh` ✓ `tests/thread_local_drop_test.tg` ✓ `tests/db_async_pool_test.tg` ✓ |
| the stdlib completeness linkage (stdlib_contracts.toml -> stdlib_completeness.md) | stdlib_contracts.toml | `tests/run_stdlib_completeness_gate.sh` ✓ `tests/run_stdlib_e106_sweep.sh` ✓ |

## The per-target capability evidence (the ✓ marks' artifacts)

- **aarch64-apple-darwin** (10 ✓): `tests/canary` ✓ `tests/canary_neg` ✓ `tests/resource_cfg` ✓ `tests/differential` ✓ `tests/run_target_lane_canaries.sh` ✓ `tests/thread_local_drop_test.tg` ✓ `tests/pthread_abi_test.tg` ✓ `tests/db_mysql_integration_test.tg` ✓ `tests/db_postgres_integration_test.tg` ✓ `tests/db_async_pool_test.tg` ✓
- **x86_64-unknown-linux-gnu** (6 ✓): `tests/canary` ✓ `tests/canary_neg` ✓ `tests/resource_cfg` ✓ `tests/differential` ✓ `tests/run_target_lane_canaries.sh` ✓
- **x86_64-apple-darwin** (4 ✓): `tests/canary` ✓ `tests/canary_neg` ✓ `tests/resource_cfg` ✓ `tests/differential` ✓ `tests/run_target_lane_canaries.sh` ✓
- **x86_64-windows** (3 ✓): `tests/canary` ✓ `tests/canary_neg` ✓ `tests/resource_cfg` ✓ `tests/differential` ✓
- **wasm32** (3 ✓): `tests/canary` ✓ `tests/canary_neg` ✓ `tests/resource_cfg` ✓ `tests/differential` ✓

## The mechanical gates the generator enforces

- every evidence artifact under a ✓ capability exists in the tree;
- the Object -> Static-link -> Dynamic-extern -> Native-run chain is
  strictly increasing per target (no skipped link);
- the front-end rows (Parse/Type/MIR) are true for every target;
- every requirement artifact in the map above exists.

---

*Generated from `language_spec.toml`, `target_capabilities.toml`, `abi_schema.toml`,
`compiler_pipeline.toml` and `stdlib_contracts.toml`.*
