#!/usr/bin/env python3
"""closure_bare_name_collisions.py — the seed bare-name collision tripwire.

The seed's nominal table and its flat lowering tables are keyed by BARE
names with first-wins semantics; two modules declaring the same bare
nominal name are a latent identity hazard (the EnumLayout incident: a
literal in tg_compiler::layout_engine resolved std::alloc's nominal and
E0203 fired on a field that does not exist in the compiler's struct).

This script reads bootstrap/compiler_kernel.manifest, extracts every
top-level `struct` / `enum` / `trait` declaration name per closure member,
and prints the sorted bare names declared in MORE THAN ONE module.  The
gate pins the exact known set so a NEW collision fails immediately (and a
removed one is visible), without pretending the existing five are fixed:
they are the collision-parity corpus's subject.
"""

import collections
import re
import sys

MANIFEST = "bootstrap/compiler_kernel.manifest"
# Every declaration kind that feeds a BARE-keyed seed table:
#   struct/enum/trait -> the nominal table;
#   const/static       -> the flat const/static lowering tables;
#   def                -> the flat callable/value tables (only PUBLIC
#                         names participate closure-wide);
#   typealias          -> the flat type-name table.
# Enum-variant constructors are collected separately (variant names).
DECL = re.compile(
    r"^(?:pub )?(struct|enum|trait|typealias|const|static|def)\s+"
    r"([A-Za-z_][A-Za-z_0-9]*)",
    re.M,
)
VARIANT = re.compile(r"^enum\s+([A-Za-z_][A-Za-z_0-9]*)\s*$", re.M)


def main() -> int:
    files = []
    try:
        with open(MANIFEST, encoding="utf-8") as fh:
            for line in fh:
                m = re.match(r"^(std|compiler):\s+(\S+\.tg)", line.strip())
                if m:
                    top = "std" if m.group(1) == "std" else "tg_compiler"
                    files.append(f"{top}/{m.group(2)}")
    except OSError as exc:
        print(f"closure_bare_name_collisions: cannot read {MANIFEST}: {exc}", file=sys.stderr)
        return 2
    by_name = collections.defaultdict(set)
    variants = collections.defaultdict(set)
    for path in sorted(set(files)):
        try:
            with open(path, encoding="utf-8") as fh:
                src = fh.read()
        except OSError as exc:
            print(f"closure_bare_name_collisions: cannot read {path}: {exc}", file=sys.stderr)
            return 2
        mod = path[:-3].replace("/", "::")
        for m in DECL.finditer(src):
            by_name[m.group(2)].add(f"{m.group(1)}@{mod}")
        for m in VARIANT.finditer(src):
            # the enum body's variant names are the following indented
            # `Name` / `Name(...)` lines
            body = src[m.end():]
            for vm in re.finditer(r"^\s{2,}([A-Z][A-Za-z_0-9]*)\s*(?:\(|$)", body, re.M):
                variants[vm.group(1)].add(mod)
                if not vm.group(0).endswith("(") and not body[vm.end():].lstrip().startswith("("):
                    pass
    # Gate output: the NOMINAL (struct/enum/trait) bare-name collisions —
    # these are the first-wins nominal-table hazards (the EnumLayout
    # incident).  The wider report (const/static/def/typealias/variant
    # duplicates) is informational: many are legitimate per-module
    # helpers resolved through qualified/method tables, but each is a
    # candidate for the tracked bare-name-elimination work.
    nominal = sorted(
        name
        for name, decls in by_name.items()
        if len({d.split("@")[1] for d in decls}) > 1
        and all(d.split("@")[0] in ("struct", "enum", "trait") for d in decls)
    )
    print(" ".join(nominal))
    wide = sorted(
        name
        for name, decls in by_name.items()
        if len({d.split("@")[1] for d in decls}) > 1 and name not in nominal
    )
    vdups = sorted(name for name, mods in variants.items() if len(mods) > 1)
    print(
        "closure_bare_name_collisions (informational): decl="
        + " ".join(wide)
        + " | variants="
        + " ".join(vdups),
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
