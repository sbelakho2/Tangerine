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
#   H) (item 45 / P1-7) the heap_bytes NO-FINITE-BOUND failure:
#      `@budget(heap_bytes = 0)` on a function whose reachable sites
#      include a RUNTIME-SIZED allocation (Vec::new + push) FAILS the
#      compilation with the Unbounded row (the P1-7 rule: a runtime-sized
#      site can never be certified against a finite heap_bytes limit).
#   I) (item 45) the INSTRUCTIONS runtime counter: a loop whose dynamic
#      statement count exceeds the declared limit but whose STATIC
#      estimate is under it compiles and TRAPS at runtime.
#   J) (item 45) the time_us runtime-measured row: a generous
#      `@budget(time_us = 1000000)` compiles and exits 0 (the runtime
#      frame clock decides — no static row).
#   K) (P1-7) the runtime-capacity soundness case: a GENEROUS
#      `@budget(heap_bytes = "1073741824")` on a function that calls
#      `Vec::with_capacity(n)` with a RUNTIME n must still FAIL — the
#      with_capacity site is Unbounded, and "one site × 4096" can never
#      become a finite static proof.
#   L) (P1-8) the max TRANSITIVE stack: a caller whose own frame fits a
#      small `@budget(stack_bytes = "200")` but whose callee chain does
#      not FAILS with a row reporting BOTH frame_bytes and max_stack_bytes;
#      the generous-limit companion compiles and exits 0.
#   M) (P1-8) the recursion rule: a self-recursive function with a
#      generous `@budget(stack_bytes)` FAILS as Unbounded (a call cycle
#      with no proven finite recursion bound has no finite static
#      max-stack).
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

# H) (item 45 / P1-7) The heap_bytes no-finite-bound failure: a function
#    whose reachable sites include a RUNTIME-SIZED allocation (Vec::new +
#    push) against heap_bytes = 0 must NOT compile — the P1-7 Unbounded
#    aggregate carries no finite static bound to compare.
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

# K) (P1-7) The runtime-capacity soundness case: Vec::with_capacity(n)
#    with a RUNTIME n is Unbounded — even a 1 GiB heap_bytes limit must
#    FAIL (a runtime-sized site can never satisfy a finite static proof).
cat > "$SCRATCH/budget_heap_runtime_capacity.tg" <<'EOF'
def sized(n: Int) -> Int @budget(heap_bytes = "1073741824")
  let v = Vec[Int]::with_capacity(n)
  v.len() as Int
end

def main() -> Int
  sized(4)
end
EOF

# L) (P1-8) The max TRANSITIVE stack failure: `shallow`'s own MIR frame
#    fits stack_bytes = 200, but its callee `heavy` has a wide frame; the
#    derived max_stack = frame(shallow) + frame(heavy) + the documented
#    call overhead must FAIL and the row must report BOTH frame_bytes and
#    max_stack_bytes. `heavy` keeps its ~30 locals live through the sum.
cat > "$SCRATCH/budget_stack_transitive.tg" <<'EOF'
def heavy() -> Int
  let a0 = 1
  let a1 = 2
  let a2 = 3
  let a3 = 4
  let a4 = 5
  let a5 = 6
  let a6 = 7
  let a7 = 8
  let a8 = 9
  let a9 = 10
  let a10 = 11
  let a11 = 12
  let a12 = 13
  let a13 = 14
  let a14 = 15
  let a15 = 16
  let a16 = 17
  let a17 = 18
  let a18 = 19
  let a19 = 20
  let a20 = 21
  let a21 = 22
  let a22 = 23
  let a23 = 24
  let a24 = 25
  let a25 = 26
  let a26 = 27
  let a27 = 28
  let a28 = 29
  let a29 = 30
  let s0 = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9
  let s1 = a10 + a11 + a12 + a13 + a14 + a15 + a16 + a17 + a18 + a19
  let s2 = a20 + a21 + a22 + a23 + a24 + a25 + a26 + a27 + a28 + a29
  s0 + s1 + s2
end

def shallow() -> Int @budget(stack_bytes = "200")
  let x = heavy()
  x
end

def main() -> Int
  shallow()
end
EOF

# L2) The generous-limit companion: the SAME chain under a limit above the
#     computed max-stack must compile and exit 0.
cat > "$SCRATCH/budget_stack_transitive_within.tg" <<'EOF'
def heavy() -> Int
  let a0 = 1
  let a1 = 2
  let a2 = 3
  let a3 = 4
  let a4 = 5
  let a5 = 6
  let a6 = 7
  let a7 = 8
  let a8 = 9
  let a9 = 10
  let a10 = 11
  let a11 = 12
  let a12 = 13
  let a13 = 14
  let a14 = 15
  let a15 = 16
  let a16 = 17
  let a17 = 18
  let a18 = 19
  let a19 = 20
  let a20 = 21
  let a21 = 22
  let a22 = 23
  let a23 = 24
  let a24 = 25
  let a25 = 26
  let a26 = 27
  let a27 = 28
  let a28 = 29
  let a29 = 30
  let s0 = a0 + a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8 + a9
  let s1 = a10 + a11 + a12 + a13 + a14 + a15 + a16 + a17 + a18 + a19
  let s2 = a20 + a21 + a22 + a23 + a24 + a25 + a26 + a27 + a28 + a29
  s0 + s1 + s2
end

def shallow() -> Int @budget(stack_bytes = "8192")
  let x = heavy()
  x
end

def main() -> Int
  shallow()
end
EOF

# M) (P1-8) The recursion rule: a self-recursive function has a call cycle
#    with NO proven finite recursion bound — the max-stack analysis reports
#    Unbounded and the generous annotation FAILS.
cat > "$SCRATCH/budget_stack_recursive.tg" <<'EOF'
def rec(n: Int) -> Int @budget(stack_bytes = "1048576")
  if n <= 0 then
    0
  else
    rec(n - 1) + 1
  end
end

def main() -> Int
  rec(3)
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

# Cases B/C/D/E/G/J/L2: within-limit programs must compile and exit 0.
for case_name in budget_branch_within budget_two_calls budget_nested budget_static_within budget_static_proof budget_time_us budget_stack_transitive_within; do
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

# Case H: the heap_bytes P1-7 rule — a reachable runtime-sized allocation
# can never be certified, so the compile must FAIL with the Unbounded row.
if "$COMPILER" "$SCRATCH/budget_heap_over.tg" -o "$SCRATCH/heap_over" >"$SCRATCH/h_build.log" 2>&1; then
  bh_err "budget Case H FAILED: heap_bytes = 0 compiled despite a runtime-sized allocating site"
  failures=$((failures + 1))
else
  if grep -Eq "budget:heap_bytes (unbounded|unknown)" "$SCRATCH/h_build.log" && grep -q "no finite static bound" "$SCRATCH/h_build.log"; then
    bh_log "budget Case H ok: heap_bytes Unbounded/Unknown violation failed the annotation"
  else
    bh_err "budget Case H FAILED: the compile failed but the no-finite-bound heap_bytes row is missing"
    bh_err "  $(head -n5 "$SCRATCH/h_build.log" | tr '\n' ' ')"
    failures=$((failures + 1))
  fi
fi

# Case K: the runtime-capacity soundness case. Vec::with_capacity(n) over
# a runtime n is Unbounded — a finite heap_bytes limit (even 1 GiB) can
# never be certified and the compile must FAIL with the P1-7 row.
if "$COMPILER" "$SCRATCH/budget_heap_runtime_capacity.tg" -o "$SCRATCH/heap_runtime_capacity" >"$SCRATCH/k_build.log" 2>&1; then
  bh_err "budget Case K FAILED: Vec::with_capacity(runtime n) satisfied a finite heap_bytes proof"
  failures=$((failures + 1))
else
  if grep -Eq "budget:heap_bytes (unbounded|unknown)" "$SCRATCH/k_build.log" && grep -q "no finite static bound" "$SCRATCH/k_build.log"; then
    bh_log "budget Case K ok: the runtime-capacity site can never satisfy a finite heap_bytes proof"
  else
    bh_err "budget Case K FAILED: the compile failed but the runtime-capacity heap row is missing"
    bh_err "  $(head -n5 "$SCRATCH/k_build.log" | tr '\n' ' ')"
    failures=$((failures + 1))
  fi
fi

# Case L: the max TRANSITIVE stack — the caller's own frame fits the limit
# while frame + callee frame + call overhead does not. The row must report
# BOTH frame_bytes and max_stack_bytes.
if "$COMPILER" "$SCRATCH/budget_stack_transitive.tg" -o "$SCRATCH/stack_transitive" >"$SCRATCH/l_build.log" 2>&1; then
  bh_err "budget Case L FAILED: the transitive max-stack overrun compiled"
  failures=$((failures + 1))
else
  if grep -q "budget:stack_bytes static-bound bound" "$SCRATCH/l_build.log" && grep -q "exceeds limit 200" "$SCRATCH/l_build.log" && grep -q "frame_bytes" "$SCRATCH/l_build.log" && grep -q "max_stack_bytes" "$SCRATCH/l_build.log"; then
    bh_log "budget Case L ok: the transitive max-stack violation reports frame_bytes + max_stack_bytes"
  else
    bh_err "budget Case L FAILED: the max-stack row is missing"
    bh_err "  $(head -n5 "$SCRATCH/l_build.log" | tr '\n' ' ')"
    failures=$((failures + 1))
  fi
fi

# Case M: the recursion rule — a self-recursive function has no proven
# finite recursion bound, so the max-stack is Unbounded and the generous
# stack_bytes annotation FAILS.
if "$COMPILER" "$SCRATCH/budget_stack_recursive.tg" -o "$SCRATCH/stack_recursive" >"$SCRATCH/m_build.log" 2>&1; then
  bh_err "budget Case M FAILED: a recursive call cycle satisfied a finite stack_bytes proof"
  failures=$((failures + 1))
else
  if grep -q "budget:stack_bytes unbounded" "$SCRATCH/m_build.log" && grep -q "recursion bound" "$SCRATCH/m_build.log"; then
    bh_log "budget Case M ok: the recursive call cycle failed as Unbounded"
  else
    bh_err "budget Case M FAILED: the compile failed but the unbounded recursion row is missing"
    bh_err "  $(head -n5 "$SCRATCH/m_build.log" | tr '\n' ' ')"
    failures=$((failures + 1))
  fi
fi

if [ "$failures" -ne 0 ]; then
  bh_err "budget enforcement tests FAILED: $failures problem(s)"
  exit 1
fi
bh_log "budget enforcement tests OK: runtime traps (alloc/instructions/time), static guarantees (stack/heap/instructions vocabulary), the P1-7 runtime-size/with_capacity no-finite-bound rule, the P1-8 transitive max-stack rows and the recursion rule all behave"
exit 0
