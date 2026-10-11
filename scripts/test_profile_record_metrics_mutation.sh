#!/usr/bin/env bash
#
# scripts/test_profile_record_metrics_mutation.sh — mutation suite for the
# raw-log parser `scripts/profile_record_metrics.sh` (the layer that turns a
# profile log into the metric blocks the cold/warm repin validator trusts).
#
# Self-contained: synthesizes logs only, no compiler, no VM, no network.
# Every case asserts EXACT recorder fields; a case that merely "does not
# crash" is not a pass.
#
# Usage: bash scripts/test_profile_record_metrics_mutation.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
RECORDER="$ROOT/scripts/profile_record_metrics.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/tg-prof-mut.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
declare -a FAILED_CASES=()

note() { printf '  %s\n' "$*"; }

# rec <log> — run the recorder once per log (cached in $TMP/<log>.out)
rec() {
  local log="$1" out="$TMP/$1.out"
  if [ ! -f "$out" ]; then
    bash "$RECORDER" "$TMP/$1.log" mutation >"$out" 2>&1 || true
  fi
  echo "$out"
}

# expect_line <case> <log> <exact line>
expect_line() {
  local case_name="$1" log="$2" line="$3" out
  out="$(rec "$log")"
  if grep -qxF "$line" "$out"; then
    note "OK   $case_name: $line"
  else
    note "FAIL $case_name: missing '$line'"
    printf '       got:\n'
    grep -E '^(STATUS|SELFCHECK_RESULT|RUN_OUTCOME|VM_[AB]_)' "$out" | sed 's/^/         /'
    FAIL=$((FAIL + 1)); FAILED_CASES+=("$case_name")
  fi
}

# expect_no_line <case> <log> <banned pattern>
expect_no_match() {
  local case_name="$1" log="$2" pattern="$3" out
  out="$(rec "$log")"
  if grep -qE "$pattern" "$out"; then
    note "FAIL $case_name: banned pattern '$pattern' present"
    grep -E "$pattern" "$out" | sed 's/^/         /'
    FAIL=$((FAIL + 1)); FAILED_CASES+=("$case_name")
  else
    note "OK   $case_name: '$pattern' absent"
  fi
}

mark() { PASS=$((PASS + 1)); }

# ─────────────────────────────────────────────────────────────────────────
# 1. VM A then VM B: exact summary wins over beacons; no counter bleed.
# ─────────────────────────────────────────────────────────────────────────
cat >"$TMP/bleed.log" <<'EOF'
BOOTSTRAP COMPLETENESS GATE (tg_bootstrap_gate)
[5/10] VM A corpus compile
VM BEACON steps=100000000 host=1 copies=11 pushes=12 push_copies=13 set_copies=14 map_scans=15 set_scans=16 mark_calls=17 mark_nodes=18 mark_cleared=19 dt=1.0s regions=1 live_mb=1 rss_mb=1 reg_live=1 reg_bytes=1.0MB pool_mb=0.0 cap_live=0 frames=1
VM STEPS: 180000000 (limit 30000000000), host calls: 2 (limit 5000000000), copies: 21, pushes: 22, push copies: 23, set copies: 24, map replace scans: 25, set replace scans: 26, mark calls: 27, mark nodes: 28, mark cleared: 29
[11/11] self-host preflight VM run
VM BEACON steps=50000000 host=3 copies=2 pushes=3 push_copies=4 set_copies=5 map_scans=6 set_scans=7 mark_calls=8 mark_nodes=9 mark_cleared=10 dt=1.0s regions=1 live_mb=1 rss_mb=1 reg_live=1 reg_bytes=1.0MB pool_mb=0.0 cap_live=0 frames=1
VM STEPS: 200000000 (limit 30000000000), host calls: 4 (limit 5000000000), copies: 51, pushes: 52, push copies: 53, set copies: 54, map replace scans: 55, set replace scans: 56, mark calls: 57, mark nodes: 58, mark cleared: 59
BOOTSTRAP GATE: PASS — full closure through every stage
  SELF-HOST PREFLIGHT: PASS — kernel check of tg_compiler/bootstrap_main.tg over the exact manifest closure
typecheck: 0 errors
RUN_EXIT=0
EOF
for check in "VM_A_FINAL_STEPS=180000000" "VM_B_FINAL_STEPS=200000000" \
             "VM_A_COPIES=21" "VM_B_COPIES=51" "VM_A_MAP_SCANS=25" "VM_B_MAP_SCANS=55" \
             "VM_A_SET_COPIES=24" "VM_B_SET_COPIES=54" "STATUS=COMPLETED" \
             "SELFCHECK_RESULT=PASS" "RUN_OUTCOME=PASS"; do
  expect_line "bleed/final-wins+no-bleed" bleed "$check"
done
mark

# ─────────────────────────────────────────────────────────────────────────
# 2. Trap: step limit → TRAPPED_STEPS, never PASS.
# ─────────────────────────────────────────────────────────────────────────
cat >"$TMP/trap.log" <<'EOF'
BOOTSTRAP COMPLETENESS GATE (tg_bootstrap_gate)
[11/11] self-host preflight VM run
VM BEACON steps=100000000 host=1 copies=1 pushes=1 push_copies=1 set_copies=1 map_scans=1 set_scans=1 mark_calls=1 mark_nodes=1 mark_cleared=1 dt=1.0s regions=1 live_mb=1 rss_mb=1 reg_live=1 reg_bytes=1.0MB pool_mb=0.0 cap_live=0 frames=1
TRAPPED: vm: step limit exceeded
RUN_EXIT=1
EOF
expect_line "trap" trap "STATUS=TRAPPED_STEPS"
expect_line "trap" trap "RUN_OUTCOME=FAIL"
mark

# ─────────────────────────────────────────────────────────────────────────
# 3. Explicit-exit telemetry path (full per-VM counters) → COMPLETED.
# ─────────────────────────────────────────────────────────────────────────
cat >"$TMP/exit_path.log" <<'EOF'
TG SELF-HOST PREFLIGHT (kernel in the seed VM checks tg_compiler/bootstrap_main.tg)
VM STEPS: 4000000000 (limit 30000000000), host calls: 9 (limit 5000000000), copies: 91, pushes: 92, push copies: 93, set copies: 94, map replace scans: 95, set replace scans: 96, mark calls: 97, mark nodes: 98, mark cleared: 99
TANGERINE_SELFCHECK_PASS name=tg_bootstrap_selfcheck version=1
RUN_EXIT=0
EOF
expect_line "exit-path" exit_path "VM_B_FINAL_STEPS=4000000000"
expect_line "exit-path" exit_path "VM_B_COPIES=91"
expect_line "exit-path" exit_path "STATUS=COMPLETED"
expect_line "exit-path" exit_path "SELFCHECK_RESULT=PASS"
mark

# ─────────────────────────────────────────────────────────────────────────
# 4. Zero-beacon short VM: the exact final summary alone must be enough
#    (previously the churn fields required a beacon and read UNKNOWN).
# ─────────────────────────────────────────────────────────────────────────
cat >"$TMP/zero_beacon.log" <<'EOF'
TG SELF-HOST PREFLIGHT (kernel in the seed VM checks tg_compiler/bootstrap_main.tg)
VM STEPS: 7777 (limit 30000000000), host calls: 1 (limit 5000000000), copies: 7, pushes: 8, push copies: 9, set copies: 10, map replace scans: 11, set replace scans: 12, mark calls: 13, mark nodes: 14, mark cleared: 15
TANGERINE_SELFCHECK_PASS name=tg_bootstrap_selfcheck version=1
RUN_EXIT=0
EOF
expect_line "zero-beacon" zero_beacon "VM_B_COPIES=7"
expect_line "zero-beacon" zero_beacon "VM_B_MAP_SCANS=11"
expect_line "zero-beacon" zero_beacon "VM_B_MARK_NODES=14"
mark

# ─────────────────────────────────────────────────────────────────────────
# 5. Truncated final line / no summary and no RUN_EXIT → INCOMPLETE.
# ─────────────────────────────────────────────────────────────────────────
cat >"$TMP/truncated.log" <<'EOF'
BOOTSTRAP COMPLETENESS GATE (tg_bootstrap_gate)
[11/11] self-host preflight VM run
VM BEACON steps=100000000 host=1 copies=1 pushes=1 push_copies=1 set_copies=1 map_scans=1 set_scans=1 mark_calls=1 mark_nodes=1 mark_cleared=1 dt=1.0s regions=1 live_mb=1 rss_mb=1 reg_live=1 reg_bytes=1.0MB pool_mb=0.0 cap_live=0 frames=1
EOF
expect_line "truncated" truncated "STATUS=INCOMPLETE"
mark

# ─────────────────────────────────────────────────────────────────────────
# 6. Duplicated standalone sentinels → FAIL (exactly one required).
# ─────────────────────────────────────────────────────────────────────────
cat >"$TMP/double_sentinel.log" <<'EOF'
TG SELF-HOST PREFLIGHT (kernel in the seed VM checks tg_compiler/bootstrap_main.tg)
VM STEPS: 100 (limit 30000000000), host calls: 1 (limit 5000000000), copies: 1, pushes: 1, push copies: 1, set copies: 1, map replace scans: 1, set replace scans: 1, mark calls: 1, mark nodes: 1, mark cleared: 1
TANGERINE_SELFCHECK_PASS name=tg_bootstrap_selfcheck version=1
TANGERINE_SELFCHECK_PASS name=tg_bootstrap_selfcheck version=1
RUN_EXIT=0
EOF
expect_line "double-sentinel" double_sentinel "SELFCHECK_RESULT=FAIL"
mark

# ─────────────────────────────────────────────────────────────────────────
# 7. Missing RUN_EXIT: facts complete but no exit line → outcome FAIL.
# ─────────────────────────────────────────────────────────────────────────
cat >"$TMP/missing_exit.log" <<'EOF'
BOOTSTRAP COMPLETENESS GATE (tg_bootstrap_gate)
[11/11] self-host preflight VM run
VM STEPS: 100 (limit 30000000000), host calls: 1 (limit 5000000000), copies: 1, pushes: 1, push copies: 1, set copies: 1, map replace scans: 1, set replace scans: 1, mark calls: 1, mark nodes: 1, mark cleared: 1
BOOTSTRAP GATE: PASS — full closure through every stage
  SELF-HOST PREFLIGHT: PASS — kernel check of tg_compiler/bootstrap_main.tg over the exact manifest closure
typecheck: 0 errors
EOF
expect_line "missing-exit" missing_exit "RUN_OUTCOME=FAIL"
mark

# ─────────────────────────────────────────────────────────────────────────
# 8. Fake PASS phrase inside an error message must NOT count.
# ─────────────────────────────────────────────────────────────────────────
cat >"$TMP/fake_pass.log" <<'EOF'
BOOTSTRAP COMPLETENESS GATE (tg_bootstrap_gate)
[11/11] self-host preflight VM run
VM STEPS: 100 (limit 30000000000), host calls: 1 (limit 5000000000), copies: 1, pushes: 1, push copies: 1, set copies: 1, map replace scans: 1, set replace scans: 1, mark calls: 1, mark nodes: 1, mark cleared: 1
BOOTSTRAP GATE: PASS — full closure through every stage
error: expected `SELF-HOST PREFLIGHT: PASS` but the run trapped
typecheck: 0 errors
RUN_EXIT=0
EOF
expect_line "fake-pass" fake_pass "SELFCHECK_RESULT=FAIL"
mark

# ─────────────────────────────────────────────────────────────────────────
# 9. Failure evidence AFTER an apparent success line → FAIL.
# ─────────────────────────────────────────────────────────────────────────
cat >"$TMP/failure_after.log" <<'EOF'
BOOTSTRAP COMPLETENESS GATE (tg_bootstrap_gate)
[11/11] self-host preflight VM run
VM STEPS: 100 (limit 30000000000), host calls: 1 (limit 5000000000), copies: 1, pushes: 1, push copies: 1, set copies: 1, map replace scans: 1, set replace scans: 1, mark calls: 1, mark nodes: 1, mark cleared: 1
BOOTSTRAP GATE: PASS — full closure through every stage
  SELF-HOST PREFLIGHT: PASS — kernel check of tg_compiler/bootstrap_main.tg over the exact manifest closure
typecheck: 0 errors
SELFCHECK NOT RUN: tg_kernel_runtime_parity (harness aborted after the success line)
RUN_EXIT=0
EOF
expect_line "failure-after-success" failure_after "SELFCHECK_RESULT=FAIL"
mark

# ─────────────────────────────────────────────────────────────────────────
# 10. The recorder NEVER prints an authorization sentinel.
# ─────────────────────────────────────────────────────────────────────────
expect_no_match "no-authorization-sentinel" bleed "BOOTSTRAP COMPLETE: PASS"
mark

echo ""
echo "profile_record_metrics mutation suite: $PASS case groups passed, $FAIL failed"
if [ "$FAIL" -ne 0 ]; then
  echo "failed: ${FAILED_CASES[*]}" >&2
  exit 1
fi
echo "profile_record_metrics mutation suite: ALL PASS"
exit 0
