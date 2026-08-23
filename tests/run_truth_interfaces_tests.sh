#!/usr/bin/env bash
#
# tests/run_truth_interfaces_tests.sh — the reviewer's false-success
# interfaces lane:
#
#   (1) the -g flag is the REJECTION: `tg compile -g <file>` fails with
#       the explicit "debug info is not supported" error — the inert
#       debug_info option is gone (no compile path emits debug info, so
#       the flag is never silently accepted).
#   (2) `tg agent check` is the REAL semantic verification: a file with
#       an unsatisfiable contract (pre false) is REPORTED — the
#       violation is counted and the invocation fails — and a clean file
#       passes with zero violations (the never-incremented
#       violation_count stub is gone).
#   (3) std::gpu_vulkan's device properties are the UNSUPPORTED contract
#       (P1.11): the enumeration returns the Unsupported error and never
#       FABRICATES device values (the undefined `from_native` path is
#       gone); the software/reference backend stays the supported path.
#       The check is structural (the module's FFI surface is unbound, so
#       it cannot be executed on this host).
#
# Usage: tests/run_truth_interfaces_tests.sh [compiler]
#   compiler defaults to ./build/tg_stage1
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
COMPILER="${1:-./build/tg_stage1}"
FAILURES=0

if [ ! -x "$COMPILER" ]; then
  echo "truth-interfaces: compiler not executable: $COMPILER" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tg_truth.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

# check <desc> <expected-exit> <actual-exit>
check() {
  if [ "$3" -eq "$2" ]; then
    pass "$1"
  else
    fail "$1 (exit $3, expected $2)"
  fi
}

echo "========================================"
echo "truth interfaces: compiler = $COMPILER"
echo "========================================"

echo ""
echo "--- (1) the -g rejection ---"

cat > "$TMP/gflag.tg" <<'EOF'
def main() -> Int
  0
end
EOF

OUT="$("$COMPILER" compile -g "$TMP/gflag.tg" 2>&1)"; RC=$?
check "tg compile -g is REJECTED (nonzero)" 1 "$RC"
if echo "$OUT" | grep -q "debug info is not supported"; then
  pass "-g rejection message printed"
else
  fail "-g rejection message missing: $OUT"
fi

"$COMPILER" run -g "$TMP/gflag.tg" >/dev/null 2>&1
check "tg run -g is REJECTED (nonzero)" 1 $?

"$COMPILER" check -g "$TMP/gflag.tg" >/dev/null 2>&1
check "tg check -g is REJECTED (nonzero)" 1 $?

echo ""
echo "--- (2) tg agent check: the real semantic verification ---"

# The UNSATISFIABLE contract: `pre false` is trivially false — the
# checker's contract machinery must report it as a violation.
cat > "$TMP/bad_contract.tg" <<'EOF'
def divide(a: Int, b: Int) -> Int
  pre false
  a / b
end

def main() -> Int
  0
end
EOF

OUT="$("$COMPILER" agent check "$TMP/bad_contract.tg" 2>&1)"; RC=$?
check "tg agent check on an unsatisfiable contract FAILS" 1 "$RC"
if echo "$OUT" | grep -q "Violations: 1"; then
  pass "the violation is counted (Violations: 1)"
else
  fail "violation count missing: $OUT"
fi
if echo "$OUT" | grep -q "unsatisfiable precondition"; then
  pass "the violation is reported (unsatisfiable precondition)"
else
  fail "violation report missing: $OUT"
fi

# The CLEAN file: no contracts at all — zero violations and success.
cat > "$TMP/clean.tg" <<'EOF'
def add(a: Int, b: Int) -> Int
  a + b
end

def main() -> Int
  0
end
EOF

OUT="$("$COMPILER" agent check "$TMP/clean.tg" 2>&1)"; RC=$?
check "tg agent check on a clean file PASSES" 0 "$RC"
if echo "$OUT" | grep -q "Violations: 0"; then
  pass "the clean file counts zero violations"
else
  fail "clean file violation count: $OUT"
fi

echo ""
echo "--- (3) std::gpu_vulkan: the UNSUPPORTED device properties (no fabricated values) ---"

if grep -q "physical-device enumeration is UNSUPPORTED" std/gpu_vulkan.tg; then
  pass "the enumeration returns the UNSUPPORTED error"
else
  fail "std/gpu_vulkan.tg has no UNSUPPORTED device-properties diagnostic"
fi

if grep -q "never fabricates device values" std/gpu_vulkan.tg; then
  pass "the module states the never-fabricate contract"
else
  fail "std/gpu_vulkan.tg does not state the never-fabricate contract"
fi

if grep -q "from_native" std/gpu_vulkan.tg; then
  fail "std/gpu_vulkan.tg still references the undefined PhysicalDevice::from_native fabrication path"
else
  pass "the undefined from_native fabrication path is gone"
fi

if grep -q "use the software/reference backend (std::gpu) or bind the real loader FFI" std/gpu_vulkan.tg; then
  pass "the supported path (the software/reference backend) is stated"
else
  fail "std/gpu_vulkan.tg does not point to the software/reference backend"
fi

echo ""
if [ "$FAILURES" -eq 0 ]; then
  echo "truth-interfaces: all lanes OK"
  exit 0
else
  echo "truth-interfaces: $FAILURES FAILURES" >&2
  exit 1
fi
