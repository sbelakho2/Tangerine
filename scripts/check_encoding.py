#!/usr/bin/env python3
"""check_encoding.py — repository text-file encoding gate (lint lane).

Rules (the lane's byte-level encoding contract):

  * every scanned text file decodes as valid UTF-8. Source files MUST be
    valid UTF-8 (docs/current/unicode_policy.md §1.1); the compiler rejects
    invalid byte sequences with E9029 / INV-PARSE-002.
  * no UTF-8 BOM (0xEF 0xBB 0xBF) is present. The lexer tolerates a BOM
    (unicode_policy.md §1.2 "permitted but discouraged") and the canonical
    formatter strips one on output, so the checked-in tree must stay
    BOM-free — otherwise `tg fmt --check` in this same lane would fail on
    the next format pass.

Line endings are deliberately NOT policed here: unicode_policy.md §1.3
accepts LF / CRLF / CR as line terminators at the lexer, and the formatter
normalization to LF is already enforced by the lane's `tg fmt --check`
step. Identifier NFC normalization (unicode_policy.md §2.3) is a
compiler/linter rule, not a byte-level encoding rule.

The lane invokes the script with no arguments, so the default root is the
repository root. VCS metadata, generated/tooling trees (build/, .kilo/,
node_modules/, ...) and detected binaries (known binary suffixes or NUL
bytes) are skipped; those are not source.

Findings are printed sorted as ``<path>: <message>``; exit 0 when clean,
1 when any finding exists.
"""

from __future__ import annotations

import argparse
import os
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent

BOM = b"\xef\xbb\xbf"

# Directories that never contain checked-in source: VCS metadata, build
# outputs and local tooling state (see .gitignore: build/, __pycache__/,
# node_modules/, dune _build/, .kilo/ is Kilo's local worktree/tool state).
EXCLUDED_DIRS = {
    ".git",
    ".hg",
    ".svn",
    ".kilo",
    "_build",
    "__pycache__",
    ".mypy_cache",
    ".pytest_cache",
    "build",
    "node_modules",
    "target",
}

# Known binary formats: never text candidates even without NUL bytes.
SKIP_SUFFIXES = {
    ".a",
    ".bin",
    ".class",
    ".dll",
    ".dylib",
    ".gif",
    ".gz",
    ".icns",
    ".ico",
    ".jar",
    ".jpeg",
    ".jpg",
    ".lib",
    ".mp3",
    ".mp4",
    ".o",
    ".otf",
    ".pdf",
    ".png",
    ".pyc",
    ".pyo",
    ".so",
    ".tgcov",
    ".ttf",
    ".vsix",
    ".wasm",
    ".webp",
    ".woff",
    ".woff2",
    ".zip",
}

# The single deliberate invalid-UTF-8 fixture: tests/differential/negative/
# not_utf8.tg carries 0xFF 0xFE inside a string literal and MUST keep them —
# INV-PARSE-002 (invariants.toml negative = [.../not_utf8.tg],
# tests/differential/corpus.manifest) proves the compiler rejects invalid
# UTF-8 with E9029. Do not fix the file, and do not add further entries.
INVALID_UTF8_ALLOWLIST = {
    "tests/differential/negative/not_utf8.tg",
}


def repo_relative(path: Path) -> str:
    """Return the repo-root-relative posix path when possible."""
    try:
        return path.resolve().relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def iter_files(roots: list[Path]) -> list[Path]:
    """Yield candidate files under each root in sorted, deterministic order."""
    files: list[Path] = []
    for root in roots:
        if root.is_file() or root.is_symlink():
            files.append(root)
            continue
        if not root.is_dir():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            # Prune excluded and hidden-tooling directories in place so the
            # walk never descends into them.
            dirnames[:] = sorted(d for d in dirnames if d not in EXCLUDED_DIRS)
            for name in sorted(filenames):
                files.append(Path(dirpath) / name)
    return files


def is_text_candidate(path: Path) -> bool:
    return path.suffix.lower() not in SKIP_SUFFIXES


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("roots", nargs="*", default=["."], help="Files/folders to scan")
    args = parser.parse_args()

    findings: list[str] = []
    for file_path in iter_files([Path(r) for r in args.roots]):
        if file_path.is_symlink() or not file_path.is_file():
            continue
        if not is_text_candidate(file_path):
            continue

        rel = repo_relative(file_path)
        data = file_path.read_bytes()

        # Binary sniff: text files never contain NUL bytes. Compiled fixtures
        # (golden/smoke_test, tests/hello, ...) and OS metadata (.DS_Store)
        # are skipped here rather than mistaken for broken encodings.
        if b"\x00" in data:
            continue

        if data.startswith(BOM):
            findings.append(f"{rel}:1: UTF-8 BOM is not allowed")
            continue

        try:
            data.decode("utf-8")
        except UnicodeDecodeError as exc:
            if rel in INVALID_UTF8_ALLOWLIST:
                continue
            line_no = data.count(b"\n", 0, exc.start) + 1
            findings.append(f"{rel}:{line_no}: invalid UTF-8 ({exc})")

    if findings:
        print("Encoding issues found:")
        for finding in sorted(findings):
            print(finding)
        return 1

    print("OK: encoding check passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
