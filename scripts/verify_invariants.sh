#!/usr/bin/env bash
# ———————————————————————————————————————————————————————————————
# Tangerine invariant-verification artifact
# scripts/verify_invariants.sh
#
# Machine-checkable encoding of the round-7 audit invariants. Every
# assertion below is a structural check over the SOURCE TREE (grep /
# line-range / manifest parity — no compiler ladder runs), the same
# evidence the review prose asserted. A failing assertion means the
# invariant is NOT true of the tree — the fact, not the prose, is
# authoritative. Exit status: 0 = every assertion passed; 1 = at least
# one assertion failed (a CI gate).
#
# Group map (the reviewer's mandate items):
#   G1  Map/Set header   G2  String ABI         G3  Reference model
#   G4  Deleted authorities                     G5  Collection ownership
#   G6  Verifier         G7  Allocator          G8  Mode reduction
#   G9  Diagnostics      G10 Infrastructure     G11 Module identity
#   G12 Summary report
#
# Run: bash scripts/verify_invariants.sh
# ———————————————————————————————————————————————————————————————
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT" || { echo "cannot cd to repo root"; exit 2; }

# The SOURCE-INTEGRITY mode for the bounded mutation harness:
# --mutation-source-integrity <mutation-id> — run against a MUTATED copy:
# the mutation's own G13 assertion MUST FIRE (the canonical form at the
# site is destroyed = the mutation is really applied at the intended
# site), the documented site-mirror assertions (non-G13 assertions
# encoding the SAME canonical form) may fire too, and every other
# assertion must PASS. Exit 0 = source integrity holds; 1 = the mutation
# is not observable at its site or collateral invariant disturbance.
# This mode NEVER classifies a kill (the kill classification is the
# behavioral tier of scripts/run_mutation_tests.sh). Without the flag the
# script runs the plain invariant gate (G13 holds on the pristine tree).
MUTATION_SOURCE_CHECK=""
while [ $# -gt 0 ]; do
  case "$1" in
    --mutation-source-integrity)
      shift
      MUTATION_SOURCE_CHECK="${1:-}"
      shift
      ;;
    *) break ;;
  esac
done

PASSED=0
FAILURES=0
FAILED_LABELS=""
CURRENT_GROUP=""

# report <label> <desc> <status>
report() {
  printf '  [%s] %-4s %s\n' "$1" "$3" "$2"
  case "$3" in
    PASS) PASSED=$((PASSED + 1)) ;;
    FAIL) FAILURES=$((FAILURES + 1)); FAILED_LABELS="${FAILED_LABELS} $1" ;;
  esac
}

# t <label> <desc> <command-string>   — non-zero = FAIL (eval keeps the
# helper functions in scope; every command string is literal below).
t() {
  local label="$1" desc="$2" cmd="$3" rc
  eval "$cmd"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    report "$label" "$desc" PASS
  else
    report "$label" "$desc" FAIL
  fi
}

# group <G#.name> <title>
group() {
  CURRENT_GROUP="$1"
  printf '\n== %s: %s ==\n' "$1" "$2"
}

# ———————————————————————————————————————————————————————————————
# Kernel source set (bootstrap/compiler_kernel.manifest is the authority).
# ———————————————————————————————————————————————————————————————
kernel_sources() {
  ls "$ROOT"/tg_compiler/*.tg
  grep '^std: ' "$ROOT"/bootstrap/compiler_kernel.manifest | sed 's/^std: /std\//'
}

# ———————————————————————————————————————————————————————————————
# G1  Map/Set header
# ———————————————————————————————————————————————————————————————
group G1 "Map/Set header: 96-byte canonical layout"

t G1.1 "map_header_total_size() == 96 (the canonical authority)" \
  'grep -qE "^def map_header_total_size\(\) -> Int = 96$" tg_compiler/layout_engine.tg'

while read -r fld off; do
  t "G1.2.$fld" "MAP_HEADER_FIELDS table: $fld == $off" \
    "grep -qE 'field_name == \"$fld\".*then Option::Some\($off\)' tg_compiler/layout_engine.tg"
done <<'FIELDS'
buckets 0
size 8
capacity 16
key_stride 24
key_align 32
value_stride 40
value_align 48
key_off 56
value_off 64
next_off 72
bucket_stride 80
free_list 88
FIELDS

t G1.3a "map_header_assert_contract exists and enforces total == 96" \
  'grep -q "^def map_header_assert_contract" tg_compiler/layout_engine.tg && grep -q "if total != 96 then" tg_compiler/layout_engine.tg'

t G1.3b "map_header_assert_contract table_read checks every field" \
  'grep -q "table_read(\"buckets\", 0)" tg_compiler/layout_engine.tg && grep -q "table_read(\"size\", 8)" tg_compiler/layout_engine.tg && grep -q "table_read(\"capacity\", 16)" tg_compiler/layout_engine.tg && grep -q "table_read(\"key_stride\", 24)" tg_compiler/layout_engine.tg && grep -q "table_read(\"key_align\", 32)" tg_compiler/layout_engine.tg && grep -q "table_read(\"value_stride\", 40)" tg_compiler/layout_engine.tg && grep -q "table_read(\"value_align\", 48)" tg_compiler/layout_engine.tg && grep -q "table_read(\"key_off\", 56)" tg_compiler/layout_engine.tg && grep -q "table_read(\"value_off\", 64)" tg_compiler/layout_engine.tg && grep -q "table_read(\"next_off\", 72)" tg_compiler/layout_engine.tg && grep -q "table_read(\"bucket_stride\", 80)" tg_compiler/layout_engine.tg && grep -q "table_read(\"free_list\", 88)" tg_compiler/layout_engine.tg'

missing_h=""
for i in $(seq 1 33); do
  grep -qF "\"H$i:" tests/layout_tests.tg || missing_h="$missing_h H$i"
done
if [ -z "$missing_h" ]; then
  report G1.4 "layout tests H1..H33 all present in tests/layout_tests.tg" PASS
else
  report G1.4 "layout tests H1..H33 all present (missing:$missing_h)" FAIL
fi

t G1.5 "zero '88-byte' map-header claims in the tg sources" \
  '! grep -rq "88-byte" tg_compiler/*.tg std/*.tg tests/*.tg tests/layout/*.tg'

# ———————————————————————————————————————————————————————————————
# G2  String ABI
# ———————————————————————————————————————————————————————————————
group G2 "String ABI: 8-byte handle + 32-byte owned object"

t G2.1 "layout test A20: String handle size = 8" \
  'grep -qF "\"A20: String handle size = 8" tests/layout_tests.tg'
t G2.2 "layout test A26: String object header = 32" \
  'grep -qF "\"A26: String object header = 32" tests/layout_tests.tg'
t G2.3 "_tg_string_drop runtime emitter exists" \
  'grep -qE "^def emit_tg_string_drop" tg_compiler/runtime.tg && grep -q "_tg_mem_free" tg_compiler/runtime.tg'
t G2.4a "DeinitPlan::String variant in the DeinitPlan enum (types.tg)" \
  'awk "/^enum DeinitPlan\$/,/^end\$/" tg_compiler/types.tg | grep -qE "^[[:space:]]*String\$"'
t G2.4b "DeinitPlan::String arm in mir.tg drop planning" \
  'grep -q "DeinitPlan::String" tg_compiler/mir.tg'
t G2.5 "String Clone/Eq/Hash impls in std/core.tg" \
  'grep -q "^impl Clone for String$" std/core.tg && grep -q "^impl Eq for String$" std/core.tg && grep -q "^impl Hash for String$" std/core.tg'
t G2.6 "_tg_string_reserve frees the old buffer (a64 + x64 free call sites)" \
  'awk "/^def emit_tg_string_reserve/{f=1; d=0} f && /^def /{d++} d==1 && /_tg_mem_free/{n++} d>1{exit} END{exit !(n>=2)}" tg_compiler/runtime.tg'

# ———————————————————————————————————————————————————————————————
# G3  Reference model
# ———————————————————————————————————————————————————————————————
group G3 "Reference model: no first-class references"

t G3.1a "E106 diagnostic registered (ErrorCode::E106SafeRefNotFirstClass)" \
  'grep -q "ErrorCode::E106SafeRefNotFirstClass" tg_compiler/parser.tg && grep -q "then \"E106\"" tg_compiler/parser.tg'
t G3.1b "E106 'ref patterns are not supported' message" \
  'grep -q "ref patterns are not supported" tg_compiler/parser.tg'
t G3.2 "parse_single_pattern rejects & / &mut / ref arms (3 diag sites)" \
  'test "$(grep -c "diag_ref_pattern_not_supported(&mut p.diag" tg_compiler/parser.tg)" -eq 3'
t G3.3a "extern ABI gate: parse_extern_fn + parse_extern_static key on is_intrinsic_extern_name (2 sites)" \
  'test "$(grep -c "p.extern_abi_context = is_intrinsic_extern_name(&name)" tg_compiler/parser.tg)" -eq 2'
t G3.3b "is_intrinsic_extern_name = the __intrinsic_ prefix test (ids.tg)" \
  'grep -q "def is_intrinsic_extern_name" tg_compiler/ids.tg && grep -q "starts_with(\"__intrinsic_\")" tg_compiler/ids.tg'

bad_ref_pos=""
for f in $(kernel_sources); do
  hits=$(grep -n -e '-> &' -e 'Option\[&' "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | grep -vE 'extern def __intrinsic_' || true)
  if [ -n "$hits" ]; then bad_ref_pos="$bad_ref_pos
$f: $hits"; fi
done
if [ -z "$bad_ref_pos" ]; then
  report G3.4 "zero \`-> &\`/\`Option[&\` positions outside __intrinsic_-gated externs (kernel sources)" PASS
else
  report G3.4 "zero \`-> &\`/\`Option[&\` positions outside __intrinsic_-gated externs: $bad_ref_pos" FAIL
fi

bad_ref_pat=""
for f in $(kernel_sources); do
  hits=$(grep -nF -e '(ref ' "$f" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' || true)
  if [ -n "$hits" ]; then bad_ref_pat="$bad_ref_pat
$f: $hits"; fi
done
if [ -z "$bad_ref_pat" ]; then
  report G3.5 "zero ref-pattern binders in the kernel/std sources" PASS
else
  report G3.5 "zero ref-pattern binders in the kernel/std sources: $bad_ref_pat" FAIL
fi

# ———————————————————————————————————————————————————————————————
# G4  Deleted authorities
# ———————————————————————————————————————————————————————————————
group G4 "Deleted authorities: Type::Function / ParamModifier / Permissive / review items"

t G4.1 "zero Type::Function in tg_compiler + std" \
  '! grep -rq "Type::Function" tg_compiler/*.tg std/*.tg'
t G4.2 "zero non-comment ParamModifier in tg_compiler + std" \
  'test -z "$(grep -rn "ParamModifier" tg_compiler/*.tg std/*.tg | grep -vE ":[0-9]+:[[:space:]]*#" || true)"'
t G4.3 "zero 'Permissive' arity-unification token in tg_compiler + std" \
  '! grep -rq "Permissive" tg_compiler/*.tg std/*.tg'
t G4.4 "zero P0-<n> / P1-<n> / reviewer-item tokens in tg_compiler + std" \
  'test -z "$(grep -rn -e "P0-[0-9]" -e "P1-[0-9]" -e "reviewer item" -e "reviewer-item" tg_compiler/*.tg std/*.tg || true)"'

# ———————————————————————————————————————————————————————————————
# G5  Collection ownership
# ———————————————————————————————————————————————————————————————
group G5 "Collection ownership: Copy/_cloned accessor discipline"

# in_block_def <file> <impl-header-substr> <def-substr>: the def appears
# inside the impl block opened by the header (block closed at the next
# top-level `end`).
in_block_def() {
  awk -v h="$2" -v d="$3" '
    index($0, h) { inb = 1 }
    inb && index($0, d) { found = 1; exit }
    inb && /^end$/ { inb = 0 }
    inb && /^impl\[/ && !index($0, h) { exit }
    END { exit !found }
  ' "$1"
}

t G5.1a "Map::get is Copy-gated (impl[K: Hash + Eq, V: Copy])" \
  'in_block_def std/collections.tg "impl[K: Hash + Eq, V: Copy] Map[K, V]" "def get(self: Self, key: K) -> Option[V]"'
t G5.1b "Map::entries is Copy-gated (impl[K: Hash + Eq + Copy, V: Copy])" \
  'in_block_def std/collections.tg "impl[K: Hash + Eq + Copy, V: Copy] Map[K, V]" "def entries(self: Self) -> Vec[(K, V)]"'
t G5.1c "Map::entries_cloned is the Clone variant (impl[K: Hash + Eq + Clone, V: Clone])" \
  'in_block_def std/collections.tg "impl[K: Hash + Eq + Clone, V: Clone] Map[K, V]" "def entries_cloned(self: Self) -> Vec[(K, V)]"'
t G5.1d "Set::entries_copy is Copy-gated (impl[T: Hash + Eq + Copy])" \
  'in_block_def std/collections.tg "impl[T: Hash + Eq + Copy] Set[T]" "def entries_copy(self: Self) -> Vec[T]"'
t G5.1e "Set::entries_cloned is the Clone variant (impl[T: Hash + Eq + Clone])" \
  'in_block_def std/collections.tg "impl[T: Hash + Eq + Clone] Set[T]" "def entries_cloned(self: Self) -> Vec[T]"'
t G5.1f "OrderedMap::get is Copy-gated (impl[K: Hash + Eq, V: Copy])" \
  'in_block_def std/collections.tg "impl[K: Hash + Eq, V: Copy] OrderedMap[K, V]" "def get(self: Self, key: K) -> Option[V]"'
t G5.1g "OrderedMap::get_cloned is the Clone variant (impl[K: Hash + Eq, V: Clone])" \
  'in_block_def std/collections.tg "impl[K: Hash + Eq, V: Clone] OrderedMap[K, V]" "def get_cloned(self: Self, key: K) -> Option[V]"'
t G5.1h "RingBuffer::peek_front is Copy-gated (impl[T: Copy])" \
  'in_block_def std/collections.tg "impl[T: Copy] RingBuffer[T]" "def peek_front(self: Self) -> Option[T]"'
t G5.1i "RingBuffer::peek_front_cloned is the Clone variant (impl[T: Clone])" \
  'in_block_def std/collections.tg "impl[T: Clone] RingBuffer[T]" "def peek_front_cloned(self: Self) -> Option[T]"'
t G5.1j "Array::get/slice are Copy-gated (impl[T: Copy])" \
  'in_block_def std/collections.tg "impl[T: Copy] Array[T]" "def get(self: Self, index: Int) -> T" && in_block_def std/collections.tg "impl[T: Copy] Array[T]" "def slice(self: Self, start: Int, end_idx: Int) -> Array[T]"'

# block_with <file> <impl-header-substr> <needle>: the needle appears
# inside the impl block. block_without: the needle does NOT.
block_with() {
  awk -v h="$2" -v n="$3" '
    index($0, h) { inb = 1 }
    inb && index($0, n) { found = 1; exit }
    inb && /^end$/ { inb = 0 }
    END { exit !found }
  ' "$1"
}
block_without() {
  awk -v h="$2" -v n="$3" '
    index($0, h) { inb = 1 }
    inb && index($0, n) { found = 1 }
    inb && /^end$/ { inb = 0 }
    END { exit found }
  ' "$1"
}

t G5.2a "Map entries_cloned walks the visit intrinsics (begin/next/value)" \
  'block_with std/collections.tg "impl[K: Hash + Eq + Clone, V: Clone] Map[K, V]" "__intrinsic_map_visit_begin" && block_with std/collections.tg "impl[K: Hash + Eq + Clone, V: Clone] Map[K, V]" "__intrinsic_map_visit_next" && block_with std/collections.tg "impl[K: Hash + Eq + Clone, V: Clone] Map[K, V]" "__intrinsic_map_visit_value"'
t G5.2b "zero __intrinsic_map_entries in the Clone-bounded Map block" \
  'block_without std/collections.tg "impl[K: Hash + Eq + Clone, V: Clone] Map[K, V]" "__intrinsic_map_entries"'
t G5.2c "Set entries_cloned walks the visit intrinsics, no raw entries" \
  'block_with std/collections.tg "impl[T: Hash + Eq + Clone] Set[T]" "__intrinsic_set_visit_begin" && block_without std/collections.tg "impl[T: Hash + Eq + Clone] Set[T]" "__intrinsic_set_entries"'

# ———————————————————————————————————————————————————————————————
# G6  Verifier
# ———————————————————————————————————————————————————————————————
group G6 "Verifier: projection-walking place typing"

t G6.1 "exactly one verifier_place_result_type_opt definition (mir.tg)" \
  'test "$(grep -c "^def verifier_place_result_type_opt" tg_compiler/mir.tg)" -eq 1'
t G6.2 "verifier projection tests exist (tests/verifier_projection_tests.tg)" \
  'test -s tests/verifier_projection_tests.tg && grep -q "def " tests/verifier_projection_tests.tg'

# ———————————————————————————————————————————————————————————————
# G7  Allocator
# ———————————————————————————————————————————————————————————————
group G7 "Allocator: free-list linkage, fail-closed checks, platform pairing"

t G7.1 "free-list small-class LIFO push in _tg_mem_free (all 4 arch/OS paths)" \
  'test "$(grep -c "Small: link the block into the class free list" tg_compiler/runtime.tg)" -eq 4 && grep -q "_tg_alloc_free_heads" tg_compiler/runtime.tg'
t G7.2 "MAP_FAILED check before every large-block header write (4 sites)" \
  'test "$(grep -c "MAP_FAILED check BEFORE the header write" tg_compiler/runtime.tg)" -eq 4'
t G7.3 "Windows pairing: marker-1 blocks -> VirtualFree (a64) / HeapFree (x64)" \
  'grep -q "marker 1 -> VirtualFree" tg_compiler/runtime.tg && grep -q "marker 1 -> HeapFree" tg_compiler/runtime.tg'
t G7.4 "allocator tests exist (churn/large/oom/reuse)" \
  'test -s tests/allocator_churn_test.tg && test -s tests/allocator_large_test.tg && test -s tests/allocator_oom_test.tg && test -s tests/allocator_reuse_test.tg'

# ———————————————————————————————————————————————————————————————
# G8  Mode reduction
# ———————————————————————————————————————————————————————————————
group G8 "Mode reduction: ModeConfig carries only the enforced bits"

t G8.1 "ModeConfig fields are exactly mode/enforce_contracts/enforce_capabilities" \
  'test "$(awk "/^struct ModeConfig\$/{s=1; next} s && /^end\$/{exit} s{print}" tg_compiler/mode.tg | sed -E "s/[[:space:]]*:.*//; s/^[[:space:]]*//" | tr "\n" " ")" = "mode enforce_contracts enforce_capabilities "'
t G8.2 "zero enforce_effects/enforce_budgets/enforce_io/enforce_purity/enforce_linearity in mode.tg" \
  '! grep -qE "enforce_effects|enforce_budgets|enforce_io|enforce_purity|enforce_linearity|enforce_taint|enforce_contracts_v2|enforce_capabilities_v2" tg_compiler/mode.tg'

# ———————————————————————————————————————————————————————————————
# G9  Diagnostics
# ———————————————————————————————————————————————————————————————
group G9 "Diagnostics: structured Vec[Diagnostic] through analysis"

t G9.1a "analyze_parsed/analyze_program/analyze_source return Vec[Diagnostic]" \
  'test "$(grep -cE "^pub def analyze_(parsed|program|source).*Result\[AnalyzedProgram, Vec\[Diagnostic\]\]$" tg_compiler/compiler_core.tg)" -eq 3'
t G9.1b "zero Result[AnalyzedProgram, String] signatures" \
  '! grep -rq "Result\[AnalyzedProgram, String\]" tg_compiler/*.tg'
t G9.2a "join_diagnostics exists and is the String boundary" \
  'grep -qE "^pub def join_diagnostics\(diags: Vec\[Diagnostic\]\) -> String$" tg_compiler/compiler_core.tg'
t G9.2b "no join_diagnostics inside the structured analysis surface (analyze_parsed..analyze_source)" \
  'awk "/^pub def analyze_parsed/{f=1} f && /^pub def compile_file_core/{f=0} f && /join_diagnostics/{n++} END{exit n+0}" tg_compiler/compiler_core.tg'
t G9.2c "join_diagnostics lives at the CLI boundary (driver.tg + compile_file_core)" \
  'test "$(grep -c "join_diagnostics" tg_compiler/driver.tg)" -ge 2 && test "$(awk "/^pub def compile_file_core/{f=1} f && /join_diagnostics/{n++} END{print n+0}" tg_compiler/compiler_core.tg)" -ge 2'

# ———————————————————————————————————————————————————————————————
# G10 Infrastructure
# ———————————————————————————————————————————————————————————————
group G10 "Infrastructure: manifest parity, harness constants, flag parity, gates"

# suite_parity <dir> <manifest>: listed == discovered == declared,
# every listed file exists, every discovered file is listed.
suite_parity() {
  local dir="$1" manifest="$2"
  [ -d "$dir" ] || return 1
  [ -f "$manifest" ] || return 1
  local declared listed discovered entry line f
  declared="$(grep -E '^# count: [0-9]+' "$manifest" | sed -E 's/^# count: //' | head -n1)"
  [ -n "$declared" ] || return 1
  listed=0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    entry="${line%%$'\t'*}"
    [ -f "$dir/$entry" ] || return 1
    listed=$((listed + 1))
  done < "$manifest"
  discovered=0
  for f in "$dir"/*.tg; do
    [ -e "$f" ] || continue
    entry="$(basename "$f")"
    grep -qxF "$entry" <(grep -vE '^#|^[[:space:]]*$' "$manifest" | cut -f1) || return 1
    discovered=$((discovered + 1))
  done
  [ "$listed" -eq "$discovered" ] && [ "$declared" -eq "$listed" ] || return 1
}

t G10.1a "canary MANIFEST three-way parity: tests/canary (recomputed from FS)" \
  'suite_parity tests/canary tests/canary/MANIFEST'
t G10.1b "canary MANIFEST three-way parity: tests/canary_neg (recomputed from FS)" \
  'suite_parity tests/canary_neg tests/canary_neg/MANIFEST'
t G10.1c "canary MANIFEST three-way parity: tests/arm64 (recomputed from FS)" \
  'suite_parity tests/arm64 tests/arm64/MANIFEST'

pos_actual="$(ls tests/canary/*.tg 2>/dev/null | wc -l | tr -d ' ')"
neg_actual="$(ls tests/canary_neg/*.tg 2>/dev/null | wc -l | tr -d ' ')"
arm_actual="$(ls tests/arm64/*.tg 2>/dev/null | wc -l | tr -d ' ')"
t G10.2a "harness constant CANARY_SUITE_POSITIVE_COUNT matches filesystem ($pos_actual)" \
  "test \"\$(grep -E '^CANARY_SUITE_POSITIVE_COUNT=' scripts/bootstrap_helpers.sh | head -1 | cut -d= -f2)\" = \"$pos_actual\""
t G10.2b "harness constant CANARY_SUITE_NEGATIVE_COUNT matches filesystem ($neg_actual)" \
  "test \"\$(grep -E '^CANARY_SUITE_NEGATIVE_COUNT=' scripts/bootstrap_helpers.sh | head -1 | cut -d= -f2)\" = \"$neg_actual\""
t G10.2c "harness constant CANARY_SUITE_ARM64_COUNT matches filesystem ($arm_actual)" \
  "test \"\$(grep -E '^CANARY_SUITE_ARM64_COUNT=' scripts/bootstrap_helpers.sh | head -1 | cut -d= -f2)\" = \"$arm_actual\""

for flag in dump-tokens dump-ast dump-resolved-ast dump-mir-lowered dump-mir-mono; do
  t "G10.3.$flag" "dump flag --$flag present in bootstrap_main.tg AND driver.tg" \
    "grep -q -- \"--$flag\" tg_compiler/bootstrap_main.tg && grep -q -- \"--$flag\" tg_compiler/driver.tg"
done

t G10.4 "trap-gate whitelist: check_target_capabilities rejects instead of emitting a trap" \
  'grep -qE "^def check_target_capabilities" tg_compiler/driver.tg && grep -q "capability diagnostic instead of emitting a trap" tg_compiler/driver.tg'
t G10.5 "self-host manifest gate: merge_imported_deps fails without compiler_kernel.manifest" \
  'grep -qE "^pub def merge_imported_deps" tg_compiler/compiler_core.tg && grep -q "requires bootstrap/compiler_kernel.manifest" tg_compiler/compiler_core.tg && grep -q "prelude fallback is disabled in self-host mode" tg_compiler/compiler_core.tg'

# diagnostic_parity: every expected diagnostic substring in the canary_neg
# MANIFEST must be present in the compiler sources — verbatim, or with the
# backtick-quoted spans normalized (a template diagnostic such as
# "no method `{}` on receiver type" still pins the canary's expected
# "no method `iter` on receiver type"). A mutation that deletes or renames
# a diagnostic site the negative canaries pin breaks the parity — the
# mandate's "a deleted diagnostic → the expected substring missing → the
# parity gate fails".
diagnostic_parity() {
  python3 - tests/canary_neg/MANIFEST tg_compiler std <<'PY'
import os, re, sys
manifest, src_dir_a, src_dir_b = sys.argv[1], sys.argv[2], sys.argv[3]
text = ""
for d in (src_dir_a, src_dir_b):
    for f in sorted(os.listdir(d)):
        if f.endswith(".tg"):
            with open(os.path.join(d, f), encoding="utf-8") as fh:
                text += fh.read()
def norm(s):
    return re.sub(r"`[^`]*`", "`X`", s)
for line in open(manifest, encoding="utf-8"):
    line = line.rstrip("\n")
    if not line or line.startswith("#"):
        continue
    parts = line.split("\t")
    if len(parts) < 2:
        continue
    expected = parts[1]
    if expected in text:
        continue
    if norm(expected) != expected and norm(expected) in norm(text):
        continue
    print("expected diagnostic not found in the sources: " + parts[0] + " -> '" + expected + "'", file=sys.stderr)
    sys.exit(1)
PY
}

t G10.6 "canary_neg expected-diagnostic parity: every expected diagnostic substring in the MANIFEST is present in the compiler sources (verbatim or backtick-normalized)" \
  'diagnostic_parity'

# ———————————————————————————————————————————————————————————————
# G11 Module identity
# ———————————————————————————————————————————————————————————————
group G11 "Module identity: O(1) table reads, no lookup-path scans"

t G11.1a "exactly one crate_module_path_of (the O(1) table read)" \
  'test "$(grep -cE "^pub def crate_module_path_of\(" tg_compiler/types.tg)" -eq 1'
t G11.1b "strict/recovery split: crate_module_of(_recovery) / crate_module_path_recovery" \
  'grep -qE "^pub def crate_module_of\(" tg_compiler/types.tg && grep -qE "^pub def crate_module_of_recovery\(" tg_compiler/types.tg && grep -qE "^pub def crate_module_path_recovery\(" tg_compiler/types.tg'
t G11.1c "strict path fails closed on a missing ModuleId (ICE, never root fallback)" \
  'grep -q "must never fall back to the root" tg_compiler/types.tg'

scan_bad=""
for f in types.tg resolver.tg mono.tg resource_check.tg mir.tg; do
  grep -q "crate.modules.entries()" "tg_compiler/$f" && scan_bad="$scan_bad $f"
done
if [ -z "$scan_bad" ]; then
  report G11.2a "zero crate.modules.entries() scans in the lookup modules (types/resolver/mono/resource_check/mir)" PASS
else
  report G11.2a "zero crate.modules.entries() scans in lookup modules (found in:$scan_bad)" FAIL
fi

t G11.2b "the only crate.modules.entries() in the compiler are the macro-filter rebuild, the module-graph dump, and the @cfg module remap (compiler_core.tg)" \
  'test "$(grep -c "crate.modules.entries()" tg_compiler/compiler_core.tg)" -eq 3'

# ———————————————————————————————————————————————————————————————
# G13 Mutation-site SOURCE-INTEGRITY checks (the G13 structural
# detectors — KEPT as the source-integrity checks, REMOVED from the kill
# classification)
# ———————————————————————————————————————————————————————————————
# The bounded mutation harness (scripts/run_mutation_tests.sh) applies one
# mutation at a time to a COPY of the tree and runs the behavioral tier
# (mutate -> build the mutated kernel -> run the per-mutation behavioral
# suite -> KILLED iff the suite FAILS). THE G13 GROUP NEVER CLASSIFIES A
# KILL: each assertion below pins the CANONICAL SEMANTIC FORM of one
# mutation target site — the mutation destroys its own site's canonical
# form, so on the mutated copy the site's own G13 assertion FIRES and the
# other G13 assertions still HOLD. The harness uses the group as the
# SOURCE-INTEGRITY CONFIRMATION (via --mutation-source-integrity <id>):
# the mutation's own G13 must fire — the mutation is really applied at
# the intended site; on the pristine tree every assertion holds. The
# mapping is the harness's mutation catalog:
#   G13.1  <- mut-invert-comparison        G13.8  <- mut-field-offset
#   G13.2  <- mut-delete-diagnostic        G13.9  <- mut-enum-tag
#   G13.3  <- mut-consume-to-read          G13.10 <- mut-remove-overflow-check
#   G13.4  <- mut-modify-to-read           G13.11 <- mut-branch-target
#   G13.5  <- mut-remove-drop-mark         G13.12 <- mut-remove-wake
#   G13.6  <- mut-duplicate-drop           G13.13 <- mut-remove-atomic-ordering
#   G13.7  <- mut-skip-verifier            G13.14 <- mut-equality-to-permissive
# ———————————————————————————————————————————————————————————————
group G13 "Mutation-site source-integrity checks (the canonical-form assertions; never a kill classification)"

# mutation_g13_label <mutation-id> — the G13 assertion that guards the
# mutation's own site (the assertion that MUST FIRE on the mutated copy).
mutation_g13_label() {
  case "$1" in
    mut-invert-comparison)      echo "G13.1" ;;
    mut-delete-diagnostic)      echo "G13.2" ;;
    mut-consume-to-read)        echo "G13.3" ;;
    mut-modify-to-read)         echo "G13.4" ;;
    mut-remove-drop-mark)       echo "G13.5" ;;
    mut-duplicate-drop)         echo "G13.6" ;;
    mut-skip-verifier)          echo "G13.7" ;;
    mut-field-offset)           echo "G13.8" ;;
    mut-enum-tag)               echo "G13.9" ;;
    mut-remove-overflow-check)  echo "G13.10" ;;
    mut-branch-target)          echo "G13.11" ;;
    mut-remove-wake)            echo "G13.12" ;;
    mut-remove-atomic-ordering) echo "G13.13" ;;
    mut-equality-to-permissive) echo "G13.14" ;;
    *)                          echo "" ;;
  esac
}

# mutation_site_mirrors <mutation-id> — the NON-G13 assertions that encode
# the SAME canonical form as the mutation's own G13 (they legitimately
# fire on the mutated copy — e.g. G1.2.key_stride IS the MAP_HEADER_FIELDS
# key_stride offset the field-offset mutation rewrites, so it fires
# alongside G13.8).
mutation_site_mirrors() {
  case "$1" in
    mut-field-offset) echo "G1.2.key_stride" ;;
    *) echo "" ;;
  esac
}

t G13.1 'invert-comparison detector: the field-index bounds check is the canonical `>= 0 && < len()` form (a valid index is never rejected)' \
  'grep -qF "if fid.index >= 0 && fid.index < fields.len() then" tg_compiler/types.tg'

t G13.2 "delete-diagnostic detector: the ABI-classification block's two diagnostic arms are both present (the extern-unknown arm's deletion breaks the two-site count and the expected substring goes missing)" \
  'test "$(grep -c "extern function carries unknown ABI classification" tg_compiler/mir.tg)" -eq 1 && test "$(grep -c "non-extern function carries ABI classification" tg_compiler/mir.tg)" -eq 1'

t G13.3 "consume-to-read detector: the partial-move binder still classifies AccessEffect::Consume (a moving binding is never read-only)" \
  'grep -qF "if bp.action == AccessEffect::Consume then" tg_compiler/types.tg && grep -q "canary_neg_access_sink_twice.tg.*consumed twice" tests/canary_neg/MANIFEST && grep -q "canary_neg_access_sink_use_after.tg.*use of consumed" tests/canary_neg/MANIFEST && grep -qF "consumed twice" tg_compiler/resource_check.tg'

t G13.4 "modify-to-read detector: the inout access convention still maps to AccessEffect::Modify (an inout parameter is never read-only)" \
  'grep -qF "when AccessConvention::Inout then AccessEffect::Modify" tg_compiler/mir.tg && grep -q "canary_neg_access_inout_dup.tg.*conflicting accesses" tests/canary_neg/MANIFEST && grep -qF "conflicting accesses" tg_compiler/access_check.tg'

t G13.5 "remove-drop-mark detector: the partial-move registry still marks the consumed place (the MIR partial-drop chain sees the Consumed state)" \
  'grep -qF "ext.insert(path.clone(), PlaceMoveState::Consumed)" tg_compiler/types.tg && grep -q "canary_neg_resource_use_after_consume.tg.*consumed" tests/canary_neg/MANIFEST && grep -qF "use of consumed" tg_compiler/resource_check.tg'

t G13.6 "duplicate-drop detector: the deinit-count invariants — the MirDeinit identity guard and the deinit-instance registration site both present, each exactly once (a duplicate/unregistered deinit is a verifier error; the collection site count is pinned)" \
  'grep -qF "if !deinit_instances.contains(&inst_key) && !drop_glue_fns.contains_key(&inst_key) then" tg_compiler/mir.tg && test "$(grep -c "collect_deinit_plan_instances(&dp, &mut deinit_instances)" tg_compiler/mir.tg)" -eq 1'

t G13.7 "skip-verifier detector: the MIR firewall calls verify_function_v2 from verify_mir and never early-returns an empty error list" \
  'test "$(grep -c "verify_function_v2(&type_index" tg_compiler/mir.tg)" -eq 1 && test "$(awk "/^def verify_mir\(/{f=1; next} f && /^def /{f=0} f && /return Vec::new\(\)/{n++} END{print n+0}" tg_compiler/mir.tg)" -eq 0'

t G13.8 "field-offset detector: the Map header key_stride offset is the canonical 24 (the MAP_HEADER_FIELDS table)" \
  'grep -qE "field_name == \"key_stride\".*then Option::Some\(24\)" tg_compiler/layout_engine.tg'

t G13.9 "enum-tag detector: the TaggedUnion layout record pins tag_size 8 / payload_offset 8 (F3 — tag at 0, payload at 8)" \
  'grep -qF "tag_size: 8" tg_compiler/layout_engine.tg && grep -qF "payload_offset: 8" tg_compiler/layout_engine.tg && grep -qF "\"B7: Enum tag at offset 0\"" tests/layout_tests.tg'

t G13.10 "remove-overflow-check detector: layout_checked_add keeps the fail-closed overflow guard (a wrapped size/offset never reaches the emitter)" \
  'grep -qF "if b > 9223372036854775807 - a then" tg_compiler/layout_engine.tg && grep -qF "if a != 0 && b > 9223372036854775807 / a then" tg_compiler/layout_engine.tg'

t G13.11 "branch-target detector: verify_function_v2 early-returns ONLY for extern functions (the non-extern edge stays verified)" \
  'test "$(awk "/^def verify_function_v2\(/{f=1} f && /if func.is_extern then return end/{n++} f && /^def / && !/^def verify_function_v2/{f=0} END{print n+0}" tg_compiler/mir.tg)" -eq 1 && ! grep -qF "if !func.is_extern then return end" tg_compiler/mir.tg'

t G13.12 "remove-wake detector: the task waker's wake_task dispatch site is present (the ready-queue wake path exists)" \
  'grep -qF "      exec.wake_task(self.task_id)" std/async.tg && test "$(grep -c "wake_task" std/async.tg)" -eq 10'

t G13.13 "remove-atomic-ordering detector: the x86 SeqCst store branch and the a64 ordering arms (ldaddal/casal/xchg) are present" \
  'grep -qF "emit8(&mut ctx.text, 0x05)   # cmp edx, 5 (SeqCst)" tg_compiler/codegen.tg && grep -q "a64_ldaddal" tg_compiler/codegen.tg && grep -q "a64_casal" tg_compiler/codegen.tg && grep -q "xchg" tg_compiler/codegen.tg'

t G13.14 'permissive-equality detector: the EXACT-equality invariants (the E0225-class) — the depth-1 projection check is the exact `== 1`, the convention-equality site is the exact `!(cpt.convention == ipt.convention)` form with the E0225 code, and the convention-mismatch negative canaries pin the expected text; the permissive `>= 1` never appears at the projection site' \
  'grep -qF "if keys.len() == 1 then" tg_compiler/types.tg && ! grep -qF "if keys.len() >= 1 then" tg_compiler/types.tg && grep -qF "if !(cpt.convention == ipt.convention) then" tg_compiler/types.tg && grep -q "\"E0225\"" tg_compiler/types.tg && grep -q "canary_neg_conv_convention_inout_let.tg.*access convention mismatch" tests/canary_neg/MANIFEST && grep -q "canary_neg_conv_convention_let_inout.tg.*access convention mismatch" tests/canary_neg/MANIFEST'

# ———————————————————————————————————————————————————————————————
# G12 Summary report
# ———————————————————————————————————————————————————————————————
printf '\n== %s: Summary ==\n' "G12"
printf '  assertions: %d total, %d passed, %d failed\n' "$((PASSED + FAILURES))" "$PASSED" "$FAILURES"

# — the SOURCE-INTEGRITY verdict (--mutation-source-integrity <id>) —
# The bounded mutation harness runs this mode on a MUTATED copy: the
# mutation's own G13 assertion MUST FIRE (the canonical form at the site
# is destroyed = the mutation is really applied at the intended site —
# its FAIL above is the FIRED signal); the documented site-mirror
# assertions may fire too; every other assertion must PASS. This is a
# SOURCE-INTEGRITY check only — it NEVER classifies a kill (the kill
# classification is the behavioral tier of scripts/run_mutation_tests.sh:
# mutate -> build the mutated kernel -> run the per-mutation behavioral
# suite -> KILLED iff the suite FAILS).
if [ -n "$MUTATION_SOURCE_CHECK" ]; then
  OWN_LABEL="$(mutation_g13_label "$MUTATION_SOURCE_CHECK")"
  if [ -z "$OWN_LABEL" ]; then
    printf '  RESULT: FAIL — unknown mutation id for the source-integrity mode: %s\n' "$MUTATION_SOURCE_CHECK"
    exit 2
  fi
  MIRRORS=" $(mutation_site_mirrors "$MUTATION_SOURCE_CHECK") "
  FIRED=0
  COLLATERAL=""
  for label in $FAILED_LABELS; do
    if [ "$label" = "$OWN_LABEL" ]; then
      FIRED=1
    elif [[ "$MIRRORS" == *" $label "* ]]; then
      :
    else
      COLLATERAL="$COLLATERAL $label"
    fi
  done
  if [ "$FIRED" -eq 0 ]; then
    printf '  RESULT: FAIL — source integrity: the mutation %s is NOT observable at its target site (the %s canonical form still holds — the transformation was a no-op or the catalog drifted from the sources)\n' "$MUTATION_SOURCE_CHECK" "$OWN_LABEL"
    exit 1
  fi
  if [ -n "$COLLATERAL" ]; then
    printf '  RESULT: FAIL — source integrity: the mutation %s fired its own %s assertion but ALSO disturbed invariant(s) beyond the site:%s\n' "$MUTATION_SOURCE_CHECK" "$OWN_LABEL" "$COLLATERAL"
    exit 1
  fi
  printf '  RESULT: PASS — source integrity: the mutation %s is applied at the intended site (%s FIRED on the mutated copy); every other invariant holds (this is the application confirmation, never a kill classification)\n' "$MUTATION_SOURCE_CHECK" "$OWN_LABEL"
  exit 0
fi

if [ "$FAILURES" -eq 0 ]; then
  printf '  RESULT: PASS — every encoded invariant holds on this tree\n'
  exit 0
fi
printf '  RESULT: FAIL — invariant(s) not machine-verified: %s\n' "$FAILED_LABELS"
exit 1
