#!/usr/bin/env bash
# check_ocaml_seed_health.sh — OCaml-seed DEVELOPMENT-HEALTH gate.
#
# Debt policy (re-audit finding 3; audit P0/P1-1): ONE authority for the
# ACCEPTED baseline — tg_bootstrap_accepted.exe --print-debt-json
# (Bootstrap_accepted: pointer schema + the record's REAL SHA-256 + debt
# schema; fail-closed, override-proof), consumed through the testable
# helper check_ocaml_seed_debt_policy.sh, which enforces the SAME
# three-scalar monotonic no-regression contract as tg_bootstrap_gate
# (total / primary / secondary must not rise; category redistribution is
# diagnostic only). This script pins NO debt scalar of its own.
#   1. the pinned OCaml/Dune toolchain
#   2. dune build (warnings are errors)
#   3. the EXACT unit-test inventory: 230 passed, 0 failed
#      (the committed pre-wave1 inventory was 216; the wave1 tests
#      brought it to 230; the P0 typechecking regressions (pop_scope,
#      zero-argument method tails) brought it to 230 — the pin is the
#      exact CURRENT inventory; ANY change up or down fails)
#   4. the accepted-debt policy regression lane (synthetic secondary-only
#      regression fails; corrupted/malformed pointers and malformed
#      authority output fail closed; the real tree passes)
#   5. EVERY self-check executable enumerated in selfcheck/dune (a new
#      self-check is automatically required; each must exit 0 AND print
#      EXACTLY ONE machine-readable sentinel
#      `TANGERINE_SELFCHECK_PASS name=<name> version=1` — an exit-0
#      executable with no sentinel is rejected by the exact-line
#      verifier, never a loose `grep PASS`.  tg_bootstrap_gate and
#      tg_bootstrap_selfcheck are completeness gates reported separately,
#      not components of this lane.)
#   6. bootstrap-check: must not crash; the measured typecheck count is
#      reported, and the debt policy is enforced against the accepted
#      baseline by the three-scalar helper above; tg_bootstrap_gate (the
#      aggregate gate) is also run and reported separately.
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
# tg_evidence component 1276.6 s (21:16.63).  The zero-debt path also
# runs the self-host preflight in a second VM (audit P0-2), so re-measure
# the gate cap at zero debt before treating a timeout as a stall.  Each
# cap is the measurement
# x 1.5 rounded up to the next 60 s (bootstrap-check: 1049.9 x 1.5 =
# 1574.8 -> 1620 s; gate: 1207.6 x 1.5 = 1811.3 -> 1860 s; tg_evidence:
# 1276.6 x 1.5 = 1914.9 -> 1920 s): the host carries unrelated background
# load (load average 12-17 on 18 cores during the calibration). A cap is a
# bound, never a skip: the full check still runs under it, and the debt
# predicate is unchanged. Re-measure when the closure grows materially.
BOOTSTRAP_CHECK_TIMEOUT_S=1620
# The gate cap was re-measured 2026-09-27 after the post-mono deep-share
# mark fix landed the full closure: 2759.9 s wall (closure front end
# 1419.5 + lower 22.2 + mono 53.7 + reachable-host 0.2 + fold 0.0 + VM
# run 1264.3) -> 4139.9 -> the same 4140 s cap as
# check_ocaml_bootstrap_complete.sh.  The pre-fix 1860 s cap is
# superseded (the frozen tree stalled in the post-mono segment and never
# reached the VM; the cap must cover the run, not the stall).
GATE_TIMEOUT_S=4140
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

# Devirt-probe calibration (the tg_devirt probe: the devirtprobe_mini
# closure carries mir.tg + mono.tg, so its closure front end is larger
# than the identity probe's). Provisional: the lane is currently red on
# the closure's front-end gate (the probe VM has not run yet, so no
# green-path measurement exists); the front-end-only wall measured 429 s
# under concurrent host load (299 s CPU) on 2026-09-22, above the generic
# 420 s bound. Cap 900 s (the same provisional bound as tg_infer's closure
# build); re-measure once the closure is green. A cap is a bound, never a
# skip.
TG_DEVIRT_TIMEOUT_S=900

# Kernel-native link/codesign lane calibration (the tg_linkprobe probe:
# the linkprobe_mini closure is the FULL kernel closure plus the probe).
# Measured on the Darwin/arm64 host:
#   - cold (program cache absent, closure front end + mono + linkobj VM):
#     390.3 s at light load (~11.6 min under concurrent host load was the
#     earlier calibration);
#   - warm (prepared-VM program cache hit, linkobj mode): ~0.5 s;
#   - --mode full (the REAL kernel compile entry): the emitted ~914 KiB
#     executable is ad-hoc codesigned by the kernel, run natively by the
#     harness, and must exit 42.  Warm (prepared-VM cache hit): 484.0 s
#     (8.1 min) at load ~8.4; the cache-miss run measured 1121.8 s
#     (18.7 min) at load ~13.  The mem_free small-block clobber (x0, the
#     user block pointer, was overwritten with the class index before
#     _tg_alloc_lock, so the free-list link store went through x0 = NULL)
#     is fixed — base now lives in the callee-saved x21 across the lock
#     with an FP/LR prologue on the AArch64 path — and the native RUN
#     gate is green.  The CI lane
#     (.woodpecker/ocaml-seed-health.yaml's kernel-native-link-lane) runs
#     --mode full by default; TG_LINKPROBE_FULL=0 only skips it.
# Cap 1800 s (1121.8 x 1.5 = 1682.7 rounded up to the next 60 s; also the
# bound the CI step uses); a cap is a bound, never a skip.
TG_LINKPROBE_TIMEOUT_S=1800

# Resolution-parity lane calibration (the tg_resolution_parity probe: the
# resolution_parity_mini closure is the kernel front end + id/type modules
# and the probe parses+merges+resolves the FULL bootstrap closure). Measured
# 2026-09-28 on the development host at light load: 612.2 s wall (10:12.22)
# for the green path. Cap 960 s (612.2 x 1.5 = 918.3 rounded up to the next
# 60 s); a cap is a bound, never a skip. Re-measure when the front end
# grows materially.
RESOLUTION_PARITY_TIMEOUT_S=960

if [ -f scripts/check_ocaml_toolchain.sh ]; then
  scripts/check_ocaml_toolchain.sh
fi

# Repository-artifact hygiene (audit P0-1): cheap, index-only, fail-closed
# BEFORE any build — a tracked native artifact is never accepted, and a
# bootstrap gate that dropped one at the repository root must go red here.
if [ -x scripts/check_repo_artifact_hygiene.sh ]; then
  if ! scripts/check_repo_artifact_hygiene.sh; then
    echo "check_ocaml_seed_health: FAIL — repository artifact hygiene"
    exit 1
  fi
fi

cd stage0_ocaml
dune build

# The unit-test gate is exit status AND evidence: a pathological binary
# that prints the summary and hangs (killed by timeout) or exits nonzero
# must never be accepted on its text alone (the timeout's `|| true` made
# the text the only signal).  Require rc == 0 and EXACTLY ONE exact-count
# summary line.
set +e
TEST_OUT="$(timeout 120 _build/default/test/test_main.exe 2>&1)"
TEST_RC=$?
set -e
if [ "$TEST_RC" -ne 0 ]; then
  echo "check_ocaml_seed_health: FAIL — unit test suite exited non-zero (rc=$TEST_RC):"
  echo "$TEST_OUT" | tail -5
  exit 1
fi
TESTS="$(grep -oE '[0-9]+ passed, 0 failed' <<<"$TEST_OUT" | head -1)"
if [ "$(grep -Fxc "${PINNED_TEST_INVENTORY} passed, 0 failed" <<<"$TEST_OUT")" != "1" ]; then
  echo "check_ocaml_seed_health: FAIL — unit test suite must print exactly one exact summary line '${PINNED_TEST_INVENTORY} passed, 0 failed'; got '$TESTS'"
  echo "$TEST_OUT" | tail -5
  exit 1
fi

# Success-evidence verifier meta-test (audit P0-4): proves in
# milliseconds that a silent exit-0 executable is rejected and the exact
# sentinel is accepted, so the marker gate can never be ceremonial.
if ! "$ROOT/scripts/test_selfcheck_sentinel.sh"; then
  echo "check_ocaml_seed_health: FAIL — selfcheck sentinel verifier meta-test"
  exit 1
fi
if ! "$ROOT/scripts/check_selfcheck_source_sentinels.sh"; then
  echo "check_ocaml_seed_health: FAIL — selfcheck sentinel source invariants"
  exit 1
fi

# Regression lane for the accepted-debt authority + three-scalar policy
# (audit P0/P1-1): synthetic roots prove a secondary-only regression
# fails, corrupted/malformed pointers and malformed authority output fail
# CLOSED, and the real tree passes.  It exercises the SAME helper the
# debt policy below invokes, so the bypass that skipped the comparison
# cannot recur.
if ! "$ROOT/scripts/test_ocaml_seed_debt_policy.sh"; then
  echo "check_ocaml_seed_health: FAIL — accepted-debt policy regression lane"
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
  if [ "$name" = "tg_bootstrap_gate" ] || [ "$name" = "tg_bootstrap_selfcheck" ]; then
    # tg_bootstrap_gate is the FULL-COMPLETENESS gate (red by design
    # while the subset is nonzero) and tg_bootstrap_selfcheck is the
    # self-host preflight that can only run once the closure typechecks
    # clean — both are reported separately, never part of the
    # component-selfcheck lane (re-audit P0: health vs completeness
    # split; the complete gate runs them).
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
  if [ "$name" = "tg_devirt" ]; then
    SC_TIMEOUT_S="$TG_DEVIRT_TIMEOUT_S"
  fi
  if [ "$name" = "tg_linkprobe" ]; then
    SC_TIMEOUT_S="$TG_LINKPROBE_TIMEOUT_S"
  fi
  if [ "$name" = "tg_resolution_parity" ]; then
    SC_TIMEOUT_S="$RESOLUTION_PARITY_TIMEOUT_S"
  fi
  if ! timeout "$SC_TIMEOUT_S" "_build/default/selfcheck/${name}.exe" >"/tmp/ocaml_sc_${name}.out" 2>&1; then
    echo "check_ocaml_seed_health: FAIL — selfcheck ${name} exited non-zero"
    tail -10 "/tmp/ocaml_sc_${name}.out" || true
    SELFCHECK_FAIL=1
  fi
  # Success evidence (audit P0-4): exit 0 alone is not a pass — the
  # executable must print EXACTLY ONE machine-readable sentinel
  # (TANGERINE_SELFCHECK_PASS name=<name> version=1).  A broken
  # selfcheck that exits early with 0 and prints nothing is rejected by
  # the exact-line verifier (never a loose `grep PASS`: error text can
  # contain the word).  scripts/test_selfcheck_sentinel.sh proves the
  # verifier's reject/pass behaviour.
  if ! "$ROOT/scripts/check_selfcheck_sentinel.sh" "$name" "/tmp/ocaml_sc_${name}.out"; then
    echo "check_ocaml_seed_health: FAIL — selfcheck ${name} exited 0 without its success sentinel"
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
timeout "$BOOTSTRAP_CHECK_TIMEOUT_S" _build/default/bin/tg_stage0.exe bootstrap-check --repo-root .. --target "${TG_BOOTSTRAP_TARGET:-aarch64-apple-darwin}" >/tmp/ocaml_bootstrap_check.out 2>&1
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

# Debt policy (the audit's P1 directive; re-audit finding 3: ONE
# authority): MONOTONIC no-regression of ALL THREE scalars against the
# single accepted baseline —
#   head.total     <= accepted.total
#   head.primary   <= accepted.primary
#   head.secondary <= accepted.secondary
# (the same three scalars tg_bootstrap_gate enforces; a secondary-only
# regression fails even when total and primary are flat).  The accepted
# facts are resolved ONLY by the authority
# stage0_ocaml/selfcheck/tg_bootstrap_accepted.exe --print-debt-json
# (Bootstrap_accepted: pointer schema + the record's REAL SHA-256 + debt
# schema total = primary + secondary), never parsed here and never
# substituted by a historical evidence record.  The comparison itself is
# the testable helper scripts/check_ocaml_seed_debt_policy.sh — the same
# helper the regression lane scripts/test_ocaml_seed_debt_policy.sh
# exercises against synthetic roots (a secondary-only regression and
# corrupted pointers must fail; the real tree must pass).  Fail-closed:
# a missing binary, a non-zero authority exit or a missing/malformed
# authority line fails this script; there is no silent skip.
#
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
if ! "$ROOT/scripts/check_ocaml_seed_debt_policy.sh" \
  --repo-root "$ROOT" \
  --current-total "$DEBT_TOTAL" \
  --current-primary "$DEBT_PRIMARY" \
  --current-secondary "$DEBT_SECONDARY"; then
  echo "check_ocaml_seed_health: FAIL — accepted-debt monotonic policy failed (authority or three-scalar comparison; see above)"
  exit 1
fi

# FULL-COMPLETENESS gate: tg_bootstrap_gate — reported separately,
# informational only; red by design while the subset is nonzero.
set +e
timeout "$GATE_TIMEOUT_S" _build/default/selfcheck/tg_bootstrap_gate.exe --repo-root .. --target "${TG_BOOTSTRAP_TARGET:-aarch64-apple-darwin}" >/tmp/ocaml_bootstrap_gate.out 2>&1
GATE_STATUS=$?
set -e
SUBSET_N="$(grep -oE 'SUBSET_FIREWALL = (PASS|FAIL \([0-9]+ findings)' /tmp/ocaml_bootstrap_check.out 2>/dev/null | head -1 | grep -oE 'PASS|[0-9]+' | head -1 || true)"
if [ "$GATE_STATUS" -eq 0 ]; then
  echo "check_ocaml_seed_health: DEVELOPMENT DEBT GATE: PASS (no regression vs the checked baseline)"
  echo "DEBT-GATE-PASS (FULL COMPLETENESS: NOT RUN / DEFERRED)" > /tmp/ocaml_full_completeness_verdict.txt
else
  echo "check_ocaml_seed_health: DEVELOPMENT DEBT GATE: RED (gate exit $GATE_STATUS)"
  echo "DEBT-GATE-RED" > /tmp/ocaml_full_completeness_verdict.txt
  # The subtle health/completeness agreement rule: while the typecheck
  # debt is nonzero the gate may be informational, but AT ZERO DEBT the
  # gate's full closure (including the self-host preflight) is mandatory
  # — a red completeness gate is a red health result, never a green
  # dashboard next to an unclosed closure.
  if [ "$DEBT_TOTAL" -eq 0 ]; then
    echo "check_ocaml_seed_health: FAIL — typecheck debt is 0 but tg_bootstrap_gate is red (full closure / self-host preflight failed); health cannot pass while completeness is red at zero debt"
    tail -30 /tmp/ocaml_bootstrap_gate.out
    exit 1
  fi
  echo "check_ocaml_seed_health: note: the gate is informational ONLY because the typecheck debt is nonzero (${DEBT_TOTAL})"
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
