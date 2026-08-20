#!/usr/bin/env bash
# tests/run_stdlib_e106_sweep.sh
#
# E106 migration sweep — the stdlib parse-clean gate behind
# docs/current/stdlib_reference.md "Completeness Status".
#
# The E106 first-class-reference migration is COMPLETE: every shipped std
# module parses clean (the 14 kernel modules from
# bootstrap/compiler_kernel.manifest PLUS every remaining std/*.tg file —
# the manifest's std list is the kernel closure, the rest is the migrated
# set). `tg check` on every module MUST succeed with zero E106 diagnostics.
#
# Usage: tests/run_stdlib_e106_sweep.sh [compiler-binary] [scratch-dir]
#   compiler-binary defaults to build/tg_stage2
#   scratch-dir     defaults to build/.stdlib_e106_sweep
# Exits 0 when every shipped std module checks clean and E106-free;
# nonzero otherwise.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/bootstrap_helpers.sh
source "$ROOT/scripts/bootstrap_helpers.sh"

COMPILER="${1:-$ROOT/build/tg_stage2}"
SCRATCH="${2:-$ROOT/build/.stdlib_e106_sweep}"

if [ ! -x "$COMPILER" ]; then
  bh_err "e106 sweep: compiler binary not executable: $COMPILER"
  exit 1
fi

mkdir -p "$SCRATCH"

# The kernel std closure (bootstrap/compiler_kernel.manifest "std:" entries)
# plus every other shipped std module (std/*.tg). The manifest is the
# authority for the kernel list; the remaining modules are the migrated
# non-kernel set. Duplicates are harmless (the loop re-checks).
KERNEL_MODULES="alloc args bench collections core env ffi fmt fs gfx_errors io process taint time"

MANIFEST_STD=""
if [ -f "$ROOT/bootstrap/compiler_kernel.manifest" ]; then
  MANIFEST_STD="$(sed -n 's/^std: \([A-Za-z0-9_]*\)\.tg$/\1/p' "$ROOT/bootstrap/compiler_kernel.manifest" | tr '\n' ' ')"
fi

ALL_MODULES=""
for file in "$ROOT"/std/*.tg; do
  [ -f "$file" ] || continue
  mod="$(basename "$file" .tg)"
  ALL_MODULES="$ALL_MODULES $mod"
done

failures=0
checked=0

for mod in $ALL_MODULES; do
  file="$ROOT/std/$mod.tg"
  if [ ! -f "$file" ]; then
    bh_err "e106 sweep: module file missing: std/$mod.tg"
    failures=$((failures + 1))
    continue
  fi
  if ! "$COMPILER" check "$file" >"$SCRATCH/$mod.out" 2>&1; then
    bh_err "e106 sweep FAILED: std/$mod.tg did not check clean:"
    bh_err "  $(head -n3 "$SCRATCH/$mod.out" | tr '\n' ' ')"
    failures=$((failures + 1))
    continue
  fi
  if grep -q "E106" "$SCRATCH/$mod.out"; then
    bh_err "e106 sweep FAILED: std/$mod.tg produced an E106 diagnostic"
    failures=$((failures + 1))
    continue
  fi
  checked=$((checked + 1))
done

if [ "$failures" -ne 0 ]; then
  bh_err "stdlib E106 sweep FAILED: $failures problem(s), $checked modules verified clean"
  exit 1
fi
bh_log "stdlib E106 sweep OK: all $checked shipped std modules parse clean (kernel closure: ${MANIFEST_STD:-$KERNEL_MODULES})"
exit 0
