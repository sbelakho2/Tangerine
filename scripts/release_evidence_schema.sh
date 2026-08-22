#!/usr/bin/env bash
# scripts/release_evidence_schema.sh — the TANGERINE RELEASE EVIDENCE
# SCHEMA: the machine-readable contract between the evidence WRITER
# (scripts/gen_status.sh --release-evidence) and the proof GENERATOR
# (scripts/gen_release_proof.sh --evidence).
#
# The schema declares the EXACT required set:
#
#   RELEASE_EVIDENCE_SCHEMA_VERSION  — the evidence file must declare this
#                                      schema version
#   RELEASE_REQUIRED_JOBS            — the required jobs; the evidence must
#                                      record each with conclusion
#                                      "success" (a failed/skipped/unrecorded
#                                      job is a violation)
#   RELEASE_REQUIRED_ARTIFACTS       — the required artifact names; the
#                                      evidence must record each (the
#                                      per-file sha-256 read from the ACTUAL
#                                      files), and nothing unlisted — an
#                                      extra unlisted artifact is a violation
#   RELEASE_STAGE_BINARIES           — the stage binaries stage1/stage2/
#                                      stage3 with their hashes
#   RELEASE_SEMANTIC_PHASES          — the tokens/AST/HIR/MIR/post-mono
#                                      phases whose stage2 == stage3
#                                      equality must be proven
#   RELEASE_NATIVE_*_JOB(S)          — the native-lane outputs (the canary
#                                      counts, the litmus, the allocator,
#                                      the DB, the TLS) with their job
#                                      conclusions
#
# The evidence file records the per-artifact hash + the per-job conclusion
# + the per-verdict proof (the equality checks' actual results). The
# matching-SHA test alone is never a proof: the proof generator validates
# the evidence against this schema, and a category is PASS only when its
# OWN artifacts and conclusions are recorded and proven.
#
# This file is a LIBRARY: it defines the schema constants and three
# functions — build_release_evidence (the writer), validate_release_evidence
# (the fail-closed validator), release_evidence_rows (the per-category
# verdicts) — and emits nothing when sourced.
set -u

RELEASE_EVIDENCE_SCHEMA_VERSION=1

# The required jobs (the evidence records each conclusion; the validator
# requires "success").
RELEASE_REQUIRED_JOBS=(
  bootstrap
  cross-compile
  allocator
  atomic-litmus
  stdlib-integration
  db-integration-postgres
  db-integration-mysql
  linux-x86-64-native
)

# The required artifacts (the evidence dir must hold one subdirectory per
# artifact name; the validator requires the EXACT set — an unlisted artifact
# fails).
RELEASE_REQUIRED_ARTIFACTS=(
  tg-stages-macos-arm64
  bootstrap-fingerprints
  bootstrap-native-tests
  cross-lane-binaries
  linux-fingerprints
  linux-native-tests
)

# The stage binaries (recorded with their sha-256 from the actual files of
# the tg-stages-macos-arm64 artifact).
RELEASE_STAGE_BINARIES=(stage1 stage2 stage3)

# The semantic phases whose stage2 == stage3 equality must be proven.
RELEASE_SEMANTIC_PHASES=(tokens ast hir mir mir-mono)

# The native-lane outputs' backing jobs.
RELEASE_NATIVE_LITMUS_JOB=atomic-litmus
RELEASE_NATIVE_ALLOCATOR_JOB=allocator
RELEASE_NATIVE_DB_JOBS=(stdlib-integration db-integration-mysql db-integration-postgres)
RELEASE_NATIVE_TLS_JOB=stdlib-integration

# ────────────────────────────────────────────────────────────────────────────
# The writer: build_release_evidence
# Usage: build_release_evidence <evidence-dir> <outfile> <tested-sha>
#                               <job-results-json|-> <release-gated-features>
#                               <timestamp-utc>
# <evidence-dir> holds one subdirectory per artifact (the artifact names);
# every subdirectory is recorded with the per-file sha-256 OF THE ACTUAL
# FILES. The verdicts are computed from the actual artifacts: the
# stage2 == stage3 equality is the equality of the actual stage binaries'
# hashes, and the semantic-phase equality is the equality of the actual
# stage2/stage3 fingerprint records. The workflow run identity is read from
# the GITHUB_* environment. The compatibility key artifact_hashes carries
# the same per-file hashes as a flat "sha256  path" list (the feature
# registry consumes it as the run-evidence existence check).
# ────────────────────────────────────────────────────────────────────────────
build_release_evidence() {
  local ev_dir="$1" outfile="$2" sha="$3" jobs_file="$4" gated="$5" stamp="$6"
  local wf_name="${GITHUB_WORKFLOW:-}" wf_job="${GITHUB_JOB:-}"
  local wf_run="${GITHUB_RUN_ID:-}" wf_attempt="${GITHUB_RUN_ATTEMPT:-}"
  RELEASE_SCHEMA_VERSION="$RELEASE_EVIDENCE_SCHEMA_VERSION" \
  RELEASE_SCHEMA_ARTIFACTS="${RELEASE_REQUIRED_ARTIFACTS[*]}" \
  RELEASE_SCHEMA_STAGES="${RELEASE_STAGE_BINARIES[*]}" \
  RELEASE_SCHEMA_PHASES="${RELEASE_SEMANTIC_PHASES[*]}" \
  RELEASE_SCHEMA_DB_JOBS="${RELEASE_NATIVE_DB_JOBS[*]}" \
  RELEASE_SCHEMA_LITMUS_JOB="$RELEASE_NATIVE_LITMUS_JOB" \
  RELEASE_SCHEMA_ALLOC_JOB="$RELEASE_NATIVE_ALLOCATOR_JOB" \
  RELEASE_SCHEMA_TLS_JOB="$RELEASE_NATIVE_TLS_JOB" \
  python3 - "$ev_dir" "$outfile" "$sha" "$jobs_file" "$gated" "$stamp" \
    "$wf_name" "$wf_job" "$wf_run" "$wf_attempt" <<'PY'
import hashlib, json, os, re, sys

ev_dir, outfile, sha, jobs_file, gated, stamp = sys.argv[1:7]
wf_name, wf_job, wf_run, wf_attempt = sys.argv[7:11]

REQUIRED_ARTIFACTS = os.environ["RELEASE_SCHEMA_ARTIFACTS"].split()
STAGES = os.environ["RELEASE_SCHEMA_STAGES"].split()
PHASES = os.environ["RELEASE_SCHEMA_PHASES"].split()
DB_JOBS = os.environ["RELEASE_SCHEMA_DB_JOBS"].split()
LITMUS_JOB = os.environ["RELEASE_SCHEMA_LITMUS_JOB"]
ALLOC_JOB = os.environ["RELEASE_SCHEMA_ALLOC_JOB"]
TLS_JOB = os.environ["RELEASE_SCHEMA_TLS_JOB"]

HEX64 = re.compile(r"^[0-9a-f]{64}$")


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            h.update(chunk)
    return h.hexdigest()


def norm_stage(s):
    # the fingerprint files name the stages tg_stageN (macOS + linux);
    # normalize to stageN.
    return s[3:] if s.startswith("tg_stage") else s


def good_hex(h):
    return bool(h) and h != "UNAVAILABLE" and bool(HEX64.fullmatch(h))


# ── the per-job conclusions (from the CI needs/results JSON; the records
#    are the ACTUAL observed conclusions, never assumed) ─────────────────────
jobs = {}
if jobs_file and os.path.isfile(jobs_file):
    try:
        d = json.load(open(jobs_file, encoding="utf-8"))
        for name, rec in (d or {}).items():
            if isinstance(rec, dict):
                jobs[name] = str(rec.get("result") or rec.get("conclusion") or "unobserved")
            else:
                jobs[name] = str(rec)
    except Exception:
        jobs = {}

# ── the artifacts: every subdirectory of the evidence dir is one artifact;
#    the per-file sha-256 are read from the ACTUAL files ─────────────────────
artifacts = {}
artifact_hashes = []
if os.path.isdir(ev_dir):
    for name in sorted(os.listdir(ev_dir)):
        d = os.path.join(ev_dir, name)
        if not os.path.isdir(d):
            continue
        files = []
        for root, _dirs, fnames in os.walk(d):
            for fn in sorted(fnames):
                p = os.path.join(root, fn)
                files.append({"path": os.path.relpath(p, ev_dir),
                              "sha256": sha256_file(p)})
        files.sort(key=lambda f: f["path"])
        artifact_hashes.extend("%s  %s" % (f["sha256"], f["path"]) for f in files)
        artifacts[name] = {"present": bool(files), "files": files}

# ── the stage binaries: from the tg-stages-macos-arm64 artifact's ACTUAL
#    files ────────────────────────────────────────────────────────────────────
stage_files = artifacts.get("tg-stages-macos-arm64", {}).get("files", [])
stage_binaries = {}
for st in STAGES:
    rec = None
    for f in stage_files:
        if os.path.basename(f["path"]) in ("tg_%s" % st, st):
            rec = f
            break
    stage_binaries[st] = {
        "sha256": rec["sha256"] if rec else None,
        "artifact": "tg-stages-macos-arm64",
        "file": rec["path"] if rec else None,
    }


def fp_parse(artifact_name):
    lines = []
    for f in artifacts.get(artifact_name, {}).get("files", []):
        if not f["path"].endswith(".fingerprints"):
            continue
        try:
            for raw in open(os.path.join(ev_dir, f["path"]),
                            encoding="utf-8", errors="replace"):
                m = re.match(r"FINGERPRINT\s+(\S+)\s+(\S+)\s+(\S+)", raw.strip())
                if m:
                    lines.append((norm_stage(m.group(1)), m.group(2), m.group(3)))
        except OSError:
            pass
    return lines


def link_image_map(lines):
    out = {}
    for st, phase, h in lines:
        if phase == "link-image":
            out.setdefault(st, h)
    return out


def phase_hashes(lines):
    out = {}
    for st, phase, h in lines:
        if phase in PHASES:
            out.setdefault(phase, {})[st] = h
    return out


macos_fp = fp_parse("bootstrap-fingerprints")
linux_fp = fp_parse("linux-fingerprints")
link_image_macos = link_image_map(macos_fp)
link_image_linux = link_image_map(linux_fp)
phase_records = phase_hashes(macos_fp)

# ── the per-verdict proofs (the equality checks' ACTUAL results) ────────────
h2 = stage_binaries.get("stage2", {}).get("sha256")
h3 = stage_binaries.get("stage3", {}).get("sha256")
stage2_equals_stage3 = bool(good_hex(h2) and good_hex(h3) and h2 == h3)

l2 = link_image_linux.get("stage2")
l3 = link_image_linux.get("stage3")
linux_stage2_equals_stage3 = bool(good_hex(l2) and good_hex(l3) and l2 == l3)

phase_verdicts = {}
for ph in PHASES:
    rec = phase_records.get(ph) or {}
    a, b = rec.get("stage2"), rec.get("stage3")
    phase_verdicts[ph] = bool(good_hex(a) and good_hex(b) and a == b)
semantic_fingerprints_equal = all(phase_verdicts.values())

linux_stage_hashes = {st: link_image_linux.get(st) for st in STAGES}

# ── the native-lane outputs (the canary count + the lane conclusions) ───────
native_outputs = {
    "canary_count": len(artifacts.get("bootstrap-native-tests", {}).get("files", [])),
    "litmus": {"job": LITMUS_JOB, "conclusion": jobs.get(LITMUS_JOB, "unobserved")},
    "allocator": {"job": ALLOC_JOB, "conclusion": jobs.get(ALLOC_JOB, "unobserved")},
    "db": {"jobs": DB_JOBS, "conclusions": [jobs.get(j, "unobserved") for j in DB_JOBS]},
    "tls": {"job": TLS_JOB, "conclusion": jobs.get(TLS_JOB, "unobserved")},
}

doc = {
    "schema_version": int(os.environ["RELEASE_SCHEMA_VERSION"]),
    "tested_sha": sha,
    "timestamp_utc": stamp,
    "generated_by": "scripts/gen_status.sh --release-evidence (scripts/release_evidence_schema.sh)",
    "workflow": {
        "workflow": wf_name,
        "job": wf_job,
        "run_id": wf_run,
        "run_attempt": wf_attempt,
    },
    "jobs": {k: jobs[k] for k in sorted(jobs)},
    "artifacts": {k: artifacts[k] for k in sorted(artifacts)},
    "artifact_hashes": sorted(artifact_hashes),
    "stage_binaries": {k: stage_binaries[k] for k in STAGES},
    "linux_stage_hashes": {k: linux_stage_hashes[k] for k in STAGES},
    "fingerprints": {
        "bootstrap_link_image": link_image_macos,
        "linux_link_image": link_image_linux,
        "phases": phase_records,
    },
    "verdicts": {
        "stage2_equals_stage3": stage2_equals_stage3,
        "linux_stage2_equals_stage3": linux_stage2_equals_stage3,
        "semantic_fingerprints_equal": semantic_fingerprints_equal,
        "phases": phase_verdicts,
    },
    "native_outputs": native_outputs,
    "release_gated_features": gated.split(),
}

with open(outfile, "w", encoding="utf-8") as fh:
    json.dump(doc, fh, indent=2, sort_keys=True)
    fh.write("\n")
PY
}

# ────────────────────────────────────────────────────────────────────────────
# The fail-closed validator: validate_release_evidence <evidence-json>
# Prints one "violation: ..." line per problem and returns 0 when the
# evidence satisfies the schema EXACTLY, 1 otherwise. A missing required
# artifact, an extra unlisted artifact, a failed/skipped job, a mismatched
# hash, a missing fingerprint, an absent equality proof — every one is a
# violation; nothing is inferred.
# ────────────────────────────────────────────────────────────────────────────
validate_release_evidence() {
  RELEASE_SCHEMA_VERSION="$RELEASE_EVIDENCE_SCHEMA_VERSION" \
  RELEASE_SCHEMA_JOBS="${RELEASE_REQUIRED_JOBS[*]}" \
  RELEASE_SCHEMA_ARTIFACTS="${RELEASE_REQUIRED_ARTIFACTS[*]}" \
  RELEASE_SCHEMA_STAGES="${RELEASE_STAGE_BINARIES[*]}" \
  RELEASE_SCHEMA_PHASES="${RELEASE_SEMANTIC_PHASES[*]}" \
  RELEASE_SCHEMA_DB_JOBS="${RELEASE_NATIVE_DB_JOBS[*]}" \
  RELEASE_SCHEMA_LITMUS_JOB="$RELEASE_NATIVE_LITMUS_JOB" \
  RELEASE_SCHEMA_ALLOC_JOB="$RELEASE_NATIVE_ALLOCATOR_JOB" \
  RELEASE_SCHEMA_TLS_JOB="$RELEASE_NATIVE_TLS_JOB" \
  python3 - "$1" <<'PY'
import json, os, re, sys

path = sys.argv[1]
REQUIRED_JOBS = os.environ["RELEASE_SCHEMA_JOBS"].split()
REQUIRED_ARTIFACTS = os.environ["RELEASE_SCHEMA_ARTIFACTS"].split()
STAGES = os.environ["RELEASE_SCHEMA_STAGES"].split()
PHASES = os.environ["RELEASE_SCHEMA_PHASES"].split()
DB_JOBS = os.environ["RELEASE_SCHEMA_DB_JOBS"].split()
LITMUS_JOB = os.environ["RELEASE_SCHEMA_LITMUS_JOB"]
ALLOC_JOB = os.environ["RELEASE_SCHEMA_ALLOC_JOB"]
TLS_JOB = os.environ["RELEASE_SCHEMA_TLS_JOB"]
SCHEMA_VERSION = os.environ["RELEASE_SCHEMA_VERSION"]

HEX64 = re.compile(r"^[0-9a-f]{64}$")
violations = []


def bad(msg):
    violations.append(msg)


try:
    with open(path, encoding="utf-8") as fh:
        d = json.load(fh)
except Exception as e:
    print("violation: the evidence file is not readable JSON: %s" % e)
    sys.exit(1)
if not isinstance(d, dict):
    print("violation: the evidence file is not a JSON object")
    sys.exit(1)

if d.get("schema_version") != int(SCHEMA_VERSION):
    bad("schema_version mismatch: expected %s, recorded %r"
        % (SCHEMA_VERSION, d.get("schema_version")))

sha = d.get("tested_sha") or ""
if not re.fullmatch(r"[0-9a-f]{7,40}", sha):
    bad("tested_sha is missing or malformed (expected 7-40 hex chars)")

wf = d.get("workflow") or {}
if not isinstance(wf, dict) or not wf.get("workflow") or not wf.get("run_id"):
    bad("the workflow run identity is missing (workflow.workflow and workflow.run_id are required)")

jobs = d.get("jobs") or {}
for j in REQUIRED_JOBS:
    c = jobs.get(j)
    if c != "success":
        bad("required job '%s' conclusion is %r (required: success)" % (j, c))

artifacts = d.get("artifacts") or {}
for a in REQUIRED_ARTIFACTS:
    rec = artifacts.get(a)
    if not isinstance(rec, dict):
        bad("required artifact '%s' is not recorded" % a)
        continue
    files = rec.get("files") or []
    if not rec.get("present") or not files:
        bad("required artifact '%s' is recorded present=false or empty (the artifact directory is missing or empty)" % a)
    for f in files:
        if not isinstance(f, dict) or not f.get("path") or \
           not isinstance(f.get("sha256"), str) or not HEX64.fullmatch(f.get("sha256") or ""):
            bad("artifact '%s' has a file record without a valid sha-256: %r" % (a, f))
for a in artifacts:
    if a not in REQUIRED_ARTIFACTS:
        bad("unlisted artifact '%s' is recorded (the evidence must record exactly the required artifact set — an extra unlisted artifact fails the validation)" % a)

sb = d.get("stage_binaries") or {}
if not isinstance(sb, dict) or sorted(sb.keys()) != sorted(STAGES):
    bad("stage_binaries must record exactly %s" % ", ".join(STAGES))
for st in STAGES:
    h = (sb.get(st) or {}).get("sha256")
    if not isinstance(h, str) or not HEX64.fullmatch(h):
        bad("the %s binary hash is missing or malformed: %r" % (st, h))

stage_artifact_files = {}
for f in (artifacts.get("tg-stages-macos-arm64") or {}).get("files", []):
    b = os.path.basename(f.get("path") or "")
    if b.startswith("tg_stage") or b.startswith("stage"):
        stage_artifact_files[b] = f
for st in STAGES:
    f2 = None
    for k, f in stage_artifact_files.items():
        if k in ("tg_%s" % st, st):
            f2 = f
            break
    if f2 is None:
        bad("the %s binary file is missing from the tg-stages-macos-arm64 artifact record" % st)
    elif (sb.get(st) or {}).get("sha256") != f2.get("sha256"):
        bad("stage%s: the recorded binary hash does not match the artifact file hash" % st)
if "tg_stage2" in stage_artifact_files and "tg_stage3" in stage_artifact_files:
    if stage_artifact_files["tg_stage2"].get("sha256") != stage_artifact_files["tg_stage3"].get("sha256"):
        bad("the stage2/stage3 binaries are NOT byte-identical (their artifact file hashes differ)")
else:
    bad("the stage2/stage3 binary files are missing from the tg-stages-macos-arm64 artifact record")

ver = d.get("verdicts") or {}
if ver.get("stage2_equals_stage3") is not True:
    bad("the stage2 == stage3 equality proof is absent or false")
elif (sb.get("stage2") or {}).get("sha256") != (sb.get("stage3") or {}).get("sha256"):
    bad("stage2 and stage3 recorded hashes differ (the equality proof is contradicted)")

fp = d.get("fingerprints") or {}
bli = fp.get("bootstrap_link_image") or {}
if not isinstance(bli, dict):
    bad("fingerprints.bootstrap_link_image is missing")
for st in STAGES:
    li = bli.get(st)
    bh = (sb.get(st) or {}).get("sha256")
    if not isinstance(li, str) or not HEX64.fullmatch(li):
        bad("the bootstrap link-image fingerprint for %s is missing or malformed" % st)
    elif bh and li != bh:
        bad("stage%s: the bootstrap link-image fingerprint (%s) mismatches the recorded binary hash (%s)" % (st, li, bh))

phases_fp = fp.get("phases") or {}
if not isinstance(phases_fp, dict) or sorted(phases_fp.keys()) != sorted(PHASES):
    bad("fingerprints.phases must record exactly the semantic phases: %s" % ", ".join(PHASES))
phase_verdicts = ver.get("phases") or {}
if not isinstance(phase_verdicts, dict):
    bad("verdicts.phases is missing")
for ph in PHASES:
    rec = phases_fp.get(ph) or {}
    a, b = rec.get("stage2"), rec.get("stage3")
    if not isinstance(a, str) or not HEX64.fullmatch(a) or \
       not isinstance(b, str) or not HEX64.fullmatch(b):
        bad("the '%s' phase fingerprints are missing or malformed (stage2=%r stage3=%r)" % (ph, a, b))
    elif a != b:
        bad("the '%s' phase equality is NOT proven (stage2=%s stage3=%s)" % (ph, a, b))
    if phase_verdicts.get(ph) is not True:
        bad("the '%s' phase equality verdict is not true" % ph)
if ver.get("semantic_fingerprints_equal") is not True:
    bad("the semantic fingerprints' equality proof is absent or false")

lli = fp.get("linux_link_image") or {}
if not isinstance(lli, dict):
    bad("fingerprints.linux_link_image is missing")
for st in STAGES:
    h = lli.get(st)
    if not isinstance(h, str) or not HEX64.fullmatch(h):
        bad("the linux link-image fingerprint for %s is missing or malformed" % st)
l2, l3 = lli.get("stage2"), lli.get("stage3")
if isinstance(l2, str) and isinstance(l3, str) and l2 != l3:
    bad("the linux stage2/stage3 link-image hashes differ (the linux fixed point is NOT proven)")
if ver.get("linux_stage2_equals_stage3") is not True:
    bad("the linux stage2 == stage3 equality proof is absent or false")

no = d.get("native_outputs") or {}
if not isinstance(no, dict):
    bad("native_outputs is missing")
cc = no.get("canary_count")
if not isinstance(cc, int) or cc < 1:
    bad("the native canary count is %r (required: >= 1 executed canary outputs)" % cc)
for key, job, label in (("litmus", LITMUS_JOB, "the litmus"),
                        ("allocator", ALLOC_JOB, "the allocator"),
                        ("tls", TLS_JOB, "the TLS")):
    rec = no.get(key)
    if not isinstance(rec, dict) or rec.get("job") != job or \
       rec.get("conclusion") != "success" or jobs.get(job) != "success":
        bad("%s native-lane output is not proven (recorded: %r; the backing job conclusion: %r)"
            % (label, rec, jobs.get(job)))
db = no.get("db")
if not isinstance(db, dict) or list(db.get("jobs") or []) != DB_JOBS:
    bad("the db native-lane outputs must record the jobs %s" % ", ".join(DB_JOBS))
else:
    for j, c in zip(db.get("jobs") or [], db.get("conclusions") or []):
        if c != "success" or jobs.get(j) != "success":
            bad("the db native-lane output for job '%s' is not proven (recorded: %r; the backing job conclusion: %r)"
                % (j, c, jobs.get(j)))

for v in violations:
    print("violation: %s" % v)
sys.exit(1 if violations else 0)
PY
}

# ────────────────────────────────────────────────────────────────────────────
# The per-category verdicts: release_evidence_rows <evidence-json> <proof-sha>
# Emits four "NAME|STATE|detail" lines: EVIDENCE, R5 (the self-host fixed
# point), R6 (the cross-stage ladder), R7 (the native runs).
#   ABSENT          -> the categories PENDING-UNTIL-LADDER (no evidence)
#   STALE           -> the categories PENDING-UNTIL-LADDER (a matching SHA
#                      alone is never a proof)
#   INVALID         -> the categories FAIL (the evidence exists but fails
#                      the fail-closed schema validation)
#   VALID           -> the categories PASS (each category's PASS rests on
#                      its OWN recorded artifacts + conclusions)
# ────────────────────────────────────────────────────────────────────────────
release_evidence_rows() {
  local evidence="$1" sha="$2"
  if [ ! -f "$evidence" ]; then
    printf 'EVIDENCE|ABSENT|no release evidence at %s (written only by scripts/gen_status.sh --release-evidence from the tested SHA + the run artifacts)\n' "$evidence"
    printf 'R5|PENDING-UNTIL-LADDER|the self-host fixed point (stage2 == stage3) requires the ladder evidence — none exists at %s\n' "$evidence"
    printf 'R6|PENDING-UNTIL-LADDER|the cross-stage ladder (stage0 -> stage1 -> stage2 -> stage3) requires the ladder evidence — none exists at %s\n' "$evidence"
    printf 'R7|PENDING-UNTIL-LADDER|the native runs (canary/litmus/allocator/db/tls) require the ladder evidence — none exists at %s\n' "$evidence"
    return 0
  fi
  local esha
  esha="$(python3 - "$evidence" <<'PY'
import json, sys
try:
    print(json.load(open(sys.argv[1], encoding="utf-8")).get("tested_sha", ""))
except Exception:
    print("")
PY
)"
  if [ "$esha" != "$sha" ]; then
    printf 'EVIDENCE|STALE|the evidence tested_sha (%s) != the proof SHA (%s) — a matching SHA alone is never a proof; the evidence is stale for this snapshot\n' "${esha:-unknown}" "$sha"
    printf 'R5|PENDING-UNTIL-LADDER|the fixed-point evidence is stale (tested_sha %s != %s)\n' "${esha:-unknown}" "$sha"
    printf 'R6|PENDING-UNTIL-LADDER|the cross-stage-ladder evidence is stale (tested_sha %s != %s)\n' "${esha:-unknown}" "$sha"
    printf 'R7|PENDING-UNTIL-LADDER|the native-run evidence is stale (tested_sha %s != %s)\n' "${esha:-unknown}" "$sha"
    return 0
  fi
  local violations n v1
  violations="$(validate_release_evidence "$evidence")"
  if [ -n "$violations" ]; then
    n="$(printf '%s\n' "$violations" | grep -c . || true)"
    [ -n "$n" ] || n=0
    v1="$(printf '%s\n' "$violations" | head -1)"
    local rest
    rest=$((n - 1))
    [ "$rest" -lt 0 ] && rest=0
    printf 'EVIDENCE|INVALID|the evidence at %s is INVALID against the release-evidence schema (%s violation(s)): %s\n' "$evidence" "$n" "$v1"
    printf 'R5|FAIL|the fixed-point category is NOT PASS: %s (+%s more violation(s))\n' "$v1" "$rest"
    printf 'R6|FAIL|the cross-stage-ladder category is NOT PASS: %s (+%s more violation(s))\n' "$v1" "$rest"
    printf 'R7|FAIL|the native-run category is NOT PASS: %s (+%s more violation(s))\n' "$v1" "$rest"
    return 0
  fi
  # VALID: per-category PASS, each resting on its OWN recorded artifacts.
  local h2 canary litmus alloc db tls linux_eq fields
  fields="$(python3 - "$evidence" <<'PY'
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
sb = d["stage_binaries"]
no = d["native_outputs"]
print("h2=%s" % sb["stage2"]["sha256"])
print("canary=%d" % no["canary_count"])
print("litmus=%s" % no["litmus"]["conclusion"])
print("alloc=%s" % no["allocator"]["conclusion"])
print("db=%s" % "/".join(no["db"]["conclusions"]))
print("tls=%s" % no["tls"]["conclusion"])
print("linux_eq=%s" % ("true" if d["verdicts"]["linux_stage2_equals_stage3"] else "false"))
PY
)"
  while IFS= read -r line || [ -n "$line" ]; do
    eval "${line%%=*}=\"${line#*=}\""
  done <<< "$fields"
  printf 'EVIDENCE|VALID|the evidence at %s satisfies the release-evidence schema exactly (schema v%s; tested_sha %s)\n' "$evidence" "$RELEASE_EVIDENCE_SCHEMA_VERSION" "$sha"
  printf 'R5|PASS|the fixed-point proof: stage2 == stage3 byte-identical (sha256 %s); the semantic fingerprints (tokens/ast/hir/mir/mir-mono) equality proven\n' "${h2:-unknown}"
  printf 'R6|PASS|the cross-stage-ladder proof: stage1/stage2/stage3 binaries present with hashes; bootstrap + linux-x86-64-native success; the linux stage2 == stage3 link-image equality proven (%s)\n' "${linux_eq:-unknown}"
  printf 'R7|PASS|the native-run proof: %s executed canary output(s); litmus (%s), allocator (%s), db (%s), tls (%s) conclusions all success\n' "${canary:-0}" "${litmus:-unknown}" "${alloc:-unknown}" "${db:-unknown}" "${tls:-unknown}"
}
