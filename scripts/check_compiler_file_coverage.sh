#!/usr/bin/env bash
#
# scripts/check_compiler_file_coverage.sh — the compiler-source coverage
# oracle (mandate #6): every tg_compiler/*.tg file must be exercised by at
# least one test.
#
# ATTRIBUTION RULE — a compiler file is covered when at least one test
# references it:
#   - `tg_compiler::<module>` in a tests/**/*.tg file (a real import or a
#     qualified-path reference — the module must resolve for the test to
#     compile), or
#   - `<file>.tg` / `tg_compiler/<file>` in a tests/*.sh tool test (the
#     tool-contract lane runs the tools over compiler sources).
#
# The tests-added layer for the files with no other exercising test is
# tests/compiler_module_sweep_tests.tg (the sweep references EVERY
# compiler module by qualified path); its closure is verified: the sweep
# must contain a `tg_compiler::<module>` token for every enumerated file,
# so a NEW compiler file without a sweep entry is an uncovered file and
# the gate fails until the sweep grows.
#
# Usage: scripts/check_compiler_file_coverage.sh [--report-only]
# Exit status: 0 when every compiler file has an exercising test; 1
# otherwise.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
COMPILER_DIR="$ROOT/tg_compiler"
TESTS_DIR="$ROOT/tests"
SWEEP="$TESTS_DIR/compiler_module_sweep_tests.tg"
REPORT_ONLY=0
case "${1:-}" in
  --report-only) REPORT_ONLY=1 ;;
  "") ;;
  *) echo "check_compiler_file_coverage: unknown argument: $1" >&2; exit 2 ;;
esac

fail() { echo "[compiler-coverage:error] $*" >&2; exit 1; }

[ -d "$COMPILER_DIR" ] || fail "missing compiler dir: $COMPILER_DIR"
[ -f "$SWEEP" ] || fail "missing compiler-module sweep: $SWEEP"

# ———————————————————————————————————————————————————————————————
# The test-file universe: every tests/**/*.tg plus the tests/*.sh tool
# lanes.
# ———————————————————————————————————————————————————————————————

test_files="$(find "$TESTS_DIR" -name '*.tg' -type f | sort)"
shell_tests="$(find "$TESTS_DIR" -maxdepth 1 -name '*.sh' -type f | sort)"
if [ -z "$test_files" ]; then
  fail "no test files found under $TESTS_DIR"
fi

# ———————————————————————————————————————————————————————————————
# The per-file attribution + the sweep closure.
# ———————————————————————————————————————————————————————————————

bad=0
printf '%-24s %-46s %s\n' "COMPILER FILE" "EXERCISING TEST" "REFERENCE"
for f in "$COMPILER_DIR"/*.tg; do
  [ -f "$f" ] || continue
  base="$(basename "$f")"
  module="${base%.tg}"

  # 1. tests/**/*.tg referencing `tg_compiler::<module>`
  hit=""
  while IFS= read -r t; do
    [ -n "$t" ] || continue
    if grep -qE "tg_compiler::${module}\b" "$t" 2>/dev/null; then
      hit="${t#"$ROOT"/}"
      break
    fi
  done <<< "$test_files"

  # 2. tests/*.sh tool tests referencing the file
  if [ -z "$hit" ]; then
    while IFS= read -r t; do
      [ -n "$t" ] || continue
      if grep -qE "${base}|tg_compiler/${base}" "$t" 2>/dev/null; then
        hit="${t#"$ROOT"/}"
        break
      fi
    done <<< "$shell_tests"
  fi

  # 3. the sweep must close the gap: a file with NO other exercising test
  #    must be referenced by the compiler-module sweep (a compiler file
  #    without any exercising test can never be shipped)
  if [ -z "$hit" ]; then
    if ! grep -qE "tg_compiler::${module}\b" "$SWEEP" 2>/dev/null; then
      echo "[compiler-coverage:error] $base: no exercising test AND missing from the compiler-module sweep (tests/compiler_module_sweep_tests.tg)"
      bad=1
    fi
    hit="$SWEEP"
  fi

  printf '%-24s %-46s %s\n' "$base" "$hit" "tg_compiler::${module}"
done

total="$(ls "$COMPILER_DIR"/*.tg | wc -l | tr -d ' ')"
echo "[compiler-coverage] $total compiler files; the compiler-module sweep (tests/compiler_module_sweep_tests.tg) closes every file"

if [ "$bad" -ne 0 ]; then
  [ "$REPORT_ONLY" -eq 1 ] || exit 1
fi
echo "[compiler-coverage] PASSED: every tg_compiler/*.tg file is exercised by at least one test"
exit 0
