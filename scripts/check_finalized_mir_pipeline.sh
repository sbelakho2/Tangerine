#!/usr/bin/env bash
#
# check_finalized_mir_pipeline.sh — the no-duplicated-sequence gate for the
# shared finalized-MIR pipeline (tg_compiler/finalize.tg).
#
# THE RULE (audit finding): the normative verified pipeline —
#   lower -> verify post-lower -> effect/purity/budget annotations ->
#   mono (persistent cache path) -> verify post-mono (unconditional) ->
#   ABI/tail/target stamps -> optimize -> post-opt verify ->
#   final pre-codegen verify
# — is owned by ONE shared entry, finalize_verified_mir. Every full-library
# production route calls it exactly once and NEVER re-spells the phase
# calls. This gate enforces that on the two route modules:
#
#   tg_compiler/driver.tg            — LIR, snapshot and wasm routes
#                                      (3 calls; the coverage-harness route
#                                      runs the SAME shared entry through
#                                      coverage.tg's ONE harness-
#                                      construction entry below)
#   tg_compiler/semantic_server.tg   — session_compile_source and
#                                      session_verified_edit_full (2 calls)
#   tg_compiler/coverage.tg          — the ONE coverage-harness
#                                      construction (1 call) the CLI route
#                                      AND the verified-edit transaction
#                                      share (the transaction cannot import
#                                      driver.tg, cycle)
#
# The DIRECT phase calls may only survive at the DOCUMENTED KERNEL /
# INSPECTION exceptions (the kernel paths live in compiler_core.tg, which
# this gate does not scan for phase reuse because the shared full-library
# entry is out of its closure — see finalize.tg's module doc):
#
#   driver.tg
#     - driver_lower_to_mir (x3): the CQS query pass and the budget
#       analysis pass stop after lowering (no verification, no codegen —
#       not compile routes), plus dump_abi_plans_direct;
#     - verify_mir / monomorphize_program / stamp_tail_abi_plans (x1 each):
#       dump_abi_plans_direct, the documented EXPLICIT-EPHEMERAL
#       inspection (no persistent store, no optimizer, no artifact) that
#       reads the SAME plan authority as the LIR route's --dump-abi-plans
#       stop shape.
#
# The same gate also enforces the test-harness construction and the
# synthesis wrapper no-duplication:
#
#   * coverage.tg owns ONE harness-construction entry
#     (coverage_harness_build_and_run: dispatch-main generation, compile
#     through finalize_verified_mir, coverage emission plan, LIR
#     executable, per-test execution, trace ingest). The driver's CLI
#     route and both transaction legs call ONLY that entry — no caller
#     re-spells the pipeline pieces.
#   * test_synthesis.tg owns ONE synthesis wrapper
#     (synthesize_delta_suite: producer + render). The driver's synthesis
#     entry and the transaction's bounded loop call it; neither calls the
#     producer directly.
#
# Usage: scripts/check_finalized_mir_pipeline.sh
# Exit status: 0 when the route modules are clean; 1 otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

DRIVER="tg_compiler/driver.tg"
SERVER="tg_compiler/semantic_server.tg"
COVERAGE="tg_compiler/coverage.tg"
SYNTHESIS="tg_compiler/test_synthesis.tg"
FINALIZE="tg_compiler/finalize.tg"

fail() { echo "[finalize-pipeline:error] $*" >&2; exit 1; }

for f in "$DRIVER" "$SERVER" "$COVERAGE" "$SYNTHESIS" "$FINALIZE"; do
  [ -f "$f" ] || fail "missing $f"
done

# count_occurrences <file> <literal>; 0 when absent (never fails the gate).
count_occurrences() {
  local n
  n="$(grep -cF -- "$2" "$1" 2>/dev/null || true)"
  if [ -z "$n" ]; then n=0; fi
  printf '%s' "$n"
}

expect_count() {
  local file="$1" literal="$2" want="$3" why="$4"
  local got
  got="$(count_occurrences "$file" "$literal")"
  if [ "$got" != "$want" ]; then
    fail "$file: expected $want occurrence(s) of '$literal' ($why), found $got — the route must run this phase through finalize_verified_mir (tg_compiler/finalize.tg), not hand-spell it"
  fi
}

# ———————————————————————————————————————————————————————————————
# driver.tg — the production routes must not hand-spell the sequence.
# ———————————————————————————————————————————————————————————————
expect_count "$DRIVER" "finalize_verified_mir(" 3 \
  "the LIR, snapshot-serve and wasm routes (the coverage-harness route goes through coverage.tg's ONE entry)"
expect_count "$DRIVER" "snapshot_lineage_view_of(" 0 "the pre-mono view is built inside the shared entry"
expect_count "$DRIVER" "mono_cache_new_persistent(" 0 "the persistent cache is built inside the shared entry"
expect_count "$DRIVER" "check_effect_class_annotations_mir(" 0 "the §11 check is owned by the shared entry"
expect_count "$DRIVER" "check_purity_annotations_mir(" 0 "the purity theorem is owned by the shared entry"
expect_count "$DRIVER" "check_budget_annotations_mir(" 0 "the @budget check is owned by the shared entry"
expect_count "$DRIVER" "optimize_mir(" 0 "the optimizer is owned by the shared entry"
expect_count "$DRIVER" "stamp_slp_vector_facility_desc(" 0 "the SLP stamp is owned by the shared entry"

# The documented driver exceptions (see the header): the two analysis-only
# lowering calls and the explicit-ephemeral --dump-abi-plans inspection.
expect_count "$DRIVER" "driver_lower_to_mir(" 3 "CQS pass + budget analysis + dump_abi_plans_direct"
expect_count "$DRIVER" "verify_mir(" 1 "dump_abi_plans_direct (explicit ephemeral inspection)"
expect_count "$DRIVER" "monomorphize_program(" 1 "dump_abi_plans_direct (explicit ephemeral inspection)"
expect_count "$DRIVER" "stamp_tail_abi_plans(" 1 "dump_abi_plans_direct (explicit ephemeral inspection)"

# ———————————————————————————————————————————————————————————————
# semantic_server.tg — both session pipelines run the shared entry only.
# ———————————————————————————————————————————————————————————————
expect_count "$SERVER" "finalize_verified_mir(" 2 \
  "session_compile_source and session_verified_edit_full"
for literal in \
  "driver_lower_to_mir(" "verify_mir(" "monomorphize_program(" \
  "mono_cache_new_persistent(" "check_effect_class_annotations_mir(" \
  "check_purity_annotations_mir(" "check_budget_annotations_mir(" \
  "optimize_mir(" "snapshot_lineage_view_of(" \
  "stamp_tail_abi_plans(" "stamp_slp_vector_facility_desc("
do
  expect_count "$SERVER" "$literal" 0 "both session pipelines are migrated"
done

# ———————————————————————————————————————————————————————————————
# coverage.tg — the ONE coverage-harness construction the CLI route and
# the verified-edit transaction share (it lives here because driver.tg
# imports semantic_server.tg, so the transaction cannot import the
# driver; the module imports neither). It runs the shared finalized-MIR
# entry once and owns every harness phase.
# ———————————————————————————————————————————————————————————————
expect_count "$COVERAGE" "finalize_verified_mir(" 1 \
  "the harness construction runs the shared entry once"
for literal in \
  "driver_lower_to_mir(" "verify_mir(" "monomorphize_program(" \
  "mono_cache_new_persistent(" "check_effect_class_annotations_mir(" \
  "check_purity_annotations_mir(" "check_budget_annotations_mir(" \
  "optimize_mir(" "snapshot_lineage_view_of(" \
  "stamp_tail_abi_plans(" "stamp_slp_vector_facility_desc("
do
  expect_count "$COVERAGE" "$literal" 0 "the harness pipeline is migrated"
done

# The harness-construction dedup: ONE entry owns dispatch-main generation,
# the compile, the coverage emission plan, the LIR executable, the
# per-test execution and the trace ingest; every caller calls only it.
expect_count "$COVERAGE" "pub def coverage_harness_build_and_run(" 1 \
  "the ONE harness-construction entry"
expect_count "$DRIVER" "coverage_harness_build_and_run(" 1 \
  "the CLI coverage route calls the ONE shared harness entry"
for literal in \
  "coverage_harness_compile(" "coverage_harness_run(" \
  "coverage_trace_bind_stable(" "coverage_ingest("
do
  expect_count "$DRIVER" "$literal" 0 \
    "the driver never re-spells the harness pipeline"
done
expect_count "$SERVER" "coverage_harness_build_and_run(" 2 \
  "both transaction legs call the ONE shared harness entry"
for literal in "coverage_harness_compile(" "coverage_harness_run("
do
  expect_count "$SERVER" "$literal" 0 \
    "the transaction calls the ONE entry, never the pipeline pieces"
done

# The synthesis dedup: ONE wrapper (test_synthesis.synthesize_delta_suite:
# producer + render) is called by the driver entry and the transaction;
# neither calls the producer directly.
expect_count "$SYNTHESIS" "pub def synthesize_delta_suite(" 1 \
  "the ONE shared synthesis wrapper"
for file in "$DRIVER" "$SERVER"; do
  expect_count "$file" "synthesize_tests_for_delta(" 0 \
    "the producer is called only inside the shared wrapper"
  expect_count "$file" "render_synthesized_suite(" 0 \
    "the render composition is owned by the shared wrapper"
  expect_count "$file" "synthesize_delta_suite(" 1 \
    "the caller runs the shared wrapper"
done

# ———————————————————————————————————————————————————————————————
# finalize.tg — ONE entry, and it really owns the sequence.
# ———————————————————————————————————————————————————————————————
expect_count "$FINALIZE" "pub def finalize_verified_mir(" 1 "the ONE shared entry"
expect_count "$FINALIZE" "verify_mir(" 4 "post-lower / post-mono / post-opt / pre-codegen"
expect_count "$FINALIZE" "monomorphize_program(" 1 "the mono step"
expect_count "$FINALIZE" "mono_cache_new_persistent(" 1 "the persistent cache path"
expect_count "$FINALIZE" "snapshot_lineage_view_of(" 1 "the pre-mono lineage view"
expect_count "$FINALIZE" "optimize_mir_verified(" 1 "the release optimizer entry"
expect_count "$FINALIZE" "optimize_mir_with_decisions(" 1 "the decision-capturing entry"

echo "[finalize-pipeline] OK: the shared finalized-MIR pipeline owns the verified sequence (driver.tg x3 routes, semantic_server.tg x2 pipelines, coverage.tg x1 harness construction); the ONE coverage-harness entry and the ONE synthesis wrapper are the only call sites (driver CLI + transaction); no route hand-spells the phase calls."
