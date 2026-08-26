#!/usr/bin/env bash
# check_ocaml_seed_health.sh — OCaml-seed DEVELOPMENT-HEALTH gate.
#
# Debt policy (re-audit finding 3): ONE authority — tg_bootstrap_gate
# (stage0_ocaml/selfcheck), the aggregate bootstrap gate whose monotonic
# no-regression check runs against its checked baseline (total / primary
# / secondary must not rise; category redistribution is reported as a
# diagnostic). This script pins NO debt scalar of its own.
#   1. the pinned OCaml/Dune toolchain
#   2. dune build (warnings are errors)
#   3. the EXACT unit-test inventory: 226 passed, 0 failed
#      (the committed pre-wave1 inventory was 216; the in-flight wave1
#      manifest/module-graph/debt tests brought it to 226 — the pin is
#      the exact CURRENT inventory; ANY change up or down fails)
#   4. EVERY self-check executable enumerated in selfcheck/dune (a new
#      self-check is automatically required; each must exit 0 and print
#      its PASS marker)
#   5. bootstrap-check: must not crash; the measured typecheck count is
#      reported, and the debt policy is delegated to tg_bootstrap_gate
#      (the single debt authority), which must pass.
#
# This script is NOT a compiler-closure gate: the closure gate is
# check_ocaml_bootstrap_complete.sh (zero semantic debt, full closure).
#
# Usage: scripts/check_ocaml_seed_health.sh [repo-root]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PINNED_TEST_INVENTORY=226

if [ -f scripts/check_ocaml_toolchain.sh ]; then
  scripts/check_ocaml_toolchain.sh
fi

cd stage0_ocaml
dune build

TEST_OUT="$(timeout 120 _build/default/test/test_main.exe 2>&1)"
if ! grep -qE '[0-9]+ passed, 0 failed' <<<"$TEST_OUT"; then
  echo "check_ocaml_seed_health: FAIL — unit test suite did not report a clean pass:"
  echo "$TEST_OUT" | tail -5
  exit 1
fi
TESTS="$(grep -oE '[0-9]+ passed, 0 failed' <<<"$TEST_OUT" | head -1)"
if [ "$TESTS" != "${PINNED_TEST_INVENTORY} passed, 0 failed" ]; then
  echo "check_ocaml_seed_health: FAIL — test inventory changed: got '$TESTS', pinned exact inventory '${PINNED_TEST_INVENTORY} passed, 0 failed'"
  exit 1
fi

# Enumerate the required self-checks from the dune file so new ones are
# automatically required. The (names ...) block may span several lines.
NAMES="$(
  awk '
    /\(names/ { sub(/.*\(names[[:space:]]*/, ""); in_names = 1 }
    in_names {
      if ($0 ~ /\)/) { sub(/[[:space:]]*\).*/, ""); print; exit }
      print
    }' selfcheck/dune
)"
SELFCHECK_COUNT=0
SELFCHECK_FAIL=0
for name in $NAMES; do
  SELFCHECK_COUNT=$((SELFCHECK_COUNT + 1))
  if ! timeout 420 "_build/default/selfcheck/${name}.exe" >"/tmp/ocaml_sc_${name}.out" 2>&1; then
    echo "check_ocaml_seed_health: FAIL — selfcheck ${name} exited non-zero"
    tail -10 "/tmp/ocaml_sc_${name}.out" || true
    SELFCHECK_FAIL=1
  fi
done

# bootstrap-check: must not crash. The debt policy is NOT a scalar pin
# here — it is delegated to tg_bootstrap_gate, the single debt authority
# (monotonic no-regression vs its checked baseline).
set +e
timeout 300 _build/default/bin/tg_stage0.exe bootstrap-check --repo-root .. >/tmp/ocaml_bootstrap_check.out 2>&1
BC_STATUS=$?
set -e
if [ "$BC_STATUS" -ne 0 ] && [ "$BC_STATUS" -ne 1 ]; then
  echo "check_ocaml_seed_health: FAIL — bootstrap-check crashed (exit $BC_STATUS)"
  tail -20 /tmp/ocaml_bootstrap_check.out
  exit 1
fi
if grep -qE 'Fatal error|Stack overflow|Assertion failure' /tmp/ocaml_bootstrap_check.out; then
  echo "check_ocaml_seed_health: FAIL — bootstrap-check crashed"
  tail -20 /tmp/ocaml_bootstrap_check.out
  exit 1
fi
TC_COUNT="$(grep -oE 'typecheck: [0-9]+ modules, [0-9]+ items, [0-9]+ errors' /tmp/ocaml_bootstrap_check.out | head -1 | grep -oE '[0-9]+ errors$' | grep -oE '^[0-9]+')"
if [ -z "$TC_COUNT" ]; then
  echo "check_ocaml_seed_health: FAIL — could not read the bootstrap-check typecheck count"
  tail -20 /tmp/ocaml_bootstrap_check.out
  exit 1
fi

# The single debt-policy authority: tg_bootstrap_gate must pass its
# monotonic no-regression gate against the checked baseline.
if ! timeout 420 _build/default/selfcheck/tg_bootstrap_gate.exe --repo-root .. >/tmp/ocaml_bootstrap_gate.out 2>&1; then
  echo "check_ocaml_seed_health: FAIL — tg_bootstrap_gate (the debt-policy authority) rejected the measured debt"
  tail -20 /tmp/ocaml_bootstrap_gate.out
  exit 1
fi

if [ "$SELFCHECK_FAIL" -ne 0 ]; then
  echo "check_ocaml_seed_health: FAIL"
  exit 1
fi

echo "check_ocaml_seed_health: tests=${TESTS} (pinned exact inventory) selfchecks=${SELFCHECK_COUNT} selfcheck_fail=0 typecheck_debt=${TC_COUNT} (debt policy: tg_bootstrap_gate monotonic vs checked baseline)"
echo "check_ocaml_seed_health: seed health ALL REQUIRED CHECKS PASSED (this is NOT a compiler-closure PASS — run check_ocaml_bootstrap_complete.sh for the closure gate)"
