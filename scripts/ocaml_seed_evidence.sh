#!/usr/bin/env bash
#
# scripts/ocaml_seed_evidence.sh — exact-HEAD CI evidence for the OCaml
# bootstrap seed (stage0_ocaml), audit P1-2.
#
# WHAT THIS RECORDS
#   Every record is bound to the EXACT tested revision.  Each run writes
#   one machine-readable JSON record to
#
#     bootstrap/evidence/ocaml/<short-sha>_<unix-time>.json
#
#   containing:
#     git_commit            exact `git rev-parse HEAD`
#     git_dirty             false on a clean tree; true otherwise
#     git_dirty_stat        `git diff --stat` summary when dirty
#     manifest_file_sha256  SHA-256 of bootstrap/compiler_kernel.manifest
#     manifest_fingerprint  the pipeline's canonical manifest fingerprint
#                           (the same value the driver prints)
#     toolchain_lock_sha256 SHA-256 of bootstrap/ocaml-toolchain.lock
#                           (fallback: SHA-256 of the ocaml/dune version
#                           output when no lock file exists)
#     toolchain             the locked ocaml/dune/arch versions
#     stage0_binary_sha256  SHA-256 of _build/default/bin/tg_stage0.exe
#     tests                 passed/failed counts from test_main.exe
#     selfchecks            per-executable exit status of every built
#                           stage0_ocaml/selfcheck/*.exe
#     bootstrap_check       the driver gate output: typecheck counts,
#                           the machine-readable diagnostic-debt block
#                           (debt: <category> <count> per category and
#                           debt_total), and every gate verdict
#                           (FRONTEND_SEMANTIC_GATE,
#                           SEED_MIR_STRUCTURAL_GATE,
#                           BOOTSTRAP_EXECUTABLE_CLOSURE, RESULT)
#     evidence              the deterministic tg_evidence phase lines
#     recorded_at_unix/iso  when the record was captured
#
#   The record IS the CI artifact for the exact tested SHA: publish
#   bootstrap/evidence/ocaml/<short-sha>_<unix-time>.json from the CI
#   job that tested that SHA.
#
# STALE-FILE POLICY
#   bootstrap/evidence/ocaml/ holds ONLY exact-HEAD records of the
#   current schema.  Files that are not JSON records with the required
#   fields (e.g. the legacy *.evidence files) are MOVED to
#   bootstrap/evidence/ocaml/history/ — never deleted, never left in
#   place as "current state".
#
# USAGE
#   scripts/ocaml_seed_evidence.sh
#
# Behavior: (a) verifies the locked OCaml/Dune toolchain via
# scripts/check_ocaml_toolchain.sh; (b) builds the seed with `dune build`
# (a failing build aborts before any record is written — no record for a
# tree that does not compile); (c) captures git identity, all hashes,
# the test suite result, every selfcheck verdict, the bootstrap-check
# gate output and the tg_evidence phase lines; (d) writes the JSON
# record; (e) moves stale non-schema files to history/; (f) prints the
# record to stdout.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STAGE_DIR="$ROOT_DIR/stage0_ocaml"
EVIDENCE_DIR="$ROOT_DIR/bootstrap/evidence/ocaml"
HISTORY_DIR="$EVIDENCE_DIR/history"
MANIFEST="$ROOT_DIR/bootstrap/compiler_kernel.manifest"
LOCK="$ROOT_DIR/bootstrap/ocaml-toolchain.lock"
TG_BIN="$STAGE_DIR/_build/default/bin/tg_stage0.exe"
TEST_BIN="$STAGE_DIR/_build/default/test/test_main.exe"

sha256_of() { shasum -a 256 "$1" | awk '{print $1}'; }

# (a) Toolchain gate: fail fast when the locked OCaml/Dune versions
# (bootstrap/ocaml-toolchain.lock) are not installed.
"$ROOT_DIR/scripts/check_ocaml_toolchain.sh"

# (b) Build the seed. The tree treats warnings as errors, so a clean
# build is also the compile gate; a broken tree never records evidence.
(cd "$STAGE_DIR" && dune build)

# (c) Gather the exact-HEAD identity.
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
GIT_SHORT="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
if git -C "$ROOT_DIR" status --porcelain | grep -q .; then
  GIT_DIRTY=true
  GIT_DIRTY_STAT="$(git -C "$ROOT_DIR" diff --stat)"
else
  GIT_DIRTY=false
  GIT_DIRTY_STAT=""
fi

# Manifest and toolchain-lock hashes.
MANIFEST_SHA="$(sha256_of "$MANIFEST")"
if [ -f "$LOCK" ]; then
  LOCK_SHA="$(sha256_of "$LOCK")"
else
  LOCK_SHA="$(printf '%s\n%s\n' "$(ocaml --version)" "$(dune --version)" | shasum -a 256 | awk '{print $1}')"
fi
LOCK_OCAML="$(awk -F' = ' '$1 == "ocaml" { gsub(/"/, "", $2); print $2 }' "$LOCK")"
LOCK_DUNE="$(awk -F' = ' '$1 == "dune" { gsub(/"/, "", $2); print $2 }' "$LOCK")"
LOCK_ARCH="$(awk -F' = ' '$1 == "arch" { gsub(/"/, "", $2); print $2 }' "$LOCK")"

# Stage0 binary hash.
BIN_SHA="$(sha256_of "$TG_BIN")"

# Test suite counts (run from the stage dir: the manifest suite resolves
# corpus paths relative to stage0_ocaml, e.g. ../bootstrap/...).
TESTS_OUT="$(cd "$STAGE_DIR" && timeout 300 "$TEST_BIN")"
TESTS_PASSED="$(printf '%s\n' "$TESTS_OUT" | sed -nE 's/^([0-9]+) passed.*/\1/p' | tail -1)"
TESTS_FAILED="$(printf '%s\n' "$TESTS_OUT" | sed -nE 's/^[0-9]+ passed, ([0-9]+) failed.*/\1/p' | tail -1)"

# Selfcheck verdicts (every built executable, run from the stage dir so
# corpus-relative defaults resolve; tg_evidence takes the repo root).
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ocaml_evidence.XXXXXX")"
SELFCHECKS_TSV="$WORK_DIR/selfchecks.tsv"
: > "$SELFCHECKS_TSV"
for EXE in "$STAGE_DIR"/_build/default/selfcheck/*.exe; do
  [ -x "$EXE" ] || continue
  NAME="$(basename "$EXE" .exe)"
  set +e
  if [ "$NAME" = "tg_evidence" ]; then
    (cd "$STAGE_DIR" && timeout 300 "$EXE" "$ROOT_DIR") > "$WORK_DIR/sc_$NAME.out" 2>&1
  else
    (cd "$STAGE_DIR" && timeout 300 "$EXE") > "$WORK_DIR/sc_$NAME.out" 2>&1
  fi
  RC=$?
  set -e
  printf '%s\t%d\n' "$NAME" "$RC" >> "$SELFCHECKS_TSV"
done

# The deterministic tg_evidence phase lines.
EVIDENCE_OUT="$(timeout 300 "$STAGE_DIR/_build/default/selfcheck/tg_evidence.exe" "$ROOT_DIR" 2>&1 || true)"
printf '%s\n' "$EVIDENCE_OUT" | grep '^evidence ' > "$WORK_DIR/evidence_lines" || true

# The bootstrap-check gate output (the gate may FAIL — the record keeps
# the verdicts; a nonzero exit is expected while the typecheck gate
# fails and must not abort the record).
set +e
BC_OUT="$(timeout 300 "$TG_BIN" bootstrap-check --repo-root "$ROOT_DIR" 2>&1)"
BC_RC=$?
set -e
printf '%s\n' "$BC_OUT" > "$WORK_DIR/bc_out"

# (d) Compose the JSON record.
RECORD_TIME="$(date +%s)"
RECORD_FILE="$EVIDENCE_DIR/${GIT_SHORT}_${RECORD_TIME}.json"
mkdir -p "$EVIDENCE_DIR"
printf '%s' "$GIT_COMMIT" > "$WORK_DIR/git_commit"
printf '%s' "$GIT_SHORT" > "$WORK_DIR/git_short"
printf '%s' "$GIT_DIRTY" > "$WORK_DIR/git_dirty"
printf '%s' "$GIT_DIRTY_STAT" > "$WORK_DIR/git_dirty_stat"
printf '%s' "$MANIFEST_SHA" > "$WORK_DIR/manifest_sha"
printf '%s' "$LOCK_SHA" > "$WORK_DIR/lock_sha"
printf '%s|%s|%s' "$LOCK_OCAML" "$LOCK_DUNE" "$LOCK_ARCH" > "$WORK_DIR/lock_versions"
printf '%s' "$BIN_SHA" > "$WORK_DIR/bin_sha"
printf '%s' "$TESTS_PASSED" > "$WORK_DIR/tests_passed"
printf '%s' "$TESTS_FAILED" > "$WORK_DIR/tests_failed"
printf '%s' "$BC_RC" > "$WORK_DIR/bc_rc"
printf '%s' "$RECORD_TIME" > "$WORK_DIR/record_time"
python3 - "$WORK_DIR" "$RECORD_FILE" <<'PYEOF'
import json
import os
import re
import sys

work_dir, record_file = sys.argv[1], sys.argv[2]


def rd(name, default=""):
    p = os.path.join(work_dir, name)
    if not os.path.exists(p):
        return default
    with open(p) as f:
        return f.read().rstrip("\n")


def rd_int(name, default=0):
    v = rd(name)
    return int(v) if v.isdigit() else default


lock_ocaml, lock_dune, lock_arch = rd("lock_versions", "||").split("|", 2)

# Parse the bootstrap-check output: the last debt block (8 category
# lines + debt_total) is the closure's final debt report; the gate
# verdicts and typecheck counters come from the same output.
bc_out = rd("bc_out")
debt_lines = [l for l in bc_out.splitlines() if l.startswith("debt: ")]
debt_total_lines = [l for l in bc_out.splitlines() if l.startswith("debt_total: ")]
debt = {}
last_total = 0
if debt_total_lines:
    last_total = int(debt_total_lines[-1].split()[1])
    n = len(debt_lines)
    if n >= 8:
        block = debt_lines[-8:]
        for l in block:
            _, cat, count = l.split()
            debt[cat] = int(count)
        # The block's own total must agree with the printed total.
        if sum(debt.values()) != last_total:
            sys.stderr.write("warning: last debt block sum != debt_total\n")

def last_match(pattern):
    m = list(re.finditer(pattern, bc_out))
    return m[-1].group(1) if m else ""

typecheck_m = list(re.finditer(
    r"typecheck: (\d+) modules, (\d+) items, (\d+) errors \((\d+) rounds\)", bc_out))
typecheck_groups = typecheck_m[-1].groups() if typecheck_m else ("", "", "", "")

record = {
    "schema_version": 2,
    "git_commit": rd("git_commit"),
    "git_short_sha": rd("git_short"),
    "git_dirty": rd("git_dirty") == "true",
    "git_dirty_stat": rd("git_dirty_stat"),
    "manifest_file_sha256": rd("manifest_sha"),
    "manifest_fingerprint": last_match(r"fingerprint: ([0-9a-f]{64})"),
    "toolchain_lock_sha256": rd("lock_sha"),
    "toolchain": {
        "ocaml": lock_ocaml,
        "dune": lock_dune,
        "arch": lock_arch,
    },
    "stage0_binary_sha256": rd("bin_sha"),
    "tests": {
        "passed": rd_int("tests_passed"),
        "failed": rd_int("tests_failed"),
    },
    "selfchecks": {},
    "bootstrap_check": {
        "exit_code": rd_int("bc_rc"),
        "modules": int(typecheck_groups[0]) if typecheck_groups[0] else None,
        "items": int(typecheck_groups[1]) if typecheck_groups[1] else None,
        "errors": int(typecheck_groups[2]) if typecheck_groups[2] else None,
        "rounds": int(typecheck_groups[3]) if typecheck_groups[3] else None,
        "debt": debt,
        "debt_total": last_total,
        "gates": {
            "FRONTEND_SEMANTIC_GATE": last_match(r"FRONTEND_SEMANTIC_GATE = (\S+)"),
            "SEED_MIR_STRUCTURAL_GATE": last_match(r"SEED_MIR_STRUCTURAL_GATE = (\S+)"),
            "BOOTSTRAP_EXECUTABLE_CLOSURE": last_match(r"BOOTSTRAP_EXECUTABLE_CLOSURE = (\S+)"),
            "RESULT": last_match(r"RESULT[:=] (\S+)"),
        },
    },
    "evidence": [
        l for l in rd("evidence_lines").splitlines() if l.startswith("evidence ")
    ],
    "recorded_at_unix": rd_int("record_time"),
    "record_file": os.path.basename(record_file),
}

with open(os.path.join(work_dir, "selfchecks.tsv")) as f:
    for line in f:
        name, rc = line.rstrip("\n").split("\t")
        record["selfchecks"][name] = {"exit": int(rc), "pass": int(rc) == 0}

with open(record_file, "w") as f:
    json.dump(record, f, indent=2, sort_keys=True)
    f.write("\n")
PYEOF

# (e) Stale-file policy: only exact-HEAD records of the current schema
# stay in place; anything else moves to history/.
python3 - "$EVIDENCE_DIR" "$HISTORY_DIR" "$GIT_COMMIT" "$RECORD_FILE" <<'PYEOF'
import json
import os
import shutil
import sys

evidence_dir, history_dir, head, fresh_record = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

required_fields = [
    "git_commit",
    "manifest_file_sha256",
    "manifest_fingerprint",
    "toolchain_lock_sha256",
    "stage0_binary_sha256",
    "tests",
    "selfchecks",
    "bootstrap_check",
]


def is_current_record(path):
    try:
        with open(path) as f:
            rec = json.load(f)
    except Exception:
        return False
    if not isinstance(rec, dict):
        return False
    if not all(k in rec for k in required_fields):
        return False
    return rec.get("git_commit") == head


os.makedirs(history_dir, exist_ok=True)
for name in sorted(os.listdir(evidence_dir)):
    path = os.path.join(evidence_dir, name)
    if not os.path.isfile(path):
        continue
    if os.path.abspath(path) == os.path.abspath(fresh_record):
        continue
    if is_current_record(path):
        continue
    shutil.move(path, os.path.join(history_dir, name))
PYEOF

# (f) Print the record.
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2))' "$RECORD_FILE"
printf '\nrecord: %s\n' "$RECORD_FILE"
