#!/usr/bin/env bash
#
# scripts/ocaml_seed_evidence.sh — tested-parent CI evidence for the OCaml
# bootstrap seed (stage0_ocaml), audit P1-2.
#
# WHAT THIS RECORDS
#   Every record is evidence FOR THE TESTED PARENT: the commit whose
#   clean tree was built and tested (the SHA the record names).  The
#   commit that later CONTAINS the record has a NEW SHA — a record can
#   be exact for its tested parent, never for itself.  Each run writes
#   one machine-readable JSON record to
#
#     bootstrap/evidence/ocaml/<short-sha>_<unix-time>.json
#
#   containing:
#     git_commit            the TESTED commit (`git rev-parse HEAD` of
#                           the CLEAN tree the build/tests ran on)
#     git_dirty             ALWAYS false — the generator FAILS on a dirty
#                           tree (re-audit finding 1: a tested-parent
#                           record is only produced from a clean checkout;
#                           a dirty tree aborts before anything is
#                           recorded)
#     git_dirty_stat        always empty (no dirty-tree record exists)
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
#                           (debt: <category> <count> per category,
#                           debt_total, debt_primary, debt_secondary)
#                           and every gate verdict
#                           (FRONTEND_SEMANTIC_GATE,
#                           SEED_MIR_STRUCTURAL_GATE,
#                           BOOTSTRAP_EXECUTABLE_CLOSURE, RESULT)
#     evidence              the deterministic tg_evidence phase lines
#                           (incl. declaration_fixpoint_iterations /
#                           body_passes, parsed into bootstrap_check)
#     diagnostics           ocaml-diagnostics.jsonl next to the record
#                           (re-audit finding 6): one JSON line per
#                           bootstrap-check diagnostic — module, item,
#                           category, message, span-file, span-start/end,
#                           secondary flag — lines sorted
#                           lexicographically; diagnostics.sha256 is the
#                           sha256 over the sorted lines (deterministic),
#                           diagnostics.count the number of lines
#     recorded_at_unix/iso  when the record was captured
#
#   The record IS the CI artifact for the TESTED PARENT — the SHA it
#   names: publish bootstrap/evidence/ocaml/<short-sha>_<unix-time>.json
#   from the CI job that tested that SHA.  If the record is committed,
#   it is evidence for the COMMIT'S PARENT (the tested tree), not for
#   the commit containing it (that commit has a new SHA).
#
# CLEAN-TREE POLICY (re-audit finding 1)
#   Tested-parent evidence requires a clean checkout of the tested
#   commit: `git status --porcelain` must be empty or the script FAILS
#   before building or recording anything.  A record with
#   git_dirty=true can never be produced.
#
# STALE-FILE POLICY
#   bootstrap/evidence/ocaml/ holds ONLY tested-parent records of the
#   current schema — a file that is not a JSON record with the required
#   fields (e.g. the legacy *.evidence files), or a record that names a
#   commit other than the current tested commit, is MOVED to
#   bootstrap/evidence/ocaml/history/ — never deleted, never left in
#   place as "current state".
#
# USAGE
#   scripts/ocaml_seed_evidence.sh
#
# Behavior: (a) verifies the locked OCaml/Dune toolchain via
# scripts/check_ocaml_toolchain.sh and FAILS if the working tree is
# dirty (tested-parent evidence requires a clean checkout of the tested
# commit); (b) builds the seed with `dune build` (a failing build aborts
# before any record is written — no record for a tree that does not
# compile); (c) captures git identity, all hashes, the test suite
# result, every selfcheck verdict, the bootstrap-check gate output and
# the tg_evidence phase lines; (d) writes the JSON record and the
# ocaml-diagnostics.jsonl artifact; (e) moves stale non-schema files to
# history/; (f) prints the record to stdout.

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

# (a') Tested-parent evidence model (re-audit finding 1): the tree MUST
# be clean.  A dirty tree cannot produce a tested-parent record — fail
# before building or recording anything instead of emitting
# git_dirty=true.
if [ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]; then
  echo "ocaml_seed_evidence: FAIL — the working tree is NOT clean; tested-parent evidence requires a clean checkout of the tested commit" >&2
  git -C "$ROOT_DIR" status --porcelain >&2
  exit 1
fi

# (b) Build the seed. The tree treats warnings as errors, so a clean
# build is also the compile gate; a broken tree never records evidence.
(cd "$STAGE_DIR" && dune build)

# (c) Gather the tested-commit identity of the clean tree.
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse HEAD)"
GIT_SHORT="$(git -C "$ROOT_DIR" rev-parse --short HEAD)"
GIT_DIRTY=false
GIT_DIRTY_STAT=""

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
import hashlib
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
# lines + debt_total + debt_primary + debt_secondary) is the closure's
# final debt report; the gate verdicts and typecheck counters come from
# the same output.  The declaration/body phase counts come from the
# tg_evidence lines (declaration_fixpoint_iterations / body_passes —
# the re-audit's replacement for the misleading "(N rounds)" driver
# line).
bc_out = rd("bc_out")
debt_lines = [l for l in bc_out.splitlines() if l.startswith("debt: ")]
debt_total_lines = [l for l in bc_out.splitlines() if l.startswith("debt_total: ")]
debt_primary_lines = [l for l in bc_out.splitlines() if l.startswith("debt_primary: ")]
debt_secondary_lines = [l for l in bc_out.splitlines() if l.startswith("debt_secondary: ")]
debt = {}
last_total = 0
last_primary = 0
last_secondary = 0
if debt_total_lines:
    last_total = int(debt_total_lines[-1].split()[1])
    if debt_primary_lines:
        last_primary = int(debt_primary_lines[-1].split()[1])
    if debt_secondary_lines:
        last_secondary = int(debt_secondary_lines[-1].split()[1])
    n = len(debt_lines)
    if n >= 8:
        block = debt_lines[-8:]
        for l in block:
            _, cat, count = l.split()
            debt[cat] = int(count)
        # The block's own total must agree with the printed total.
        if sum(debt.values()) != last_total:
            sys.stderr.write("warning: last debt block sum != debt_total\n")

# The declaration/body phase counts from the tg_evidence lines (the
# canonical measurement; the driver's "(N rounds)" line is not used for
# these because rounds=2 was found semantically misleading).
phase_m = list(re.finditer(
    r"evidence declaration_fixpoint_iterations=(\d+) body_passes=(\d+)",
    rd("evidence_lines")))
phase_groups = phase_m[-1].groups() if phase_m else ("", "")

def last_match(pattern):
    m = list(re.finditer(pattern, bc_out))
    return m[-1].group(1) if m else ""

typecheck_m = list(re.finditer(
    r"typecheck: (\d+) modules, (\d+) items, (\d+) errors \((\d+) rounds\)", bc_out))
typecheck_groups = typecheck_m[-1].groups() if typecheck_m else ("", "", "", "")

# ocaml-diagnostics.jsonl (re-audit finding 6): every per-item
# bootstrap-check line — "<module>: [secondary] <item>: <message> at
# file#<id>[<start>..<end>)" (the driver emits the "[secondary] "
# prefix before the item name) — becomes one JSON line with module,
# item, category (Debt_report.classify ported 1:1 from
# src/debt_report.ml, in pattern order), the full message, the span
# file id and byte offsets, and the secondary flag.  Lines are written
# lexicographically sorted so the content is canonical; the hash is
# sha256 over exactly those sorted lines (deterministic).
DEBT_PATTERNS = [
    ("cannot infer", "cannot_infer_generic"),
    ("Type_param(s) in concrete execution position", "cannot_infer_generic"),
    ("unsolved type variable", "cannot_infer_generic"),
    ("type parameters do not take arguments", "cannot_infer_generic"),
    ("too many type arguments", "cannot_infer_generic"),
    ("type parameter `", "cannot_infer_generic"),
    ("unknown type `", "unresolved_type"),
    ("unknown nominal type `", "unresolved_type"),
    ("unknown trait `", "unresolved_type"),
    ("unknown field `", "unresolved_type"),
    ("unknown variant `", "unresolved_type"),
    ("unknown identity", "unresolved_type"),
    ("Self is only available", "unresolved_type"),
    ("does not take arguments", "unresolved_type"),
    ("associated type `", "unresolved_type"),
    ("trait-object types", "unresolved_type"),
    ("FieldId", "unresolved_type"),
    ("VariantId", "unresolved_type"),
    ("unknown function `", "unresolved_callable"),
    ("unknown name `", "unresolved_callable"),
    ("unknown variable `", "unresolved_callable"),
    ("has no method `", "unresolved_callable"),
    ("cannot call a value of type ", "unresolved_callable"),
    ("too many arguments", "unresolved_callable"),
    ("too few arguments", "unresolved_callable"),
    ("is a function; call it with arguments", "unresolved_callable"),
    ("DefId", "unresolved_callable"),
    ("unresolved call", "unresolved_callable"),
    ("missing argument access effects", "unresolved_callable"),
    ("not a module", "unresolved_module"),
    ("type mismatch", "type_mismatch"),
    ("cannot cast ", "type_mismatch"),
    ("cannot index ", "type_mismatch"),
    ("cannot iterate ", "type_mismatch"),
    ("cannot dereference ", "type_mismatch"),
    ("cannot project ", "type_mismatch"),
    ("operator requires matching numeric operands", "type_mismatch"),
    ("bitwise operator requires integer operands", "type_mismatch"),
    ("unary minus requires a number", "type_mismatch"),
    ("requires Bool", "type_mismatch"),
    ("requires an integer", "type_mismatch"),
    ("requires an Option or Result", "type_mismatch"),
    ("tuple pattern requires a tuple type", "type_mismatch"),
    ("tuple pattern arity mismatch", "type_mismatch"),
    ("tuple index ", "type_mismatch"),
    ("or-pattern alternatives bind different types", "type_mismatch"),
    ("range pattern ", "type_mismatch"),
    ("is not a struct", "type_mismatch"),
    ("is not an enum", "type_mismatch"),
    ("is not a nominal type", "type_mismatch"),
    ("type argument(s)", "type_mismatch"),
    (" field(s)", "type_mismatch"),
    ("incompatible with the expected function type", "type_mismatch"),
    ("recursive type", "type_mismatch"),
    ("unsatisfied", "obligation"),
    ("obligation", "obligation"),
    ("trait contract", "obligation"),
    ("duplicate ", "duplicate_decl"),
]


def classify(message):
    for sub, cat in DEBT_PATTERNS:
        if sub in message:
            return cat
    return "other"


DIAG_RE = re.compile(
    r"^(.+?): (\[secondary\] )?(.+?): (.+) at file#(\d+)\[(\d+)\.\.(\d+)\)$")
diagnostics = []
for raw in bc_out.splitlines():
    m = DIAG_RE.match(raw.strip())
    if not m:
        continue
    module, sec, item, message, fid, start, end = m.groups()
    diagnostics.append({
        "module": module,
        "item": item,
        "category": classify(message),
        "message": message,
        "span_file": int(fid),
        "span_start": int(start),
        "span_end": int(end),
        "secondary": sec is not None,
    })
diagnostics.sort(
    key=lambda d: json.dumps(d, sort_keys=True, separators=(",", ":")))
diag_content = "\n".join(
    json.dumps(d, sort_keys=True, separators=(",", ":")) for d in diagnostics)
if diag_content:
    diag_content += "\n"
diag_sha = hashlib.sha256(diag_content.encode()).hexdigest()
diag_path = record_file[:-5] + ".diagnostics.jsonl"
with open(diag_path, "w") as f:
    f.write(diag_content)

record = {
    "schema_version": 3,
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
        "declaration_fixpoint_iterations": int(phase_groups[0]) if phase_groups[0] else None,
        "body_passes": int(phase_groups[1]) if phase_groups[1] else None,
        "debt": debt,
        "debt_total": last_total,
        "debt_primary": last_primary,
        "debt_secondary": last_secondary,
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
    "diagnostics": {
        "artifact": os.path.basename(diag_path),
        "count": len(diagnostics),
        "sha256": diag_sha,
    },
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

# (e) Stale-file policy: only tested-parent records of the current
# schema (records naming the CURRENT tested commit) stay in place;
# anything else (including stale diagnostics artifacts) moves to
# history/.
DIAG_FILE="${RECORD_FILE%.json}.diagnostics.jsonl"
python3 - "$EVIDENCE_DIR" "$HISTORY_DIR" "$GIT_COMMIT" "$RECORD_FILE" "$DIAG_FILE" <<'PYEOF'
import json
import os
import shutil
import sys

evidence_dir, history_dir, head, fresh_record, fresh_diag = (
    sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4], sys.argv[5])

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
    if os.path.abspath(path) in (os.path.abspath(fresh_record), os.path.abspath(fresh_diag)):
        continue
    if is_current_record(path):
        continue
    shutil.move(path, os.path.join(history_dir, name))
PYEOF

# (f) Print the record.
python3 -c 'import json,sys; print(json.dumps(json.load(open(sys.argv[1])), indent=2))' "$RECORD_FILE"
printf '\nrecord: %s — evidence for TESTED PARENT %s (the clean tree that was built and tested); the commit containing this record is a NEW SHA and was NOT what was tested\n' "$RECORD_FILE" "$GIT_COMMIT"
printf 'diagnostics artifact: %s (sha256 %s)\n' "$DIAG_FILE" \
  "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["diagnostics"]["sha256"])' "$RECORD_FILE")"
