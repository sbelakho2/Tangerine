#!/usr/bin/env bash
# ———————————————————————————————————————————————————————————————
# scripts/check_intrinsic_closure.sh — the intrinsic closure scan
# (reviewer item 19: the intrinsic-name gate).
#
# The PHANTOM CLOSURE property, machine-checked over the SOURCE TREE
# (static source scan — no compiler ladder runs):
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
#           is CLASSIFIED by a semantic router:
#             a. the scalar/aggregate router (intrinsic_id_of_call in
#                tg_compiler/types.tg, which reaches the base SIMD router
#                simd_intrinsic_kind_of);
#             b. the LIR EXPLICIT-OP router (lir_simd_ext_op_of in
#                tg_compiler/lir.tg) for the completed
#                __intrinsic_simd_<op>_<lane> extension family: the
#                router classifies the OP token — the segment between
#                `simd_` and the FINAL `_` — and deliberately leaves the
#                lane suffix unconstrained. The per-lane semantic set
#                (the float gt/ge exclusion, the 64-bit integer ordering
#                exclusion, the float lane-move exclusion, the narrow
#                pack source rule) is enforced by the lowering's
#                fail-closed gates (lir_lower_simd_ext_call), which is
#                exactly what the refusal rows of
#                tests/lir_vector_ext_op_rows_test.tg assert: a routed
#                name with an out-of-surface lane is
#                implemented-and-refused, not a phantom.
#      An unclassified AND undeclared AND un-runtime-defined name is a
#      PHANTOM. The scan surface is the shipped/compiled set: the
#      bootstrap kernel manifest closure, the reviewer-mandate std
#      modules, the full tg_compiler tool tree (comments/strings
#      stripped — the grammar-gate precedent), and the top-level tests.
#
#   THE USE MODEL (context-aware, mirroring the implementation side):
#     - a `__intrinsic_*` occurrence counts as a use when it is a BARE
#       identifier or the WHOLE content of a quoted literal;
#     - an occurrence inside a longer literal (the
#       tests/simd_declaration_router_test.tg parser prefix
#       `starts_with("extern def __intrinsic_simd_")`) or a whole-literal
#       name concatenated with more text (the syscall fixtures'
#       `"__intrinsic_syscall" + n.to_string()` stem) is a
#       NAME-CONSTRUCTION fragment, never a call;
#     - a quoted name passed to a classification authority
#       (lir_syscall_nargs_of / lir_simd_ext_op_of / simd_intrinsic_kind_of
#       / simd_intrinsic_lane_of / intrinsic_id_of_call /
#       classify_intrinsic_call) or to a test's `*_none`
#       assert-not-classified helper is a classifier PROBE: the tests'
#       negative-control rows (tests/syscall_lir_rows_test.tg's
#       syscall0/syscall7/syscall/syscallx rows,
#       tests/lir_vector_model_test.tg's check_ext_none bogus row) pass
#       the spelling to a router and assert it is NOT classified, so it
#       is never lowered and is reported informationally, not failed.
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

# 1d. The LIR explicit-op router (lir.tg's lir_simd_ext_op_of): its
#     `when "<op>" then Option::Some(LirSimdExtKind::...)` arms are the
#     extension-op vocabulary. The router reads the name's
#     `simd_<op>_<lane>` shape and classifies the OP alone — the lane
#     suffix is unconstrained there and gated per-op in the lowering
#     (lir_lower_simd_ext_call), so this set + the name shape is the
#     resolution: `__intrinsic_simd_<op>_<lane>` with `<op>` in the set.
#     The set is deliberately NOT merged into impl_all/impl_named: the
#     tokens are bare words ("ge", "pack", ...) whose reachability is
#     the lowering dispatch, not a textual reference.
ext_ops=$(sed -n '/^def lir_simd_ext_op_of/,/^end$/p' tg_compiler/lir.tg \
  | rg -o 'when "[a-z_0-9]+" then Option::Some\(LirSimdExtKind::' \
  | sed -E 's/when "([a-z_0-9]+)".*/\1/' | sort -u)
if [ -z "$ext_ops" ]; then
  fail "the LIR explicit-op router extraction is empty (lir_simd_ext_op_of moved or its arms changed shape)"
fi

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

# The use scan (see THE USE MODEL above). Comments are stripped; for the
# tg_compiler files (the tool tree — the grammar-gate precedent) string
# literals are stripped too, so a name inside a codegen string (e.g.
# `name.starts_with("__intrinsic_atomic_")`) is never counted. For the
# other files the scan is quote-aware: bare identifiers and
# whole-literal names are uses, quoted fragments/concatenations are
# name-construction fragments, and quoted arguments to a classification
# authority (or a `*_none` helper) are negative classifier probes.
for f in $scan_files; do
  [ -f "$f" ] || fail "scan surface file missing: $f"
done
if ! command -v python3 >/dev/null 2>&1; then
  echo "intrinsic closure: python3 is required for the quote-aware use scan" >&2
  exit 2
fi
if ! scan_out=$(python3 - $scan_files <<'PY'
import re
import sys

NAME = re.compile(r'__intrinsic_[a-z_0-9]+')
EXTERN_DECL = re.compile(r'extern\s+(def|static)\s+__intrinsic_')
PROBE_CALL = re.compile(
    r'\b(?:lir_syscall_nargs_of|lir_simd_ext_op_of|simd_intrinsic_kind_of|'
    r'simd_intrinsic_lane_of|intrinsic_id_of_call|classify_intrinsic_call)\s*\('
    r'|[A-Za-z_][A-Za-z_0-9]*_none\s*\('
)

uses = set()
probes = set()
for path in sys.argv[1:]:
    compiler = path.startswith('tg_compiler/')
    try:
        fh = open(path, 'r', encoding='utf-8', errors='replace')
    except OSError:
        continue
    with fh:
        for lineno, raw in enumerate(fh, 1):
            line = raw.split('#', 1)[0]
            if compiler:
                # Compiler files reference intrinsic names only inside
                # strings/comments (the MirFnItem synthesis and the
                # codegen prefix tests) — never as source calls.
                line = re.sub(r'"[^"]*"', '', line)
            if EXTERN_DECL.search(line):
                continue
            if compiler:
                for m in NAME.finditer(line):
                    uses.add((path, lineno, m.group(0)))
                continue
            i = 0
            while i < len(line):
                q = line.find('"', i)
                if q < 0:
                    for m in NAME.finditer(line[i:]):
                        uses.add((path, lineno, m.group(0)))
                    break
                for m in NAME.finditer(line[i:q]):
                    uses.add((path, lineno, m.group(0)))
                q2 = line.find('"', q + 1)
                if q2 < 0:
                    break
                content = line[q + 1:q2]
                for m in NAME.finditer(content):
                    tok = m.group(0)
                    if content != tok:
                        continue  # fragment inside a longer literal
                    if line[q2 + 1:].lstrip().startswith('+'):
                        continue  # name-construction concatenation
                    if PROBE_CALL.search(line):
                        probes.add((path, lineno, tok))
                    else:
                        uses.add((path, lineno, tok))
                i = q2 + 1

for kind, items in (('U', uses), ('P', probes)):
    for path, lineno, name in sorted(items):
        print(kind + '\t' + path + ':' + str(lineno) + '\t' + name)
PY
); then
  fail "the quote-aware use scan failed (python3)"
  scan_out=""
fi
uses=$(printf '%s\n' "$scan_out" | awk -F '\t' '$1 == "U" { print $2 " " $3 }' | sort -u)
probes=$(printf '%s\n' "$scan_out" | awk -F '\t' '$1 == "P" { print $2 " " $3 }' | sort -u)
probe_count=$(printf '%s\n' "$probes" | sed '/^$/d' | wc -l | tr -d ' ')

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
    # The LIR explicit-op router: `__intrinsic_simd_<op>_<lane>` is
    # routed when the segment between `simd_` and the FINAL `_` is a
    # router token (the lane is the lowering's fail-closed domain).
    if [ "$stripped" != "$name" ] && [[ "$stripped" == simd_* ]]; then
      ext_tail="${stripped#simd_}"
      ext_op="${ext_tail%_*}"
      if [ "$ext_op" != "$ext_tail" ] && echo "$ext_ops" | grep -qx "$ext_op"; then
        continue
      fi
    fi
    if echo "$KNOWN_EXCEPTIONS" | tr ' ' '\n' | grep -qx "$name"; then
      echo "  [known-exception] $name (site: $site) — pre-gate phantom, MUST be resolved"
      continue
    fi
    fail "PHANTOM intrinsic use: $name (site: $site) — not classified (intrinsic_id_of_call / lir_simd_ext_op_of), not extern-declared, not runtime-defined"
    phantom=$((phantom + 1))
  fi
done <<< "$use_names_with_sites"

# The negative classifier probes (reported informationally, never
# failed): the tests pass these spellings to a router and assert it
# rejects them, so they can never be lowered — they are boundary
# assertions, not uses.
while IFS=' ' read -r site name; do
  [ -n "$name" ] || continue
  echo "  [probe-fixture] $name (site: $site) — classifier probe asserted not-classified; not a use"
done <<< "$probes"

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

echo "phantoms: $phantom, probe fixtures: $probe_count, dead implementations: $dead, resolved exceptions: $resolved"
if [ "$FAILURES" -eq 0 ]; then
  echo "intrinsic closure: PASS"
  exit 0
else
  echo "intrinsic closure: FAIL ($FAILURES issue(s))"
  exit 1
fi
