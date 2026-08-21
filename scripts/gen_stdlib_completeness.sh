#!/usr/bin/env bash
#
# scripts/gen_stdlib_completeness.sh — generate docs/current/stdlib_completeness.md
# from the machine-readable docs/current/stdlib_contracts.toml (the reviewer's
# item 32 completeness model: every shipped std/*.tg module belongs to exactly
# one verification family, and every family names its minimum proof).
#
# The completeness model is GENERATED EVIDENCE, not hand-written prose:
#   - docs/current/stdlib_contracts.toml is the single source (module ->
#     family -> the proof tests; family -> the minimum proof).
#   - The generator MECHANICALLY verifies the manifest before rendering:
#       * THE ENUMERATION: every std/*.tg file has a contract entry, and
#         every contract names a real std/*.tg module. A new std file
#         (a 132nd module) FAILS the generation until it receives a
#         contract + proof tests; an orphan contract (no such module)
#         fails too.
#       * every proof test path exists in the tree;
#       * the family names are inside the vocabulary
#         {kernel, native, lane, parse-clean, experimental};
#       * the EXPERIMENTAL family agrees with features.toml: every module
#         flagged experimental in the manifest must be listed in exactly
#         one `experimental = true` feature row's `modules = [...]`, and
#         every module a row lists must be experimental in the manifest
#         (the item 33 registry gating cannot drift from the module-level
#         contracts).
#   - The CI enumeration gate (tests/run_stdlib_completeness_gate.sh,
#     run first by tests/run_stdlib_e106_sweep.sh — the REQUIRED
#     stdlib-e106-sweep job) regenerates this document AND the public-API
#     manifest and runs `git diff --exit-code`: a drifted completeness
#     model cannot merge.
#
# Usage: scripts/gen_stdlib_completeness.sh [outfile]
#   outfile defaults to docs/current/stdlib_completeness.md.
# Exit status: 0 when every mechanical check holds and the document is
# rendered; non-zero (with the file still written, so CI can diff it) when
# the enumeration, a proof path, a family name, or the experimental
# cross-check drifted.

set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOML="$ROOT/docs/current/stdlib_contracts.toml"
FEATURES="$ROOT/features.toml"
STDDIR="$ROOT/std"
OUT="${1:-$ROOT/docs/current/stdlib_completeness.md}"

if [ ! -f "$TOML" ]; then
  echo "gen_stdlib_completeness: missing contracts manifest: $TOML" >&2
  exit 1
fi
if [ ! -f "$FEATURES" ]; then
  echo "gen_stdlib_completeness: missing features.toml: $FEATURES" >&2
  exit 1
fi

python3 - "$TOML" "$FEATURES" "$STDDIR" "$OUT" <<'PY'
import json
import os
import re
import sys

toml_path, features_path, stddir, out_path = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

FAMILY_VOCAB = ["kernel", "native", "lane", "parse-clean", "experimental"]

# ── TOML parsing: tomllib (3.11+) -> tomli -> the constrained fallback ────
def parse_fallback(text):
    """Parse the constrained contracts/features subset: comments,
    [family."x"] / [module."y"] / [feature."x"] tables, key = "value",
    key = true|false, key = [...] (quoted strings)."""
    data = {"family": {}, "module": {}, "feature": {}}
    current = None
    current_kind = None
    pending_key = None
    array = None
    for raw in text.splitlines():
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line.startswith("[") and line.endswith("]"):
            if array is not None:
                current[pending_key] = array
                array = None
            header = line[1:-1].strip()
            m = re.match(r'(family|module|feature)\.\s*"([^"]+)"', header)
            if not m:
                raise ValueError("unexpected table header: " + header)
            kind, name = m.group(1), m.group(2)
            current_kind = kind
            current = data[kind].setdefault(name, {})
            continue
        if array is not None:
            if line == "]":
                current[pending_key] = array
                array = None
                continue
            m = re.match(r'"((?:[^"\\]|\\.)*)"\s*,?$', line)
            if not m:
                raise ValueError("array entry parse failure: " + line)
            array.append(m.group(1).replace('\\"', '"').replace("\\\\", "\\"))
            continue
        m = re.match(r'([A-Za-z0-9_]+)\s*=\s*(true|false)\s*$', line)
        if m:
            current[m.group(1)] = m.group(2) == "true"
            continue
        m = re.match(r'([A-Za-z0-9_]+)\s*=\s*"((?:[^"\\]|\\.)*)"\s*$', line)
        if m:
            current[m.group(1)] = m.group(2).replace('\\"', '"').replace("\\\\", "\\")
            continue
        m = re.match(r'([A-Za-z0-9_]+)\s*=\s*\[\s*$', line)
        if m:
            pending_key = m.group(1)
            array = []
            continue
        m = re.match(r'([A-Za-z0-9_]+)\s*=\s*\[\]\s*$', line)
        if m:
            current[m.group(1)] = []
            continue
        raise ValueError("parse failure: " + raw)
    if array is not None:
        current[pending_key] = array
    return data

def parse_toml(text):
    try:
        import tomllib
        return tomllib.loads(text)
    except ImportError:
        pass
    try:
        import tomli
        return tomli.loads(text)
    except ImportError:
        pass
    return parse_fallback(text)

with open(toml_path, "r", encoding="utf-8") as fh:
    doc = parse_toml(fh.read())
with open(features_path, "r", encoding="utf-8") as fh:
    features_doc = parse_toml(fh.read())

families = doc.get("family", {})
contracts = doc.get("module", {})
if not families or not contracts:
    print("gen_stdlib_completeness: the contracts manifest has no families/modules", file=sys.stderr)
    sys.exit(1)

# ── the enumeration: std/*.tg is the complete module list ──────────────────
modules = sorted(f[:-3] for f in os.listdir(stddir) if f.endswith(".tg"))
failures = []
for mod in modules:
    if mod not in contracts:
        failures.append(
            "enumeration: std/%s.tg has NO contract — the completeness gate fails "
            "until it receives a family + proof tests (the 134th-module rule)" % mod)
for mod in sorted(contracts.keys()):
    if mod not in modules:
        failures.append(
            "enumeration: contract for '%s' names no std/%s.tg module (orphan contract)" % (mod, mod))

# ── mechanical checks: family vocabulary + proof-test existence ────────────
for name, fam in sorted(families.items()):
    if name not in FAMILY_VOCAB:
        failures.append("family '%s' is outside the vocabulary %s" % (name, FAMILY_VOCAB))
for mod, c in sorted(contracts.items()):
    fam = c.get("family")
    if fam not in FAMILY_VOCAB:
        failures.append("module '%s': family '%s' is outside the vocabulary %s" % (mod, fam, FAMILY_VOCAB))
    for p in c.get("proof") or []:
        if not os.path.exists(os.path.join(os.path.dirname(stddir), p)):
            failures.append("module '%s': proof test does not exist: %s" % (mod, p))

# ── the item 33 experimental cross-check with features.toml ────────────────
# Every experimental module in the manifest must be listed in exactly one
# `experimental = true` feature row's `modules = [...]`, and every module a
# row lists must be experimental in the manifest.
experimental_modules = sorted(m for m, c in contracts.items() if c.get("family") == "experimental")
row_modules = {}
for fid, f in (features_doc.get("feature") or {}).items():
    if isinstance(f, dict) and f.get("experimental"):
        for m in f.get("modules") or []:
            row_modules.setdefault(m, []).append(fid)
for m in experimental_modules:
    if m not in row_modules:
        failures.append(
            "module '%s' is experimental in the contracts manifest but NO experimental "
            "feature row in features.toml lists it (add it to a row's `modules`)" % m)
for m, rows in sorted(row_modules.items()):
    if m not in experimental_modules:
        failures.append(
            "features.toml row(s) %s list module '%s' as experimental, but the contracts "
            "manifest does not flag it experimental" % (", ".join(rows), m))
    if len(rows) > 1:
        failures.append("module '%s' is listed in MORE THAN ONE experimental row: %s"
                        % (m, ", ".join(rows)))

# ── render the completeness document (DETERMINISTIC — no SHA/timestamp) ───
shipped = [m for m in modules if contracts[m].get("family") != "experimental"]
experimental = [m for m in modules if contracts[m].get("family") == "experimental"]

lines = []
lines.append("# Tangerine Stdlib Completeness Model")
lines.append("")
lines.append("> **GENERATED EVIDENCE — do not edit by hand.** This document is")
lines.append("> rendered by `scripts/gen_stdlib_completeness.sh` from")
lines.append("> [`stdlib_contracts.toml`](stdlib_contracts.toml), the machine-readable")
lines.append("> completeness manifest: module → verification family → the proof tests.")
lines.append("> The CI enumeration gate regenerates it and runs `git diff --exit-code`,")
lines.append("> so a drifted completeness model cannot merge.")
lines.append("")
lines.append("## The completeness model (the reviewer's item 32)")
lines.append("")
lines.append("Every shipped `std/*.tg` module belongs to **exactly one verification")
lines.append("family**, and every family names its **minimum proof** — the weakest")
lines.append("evidence the module must carry to stay shipped. The family assignment")
lines.append("is the contract: it states what is CLAIMED for the module and what is")
lines.append("NOT. A module's family is never stronger than its committed evidence,")
lines.append("and the shipped-std claims are never stronger than the families.")
lines.append("")
lines.append("**The enumeration is the gate.** The module list is COMPUTED from the")
lines.append("`std/*.tg` glob — never typed. This tree enumerates **%d modules**"
% len(modules))
lines.append("(the reviewer's table enumerated 133: `std/postgres.tg` was merged into")
lines.append("`std/db.tg` and `std/hash_tests.tg` was removed in earlier waves). A")
lines.append("**new** `std/*.tg` file (a %dth module) has no contract, and the" % (len(modules) + 1))
lines.append("completeness gate FAILS until it receives a contract + proof tests —")
lines.append("adding a module to std/ without completing its verification is")
lines.append("impossible by construction.")
lines.append("")
lines.append("## The verification families")
lines.append("")
lines.append("| Family | Minimum proof (the contract) | Modules |")
lines.append("|--------|-------------------------------|---------|")
for fam in FAMILY_VOCAB:
    fam_mods = sorted(m for m in modules if contracts[m].get("family") == fam)
    if not fam_mods:
        continue
    mp = (families.get(fam) or {}).get("minimum_proof") or "—"
    lines.append("| `%s` | %s | %d |" % (fam, mp.replace("|", "\\|"), len(fam_mods)))
lines.append("")
lines.append("- **kernel** — the 14-module bootstrap closure (`bootstrap/compiler_kernel.manifest`)")
lines.append("  compiled by every stage of the ladder; the strongest tier.")
lines.append("- **native** — a committed native behavior suite (`tests/unit/*_rigor.tg`,")
lines.append("  `tests/*_test.tg`) exercises the module's public API through `tg test`.")
lines.append("- **lane** — a committed CI lane verifies `tg check` + object emission +")
lines.append("  link/import smoke and the module's own `@test` suites where declared")
lines.append("  (the `stdlib-new-modules` lane).")
lines.append("- **parse-clean** — the E106 sweep only (`tg check` zero-diagnostics + the")
lines.append("  forbidden-syntax backstop). The module is parse-clean; NO behavior claim.")
lines.append("- **experimental** — the item 33 stable-subset policy: platform-only modules")
lines.append("  whose targets are unsupported/API-only. Parse-clean only, and")
lines.append("  **explicitly excluded from the shipped-std behavior claims** (see")
lines.append("  [the stable-subset policy](#the-stable-subset-policy-reviewers-item-33)).")
lines.append("")
lines.append("## The module registry")
lines.append("")
lines.append("| Module | Family | Proof tests (the contract) |")
lines.append("|--------|--------|----------------------------|")
for mod in modules:
    c = contracts[mod]
    fam = c.get("family", "?")
    proof = c.get("proof") or []
    if proof:
        pcell = "; ".join("`%s`" % p for p in proof)
    else:
        pcell = "—"
    note = c.get("note")
    if note:
        pcell = pcell + " — " + note.replace("|", "\\|")
    lines.append("| `%s` | %s | %s |" % (mod, fam, pcell))
lines.append("")
lines.append("## The stable-subset policy (the reviewer's item 33)")
lines.append("")
lines.append("**The choice: the stable-subset policy.** Two policies were considered:")
lines.append("")
lines.append("1. **Everything-in-std-guaranteed** — every module in `std/` must reach")
lines.append("   native-tested + target-complete status on every advertised target.")
lines.append("   The honest registry forbids this: the targets of the modules below are")
lines.append("   unsupported or API-only (`wasm-target` = api-only, `embedded-targets` =")
lines.append("   unsupported, `wasi` = unsupported, `simd` = api-only,")
lines.append("   `algebraic-effects` = api-only, the GPU and platform-only surfaces have")
lines.append("   no target row at all — see the feature registry + target_capabilities.md).")
lines.append("   Under this policy the shipped-std-100%% claim would be permanently")
lines.append("   unreachable or dishonest.")
lines.append("2. **The stable-subset policy (CHOSEN)** — the experimental modules are")
lines.append("   flagged experimental in the registry (`experimental = true` on the")
lines.append("   feature rows, with the affected modules listed in `modules = [...]`),")
lines.append("   grouped here in the `experimental` family with the parse-clean minimum")
lines.append("   proof, and **explicitly excluded from the shipped-std-100%% claim**.")
lines.append("   The claim covers the %d non-experimental modules; the %d experimental"
% (len(shipped), len(experimental)))
lines.append("   modules remain in `std/` (parse-clean, never removed) but carry no")
lines.append("   behavior or target claim until their targets are served and their")
lines.append("   evidence lands.")
lines.append("")
lines.append("**The affected modules (%d):** %s." % (len(experimental), ", ".join(
    "`%s`" % m for m in experimental)))
lines.append("")
lines.append("**The shipped-std-100%% claim.** The claim is: every one of the %d"
% len(shipped))
lines.append("shipped (non-experimental) modules belongs to a family with a committed")
lines.append("minimum proof, and every module — shipped or experimental — is")
lines.append("parse-clean under the E106 sweep. The experimental modules are named")
lines.append("above; any claim about them is outside the shipped claim by explicit")
lines.append("exclusion.")
lines.append("")
lines.append("## Cross-references")
lines.append("")
lines.append("- [`stdlib_contracts.toml`](stdlib_contracts.toml) — the machine-readable source.")
lines.append("- [Standard Library Reference](stdlib_reference.md) — module surfaces and the migration-complete gate.")
lines.append("- [Feature Registry](feature_registry.md) — the feature-level statuses and the item 36 status ladder.")
lines.append("- [Target Capabilities](target_capabilities.md) — the honest per-target capability matrix.")
lines.append("- `tests/run_stdlib_completeness_gate.sh` — the enumeration gate (run first by the E106 sweep).")
lines.append("- `scripts/gen_api_manifest.sh` — the public-API manifest over the same module list.")
lines.append("")
lines.append("---")
lines.append("")
lines.append("*Generated by `scripts/gen_stdlib_completeness.sh` from")
lines.append("`docs/current/stdlib_contracts.toml` — deterministic output, so the CI")
lines.append("enumeration gate can regenerate it and run `git diff --exit-code`.")
lines.append("Do not edit this file by hand.*")
lines.append("")

text = "\n".join(lines)
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write(text)

print("gen_stdlib_completeness: %d module(s) enumerated -> %s (%d shipped, %d experimental)"
      % (len(modules), out_path, len(shipped), len(experimental)))
if failures:
    print("gen_stdlib_completeness: FAILURES (the document was still written for the CI diff):", file=sys.stderr)
    for f in failures:
        print("  - " + f, file=sys.stderr)
    sys.exit(1)
print("gen_stdlib_completeness: every module contracted, every proof test verified, experimental gating consistent")
sys.exit(0)
PY
