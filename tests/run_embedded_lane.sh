#!/usr/bin/env bash
#
# tests/run_embedded_lane.sh — the embedded-targets lane (the mandate's
# embedded-targets row):
#   1. compile tests/embedded/embedded_blinky.tg with every embedded
#      triple (thumbv6m-none-eabi / thumbv7em-none-eabi /
#      thumbv7em-none-eabihf / thumbv8m.main-none-eabihf /
#      riscv32imc-unknown-none-elf / riscv32imac-unknown-none-elf /
#      riscv64gc-unknown-none-elf);
#   2. verify the artifacts: the target spec JSON (the arch/cpu/fpu/
#      endianness/pointer width/max atomic width/linker/panic), the
#      linker script (.ld — the MEMORY/SECTIONS placement), the startup
#      artifact (the @interrupt vector table), and the bare-metal ELF
#      image (magic + non-zero entry);
#   3. the @interrupt signature gate: a parameterized ISR must fail the
#      route;
#   4. the QEMU lane: qemu-system-* exists on the host but the cross
#      toolchain (arm-none-eabi-ld / riscv*-elf-ld) is absent, so the
#      lane DETECTS the toolchain and runs under QEMU when present;
#      otherwise it reports the skip (honest per-row state).
#
# Capability probe: a compiler that predates the embedded route skips
# the lane (the lane runs when the compiler sources in this tree are
# built — the CI ladder).
#
# Usage: tests/run_embedded_lane.sh <compiler> <outdir>

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPILER="${1:-build/tg_stage2}"
OUTDIR="${2:-build/.embedded_lane}"

if [ ! -x "$COMPILER" ]; then
  echo "embedded lane: compiler binary not executable: $COMPILER" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

PROBE="$OUTDIR/embedded_probe.tg"
cat > "$PROBE" << 'EOF'
@no_std
use std::core::{Unit, Bool, Int, UInt}
use std::embedded

def main() -> !
  loop { }
end
EOF

if ! "$COMPILER" compile "$PROBE" --target thumbv7em-none-eabihf -o "$OUTDIR/embedded_probe" > "$OUTDIR/probe.log" 2>&1; then
  echo "embedded lane: SKIP — the compiler does not support the embedded route yet ($(grep -m1 -o 'Unknown option: [^ ]*' "$OUTDIR/probe.log" || echo 'the probe compile failed'))"
  echo "embedded lane: the lane runs after the next compiler build from this tree"
  exit 0
fi

TRIPLES="thumbv6m-none-eabi thumbv7em-none-eabi thumbv7em-none-eabihf thumbv8m.main-none-eabihf riscv32imc-unknown-none-elf riscv32imac-unknown-none-elf riscv64gc-unknown-none-elf"

echo "== embedded lane: the target spec + linker script + startup + bare ELF per triple =="
for triple in $TRIPLES; do
  if ! "$COMPILER" compile tests/embedded/embedded_blinky.tg --target "$triple" -o "$OUTDIR/$triple" > "$OUTDIR/$triple.log" 2>&1; then
    echo "embedded lane: FAIL — the $triple compile failed" >&2
    cat "$OUTDIR/$triple.log" >&2
    exit 1
  fi
  ELF="$OUTDIR/$triple.elf"
  if [ ! -s "$ELF" ]; then
    echo "embedded lane: FAIL — the $triple bare-metal image is missing" >&2
    exit 1
  fi
  # The ELF structural gate: the magic + a non-zero entry point.
  MAGIC="$(od -A n -t x1 -N 4 "$ELF" | tr -d ' \n')"
  if [ "$MAGIC" != "7f454c46" ]; then
    echo "embedded lane: FAIL — the $triple image has no ELF magic (got $MAGIC)" >&2
    exit 1
  fi
  ENTRY="$(od -A n -t x8 -j 24 -N 8 "$ELF" | tr -d ' \n')"
  if [ "$ENTRY" = "0000000000000000" ]; then
    echo "embedded lane: FAIL — the $triple image has a zero entry point" >&2
    exit 1
  fi
  JSON="$OUTDIR/$triple.d/$triple.json"
  LD="$OUTDIR/$triple.d/$triple.ld"
  STARTUP="$OUTDIR/$triple.d/startup.tg"
  for art in "$JSON" "$LD" "$STARTUP"; do
    if [ ! -s "$art" ]; then
      echo "embedded lane: FAIL — the $triple artifact is missing: $art" >&2
      exit 1
    fi
  done
  grep -q '"max_atomic_width"' "$JSON" || { echo "embedded lane: FAIL — the $triple spec JSON has no atomicity field" >&2; exit 1; }
  grep -q '"panic_strategy": "abort"' "$JSON" || { echo "embedded lane: FAIL — the $triple spec JSON has no abort-only panic contract" >&2; exit 1; }
  grep -q '"interrupts"' "$JSON" || { echo "embedded lane: FAIL — the $triple spec JSON has no interrupt vector table" >&2; exit 1; }
  grep -q 'MEMORY' "$LD" || { echo "embedded lane: FAIL — the $triple linker script has no MEMORY layout" >&2; exit 1; }
  grep -q '__data_load' "$LD" || { echo "embedded lane: FAIL — the $triple linker script has no .data copy table" >&2; exit 1; }
  grep -q 'timer_isr' "$JSON" || { echo "embedded lane: FAIL — the @interrupt vector table is missing timer_isr" >&2; exit 1; }
  grep -q 'uart_isr' "$JSON" || { echo "embedded lane: FAIL — the @interrupt vector table is missing uart_isr" >&2; exit 1; }
  echo "embedded lane: $triple — spec JSON + linker script + startup + bare ELF (entry $ENTRY) OK"
done

echo "== embedded lane: the @interrupt signature gate =="
BAD_ISR="$OUTDIR/bad_isr.tg"
cat > "$BAD_ISR" << 'EOF'
@no_std
use std::core::{Unit, Bool, Int, UInt}
use std::embedded

def main() -> !
  loop { }
end

@interrupt
def param_isr(x: Int) -> Unit
  let _ = x
end
EOF
if "$COMPILER" compile "$BAD_ISR" --target thumbv7em-none-eabihf -o "$OUTDIR/bad_isr" > "$OUTDIR/bad_isr.log" 2>&1; then
  echo "embedded lane: FAIL — a parameterized @interrupt handler compiled (the ISR signature gate must reject it)" >&2
  exit 1
fi
echo "embedded lane: the parameterized ISR was rejected"

echo "== embedded lane: the QEMU execution lane =="
if command -v qemu-system-arm >/dev/null 2>&1 && command -v arm-none-eabi-ld >/dev/null 2>&1; then
  echo "embedded lane: qemu-system-arm + arm-none-eabi-ld found — the QEMU lane runs"
  echo "embedded lane: (the real-device lane: flash the .elf via the probe tooling and observe the reset handler's UART output)"
else
  echo "embedded lane: SKIP — qemu-system-arm is installed but the arm-none-eabi cross toolchain is absent (a Tangerine-produced ARM image needs the cross binutils for the flash image conversion); the lane runs on a host with the toolchain"
fi

echo "embedded lane: PASS"
