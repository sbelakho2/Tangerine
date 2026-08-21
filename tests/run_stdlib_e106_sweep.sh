#!/usr/bin/env bash
# tests/run_stdlib_e106_sweep.sh
#
# E106 migration sweep — the whole-semantic std sweep, the REQUIRED gate
# (reviewer item 16) behind docs/current/stdlib_reference.md "Completeness
# Status".
#
# Every shipped std module (std/*.tg, currently 133 files) must:
#   1. PASS `tg check` — the driver's check command (driver.tg cmd_check,
#      stop_after = StopAfter::Mir) runs the FULL semantic pipeline per
#      module: lex/parse, the imported-dependency merge, the @cfg target
#      elimination, macro expansion (E105/E107 hard stops), name
#      resolution, the strict type check, the access check, the resource
#      check, MIR lowering, and the post-lower MIR verification (the
#      unconditional verify_mir after lowering) — stopping before
#      monomorphization and codegen. No extra flags are needed for the
#      full pipeline: the MIR verification `tg check` reaches is the
#      unconditional post-lower one, and the mode-gated post-mono /
#      post-opt verifies are unreachable (check never monomorphizes).
#      Zero diagnostics (an E106/E100/E1100 diagnostic or any syntax
#      error) fails the module. This is the compiler's own gate: `&T` in
#      a general type position, legacy parameter spellings, and malformed
#      tokens are hard errors.
#   2. PASS the grep backstop — the check can tolerate a syntax through a
#      gap (a counterexample class that happens to lex/parse as junk, e.g.
#      angle-bracket `Option<&T>` generic forms or `+ 'static` lifetime
#      tokens), so every module is additionally grepped for the forbidden
#      syntax classes. A module containing any of them fails EVEN IF the
#      check passes.
#
# Forbidden syntax classes (the backstop greps):
#   (a) `&T` in type positions OUTSIDE the `__intrinsic_` extern
#       declarations (the documented extern-ABI exception — the ONLY
#       remaining reference type positions, scoped by name):
#         - `x: &T` / `x: &mut T` annotations (params, fields, lets, consts)
#         - `-> &T` return types
#         - nested `&` in generic args (`Option[&T]`, `Vec[&T]`, `[&T]`)
#         - fn-type / closure param conventions (`Fn(&T)`, `|x: &T|`)
#         - `def foo(&self)` receiver prefixes
#         - `as &T` casts, `for &x` ref patterns, `impl X for &T`
#   (b) lifetime tokens (`'static`, `'a` — the language has no lifetimes;
#       char literals like `'x'` are exempt)
#   (c) `when`-in-enum older-dialect variants (`when V1` inside an enum
#       body; `when` in match arms is exempt)
#   (d) angle-bracket generic forms (`Option<u32>`, `Vec<u8>`,
#       `Option[u32>` mixed brackets — the grammar's generics are
#       `[...]` only)
#   (e) `Box[dyn Any]` erased-result spelling (current form: `Box[Any]`)
#
# Usage: tests/run_stdlib_e106_sweep.sh [compiler-binary] [scratch-dir]
#   compiler-binary defaults to build/tg_stage2
#   scratch-dir     defaults to build/.stdlib_e106_sweep
# Exits 0 when every shipped std module checks clean AND passes the grep
# backstop; nonzero otherwise.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/bootstrap_helpers.sh
source "$ROOT/scripts/bootstrap_helpers.sh"

COMPILER="${1:-$ROOT/build/tg_stage2}"
SCRATCH="${2:-$ROOT/build/.stdlib_e106_sweep}"

if [ ! -x "$COMPILER" ]; then
  bh_err "e106 sweep: compiler binary not executable: $COMPILER"
  exit 1
fi

mkdir -p "$SCRATCH"

# Every shipped std module. The std/*.tg glob is the complete enumeration
# — there is no separate kernel list: the kernel closure (the `std:`
# entries of bootstrap/compiler_kernel.manifest — currently 14 modules) is
# a strict subset of the swept set, so kernel-closure and non-kernel
# modules alike are swept by the same list. The enumeration is kept
# manifest-derived below: every manifest `std:` entry must resolve to a
# swept std/*.tg module, so the closure cannot drift out of the sweep.
ALL_MODULES=""
for file in "$ROOT"/std/*.tg; do
  [ -f "$file" ] || continue
  mod="$(basename "$file" .tg)"
  ALL_MODULES="$ALL_MODULES $mod"
done

failures=0
checked=0

# Manifest-derived enumeration cross-check: every `std:` entry of the
# kernel manifest must exist in std/ and be inside the swept set. The
# kernel closure is covered because it is a subset of std/*.tg; a
# manifest module the glob cannot see fails the sweep up front.
KERNEL_MANIFEST="$ROOT/bootstrap/compiler_kernel.manifest"
kernel_count=0
if [ -f "$KERNEL_MANIFEST" ]; then
  kernel_std="$(awk '$1 == "std:" { print $2 }' "$KERNEL_MANIFEST")"
  for rel in $kernel_std; do
    kernel_count=$((kernel_count + 1))
    if [ ! -f "$ROOT/std/$rel" ]; then
      bh_err "e106 sweep: kernel-closure std module file missing: std/$rel (manifest $KERNEL_MANIFEST)"
      failures=$((failures + 1))
      continue
    fi
    mod="${rel%.tg}"
    case " $ALL_MODULES " in
      *" $mod "*)
        ;;
      *)
        bh_err "e106 sweep: kernel-closure std module outside the swept std/*.tg set: std/$rel"
        failures=$((failures + 1))
        ;;
    esac
  done
  if [ "$failures" -eq 0 ]; then
    bh_log "e106 sweep: kernel-closure cross-check OK: $kernel_count manifest std module(s) all swept"
  fi
else
  bh_err "e106 sweep: kernel manifest missing: $KERNEL_MANIFEST"
  failures=$((failures + 1))
fi

# Strip string literals and comments from a module so the backstop greps
# only real code: char literals (including `'"'` and `'\''`), double-quoted
# strings (which may embed HTML with `</title>`-style angle forms, quoted
# font names, and ` #` color codes), and `#` comments (at line start or
# after whitespace). Order matters: char literals BEFORE strings (a char
# literal can contain a `"`), strings BEFORE comments (a `#` inside a
# string must not truncate the line and leave a dangling quote). Stripping
# is monotone — a leftover fragment can only reduce matches, never create
# a false positive.
strip_code() {
  python3 - "$1" <<'PY'
import re, sys
src = open(sys.argv[1], encoding="utf-8").read()
src = re.sub(r"'(?:\\.|[^'\\])'", "''", src)                   # char literals
src = re.sub(r'"(?:\\.|[^"\\])*"', '""', src)                  # strings
src = re.sub(r'(^|[ \t])#.*$', r'\1', src, flags=re.MULTILINE) # comments
sys.stdout.write(src)
PY
}

# Forbidden syntax classes, each a grep -E pattern applied to the
# comment-stripped module. Lines inside `__intrinsic_` extern declarations
# are exempt from the reference-position classes (the documented extern-ABI
# exception — the parser scopes it by name via is_intrinsic_extern_name).
backstop_amp() {
  # (a) `&T` in type positions outside __intrinsic_ externs
  local file="$1" tmp="$2"
  grep -nE ':\s*&\s*(mut\s+)?([A-Za-z_\[\{]|self\b|str\b|dyn\b)' "$tmp" |
    grep -v '__intrinsic_' | head -n8
}
backstop_arrow_amp() {
  local file="$1" tmp="$2"
  grep -nE -- '->\s*&\s*(mut\s+)?[A-Za-z_\[\{]' "$tmp" |
    grep -v '__intrinsic_' | head -n8
}
backstop_nested_amp() {
  local file="$1" tmp="$2"
  grep -nE '\[\s*&\s*(mut\s+)?[A-Z]' "$tmp" |
    grep -v '__intrinsic_' | head -n8
}
backstop_amp_misc() {
  # as &T casts, ref patterns, impl-for-&, closure/fn-type params,
  # receiver prefixes, const/let annotations
  local file="$1" tmp="$2"
  grep -nE -- 'as\s+&|for\s+&|\bwhen\s+&|\bimpl\s+[A-Za-z_\[\],\s]+\s+for\s+&\||\|[a-zA-Z_][a-zA-Z0-9_]*\s*:\s*&|\b(Fn|FnOnce|FnMut|fn)\([^)]*&\s*(mut\s+)?[A-Za-z_\[\{]|\bdef\s+[A-Za-z_][A-Za-z0-9_]*\(\s*&\s*(mut\s+)?self\s*[),]' "$tmp" |
    grep -v '__intrinsic_' | head -n8
}
backstop_lifetime() {
  # (b) lifetime tokens: 'word (char literals were stripped to '' by
  #     strip_code, so any remaining 'word is a lifetime)
  local file="$1" tmp="$2"
  grep -nE "'[a-zA-Z_][a-zA-Z0-9_]*" "$tmp" | head -n8
}
backstop_when_enum() {
  # (c) `when` inside an enum body (older dialect; match arms are outside
  #     enum bodies and are exempt). POSIX classes only — BSD awk has no
  #     \b / \s.
  local file="$1" tmp="$2"
  awk '
    /^[[:space:]]*(pub[[:space:]]+)?(private[[:space:]]+)?enum([^A-Za-z0-9_]|$)/ {
      if (match($0, / when([^A-Za-z0-9_]|$)/)) print FILENAME ":" NR ":" $0
      in_enum = 1; next
    }
    in_enum && /^[[:space:]]*end([^A-Za-z0-9_]|$)/                       { in_enum = 0; next }
    in_enum && /^[[:space:]]*when([^A-Za-z0-9_]|$)/                      { print FILENAME ":" NR ":" $0 }
  ' "$tmp" | head -n8
}
backstop_angle() {
  # (d) angle-bracket generics (adjacent capital-name < is a generic in the
  #     grammar that does not exist — comparisons `A < B` are space-separated)
  local file="$1" tmp="$2"
  grep -nE -- '[A-Z][A-Za-z0-9_]*<|>[A-Za-z0-9_]*\]|<[A-Za-z0-9_]*\]' "$tmp" |
    head -n8
}
backstop_box_dyn_any() {
  # (e) Box[dyn Any] erased-result spelling
  local file="$1" tmp="$2"
  grep -nE -- 'Box\s*\[\s*dyn\s+Any' "$tmp" | head -n8
}

for mod in $ALL_MODULES; do
  file="$ROOT/std/$mod.tg"
  if [ ! -f "$file" ]; then
    bh_err "e106 sweep: module file missing: std/$mod.tg"
    failures=$((failures + 1))
    continue
  fi

  # 1. The compiler gate: the FULL semantic pipeline (`tg check` —
  #    parse + resolve + typecheck + access/resource + MIR verify) must
  #    succeed with zero diagnostics (E106/E100/E1100 and any other error
  #    fail the compile).
  bh_log "e106 sweep: checking std/$mod.tg"
  if ! "$COMPILER" check "$file" >"$SCRATCH/$mod.out" 2>&1; then
    bh_err "e106 sweep FAILED: std/$mod.tg did not check clean:"
    bh_err "  $(head -n3 "$SCRATCH/$mod.out" | tr '\n' ' ')"
    failures=$((failures + 1))
    continue
  fi
  if grep -q "E106" "$SCRATCH/$mod.out"; then
    bh_err "e106 sweep FAILED: std/$mod.tg produced an E106 diagnostic"
    failures=$((failures + 1))
    continue
  fi

  # 2. The grep backstop: the check can tolerate a forbidden syntax through
  #    a parsing gap (angle-bracket generics, lifetime tokens, when-in-enum,
  #    Box[dyn Any]); a module containing any class fails even if the check
  #    passed. This is the gate that keeps the migration claim honest.
  stripped="$SCRATCH/$mod.stripped"
  strip_code "$file" >"$stripped"

  amp_hits="$(backstop_amp "$file" "$stripped")"
  if [ -n "$amp_hits" ]; then
    bh_err "e106 sweep FAILED: std/$mod.tg backstop (ref in annotation position):"
    printf '%s\n' "$amp_hits" | sed 's/^/    /'
    failures=$((failures + 1))
  fi

  arrow_hits="$(backstop_arrow_amp "$file" "$stripped")"
  if [ -n "$arrow_hits" ]; then
    bh_err "e106 sweep FAILED: std/$mod.tg backstop (ref in return type):"
    printf '%s\n' "$arrow_hits" | sed 's/^/    /'
    failures=$((failures + 1))
  fi

  nested_hits="$(backstop_nested_amp "$file" "$stripped")"
  if [ -n "$nested_hits" ]; then
    bh_err "e106 sweep FAILED: std/$mod.tg backstop (ref nested in generic arg):"
    printf '%s\n' "$nested_hits" | sed 's/^/    /'
    failures=$((failures + 1))
  fi

  misc_hits="$(backstop_amp_misc "$file" "$stripped")"
  if [ -n "$misc_hits" ]; then
    bh_err "e106 sweep FAILED: std/$mod.tg backstop (ref in cast/pattern/fn-type/receiver):"
    printf '%s\n' "$misc_hits" | sed 's/^/    /'
    failures=$((failures + 1))
  fi

  lifetime_hits="$(backstop_lifetime "$file" "$stripped")"
  if [ -n "$lifetime_hits" ]; then
    bh_err "e106 sweep FAILED: std/$mod.tg backstop (lifetime token):"
    printf '%s\n' "$lifetime_hits" | sed 's/^/    /'
    failures=$((failures + 1))
  fi

  when_hits="$(backstop_when_enum "$file" "$stripped")"
  if [ -n "$when_hits" ]; then
    bh_err "e106 sweep FAILED: std/$mod.tg backstop (when-in-enum variant):"
    printf '%s\n' "$when_hits" | sed 's/^/    /'
    failures=$((failures + 1))
  fi

  angle_hits="$(backstop_angle "$file" "$stripped")"
  if [ -n "$angle_hits" ]; then
    bh_err "e106 sweep FAILED: std/$mod.tg backstop (angle-bracket generic):"
    printf '%s\n' "$angle_hits" | sed 's/^/    /'
    failures=$((failures + 1))
  fi

  box_hits="$(backstop_box_dyn_any "$file" "$stripped")"
  if [ -n "$box_hits" ]; then
    bh_err "e106 sweep FAILED: std/$mod.tg backstop (Box[dyn Any]):"
    printf '%s\n' "$box_hits" | sed 's/^/    /'
    failures=$((failures + 1))
  fi

  checked=$((checked + 1))
done

if [ "$failures" -ne 0 ]; then
  bh_err "stdlib E106 sweep FAILED: $failures problem(s), $checked modules passed the full semantic pipeline"
  exit 1
fi
bh_log "stdlib E106 sweep OK: all $checked shipped std modules pass the full semantic pipeline (tg check) and the forbidden-syntax grep backstop"
exit 0
