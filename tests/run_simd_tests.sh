#!/usr/bin/env bash
#
# tests/run_simd_tests.sh — the SIMD test lane (the mandate's SIMD (e),
# P1.12).
#
# Runs the three committed SIMD suites against the given tg compiler
# binary: the behavior suite (the vector add/shuffle/load-store vs the
# scalar reference), the layout suite (the VECTOR ROW assertions: size =
# N lanes x lane size, alignment = the vector width), and the ABI probe
# (the 16-byte vector through the registers vs the 32/64-byte by-address
# classification).
#
# Plus the CLAIMS' HONESTY gate: the std/simd.tg module header and the
# registry/docs must state the proof state exactly — the intrinsics + the
# codegen arms implemented, the NATIVE EXACT-VECTOR execution tests NOT
# yet run — and must carry NO unproven "production-ready" claim.
#
# Usage: tests/run_simd_tests.sh <compiler>
#   <compiler>  the tg compiler binary (a stage/bootstrap binary)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <compiler>" >&2
  exit 1
fi

COMPILER="$1"

if [ ! -x "$COMPILER" ]; then
  echo "simd tests: compiler binary not executable: $COMPILER" >&2
  exit 1
fi

echo "== simd tests: the behavior suite (the vector ops vs the scalar reference) =="
"$COMPILER" run tests/simd/simd_behavior_test.tg

echo "== simd tests: the layout suite (the vector rows) =="
"$COMPILER" run tests/simd/simd_layout_test.tg

echo "== simd tests: the ABI probe (the register vs memory vector cases) =="
"$COMPILER" run tests/simd/simd_abi_probe.tg

echo "== simd tests: the claims' honesty (the proof-state separation, P1.12) =="
FAILURES=0
fail() { echo "simd tests: FAIL — $1" >&2; FAILURES=$((FAILURES + 1)); }

# The unproven "production-ready" CLAIM (the old header line) must be
# GONE from the module; the honest NOT-production-ready status must stay.
if grep -qi "production-ready vector operations\|production ready vector operations" std/simd.tg; then
  fail "std/simd.tg still carries the 'production-ready vector operations' claim (the module is experimental; the native exact-vector tests have not run)"
fi

# The honest proof state must be present: implemented (the intrinsics +
# the codegen arms) and NOT-yet-run (the native exact-vector tests).
if ! grep -q "NOT YET RUN" std/simd.tg; then
  fail "std/simd.tg has no 'NOT YET RUN' proof-state marker"
fi
if ! grep -qi "native exact-vector" std/simd.tg; then
  fail "std/simd.tg does not state that the native exact-vector execution tests have not run"
fi
if ! grep -q "NOT production-ready" std/simd.tg; then
  fail "std/simd.tg does not state the NOT-production-ready status"
fi

# The registry (features.toml — the single source) must carry the same
# proof state.
if ! grep -q "NATIVE EXACT-VECTOR execution tests are NOT yet run" features.toml; then
  fail "features.toml's simd summary does not state that the native exact-vector tests are NOT yet run"
fi

# The hand-maintained docs must agree.
if ! grep -q "NATIVE EXACT-VECTOR execution tests are NOT yet run" docs/current/feature_matrix.md; then
  fail "docs/current/feature_matrix.md's SIMD row does not state the not-yet-run proof state"
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "simd tests: $FAILURES honesty failures" >&2
  exit 1
fi
echo "simd tests: the claims' honesty OK (no production-ready claim; the proof state is stated)"

echo "simd tests: PASS"
