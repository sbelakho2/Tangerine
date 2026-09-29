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

# Harness timeout calibration (shared with check_ocaml_seed_health.sh;
# re-measured 2026-09-27 on the development host, tree at the
# post-mono-mark-memoization seed + the active workstream changes, under
# background load): tg_bootstrap_gate measured 2759.9 s wall (sum of the
# driver phase prints: closure front end 1419.5 s, lower 22.2 s, mono
# 53.7 s, reachable-host 0.2 s, closure check 0.0 s, layout fold 0.0 s,
# VM run 1264.3 s); the cap is the measurement x 1.5 rounded up to the
# next 60 s (4139.9 -> 4140 s), matching the health script's calibrated
# gate cap (the host carries unrelated background load).  The pre-fix
# 1860 s cap is superseded: the frozen tree stalled in the post-mono
# segment (the deep-share mark's redundant aggregate re-walks) and the
# fix lands the full closure — the cap must cover the RUN, not the
# stall.  A cap is a bound, never a skip.  Re-measure when the closure
# grows materially.
# NOTE (audit P0-2): at zero debt the gate now also executes the
# self-host preflight in a SECOND VM run (the kernel interprets
# `check --strict-resolution tg_compiler/bootstrap_main.tg` over the
# 45-source closure).  This cap was calibrated on the artifact VM run
# alone; re-measure the gate at zero debt and raise the cap only with
# the instrumented phase numbers (never as a blind timeout increase).
# Observed while landing P0-2: the standalone preflight did not complete
# within 70 minutes on the current tree, where the in-VM kernel first
# fails its own typechecker on std/alloc.tg's `size_of[T]()` (the
# pre-existing last-mile divergence) — fix that kernel issue and profile
# the in-VM check before re-pinning this cap.
# An explicit override is for MEASUREMENT runs only (record the gate's
# instrumented phase lines, then re-pin the default from the numbers).
GATE_TIMEOUT_S="${TG_GATE_TIMEOUT_S:-4140}"
# The bootstrap target authority: the SAME triple the ladder compiles for
# (TG_BOOTSTRAP_TARGET; default aarch64-apple-darwin).  The gate's closure
# front end is target-parameterized through @cfg elimination, and its
# artifact corpus compile runs the TARGET's codegen/link route — so the
# gate must be asked about the target the ladder will actually build.
TARGET_TRIPLE="${TG_BOOTSTRAP_TARGET:-aarch64-apple-darwin}"
echo "check_ocaml_bootstrap_complete: target $TARGET_TRIPLE"

set +e
timeout "$GATE_TIMEOUT_S" _build/default/selfcheck/tg_bootstrap_gate.exe --repo-root .. --target "$TARGET_TRIPLE" >/tmp/ocaml_bootstrap_gate.out 2>&1
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

# The last test before authorizing the real bootstrap (audit P0-2): the
# prepared kernel executes `check --strict-resolution
# tg_compiler/bootstrap_main.tg` inside the seed VM and the gate requires
# the exact TG_CHECK_OK summary (45-source manifest closure, strict
# resolver, stop after MIR) — zero exit alone is not accepted as the
# preflight proof.
if ! grep -q "SELF-HOST PREFLIGHT: PASS" /tmp/ocaml_bootstrap_gate.out; then
  echo "check_ocaml_bootstrap_complete: FAIL — the full closure passed but the self-host preflight did not (the kernel cannot be proven to consume tg_compiler/bootstrap_main.tg)"
  tail -30 /tmp/ocaml_bootstrap_gate.out
  exit 1
fi

echo "check_ocaml_bootstrap_complete: typecheck debt 0 — full closure PASS"
echo "check_ocaml_bootstrap_complete: SELF-HOST PREFLIGHT: PASS (kernel check of tg_compiler/bootstrap_main.tg over the exact manifest closure)"
echo "check_ocaml_bootstrap_complete: BOOTSTRAP COMPLETE: PASS"
