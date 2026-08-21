#!/usr/bin/env bash
# ———————————————————————————————————————————————————————————————
# scripts/gen_release_proof.sh — the TANGERINE RELEASE PROOF artifact
# (the reviewer's item 36).
#
# Runs the release checks and writes the proof document:
#
#   THE RELEASE CHECKS (the reviewer's table) — one PASS / FAIL /
#   PENDING-UNTIL-LADDER line per row:
#     R1  the inventory            — the std-module completeness
#                                   enumeration (every std/*.tg
#                                   contracted) + the canary-manifest
#                                   self-description (a stale committed
#                                   count fails)
#     R2  the semantic checks      — the self-host grammar gate over the
#                                   bootstrap closure + the full tool
#                                   tree; the compiler check part runs
#                                   where a stage binary exists
#     R3  the manifest/registry    — the feature registry generation,
#     generations                  the public-API manifest generation,
#                                   the invariant verification
#     R4  the API manifest's       — gen_api_manifest.sh --release-check
#         release-check              (a public callable with zero
#                                   behavior tests, an error variant
#                                   never exercised, or a cfg target
#                                   without execution FAILS the row)
#     R5  the self-host fixed      — stage2 == stage3 byte-identical
#         point
#     R6  the cross-stage ladder   — stage0 -> stage1 -> stage2 -> stage3
#     R7  the native runs          — the executed canary/litmus/native
#                                   suites at the tested SHA
#
#   THE HONEST STATE: R5-R7 REQUIRE THE LADDER. They are marked
#   PENDING-UNTIL-LADDER in the current snapshot and turn PASS only
#   when the ladder evidence exists — build/release_evidence.json
#   (written ONLY by scripts/gen_status.sh --release-evidence from the
#   tested SHA + the run artifacts; a failing release gate writes no
#   evidence file — that file's role in this proof is exactly the
#   ladder-evidence check). The artifact is generated from the tested
#   SHA by the CI `release-proof` job.
#
#   THE COUNTS (the reviewer's table):
#     UNTESTED PUBLIC SYMBOLS      — the API manifest's
#                                   gates.uncovered_callables
#     UNCLASSIFIED PRODUCT FILES   — std/*.tg without a contracts entry
#     PHANTOM INTRINSICS           — check_intrinsic_closure.sh's
#                                   phantom count (new phantoms fail)
#     KNOWN SAFETY WAIVERS         — tests/release_waivers.json
#                                   waived entries
#     SKIPPED REQUIRED TESTS       — the number of R5-R7 rows still
#                                   PENDING-UNTIL-LADDER
#
#   RELEASE_100 = TRUE iff every row is PASS and every count is 0;
#   otherwise RELEASE_100 = FALSE (the honest verdict — a FAIL or a
#   PENDING row or a nonzero count is not 100).
#
# The script is non-destructive: every generated document is written to
# a scratch path (never over the committed artifacts), except the
# canary-manifest refresh which is diffed against the committed state
# (the evidence-gate discipline: a stale committed count is a FAIL, not
# a rewrite).
#
# Exit status: 0 when the proof document was WRITTEN (the verdicts are
# data inside the document — a RELEASE_100 = FALSE proof is still
# generated and reported, never suppressed); non-zero when the document
# could not be produced.
#
# Usage: scripts/gen_release_proof.sh [--sha <sha>] [--evidence <path>] [outfile]
#   --sha       the tested SHA (default: `git rev-parse HEAD`)
#   --evidence  the ladder-evidence path (default: build/release_evidence.json)
#   outfile     default: build/release_proof.md
# ———————————————————————————————————————————————————————————————
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "gen_release_proof: cannot cd to repo root" >&2; exit 2; }

SHA="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
EVIDENCE="$ROOT/build/release_evidence.json"
OUT="$ROOT/build/release_proof.md"

while [ $# -gt 0 ]; do
  case "$1" in
    --sha)
      shift
      SHA="${1:-$SHA}"
      shift
      ;;
    --evidence)
      shift
      EVIDENCE="${1:-$EVIDENCE}"
      shift
      ;;
    *) break ;;
  esac
done
[ $# -eq 0 ] || OUT="$1"

SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/release_proof.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

# ———————————————————————————————————————————————————————————————
# R1 — the inventory (the completeness enumeration + the canary
#      manifest self-description)
# ———————————————————————————————————————————————————————————————
R1_STATE="FAIL"
R1_DETAIL=""
# Save the committed manifests so the refresh never leaves a rewrite
# behind (the proof is non-destructive; the diff check is the verdict).
cp -p tests/canary/MANIFEST "$SCRATCH/manifest_canary" 2>/dev/null || true
cp -p tests/canary_neg/MANIFEST "$SCRATCH/manifest_canary_neg" 2>/dev/null || true
cp -p tests/arm64/MANIFEST "$SCRATCH/manifest_arm64" 2>/dev/null || true
if bash "$ROOT/scripts/gen_stdlib_completeness.sh" "$SCRATCH/stdlib_completeness.md" >"$SCRATCH/r1_completeness.log" 2>&1; then
  R1_DETAIL="completeness enumeration: PASS (every std/*.tg contracted)"
  if bash "$ROOT/scripts/gen_status.sh" --refresh-manifests >"$SCRATCH/r1_manifests.log" 2>&1 \
     && git diff --exit-code -- tests/canary/MANIFEST tests/canary_neg/MANIFEST tests/arm64/MANIFEST >/dev/null 2>&1; then
    R1_STATE="PASS"
    R1_DETAIL="completeness enumeration PASS; canary manifests current (count + manifest sha256 + test-list sha256)"
  else
    R1_STATE="FAIL"
    R1_DETAIL="$R1_DETAIL; canary MANIFEST refresh produced a diff (a stale committed count) — regenerate via scripts/gen_status.sh --refresh-manifests and commit"
  fi
else
  R1_STATE="FAIL"
  R1_DETAIL="completeness enumeration FAILED (see: $(sed -n '1,3p' "$SCRATCH/r1_completeness.log" | tr '\n' ' '))"
fi
cp -p "$SCRATCH/manifest_canary" tests/canary/MANIFEST 2>/dev/null || true
cp -p "$SCRATCH/manifest_canary_neg" tests/canary_neg/MANIFEST 2>/dev/null || true
cp -p "$SCRATCH/manifest_arm64" tests/arm64/MANIFEST 2>/dev/null || true

# ———————————————————————————————————————————————————————————————
# R2 — the semantic checks (the self-host grammar gate; the compiler
#      check part runs where a stage binary exists)
# ———————————————————————————————————————————————————————————————
R2_STATE="FAIL"
R2_DETAIL=""
if bash "$ROOT/scripts/run_selfhost_grammar_gate.sh" >"$SCRATCH/r2_grammar.log" 2>&1; then
  R2_STATE="PASS"
  R2_DETAIL="the self-host grammar gate PASS (the closure + the full tool tree are free of the forbidden legacy forms; the compiler check ran $(grep -q 'compiler check' "$SCRATCH/r2_grammar.log" && echo 'with a binary' || echo 'structurally — no USABLE stage binary in this tree (stale binaries are rejected by the probe)'))"
else
  R2_DETAIL="the self-host grammar gate FAILED (see: $(sed -n '1,3p' "$SCRATCH/r2_grammar.log" | tr '\n' ' '))"
fi

# ———————————————————————————————————————————————————————————————
# R3 — the manifest/registry generations (feature registry + public-API
#      manifest + the invariant verification)
# ———————————————————————————————————————————————————————————————
R3_STATE="FAIL"
R3_DETAIL=""
GENERATION_OK=1
if ! bash "$ROOT/scripts/gen_feature_registry.sh" "$SCRATCH/feature_registry.md" "$SCRATCH/feature_ladder.json" >"$SCRATCH/r3_features.log" 2>&1; then
  GENERATION_OK=0
  R3_DETAIL="feature-registry generation FAILED (see: $(sed -n '1,2p' "$SCRATCH/r3_features.log" | tr '\n' ' '))"
elif ! bash "$ROOT/scripts/gen_api_manifest.sh" "$SCRATCH/public_api_manifest.json" >"$SCRATCH/r3_api.log" 2>&1; then
  GENERATION_OK=0
  R3_DETAIL="public-API manifest generation FAILED (see: $(sed -n '1,2p' "$SCRATCH/r3_api.log" | tr '\n' ' '))"
elif ! bash "$ROOT/scripts/verify_invariants.sh" >"$SCRATCH/r3_invariants.log" 2>&1; then
  GENERATION_OK=0
  R3_DETAIL="the invariant verification FAILED (see: $(grep -E 'RESULT|FAIL' "$SCRATCH/r3_invariants.log" | tail -2 | tr '\n' ' '))"
else
  INV_SUMMARY="$(grep -E '^  assertions:' "$SCRATCH/r3_invariants.log" | tail -1 | sed 's/^  //')"
  R3_DETAIL="feature registry + public-API manifest generated; invariants: ${INV_SUMMARY:-see log}"
fi
[ "$GENERATION_OK" -eq 1 ] && R3_STATE="PASS"

# ———————————————————————————————————————————————————————————————
# R4 — the API manifest's release-check
# ———————————————————————————————————————————————————————————————
R4_STATE="FAIL"
R4_DETAIL=""
if bash "$ROOT/scripts/gen_api_manifest.sh" --release-check "$SCRATCH/api_release_check.json" >"$SCRATCH/r4_api.log" 2>&1; then
  R4_STATE="PASS"
  R4_DETAIL="the API-manifest release-check PASS (no untested public callable, no unexercised error variant, no cfg target without execution evidence)"
else
  R4_DETAIL="the API-manifest release-check FAILED: $(grep -E '^\s+- \[' "$SCRATCH/r4_api.log" | sed 's/^[[:space:]]*//' | tr '\n' '; ')"
fi

# ———————————————————————————————————————————————————————————————
# The ladder evidence (the release_evidence.json's role)
# ———————————————————————————————————————————————————————————————
EVIDENCE_STATE="ABSENT"
EVIDENCE_SHA=""
if [ -f "$EVIDENCE" ]; then
  EVIDENCE_SHA="$(python3 - "$EVIDENCE" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1])).get("tested_sha", ""))
except Exception:
    print("")
PY
)"
  if [ "$EVIDENCE_SHA" = "$SHA" ]; then
    EVIDENCE_STATE="PRESENT (tested_sha = $SHA)"
    R5_STATE="PASS"
    R6_STATE="PASS"
    R7_STATE="PASS"
  else
    EVIDENCE_STATE="PRESENT but tested_sha ($EVIDENCE_SHA) != the proof SHA — STALE for this snapshot"
    R5_STATE="PENDING-UNTIL-LADDER"
    R6_STATE="PENDING-UNTIL-LADDER"
    R7_STATE="PENDING-UNTIL-LADDER"
  fi
else
  R5_STATE="PENDING-UNTIL-LADDER"
  R6_STATE="PENDING-UNTIL-LADDER"
  R7_STATE="PENDING-UNTIL-LADDER"
fi
R5_DETAIL="stage2 == stage3 byte-identical at the tested SHA — requires the ladder evidence (build/release_evidence.json written by scripts/gen_status.sh --release-evidence from the tested SHA + the run artifacts)"
R6_DETAIL="stage0 -> stage1 -> stage2 -> stage3 at the tested SHA — requires the ladder evidence"
R7_DETAIL="the executed canary/litmus/native suites at the tested SHA — requires the ladder evidence"

# ———————————————————————————————————————————————————————————————
# THE COUNTS (the reviewer's table)
# ———————————————————————————————————————————————————————————————
UNTESTED_PUBLIC_SYMBOLS=0
if [ -f "$SCRATCH/public_api_manifest.json" ]; then
  UNTESTED_PUBLIC_SYMBOLS="$(python3 - "$SCRATCH/public_api_manifest.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(len(d.get("gates", {}).get("uncovered_callables", [])))
except Exception:
    print("?")
PY
)"
fi

UNCLASSIFIED_PRODUCT_FILES="$(python3 - <<'PY'
import os, tomllib
try:
    contracts = tomllib.load(open("docs/current/stdlib_contracts.toml", "rb"))
except Exception:
    try:
        import tomli
        contracts = tomli.load(open("docs/current/stdlib_contracts.toml", "rb"))
    except Exception:
        print("?")
        raise SystemExit
mods = sorted(f[:-3] for f in os.listdir("std") if f.endswith(".tg"))
print(sum(1 for m in mods if m not in contracts.get("module", {})))
PY
)"

PHANTOM_INTRINSICS=0
if bash "$ROOT/scripts/check_intrinsic_closure.sh" >"$SCRATCH/r_counts_intrinsics.log" 2>&1; then
  PHANTOM_INTRINSICS="$(sed -n 's/.*phantoms: \([0-9]*\),.*/\1/p' "$SCRATCH/r_counts_intrinsics.log" | head -1)"
  [ -n "$PHANTOM_INTRINSICS" ] || PHANTOM_INTRINSICS=0
else
  PHANTOM_INTRINSICS="$(sed -n 's/.*phantoms: \([0-9]*\),.*/\1/p' "$SCRATCH/r_counts_intrinsics.log" | head -1)"
  [ -n "$PHANTOM_INTRINSICS" ] || PHANTOM_INTRINSICS="? (the intrinsic-closure scan FAILED)"
fi

KNOWN_SAFETY_WAIVERS="$(python3 - <<'PY'
import json
try:
    d = json.load(open("tests/release_waivers.json"))
    print(len(d.get("waived", {})))
except Exception:
    print("?")
PY
)"

SKIPPED_REQUIRED_TESTS=0
for st in "$R5_STATE" "$R6_STATE" "$R7_STATE"; do
  if [ "$st" = "PENDING-UNTIL-LADDER" ]; then
    SKIPPED_REQUIRED_TESTS=$((SKIPPED_REQUIRED_TESTS + 1))
  fi
done

# ———————————————————————————————————————————————————————————————
# RELEASE_100
# ———————————————————————————————————————————————————————————————
RELEASE_100="TRUE"
for st in "$R1_STATE" "$R2_STATE" "$R3_STATE" "$R4_STATE" "$R5_STATE" "$R6_STATE" "$R7_STATE"; do
  [ "$st" = "PASS" ] || RELEASE_100="FALSE"
done
for c in "$UNTESTED_PUBLIC_SYMBOLS" "$UNCLASSIFIED_PRODUCT_FILES" "$PHANTOM_INTRINSICS" "$KNOWN_SAFETY_WAIVERS" "$SKIPPED_REQUIRED_TESTS"; do
  [ "$c" = "0" ] || RELEASE_100="FALSE"
done

# ———————————————————————————————————————————————————————————————
# Write the proof document
# ———————————————————————————————————————————————————————————————
mkdir -p "$(dirname "$OUT")"
{
  echo "# TANGERINE RELEASE PROOF"
  echo ""
  echo "tested SHA:  $SHA"
  echo "generated:   $(date -u +%Y-%m-%dT%H:%M:%SZ) (UTC)"
  echo "by:          scripts/gen_release_proof.sh"
  echo "ladder evidence (release_evidence.json): $EVIDENCE_STATE"
  echo ""
  echo "## The release checks (the reviewer's table)"
  echo ""
  echo "| Row | Check | Verdict | Detail |"
  echo "|-----|-------|---------|--------|"
  echo "| R1 | the inventory (completeness enumeration + canary-manifest self-description) | $R1_STATE | $R1_DETAIL |"
  echo "| R2 | the semantic checks (the self-host grammar gate; the compiler check where a binary exists) | $R2_STATE | $R2_DETAIL |"
  echo "| R3 | the manifest/registry generations (feature registry + public-API manifest + invariants) | $R3_STATE | $R3_DETAIL |"
  echo "| R4 | the API manifest's release-check | $R4_STATE | $R4_DETAIL |"
  echo "| R5 | the self-host fixed point (stage2 == stage3 byte-identical) | $R5_STATE | $R5_DETAIL |"
  echo "| R6 | the cross-stage ladder (stage0 -> stage1 -> stage2 -> stage3) | $R6_STATE | $R6_DETAIL |"
  echo "| R7 | the native runs (the canary/litmus/native suites at the tested SHA) | $R7_STATE | $R7_DETAIL |"
  echo ""
  echo "## The counts (the reviewer's table)"
  echo ""
  echo "UNTESTED PUBLIC SYMBOLS: $UNTESTED_PUBLIC_SYMBOLS"
  echo "UNCLASSIFIED PRODUCT FILES: $UNCLASSIFIED_PRODUCT_FILES"
  echo "PHANTOM INTRINSICS: $PHANTOM_INTRINSICS"
  echo "KNOWN SAFETY WAIVERS: $KNOWN_SAFETY_WAIVERS"
  echo "SKIPPED REQUIRED TESTS: $SKIPPED_REQUIRED_TESTS"
  echo ""
  echo "RELEASE_100 = $RELEASE_100"
} > "$OUT"

echo "wrote $OUT (tested SHA $SHA, RELEASE_100 = $RELEASE_100)"
exit 0
