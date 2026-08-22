#!/usr/bin/env bash
#
# tests/run_simd_tests.sh — the SIMD test lane (the mandate's SIMD (e)).
#
# Runs the three committed SIMD suites against the given tg compiler
# binary: the behavior suite (the vector add/shuffle/load-store vs the
# scalar reference), the layout suite (the VECTOR ROW assertions: size =
# N lanes x lane size, alignment = the vector width), and the ABI probe
# (the 16-byte vector through the registers vs the 32/64-byte by-address
# classification).
#
# Usage: tests/run_simd_tests.sh <compiler>
#   <compiler>  the tg compiler binary (a stage/bootstrap binary)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "$#" -lt 1 ]; then
  echo "usage: $0 <compiler>" >&2
  exit 1
fi

COMPILER="$1"

if [ ! -x "$COMPILER" ]; then
  echo "simd tests: compiler binary not executable: $COMPILER" >&2
  exit 1
fi

echo "== simd tests: the behavior suite (the vector ops vs the scalar reference) =="
"$COMPILER" run tests/simd/simd_behavior_test.tg

echo "== simd tests: the layout suite (the vector rows) =="
"$COMPILER" run tests/simd/simd_layout_test.tg

echo "== simd tests: the ABI probe (the register vs memory vector cases) =="
"$COMPILER" run tests/simd/simd_abi_probe.tg

echo "simd tests: PASS"
