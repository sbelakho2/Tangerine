#!/usr/bin/env python3
#
# scripts/api_manifest_extractor.py — the public-API extraction tool behind
# scripts/gen_api_manifest.sh (the reviewer's public-API manifest).
#
# For every std/*.tg module the tool extracts the PUBLIC API surface — the
# public functions, methods, constructors, types, traits, enum variants and
# constants — and the module's error variants and @cfg target references.
# The extraction is AST-shaped: it walks the module's DECLARATION STRUCTURE
# (the top-level item table + the impl/struct/enum/trait bodies, each a
# block opened by its header and closed by `end`), mirroring the surface
# tg_compiler/docgen.tg consumes. It is deliberately compiler-independent:
# the CI evidence-gate job has no compiler binary, and the manifest must be
# regenerable there for the generate-then-diff discipline.
#
# Extraction health is part of the gate: an unterminated block, an
# unparsable item header, or a module that yields NO public item is a
# FAILURE (the sweep gate fails), so a module whose structure the tool
# cannot read cannot be shipped silently.
#
# Usage: scripts/api_manifest_extractor.py <module.tg> [<contracts.toml>]
#   Prints one JSON object per module (the manifest record) to stdout.
#   <contracts.toml> defaults to docs/current/stdlib_contracts.toml; the
#   family / proof tests / experimental flag are attached from it.
# Exit status: 0 when the module parsed structurally; non-zero with the
# findings on stderr when the block structure is unterminated or the
# module has no public item.

import json
import os
import re
import sys

BLOCK_OPENERS = re.compile(
    r"^\s*(?:pub\s+|private\s+)?(?:(?:extern\s+)?def|struct|enum|trait|impl)\b")
ITEM_HEADERS = re.compile(
    r"^\s*(?:(pub|private)\s+)?(def|struct|enum|trait|const|static|type)\b")
DEF_HEADER = re.compile(r"^\s*(?:(pub|private)\s+)?(?:extern\s+)?def\s+([A-Za-z_][A-Za-z0-9_]*(?:::[A-Za-z_][A-Za-z0-9_]*)?)\b")
STRUCT_HEADER = re.compile(r"^\s*(?:(pub|private)\s+)?struct\s+([A-Za-z_][A-Za-z0-9_]*)\b")
ENUM_HEADER = re.compile(r"^\s*(?:(pub|private)\s+)?enum\s+([A-Za-z_][A-Za-z0-9_]*)\b")
TRAIT_HEADER = re.compile(r"^\s*(?:(pub|private)\s+)?trait\s+([A-Za-z_][A-Za-z0-9_]*)\b")
IMPL_HEADER = re.compile(
    r"^\s*impl\s*(\[.*\]\s*)?([A-Za-z_][A-Za-z0-9_:]*(?:\[.*\])?)(?:\s+for\s+([A-Za-z_][A-Za-z0-9_:]*(?:\[.*\])?))?(?:\s+where\b.*)?(?:\s*\{\})?\s*$")
ONE_LINE_DEF = re.compile(r"^\s*def\b.*\bend\s*$")
# A def whose BODY is the same line: `def name(...) -> T = expr` (no `end`).
DEF_WITH_EQ_BODY = re.compile(r"^.*->.*=\s*\S")
# One-line type declarations: `trait FfiBoundary end` / `impl X for Y {}`.
ONE_LINE_TYPE = re.compile(r"\bend\s*$|\{\}\s*$")
CONST_HEADER = re.compile(r"^\s*(?:(pub|private)\s+)?(const|static)\s+([A-Za-z_][A-Za-z0-9_]*)\b")
TYPE_HEADER = re.compile(r"^\s*(?:(pub|private)\s+)?type\s+([A-Za-z_][A-Za-z0-9_]*)\b")
USE_LINE = re.compile(r"^\s*use\s+")
CFG_ATTR = re.compile(r"@cfg\s*\(([^)]*)\)")
CFG_VALUE = re.compile(r'(target_os|target_arch)\s*=\s*"([^"]+)"')
END_LINE = re.compile(r"^\s*end\b")
VARIANT_LINE = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\b")
ERROR_ENUM = re.compile(r"[Ee]rror")
COMMENT_ONLY = re.compile(r"^\s*(#|$)")


def strip_code(line):
    """Remove comments and replace string/char literals with placeholders
    so headers and variants are classified from real tokens only."""
    out = []
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == '"':
            j = i + 1
            while j < n:
                if line[j] == "\\":
                    j += 2
                    continue
                if line[j] == '"':
                    break
                j += 1
            out.append('""')
            i = j + 1
        elif c == "'":
            if i + 2 < n and line[i + 2] == "'":
                out.append("''")
                i += 3
            elif i + 3 < n and line[i + 1] == "\\" and line[i + 3] == "'":
                out.append("''")
                i += 4
            else:
                out.append(c)
                i += 1
        else:
            if c == "#" and (i == 0 or line[i - 1].isspace()):
                break
            out.append(c)
            i += 1
    return "".join(out)


def strip_comments(line):
    """Remove # comments but KEEP string literals intact (the cfg values
    are string literals: @cfg(target_os = "windows") must survive)."""
    out = []
    i = 0
    n = len(line)
    while i < n:
        c = line[i]
        if c == '"':
            j = i + 1
            while j < n:
                if line[j] == "\\":
                    j += 2
                    continue
                if line[j] == '"':
                    break
                j += 1
            out.append(line[i:j + 1])
            i = j + 1
        elif c == "'":
            if i + 2 < n and line[i + 2] == "'":
                out.append(line[i:i + 3])
                i += 3
            elif i + 3 < n and line[i + 1] == "\\" and line[i + 3] == "'":
                out.append(line[i:i + 4])
                i += 4
            else:
                out.append(c)
                i += 1
        else:
            if c == "#" and (i == 0 or line[i - 1].isspace()):
                break
            out.append(c)
            i += 1
    return "".join(out)


def balance_ok(text):
    """True when the parens/brackets of the accumulated signature balance."""
    return text.count("(") == text.count(")") and text.count("[") == text.count("]")


def read_sig(lines, idx, first):
    """Join continuation lines until the signature's parens balance."""
    sig = first
    while not balance_ok(sig) and idx < len(lines):
        idx += 1
        if idx < len(lines):
            sig += " " + strip_code(lines[idx]).strip()
    return sig, idx


def extract(path, contracts):
    with open(path, "r", encoding="utf-8") as fh:
        src = fh.read()
    lines = src.splitlines()

    mod = os.path.basename(path)[:-3]
    # The path field is a REPO-RELATIVE source reference (relative to the
    # ROOT env the generator exports, else the process CWD): the manifest is
    # root-independent — the two-root reproducibility proof compares the
    # generated manifests byte-for-byte across different absolute roots, and
    # an absolute path would leak the build machine's layout into the
    # artifact.
    manifest_root = os.environ.get("ROOT", os.getcwd())
    record = {
        "module": mod,
        "path": os.path.relpath(path, manifest_root),
        "family": (contracts.get(mod) or {}).get("family", "?"),
        "experimental": (contracts.get(mod) or {}).get("family") == "experimental",
        "proof_tests": (contracts.get(mod) or {}).get("proof") or [],
        "contract_note": (contracts.get(mod) or {}).get("note"),
        "public_api": {
            "functions": [],
            "methods": [],
            "constructors": [],
            "types": [],
            "traits": [],
            "enum_variants": [],
            "constants": [],
        },
        "error_variants": [],
        "cfg_targets": [],
    }

    # cfg targets: every target_os/target_arch value referenced by @cfg
    # (comment-only stripping — the values are string literals).
    for m in CFG_ATTR.finditer("\n".join(strip_comments(l) for l in src.splitlines())):
        for kv in CFG_VALUE.finditer(m.group(1)):
            token = kv.group(2)
            if token not in record["cfg_targets"]:
                record["cfg_targets"].append(token)

    # The declaration-structure walk: a top-level frame is a block opened at
    # column 0 (def/struct/enum/trait/impl) and closed by `end` at column 0.
    frames = []          # stack of {kind, name, indent}
    enum = None          # the open enum frame, for variant capture
    enum_indent = None
    i = 0
    health_failures = []
    while i < len(lines):
        raw = lines[i]
        clean = strip_code(raw)
        if COMMENT_ONLY.match(clean):
            i += 1
            continue
        stripped = clean.strip()
        indent = len(clean) - len(clean.lstrip())

        if END_LINE.match(clean):
            if frames:
                f = frames.pop()
                if f["kind"] == "enum":
                    enum = None
                    enum_indent = None
            i += 1
            continue

        # one-line top-level items (const/static/type) — no block.
        m = CONST_HEADER.match(clean)
        if m and indent == 0:
            record["public_api"]["constants"].append({
                "name": m.group(3),
                "kind": m.group(2),
                "pub": m.group(1) != "private",
                "declaration": stripped,
            })
            i += 1
            continue
        m = TYPE_HEADER.match(clean)
        if m and indent == 0:
            record["public_api"]["types"].append({
                "name": m.group(2),
                "kind": "alias",
                "pub": m.group(1) != "private",
                "declaration": stripped,
            })
            i += 1
            continue

        if indent == 0 and BLOCK_OPENERS.match(clean):
            f = {"kind": None, "name": None, "pub": True}
            m = DEF_HEADER.match(clean)
            if m:
                f["kind"] = "def"
                f["name"] = m.group(2)
                f["pub"] = m.group(1) != "private"
                sig, i = read_sig(lines, i, stripped)
                item = {
                    "name": f["name"],
                    "kind": "extern" if "extern" in clean else "fn",
                    "pub": f["pub"],
                    "signature": sig,
                }
                record["public_api"]["functions"].append(item)
                is_extern = "extern" in clean
                one_line = bool(ONE_LINE_DEF.match(clean)) or bool(DEF_WITH_EQ_BODY.match(clean))
                if is_extern or one_line:
                    # extern defs may be bare one-line declarations (no
                    # block, no `end`); consume a trailing `end` only when
                    # the next code line is one.
                    if not one_line:
                        j = i + 1
                        while j < len(lines) and COMMENT_ONLY.match(strip_code(lines[j])):
                            j += 1
                        if j < len(lines) and END_LINE.match(strip_code(lines[j])):
                            i = j
                    i += 1
                    continue
            else:
                m = STRUCT_HEADER.match(clean)
                if m:
                    f["kind"] = "struct"
                    f["name"] = m.group(2)
                    f["pub"] = m.group(1) != "private"
                    record["public_api"]["types"].append({
                        "name": f["name"], "kind": "struct", "pub": f["pub"]})
                    if ONE_LINE_TYPE.search(clean):
                        i += 1
                        continue
                else:
                    m = ENUM_HEADER.match(clean)
                    if m:
                        f["kind"] = "enum"
                        f["name"] = m.group(2)
                        f["pub"] = m.group(1) != "private"
                        record["public_api"]["types"].append({
                            "name": f["name"], "kind": "enum", "pub": f["pub"]})
                        if ONE_LINE_TYPE.search(clean):
                            i += 1
                            continue
                        enum = f
                        enum_indent = indent
                    else:
                        m = TRAIT_HEADER.match(clean)
                        if m:
                            f["kind"] = "trait"
                            f["name"] = m.group(2)
                            f["pub"] = m.group(1) != "private"
                            record["public_api"]["traits"].append({
                                "name": f["name"], "pub": f["pub"], "methods": []})
                            if ONE_LINE_TYPE.search(clean):
                                i += 1
                                continue
                        else:
                            m = IMPL_HEADER.match(clean)
                            if m:
                                f["kind"] = "impl"
                                f["name"] = m.group(3) or m.group(2)
                                if ONE_LINE_TYPE.search(clean):
                                    i += 1
                                    continue
                            else:
                                health_failures.append(
                                    "line %d: unparsable block opener: %s" % (i + 1, stripped))
                                f = None
            if f is not None:
                frames.append(f)
            i += 1
            continue

        # inside a frame: methods of impl/trait, variants of enum.
        if frames:
            top = frames[-1]
            if top["kind"] == "impl" and DEF_HEADER.match(clean):
                m = DEF_HEADER.match(clean)
                sig, i = read_sig(lines, i, stripped)
                is_ctor = m.group(2) == "new" or m.group(2).endswith("::new")
                item = {
                    "name": m.group(2),
                    "impl": top["name"],
                    "pub": m.group(1) != "private",
                    "signature": sig,
                }
                target = record["public_api"]["constructors"] if is_ctor else record["public_api"]["methods"]
                target.append(item)
                i += 1
                continue
            if top["kind"] == "trait" and DEF_HEADER.match(clean):
                m = DEF_HEADER.match(clean)
                sig, i = read_sig(lines, i, stripped)
                (record["public_api"]["traits"][-1]["methods"] if
                 record["public_api"]["traits"] else []).append({
                    "name": m.group(2), "signature": sig})
                i += 1
                continue
            if top["kind"] == "enum" and indent > enum_indent:
                m = VARIANT_LINE.match(clean)
                if m and not USE_LINE.match(clean) and not CFG_ATTR.match(clean):
                    variant = m.group(1)
                    entry = {"enum": top["name"], "variant": variant}
                    if variant not in [v["variant"] for v in record["public_api"]["enum_variants"]]:
                        record["public_api"]["enum_variants"].append(entry)
                        if ERROR_ENUM.search(top["name"]):
                            record["error_variants"].append(entry)
        i += 1

    if frames:
        health_failures.append(
            "unterminated block at EOF: %s (missing `end`)" % frames[-1].get("name", "?"))
    if not health_failures and not (
            record["public_api"]["functions"] or record["public_api"]["methods"] or
            record["public_api"]["types"] or record["public_api"]["traits"] or
            record["public_api"]["constants"]):
        health_failures.append("no public item extracted")

    if health_failures:
        print(json.dumps({"module": mod, "path": path, "health_failures": health_failures}))
        for hf in health_failures:
            print("api_manifest_extractor: %s: %s" % (mod, hf), file=sys.stderr)
        sys.exit(1)

    print(json.dumps(record, sort_keys=True))
    sys.exit(0)


def main():
    if len(sys.argv) < 2:
        print("usage: api_manifest_extractor.py <module.tg> [<contracts.toml>]", file=sys.stderr)
        sys.exit(2)
    path = sys.argv[1]
    contracts_path = sys.argv[2] if len(sys.argv) > 2 else None
    contracts = {}
    if contracts_path and os.path.exists(contracts_path):
        text = open(contracts_path, "r", encoding="utf-8").read()
        try:
            import tomllib
            contracts = tomllib.loads(text).get("module", {})
        except ImportError:
            try:
                import tomli
                contracts = tomli.loads(text).get("module", {})
            except ImportError:
                contracts = {}
    extract(path, contracts)


if __name__ == "__main__":
    main()
