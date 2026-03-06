#!/usr/bin/env python3
"""Validate keyword tables stay in sync across stage0 and tg_compiler.

Extracts keyword lists from:
  1. stage0/lib/token.ml   — keyword_set (hard) + soft_keyword_set
  2. tg_compiler/token.tg  — init_keyword_map() entries

Reports any keyword present in one source but missing from the other.
Exit code 0 if in sync, 1 otherwise.
"""

import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent

def extract_ocaml_keywords(path: Path) -> tuple[set[str], set[str]]:
    """Return (hard_keywords, soft_keywords) from token.ml."""
    text = path.read_text()

    hard = set()
    soft = set()

    # Extract keyword_set block — from "let keyword_set =" to next blank line or "let " at column 0
    m = re.search(r'let keyword_set =\n(.*?)(?=\nlet )', text, re.DOTALL)
    if m:
        hard = set(re.findall(r'"(\w+)"', m.group(1)))

    # Extract soft_keyword_set block
    m = re.search(r'let soft_keyword_set =\n(.*?)(?=\nlet )', text, re.DOTALL)
    if m:
        soft = set(re.findall(r'"(\w+)"', m.group(1)))

    return hard, soft


def extract_tg_keywords(path: Path) -> set[str]:
    """Return all keyword strings from init_keyword_map() in token.tg."""
    text = path.read_text()
    m = re.search(r'def init_keyword_map\(\).*?^end', text, re.DOTALL | re.MULTILINE)
    if not m:
        print(f"ERROR: Could not find init_keyword_map in {path}", file=sys.stderr)
        sys.exit(2)
    block = m.group(0)
    return set(re.findall(r'm\.insert\("(\w+)"', block))


def main() -> int:
    token_ml = REPO / "stage0" / "lib" / "token.ml"
    token_tg = REPO / "tg_compiler" / "token.tg"

    if not token_ml.exists():
        print(f"ERROR: {token_ml} not found", file=sys.stderr)
        return 2
    if not token_tg.exists():
        print(f"ERROR: {token_tg} not found", file=sys.stderr)
        return 2

    hard, soft = extract_ocaml_keywords(token_ml)
    all_ocaml = hard | soft
    tg_kws = extract_tg_keywords(token_tg)

    # "fn" maps to Def in tg_compiler and "mod" maps to Module —
    # they're aliases, counted as present if the canonical form is present.
    # Normalize: "fn" is an alias for "def", "mod" is an alias for "module".
    # Both should be in the tg set (and they are via insert calls).

    overlap = hard & soft
    only_ocaml = all_ocaml - tg_kws
    only_tg = tg_kws - all_ocaml

    ok = True

    if overlap:
        print(f"FAIL: {len(overlap)} keyword(s) in BOTH hard and soft sets:")
        for kw in sorted(overlap):
            print(f"  - {kw}")
        ok = False

    if only_ocaml:
        print(f"FAIL: {len(only_ocaml)} keyword(s) in stage0 but NOT in tg_compiler:")
        for kw in sorted(only_ocaml):
            category = "hard" if kw in hard else "soft"
            print(f"  - {kw} ({category})")
        ok = False

    if only_tg:
        print(f"FAIL: {len(only_tg)} keyword(s) in tg_compiler but NOT in stage0:")
        for kw in sorted(only_tg):
            print(f"  - {kw}")
        ok = False

    if ok:
        print(f"OK: {len(all_ocaml)} stage0 keywords ({len(hard)} hard + {len(soft)} soft) "
              f"in sync with {len(tg_kws)} tg_compiler keywords.")
        return 0
    return 1


if __name__ == "__main__":
    sys.exit(main())
