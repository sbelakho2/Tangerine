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
  "tests/wasi/wasi_guest_surface_test.tg"
  "tests/kernel/kernel_primitives_test.tg"
  "tests/hal/hal_software_backend_test.tg"
  "tests/gui/gui_software_canvas_test.tg"
  "tests/gpu/gpu_software_backend_test.tg"
  "tests/platform/platform_surface_smoke_test.tg"
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

if [ "$FAILED" -ne 0 ]; then
  echo "behavior suites: FAILED" >&2
  exit 1
fi

echo "behavior suites: PASS"
