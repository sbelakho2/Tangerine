#!/usr/bin/env bash
#
# tests/run_int_arith_trap_lane.sh — audit §24: the signed-overflow
# TRAP at the native runtime, across every optimization level.
#
# The P1-5 language rule: signed `+` `-` `*` (Int/i8..i64) trap on
# overflow. A trap is a machine-level fault (the MirAssert terminator
# lowers to UDF on AArch64 / UD2 on x86), NOT a catchable panic, so it
# cannot be asserted inside an @test suite — the assertion lives here,
# at the process-exit boundary: every fixture below must FAIL (exit
# nonzero) at -O0..-O3, and the in-range control must exit 0. An
# optimizer that folded the overflow into silent wrap-around would make
# the fixture exit 0 and this lane fails.
#
# The division-edge rule (audit item 30) is asserted here too: the raw
# `/` and `%` edges — divisor zero on every kind, and the SIGNED
# INT64_MIN/-1 quotient (the remainder divides through the same edge) —
# TRAP on every target and both routes (the aarch64 UDF guard, the x86
# UD2 guard). Four trap cases plus the near-edge controls below.
#
# The edge values are passed through typed locals (never literal
# overflow expressions, which the checker rejects at compile time).
#
# Usage: tests/run_int_arith_trap_lane.sh <compiler> <outdir>

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPILER="${1:-build/tg}"
OUTDIR="${2:-build/.int_arith_trap_lane}"

if [ ! -x "$COMPILER" ]; then
  echo "int-arith trap lane: compiler binary not executable: $COMPILER" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

FAILED=0
LEVELS="0 1 2 3"

# One fixture per overflow edge. Each source writes the edge values
# into typed locals, performs the plain signed operation and ignores
# the result: the ONLY way the process exits 0 is a silently wrapped
# result (the language rule violated). Every fixture defines main()
# returning 0 on success.
write_case() {
  local file="$1"
  local body="$2"
  cat > "$file" << EOF
$body
EOF
}

TOTAL_RUNS=0
TOTAL_TRAPS=0

run_trap_case() {
  local name="$1"
  local body="$2"
  local file="$OUTDIR/trap_${name}.tg"
  write_case "$file" "$body"
  local level
  for level in $LEVELS; do
    TOTAL_RUNS=$((TOTAL_RUNS + 1))
    if "$COMPILER" run "-O$level" "$file" > "$OUTDIR/trap_${name}_O${level}.log" 2>&1; then
      echo "int-arith trap lane: FAIL  ${name} at -O${level} exited 0 (the overflow must TRAP)"
      FAILED=1
    else
      TOTAL_TRAPS=$((TOTAL_TRAPS + 1))
    fi
  done
}

# ── the overflowing edges (each must trap at every level) ──────────

run_trap_case "add_int_max_plus_one" '
def main() -> Int
  let a: Int = 9223372036854775807
  let b: Int = 1
  let r = a + b
  let _ = r
  0
end'

run_trap_case "sub_int_min_minus_one" '
def main() -> Int
  let a: Int = -9223372036854775807 - 1
  let b: Int = 1
  let r = a - b
  let _ = r
  0
end'

run_trap_case "mul_i64_min_times_minus_one" '
def main() -> Int
  let a: Int = -9223372036854775807 - 1
  let b: Int = -1
  let r = a * b
  let _ = r
  0
end'

run_trap_case "mul_i64_max_times_two" '
def main() -> Int
  let a: Int = 9223372036854775807
  let b: Int = 2
  let r = a * b
  let _ = r
  0
end'

run_trap_case "add_i64_max_plus_one" '
def main() -> Int
  let a: i64 = 9223372036854775807
  let b: i64 = 1
  let r = a + b
  let _ = r
  0
end'

run_trap_case "add_i32_max_plus_one" '
def main() -> Int
  let a: i32 = 2147483647
  let b: i32 = 1
  let r = a + b
  let _ = r
  0
end'

run_trap_case "add_i16_max_plus_one" '
def main() -> Int
  let a: i16 = 32767
  let b: i16 = 1
  let r = a + b
  let _ = r
  0
end'

run_trap_case "add_i8_max_plus_one" '
def main() -> Int
  let a: i8 = 127
  let b: i8 = 1
  let r = a + b
  let _ = r
  0
end'

run_trap_case "sub_i32_min_minus_one" '
def main() -> Int
  let a: i32 = -2147483647 - 1
  let b: i32 = 1
  let r = a - b
  let _ = r
  0
end'

run_trap_case "mul_i8_min_times_minus_one" '
def main() -> Int
  let a: i8 = -128
  let b: i8 = -1
  let r = a * b
  let _ = r
  0
end'

# ── the division/remainder edges (audit item 30: each must trap) ────

run_trap_case "div_int_by_zero" '
def main() -> Int
  let a: Int = 84
  let b: Int = 0
  let r = a / b
  let _ = r
  0
end'

run_trap_case "mod_int_by_zero" '
def main() -> Int
  let a: Int = 84
  let b: Int = 0
  let r = a % b
  let _ = r
  0
end'

run_trap_case "div_int_min_by_minus_one" '
def main() -> Int
  let a: Int = -9223372036854775807 - 1
  let b: Int = -1
  let r = a / b
  let _ = r
  0
end'

run_trap_case "mod_int_min_by_minus_one" '
def main() -> Int
  let a: Int = -9223372036854775807 - 1
  let b: Int = -1
  let r = a % b
  let _ = r
  0
end'

run_trap_case "div_i64_by_zero" '
def main() -> Int
  let a: i64 = 84
  let b: i64 = 0
  let r = a / b
  let _ = r
  0
end'

run_trap_case "div_i8_by_zero" '
def main() -> Int
  let a: i8 = 84
  let b: i8 = 0
  let r = a / b
  let _ = r
  0
end'

# ── the in-range control (must NOT trap at any level) ──────────────

CONTROL_RUNS=0
CONTROL_OK=0
control_case() {
  local name="$1"
  local body="$2"
  local file="$OUTDIR/control_${name}.tg"
  write_case "$file" "$body"
  local level
  for level in $LEVELS; do
    CONTROL_RUNS=$((CONTROL_RUNS + 1))
    if "$COMPILER" run "-O$level" "$file" > "$OUTDIR/control_${name}_O${level}.log" 2>&1; then
      CONTROL_OK=$((CONTROL_OK + 1))
    else
      echo "int-arith trap lane: FAIL  control ${name} at -O${level} trapped (in-range arithmetic must run)"
      FAILED=1
    fi
  done
}

control_case "add_in_range" '
def main() -> Int
  let a: Int = 9223372036854775806
  let r = a + 1
  let _ = r
  0
end'

control_case "sub_in_range" '
def main() -> Int
  let a: Int = -9223372036854775807 - 1
  let r = a - 0
  let _ = r
  0
end'

control_case "mul_in_range" '
def main() -> Int
  let a: Int = -9223372036854775807 - 1
  let r = a * 1
  let _ = r
  0
end'

# The division guard must not over-trap: MIN / 1 and MIN / 2 are in
# range, and (MIN + 1) / -1 is the largest in-range negative quotient.
control_case "div_min_by_one" '
def main() -> Int
  let a: Int = -9223372036854775807 - 1
  let b: Int = 1
  let r = a / b
  let _ = r
  0
end'

control_case "div_min_by_two" '
def main() -> Int
  let a: Int = -9223372036854775807 - 1
  let b: Int = 2
  let r = a / b
  let _ = r
  0
end'

control_case "div_near_min_by_minus_one" '
def main() -> Int
  let a: Int = -9223372036854775807
  let b: Int = -1
  let r = a / b
  let _ = r
  0
end'

control_case "mod_in_range" '
def main() -> Int
  let a: Int = 84
  let b: Int = 12
  let r = a % b
  let _ = r
  0
end'

echo "int-arith trap lane: $TOTAL_TRAPS/$TOTAL_RUNS overflowing runs trapped; $CONTROL_OK/$CONTROL_RUNS in-range controls ran clean"
if [ "$FAILED" -ne 0 ]; then
  echo "int-arith trap lane: FAILED" >&2
  exit 1
fi

echo "int-arith trap lane: PASS"
