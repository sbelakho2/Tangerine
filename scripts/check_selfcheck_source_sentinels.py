#!/usr/bin/env python3
"""check_selfcheck_source_sentinels.py - source-level sentinel invariants.

Audit P2: the output verifier (scripts/check_selfcheck_sentinel.sh) proves
that an executed selfcheck printed exactly one sentinel; this check proves
the SOURCE cannot bypass it:

  * every component selfcheck (every tg_* executable in
    stage0_ocaml/selfcheck/dune except the two completeness gates) has at
    least one Selfcheck_sentinel.emit/emit_and_exit call naming ITS OWN
    executable name;
  * no component selfcheck has a raw `exit 0` CODE path (occurrences
    inside strings and comments do not count) - every success exit must
    go through the sentinel emitter.

Exit 0 clean, 1 on any violation.
"""

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DUNE = ROOT / "stage0_ocaml" / "selfcheck" / "dune"
SELFCHECK_DIR = ROOT / "stage0_ocaml" / "selfcheck"

COMPLETENESS_GATES = {"tg_bootstrap_gate", "tg_bootstrap_selfcheck"}


def strip_strings_and_comments(source: str) -> str:
    source = re.sub(r"\(\*.*?\*\)", "", source, flags=re.S)
    source = re.sub(r"#.*", "", source)
    source = re.sub(r'"(\\.|[^"\\])*"', '""', source)
    return source


def main() -> int:
    names = sorted(set(re.findall(r"tg_[a-z0-9_]+", DUNE.read_text())))
    violations = []
    for name in names:
        if name in COMPLETENESS_GATES:
            continue
        path = SELFCHECK_DIR / f"{name}.ml"
        if not path.exists():
            violations.append(f"{name}: missing source file")
            continue
        raw = path.read_text()
        own = len(
            re.findall(
                r'Selfcheck_sentinel\.(?:emit|emit_and_exit) "%s"' % re.escape(name),
                raw,
            )
        )
        code_exits = len(re.findall(r"\bexit 0\b", strip_strings_and_comments(raw)))
        if own < 1:
            violations.append(
                f"{name}: no Selfcheck_sentinel emit naming its own name"
            )
        if code_exits:
            violations.append(
                f"{name}: {code_exits} raw `exit 0` code path(s) - success exits must use emit_and_exit"
            )
    if violations:
        for violation in violations:
            print(f"SELFCHECK-SOURCE: FAIL - {violation}", file=sys.stderr)
        return 1
    print(f"SELFCHECK-SOURCE: PASS - {len(names) - len(COMPLETENESS_GATES)} component selfchecks emit their own sentinel with no bypass exit")
    return 0


if __name__ == "__main__":
    sys.exit(main())
