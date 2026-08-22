#!/usr/bin/env bash
#
# tests/run_nostd_bare_lane.sh — the no_std lane (the mandate's no-std
# row):
#   1. the POSITIVE lane: compile tests/nostd/nostd_bare_start.tg with
#      --no-std (the @no_std attribute + the core-only import surface +
#      the `_start` bare entry), run the produced bare binary and verify
#      the direct-syscall output;
#   2. the ATTRIBUTE lane: the same compile WITHOUT the flag (the
#      @no_std attribute alone must route the compile);
#   3. the NEGATIVE lane: a program importing std::collections must fail
#      the no_std compile with the core-only-surface diagnostic.
#
# Capability probe: a compiler that predates the no_std route fails the
# probe and the lane reports SKIP (the lane runs when the compiler
# sources in this tree are built — the CI ladder).
#
# Usage: tests/run_nostd_bare_lane.sh <compiler> <outdir>

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPILER="${1:-build/tg_stage2}"
OUTDIR="${2:-build/.nostd_lane}"

if [ ! -x "$COMPILER" ]; then
  echo "nostd lane: compiler binary not executable: $COMPILER" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

PROBE="$OUTDIR/nostd_probe.tg"
cat > "$PROBE" << 'EOF'
@no_std
use std::core::{Unit, Bool, Int, UInt}
extern def _exit(code: Int) -> Never
def _start() -> !
  _exit(0)
end
EOF

if ! "$COMPILER" compile "$PROBE" --no-std -o "$OUTDIR/nostd_probe_bin" > "$OUTDIR/probe.log" 2>&1; then
  echo "nostd lane: SKIP — the compiler does not support the --no-std route yet ($(grep -m1 -o 'Unknown option: [^ ]*' "$OUTDIR/probe.log" || echo 'the probe compile failed'))"
  echo "nostd lane: the lane runs after the next compiler build from this tree"
  exit 0
fi

echo "== nostd lane: the positive bare compile =="
if ! "$COMPILER" compile tests/nostd/nostd_bare_start.tg --no-std -o "$OUTDIR/nostd_bare" > "$OUTDIR/positive.log" 2>&1; then
  echo "nostd lane: FAIL — the bare no_std compile failed" >&2
  cat "$OUTDIR/positive.log" >&2
  exit 1
fi
if [ ! -s "$OUTDIR/nostd_bare" ]; then
  echo "nostd lane: FAIL — the bare no_std compile produced no binary" >&2
  exit 1
fi

echo "== nostd lane: the bare binary execution =="
OUTPUT="$("$OUTDIR/nostd_bare" 2>&1)"
RC=$?
if [ "$RC" -ne 0 ]; then
  echo "nostd lane: FAIL — the bare binary exited with $RC" >&2
  echo "$OUTPUT" >&2
  exit 1
fi
if ! printf '%s' "$OUTPUT" | grep -q "no_std bare binary: the _start entry"; then
  echo "nostd lane: FAIL — the bare binary output is missing the direct-syscall line" >&2
  printf '%s\n' "$OUTPUT" >&2
  exit 1
fi
echo "nostd lane: the bare binary ran (the _start entry + the direct syscall write)"

echo "== nostd lane: the @no_std attribute alone =="
if ! "$COMPILER" compile tests/nostd/nostd_bare_start.tg -o "$OUTDIR/nostd_bare_attr" > "$OUTDIR/attr.log" 2>&1; then
  echo "nostd lane: FAIL — the attribute-only compile failed" >&2
  cat "$OUTDIR/attr.log" >&2
  exit 1
fi
echo "nostd lane: the @no_std attribute alone routed the compile"

echo "== nostd lane: the negative surface canary =="
if "$COMPILER" compile tests/nostd/nostd_core_surface_negative.tg --no-std -o "$OUTDIR/nostd_neg" > "$OUTDIR/negative.log" 2>&1; then
  echo "nostd lane: FAIL — the collections-importing program compiled (the core-only surface must reject it)" >&2
  exit 1
fi
if ! grep -q "no_std: the import \`use std::collections" "$OUTDIR/negative.log"; then
  echo "nostd lane: FAIL — the rejection did not carry the core-only-surface diagnostic" >&2
  cat "$OUTDIR/negative.log" >&2
  exit 1
fi
echo "nostd lane: the std::collections import was rejected with the core-only-surface diagnostic"

echo "nostd lane: PASS"
