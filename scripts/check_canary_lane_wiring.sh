#!/usr/bin/env bash
# The negative-canary lane is the executable diagnostic oracle:
#   * every MANIFEST row names an existing tests/canary_neg file;
#   * the verifier-stress CI step reads BOTH tab-separated fields and
#     requires rejection PLUS the expected diagnostic fragment.
# This replaces the old source-string parity check, which could pass on a
# dead literal and fail on composed/template diagnostics.
set -u
cd "$(dirname "$0")/.." || exit 2

fail=0
while IFS=$'\t' read -r file expected || [ -n "${file:-}" ]; do
  case "$file" in
    ""|\#*) continue ;;
  esac
  if [ ! -f "tests/canary_neg/$file" ]; then
    echo "canary lane: missing tests/canary_neg/$file" >&2
    fail=1
  fi
  if [ -z "${expected:-}" ]; then
    echo "canary lane: no expected diagnostic for $file" >&2
    fail=1
  fi
done < tests/canary_neg/MANIFEST

if ! grep -qF 'read -r file expected' .woodpecker/verify-core.yaml; then
  echo "canary lane: the verifier-stress step does not read the tab-separated manifest" >&2
  fail=1
fi
if ! grep -qF 'grep -Fq -- "$expected"' .woodpecker/verify-core.yaml; then
  echo "canary lane: the verifier-stress step does not validate the expected diagnostic" >&2
  fail=1
fi

exit "$fail"
