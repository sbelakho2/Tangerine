#!/usr/bin/env bash
#
# tests/run_lint_tests.sh — the `tg lint` CLI contract gate: the exit
# codes (0 clean / 1 errors / 2 warnings-only), the suppression
# (--allow and the #[allow] attribute), the --deny escalation, the
# --json output (RFC 8259-parseable lines), the --list catalog, and the
# deterministic repeat.
#
# Usage: tests/run_lint_tests.sh [compiler]
#   compiler defaults to ./build/tg_stage1
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
COMPILER="${1:-./build/tg_stage1}"
FAILURES=0

if [ ! -x "$COMPILER" ]; then
  echo "lint-gate: compiler not executable: $COMPILER" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tg_lint.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }
check() { # check <desc> <expected-exit> <actual-exit>
  if [ "$3" -eq "$2" ]; then pass "$1"; else fail "$1 (exit $3, expected $2)"; fi
}

echo "========================================"
echo "lint gate: compiler = $COMPILER"
echo "========================================"

# ── fixtures ──────────────────────────────────────────────────────────
CLEAN="$TMP/clean.tg"
cat > "$CLEAN" <<'EOF'
def clean_fn(x: Int) -> Int
  x + 1
end

def main() -> Int
  clean_fn(1)
end
EOF

UNUSED="$TMP/unused.tg"
cat > "$UNUSED" <<'EOF'
def compute() -> Int
  let unused_var = 1
  0
end

def main() -> Int
  compute()
end
EOF

ALLOWED="$TMP/allowed.tg"
cat > "$ALLOWED" <<'EOF'
@[allow("unused_variables")]
def compute() -> Int
  let hidden = 1
  0
end

def main() -> Int
  compute()
end
EOF

BROKEN="$TMP/broken.tg"
cat > "$BROKEN" <<'EOF'
def main() -> Int
  let =
end
EOF

echo ""
echo "--- the exit codes: 0 clean / 1 errors / 2 warnings-only ---"
"$COMPILER" lint "$CLEAN" >/dev/null 2>&1; check "tg lint clean file exits 0" 0 $?
"$COMPILER" lint "$UNUSED" >/dev/null 2>&1; check "tg lint warnings-only exits 2" 2 $?
"$COMPILER" lint "$BROKEN" >/dev/null 2>&1; check "tg lint parse-error file exits 1" 1 $?
"$COMPILER" lint tests/__no_such_file__.tg >/dev/null 2>&1; check "tg lint missing file exits 1" 1 $?

echo ""
echo "--- the diagnostics are printed (human form) ---"
"$COMPILER" lint "$UNUSED" > "$TMP/unused.out" 2>&1; check "tg lint prints the diagnostics" 2 $?
grep -q "unused_variables" "$TMP/unused.out" && pass "the lint name appears in the output" || fail "the lint name appears in the output"

echo ""
echo "--- the suppression: --allow and the #[allow] attribute ---"
"$COMPILER" lint --allow unused_variables "$UNUSED" >/dev/null 2>&1; check "tg lint --allow suppresses (exit 0)" 0 $?
"$COMPILER" lint "$ALLOWED" >/dev/null 2>&1; check "tg lint #[allow] attribute suppresses (exit 0)" 0 $?

echo ""
echo "--- the escalation: --deny makes the lint an error ---"
"$COMPILER" lint --deny unused_variables "$UNUSED" >/dev/null 2>&1; check "tg lint --deny escalates to exit 1" 1 $?

echo ""
echo "--- the --json output is RFC 8259-parseable ---"
"$COMPILER" lint --json "$UNUSED" > "$TMP/lint.json" 2>&1
check "tg lint --json runs" 2 $?
if python3 - <<PY
import json, sys
ok = True
count = 0
with open("$TMP/lint.json") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        obj = json.loads(line)
        count += 1
        assert "file" in obj and "line" in obj and "column" in obj
        assert "lint" in obj and "level" in obj and "message" in obj
sys.exit(0 if ok and count > 0 else 1)
PY
then
  pass "lint --json strict-parse (RFC 8259)"
else
  fail "lint --json strict-parse (RFC 8259): $(cat "$TMP/lint.json")"
fi

echo ""
echo "--- the --list catalog advertises the nine passes ---"
"$COMPILER" lint --list > "$TMP/lints.txt" 2>&1; check "tg lint --list exits 0" 0 $?
for lint in unused_variables unused_imports dead_code needless_mut naming_conventions unsafe_usage large_function redundant_return empty_block; do
  grep -q "$lint" "$TMP/lints.txt" && pass "advertised: $lint" || fail "advertised: $lint"
done

echo ""
echo "--- the deterministic repeat (byte-identical output) ---"
"$COMPILER" lint "$UNUSED" > "$TMP/lint1.out" 2>&1; L1=$?
"$COMPILER" lint "$UNUSED" > "$TMP/lint2.out" 2>&1; L2=$?
check "tg lint deterministic exit" $L1 $L2
cmp -s "$TMP/lint1.out" "$TMP/lint2.out" && pass "tg lint deterministic output" || fail "tg lint deterministic output"

echo ""
if [ "$FAILURES" -ne 0 ]; then
  echo "lint gate FAILED with $FAILURES failure(s)" >&2
  exit 1
fi
echo "lint gate OK: exit codes / printing / suppression / escalation / JSON / --list / determinism all green"
