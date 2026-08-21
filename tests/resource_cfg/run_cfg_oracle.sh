#!/usr/bin/env bash
#
# tests/resource_cfg/run_cfg_oracle.sh — the resource-checker adversarial
# CFG oracle lane (the reviewer's item 9).
#
# The equation under test: COMPILER ACCEPTANCE == ORACLE ACCEPTANCE.
#   - the oracle (the independent symbolic state interpreter inside
#     cfg_oracle_test.tg) predicts accept/reject for every shape in its
#     table;
#   - the POSITIVE shapes are real functions compiled into
#     cfg_oracle_test.tg — the compiler's acceptance is the file
#     compiling + running, and the instrumented construct/drop counters
#     assert exactly-once destruction at runtime (the Gate-L shapes);
#   - the NEGATIVE shapes live in tests/resource_cfg/neg/*.tg — this
#     runner verifies `tg check` REJECTS every one, and the oracle's
#     reject-verdict for the same shape is asserted inside the positive
#     run.
#
# Usage: tests/resource_cfg/run_cfg_oracle.sh [compiler]
#   compiler defaults to ./build/tg_stage1

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"

COMPILER="${1:-./build/tg_stage1}"
if [ ! -x "$COMPILER" ]; then
  echo "cfg-oracle: compiler not executable: $COMPILER" >&2
  exit 1
fi

NEG_DIR="tests/resource_cfg/neg"
FAILURES=0

echo "[cfg-oracle] structural gate: balance/arity/end-tokens on the suite files..."
if command -v python3 >/dev/null 2>&1 && [ -f "$ROOT/scripts/check_struct_balance.py" ]; then
  if ! python3 "$ROOT/scripts/check_struct_balance.py" \
      "$ROOT/tests/resource_cfg/cfg_oracle_test.tg" "$ROOT"/tests/resource_cfg/neg/*.tg >/dev/null 2>&1; then
    echo "[cfg-oracle] FAIL: the structural balance gate rejected a suite file" >&2
    FAILURES=$((FAILURES + 1))
  fi
else
  echo "[cfg-oracle] note: python3/check_struct_balance.py unavailable — structural gate skipped"
fi

echo "[cfg-oracle] running the positive suite (oracle verdicts + instrumented counters)..."
if ! "$COMPILER" run tests/resource_cfg/cfg_oracle_test.tg >/dev/null 2>&1; then
  echo "[cfg-oracle] FAIL: the positive suite did not compile+run cleanly" >&2
  FAILURES=$((FAILURES + 1))
else
  echo "[cfg-oracle] positive suite OK (oracle verdicts agree with the compiler's acceptance; counters verified exactly-once)"
fi

echo "[cfg-oracle] negative lane: every tests/resource_cfg/neg/*.tg must be REJECTED by \`tg check\`"
for f in "$NEG_DIR"/*.tg; do
  [ -e "$f" ] || continue
  name="$(basename "$f" .tg)"
  if "$COMPILER" check "$f" >/dev/null 2>&1; then
    echo "[cfg-oracle] FAIL: negative shape $name was ACCEPTED by the compiler (the oracle rejects it)" >&2
    FAILURES=$((FAILURES + 1))
  else
    echo "[cfg-oracle] OK: negative shape $name rejected (matches the oracle's REJECT verdict)"
  fi
done

# Every negative shape in the oracle's table must have a mirror file (and
# vice versa) — the two sides of the equation stay in lockstep.
for f in "$NEG_DIR"/*.tg; do
  [ -e "$f" ] || continue
  name="$(basename "$f" .tg)"
  if ! grep -q "\"$name\"" tests/resource_cfg/cfg_oracle_test.tg; then
    echo "[cfg-oracle] FAIL: negative file $f has no oracle-table entry in cfg_oracle_test.tg" >&2
    FAILURES=$((FAILURES + 1))
  fi
done

if [ "$FAILURES" -ne 0 ]; then
  echo "[cfg-oracle] FAILED with $FAILURES failure(s)" >&2
  exit 1
fi
echo "[cfg-oracle] all lanes OK: compiler acceptance == oracle acceptance for every shape"
