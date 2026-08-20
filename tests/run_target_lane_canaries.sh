#!/usr/bin/env bash
#
# tests/run_target_lane_canaries.sh — Per-target canary lane (CI cross lane).
#
# Builds and executes the positive canary manifest for a target triple:
#   - native lane (default): the resolved bootstrap target, executed directly
#   - cross lane (x86_64 on the aarch64 host): executed under Rosetta
#     (arch -x86_64) when available, else under qemu-x86_64, else the
#     disassembly gate alone
# In EVERY case the emitted object is checked by the SYMBOL-AWARE trap-stub
# gate: every trap instruction is attributed to its containing function
# symbol, and only the deliberate abort/panic/unreachable machinery
# (__intrinsic_abort + the std::core panic helpers) is whitelisted. A trap
# in any other symbol — in particular a trap-only implementation or
# OS-fallback trap in the map/set/string/array runtime families — fails the
# gate. The arm64 vec-push sanity trap 'brk #0xbeef' remains allowed.
#
# Usage: tests/run_target_lane_canaries.sh <compiler> <outdir> [triple|arch-alias]
#   triple omitted            -> bh_boot_target (native lane)
#   "x86_64" / "amd64" alias  -> x86_64-apple-darwin (the cross lane)
#   "aarch64" / "arm64" alias -> bh_boot_target (native lane on the bootstrap host)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/bootstrap_helpers.sh
source "$ROOT/scripts/bootstrap_helpers.sh"

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <compiler> <outdir> [triple|arch-alias]" >&2
  exit 1
fi

COMPILER="$1"
OUTDIR="$2"

if [ ! -x "$COMPILER" ]; then
  bh_err "lane: compiler binary not executable: $COMPILER"
  exit 1
fi

run_target_lane_canaries "$COMPILER" "$OUTDIR" "${3:-}"
