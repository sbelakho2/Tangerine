#!/usr/bin/env bash
# ———————————————————————————————————————————————————————————————
# scripts/check_intrinsic_closure.sh — the intrinsic closure scan
# (reviewer item 19: the intrinsic-name gate).
#
# The PHANTOM CLOSURE property, machine-checked over the SOURCE TREE
# (grep-only — no compiler ladder runs):
#
#   A. EVERY @intrinsic / __intrinsic_* USE maps to exactly one compiler
#      lowering or runtime implementation. A use is IMPLEMENTED when any
#      of:
#        1. the name is DECLARED as an extern in std/ or tg_compiler/
#           (`extern def/static __intrinsic_...` — the runtime symbol
#           surface);
#        2. the name is a RUNTIME definition (def_runtime_fn in
#           tg_compiler/runtime.tg);
#        3. the name (or its bare form with the `__intrinsic_` prefix
#           stripped — the codegen's bare_intrinsic_name normalization)
#           is CLASSIFIED in the semantic router
#           (intrinsic_id_of_call in tg_compiler/types.tg).
#      An unclassified AND undeclared AND un-runtime-defined name is a
#      PHANTOM. The scan surface is the shipped/compiled set: the
#      bootstrap kernel manifest closure, the reviewer-mandate std
#      modules, the full tg_compiler tool tree (comments/strings
#      stripped — the grammar-gate precedent), and the top-level tests.
#
#   B. EVERY implementation has >= 1 reachable declaration/use: each
#      declared / runtime-defined / classified intrinsic name must
#      appear at least once as a use or declaration anywhere in the
#      tree (an implementation nothing references is dead surface).
#
#   C. THE KNOWN-EXCEPTION LIST is exactly the enumerated set of legacy
#      phantoms that predate the gate (currently ONE:
#      __intrinsic_regex_match — the prelude-reachable phantom in
#      std/taint.tg, whose owning module is outside the reviewer-item
#      scope; the checker's gate_pending_intrinsic_name exemption
#      mirrors it). The scan FAILS when a NEW phantom appears — the
#      list can only shrink, never grow.
#
# Exit status: 0 = the closure holds; 1 = a phantom, a dead
# implementation, or a growth of the exception list.
# ———————————————————————————————————————————————————————————————
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "cannot cd to repo root"; exit 2; }

FAILURES=0

fail() {
  echo "[intrinsic-closure:error] $*" >&2
  FAILURES=$((FAILURES + 1))
}

# The KNOWN-EXCEPTION list (see C above). A phantom in this list is
# reported but tolerated; everything else fails the gate.
KNOWN_EXCEPTIONS="__intrinsic_regex_match"

# ———————————————————————————————————————————————————————————————
# Step 1 — collect the IMPLEMENTATION set
# ———————————————————————————————————————————————————————————————

# 1a. Extern declarations (std + tg_compiler).
externs=$(rg -o "extern[[:space:]]+(def|static)[[:space:]]+__intrinsic_[a-z_0-9]+" std/*.tg tg_compiler/*.tg 2>/dev/null \
  | sed -E 's/^[^:]+:extern[[:space:]]+(def|static)[[:space:]]+//' | sort -u)

# 1b. Runtime definitions (def_runtime_fn names).
runtimes=$(rg -o 'def_runtime_fn\([^,]+,[[:space:]]*"__intrinsic_[a-z_0-9]+"' tg_compiler/runtime.tg 2>/dev/null \
  | grep -o "__intrinsic_[a-z_0-9]*" | sort -u)

# 1c. The router classification: the string literals inside
#     intrinsic_id_of_call — the prefixed names plus the bare names
#     (codegen strips the __intrinsic_ prefix before re-classifying, so
#     a prefixed use is implemented when ITS BARE FORM is a router key).
router=$(sed -n '/^pub def intrinsic_id_of_call/,/^end$/p' tg_compiler/types.tg \
  | rg -o '"[a-zA-Z_0-9]+"' | tr -d '"' | sort -u)

# The NAMED implementations (an explicit __intrinsic_ identity — the
# extern symbol surface, the runtime definitions, and the router keys
# spelled with the prefix). The bare router keys are the CLASSIFICATION
# surface (type-directed aliases / method names — their reachability is
# the checker + codegen dispatch, never a textual reference), so the
# dead-implementation check (B) applies to the named set only.
impl_named=$( { echo "$externs"; echo "$runtimes"; echo "$router" | grep '^__intrinsic_'; } | sort -u )
impl_all=$( { echo "$externs"; echo "$runtimes"; echo "$router"; } | sort -u )

# ———————————————————————————————————————————————————————————————
# Step 2 — collect the USE set
# ———————————————————————————————————————————————————————————————

# The scan surface: the kernel manifest closure (std:/compiler:), the
# reviewer-mandate std modules, the full compiler tool tree, and the
# top-level tests. `@intrinsic("name")` attribute uses count too.
surface_std=$(awk '$1 == "std:" { print "std/" $2 }' bootstrap/compiler_kernel.manifest 2>/dev/null)
surface_compiler=$(awk '$1 == "compiler:" { print "tg_compiler/" $2 }' bootstrap/compiler_kernel.manifest 2>/dev/null)
mandate_std="std/db.tg std/audit.tg std/sql.tg std/metrics.tg std/graph.tg std/rand.tg std/random.tg"
surface_compiler_all=$(ls tg_compiler/*.tg 2>/dev/null)

scan_files="$( { echo "$surface_std"; echo "$mandate_std"; echo "$surface_compiler_all"; echo "$surface_compiler"; echo "tests"/*.tg; } | sort -u | sed '/^$/d' )"

# A use line is a NON-declaration occurrence (declaration lines are the
# implementation side, not the use side). Comments are stripped; for the
# tg_compiler files (the tool tree — the grammar-gate precedent) string
# literals are stripped too, so a name inside a codegen string (e.g.
# `name.starts_with("__intrinsic_atomic_")`) is never counted as a use.
uses=$(for f in $scan_files; do
  [ -f "$f" ] || { fail "scan surface file missing: $f"; continue; }
  if [[ "$f" == tg_compiler/* ]]; then
    # Strip `#` line comments and DELETE double-quoted string literal
    # contents (compiler files reference intrinsic names only inside
    # strings/comments — the MirFnItem synthesis and the codegen prefix
    # tests — never as source calls).
    sed 's/#.*//' "$f" | sed -E 's/"[^"]*"//g'
  else
    sed 's/#.*//' "$f"
  fi \
    | rg -v "extern[[:space:]]+(def|static)[[:space:]]+__intrinsic_" \
    | rg -o "__intrinsic_[a-z_0-9]+" \
    | sed "s|^|$f: |"
done | sort -u)

# The @intrinsic("name") attribute uses: scoped to the reviewer-mandate
# std modules (std/bench.tg's black_box and std/debug.tg's type_name
# keep the pre-existing compiler-attribute pattern and are outside the
# item scope — the attribute is a declaration, not a call).
attr_uses=$(for f in $mandate_std; do
  [ -f "$f" ] || continue
  sed 's/#.*//' "$f" \
    | rg -o '@intrinsic\("[a-zA-Z_0-9]+"\)' \
    | sed -E 's/@intrinsic\("([a-zA-Z_0-9]+)"\)/\1/' \
    | sed "s|^|$f: |"
done | sort -u)

# The USE names with their first site (for diagnostics).
use_names_with_sites=$( { echo "$uses"; echo "$attr_uses"; } | sort -u )
use_names=$(echo "$use_names_with_sites" | sed -E 's/^[^ ]+ //' | sort -u)

# ———————————————————————————————————————————————————————————————
# Step 3 — CHECK A: every use maps to exactly one implementation
# ———————————————————————————————————————————————————————————————
echo "== intrinsic closure scan =="
echo "scan surface files: $(echo "$scan_files" | sed '/^$/d' | wc -l | tr -d ' ')"
echo "implementation entries: $(echo "$impl_all" | sed '/^$/d' | wc -l | tr -d ' ')"
echo "use names: $(echo "$use_names" | sed '/^$/d' | wc -l | tr -d ' ')"

phantom=0
while IFS=' ' read -r site name; do
  [ -n "$name" ] || continue
  if ! echo "$impl_all" | grep -qx "$name"; then
    # The prefix-stripped classification: `__intrinsic_foo` is
    # implemented when `foo` is a router key.
    stripped="${name#__intrinsic_}"
    if [ "$stripped" != "$name" ] && echo "$router" | grep -qx "$stripped"; then
      continue
    fi
    if echo "$KNOWN_EXCEPTIONS" | tr ' ' '\n' | grep -qx "$name"; then
      echo "  [known-exception] $name (site: $site) — pre-gate phantom, MUST be resolved"
      continue
    fi
    fail "PHANTOM intrinsic use: $name (site: $site) — not classified (intrinsic_id_of_call), not extern-declared, not runtime-defined"
    phantom=$((phantom + 1))
  fi
done <<< "$use_names_with_sites"

# ———————————————————————————————————————————————————————————————
# Step 4 — CHECK B: every implementation has >= 1 reachable
#          declaration/use
# ———————————————————————————————————————————————————————————————
# The reachability side is not surface-scoped: a declaration is
# reachable when ANY source references it. The reference set is
# NORMALIZED: a bare router name `foo` is referenced when `foo` or its
# prefixed spelling `__intrinsic_foo` appears anywhere (the std's
# extern-declared family is called through the prefixed spelling; the
# MIR synthesizes the prefixed spelling from the bare classification).
all_refs=$( { rg -o "__intrinsic_[a-z_0-9]+" std/*.tg tg_compiler/*.tg tests/*.tg tests/unit/*.tg 2>/dev/null | sed 's/.*://'; } \
  | sed -E 's/^__intrinsic_//' | sort -u )

dead=0
while read -r name; do
  [ -n "$name" ] || continue
  # The same normalization as the ref side: `__intrinsic_foo` is
  # reachable when `foo` appears anywhere.
  ref_key="${name#__intrinsic_}"
  if ! echo "$all_refs" | grep -qx "$ref_key"; then
    fail "DEAD intrinsic implementation: $name — declared/classified/runtime-defined but referenced by nothing"
    dead=$((dead + 1))
  fi
done <<< "$impl_named"

# ———————————————————————————————————————————————————————————————
# Step 5 — the exception list must never grow
# ———————————————————————————————————————————————————————————————
# Every known exception is reported above (tolerated). A NEW phantom
# already fails in Step 3. An entry that is no longer a use at all
# (resolved!) should be REMOVED from the list — flag it.
resolved=0
for name in $KNOWN_EXCEPTIONS; do
  if ! echo "$use_names" | grep -qx "$name"; then
    echo "  [resolved] $name is no longer used — REMOVE it from KNOWN_EXCEPTIONS"
    resolved=$((resolved + 1))
  fi
done

echo "phantoms: $phantom, dead implementations: $dead, resolved exceptions: $resolved"
if [ "$FAILURES" -eq 0 ]; then
  echo "intrinsic closure: PASS"
  exit 0
else
  echo "intrinsic closure: FAIL ($FAILURES issue(s))"
  exit 1
fi
