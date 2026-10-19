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

# Final authorization binds to a FROZEN, CLEAN tree: the calibration
# identity (RUN_SHA / SEED_SHA256) names the tested SHA, so a dirty
# worktree can never be authorization material.  This check is
# independent of prebootstrap_quick.sh --final (which refuses
# --allow-dirty): neither path can authorize an unreproducible tree.
if ! git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "check_ocaml_bootstrap_complete: FAIL — not a git worktree; final authorization requires a clean, identified tree" >&2
  exit 1
fi
DIRTY="$(git -C "$ROOT" status --porcelain=v1 2>/dev/null)"
if [ -n "$DIRTY" ]; then
  echo "check_ocaml_bootstrap_complete: FAIL — dirty worktree; final authorization requires a frozen clean tree (the calibration identity binds to the tested SHA)" >&2
  printf '%s\n' "$DIRTY" | head -20 >&2
  exit 1
fi

# The shared bootstrap validation library: the timeout facility is the single
# authority (GNU timeout / Homebrew gtimeout).  Authorization mode REJECTS
# the TG_TIMEOUT_CMD ambient override: final evidence must use the verified
# platform timeout, not an operator-supplied command (which could silently
# skip or alter enforcement).  A pre-resolved BH_TIMEOUT_CMD_RESOLVED is
# cleared so resolution re-runs under the pinned policy.
# shellcheck source=scripts/bootstrap_helpers.sh
source "$ROOT/scripts/bootstrap_helpers.sh"
unset TG_TIMEOUT_CMD
unset BH_TIMEOUT_CMD_RESOLVED
# Authorization pins the measurement GC policy: profiling calibrated with
# o=40 (RSS ~1.2x live) and the pinned RSS ceiling assumes the same policy;
# inheriting a different OCAMLRUNPARAM would invalidate the calibration.
bh_export_bootstrap_vm_limits
# A stale diagnostic phase-trace flag must never perturb an authorization
# run (phase_trace performs guest filesystem writes). Profiling is explicit.
if [ "${TANGERINE_BOOTSTRAP_PROFILE:-0}" != "1" ]; then
  rm -f "$ROOT/build/phase_trace.flag" "$ROOT/build/kernel_phase.log"
fi

if [ -f scripts/check_ocaml_toolchain.sh ]; then
  scripts/check_ocaml_toolchain.sh
fi

cd stage0_ocaml
dune build

# Harness timeout calibration (shared with check_ocaml_seed_health.sh).
# The 2026-09-27 measurement (tg_bootstrap_gate 2759.9 s wall: closure
# front end 1419.5 s, lower 22.2 s, mono 53.7 s, reachable-host 0.2 s,
# VM run 1264.3 s) belongs to a tree BEFORE the current algorithm: the
# in-VM self-host preflight then entered a quadratic shared-marking zone
# and did NOT fit the 30e9-step VM default (driver.ml records the
# ~43.5e9 frontier), so the "fix lands the full closure" narrative that
# used to live here described a completion this algorithm state cannot
# reproduce.  The current pass replaced the redundant deep re-walks with
# the memoized Map/Set store markers AND removed the unsafe O(1)
# pure-data Clone fast path (generic Map::clone/Set::clone clone every
# element again), so BOTH the wall time and the VM step count must be
# re-measured from a completed cold and warm run before the caps mean
# anything.  4140 s stays as the provisional upper bound (a cap is a
# bound, never a skip, and it still fails closed); it is NOT evidence of
# a completed route.  Re-measure and re-pin both budgets only after the
# preflight actually completes.
# NOTE (audit P0-2 / timeout recalibration): at zero debt the gate runs
# TWO kernel VM executions:
#   VM A: the artifact corpus compile+run (native codegen/link evidence)
#   VM B: the self-host preflight (`check --strict-resolution
#         --bootstrap-proof --stop-after=mono tg_compiler/bootstrap_main.tg`)
#         — full front end, lowering, mono, type-query fold, post-mono
#         verify/oracle, plus the closure-digest recomputation (it reads
#         and SHA-256s all 45 manifest sources).
# The historic cap was calibrated on VM A alone.  Re-measure both VMs at
# zero debt (cold AND warm) and re-pin the cap from the instrumented
# phase numbers — never as a blind timeout increase.  The gate prints
# per-phase wall times, including the preflight VM run.
# An explicit override is for MEASUREMENT runs only (record the gate's
# instrumented phase lines, then re-pin the default from the numbers).
# Repinned from the completed aggregate run: front end 399s + VM A 730s
# + self-host preflight VM B 4120s + builder phases = ~5300s wall. 6000s
# is the measured bound plus ~13% host-noise margin. The former 4140s
# provisional cap predates the completed preflight measurement.
GATE_TIMEOUT_S=6000
# Resource-affecting VM budgets are PINNED for authorization: ambient
# TANGERINE_BOOTSTRAP_VM_MAX_* / TG_GATE_TIMEOUT_S cannot alter a
# reproducible authorization run.  Bounded profiling measures the
# selfcheck directly with explicit env, never through this script, so no
# measurement configuration can emit an authorization PASS.  Re-pin the
# step/host-call/alloc limits only from a completed cold+warm calibration.
# MEASURED REPIN (aggregate run, o=40, HEAD 02b6344, aarch64-apple-darwin):
# the provisional 30e9 cap trapped inside resolve-import binding before the
# self-host preflight reached its tail.  With 150e9 the FULL preflight
# completes (VM B 4120.4s, all 11 phases).  The earlier 2486s figure in the
# first repin note was a TYPECHECK-FAILED run (it stopped on a non-exhaustive
# match) and is NOT a completion measurement.  This is a completed-run
# measurement, not a blind increase; a lower cap requires a completed cold
# run that proves it.
# Repinned from the same completed aggregate run: the provisional 1e9
# host-call cap trapped inside lower_stmt_impl/typed_binding_type_by_name;
# the full preflight's realized host-call count is far below 8e9 (the
# 46e9-step beacon in the instrumented run reported 442M, and the gate
# completes under 8e9).  Allocation stays at 8GiB (RSS beacon <= ~9.0GB
# under the 12GiB ceiling).
# The final authorization ALWAYS installs the measured RSS ceiling and
# accepts NO resource-budget override: an ambient environment cannot
# disable the guard (0 = disabled), raise it, or turn this script into a
# measurement run.  Bounded-profiling measurements run the selfcheck
# directly (tg_bootstrap_selfcheck with an explicit
# TANGERINE_BOOTSTRAP_VM_MAX_RSS_MB), never through the authorization
# script — no measurement configuration can emit an authorization PASS.
# RSS measurement is three-tier: Linux /proc/self/status VmRSS, or the
# seed's native Mach task_info stub on macOS (rss_stubs.c).  A host
# with neither REFUSES to authorize — there is no unbounded authorization path.
case "$(uname -s 2>/dev/null)" in
  Linux | Darwin) FINAL_RSS_SUPPORTED=1 ;;
  *) FINAL_RSS_SUPPORTED=0 ;;
esac
if [ "$FINAL_RSS_SUPPORTED" != "1" ]; then
  echo "check_ocaml_bootstrap_complete: FAIL — final authorization requires an RSS ceiling, but this host has no RSS measurement (/proc on Linux, Mach task_info on macOS). Run the authorization gate on Linux or macOS; unbounded measurement is a separate, explicitly non-authorizing activity." >&2
  exit 1
fi
# The bootstrap target authority: the SAME triple the ladder compiles for
# (TG_BOOTSTRAP_TARGET; default aarch64-apple-darwin).  The gate's closure
# front end is target-parameterized through @cfg elimination, and its
# artifact corpus compile runs the TARGET's codegen/link route — so the
# gate must be asked about the target the ladder will actually build.
# ONE target authority: honour the pre-resolved/exported TARGET_TRIPLE from
# run_bootstrap.sh, then the operator override, then bh_boot_target().
TARGET_TRIPLE="${TARGET_TRIPLE:-${TG_BOOTSTRAP_TARGET:-$(bh_boot_target)}}"
echo "check_ocaml_bootstrap_complete: target $TARGET_TRIPLE"

set +e
bh_run_with_timeout "$GATE_TIMEOUT_S" _build/default/selfcheck/tg_bootstrap_gate.exe --repo-root .. --target "$TARGET_TRIPLE" >/tmp/ocaml_bootstrap_gate.out 2>&1
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
# resolver, stop after MONO) — zero exit alone is not accepted as the
# preflight proof.
if ! grep -q "SELF-HOST PREFLIGHT: PASS" /tmp/ocaml_bootstrap_gate.out; then
  echo "check_ocaml_bootstrap_complete: FAIL — the full closure passed but the self-host preflight did not (the kernel cannot be proven to consume tg_compiler/bootstrap_main.tg)"
  tail -30 /tmp/ocaml_bootstrap_gate.out
  exit 1
fi

echo "check_ocaml_bootstrap_complete: typecheck debt 0 — full closure PASS"
echo "check_ocaml_bootstrap_complete: SELF-HOST PREFLIGHT: PASS (kernel check of tg_compiler/bootstrap_main.tg over the exact manifest closure)"
echo "check_ocaml_bootstrap_complete: BOOTSTRAP COMPLETE: PASS"
