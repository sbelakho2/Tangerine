#!/usr/bin/env bash
#
# run_bootstrap.sh — Deterministic Tangerine bootstrap validation harness
#
# Builds and validates the compiler through its self-hosting ladder:
#     stage0 (Swift) -> stage1 -> stage2 -> stage3
# and asserts that stage2 and stage3 are byte-identical (reproducible build).
#
# Stages are produced into build/tg_stage{1,2,3}, with logs under
# build/bootstrap/. CI uploads these artifacts and logs (see ci.yml).
#
# Determinism guarantees:
#   - Fixed, repo-relative output paths (no mktemp randomness).
#   - Sorted, stable argument ordering.
#   - No reliance on wall-clock output; only content hashes are compared.
#   - The two-root reproducibility check builds the identical manifest
#     closure from two pristine trees (common seed + common host) and
#     asserts byte-identical binaries.
#   - Canary suite manifests are validated for parity in both directions
#     (manifest == discovered-set) with recorded counts, before the ladder.
#
# Phase fingerprints:
#   Per-phase sha256 fingerprints are emitted for every stage (link-image,
#   text, sections, symbols, relocs and — under trace — the probed tokens,
#   ast/hir, mir, mir-mono front-end dumps). The stage2 == stage3
#   reproducibility gate compares EVERY fingerprinted phase, not just the
#   final link image.
#
# Usage:
#   ./run_bootstrap.sh [--trace|--trace-phases] [--skip-determinism] [--skip-ladder]
#   TG_BOOTSTRAP_TRACE=1 ./run_bootstrap.sh
#
# Exit codes:
#   0  all stages built and validated
#   1  any stage failed to build or validate
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
  --trace | --trace-phases   emit per-phase sha256 fingerprints (link/text/sections/symbols/relocs + probed front-end dumps)
  --skip-ladder              skip the stage2 diagnostic ladder
  --skip-determinism         skip the two-root reproducibility check
  --skip-native-tests        skip compiling+running native canaries / arch tests
  -h | --help                show this help

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

if ! command -v swift >/dev/null 2>&1; then
  bh_err "swift toolchain not found; stage0 cannot be built"
  exit 1
fi

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
# Step 1 — build stage0 (Swift interpreter)
# ———————————————————————————————————————————————————————————————

bh_log "== Stage 0: Swift bootstrap compiler =="
run_logged stage0_build_swift \
  swift build --package-path "$ROOT_DIR/stage0_swift" -c release

STAGE0_BIN="$ROOT_DIR/stage0_swift/.build/release/tg_stage0"
if [ ! -x "$STAGE0_BIN" ]; then
  bh_err "stage0 binary not produced: $STAGE0_BIN"
  exit 1
fi
bh_log "stage0 ready: $STAGE0_BIN"

# ———————————————————————————————————————————————————————————————
# Step 2 — stage1 (native, via interpreted stage0)
# ———————————————————————————————————————————————————————————————

bh_log "== Stage 1: native compiler via stage0 interpreter =="
STAGE1="$BUILD_DIR/tg_stage1"
run_logged stage1_compile \
  "$STAGE0_BIN" compile --strict-resolution "$DRIVER_SRC" -o "$STAGE1" --target "$TARGET_TRIPLE"

chmod +x "$STAGE1"
if ! validate_stage tg_stage1 "$STAGE1"; then
  bh_err "stage1 failed validation"
  exit 1
fi

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
# Step 3 — stage2 (self-host: stage1 compiles itself)
# ———————————————————————————————————————————————————————————————

bh_log "== Stage 2: self-host via stage1 =="
STAGE2="$BUILD_DIR/tg_stage2"
run_logged stage2_compile \
  "$STAGE1" compile --strict-resolution "$DRIVER_SRC" -o "$STAGE2" --target "$TARGET_TRIPLE"

chmod +x "$STAGE2"
if ! validate_stage tg_stage2 "$STAGE2"; then
  bh_err "stage2 failed validation"
  exit 1
fi

# Critical canaries under stage2 before the full stage3 cycle.
if [ "$RUN_NATIVE_TESTS" = "1" ]; then
  bh_log "== Critical canaries (via stage2) =="
  if ! run_critical_canaries "$STAGE2" "$BUILD_DIR/.native_stage2"; then
    bh_err "stage2 critical canaries failed"
    exit 1
  fi
  bh_log "== Semantic canary negatives (via stage2) =="
  if ! run_semantic_canary_negatives "$STAGE2"; then
    bh_err "stage2 semantic canary negatives failed"
    exit 1
  fi
fi

# ———————————————————————————————————————————————————————————————
# Step 4 — stage2 diagnostic ladder
# ———————————————————————————————————————————————————————————————

if [ "$RUN_LADDER" = "1" ]; then
  bh_log "== Stage 2 diagnostic ladder =="
  if ! run_stage2_diag_ladder "$STAGE2" "$BUILD_DIR/.ladder"; then
    bh_err "stage2 diagnostic ladder failed"
    exit 3
  fi
fi

# ———————————————————————————————————————————————————————————————
# Step 5 — stage3 (self-host: stage2 compiles itself)
# ———————————————————————————————————————————————————————————————

bh_log "== Stage 3: self-host via stage2 =="
STAGE3="$BUILD_DIR/tg_stage3"
run_logged stage3_compile \
  "$STAGE2" compile --strict-resolution "$DRIVER_SRC" -o "$STAGE3" --target "$TARGET_TRIPLE"

chmod +x "$STAGE3"
if ! validate_stage tg_stage3 "$STAGE3"; then
  bh_err "stage3 failed validation"
  exit 1
fi

# ———————————————————————————————————————————————————————————————
# Step 5.5 — native canaries + ARM64 encoder/ABI tests
# ———————————————————————————————————————————————————————————————

if [ "$RUN_NATIVE_TESTS" = "1" ]; then
  bh_log "== Native canaries + ARM64 tests (via stage3) =="
  if ! run_native_tests "$STAGE3" "$BUILD_DIR/.native_tests"; then
    bh_err "native canary / ARM64 tests failed"
    exit 1
  fi
fi

# ———————————————————————————————————————————————————————————————
# Step 6 — stage2 == stage3 reproducibility gate (every phase)
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
if ! bh_phase_equality tg_stage2 tg_stage3 "$BUILD_DIR"; then
  bh_err "stage2/stage3 per-phase equality failed — phase fingerprints diverged"
  exit 2
fi

# ———————————————————————————————————————————————————————————————
# Step 7 — two-root reproducibility check
# ———————————————————————————————————————————————————————————————

if [ "$RUN_DETERMINISM" = "1" ]; then
  bh_log "== Two-root reproducibility check (common seed + common host) =="
  if ! check_two_clean_dirs tg_det "$STAGE2" "$BUILD_DIR" "$ROOT_DIR"; then
    bh_err "two-root reproducibility check failed"
    exit 2
  fi
fi

# ———————————————————————————————————————————————————————————————
# Summary
# ———————————————————————————————————————————————————————————————

bh_log "== Bootstrap complete =="
bh_log "stage0:  $STAGE0_BIN"
bh_log "stage1:  $STAGE1"
bh_log "stage2:  $STAGE2"
bh_log "stage3:  $STAGE3"
bh_log "logs:    $BOOT_LOG_DIR"
bh_log "bootstrap OK"

exit 0
