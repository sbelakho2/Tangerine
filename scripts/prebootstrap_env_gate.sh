#!/usr/bin/env bash
# prebootstrap_env_gate.sh — reject degraded escape variables before a
# full bootstrap (audit P0-5).
#
# The repository exposes development escape valves that turn a mandatory
# semantic test into a skip or a warning.  They are legitimate
# interactively, but a full bootstrap attempt must never run under them:
# its evidence would claim a closure the run did not actually prove.
#
# Forbidden before prebootstrap / full bootstrap (any value other than
# unset or 0 fails; the canonical degraded value is 1):
#   TG_BOOTSTRAP_ACCEPTED_OVERRIDE=1      accepted-debt authority override
#                                         (hardcoded development baseline)
#   TG_GRAMMAR_GATE_ALLOW_PARITY_SKIP=1   grammar gate structural-only run
#                                         (no parse-parity / conformance)
#
# Usage: scripts/prebootstrap_env_gate.sh
# Exit: 0 clean, 1 a forbidden override is set.
set -euo pipefail

fail=0

check_forbidden() {
  local var="$1" why="$2" val
  val="${!var-}"
  if [ -z "$val" ]; then
    return 0
  fi
  if [ "$val" != "0" ]; then
    echo "[prebootstrap-env:error] ${var}=${val} is forbidden before a full bootstrap: ${why}" >&2
    fail=1
  fi
}

check_forbidden TG_BOOTSTRAP_ACCEPTED_OVERRIDE \
  "it swaps the verified accepted-debt authority for the hardcoded development baseline (degraded evidence)"
check_forbidden TG_GRAMMAR_GATE_ALLOW_PARITY_SKIP \
  "it runs the grammar gate structural-only, skipping closure parse-parity and the conformance corpus"
check_forbidden TG_ALLOW_UNBOUNDED_FINAL \
  "it removes the mandatory RSS ceiling from the final authorization (degraded safety evidence)"
check_forbidden TG_FINAL_RSS_MEASUREMENT \
  "it enables the measurement-only RSS override on the authorization route"

if [ "$fail" -ne 0 ]; then
  echo "[prebootstrap-env:error] unset/zero the variable(s) above for a full, non-degraded run" >&2
  exit 1
fi

echo "prebootstrap-env: PASS — no degraded escape overrides present"
exit 0
