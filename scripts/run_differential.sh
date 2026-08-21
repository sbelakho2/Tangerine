#!/usr/bin/env bash
#
# scripts/run_differential.sh — stage0-vs-stage3 differential parity harness
# driver (reviewer item 6).
#
# The semantic-parity gate for the bootstrap subset:
#   - the corpus lives in tests/differential/ (corpus.manifest + corpus/*.tg
#     + negative/*.tg) and exercises every construct the bootstrap needs;
#   - the comparisons run in the stage0 front end itself
#     (`tg_stage0 diff`), which normalizes both sides' dumps (ids and spans
#     stripped) and compares the canonical token streams and top-level
#     item-kind sequences;
#   - the stage3 side requires a ladder-produced binary that supports the
#     dump hooks (`check --dump-tokens` / `check --dump-ast` — landed in
#     commit a14eeca). The harness PROBES that surface first: a stage3
#     binary that cannot dump makes the run fail with exit 2 — parity is
#     never claimed against a front end that cannot be compared.
#
# Modes:
#   scripts/run_differential.sh                 full differential (probe +
#                                               gates + comparisons)
#   scripts/run_differential.sh --self-check    stage0-side only: corpus
#                                               gates + normalization, no
#                                               stage3 binary required
#   scripts/run_differential.sh --probe         probe the stage3 dump
#                                               surface and exit 0/1
#
# Exit status:
#   0  every compared phase matched and every gate passed
#   1  a divergence or normalization gap
#   2  stage3 probe failure (cannot claim parity)
#   3  a corpus gate failure
#
# Binary resolution: TG_STAGE0_BIN / TG_STAGE3_BIN override the defaults
# (stage0_swift/.build/release/tg_stage0 and build/tg_stage1).
#
# This script performs NO ladder runs: the stage0 binary is a plain Swift
# build product, and the stage3 binary is a ladder artifact consumed
# read-only.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STAGE0_BIN="${TG_STAGE0_BIN:-$ROOT/stage0_swift/.build/release/tg_stage0}"
STAGE3_BIN="${TG_STAGE3_BIN:-$ROOT/build/tg_stage1}"
CORPUS_DIR="$ROOT/tests/differential"

MODE=()
if [ $# -gt 0 ]; then
  MODE=("$@")
fi

if [ ! -x "$STAGE0_BIN" ]; then
  echo "run_differential: stage0 binary not found or not executable: $STAGE0_BIN" >&2
  echo "  (build it with: cd stage0_swift && swift build -c release)" >&2
  exit 2
fi

echo "=== Tangerine differential parity harness ==="
echo "Stage0 (Swift bootstrap): $STAGE0_BIN"
echo "Stage3 (self-host):       $STAGE3_BIN"
echo "Corpus:                   $CORPUS_DIR"
echo ""

BASE_ARGS=(--corpus "$CORPUS_DIR" --stage3-bin "$STAGE3_BIN")
"$STAGE0_BIN" diff "${BASE_ARGS[@]}" "${MODE[@]+"${MODE[@]}"}"
rc=$?

case $rc in
  0) echo "run_differential: ALL MATCH (exit 0)" ;;
  1) echo "run_differential: DIVERGENT or NORMALIZATION-GAP (exit 1)" >&2 ;;
  2) echo "run_differential: stage3 probe failure — rebuild the ladder (exit 2)" >&2 ;;
  3) echo "run_differential: corpus gate failure (exit 3)" >&2 ;;
esac
exit "$rc"
