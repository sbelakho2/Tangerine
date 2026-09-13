#!/usr/bin/env python3
"""check_tg_control_flow_forms.py — canonical control-flow spelling gate.

Rules (the lane's control-flow style contract):

  * Control-flow headers use the Tangerine block forms (``if ... then``,
    ``while ... do``, ``match ... when ... end``, ``for ... do``,
    ``loop ... end``). Rust-style brace headers (``if x {``, ``while x {``,
    ``match x {``, ...) are rejected.
  * ``next`` is the canonical spelling of the loop-continue keyword;
    ``continue`` is a legacy alias that lexes to the same ``TokenKind::Next``
    (docs/current/grammar.md migration table — "Continue keyword:
    ``continue`` -> ``next`` (both accepted)") and is rejected here. The
    canonical formatter emits ``next`` (tg_compiler/formatter.tg
    ``StmtKind::StmtContinue``), so a ``continue`` in the tree would also
    fail the lane's ``tg fmt --check`` step.

String literals (both ``"..."`` and ``'...'`` char literals) and ``#``
comments are stripped before matching, so the legacy keyword mentioned in
comments, docs or diagnostic tables inside .tg files is not flagged.

The lane invokes the script with no arguments, so the default roots are
std/, tg_compiler/ and golden/. Findings are printed sorted as
``<path>:<line>: <message>``; exit 0 when clean, 1 when any finding exists.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

DEFAULT_ROOTS = ("std", "tg_compiler", "golden")

BRACE_CONTROL_RE = re.compile(r"^\s*(if|elsif|while|for|match|loop)\b[^=]*\{\s*$")
CONTINUE_RE = re.compile(r"\bcontinue\b")


def strip_strings_and_comments(line: str) -> str:
    """Blank out string/char literals and trailing comments from a line.

    Keeps the code portion (and column positions) so word matches cannot
    trigger on literal or comment text.
    """
    out: list[str] = []
    quote: str | None = None
    escaped = False
    for ch in line:
        if quote is not None:
            out.append(" ")
            if escaped:
                escaped = False
            elif ch == "\\":
                escaped = True
            elif ch == quote:
                quote = None
            continue

        if ch == "#":
            break
        if ch == '"' or ch == "'":
            quote = ch
            out.append(" ")
            continue
        out.append(ch)
    return "".join(out)


def iter_tg_files(roots: list[Path]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        if root.is_file():
            if root.suffix == ".tg":
                files.append(root)
            continue
        if root.is_dir():
            files.extend(sorted(p for p in root.rglob("*.tg") if p.is_file()))
    return sorted(files)


def scan_file(path: Path) -> list[str]:
    issues: list[str] = []
    try:
        text = path.read_text(encoding="utf-8")
    except UnicodeDecodeError:
        return [f"{path}: not valid UTF-8 (run check_encoding.py first)"]
    except OSError as exc:
        return [f"{path}: unreadable ({exc})"]

    for idx, line in enumerate(text.splitlines(), start=1):
        scan_line = strip_strings_and_comments(line)
        if BRACE_CONTROL_RE.search(scan_line):
            issues.append(f"{path}:{idx}: brace-style control flow")
        if CONTINUE_RE.search(scan_line):
            issues.append(f"{path}:{idx}: uses `continue` (prefer `next`)")
    return issues


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("roots", nargs="*", help="Folders/files to scan")
    args = parser.parse_args()

    roots = [Path(r) for r in (args.roots or DEFAULT_ROOTS)]
    files = iter_tg_files(roots)

    all_issues: list[str] = []
    for file_path in files:
        all_issues.extend(scan_file(file_path))

    if all_issues:
        print("Control-flow form issues found:")
        for issue in sorted(all_issues):
            print(issue)
        return 1

    print(f"OK: scanned {len(files)} .tg files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
