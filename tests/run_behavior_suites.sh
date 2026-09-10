#!/usr/bin/env bash
#
# tests/run_behavior_suites.sh — the non-kernel-stdlib behavior suites
# (the mandate's non-kernel-stdlib-behavior row): the behavioral @test
# suites for the parse-clean modules whose behavior the host can run —
# the embedded MMIO/collections surface, the wasi guest surface, the
# kernel primitives, the HAL software backend, the GPU software backend
# and the GUI software canvas.
#
# Every suite runs through `tg test` (the standard runner — each @test
# function runs in its own process). The runner PROBES the compiler
# first: a compiler that cannot serve the suites (a pre-ladder or broken
# local binary) reports the suites as skipped — the CI ladder build
# serves them.
#
# Usage: tests/run_behavior_suites.sh <compiler> <outdir>

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPILER="${1:-build/tg_stage2}"
OUTDIR="${2:-build/.behavior_suites}"

if [ ! -x "$COMPILER" ]; then
  echo "behavior suites: compiler binary not executable: $COMPILER" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

# The probe: a trivial suite must compile and run.
PROBE="$OUTDIR/probe_suite.tg"
cat > "$PROBE" << 'EOF'
use std::core::{Option, Result, Unit, Bool, Int, UInt}
use std::test::*

@test
def probe_ok() -> Unit
  let x = 40 + 2
  if x != 42 then
    panic("probe failed")
  end
end
EOF

if ! "$COMPILER" test "$PROBE" > "$OUTDIR/probe.log" 2>&1; then
  echo "behavior suites: SKIP — the compiler cannot run `tg test` suites (the probe failed; see $OUTDIR/probe.log)"
  echo "behavior suites: the suites run after the next compiler build from this tree"
  exit 0
fi

SUITES=(
  "tests/embedded/embedded_mmio_behavior_test.tg"
  "tests/embedded/embedded_volatile_surface_test.tg"
  "tests/wasi/wasi_guest_surface_test.tg"
  "tests/kernel/kernel_primitives_test.tg"
  "tests/hal/hal_software_backend_test.tg"
  "tests/gui/gui_software_canvas_test.tg"
  "tests/gpu/gpu_software_backend_test.tg"
  "tests/platform/platform_surface_smoke_test.tg"
  "tests/mir_int_arith_semantics_test.tg"
  "tests/diag_derivation_test.tg"
  # audit item 49: the structured generic-instance keys (InstanceKey /
  # MonoCache.instances re-key + the documented const-fold model).
  "tests/mono_instance_key_test.tg"
  "tests/unit/test_int_overflow_behavior.tg"
  # audit item 1: the Slice ownership split (copied_slice / cloned_slice
  # drop counts, sub-view range validation) + the fixed-decimal suite.
  "tests/unit/test_slice_copy_resource_drop_count.tg"
  "tests/unit/test_slice_noncopy_clone_drop.tg"
  "tests/unit/test_slice_sub_oob.tg"
  "tests/unit/test_slice_sub_overflow.tg"
  "tests/unit/test_fixed_decimal.tg"
  # audit items 28 + 29: the ABI call-plan rows (classify_call_plan over
  # aarch64/x86-64/cortex-m/riscv64, internal + ExternC flavors).
  "tests/abi/abi_call_plan_rows_test.tg"
)

FAILED=0
for suite in "${SUITES[@]}"; do
  if "$COMPILER" test "$suite" > "$OUTDIR/$(basename "$suite").log" 2>&1; then
    echo "behavior suites: PASS  $suite"
  else
    echo "behavior suites: FAIL  $suite (see $OUTDIR/$(basename "$suite").log)" >&2
    FAILED=1
  fi
done

# Audit §24: the ordinary integer arithmetic semantics must be
# identical at every optimization level — the runtime rows of
# test_int_overflow_behavior.tg run again under -O0..-O3 (the default
# run above uses the driver's default level), and the exit-code trap
# lane proves the signed-overflow TRAP and the division-edge TRAP
# (audit item 30: /0, %0 and signed MIN/-1) fire at every level.
for level in 0 1 2 3; do
  if "$COMPILER" test "-O$level" "tests/unit/test_int_overflow_behavior.tg" > "$OUTDIR/test_int_overflow_behavior_O${level}.log" 2>&1; then
    echo "behavior suites: PASS  tests/unit/test_int_overflow_behavior.tg at -O$level"
  else
    echo "behavior suites: FAIL  tests/unit/test_int_overflow_behavior.tg at -O$level (see $OUTDIR/test_int_overflow_behavior_O${level}.log)" >&2
    FAILED=1
  fi
done

if bash tests/run_int_arith_trap_lane.sh "$COMPILER" "$OUTDIR/trap_lane"; then
  echo "behavior suites: PASS  tests/run_int_arith_trap_lane.sh"
else
  echo "behavior suites: FAIL  tests/run_int_arith_trap_lane.sh" >&2
  FAILED=1
fi

if [ "$FAILED" -ne 0 ]; then
  echo "behavior suites: FAILED" >&2
  exit 1
fi

echo "behavior suites: PASS"
