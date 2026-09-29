#!/usr/bin/env bash
# check_repo_artifact_hygiene.sh — repository-artifact hygiene gate (audit P0-1).
#
# Fails when a TRACKED file is a compiled artifact (ELF / Mach-O / PE /
# ar archive / object file) outside the explicit fixture allowlist, or
# when an explicitly banned generated path is tracked.  This is the cheap
# regression that keeps a successful bootstrap gate (or a local compile)
# from committing a native binary into the repository root again.
#
# The check is purely index-based (`git ls-files`) plus an 8-byte magic
# read per tracked file, so it costs well under a second and never
# depends on the toolchain, a build, or `file(1)`.
#
# Usage: scripts/check_repo_artifact_hygiene.sh [repo-root]
# Exit: 0 clean, 1 artifact/banned path found.
set -euo pipefail

ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
cd "$ROOT"

# Explicit fixture allowlist: generated-binary fixtures that are
# deliberately tracked.  Extend only with a companion comment naming the
# consuming test.
ALLOWLIST=(
  # shellcheck disable=SC2054
  'tests/fixtures/'
)

# Generated paths that must never be tracked, wherever magic detection
# might miss them (an empty or truncated file, a text wrapper, ...).
# The scan loop below bans bootstrap_gate.out / bootstrap_check.out /
# tg_stage{1,2,3} / tg at the repository root and *.o / *.out at any
# depth (build outputs everywhere in this repository).

allowed() {
  local f="$1" p
  for p in "${ALLOWLIST[@]}"; do
    case "$f" in
      "$p"*) return 0 ;;
    esac
  done
  return 1
}

# 8-byte magic classification (inlined in the scan loop: one fork-free
# read per file, no subshell per tracked path).  Mach-O magics are
# byteswapped-endian aware; PE starts with the DOS "MZ" stub.  None of
# the targeted magics contain a NUL byte, so bash's NUL elision cannot
# corrupt the prefix.
violations=0
while IFS= read -r -d '' f; do
  if allowed "$f"; then
    continue
  fi
  case "$f" in
    bootstrap_gate.out|bootstrap_check.out)
      printf 'ARTIFACT HYGIENE: banned tracked path: %s (generated bootstrap gate artifact; must be written under build/)\n' "$f" >&2
      violations=$((violations + 1))
      continue ;;
    tg_stage1|tg_stage2|tg_stage3|tg)
      printf 'ARTIFACT HYGIENE: banned tracked path: %s (generated bootstrap stage binary; must be written under build/)\n' "$f" >&2
      violations=$((violations + 1))
      continue ;;
    *.o)
      printf 'ARTIFACT HYGIENE: banned tracked path: %s (object file/build output)\n' "$f" >&2
      violations=$((violations + 1))
      continue ;;
    *.out)
      printf 'ARTIFACT HYGIENE: banned tracked path: %s (generated .out binary/artifact)\n' "$f" >&2
      violations=$((violations + 1))
      continue ;;
  esac
  head=""
  LC_ALL=C IFS= read -r -N 8 head < "$f" 2>/dev/null || true
  label=""
  case "$head" in
    $'\x7fELF'*)                               label='ELF' ;;
    $'\xcf\xfa\xed\xfe'*|$'\xce\xfa\xed\xfe'*) label='Mach-O (little-endian)' ;;
    $'\xfe\xed\xfa\xce'*|$'\xfe\xed\xfa\xcf'*) label='Mach-O (big-endian/native)' ;;
    $'\xca\xfe\xba\xbe'*|$'\xbe\xba\xfe\xca'*) label='Mach-O universal/fat' ;;
    MZ*)                                       label='PE (MZ)' ;;
    '!<arch>'*)                                label='ar archive' ;;
  esac
  if [ -n "$label" ]; then
    printf 'ARTIFACT HYGIENE: tracked compiled artifact: %s (%s)\n' "$f" "$label" >&2
    violations=$((violations + 1))
  fi
done < <(git ls-files -z)

if [ "$violations" -ne 0 ]; then
  printf 'ARTIFACT HYGIENE: FAIL — %d tracked artifact(s); generated outputs belong under build/ and are never committed\n' \
    "$violations" >&2
  exit 1
fi

printf 'ARTIFACT HYGIENE: PASS — no tracked compiled artifacts or banned generated paths (%s tracked files scanned)\n' \
  "$(git ls-files | wc -l | tr -d ' ')"
exit 0
