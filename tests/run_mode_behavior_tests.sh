#!/usr/bin/env bash
# tests/run_mode_behavior_tests.sh
#
# Mode-behavior acceptance tests — every mode's promised behavior, per
# docs/current/language.md §Progressive Strictness:
#
#   A) contract enforcement is UNCONDITIONAL in every mode: a program whose
#      precondition fails must trap at runtime under --mode dev, strict,
#      production AND hardened (the MirContractCheck -> runtime trap path
#      never consults the mode flag).
#   B) capability enforcement is UNCONDITIONAL in every mode: a program
#      that drops a live capability at function exit must be REJECTED at
#      compile time under all four modes (validate_capability_exit).
#   C) sanity: the same contract program with a SATISFIED precondition
#      compiles and exits 0 under every mode.
#
# Usage: tests/run_mode_behavior_tests.sh [compiler-binary] [scratch-dir]
#   compiler-binary defaults to build/tg_stage2
#   scratch-dir     defaults to build/.mode_behavior
# Exits 0 when all four modes pass all three cases.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/bootstrap_helpers.sh
source "$ROOT/scripts/bootstrap_helpers.sh"

COMPILER="${1:-$ROOT/build/tg_stage2}"
SCRATCH="${2:-$ROOT/build/.mode_behavior}"

if [ ! -x "$COMPILER" ]; then
  bh_err "mode behavior: compiler binary not executable: $COMPILER"
  exit 1
fi

mkdir -p "$SCRATCH"

MODES="dev strict production hardened"

# A) Contract violation -> runtime trap (the enforcing pass is
#    lower_contract / MirContractCheck, unconditional).
cat > "$SCRATCH/contract_violation.tg" <<'EOF'
use std::core

def sqrt_ok(x: Float) -> Float
  pre x >= 0.0, "sqrt requires non-negative input"
  x
end

def main() -> Int
  let r = sqrt_ok(-1.0)
  0
end
EOF

# B) Capability dropped at exit -> compile-time rejection (the enforcing
#    pass is validate_capability_exit, unconditional).
cat > "$SCRATCH/capability_drop.tg" <<'EOF'
use std::core

cap C

def drop_cap(c: sink C) -> Int
  let c2 = c
  0
end

def main() -> Int
  0
end
EOF

# C) Satisfied contract -> clean run (sanity).
cat > "$SCRATCH/contract_ok.tg" <<'EOF'
use std::core

def sqrt_ok(x: Float) -> Float
  pre x >= 0.0, "sqrt requires non-negative input"
  x
end

def main() -> Int
  let r = sqrt_ok(4.0)
  0
end
EOF

failures=0
for mode in $MODES; do
  # Case A: compile + run the contract-violating program; the runtime trap
  # must produce a nonzero exit.
  if ! "$COMPILER" "$SCRATCH/contract_violation.tg" --mode "$mode" -o "$SCRATCH/violation_$mode" >"$SCRATCH/a_build_$mode.log" 2>&1; then
    bh_err "mode=$mode Case A: contract-violation program did not compile (contracts must compile; the trap is runtime)"
    bh_err "  $(head -n3 "$SCRATCH/a_build_$mode.log" | tr '\n' ' ')"
    failures=$((failures + 1))
  else
    if "$SCRATCH/violation_$mode" >"$SCRATCH/a_run_$mode.log" 2>&1; then
      bh_err "mode=$mode Case A FAILED: contract-violating program exited 0 (no trap)"
      failures=$((failures + 1))
    else
      bh_log "mode=$mode Case A ok: contract violation trapped at runtime"
    fi
  fi

  # Case B: the capability-dropping program must be rejected at compile time.
  if "$COMPILER" check "$SCRATCH/capability_drop.tg" --mode "$mode" >"$SCRATCH/b_$mode.out" 2>&1; then
    bh_err "mode=$mode Case B FAILED: capability-dropping program accepted"
    failures=$((failures + 1))
  else
    if grep -qi "capability" "$SCRATCH/b_$mode.out"; then
      bh_log "mode=$mode Case B ok: capability drop rejected"
    else
      bh_err "mode=$mode Case B: rejected but no capability diagnostic found:"
      bh_err "  $(head -n3 "$SCRATCH/b_$mode.out" | tr '\n' ' ')"
      failures=$((failures + 1))
    fi
  fi

  # Case C: the satisfied-contract program must compile and exit 0.
  if ! "$COMPILER" "$SCRATCH/contract_ok.tg" --mode "$mode" -o "$SCRATCH/ok_$mode" >"$SCRATCH/c_build_$mode.log" 2>&1; then
    bh_err "mode=$mode Case C FAILED: satisfied-contract program did not compile"
    bh_err "  $(head -n3 "$SCRATCH/c_build_$mode.log" | tr '\n' ' ')"
    failures=$((failures + 1))
  else
    if ! "$SCRATCH/ok_$mode" >"$SCRATCH/c_run_$mode.log" 2>&1; then
      bh_err "mode=$mode Case C FAILED: satisfied-contract program exited nonzero"
      failures=$((failures + 1))
    else
      bh_log "mode=$mode Case C ok: satisfied contract compiles and runs clean"
    fi
  fi
done

if [ "$failures" -ne 0 ]; then
  bh_err "mode behavior tests FAILED: $failures problem(s)"
  exit 1
fi
bh_log "mode behavior tests OK: contracts+capabilities unconditional across dev/strict/production/hardened"
exit 0
