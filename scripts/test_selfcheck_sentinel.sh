#!/usr/bin/env bash
# test_selfcheck_sentinel.sh — meta-test for the selfcheck sentinel
# verifier (audit P0-4).
#
# Proves the verifier (scripts/check_selfcheck_sentinel.sh) rejects a
# selfcheck that exits 0 but prints nothing, rejects a wrong-name or
# duplicated marker, and accepts the exact single sentinel line.  Runs
# in milliseconds and needs no toolchain.
#
# Usage: scripts/test_selfcheck_sentinel.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERIFIER="$ROOT/scripts/check_selfcheck_sentinel.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
expect_reject() {
  local label="$1" name="$2" file="$3"
  if "$VERIFIER" "$name" "$file" >/dev/null 2>&1; then
    echo "selfcheck-sentinel meta-test: FAIL — ${label} was accepted" >&2
    fail=1
  else
    echo "selfcheck-sentinel meta-test: reject ${label}: PASS"
  fi
}

expect_accept() {
  local label="$1" name="$2" file="$3"
  if "$VERIFIER" "$name" "$file" >/dev/null 2>&1; then
    echo "selfcheck-sentinel meta-test: accept ${label}: PASS"
  else
    echo "selfcheck-sentinel meta-test: FAIL — ${label} was rejected" >&2
    fail=1
  fi
}

# 1. A fake executable that exits 0 and prints nothing: the classic
#    false-green the sentinel exists to reject.
cat >"$TMP/fake_silent" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/fake_silent"
"$TMP/fake_silent" >"$TMP/silent.out" 2>&1
expect_reject "silent exit-0 executable" fake "$TMP/silent.out"

# 2. A fake executable that exits 0 and prints the exact sentinel: pass.
cat >"$TMP/fake_pass" <<'EOF'
#!/usr/bin/env bash
echo 'TANGERINE_SELFCHECK_PASS name=fake version=1'
exit 0
EOF
chmod +x "$TMP/fake_pass"
"$TMP/fake_pass" >"$TMP/pass.out" 2>&1
expect_accept "exact sentinel" fake "$TMP/pass.out"

# 3. Wrong name never satisfies the required marker.
printf 'TANGERINE_SELFCHECK_PASS name=other version=1\n' >"$TMP/wrong.out"
expect_reject "wrong-name marker" fake "$TMP/wrong.out"

# 4. A duplicated marker is not "exactly one".
cat "$TMP/pass.out" "$TMP/pass.out" >"$TMP/dup.out"
expect_reject "duplicated sentinel" fake "$TMP/dup.out"

# 5. The word PASS in error text does not satisfy the exact-line rule.
printf 'build FAILED: PASS marker missing\n' >"$TMP/loose.out"
expect_reject "loose PASS text" fake "$TMP/loose.out"

if [ "$fail" -ne 0 ]; then
  echo "test_selfcheck_sentinel: FAIL"
  exit 1
fi
echo "test_selfcheck_sentinel: ALL PASS"
exit 0
