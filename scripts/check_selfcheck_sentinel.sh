#!/usr/bin/env bash
# check_selfcheck_sentinel.sh — verify one selfcheck's success sentinel.
#
# Audit P0-4: a selfcheck counts as green only when it exits 0 AND its
# captured output contains EXACTLY ONE line
#
#   TANGERINE_SELFCHECK_PASS name=<name> version=1
#
# A loose `grep PASS` is never used (error text can contain the word).
# This helper is the ONE verifier; scripts/check_ocaml_seed_health.sh
# invokes it per selfcheck, and scripts/test_selfcheck_sentinel.sh proves
# its reject/pass behaviour against synthetic outputs.
#
# Usage: check_selfcheck_sentinel.sh <name> <captured-output-file>
# Exit: 0 exactly one matching line, 1 otherwise.
set -euo pipefail

name="${1:?usage: check_selfcheck_sentinel.sh <name> <captured-output-file>}"
out="${2:?usage: check_selfcheck_sentinel.sh <name> <captured-output-file>}"

marker="TANGERINE_SELFCHECK_PASS name=${name} version=1"

if [ ! -f "$out" ]; then
  echo "selfcheck-sentinel: FAIL — no captured output for ${name} at ${out}" >&2
  exit 1
fi

count="$(grep -Fxc "$marker" "$out" || true)"
if [ "$count" != "1" ]; then
  echo "selfcheck-sentinel: FAIL — ${name} exited 0 without exactly one success sentinel (found ${count:-0} exact line(s) '${marker}')" >&2
  exit 1
fi

# Exactly one sentinel GLOBALLY: one selfcheck's output must never carry a
# second check's marker (a cross-contaminated or duplicated emission is a
# harness-integrity failure, not a pass).
total="$(grep -cE '^TANGERINE_SELFCHECK_PASS ' "$out" || true)"
if [ "$total" != "1" ]; then
  echo "selfcheck-sentinel: FAIL — ${name} output contains ${total:-0} sentinel line(s) (exactly one global sentinel per selfcheck required)" >&2
  exit 1
fi

exit 0
