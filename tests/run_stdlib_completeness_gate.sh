#!/usr/bin/env bash
#
# tests/run_stdlib_completeness_gate.sh — the automated enumeration gate of
# the stdlib completeness model (the reviewer's item 32).
#
# The gate is the CI enforcement of the completeness model:
#   1. THE ENUMERATION — every std/*.tg file must have a contract entry in
#      docs/current/stdlib_contracts.toml (module -> family -> proof
#      tests), and every contract must name a real module. A NEW std file
#      (a 132nd module) FAILS the gate until it receives a contract +
#      proof tests; an orphan contract fails too. The count is computed
#      from the std/*.tg glob, never typed.
#   2. THE GENERATE-THEN-DIFF DISCIPLINE — the gate regenerates
#      docs/current/stdlib_completeness.md (scripts/gen_stdlib_completeness.sh)
#      and build/public_api_manifest.json (scripts/gen_api_manifest.sh)
#      and runs `git diff --exit-code` on the committed artifacts: a
#      drifted completeness model or a manifest that no longer matches
#      the extractor cannot merge. (The completeness doc + the contracts
#      manifest are committed; public_api_manifest.json is a build
#      artifact — the diff checks the committed docs.)
#   3. THE EXTRACTION HEALTH — every module must yield a public-API
#      record from scripts/api_manifest_extractor.py (an unterminated
#      block or an unparsable item header fails).
#   4. THE RELEASE-CHECK DRY RUN — the gate runs the API-manifest
#      generator in --release-check mode? NO: the release checks require
#      the release-run evidence (scripts/gen_status.sh --release-evidence)
#      and are NOT part of this gate — this gate enforces the
#      source-state facts only. The release checks ride the
#      release-evidence path.
#
# This script is compiler-free (bash + python3 only), so it runs in the
# stdlib-e106-sweep job (which has the stage3 artifact) AND locally.
# tests/run_stdlib_e106_sweep.sh calls it before any module check.
#
# Usage: tests/run_stdlib_completeness_gate.sh
# Exit status: 0 when the enumeration, the proofs, the generation and the
# committed diffs all hold; non-zero otherwise.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

failures=0
step() { printf '\n=== %s ===\n' "$1"; }
fail() { echo "completeness gate: $1" >&2; failures=$((failures + 1)); }

step "1/4: the enumeration (every std/*.tg module must have a contract)"
ENUM_OUT="$(python3 - <<'PY'
import json, os, re, sys
try:
    import tomllib
    def parse(path):
        return tomllib.load(open(path, "rb"))
except ImportError:
    print("completeness gate: python3 has no tomllib", file=sys.stderr)
    sys.exit(2)
d = parse("docs/current/stdlib_contracts.toml")
mods = sorted(f[:-3] for f in os.listdir("std") if f.endswith(".tg"))
contracts = d.get("module", {})
problems = []
for mod in mods:
    if mod not in contracts:
        problems.append("std/%s.tg has NO contract — the gate fails until it receives a family + proof tests (the 132nd-module rule)" % mod)
for mod in sorted(contracts):
    if mod not in mods:
        problems.append("contract for '%s' names no std/%s.tg module (orphan)" % (mod, mod))
if problems:
    print("\n".join(problems))
    sys.exit(1)
print("enumeration OK: %d std/*.tg modules, %d contracts, %d families"
      % (len(mods), len(contracts), len(d.get("family", {}))))
sys.exit(0)
PY
)" || true
if [ -n "$ENUM_OUT" ]; then
  if printf '%s\n' "$ENUM_OUT" | grep -q "^enumeration OK"; then
    printf '%s\n' "$ENUM_OUT"
  else
    printf '%s\n' "$ENUM_OUT" >&2
    fail "the enumeration drifted (a module is un-contracted or an orphan contract exists)"
  fi
else
  fail "the enumeration check produced no verdict"
fi

step "2/4: the completeness model (regenerate + verify + diff)"
if bash scripts/gen_stdlib_completeness.sh; then
  :
else
  fail "gen_stdlib_completeness.sh failed (enumeration / proof paths / experimental gating)"
fi
if git diff --exit-code -- docs/current/stdlib_completeness.md docs/current/stdlib_contracts.toml >/dev/null; then
  echo "completeness model diff: clean (the committed model matches the generated model)"
else
  fail "docs/current/stdlib_completeness.md or docs/current/stdlib_contracts.toml drifted — regenerate and commit the generated form"
fi

step "3/4: the public-API manifest (extraction health + regenerate)"
if bash scripts/gen_api_manifest.sh; then
  :
else
  fail "gen_api_manifest.sh failed (extraction health — an unterminated block or an unparsable module)"
fi

step "4/4: the release-check dry run (recorded findings only — the release gate runs the strict mode)"
bash scripts/gen_api_manifest.sh --release-check >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ]; then
  echo "release checks (dry): PASS — every behavior-claimed callable is referenced, every error variant exercised, every cfg target has execution evidence"
else
  echo "release checks (dry): FINDINGS RECORDED (see build/public_api_manifest.json 'gates') — the strict mode is the release-evidence path's call" >&2
fi

if [ "$failures" -ne 0 ]; then
  echo "stdlib completeness gate FAILED with $failures problem(s)" >&2
  exit 1
fi
echo "stdlib completeness gate OK: the enumeration, the contracts, the generated model and the API manifest are consistent"
exit 0
