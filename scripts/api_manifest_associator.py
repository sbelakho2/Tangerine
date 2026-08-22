#!/usr/bin/env python3
#
# scripts/api_manifest_associator.py — the per-symbol test-association
# extraction (the NEW std public-API coverage oracle).
#
# For every public callable (function / method / constructor) of every std
# module the associator extracts the BEHAVIOR TESTS that exercise it: the
# tests/**/*.tg files whose content references the callable's symbol name
# as a word token (the same token rule gen_api_manifest.sh's module-level
# reference scan uses — now applied PER SYMBOL).
#
# The extraction is deterministic (sorted symbol names, sorted relative
# test paths, no run identity), so the manifest can be regenerated and
# diffed — the generate-then-diff discipline.
#
# The UNCOVERED enumeration is BOUNDED to the modules with real behavior
# suites: the behavior families (native / lane) whose modules are not
# experimental. A callable of such a module with zero referencing tests is
# an honest release finding; the count is reported exactly.
#
# Output (stdout, one JSON object):
#   {
#     "symbols":      { "<module>": { "<callable>": ["tests/...tg", ...] } },
#     "uncovered":    { "<module>": ["<callable>", ...] },   # bounded
#     "stats":        { "callables": N, "referenced": N, "uncovered_bounded": N }
#   }
#
# Usage: scripts/api_manifest_associator.py <manifest.json> <tests-dir>
#   Exit status: 0 always (the caller decides the gate from the output);
#   non-zero only on usage/read errors.

import json
import os
import re
import sys

BEHAVIOR_FAMILIES = {"native", "lane"}

WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def load_manifest(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def collect_test_files(tests_dir):
    # The per-symbol association universe: tests/**/*.tg EXCLUDING the
    # generated sweep suite (tests/api_manifest/**) — the sweep references
    # exactly the uncovered callables, so counting it would be circular
    # (the manifest's uncovered list must measure the behavior tests
    # OUTSIDE the sweep; the sweep's closure is the health gate's check).
    files = []
    for base, _dirs, names in os.walk(tests_dir):
        if os.path.basename(base) == "api_manifest":
            continue
        for fn in names:
            if fn.endswith(".tg"):
                files.append(os.path.join(base, fn))
    return sorted(files)


def read_file(path):
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return ""


def symbols_of(record):
    """The public callables of a module record: name -> display kind."""
    out = {}
    api = record.get("public_api", {})
    for item in api.get("functions", []):
        out[item.get("name", "")] = "function"
    for item in api.get("methods", []):
        out[item.get("name", "")] = "method"
    for item in api.get("constructors", []):
        out[item.get("name", "")] = "constructor"
    out.pop("", None)
    return out


def associate(manifest, tests_dir):
    test_files = collect_test_files(tests_dir)
    contents = [(f, read_file(f)) for f in test_files]

    symbols = {}
    uncovered = {}
    total = 0
    referenced = 0

    for record in manifest.get("modules", []):
        mod = record.get("module", "?")
        family = record.get("family", "?")
        experimental = record.get("experimental", False)
        bounded = family in BEHAVIOR_FAMILIES and not experimental
        syms = symbols_of(record)
        if not syms:
            continue
        mod_map = symbols.setdefault(mod, {})
        mod_uncovered = []
        for name in sorted(syms):
            total += 1
            hits = []
            for f, text in contents:
                if re.search(r"\b" + re.escape(name) + r"\b", text):
                    hits.append(os.path.normpath(
                        os.path.join("tests", os.path.relpath(f, tests_dir))))
            hits = sorted(hits)
            mod_map[name] = hits
            if hits:
                referenced += 1
            elif bounded:
                mod_uncovered.append(name)
        if mod_uncovered:
            uncovered[mod] = sorted(mod_uncovered)

    return {
        "symbols": symbols,
        "uncovered": uncovered,
        "stats": {
            "callables": total,
            "referenced": referenced,
            "uncovered_bounded": sum(len(v) for v in uncovered.values()),
        },
    }


def main():
    if len(sys.argv) < 3:
        print("usage: api_manifest_associator.py <manifest.json> <tests-dir>", file=sys.stderr)
        sys.exit(2)
    manifest = load_manifest(sys.argv[1])
    result = associate(manifest, sys.argv[2])
    json.dump(result, sys.stdout, indent=2, sort_keys=True)
    print()
    sys.exit(0)


if __name__ == "__main__":
    main()
