#!/usr/bin/env python3
"""check_copy_mutation.py — the copy-mutation (lost-update) source gate.

Tangerine values are bound BY VALUE. Two structural idioms therefore mutate a
COPY and silently lose the update unless the updated value is written back:

  * a match arm binding a ``Some(x)`` / ``Some(mut x)`` payload out of a
    by-value table read (``map.get(k)``, ``vec[i]``) — ``x`` is a copy of the
    stored element (``get_mut`` is the mutating accessor and is exempt);
  * a ``for x in <collection> do`` binding — ``x`` is a copy of each element.

The gate flags those two idioms when the arm/loop body mutates the binding
(field assignment, a mutating method, or a rebind) and no write-back of the
binding appears in the body (``return ... x``, ``Some(x``, ``Ok(x``,
``insert(..., x)``, ``push(x)``, ``... = x``, ``coll[i] = x``).

Scope: the compiler sources under the requested root(s), defaulting to
``tg_compiler``. ``mir.tg`` is excluded while the MIR builder's copy-state
persistence workstream lands; pass ``--include-mir`` to scan it too. Findings
print sorted as ``<path>:<line>: COPY_MUTATION ...``; exit 0 when clean, 1 on
any finding, 2 on a usage/IO error.

The gate is deliberately narrow (no type inference): it is green on the
current tree and fires on every pre-fix site of the class the kernel fixed
(``driver.tg`` rename grouping, ``linker.tg`` LTO reachability filter,
``parser.tg`` where-clause bounds / trailing receiver convention).
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

MUT_METHODS = (
    r"(?:push|insert|remove|pop|clear|extend|append|sort|retain|truncate|"
    r"swap|reverse|fill|add|update|put|add_all|insert_all)"
)
FIELD_ASSIGN_RE = re.compile(
    r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*[A-Za-z_][A-Za-z0-9_]*\s*"
    r"(?:=|\+=|-=|\*=|/=|\|=|&=)(?!=)"
)
NESTED_MUT_RE = re.compile(
    r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*[A-Za-z_][A-Za-z0-9_]*\s*\.\s*"
    + MUT_METHODS
    + r"\s*\("
)
SINGLE_MUT_RE = re.compile(
    r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\.\s*" + MUT_METHODS + r"\s*\("
)
SOME_ARM_RE = re.compile(
    r"^(\s*)(?:\}\s*)?when\s+(?:Option::)?Some\(\s*(?:mut\s+)?"
    r"([A-Za-z_][A-Za-z0-9_]*)\s*\)\s+then\s*$"
)
FOR_RE = re.compile(r"^(\s*)for\s+([A-Za-z_][A-Za-z0-9_]*)\s+in\s+(.+?)\s+do\s*$")


def strip_comment(line: str) -> str:
    """Drop a trailing ``#`` comment; keep string-literal contents."""
    out: list[str] = []
    in_str = False
    escaped = False
    for ch in line:
        if escaped:
            out.append(ch)
            escaped = False
            continue
        if ch == "\\" and in_str:
            out.append(ch)
            escaped = True
            continue
        if ch == '"':
            in_str = not in_str
            out.append(ch)
            continue
        if ch == "#" and not in_str:
            break
        out.append(ch)
    return "".join(out)


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" "))


def block_body(lines: list[str], start: int, header_indent: int) -> list[str]:
    """Lines of the block opened by a header at ``header_indent``."""
    body: list[str] = []
    i = start + 1
    while i < len(lines):
        line = lines[i]
        if line.strip() == "":
            i += 1
            continue
        if indent_of(line) <= header_indent:
            break
        body.append(line)
        i += 1
    return body


def mutates(bind: str, body_text: str) -> bool:
    for rx in (FIELD_ASSIGN_RE, NESTED_MUT_RE, SINGLE_MUT_RE):
        for m in rx.finditer(body_text):
            if m.group(1) == bind:
                return True
    return False


def has_write_back(bind: str, body_text: str) -> bool:
    """Does the body persist the mutated binding?

    Accepted write-backs: ``return ... x``; ``Some(x`` / ``Ok(x`` (the value
    is handed to the arm's result); ``insert(..., x)`` / ``push(x)`` /
    ``coll[i] = x`` / ``... = x`` (stored back into a table/collection).
    """
    esc = re.escape(bind)
    patterns = (
        r"\breturn\b[^\n]*\b" + esc + r"\b",
        r"\b(?:Option::)?Some\s*\(\s*" + esc + r"\b",
        r"\b(?:Option::)?Ok\s*\(\s*" + esc + r"\b",
        r"\binsert\s*\([^\n]*\b" + esc + r"\b",
        r"\bpush\s*\(\s*" + esc + r"\b",
        r"=\s*" + esc + r"\s*$",
        r"\[\s*[A-Za-z_][A-Za-z0-9_]*\s*\]\s*=\s*" + esc + r"\b",
    )
    return any(re.search(p, body_text, re.M) for p in patterns)


def scan_match_arms(path: Path, lines: list[str]) -> list[str]:
    findings: list[str] = []
    for i, line in enumerate(lines):
        m = SOME_ARM_RE.match(line)
        if not m:
            continue
        indent, bind = len(m.group(1)), m.group(2)
        scrutinee = ""
        k = i - 1
        while k >= 0:
            stripped = lines[k].strip()
            if stripped.startswith("match "):
                scrutinee = stripped
                break
            k -= 1
        if "get_mut(" in scrutinee:
            continue
        is_table_read = (
            ".get(" in scrutinee
            or ".expect(" in scrutinee
            or re.search(r"\[[^\]]+\]", scrutinee) is not None
        )
        if not is_table_read:
            continue
        body = block_body(lines, i, indent)
        body_text = "\n".join(body)
        if mutates(bind, body_text) and not has_write_back(bind, body_text):
            findings.append(
                f"{path}:{i + 1}: COPY_MUTATION match-binding `{bind}` is a "
                f"copy of a by-value table read ({scrutinee!r}) and is mutated "
                "with no write-back (lost update): store it back "
                "(insert/push/index-assign/return Some(binding)) or use the "
                "`get_mut` accessor"
            )
    return findings


def scan_for_loops(path: Path, lines: list[str]) -> list[str]:
    findings: list[str] = []
    for i, line in enumerate(lines):
        m = FOR_RE.match(line)
        if not m:
            continue
        indent, bind, coll = len(m.group(1)), m.group(2), m.group(3)
        if ".." in coll:
            continue
        body = block_body(lines, i, indent)
        body_text = "\n".join(body)
        if mutates(bind, body_text) and not has_write_back(bind, body_text):
            findings.append(
                f"{path}:{i + 1}: COPY_MUTATION for-binding `{bind}` over "
                f"{coll!r} is a copy and is mutated with no write-back into "
                "the collection (lost update): use an index loop and store the "
                "updated element back (coll[i] = binding)"
            )
    return findings


def scan_file(path: Path) -> list[str]:
    lines = [strip_comment(l.rstrip("\n")) for l in path.read_text().splitlines()]
    findings = scan_match_arms(path, lines)
    findings += scan_for_loops(path, lines)
    return findings


def collect_targets(roots: list[str], include_mir: bool) -> list[Path]:
    targets: list[Path] = []
    for root in roots:
        p = Path(root)
        if p.is_file():
            targets.append(p)
            continue
        if not p.is_dir():
            print(f"check_copy_mutation: not a file or directory: {root}", file=sys.stderr)
            raise SystemExit(2)
        targets.extend(sorted(p.glob("*.tg")))
    if not include_mir:
        targets = [t for t in targets if t.name != "mir.tg"]
    return sorted(set(targets))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument(
        "roots",
        nargs="*",
        default=["tg_compiler"],
        help="files/directories to scan (default: tg_compiler)",
    )
    parser.add_argument(
        "--include-mir",
        action="store_true",
        help="also scan mir.tg (excluded by default while the MIR builder "
        "copy-state persistence workstream lands)",
    )
    args = parser.parse_args()
    roots = args.roots or ["tg_compiler"]
    findings: list[str] = []
    for path in collect_targets(roots, args.include_mir):
        if path.suffix != ".tg":
            continue
        findings.extend(scan_file(path))
    for finding in sorted(findings):
        print(finding)
    if findings:
        print(
            f"check_copy_mutation: {len(findings)} finding(s) — the "
            "copy-mutation (lost-update) gate FAILED",
            file=sys.stderr,
        )
        return 1
    print(
        f"check_copy_mutation: clean ({len(collect_targets(roots, args.include_mir))} "
        "file(s) scanned)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
