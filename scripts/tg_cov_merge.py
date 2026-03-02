#!/usr/bin/env python3
"""Merge Tangerine coverage JSON files with branch-aware keys."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path
from typing import Any


def record_key(record: dict[str, Any]) -> tuple[Any, ...]:
    return (
        record.get("file"),
        record.get("function"),
        record.get("line"),
        record.get("column"),
        record.get("branch_id"),
        record.get("arm_id"),
    )


def merge_records(inputs: list[dict[str, Any]]) -> list[dict[str, Any]]:
    merged: dict[tuple[Any, ...], dict[str, Any]] = {}
    for rec in inputs:
        key = record_key(rec)
        if key not in merged:
            merged[key] = dict(rec)
            continue
        dst = merged[key]
        dst["hits"] = int(dst.get("hits", 0)) + int(rec.get("hits", 0))
        dst["count"] = int(dst.get("count", 0)) + int(rec.get("count", 0))
    return list(merged.values())


def load_coverage(path: Path) -> list[dict[str, Any]]:
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"warning: skipping malformed coverage file {path}: {exc}", file=sys.stderr)
        return []
    if isinstance(raw, dict):
        if "records" in raw and isinstance(raw["records"], list):
            return [r for r in raw["records"] if isinstance(r, dict)]
        if "coverage" in raw and isinstance(raw["coverage"], list):
            return [r for r in raw["coverage"] if isinstance(r, dict)]
    if isinstance(raw, list):
        return [r for r in raw if isinstance(r, dict)]
    return []


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("output", help="Output JSON path")
    parser.add_argument("inputs", nargs="+", help="Input coverage JSON files")
    args = parser.parse_args()

    all_records: list[dict[str, Any]] = []
    for inp in args.inputs:
        all_records.extend(load_coverage(Path(inp)))

    merged = merge_records(all_records)
    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(json.dumps({"records": merged}, indent=2), encoding="utf-8")
    print(f"merged {len(all_records)} records -> {len(merged)} records")
    return 0


if __name__ == "__main__":
    sys.exit(main())
