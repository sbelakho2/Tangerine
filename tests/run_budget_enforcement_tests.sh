#!/usr/bin/env bash
# tests/run_budget_enforcement_tests.sh
#
# Budget-enforcement acceptance tests — the RUNTIME-TRAP class. The
# allocation metric's enforcement is purely runtime (the static
# allocation-site rejection was removed as path-insensitive): a budgeted
# function whose TAKEN PATH exceeds the declared limit traps at runtime
# (the per-invocation frame-slot counter — the prologue zeroes it, the
# MirBudgetConsume arms increment + compare, the limit exceeded -> the
# runtime trap -> nonzero exit), while every within-limit path exits 0.
#
#   A) the OVER-LIMIT path (an `if` where the taken branch allocates
#      TWICE against alloc: "1") must COMPILE and TRAP at runtime.
#   B) the within-limit branch case (the 2-site if with limit 1 — the
#      former static-exceed rejection) must compile and exit 0.
#   C) two calls of a within-limit function (the per-invocation counter)
#      must compile and exit 0.
#   D) nested budgeted calls (each invocation's own frame slots) must
#      compile and exit 0.
#
# Usage: tests/run_budget_enforcement_tests.sh [compiler-binary] [scratch-dir]
#   compiler-binary defaults to build/tg_stage2
#   scratch-dir     defaults to build/.budget_enforcement
# Exits 0 when all four cases pass.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/bootstrap_helpers.sh
source "$ROOT/scripts/bootstrap_helpers.sh"

COMPILER="${1:-$ROOT/build/tg_stage2}"
SCRATCH="${2:-$ROOT/build/.budget_enforcement}"

if [ ! -x "$COMPILER" ]; then
  bh_err "budget enforcement: compiler binary not executable: $COMPILER"
  exit 1
fi

mkdir -p "$SCRATCH"

# A) Over-limit path -> runtime trap (nonzero exit). The taken branch
#    allocates twice against `alloc: "1"`; the frame-slot counter exceeds
#    the limit at the second push and the codegen arms trap.
cat > "$SCRATCH/budget_over_limit.tg" <<'EOF'
def budgeted(c: Bool) -> Int @budget alloc: "1"
  let v = Vec[Int]::new()
  if c then
    v.push(1)
    v.push(2)
  else
    v.push(1)
  end
  0
end

def main() -> Int
  budgeted(true)
end
EOF

# B) Within-limit branch case (2 sites, 1 per path, limit 1) -> exit 0.
cat > "$SCRATCH/budget_branch_within.tg" <<'EOF'
def budgeted(c: Bool) -> Int @budget alloc: "1"
  let v = Vec[Int]::new()
  if c then
    v.push(1)
  else
    v.push(2)
  end
  0
end

def main() -> Int
  let a = budgeted(true)
  let b = budgeted(false)
  a + b
end
EOF

# C) Per-invocation counter: two calls within the limit -> exit 0.
cat > "$SCRATCH/budget_two_calls.tg" <<'EOF'
def step() -> Int @budget alloc: "1"
  let v = Vec[Int]::new()
  v.push(1)
  0
end

def main() -> Int
  let a = step()
  let b = step()
  a + b
end
EOF

# D) Nested budgeted calls (each invocation's own frame slots) -> exit 0.
cat > "$SCRATCH/budget_nested.tg" <<'EOF'
def inner() -> Int @budget alloc: "1"
  let v = Vec[Int]::new()
  v.push(1)
  0
end

def outer() -> Int @budget alloc: "2"
  let v = Vec[Int]::new()
  v.push(1)
  v.push(2)
  let _ = inner()
  0
end

def main() -> Int
  outer()
end
EOF

failures=0

# Case A: compile + run the over-limit program; the runtime trap must
# produce a nonzero exit (the trap is runtime — the compile succeeds).
if ! "$COMPILER" "$SCRATCH/budget_over_limit.tg" -o "$SCRATCH/over_limit" >"$SCRATCH/a_build.log" 2>&1; then
  bh_err "budget Case A: over-limit program did not compile (the enforcement is runtime; compile must succeed)"
  bh_err "  $(head -n3 "$SCRATCH/a_build.log" | tr '\n' ' ')"
  failures=$((failures + 1))
else
  if "$SCRATCH/over_limit" >"$SCRATCH/a_run.log" 2>&1; then
    bh_err "budget Case A FAILED: over-limit program exited 0 (no trap)"
    failures=$((failures + 1))
  else
    bh_log "budget Case A ok: over-limit path trapped at runtime"
  fi
fi

# Cases B/C/D: within-limit programs must compile and exit 0.
for case_name in budget_branch_within budget_two_calls budget_nested; do
  if ! "$COMPILER" "$SCRATCH/$case_name.tg" -o "$SCRATCH/$case_name" >"$SCRATCH/${case_name}_build.log" 2>&1; then
    bh_err "budget Case $case_name FAILED: within-limit program did not compile"
    bh_err "  $(head -n3 "$SCRATCH/${case_name}_build.log" | tr '\n' ' ')"
    failures=$((failures + 1))
  else
    if ! "$SCRATCH/$case_name" >"$SCRATCH/${case_name}_run.log" 2>&1; then
      bh_err "budget Case $case_name FAILED: within-limit program exited nonzero"
      failures=$((failures + 1))
    else
      bh_log "budget Case $case_name ok: within-limit program exits 0"
    fi
  fi
done

if [ "$failures" -ne 0 ]; then
  bh_err "budget enforcement tests FAILED: $failures problem(s)"
  exit 1
fi
bh_log "budget enforcement tests OK: over-limit traps at runtime; within-limit paths (branch/two-calls/nested) exit 0"
exit 0
