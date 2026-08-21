#!/usr/bin/env bash
#
# tests/run_test_runner_integrity.sh — P0 verification-integrity gate for `tg test`.
#
# `tg test` must distinguish its outcomes:
#   1. an EXPLICITLY named file whose tests all pass exits 0;
#   2. an explicitly named file with a failing test exits nonzero;
#   3. an explicitly named file with ZERO @test functions exits nonzero and
#      prints the "no tests found in <file>" diagnostic (it must be verified
#      with `tg check` instead);
#   4. an explicitly named file that fails to parse exits nonzero AND emits
#      the parse diagnostics (never skipped);
#   5. implicit discovery selects only RECOGNIZED test sources: a directory
#      scan containing a broken NON-test source next to a passing file exits
#      0 (the broken file is never selected); a recognized TEST source that
#      fails to compile exits nonzero (no silent vanish).
#
# Usage: tests/run_test_runner_integrity.sh [compiler]
#   compiler defaults to build/tg (the CI-materialized stage3 artifact).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPILER="${1:-build/tg}"

if [ ! -x "$COMPILER" ]; then
  echo "::error::test-runner integrity: compiler binary not executable: $COMPILER" >&2
  exit 1
fi

WORK="build/.tg_test_integrity"
rm -rf "$WORK"
mkdir -p "$WORK"

fail() {
  echo "::error::test-runner integrity: $1" >&2
  exit 1
}

cat > "$WORK/pass.tg" <<'EOF'
use std::test::*

@test
def test_trivial_pass() -> Unit
  assert_eq(1 + 1, 2)
end
EOF

cat > "$WORK/fail.tg" <<'EOF'
use std::test::*

@test
def test_trivial_fail() -> Unit
  assert_eq(1, 2)
end
EOF

cat > "$WORK/zero_tests.tg" <<'EOF'
def helper() -> Int
  42
end
EOF

cat > "$WORK/zero_tests_broken.tg" <<'EOF'
use std::does_not_exist_zzz

def helper() -> Int
  42
end
EOF

cat > "$WORK/parse_error.tg" <<'EOF'
def broken( -> Unit
EOF

# 1. Explicit file whose tests all pass exits zero.
if ! "$COMPILER" test "$WORK/pass.tg" >"$WORK/out_pass.txt" 2>&1; then
  fail "passing @test file exited nonzero"
fi

# 2. Explicit file with a failing test exits nonzero.
if "$COMPILER" test "$WORK/fail.tg" >"$WORK/out_fail.txt" 2>&1; then
  fail "failing @test file exited zero"
fi

# 3. Explicit zero-@test file exits nonzero with the diagnostic.
if "$COMPILER" test "$WORK/zero_tests.tg" >"$WORK/out_zero.txt" 2>&1; then
  fail "zero-test file exited zero"
fi
if ! grep -q "no tests found in $WORK/zero_tests.tg" "$WORK/out_zero.txt"; then
  fail "zero-test diagnostic missing from output"
fi

# 3b. Explicit zero-@test file that also fails the `tg check` gate exits
#     nonzero (a broken module cannot pass `tg test` vacuously).
if "$COMPILER" test "$WORK/zero_tests_broken.tg" >"$WORK/out_zero_broken.txt" 2>&1; then
  fail "zero-test file with broken module exited zero"
fi

# 4. Explicit parse-error file exits nonzero and emits diagnostics.
if "$COMPILER" test "$WORK/parse_error.tg" >"$WORK/out_parse.txt" 2>&1; then
  fail "parse-error file exited zero"
fi
if ! grep -qi "error" "$WORK/out_parse.txt"; then
  fail "parse-error diagnostics missing from output"
fi

# 5. Implicit discovery selects only RECOGNIZED test sources. A directory
#    scan containing a broken NON-test source next to a passing file stays
#    clean: the broken file carries no @test marker and is never selected.
mkdir -p "$WORK/implicit"
cp "$WORK/pass.tg" "$WORK/implicit/good.tg"
cp "$WORK/parse_error.tg" "$WORK/implicit/bad_non_test.tg"
if ! "$COMPILER" test "$WORK/implicit" >"$WORK/out_implicit_non_test.txt" 2>&1; then
  fail "implicit directory scan with a broken NON-test source exited nonzero"
fi

# 5b. A RECOGNIZED test source (a file carrying the @test marker) that fails
#     to compile must fail the invocation — no silent vanish.
cat > "$WORK/implicit/bad_test_source.tg" <<'EOF'
@test
def broken_test( -> Unit
EOF
if "$COMPILER" test "$WORK/implicit" >"$WORK/out_implicit_bad_test.txt" 2>&1; then
  fail "implicit directory scan with a broken TEST source exited zero"
fi

echo "✓ test-runner integrity: pass / fail / zero-test / parse-error / implicit-recognized-selection all behave"
