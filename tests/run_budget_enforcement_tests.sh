#!/usr/bin/env bash
# tests/run_budget_enforcement_tests.sh
#
# Budget-enforcement acceptance tests — the RUNTIME-TRAP class plus the
# third-audit item-45 STATIC guarantee class. The allocation metric's
# enforcement is purely runtime (the static allocation-site rejection was
# removed as path-insensitive): a budgeted function whose TAKEN PATH
# exceeds the declared limit traps at runtime (the per-invocation
# frame-slot counter — the prologue zeroes it, the MirBudgetConsume arms
# increment + compare, the limit exceeded -> the runtime trap -> nonzero
# exit), while every within-limit path exits 0.
#
#   A) the OVER-LIMIT path (an `if` where the taken branch allocates
#      TWICE against alloc: "1") must COMPILE and TRAP at runtime.
#   B) the within-limit branch case (the 2-site if with limit 1 — the
#      former static-exceed rejection) must compile and exit 0.
#   C) two calls of a within-limit function (the per-invocation counter)
#      must compile and exit 0.
#   D) nested budgeted calls (each invocation's own frame slots) must
#      compile and exit 0.
#   E) (item 45) the stack_bytes/instructions/static vocabulary:
#      `@budget(stack_bytes = 256, instructions = 10000)` on a small
#      function passes statically and exits 0 (the static-bound
#      derivation is under the limits).
#   F) (item 45) the STATIC-bound failure: `@budget(stack_bytes = 8)` on a
#      function whose MIR frame bound exceeds 8 FAILS the compilation with
#      the E0235 row naming the classification and the derived bound.
#   G) (item 45) the heap_allocations = 0 / heap_bytes = 0 static proof:
#      a non-allocating function passes statically and exits 0.
#   H) (item 45) the heap_bytes static-bound failure: `@budget(heap_bytes
#      = 0)` on an allocating function FAILS the compilation with the
#      measured/bound value row.
#   I) (item 45) the INSTRUCTIONS runtime counter: a loop whose dynamic
#      statement count exceeds the declared limit but whose STATIC
#      estimate is under it compiles and TRAPS at runtime.
#   J) (item 45) the time_us runtime-measured row: a generous
#      `@budget(time_us = 1000000)` compiles and exits 0 (the runtime
#      frame clock decides — no static row).
#
# Usage: tests/run_budget_enforcement_tests.sh [compiler-binary] [scratch-dir]
#   compiler-binary defaults to build/tg_stage2
#   scratch-dir     defaults to build/.budget_enforcement
# Exits 0 when all cases pass.
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

# E) (item 45) The static vocabulary within its limits -> exit 0. The
#    parenthesized attribute-argument form and the bare numeric bounds are
#    exercised (stack_bytes = 256, instructions = 10000).
cat > "$SCRATCH/budget_static_within.tg" <<'EOF'
def bounded(x: Int) -> Int @budget(stack_bytes = 256, instructions = 10000)
  let a = x + 1
  let b = a + 2
  b
end

def main() -> Int
  bounded(1)
end
EOF

# F) (item 45) The static-bound failure: a function whose MIR frame bound
#    exceeds stack_bytes = 8 must NOT compile (the E0235 row reports the
#    classification and the derived bound).
cat > "$SCRATCH/budget_stack_over.tg" <<'EOF'
def too_deep(x: Int) -> Int @budget stack_bytes: "8"
  let a = x + 1
  let b = a + 2
  b
end

def main() -> Int
  too_deep(1)
end
EOF

# G) (item 45) The zero-allocation / zero-heap-byte static proof -> exit 0.
cat > "$SCRATCH/budget_static_proof.tg" <<'EOF'
def pure_math(x: Int) -> Int @budget(heap_allocations = 0, heap_bytes = 0)
  let a = x * 2
  let b = a + 3
  b
end

def main() -> Int
  pure_math(1)
end
EOF

# H) (item 45) The heap_bytes static-bound failure: an allocating function
#    against heap_bytes = 0 must NOT compile (the row carries the derived
#    site bound).
cat > "$SCRATCH/budget_heap_over.tg" <<'EOF'
def leaky() -> Int @budget(heap_bytes = 0)
  let v = Vec[Int]::new()
  v.push(1)
  0
end

def main() -> Int
  leaky()
end
EOF

# I) (item 45) The instructions runtime counter: the loop's STATIC estimate
#    is under the limit (so the compile succeeds) while its dynamic
#    statement count exceeds it (so the frame counter traps at the return).
#    The loop count is observable through the result, so no optimizer pass
#    can eliminate the iterations.
cat > "$SCRATCH/budget_instr_over.tg" <<'EOF'
def spin() -> Int @budget(instructions = 50)
  var i = 0
  while i < 1000 do
    i = i + 1
  end
  i
end

def main() -> Int
  let r = spin()
  if r == 1000 then 0 else 1 end
end
EOF

# J) (item 45) The time_us runtime-measured row: no static derivation
#    exists, so the annotation compiles; the generous limit passes at run
#    time (exit 0).
cat > "$SCRATCH/budget_time_us.tg" <<'EOF'
def timed(x: Int) -> Int @budget(time_us = 1000000)
  let a = x + 1
  let b = a + 2
  b
end

def main() -> Int
  timed(1)
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

# Cases B/C/D/E/G/J: within-limit programs must compile and exit 0.
for case_name in budget_branch_within budget_two_calls budget_nested budget_static_within budget_static_proof budget_time_us; do
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

# Case I: the instructions runtime counter — compile must succeed and the
# dynamic overrun must trap at runtime (nonzero exit).
if ! "$COMPILER" "$SCRATCH/budget_instr_over.tg" -o "$SCRATCH/instr_over" >"$SCRATCH/i_build.log" 2>&1; then
  bh_err "budget Case I: instruction-budget program did not compile (the static estimate is within the limit; the runtime counter must decide)"
  bh_err "  $(head -n3 "$SCRATCH/i_build.log" | tr '\n' ' ')"
  failures=$((failures + 1))
else
  if "$SCRATCH/instr_over" >"$SCRATCH/i_run.log" 2>&1; then
    bh_err "budget Case I FAILED: dynamic instructions overrun exited 0 (no trap)"
    failures=$((failures + 1))
  else
    bh_log "budget Case I ok: instructions overrun trapped at runtime"
  fi
fi

# Case F: the stack_bytes static violation must FAIL the compile with the
# E0235 row naming the classification + the derived bound.
if "$COMPILER" "$SCRATCH/budget_stack_over.tg" -o "$SCRATCH/stack_over" >"$SCRATCH/f_build.log" 2>&1; then
  bh_err "budget Case F FAILED: stack_bytes = 8 compiled despite the derived frame bound exceeding it"
  failures=$((failures + 1))
else
  if grep -q "budget:stack_bytes static-bound bound" "$SCRATCH/f_build.log" && grep -q "exceeds limit 8" "$SCRATCH/f_build.log"; then
    bh_log "budget Case F ok: stack_bytes static-bound violation failed with the derived value row"
  else
    bh_err "budget Case F FAILED: the compile failed but the static-bound row is missing"
    bh_err "  $(head -n5 "$SCRATCH/f_build.log" | tr '\n' ' ')"
    failures=$((failures + 1))
  fi
fi

# Case H: the heap_bytes static violation must FAIL the compile with the
# static-bound row carrying the derived site bound.
if "$COMPILER" "$SCRATCH/budget_heap_over.tg" -o "$SCRATCH/heap_over" >"$SCRATCH/h_build.log" 2>&1; then
  bh_err "budget Case H FAILED: heap_bytes = 0 compiled despite an allocating site"
  failures=$((failures + 1))
else
  if grep -q "budget:heap_bytes static-bound bound" "$SCRATCH/h_build.log"; then
    bh_log "budget Case H ok: heap_bytes static-bound violation failed with the derived value row"
  else
    bh_err "budget Case H FAILED: the compile failed but the heap_bytes static-bound row is missing"
    bh_err "  $(head -n5 "$SCRATCH/h_build.log" | tr '\n' ' ')"
    failures=$((failures + 1))
  fi
fi

if [ "$failures" -ne 0 ]; then
  bh_err "budget enforcement tests FAILED: $failures problem(s)"
  exit 1
fi
bh_log "budget enforcement tests OK: runtime traps (alloc/instructions/time), static guarantees (stack/heap/instructions vocabulary) and the E0235 static-bound diagnostics all behave"
exit 0
