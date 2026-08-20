#!/usr/bin/env bash
#
# run_selfhost_grammar_gate.sh — self-host grammar gate for the compiler kernel
#
# The current parser HARD-REJECTS the legacy parameter spellings
# (`mut x:` / `&x:` / `&mut x:` / `move x:` / `own x:` prefixes and the
# `x: &T` / `x: &mut T` type-position markers, plus `fn(&T)` fn-type params
# and `&self` / `&mut self` receivers — the E100/E106 diagnostics), so the
# bootstrap closure MUST be free of them: HEAD has to compile its own kernel
# under its own grammar.
#
# This gate runs BEFORE any stage building (wired into run_bootstrap.sh next
# to the struct-integrity pre-gate) and does three things:
#
#   1. ENUMERATE — resolve the manifest closure (bootstrap/compiler_kernel.manifest,
#      the std: + compiler: entries) and fail if any listed file is missing.
#
#   2. SCAN (the hard gate) — after stripping `#` line comments and "..." string
#      literals (so ABI documentation and string payloads cannot trip it), reject
#      every forbidden legacy parameter form in ANY closure file:
#        - `x: &T` / `x: &T`-marker:      `: &`  and  `: &mut`  (type position)
#        - `x: &mut T` (same marker class)
#        - return-position reference:      `-> &T`  (E106; exempted only on
#          `extern def __intrinsic_...` ABI lines, where the reference IS the
#          legal address ABI)
#        - fn-type parameter:              `fn(&T)` / `fn(&mut T)` / `fn(mut T)`
#          / `fn(move T)` / `fn(own T)`
#        - parameter prefixes:             `(&x: T` `, &mut y: U` `, &y: U`
#          `(mut x: T` `, move y: T` `, own z: T` — param position only, so the
#          legal statement-local `mut x: T = ...` form never trips the gate)
#        - legacy receivers:               `&self` / `&mut self` (expression
#          access markers like `&self.ptr` remain legal and are NOT matched)
#
#      ANY match = hard failure (exit 1) with file:line diagnostics.
#
#   3. COMPILER CHECK (when usable) — if a native compiler binary exists in
#      build/ (tg_stage3, else tg_stage2, else tg_stage1) AND that binary
#      rejects a legacy-spelling probe (i.e. it implements the current E100
#      grammar — a stale binary built before the E100 removal silently accepts
#      the probe and is NOT usable for this gate), run `check` (the driver's
#      check command) over EVERY manifest source and hard-fail on any failure.
#      Otherwise fall back to the structural scan alone (step 2 remains the
#      authoritative rejection).
#
# Exit codes:
#   0  closure is clean (structural scan passed; compiler check passed or skipped)
#   1  hard failure: missing closure file, forbidden legacy form, or a closure
#      source failed the current compiler's check

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANIFEST="$ROOT_DIR/bootstrap/compiler_kernel.manifest"
BUILD_DIR="$ROOT_DIR/build"
PROBE_FILE="$BUILD_DIR/bootstrap/grammar_gate_probe.tg"

fail() {
  echo "[grammar-gate:error] $*" >&2
  exit 1
}

# ———————————————————————————————————————————————————————————————
# Step 1 — enumerate the manifest closure
# ———————————————————————————————————————————————————————————————

if [ ! -f "$MANIFEST" ]; then
  fail "missing kernel manifest: $MANIFEST"
fi

files="$(awk '$1 == "std:" || $1 == "compiler:" { print $1, $2 }' "$MANIFEST")"
if [ -z "$files" ]; then
  fail "kernel manifest lists no closure files: $MANIFEST"
fi

closure=""
n=0
while IFS=' ' read -r kind rel; do
  case "$kind" in
    std:) f="$ROOT_DIR/std/$rel" ;;
    compiler:) f="$ROOT_DIR/tg_compiler/$rel" ;;
    *) continue ;;
  esac
  if [ ! -f "$f" ]; then
    fail "manifest closure file missing: $f"
  fi
  closure="$closure
$f"
  n=$((n + 1))
done <<< "$files"

if [ "$n" -eq 0 ]; then
  fail "kernel manifest has no std:/compiler: entries"
fi
echo "[grammar-gate] closure: $n files from $MANIFEST"

# ———————————————————————————————————————————————————————————————
# Step 2 — legacy-parameter structural scan (the hard gate)
# ———————————————————————————————————————————————————————————————

violations="$(printf '%s' "$closure" | tail -n +2 | while IFS= read -r f; do
  awk -v file="$f" '
    function sanitize(s,    i, n, out, c, in_str) {
      n = length(s)
      out = ""
      in_str = 0
      for (i = 1; i <= n; i++) {
        c = substr(s, i, 1)
        if (in_str) {
          if (c == "\\") { i++ ; continue }
          if (c == "\"") { in_str = 0 }
          continue
        }
        if (c == "\"") { in_str = 1 ; out = out "\"\"" ; continue }
        if (c == 39) {
          # char literal: consume through the closing quote (respecting \)
          i++
          while (i <= n) {
            cc = substr(s, i, 1)
            if (cc == "\\") { i += 2 ; continue }
            if (cc == 39) { break }
            i++
          }
          continue
        }
        if (c == "#") { break }
        out = out c
      }
      return out
    }
    {
      line = $0
      L = sanitize(line)
      reason = ""
      if (L ~ /:[ \t]*&(mut[ \t]+)?[A-Za-z_<]/) {
        reason = "legacy reference parameter marker (`: &T` / `: &mut T`)"
      }
      if (reason == "" && L ~ /->[ \t]*&/ && line !~ /^[ \t]*extern[ \t]+(def|static)[ \t]+__intrinsic_/) {
        reason = "legacy reference return type (`-> &T`)"
      }
      if (reason == "" && L ~ /(^|[^A-Za-z0-9_])fn[ \t]*\([ \t]*&/) {
        reason = "legacy fn-type reference parameter (`fn(&T)` / `fn(&mut T)`)"
      }
      if (reason == "" && L ~ /(^|[^A-Za-z0-9_])fn[ \t]*\([ \t]*(mut[ \t]+|move[ \t]+|own[ \t]+)[A-Za-z_<]/) {
        reason = "legacy fn-type convention prefix (`fn(mut T)` / `fn(move T)` / `fn(own T)`)"
      }
      # The `: [^: \t]` tail keeps struct-literal call arguments like
      # `f(&tg_compiler::ids::LocalId { id: ... })` from false-positive:
      # a real legacy prefix param is `&name: Type` (the colon is followed
      # by the type), while a qualified path has `::` after the name.
      if (reason == "" && L ~ /([(,])[ \t]*&(mut[ \t]+)?[a-z_][A-Za-z0-9_]*[ \t]*:[ \t]*[^: \t]/) {
        reason = "legacy parameter prefix (`&x:` / `&mut x:`)"
      }
      if (reason == "" && L ~ /([(,])[ \t]*(mut|move|own)[ \t]+[a-z_][A-Za-z0-9_]*[ \t]*:[ \t]*[^: \t]/) {
        reason = "legacy parameter prefix (`mut x:` / `move x:` / `own x:`)"
      }
      if (reason == "" && L ~ /([(,])[ \t]*&(mut[ \t]+)?self([ \t]*[,):])/) {
        reason = "legacy receiver (`&self` / `&mut self`)"
      }
      if (reason != "") {
        printf "%s:%d: %s\n", file, NR, reason
      }
    }
  ' "$f"
done)"

if [ -n "$violations" ]; then
  echo "[grammar-gate:error] forbidden legacy parameter syntax in the self-host closure:"
  printf '%s\n' "$violations"
  count="$(printf '%s\n' "$violations" | wc -l | tr -d ' ')"
  fail "grammar gate FAILED: $count forbidden form(s) in the manifest closure"
fi
echo "[grammar-gate] structural scan OK: no legacy parameter forms in the closure"

# ———————————————————————————————————————————————————————————————
# Step 3 — compiler check over the closure (usable binary only)
# ———————————————————————————————————————————————————————————————

GOOD_PROBE_FILE="$BUILD_DIR/bootstrap/grammar_gate_good_probe.tg"

# Run `check` inside a subshell with the subshell's stderr redirected so the
# shell's signal-death report (a broken leftover binary dies by SIGILL) never
# leaks into the gate output; the signal exit code (128+N) still propagates.
probe_check() {
  ( "$1" check "$2" >/dev/null 2>&1; exit $? ) 2>/dev/null
}

BIN=""
for cand in tg_stage3 tg_stage2 tg_stage1; do
  [ -x "$BUILD_DIR/$cand" ] || continue
  cand_bin="$BUILD_DIR/$cand"
  # The binary is usable for this gate only if it is a REAL working compiler
  # (it must check a trivial valid program successfully — a crashed or broken
  # leftover artifact never qualifies) AND it implements the CURRENT grammar
  # (it must REJECT a legacy-spelling probe: a stale binary built before the
  # E100 removal silently accepts the probe and would false-pass the closure).
  mkdir -p "$(dirname "$GOOD_PROBE_FILE")"
  cat > "$GOOD_PROBE_FILE" <<'GOODPROBE'
def grammar_gate_good_probe() -> Int
  0
end
GOODPROBE
  mkdir -p "$(dirname "$PROBE_FILE")"
  cat > "$PROBE_FILE" <<'PROBE'
def grammar_gate_probe(x: &Int) -> Int
  x
end
PROBE
  if probe_check "$cand_bin" "$GOOD_PROBE_FILE" &&
     ! probe_check "$cand_bin" "$PROBE_FILE"; then
    BIN="$cand_bin"
    break
  fi
  echo "[grammar-gate] warning: $cand_bin unusable for the gate (stale grammar, broken, or crashes) — skipping it"
done

if [ -z "$BIN" ]; then
  echo "[grammar-gate] no usable native compiler binary in $BUILD_DIR — structural scan only (bootstrap will produce one)"
  exit 0
fi

echo "[grammar-gate] compiler: $BIN (current grammar confirmed by probe rejection)"
bad=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  if ! "$BIN" check "$f" >/dev/null 2>&1; then
    echo "[grammar-gate:error] closure source failed the compiler check: $f"
    bad=1
  fi
done <<< "$closure"
if [ "$bad" -ne 0 ]; then
  fail "compiler check FAILED for closure sources under $BIN"
fi
echo "[grammar-gate] compiler check OK: every manifest source passed \`$BIN check\`"
exit 0
