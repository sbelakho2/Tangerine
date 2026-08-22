#!/usr/bin/env bash
# tests/run_release_evidence_schema_tests.sh — the RELEASE-EVIDENCE SCHEMA
# tests (the P0 fail-closed contract between the evidence writer and the
# proof generator).
#
# The cases (each asserts the CATEGORY verdicts R5/R6/R7 — the rows the
# proof generator consumes — not only the validator's exit status):
#   1. a complete valid evidence set        -> the categories PASS
#   2. a missing required artifact          -> INVALID -> the categories FAIL
#   3. a wrong hash (a tampered stage file) -> INVALID -> the categories FAIL
#   4. a failed/skipped required job        -> INVALID -> the categories FAIL
#   5. an extra unlisted artifact           -> INVALID -> the categories FAIL
#   6. no evidence file                     -> the categories PENDING-UNTIL-LADDER
#   7. stale evidence (tested_sha mismatch) -> the categories PENDING-UNTIL-LADDER
#
# The evidence itself is FAKE (scratch files); the validation is the REAL
# scripts/release_evidence_schema.sh — pure bash + python3, no ladder.
#
# Usage: tests/run_release_evidence_schema_tests.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/release_evidence_schema_tests.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

PASS=0
FAIL=0

# shellcheck source=scripts/release_evidence_schema.sh
. "$ROOT/scripts/release_evidence_schema.sh"

check() { # check <case> <exit-code-of-the-check>
  if [ "$2" -eq 0 ]; then
    echo "  [ok] $1"
    PASS=$((PASS + 1))
  else
    echo "  [FAILED] $1" >&2
    FAIL=$((FAIL + 1))
  fi
}

# ── the fake-but-complete artifact set ──────────────────────────────────────
EVDIR="$SCRATCH/evidence"
JOB_RESULTS="$SCRATCH/job_results.json"
TESTED_SHA="0123456789abcdef0123456789abcdef01234567"

# The workflow run identity the writer records (the schema requires it).
export GITHUB_WORKFLOW="CI"
export GITHUB_JOB="status"
export GITHUB_RUN_ID="4242"
export GITHUB_RUN_ATTEMPT="1"

make_valid_dir() { # make_valid_dir <dir> ; builds the COMPLETE artifact set
  local d="$1"
  rm -rf "$d"
  for a in tg-stages-macos-arm64 bootstrap-fingerprints bootstrap-native-tests \
           cross-lane-binaries linux-fingerprints linux-native-tests; do
    mkdir -p "$d/$a"
  done
  # The stage binaries (stage2 == stage3 byte-identical).
  printf 'stage-one-image\n' > "$d/tg-stages-macos-arm64/tg_stage1"
  printf 'stage-two-three-image\n' > "$d/tg-stages-macos-arm64/tg_stage2"
  cp "$d/tg-stages-macos-arm64/tg_stage2" "$d/tg-stages-macos-arm64/tg_stage3"
  local h1 h2 h3
  h1="$(shasum -a 256 "$d/tg-stages-macos-arm64/tg_stage1" | cut -d' ' -f1)"
  h2="$(shasum -a 256 "$d/tg-stages-macos-arm64/tg_stage2" | cut -d' ' -f1)"
  h3="$(shasum -a 256 "$d/tg-stages-macos-arm64/tg_stage3" | cut -d' ' -f1)"
  # The bootstrap fingerprints: the link-image rows carry the ACTUAL stage
  # binary hashes; the semantic phases (tokens/ast/hir/mir/mir-mono) are
  # equal between stage2 and stage3.
  local pt pa ph pm pmm
  pt="$(printf 'tokens' | shasum -a 256 | cut -d' ' -f1)"
  pa="$(printf 'ast' | shasum -a 256 | cut -d' ' -f1)"
  ph="$(printf 'hir' | shasum -a 256 | cut -d' ' -f1)"
  pm="$(printf 'mir' | shasum -a 256 | cut -d' ' -f1)"
  pmm="$(printf 'mir-mono' | shasum -a 256 | cut -d' ' -f1)"
  {
    printf 'FINGERPRINT tg_stage1 link-image %s\n' "$h1"
    printf 'FINGERPRINT tg_stage1 tokens %s\n' "$(printf 'tok1' | shasum -a 256 | cut -d' ' -f1)"
    printf 'FINGERPRINT tg_stage1 ast %s\n' "$(printf 'ast1' | shasum -a 256 | cut -d' ' -f1)"
    printf 'FINGERPRINT tg_stage1 hir %s\n' "$(printf 'hir1' | shasum -a 256 | cut -d' ' -f1)"
    printf 'FINGERPRINT tg_stage1 mir %s\n' "$(printf 'mir1' | shasum -a 256 | cut -d' ' -f1)"
    printf 'FINGERPRINT tg_stage1 mir-mono %s\n' "$(printf 'mm1' | shasum -a 256 | cut -d' ' -f1)"
  } > "$d/bootstrap-fingerprints/tg_stage1.fingerprints"
  {
    printf 'FINGERPRINT tg_stage2 link-image %s\n' "$h2"
    printf 'FINGERPRINT tg_stage2 tokens %s\n' "$pt"
    printf 'FINGERPRINT tg_stage2 ast %s\n' "$pa"
    printf 'FINGERPRINT tg_stage2 hir %s\n' "$ph"
    printf 'FINGERPRINT tg_stage2 mir %s\n' "$pm"
    printf 'FINGERPRINT tg_stage2 mir-mono %s\n' "$pmm"
  } > "$d/bootstrap-fingerprints/tg_stage2.fingerprints"
  {
    printf 'FINGERPRINT tg_stage3 link-image %s\n' "$h3"
    printf 'FINGERPRINT tg_stage3 tokens %s\n' "$pt"
    printf 'FINGERPRINT tg_stage3 ast %s\n' "$pa"
    printf 'FINGERPRINT tg_stage3 hir %s\n' "$ph"
    printf 'FINGERPRINT tg_stage3 mir %s\n' "$pm"
    printf 'FINGERPRINT tg_stage3 mir-mono %s\n' "$pmm"
  } > "$d/bootstrap-fingerprints/tg_stage3.fingerprints"
  # The linux lane fingerprints (stage2 == stage3 link-image).
  {
    printf 'FINGERPRINT tg_stage1 link-image %s\n' "$(printf 'linux-one' | shasum -a 256 | cut -d' ' -f1)"
    printf 'FINGERPRINT tg_stage2 link-image %s\n' "$(printf 'linux-two-three' | shasum -a 256 | cut -d' ' -f1)"
    printf 'FINGERPRINT tg_stage3 link-image %s\n' "$(printf 'linux-two-three' | shasum -a 256 | cut -d' ' -f1)"
  } > "$d/linux-fingerprints/tg_stages.fingerprints"
  # The native-lane outputs (the canary count + the lanes' artifacts).
  printf 'canary output A\n' > "$d/bootstrap-native-tests/canary_pos_a"
  printf 'canary output B\n' > "$d/bootstrap-native-tests/canary_pos_b"
  mkdir -p "$d/cross-lane-binaries/.cross_lane_x86_64"
  printf 'x86_64 cross-lane binary\n' > "$d/cross-lane-binaries/.cross_lane_x86_64/bin"
  printf 'linux native canary\n' > "$d/linux-native-tests/lnx_canary"
}

write_valid_job_results() { # write_valid_job_results <file>
  cat > "$1" <<'JSON'
{
  "bootstrap": {"result": "success"},
  "cross-compile": {"result": "success"},
  "allocator": {"result": "success"},
  "atomic-litmus": {"result": "success"},
  "stdlib-integration": {"result": "success"},
  "db-integration-postgres": {"result": "success"},
  "db-integration-mysql": {"result": "success"},
  "linux-x86-64-native": {"result": "success"},
  "conformance": {"result": "success"}
}
JSON
}

rows_states() { # rows_states <evidence> <sha> ; the R5/R6/R7 states
  release_evidence_rows "$1" "$2" | grep -E '^(R5|R6|R7)\|' | cut -d'|' -f2 | sort -u
}

expect_rows_state() { # expect_rows_state <case> <evidence> <sha> <expected-state>
  local case_name="$1" ev="$2" sha="$3" want="$4"
  local rows got
  rows="$(release_evidence_rows "$ev" "$sha")"
  got="$(printf '%s\n' "$rows" | grep -E '^(R5|R6|R7)\|' | cut -d'|' -f2 | sort -u)"
  if [ "$got" != "$want" ]; then
    echo "  [FAILED] $case_name (expected R5/R6/R7 = $want; got: $got)" >&2
    printf '%s\n' "$rows" >&2
    FAIL=$((FAIL + 1))
  else
    echo "  [ok] $case_name (R5/R6/R7 = $want)"
    PASS=$((PASS + 1))
  fi
}

echo "=== case 1: a complete valid evidence set -> the categories PASS ==="
write_valid_job_results "$JOB_RESULTS"
make_valid_dir "$EVDIR"
build_release_evidence "$EVDIR" "$EVDIR/release_evidence.json" "$TESTED_SHA" "$JOB_RESULTS" "" "2026-08-22T00:00:00Z"
check "the writer produced the evidence file" $([ -f "$EVDIR/release_evidence.json" ] && echo 0 || echo 1)

if python3 - "$EVDIR/release_evidence.json" <<'PY'
import json, sys, re
d = json.load(open(sys.argv[1], encoding="utf-8"))
ah = d.get("artifact_hashes")
if not isinstance(ah, list) or not ah:
    sys.exit(1)
if not all(re.fullmatch(r"[0-9a-f]{64}  \S+", x) for x in ah):
    sys.exit(1)
if any("present" in x for x in ah):
    sys.exit(1)
if not any(x.endswith("tg-stages-macos-arm64/tg_stage2") for x in ah):
    sys.exit(1)
if len(d["artifacts"]["bootstrap-native-tests"]["files"]) != 2:
    sys.exit(1)
sys.exit(0)
PY
then
  check "the per-file hash records are the actual 64-hex hashes of the actual files (no 'present' shorthand)" 0
else
  check "the per-file hash records are the actual 64-hex hashes of the actual files (no 'present' shorthand)" 1
fi

if python3 - "$EVDIR/release_evidence.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
v = d["verdicts"]
ok = (v["stage2_equals_stage3"] is True and
      v["semantic_fingerprints_equal"] is True and
      v["linux_stage2_equals_stage3"] is True and
      all(x is True for x in v["phases"].values()) and
      d["jobs"]["bootstrap"] == "success" and
      d["workflow"]["run_id"] == "4242")
sys.exit(0 if ok else 1)
PY
then
  check "the verdicts + jobs + workflow identity are recorded" 0
else
  check "the verdicts + jobs + workflow identity are recorded" 1
fi

if validate_release_evidence "$EVDIR/release_evidence.json" > "$SCRATCH/validation_ok.txt"; then
  check "the validator accepts the complete evidence set (no violations)" 0
else
  check "the validator accepts the complete evidence set (no violations)" 1
fi
check "the validator output is empty for the complete set" $([ -s "$SCRATCH/validation_ok.txt" ] && echo 1 || echo 0)
expect_rows_state "the complete valid evidence set -> R5/R6/R7 PASS" "$EVDIR/release_evidence.json" "$TESTED_SHA" "PASS"

echo "=== case 2: a missing required artifact -> INVALID -> the categories FAIL ==="
EV2="$SCRATCH/evidence_missing_artifact"
make_valid_dir "$EV2"
rm -rf "$EV2/linux-native-tests"
build_release_evidence "$EV2" "$EV2/release_evidence.json" "$TESTED_SHA" "$JOB_RESULTS" "" "2026-08-22T00:00:00Z"
expect_rows_state "the missing linux-native-tests artifact fails the categories" "$EV2/release_evidence.json" "$TESTED_SHA" "FAIL"

echo "=== case 3: a wrong hash (a tampered stage binary) -> INVALID -> the categories FAIL ==="
EV3="$SCRATCH/evidence_wrong_hash"
make_valid_dir "$EV3"
printf 'tampered\n' >> "$EV3/tg-stages-macos-arm64/tg_stage2"
build_release_evidence "$EV3" "$EV3/release_evidence.json" "$TESTED_SHA" "$JOB_RESULTS" "" "2026-08-22T00:00:00Z"
expect_rows_state "the wrong stage hash (stage2 != stage3, link-image mismatch) fails the categories" "$EV3/release_evidence.json" "$TESTED_SHA" "FAIL"

echo "=== case 4: a failed/skipped required job -> INVALID -> the categories FAIL ==="
EV4="$SCRATCH/evidence_failed_job"
make_valid_dir "$EV4"
cat > "$JOB_RESULTS" <<'JSON'
{
  "bootstrap": {"result": "failure"},
  "cross-compile": {"result": "success"},
  "allocator": {"result": "success"},
  "atomic-litmus": {"result": "success"},
  "stdlib-integration": {"result": "success"},
  "db-integration-postgres": {"result": "success"},
  "db-integration-mysql": {"result": "success"},
  "linux-x86-64-native": {"result": "skipped"}
}
JSON
build_release_evidence "$EV4" "$EV4/release_evidence.json" "$TESTED_SHA" "$JOB_RESULTS" "" "2026-08-22T00:00:00Z"
expect_rows_state "the failed bootstrap + skipped linux-x86-64-native conclusions fail the categories" "$EV4/release_evidence.json" "$TESTED_SHA" "FAIL"
write_valid_job_results "$JOB_RESULTS"

echo "=== case 5: an extra unlisted artifact -> INVALID -> the categories FAIL ==="
EV5="$SCRATCH/evidence_extra_artifact"
make_valid_dir "$EV5"
mkdir -p "$EV5/extra-unlisted-artifact"
printf 'unlisted\n' > "$EV5/extra-unlisted-artifact/file.bin"
build_release_evidence "$EV5" "$EV5/release_evidence.json" "$TESTED_SHA" "$JOB_RESULTS" "" "2026-08-22T00:00:00Z"
expect_rows_state "the extra unlisted artifact fails the categories" "$EV5/release_evidence.json" "$TESTED_SHA" "FAIL"

echo "=== case 6: no evidence file -> the categories PENDING-UNTIL-LADDER ==="
expect_rows_state "the absent evidence keeps the categories PENDING-UNTIL-LADDER" "$SCRATCH/does-not-exist.json" "$TESTED_SHA" "PENDING-UNTIL-LADDER"

echo "=== case 7: stale evidence (tested_sha mismatch) -> the categories PENDING-UNTIL-LADDER ==="
EV7="$SCRATCH/evidence_stale"
make_valid_dir "$EV7"
build_release_evidence "$EV7" "$EV7/release_evidence.json" "feedfacefeedfacefeedfacefeedfacefeedface" "$JOB_RESULTS" "" "2026-08-22T00:00:00Z"
expect_rows_state "the stale evidence (a matching-SHA test alone is never a proof) stays PENDING-UNTIL-LADDER" "$EV7/release_evidence.json" "$TESTED_SHA" "PENDING-UNTIL-LADDER"

echo ""
echo "release-evidence schema tests: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
