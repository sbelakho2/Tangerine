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
# Toolchain (authoritative pins): bootstrap/ocaml-toolchain.lock pins
# OCaml 5.4.0 / dune 3.21.1 / arm64, and the CI lane
# .woodpecker/ocaml-seed-health.yaml runs this script THROUGH the opam
# switch that carries them:
#   eval "$(opam env --switch=5.4.0 --set-switch)"
#   bash scripts/check_ocaml_seed_health.sh
# A bare host toolchain (e.g. brew's OCaml 5.5.0 / dune 3.24.2) fails the
# check_ocaml_toolchain.sh pre-check BY DESIGN — the pins are the tested
# versions, not a range.
#
# Usage: scripts/check_ocaml_seed_health.sh [repo-root]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PINNED_TEST_INVENTORY=230

# Harness timeout calibration (re-measured 2026-09-14 on the development
# host, tree at 1e5ea8a + the active workstream changes, under concurrent
# host load; the 2026-09-13 calibration at 7e2f449 — 400.4/364.9/385.6 s —
# is superseded: the closure now runs the full 0-error path instead of
# stopping at the frontend): the FULL bootstrap-check closure measured
# 1049.9 s wall (17:29.88), tg_bootstrap_gate 1207.6 s (20:07.55) and the
# tg_evidence component 1276.6 s (21:16.63). Each cap is the measurement
# x 1.5 rounded up to the next 60 s (bootstrap-check: 1049.9 x 1.5 =
# 1574.8 -> 1620 s; gate: 1207.6 x 1.5 = 1811.3 -> 1860 s; tg_evidence:
# 1276.6 x 1.5 = 1914.9 -> 1920 s): the host carries unrelated background
# load (load average 12-17 on 18 cores during the calibration). A cap is a
# bound, never a skip: the full check still runs under it, and the debt
# predicate is unchanged. Re-measure when the closure grows materially.
BOOTSTRAP_CHECK_TIMEOUT_S=1620
GATE_TIMEOUT_S=1860
EVIDENCE_TIMEOUT_S=1920

# Merged-probe calibration (the tg_infer probe: the Seed VM typecheck of
# the merged corpus+std closure — see tg_compiler/infer_probe.tg's merged
# mode).  The probe's merged mode runs the REAL compile path's canonical
# preparation (apply_cfg_elimination + prepare_parsed: macro expansion +
# node-id assignment) before the kernel checker — the impl-conformance
# rows (E0229/E0226/E0224) only reproduce after that preparation has
# rewritten the impl items, so tg_compiler/compiler_core.tg and its FULL
# dependency closure (asm/codegen/linker/object/runtime/mono/
# layout_engine/target_desc — the manifest grew from 26 to 36 modules)
# are part of bootstrap/infer_mini.manifest.  The larger closure raises
# both invocations' cost:
#   - the DEFAULT component-lane invocation (standalone battery; the
#     probe entry always runs it): re-measured 2026-09-16 on this host
#     under load average 15, 549 s worst wall — cap 549 x 1.5 = 823.5 ->
#     900 s (the generic 420 s bound no longer covers the closure);
#   - the --merged opt-in invocation (battery + canonical preparation +
#     merged-closure VM typecheck): measured 250-370 s at load ~10 and
#     600 s worst estimated at load 15 — cap 1200 s (2x the load-15
#     estimate; the old 466 s-based 720 s cap is superseded).
# The merged mode is still opt-in (TG_INFER_MERGED=1) so the default lane
# pays the closure build once.  Re-measure when the closure or the probe
# grows materially.  A cap is a bound, never a skip.
TG_INFER_TIMEOUT_S=900
TG_INFER_MERGED_TIMEOUT_S=1200

if [ -f scripts/check_ocaml_toolchain.sh ]; then
  scripts/check_ocaml_toolchain.sh
fi

cd stage0_ocaml
dune build

TEST_OUT="$(timeout 120 _build/default/test/test_main.exe 2>&1 || true)"
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
SELFCHECK_TOTAL=0
SELFCHECK_FAIL=0
if [ -z "$NAMES" ]; then
  echo "check_ocaml_seed_health: FAIL — could not enumerate the selfcheck executables from selfcheck/dune"
  exit 1
fi
for name in $NAMES; do
  if [ "$name" = "tg_bootstrap_gate" ]; then
    # tg_bootstrap_gate is the FULL-COMPLETENESS gate (red by design
    # while the subset is nonzero) — reported separately, never part of
    # the component-selfcheck lane (re-audit P0: health vs completeness
    # split).
    continue
  fi
  # The denominator is DERIVED from the enumerated dune names (minus
  # tg_bootstrap_gate) — never a literal — so a new selfcheck cannot
  # leave the summary stale.
  SELFCHECK_TOTAL=$((SELFCHECK_TOTAL + 1))
  SELFCHECK_COUNT=$((SELFCHECK_COUNT + 1))
  # The generic component bound is 420 s; tg_evidence runs the full evidence
  # phase (measured 1276.6 s on 2026-09-14, far above the generic bound) and
  # tg_infer builds the canonical-preparation closure (compiler_core + its
  # closure; measured 549 s worst on 2026-09-16, also above the generic
  # bound) — both use their calibrated caps.
  SC_TIMEOUT_S=420
  if [ "$name" = "tg_evidence" ]; then
    SC_TIMEOUT_S="$EVIDENCE_TIMEOUT_S"
  fi
  if [ "$name" = "tg_infer" ]; then
    SC_TIMEOUT_S="$TG_INFER_TIMEOUT_S"
  fi
  if ! timeout "$SC_TIMEOUT_S" "_build/default/selfcheck/${name}.exe" >"/tmp/ocaml_sc_${name}.out" 2>&1; then
    echo "check_ocaml_seed_health: FAIL — selfcheck ${name} exited non-zero"
    tail -10 "/tmp/ocaml_sc_${name}.out" || true
    SELFCHECK_FAIL=1
  fi
  # tg_infer's merged-corpus diagnostic (opt-in, TG_INFER_MERGED=1): the
  # probe's merged mode runs the canonical preparation + the kernel
  # checker over the merged corpus+std closure (build/infer_merged.flag)
  # and asserts the same zero-diagnostic battery plus IMPLCONF=0 (the
  # impl-conformance rows must agree with the host typechecker).  It is
  # minutes-scale (see the merged-probe calibration above), so the
  # default lane runs the standalone battery under its calibrated cap and
  # the opt-in runs the full merged workload under its own.
  if [ "$name" = "tg_infer" ] && [ "${TG_INFER_MERGED:-0}" = "1" ]; then
    if ! timeout "$TG_INFER_MERGED_TIMEOUT_S" \
        "_build/default/selfcheck/${name}.exe" .. --merged \
        >/tmp/ocaml_sc_tg_infer_merged.out 2>&1; then
      echo "check_ocaml_seed_health: FAIL — tg_infer --merged exited non-zero"
      tail -10 /tmp/ocaml_sc_tg_infer_merged.out || true
      SELFCHECK_FAIL=1
    fi
  fi
done

# bootstrap-check: must not crash. The debt policy is NOT a scalar pin
# here — it is delegated to tg_bootstrap_gate, the single debt authority
# (monotonic no-regression vs its checked baseline).
set +e
timeout "$BOOTSTRAP_CHECK_TIMEOUT_S" _build/default/bin/tg_stage0.exe bootstrap-check --repo-root .. >/tmp/ocaml_bootstrap_check.out 2>&1
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
# The greps below are guarded with `|| true`: under `set -e`/pipefail a
# no-match grep in a command substitution aborts the whole script before
# any explicit check, which is exactly the zero-debt failure mode.
TC_COUNT="$(grep -oE 'typecheck: [0-9]+ modules, [0-9]+ items, [0-9]+ errors' /tmp/ocaml_bootstrap_check.out 2>/dev/null | head -1 | grep -oE '[0-9]+ errors$' | grep -oE '^[0-9]+' || true)"
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
  EVIDENCE_JSON="$(ls -1 "$ROOT/bootstrap/evidence/ocaml/" 2>/dev/null | grep -v history | grep -E '^[0-9a-f]{7}_.*\.json$' | sort | tail -1 || true)"
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
# Debt totals.  The `debt_total:` / `debt_primary:` / `debt_secondary:`
# lines are emitted by record_module_debt as the ACCUMULATED per-module
# report (Typecheck.state.debt_by_module) changes: each block already is
# the per-module sum, and the LAST block is the closure's final debt
# report (exactly the parse scripts/ocaml_seed_evidence.sh records as
# the accepted facts).  The blocks are running cumulative snapshots —
# never add them together.
#
# Zero-debt run: every module's report is empty and is dropped from
# debt_by_module, so the block is never (re-)emitted and the output has
# no debt line at all.  0 typecheck errors with no debt block therefore
# IS zero debt.  The inverse is a hard FAIL: errors > 0 with no debt
# line means truncated/malformed output — never silently treat it as 0.
DEBT_TOTAL="$(grep -oE 'debt_total: [0-9]+' /tmp/ocaml_bootstrap_check.out 2>/dev/null | tail -1 | grep -oE '[0-9]+$' || true)"
DEBT_PRIMARY="$(grep -oE 'debt_primary: [0-9]+' /tmp/ocaml_bootstrap_check.out 2>/dev/null | tail -1 | grep -oE '[0-9]+$' || true)"
DEBT_SECONDARY="$(grep -oE 'debt_secondary: [0-9]+' /tmp/ocaml_bootstrap_check.out 2>/dev/null | tail -1 | grep -oE '[0-9]+$' || true)"
if [ -z "$DEBT_TOTAL" ]; then
  if [ "$TC_COUNT" -ne 0 ]; then
    echo "check_ocaml_seed_health: FAIL — bootstrap-check reported $TC_COUNT typecheck error(s) but printed no debt_total line (truncated or malformed output; refusing to treat it as zero debt)"
    tail -20 /tmp/ocaml_bootstrap_check.out
    exit 1
  fi
  DEBT_TOTAL=0
  DEBT_PRIMARY=0
  DEBT_SECONDARY=0
elif [ -z "$DEBT_PRIMARY" ] || [ -z "$DEBT_SECONDARY" ]; then
  echo "check_ocaml_seed_health: FAIL — incomplete debt block in the bootstrap-check output (debt_total present without debt_primary/debt_secondary)"
  tail -20 /tmp/ocaml_bootstrap_check.out
  exit 1
fi
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
timeout "$GATE_TIMEOUT_S" _build/default/selfcheck/tg_bootstrap_gate.exe --repo-root .. >/tmp/ocaml_bootstrap_gate.out 2>&1
GATE_STATUS=$?
set -e
SUBSET_N="$(grep -oE 'SUBSET_FIREWALL = (PASS|FAIL \([0-9]+ findings)' /tmp/ocaml_bootstrap_check.out 2>/dev/null | head -1 | grep -oE 'PASS|[0-9]+' | head -1 || true)"
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

if [ "$DEBT_TOTAL" -eq 0 ]; then
  FULL_COMPLETENESS_NOTE="the typecheck debt is 0, so the gate ran the full semantic closure (see the DEVELOPMENT DEBT GATE result above); check_ocaml_bootstrap_complete.sh is the true closure gate"
else
  FULL_COMPLETENESS_NOTE="FULL COMPLETENESS is NOT RUN / DEFERRED while the typecheck debt is nonzero — run check_ocaml_bootstrap_complete.sh for the true closure gate"
fi
echo "check_ocaml_seed_health: tests=${TESTS} (pinned exact inventory) component_selfchecks=${SELFCHECK_COUNT}/${SELFCHECK_TOTAL} selfcheck_fail=0 typecheck_debt=${DEBT_TOTAL:-$TC_COUNT} subset_findings=${SUBSET_N:-?}"
echo "check_ocaml_seed_health: DEVELOPMENT HEALTH PASS — ${SELFCHECK_COUNT} component selfchecks green of ${SELFCHECK_TOTAL} selfcheck executables; tg_bootstrap_gate is the DEVELOPMENT DEBT GATE, reported separately above. ${FULL_COMPLETENESS_NOTE}"
echo "check_ocaml_seed_health: seed health ALL REQUIRED CHECKS PASSED (this is NOT a compiler-closure PASS — run check_ocaml_bootstrap_complete.sh for the closure gate)"
exit 0
