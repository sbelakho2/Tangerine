#!/usr/bin/env bash
# scripts/check_ci_required_jobs.sh — the Woodpecker port of the GitHub
# Actions "RELEASE-REQUIRED JOBS set" machine check (the reviewer's item 35).
#
# The authority is `.woodpecker/release_required_jobs.txt`: the EXACT set of
# release-required job names. The check asserts, both directions and with no
# subset tests:
#
#   1. every entry is a step name (a `- name: <entry>` step) in one of the
#      `.woodpecker/*.yaml|*.yml` workflows;
#   2. the set of workflow files that contain at least one required step
#      equals the `depends_on:` list of the aggregate `.woodpecker/gate.yaml`
#      (so a new critical lane must be added to the aggregate, and an
#      aggregate dependency that carries no required step fails);
#   3. every gate dependency file exists in `.woodpecker/`.
#
# Exit status: 0 when every check holds, non-zero (with a readable reason)
# otherwise. Pure bash + python3 + regex (no YAML library needed).
#
# Usage: scripts/check_ci_required_jobs.sh [root]
#   root defaults to the repository root (the script's parent directory).

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ROOT="${1:-$ROOT}"

python3 - "$ROOT" <<'PY'
import os, re, sys

root = sys.argv[1]
wp = os.path.join(root, ".woodpecker")
req_file = os.path.join(wp, "release_required_jobs.txt")
gate_file = os.path.join(wp, "gate.yaml")

fail = False


def bad(msg):
    global fail
    print("error: %s" % msg, file=sys.stderr)
    fail = True


# ── the required set ───────────────────────────────────────────────────────
if not os.path.isfile(req_file):
    bad("missing %s" % req_file)
    sys.exit(1)

required = []
for raw in open(req_file, encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if not re.fullmatch(r"[a-z0-9-]+", line):
        bad("release_required_jobs.txt has a malformed entry: %r" % line)
        continue
    required.append(line)
if not required:
    bad("%s lists no release-required jobs" % req_file)
    sys.exit(1)

# ── the step names across the Woodpecker workflows ─────────────────────────
STEP_RE = re.compile(r"^\s*-\s*name:\s*([A-Za-z0-9._-]+)\s*$", re.M)
workflows = {}
for name in sorted(os.listdir(wp)):
    if not (name.endswith(".yaml") or name.endswith(".yml")):
        continue
    path = os.path.join(wp, name)
    text = open(path, encoding="utf-8").read()
    workflows[name] = set(STEP_RE.findall(text))

job_files = {}
for job in required:
    files = sorted(n for n, steps in workflows.items() if job in steps)
    if not files:
        bad("release-required job '%s' is not a Woodpecker step in any .woodpecker/*.yaml" % job)
    job_files[job] = files

# ── the aggregate's depends_on list ────────────────────────────────────────
if not os.path.isfile(gate_file):
    bad("missing %s" % gate_file)
    sys.exit(1)

gate_text = open(gate_file, encoding="utf-8").read().splitlines()
gate_deps = []
in_deps = False
for line in gate_text:
    if re.match(r"^depends_on:\s*$", line):
        in_deps = True
        continue
    if in_deps:
        if re.match(r"^[A-Za-z_]", line):
            break
        m = re.match(r"^\s*-\s*(?:name:\s*)?([A-Za-z0-9._-]+)\s*$", line)
        if m:
            gate_deps.append(m.group(1))
if not gate_deps:
    bad("gate.yaml has no depends_on list (the aggregate cannot be empty)")
    sys.exit(1)

dep_files = set(d if d.endswith((".yaml", ".yml")) else d + ".yaml" for d in gate_deps)
for f in sorted(dep_files):
    if f not in workflows:
        bad("gate.yaml depends_on '%s' but .woodpecker/%s does not exist" % (os.path.splitext(f)[0], f))

# ── exact set equality, both directions ────────────────────────────────────
carrier_files = set()
for files in job_files.values():
    carrier_files.update(files)
missing_from_gate = sorted(carrier_files - dep_files)
extra_in_gate = sorted(dep_files - carrier_files)
if missing_from_gate:
    bad("workflow(s) carry release-required steps but are NOT in gate.yaml depends_on: %s" % ", ".join(missing_from_gate))
if extra_in_gate:
    bad("workflow(s) are in gate.yaml depends_on but carry NO release-required step: %s" % ", ".join(extra_in_gate))

for job in required:
    for f in job_files.get(job, []):
        if f not in dep_files:
            bad("release-required job '%s' lives in %s, which the aggregate does not depend on" % (job, f))

if fail:
    sys.exit(1)
print("  [ok] %d release-required job(s) are Woodpecker steps; their workflows == gate.yaml depends_on (exact set equality)"
      % len(required))
PY
