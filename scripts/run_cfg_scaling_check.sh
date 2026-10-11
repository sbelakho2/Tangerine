#!/usr/bin/env bash
#
# scripts/run_cfg_scaling_check.sh — realized cfg-elimination scaling guard.
#
# Runs synthetic 256/512/1024/2048-item @cfg programs (each with an inline
# nested module) through the REAL kernel in the seed VM and asserts:
#   * exact linear predicate-evaluation growth (3n + 2), and
#   * REALIZED VM-step growth within a generous linear envelope
#     (8x items < 10x steps; each doubling < 3x steps).
#
# This is the realized-work companion to the in-kernel structural
# CFG_SCALING_BATTERY (which only counts predicate evaluations and could
# not catch a hidden quadratic scan that does not increment the counter).
# It is deterministic (VM steps, never wall time) and opt-in: it runs one
# cold kernel-closure pipeline plus four warm VM-only runs (~2-5 minutes
# once the build cache exists), so it is not part of the per-PR lane.
#
# Usage: bash scripts/run_cfg_scaling_check.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2

EXE="$ROOT/stage0_ocaml/_build/default/selfcheck/tg_cfg_scaling.exe"
if [ ! -x "$EXE" ]; then
  echo "run_cfg_scaling_check: building the seed selfchecks..." >&2
  (cd "$ROOT/stage0_ocaml" && dune build) || {
    echo "run_cfg_scaling_check: dune build failed" >&2
    exit 2
  }
fi

"$EXE" "$ROOT"
rc=$?
if [ "$rc" -eq 0 ]; then
  echo "run_cfg_scaling_check: PASS"
else
  echo "run_cfg_scaling_check: FAIL (exit $rc)" >&2
fi
exit "$rc"
