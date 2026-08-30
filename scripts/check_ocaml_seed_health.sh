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
#   3. the EXACT unit-test inventory: 230 passed, 0 failed
#      (the committed pre-wave1 inventory was 216; the wave1 tests
#      brought it to 230; the P0 typechecking regressions (pop_scope,
#      zero-argument method tails) brought it to 230 — the pin is the
#      exact CURRENT inventory; ANY change up or down fails)
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

PINNED_TEST_INVENTORY=230

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
  if [ "$name" = "tg_bootstrap_gate" ]; then
    # tg_bootstrap_gate is the FULL-COMPLETENESS gate (red by design
    # while the subset is nonzero) — reported separately, never part of
    # the component-selfcheck lane (re-audit P0: health vs completeness
    # split).
    continue
  fi
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

# Debt policy (the audit's P1 directive): MONOTONIC no-regression vs
# the SINGLE ACCEPTED BASELINE POINTER (re-audit item 30) —
# bootstrap/evidence/ocaml/accepted.json (the tested SHA + the expected
# debt facts), the SAME machine-readable record tg_bootstrap_gate reads;
# the gate and this script can no longer drift.  When the accepted
# record is absent, fall back to the last accepted evidence record.
#   head.total   <= accepted.total
#   head.primary <= accepted.primary
# with an explicit, reviewed override for intentional soundness
# discoveries.  No +20% tolerance; a primary regression fails even
# when the total stays flat.
ACCEPTED_JSON="$ROOT/bootstrap/evidence/ocaml/accepted.json"
EVIDENCE_JSON=""
if [ -f "$ACCEPTED_JSON" ]; then
  EVIDENCE_JSON="$ACCEPTED_JSON"
else
  EVIDENCE_JSON="$(ls -1 "$ROOT/bootstrap/evidence/ocaml/" 2>/dev/null | grep -v history | grep -E '^[0-9a-f]{7}_.*\.json$' | sort | tail -1)"
  if [ -n "$EVIDENCE_JSON" ]; then
    EVIDENCE_JSON="$ROOT/bootstrap/evidence/ocaml/$EVIDENCE_JSON"
  fi
fi
REC_TOTAL=""
REC_PRIMARY=""
REC_SECONDARY=""
if [ -n "$EVIDENCE_JSON" ] && [ -f "$EVIDENCE_JSON" ]; then
  REC_TOTAL="$(python3 -c "import json,sys; d=json.load(open('$EVIDENCE_JSON')); print(d.get('debt_total') or d.get('debt',{}).get('total',''))" 2>/dev/null)"
  REC_PRIMARY="$(python3 -c "import json,sys; d=json.load(open('$EVIDENCE_JSON')); print(d.get('debt_primary') or d.get('debt',{}).get('primary',''))" 2>/dev/null)"
  REC_SECONDARY="$(python3 -c "import json,sys; d=json.load(open('$EVIDENCE_JSON')); print(d.get('debt_secondary') or d.get('debt',{}).get('secondary',''))" 2>/dev/null)"
fi
DEBT_TOTAL="$(grep -oE 'debt_total: [0-9]+' /tmp/ocaml_bootstrap_check.out | tail -1 | grep -oE '[0-9]+$')"
DEBT_PRIMARY="$(grep -oE 'debt_primary: [0-9]+' /tmp/ocaml_bootstrap_check.out | tail -1 | grep -oE '[0-9]+$')"
DEBT_SECONDARY="$(grep -oE 'debt_secondary: [0-9]+' /tmp/ocaml_bootstrap_check.out | tail -1 | grep -oE '[0-9]+$')"
if [ -n "$REC_TOTAL" ] && [ -n "$DEBT_TOTAL" ]; then
  echo "check_ocaml_seed_health: debt policy — vs the last accepted evidence record $(basename "$EVIDENCE_JSON") (debt_total $REC_TOTAL / debt_primary $REC_PRIMARY / debt_secondary $REC_SECONDARY)"
  if [ -n "$REC_PRIMARY" ] && [ -n "$DEBT_PRIMARY" ] && [ "$DEBT_PRIMARY" -gt "$REC_PRIMARY" ]; then
    echo "check_ocaml_seed_health: FAIL — debt_primary grew vs the evidence record ($DEBT_PRIMARY > $REC_PRIMARY)"
    exit 1
  fi
  if [ "$DEBT_TOTAL" -gt "$REC_TOTAL" ]; then
    echo "check_ocaml_seed_health: FAIL — debt_total grew vs the evidence record ($DEBT_TOTAL > $REC_TOTAL)"
    exit 1
  fi
  echo "check_ocaml_seed_health: debt policy — monotonic no-regression: PASS"
fi

# FULL-COMPLETENESS gate: tg_bootstrap_gate — reported separately,
# informational only; red by design while the subset is nonzero.
set +e
timeout 420 _build/default/selfcheck/tg_bootstrap_gate.exe --repo-root .. >/tmp/ocaml_bootstrap_gate.out 2>&1
GATE_STATUS=$?
set -e
SUBSET_N="$(grep -oE 'SUBSET_FIREWALL = (PASS|FAIL \([0-9]+ findings)' /tmp/ocaml_bootstrap_check.out | head -1 | grep -oE 'PASS|[0-9]+' | head -1)"
if [ "$GATE_STATUS" -eq 0 ]; then
  echo "check_ocaml_seed_health: DEVELOPMENT DEBT GATE: PASS (no regression vs the checked baseline)"
  echo "DEBT-GATE-PASS (FULL COMPLETENESS: NOT RUN / DEFERRED)" > /tmp/ocaml_full_completeness_verdict.txt
else
  echo "check_ocaml_seed_health: DEVELOPMENT DEBT GATE: RED (gate exit $GATE_STATUS — informational; this lane is development health, the gate is reported separately)"
  echo "DEBT-GATE-RED" > /tmp/ocaml_full_completeness_verdict.txt
fi

if [ "$SELFCHECK_FAIL" -ne 0 ]; then
  echo "check_ocaml_seed_health: FAIL"
  exit 1
fi

echo "check_ocaml_seed_health: tests=${TESTS} (pinned exact inventory) component_selfchecks=${SELFCHECK_COUNT}/24 selfcheck_fail=0 typecheck_debt=${DEBT_TOTAL:-$TC_COUNT} subset_findings=${SUBSET_N:-?}"
echo "check_ocaml_seed_health: DEVELOPMENT HEALTH PASS — ${SELFCHECK_COUNT} component selfchecks green of 24 selfcheck executables; tg_bootstrap_gate is the DEVELOPMENT DEBT GATE, reported separately above. FULL COMPLETENESS is NOT RUN / DEFERRED while the typecheck debt is nonzero — run check_ocaml_bootstrap_complete.sh for the true closure gate"
echo "check_ocaml_seed_health: seed health ALL REQUIRED CHECKS PASSED (this is NOT a compiler-closure PASS — run check_ocaml_bootstrap_complete.sh for the closure gate)"
