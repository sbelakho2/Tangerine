#!/usr/bin/env bash
#
# scripts/check_determinism.sh — Two-clean-directory determinism check
#
# Builds a stage binary twice from two pristine copies of the compiler
# driver and asserts the two builds are byte-identical. This is the
# reproducibility gate: same source + toolchain must produce matching
# checksums.
#
# Usage:
#   scripts/check_determinism.sh <compiler-binary> [<source-file>] [<outdir>]
#
# Example:
#   scripts/check_determinism.sh build/tg_stage2 tg_compiler/driver.tg build

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=bootstrap_helpers.sh
source "$ROOT_DIR/scripts/bootstrap_helpers.sh"

COMPILER="${1:-build/tg_stage2}"
SOURCE_FILE="${2:-tg_compiler/driver.tg}"
OUTDIR="${3:-build}"

if [ ! -x "$COMPILER" ]; then
  bh_err "compiler binary not executable: $COMPILER"
  exit 1
fi
if [ ! -f "$SOURCE_FILE" ]; then
  bh_err "source file missing: $SOURCE_FILE"
  exit 1
fi

# Stage the same source into two independent clean directories.
A_DIR="$OUTDIR/.det_clean_a"
B_DIR="$OUTDIR/.det_clean_b"
rm -rf "$A_DIR" "$B_DIR"
mkdir -p "$A_DIR" "$B_DIR"
cp "$SOURCE_FILE" "$A_DIR/driver.tg"
cp "$SOURCE_FILE" "$B_DIR/driver.tg"

bh_log "determinism: compiler=$COMPILER"
bh_log "determinism: source copies -> $A_DIR and $B_DIR"

if ! check_two_clean_dirs tg_det "$COMPILER" \
      "$A_DIR/driver.tg" "$B_DIR/driver.tg" "$OUTDIR"; then
  bh_err "two-clean-directory determinism check FAILED"
  exit 2
fi

bh_log "determinism OK"
exit 0
