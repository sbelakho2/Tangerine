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

# The shared bootstrap validation library: the timeout facility is the single
# authority (GNU timeout / Homebrew gtimeout / TG_TIMEOUT_CMD override).
# shellcheck source=scripts/bootstrap_helpers.sh
source "$ROOT/scripts/bootstrap_helpers.sh"

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
GATE_TIMEOUT_S=4140
# Resource-affecting VM budgets are PINNED for authorization: ambient
# TANGERINE_BOOTSTRAP_VM_MAX_* / TG_GATE_TIMEOUT_S cannot alter a
# reproducible authorization run.  Bounded profiling measures the
# selfcheck directly with explicit env, never through this script, so no
# measurement configuration can emit an authorization PASS.  Re-pin the
# step/host-call/alloc limits only from a completed cold+warm calibration.
export TANGERINE_BOOTSTRAP_VM_MAX_STEPS=30000000000
export TANGERINE_BOOTSTRAP_VM_MAX_HOST_CALLS=1000000000
export TANGERINE_BOOTSTRAP_VM_MAX_ALLOC=8589934592
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
export TANGERINE_BOOTSTRAP_VM_MAX_RSS_MB=12288
# The bootstrap target authority: the SAME triple the ladder compiles for
# (TG_BOOTSTRAP_TARGET; default aarch64-apple-darwin).  The gate's closure
# front end is target-parameterized through @cfg elimination, and its
# artifact corpus compile runs the TARGET's codegen/link route — so the
# gate must be asked about the target the ladder will actually build.
TARGET_TRIPLE="${TG_BOOTSTRAP_TARGET:-aarch64-apple-darwin}"
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
