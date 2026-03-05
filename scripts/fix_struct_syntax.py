#!/usr/bin/env python3
"""Normalize brace-style Tangerine declarations to `... end` form.

Supports .tg files directly and markdown files by rewriting only ```tangerine fences.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

OPEN_RE = re.compile(r"^(?P<indent>\s*)(?P<kw>def|struct|enum|impl|trait|module|extern)\b(?P<rest>.*)\{\s*$")
CLOSE_RE = re.compile(r"^\s*}\s*$")


class TransformError(Exception):
    pass


def transform_tangerine_lines(lines: list[str]) -> tuple[list[str], int]:
    out: list[str] = []
    stack: list[str] = []
    changes = 0

    for line in lines:
        m_open = OPEN_RE.match(line)
        if m_open:
            out.append(f"{m_open.group('indent')}{m_open.group('kw')}{m_open.group('rest').rstrip()}")
            stack.append(m_open.group("kw"))
            changes += 1
            continue

        if CLOSE_RE.match(line) and stack:
            kw = stack[-1]
            indent = re.match(r"^\s*", line).group(0)
            out.append(f"{indent}end")
            stack.pop()
            changes += 1
            continue

        out.append(line)

    if stack:
        raise TransformError(f"unclosed blocks after transform: {stack}")

    return out, changes


def transform_content(path: Path, content: str) -> tuple[str, int]:
    if path.suffix.lower() in {".md", ".markdown"}:
        lines = content.splitlines()
        out: list[str] = []
        in_tg = False
        buffer: list[str] = []
        changes = 0

        for line in lines:
            stripped = line.strip().lower()
            if stripped.startswith("```tangerine") and not in_tg:
                in_tg = True
                out.append(line)
                buffer = []
                continue
            if stripped == "```" and in_tg:
                transformed, delta = transform_tangerine_lines(buffer)
                out.extend(transformed)
                out.append(line)
                in_tg = False
                buffer = []
                changes += delta
                continue
            if in_tg:
                buffer.append(line)
            else:
                out.append(line)

        if in_tg:
            raise TransformError("unterminated ```tangerine block")
        return "\n".join(out) + ("\n" if content.endswith("\n") else ""), changes

    transformed, changes = transform_tangerine_lines(content.splitlines())
    return "\n".join(transformed) + ("\n" if content.endswith("\n") else ""), changes


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("paths", nargs="+", help="Files to rewrite")
    parser.add_argument("--dry-run", action="store_true", help="Preview only")
    args = parser.parse_args()

    total_changes = 0
    for raw in args.paths:
        path = Path(raw)
        if not path.exists() or not path.is_file():
            print(f"ERROR: missing file: {path}")
            return 2
        try:
            content = path.read_text(encoding="utf-8")
            new_content, changes = transform_content(path, content)
        except (UnicodeDecodeError, OSError, TransformError) as exc:
            print(f"ERROR: {path}: {exc}")
            return 2

        if changes > 0:
            total_changes += changes
            if args.dry_run:
                print(f"would-update {path} ({changes} changes)")
            else:
                backup = path.with_suffix(path.suffix + ".bak")
                backup.write_text(content, encoding="utf-8")
                path.write_text(new_content, encoding="utf-8")
                print(f"updated {path} ({changes} changes, backup: {backup})")

    print(f"done: {total_changes} changes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
