#!/usr/bin/env python3
import argparse
import glob
import json
from pathlib import Path

HEADER_KEYS = [
    "schema_version",
    "edition",
    "tgc_version",
    "target",
    "target_triple",
    "branch_id_scheme",
    "arm_id_scheme",
    "build_id",
]


def read_jsonl(path: Path):
    with path.open("r", encoding="utf-8") as f:
        lines = [line.strip() for line in f if line.strip()]
    if not lines:
        raise ValueError(f"empty coverage file: {path}")
    header = json.loads(lines[0])
    records = [json.loads(line) for line in lines[1:]]
    return header, records


def validate_header(base, other, path):
    for key in HEADER_KEYS:
        if base.get(key) != other.get(key):
            raise ValueError(
                f"header mismatch in {path}: key={key} expected={base.get(key)!r} got={other.get(key)!r}"
            )


def main():
    parser = argparse.ArgumentParser(description="Merge Tangerine .tgcov JSONL files")
    parser.add_argument("--in", dest="input_pattern", required=True)
    parser.add_argument("--out", dest="output", required=True)
    args = parser.parse_args()

    files = [Path(p) for p in sorted(glob.glob(args.input_pattern))]
    if not files:
        raise SystemExit("no input files matched")

    base_header, base_records = read_jsonl(files[0])
    merged = {}

    def add_record(record):
        key = (record["symbol_id"], record["arm_id"])
        if key not in merged:
            merged[key] = dict(record)
        else:
            merged[key]["hits"] = int(merged[key].get("hits", 0)) + int(record.get("hits", 0))

    for rec in base_records:
        add_record(rec)

    for path in files[1:]:
        header, records = read_jsonl(path)
        validate_header(base_header, header, path)
        for rec in records:
            add_record(rec)

    out_header = dict(base_header)
    out_header["merged_from_count"] = len(files)

    sorted_records = [
        merged[k] for k in sorted(merged.keys(), key=lambda k: (k[0], k[1]))
    ]

    out_path = Path(args.output)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8") as f:
        f.write(json.dumps(out_header, sort_keys=True) + "\n")
        for rec in sorted_records:
            f.write(json.dumps(rec, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
