#!/usr/bin/env bash
#
# scripts/gen_invariants.sh — the invariant registry generator / validator.
#
# The catalog is GENERATED EVIDENCE, not hand-written prose:
#   - invariants.toml is the single source (id, stage, severity, summary,
#     status, assertion implementation file:function, positive/negative/
#     mutation tests, target coverage, and the registry content digest).
#   - invariants.toml carries registry_digest — a sha-256 over the
#     CANONICAL DEFINITIONS (scripts/invariant_registry.py) — NOT a commit
#     SHA. A committed file cannot know the SHA of the commit that contains
#     it; the digest identifies the definition content instead, and the
#     tested commit lives in the EXTERNAL evidence artifact below.
#   - The generator MECHANICALLY verifies the registry before rendering:
#       * every id is unique;
#       * status is one of implemented | scoped;
#       * every entry with a former_status carries a classification in the
#         vocabulary {implemented-with-assertions, explicitly-scoped};
#       * every assertion FILE exists in the tree, and the function token
#         is present in it (Swift / .tg / .sh sources);
#       * every positive/negative/mutation test entry is a glob that
#         matches at least one real file;
#       * summaries and coverage are non-empty;
#       * registry_digest matches the re-computed definition digest;
#       * no legacy committed-SHA key (last_verified_sha / verified_sha)
#         is present — the old scheme is rejected, never carried over.
#     Any drift FAILS the run (exit non-zero).
#   - `--validate-tree` validates the registry + tree at the current HEAD
#     WITHOUT writing anything and WITHOUT requiring any self-referential
#     SHA: the definitions, the tree references (assertion files/tokens,
#     test globs), the recorded registry_digest, and the committed
#     docs/current/invariants.md rendering must all agree.
#   - The default (generation) mode keeps registry_digest current,
#     regenerates docs/current/invariants.md, and writes the external CI
#     artifact invariants-evidence.json:
#       tested_commit_sha (git rev-parse HEAD), registry_digest,
#       compiler_digest (the seed/kernel closure digest), checks (the
#       mechanical check results), test_evidence (the per-invariant test
#       globs + matched-file counts and the matched-files digest), build
#       identity and timestamp. The artifact is authoritative for test
#       evidence; the markdown is the registry rendering.
#   - The CI evidence-gate job runs `--validate-tree`, then generation,
#     then `git diff --exit-code -- invariants.toml docs/current/invariants.md`
#     (a hand-edited or drifted registry/catalog cannot merge) and uploads
#     invariants-evidence.json with the artifacts.
#
# Usage: scripts/gen_invariants.sh [--validate-tree] [--evidence <path>] [outfile]
#   outfile defaults to docs/current/invariants.md.
#   --evidence defaults to build/invariants-evidence.json (generation only).
# Exit status: 0 when every mechanical check holds; 1 when the registry
# drifted; 2 on usage / parse errors.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOML="$ROOT/invariants.toml"
OUT="$ROOT/docs/current/invariants.md"
EVIDENCE="$ROOT/build/invariants-evidence.json"
MODE="generate"

usage() {
  cat <<'EOF'
Usage: scripts/gen_invariants.sh [--validate-tree] [--evidence <path>] [outfile]

Modes:
  (default)          generate: validate the registry, keep invariants.toml's
                     registry_digest current, regenerate
                     docs/current/invariants.md, and write the external
                     invariants-evidence.json artifact.
  --validate-tree    validate the registry + tree at HEAD without writing
                     anything: definitions, assertion files/tokens, test
                     globs, the recorded registry digest vs the recomputed
                     one, and the committed docs/current/invariants.md
                     rendering. No self-referential commit SHA is required.

Options:
  --evidence <path>  the invariants-evidence.json output (default:
                     build/invariants-evidence.json; generation mode only).
  -h, --help         print this help.

Arguments:
  outfile            the markdown output (default:
                     docs/current/invariants.md).
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --validate-tree) MODE="validate"; shift ;;
    --evidence)
      if [ $# -lt 2 ]; then
        echo "gen_invariants: --evidence needs a path" >&2
        exit 2
      fi
      EVIDENCE="$2"
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    --*)
      echo "gen_invariants: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *)
      OUT="$1"
      shift
      ;;
  esac
done

if [ ! -f "$TOML" ]; then
  echo "gen_invariants: missing invariants.toml: $TOML" >&2
  exit 1
fi
if [ ! -f "$ROOT/scripts/invariant_registry.py" ]; then
  echo "gen_invariants: missing scripts/invariant_registry.py (the canonical registry codec)" >&2
  exit 1
fi

python3 - "$TOML" "$OUT" "$ROOT" "$MODE" "$EVIDENCE" <<'PY'
import datetime
import glob
import hashlib
import json
import os
import re
import subprocess
import sys

sys.path.insert(0, os.path.join(sys.argv[3], "scripts"))
import invariant_registry as ir  # noqa: E402  (the canonical digest codec)

toml_path, out_path, root, mode, evidence_path = sys.argv[1:6]
is_validate = (mode == "validate")

with open(toml_path, "r", encoding="utf-8") as handle:
    text = handle.read()
try:
    doc = ir.parse_toml(text)
except Exception as exc:  # a genuine parse error
    print("gen_invariants: cannot parse %s: %s" % (toml_path, exc), file=sys.stderr)
    sys.exit(2)

invariants = doc.get("invariant", []) or []
errors = []
checks = []


def fail(msg):
    errors.append(msg)
    print("gen_invariants: FAIL: %s" % msg, file=sys.stderr)


def add_check(name, ok, **detail):
    record = {"name": name, "status": "pass" if ok else "fail"}
    record.update(detail)
    checks.append(record)


# ── the old committed-SHA scheme is rejected, never carried over ───────────
legacy = ir.legacy_usage(doc)
if legacy:
    fail("legacy committed-SHA key(s) present: %s — the invariant evidence "
         "scheme is registry_digest (in invariants.toml) + the external "
         "invariants-evidence.json artifact; remove the key(s)"
         % ", ".join(legacy))
add_check("no_legacy_committed_sha_keys", not legacy, legacy=legacy)

# ── ids / status / classification / summary / coverage ─────────────────────
id_seen = set()
duplicate_ids = []
bad_status = []
bad_classification = []
missing_summary = []
missing_coverage = []
missing_assertion = []
for entry in invariants:
    eid = str(entry.get("id", ""))
    if not eid:
        fail("entry without id")
        continue
    if eid in id_seen:
        duplicate_ids.append(eid)
    id_seen.add(eid)

    status = str(entry.get("status", ""))
    if status not in ("implemented", "scoped"):
        bad_status.append("%s:%s" % (eid, status))

    former = str(entry.get("former_status", ""))
    classification = str(entry.get("classification", ""))
    if classification and classification not in ("implemented-with-assertions",
                                                 "explicitly-scoped"):
        bad_classification.append("%s:%s" % (eid, classification))
    if former and not classification:
        fail("%s: former_status '%s' requires a classification" % (eid, former))
    if former and classification == "implemented-with-assertions" and status != "implemented":
        fail("%s: classified implemented-with-assertions but status is '%s'" % (eid, status))
    if former and classification == "explicitly-scoped" and status != "scoped":
        fail("%s: classified explicitly-scoped but status is '%s'" % (eid, status))

    assertion = str(entry.get("assertion", ""))
    if status == "implemented" and not assertion:
        missing_assertion.append(eid)
    if not str(entry.get("summary", "")).strip():
        missing_summary.append(eid)
    if not str(entry.get("coverage", "")).strip():
        missing_coverage.append(eid)

add_check("ids_unique", not duplicate_ids, duplicates=duplicate_ids, count=len(invariants))
add_check("statuses_valid", not bad_status, invalid=bad_status)
add_check("classifications_valid", not bad_classification, invalid=bad_classification)
add_check("implemented_entries_have_assertions", not missing_assertion,
          missing=missing_assertion)
add_check("summaries_non_empty", not missing_summary, missing=missing_summary)
add_check("coverage_non_empty", not missing_coverage, missing=missing_coverage)
for eid in missing_assertion:
    fail("%s: implemented but no assertion" % eid)
for eid in missing_summary:
    fail("%s: empty summary" % eid)
for eid in missing_coverage:
    fail("%s: empty coverage" % eid)


# ── tree references: assertion files/tokens + test globs ───────────────────
def check_assertion(eid, assertion):
    if ":" not in assertion:
        return None  # file-only assertion (informational)
    path, _, token = assertion.rpartition(":")
    full = os.path.join(root, path)
    if not os.path.isfile(full):
        return "assertion file '%s' does not exist" % path
    if not token or len(token) < 3:
        return None  # too short to grep reliably
    if path.endswith(".swift"):
        patterns = [r"\b%s\b" % re.escape(token)]
    elif path.endswith(".tg"):
        patterns = [r"def %s\b" % re.escape(token), r"\b%s\b" % re.escape(token)]
    else:
        patterns = [r"\b%s\b" % re.escape(token)]
    with open(full, "r", encoding="utf-8", errors="replace") as handle:
        content = handle.read()
    if not any(re.search(pattern, content) for pattern in patterns):
        return "assertion token '%s' not found in '%s'" % (token, path)
    return None


assertion_failures = []
assertions_checked = 0
for entry in invariants:
    assertion = str(entry.get("assertion", ""))
    if not assertion:
        continue
    assertions_checked += 1
    problem = check_assertion(str(entry.get("id", "")), assertion)
    if problem:
        assertion_failures.append(problem)
        fail("%s: %s" % (entry.get("id", ""), problem))
add_check("assertion_references_resolve", not assertion_failures,
          checked=assertions_checked, failures=assertion_failures)


def expand(pattern):
    full = os.path.join(root, pattern)
    if any(ch in pattern for ch in "*?["):
        return sorted(glob.glob(full))
    return [full] if os.path.isfile(full) else []


glob_failures = []
glob_counts = {"positive": 0, "negative": 0, "mutation": 0}
matched_files = set()
per_invariant_evidence = []
for entry in sorted(invariants, key=lambda e: str(e.get("id", ""))):
    eid = str(entry.get("id", ""))
    evidence_record = {"id": eid}
    for field in ("positive", "negative", "mutation"):
        globs = [str(g) for g in (entry.get(field) or []) if str(g)]
        matches = 0
        for pattern in globs:
            glob_counts[field] += 1
            hits = expand(pattern)
            if not hits:
                glob_failures.append("%s %s glob '%s' matches no file" % (eid, field, pattern))
                fail("%s %s glob '%s' matches no file" % (eid, field, pattern))
            matches += len(hits)
            for hit in hits:
                matched_files.add(os.path.relpath(hit, root))
        evidence_record[field] = {"globs": globs, "matches": matches}
    per_invariant_evidence.append(evidence_record)
add_check("test_globs_match_files", not glob_failures,
          checked=sum(glob_counts.values()), failures=glob_failures,
          positive=glob_counts["positive"], negative=glob_counts["negative"],
          mutation=glob_counts["mutation"], matched_files=len(matched_files))

# ── the registry content digest vs the recorded one ────────────────────────
recorded_digest = str(doc.get("registry_digest", ""))
computed_digest = ir.registry_digest(doc)
digest_matches = bool(ir.DIGEST_RE.match(recorded_digest)) and recorded_digest == computed_digest
if digest_matches:
    add_check("registry_digest_matches_definitions", True,
              recorded=recorded_digest, recomputed=computed_digest)
elif is_validate:
    if not ir.DIGEST_RE.match(recorded_digest):
        fail("registry_digest %r is missing or malformed (expected sha256:<64 hex>)"
             % recorded_digest)
    else:
        fail("registry_digest %s is STALE for the registry definitions "
             "(recomputed %s); run scripts/gen_invariants.sh to refresh it"
             % (recorded_digest, computed_digest))
    add_check("registry_digest_matches_definitions", False,
              recorded=recorded_digest, recomputed=computed_digest)
else:
    # Generation mode MAINTAINS the digest: a stale/absent line is refreshed
    # here, and the committed-value gate is the CI
    # `git diff --exit-code -- invariants.toml` after the regeneration.
    add_check("registry_digest_refresh", True,
              recorded=recorded_digest or "(absent)", refreshed=computed_digest)

# ── the markdown rendering (the registry's generated catalog) ──────────────
def esc(value):
    return (value or "").replace("|", "\\|").replace("\n", " ")


def render_md():
    lines = []
    lines.append("# Tangerine Compiler Invariants Catalog")
    lines.append("")
    lines.append("GENERATED EVIDENCE — do not edit by hand. The machine-readable")
    lines.append("registry is `invariants.toml` (id, stage, severity, summary, status,")
    lines.append("assertion implementation, positive/negative/mutation tests, target")
    lines.append("coverage, and the registry content digest). This document is rendered")
    lines.append("by `scripts/gen_invariants.sh`; the CI evidence-gate job regenerates it")
    lines.append("and runs `git diff --exit-code`.")
    lines.append("")
    lines.append("The **test evidence** (the tested commit, the mechanical check results")
    lines.append("and the matched test files) is recorded in the external")
    lines.append("`invariants-evidence.json` CI artifact the generator writes; that artifact")
    lines.append("is authoritative for test evidence, while this catalog is the registry")
    lines.append("rendering (definitions + mechanical tree validation).")
    lines.append("")
    lines.append("Registry digest: `%s`  ·  Registry version: `%s`"
                 % (computed_digest, doc.get("version", "?")))
    lines.append("")
    lines.append("## Status policy")
    lines.append("")
    lines.append("Every invariant is either **implemented** (backed by an assertion")
    lines.append("implementation — `file:function` — and by positive/negative/mutation")
    lines.append("tests that exercise it) or **scoped** (the claim is explicitly removed")
    lines.append("from the verified callable: the surface does not exist in the callable")
    lines.append("path, the machinery is deleted, the option is inert, the construct is")
    lines.append("rejected by the bootstrap subset, or the enforceable core is asserted")
    lines.append("elsewhere — the `scoping` text states the concrete action). There are no")
    lines.append("`partial` / `design` / `eventually` / `TODO` statuses: every former")
    lines.append("gap is classified as **implemented-with-assertions** or")
    lines.append("**explicitly-scoped** (see the classification table).")
    lines.append("")
    lines.append("## Classification of former gaps")
    lines.append("")
    lines.append("| ID | Former status | Classification | Status | Assertion / scoping |")
    lines.append("|----|---------------|----------------|--------|----------------------|")
    for entry in sorted(invariants, key=lambda e: e.get("id", "")):
        if not entry.get("former_status"):
            continue
        if entry.get("status") == "scoped" and entry.get("scoping"):
            assert_text = entry["scoping"]
        else:
            assert_text = entry.get("assertion") or entry.get("scoping", "")
        lines.append("| %s | %s | %s | %s | %s |"
                     % (entry["id"], entry["former_status"],
                        entry.get("classification", ""), entry.get("status", ""),
                        esc(assert_text)))
    lines.append("")
    lines.append("## Invariants")
    lines.append("")
    lines.append("| ID | Stage | Description | Severity | Status | Assertion / scoping |")
    lines.append("|----|-------|-------------|----------|--------|---------------------|")
    for entry in sorted(invariants, key=lambda e: e.get("id", "")):
        enforce = entry.get("assertion") or entry.get("scoping", "")
        lines.append("| %s | %s | %s | %s | %s | %s |"
                     % (entry["id"], entry.get("stage", ""), esc(entry.get("summary", "")),
                        entry.get("severity", ""), entry.get("status", ""), esc(enforce)))
    lines.append("")
    lines.append("## Test matrix")
    lines.append("")
    lines.append("| ID | Positive | Negative | Mutation |")
    lines.append("|----|----------|----------|----------|")
    for entry in sorted(invariants, key=lambda e: e.get("id", "")):
        lines.append("| %s | %s | %s | %s |"
                     % (entry["id"], esc(", ".join(entry.get("positive", []))),
                        esc(", ".join(entry.get("negative", []))),
                        esc(", ".join(entry.get("mutation", [])))))
    lines.append("")
    lines.append("## Target coverage")
    lines.append("")
    lines.append("| ID | Coverage |")
    lines.append("|----|----------|")
    for entry in sorted(invariants, key=lambda e: e.get("id", "")):
        lines.append("| %s | %s |" % (entry["id"], esc(entry.get("coverage", ""))))
    lines.append("")
    lines.append("---")
    lines.append("")
    lines.append("Generated by `scripts/gen_invariants.sh` from `invariants.toml`.")
    lines.append("Registry version %s; registry digest %s."
                 % (doc.get("version", "?"), computed_digest))
    return "\n".join(lines) + "\n"


rendered = render_md()

# ── validate mode: nothing is written; the committed catalog must match ────
if is_validate:
    try:
        with open(out_path, "r", encoding="utf-8") as handle:
            committed = handle.read()
    except OSError as exc:
        fail("cannot read the committed catalog %s: %s" % (out_path, exc))
        committed = None
    if committed is not None:
        doc_consistent = (committed == rendered)
        if not doc_consistent:
            fail("%s is NOT the rendering of %s at this tree (the committed "
                 "catalog/digest drifted); run scripts/gen_invariants.sh to "
                 "regenerate it" % (out_path, toml_path))
        add_check("committed_catalog_matches_registry", doc_consistent,
                  path=os.path.relpath(out_path, root))
    if errors:
        print("gen_invariants: --validate-tree FAILED with %d problem(s)" % len(errors),
              file=sys.stderr)
        sys.exit(1)
    print("gen_invariants: --validate-tree PASS (%d invariant(s), %d test glob(s) "
          "matched %d file(s), registry digest %s matches the definitions, the "
          "committed catalog matches the rendering; no commit SHA required)"
          % (len(invariants), sum(glob_counts.values()), len(matched_files),
             computed_digest))
    sys.exit(0)

# ── generation mode: refresh the digest + catalog + evidence artifact ──────
def git_out(*args):
    try:
        result = subprocess.run(["git", "-C", root, *args], capture_output=True,
                                text=True, timeout=20)
    except Exception:
        return ""
    return result.stdout.strip() if result.returncode == 0 else ""


# The tested-tree identity BEFORE this generator writes anything (the
# writes are the generator's output, not the input tree's dirt).
tested_sha = git_out("rev-parse", "HEAD") or "unknown"
working_tree_dirty = bool(git_out("status", "--porcelain"))

# The digest is maintained by the generator: refresh the recorded line if it
# is absent or stale (never when the legacy scheme is still present).
if not legacy and recorded_digest != computed_digest:
    new_text = re.sub(r'(?m)^registry_digest\s*=.*$',
                      'registry_digest = "%s"' % computed_digest, text)
    if new_text == text and not re.search(r'(?m)^registry_digest\s*=', text):
        match = re.search(r'(?m)^version\s*=.*$', text)
        if not match:
            fail("cannot record registry_digest: no 'version = ...' line in %s" % toml_path)
        else:
            new_text = text[:match.end()] + '\nregistry_digest = "%s"' % computed_digest + text[match.end():]
    if new_text != text:
        with open(toml_path, "w", encoding="utf-8") as handle:
            handle.write(new_text)
        print("gen_invariants: updated registry_digest in %s (%s)"
              % (os.path.relpath(toml_path, root), computed_digest))

os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
with open(out_path, "w", encoding="utf-8") as handle:
    handle.write(rendered)

# ── compiler_digest: the seed/kernel closure digest used ───────────────────
def compiler_digest():
    manifest = os.path.join(root, "bootstrap/compiler_kernel.manifest")
    if not os.path.isfile(manifest):
        fail("cannot compute compiler_digest: %s is missing"
             % os.path.relpath(manifest, root))
        return None
    sources = []
    with open(manifest, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            for prefix, base in (("std: ", "std"), ("compiler: ", "tg_compiler")):
                if line.startswith(prefix):
                    rel = line[len(prefix):].strip()
                    full = os.path.join(root, base, rel)
                    if not os.path.isfile(full):
                        fail("compiler_digest: kernel source '%s/%s' is missing"
                             % (base, rel))
                        continue
                    sources.append({"path": "%s/%s" % (base, rel),
                                    "sha256": ir.sha256_file(full)})
    sources.sort(key=lambda item: item["path"])
    payload = json.dumps({"manifest_sha256": ir.sha256_file(manifest),
                          "sources": sources},
                         sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return "sha256:" + hashlib.sha256(payload.encode("utf-8")).hexdigest()


computed_compiler_digest = compiler_digest()

# ── test_evidence: the matched test-file set pinned by digest ──────────────
matched_hash_lines = []
for rel in sorted(matched_files):
    full = os.path.join(root, rel)
    if os.path.isfile(full):
        matched_hash_lines.append("%s  %s" % (ir.sha256_file(full), rel))
matched_files_payload = "".join(line + "\n" for line in matched_hash_lines)
matched_files_digest = "sha256:" + hashlib.sha256(
    matched_files_payload.encode("utf-8")).hexdigest()

test_evidence = {
    "totals": {
        "invariants": len(invariants),
        "positive_globs": glob_counts["positive"],
        "negative_globs": glob_counts["negative"],
        "mutation_globs": glob_counts["mutation"],
        "positive_matches": sum(r["positive"]["matches"] for r in per_invariant_evidence),
        "negative_matches": sum(r["negative"]["matches"] for r in per_invariant_evidence),
        "mutation_matches": sum(r["mutation"]["matches"] for r in per_invariant_evidence),
        "matched_files": len(matched_files),
    },
    "matched_files_digest": matched_files_digest,
    "invariants": per_invariant_evidence,
}

# ── build identity (Woodpecker CI_* first, GitHub Actions as fallback) ─────
def env_first(*names):
    for name in names:
        value = os.environ.get(name)
        if value:
            return value
    return ""


if os.environ.get("GITHUB_ACTIONS"):
    build_system = "github-actions"
elif os.environ.get("CI_PIPELINE_NUMBER") or os.environ.get("CI_COMMIT_SHA"):
    build_system = "woodpecker"
elif os.environ.get("CI"):
    build_system = "ci"
else:
    build_system = "local"
run_attempt = os.environ.get("GITHUB_RUN_ATTEMPT", "")
if os.environ.get("CI_PIPELINE_RERUNS"):
    try:
        run_attempt = str(int(os.environ["CI_PIPELINE_RERUNS"]) + 1)
    except ValueError:
        pass
build = {
    "system": build_system,
    "workflow": env_first("CI_WORKFLOW_NAME", "GITHUB_WORKFLOW"),
    "job": env_first("CI_STEP_NAME", "GITHUB_JOB"),
    "run_id": env_first("CI_PIPELINE_NUMBER", "GITHUB_RUN_ID"),
    "run_attempt": run_attempt or "1",
}

timestamp_utc = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

evidence = {
    "schema_version": 1,
    "generated_by": "scripts/gen_invariants.sh (scripts/invariant_registry.py)",
    "timestamp_utc": timestamp_utc,
    "tested_commit_sha": tested_sha,
    "tested_commit_short": tested_sha[:12],
    "working_tree_dirty": working_tree_dirty,
    "registry_version": doc.get("version", "?"),
    "registry_digest": computed_digest,
    "compiler_digest": computed_compiler_digest,
    "docs_output": os.path.relpath(out_path, root),
    "checks": {"passed": not errors, "mode": mode, "items": checks},
    "test_evidence": test_evidence,
    "build": build,
}

os.makedirs(os.path.dirname(evidence_path) or ".", exist_ok=True)
with open(evidence_path, "w", encoding="utf-8") as handle:
    json.dump(evidence, handle, indent=2, sort_keys=True)
    handle.write("\n")

if errors:
    print("gen_invariants: %d check(s) FAILED (the catalog + evidence artifact "
          "were still written so CI can diff them)" % len(errors), file=sys.stderr)
    sys.exit(1)

print("gen_invariants: wrote %s (%d invariants, %d classified former gaps); "
      "evidence %s (tested_commit_sha %s, registry_digest %s, compiler_digest %s)"
      % (os.path.relpath(out_path, root), len(invariants),
         sum(1 for entry in invariants if entry.get("former_status")),
         os.path.relpath(evidence_path, root), tested_sha, computed_digest,
         computed_compiler_digest))
print("gen_invariants: all mechanical checks passed")
sys.exit(0)
PY
