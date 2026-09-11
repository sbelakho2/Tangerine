#!/usr/bin/env bash
#
# scripts/run_differential.sh — semantic parity gate driver: the OCaml
# seed vs the self-hosted stage3, over the differential corpus
# (tests/differential/corpus/*.tg).
#
# The retired Swift stage0 is NO LONGER a participant: the OCaml seed is
# THE bootstrap seed (stage0_ocaml/). The legacy `--swift-only` /
# `--three-way` flags are recognized only to fail with a clear retirement
# message — there is no Swift binary to compare against.
#
# The migration criterion is EXPLICIT and strict:
#     "OCaml agrees with stage3 on the language semantics."
# It is NEVER "OCaml can produce something executable."  A comparison point
# whose stage3 baseline is not computable is reported NOT-IMPLEMENTED, not
# PASS — the gate never claims parity it cannot demonstrate.
#
# Participants
#   ocaml   the OCaml seed (`tg_stage0.exe` + `tg_pipeline_smoke.exe`)
#   stage3  the ladder artifact `build/tg_stage1` (consumed read-only)
#
# Comparison points (per corpus file), and what is compared:
#   typecheck  OCaml: the smoke executable's per-file path
#              (tg_pipeline_smoke.exe --repo-root ROOT <file>) — the
#              typecheck verdict on the CORPUS module, extracted from its
#              output (a smoke PASS via the inline fallback is NOT a corpus
#              verdict and is treated as such).  stage3: `check <file>`
#              exit status (the current script's stage3 invocation shape).
#              AGREE = identical verdict (both accept or both reject).
#   lower-mir  OCaml: `tg_stage0.exe lower <file>` (check + Seed MIR +
#              MIR verifier + dump; the subcommand exists and is exercised).
#              stage3: NO pinned MIR projection exists in the current
#              harness (it pins tokens/ast only — tests/differential/
#              README.md documents MIR parity as an extension), so the
#              cross-implementation MIR agreement is NOT-IMPLEMENTED.  The
#              OCaml-side outcome is still reported per file.
#   vm         OCaml: the smoke's corpus-path VM run (exit code + returned
#              value) when the corpus module lowers.  stage3: no observable
#              execution baseline is computed by the current script (stage3
#              `check` is compile-only), so the VM agreement is
#              NOT-IMPLEMENTED.  The OCaml-side VM result is still reported.
#
# Modes
#   scripts/run_differential.sh                     OCaml seed pipeline vs
#                                                   stage3, per corpus file
#                                                   (== --ocaml-only)
#   scripts/run_differential.sh --ocaml-only        OCaml seed pipeline vs
#                                                   stage3, per corpus file
#   scripts/run_differential.sh --swift-only        RETIRED: the Swift stage0
#                                                   is gone; exits 2 with the
#                                                   retirement message
#   scripts/run_differential.sh --three-way         RETIRED: no Swift
#                                                   participant remains;
#                                                   exits 2 with the
#                                                   retirement message
#
# Exit status
#   0  every implemented comparison point agreed (no disagreements, no
#      NOT-IMPLEMENTED points required by the mode)
#   1  any implemented comparison point DISAGREED (a divergence dominates
#      the exit code; the NOT-IMPLEMENTED summary is still printed)
#   2  no disagreements, but the mode requires comparison points that are
#      NOT-IMPLEMENTED (or a required binary is missing / the stage3 dump
#      probe fails), or a retired Swift mode was requested
#
# Binary resolution: TG_STAGE3_BIN overrides the stage3 binary;
# TG_OCAML_STAGE0_BIN / TG_OCAML_SMOKE_BIN override the OCaml seed binaries.
#
# This script performs NO ladder runs: the stage0 binaries are plain build
# products, and the stage3 binary is a ladder artifact consumed read-only.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

STAGE3_BIN="${TG_STAGE3_BIN:-$ROOT/build/tg_stage1}"
OCAML_STAGE0_BIN="${TG_OCAML_STAGE0_BIN:-$ROOT/stage0_ocaml/_build/default/bin/tg_stage0.exe}"
OCAML_SMOKE_BIN="${TG_OCAML_SMOKE_BIN:-$ROOT/stage0_ocaml/_build/default/selfcheck/tg_pipeline_smoke.exe}"
CORPUS_DIR="$ROOT/tests/differential"
MANIFEST="$CORPUS_DIR/corpus.manifest"
CORPUS_FILES_DIR="$CORPUS_DIR/corpus"

# ── mode parsing ────────────────────────────────────────────────────────
# The OCaml seed is THE bootstrap seed: the default mode is the OCaml
# migration gate. The Swift modes are retired and fail explicitly.
MODE=ocaml
DIFF_ARGS=()
for arg in "$@"; do
  case "$arg" in
    --swift-only|--three-way) MODE=swift_retired; RETIRED_ARG="$arg" ;;
    --ocaml-only) MODE=ocaml ;;
    *) DIFF_ARGS+=("$arg") ;;
  esac
done

# ── retired Swift modes: explicit failure, never a silent no-op ─────────
if [ "$MODE" = swift_retired ]; then
  echo "run_differential: $RETIRED_ARG is RETIRED — the Swift stage0 (stage0_swift/) no longer exists." >&2
  echo "  The OCaml seed is THE bootstrap seed; run scripts/run_differential.sh (or --ocaml-only)" >&2
  echo "  for the OCaml-seed-vs-stage3 semantic parity gate." >&2
  exit 2
fi

# ── the OCaml-seed migration gate ───────────────────────────────────────

for bin in "$OCAML_STAGE0_BIN" "$OCAML_SMOKE_BIN"; do
  if [ ! -x "$bin" ]; then
    echo "run_differential: OCaml seed binary not found or not executable: $bin" >&2
    echo "  (build it with: cd stage0_ocaml && dune build)" >&2
    exit 2
  fi
done
if [ ! -x "$STAGE3_BIN" ]; then
  echo "run_differential: stage3 binary not found or not executable: $STAGE3_BIN" >&2
  echo "  (the migration gate compares against the stage3 baseline; rebuild the ladder)" >&2
  exit 2
fi
if [ ! -f "$MANIFEST" ]; then
  echo "run_differential: corpus manifest not found: $MANIFEST" >&2
  exit 2
fi

# Positive corpus files, in manifest order (negative/ cases carry `expect`
# and are never migration-compared — the legacy harness already gates them).
CORPUS_FILES=()
while IFS= read -r line; do
  case "$line" in
    'file = 'corpus/*)
      f="${line#file = }"
      CORPUS_FILES+=("$f")
      ;;
  esac
done < "$MANIFEST"
if [ ${#CORPUS_FILES[@]} -eq 0 ]; then
  echo "run_differential: no positive corpus files declared in $MANIFEST" >&2
  exit 2
fi

echo "=== Tangerine OCaml-seed semantic parity gate ==="
echo "Mode:                    --ocaml-only (OCaml seed vs stage3)"
echo "OCaml seed (driver):     $OCAML_STAGE0_BIN"
echo "OCaml seed (smoke):      $OCAML_SMOKE_BIN"
echo "Stage3 (self-host):      $STAGE3_BIN"
echo "Corpus:                  $CORPUS_DIR ($((${#CORPUS_FILES[@]})) files)"
echo ""
echo "Migration criterion: OCaml agrees with stage3 on the language semantics."
echo "  NOT-IMPLEMENTED is reported, never PASS, where a stage3 baseline does not exist."
echo ""

# ── participants ─────────────────────────────────────────────────────────

stage3_verdict() { # $1 = absolute file path; echoes PASS|FAIL
  if "$STAGE3_BIN" check "$1" >/dev/null 2>&1; then echo PASS; else echo FAIL; fi
}

# OCaml verdicts from the smoke executable (the per-file path).
# Sets: SMOKE_RC, OC_TC, OC_TC_N, OC_FALLBACK, OC_VM, OC_VM_RET
ocaml_smoke_verdicts() { # $1 = absolute file path
  local file="$1" out rc
  out="$("$OCAML_SMOKE_BIN" --repo-root "$ROOT" "$file" 2>&1)"
  rc=$?
  SMOKE_RC=$rc; OC_TC=; OC_TC_N=0; OC_FALLBACK=no; OC_VM=; OC_VM_RET=
  if [[ "$out" =~ has[[:space:]]+([0-9]+)[[:space:]]+typecheck[[:space:]]+error\(s\) ]]; then
    OC_TC=FAIL; OC_TC_N="${BASH_REMATCH[1]}"; OC_FALLBACK=yes
  elif [[ "$out" == *"typecheck: 0 errors"* ]]; then
    OC_TC=PASS
  else
    OC_TC=UNKNOWN
  fi
  if [[ "$out" == *"using the inline program"* ]]; then OC_FALLBACK=yes; fi
  if [[ "$out" =~ VM:[[:space:]]+exit[[:space:]]+([0-9]+) ]]; then
    OC_VM="${BASH_REMATCH[1]}"
  fi
  if [[ "$out" =~ main[[:space:]]+returned:[[:space:]]+(.*) ]]; then
    OC_VM_RET="$(printf '%s' "${BASH_REMATCH[1]%%$'\n'*}" | sed 's/[[:space:]]*$//')"
  fi
}

# OCaml verdict from `tg_stage0.exe lower <file>` (the MIR-dump point).
# Sets: OC_LOWER
ocaml_lower_verdict() { # $1 = absolute file path
  local file="$1" out rc
  out="$("$OCAML_STAGE0_BIN" lower "$file" 2>&1)"
  rc=$?
  OC_LOWER=
  if [ $rc -eq 0 ] && [[ "$out" == *"MIR verify PASS"* ]]; then
    if [[ "$out" =~ MIR[[:space:]]+verify[[:space:]]+PASS[[:space:]]+\(([0-9]+)[[:space:]]+functions\) ]]; then
      OC_LOWER="PASS(${BASH_REMATCH[1]})"
    else
      OC_LOWER="PASS"
    fi
  elif [[ "$out" == *"FAILED (typecheck)"* ]]; then
    OC_LOWER="TYPECHECK-FAIL"
  elif [[ "$out" =~ error\[(E9[0-9]+)\] ]]; then
    OC_LOWER="SUBSET-REJECT(${BASH_REMATCH[1]})"
  elif [[ "$out" == *"Seed_bug"* ]]; then
    OC_LOWER="SEED-GAP"
  else
    OC_LOWER="FAIL(rc=$rc)"
  fi
}

# ── per-file verdict rows ────────────────────────────────────────────────

NOT_IMPL_LOWER="no stage3 MIR projection pinned by the current harness (tokens/ast only; tests/differential/README.md documents MIR parity as an extension)"
NOT_IMPL_VM="no stage3 observable-execution baseline (stage3 'check' is compile-only; the current script computes no stage3 VM result)"

TOTAL=0; AGREE_N=0; DISAGREE_N=0; UNKNOWN_N=0
NI_LOWER_N=0; NI_VM_N=0

printf "%-34s | %-46s | %-10s | %s\n" "file" "ocaml" "stage3" "agreement"
printf -- "----------------------------------------------------------------------------------------------------------------------------------------------------------\n"

for mf in "${CORPUS_FILES[@]}"; do
  TOTAL=$((TOTAL + 1))
  file="$CORPUS_FILES_DIR/$(basename "$mf")"
  [ -f "$file" ] || { echo "run_differential: corpus file missing: $file" >&2; exit 3; }

  # stage3 baseline (the current script's stage3 invocation shape: `check`)
  s3="$(stage3_verdict "$file")"

  # OCaml participant
  ocaml_smoke_verdicts "$file"
  ocaml_lower_verdict "$file"

  if [ "$OC_TC" = FAIL ]; then oc_tc="tc:FAIL($OC_TC_N)"; else oc_tc="tc:$OC_TC"; fi
  oc_lower="lower:$OC_LOWER"
  if [ "$OC_FALLBACK" = yes ]; then
    oc_vm="vm:n/a-inline"
  elif [ -n "$OC_VM" ]; then
    oc_vm="vm:$OC_VM/${OC_VM_RET:-?}"
  else
    oc_vm="vm:not-run"
  fi
  oc_cell="$oc_tc $oc_lower $oc_vm"

  # agreement on the implemented point (typecheck); lower-mir and vm have
  # no stage3 baseline today -> NOT-IMPLEMENTED, never a silent pass.
  ni_marks=""
  NI_LOWER_N=$((NI_LOWER_N + 1)); ni_marks="$ni_marks lower-mir"
  NI_VM_N=$((NI_VM_N + 1));       ni_marks="$ni_marks vm"

  if [ "$OC_TC" = UNKNOWN ]; then
    agreement="UNKNOWN (smoke rc=$SMOKE_RC) | NI:$ni_marks"
    UNKNOWN_N=$((UNKNOWN_N + 1))
  elif [ "$OC_TC" = "$s3" ]; then
    agreement="AGREE (typecheck) | NI:$ni_marks"
    AGREE_N=$((AGREE_N + 1))
  else
    agreement="DISAGREE (typecheck: ocaml=$OC_TC stage3=$s3) | NI:$ni_marks"
    DISAGREE_N=$((DISAGREE_N + 1))
  fi

  printf "%-34s | %-46s | %-10s | %s\n" "$mf" "$oc_cell" "check:$s3" "$agreement"
done

# ── summary ─────────────────────────────────────────────────────────────

echo ""
echo "=== Agreement summary (OCaml vs stage3) ==="
echo "  typecheck verdict : $AGREE_N AGREE, $DISAGREE_N DISAGREE, $UNKNOWN_N UNKNOWN (implemented)"
echo "  lower-mir         : NOT-IMPLEMENTED ($NI_LOWER_N/$TOTAL files) — $NOT_IMPL_LOWER"
echo "  vm                : NOT-IMPLEMENTED ($NI_VM_N/$TOTAL files) — $NOT_IMPL_VM"
echo ""
echo "  Comparison points from the audit P1 list with no per-file baseline on either side today:"
echo "    module/DefId graph (per file), typed callable signatures, inferred substitutions,"
echo "    call access effects, resource cleanup plans, canonical-MIR normalization,"
echo "    monomorphized instance graph, stage1 artifact/semantic fingerprints"
echo "    (the latter requires both seeds to compile the kernel closure)."
echo ""
echo "  Criterion applied: OCaml agrees with stage3 on the language semantics."
echo "  NOT-IMPLEMENTED points are never scored as PASS; a file whose corpus pipeline"
echo "  fell back to the inline program (smoke) carries no corpus VM verdict (n/a-inline)."

if [ "$DISAGREE_N" -gt 0 ]; then
  echo ""
  echo "run_differential: OCAML-vs-STAGE3 DIVERGENT on $DISAGREE_N file(s) — migration gate FAILS (exit 1)" >&2
  exit 1
fi
if [ "$UNKNOWN_N" -gt 0 ]; then
  echo ""
  echo "run_differential: $UNKNOWN_N file(s) without a usable OCaml verdict (exit 1)" >&2
  exit 1
fi
if [ "$NI_LOWER_N" -gt 0 ] || [ "$NI_VM_N" -gt 0 ]; then
  echo ""
  echo "run_differential: NOT-IMPLEMENTED comparison points — migration parity cannot be claimed (exit 2)" >&2
  exit 2
fi
echo ""
echo "run_differential: ALL MATCH (exit 0)"
exit 0
