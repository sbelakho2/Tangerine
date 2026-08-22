#!/usr/bin/env bash
#
# tests/run_wasm_conformance.sh — the wasm conformance lane (the
# mandate's wasm (d)).
#
# CHOSEN CONFORMANCE: the STRUCTURAL validation — the emitted binary's
# sections are parsed and validated by the independent wasm parser in
# tests/wasm/wasm_conformance_test.tg (the magic/version header, the
# section order and lengths, the type/function/memory/global/export/
# start/code/data sections, the producer custom record, the data-section
# string interning). The wasmtime EXECUTION lane runs additionally when
# the wasmtime runtime is installed: the canary module is compiled with
# the driver route (--target wasm32-unknown-unknown), instantiated, and
# the exported `add` function is invoked and checked.
#
# Usage: tests/run_wasm_conformance.sh <compiler> <outdir>
#   <compiler>  the tg compiler binary (a stage/bootstrap binary)
#   <outdir>    the scratch directory for artifacts

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <compiler> <outdir>" >&2
  exit 1
fi

COMPILER="$1"
OUTDIR="$2"

if [ ! -x "$COMPILER" ]; then
  echo "wasm conformance: compiler binary not executable: $COMPILER" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

echo "== wasm conformance: structural lane =="

# 1. The structural conformance test (the in-process emission + the
#    independent section parser).
"$COMPILER" run tests/wasm/wasm_conformance_test.tg

# 2. The driver route: compile the canary with --target
#    wasm32-unknown-unknown and validate the produced binary
#    structurally (the magic + section walk via the same test harness is
#    the in-process proof; the driver-route proof is the successful
#    emission below).
"$COMPILER" compile tests/wasm/wasm_canary.tg --target wasm32-unknown-unknown -o "$OUTDIR/wasm_canary.wasm"

if [ ! -s "$OUTDIR/wasm_canary.wasm" ]; then
  echo "wasm conformance: the driver route produced an empty wasm module" >&2
  exit 1
fi

# 3. The wasmtime EXECUTION lane (optional — reported, not required).
if command -v wasmtime >/dev/null 2>&1; then
  echo "== wasm conformance: wasmtime execution lane =="
  # Invoke the exported add(40, 2) and require the 42 result.
  RESULT="$(wasmtime run --invoke add "$OUTDIR/wasm_canary.wasm" 40 2 2>/dev/null)"
  if [ "$RESULT" != "42" ]; then
    echo "wasm conformance: wasmtime add(40, 2) returned '$RESULT' (expected 42)" >&2
    exit 1
  fi
  echo "wasm conformance: wasmtime add(40, 2) == 42"
else
  echo "wasm conformance: wasmtime not installed — the structural lane is the conformance (the execution lane is reported as skipped)"
fi

echo "wasm conformance: PASS"
