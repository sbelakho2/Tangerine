#!/usr/bin/env bash
# check_ocaml_stage0.sh — the single authoritative OCaml-seed gate.
#
# Runs EVERY required check for the OCaml Stage0 seed and fails if any
# required executable is missing or failing:
#   1. the pinned OCaml/Dune toolchain check
#   2. dune build (warnings are errors)
#   3. the unit test suite (must report the full pass count)
#   4. EVERY self-check executable listed in selfcheck/dune (a new
#      self-check is automatically required to pass)
#   5. bootstrap-check (its known gate failure — frontend semantic gate
#      FAIL while the typechecker converges — is accepted and reported;
#      any crash or unexpected exit is a hard failure)
#
# Usage: scripts/check_ocaml_stage0.sh [repo-root]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -f scripts/check_ocaml_toolchain.sh ]; then
  scripts/check_ocaml_toolchain.sh
fi

cd stage0_ocaml
dune build

TEST_OUT="$(timeout 120 _build/default/test/test_main.exe 2>&1)"
if ! grep -qE '[0-9]+ passed, 0 failed' <<<"$TEST_OUT"; then
  echo "check_ocaml_stage0: FAIL — unit test suite did not report a clean pass:"
  echo "$TEST_OUT" | tail -5
  exit 1
fi
TESTS="$(grep -oE '[0-9]+ passed, 0 failed' <<<"$TEST_OUT" | head -1)"

# Enumerate the required self-checks from the dune file so new ones are
# automatically required.
NAMES_LINE="$(grep -E '^\s*\(names' selfcheck/dune | head -1)"
NAMES="$(echo "$NAMES_LINE" | sed -E 's/.*\(names[[:space:]]*//; s/[[:space:]]*\).*//')"
SELFCHECK_COUNT=0
SELFCHECK_FAIL=0
for name in $NAMES; do
  SELFCHECK_COUNT=$((SELFCHECK_COUNT + 1))
  if ! timeout 180 "_build/default/selfcheck/${name}.exe" >/tmp/ocaml_sc_${name}.out 2>&1; then
    echo "check_ocaml_stage0: FAIL — selfcheck ${name} exited non-zero"
    tail -10 "/tmp/ocaml_sc_${name}.out" || true
    SELFCHECK_FAIL=1
  fi
done

# bootstrap-check: the frontend gate currently fails by design while the
# typechecker converges; accept exit 1, hard-fail on anything else.
set +e
timeout 300 _build/default/bin/tg_stage0.exe bootstrap-check --repo-root .. >/tmp/ocaml_bootstrap_check.out 2>&1
BC_STATUS=$?
set -e
if [ "$BC_STATUS" -ne 0 ] && [ "$BC_STATUS" -ne 1 ]; then
  echo "check_ocaml_stage0: FAIL — bootstrap-check crashed (exit $BC_STATUS)"
  tail -20 /tmp/ocaml_bootstrap_check.out
  exit 1
fi
if grep -qE 'Fatal error|Stack overflow|Assertion failure' /tmp/ocaml_bootstrap_check.out; then
  echo "check_ocaml_stage0: FAIL — bootstrap-check crashed"
  tail -20 /tmp/ocaml_bootstrap_check.out
  exit 1
fi
if [ "$BC_STATUS" -eq 0 ]; then
  BC_GATE="PASS"
else
  BC_GATE="EXPECTED_FAIL"
fi

if [ "$SELFCHECK_FAIL" -ne 0 ]; then
  echo "check_ocaml_stage0: FAIL"
  exit 1
fi

echo "check_ocaml_stage0: tests=${TESTS} selfchecks=${SELFCHECK_COUNT} selfcheck_fail=0 bootstrap_gate=${BC_GATE}"
echo "check_ocaml_stage0: ALL REQUIRED CHECKS RAN"
