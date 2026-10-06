#!/usr/bin/env bash
# run_bootstrap_slices.sh -- seed front-end semantic gate over the
# dependency-closed bootstrap slices.
#
# Generates the slices (scripts/bootstrap_slices.py) and runs
# `bootstrap-check` against each one with a hard timeout, recording the
# PASS/FAIL verdict and a set of stable failure fingerprints per slice:
#
#   build/slices/k<K>.out            raw front-end output
#   build/slices/k<K>.fingerprints   sorted unique failure fingerprints
#
# A missing `FRONTEND_SEMANTIC_GATE = PASS` line is a SEMANTIC failure:
# it is evidence and does not fail this script.  The script exits non-zero
# only when a run is INVALID (hard timeout, missing/empty output, or the
# seed binary could not be executed).
#
# This is an evidence tool, never an authorization: it prints no
# authorization sentinel.  Re-running is safe: every output is rewritten.
#
# Environment:
#   SLICE_SIZES   slice sizes to generate/run (default "10 20 30 40 45")

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SLICE_SIZES="${SLICE_SIZES:-10 20 30 40 45}"
STAGE0="stage0_ocaml/_build/default/bin/tg_stage0.exe"
TARGET="aarch64-apple-darwin"
OUT_DIR="build/slices"
SLICE_TIMEOUT=900

mkdir -p "$OUT_DIR"

collapse_ws() { tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }

# Reduce one diagnostic line to a stable fingerprint:
#   HIR_MISSING|<module>|<function-or-item>|<Node=...>|<detail>  (node id)
#   FRONTEND_FAIL|<module>|<detail-slug>                         (otherwise)
fingerprint_line() {
  local raw="$1" line module node item detail
  line="$(printf '%s' "$raw" | collapse_ws)"
  module="$(printf '%s' "$line" | sed -nE 's/^((std|tg_compiler)::[A-Za-z0-9_]+):.*/\1/p' | head -1)"
  if [ -z "$module" ]; then
    module="$(printf '%s' "$line" | sed -nE 's#.*(std|tg_compiler)/([A-Za-z0-9_]+)\.tg:[0-9]+.*#\1::\2#p' | head -1)"
  fi
  if [ -z "$module" ]; then
    module="$(printf '%s' "$line" | sed -nE 's/.*([A-Za-z0-9_]+)\.tg:[0-9]+.*/\1/p' | head -1)"
  fi
  [ -n "$module" ] || module="unknown"
  node="$(printf '%s' "$line" | grep -oE 'Node=[0-9]+' | head -1 || true)"
  detail="$(printf '%s' "$line" | cut -c1-80)"
  if [ -n "$node" ]; then
    item="$(printf '%s' "$line" | grep -oE '(fn|def|item) [A-Za-z_][A-Za-z0-9_]*' | head -1 || true)"
    item="${item#fn }"
    item="${item#def }"
    item="${item#item }"
    [ -n "$item" ] || item="-"
    printf 'HIR_MISSING|%s|%s|%s|%s\n' "$module" "$item" "$node" "$detail"
  else
    printf 'FRONTEND_FAIL|%s|%s\n' "$module" "$detail"
  fi
}

# Extract every location-like diagnostic from <out>, fingerprint it in
# output order, then store the sorted unique set.  Echoes the fingerprint
# derived from the FIRST diagnostic line (empty when none matched).
extract_fingerprints() { # <out> <k>
  local out="$1" k="$2" ordered="$OUT_DIR/k${k}.fp.ordered" fp="$OUT_DIR/k${k}.fingerprints" raw first
  : > "$ordered"
  { grep -E 'file#|\.tg:[0-9]+|[Ii]nternal error' "$out" || true; } |
    while IFS= read -r raw; do
      fingerprint_line "$raw"
    done > "$ordered"
  first="$(head -1 "$ordered")"
  sort -u "$ordered" > "$fp"
  rm -f "$ordered"
  printf '%s' "$first"
}

echo "run_bootstrap_slices: generating slices: ${SLICE_SIZES}"
if ! python3 scripts/bootstrap_slices.py --sizes "$SLICE_SIZES"; then
  echo "run_bootstrap_slices: slice generation failed" >&2
  exit 2
fi

sizes_sorted="$(printf '%s' "$SLICE_SIZES" | tr ', ' '\n\n' | grep -E '^[0-9]+$' | sort -n -u)"
if [ -z "$sizes_sorted" ]; then
  echo "run_bootstrap_slices: no valid slice sizes in '${SLICE_SIZES}'" >&2
  exit 2
fi

invalid=0
printf 'K\tmodules\tverdict\tfingerprints\tfirst\n'

while IFS= read -r k; do
  [ -n "$k" ] || continue
  manifest="$OUT_DIR/k${k}.manifest"
  out="$OUT_DIR/k${k}.out"
  fp="$OUT_DIR/k${k}.fingerprints"

  if [ ! -f "$manifest" ]; then
    echo "run_bootstrap_slices: INVALID K=${k}: missing manifest ${manifest}" >&2
    : > "$fp"
    printf '%s\t%s\tINVALID\t-\t-\n' "$k" "0"
    invalid=1
    continue
  fi
  modules="$(grep -cE '^(std|compiler):' "$manifest" || true)"

  echo "run_bootstrap_slices: RUN K=${k} modules=${modules} (hard timeout ${SLICE_TIMEOUT}s)" >&2
  rc=0
  timeout "$SLICE_TIMEOUT" "$STAGE0" bootstrap-check \
    --manifest "$manifest" --repo-root . --target "$TARGET" >"$out" 2>&1 || rc=$?

  if [ "$rc" -eq 124 ]; then
    echo "run_bootstrap_slices: INVALID K=${k}: hard timeout after ${SLICE_TIMEOUT}s" >&2
    : > "$fp"
    printf '%s\t%s\tINVALID(timeout)\t-\t-\n' "$k" "$modules"
    invalid=1
    continue
  fi
  if [ "$rc" -eq 126 ] || [ "$rc" -eq 127 ]; then
    echo "run_bootstrap_slices: INVALID K=${k}: seed binary is not executable (rc=${rc})" >&2
    : > "$fp"
    printf '%s\t%s\tINVALID(no-seed)\t-\t-\n' "$k" "$modules"
    invalid=1
    continue
  fi
  if [ ! -s "$out" ]; then
    echo "run_bootstrap_slices: INVALID K=${k}: missing/empty output ${out} (rc=${rc})" >&2
    : > "$fp"
    printf '%s\t%s\tINVALID(no-output)\t-\t-\n' "$k" "$modules"
    invalid=1
    continue
  fi

  if grep -q 'FRONTEND_SEMANTIC_GATE = PASS' "$out"; then
    : > "$fp"
    printf '%s\t%s\tPASS\t0\t-\n' "$k" "$modules"
  else
    first="$(extract_fingerprints "$out" "$k")"
    [ -n "$first" ] || first="-"
    fps="$(wc -l < "$fp" | tr -d ' ')"
    printf '%s\t%s\tFAIL\t%s\t%s\n' "$k" "$modules" "$fps" "$first"
  fi
done <<<"$sizes_sorted"

if [ "$invalid" -ne 0 ]; then
  echo "run_bootstrap_slices: INVALID run(s) encountered" >&2
  exit 1
fi
echo "run_bootstrap_slices: all slice runs valid (semantic FAIL is evidence, not an error)"
exit 0
