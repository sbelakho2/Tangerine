#!/usr/bin/env bash
# ———————————————————————————————————————————————————————————————
# scripts/run_mutation_tests.sh — the bounded mutation harness
# (the reviewer's mutation categories; the SEMANTIC mutation protocol).
#
# THE SEMANTIC MUTATION PROTOCOL (the reviewer's mandate):
#   mutate -> BUILD the mutated compiler/runtime -> RUN the behavioral
#   suite -> the mutation is KILLED iff the behavioral suite FAILS.
# Per mutation:
#   (1) MUTATE — apply ONE scripted transformation to a COPY of the tree
#       (the ORIGINALS ARE NEVER MODIFIED; exact-string edits with an
#       anchor-count assertion — an unapplied transformation is a drift
#       error; the mutated file must differ from the pristine original).
#   (2) SOURCE-INTEGRITY CONFIRMATION (never a kill classification) — the
#       per-mutation detector (scripts/mutation_detectors.sh) MUST FIRE
#       (the canonical semantic form at the intended site is destroyed)
#       and scripts/verify_invariants.sh --mutation-source-integrity <id>
#       must pass (the mutation's own G13 assertion fired; every other
#       invariant holds). The G13 structural detectors are KEPT ONLY as
#       these source-integrity checks — they verify the mutation was
#       applied at the intended site and NEVER classify a kill.
#   (3) BUILD — when a usable current-grammar compiler binary exists (the
#       ladder produces one: build/tg_stage3 -> tg_stage2 -> tg_stage1,
#       or the --binary argument), the MUTATED kernel is compiled with it
#       (tg_compiler/bootstrap_main.tg -> the mutated compiler binary).
#       A mutated kernel that does not compile is caught at the BUILD
#       step — KILLED-BEHAVIORALLY (the build is part of the protocol).
#   (4) RUN — the PER-MUTATION BEHAVIORAL SUITE (the mapping table below)
#       runs under the mutated compiler. The mutation is KILLED iff the
#       mapped behavioral suite FAILS. A suite that PASSES under the
#       mutated compiler = SURVIVED (a finding — every catalog entry is
#       non-equivalent, so a survivor means the suite needs a detector).
#
# THE HONEST CURRENT STATE: without a usable compiler binary the
# behavioral tier cannot run — every mutation's kill classification is
# PENDING-UNTIL-BINARY (NOT killed). PENDING-UNTIL-BINARY and SURVIVED
# make the release gate fail: with --gate the harness exits nonzero while
# any non-equivalent mutation is not KILLED-BEHAVIORALLY (a survivor or a
# pending kill in the release context fails CI).
#
# THE PER-MUTATION BEHAVIORAL SUITE MAPPING (the kill instruments — the
# suites whose PASS/FAIL depends on the mutated semantics):
#   mut-invert-comparison        canary-pos + canary-neg  (the canaries'
#                               accepted/rejected sets)
#   mut-delete-diagnostic        canary-neg  (the negative canaries'
#                               expected-diagnostic suite)
#   mut-consume-to-read          resource-neg  (the resource negatives)
#   mut-modify-to-read           resource-neg  (the resource negatives)
#   mut-remove-drop-mark         resource-neg  (the resource negatives)
#   mut-duplicate-drop           verifier  (the verifier tests)
#   mut-skip-verifier            verifier  (the verifier tests)
#   mut-field-offset             layout  (the layout tests)
#   mut-enum-tag                 enum + layout  (the enum tests + the
#                               layout engine's enum-offset assertions)
#   mut-remove-overflow-check    numeric-gate  (the numeric gate)
#   mut-branch-target            cfg-oracle  (the CFG oracle)
#   mut-remove-wake              async-waiter  (the async waiter tests)
#   mut-remove-atomic-ordering   litmus  (the atomic litmus suites)
#   mut-equality-to-permissive   conv-neg  (the trait-conformance
#                               negatives)
#
# Usage: scripts/run_mutation_tests.sh [--binary <tg>] [--only <id,...>]
#                                      [--out <file>] [--gate]
#   --binary  a usable CURRENT-GRAMMAR compiler binary (the ladder's
#             stage3/stage2/stage1, or any binary that passes the
#             usability probe: it must `check` a trivial valid program
#             AND reject a legacy-spelling probe). The mutated kernel is
#             compiled with it and the behavioral tier runs for EVERY
#             mutation. When omitted, the harness auto-detects
#             build/tg_stage3 -> tg_stage2 -> tg_stage1 -> build/tg.
#   --only    run a subset of the catalog (comma-separated ids).
#   --out     write the report to a file (also printed on stdout).
#   --gate    the release-context gate: exit nonzero when any
#             non-equivalent mutation is not KILLED-BEHAVIORALLY
#             (SURVIVED or PENDING-UNTIL-BINARY) or when any mutation
#             errored. WITHOUT a usable compiler binary every kill is
#             PENDING-UNTIL-BINARY and the gate fails — the honest state.
# Exit status: 0 when every mutation ran, the report was produced, and
# (with --gate) every non-equivalent mutation is KILLED-BEHAVIORALLY;
# 1 when a mutation could not be applied / failed the source-integrity
# confirmation (the catalog drifted from the sources — a real failure to
# fix), or with --gate when a mutation SURVIVED or is PENDING-UNTIL-
# BINARY; 2 on a harness configuration error (an unusable --binary).
# ———————————————————————————————————————————————————————————————
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "run_mutation_tests: cannot cd to repo root" >&2; exit 2; }

# shellcheck disable=SC1091
. scripts/mutation_detectors.sh

BINARY=""
ONLY=""
OUT=""
GATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --binary)
      shift
      BINARY="${1:-}"
      shift
      ;;
    --only)
      shift
      ONLY="${1:-}"
      shift
      ;;
    --out)
      shift
      OUT="${1:-}"
      shift
      ;;
    --gate)
      GATE=1
      shift
      ;;
    *) break ;;
  esac
done

# probe_usable_compiler <binary> — 0 iff the binary is a USABLE
# CURRENT-GRAMMAR compiler: it must `check` a trivial valid program
# (a crashed/broken leftover artifact never qualifies) AND reject a
# legacy-spelling probe (a stale binary built before the E100 removal
# silently accepts the probe and is NOT usable for the build tier — the
# same probe discipline as scripts/run_selfhost_grammar_gate.sh).
probe_usable_compiler() {
  local bin="$1" d rc
  d="$(mktemp -d "${TMPDIR:-/tmp}/tg_mut_probe.XXXXXX")" || return 1
  cat > "$d/good.tg" <<'PROBEGOOD'
def mutation_good_probe() -> Int
  0
end
PROBEGOOD
  cat > "$d/legacy.tg" <<'PROBELEGACY'
def mutation_legacy_probe(x: &Int) -> Int
  x
end
PROBELEGACY
  ( "$bin" check "$d/good.tg" >/dev/null 2>&1 ) && ! ( "$bin" check "$d/legacy.tg" >/dev/null 2>&1 )
  rc=$?
  rm -rf "$d"
  return $rc
}

if [ -n "$BINARY" ]; then
  if [ ! -x "$BINARY" ]; then
    echo "run_mutation_tests: the --binary compiler is not executable: $BINARY" >&2
    exit 2
  fi
  if ! probe_usable_compiler "$BINARY"; then
    echo "run_mutation_tests: the --binary compiler is NOT a usable current-grammar compiler (it must check a trivial valid program AND reject a legacy-spelling probe): $BINARY — a stale or broken artifact cannot drive the behavioral tier" >&2
    exit 2
  fi
else
  for cand in build/tg_stage3 build/tg_stage2 build/tg_stage1 build/tg; do
    if [ -x "$cand" ] && probe_usable_compiler "$cand"; then
      BINARY="$cand"
      break
    fi
  done
fi

WORK_BASE="$(mktemp -d "${TMPDIR:-/tmp}/tg_mutation.XXXXXX")"
PRISTINE="$WORK_BASE/pristine"
WORK="$WORK_BASE/work"
LOGS="$WORK_BASE/logs"
mkdir -p "$LOGS"
trap 'rm -rf "$WORK_BASE"' EXIT

# ———————————————————————————————————————————————————————————————
# Step 1 — build the pristine source copy (never the real tree)
# ———————————————————————————————————————————————————————————————
echo "building the pristine source copy ..."
mkdir -p "$PRISTINE"
for d in tg_compiler std bootstrap docs scripts tests; do
  rsync -a "$ROOT/$d/" "$PRISTINE/$d/"
done
for f in features.toml invariants.toml; do
  cp -p "$ROOT/$f" "$PRISTINE/$f"
done
if [ -n "$BINARY" ]; then
  mkdir -p "$PRISTINE/build"
  cp -p "$BINARY" "$PRISTINE/build/tg_stage1"
fi

# The mutation catalog: id | file | class | description. Every entry is
# NON-EQUIVALENT (NE) — the observable semantic change is stated in the
# description. The transformations live in the python block below
# (exact-string edits with an apply-count assertion).
CATALOG=(
  "mut-invert-comparison|tg_compiler/types.tg|NE|checker: the field-index bounds check inverted (valid indices rejected)"
  "mut-delete-diagnostic|tg_compiler/mir.tg|NE|verifier: the extern-ABI classification diagnostic deleted"
  "mut-consume-to-read|tg_compiler/types.tg|NE|checker: AccessEffect::Consume classified as AccessEffect::Read"
  "mut-modify-to-read|tg_compiler/mir.tg|NE|checker: the inout access convention maps to AccessEffect::Read"
  "mut-remove-drop-mark|tg_compiler/types.tg|NE|checker: the partial-drop-chain record never marks the consumed place"
  "mut-duplicate-drop|tg_compiler/mir.tg|NE|verifier: the MirDeinit identity guard deleted (a duplicate/unregistered deinit instance passes)"
  "mut-skip-verifier|tg_compiler/mir.tg|NE|verifier: verify_mir returns an empty error list immediately"
  "mut-field-offset|tg_compiler/layout_engine.tg|NE|layout engine: the Map header key_stride offset 24 -> 32"
  "mut-enum-tag|tg_compiler/layout_engine.tg|NE|layout engine: the TaggedUnion tag_size 8 -> 4 (F3: tag at 0, payload at 8)"
  "mut-remove-overflow-check|tg_compiler/layout_engine.tg|NE|layout engine: the layout_checked_add overflow guard deleted"
  "mut-branch-target|tg_compiler/mir.tg|NE|verifier: the verify_function_v2 extern early-return flipped (non-extern functions return unverified)"
  "mut-remove-wake|std/async.tg|NE|async contract: the waker's wake_task dispatch removed"
  "mut-remove-atomic-ordering|tg_compiler/codegen.tg|NE|atomics: the x86 SeqCst store branch made unreachable (weak MOV always)"
  "mut-equality-to-permissive|tg_compiler/types.tg|NE|checker: the exact depth-1 projection check == 1 becomes >= 1"
)

# behavioral_suites_for <mutation-id> — the PER-MUTATION BEHAVIORAL SUITE
# MAPPING (the kill instruments: the mutation is KILLED iff any mapped
# suite FAILS under the mutated compiler).
behavioral_suites_for() {
  case "$1" in
    mut-invert-comparison)      echo "canary-pos canary-neg" ;;
    mut-delete-diagnostic)      echo "canary-neg" ;;
    mut-consume-to-read)        echo "resource-neg" ;;
    mut-modify-to-read)         echo "resource-neg" ;;
    mut-remove-drop-mark)       echo "resource-neg" ;;
    mut-duplicate-drop)         echo "verifier" ;;
    mut-skip-verifier)          echo "verifier" ;;
    mut-field-offset)           echo "layout" ;;
    mut-enum-tag)               echo "enum layout" ;;
    mut-remove-overflow-check)  echo "numeric-gate" ;;
    mut-branch-target)          echo "cfg-oracle" ;;
    mut-remove-wake)            echo "async-waiter" ;;
    mut-remove-atomic-ordering) echo "litmus" ;;
    mut-equality-to-permissive) echo "conv-neg" ;;
    *)                          echo "" ;;
  esac
}

apply_mutation() { # apply_mutation <id> <root> ; prints "applied" | "ERROR: ..."
  python3 - "$1" "$2" <<'PY'
import sys

mutation_id = sys.argv[1]
root = sys.argv[2]

def load(rel):
    with open(root + "/" + rel, encoding="utf-8") as fh:
        return fh.read()

def save(rel, text):
    with open(root + "/" + rel, "w", encoding="utf-8") as fh:
        fh.write(text)

def apply(rel, old, new, expected_count=1, restrict=None):
    text = load(rel)
    base = text
    if restrict:
        idx = text.find(restrict)
        if idx < 0:
            print("ERROR: restriction marker not found in " + rel)
            sys.exit(2)
        head, tail = text[:idx], text[idx:]
        if tail.count(old) != expected_count:
            print("ERROR: expected %d occurrence(s) of the anchor in the restricted region of %s, found %d" % (expected_count, rel, tail.count(old)))
            sys.exit(2)
        tail = tail.replace(old, new, expected_count)
        text = head + tail
    else:
        if text.count(old) != expected_count:
            print("ERROR: expected %d occurrence(s) of the anchor in %s, found %d" % (expected_count, rel, text.count(old)))
            sys.exit(2)
        text = text.replace(old, new, expected_count)
    save(rel, text)
    print("applied")

def delete(rel, block, expected_count=1):
    text = load(rel)
    if text.count(block) != expected_count:
        print("ERROR: expected %d occurrence(s) of the deletion block in %s, found %d" % (expected_count, rel, text.count(block)))
        sys.exit(2)
    save(rel, text.replace(block, "", expected_count))
    print("applied")

def insert_after(rel, anchor, insertion, expected_count=1):
    text = load(rel)
    if text.count(anchor) != expected_count:
        print("ERROR: expected %d occurrence(s) of the insertion anchor in %s, found %d" % (expected_count, rel, text.count(anchor)))
        sys.exit(2)
    save(rel, text.replace(anchor, anchor + insertion, expected_count))
    print("applied")

if mutation_id == "mut-invert-comparison":
    apply("tg_compiler/types.tg",
          "if fid.index >= 0 && fid.index < fields.len() then",
          "if fid.index >= 0 && fid.index > fields.len() then")
elif mutation_id == "mut-delete-diagnostic":
    delete("tg_compiler/mir.tg",
           '      errors.push(fn_ctx.clone() + ": extern function carries unknown ABI classification \\"" + func.extern_abi.clone() + "\\" (known: C, System, Ruby, Tangerine)")\n')
elif mutation_id == "mut-consume-to-read":
    apply("tg_compiler/types.tg",
          "if bp.action == AccessEffect::Consume then",
          "if bp.action == AccessEffect::Read then")
elif mutation_id == "mut-modify-to-read":
    apply("tg_compiler/mir.tg",
          "when AccessConvention::Inout then AccessEffect::Modify",
          "when AccessConvention::Inout then AccessEffect::Read")
elif mutation_id == "mut-remove-drop-mark":
    delete("tg_compiler/types.tg",
           "    ext.insert(path.clone(), PlaceMoveState::Consumed)\n")
elif mutation_id == "mut-duplicate-drop":
    delete("tg_compiler/mir.tg",
           "      if !deinit_instances.contains(&inst_key) && !drop_glue_fns.contains_key(&inst_key) then\n"
           "        errors.push(bb_ctx.clone() + \": deinit instance is not a registered finalizer identity and not a generated drop-glue function\")\n"
           "      end\n")
elif mutation_id == "mut-skip-verifier":
    insert_after("tg_compiler/mir.tg",
                 "def verify_mir(mir: MirProgram) -> Vec[String]\n  var errors = Vec::new()\n",
                 "  return Vec::new()\n")
elif mutation_id == "mut-field-offset":
    apply("tg_compiler/layout_engine.tg",
          'else if field_name == "key_stride" then Option::Some(24)',
          'else if field_name == "key_stride" then Option::Some(32)')
elif mutation_id == "mut-enum-tag":
    apply("tg_compiler/layout_engine.tg",
          "    tag_size: 8,        # F3: tag is 8 bytes",
          "    tag_size: 4,        # MUTATION: tag is 4 bytes")
elif mutation_id == "mut-remove-overflow-check":
    delete("tg_compiler/layout_engine.tg",
           "  if b > 9223372036854775807 - a then\n"
           "    panic(\"layout: integer overflow in \" + what + \" (a=\" + a.to_string() + \", b=\" + b.to_string() + \") — fail closed, never a wrapped size/offset\")\n"
           "  end\n")
elif mutation_id == "mut-branch-target":
    apply("tg_compiler/mir.tg",
          "  if func.is_extern then return end\n",
          "  if !func.is_extern then return end\n",
          restrict="def verify_function_v2")
elif mutation_id == "mut-remove-wake":
    delete("std/async.tg",
           "      exec.wake_task(self.task_id)\n")
elif mutation_id == "mut-remove-atomic-ordering":
    apply("tg_compiler/codegen.tg",
          "    emit8(&mut ctx.text, 0x05)   # cmp edx, 5 (SeqCst)",
          "    emit8(&mut ctx.text, 0x06)   # cmp edx, 6 (MUTATION: never matches — the SeqCst store ordering removed)")
elif mutation_id == "mut-equality-to-permissive":
    apply("tg_compiler/types.tg",
          "if keys.len() == 1 then",
          "if keys.len() >= 1 then")
else:
    print("ERROR: unknown mutation id: " + mutation_id)
    sys.exit(2)
PY
}

# ———————————————————————————————————————————————————————————————
# Step 2 — the source-integrity suite pieces
# ———————————————————————————————————————————————————————————————
# manifest_parity <dir> <manifest>: listed == discovered == declared,
# every listed file exists, every discovered file is listed (the
# G10.1-family check the harness runs as an explicit source-integrity
# piece — the mutated copy must keep the suite sets intact).
# diagnostic_parity <manifest> <src-dir>...: every expected diagnostic
# substring in the canary_neg MANIFEST is present in the compiler
# sources (the G10.6 check — the expected-diagnostic parity; a mutation
# that deletes a diagnostic site the negative canaries pin breaks the
# parity — recorded as a source-integrity observation, NEVER a kill).
manifest_parity() {
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

diagnostic_parity() {
  python3 - "$1" "$2" "$3" <<'PY'
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

# the balance gate: end-token/delimiter balance over the kernel closure
# + the mutation target files (std/async.tg is a target but not in the
# kernel manifest).
balance_gate() {
  local closure=""
  local kind rel f
  while IFS=' ' read -r kind rel; do
    case "$kind" in
      std:) f="std/$rel" ;;
      compiler:) f="tg_compiler/$rel" ;;
      *) continue ;;
    esac
    [ -f "$f" ] || return 1
    closure="$closure $f"
  done < bootstrap/compiler_kernel.manifest
  python3 scripts/check_struct_balance.py $closure std/async.tg >/dev/null 2>&1
}

# ———————————————————————————————————————————————————————————————
# Step 3 — the per-mutation BEHAVIORAL SUITE runners
# (each runs with cwd = the MUTATED COPY; 0 = suite passed, 1 = the
# suite FAILED under the mutated compiler — the kill instrument)
# ———————————————————————————————————————————————————————————————
# run_pos_canaries <compiler> — the positive canaries' accepted set:
# every tests/canary/MANIFEST entry must compile AND execute cleanly.
run_pos_canaries() {
  local compiler="$1" failures=0 total=0 line name
  mkdir -p build/.mut_canaries
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    name="${line%.tg}"
    total=$((total + 1))
    if ! "$compiler" compile --mode dev -O2 -o "build/.mut_canaries/$name" "tests/canary/$line" >/dev/null 2>&1 \
       || ! "build/.mut_canaries/$name" >/dev/null 2>&1; then
      echo "FAIL: positive canary $name failed to compile or execute under the mutated compiler"
      failures=$((failures + 1))
    else
      echo "OK: positive canary $name compiled and executed"
    fi
  done < tests/canary/MANIFEST
  [ "$total" -eq 0 ] && { echo "FAIL: zero positive canaries discovered (a zero suite is fatal)"; return 1; }
  [ "$failures" -eq 0 ]
}

# run_neg_canaries <compiler> <name-regex> — the negative canaries'
# accepted/rejected sets: every matching tests/canary_neg/MANIFEST entry
# must be REJECTED by `check` and carry the manifest's expected
# diagnostic substring (an entry without one needs rejection only).
run_neg_canaries() {
  local compiler="$1" regex="$2" failures=0 total=0 line file expected name out rc
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|\#*) continue ;; esac
    file="${line%%$'\t'*}"
    expected="${line#*$'\t'}"
    [ "$expected" = "$line" ] && expected=""
    name="${file%.tg}"
    [[ "$name" =~ $regex ]] || continue
    total=$((total + 1))
    out="$( "$compiler" check "tests/canary_neg/$file" 2>&1 )"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      echo "FAIL: negative $name was ACCEPTED by the mutated compiler (the accepted set widened)"
      failures=$((failures + 1))
    elif [ -n "$expected" ] && ! printf '%s' "$out" | grep -qF "$expected"; then
      echo "FAIL: negative $name rejected but WITHOUT the expected diagnostic '$expected'"
      failures=$((failures + 1))
    else
      echo "OK: negative $name rejected with the expected diagnostic"
    fi
  done < tests/canary_neg/MANIFEST
  [ "$total" -eq 0 ] && { echo "FAIL: zero negatives matched the family (a zero suite is fatal)"; return 1; }
  [ "$failures" -eq 0 ]
}

# run_behavioral_suite <suite-id> <compiler> — dispatch the per-mutation
# behavioral suite mapping. 0 = suite passed; 1 = suite FAILED.
run_behavioral_suite() {
  case "$1" in
    canary-pos)     run_pos_canaries "$2" ;;
    canary-neg)     run_neg_canaries "$2" '.*' ;;
    resource-neg)   run_neg_canaries "$2" '^(canary_neg_access_|canary_neg_resource_|resource_|canary_neg_option_resource)' ;;
    conv-neg)       run_neg_canaries "$2" '^canary_neg_conv_' ;;
    verifier)       "$2" test tests/verifier_projection_tests.tg golden/compiler_module_tests.tg ;;
    layout)         "$2" test tests/layout_tests.tg tests/layout/differential_layout_test.tg ;;
    enum)           "$2" test tests/struct_enum_test.tg ;;
    numeric-gate)   "$2" test tests/numeric_literal_gate_e_test.tg ;;
    cfg-oracle)     bash tests/resource_cfg/run_cfg_oracle.sh "$2" ;;
    async-waiter)   "$2" test tests/async_mutex_waiter_test.tg tests/async_channel_waiter_test.tg \
                          tests/async_semaphore_waiter_test.tg tests/task_scope_test.tg \
                          tests/cancellation_token_test.tg tests/reactor_readiness_test.tg \
                          tests/channel_stream_wake_test.tg tests/join_cancel_test.tg ;;
    litmus)         "$2" test tests/atomic_litmus_sb_test.tg tests/atomic_litmus_mp_test.tg \
                          tests/atomic_litmus_wrc_test.tg tests/atomic_litmus_acqrel_test.tg \
                          tests/atomic_litmus_cas_pub_test.tg tests/atomic_litmus_cas_fail_test.tg \
                          tests/atomic_litmus_ring4_test.tg tests/atomic_litmus_seqcst_chain4_test.tg ;;
    *) echo "run_behavioral_suite: unknown suite: $1" >&2; return 2 ;;
  esac
}

# ———————————————————————————————————————————————————————————————
# Step 4 — one mutation at a time, against a fresh copy
# (mutate -> source-integrity confirmation -> build -> behavioral suite)
# ———————————————————————————————————————————————————————————————
declare -a KILLED_IDS=()
declare -a KILLED_BY=()
declare -a SURVIVED_IDS=()
declare -a SURVIVED_REASON=()
declare -a PENDING_IDS=()
declare -a PENDING_REASON=()
declare -a ERROR_IDS=()
declare -a ERROR_REASON=()
TOTAL=0
KILLED=0
SURVIVED=0
PENDING=0
ERRORS=0
SOURCE_INTEGRITY_OK=0

if [ -n "$BINARY" ]; then
  echo "binary tier: $BINARY (usable current-grammar compiler — the mutated kernel is built with it and the behavioral tier runs for every mutation)"
else
  echo "binary tier: NONE — no usable current-grammar compiler binary in build/ and no --binary given; every kill classification is PENDING-UNTIL-BINARY (the behavioral tier cannot run)"
fi

for entry in "${CATALOG[@]}"; do
  id="${entry%%|*}"
  rest="${entry#*|}"
  file="${rest%%|*}"
  rest="${rest#*|}"
  klass="${rest%%|*}"
  desc="${rest#*|}"
  if [ -n "$ONLY" ]; then
    case ",$ONLY," in
      *,"$id",*) ;;
      *) continue ;;
    esac
  fi
  TOTAL=$((TOTAL + 1))

  rm -rf "$WORK"
  rsync -a "$PRISTINE/" "$WORK/"

  # ————— (1) MUTATE —————
  APPLY_OUT="$(apply_mutation "$id" "$WORK" 2>&1)" || {
    echo "== $id — MUTATION APPLICATION ERROR: $APPLY_OUT (the catalog drifted from the sources)"
    ERROR_IDS+=("$id")
    ERROR_REASON+=("mutation application error: $APPLY_OUT")
    ERRORS=$((ERRORS + 1))
    continue
  }

  # the per-mutation DIFF-assertion (the application assertion): the
  # mutated file MUST differ from the pristine original — the mutation
  # is really present in the copy (the anchor-count in apply_mutation
  # proved the site; this pins the file-level difference).
  if diff -q "$PRISTINE/$file" "$WORK/$file" >/dev/null 2>&1; then
    echo "== $id — MUTATION APPLICATION ERROR: the mutated file does not differ from the pristine original (the transformation was a no-op)"
    ERROR_IDS+=("$id")
    ERROR_REASON+=("the mutated file does not differ from the pristine original")
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # ————— (2) THE SOURCE-INTEGRITY CONFIRMATION (never a kill) —————
  # The per-mutation detector (scripts/mutation_detectors.sh) MUST FIRE:
  # the canonical semantic form at the intended site is destroyed — the
  # mutation is really applied where the catalog says. A detector that
  # does NOT fire means the mutation is not observable at its site — an
  # application/drift error, NEVER a kill.
  DETECTOR_NAME="$(detector_name "$id")"
  if detect_mutation "$id" "$WORK" >/dev/null 2>&1; then
    echo "== $id — SOURCE-INTEGRITY ERROR: the mutation is NOT observable at its target site ($DETECTOR_NAME did not fire — the transformation was a no-op or the site drifted)"
    ERROR_IDS+=("$id")
    ERROR_REASON+=("the per-mutation detector did not fire: $DETECTOR_NAME")
    ERRORS=$((ERRORS + 1))
    continue
  fi
  DETECTOR_REASON="$(detect_mutation "$id" "$WORK" 2>&1)"

  # the tree-wide source-integrity mode of verify_invariants.sh: the
  # mutation's own G13 assertion must FIRE and every other invariant
  # (incl. the remaining G13s, the grammar gate, the balance gate, the
  # manifest/diagnostic parity) must hold.
  INV_LOG="$LOGS/$id.invariants"
  GATE_LOG="$LOGS/$id.grammar"
  BAL_LOG="$LOGS/$id.balance"
  if ! (cd "$WORK" && bash scripts/verify_invariants.sh --mutation-source-integrity "$id" >"$INV_LOG" 2>&1); then
    echo "== $id — SOURCE-INTEGRITY ERROR: verify_invariants.sh --mutation-source-integrity $id FAILED (see the log: $(tail -n 1 "$INV_LOG"))"
    ERROR_IDS+=("$id")
    ERROR_REASON+=("verify_invariants.sh --mutation-source-integrity $id failed: $(tail -n 1 "$INV_LOG")")
    ERRORS=$((ERRORS + 1))
    continue
  fi
  if ! (cd "$WORK" && bash scripts/run_selfhost_grammar_gate.sh >"$GATE_LOG" 2>&1); then
    echo "== $id — SOURCE-INTEGRITY ERROR: the self-host grammar gate FAILED on the mutated copy"
    ERROR_IDS+=("$id")
    ERROR_REASON+=("the self-host grammar gate failed on the mutated copy")
    ERRORS=$((ERRORS + 1))
    continue
  fi
  if ! (cd "$WORK" && balance_gate >"$BAL_LOG" 2>&1) \
     || ! (cd "$WORK" && manifest_parity tests/canary tests/canary/MANIFEST \
            && manifest_parity tests/canary_neg tests/canary_neg/MANIFEST \
            && manifest_parity tests/arm64 tests/arm64/MANIFEST \
            && diagnostic_parity tests/canary_neg/MANIFEST tg_compiler std) >"$BAL_LOG" 2>&1; then
    echo "== $id — SOURCE-INTEGRITY ERROR: the balance gate or the manifest/diagnostic parity FAILED on the mutated copy"
    ERROR_IDS+=("$id")
    ERROR_REASON+=("the balance gate or the manifest/diagnostic parity failed on the mutated copy")
    ERRORS=$((ERRORS + 1))
    continue
  fi
  SOURCE_INTEGRITY_OK=$((SOURCE_INTEGRITY_OK + 1))
  echo "== $id — source-integrity OK: $DETECTOR_NAME fired (the mutation is applied at the intended site); the tree-wide invariants hold"

  # ————— (3)+(4) BUILD + the per-mutation BEHAVIORAL SUITE —————
  # Without a usable compiler binary the behavioral tier cannot run: the
  # kill classification is PENDING-UNTIL-BINARY (NOT killed).
  if [ -z "$BINARY" ]; then
    PENDING=$((PENDING + 1))
    PENDING_IDS+=("$id")
    PENDING_REASON+=("no usable current-grammar compiler binary — the behavioral tier cannot run (PENDING-UNTIL-BINARY, not killed)")
    echo "== $id — PENDING-UNTIL-BINARY (no usable compiler binary; the behavioral tier cannot run — not killed, not survived)"
    echo "   $file — $desc"
    continue
  fi

  # BUILD the mutated kernel with the current-grammar binary: a kernel
  # that does not compile is caught at the compiler's own build gate —
  # KILLED-BEHAVIORALLY (the build is part of the protocol).
  TARGET="${TARGET_TRIPLE:-${TG_BOOTSTRAP_TARGET:-aarch64-apple-darwin}}"
  MUT_BIN="$WORK/build/.mut_stage1"
  BUILD_LOG="$LOGS/$id.build"
  if ! (cd "$WORK" && ./build/tg_stage1 compile --strict-resolution tg_compiler/bootstrap_main.tg \
           -o "$MUT_BIN" --target "$TARGET" >"$BUILD_LOG" 2>&1); then
    KILLED=$((KILLED + 1))
    KILLED_IDS+=("$id")
    KILLED_BY+=("the BUILD step: the mutated kernel does not compile under the current-grammar binary (the mutation is caught at the compiler's own gate)")
    echo "== $id — KILLED-BEHAVIORALLY (the BUILD step: the mutated kernel failed to compile under the current-grammar binary)"
    echo "   $file — $desc"
    continue
  fi

  # RUN the per-mutation behavioral suite (the mapping table above) under
  # the mutated compiler. The mutation is KILLED iff a mapped suite FAILS.
  SUITES="$(behavioral_suites_for "$id")"
  if [ -z "$SUITES" ]; then
    echo "== $id — HARNESS ERROR: no behavioral suite mapped for $id"
    ERROR_IDS+=("$id")
    ERROR_REASON+=("no behavioral suite mapped for $id")
    ERRORS=$((ERRORS + 1))
    continue
  fi
  SUITE_LOG="$LOGS/$id.suite"
  FAILED_SUITES=""
  for suite in $SUITES; do
    if ! (cd "$WORK" && run_behavioral_suite "$suite" "$MUT_BIN" >>"$SUITE_LOG" 2>&1); then
      FAILED_SUITES="${FAILED_SUITES:+$FAILED_SUITES, }$suite"
    fi
  done

  if [ -n "$FAILED_SUITES" ]; then
    KILLED=$((KILLED + 1))
    KILLED_IDS+=("$id")
    KILLED_BY+=("the behavioral suite failed under the mutated compiler: $FAILED_SUITES")
    echo "== $id — KILLED-BEHAVIORALLY (the behavioral suite failed under the mutated compiler: $FAILED_SUITES)"
    echo "   $file — $desc"
    if [ -s "$SUITE_LOG" ]; then
      echo "   behavioral suite log (tail):"
      tail -n 25 "$SUITE_LOG" | sed 's/^/     /'
    fi
  else
    SURVIVED=$((SURVIVED + 1))
    SURVIVED_IDS+=("$id")
    SURVIVED_REASON+=("the mapped behavioral suite(s) passed under the mutated compiler: $SUITES")
    echo "== $id — SURVIVED (the mapped behavioral suite passed under the mutated compiler: $SUITES) — a non-equivalent survivor is a FINDING"
    echo "   $file — $desc"
    if [ -s "$SUITE_LOG" ]; then
      echo "   behavioral suite log (tail):"
      tail -n 6 "$SUITE_LOG" | sed 's/^/     /'
    fi
  fi
done

# ———————————————————————————————————————————————————————————————
# Step 5 — the report (the honest per-mutation kill table)
# ———————————————————————————————————————————————————————————————
{
  echo ""
  echo "======================================================"
  echo "MUTATION TEST REPORT (the semantic protocol: mutate -> build -> behavioral suite)"
  echo "======================================================"
  if [ -n "$BINARY" ]; then
    echo "binary tier:      $BINARY (a usable current-grammar compiler — the mutated kernel is built with it)"
  else
    echo "binary tier:      NONE — no usable current-grammar compiler binary; every kill is PENDING-UNTIL-BINARY"
  fi
  echo "tier:             behavioral — the per-mutation mapped suite runs under the MUTATED compiler;"
  echo "                  the structural detectors (mutation_detectors.sh + the G13 group of"
  echo "                  verify_invariants.sh) are SOURCE-INTEGRITY checks only and never"
  echo "                  classify a kill"
  echo "mutations run:    $TOTAL"
  echo "killed behaviorally: $KILLED"
  echo "survived:         $SURVIVED"
  echo "pending:          $PENDING"
  echo "apply errors:     $ERRORS"
  if [ "$TOTAL" -gt 0 ]; then
    KILL_RATE="$(python3 -c "print('%.1f%%' % (100.0 * $KILLED / $TOTAL))")"
    echo "kill-rate:        $KILL_RATE  ($KILLED/$TOTAL) — KILLED iff the behavioral suite FAILED under the mutated compiler"
  else
    echo "kill-rate:        n/a"
  fi
  echo ""
  echo "the per-mutation behavioral suite mapping (the kill instruments):"
  echo "  mut-invert-comparison        canary-pos + canary-neg (the canaries' accepted/rejected sets)"
  echo "  mut-delete-diagnostic        canary-neg (the negative canaries' expected-diagnostic suite)"
  echo "  mut-consume-to-read          resource-neg (the resource negatives)"
  echo "  mut-modify-to-read           resource-neg (the resource negatives)"
  echo "  mut-remove-drop-mark         resource-neg (the resource negatives)"
  echo "  mut-duplicate-drop           verifier (the verifier tests)"
  echo "  mut-skip-verifier            verifier (the verifier tests)"
  echo "  mut-field-offset             layout (the layout tests)"
  echo "  mut-enum-tag                 enum + layout (the enum tests + the layout engine's enum-offset assertions)"
  echo "  mut-remove-overflow-check    numeric-gate (the numeric gate)"
  echo "  mut-branch-target            cfg-oracle (the CFG oracle)"
  echo "  mut-remove-wake              async-waiter (the async waiter tests)"
  echo "  mut-remove-atomic-ordering   litmus (the atomic litmus suites)"
  echo "  mut-equality-to-permissive   conv-neg (the trait-conformance negatives)"
  echo ""
  echo "the per-mutation result table (id | class | behavioral suite(s) | result):"
  for entry in "${CATALOG[@]}"; do
    id="${entry%%|*}"
    rest="${entry#*|}"
    file="${rest%%|*}"
    rest="${rest#*|}"
    klass="${rest%%|*}"
    if [ -n "$ONLY" ]; then
      case ",$ONLY," in
        *,"$id",*) ;;
        *) continue ;;
      esac
    fi
    result="not-run"
    for i in "${!KILLED_IDS[@]}"; do
      if [ "${KILLED_IDS[$i]}" = "$id" ]; then
        result="KILLED-BEHAVIORALLY"
        break
      fi
    done
    if [ "$result" = "not-run" ]; then
      for i in "${!SURVIVED_IDS[@]}"; do
        if [ "${SURVIVED_IDS[$i]}" = "$id" ]; then
          result="SURVIVED"
          break
        fi
      done
    fi
    if [ "$result" = "not-run" ]; then
      for i in "${!PENDING_IDS[@]}"; do
        if [ "${PENDING_IDS[$i]}" = "$id" ]; then
          result="PENDING-UNTIL-BINARY"
          break
        fi
      done
    fi
    if [ "$result" = "not-run" ]; then
      for i in "${!ERROR_IDS[@]}"; do
        if [ "${ERROR_IDS[$i]}" = "$id" ]; then
          result="ERROR"
          break
        fi
      done
    fi
    printf '  %-28s %-3s %-46s %s\n' "$id" "$klass" "$(behavioral_suites_for "$id")" "$result"
  done
  echo ""
  echo "non-equivalent classification: every catalog entry is NE (it"
  echo "changes an observable semantic — accepted/rejected sets, emitted"
  echo "layout/code, or a wake/ordering arm). An NE survivor is a finding;"
  echo "an unproven kill (PENDING-UNTIL-BINARY) is not a kill."
  echo "  NE mutations:    $TOTAL"
  echo "  NE killed:       $KILLED (behaviorally)"
  echo "  NE survivors:    $SURVIVED"
  echo "  NE pending:      $PENDING"
  if [ "$SURVIVED" -eq 0 ] && [ "$PENDING" -eq 0 ]; then
    echo "  NE kill-rate:    100.0% ($KILLED/$TOTAL) — every non-equivalent mutation is KILLED-BEHAVIORALLY (the behavioral suite failed under the mutated compiler)"
  else
    echo "  NE kill-rate:    $([ "$TOTAL" -gt 0 ] && python3 -c "print('%.1f%%' % (100.0 * $KILLED / $TOTAL))") — FINDING:"
    if [ "$SURVIVED" -gt 0 ]; then
      echo "    the surviving non-equivalent mutation(s) must gain a behavioral detector (the mapped suite passed under the mutated compiler)"
    fi
    if [ "$PENDING" -gt 0 ]; then
      echo "    the pending kills are UNPROVEN: without a usable current-grammar compiler binary the behavioral tier cannot run (PENDING-UNTIL-BINARY is not a kill)"
    fi
  fi
  echo ""
  echo "source-integrity tier: $SOURCE_INTEGRITY_OK mutation(s) confirmed applied at the intended site"
  echo "  (the per-mutation detector FIRED and verify_invariants.sh --mutation-source-integrity"
  echo "  passed — the structural detectors NEVER classify a kill)"
  echo ""
  echo "killed behaviorally (with the killing instrument):"
  if [ "$KILLED" -gt 0 ]; then
    idx=0
    for id in "${KILLED_IDS[@]}"; do
      echo "  $id — ${KILLED_BY[$idx]}"
      idx=$((idx + 1))
    done
  fi
  echo "survived (the mutations the behavioral suite does NOT catch — findings):"
  if [ "$SURVIVED" -gt 0 ]; then
    idx=0
    for id in "${SURVIVED_IDS[@]}"; do
      echo "  $id — ${SURVIVED_REASON[$idx]}"
      idx=$((idx + 1))
    done
  fi
  echo "pending-until-binary (the kills the behavioral tier could not prove):"
  if [ "$PENDING" -gt 0 ]; then
    idx=0
    for id in "${PENDING_IDS[@]}"; do
      echo "  $id — ${PENDING_REASON[$idx]}"
      idx=$((idx + 1))
    done
  fi
  echo "apply/source-integrity errors (the catalog drifted — a real failure):"
  if [ "$ERRORS" -gt 0 ]; then
    idx=0
    for id in "${ERROR_IDS[@]}"; do
      echo "  $id — ${ERROR_REASON[$idx]}"
      idx=$((idx + 1))
    done
  fi
  if [ "$GATE" -eq 1 ]; then
    if [ "$SURVIVED" -eq 0 ] && [ "$PENDING" -eq 0 ] && [ "$ERRORS" -eq 0 ]; then
      echo ""
      echo "GATE (--gate): PASS — every non-equivalent mutation is KILLED-BEHAVIORALLY"
    else
      echo ""
      echo "GATE (--gate): FAIL — every non-equivalent mutation must be killed behaviorally;"
      echo "  a SURVIVED ($SURVIVED) or PENDING-UNTIL-BINARY ($PENDING) non-equivalent mutation"
      echo "  (or an apply error: $ERRORS) fails the release gate"
    fi
  fi
  echo "======================================================"
} > "${OUT:-/dev/stdout}"

# ———————————————————————————————————————————————————————————————
# Step 6 — the exit status
# ———————————————————————————————————————————————————————————————
if [ "$ERRORS" -gt 0 ]; then
  echo "run_mutation_tests: $ERRORS mutation(s) could not be applied or failed the source-integrity confirmation (the catalog drifted from the sources — a real failure to fix)" >&2
  exit 1
fi
if [ "$GATE" -eq 1 ] && { [ "$SURVIVED" -gt 0 ] || [ "$PENDING" -gt 0 ]; }; then
  if [ "$PENDING" -gt 0 ] && [ "$SURVIVED" -eq 0 ]; then
    echo "run_mutation_tests: GATE FAILED — every kill is PENDING-UNTIL-BINARY (no usable current-grammar compiler binary; the behavioral tier cannot run — an unproven non-equivalent kill fails the release gate)" >&2
  else
    echo "run_mutation_tests: GATE FAILED — $SURVIVED non-equivalent mutation(s) survived the behavioral suite and/or $PENDING kill(s) are pending-until-binary; every non-equivalent mutation must be killed behaviorally (a surviving non-equivalent mutation fails CI)" >&2
  fi
  exit 1
fi
exit 0
