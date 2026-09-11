#!/usr/bin/env bash
# tests/run_differential_corpus_tests.sh
#
# Differential-corpus route-parity lane — the P0-21 retirement-readiness
# contract's DIFFERENTIAL PARITY item. The contract's criterion:
#
#     "the direct and LIR routes agree on the differential corpus lane ...
#      Since the flip this pass runs the EXPLICIT --codegen=direct
#      fallback against the default LIR route."
#
# Every corpus program is compiled TWICE — once through the LIR route
# (the canonical default; named with --codegen=lir so a pre-flip compiler
# can never silently compare direct-against-direct) and once through the
# explicit --codegen=direct fallback — and the two artifacts are compared:
#
#   EXECUTED   both routes compiled, the host can execute both binaries:
#              the exit code and the stdout stream must be IDENTICAL.
#              (stderr is captured for diagnostics only — the observable
#              contract is exit code + stdout, as the contract states.)
#
#   SKIP-EXEC  execution of one/both routes is impossible in this lane
#              environment (no executable artifact, a forced-structural
#              run, or an exec-format failure). The lane then degrades to
#              the emitted-object STRUCTURAL facts the two routes must
#              share and reports the SKIP-EXEC status EXPLICITLY:
#                - the per-function AbiCallPlan signatures (the ONE
#                  classify_call_plan authority — dumped by
#                  `compile --dump-abi-plans` on each spelling and
#                  compared line-set against line-set), and
#                - the corpus program's defined function symbols (`nm`
#                  over both --emit-obj artifacts: every top-level
#                  `def <name>` of the source must appear in BOTH
#                  objects; the per-route runtime symbol sets are
#                  route-internal and are reported only, never compared
#                  as a parity fact).
#              A sub-check whose surface is unavailable (no `nm`; a
#              compiler without --dump-abi-plans) is reported as
#              SKIP(<sub-check>) — never silently treated as a match.
#              Execution is never claimed in this mode.
#
#   LIR-GAP    the LIR compile failed while the direct compile succeeded:
#              a route-parity gap (the precise first error line is
#              reported). Counted as a FAILURE — the differential corpus
#              is the parity criterion, not a gap catalogue.
#
#   DIVERGE    both compiled, but the executed behavior or the structural
#              facts differ. Counted as a FAILURE.
#
#   COMPILE-FAIL  the direct (or both) compiles failed: a corpus/lane
#              problem, counted as a FAILURE.
#
# Corpus (the contract's feature list — aggregates/enums, floats,
# atomics, statics, control flow, calls/args/returns, tail calls):
#   - existing positive fixtures: tests/exit_code_test.tg (calls/returns,
#     exit 42), tests/fib_test.tg (recursion/control flow), tests/
#     struct_basic_test.tg (plain-struct aggregate, exit 42), tests/
#     hello.tg and tests/retval_test.tg (stdout literals + exit code);
#   - generated behavior fixtures (written into the scratch dir): tagged
#     (payloaded) enum crossings, a niched (pointer-payload) enum, float
#     arithmetic/compare, the AtomicInt load/store/exchange surface, a
#     read-only static + const, nested-loop/break/continue control flow,
#     a 10-parameter call (two stack words on aarch64) + a 9-float-
#     parameter call (one float stack slot), a by-address 24-byte struct
#     return/argument, and an accumulator tail call compiled at -O2 (so
#     the tail-call pass runs on both routes).
#
# The lane also carries the aarch64-unknown-none LIR artifact rows
# (structural only — the bare-metal image is never executed here):
#   - `--target aarch64-unknown-none --codegen=lir --emit-obj` emits an
#     ELF64 AArch64 relocatable object (magic, class, e_machine, the
#     spec/linker/startup artifacts beside it);
#   - the direct default spelling still emits a non-zero-entry bare ELF
#     image (the regression row for the route's own default);
#   - `--coverage` on the bare-metal image FAILS CLOSED with the precise
#     rule (the exit-time dump is a host OS file surface).
#
# Usage: tests/run_differential_corpus_tests.sh [compiler-binary] [scratch-dir]
#   compiler-binary defaults to build/tg_stage2
#   scratch-dir     defaults to build/.differential_corpus
# Env: TG_DIFF_FORCE_STRUCTURAL=1 forces SKIP-EXEC structural comparison
#      for every host case (exercises the degradation path without
#      pretending execution ran).
# Exits 0 when every case MATCHes (or degrades with an explicit SKIP-EXEC
# status); 1 on any route gap, divergence or compile failure.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/bootstrap_helpers.sh
source "$ROOT/scripts/bootstrap_helpers.sh"

COMPILER="${1:-$ROOT/build/tg_stage2}"
SCRATCH="${2:-$ROOT/build/.differential_corpus}"

if [ ! -x "$COMPILER" ]; then
  bh_err "differential corpus: compiler binary not executable: $COMPILER"
  exit 1
fi

mkdir -p "$SCRATCH"

# ── the driver invocation helpers ───────────────────────────────────────
# compile_route <route> <file> <out> <log> [extra args...]
# The route spellings: "lir" (--codegen=lir), "direct" (--codegen=direct).
# Every invocation goes through the `tg compile` subcommand (the lane
# convention — the canary/embedded lanes' shape), never the raw mode.
compile_route() {
  local route="$1" file="$2" out="$3" log="$4"
  shift 4
  local -a cmd=("$COMPILER" compile "$file" "--codegen=$route")
  cmd+=("$@")
  cmd+=(-o "$out")
  "${cmd[@]}" > "$log" 2>&1
}

# compile_route_obj <route> <file> <out> <log> [extra args...]
# The --emit-obj spelling behind the structural comparison.
compile_route_obj() {
  local route="$1" file="$2" out="$3" log="$4"
  shift 4
  local -a cmd=("$COMPILER" compile "$file" "--codegen=$route" --emit-obj)
  cmd+=("$@")
  cmd+=(-o "$out")
  "${cmd[@]}" > "$log" 2>&1
}

# extract_symbols <object> — the object's symbol names (one per line).
# Plain `nm` (BSD/macOS and GNU both print the name in the last column).
extract_symbols() {
  nm "$1" 2>/dev/null | awk 'NF > 0 { print $NF }' | sort -u
}

# program_symbols <source> — the top-level `def <name>(` symbols of the
# corpus source. These are the symbols BOTH routes must define in their
# emitted objects (the shared symbol-set fact); the runtime helpers each
# emitter contributes are route-internal and are reported only.
program_symbols() {
  grep -E '^def [A-Za-z_][A-Za-z0-9_]*\(' "$1" 2>/dev/null \
    | sed -E 's/^def ([A-Za-z_][A-Za-z0-9_]*)\(.*/\1/' | sort -u
}

# has_symbol <symbols-file> <name> — the Mach-O leading underscore is
# normalized (the same host object container is compared on both sides).
has_symbol() {
  grep -qx "$2" "$1" || grep -qx "_$2" "$1"
}

# dump_plans <route> <file> <out> <err> — the per-function AbiCallPlan
# rows (`abi-plan <name> <signature>`), sorted for comparison. Returns
# non-zero when the compiler has no such surface or the dump failed.
dump_plans() {
  local route="$1" file="$2" out="$3" err="$4"
  "$COMPILER" compile "$file" "--codegen=$route" --dump-abi-plans > "$out" 2> "$err" || return 1
  sort "$out" > "$out.sorted" 2>/dev/null || return 1
  mv "$out.sorted" "$out"
  [ -s "$out" ] || return 1
}

# can_execute <path> — an executable artifact we may run.
can_execute() {
  [ -x "$1" ] && [ -s "$1" ]
}

# looks_like_exec_format_failure <stderr> — the shell could not exec the
# artifact (a cross-host image): the degradation trigger.
looks_like_exec_format_failure() {
  grep -Eqi "cannot execute|bad cpu type|exec format error" "$1"
}

# ── capability probe ────────────────────────────────────────────────────
PROBE="$SCRATCH/route_probe.tg"
cat > "$PROBE" <<'EOF'
def main() -> Int
  0
end
EOF

if ! compile_route lir "$PROBE" "$SCRATCH/route_probe.lir" "$SCRATCH/route_probe.lir.log"; then
  echo "differential corpus: SKIP — the compiler cannot serve the LIR route probe (a pre-ladder or pre-flip compiler; see $SCRATCH/route_probe.lir.log)"
  exit 0
fi
if ! compile_route direct "$PROBE" "$SCRATCH/route_probe.direct" "$SCRATCH/route_probe.direct.log"; then
  echo "differential corpus: SKIP — the compiler cannot serve the explicit --codegen=direct probe (see $SCRATCH/route_probe.direct.log)"
  exit 0
fi

# ── corpus: existing positives ──────────────────────────────────────────
# name|path|extra-flags
EXISTING_CASES=(
  "exit_code|tests/exit_code_test.tg|"
  "fib|tests/fib_test.tg|"
  "struct_basic|tests/struct_basic_test.tg|"
  "hello|tests/hello.tg|"
  "retval|tests/retval_test.tg|"
)

# ── corpus: generated behavior fixtures ─────────────────────────────────
write_fixture() {
  local file="$1"
  cat > "$file"
}

# Tagged (payloaded) enum: the canonical TaggedPtr value word crossing.
write_fixture "$SCRATCH/diff_enum_tagged.tg" <<'EOF'
enum Shape
  Circle(Int)
  Square(Int)
end

def area(s: Shape) -> Int
  match s
  when Circle(r) => r * r
  when Square(w) => w * w
  end
end

def main() -> Int
  let a = area(Shape::Circle(3))
  let b = area(Shape::Square(4))
  if a == 9 && b == 16 then
    0
  else
    1
  end
end
EOF

# Niched enum: a two-variant enum whose single payload is a pointer word
# (the PointerNull niche — ONE payload word, no tag).
write_fixture "$SCRATCH/diff_enum_niched.tg" <<'EOF'
enum MaybePtr
  Missing
  Present(Ptr[Int])
end

def read_or(m: MaybePtr, fallback: Int) -> Int
  match m
  when Present(p) => (p as Int) + 1
  when Missing => fallback
  end
end

def main() -> Int
  let p = 40 as Ptr[Int]
  let a = read_or(MaybePtr::Present(p), 0)
  let b = read_or(MaybePtr::Missing, 2)
  if a == 41 && b == 2 then
    0
  else
    1
  end
end
EOF

# Floats: arithmetic, comparison, call/return crossings.
write_fixture "$SCRATCH/diff_floats.tg" <<'EOF'
def scale(x: Float) -> Float
  x * 2.0 + 1.0
end

def mix(a: Float, b: Float) -> Float
  scale(a) - scale(b)
end

def main() -> Int
  let a = scale(1.5)
  let b = scale(0.25)
  let c = mix(1.5, 0.25)
  if a == 4.0 && b == 1.5 && c == 2.5 then
    0
  else
    1
  end
end
EOF

# Atomics: the AtomicInt load/store/exchange surface (the inline
# __intrinsic_atomic_* lowering on both routes).
write_fixture "$SCRATCH/diff_atomics.tg" <<'EOF'
use std::atomic::{AtomicInt, Ordering}

def main() -> Int
  var a = AtomicInt::new(0)
  a.store(5, Ordering::Release)
  let old = a.exchange(7, Ordering::AcqRel)
  let v = a.load(Ordering::Acquire)
  if old == 5 && v == 7 then
    0
  else
    1
  end
end
EOF

# Statics: a read-only static + a const, read from a function.
write_fixture "$SCRATCH/diff_statics.tg" <<'EOF'
const BASE: Int = 40
static LIMIT: Int = 2

def total() -> Int
  BASE + LIMIT
end

def main() -> Int
  if total() == 42 then
    0
  else
    1
  end
end
EOF

# Control flow: nested loops, break/continue, early return, if/elsif.
write_fixture "$SCRATCH/diff_control_flow.tg" <<'EOF'
def first_cell(target: Int) -> Int
  var j = 0
  while j < 6 do
    var k = 0
    while k < 6 do
      if j * k == target then
        return j
      end
      k = k + 1
    end
    j = j + 1
  end
  0 - 1
end

def odd_sum(limit: Int) -> Int
  var total = 0
  var i = 0
  while i < limit do
    i = i + 1
    if i % 2 == 0 then
      continue
    end
    total = total + i
  end
  total
end

def main() -> Int
  let cell = first_cell(6)
  let sum = odd_sum(10)
  if cell == 2 && sum == 25 then
    0
  else
    1
  end
end
EOF

# Calls/args/returns: a 10-parameter integer call (two stack words on the
# aarch64 caller stream) and a 9-parameter float call (one float stack
# slot beyond d0..d7).
write_fixture "$SCRATCH/diff_calls_abi.tg" <<'EOF'
def sum10(a: Int, b: Int, c: Int, d: Int, e: Int, f: Int, g: Int, h: Int, i: Int, j: Int) -> Int
  a + b + c + d + e + f + g + h + i + j
end

def fsum9(a: Float, b: Float, c: Float, d: Float, e: Float, f: Float, g: Float, h: Float, i: Float) -> Float
  a + b + c + d + e + f + g + h + i
end

def main() -> Int
  let s = sum10(1, 2, 3, 4, 5, 6, 7, 8, 9, 10)
  let fs = fsum9(0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.5)
  if s == 55 && fs == 4.5 then
    0
  else
    1
  end
end
EOF

# Whole-image aggregate: a 24-byte plain struct crossing by address
# (sret return + by-address argument) and a whole copy.
write_fixture "$SCRATCH/diff_aggregate_triple.tg" <<'EOF'
struct Triple
  a: Int
  b: Int
  c: Int
end

def make_triple(x: Int) -> Triple
  Triple { a: x, b: x + 1, c: x + 2 }
end

def total(t: Triple) -> Int
  t.a + t.b + t.c
end

def main() -> Int
  let t = make_triple(5)
  let u = t
  if total(u) == 18 then
    0
  else
    1
  end
end
EOF

# Tail calls: an accumulator self-recursion compiled at -O2 so the
# tail-call recognition/emission path runs on both routes.
write_fixture "$SCRATCH/diff_tail_calls.tg" <<'EOF'
def count(n: Int, acc: Int) -> Int
  if n == 0 then
    acc
  else
    count(n - 1, acc + n)
  end
end

def main() -> Int
  let r = count(10000, 0)
  if r == 50005000 then
    0
  else
    1
  end
end
EOF

# ── corpus: the generated case table ────────────────────────────────────
# name|path|extra-flags
GENERATED_CASES=(
  "enum_tagged|$SCRATCH/diff_enum_tagged.tg|"
  "enum_niched|$SCRATCH/diff_enum_niched.tg|"
  "floats|$SCRATCH/diff_floats.tg|"
  "atomics|$SCRATCH/diff_atomics.tg|"
  "statics|$SCRATCH/diff_statics.tg|"
  "control_flow|$SCRATCH/diff_control_flow.tg|"
  "calls_abi|$SCRATCH/diff_calls_abi.tg|"
  "aggregate_triple|$SCRATCH/diff_aggregate_triple.tg|"
  "tail_calls|$SCRATCH/diff_tail_calls.tg|-O2"
)

# ── the per-case runner ─────────────────────────────────────────────────
MATCH_N=0
SKIP_N=0
GAP_N=0
DIVERGE_N=0
CFAIL_N=0

# run_case <name> <file> <extra>
run_case() {
  local name="$1" file="$2" extra="$3"
  local lir_bin="$SCRATCH/$name.lir"
  local direct_bin="$SCRATCH/$name.direct"
  local lir_log="$SCRATCH/$name.lir.compile.log"
  local direct_log="$SCRATCH/$name.direct.compile.log"
  rm -f "$lir_bin" "$direct_bin" "$lir_log" "$direct_log"

  # shellcheck disable=SC2086
  if compile_route lir "$file" "$lir_bin" "$lir_log" $extra; then
    local lir_ok=1
  else
    local lir_ok=0
  fi
  # shellcheck disable=SC2086
  if compile_route direct "$file" "$direct_bin" "$direct_log" $extra; then
    local direct_ok=1
  else
    local direct_ok=0
  fi

  if [ "$lir_ok" -eq 0 ] && [ "$direct_ok" -eq 1 ]; then
    bh_err "differential corpus: LIR-GAP  $name — the LIR route refused a program the direct route compiles"
    bh_err "  $(head -n2 "$lir_log" | tr '\n' ' ')"
    GAP_N=$((GAP_N + 1))
    return
  fi
  if [ "$direct_ok" -eq 0 ]; then
    if [ "$lir_ok" -eq 0 ]; then
      bh_err "differential corpus: COMPILE-FAIL  $name — both routes failed to compile"
      bh_err "  direct: $(head -n2 "$direct_log" | tr '\n' ' ')"
    else
      bh_err "differential corpus: COMPILE-FAIL  $name — the direct route failed to compile"
      bh_err "  $(head -n2 "$direct_log" | tr '\n' ' ')"
    fi
    CFAIL_N=$((CFAIL_N + 1))
    return
  fi

  chmod +x "$lir_bin" "$direct_bin" 2>/dev/null || true

  local structural=0
  if [ "${TG_DIFF_FORCE_STRUCTURAL:-0}" = "1" ]; then
    structural=1
  fi
  if ! can_execute "$lir_bin" || ! can_execute "$direct_bin"; then
    structural=1
  fi

  if [ "$structural" -eq 0 ]; then
    local lir_rc direct_rc
    if "$lir_bin" > "$SCRATCH/$name.lir.stdout" 2> "$SCRATCH/$name.lir.stderr"; then
      lir_rc=0
    else
      lir_rc=$?
    fi
    if "$direct_bin" > "$SCRATCH/$name.direct.stdout" 2> "$SCRATCH/$name.direct.stderr"; then
      direct_rc=0
    else
      direct_rc=$?
    fi
    if [ "$lir_rc" -eq 126 ] && looks_like_exec_format_failure "$SCRATCH/$name.lir.stderr"; then
      structural=1
    elif [ "$direct_rc" -eq 126 ] && looks_like_exec_format_failure "$SCRATCH/$name.direct.stderr"; then
      structural=1
    else
      if [ "$lir_rc" -ne "$direct_rc" ]; then
        bh_err "differential corpus: DIVERGE  $name — exit codes differ (lir=$lir_rc direct=$direct_rc)"
        DIVERGE_N=$((DIVERGE_N + 1))
        return
      fi
      if ! cmp -s "$SCRATCH/$name.lir.stdout" "$SCRATCH/$name.direct.stdout"; then
        bh_err "differential corpus: DIVERGE  $name — stdout differs (exit codes both $lir_rc)"
        DIVERGE_N=$((DIVERGE_N + 1))
        return
      fi
      bh_log "differential corpus: MATCH    $name — exit $lir_rc, stdout identical"
      MATCH_N=$((MATCH_N + 1))
      return
    fi
  fi

  # — SKIP-EXEC: structural facts only. Execution is NOT claimed. —
  local lir_obj="$SCRATCH/$name.lir.o"
  local direct_obj="$SCRATCH/$name.direct.o"
  local lir_obj_log="$SCRATCH/$name.lir.obj.log"
  local direct_obj_log="$SCRATCH/$name.direct.obj.log"
  # shellcheck disable=SC2086
  if ! compile_route_obj lir "$file" "$lir_obj" "$lir_obj_log" $extra; then
    bh_log "differential corpus: SKIP-EXEC $name — execution unavailable and the LIR --emit-obj artifact is unavailable; no parity claim"
    SKIP_N=$((SKIP_N + 1))
    return
  fi
  # shellcheck disable=SC2086
  if ! compile_route_obj direct "$file" "$direct_obj" "$direct_obj_log" $extra; then
    bh_log "differential corpus: SKIP-EXEC $name — execution unavailable and the direct --emit-obj artifact is unavailable; no parity claim"
    SKIP_N=$((SKIP_N + 1))
    return
  fi

  local notes=""
  local facts_fail=0

  if command -v nm >/dev/null 2>&1; then
    extract_symbols "$lir_obj" > "$SCRATCH/$name.lir.syms"
    extract_symbols "$direct_obj" > "$SCRATCH/$name.direct.syms"
    program_symbols "$file" > "$SCRATCH/$name.program.syms"
    local missing=""
    while IFS= read -r sym; do
      [ -n "$sym" ] || continue
      if ! has_symbol "$SCRATCH/$name.lir.syms" "$sym"; then
        missing="$missing $sym(lir)"
      fi
      if ! has_symbol "$SCRATCH/$name.direct.syms" "$sym"; then
        missing="$missing $sym(direct)"
      fi
    done < "$SCRATCH/$name.program.syms"
    if [ -n "$missing" ]; then
      bh_err "differential corpus: DIVERGE  $name — SKIP-EXEC program symbols missing from an emitted object:$missing"
      notes="$notes symbols:MISMATCH"
      facts_fail=1
    else
      notes="$notes symbols:MATCH(program)"
      if ! cmp -s "$SCRATCH/$name.lir.syms" "$SCRATCH/$name.direct.syms"; then
        notes="$notes(runtime-symbol-sets-differ)"
      fi
    fi
  else
    notes="$notes symbols:SKIP(no-nm)"
  fi

  if dump_plans lir "$file" "$SCRATCH/$name.lir.plans" "$SCRATCH/$name.lir.plans.err"; then
    if dump_plans direct "$file" "$SCRATCH/$name.direct.plans" "$SCRATCH/$name.direct.plans.err"; then
      if cmp -s "$SCRATCH/$name.lir.plans" "$SCRATCH/$name.direct.plans"; then
        notes="$notes abi-plans:MATCH"
      else
        bh_err "differential corpus: DIVERGE  $name — SKIP-EXEC per-function AbiCallPlans differ"
        notes="$notes abi-plans:MISMATCH"
        facts_fail=1
      fi
    else
      notes="$notes abi-plans:SKIP(direct-dump-unavailable)"
    fi
  else
    notes="$notes abi-plans:SKIP(dump-surface-unavailable)"
  fi

  if [ "$facts_fail" -ne 0 ]; then
    DIVERGE_N=$((DIVERGE_N + 1))
  else
    bh_log "differential corpus: SKIP-EXEC $name — execution unavailable; structural facts:$notes (execution NOT claimed)"
    SKIP_N=$((SKIP_N + 1))
  fi
}

for row in "${EXISTING_CASES[@]}"; do
  name="${row%%|*}"
  rest="${row#*|}"
  file="${rest%%|*}"
  extra="${rest#*|}"
  if [ ! -f "$file" ]; then
    bh_err "differential corpus: corpus file missing: $file (manifest parity broken)"
    CFAIL_N=$((CFAIL_N + 1))
    continue
  fi
  run_case "$name" "$file" "$extra"
done

for row in "${GENERATED_CASES[@]}"; do
  name="${row%%|*}"
  rest="${row#*|}"
  file="${rest%%|*}"
  extra="${rest#*|}"
  run_case "$name" "$file" "$extra"
done

# ── the aarch64-unknown-none LIR artifact rows (structural only) ────────
echo "differential corpus: == the aarch64-unknown-none LIR artifact rows (structural) =="

NONE_PROBE="$SCRATCH/aarch64_none_probe.tg"
cat > "$NONE_PROBE" <<'EOF'
@no_std
use std::core::{Unit, Bool, Int, UInt}

def _reset_handler() -> !
  loop { }
end
EOF

NONE_TRIPLE="aarch64-unknown-none"
NONE_OBJ="$SCRATCH/aarch64_none_lir.o"
NONE_OBJ_LOG="$SCRATCH/aarch64_none_lir.log"
rm -f "$NONE_OBJ"
rm -rf "$NONE_OBJ.d"
if "$COMPILER" compile "$NONE_PROBE" --target "$NONE_TRIPLE" --codegen=lir --emit-obj -o "$NONE_OBJ" > "$NONE_OBJ_LOG" 2>&1; then
  if [ ! -s "$NONE_OBJ" ]; then
    bh_err "differential corpus: aarch64-none LIR object row FAILED — the object is missing"
    CFAIL_N=$((CFAIL_N + 1))
  else
    MAGIC="$(od -A n -t x1 -N 4 "$NONE_OBJ" | tr -d ' \n')"
    CLASS="$(od -A n -t x1 -j 4 -N 1 "$NONE_OBJ" | tr -d ' \n')"
    MACHINE="$(od -A n -t x1 -j 18 -N 2 "$NONE_OBJ" | tr -d ' \n')"
    if [ "$MAGIC" != "7f454c46" ]; then
      bh_err "differential corpus: aarch64-none LIR object row FAILED — no ELF magic (got $MAGIC)"
      CFAIL_N=$((CFAIL_N + 1))
    elif [ "$CLASS" != "02" ]; then
      bh_err "differential corpus: aarch64-none LIR object row FAILED — ELF class $CLASS (expected 02 = ELF64)"
      CFAIL_N=$((CFAIL_N + 1))
    elif [ "$MACHINE" != "b700" ]; then
      bh_err "differential corpus: aarch64-none LIR object row FAILED — e_machine $MACHINE (expected b700 = AArch64)"
      CFAIL_N=$((CFAIL_N + 1))
    else
      NONE_FACTS="ELF64/AArch64 object"
      if command -v nm >/dev/null 2>&1; then
        if nm "$NONE_OBJ" 2>/dev/null | awk 'NF > 0 { print $NF }' | grep -qx "_reset_handler"; then
          NONE_FACTS="$NONE_FACTS + _reset_handler symbol"
        else
          bh_err "differential corpus: aarch64-none LIR object row FAILED — the _reset_handler symbol is missing"
          CFAIL_N=$((CFAIL_N + 1))
        fi
      else
        NONE_FACTS="$NONE_FACTS + (nm unavailable: symbol sub-check SKIPPED)"
      fi
      if [ -f "$NONE_OBJ.d/$NONE_TRIPLE.json" ] && [ -f "$NONE_OBJ.d/$NONE_TRIPLE.ld" ] && [ -f "$NONE_OBJ.d/startup.tg" ]; then
        NONE_FACTS="$NONE_FACTS + spec/ld/startup artifacts"
      else
        bh_err "differential corpus: aarch64-none LIR object row FAILED — the spec/linker/startup artifacts are missing (expected under $NONE_OBJ.d)"
        CFAIL_N=$((CFAIL_N + 1))
      fi
      bh_log "differential corpus: aarch64-none LIR object row OK — $NONE_FACTS"
    fi
  fi
else
  if grep -Eq "Unknown option: --codegen|Unknown codegen route" "$NONE_OBJ_LOG"; then
    bh_log "differential corpus: SKIP aarch64-none LIR object row — the compiler predates the aarch64 LIR arm (see $NONE_OBJ_LOG)"
    SKIP_N=$((SKIP_N + 1))
  else
    bh_err "differential corpus: aarch64-none LIR object row FAILED — the compile failed"
    bh_err "  $(head -n2 "$NONE_OBJ_LOG" | tr '\n' ' ')"
    CFAIL_N=$((CFAIL_N + 1))
  fi
fi

# The direct default spelling regression row: the bare-metal ELF image
# with a non-zero entry still comes out of the direct startup backend.
NONE_DIRECT="$SCRATCH/aarch64_none_direct"
NONE_DIRECT_LOG="$SCRATCH/aarch64_none_direct.log"
rm -f "$NONE_DIRECT.elf"
rm -rf "$NONE_DIRECT.d"
if "$COMPILER" compile "$NONE_PROBE" --target "$NONE_TRIPLE" --codegen=direct -o "$NONE_DIRECT" > "$NONE_DIRECT_LOG" 2>&1; then
  NONE_ELF="$NONE_DIRECT.elf"
  if [ ! -s "$NONE_ELF" ]; then
    bh_err "differential corpus: aarch64-none direct row FAILED — the bare-metal image is missing"
    CFAIL_N=$((CFAIL_N + 1))
  else
    MAGIC="$(od -A n -t x1 -N 4 "$NONE_ELF" | tr -d ' \n')"
    ENTRY="$(od -A n -t x8 -j 24 -N 8 "$NONE_ELF" | tr -d ' \n')"
    if [ "$MAGIC" != "7f454c46" ] || [ "$ENTRY" = "0000000000000000" ]; then
      bh_err "differential corpus: aarch64-none direct row FAILED — ELF magic=$MAGIC entry=$ENTRY"
      CFAIL_N=$((CFAIL_N + 1))
    else
      bh_log "differential corpus: aarch64-none direct row OK — bare ELF image (entry $ENTRY)"
    fi
  fi
else
  bh_err "differential corpus: aarch64-none direct row FAILED — the compile failed"
  bh_err "  $(head -n2 "$NONE_DIRECT_LOG" | tr '\n' ' ')"
  CFAIL_N=$((CFAIL_N + 1))
fi

# The coverage fail-closed row: --coverage on the bare-metal image must
# fail with the precise bare-metal rule (the exit-time dump is a host OS
# file surface), never be silently dropped.
NONE_COV_LOG="$SCRATCH/aarch64_none_coverage.log"
rm -f "$SCRATCH/aarch64_none_coverage.elf"
rm -rf "$SCRATCH/aarch64_none_coverage.d"
if "$COMPILER" compile "$NONE_PROBE" --target "$NONE_TRIPLE" --codegen=lir --coverage -o "$SCRATCH/aarch64_none_coverage" > "$NONE_COV_LOG" 2>&1; then
  bh_err "differential corpus: aarch64-none coverage row FAILED — --coverage compiled on the bare-metal image (must fail closed)"
  CFAIL_N=$((CFAIL_N + 1))
else
  if grep -q "bare-metal" "$NONE_COV_LOG" && grep -q "_tg_cov_dump" "$NONE_COV_LOG"; then
    bh_log "differential corpus: aarch64-none coverage row OK — --coverage fails closed with the bare-metal dump rule"
  else
    bh_err "differential corpus: aarch64-none coverage row FAILED — the refusal lacks the bare-metal rule"
    bh_err "  $(head -n2 "$NONE_COV_LOG" | tr '\n' ' ')"
    CFAIL_N=$((CFAIL_N + 1))
  fi
fi

# ── summary ─────────────────────────────────────────────────────────────
echo "differential corpus: $MATCH_N MATCH, $SKIP_N SKIP-EXEC (structural facts only), $GAP_N LIR-GAP, $DIVERGE_N DIVERGE, $CFAIL_N COMPILE-FAIL"
if [ "$SKIP_N" -gt 0 ]; then
  echo "differential corpus: NOTE — $SKIP_N case(s) skipped execution and carry NO behavioral-parity claim"
fi
if [ "$GAP_N" -ne 0 ] || [ "$DIVERGE_N" -ne 0 ] || [ "$CFAIL_N" -ne 0 ]; then
  bh_err "differential corpus: FAILED — route parity is not established"
  exit 1
fi
bh_log "differential corpus: PASS — the default LIR route and the explicit --codegen=direct fallback MATCH on the corpus"
exit 0
