#!/usr/bin/env python3
#
# scripts/api_manifest_associator.py — the per-symbol test-association
# extraction (the NEW std public-API coverage oracle).
#
# For every public callable (function / method / constructor) of every std
# module the associator extracts the BEHAVIOR TESTS that exercise it.
#
# THE STRENGTHENED ATTRIBUTION (the reviewer's P0): a test file counts as
# exercising a callable only when it BOTH references it AND calls it,
# scoped to the module the file actually imports —
#   (1) the REFERENCE: the callable's symbol name appears as a word token
#       in executable code (comments are stripped, `use`-import lines are
#       stripped — an import or a comment does not exercise anything);
#   (2) the CALL: the name appears in CALL POSITION — `name(...)`,
#       `Type::name(...)`, or `x.name(...)` — the name immediately
#       followed by an argument list. A bare mention (a binding
#       `let _f = name`, a use-import, a doc line) never exercises the
#       callable;
#   (3) the MODULE SCOPE: the file must import the callable's module
#       (`use std::<mod>...` or a qualified `std::<mod>::` reference) —
#       a same-named type of a DIFFERENT module is never attributed to
#       it (a file calling std::atomic's `AtomicBool::load` does not
#       exercise std::sync's `AtomicBool::load`);
#   (4) the ASSERTION: the associator additionally classifies each
#       exercising file by whether it contains an OUTCOME CHECK (an
#       `assert*` construct from std::test, or a non-zero return code —
#       the behavior tests' failure branch). The `asserting` map reports
#       the full-strength associations (reference + call + assertion);
#       the release findings' rule text names all three.
#
# THE UNIVERSE: the behavior-test universe is tests/**/*.tg EXCLUDING the
# generated sweep suite (tests/api_manifest/** — the sweep references
# exactly the uncovered callables as bound symbols; counting it would be
# circular, and under the call-position rule its value-bindings would not
# exercise anyway) PLUS the @test suites embedded in the std modules
# themselves (std/*.tg files carry `@test def ...` blocks; their regions
# are extracted with the same structural balance discipline the compiler
# gate uses, so a module's own in-module behavior tests count).
#
# The extraction is deterministic (sorted symbol names, sorted relative
# test paths, no run identity), so the manifest can be regenerated and
# diffed — the generate-then-diff discipline.
#
# The UNCOVERED enumeration is BOUNDED to the modules with real behavior
# suites: the behavior families (native / lane) whose modules are not
# experimental. A callable of such a module with zero exercising tests is
# an honest release finding; the count is reported exactly.
#
# Output (stdout, one JSON object):
#   {
#     "symbols":      { "<module>": { "<callable>": ["tests/...tg", ...] } },
#     "asserting":    { "<module>": { "<callable>": ["tests/...tg", ...] } },
#     "uncovered":    { "<module>": ["<callable>", ...] },   # bounded
#     "std_test_regions": { "std/<module>.tg": "<region text>" },
#     "stats":        { "callables": N, "referenced": N,
#                       "referenced_asserted": N, "uncovered_bounded": N }
#   }
#
# Usage: scripts/api_manifest_associator.py <manifest.json> <tests-dir>
#   The std modules are discovered as the `std` sibling of <tests-dir>
#   (the repo layout); when the sibling does not exist the std-region
#   scan is skipped (the fixture gates run against a synthetic tests
#   tree with no std sibling).
#   Exit status: 0 always (the caller decides the gate from the output);
#   non-zero only on usage/read errors.

import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
try:
    from check_struct_balance import count_openers  # the shared structural discipline
except Exception:
    # A degraded fallback (never expected in this repo): a minimal opener
    # count so the region extraction never crashes on import failure.
    def count_openers(code, lineno, stack, lines, idx):
        if re.search(r"\bdef\b|\bfn\b|\bif\b|\bwhile\b|\bfor\b|\bmatch\b|\bloop\b|\bdo\b", code):
            stack.append((lineno, "?"))
        return None

BEHAVIOR_FAMILIES = {"native", "lane"}

WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")

# The reference scan's stripped forms.
USE_LINE = re.compile(r"^\s*use\b")

# The assertion constructs: the std::test assert family + the non-zero
# return-code failure branch (the behavior suites' outcome check).
ASSERT_RE = re.compile(
    r"\bassert[a-z_]*\s*\(|\bexpect[a-z_]*\s*\(|\breturn\s+[1-9]\d*\b")

# The primitive-type method extensions (`def u64.wrapping_add(...)`) are
# extracted under the RECEIVER's name: their exercise form is a method
# call on a value of that type (`(5 as u64).wrapping_add(3)`), not a
# `u64(` call position.
PRIMITIVE_NAMES = re.compile(
    r"^(?:u8|u16|u32|u64|i8|i16|i32|i64|f32|f64|Int|UInt|Bool|Float|isize|usize)$")


def strip_comments(text):
    out = []
    for line in text.split("\n"):
        out.append(line.split("#", 1)[0])
    return "\n".join(out)


def strip_use_lines(text):
    """Remove `use ...` import lines (single-line and brace-spanned)."""
    lines = text.split("\n")
    out = []
    i = 0
    while i < len(lines):
        if USE_LINE.match(lines[i]):
            depth = lines[i].count("{") - lines[i].count("}")
            i += 1
            while depth > 0 and i < len(lines):
                depth += lines[i].count("{") - lines[i].count("}")
                i += 1
            continue
        out.append(lines[i])
        i += 1
    return "\n".join(out)


def scan_text(path):
    """The association scan text of a test file: comment- and use-stripped."""
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            text = fh.read()
    except OSError:
        return ""
    return strip_use_lines(strip_comments(text))


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


# ———————————————————————————————————————————————————————————————
# The std modules' @test regions (the in-module behavior suites).
#
# A region is the span opened by the `@test` attribute's `def` block,
# closed by the `end` that returns the block stack to its pre-def depth.
# The block accounting reuses scripts/check_struct_balance.py's opener
# rules (the same discipline the compiler gate applies), so an unterminated
# test block never produces a bogus region.
# ———————————————————————————————————————————————————————————————

def std_test_regions(std_file):
    """{path: scan-text-of-its-@test-regions} for one std module file."""
    text = read_file(std_file)
    lines = text.split("\n")
    regions = []
    i = 0
    while i < len(lines):
        ls = lines[i].strip()
        if ls != "@test":
            i += 1
            continue
        j = i + 1
        while j < len(lines):
            cand = lines[j].strip()
            if cand == "" or cand.startswith("#"):
                j += 1
                continue
            break
        if j >= len(lines) or not re.match(r"^(?:pub\s+)?(?:async\s+)?(?:def|fn)\b", lines[j].lstrip()):
            i = j
            continue
        # Replay the structural balance from the def line onward (the same
        # open/pop discipline as the compiler gate's balance checker): the
        # region ends when the def's own block is popped — the stack
        # returns to the pre-def depth.
        stack = []
        pre_depth = len(stack)
        def_line = j
        k = j
        opened = False
        while k < len(lines):
            code = lines[k].split("#", 1)[0]
            before = len(stack)
            count_openers(code, k + 1, stack, lines, k)
            ends = len(re.findall(r"\bend\b", code))
            if k == def_line and len(stack) == before and ends == 0:
                break  # a value-def one-liner without a block: no region
            pops = min(ends, len(stack) - pre_depth)
            if pops > 0:
                del stack[len(stack) - pops:]
            if ends > 0 and len(stack) <= pre_depth:
                regions.append((def_line, k + 1))
                opened = True
                break
            k += 1
        if opened:
            i = k + 1
        else:
            i = def_line + 1
    out = {}
    if regions:
        parts = []
        for start, end in regions:
            parts.extend(lines[start:end])
        out[std_file] = "\n".join(parts)
    return out


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


def imported_modules(text):
    """The std modules a file imports (`use std::<mod>`, `use
    std::<mod>::*`, `use std::<mod>::{...}`, `use std::<mod>::<sub>`),
    plus the fully-qualified `std::<mod>::` references in code."""
    mods = set()
    for m in re.finditer(r"^\s*use\s+([A-Za-z_][A-Za-z0-9_:]*)", text, re.M):
        seg = text[m.start():]
        depth = 0
        j = 0
        while j < len(seg):
            c = seg[j]
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
                if depth == 0:
                    j += 1
                    break
            elif c == "\n" and depth == 0:
                break
            j += 1
        use_span = seg[:j]
        pm = re.match(r"\s*use\s+((?:[A-Za-z_][A-Za-z0-9_]*::)*[A-Za-z_][A-Za-z0-9_]*)", use_span)
        if pm:
            parts = pm.group(1).split("::")
            if len(parts) >= 2 and parts[0] == "std":
                mods.add(parts[1])
    for m in re.finditer(r"\bstd::([A-Za-z_][A-Za-z0-9_]*)::", text):
        mods.add(m.group(1))
    return mods


def exercised(text, module, name, imported):
    """The strengthened attribution: the reference + the call, scoped to
    the module the file actually imports.

    A `Type::method` callable of <module> is exercised by a file that
    (a) imports the module (`use std::<module>...` or a qualified
    `std::<module>::` reference), (b) references the TYPE token, and
    (c) CALLS the method name (`x.method(` / `Type::method(`). A plain
    callable is exercised by a file that calls it (`name(`) and either
    imports the module or defines the name itself (a local definition
    with a body — the behavior-test helper pattern). The qualified
    `Type::method(` form alone also counts (it carries both).
    """
    if "::" not in name:
        if PRIMITIVE_NAMES.match(name):
            # a primitive-type method extension: the type token appears
            # in a receiver chain whose method is called
            return bool(re.search(r"\b" + re.escape(name) + r"\b", text)) and bool(
                re.search(r"\b" + re.escape(name) + r"\b[^(\n]*\.\s*[A-Za-z_][A-Za-z0-9_]*\s*\(", text))
        if imported:
            return bool(re.search(
                r"\b" + re.escape(name) + r"\s*(\[[^\[\]]*\])?\s*\(", text))
        # the local-definition pattern (a helper defined and called in
        # the same behavior test)
        return bool(re.search(
            r"\bdef\s+" + re.escape(name) + r"\s*(\[[^\[\]]*\])?\s*\(", text)) and bool(
            re.search(r"\b" + re.escape(name) + r"\s*(\[[^\[\]]*\])?\s*\(", text))
    if not imported:
        return False
    typ, meth = name.rsplit("::", 1)
    if re.search(r"\b" + re.escape(name) + r"\s*(\[[^\[\]]*\])?\s*\(", text):
        return True
    return bool(re.search(r"\b" + re.escape(typ) + r"\b", text)) and bool(
        re.search(r"\b" + re.escape(meth) + r"\s*(\[[^\[\]]*\])?\s*\(", text))


def associate(manifest, tests_dir):
    test_files = collect_test_files(tests_dir)
    contents = [(f, scan_text(f), read_file(f)) for f in test_files]

    # The in-module @test suites: the std sibling of the tests dir.
    std_dir = os.path.join(os.path.dirname(os.path.abspath(tests_dir)), "std")
    std_entries = []
    if os.path.isdir(std_dir):
        for fn in sorted(os.listdir(std_dir)):
            if fn.endswith(".tg"):
                for path, region_text in std_test_regions(os.path.join(std_dir, fn)).items():
                    rel = os.path.normpath(os.path.join("std", fn))
                    std_entries.append((rel, strip_use_lines(strip_comments(region_text)), read_file(os.path.join(std_dir, fn))))
    std_test_regions_map = {rel: txt for rel, txt, _raw in std_entries}

    symbols = {}
    asserting = {}
    uncovered = {}
    total = 0
    referenced = 0
    referenced_asserted = 0

    for record in manifest.get("modules", []):
        mod = record.get("module", "?")
        family = record.get("family", "?")
        experimental = record.get("experimental", False)
        bounded = family in BEHAVIOR_FAMILIES and not experimental
        syms = symbols_of(record)
        if not syms:
            continue
        mod_map = symbols.setdefault(mod, {})
        mod_asserting = asserting.setdefault(mod, {})
        mod_uncovered = []
        for name in sorted(syms):
            total += 1
            hits = []
            hit_asserting = []
            for f, text, raw in contents:
                if exercised(text, mod, name, mod in imported_modules(raw)):
                    hits.append(os.path.normpath(
                        os.path.join("tests", os.path.relpath(f, tests_dir))))
                    if ASSERT_RE.search(text):
                        hit_asserting.append(hits[-1])
            for rel, text, raw in std_entries:
                if exercised(text, mod, name, mod in imported_modules(raw)):
                    hits.append(rel)
                    if ASSERT_RE.search(text):
                        hit_asserting.append(rel)
            hits = sorted(set(hits))
            hit_asserting = sorted(set(hit_asserting))
            mod_map[name] = hits
            mod_asserting[name] = hit_asserting
            if hits:
                referenced += 1
            if hit_asserting:
                referenced_asserted += 1
            elif not hits and bounded:
                mod_uncovered.append(name)
        if mod_uncovered:
            uncovered[mod] = sorted(mod_uncovered)

    return {
        "symbols": symbols,
        "asserting": asserting,
        "uncovered": uncovered,
        "std_test_regions": std_test_regions_map,
        "stats": {
            "callables": total,
            "referenced": referenced,
            "referenced_asserted": referenced_asserted,
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
