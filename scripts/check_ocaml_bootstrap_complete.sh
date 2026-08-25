#!/usr/bin/env bash
# check_ocaml_bootstrap_complete.sh — OCaml-seed BOOTSTRAP-COMPLETENESS gate.
#
# Zero-semantic-debt gate (audit P1 item 3). Runs the full bootstrap
# closure through every stage with no fallback program and requires
# ZERO typecheck debt:
#   1. the pinned OCaml/Dune toolchain
#   2. dune build
#   3. tg_bootstrap_gate (the aggregate closure gate): the actual
#      bootstrap/compiler_kernel.manifest through cfg elimination,
#      resolver, typechecker, access/resource, lowering, MIR verify,
#      mono, second MIR verify, reachable-host closure, VM run and
#      artifact production — no fallback program, no informational DIFF.
#   4. the gate's own typecheck count must be 0.
#
# The gate executable exits 0 while the typecheck debt is pinned and
# unchanged (the debt is reported and the semantic stages are deferred),
# so THIS script inspects the gate's report: only a 0-error report with
# a full-closure PASS prints "BOOTSTRAP COMPLETE: PASS". Until the
# semantic debt is zero this script exits 1 and says exactly what
# remains.
#
# Usage: scripts/check_ocaml_bootstrap_complete.sh [repo-root]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ -f scripts/check_ocaml_toolchain.sh ]; then
  scripts/check_ocaml_toolchain.sh
fi

cd stage0_ocaml
dune build

set +e
timeout 600 _build/default/selfcheck/tg_bootstrap_gate.exe --repo-root .. >/tmp/ocaml_bootstrap_gate.out 2>&1
GATE_STATUS=$?
set -e
if [ "$GATE_STATUS" -ne 0 ]; then
  echo "check_ocaml_bootstrap_complete: FAIL — tg_bootstrap_gate exited $GATE_STATUS"
  tail -30 /tmp/ocaml_bootstrap_gate.out
  exit 1
fi

TC_COUNT="$(grep -oE 'typecheck: [0-9]+ errors' /tmp/ocaml_bootstrap_gate.out | head -1 | grep -oE '[0-9]+' | head -1)"
if [ -z "$TC_COUNT" ]; then
  echo "check_ocaml_bootstrap_complete: FAIL — could not read the gate's typecheck count"
  tail -30 /tmp/ocaml_bootstrap_gate.out
  exit 1
fi

if [ "$TC_COUNT" -ne 0 ]; then
  echo "check_ocaml_bootstrap_complete: NOT YET — typecheck debt $TC_COUNT remains (the gate's pinned debt; semantic stages deferred). Zero semantic debt is required before the full closure can run."
  echo "check_ocaml_bootstrap_complete: run scripts/check_ocaml_seed_health.sh for the pinned-debt development-health gate"
  exit 1
fi

if ! grep -q "BOOTSTRAP GATE: PASS — full closure through every stage" /tmp/ocaml_bootstrap_gate.out; then
  echo "check_ocaml_bootstrap_complete: FAIL — typecheck debt is 0 but the gate did not pass the full closure"
  tail -30 /tmp/ocaml_bootstrap_gate.out
  exit 1
fi

echo "check_ocaml_bootstrap_complete: typecheck debt 0 — full closure PASS"
echo "check_ocaml_bootstrap_complete: BOOTSTRAP COMPLETE: PASS"
