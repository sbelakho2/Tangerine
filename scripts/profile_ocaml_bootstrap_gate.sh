#!/usr/bin/env bash
# profile_ocaml_bootstrap_gate.sh — NON-AUTHORIZING aggregate profiling.
#
# Profiles the ACTUAL final workload used by the authorization gate
# (scripts/check_ocaml_bootstrap_complete.sh): `dune build`, then
# stage0_ocaml/_build/default/selfcheck/tg_bootstrap_gate.exe
# --repo-root .. --target <triple> under the pinned GC policy and
# explicit, generous HARD VM caps, with a whole-gate wall clock.
#
# This script is measurement-only and can NEVER authorize the bootstrap:
# the authorization sentinel is printed exclusively by
# scripts/check_ocaml_bootstrap_complete.sh, and this script does not
# contain that wording at all (scripts/test_prebootstrap_gates.sh proves
# it textually).  It prints the same machine-readable header as
# profile_ocaml_bootstrap.sh (PROFILE_SCHEMA=2) BEFORE the gate runs:
#
#   PROFILE_SCHEMA=2 RUN_SHA RUN_TREE_CLEAN RUN_TARGET SEED_SHA256
#   MANIFEST_SHA256 CLOSURE_FINGERPRINT OCAML_VERSION DUNE_VERSION
#   GC_POLICY PROFILE_MAX_STEPS/RSS_MIB/HOST_CALLS/ALLOC
#
# SEED_SHA256 hashes the executed gate binary (the aggregate wrapper's
# "seed" is the gate executable; the standalone wrapper hashes the
# selfcheck executable).  CLOSURE_FINGERPRINT is recorded from the
# child's `  fingerprint: <64hex>` line after exit, like the standalone
# wrapper.  After the child exits the script appends
# `RUN_EXIT=<child exit code>` and `AGGREGATE_WALL_S=<seconds>` (the
# whole-gate wall clock, integer seconds; the coordinator turns it into
# GATE_TIMEOUT_S with the measured margin).
#
# VM A and VM B in the gate's output (per the gate/driver source):
#   VM A — the artifact-corpus compile inside Driver.run_bootstrap_closure
#          (before the [11/11] marker): the kernel compiles+links+runs
#          tests/differential/corpus/01_defs_arith.tg.
#   VM B — the self-host preflight after the [11/11] marker: the kernel
#          checks tg_compiler/bootstrap_main.tg (strict resolution,
#          --bootstrap-proof, stop after MONO) in a FRESH VM.
# With TANGERINE_DEBUG_STEPS=1 both VMs stream VM BEACON / VM STEPS
# lines; profile_record_metrics.sh sections them into VM_A_*/VM_B_*.
#
# Usage:
#   scripts/profile_ocaml_bootstrap_gate.sh [--dry-run] [steps] [rss_mib] [host_calls] [alloc_bytes]
#   --dry-run: run the toolchain check + dune build, print the header,
#              then exit BEFORE executing the gate (no gate wall clock).
# Defaults: 120e9 steps, 16 GiB RSS, 5e9 host calls, 32 GiB allocation
# (generous but HARD).  PROFILE_WALL_TIMEOUT_S (default 14400) bounds the
# gate process; the coordinator does the real cold/warm runs later.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

DRY_RUN=0
if [ "${1:-}" = "--dry-run" ]; then
  DRY_RUN=1
  shift
fi

STEPS="${1:-120000000000}"
RSS_MIB="${2:-16384}"
HOST_CALLS="${3:-5000000000}"
ALLOC_BYTES="${4:-34359738368}"
WALL_TIMEOUT_S="${PROFILE_WALL_TIMEOUT_S:-14400}"

case "$STEPS" in '' | *[!0-9]*) echo "profile_gate: steps must be an integer" >&2; exit 2 ;; esac
case "$RSS_MIB" in '' | *[!0-9]*) echo "profile_gate: rss_mib must be an integer" >&2; exit 2 ;; esac
case "$HOST_CALLS" in '' | *[!0-9]*) echo "profile_gate: host_calls must be an integer" >&2; exit 2 ;; esac
case "$ALLOC_BYTES" in '' | *[!0-9]*) echo "profile_gate: alloc_bytes must be an integer" >&2; exit 2 ;; esac
case "$WALL_TIMEOUT_S" in '' | *[!0-9]*) echo "profile_gate: PROFILE_WALL_TIMEOUT_S must be an integer" >&2; exit 2 ;; esac
if [ "$RSS_MIB" -lt 1024 ]; then echo "profile_gate: rss_mib too small" >&2; exit 2; fi

TARGET_TRIPLE="${TG_BOOTSTRAP_TARGET:-aarch64-apple-darwin}"

sha256_file() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum < "$1" | cut -d' ' -f1
  else
    shasum -a 256 < "$1" | cut -d' ' -f1
  fi
}

# ── calibration authority: pinned toolchain + build (fail hard) ──────
"$ROOT/scripts/check_ocaml_toolchain.sh"
( cd "$ROOT/stage0_ocaml" && dune build )

GATE_EXE="$ROOT/stage0_ocaml/_build/default/selfcheck/tg_bootstrap_gate.exe"
MANIFEST="$ROOT/bootstrap/compiler_kernel.manifest"
[ -x "$GATE_EXE" ] || { echo "profile_gate: missing built gate binary: $GATE_EXE" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "profile_gate: missing kernel manifest: $MANIFEST" >&2; exit 2; }

RUN_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
if [ -z "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  RUN_TREE_CLEAN=1
else
  RUN_TREE_CLEAN=0
fi
SEED_SHA256="$(sha256_file "$GATE_EXE")"
MANIFEST_SHA256="$(sha256_file "$MANIFEST")"
OCAML_VERSION="$(ocamlopt -version 2>/dev/null | head -1 || echo UNKNOWN)"
DUNE_VERSION="$(dune --version 2>/dev/null | head -1 || echo UNKNOWN)"

# Same measurement GC policy as the standalone profiler (documented in
# the recorded metric block; override-able for A/B measurement).
OCAMLRUNPARAM="${OCAMLRUNPARAM:-o=40}"
export OCAMLRUNPARAM

# ── machine-readable header (BEFORE the gate child) ──────────────────
echo "profile_ocaml_bootstrap_gate: steps=${STEPS} rss=${RSS_MIB}MiB host_calls=${HOST_CALLS} alloc=${ALLOC_BYTES} gc=${OCAMLRUNPARAM} wall_timeout=${WALL_TIMEOUT_S}s (NON-AUTHORIZING aggregate profiling; not authorization)"
echo "PROFILE_SCHEMA=2"
echo "RUN_SHA=${RUN_SHA:-UNKNOWN}"
echo "RUN_TREE_CLEAN=${RUN_TREE_CLEAN}"
echo "RUN_TARGET=${TARGET_TRIPLE}"
echo "SEED_SHA256=${SEED_SHA256}"
echo "MANIFEST_SHA256=${MANIFEST_SHA256}"
# The closure digest is only observable inside the run.
echo "CLOSURE_FINGERPRINT=UNKNOWN"
echo "OCAML_VERSION=${OCAML_VERSION:-UNKNOWN}"
echo "DUNE_VERSION=${DUNE_VERSION:-UNKNOWN}"
echo "GC_POLICY=${OCAMLRUNPARAM}"
echo "PROFILE_MAX_STEPS=${STEPS}"
echo "PROFILE_MAX_RSS_MIB=${RSS_MIB}"
echo "PROFILE_MAX_HOST_CALLS=${HOST_CALLS}"
echo "PROFILE_MAX_ALLOC=${ALLOC_BYTES}"

if [ "$DRY_RUN" = 1 ]; then
  echo "PROFILE_DRY_RUN=1"
  exit 0
fi

CHILD_LOG="$(mktemp "${TMPDIR:-/tmp}/tg_profile_gate.XXXXXX")"
trap 'rm -f "$CHILD_LOG"' EXIT

# shellcheck source=scripts/bootstrap_helpers.sh
source "$ROOT/scripts/bootstrap_helpers.sh"

cd "$ROOT/stage0_ocaml"
START_S="$(date +%s)"
set +e
TANGERINE_BOOTSTRAP_VM_MAX_STEPS="$STEPS" \
TANGERINE_BOOTSTRAP_VM_MAX_RSS_MB="$RSS_MIB" \
TANGERINE_BOOTSTRAP_VM_MAX_HOST_CALLS="$HOST_CALLS" \
TANGERINE_BOOTSTRAP_VM_MAX_ALLOC="$ALLOC_BYTES" \
TANGERINE_DEBUG_STEPS=1 \
  bh_run_with_timeout "$WALL_TIMEOUT_S" \
  "$GATE_EXE" --repo-root .. --target "$TARGET_TRIPLE" 2>&1 | tee "$CHILD_LOG"
CHILD_EXIT="${PIPESTATUS[0]}"
END_S="$(date +%s)"
set -e
AGGREGATE_WALL_S=$((END_S - START_S))

CLOSURE_FP="$(grep -oE 'CLOSURE_FINGERPRINT=[0-9a-fA-F]{64}' "$CHILD_LOG" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
if [ -z "$CLOSURE_FP" ]; then
  CLOSURE_FP="$(grep -oE 'fingerprint: [0-9a-fA-F]{64}' "$CHILD_LOG" 2>/dev/null | tail -1 | sed 's/.*fingerprint: //' || true)"
fi
echo "CLOSURE_FINGERPRINT=${CLOSURE_FP:-UNKNOWN}"
echo "RUN_EXIT=${CHILD_EXIT}"
echo "AGGREGATE_WALL_S=${AGGREGATE_WALL_S}"
