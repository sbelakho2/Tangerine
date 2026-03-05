#!/usr/bin/env python3
"""Validate UTF-8 encoding and reject UTF-8 BOM in text files."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

BOM = b"\xef\xbb\xbf"
SKIP_SUFFIXES = {
    ".png", ".jpg", ".jpeg", ".gif", ".ico", ".pdf", ".zip", ".gz", ".tgcov", ".bin", ".so", ".dylib"
}


def is_text_candidate(path: Path) -> bool:
    return path.suffix.lower() not in SKIP_SUFFIXES


def iter_files(roots: list[Path]) -> list[Path]:
    files: list[Path] = []
    for root in roots:
        if root.is_file():
            files.append(root)
        elif root.is_dir():
            seen: set[Path] = set()
            for p in root.rglob("*"):
                resolved = p.resolve()
                if resolved in seen:
                    continue
                seen.add(resolved)
                if p.is_file() and not p.is_symlink():
                    files.append(p)
    return files


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("roots", nargs="*", default=["."], help="Files/folders to scan")
    args = parser.parse_args()

    bad: list[str] = []
    for file_path in iter_files([Path(r) for r in args.roots]):
        if not is_text_candidate(file_path):
            continue
        data = file_path.read_bytes()
        if data.startswith(BOM):
            bad.append(f"{file_path}: UTF-8 BOM is not allowed")
            continue
        try:
            data.decode("utf-8")
        except UnicodeDecodeError as exc:
            bad.append(f"{file_path}: invalid UTF-8 ({exc})")

    if bad:
        print("Encoding issues found:")
        for issue in bad:
            print(issue)
        return 1

    print("OK: encoding check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
