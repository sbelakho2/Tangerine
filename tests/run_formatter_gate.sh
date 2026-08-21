#!/usr/bin/env bash
#
# tests/run_formatter_gate.sh — the reviewer item 6 lane: the formatter's
# semantic-equivalence + idempotence gates asserted over the compiler/std/
# test sources (tests/unit/test_formatter_gate.tg).
#
#   parse(original) == parse(format(original))   (semantic equivalence —
#     the re-parsed programs' structural signatures must match)
#   format(format(x)) == format(x)               (idempotence)
#
# Usage: tests/run_formatter_gate.sh [compiler]
#   compiler defaults to ./build/tg_stage1
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
COMPILER="${1:-./build/tg_stage1}"

if [ ! -x "$COMPILER" ]; then
  echo "formatter-gate: compiler not executable: $COMPILER" >&2
  exit 1
fi

echo "========================================"
echo "formatter gate: compiler = $COMPILER"
echo "========================================"

if "$COMPILER" test tests/unit/test_formatter_gate.tg; then
  echo "formatter gate OK: semantic equivalence + idempotence hold over the tree"
  exit 0
else
  echo "formatter gate FAILED" >&2
  exit 1
fi
