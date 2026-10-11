#!/usr/bin/env bash
#
# tests/run_cfg_matrix_tests.sh — the @cfg cross-target matrix (P0 gate).
#
# The @cfg evaluation is a compile-time pass: the driver's --target flag
# selects the SAME TargetSpec resolve_codegen_target feeds
# apply_cfg_elimination, so the matrix drives the pass with the explicit
# target options (never relying on the host being the asserted target).
#
# The matrix (each case is checked with `tg check --target <triple>` so
# the assertion is front-end semantics — parse/merge -> @cfg elimination ->
# resolution/type-checking — with no codegen/link dependence):
#
#   (a+) tests/cfg_matrix/canary_pos_cfg_linux.tg
#       --target x86_64-linux-gnu   -> MUST CHECK CLEAN (linux member exists)
#   (a-) tests/cfg_matrix/canary_neg_cfg_macos_symbol_on_linux.tg
#       --target x86_64-linux-gnu   -> MUST BE REJECTED with
#                                      "unresolved name: cfg_macos_marker"
#                                      (the macos member does not exist on
#                                      linux; the un-gated reference fails)
#   (b+) tests/cfg_matrix/canary_pos_cfg_macos.tg
#       --target aarch64-apple-darwin -> MUST CHECK CLEAN (macos member exists)
#   (b-) tests/cfg_matrix/canary_neg_cfg_linux_symbol_on_macos.tg
#       --target aarch64-apple-darwin -> MUST BE REJECTED with
#                                        "unresolved name: cfg_linux_marker"
#   (c)  tests/cfg_matrix/canary_neg_cfg_ungated_windows_ref.tg
#       --target aarch64-apple-darwin AND --target x86_64-linux-gnu
#       -> MUST BE REJECTED with "unresolved name: cfg_windows_marker"
#       (an un-gated reference to an unavailable symbol fails on EVERY
#       non-windows target; the deleted resurrection cannot make it legal)
#   host tests/cfg_matrix/canary_pos_cfg_host_family.tg
#       --target <host triple>      -> MUST COMPILE AND RUN, exit code 0
#       (the target-kept member of the mutually exclusive family resolves;
#       the family is host-agnostic)
#
# A POSITIVE case must check clean; a NEGATIVE case must be rejected AND
# the rejection must contain the EXPECTED unresolved-name diagnostic
# (never merely any error — an unrelated failure is a matrix failure).
#
# Usage: tests/run_cfg_matrix_tests.sh [compiler] [outdir] [host-triple]
#   compiler    defaults to build/tg
#   outdir      defaults to build/.cfg_matrix
#   host-triple defaults to aarch64-apple-darwin (the bootstrap default;
#               pass the resolved TG_BOOTSTRAP_TARGET / TARGET_TRIPLE when
#               the harness resolved something else)

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPILER="${1:-build/tg}"
OUTDIR="${2:-build/.cfg_matrix}"
HOST_TRIPLE="${3:-aarch64-apple-darwin}"
LINUX_TRIPLE="x86_64-linux-gnu"
DARWIN_TRIPLE="aarch64-apple-darwin"

if [ ! -x "$COMPILER" ]; then
  echo "cfg matrix: compiler binary not executable: $COMPILER" >&2
  exit 1
fi

mkdir -p "$OUTDIR"

failures=0
total=0

# expect_check <file> <triple> <expected-substring-or-EMPTY-for-clean>
expect_check() {
  local file="$1" triple="$2" expect="$3"
  total=$((total + 1))
  local name
  name="$(basename "$file" .tg)"
  local out
  out="$("$COMPILER" check "$file" --target "$triple" 2>&1)"
  local exitcode=$?
  if [ -z "$expect" ]; then
    if [ "$exitcode" -eq 0 ]; then
      echo "cfg matrix OK  : $name ($triple) checks clean"
      return 0
    fi
    echo "cfg matrix FAIL: $name ($triple) expected clean check, got exit $exitcode:" >&2
    printf '%s\n' "$out" | head -n 5 | sed 's/^/    /' >&2
    failures=$((failures + 1))
    return 1
  fi
  if [ "$exitcode" -eq 0 ]; then
    echo "cfg matrix FAIL: $name ($triple) ACCEPTED (expected rejection '$expect')" >&2
    failures=$((failures + 1))
    return 1
  fi
  if ! printf '%s' "$out" | grep -qF "$expect"; then
    echo "cfg matrix FAIL: $name ($triple) rejected but WITHOUT '$expect':" >&2
    printf '%s\n' "$out" | head -n 5 | sed 's/^/    /' >&2
    failures=$((failures + 1))
    return 1
  fi
  echo "cfg matrix OK  : $name ($triple) rejected with '$expect'"
  return 0
}

# (a+) / (a-): the linux target keeps exactly the linux member.
expect_check "tests/cfg_matrix/canary_pos_cfg_linux.tg" "$LINUX_TRIPLE" "" || true
expect_check "tests/cfg_matrix/canary_neg_cfg_macos_symbol_on_linux.tg" "$LINUX_TRIPLE" "unresolved name: cfg_macos_marker" || true

# (b+) / (b-): the macos target keeps exactly the macos member.
expect_check "tests/cfg_matrix/canary_pos_cfg_macos.tg" "$DARWIN_TRIPLE" "" || true
expect_check "tests/cfg_matrix/canary_neg_cfg_linux_symbol_on_macos.tg" "$DARWIN_TRIPLE" "unresolved name: cfg_linux_marker" || true

# (c): an un-gated reference to an unavailable symbol fails on every
# non-windows target.
expect_check "tests/cfg_matrix/canary_neg_cfg_ungated_windows_ref.tg" "$DARWIN_TRIPLE" "unresolved name: cfg_windows_marker" || true
expect_check "tests/cfg_matrix/canary_neg_cfg_ungated_windows_ref.tg" "$LINUX_TRIPLE" "unresolved name: cfg_windows_marker" || true

# host: the host-agnostic family canary compiles AND runs (exit code 0).
total=$((total + 1))
HOST_BIN="$OUTDIR/canary_pos_cfg_host_family"
if ! "$COMPILER" compile "tests/cfg_matrix/canary_pos_cfg_host_family.tg" -o "$HOST_BIN" --target "$HOST_TRIPLE" >/dev/null 2>&1; then
  echo "cfg matrix FAIL: canary_pos_cfg_host_family ($HOST_TRIPLE) failed to compile" >&2
  failures=$((failures + 1))
elif ! "$HOST_BIN" >/dev/null 2>&1; then
  echo "cfg matrix FAIL: canary_pos_cfg_host_family ($HOST_TRIPLE) ran but exited nonzero" >&2
  failures=$((failures + 1))
else
  echo "cfg matrix OK  : canary_pos_cfg_host_family ($HOST_TRIPLE) compiled and ran (exit 0)"
fi

echo ""
echo "cfg matrix: $((total - failures))/$total passed (linux/macos presence, absence, un-gated-reference rejection)"
if [ "$failures" -ne 0 ]; then
  echo "cfg matrix FAILED: $failures problem(s)" >&2
  exit 1
fi
echo "cfg matrix OK"
exit 0
