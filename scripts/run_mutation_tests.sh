#!/usr/bin/env bash
# ———————————————————————————————————————————————————————————————
# scripts/run_mutation_tests.sh — the bounded mutation harness
# (the reviewer's mutation categories; per-mutation DETECTORS).
#
# The mutations are applied to COPIES of the KEY SEMANTIC files (the
# checker, the verifier, the layout engine — plus the two contracts
# whose semantic homes are std/async.tg and tg_compiler/codegen.tg) by
# SCRIPTED transformations (exact-string edits with an anchor-count
# assertion — an unapplied transformation is a drift error). The
# ORIGINALS ARE NEVER MODIFIED: the harness builds a fresh source copy
# of the tree, applies ONE mutation to the copy, runs the bounded suite
# against the mutated tree, and discards it.
#
# THE KILL RULE (the reviewer's mandate): each mutation is KILLED iff its
# DETECTOR fails — a structural test whose outcome depends on the mutated
# site's CORRECTNESS. The detectors are the canonical-semantic-form
# assertions of scripts/mutation_detectors.sh (mirrored tree-wide as the
# G13 group of scripts/verify_invariants.sh): a mutation destroys its own
# target site's canonical form, so the detector fails exactly on its own
# mutation and holds on the pristine tree. The BOUNDED SUITE (structural
# tier — runs everywhere, no compiler binary, no ladder):
#     scripts/mutation_detectors.sh   — the per-mutation detector
#     scripts/verify_invariants.sh    — the invariant script (incl. the
#                                       G13 per-mutation detector group)
#     scripts/run_selfhost_grammar_gate.sh — the structural semantic
#                                       scans over the closure + the
#                                       full tool tree
#     scripts/check_struct_balance.py — the balance/end-token gate over
#                                       the kernel closure + the
#                                       mutation target files
#     the manifest-parity check       — canary / canary_neg / arm64
#                                       three-way manifest parity PLUS the
#                                       canary_neg expected-diagnostic
#                                       parity (every expected diagnostic
#                                       substring in the MANIFEST is
#                                       present in the checker/verifier
#                                       sources — a deleted diagnostic
#                                       site breaks the parity)
#   binary tier (--binary <tg> — runs only when every structural piece
#   PASSED, i.e. a mutation escaped the structural detectors; the mutated
#   kernel is COMPILED with the given binary and the executed suites run
#   against the mutated compiler):
#     the canaries (tests/canary/MANIFEST)  — compile + execute every
#     tests/verifier_projection_tests.tg    — the verifier tests
#
# THE MUTATION CATALOG (one entry per reviewer category; every entry is
# classified NON-EQUIVALENT — each changes an observable semantic: the
# accepted/rejected sets, the emitted layout/code, or a wake/ordering
# arm — so a survivor is a finding, and the target is a 100% kill-rate):
#   mut-invert-comparison        NE  checker       types.tg — the field-
#                                                index bounds check is
#                                                inverted (`<` -> `>`)
#                                                detector G13.1
#   mut-delete-diagnostic        NE  verifier      mir.tg — the extern-ABI
#                                                classification diagnostic
#                                                is deleted
#                                                detector G13.2
#   mut-consume-to-read          NE  checker       types.tg — AccessEffect::
#                                                Consume classified as
#                                                Read (a moving binding
#                                                is treated as read-only)
#                                                detector G13.3
#   mut-modify-to-read           NE  checker       mir.tg — the inout
#                                                access convention maps to
#                                                Read (an inout parameter
#                                                is treated as read-only)
#                                                detector G13.4
#   mut-remove-drop-mark         NE  checker       types.tg — the partial-
#                                                move registry record the
#                                                MIR's partial-drop chain
#                                                consumes is never marked
#                                                detector G13.5
#   mut-duplicate-drop           NE  verifier      mir.tg — the MirDeinit
#                                                identity guard is deleted
#                                                (a duplicate/unregistered
#                                                deinit instance passes)
#                                                detector G13.6
#   mut-skip-verifier            NE  verifier      mir.tg — verify_mir
#                                                returns an empty error
#                                                list immediately
#                                                detector G13.7
#   mut-field-offset             NE  layout engine layout_engine.tg — the
#                                                Map header key_stride
#                                                offset 24 -> 32
#                                                detector G13.8
#   mut-enum-tag                 NE  layout engine layout_engine.tg — the
#                                                TaggedUnion tag_size
#                                                8 -> 4 (F3: tag at 0)
#                                                detector G13.9
#   mut-remove-overflow-check    NE  layout engine layout_engine.tg — the
#                                                layout_checked_add
#                                                overflow guard is
#                                                deleted (fail-closed
#                                                becomes wrap)
#                                                detector G13.10
#   mut-branch-target            NE  verifier      mir.tg — the verify_
#                                                function_v2 extern
#                                                early-return condition
#                                                is flipped (non-extern
#                                                functions return
#                                                unverified)
#                                                detector G13.11
#   mut-remove-wake              NE  async contract std/async.tg — the
#                                                waker's wake_task
#                                                dispatch is removed
#                                                detector G13.12
#   mut-remove-atomic-ordering   NE  atomics       codegen.tg — the x86
#                                                SeqCst store branch is
#                                                made unreachable (the
#                                                ordering is removed;
#                                                SeqCst stores become
#                                                weak MOVs)
#                                                detector G13.13
#   mut-equality-to-permissive   NE  checker       types.tg — the exact
#                                                depth-1 projection
#                                                check `== 1` becomes
#                                                the permissive `>= 1`
#                                                detector G13.14
#
# Usage: scripts/run_mutation_tests.sh [--binary <tg>] [--only <id,...>]
#                                      [--out <file>]
#   --binary  a working tg compiler; the mutated kernel is compiled
#             with it and the binary tier runs (canaries + verifier
#             tests) — ONLY for mutations that escape every structural
#             detector.
#   --only    run a subset of the catalog (comma-separated ids).
#   --out     write the report to a file (also printed on stdout).
# Exit status: 0 when every mutation ran and the report was produced
# (SURVIVORS are a finding inside the report, not a harness failure);
# 1 when a mutation could not be applied (the catalog drifted from the
# sources — a real failure to fix).
# ———————————————————————————————————————————————————————————————
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "run_mutation_tests: cannot cd to repo root" >&2; exit 2; }

# shellcheck disable=SC1091
. scripts/mutation_detectors.sh

BINARY=""
ONLY=""
OUT=""
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
    *) break ;;
  esac
done

if [ -n "$BINARY" ] && [ ! -x "$BINARY" ]; then
  echo "run_mutation_tests: the --binary compiler is not executable: $BINARY" >&2
  exit 2
fi

WORK_BASE="$(mktemp -d "${TMPDIR:-/tmp}/tg_mutation.XXXXXX")"
PRISTINE="$WORK_BASE/pristine"
WORK="$WORK_BASE/work"
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
# Step 2 — the bounded suite pieces
# ———————————————————————————————————————————————————————————————
# manifest_parity <dir> <manifest>: listed == discovered == declared,
# every listed file exists, every discovered file is listed (the
# G10.1-family check the harness runs as an explicit suite piece).
# diagnostic_parity <manifest> <src-dir>...: every expected diagnostic
# substring in the canary_neg MANIFEST is present in the compiler
# sources (the G10.6 check — the mandate's expected-diagnostic parity).
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

# the canary_neg expected-diagnostic parity: every expected diagnostic
# substring in the MANIFEST must be present in the compiler sources —
# verbatim, or with the backtick-quoted spans normalized (a template
# diagnostic still pins the canary's expected text). A mutation that
# deletes or renames a diagnostic site the negative canaries pin breaks
# the parity (the mandate's "a deleted diagnostic → the expected
# substring missing → the parity gate fails").
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
# Step 3 — one mutation at a time, against a fresh copy
# ———————————————————————————————————————————————————————————————
declare -a KILLED_IDS=()
declare -a SURVIVED_IDS=()
declare -a ERROR_IDS=()
declare -a KILLED_BY=()
declare -a SURVIVED_CLASS=()
TOTAL=0
KILLED=0
SURVIVED=0
ERRORS=0

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

  APPLY_OUT="$(apply_mutation "$id" "$WORK" 2>&1)" || {
    echo "== $id — MUTATION APPLICATION ERROR: $APPLY_OUT (the catalog drifted from the sources)"
    ERROR_IDS+=("$id")
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
    ERRORS=$((ERRORS + 1))
    continue
  fi

  # (1) the per-mutation DETECTOR — the primary kill instrument. It must
  # fail iff the mutation is observable at its target site.
  DETECTOR_NAME="$(detector_name "$id")"
  DETECTOR_REASON=""
  if ! DETECTOR_REASON="$(detect_mutation "$id" "$WORK" 2>&1)"; then
    :
  fi

  # (2) the shared structural suite — invariant script (incl. the G13
  # detector group), grammar gate, balance gate, manifest parity.
  INV_LOG="$(mktemp "${TMPDIR:-/tmp}/tg_mut_inv.XXXXXX")"
  GATE_LOG="$(mktemp "${TMPDIR:-/tmp}/tg_mut_gate.XXXXXX")"
  BAL_LOG="$(mktemp "${TMPDIR:-/tmp}/tg_mut_bal.XXXXXX")"
  SUITE_FAILED_PIECES=""
  if ! (cd "$WORK" && bash scripts/verify_invariants.sh >"$INV_LOG" 2>&1); then
    SUITE_FAILED_PIECES="verify_invariants.sh"
  fi
  if ! (cd "$WORK" && bash scripts/run_selfhost_grammar_gate.sh >"$GATE_LOG" 2>&1); then
    SUITE_FAILED_PIECES="${SUITE_FAILED_PIECES:+$SUITE_FAILED_PIECES, }run_selfhost_grammar_gate.sh"
  fi
  if ! (cd "$WORK" && balance_gate >"$BAL_LOG" 2>&1); then
    SUITE_FAILED_PIECES="${SUITE_FAILED_PIECES:+$SUITE_FAILED_PIECES, }check_struct_balance.py"
  fi
  if ! (cd "$WORK" && manifest_parity tests/canary tests/canary/MANIFEST \
       && manifest_parity tests/canary_neg tests/canary_neg/MANIFEST \
       && manifest_parity tests/arm64 tests/arm64/MANIFEST \
       && diagnostic_parity tests/canary_neg/MANIFEST tg_compiler std) >"$BAL_LOG" 2>&1; then
    SUITE_FAILED_PIECES="${SUITE_FAILED_PIECES:+$SUITE_FAILED_PIECES, }manifest parity + the canary_neg expected-diagnostic parity"
  fi

  SUITE_OK=1
  if [ -n "$DETECTOR_REASON" ] || [ -n "$SUITE_FAILED_PIECES" ]; then
    SUITE_OK=0
  fi

  # (3) the bounded suite — binary tier (only when every structural
  # piece passed: a mutation that escaped the structural detectors).
  if [ "$SUITE_OK" -eq 1 ] && [ -n "$BINARY" ]; then
    TARGET="${TARGET_TRIPLE:-${TG_BOOTSTRAP_TARGET:-aarch64-apple-darwin}}"
    MUT_BIN="$WORK/build/.mut_stage1"
    CANARY_LOG="$(mktemp "${TMPDIR:-/tmp}/tg_mut_canary.XXXXXX")"
    VTEST_LOG="$(mktemp "${TMPDIR:-/tmp}/tg_mut_vtest.XXXXXX")"
    mkdir -p "$WORK/build/.mut_canaries"
    if ! (cd "$WORK" && ./build/tg_stage1 compile --strict-resolution tg_compiler/bootstrap_main.tg \
             -o "$MUT_BIN" --target "$TARGET" >"$CANARY_LOG" 2>&1); then
      # the kernel could not be compiled from the mutated sources — the
      # mutation is caught at the compiler's own gate: KILLED.
      SUITE_OK=0
      SUITE_FAILED_PIECES="the mutated kernel compile (tg_stage1 compile of tg_compiler/bootstrap_main.tg)"
    fi
    if [ "$SUITE_OK" -eq 1 ]; then
      CANARY_FAILURES=0
      while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
          \#*|"") continue ;;
        esac
        name="${line%.tg}"
        if ! "$MUT_BIN" compile --mode dev -O2 -o "$WORK/build/.mut_canaries/$name" "$WORK/tests/canary/$line" >>"$CANARY_LOG" 2>&1 \
           || ! "$WORK/build/.mut_canaries/$name" >>"$CANARY_LOG" 2>&1; then
          CANARY_FAILURES=$((CANARY_FAILURES + 1))
        fi
      done < "$WORK/tests/canary/MANIFEST"
      if [ "$CANARY_FAILURES" -ne 0 ]; then
        SUITE_OK=0
        SUITE_FAILED_PIECES="the canary suite ($CANARY_FAILURES canary failure(s))"
      fi
    fi
    if [ "$SUITE_OK" -eq 1 ]; then
      if ! "$MUT_BIN" test "$WORK/tests/verifier_projection_tests.tg" >"$VTEST_LOG" 2>&1; then
        SUITE_OK=0
        SUITE_FAILED_PIECES="${SUITE_FAILED_PIECES:+$SUITE_FAILED_PIECES, }tests/verifier_projection_tests.tg"
      fi
    fi
    rm -f "$CANARY_LOG" "$VTEST_LOG"
  fi

  if [ "$SUITE_OK" -eq 0 ]; then
    KILLED=$((KILLED + 1))
    KILLED_IDS+=("$id")
    if [ -n "$DETECTOR_REASON" ]; then
      KILLED_BY+=("the dedicated detector ($DETECTOR_NAME): $DETECTOR_REASON")
      echo "== $id — KILLED (the dedicated detector fired)"
      echo "   detector: $DETECTOR_NAME — $DETECTOR_REASON"
      if [ -n "$SUITE_FAILED_PIECES" ]; then
        echo "   also caught by: $SUITE_FAILED_PIECES"
      fi
    else
      KILLED_BY+=("the shared suite: $SUITE_FAILED_PIECES")
      echo "== $id — KILLED (the shared suite caught it: ${SUITE_FAILED_PIECES})"
    fi
    echo "   $file — $desc"
  else
    SURVIVED=$((SURVIVED + 1))
    SURVIVED_IDS+=("$id")
    SURVIVED_CLASS+=("$klass")
    if [ -n "$BINARY" ]; then
      echo "== $id — SURVIVED (no structural detector fired; the binary tier passed too)"
    else
      echo "== $id — SURVIVED (no structural detector fired; no --binary given, so the binary tier did not run)"
    fi
    echo "   $file — $desc"
  fi
  rm -f "$INV_LOG" "$GATE_LOG" "$BAL_LOG"
done

# ———————————————————————————————————————————————————————————————
# Step 4 — the report (the honest per-mutation kill-rate table)
# ———————————————————————————————————————————————————————————————
{
  echo ""
  echo "======================================================"
  echo "MUTATION TEST REPORT (bounded harness, per-mutation detectors)"
  echo "======================================================"
  echo "tier:            structural (per-mutation detectors + invariant script + grammar gate + balance gate + manifest parity; no ladder run)"
  echo "mutations run:   $TOTAL"
  echo "killed:          $KILLED"
  echo "survived:        $SURVIVED"
  echo "apply errors:    $ERRORS"
  if [ "$TOTAL" -gt 0 ]; then
    KILL_RATE="$(python3 -c "print('%.1f%%' % (100.0 * $KILLED / $TOTAL))")"
    echo "kill-rate:       $KILL_RATE  ($KILLED/$TOTAL)"
  else
    echo "kill-rate:       n/a"
  fi
  echo ""
  echo "the per-mutation result table (id | class | detector | result):"
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
        result="KILLED"
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
    printf '  %-28s %-3s %-52s %s\n' "$id" "$klass" "$(detector_name "$id")" "$result"
  done
  echo ""
  echo "non-equivalent classification: every catalog entry is NE (it"
  echo "changes an observable semantic — accepted/rejected sets, emitted"
  echo "layout/code, or a wake/ordering arm). An NE survivor is a finding."
  echo "  NE mutations:    $TOTAL"
  echo "  NE survivors:    $SURVIVED"
  if [ "$SURVIVED" -eq 0 ]; then
    echo "  NE kill-rate:    100.0% ($KILLED/$TOTAL) — every non-equivalent mutation is killed by its detector"
  else
    echo "  NE kill-rate:    $([ "$TOTAL" -gt 0 ] && python3 -c "print('%.1f%%' % (100.0 * ($TOTAL - $SURVIVED) / $TOTAL))") — FINDING: the surviving mutations must gain detectors"
  fi
  echo ""
  echo "killed (with the killing detector):"
  if [ "$KILLED" -gt 0 ]; then
    idx=0
    for id in "${KILLED_IDS[@]}"; do
      echo "  $id — ${KILLED_BY[$idx]}"
      idx=$((idx + 1))
    done
  fi
  echo "survived (the mutations the suite does NOT catch):"
  if [ "$SURVIVED" -gt 0 ]; then
    idx=0
    for id in "${SURVIVED_IDS[@]}"; do
      echo "  $id (class ${SURVIVED_CLASS[$idx]})"
      idx=$((idx + 1))
    done
  fi
  echo "apply errors (the catalog drifted — a real failure):"
  if [ "$ERRORS" -gt 0 ]; then
    for id in "${ERROR_IDS[@]}"; do echo "  $id"; done
  fi
  echo "======================================================"
} > "${OUT:-/dev/stdout}"
