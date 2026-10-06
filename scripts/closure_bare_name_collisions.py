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
DECL = re.compile(r"^(?:pub )?(struct|enum|trait)\s+([A-Za-z_][A-Za-z_0-9]*)", re.M)


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
    by_name = collections.defaultdict(list)
    for path in sorted(set(files)):
        try:
            with open(path, encoding="utf-8") as fh:
                src = fh.read()
        except OSError as exc:
            print(f"closure_bare_name_collisions: cannot read {path}: {exc}", file=sys.stderr)
            return 2
        for m in DECL.finditer(src):
            by_name[m.group(2)].append(path[:-3].replace("/", "::"))
    dups = sorted(name for name, mods in by_name.items() if len(mods) > 1)
    print(" ".join(dups))
    return 0


if __name__ == "__main__":
    sys.exit(main())
