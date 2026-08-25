#!/usr/bin/env bash
# check_ocaml_stage0.sh — thin wrapper over the two split gates (audit
# P1 item 3): seed development health (pinned debt) and bootstrap
# completeness (zero semantic debt, full closure).  CI does not
# reference this script (checked .github/workflows/ci.yml), so it is
# kept only as the familiar entry point.
#
# Usage: scripts/check_ocaml_stage0.sh [repo-root]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

echo "== stage0 OCaml gate 1/2: seed development health (pinned debt) =="
scripts/check_ocaml_seed_health.sh

echo ""
echo "== stage0 OCaml gate 2/2: bootstrap completeness (zero semantic debt) =="
if scripts/check_ocaml_bootstrap_complete.sh; then
  echo ""
  echo "check_ocaml_stage0: ALL GATES PASSED (seed health + bootstrap completeness)"
else
  echo ""
  echo "check_ocaml_stage0: seed health PASSED; bootstrap completeness NOT YET (pinned semantic debt remains — see check_ocaml_bootstrap_complete.sh)"
  exit 1
fi
