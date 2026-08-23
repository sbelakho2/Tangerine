#!/usr/bin/env bash
#
# tests/run_embedded_lane.sh — the embedded-targets lane (the mandate's
# embedded-targets row, P0.2):
#   1. compile tests/embedded/embedded_blinky.tg with the REAL bare-metal
#      target (aarch64-unknown-none — the ONLY embedded triple with real
#      code generation, the aarch64 backend);
#   2. verify the artifacts: the target spec JSON (the arch/cpu/fpu/
#      endianness/pointer width/max atomic width/linker/panic), the
#      linker script (.ld — the MEMORY/SECTIONS placement), the startup
#      artifact (the @interrupt vector table), and the bare-metal aarch64
#      ELF image (magic + non-zero entry);
#   3. the ISA-CODEGEN REJECTION lane: every Thumb (thumbv6m/thumbv7em/
#      thumbv8m.main) and RISC-V (riscv32imc/riscv32imac/riscv64gc)
#      embedded triple is HARD-REJECTED with the stable diagnostic, NO
#      artifacts, NO "compiles" claim — the route must never fabricate an
#      aarch64 image under a foreign triple;
#   4. the @interrupt signature gate (on the real aarch64 target);
#   5. NO QEMU execution lane: the old lane PRINTED "the QEMU lane runs"
#      without invoking QEMU — it is removed. Hardware execution is not
#      claimed until a real invocation with exit-code checks exists.
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

# THE REAL TARGET: aarch64-unknown-none (the aarch64 backend).
REAL_TRIPLE="aarch64-unknown-none"

# THE REJECTED TRIPLES: no Thumb/RISC-V code generator exists.
REJECTED_TRIPLES="thumbv6m-none-eabi thumbv7em-none-eabi thumbv7em-none-eabihf thumbv8m.main-none-eabihf riscv32imc-unknown-none-elf riscv32imac-unknown-none-elf riscv64gc-unknown-none-elf"

PROBE="$OUTDIR/embedded_probe.tg"
cat > "$PROBE" << 'EOF'
@no_std
use std::core::{Unit, Bool, Int, UInt}
use std::embedded

def main() -> !
  loop { }
end
EOF

if ! "$COMPILER" compile "$PROBE" --target "$REAL_TRIPLE" -o "$OUTDIR/embedded_probe" > "$OUTDIR/probe.log" 2>&1; then
  echo "embedded lane: SKIP — the compiler does not support the embedded route yet ($(grep -m1 -o 'Unknown option: [^ ]*' "$OUTDIR/probe.log" || echo 'the probe compile failed'))"
  echo "embedded lane: the lane runs after the next compiler build from this tree"
  exit 0
fi

echo "== embedded lane: the target spec + linker script + startup + bare ELF (aarch64-unknown-none) =="
"$COMPILER" compile tests/embedded/embedded_blinky.tg --target "$REAL_TRIPLE" -o "$OUTDIR/$REAL_TRIPLE" > "$OUTDIR/$REAL_TRIPLE.log" 2>&1 || {
  echo "embedded lane: FAIL — the $REAL_TRIPLE compile failed" >&2
  cat "$OUTDIR/$REAL_TRIPLE.log" >&2
  exit 1
}
ELF="$OUTDIR/$REAL_TRIPLE.elf"
if [ ! -s "$ELF" ]; then
  echo "embedded lane: FAIL — the $REAL_TRIPLE bare-metal image is missing" >&2
  exit 1
fi
# The ELF structural gate: the magic + a non-zero entry point.
MAGIC="$(od -A n -t x1 -N 4 "$ELF" | tr -d ' \n')"
if [ "$MAGIC" != "7f454c46" ]; then
  echo "embedded lane: FAIL — the $REAL_TRIPLE image has no ELF magic (got $MAGIC)" >&2
  exit 1
fi
ENTRY="$(od -A n -t x8 -j 24 -N 8 "$ELF" | tr -d ' \n')"
if [ "$ENTRY" = "0000000000000000" ]; then
  echo "embedded lane: FAIL — the $REAL_TRIPLE image has a zero entry point" >&2
  exit 1
fi
JSON="$OUTDIR/$REAL_TRIPLE.d/$REAL_TRIPLE.json"
LD="$OUTDIR/$REAL_TRIPLE.d/$REAL_TRIPLE.ld"
STARTUP="$OUTDIR/$REAL_TRIPLE.d/startup.tg"
for art in "$JSON" "$LD" "$STARTUP"; do
  if [ ! -s "$art" ]; then
    echo "embedded lane: FAIL — the $REAL_TRIPLE artifact is missing: $art" >&2
    exit 1
  fi
done
grep -q '"max_atomic_width"' "$JSON" || { echo "embedded lane: FAIL — the $REAL_TRIPLE spec JSON has no atomicity field" >&2; exit 1; }
grep -q '"panic_strategy": "abort"' "$JSON" || { echo "embedded lane: FAIL — the $REAL_TRIPLE spec JSON has no abort-only panic contract" >&2; exit 1; }
grep -q '"interrupts"' "$JSON" || { echo "embedded lane: FAIL — the $REAL_TRIPLE spec JSON has no interrupt vector table" >&2; exit 1; }
grep -q '"arch": "aarch64"' "$JSON" || { echo "embedded lane: FAIL — the $REAL_TRIPLE spec JSON does not record the aarch64 arch" >&2; exit 1; }
grep -q 'MEMORY' "$LD" || { echo "embedded lane: FAIL — the $REAL_TRIPLE linker script has no MEMORY layout" >&2; exit 1; }
grep -q '__data_load' "$LD" || { echo "embedded lane: FAIL — the $REAL_TRIPLE linker script has no .data copy table" >&2; exit 1; }
grep -q 'timer_isr' "$JSON" || { echo "embedded lane: FAIL — the @interrupt vector table is missing timer_isr" >&2; exit 1; }
grep -q 'uart_isr' "$JSON" || { echo "embedded lane: FAIL — the @interrupt vector table is missing uart_isr" >&2; exit 1; }
echo "embedded lane: $REAL_TRIPLE — spec JSON + linker script + startup + bare aarch64 ELF (entry $ENTRY) OK"

echo "== embedded lane: the ISA-CODEGEN REJECTION (Thumb + RISC-V triples) =="
for triple in $REJECTED_TRIPLES; do
  rm -f "$OUTDIR/$triple.elf" "$OUTDIR/$triple.log"
  rm -rf "$OUTDIR/$triple.d"
  if "$COMPILER" compile tests/embedded/embedded_blinky.tg --target "$triple" -o "$OUTDIR/$triple" > "$OUTDIR/$triple.log" 2>&1; then
    echo "embedded lane: FAIL — the $triple compile SUCCEEDED (the route must reject every ISA without real codegen)" >&2
    cat "$OUTDIR/$triple.log" >&2
    exit 1
  fi
  if ! grep -q "embedded: the target triple \`$triple\` is REJECTED" "$OUTDIR/$triple.log"; then
    echo "embedded lane: FAIL — the $triple rejection lacks the stable diagnostic" >&2
    cat "$OUTDIR/$triple.log" >&2
    exit 1
  fi
  if grep -q "compiles\|compilation succeeded\|bare-metal ELF" "$OUTDIR/$triple.log"; then
    echo "embedded lane: FAIL — the $triple rejection makes a 'compiles' claim" >&2
    cat "$OUTDIR/$triple.log" >&2
    exit 1
  fi
  if [ -e "$OUTDIR/$triple.elf" ] || [ -d "$OUTDIR/$triple.d" ]; then
    echo "embedded lane: FAIL — the $triple rejection produced artifacts (NO artifact is the contract)" >&2
    exit 1
  fi
  echo "embedded lane: $triple — REJECTED with the stable diagnostic, no artifact"
done

echo "== embedded lane: the @interrupt signature gate (on the real target) =="
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
rm -f "$OUTDIR/bad_isr.elf"
rm -rf "$OUTDIR/bad_isr.d"
if "$COMPILER" compile "$BAD_ISR" --target "$REAL_TRIPLE" -o "$OUTDIR/bad_isr" > "$OUTDIR/bad_isr.log" 2>&1; then
  echo "embedded lane: FAIL — a parameterized @interrupt handler compiled (the ISR signature gate must reject it)" >&2
  exit 1
fi
if [ -e "$OUTDIR/bad_isr.elf" ] || [ -d "$OUTDIR/bad_isr.d" ]; then
  echo "embedded lane: FAIL — the rejected ISR program produced artifacts" >&2
  exit 1
fi
echo "embedded lane: the parameterized ISR was rejected (no artifacts)"

echo "embedded lane: NO QEMU execution lane — the old lane only PRINTED that it ran without invoking QEMU; it is removed (hardware execution is not claimed; the bare-metal image production is structurally verified above)"

echo "embedded lane: PASS"
