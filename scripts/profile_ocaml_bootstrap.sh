#!/usr/bin/env bash
# profile_ocaml_bootstrap.sh — BOUNDED PROFILING entry point.
#
# This script can never emit an authorization sentinel: it runs the
# self-host selfcheck with explicit, hard-capped VM limits and prints
# profiling evidence only.  Authorization is exclusively
# scripts/check_ocaml_bootstrap_complete.sh, whose budgets are pinned and
# which rejects ambient overrides.
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

cd "$ROOT/stage0_ocaml"
echo "profile_ocaml_bootstrap: steps=${STEPS} rss=${RSS_MIB}MiB host_calls=${HOST_CALLS} alloc=${ALLOC_BYTES} (NON-AUTHORIZING)"
TANGERINE_BOOTSTRAP_VM_MAX_STEPS="$STEPS" \
TANGERINE_BOOTSTRAP_VM_MAX_RSS_MB="$RSS_MIB" \
TANGERINE_BOOTSTRAP_VM_MAX_HOST_CALLS="$HOST_CALLS" \
TANGERINE_BOOTSTRAP_VM_MAX_ALLOC="$ALLOC_BYTES" \
TANGERINE_DEBUG_STEPS=1 \
  "$ROOT/stage0_ocaml/_build/default/selfcheck/tg_bootstrap_selfcheck.exe" \
  --repo-root .. --target aarch64-apple-darwin
