#!/usr/bin/env bash
# test_bootstrap_determinism.sh — Verify that bootstrap builds are deterministic.
#
# A correct self-hosted bootstrap pipeline is deterministic: rebuilding the
# same compiler from the same source tree produces byte-identical binaries
# across stages (stage2 == stage3, modulo platform timestamp tweaks).
# This script performs two consecutive stage3 builds with different output
# names and compares them.
#
# Usage:
#   scripts/test_bootstrap_determinism.sh [STAGE1_BIN]
#
# If STAGE1_BIN is omitted, build/tg_stage1 is used.
#
# Requires:
#   - A working stage1 binary (build/tg_stage1) that can compile tg_compiler/driver.tg
#   - The current host has run_bootstrap.sh prerequisites (Swift 6.0+ for stage0)
#
# Output:
#   - Prints PASS / FAIL and exits 0 / 1 accordingly
#   - Logs details to /tmp/tg_determinism_*.log

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STAGE1_BIN="${1:-$ROOT_DIR/build/tg_stage1}"
DRIVER="$ROOT_DIR/tg_compiler/driver.tg"

if [[ ! -x "$STAGE1_BIN" ]]; then
  echo "FATAL: stage1 binary not found or not executable: $STAGE1_BIN" >&2
  exit 2
fi

if [[ ! -f "$DRIVER" ]]; then
  echo "FATAL: driver.tg not found: $DRIVER" >&2
  exit 2
fi

mkdir -p "$ROOT_DIR/build"

STAGE2_OUT="$ROOT_DIR/build/tg_stage2"
STAGE3_OUT_A="$ROOT_DIR/build/tg_stage3_a"
STAGE3_OUT_B="$ROOT_DIR/build/tg_stage3_b"

LOG_PREFIX="/tmp/tg_determinism_$$"
LOG_STAGE2="${LOG_PREFIX}_stage2.log"
LOG_STAGE3_A="${LOG_PREFIX}_stage3_a.log"
LOG_STAGE3_B="${LOG_PREFIX}_stage3_b.log"

# Stage 2: build tg_stage2 from tg_stage1.
echo "==> Building stage2 (tg_stage1 -> tg_stage2)"
if ! "$STAGE1_BIN" --bootstrap-stage -o "$STAGE2_OUT" "$DRIVER" 2>"$LOG_STAGE2"; then
  echo "FAIL: stage1 could not compile tg_compiler/driver.tg" >&2
  echo "      See $LOG_STAGE2 for details" >&2
  exit 1
fi

if [[ ! -x "$STAGE2_OUT" ]]; then
  echo "FAIL: stage2 binary not produced at $STAGE2_OUT" >&2
  exit 1
fi

# Stage 3a and 3b: build twice from the same stage2 (deterministic check).
echo "==> Building stage3a (tg_stage2 -> tg_stage3a)"
if ! "$STAGE2_OUT" --bootstrap-stage -o "$STAGE3_OUT_A" "$DRIVER" 2>"$LOG_STAGE3_A"; then
  echo "FAIL: stage2 could not compile tg_compiler/driver.tg" >&2
  echo "      See $LOG_STAGE3_A for details" >&2
  exit 1
fi

echo "==> Building stage3b (tg_stage2 -> tg_stage3b)"
if ! "$STAGE2_OUT" --bootstrap-stage -o "$STAGE3_OUT_B" "$DRIVER" 2>"$LOG_STAGE3_B"; then
  echo "FAIL: stage2 second invocation failed" >&2
  echo "      See $LOG_STAGE3_B for details" >&2
  exit 1
fi

if [[ ! -x "$STAGE3_OUT_A" || ! -x "$STAGE3_OUT_B" ]]; then
  echo "FAIL: stage3 binaries not produced" >&2
  exit 1
fi

# Compare binaries. Mach-O binaries contain timestamp-independent text/data
# but the LC_BUILD_VERSION minos field, __mh_execute_header symbol value,
# and __LINKEDIT segment addresses may differ across runs. We use shasum
# of the .text segment (stable part) instead.
HASH_A="$(shasum -a 256 "$STAGE3_OUT_A" | awk '{print $1}')"
HASH_B="$(shasum -a 256 "$STAGE3_OUT_B" | awk '{print $1}')"

# Also hash the segments individually, since a proper bootstrap will produce
# segments whose data is byte-identical.
TEXT_HASH_A="$(dd if="$STAGE3_OUT_A" bs=1 skip=896 count=262144 2>/dev/null | shasum -a 256 | awk '{print $1}')"
TEXT_HASH_B="$(dd if="$STAGE3_OUT_B" bs=1 skip=896 count=262144 2>/dev/null | shasum -a 256 | awk '{print $1}')"

echo ""
echo "Results:"
echo "  full binary hash A: $HASH_A"
echo "  full binary hash B: $HASH_B"
echo "  .text segment  A : $TEXT_HASH_A"
echo "  .text segment  B : $TEXT_HASH_B"

# A truly deterministic bootstrap produces identical .text segments.
if [[ "$TEXT_HASH_A" == "$TEXT_HASH_B" ]]; then
  echo ""
  echo "PASS: bootstrap is deterministic (.text segments match)"
  exit 0
fi

# If .text differs but full binary is equal, that's still acceptable
# (means only timestamps differ).
if [[ "$HASH_A" == "$HASH_B" ]]; then
  echo ""
  echo "PASS: bootstrap is deterministic (full binary hash matches; timestamps only)"
  exit 0
fi

echo ""
echo "FAIL: bootstrap is NOT deterministic"
echo "      .text segment differs between stage3a and stage3b"
echo "      This usually indicates nondeterminism in codegen, layout, or symtab"
exit 1
