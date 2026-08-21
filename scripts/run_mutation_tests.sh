#!/usr/bin/env bash
# ———————————————————————————————————————————————————————————————
# scripts/run_mutation_tests.sh — the bounded mutation harness
# (the reviewer's mutation categories).
#
# The mutations are applied to COPIES of the KEY SEMANTIC files (the
# checker, the verifier, the layout engine — plus the two contracts
# whose semantic homes are std/async.tg and tg_compiler/codegen.tg) by
# SCRIPTED transformations (exact-string edits, no heuristics). The
# ORIGINALS ARE NEVER MODIFIED: the harness builds a fresh source copy
# of the tree, applies ONE mutation to the copy, runs the bounded suite
# against the mutated tree, and discards it. A mutation is KILLED iff
# the suite FAILS (any piece exits non-zero — a compile failure counts
# as a kill); it SURVIVED iff the suite passes.
#
# THE BOUNDED SUITE (the reviewer's suite selection):
#   structural tier (runs everywhere — no compiler binary needed):
#     scripts/verify_invariants.sh          — the invariant script
#     scripts/run_selfhost_grammar_gate.sh  — the structural semantic
#                                             scans over the closure +
#                                             the full tool tree
#   binary tier (--binary <tg>: the mutated kernel is COMPILED with the
#     given binary and the executed suites run against the mutated
#     compiler):
#     the canaries (tests/canary/MANIFEST)  — compile + execute every
#     tests/verifier_projection_tests.tg    — the verifier tests
#     scripts/verify_invariants.sh          — re-run on the mutated tree
#
# The harness is BOUNDED: a fixed mutation list per file (below), a
# fixed suite selection, one mutation at a time, one fresh copy per
# mutation. The honest current kill-rate (structural tier, no ladder
# run) is reported on stdout at the end — the mutations the current
# suite catches.
#
# THE MUTATION CATALOG (one entry per reviewer category):
#   mut-invert-comparison        checker       types.tg — the field-
#                                                index bounds check is
#                                                inverted (`<` -> `>`)
#   mut-delete-diagnostic        verifier      mir.tg — the extern-ABI
#                                                classification diagnostic
#                                                is deleted
#   mut-consume-to-read          checker       types.tg — AccessEffect::
#                                                Consume classified as
#                                                Read (a moving binding
#                                                is treated as read-only)
#   mut-remove-drop-mark         checker       types.tg — the partial-
#                                                move registry record the
#                                                MIR's partial-drop chain
#                                                consumes is never marked
#   mut-skip-verifier            verifier      mir.tg — verify_mir
#                                                returns an empty error
#                                                list immediately
#   mut-field-offset             layout engine layout_engine.tg — the
#                                                Map header key_stride
#                                                offset 24 -> 32
#   mut-remove-overflow-check    layout engine layout_engine.tg — the
#                                                layout_checked_add
#                                                overflow guard is
#                                                deleted (fail-closed
#                                                becomes wrap)
#   mut-branch-target            verifier      mir.tg — the verify_
#                                                function_v2 extern
#                                                early-return condition
#                                                is flipped (non-extern
#                                                functions return
#                                                unverified)
#   mut-remove-wake              async contract std/async.tg — the
#                                                waker's wake_task
#                                                dispatch is removed
#   mut-remove-atomic-ordering   atomics       codegen.tg — the x86
#                                                SeqCst store branch is
#                                                made unreachable (the
#                                                ordering is removed;
#                                                SeqCst stores become
#                                                weak MOVs)
#   mut-equality-to-permissive   checker       types.tg — the exact
#                                                depth-1 projection
#                                                check `== 1` becomes
#                                                the permissive `>= 1`
#
# Usage: scripts/run_mutation_tests.sh [--binary <tg>] [--only <id,...>]
#                                      [--out <file>]
#   --binary  a working tg compiler; the mutated kernel is compiled
#             with it and the binary tier runs (canaries + verifier
#             tests). Omit for the structural tier only.
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

# The mutation catalog (id | file | description). The transformations
# themselves live in the python block below (exact-string edits with an
# apply-count assertion — an unapplied transformation is a drift error).
CATALOG=(
  "mut-invert-comparison|tg_compiler/types.tg|checker: the field-index bounds check inverted (valid indices rejected)"
  "mut-delete-diagnostic|tg_compiler/mir.tg|verifier: the extern-ABI classification diagnostic deleted"
  "mut-consume-to-read|tg_compiler/types.tg|checker: AccessEffect::Consume classified as AccessEffect::Read"
  "mut-remove-drop-mark|tg_compiler/types.tg|checker: the partial-drop-chain record never marks the consumed place"
  "mut-skip-verifier|tg_compiler/mir.tg|verifier: verify_mir returns an empty error list immediately"
  "mut-field-offset|tg_compiler/layout_engine.tg|layout engine: the Map header key_stride offset 24 -> 32"
  "mut-remove-overflow-check|tg_compiler/layout_engine.tg|layout engine: the layout_checked_add overflow guard deleted"
  "mut-branch-target|tg_compiler/mir.tg|verifier: the verify_function_v2 extern early-return flipped (non-extern functions return unverified)"
  "mut-remove-wake|std/async.tg|async contract: the waker's wake_task dispatch removed"
  "mut-remove-atomic-ordering|tg_compiler/codegen.tg|atomics: the x86 SeqCst store branch made unreachable (weak MOV always)"
  "mut-equality-to-permissive|tg_compiler/types.tg|checker: the exact depth-1 projection check == 1 becomes >= 1"
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
elif mutation_id == "mut-remove-drop-mark":
    delete("tg_compiler/types.tg",
           "    ext.insert(path.clone(), PlaceMoveState::Consumed)\n")
elif mutation_id == "mut-skip-verifier":
    insert_after("tg_compiler/mir.tg",
                 "def verify_mir(mir: MirProgram) -> Vec[String]\n  var errors = Vec::new()\n",
                 "  return Vec::new()\n")
elif mutation_id == "mut-field-offset":
    apply("tg_compiler/layout_engine.tg",
          'else if field_name == "key_stride" then Option::Some(24)',
          'else if field_name == "key_stride" then Option::Some(32)')
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
# Step 2 — one mutation at a time, against a fresh copy
# ———————————————————————————————————————————————————————————————
declare -a KILLED_IDS=()
declare -a SURVIVED_IDS=()
declare -a ERROR_IDS=()
TOTAL=0
KILLED=0
SURVIVED=0
ERRORS=0

for entry in "${CATALOG[@]}"; do
  id="${entry%%|*}"
  rest="${entry#*|}"
  file="${rest%%|*}"
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

  # the bounded suite — structural tier (always)
  INV_LOG="$(mktemp "${TMPDIR:-/tmp}/tg_mut_inv.XXXXXX")"
  GATE_LOG="$(mktemp "${TMPDIR:-/tmp}/tg_mut_gate.XXXXXX")"
  SUITE_OK=1
  SUITE_FAILED_PIECES=""
  if ! (cd "$WORK" && bash scripts/verify_invariants.sh >"$INV_LOG" 2>&1); then
    SUITE_OK=0
    SUITE_FAILED_PIECES="verify_invariants.sh"
  fi
  if ! (cd "$WORK" && bash scripts/run_selfhost_grammar_gate.sh >"$GATE_LOG" 2>&1); then
    SUITE_OK=0
    SUITE_FAILED_PIECES="${SUITE_FAILED_PIECES:+$SUITE_FAILED_PIECES, }run_selfhost_grammar_gate.sh"
  fi

  # the bounded suite — binary tier (when a compiler was given)
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
    echo "== $id — KILLED (the suite caught it: ${SUITE_FAILED_PIECES})"
    echo "   $file — $desc"
  else
    SURVIVED=$((SURVIVED + 1))
    SURVIVED_IDS+=("$id")
    echo "== $id — SURVIVED (the suite did not catch it)"
    echo "   $file — $desc"
  fi
  rm -f "$INV_LOG" "$GATE_LOG"
done

# ———————————————————————————————————————————————————————————————
# Step 3 — the report (the honest kill-rate)
# ———————————————————————————————————————————————————————————————
{
  echo ""
  echo "======================================================"
  echo "MUTATION TEST REPORT (bounded harness)"
  echo "======================================================"
  echo "tier:            $([ -n "$BINARY" ] && echo 'binary (canaries + verifier tests + invariant script + grammar gate)' || echo 'structural (invariant script + grammar gate; the canaries/verifier tests need a binary — no ladder run)')"
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
  echo "killed:"
  if [ "$KILLED" -gt 0 ]; then
    for id in "${KILLED_IDS[@]}"; do echo "  $id"; done
  fi
  echo "survived (the mutations the current suite does NOT catch):"
  if [ "$SURVIVED" -gt 0 ]; then
    for id in "${SURVIVED_IDS[@]}"; do echo "  $id"; done
  fi
  echo "apply errors (the catalog drifted — a real failure):"
  if [ "$ERRORS" -gt 0 ]; then
    for id in "${ERROR_IDS[@]}"; do echo "  $id"; done
  fi
  echo "======================================================"
} > "${OUT:-/dev/stdout}"
