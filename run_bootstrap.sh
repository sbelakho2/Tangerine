#!/usr/bin/env bash
#
# run_bootstrap.sh — Deterministic Tangerine bootstrap validation harness
#
# Builds and validates the compiler through its self-hosting ladder:
#     stage0 (OCaml seed) -> stage1 -> stage2 -> stage3
# and asserts that stage2 and stage3 are byte-identical (reproducible build).
#
# Stage 0 is the OCaml seed (stage0_ocaml/): `dune build` produces
# stage0_ocaml/_build/default/bin/tg_stage0.exe, which compiles the kernel
# manifest closure (tg_compiler/bootstrap_main.tg) into stage1. The retired
# Swift stage0 (stage0_swift/) no longer exists; there is no Swift build
# step, no Swift binary path, and no fallback seed.
#
# Stages are produced into build/tg_stage{1,2,3}, with logs under
# build/bootstrap/. After stage3 validates, the harness materializes the FULL
# compiler — the driver CLI (fmt/lint/test/bench/doc/agent/...) that the
# tg-consuming CI jobs invoke — into build/tg by compiling tg_compiler/
# driver.tg with stage3. The ladder stages themselves carry only the KERNEL
# entry (bootstrap_main.tg: the compile/check commands), because driver.tg is
# intentionally NOT a member of the kernel manifest. CI publishes build/tg
# together with the stage artifacts and logs (see .woodpecker/bootstrap.yaml).
#
# Closure scoping (compiler_core.tg is_kernel_entry_path): the manifest-closed
# self-host mode (merge_imported_deps, include_compiler_lib) is keyed on the
# KERNEL ENTRY root bootstrap_main.tg — every ladder stage build is therefore
# strictly manifest-closed and hard-fails on any out-of-manifest import. The
# full-driver materialization below is NOT such a build: driver.tg is the
# out-of-manifest tooling root, so its imports load from the repo through the
# same canonical loader (prelude + recursive resolution), no flag needed.
#
# DELEGATION: the stage0 -> stage1 -> stage2 -> stage3 closure is driven by
# scripts/check_ocaml_bootstrap_complete.sh (the OCaml seed's completeness
# gate: pinned toolchain -> `cd stage0_ocaml && dune build` -> the seed's
# `tg_bootstrap_gate` closure through every stage). This script does NOT
# duplicate that flow; it resolves stage0 through
# scripts/bootstrap_helpers.sh (bh_ocaml_seed_build) and then delegates.
# The ladder can only complete once the seed's typecheck debt is zero
# (check_ocaml_bootstrap_complete.sh prints exactly what remains).
#
# Flag mapping (the pre-rewire flags keep their meaning at the delegation
# points that exist once the ladder is live):
#   --skip-ladder       skip scripts/run_stage2_diag_ladder.sh (the live
#                       stage2 diagnostic ladder, run from the delegated
#                       build/tg_stage2 after the closure gate passes)
#   --skip-determinism  skip the two-root reproducibility check, i.e.
#                       scripts/run_two_root_repro.sh — the OCaml-flow
#                       successor of check_two_clean_dirs (structural
#                       mode until a live stage binary exists, ladder mode
#                       from the seed-built stages)
#   --skip-native-tests skip the native canary / ARM64 lanes
#   --trace             per-phase fingerprints (applied to the ladder once
#                       the OCaml-built stages exist)
#
# Determinism guarantees (once the ladder is live):
#   - Fixed, repo-relative output paths (no mktemp randomness).
#   - Sorted, stable argument ordering.
#   - No reliance on wall-clock output; only content hashes are compared.
#   - The two-root reproducibility check builds the identical manifest
#     closure from two pristine trees (common seed + common host) and
#     asserts byte-identical binaries (scripts/run_two_root_repro.sh).
#   - Canary suite manifests are validated for parity in both directions
#     (manifest == discovered-set) with recorded counts, before the ladder.
#
# Phase fingerprints:
#   Per-phase sha256 fingerprints are emitted for every stage (link-image,
#   text, sections, symbols, relocs and — under trace — the probed tokens,
#   ast/hir, mir, mir-mono front-end dumps) by the shared helpers. The
#   stage2 == stage3 reproducibility gate compares EVERY fingerprinted
#   phase, not just the final link image, and in the trace (release)
#   configuration treats any UNAVAILABLE phase fingerprint as a hard
#   failure.
#
# Usage:
#   ./run_bootstrap.sh [--trace|--trace-phases] [--skip-determinism] [--skip-ladder]
#   TG_BOOTSTRAP_TRACE=1 ./run_bootstrap.sh
#
# Exit codes:
#   0  all stages built and validated
#   1  any stage failed to build or validate (including the seed's own
#      completeness gate while its typecheck debt is nonzero)
#   2  stage2 != stage3 (per-phase reproducibility gate) or two-root check failed
#   3  stage2 diagnostic ladder failed

set -euo pipefail

# ———————————————————————————————————————————————————————————————
# Configuration
# ———————————————————————————————————————————————————————————————

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

HELPERS="$ROOT_DIR/scripts/bootstrap_helpers.sh"
if [ ! -f "$HELPERS" ]; then
  echo "[bootstrap:error] missing $HELPERS" >&2
  exit 1
fi
# shellcheck source=scripts/bootstrap_helpers.sh
source "$HELPERS"

# Cheap structural pre-gate BEFORE the expensive ladder: a malformed struct
# declaration in the kernel (missing fields or missing `end`) silently
# corrupts every self-hosted stage. This is a heuristic safety net — the
# authoritative gate remains stage0 parsing the kernel — but it fails fast
# and cheaply.
if [ -x "$ROOT_DIR/scripts/check_struct_integrity.sh" ]; then
  if ! "$ROOT_DIR/scripts/check_struct_integrity.sh"; then
    echo "[bootstrap:error] kernel struct-integrity pre-gate failed" >&2
    exit 1
  fi
fi

# Self-host grammar pre-gate: the current parser HARD-REJECTS the legacy
# parameter spellings (mut/&/&mut/move/own prefixes, `x: &T` / `x: &mut T`
# markers, `fn(&T)` fn-type params, `&self` / `&mut self` receivers — the
# E100/E106 diagnostics), so the manifest closure MUST be free of them: HEAD
# has to compile its own kernel under its own grammar. Any forbidden form in
# ANY manifest closure file fails the harness before any stage is built.
if [ -x "$ROOT_DIR/scripts/run_selfhost_grammar_gate.sh" ]; then
  if ! "$ROOT_DIR/scripts/run_selfhost_grammar_gate.sh"; then
    echo "[bootstrap:error] self-host grammar pre-gate failed (legacy parameter forms in the manifest closure)" >&2
    exit 1
  fi
fi

BUILD_DIR="$ROOT_DIR/build"
BOOT_LOG_DIR="$BUILD_DIR/bootstrap"
STAGE0_BIN=""
RUN_LADDER=1
RUN_DETERMINISM=1
RUN_NATIVE_TESTS=1
# The single resolved target object: resolved ONCE through the bootstrap
# target authority (bh_boot_target) and exported so every subprocess
# (gen_bootstrap_input.sh, stage compiles, canary lanes) observes the SAME
# target. Nothing below re-derives or hard-codes a triple.
TARGET_TRIPLE="$(bh_boot_target)"
export TARGET_TRIPLE

# Compiler bootstrap entry source used as the bootstrap unit.
DRIVER_SRC="tg_compiler/bootstrap_main.tg"

# Full compiler driver source and its materialization output. driver.tg is the
# full CLI (fmt/lint/test/bench/doc/agent/...); it is intentionally NOT in the
# kernel manifest, so after stage3 validates this source is compiled with
# stage3 into TG_FULL and published with the stage artifacts.
DRIVER_FULL_SRC="tg_compiler/driver.tg"
TG_FULL="$BUILD_DIR/tg"

# ———————————————————————————————————————————————————————————————
# Argument parsing
# ———————————————————————————————————————————————————————————————

for arg in "$@"; do
  case "$arg" in
    --trace|--trace-phases)
      BOOTSTRAP_TRACE_ACTIVE="1"
      export TG_BOOTSTRAP_TRACE=1
      ;;
    --skip-ladder)
      RUN_LADDER=0
      ;;
    --skip-determinism)
      RUN_DETERMINISM=0
      ;;
    --skip-native-tests)
      RUN_NATIVE_TESTS=0
      ;;
    -h|--help)
      cat <<'HELP'
run_bootstrap.sh — deterministic Tangerine bootstrap validation harness

Options:
  --trace | --trace-phases   emit per-phase sha256 fingerprints (link/text/sections/symbols/relocs + probed front-end dumps) once the OCaml-built stages exist
  --skip-ladder              skip the stage2 diagnostic ladder
  --skip-determinism         skip the two-root reproducibility check (scripts/run_two_root_repro.sh)
  --skip-native-tests        skip compiling+running native canaries / arch tests
  -h | --help                show this help

Stage 0 (the OCaml seed):
  Stage 0 is built from stage0_ocaml/ with `cd stage0_ocaml && dune build`;
  the stage-0 binary is stage0_ocaml/_build/default/bin/tg_stage0.exe.
  Stage1 is the seed compiling the manifest closure
  (tg_compiler/bootstrap_main.tg). The stage0 -> stage1 -> stage2 -> stage3
  closure is delegated to scripts/check_ocaml_bootstrap_complete.sh (the
  OCaml-seed completeness gate), which drives the same closure through
  tg_bootstrap_gate. While the seed's typecheck debt is nonzero the
  delegation exits nonzero and prints exactly what remains.

Full compiler materialization:
  After stage3 validates, the harness compiles the full driver with stage3:
    build/tg_stage3 compile --strict-resolution tg_compiler/driver.tg \
      -o build/tg --target <host>
  build/tg is the full CLI (fmt/lint/test/bench/doc/agent/...) that the
  tg-consuming CI jobs invoke; the ladder stages carry only the kernel entry
  (compile/check). The materialized build/tg is validated like every stage and
  published together with build/tg_stage{1,2,3}.

Release gate:
  With trace active (the CI configuration) the phase-equality gate is the
  RELEASE GATE: any UNAVAILABLE fingerprint is a hard failure — every
  semantic phase must produce a real fingerprint. Without trace the
  UNAVAILABLE tolerance remains (non-release/debug probes).

Environment:
  TG_BOOTSTRAP_TRACE=1       enable phase fingerprints
  TG_BOOTSTRAP_TARGET=...    target triple (default: the bootstrap target authority in scripts/bootstrap_helpers.sh)
HELP
      exit 0
      ;;
    *)
      bh_err "unknown argument: $arg"
      exit 1
      ;;
  esac
done

# ———————————————————————————————————————————————————————————————
# Step 0 — environment & directories
# ———————————————————————————————————————————————————————————————

mkdir -p "$BUILD_DIR" "$BOOT_LOG_DIR"
touch "$BOOT_LOG_DIR/.keep"

bh_log "Tangerine bootstrap harness"
bh_log "root:      $ROOT_DIR"
bh_log "target:    $TARGET_TRIPLE"
bh_log "trace:     ${BOOTSTRAP_TRACE_ACTIVE}"
bh_log "log dir:   $BOOT_LOG_DIR"

# Portable tee helper for capturing a subcommand's log while streaming it.
run_logged() {
  local name="$1"; shift
  bh_log "running: $*"
  if "$@" 2>&1 | tee "$BOOT_LOG_DIR/$name.log"; then
    return "${PIPESTATUS[0]}"
  fi
  return "${PIPESTATUS[0]}"
}

# Build the canonical bootstrap unit from the kernel manifest (single source of
# truth). Fails the harness if the manifest closure is invalid or has an
# import outside the kernel.
bh_log "== Bootstrap unit (compiler_kernel.manifest) =="
if ! run_logged gen_bootstrap_input bash "$ROOT_DIR/scripts/gen_bootstrap_input.sh"; then
  bh_err "bootstrap kernel manifest closure is invalid"
  exit 1
fi

# ———————————————————————————————————————————————————————————————
# Step 0.5 — canary suite manifest parity pre-gate
# ———————————————————————————————————————————————————————————————

# Cheap structural gate BEFORE the expensive ladder: every canary suite
# advertised as a bootstrap acceptance gate must be present, manifest-listed
# in both directions, and exactly match its recorded count. A missing test,
# an unlisted test, or a zero suite fails the harness immediately.
bh_log "== Canary suite manifest parity =="
if ! bh_require_canary_suites; then
  bh_err "canary suite manifest parity failed (missing/unlisted tests or count drift)"
  exit 1
fi

# ———————————————————————————————————————————————————————————————
# Step 1 — stage0: build the OCaml seed
# ———————————————————————————————————————————————————————————————

# The ONE stage-0 authority (scripts/bootstrap_helpers.sh): the OCaml seed
# at stage0_ocaml/. The pinned OCaml/Dune toolchain is verified first; the
# seed is then built with `cd stage0_ocaml && dune build`, and the stage-0
# binary is stage0_ocaml/_build/default/bin/tg_stage0.exe. The Swift stage0
# (stage0_swift/) no longer exists and there is no fallback seed.
if ! scripts/check_ocaml_toolchain.sh; then
  bh_err "pinned OCaml/Dune toolchain check failed (bootstrap/ocaml-toolchain.lock)"
  exit 1
fi

bh_log "== Stage 0: OCaml bootstrap seed =="
if ! STAGE0_BIN="$(bh_ocaml_seed_build)"; then
  bh_err "stage0 (OCaml seed) build failed"
  exit 1
fi
if [ ! -x "$STAGE0_BIN" ]; then
  bh_err "stage0 binary not produced: $STAGE0_BIN"
  exit 1
fi
bh_log "stage0 ready: $STAGE0_BIN (OCaml seed)"

# ———————————————————————————————————————————————————————————————
# Step 2 — the seed's bootstrap closure (stage1 -> stage2 -> stage3)
# ———————————————————————————————————————————————————————————————

# DELEGATION: scripts/check_ocaml_bootstrap_complete.sh is the OCaml-seed
# completeness gate and the canon of the stage0 -> stage1 -> stage2 ->
# stage3 closure: it resolves the SAME stage0 binary, loads the manifest
# closure, and drives it through the seed's tg_bootstrap_gate (cfg
# elimination, resolver, typechecker, access/resource, lowering, MIR
# verify, mono, second MIR verify, reachable-host closure, VM run and
# artifact production). This script does not duplicate that pipeline; it
# delegates the closure gate and then materializes the three ladder
# artifacts from the SAME seed via bh_ocaml_seed_compile (stage1), then
# stage1 -> stage2 and stage2 -> stage3.
STAGE1="$BUILD_DIR/tg_stage1"
STAGE2="$BUILD_DIR/tg_stage2"
STAGE3="$BUILD_DIR/tg_stage3"

bh_log "== OCaml seed bootstrap completeness gate (delegated) =="
bh_log "delegate: scripts/check_ocaml_bootstrap_complete.sh (stage0 -> stage1 -> stage2 -> stage3 closure)"
set +e
scripts/check_ocaml_bootstrap_complete.sh 2>&1 | tee "$BOOT_LOG_DIR/ocaml_bootstrap_complete.log"
OCAML_GATE_RC="${PIPESTATUS[0]}"
set -e
if [ "$OCAML_GATE_RC" -ne 0 ]; then
  bh_err "OCaml seed bootstrap gate FAILED (exit $OCAML_GATE_RC) — see $BOOT_LOG_DIR/ocaml_bootstrap_complete.log"
  bh_err "the seed's typecheck debt must reach zero before the full self-hosting ladder can complete;"
  bh_err "run scripts/check_ocaml_seed_health.sh for the pinned-debt development-health gate."
  exit 1
fi

# ── stage1: the seed compiles the manifest closure (the stage1 production
# step the OCaml harness intends; see bh_ocaml_seed_compile).
bh_log "== Stage 1: kernel via the OCaml seed (manifest closure) =="
if ! run_logged stage1_compile \
     bh_ocaml_seed_compile "$STAGE0_BIN" "$ROOT_DIR" "$TARGET_TRIPLE" "$STAGE1"; then
  bh_err "stage1 failed to build from the OCaml seed"
  exit 1
fi
chmod +x "$STAGE1"
if ! validate_stage tg_stage1 "$STAGE1"; then
  bh_err "stage1 failed validation"
  exit 1
fi

# ── stage2: stage1 compiles itself (self-host).
bh_log "== Stage 2: self-host via stage1 =="
if ! run_logged stage2_compile \
     "$STAGE1" compile --strict-resolution "$DRIVER_SRC" -o "$STAGE2" --target "$TARGET_TRIPLE"; then
  bh_err "stage2 failed to build"
  exit 1
fi
chmod +x "$STAGE2"
if ! validate_stage tg_stage2 "$STAGE2"; then
  bh_err "stage2 failed validation"
  exit 1
fi

# ── stage3: stage2 compiles itself (the fixed-point cycle).
bh_log "== Stage 3: self-host via stage2 =="
if ! run_logged stage3_compile \
     "$STAGE2" compile --strict-resolution "$DRIVER_SRC" -o "$STAGE3" --target "$TARGET_TRIPLE"; then
  bh_err "stage3 failed to build"
  exit 1
fi
chmod +x "$STAGE3"
if ! validate_stage tg_stage3 "$STAGE3"; then
  bh_err "stage3 failed validation"
  exit 1
fi

# ── materialize: stage3 compiles the FULL driver (tg_compiler/driver.tg) into
# build/tg. The ladder stages carry only the KERNEL entry (bootstrap_main.tg:
# the compile/check commands); the full driver is intentionally NOT a member
# of the kernel manifest, so the full CLI the tg-consuming CI jobs invoke
# (fmt/lint/test/bench/doc/agent/...) is produced here from the validated
# stage3 with the same CLI shape the self-host stages use:
#   build/tg_stage3 compile --strict-resolution tg_compiler/driver.tg \
#     -o build/tg --target <host>
# CLOSURE SCOPE: the manifest-closed gate is keyed on the kernel entry
# (compiler_core.tg is_kernel_entry_path — bootstrap_main.tg), so the ladder
# builds above stay strictly manifest-closed while this tooling root loads
# its imports from the repo via the canonical loader. No flag is required:
# driver.tg is the sanctioned out-of-manifest tooling root by design.
# The materialized build/tg is validated like every stage and published with
# the stage artifacts (the CI artifact set carries build/tg, and the
# tg-consuming jobs keep it instead of re-copying the kernel stage3).
bh_log "== Full compiler materialization: $DRIVER_FULL_SRC via stage3 =="
if ! run_logged materialize_full \
     "$STAGE3" compile --strict-resolution "$DRIVER_FULL_SRC" -o "$TG_FULL" --target "$TARGET_TRIPLE"; then
  bh_err "full compiler materialization failed (stage3 could not compile $DRIVER_FULL_SRC)"
  exit 1
fi
chmod +x "$TG_FULL"
if [ ! -x "$TG_FULL" ]; then
  bh_err "full compiler not produced: $TG_FULL"
  exit 1
fi
if ! validate_stage tg "$TG_FULL" "$DRIVER_FULL_SRC"; then
  bh_err "materialized full compiler failed validation"
  exit 1
fi
bh_log "full compiler ready: $TG_FULL (published with the stage artifacts)"

# Critical canaries under stage1: prove stage1's runtime can compile the
# compiler before spending a full self-host cycle.
if [ "$RUN_NATIVE_TESTS" = "1" ]; then
  bh_log "== Critical canaries (via stage1) =="
  if ! run_critical_canaries "$STAGE1" "$BUILD_DIR/.native_stage1"; then
    bh_err "stage1 critical canaries failed"
    exit 1
  fi
  bh_log "== Semantic canary negatives (via stage1) =="
  if ! run_semantic_canary_negatives "$STAGE1"; then
    bh_err "stage1 semantic canary negatives failed"
    exit 1
  fi
fi

# ———————————————————————————————————————————————————————————————
# Step 3 — stage2 diagnostic ladder
# ———————————————————————————————————————————————————————————————

if [ "$RUN_LADDER" = "1" ]; then
  bh_log "== Stage 2 diagnostic ladder =="
  if ! run_stage2_diag_ladder "$STAGE2" "$BUILD_DIR/.ladder"; then
    bh_err "stage2 diagnostic ladder failed"
    exit 3
  fi
fi

# ———————————————————————————————————————————————————————————————
# Step 4 — native canaries + ARM64 encoder/ABI tests
# ———————————————————————————————————————————————————————————————

if [ "$RUN_NATIVE_TESTS" = "1" ]; then
  bh_log "== Native canaries + ARM64 tests (via stage3) =="
  if ! run_native_tests "$STAGE3" "$BUILD_DIR/.native_tests"; then
    bh_err "native canary / ARM64 tests failed"
    exit 1
  fi
fi

# ———————————————————————————————————————————————————————————————
# Step 5 — stage2 == stage3 reproducibility gate (every phase)
# ———————————————————————————————————————————————————————————————

bh_log "== Reproducibility: stage2 vs stage3 =="
H2="$(bh_sha256_file "$STAGE2")"
H3="$(bh_sha256_file "$STAGE3")"
bh_log "stage2 sha256: $H2"
bh_log "stage3 sha256: $H3"
# Hard fixed-point gate: stage2 and stage3 must be byte-identical.
if ! cmp -s "$STAGE2" "$STAGE3"; then
  bh_err "stage2 != stage3 (non-reproducible build); 'cmp stage2 stage3' failed — this is the fixed-point gate"
  exit 2
fi
bh_log "stage2 == stage3 (reproducible fixed point, 'cmp' OK)"

# Phase-level fixed-point gate: stage2 == stage3 at EVERY fingerprinted
# phase (link-image, text, sections, symbols, relocs, and the probed
# front-end dumps under trace), not only at the final link image.
# RELEASE GATE: in the trace configuration (CI sets TG_BOOTSTRAP_TRACE=1 —
# the configuration that actually probes the semantic phases) ANY UNAVAILABLE
# fingerprint is a HARD FAILURE: the semantic phases must all produce
# fingerprints. The UNAVAILABLE tolerance remains only for non-release/debug
# runs (no trace, no probes).
phase_gate_args=""
if [ "${BOOTSTRAP_TRACE_ACTIVE:-0}" = "1" ]; then
  phase_gate_args="release"
  bh_log "phase-equality RELEASE GATE active (trace mode: any UNAVAILABLE fingerprint is fatal)"
fi
if ! bh_phase_equality tg_stage2 tg_stage3 "$BUILD_DIR" $phase_gate_args; then
  bh_err "stage2/stage3 per-phase equality failed — phase fingerprints diverged (or a phase is UNAVAILABLE under the release gate)"
  exit 2
fi

# ———————————————————————————————————————————————————————————————
# Step 6 — two-root reproducibility check
# ———————————————————————————————————————————————————————————————

# The OCaml-flow two-root authority: scripts/run_two_root_repro.sh. It
# re-runs the seed -> stage1 -> stage2 -> stage3 ladder in two fresh roots
# (ladder mode) and asserts A.stage3 == B.stage3, with the structural
# comparisons (manifest identity, deterministic generations) in both modes.
# This replaces the pre-rewire Swift-seeded check_two_clean_dirs call.
if [ "$RUN_DETERMINISM" = "1" ]; then
  bh_log "== Two-root reproducibility check (scripts/run_two_root_repro.sh) =="
  if ! run_logged two_root_repro \
       bash scripts/run_two_root_repro.sh --with-binary "$STAGE3" --out "$BOOT_LOG_DIR/two_root_repro.txt"; then
    bh_err "two-root reproducibility check failed"
    exit 2
  fi
fi

# ———————————————————————————————————————————————————————————————
# Summary
# ———————————————————————————————————————————————————————————————

bh_log "== Bootstrap complete =="
bh_log "stage0:  $STAGE0_BIN (OCaml seed)"
bh_log "stage1:  $STAGE1"
bh_log "stage2:  $STAGE2"
bh_log "stage3:  $STAGE3"
bh_log "tg:      $TG_FULL (full compiler materialized from $DRIVER_FULL_SRC via stage3)"
bh_log "logs:    $BOOT_LOG_DIR"
bh_log "bootstrap OK"

exit 0
