#!/usr/bin/env bash
#
# tests/run_tool_contract_tests.sh — the reviewer item 9 lane: the
# per-tool contract tests. For the tooling (fmt/lint/doc/bench/run/check/
# repl + the top-level CLI):
#   - the command exists (runs and exits 0 on its documented probe)
#   - --help succeeds (exit 0)
#   - --version succeeds (exit 0)
#   - an unknown option is NONZERO (the silent-ignore is gone)
#   - a missing file is NONZERO
#   - paths with spaces/quotes/semicolons work (argv vectors — the run
#     path is std::process with argv, never a shell string)
#   - the deterministic repeat: two runs produce byte-identical output
#   - the run exit-code forwarding (the exact exit status propagates)
#   - the bench JSON output is STRICT RFC 8259 (parsed by a strict
#     parser: no comments, no missing commas, no NaN/Inf)
#   - the bounded REPL evaluates an entry through the compile+run path
#
# Usage: tests/run_tool_contract_tests.sh [compiler]
#   compiler defaults to ./build/tg_stage1
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
COMPILER="${1:-./build/tg_stage1}"
FAILURES=0

if [ ! -x "$COMPILER" ]; then
  echo "tool-contracts: compiler not executable: $COMPILER" >&2
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/tg_contract.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1" >&2; FAILURES=$((FAILURES + 1)); }

# check <desc> <expected-exit> <actual-exit>
check() {
  if [ "$3" -eq "$2" ]; then
    pass "$1"
  else
    fail "$1 (exit $3, expected $2)"
  fi
}

echo "========================================"
echo "tool contracts: compiler = $COMPILER"
echo "========================================"

echo ""
echo "--- command existence + --help + --version ---"
"$COMPILER" --help >/dev/null 2>&1; check "top-level --help" 0 $?
"$COMPILER" -V >/dev/null 2>&1; check "top-level -V (version)" 0 $?
"$COMPILER" --version >/dev/null 2>&1; check "top-level --version" 0 $?
for tool in fmt lint doc run check test parse explain; do
  "$COMPILER" "$tool" --help >/dev/null 2>&1; check "tg $tool --help" 0 $?
done

echo ""
echo "--- unknown options are errors (the silent-ignore is gone) ---"
"$COMPILER" fmt --bogus-flag >/dev/null 2>&1; check "tg fmt --bogus-flag nonzero" 1 $?
"$COMPILER" fmt --bogus-flag >/dev/null 2>&1; check "tg fmt --bogus-flag nonzero (again)" 1 $?
"$COMPILER" lint --bogus-flag >/dev/null 2>&1; check "tg lint --bogus-flag nonzero" 1 $?
"$COMPILER" doc --bogus-flag >/dev/null 2>&1; check "tg doc --bogus-flag nonzero" 1 $?
"$COMPILER" fmt --indent >/dev/null 2>&1; check "tg fmt --indent (missing value) nonzero" 1 $?
"$COMPILER" lint --deny >/dev/null 2>&1; check "tg lint --deny (missing value) nonzero" 1 $?
"$COMPILER" doc --output >/dev/null 2>&1; check "tg doc --output (missing value) nonzero" 1 $?
"$COMPILER" doc --format xml >/dev/null 2>&1; check "tg doc --format xml (bad value) nonzero" 1 $?

echo ""
echo "--- missing files are nonzero ---"
"$COMPILER" fmt tests/__no_such_file__.tg >/dev/null 2>&1; check "tg fmt missing file nonzero" 1 $?
"$COMPILER" lint tests/__no_such_file__.tg >/dev/null 2>&1; check "tg lint missing file nonzero" 1 $?
"$COMPILER" doc tests/__no_such_file__.tg >/dev/null 2>&1; check "tg doc missing file nonzero" 1 $?
"$COMPILER" run tests/__no_such_file__.tg >/dev/null 2>&1; check "tg run missing file nonzero" 1 $?
"$COMPILER" check tests/__no_such_file__.tg >/dev/null 2>&1; check "tg check missing file nonzero" 1 $?

echo ""
echo "--- paths with spaces / quotes / semicolons (argv vectors) ---"
SPACE_DIR="$TMP/dir with space"
mkdir -p "$SPACE_DIR"
HELLO_FILE="$SPACE_DIR/quo'te file.tg"
SEMI_FILE="$SPACE_DIR/name;touch pwned.tg"
cat > "$HELLO_FILE" <<'EOF'
def main() -> Int
  println("hello from the space dir")
  0
end
EOF
cp "$HELLO_FILE" "$SEMI_FILE"

"$COMPILER" check "$HELLO_FILE" >/dev/null 2>&1; check "tg check path-with-space-and-quote" 0 $?
"$COMPILER" check "$SEMI_FILE" >/dev/null 2>&1; check "tg check path-with-semicolon (no shell re-parse)" 0 $?
"$COMPILER" run "$HELLO_FILE" > "$TMP/run1.out" 2>&1
check "tg run path-with-space-and-quote" 0 $?
grep -q "hello from the space dir" "$TMP/run1.out" \
  && pass "tg run output propagated" \
  || fail "tg run output propagated"
"$COMPILER" fmt "$HELLO_FILE" >/dev/null 2>&1; check "tg fmt path-with-space-and-quote" 0 $?
"$COMPILER" lint "$HELLO_FILE" >/dev/null 2>&1; check "tg lint path-with-space-and-quote" 0 $?
"$COMPILER" doc -o "$TMP/docs out" "$HELLO_FILE" >/dev/null 2>&1; check "tg doc -o space-dir" 0 $?

echo ""
echo "--- deterministic repeat (byte-identical output) ---"
"$COMPILER" fmt --check "$HELLO_FILE" > "$TMP/fmt1.out" 2>&1
FMT1=$?
"$COMPILER" fmt --check "$HELLO_FILE" > "$TMP/fmt2.out" 2>&1
FMT2=$?
check "tg fmt --check deterministic exit" $FMT1 $FMT2
cmp -s "$TMP/fmt1.out" "$TMP/fmt2.out" && pass "tg fmt --check deterministic output" || fail "tg fmt --check deterministic output"
"$COMPILER" lint --json "$HELLO_FILE" > "$TMP/lint1.out" 2>&1
LINT1=$?
"$COMPILER" lint --json "$HELLO_FILE" > "$TMP/lint2.out" 2>&1
LINT2=$?
check "tg lint --json deterministic exit" $LINT1 $LINT2
cmp -s "$TMP/lint1.out" "$TMP/lint2.out" && pass "tg lint --json deterministic output" || fail "tg lint --json deterministic output"
"$COMPILER" run "$HELLO_FILE" > "$TMP/run2.out" 2>&1
RUN1=$?
"$COMPILER" run "$HELLO_FILE" > "$TMP/run3.out" 2>&1
RUN2=$?
check "tg run deterministic exit" $RUN1 $RUN2
cmp -s "$TMP/run2.out" "$TMP/run3.out" && pass "tg run deterministic output" || fail "tg run deterministic output"

echo ""
echo "--- run exit-code forwarding (the exact status propagates) ---"
EXIT42="$TMP/exit42.tg"
cat > "$EXIT42" <<'EOF'
def main() -> Int
  42
end
EOF
"$COMPILER" run "$EXIT42" >/dev/null 2>&1; check "tg run exit code 42 forwarded" 42 $?
EXIT0="$TMP/exit0.tg"
cat > "$EXIT0" <<'EOF'
def main() -> Int
  0
end
EOF
"$COMPILER" run "$EXIT0" >/dev/null 2>&1; check "tg run exit code 0 forwarded" 0 $?

echo ""
echo "--- bench JSON is STRICT RFC 8259 (no comments, no missing commas, no NaN/Inf) ---"
BENCH_FILE="$TMP/bench_contract.tg"
cat > "$BENCH_FILE" <<'EOF'
@bench
def bench_hello() -> Int
  0
end

def main() -> Int
  0
end
EOF
"$COMPILER" bench --json "$BENCH_FILE" > "$TMP/bench.json" 2>&1
check "tg bench --json runs" 0 $?
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/bench.json" 2>/dev/null; then
  pass "bench JSON strict-parse (RFC 8259)"
else
  fail "bench JSON strict-parse (RFC 8259): $(cat "$TMP/bench.json")"
fi

echo ""
echo "--- the bounded REPL evaluates through the compile+run path ---"
printf '1 + 2\n:quit\n' | "$COMPILER" repl > "$TMP/repl.out" 2>&1
check "tg repl piped session" 0 $?
grep -q "=> 3" "$TMP/repl.out" && pass "repl evaluated 1 + 2 => 3" || fail "repl evaluated 1 + 2 => 3: $(cat "$TMP/repl.out")"
grep -q "Goodbye!" "$TMP/repl.out" && pass "repl :quit exits cleanly" || fail "repl :quit exits cleanly"

echo ""
echo "--- the bounded REPL: the error-then-continue piped session ---"
# A FAILING entry (a parse error) is reported; the session CONTINUES and
# the next expression evaluates — the failed entry's state never leaks
# into the next (the buffer clears after every completed entry).
printf 'let =\n1 + 2\n:quit\n' | "$COMPILER" repl > "$TMP/repl_err.out" 2>&1
check "tg repl piped session (error then continue) exits 0" 0 $?
grep -q "=> 3" "$TMP/repl_err.out" && pass "repl continues after the failed entry (1 + 2 => 3)" || fail "repl continues after the failed entry (1 + 2 => 3): $(cat "$TMP/repl_err.out")"
grep -q "Goodbye!" "$TMP/repl_err.out" && pass "repl error-then-continue session quits cleanly" || fail "repl error-then-continue session quits cleanly"

echo ""
echo "--- the CQS query server: the diagnostics affect the check where required ---"
CQS_FIXTURE="$TMP/cqs_gate.tg"
cat > "$CQS_FIXTURE" <<'EOF'
pub def broken(given: Int) -> Int
  let dead = 1
  if given > 0 then
    42
  else
    42
  end
end

def main() -> Int
  broken(1)
end
EOF
# The Dev-mode check (the sweep contract): zero CQS diagnostics, exit 0.
"$COMPILER" check "$CQS_FIXTURE" > "$TMP/cqs_dev.out" 2>&1
check "tg check (Dev) with the CQS invocation exits 0" 0 $?
grep -q "CQS-" "$TMP/cqs_dev.out" && fail "Dev check must not emit CQS diagnostics" || pass "Dev check emits no CQS diagnostics"
# The Hardened-mode check: the mode matrix's gated failures are
# reported and FAIL the check.
"$COMPILER" check --mode hardened "$CQS_FIXTURE" > "$TMP/cqs_hard.out" 2>&1
check "tg check --mode hardened gates the fixture (exit 1)" 1 $?
grep -q "CQS-" "$TMP/cqs_hard.out" && pass "the CQS gate diagnostics are reported" || fail "the CQS gate diagnostics are reported: $(cat "$TMP/cqs_hard.out")"

echo ""
echo "--- read-only inputs are never written, never partially modified ---"
READONLY="$TMP/readonly.tg"
cp "$HELLO_FILE" "$READONLY"
chmod 444 "$READONLY"
"$COMPILER" check "$READONLY" >/dev/null 2>&1; check "tg check read-only input" 0 $?
"$COMPILER" lint "$READONLY" >/dev/null 2>&1; check "tg lint read-only input" 0 $?
"$COMPILER" fmt --check "$READONLY" >/dev/null 2>&1; check "tg fmt --check read-only input" 0 $?
"$COMPILER" doc -o "$TMP/docs_ro" "$READONLY" >/dev/null 2>&1; check "tg doc read-only input" 0 $?
cmp -s "$HELLO_FILE" "$READONLY" && pass "read-only input byte-identical after check/lint/fmt --check/doc" || fail "read-only input byte-identical after check/lint/fmt --check/doc"
# The in-place fmt path on a WRITABLE copy leaves the read-only original
# untouched (a tool that opened the input for writing would have failed
# on the 444 file or clobbered it).
WRITABLE="$TMP/writable.tg"
cp "$HELLO_FILE" "$WRITABLE"
"$COMPILER" fmt "$WRITABLE" >/dev/null 2>&1; check "tg fmt in-place on writable copy" 0 $?
cmp -s "$HELLO_FILE" "$READONLY" && pass "read-only original untouched by the in-place fmt of a copy" || fail "read-only original untouched by the in-place fmt of a copy"

echo ""
echo "--- stdout/stderr separation (diagnostics never leak to stdout) ---"
BAD_FILE="$TMP/bad_syntax.tg"
cat > "$BAD_FILE" <<'EOF'
def main() -> Int
  let =
end
EOF
"$COMPILER" check "$BAD_FILE" > "$TMP/bad.out" 2> "$TMP/bad.err"
check "tg check bad file exits nonzero" 1 $?
if [ -s "$TMP/bad.err" ]; then
  pass "diagnostics on stderr"
else
  fail "diagnostics on stderr (empty stderr)"
fi
if [ -s "$TMP/bad.out" ]; then
  fail "stdout must be empty on the error path (got: $(cat "$TMP/bad.out"))"
else
  pass "stdout empty on the error path"
fi
"$COMPILER" fmt --check "$BAD_FILE" > "$TMP/badfmt.out" 2> "$TMP/badfmt.err"
check "tg fmt --check bad file exits nonzero" 1 $?
[ -s "$TMP/badfmt.err" ] && pass "fmt diagnostics on stderr" || fail "fmt diagnostics on stderr"
[ -s "$TMP/badfmt.out" ] && fail "fmt stdout must be empty on the error path" || pass "fmt stdout empty on the error path"
# The success path: --help writes stdout with empty stderr.
"$COMPILER" --help > "$TMP/help.out" 2> "$TMP/help.err"
check "tg --help exits 0" 0 $?
[ -s "$TMP/help.out" ] && pass "--help writes stdout" || fail "--help writes stdout"
[ -s "$TMP/help.err" ] && fail "--help stderr must be empty" || pass "--help stderr empty"

echo ""
echo "--- exit-status forwarding: the signal termination (128+sig) ---"
PANIC_FILE="$TMP/panic_signal.tg"
cat > "$PANIC_FILE" <<'EOF'
def main() -> Int
  panic("the abort-only panic state")
  0
end
EOF
"$COMPILER" run "$PANIC_FILE" >/dev/null 2>&1
check "tg run panicking program exits 134 (SIGABRT, the abort-only panic state)" 134 $?
"$COMPILER" run "$PANIC_FILE" >/dev/null 2>&1
check "tg run panicking program 134 (again — the signal status is stable)" 134 $?

echo ""
echo "--- the deterministic repeat extends to doc generation ---"
"$COMPILER" doc -o "$TMP/doc1.md" "$HELLO_FILE" >/dev/null 2>&1; DOC1=$?
"$COMPILER" doc -o "$TMP/doc2.md" "$HELLO_FILE" >/dev/null 2>&1; DOC2=$?
check "tg doc deterministic exit" $DOC1 $DOC2
if [ -f "$TMP/doc1.md" ] && [ -f "$TMP/doc2.md" ]; then
  cmp -s "$TMP/doc1.md" "$TMP/doc2.md" && pass "tg doc output byte-identical across runs" || fail "tg doc output byte-identical across runs"
else
  fail "tg doc wrote no output file"
fi

echo ""
if [ "$FAILURES" -ne 0 ]; then
  echo "tool contracts FAILED with $FAILURES failure(s)" >&2
  exit 1
fi
echo "tool contracts OK: existence/help/version/unknown-option/missing-file/spaces/determinism/exit-forwarding/signals/read-only/stdout-stderr/JSON/REPL all green"
