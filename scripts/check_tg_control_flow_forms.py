#!/usr/bin/env python3
"""Check Tangerine control-flow style forms in .tg files.

Defaults to scanning std/, tg_compiler/, and golden/.
Reports Rust-style brace control forms and use of `continue` (Tangerine uses `next`).
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
    out: list[str] = []
    in_string = False
    escaped = False
    for ch in line:
        if in_string:
            if escaped:
                escaped = False
                continue
            if ch == "\\":
                escaped = True
                continue
            if ch == '"':
                in_string = False
            continue

        if ch == '#':
            break
        if ch == '"':
            in_string = True
            continue
        out.append(ch)
    return "".join(out)


def iter_tg_files(roots: list[Path]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        if not root.exists():
            continue
        if root.is_file() and root.suffix == ".tg":
            files.append(root)
            continue
        if root.is_dir():
            files.extend(sorted(root.rglob("*.tg")))
    return files


def scan_file(path: Path) -> list[str]:
    issues: list[str] = []
    for idx, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        scan_line = strip_strings_and_comments(line)
        if BRACE_CONTROL_RE.search(scan_line):
            issues.append(f"{path}:{idx}: brace-style control flow")
        if CONTINUE_RE.search(scan_line):
            issues.append(f"{path}:{idx}: uses `continue` (prefer `next`)")
    return issues


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("roots", nargs="*", help="Folders/files to scan")
    args = parser.parse_args()

    roots = [Path(r) for r in (args.roots or DEFAULT_ROOTS)]
    files = iter_tg_files(roots)

    all_issues: list[str] = []
    for file_path in files:
        all_issues.extend(scan_file(file_path))

    if all_issues:
        print("Control-flow form issues found:")
        for issue in all_issues:
            print(issue)
        return 1

    print(f"OK: scanned {len(files)} .tg files")
    return 0


if __name__ == "__main__":
    sys.exit(main())
