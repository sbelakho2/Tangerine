#!/usr/bin/env bash
# test_repin_evidence.sh — mutation matrix for the calibration-evidence
# contract of scripts/repin_bootstrap_limits.py.
#
# Builds SYNTHETIC metric blocks (no real profile run) and asserts that
# the repinner's unconditional validation accepts exactly the well-formed
# COMPLETED+PASS pairs and rejects every mutation:
#
#   accept:  standalone COMPLETED+PASS pair
#   accept:  aggregate COMPLETED+PASS pair (AGGREGATE_WALL_S + VM_A/VM_B)
#   reject:  COMPLETED + RUN_OUTCOME=FAIL
#   reject:  COMPLETED + SELFCHECK_RESULT=UNKNOWN
#   reject:  STATUS=TRAPPED_RSS / TRAPPED_STEPS
#   reject:  RUN_TREE_CLEAN=0
#   reject:  FAILURE_FINGERPRINT=HIR_INVALID|...
#   reject:  RUN_EXIT=1 / missing RUN_EXIT
#   reject:  different RUN_SHA / RUN_TARGET / CLOSURE_FINGERPRINT /
#            RUN_GC_POLICY / SEED_SHA256 / MANIFEST_SHA256
#   reject:  mixed LOG_KIND (standalone vs aggregate)
#   reject:  aggregate pair with RUN_OUTCOME=FAIL
#
# Every case runs the repinner in DRY-RUN mode (no files written) and
# asserts the expected accept/reject exit status.  Prints one PASS/FAIL
# line per case and exits nonzero on any unexpected outcome.
#
# Usage: scripts/test_repin_evidence.sh
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPIN="$ROOT/scripts/repin_bootstrap_limits.py"
GATE="$ROOT/scripts/check_ocaml_bootstrap_complete.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "repin-evidence: PASS - $*"; }
bad() {
  echo "repin-evidence: FAIL - $*" >&2
  fail=1
}

set_kv() { # <file> <KEY> <value> (replace KEY= line, or append)
  local file="$1" key="$2" value="$3"
  local tmp="${file}.tmp"
  awk -v k="$key" -v v="$value" '
    BEGIN { done = 0 }
    index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$file" >"$tmp"
  mv "$tmp" "$file"
}

emit_block() { # <path> <standalone|aggregate>
  local path="$1" kind="$2" label
  label="$(basename "$path")"
  cat >"$path" <<EOF
RUN_LABEL=${label}
LOG_KIND=${kind}
PROFILE_SCHEMA=2
PROFILE_DRY_RUN=0
RUN_SHA=1111111111111111111111111111111111111111
RUN_TREE_CLEAN=1
RUN_TARGET=aarch64-apple-darwin
SEED_SHA256=2222222222222222222222222222222222222222222222222222222222222222
MANIFEST_SHA256=3333333333333333333333333333333333333333333333333333333333333333
RUN_GC_POLICY=o=40
CLOSURE_FINGERPRINT=4444444444444444444444444444444444444444444444444444444444444444
RUN_EXIT=0
STATUS=COMPLETED
SELFCHECK_RESULT=PASS
RUN_OUTCOME=PASS
FAILURE_FINGERPRINT=NONE
FIRST_FAILURE_FINGERPRINT=none
BEACON_COUNT=10
LOG_LINES=100
FINAL_STEPS=1000000
FINAL_STEPS_LIMIT=2000000
FINAL_STEPS_SOURCE=vm_summary
PEAK_RSS_MIB=4096
PEAK_LIVE_MB=3000
HOST_CALLS=500000
HOST_CALLS_LIMIT=1000000
HOST_CALLS_SOURCE=vm_summary
ALLOC_BYTES=700000000
WALL_PHASE_SUM_S=100.0
EOF
  if [ "$kind" = "aggregate" ]; then
    cat >>"$path" <<EOF
AGGREGATE_WALL_S=1200
VM_A_BEACONS=100
VM_A_FINAL_STEPS=1000000
VM_A_FINAL_STEPS_LIMIT=120000000000
VM_A_FINAL_STEPS_SOURCE=vm_summary
VM_A_HOST_CALLS=400000
VM_A_HOST_CALLS_LIMIT=5000000000
VM_A_HOST_CALLS_SOURCE=vm_summary
VM_A_ALLOC_BYTES=600000000
VM_A_ALLOC_BYTES_SOURCE=vm_alloc_sites
VM_A_PEAK_RSS_MIB=6000
VM_A_PEAK_LIVE_MB=4000
VM_A_WALL_S=500.0
VM_A_WALL_SOURCE=driver_phase
VM_B_BEACONS=200
VM_B_FINAL_STEPS=2000000
VM_B_FINAL_STEPS_LIMIT=120000000000
VM_B_FINAL_STEPS_SOURCE=vm_summary
VM_B_HOST_CALLS=900000
VM_B_HOST_CALLS_LIMIT=5000000000
VM_B_HOST_CALLS_SOURCE=vm_summary
VM_B_ALLOC_BYTES=700000000
VM_B_ALLOC_BYTES_SOURCE=vm_alloc_sites
VM_B_PEAK_RSS_MIB=7000
VM_B_PEAK_LIVE_MB=5000
VM_B_WALL_S=700.0
VM_B_WALL_SOURCE=driver_phase
VM_B_PREFLIGHT_WALL_S=680.0
VM_B_PREFLIGHT_WALL_SOURCE=gate_phase
EOF
  fi
}

run_case() { # <label> <accept|reject> <cold> <warm>
  local label="$1" expect="$2" cold="$3" warm="$4" rc=0 out="$TMP/out.txt"
  python3 "$REPIN" "$cold" "$warm" >"$out" 2>&1 || rc=$?
  if [ "$expect" = "accept" ]; then
    if [ "$rc" -eq 0 ]; then
      pass "${label}: accepted"
    else
      bad "${label}: expected accept, got rc=${rc}"
      sed -n '1,8p' "$out" >&2
    fi
  else
    if [ "$rc" -ne 0 ]; then
      if ! grep -q 'VALIDATION FAIL' "$out"; then
        bad "${label}: rejected without a VALIDATION FAIL reason"
      else
        pass "${label}: rejected"
      fi
    else
      bad "${label}: expected reject, got accept"
    fi
  fi
}

# ── accepted standalone pair ─────────────────────────────────────────
emit_block "$TMP/cold" standalone
emit_block "$TMP/warm" standalone
set_kv "$TMP/cold" RUN_LABEL cold
set_kv "$TMP/warm" RUN_LABEL warm
set_kv "$TMP/cold" FINAL_STEPS 1000000
set_kv "$TMP/warm" FINAL_STEPS 2000000
run_case "standalone COMPLETED+PASS" accept "$TMP/cold" "$TMP/warm"
if grep -q '^PROPOSED_STEPS_LIMIT=2300000$' "$TMP/out.txt"; then
  pass "standalone margin formula: steps = ceil(2000000*1.15) = 2300000"
else
  bad "standalone margin formula: expected PROPOSED_STEPS_LIMIT=2300000"
fi
if grep -q '^PROPOSED_WALL_TIMEOUT_S=180$' "$TMP/out.txt"; then
  pass "standalone wall margin: ceil(100*1.5/60)*60 = 180"
else
  bad "standalone wall margin: expected PROPOSED_WALL_TIMEOUT_S=180"
fi

# ── COMPLETED + FAIL ─────────────────────────────────────────────────
cp "$TMP/warm" "$TMP/warm_fail"
set_kv "$TMP/warm_fail" RUN_OUTCOME FAIL
set_kv "$TMP/warm_fail" SELFCHECK_RESULT FAIL
run_case "COMPLETED+RUN_OUTCOME=FAIL" reject "$TMP/cold" "$TMP/warm_fail"

# ── COMPLETED + UNKNOWN ──────────────────────────────────────────────
cp "$TMP/warm" "$TMP/warm_unk"
set_kv "$TMP/warm_unk" SELFCHECK_RESULT UNKNOWN
run_case "COMPLETED+SELFCHECK_RESULT=UNKNOWN" reject "$TMP/cold" "$TMP/warm_unk"

# ── TRAPPED_* ────────────────────────────────────────────────────────
for trap_status in TRAPPED_RSS TRAPPED_STEPS TRAPPED_OTHER; do
  cp "$TMP/warm" "$TMP/warm_trap"
  set_kv "$TMP/warm_trap" STATUS "$trap_status"
  run_case "STATUS=${trap_status}" reject "$TMP/cold" "$TMP/warm_trap"
done

# ── dirty tree ───────────────────────────────────────────────────────
cp "$TMP/warm" "$TMP/warm_dirty"
set_kv "$TMP/warm_dirty" RUN_TREE_CLEAN 0
run_case "RUN_TREE_CLEAN=0" reject "$TMP/cold" "$TMP/warm_dirty"

# ── failure fingerprint ──────────────────────────────────────────────
cp "$TMP/warm" "$TMP/warm_fp"
set_kv "$TMP/warm_fp" FAILURE_FINGERPRINT 'HIR_INVALID|std::bench|load_baseline|Node=1'
run_case "FAILURE_FINGERPRINT=HIR_INVALID|..." reject "$TMP/cold" "$TMP/warm_fp"

# ── RUN_EXIT: nonzero / missing ──────────────────────────────────────
cp "$TMP/warm" "$TMP/warm_exit1"
set_kv "$TMP/warm_exit1" RUN_EXIT 1
run_case "RUN_EXIT=1" reject "$TMP/cold" "$TMP/warm_exit1"
cp "$TMP/warm" "$TMP/warm_exit_missing"
set_kv "$TMP/warm_exit_missing" RUN_EXIT UNKNOWN
run_case "RUN_EXIT=UNKNOWN (missing)" reject "$TMP/cold" "$TMP/warm_exit_missing"

# ── identity-field mismatches (each must be a hard failure) ──────────
for spec in \
  "RUN_SHA:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" \
  "RUN_TARGET:x86_64-unknown-linux-gnu" \
  "CLOSURE_FINGERPRINT:5555555555555555555555555555555555555555555555555555555555555555" \
  "RUN_GC_POLICY:o=200" \
  "SEED_SHA256:6666666666666666666666666666666666666666666666666666666666666666" \
  "MANIFEST_SHA256:7777777777777777777777777777777777777777777777777777777777777777" \
  "LOG_KIND:aggregate"; do
  key="${spec%%:*}"
  value="${spec#*:}"
  cp "$TMP/warm" "$TMP/warm_mut"
  set_kv "$TMP/warm_mut" "$key" "$value"
  run_case "${key} mismatch/mixed" reject "$TMP/cold" "$TMP/warm_mut"
done

# ── accepted aggregate pair ──────────────────────────────────────────
emit_block "$TMP/acold" aggregate
emit_block "$TMP/awarm" aggregate
set_kv "$TMP/acold" RUN_LABEL acold
set_kv "$TMP/awarm" RUN_LABEL awarm
set_kv "$TMP/acold" VM_A_FINAL_STEPS 1000000
set_kv "$TMP/acold" VM_B_FINAL_STEPS 2000000
set_kv "$TMP/awarm" VM_A_FINAL_STEPS 1100000
set_kv "$TMP/awarm" VM_B_FINAL_STEPS 2100000
set_kv "$TMP/acold" AGGREGATE_WALL_S 1200
set_kv "$TMP/awarm" AGGREGATE_WALL_S 1300
set_kv "$TMP/acold" VM_A_PEAK_RSS_MIB 6000
set_kv "$TMP/acold" VM_B_PEAK_RSS_MIB 7000
set_kv "$TMP/awarm" VM_A_PEAK_RSS_MIB 6200
set_kv "$TMP/awarm" VM_B_PEAK_RSS_MIB 7200
run_case "aggregate COMPLETED+PASS" accept "$TMP/acold" "$TMP/awarm"
if grep -q '^PROPOSED_STEPS_LIMIT=2415000$' "$TMP/out.txt"; then
  pass "aggregate margin formula: steps = ceil(2100000*1.15) = 2415000"
else
  bad "aggregate margin formula: expected PROPOSED_STEPS_LIMIT=2415000"
fi
if grep -q '^PROPOSED_WALL_TIMEOUT_S=1980$' "$TMP/out.txt"; then
  pass "aggregate wall margin: ceil(1300*1.5/60)*60 = 1980"
else
  bad "aggregate wall margin: expected PROPOSED_WALL_TIMEOUT_S=1980"
fi
if grep -q '^PROPOSED_RSS_MIB=9424$' "$TMP/out.txt"; then
  pass "aggregate RSS margin: 7200 + 1200 + max(1024,720) = 9424"
else
  bad "aggregate RSS margin: expected PROPOSED_RSS_MIB=9424"
fi

# ── aggregate + FAIL ─────────────────────────────────────────────────
cp "$TMP/awarm" "$TMP/awarm_fail"
set_kv "$TMP/awarm_fail" RUN_OUTCOME FAIL
run_case "aggregate RUN_OUTCOME=FAIL" reject "$TMP/acold" "$TMP/awarm_fail"

# ── legacy evidence (no RUN_OUTCOME) must be rejected outright ───────
cp "$TMP/warm" "$TMP/warm_legacy"
set_kv "$TMP/warm_legacy" RUN_OUTCOME UNKNOWN
set_kv "$TMP/warm_legacy" PROFILE_SCHEMA UNKNOWN
set_kv "$TMP/warm_legacy" RUN_EXIT UNKNOWN
run_case "legacy-style block without schema-2 evidence" reject "$TMP/cold" "$TMP/warm_legacy"

if [ "$fail" -ne 0 ]; then
  echo "test_repin_evidence: FAIL"
  exit 1
fi
echo "test_repin_evidence: ALL PASS"
exit 0
