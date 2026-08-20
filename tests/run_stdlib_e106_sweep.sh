#!/usr/bin/env bash
# tests/run_stdlib_e106_sweep.sh
#
# E106 migration sweep — the stdlib completeness gate behind
# docs/current/stdlib_reference.md "Completeness Status".
#
# For every module on the E106-pending list (the "Modules not yet
# migrated" table in stdlib_reference.md — the authority; the list below is
# mirrored from it), `tg check` on the module MUST fail with the E106
# first-class-reference hard error. Conversely, the 14 kernel modules
# (bootstrap/compiler_kernel.manifest) must check CLEAN — no E106.
#
# Usage: tests/run_stdlib_e106_sweep.sh [compiler-binary] [scratch-dir]
#   compiler-binary defaults to build/tg_stage2
#   scratch-dir     defaults to build/.stdlib_e106_sweep
# Exits 0 when every pending module is E106-rejected and every kernel
# module is E106-free; nonzero otherwise.
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

# Modules with reference type positions (return types / generic type args)
# that are E106 hard errors under the native parser — mirrored from
# docs/current/stdlib_reference.md "Modules not yet migrated". `alloc` is
# excluded (its only `-> &T` mention is a comment).
PENDING_MODULES="cli web log db http thread term url audio sync crypto atomic input config http2 serde async windows websocket toml gpu_vulkan mmap embedded wasm ui secure_types random compress path opentelemetry debug csv web_server wasm_js validation test tensor sql snapshot semver regex profile postgres platform patch obligations migrate metrics math lsp kernel json image hal graph gpu_metal gfx_gpu geom fuzz fft encoding embed_trace diagnostics device ctx contracts autotune auth audit"

# The 14 kernel std modules (bootstrap/compiler_kernel.manifest) — must be
# E106-free: std/collections.tg keeps 5 record-visit extern signatures with
# Option[&K]/&V RETURNS, but extern declarations parse through the extern
# ABI type parser (parse_extern_abi_type), which is the ONE allowed
# reference position — so even collections must check clean.
KERNEL_MODULES="alloc args bench collections core env ffi fmt fs gfx_errors io process taint time"

failures=0
checked=0

for mod in $PENDING_MODULES; do
  file="$ROOT/std/$mod.tg"
  if [ ! -f "$file" ]; then
    bh_err "e106 sweep: pending module file missing: std/$mod.tg"
    failures=$((failures + 1))
    continue
  fi
  if "$COMPILER" check "$file" >"$SCRATCH/$mod.out" 2>&1; then
    bh_err "e106 sweep FAILED: std/$mod.tg parsed clean (expected the E106 hard error)"
    bh_err "  -- if the module was migrated, remove it from the pending list in docs/current/stdlib_reference.md AND from PENDING_MODULES above"
    failures=$((failures + 1))
    continue
  fi
  if ! grep -q "E106" "$SCRATCH/$mod.out"; then
    bh_err "e106 sweep: std/$mod.tg rejected but no E106 diagnostic found:"
    bh_err "  $(head -n3 "$SCRATCH/$mod.out" | tr '\n' ' ')"
    failures=$((failures + 1))
    continue
  fi
  checked=$((checked + 1))
done

for mod in $KERNEL_MODULES; do
  file="$ROOT/std/$mod.tg"
  if [ ! -f "$file" ]; then
    bh_err "e106 sweep: kernel module file missing: std/$mod.tg"
    failures=$((failures + 1))
    continue
  fi
  if ! "$COMPILER" check "$file" >"$SCRATCH/kernel_$mod.out" 2>&1; then
    bh_err "e106 sweep FAILED: kernel module std/$mod.tg did not check clean:"
    bh_err "  $(head -n3 "$SCRATCH/kernel_$mod.out" | tr '\n' ' ')"
    failures=$((failures + 1))
    continue
  fi
  if grep -q "E106" "$SCRATCH/kernel_$mod.out"; then
    bh_err "e106 sweep FAILED: kernel module std/$mod.tg produced an E106 diagnostic"
    failures=$((failures + 1))
  fi
done

if [ "$failures" -ne 0 ]; then
  bh_err "stdlib E106 sweep FAILED: $failures problem(s), $checked pending modules verified"
  exit 1
fi
bh_log "stdlib E106 sweep OK: $checked pending modules E106-rejected, $KERNEL_MODULES kernel modules clean"
exit 0
