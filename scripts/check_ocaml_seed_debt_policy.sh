#!/usr/bin/env bash
# check_ocaml_seed_debt_policy.sh — the THREE-SCALAR accepted-debt
# monotonic policy (audit P0/P1-1).
#
# ONE authority: the accepted baseline is resolved ONLY by
# stage0_ocaml/selfcheck/tg_bootstrap_accepted.exe --print-debt-json,
# which loads bootstrap/evidence/ocaml/accepted.json through
# Bootstrap_accepted.load_pointer: pointer schema, the record's REAL
# SHA-256, and the debt schema (total >= 0, primary >= 0, secondary >= 0,
# total = primary + secondary).  This helper NEVER parses accepted.json
# itself, NEVER reads a historical evidence record as a substitute for
# the pointer, and NEVER falls back to the hardcoded development
# baseline (TG_BOOTSTRAP_ACCEPTED_OVERRIDE cannot affect this path).
#
# It then enforces the gate's monotonic contract on ALL THREE scalars
# against the caller-supplied current debt (parsed from the
# bootstrap-check output by check_ocaml_seed_health.sh):
#
#   current_total     <= accepted_total
#   current_primary   <= accepted_primary
#   current_secondary <= accepted_secondary
#
# Fail-closed: if the authority is missing, exits non-zero, prints
# nothing, or prints anything other than the one canonical JSON line
# {"record":"<name>","total":T,"primary":P,"secondary":S} whose schema is
# consistent, this helper exits non-zero WITHOUT comparing (no silent
# skip).
#
# Usage:
#   check_ocaml_seed_debt_policy.sh --repo-root <root> \
#       --current-total T --current-primary P --current-secondary S
#
# Exit: 0 = all three scalars within the accepted baseline;
#       1 = policy violation or authority/output failure (fail-closed);
#       2 = usage error.
#
# The regression lane scripts/test_ocaml_seed_debt_policy.sh exercises
# THIS helper (the same one check_ocaml_seed_health.sh invokes) against
# synthetic repo roots: a secondary-only regression, corrupted pointers,
# and malformed authority output must all fail; the real tree must pass.
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SELF_DIR/.." && pwd)"

# Same build convention as every other lane: the dune-built selfcheck
# executable under stage0_ocaml/_build/default/selfcheck/.
AUTHORITY="$ROOT/stage0_ocaml/_build/default/selfcheck/tg_bootstrap_accepted.exe"

usage() {
  echo "usage: $0 --repo-root <root> --current-total T --current-primary P --current-secondary S" >&2
}

fail() {
  echo "check_ocaml_seed_debt_policy: FAIL — $1" >&2
  exit 1
}

is_nonneg_int() {
  case "$1" in
    '' | *[!0-9]*) return 1 ;;
    *) return 0 ;;
  esac
}

REPO_ROOT=""
CUR_TOTAL=""
CUR_PRIMARY=""
CUR_SECONDARY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo-root)
      REPO_ROOT="${2:-}"
      shift 2
      ;;
    --current-total)
      CUR_TOTAL="${2:-}"
      shift 2
      ;;
    --current-primary)
      CUR_PRIMARY="${2:-}"
      shift 2
      ;;
    --current-secondary)
      CUR_SECONDARY="${2:-}"
      shift 2
      ;;
    # Regression-lane only: check_ocaml_seed_health.sh never passes this.
    # It lets scripts/test_ocaml_seed_debt_policy.sh inject fake authority
    # output to prove the malformed/empty cases fail closed.
    --authority-exe)
      AUTHORITY="${2:-}"
      shift 2
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage
      exit 2
      ;;
  esac
done

[ -n "$REPO_ROOT" ] && [ -n "$CUR_TOTAL" ] && [ -n "$CUR_PRIMARY" ] && [ -n "$CUR_SECONDARY" ] \
  || {
    usage
    exit 2
  }
is_nonneg_int "$CUR_TOTAL" && is_nonneg_int "$CUR_PRIMARY" && is_nonneg_int "$CUR_SECONDARY" \
  || fail "current debt scalars must be non-negative integers (got total '$CUR_TOTAL', primary '$CUR_PRIMARY', secondary '$CUR_SECONDARY')"
CUR_TOTAL="$((10#$CUR_TOTAL))"
CUR_PRIMARY="$((10#$CUR_PRIMARY))"
CUR_SECONDARY="$((10#$CUR_SECONDARY))"

[ -x "$AUTHORITY" ] \
  || fail "accepted-debt authority $AUTHORITY is missing or not executable (run dune build in stage0_ocaml first)"

AUTH_OUT="$(mktemp "${TMPDIR:-/tmp}/tg_seed_debt_auth_out.XXXXXX")"
AUTH_ERR="$(mktemp "${TMPDIR:-/tmp}/tg_seed_debt_auth_err.XXXXXX")"
trap 'rm -f "$AUTH_OUT" "$AUTH_ERR"' EXIT

set +e
"$AUTHORITY" --print-debt-json --repo-root "$REPO_ROOT" >"$AUTH_OUT" 2>"$AUTH_ERR"
AUTH_STATUS=$?
set -e
if [ "$AUTH_STATUS" -ne 0 ]; then
  {
    echo "check_ocaml_seed_debt_policy: FAIL — accepted-debt authority exited $AUTH_STATUS (fail-closed: refusing to compare against an unverified baseline)"
    sed 's/^/  authority: /' "$AUTH_ERR" || true
  } >&2
  exit 1
fi

AUTH_LINES="$(wc -l <"$AUTH_OUT" | tr -d ' ')"
OUT="$(cat "$AUTH_OUT")"
JSON_RE='^\{"record":"([^"]*)","total":([0-9]+),"primary":([0-9]+),"secondary":([0-9]+)\}$'
if [ "$AUTH_LINES" != "1" ] || ! [[ "$OUT" =~ $JSON_RE ]]; then
  {
    echo "check_ocaml_seed_debt_policy: FAIL — accepted-debt authority output is missing or malformed (fail-closed: refusing to compare)"
    echo "  expected exactly one line: {\"record\":\"<name>\",\"total\":T,\"primary\":P,\"secondary\":S}"
    echo "  got ($AUTH_LINES line(s)): $OUT"
  } >&2
  exit 1
fi
RECORD="${BASH_REMATCH[1]}"
ACC_TOTAL="$((10#${BASH_REMATCH[2]}))"
ACC_PRIMARY="$((10#${BASH_REMATCH[3]}))"
ACC_SECONDARY="$((10#${BASH_REMATCH[4]}))"
if [ -z "$RECORD" ] || [ "$ACC_TOTAL" -ne "$((ACC_PRIMARY + ACC_SECONDARY))" ]; then
  fail "accepted-debt authority output has an inconsistent schema (total $ACC_TOTAL <> primary $ACC_PRIMARY + secondary $ACC_SECONDARY)"
fi

echo "check_ocaml_seed_debt_policy: accepted baseline $RECORD (pointer + REAL SHA-256 verified): total $ACC_TOTAL / primary $ACC_PRIMARY / secondary $ACC_SECONDARY"
echo "check_ocaml_seed_debt_policy: current debt: total $CUR_TOTAL / primary $CUR_PRIMARY / secondary $CUR_SECONDARY"

if [ "$CUR_PRIMARY" -gt "$ACC_PRIMARY" ]; then
  fail "debt_primary grew vs the accepted record ($CUR_PRIMARY > $ACC_PRIMARY)"
fi
if [ "$CUR_TOTAL" -gt "$ACC_TOTAL" ]; then
  fail "debt_total grew vs the accepted record ($CUR_TOTAL > $ACC_TOTAL)"
fi
if [ "$CUR_SECONDARY" -gt "$ACC_SECONDARY" ]; then
  fail "debt_secondary grew vs the accepted record ($CUR_SECONDARY > $ACC_SECONDARY)"
fi

echo "check_ocaml_seed_debt_policy: debt policy — monotonic no-regression on total/primary/secondary: PASS"
exit 0
