#!/usr/bin/env python3
"""bootstrap_slices.py -- dependency-closed bootstrap compiler slices.

Reads a bootstrap kernel manifest (bootstrap/compiler_kernel.manifest by
default, format: `version: N`, `std: <file>`, `compiler: <file>`, `#`
comments), parses each listed member's absolute imports (`use std::...` /
`use tg_compiler::...`, including `{...}` groups and multi-segment paths),
and emits dependency-closed slices of the transitive closure of a root
module (default tg_compiler/bootstrap_main.tg).

A slice for size K is: the first K modules of the closure in leaves-first
topological order, closed again over dependencies (so every emitted slice
is closed even when the closure has import cycles). If the closure is
smaller than K, the full closure is emitted.

Each slice is written in the standard manifest format to
build/slices/k<K>.manifest and one summary line per K is printed:

    SLICE K=<k> modules=<n> manifest=build/slices/k<k>.manifest

A dependency on a NON-member of the manifest is an error: the kernel is
only closed if every listed member's imports are themselves listed.
"""

import argparse
import heapq
import re
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_MANIFEST = "bootstrap/compiler_kernel.manifest"
DEFAULT_ROOT = "tg_compiler/bootstrap_main.tg"
DEFAULT_SIZES = "10 20 30 40 45"

USE_RE = re.compile(r"^\s*(?:pub\s+)?use\s+")
IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def die(msg):
    print("bootstrap_slices: error: %s" % msg, file=sys.stderr)
    sys.exit(1)


def parse_manifest(path):
    """Parse the manifest into (version, members, order).

    members maps the logical key ("std::core", "tg_compiler::lexer") to a
    dict with the kind, the file name relative to the kind directory and
    the repo-relative path.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        die("cannot read manifest '%s': %s" % (path, exc))

    version = None
    members = {}
    order = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if ":" not in line:
            die("%s:%d: malformed manifest record '%s'" % (path, lineno, line))
        kind, _, value = line.partition(":")
        kind = kind.strip()
        value = value.strip()
        if kind == "version":
            if version is not None:
                die("%s:%d: duplicate version record" % (path, lineno))
            version = value
        elif kind in ("std", "compiler"):
            if not value:
                die("%s:%d: empty filename for '%s'" % (path, lineno, kind))
            name = value[:-3] if value.endswith(".tg") else value
            # Import paths name the directory namespace (`tg_compiler::x`),
            # while the manifest record kind is `compiler`.
            namespace = "std" if kind == "std" else "tg_compiler"
            key = "%s::%s" % (namespace, name)
            if key in members:
                die("%s:%d: duplicate manifest member '%s'" % (path, lineno, key))
            dirname = "std" if kind == "std" else "tg_compiler"
            fname = value if value.endswith(".tg") else value + ".tg"
            members[key] = {
                "kind": kind,
                "name": name,
                "file": fname,
                "rel": "%s/%s" % (dirname, fname),
                "line": lineno,
            }
            order.append(key)
        else:
            die("%s:%d: unknown record type '%s'" % (path, lineno, kind))

    if version is None:
        die("%s: no version record (the standard format requires 'version: 1')" % path)
    return version, members, order


def extract_imports(text):
    """Yield (lineno, key, raw_path) for absolute std/tg_compiler imports.

    Handles `use std::m`, `use std::m::item`, `use std::m::{a, b}`, aliases,
    and multi-line brace groups. Relative imports (`use super::...`) are
    not file dependencies and are skipped.
    """
    result = []
    lines = text.splitlines()
    i = 0
    while i < len(lines):
        match = USE_RE.match(lines[i])
        if not match:
            i += 1
            continue
        start = i + 1
        stmt = lines[i][match.end():].strip()
        while stmt.count("{") > stmt.count("}") and i + 1 < len(lines):
            i += 1
            stmt += " " + lines[i].strip()
        # Trim trailing line comments (`//` and `#`), then take the path
        # prefix before any brace group or terminator.
        stmt = re.split(r"//", stmt, 1)[0]
        stmt = re.split(r"#", stmt, 1)[0]
        head = re.split(r"[{;]", stmt, 1)[0].strip()
        parts = [p.strip() for p in head.split("::") if p.strip()]
        if (
            len(parts) >= 2
            and parts[0] in ("std", "tg_compiler")
            and all(IDENT_RE.match(p) for p in parts)
        ):
            result.append((start, "%s::%s" % (parts[0], parts[1]), head))
        i += 1
    return result


def dependency_graph(members):
    """Build member -> set(dependency member) plus the raw import records."""
    deps = {key: set() for key in members}
    errors = []
    for key, member in members.items():
        try:
            text = (REPO_ROOT / member["rel"]).read_text(encoding="utf-8")
        except OSError as exc:
            die("cannot read member '%s': %s" % (member["rel"], exc))
        for lineno, dep, raw in extract_imports(text):
            if dep not in members:
                errors.append(
                    "NON_MEMBER %s:%d: imports %s (not a manifest member)"
                    % (member["rel"], lineno, dep)
                )
                continue
            if dep != key:
                deps[key].add(dep)
    for err in errors:
        print("bootstrap_slices: error: %s" % err, file=sys.stderr)
    if errors:
        die("%d non-member dependency import(s); the manifest is not closed" % len(errors))
    return deps


def transitive_closure(root, deps):
    seen = set()
    stack = [root]
    while stack:
        key = stack.pop()
        if key in seen:
            continue
        seen.add(key)
        for dep in sorted(deps.get(key, ())):
            if dep not in seen:
                stack.append(dep)
    return seen


def topo_order(nodes, deps):
    """Leaves-first order, deterministic (lexicographic ties).

    Kahn's algorithm; when an import cycle stalls the queue the unemitted
    node with the fewest pending dependencies (lexicographically smallest
    on ties) is emitted to break the cycle.  This keeps the order as
    leaves-first as the cycle structure allows.
    """
    pending = {n: set(d for d in deps.get(n, ()) if d in nodes and d != n) for n in nodes}
    dependents = {n: set() for n in nodes}
    for node, ds in pending.items():
        for dep in ds:
            dependents[dep].add(node)
    ready = [n for n in nodes if not pending[n]]
    heapq.heapify(ready)
    order = []
    emitted = set()
    while len(order) < len(nodes):
        if ready:
            node = heapq.heappop(ready)
            if node in emitted:
                continue
        else:
            candidates = [n for n in nodes if n not in emitted]
            node = min(candidates, key=lambda n: (len(pending[n]), n))
        order.append(node)
        emitted.add(node)
        for dependent in sorted(dependents[node]):
            pending[dependent].discard(node)
            if not pending[dependent] and dependent not in emitted:
                heapq.heappush(ready, dependent)
    return order


def close_over(nodes, deps):
    closed = set(nodes)
    stack = list(nodes)
    while stack:
        node = stack.pop()
        for dep in sorted(deps.get(node, ())):
            if dep not in closed:
                closed.add(dep)
                stack.append(dep)
    return closed


def write_slice_manifest(path, version, keys, members):
    lines = ["version: %s" % version, ""]
    for kind in ("std", "compiler"):
        for key in sorted(k for k in keys if members[k]["kind"] == kind):
            lines.append("%s: %s" % (kind, members[key]["file"]))
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def normalize_root(root, members):
    candidate = root.strip()
    if candidate.endswith(".tg"):
        candidate = candidate[:-3]
    candidate = candidate.replace("/", "::")
    if candidate in members:
        return candidate
    if "::" not in candidate:
        for kind in ("tg_compiler", "std"):
            key = "%s::%s" % (kind, candidate)
            if key in members:
                return key
    die("root '%s' is not a manifest member" % root)


def parse_sizes(raw):
    sizes = []
    for token in re.split(r"[,\s]+", raw.strip()):
        if not token:
            continue
        try:
            size = int(token)
        except ValueError:
            die("invalid slice size '%s'" % token)
        if size <= 0:
            die("slice size must be positive, got %d" % size)
        if size not in sizes:
            sizes.append(size)
    if not sizes:
        die("no slice sizes given")
    return sorted(sizes)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Emit dependency-closed bootstrap compiler slices."
    )
    parser.add_argument("--manifest", default=DEFAULT_MANIFEST,
                        help="kernel manifest (default: %s)" % DEFAULT_MANIFEST)
    parser.add_argument("--root", default=DEFAULT_ROOT,
                        help="closure root module (default: %s)" % DEFAULT_ROOT)
    parser.add_argument("--sizes", default=DEFAULT_SIZES,
                        help="space/comma separated slice sizes (default: %r)" % DEFAULT_SIZES)
    parser.add_argument("--out-dir", default="build/slices",
                        help="output directory (default: build/slices)")
    args = parser.parse_args(argv)

    manifest_path = Path(args.manifest)
    if not manifest_path.is_absolute():
        manifest_path = REPO_ROOT / manifest_path
    version, members, _order = parse_manifest(manifest_path)
    root = normalize_root(args.root, members)
    deps = dependency_graph(members)
    closure = transitive_closure(root, deps)
    topo = topo_order(closure, deps)
    sizes = parse_sizes(args.sizes)

    out_dir = Path(args.out_dir)
    if not out_dir.is_absolute():
        out_dir = REPO_ROOT / out_dir

    if len(topo) < len(closure):
        die("internal: topological order lost modules (%d < %d)" % (len(topo), len(closure)))

    for size in sizes:
        base = topo if size >= len(topo) else topo[:size]
        slice_keys = close_over(base, deps)
        manifest_out = out_dir / ("k%d.manifest" % size)
        write_slice_manifest(manifest_out, version, slice_keys, members)
        rel = manifest_out.relative_to(REPO_ROOT) if manifest_out.is_relative_to(REPO_ROOT) else manifest_out
        print("SLICE K=%d modules=%d manifest=%s" % (size, len(slice_keys), rel))
    return 0


if __name__ == "__main__":
    sys.exit(main())
