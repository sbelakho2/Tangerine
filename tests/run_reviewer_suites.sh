#!/usr/bin/env bash
#
# tests/run_reviewer_suites.sh — the reviewer items 9/12/13 suite lanes.
#
#   lane 1 (item 9):  the resource-CFG oracle — tests/resource_cfg/
#                     run_cfg_oracle.sh (oracle verdicts + instrumented
#                     counters + the negative lane).
#   lane 2 (item 12): the layout differential — tests/layout/
#                     differential_layout_test.tg vs native C probes
#                     (requires a cc/clang toolchain).
#   lane 3 (item 13): the relocation boundary suite — tests/object/
#                     relocation_boundary_test.tg (width-aware bounds +
#                     the AArch64 ADRP/ADD pair invariants).
#
# Usage: tests/run_reviewer_suites.sh [compiler]
#   compiler defaults to ./build/tg_stage1
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
COMPILER="${1:-./build/tg_stage1}"
FAILURES=0

if [ ! -x "$COMPILER" ]; then
  echo "reviewer-suites: compiler not executable: $COMPILER" >&2
  exit 1
fi

echo "========================================"
echo "reviewer suites: compiler = $COMPILER"
echo "========================================"

echo ""
echo "--- lane 1: resource-CFG oracle (item 9) ---"
if bash tests/resource_cfg/run_cfg_oracle.sh "$COMPILER"; then
  echo "lane 1 OK"
else
  echo "lane 1 FAILED" >&2
  FAILURES=$((FAILURES + 1))
fi

echo ""
echo "--- lane 2: layout differential (item 12) ---"
if "$COMPILER" run tests/layout/differential_layout_test.tg >/dev/null 2>&1; then
  echo "lane 2 OK"
else
  echo "lane 2 FAILED (the differential suite must compile+run cleanly)" >&2
  FAILURES=$((FAILURES + 1))
fi

echo ""
echo "--- lane 3: relocation boundary (item 13) ---"
if "$COMPILER" run tests/object/relocation_boundary_test.tg >/dev/null 2>&1; then
  echo "lane 3 OK"
else
  echo "lane 3 FAILED" >&2
  FAILURES=$((FAILURES + 1))
fi

if [ "$FAILURES" -ne 0 ]; then
  echo "reviewer suites FAILED with $FAILURES failure(s)" >&2
  exit 1
fi
echo "reviewer suites OK: items 9, 12, 13 lanes all green"
