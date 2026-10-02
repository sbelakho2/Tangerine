#!/usr/bin/env bash
# check_codegen_arch_invariants.sh — mixed-architecture fail-closed gate.
#
# Audit follow-up: the previous "no tolerant branches" pin matched one
# lowercase comment spelling and went green while the fail-soft behavior
# was still live under `# Tolerance:` and through the permissive
# phys_reg_as_a64(X64)->X0 conversion.  This validator checks the
# BEHAVIOR-BEARING source shapes, case-insensitively, and is itself
# mutation-tested by scripts/test_prebootstrap_gates.sh against injected
# violations.
#
# Invariants (on tg_compiler/codegen.tg by default):
#   1. no `# tolerance` / `# tolerant` comment, any capitalization or
#      spacing;
#   2. no permissive register conversion helper (phys_reg_as_a64 /
#      phys_reg_as_x64) exists at all;
#   3. the primitive emitter helpers emit_mov_rr / emit_load_mem /
#      emit_store_mem contain an explicit mixed-architecture ICE
#      (panic) and no silent architecture fallback.
#
# Usage: scripts/check_codegen_arch_invariants.sh [path]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
file="${1:-$ROOT/tg_compiler/codegen.tg}"

if [ ! -f "$file" ]; then
  echo "codegen-arch: FAIL — missing $file" >&2
  exit 1
fi

fail=0

if grep -niE '#[[:space:]]*(tolerance|tolerant)' "$file" >/dev/null; then
  echo "codegen-arch: FAIL — tolerance-style comment(s) remain:" >&2
  grep -niE '#[[:space:]]*(tolerance|tolerant)' "$file" >&2
  fail=1
fi

if grep -nE 'phys_reg_as_(a64|x64)' "$file" >/dev/null; then
  echo "codegen-arch: FAIL — permissive architecture conversion helper present:" >&2
  grep -nE 'phys_reg_as_(a64|x64)' "$file" >&2
  fail=1
fi

for fn in emit_mov_rr emit_load_mem emit_store_mem; do
  body="$(sed -n "/^def ${fn}(/,/^end\$/p" "$file")"
  if [ -z "$body" ]; then
    echo "codegen-arch: FAIL — ${fn} not found in $file" >&2
    fail=1
    continue
  fi
  if ! printf '%s\n' "$body" | grep -q "mixed-architecture registers in ${fn}"; then
    echo "codegen-arch: FAIL — ${fn} lacks an explicit mixed-architecture ICE" >&2
    fail=1
  fi
  # No silent empty architecture-mismatch arms remain in these helpers:
  # `then ()` arms are only legitimate when guarded by a semantic pattern
  # (e.g. width), never by an architecture case inside them.
  if printf '%s\n' "$body" | grep -qE 'PhysReg::(A64|X64)Reg\(_\) then \(\)'; then
    echo "codegen-arch: FAIL — ${fn} has a silent architecture-mismatch arm" >&2
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  exit 1
fi
echo "codegen-arch: PASS — no tolerance comments, no permissive conversions, mixed-architecture primitives fail closed"
exit 0
