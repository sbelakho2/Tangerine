#!/usr/bin/env bash
#
# tests/run_conformance_canaries.sh — Manifest-driven conformance headline gate.
#
# The standalone conformance job's headline is the OWNERSHIP/ACCESS canary
# matrix, driven by tests/canary/MANIFEST — NOT the historical borrow_01/
# borrow_02 golden files (Tangerine has no borrow checker; those remain only
# as historical tests). The headline categories:
#
#   access_*      canary_access_*.tg           (read/inout/set/sink access)
#   resource_*    canary_resource*.tg          (resource ownership/drop)
#   set_*         canary_pos_set_drain.tg      (set drains)
#   sink_*        canary_access_sink / canary_pos_resource_sink_*.tg
#   deinit_*      canary_pos_resource_manual_deinit_*.tg
#   capability_*  canary_capability.tg
#   generic-*     canary_pos_generic_*.tg / canary_resource_generic_*.tg /
#                 canary_pos_wrapper_generic.tg
#
# Every headline canary is compiled AND executed with the given compiler;
# exit code 0 is required (each canary returns its failure count).
# The suite manifest itself is validated first (bidirectional parity +
# recorded counts) — a missing or unlisted test fails before any compile.
#
# Usage: tests/run_conformance_canaries.sh [compiler] [outdir]
#   compiler defaults to build/tg (the CI-materialized stage3 artifact)
#   outdir   defaults to build/.conformance_canaries

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/bootstrap_helpers.sh
source "$ROOT/scripts/bootstrap_helpers.sh"

COMPILER="${1:-build/tg}"
OUTDIR="${2:-build/.conformance_canaries}"

if [ ! -x "$COMPILER" ]; then
  bh_err "conformance: compiler binary not executable: $COMPILER"
  exit 1
fi

bh_log "conformance canary gate: compiler=$COMPILER target=$(bh_boot_target)"

if ! bh_require_canary_suites; then
  bh_err "conformance: canary suite manifest parity failed"
  exit 1
fi

# Headline selection over the manifest (manifest-driven, never a glob).
HEADLINE_RE='(^|_)(access_|resource|set_|sink_|deinit|capability|generic)'
FILES=()
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    ''|\#*) continue ;;
  esac
  if printf '%s\n' "$line" | grep -qE "$HEADLINE_RE"; then
    FILES+=("tests/canary/$line")
  fi
done < tests/canary/MANIFEST

if [ "${#FILES[@]}" -eq 0 ]; then
  bh_err "conformance: no headline canaries matched the manifest categories"
  exit 1
fi

bh_log "conformance headline gate: ${#FILES[@]} canaries (access_/resource_/set_/sink_/deinit_/capability_/generic-ownership)"
run_canary_files "$COMPILER" "$OUTDIR" "${FILES[@]}"
