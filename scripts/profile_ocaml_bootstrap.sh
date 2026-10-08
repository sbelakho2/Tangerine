#!/usr/bin/env bash
# profile_ocaml_bootstrap.sh — BOUNDED PROFILING entry point (schema 2).
#
# This script can never emit an authorization sentinel: it runs the
# self-host selfcheck with explicit, hard-capped VM limits and prints
# profiling evidence only.  Authorization is exclusively
# scripts/check_ocaml_bootstrap_complete.sh, whose budgets are pinned and
# which rejects ambient overrides.
#
# CALIBRATION AUTHORITY (this script owns the calibration input):
#   1. scripts/check_ocaml_toolchain.sh verifies the pinned OCaml/dune
#      toolchain, and `dune build` builds the executed binary — fail hard
#      on either, BEFORE any measurement header is printed.
#   2. A machine-readable header (PROFILE_SCHEMA=2) is printed to stdout
#      BEFORE the child runs, carrying the repo identity (RUN_SHA,
#      RUN_TREE_CLEAN), the exact seed binary hash (SEED_SHA256), the
#      kernel manifest hash (MANIFEST_SHA256), the target, the pinned GC
#      policy and the hard caps.
#   3. The child's output is teed to a temp file so the closure
#      fingerprint can be recorded.  The self-host harness prints the
#      closure digest only INSIDE the run (`  fingerprint: <64hex>` and,
#      inside the VM, TG_CHECK_OK closure_sha256=...), so the pre-launch
#      header carries CLOSURE_FINGERPRINT=UNKNOWN and this script appends
#      the observed `CLOSURE_FINGERPRINT=<64hex>` after the child exits.
#      If the run never reaches the manifest load, it stays UNKNOWN.
#   4. After the child exits the script appends exactly
#      `RUN_EXIT=<child exit code>` as the final line (a finalized
#      evidence log always ends with it).
#
# Usage:
#   scripts/profile_ocaml_bootstrap.sh [steps] [rss_mib] [host_calls] [alloc_bytes]
# Defaults: the plan's profiling class — 120e9 steps, 16 GiB RSS,
# 5e9 host calls, 32 GiB allocation (deliberately generous but HARD for
# this run).  Nothing here writes an authorization PASS; the final gate
# pins its own measured limits and rejects ambient overrides.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STEPS="${1:-120000000000}"
RSS_MIB="${2:-16384}"
HOST_CALLS="${3:-5000000000}"
ALLOC_BYTES="${4:-34359738368}"

case "$STEPS" in '' | *[!0-9]*) echo "profile: steps must be an integer" >&2; exit 2 ;; esac
case "$RSS_MIB" in '' | *[!0-9]*) echo "profile: rss_mib must be an integer" >&2; exit 2 ;; esac
case "$HOST_CALLS" in '' | *[!0-9]*) echo "profile: host_calls must be an integer" >&2; exit 2 ;; esac
case "$ALLOC_BYTES" in '' | *[!0-9]*) echo "profile: alloc_bytes must be an integer" >&2; exit 2 ;; esac
if [ "$RSS_MIB" -lt 1024 ]; then echo "profile: rss_mib too small" >&2; exit 2; fi

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

SEED_EXE="$ROOT/stage0_ocaml/_build/default/selfcheck/tg_bootstrap_selfcheck.exe"
MANIFEST="$ROOT/bootstrap/compiler_kernel.manifest"
[ -x "$SEED_EXE" ] || { echo "profile: missing built selfcheck binary: $SEED_EXE" >&2; exit 2; }
[ -f "$MANIFEST" ] || { echo "profile: missing kernel manifest: $MANIFEST" >&2; exit 2; }

RUN_SHA="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || echo UNKNOWN)"
if [ -z "$(git -C "$ROOT" status --porcelain 2>/dev/null)" ]; then
  RUN_TREE_CLEAN=1
else
  RUN_TREE_CLEAN=0
fi
SEED_SHA256="$(sha256_file "$SEED_EXE")"
MANIFEST_SHA256="$(sha256_file "$MANIFEST")"
OCAML_VERSION="$(ocamlopt -version 2>/dev/null | head -1 || echo UNKNOWN)"
DUNE_VERSION="$(dune --version 2>/dev/null | head -1 || echo UNKNOWN)"

# Measurement GC policy: o=40 keeps the major-heap slop near 1.2x live
# (the default space_overhead lets RSS reach ~1.5-2x live and trips the
# RSS cap before the semantic completion point).  Override-able for A/B
# measurement, documented in the recorded metric block.
OCAMLRUNPARAM="${OCAMLRUNPARAM:-o=40}"
export OCAMLRUNPARAM

# ── machine-readable header (BEFORE the child) ───────────────────────
echo "profile_ocaml_bootstrap: steps=${STEPS} rss=${RSS_MIB}MiB host_calls=${HOST_CALLS} alloc=${ALLOC_BYTES} gc=${OCAMLRUNPARAM} (NON-AUTHORIZING)"
echo "PROFILE_SCHEMA=2"
echo "RUN_SHA=${RUN_SHA:-UNKNOWN}"
echo "RUN_TREE_CLEAN=${RUN_TREE_CLEAN}"
echo "RUN_TARGET=${TARGET_TRIPLE}"
echo "SEED_SHA256=${SEED_SHA256}"
echo "MANIFEST_SHA256=${MANIFEST_SHA256}"
# The closure digest is only observable inside the run (see header note).
echo "CLOSURE_FINGERPRINT=UNKNOWN"
echo "OCAML_VERSION=${OCAML_VERSION:-UNKNOWN}"
echo "DUNE_VERSION=${DUNE_VERSION:-UNKNOWN}"
echo "GC_POLICY=${OCAMLRUNPARAM}"
echo "PROFILE_MAX_STEPS=${STEPS}"
echo "PROFILE_MAX_RSS_MIB=${RSS_MIB}"
echo "PROFILE_MAX_HOST_CALLS=${HOST_CALLS}"
echo "PROFILE_MAX_ALLOC=${ALLOC_BYTES}"

CHILD_LOG="$(mktemp "${TMPDIR:-/tmp}/tg_profile_selfcheck.XXXXXX")"
trap 'rm -f "$CHILD_LOG"' EXIT

cd "$ROOT/stage0_ocaml"
set +e
TANGERINE_BOOTSTRAP_VM_MAX_STEPS="$STEPS" \
TANGERINE_BOOTSTRAP_VM_MAX_RSS_MB="$RSS_MIB" \
TANGERINE_BOOTSTRAP_VM_MAX_HOST_CALLS="$HOST_CALLS" \
TANGERINE_BOOTSTRAP_VM_MAX_ALLOC="$ALLOC_BYTES" \
TANGERINE_DEBUG_STEPS=1 \
  "$SEED_EXE" \
  --repo-root .. --target "$TARGET_TRIPLE" 2>&1 | tee "$CHILD_LOG"
CHILD_EXIT="${PIPESTATUS[0]}"
set -e

# Record the closure fingerprint observed INSIDE the child run (the
# harness prints `  fingerprint: <64hex>` at manifest load; an explicit
# CLOSURE_FINGERPRINT= line is honoured first).  A run that never reached
# the manifest load leaves this UNKNOWN.
CLOSURE_FP="$(grep -oE 'CLOSURE_FINGERPRINT=[0-9a-fA-F]{64}' "$CHILD_LOG" 2>/dev/null | tail -1 | cut -d= -f2 || true)"
if [ -z "$CLOSURE_FP" ]; then
  CLOSURE_FP="$(grep -oE 'fingerprint: [0-9a-fA-F]{64}' "$CHILD_LOG" 2>/dev/null | tail -1 | sed 's/.*fingerprint: //' || true)"
fi
echo "CLOSURE_FINGERPRINT=${CLOSURE_FP:-UNKNOWN}"
echo "RUN_EXIT=${CHILD_EXIT}"
