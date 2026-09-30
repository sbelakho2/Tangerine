#!/usr/bin/env bash
# check_unit_test_evidence.sh — the ONE unit-test evidence rule.
#
# The caller has already verified the process exited 0 (exit status and
# timeout handling stay in the caller); this helper verifies the TEXTUAL
# evidence is exactly one pinned summary line:
#
#   <pinned> passed, 0 failed
#
# A binary that prints the summary and then hangs is killed by the
# caller's timeout; a binary that prints a wrong or duplicated summary
# never satisfies this rule.  Both check_ocaml_seed_health.sh and
# prebootstrap_quick.sh consume this helper so the two lanes cannot drift.
#
# Usage: check_unit_test_evidence.sh <captured-output-file> [pinned-total]
# Exit: 0 exactly one pinned line, 1 otherwise.
set -euo pipefail

out="${1:?usage: check_unit_test_evidence.sh <captured-output-file> [pinned-total]}"
pinned="${2:-230}"
marker="${pinned} passed, 0 failed"

count="$(grep -Fxc "$marker" "$out" || true)"
if [ "$count" != "1" ]; then
  echo "unit-evidence: FAIL — expected exactly one exact line '${marker}' in ${out} (found ${count:-0})" >&2
  grep -E '[0-9]+ passed, [0-9]+ failed' "$out" | tail -3 >&2 || true
  exit 1
fi
exit 0
