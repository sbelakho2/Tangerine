#!/usr/bin/env bash
# tests/objectgen_failure_test.sh
#
# Object-generation failure regression tests — structural harness entry.
#
# Purpose: the compile pipeline's object path (EmitMode::Object) must
# surface failures through Result::Err, never through an exit-code-style
# bare `return 1` inside a Result[Unit, String] function (P0). These tests
# force the object-generation path to fail deterministically WITHOUT a
# bootstrap ladder, using only a built compiler binary:
#
#   Case A (invalid output path):  -c -o <nonexistent-dir>/x.o
#     write_file_bytes fails, so compile_file_core must return
#     Result::Err("Failed to write object file: ...") and the CLI must exit
#     nonzero. Before the P0 fix this arm printed and returned 1 from a
#     Result-typed function (a type error in Tangerine).
#
#   Case B (empty translation unit): an empty .tg file compiled with -c
#     must SUCCEED (exit 0). An empty successful read is a valid empty
#     String — it must never be conflated with "Failed to read file".
#
#   Case C (parse error): a syntactically broken unit compiled with --check
#     must exit nonzero AND print the aggregated structured diagnostic
#     (containing the "error at <file>:<offset>" line) — never a bare
#     "Parse error" summary.
#
# Test recipe for the generate_object_file error arm itself: that arm
# fires when the backend refuses the target/MIR (e.g. an internal codegen
# failure). The deterministic stand-in is Case A: the invalid output path
# exercises the SAME EmitMode::Object Result arm in compile_file_core
# (generate_object_file -> write_file_bytes -> Result::Err propagation).
# A target mismatch variant that does not panic at parse_target_triple
# cannot be constructed today because both supported backend triples
# (the macOS canonical default and the x86_64-linux-gnu target) have
# working backends.
#
# Usage: tests/objectgen_failure_test.sh [compiler-binary] [scratch-dir]
#   compiler-binary defaults to build/tg_stage2
#   scratch-dir     defaults to build/.objectgen_failure
# Exits 0 when all cases pass, nonzero otherwise.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# The target comes from the single bootstrap target authority (bh_boot_target),
# never from a locally hard-wired triple.
# shellcheck source=scripts/bootstrap_helpers.sh
source "$ROOT/scripts/bootstrap_helpers.sh"

COMPILER="${1:-$ROOT/build/tg_stage2}"
SCRATCH="${2:-$ROOT/build/.objectgen_failure}"
TARGET="$(bh_boot_target)"

failures=0

bh_log() { printf '[objectgen-failure] %s\n' "$*"; }
bh_err() { printf '[objectgen-failure:error] %s\n' "$*" >&2; }

if [ ! -x "$COMPILER" ]; then
  bh_err "compiler binary not found or not executable: $COMPILER"
  bh_err "usage: $0 [compiler-binary] [scratch-dir]"
  exit 1
fi

mkdir -p "$SCRATCH"
rm -f "$SCRATCH"/*

# ---------------------------------------------------------------
# Case A: object generation into an invalid output path
# ---------------------------------------------------------------
cat > "$SCRATCH/objgen_a.tg" <<'EOF'
def main() -> Int
  0
end
EOF
MISSING_DIR="$SCRATCH/does_not_exist_dir"
out_a="$SCRATCH/objgen_a.o"
if "$COMPILER" compile "$SCRATCH/objgen_a.tg" -c -o "$MISSING_DIR/$out_a" --target "$TARGET" >/dev/null 2>"$SCRATCH/a.stderr"; then
  bh_err "Case A FAILED: object emit to a nonexistent directory succeeded"
  failures=$((failures + 1))
else
  if grep -qi 'object' "$SCRATCH/a.stderr"; then
    bh_log "Case A ok: object-path failure surfaced with nonzero exit"
  else
    bh_err "Case A: nonzero exit but no object-path diagnostic in stderr"
    bh_err "  stderr: $(head -n2 "$SCRATCH/a.stderr" | tr '\n' ' ')"
    failures=$((failures + 1))
  fi
fi

# ---------------------------------------------------------------
# Case B: empty translation unit must compile (empty read is valid)
# ---------------------------------------------------------------
: > "$SCRATCH/objgen_b.tg"
if "$COMPILER" compile "$SCRATCH/objgen_b.tg" -c -o "$SCRATCH/objgen_b.o" --target "$TARGET" >/dev/null 2>"$SCRATCH/b.stderr"; then
  bh_log "Case B ok: empty translation unit compiled to an object"
else
  bh_err "Case B FAILED: empty translation unit rejected (empty read conflated with I/O failure)"
  bh_err "  stderr: $(head -n2 "$SCRATCH/b.stderr" | tr '\n' ' ')"
  failures=$((failures + 1))
fi

# ---------------------------------------------------------------
# Case C: parse error must produce the aggregated diagnostic set
# ---------------------------------------------------------------
cat > "$SCRATCH/objgen_c.tg" <<'EOF'
def main() -> Int
  let = missing name
end
EOF
if "$COMPILER" check "$SCRATCH/objgen_c.tg" >/dev/null 2>"$SCRATCH/c.stderr"; then
  bh_err "Case C FAILED: parse-error unit accepted"
  failures=$((failures + 1))
else
  if grep -qi 'error at ' "$SCRATCH/c.stderr"; then
    bh_log "Case C ok: aggregated structured parse diagnostics emitted"
  else
    bh_err "Case C: rejected but no aggregated 'error at <file>:<offset>' diagnostic found"
    bh_err "  stderr: $(head -n2 "$SCRATCH/c.stderr" | tr '\n' ' ')"
    failures=$((failures + 1))
  fi
fi

# ---------------------------------------------------------------
if [ "$failures" -ne 0 ]; then
  bh_err "objectgen failure tests FAILED: $failures case(s)"
  exit 1
fi
bh_log "objectgen failure tests OK (A: invalid-output-path, B: empty-unit, C: parse-diagnostics)"
exit 0
