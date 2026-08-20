#!/usr/bin/env bash
#
# tests/run_target_lane_canaries.sh — Per-target canary lane (CI cross lane).
#
# Builds and executes the positive canary manifest for a target triple:
#   - native lane (default): the resolved bootstrap target, executed directly
#   - cross lane (x86_64 on the aarch64 host): executed under Rosetta
#     (arch -x86_64) when available, else under qemu-x86_64, else the
#     disassembly gate alone
# In EVERY case the emitted object must contain ZERO trap stubs: the gate
# disassembles each binary (otool) and asserts no ud2 (x86-64) / no udf and
# no foreign brk (arm64; the runtime's documented 'brk #0xbeef' vec-push
# sanity trap is the only allowed exception). The x86 ud2 holes are closed —
# the gate exists to make sure they stay closed.
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
