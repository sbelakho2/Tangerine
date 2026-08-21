#!/usr/bin/env bash
#
# tests/run_bench_runner_integrity.sh — P0 verification-integrity gate for
# `tg bench` (the bench counterpart of tests/run_test_runner_integrity.sh).
#
# `tg bench` must distinguish its outcomes:
#   1. an EXPLICITLY named benchmark file whose benches all run exits 0;
#   2. an explicitly named benchmark file with a failing bench exits nonzero;
#   3. an explicitly named benchmark file that fails to parse exits nonzero
#      AND emits the parse diagnostics (never skipped);
#   4. an explicitly named benchmark file with ZERO @bench functions exits
#      nonzero with the "no benchmarks found in <file>" diagnostic;
#   5. an explicitly named benchmark file that fails to compile exits
#      nonzero (a compile error is a failed bench, never skipped);
#   6. discovery (a scan) containing a broken benchmark source fails the
#      invocation (a discovered-but-broken benchmark source never passes);
#   7. the zero-benchmark case (no benchmark files at all) exits nonzero —
#      `tg bench` never reports success for 0/0.
#
# Usage: tests/run_bench_runner_integrity.sh [compiler]
#   compiler defaults to build/tg (the CI-materialized stage3 artifact).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

COMPILER="${1:-build/tg}"

if [ ! -x "$COMPILER" ]; then
  echo "::error::bench-runner integrity: compiler binary not executable: $COMPILER" >&2
  exit 1
fi
# Absolute form for invocations run from other working directories
# (the zero-benchmark case runs in an empty dir so discovery finds nothing).
COMPILER_ABS="$(cd "$(dirname "$COMPILER")" && pwd)/$(basename "$COMPILER")"

# Explicit-path fixtures live in a HIDDEN work dir so full-repo discovery
# never sees them. The discovery fixture lives in a NON-hidden dir
# (build/tg_bench_integrity/) so the repo-wide scan picks it up.
WORK="build/.tg_bench_integrity"
rm -rf "$WORK" build/tg_bench_integrity
mkdir -p "$WORK"

fail() {
  echo "::error::bench-runner integrity: $1" >&2
  exit 1
}

cat > "$WORK/pass_bench.tg" <<'EOF'
use std::args

@bench
def bench_pass() -> Unit
  ()
end

def main() -> Int
  let argv = args::args()
  if argv.len() >= 3 && argv[1] == "--run-bench" && argv[2] == "bench_pass" then
    0
  else
    1
  end
end
EOF

cat > "$WORK/fail_bench.tg" <<'EOF'
use std::args

@bench
def bench_fail() -> Unit
  ()
end

def main() -> Int
  let argv = args::args()
  if argv.len() >= 2 && argv[1] == "--run-bench" then
    1
  else
    1
  end
end
EOF

cat > "$WORK/parse_error_bench.tg" <<'EOF'
def broken( -> Unit
EOF

cat > "$WORK/zero_bench.tg" <<'EOF'
def main() -> Int
  0
end
EOF

cat > "$WORK/compile_error_bench.tg" <<'EOF'
use std::does_not_exist_zzz

@bench
def bench_compile_error() -> Unit
  ()
end

def main() -> Int
  0
end
EOF

# 7. The zero-benchmark case fails: no benchmark files at all must never
#    report success (0/0 was the historical false-green).
EMPTY_DIR="build/.tg_bench_integrity_empty"
rm -rf "$EMPTY_DIR"
mkdir -p "$EMPTY_DIR"
if (cd "$EMPTY_DIR" && "$COMPILER_ABS" bench) >"$WORK/out_zero.txt" 2>&1; then
  fail "zero-benchmark invocation exited zero"
fi
if ! grep -q "No benchmark files found" "$WORK/out_zero.txt"; then
  fail "zero-benchmark diagnostic missing from output"
fi

# 1. Explicit benchmark file whose benches all run exits zero.
if ! "$COMPILER" bench "$WORK/pass_bench.tg" >"$WORK/out_pass.txt" 2>&1; then
  fail "passing @bench file exited nonzero"
fi
if ! grep -q "bench result: 1/1 ok" "$WORK/out_pass.txt"; then
  fail "passing @bench file did not report 1/1 ok"
fi

# 2. Explicit benchmark file with a failing bench exits nonzero.
if "$COMPILER" bench "$WORK/fail_bench.tg" >"$WORK/out_fail.txt" 2>&1; then
  fail "failing @bench file exited zero"
fi
if ! grep -q "FAILED" "$WORK/out_fail.txt"; then
  fail "failing @bench file did not emit a FAILED line"
fi

# 3. Explicit parse-error benchmark file exits nonzero and emits diagnostics.
if "$COMPILER" bench "$WORK/parse_error_bench.tg" >"$WORK/out_parse.txt" 2>&1; then
  fail "parse-error benchmark file exited zero"
fi
if ! grep -qi "error" "$WORK/out_parse.txt"; then
  fail "parse-error diagnostics missing from output"
fi

# 4. Explicit benchmark file with zero @bench functions exits nonzero with
#    the diagnostic.
if "$COMPILER" bench "$WORK/zero_bench.tg" >"$WORK/out_zero_bench.txt" 2>&1; then
  fail "zero-@bench benchmark file exited zero"
fi
if ! grep -q "no benchmarks found in $WORK/zero_bench.tg" "$WORK/out_zero_bench.txt"; then
  fail "zero-@bench diagnostic missing from output"
fi

# 5. Explicit benchmark file that fails to compile exits nonzero.
if "$COMPILER" bench "$WORK/compile_error_bench.tg" >"$WORK/out_compile_error.txt" 2>&1; then
  fail "compile-error benchmark file exited zero"
fi
if ! grep -q "COMPILE ERROR" "$WORK/out_compile_error.txt"; then
  fail "compile-error diagnostic missing from output"
fi

# 6. Discovery containing a broken benchmark source fails the invocation.
mkdir -p build/tg_bench_integrity
cat > build/tg_bench_integrity/broken_bench.tg <<'EOF'
def broken( -> Unit
EOF
if "$COMPILER" bench >"$WORK/out_discovery.txt" 2>&1; then
  fail "discovery with a broken benchmark source exited zero"
fi
if ! grep -q "broken_bench.tg" "$WORK/out_discovery.txt"; then
  fail "discovery run did not diagnose the broken benchmark source"
fi
rm -rf build/tg_bench_integrity

echo "✓ bench-runner integrity: pass / fail / parse-error / zero-@bench / compile-error / discovery / zero-discovery all behave"
