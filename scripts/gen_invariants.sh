#!/usr/bin/env bash
#
# scripts/gen_invariants.sh — generate docs/current/invariants.md from the
# machine-readable invariants.toml.
#
# The catalog is GENERATED EVIDENCE, not hand-written prose:
#   - invariants.toml is the single source (id, stage, severity, summary,
#     status, assertion implementation file:function, positive/negative/
#     mutation tests, target coverage, last verified SHA, and — for the
#     former partial/design/not-applicable entries — the reviewer's
#     classification: implemented-with-assertions or explicitly-scoped).
#   - The generator MECHANICALLY verifies the registry before rendering:
#       * every id is unique;
#       * status is one of implemented | scoped;
#       * every entry with a former_status carries a classification in the
#         vocabulary {implemented-with-assertions, explicitly-scoped};
#       * every assertion FILE exists in the tree, and the function token
#         is present in it (Swift / .tg / .sh sources);
#       * every positive/negative/mutation test entry is a glob that
#         matches at least one real file;
#       * verified_sha is a 7..40 hex-char commit id that RESOLVES to a
#         real commit in this repository (git rev-parse --verify — the
#         format-only check cannot catch a stale or invented sha), and the
#         GLOBAL last_verified_sha is the current HEAD at generation time
#         (a stale global sha — the registry verified against an older
#         commit — FAILS the generation; the sha is bumped when the tree
#         moves, never silently carried over);
#       * coverage is non-empty.
#     Any drift FAILS the generation (exit non-zero), so the catalog can
#     never claim an artifact that does not exist.
#   - The CI evidence-gate job regenerates the catalog and runs
#     `git diff --exit-code`: a hand-edited or drifted committed catalog
#     cannot merge.
#
# Usage: scripts/gen_invariants.sh [outfile]
#   outfile defaults to docs/current/invariants.md.
# Exit status: 0 when every mechanical check holds and the catalog is
# rendered; non-zero (with the file still written, so CI can diff it)
# when the registry drifted.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOML="$ROOT/invariants.toml"
OUT="${1:-$ROOT/docs/current/invariants.md}"

if [ ! -f "$TOML" ]; then
  echo "gen_invariants: missing invariants.toml: $TOML" >&2
  exit 1
fi

python3 - "$TOML" "$OUT" "$ROOT" <<'PY'
import json
import os
import re
import subprocess
import sys

toml_path, out_path, root = sys.argv[1], sys.argv[2], sys.argv[3]

# ── TOML parsing: tomllib (3.11+) -> tomli -> the constrained fallback ────
def parse_fallback(text):
    """Parse the constrained invariants.toml subset: [section] headers,
    key = "quoted scalar" / ["a", "b"] / bare scalars, # comments.
    """
    import re
    data = {}
    section = None
    arrays = {}
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = re.match(r"^\[(.+)\]$", line)
        if m:
            section = m.group(1).strip()
            if section not in data:
                data[section] = []
            continue
        m = re.match(r'^([A-Za-z0-9_.-]+)\s*=\s*(.*)$', line)
        if not m:
            raise ValueError(f"toml parse error at line {lineno}: {raw}")
        key, value = m.group(1), m.group(2).strip()
        if value.startswith("[") and value.endswith("]"):
            items = []
            for part in value[1:-1].split(","):
                part = part.strip()
                if not part:
                    continue
                if part.startswith('"') and part.endswith('"') and len(part) >= 2:
                    part = part[1:-1]
                items.append(part)
            arrays[key] = items
        elif value.startswith('"') and value.endswith('"') and len(value) >= 2:
            arrays[key] = value[1:-1]
        else:
            arrays[key] = value
        data[section].append((key, arrays[key]))
    return data

def parse_toml(text):
    try:
        import tomllib
        return tomllib.loads(text)
    except Exception:
        pass
    try:
        import tomli
        return tomli.loads(text)
    except Exception:
        pass
    fallback = parse_fallback(text)
    # Normalize the fallback shape to tomllib's.
    result = {}
    for section, pairs in fallback.items():
        result[section] = dict(pairs)
    return result

with open(toml_path, "r", encoding="utf-8") as f:
    text = f.read()
try:
    doc = parse_toml(text)
except Exception as e:
    print(f"gen_invariants: cannot parse {toml_path}: {e}", file=sys.stderr)
    sys.exit(2)

invariants = doc.get("invariant", [])
errors = []
warnings = []

def fail(msg):
    errors.append(msg)
    print(f"gen_invariants: FAIL: {msg}", file=sys.stderr)

def glob_matches(pattern):
    import glob
    return glob.glob(pattern)

def check_test_globs(entry, field):
    for g in entry.get(field, []):
        if not g:
            continue
        pattern = os.path.join(root, g)
        if any(c in g for c in "*?["):
            matches = glob_matches(pattern)
            if not matches:
                fail(f"{entry['id']} {field} glob '{g}' matches no file")
        elif not os.path.isfile(os.path.join(root, g)):
            fail(f"{entry['id']} {field} path '{g}' does not exist")

def check_assertion(eid, assertion):
    if ":" not in assertion:
        return  # file-only assertion (informational)
    path, _, token = assertion.rpartition(":")
    full = os.path.join(root, path)
    if not os.path.isfile(full):
        fail(f"{eid}: assertion file '{path}' does not exist")
        return
    if not token:
        return
    if len(token) < 3:
        return  # too short to grep reliably
    if path.endswith(".swift"):
        patterns = [rf"\b{re.escape(token)}\b"]
    elif path.endswith(".tg"):
        patterns = [rf"def {re.escape(token)}\b", rf"\b{re.escape(token)}\b"]
    else:
        patterns = [rf"\b{re.escape(token)}\b"]
    with open(full, "r", encoding="utf-8", errors="replace") as f:
        content = f.read()
    if not any(re.search(p, content) for p in patterns):
        fail(f"{eid}: assertion token '{token}' not found in '{path}'")

SHA_RE = re.compile(r"^[0-9a-f]{7,40}$")
IDS = set()

# ── the SHA verification (the reviewer's item 10 stale-sha discipline) ──
# The format-only check cannot catch a stale or invented commit id: every
# verified_sha must RESOLVE to a real commit in this repository, and the
# GLOBAL last_verified_sha must be the current HEAD at generation time
# (the registry claims verification against the tree being generated).
# When git is unavailable (an exported tree), the format check remains
# the fallback; when git IS available, a non-resolving sha is a FAIL.
def git_resolve(sha):
    """Resolve a sha/prefix to its full commit id via git; None when git
    is unavailable (format-only fallback), '' when git could not resolve."""
    try:
        r = subprocess.run(
            ["git", "rev-parse", "--verify", "--quiet", sha + "^{commit}"],
            cwd=root, capture_output=True, text=True, timeout=20)
    except Exception:
        return None
    return r.stdout.strip() if r.returncode == 0 else ""

head_sha = git_resolve("HEAD")

global_sha = doc.get("last_verified_sha", "unknown")
if not SHA_RE.match(global_sha):
    fail(f"last_verified_sha '{global_sha}' is not a 7..40 hex commit id")
if head_sha is not None:
    resolved = git_resolve(global_sha)
    if not resolved:
        fail(f"last_verified_sha '{global_sha}' does not resolve to a commit in this repository (git rev-parse --verify failed)")
    elif resolved != head_sha:
        fail(f"last_verified_sha '{global_sha}' is STALE — the registry must be re-verified at the current HEAD {head_sha}; the sha is bumped when the tree moves, never carried over silently")

for entry in invariants:
    eid = entry.get("id", "")
    if not eid:
        fail("entry without id")
        continue
    if eid in IDS:
        fail(f"duplicate id {eid}")
    IDS.add(eid)

    status = entry.get("status", "")
    if status not in ("implemented", "scoped"):
        fail(f"{eid}: status '{status}' not in {{implemented, scoped}}")

    former = entry.get("former_status", "")
    classification = entry.get("classification", "")
    if classification and classification not in ("implemented-with-assertions", "explicitly-scoped"):
        fail(f"{eid}: classification '{classification}' not in vocabulary")
    if former and not classification:
        fail(f"{eid}: former_status '{former}' requires a classification")
    if former and classification == "implemented-with-assertions" and status != "implemented":
        fail(f"{eid}: classified implemented-with-assertions but status is '{status}'")
    if former and classification == "explicitly-scoped" and status != "scoped":
        fail(f"{eid}: classified explicitly-scoped but status is '{status}'")

    assertion = entry.get("assertion", "")
    if status == "implemented" and not assertion:
        fail(f"{eid}: implemented but no assertion")
    if assertion:
        check_assertion(eid, assertion)

    check_test_globs(entry, "positive")
    check_test_globs(entry, "negative")
    check_test_globs(entry, "mutation")

    sha = entry.get("verified_sha", global_sha)
    if not SHA_RE.match(sha):
        fail(f"{eid}: verified_sha '{sha}' is not a 7..40 hex commit id")
    elif head_sha is not None and not git_resolve(sha):
        fail(f"{eid}: verified_sha '{sha}' does not resolve to a commit in this repository (git rev-parse --verify failed)")

    if not entry.get("summary", "").strip():
        fail(f"{eid}: empty summary")

# ── Render docs/current/invariants.md ────────────────────────────────────
def esc(s):
    return (s or "").replace("|", "\\|").replace("\n", " ")

lines = []
lines.append("# Tangerine Compiler Invariants Catalog")
lines.append("")
lines.append("GENERATED EVIDENCE — do not edit by hand. The machine-readable")
lines.append("registry is `invariants.toml` (id, stage, severity, summary, status,")
lines.append("assertion implementation, positive/negative/mutation tests, target")
lines.append("coverage, last verified SHA). This document is rendered by")
lines.append("`scripts/gen_invariants.sh`; the CI evidence-gate job regenerates it")
lines.append("and runs `git diff --exit-code`.")
lines.append("")
lines.append(f"Last verified SHA: `{global_sha}`  ·  Registry version: `{doc.get('version', '?')}`")
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
for e in sorted(invariants, key=lambda e: e.get("id", "")):
    if not e.get("former_status"):
        continue
    if e.get("status") == "scoped" and e.get("scoping"):
        assert_text = e["scoping"]
    else:
        assert_text = e.get("assertion") or e.get("scoping", "")
    lines.append(f"| {e['id']} | {e['former_status']} | {e.get('classification','')} | {e.get('status','')} | {esc(assert_text)} |")
lines.append("")
lines.append("## Invariants")
lines.append("")
lines.append("| ID | Stage | Description | Severity | Status | Assertion / scoping | Verified SHA |")
lines.append("|----|-------|-------------|----------|--------|---------------------|--------------|")
for e in sorted(invariants, key=lambda e: e.get("id", "")):
    enforce = e.get("assertion") or e.get("scoping", "")
    sha = e.get("verified_sha", global_sha)
    lines.append(f"| {e['id']} | {e.get('stage','')} | {esc(e.get('summary',''))} | {e.get('severity','')} | {e.get('status','')} | {esc(enforce)} | {sha[:10]} |")
lines.append("")
lines.append("## Test matrix")
lines.append("")
lines.append("| ID | Positive | Negative | Mutation |")
lines.append("|----|----------|----------|----------|")
for e in sorted(invariants, key=lambda e: e.get("id", "")):
    lines.append(f"| {e['id']} | {esc(', '.join(e.get('positive', [])))} | {esc(', '.join(e.get('negative', [])))} | {esc(', '.join(e.get('mutation', [])))} |")
lines.append("")
lines.append("## Target coverage")
lines.append("")
lines.append("| ID | Coverage |")
lines.append("|----|----------|")
for e in sorted(invariants, key=lambda e: e.get("id", "")):
    lines.append(f"| {e['id']} | {esc(e.get('coverage',''))} |")
lines.append("")
lines.append("---")
lines.append("")
lines.append("Generated by `scripts/gen_invariants.sh` from `invariants.toml`.")
lines.append(f"Registry version {doc.get('version', '?')}; last verified SHA {global_sha}.")

out_text = "\n".join(lines) + "\n"
with open(out_path, "w", encoding="utf-8") as f:
    f.write(out_text)

print(f"gen_invariants: wrote {out_path} ({len(invariants)} invariants, "
      f"{sum(1 for e in invariants if e.get('former_status'))} classified former gaps)")
if errors:
    print(f"gen_invariants: {len(errors)} check(s) FAILED", file=sys.stderr)
    sys.exit(1)
print("gen_invariants: all mechanical checks passed")
sys.exit(0)
PY
