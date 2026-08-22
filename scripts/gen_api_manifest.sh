#!/usr/bin/env bash
#
# scripts/gen_api_manifest.sh — generate build/public_api_manifest.json
# (the reviewer's public-API manifest: the public fn / method /
# constructor / type / trait / enum-variant / constant per std module,
# with the contract association: module -> family -> the proof tests).
#
# The extraction is AST-based: scripts/api_manifest_extractor.py walks each
# module's declaration structure (the top-level item table + the
# impl/struct/enum/trait bodies, each a block opened by its header and
# closed by `end`) — the same surface the compiler's docgen consumes. The
# extractor is compiler-independent so the CI evidence-gate job (no
# compiler binary) can regenerate the manifest; extraction HEALTH is part
# of the gate (an unterminated block or an unparsable item header fails).
#
# THE PER-SYMBOL LAYER (the coverage oracle #5): scripts/
# api_manifest_associator.py attributes every public callable to the
# tests that reference it (tests/**/*.tg, excluding the generated sweep
# suite) and computes the honest per-symbol uncovered enumeration — the
# public callables of the behavior-family modules (native/lane,
# non-experimental) referenced by no test. The associations are embedded
# per callable (`tests` list) and the uncovered callables are listed
# per module in gates.uncovered_callables. The tests-added layer for the
# uncovered callables is the generated sweep suite (tests/api_manifest/,
# scripts/gen_api_manifest_sweep.py), closed by scripts/
# check_api_manifest_extractor.sh.
#
# The manifest is DETERMINISTIC (no timestamps, no SHA): the CI
# enumeration gate (tests/run_stdlib_completeness_gate.sh, run first by
# tests/run_stdlib_e106_sweep.sh) regenerates it and the completeness
# documents and diffs the committed artifacts.
#
# THE RELEASE CHECKS (--release-check): the release fails when
#   (1) a public callable has zero behavior tests — a module whose family
#       minimum proof claims behavior suites (native / lane) whose proof
#       tests do not reference the module's public API (token-level);
#   (2) an error variant is never exercised — a behavior-claimed module
#       declaring public error variants whose proof tests reference none
#       of them;
#   (3) a cfg target without the execution — a non-experimental module
#       whose @cfg references a target_os/target_arch with no committed
#       execution evidence (the served set: macos/linux/aarch64/x86_64 —
#       the honest capability matrix; anything else, e.g. windows/
#       android/ios/riscv32, fails until execution evidence lands or the
#       module is flagged experimental).
#   Experimental modules are excluded from all three checks (the item 33
#   stable-subset policy: the shipped claims exclude them explicitly).
#   The default mode RECORDS the findings in the manifest's `gates`
#   section without failing; --release-check exits non-zero on any
#   finding. scripts/gen_status.sh --release-evidence (the release-run
#   evidence path) invokes this mode; RELEASE_GATED is never reachable
#   without it.
#
# Usage: scripts/gen_api_manifest.sh [--release-check] [outfile]
#   outfile defaults to build/public_api_manifest.json.
# Exit status: 0 when the extraction is healthy (and, with
# --release-check, no release finding exists); non-zero otherwise.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/build/public_api_manifest.json}"
RELEASE_CHECK=0

case "${1:-}" in
  --release-check)
    RELEASE_CHECK=1
    OUT="${2:-$ROOT/build/public_api_manifest.json}"
    ;;
esac

EXTRACTOR="$ROOT/scripts/api_manifest_extractor.py"
ASSOCIATOR="$ROOT/scripts/api_manifest_associator.py"
CONTRACTS="$ROOT/docs/current/stdlib_contracts.toml"
STDDIR="$ROOT/std"

if [ ! -f "$EXTRACTOR" ]; then
  echo "gen_api_manifest: missing extractor: $EXTRACTOR" >&2
  exit 1
fi
if [ ! -f "$ASSOCIATOR" ]; then
  echo "gen_api_manifest: missing associator: $ASSOCIATOR" >&2
  exit 1
fi
if [ ! -f "$CONTRACTS" ]; then
  echo "gen_api_manifest: missing contracts manifest: $CONTRACTS" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT")"

RELEASE_CHECK="$RELEASE_CHECK" ROOT="$ROOT" STDDIR="$STDDIR" \
  EXTRACTOR="$EXTRACTOR" ASSOCIATOR="$ASSOCIATOR" CONTRACTS="$CONTRACTS" OUT="$OUT" \
  python3 - <<'PY'
import json
import os
import re
import subprocess
import sys

release_check = os.environ.get("RELEASE_CHECK") == "1"
root = os.environ["ROOT"]
stddir = os.environ["STDDIR"]
extractor = os.environ["EXTRACTOR"]
associator = os.environ["ASSOCIATOR"]
contracts_path = os.environ["CONTRACTS"]
out_path = os.environ["OUT"]

BEHAVIOR_FAMILIES = {"native", "lane"}   # families whose minimum proof claims behavior suites
# The SERVED targets' cfg tokens (the honest capability matrix — the only
# target_os/target_arch values with committed execution evidence).
SERVED_CFG = {"macos", "linux", "aarch64", "x86_64"}

def word_set(names):
    return {n for n in names if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", n)}

def module_referenced(proof_tests, module, names):
    """True when some behavior test references the module (its name or one
    of its public type/callable names) as a word token. The scan covers
    the contract's proof tests AND the whole tests/ tree (the behavior-test
    universe); the proof tests remain the documented minimum (their
    existence is the enumeration gate), the broad scan is the release
    check's honest reference universe."""
    tokens = word_set([module] + names)
    if not tokens:
        return False
    files = [os.path.join(root, rel) for rel in proof_tests
             if os.path.isfile(os.path.join(root, rel))]
    for base, _dirs, fnames in os.walk(os.path.join(root, "tests")):
        for fn in fnames:
            if fn.endswith(".tg"):
                files.append(os.path.join(base, fn))
    for path in files:
        try:
            text = open(path, "r", encoding="utf-8").read()
        except OSError:
            continue
        for t in tokens:
            if re.search(r"\b" + re.escape(t) + r"\b", text):
                return True
    return False

records = []
extraction_failures = []
for fname in sorted(os.listdir(stddir)):
    if not fname.endswith(".tg"):
        continue
    path = os.path.join(stddir, fname)
    proc = subprocess.run(
        [sys.executable, extractor, path, contracts_path],
        capture_output=True, text=True)
    if proc.returncode != 0:
        extraction_failures.append(proc.stderr.strip() or fname)
        continue
    records.append(json.loads(proc.stdout))

# ———————————————————————————————————————————————————————————————
# The PER-SYMBOL test associations (the NEW coverage oracle): every public
# callable is attributed to the tests that reference it, and the honest
# per-symbol uncovered enumeration is computed for the modules with real
# behavior suites (the native/lane families, non-experimental).
# ———————————————————————————————————————————————————————————————
assoc = {}
assoc_failures = []
if records:
    probe = {"modules": records}
    probe_path = out_path + ".assoc-probe.json"
    with open(probe_path, "w", encoding="utf-8") as fh:
        json.dump(probe, fh)
    proc = subprocess.run(
        [sys.executable, associator, probe_path, os.path.join(root, "tests")],
        capture_output=True, text=True)
    try:
        os.remove(probe_path)
    except OSError:
        pass
    if proc.returncode != 0:
        assoc_failures.append(proc.stderr.strip() or "associator failed")
    else:
        assoc = json.loads(proc.stdout)
        # attach the per-callable test lists into the manifest records
        syms = assoc.get("symbols", {})
        for rec in records:
            mod = rec.get("module", "?")
            mod_syms = syms.get(mod, {})
            api = rec.get("public_api", {})
            for key in ("functions", "methods", "constructors"):
                for item in api.get(key, []):
                    name = item.get("name", "")
                    if name in mod_syms:
                        item["tests"] = mod_syms[name]
                    else:
                        item["tests"] = []

findings = {"uncovered_callables": [], "unexercised_error_variants": [], "unexecuted_cfg_targets": []}

# The per-symbol uncovered enumeration (bounded to the behavior families,
# non-experimental): every public callable of a module with a real suite
# must be referenced by at least one test.
for mod, callables in assoc.get("uncovered", {}).items():
    findings["uncovered_callables"].append({
        "module": mod,
        "callables": callables,
        "rule": "per-symbol: the module's family claims behavior suites, but these public callables are referenced by no test (tests/**/*.tg)",
    })

for rec in records:
    # the contract association: the module's contract id (its completeness
    # contract in stdlib_contracts.toml), the family, and the proof tests
    # every public symbol of the module associates to.
    rec["contract_id"] = "STDLIB-CONTRACT-%s" % rec.get("module", "?")
    family = rec.get("family", "?")
    experimental = rec.get("experimental", False)
    api = rec.get("public_api", {})
    names = []
    for key in ("functions", "methods", "constructors"):
        names.extend(item.get("name", "") for item in api.get(key, []))
    for key in ("types", "traits"):
        names.extend(item.get("name", "") for item in api.get(key, []))
    names.extend(v.get("variant", "") for v in api.get("enum_variants", []))
    names.extend(c.get("name", "") for c in api.get("constants", []))
    names = [n for n in names if n]

    # (1) a public callable with zero behavior tests: a behavior-claimed
    # module whose proof tests never reference its public API.
    if family in BEHAVIOR_FAMILIES and not module_referenced(
            rec.get("proof_tests") or [], rec.get("module", ""), names):
        findings["uncovered_callables"].append({
            "module": rec["module"],
            "callables": [n for n in names],
            "rule": "family %s minimum proof claims behavior suites, but none of the proof tests reference the module's public API" % family,
        })
    # (2) an error variant never exercised.
    if family in BEHAVIOR_FAMILIES:
        err_variants = [v.get("variant", "") for v in rec.get("error_variants", [])]
        if err_variants and not module_referenced(
                rec.get("proof_tests") or [], rec.get("module", ""), err_variants):
            findings["unexercised_error_variants"].append({
                "module": rec["module"],
                "error_variants": err_variants,
                "rule": "the module declares public error variants but the proof tests reference none of them",
            })
    # (3) a cfg target without the execution.
    if not experimental:
        bad = sorted(t for t in rec.get("cfg_targets", []) if t not in SERVED_CFG)
        if bad:
            findings["unexecuted_cfg_targets"].append({
                "module": rec["module"],
                "cfg_targets": bad,
                "rule": "cfg target(s) without committed execution evidence (served: %s); execute the target or flag the module experimental" % ", ".join(sorted(SERVED_CFG)),
            })

manifest = {
    "schema_version": 1,
    "generator": "scripts/gen_api_manifest.sh",
    "extractor": "scripts/api_manifest_extractor.py",
    "associator": "scripts/api_manifest_associator.py",
    "source": "docs/current/stdlib_contracts.toml + std/*.tg (deterministic — no run identity embedded)",
    "modules": records,
    "symbol_test_associations": {
        "stats": assoc.get("stats", {}),
    },
    "gates": findings,
    "release_check": "PASS" if release_check and not any(findings.values()) and not assoc_failures else
                     "FAIL" if release_check else "not-run",
}

with open(out_path, "w", encoding="utf-8") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=True)
    fh.write("\n")

print("gen_api_manifest: %d module record(s) -> %s" % (len(records), out_path))
if extraction_failures:
    print("gen_api_manifest: EXTRACTION FAILURES:", file=sys.stderr)
    for f in extraction_failures:
        print("  - " + f, file=sys.stderr)
    sys.exit(1)
if assoc_failures:
    print("gen_api_manifest: ASSOCIATOR FAILURES:", file=sys.stderr)
    for f in assoc_failures:
        print("  - " + f, file=sys.stderr)
    sys.exit(1)
stats = assoc.get("stats", {})
print("  symbol associations: %(callables)d callables, %(referenced)d referenced, %(uncovered_bounded)d uncovered (bounded)" % stats)
for kind, items in findings.items():
    print("  findings[%s] = %d" % (kind, len(items)))
if release_check:
    if any(findings.values()):
        print("gen_api_manifest: RELEASE CHECK FAILED — the findings above block the release:", file=sys.stderr)
        for kind, items in findings.items():
            for it in items:
                print("  - [%s] %s: %s" % (kind, it.get("module"), it.get("rule", "")), file=sys.stderr)
        sys.exit(1)
    print("gen_api_manifest: RELEASE CHECK PASSED — every behavior-claimed callable is referenced, every error variant is exercised, every cfg target has execution evidence")
sys.exit(0)
PY
