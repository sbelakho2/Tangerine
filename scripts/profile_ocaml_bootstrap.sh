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
#   scripts/profile_ocaml_bootstrap.sh [steps] [rss_mib]
# Defaults: 120e9 steps / 14336 MiB RSS (the established profiling
# class).  Both caps are HARD for this run; nothing here writes a PASS.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STEPS="${1:-120000000000}"
RSS_MIB="${2:-14336}"

case "$STEPS" in '' | *[!0-9]*) echo "profile: steps must be an integer" >&2; exit 2 ;; esac
case "$RSS_MIB" in '' | *[!0-9]*) echo "profile: rss_mib must be an integer" >&2; exit 2 ;; esac
if [ "$RSS_MIB" -lt 1024 ]; then echo "profile: rss_mib too small" >&2; exit 2; fi

cd "$ROOT/stage0_ocaml"
echo "profile_ocaml_bootstrap: steps=${STEPS} rss=${RSS_MIB}MiB (NON-AUTHORIZING)"
TANGERINE_BOOTSTRAP_VM_MAX_STEPS="$STEPS" \
TANGERINE_BOOTSTRAP_VM_MAX_RSS_MB="$RSS_MIB" \
TANGERINE_DEBUG_STEPS=1 \
  "$ROOT/stage0_ocaml/_build/default/selfcheck/tg_bootstrap_selfcheck.exe" \
  --repo-root .. --target aarch64-apple-darwin
