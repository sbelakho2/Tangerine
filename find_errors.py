#!/usr/bin/env python3
"""Map byte offsets from error messages to line numbers and show context."""
import sys, re

def map_offset(filepath, offset):
    with open(filepath, 'rb') as f:
        data = f.read()
    if offset > len(data):
        return None, None, f"offset {offset} > file length {len(data)}"
    line = data[:offset].count(b'\n') + 1
    # Find line start/end
    ls = data.rfind(b'\n', 0, offset) + 1
    le = data.find(b'\n', offset)
    if le == -1: le = len(data)
    context = data[max(0, ls-200):le+200].decode('utf-8', errors='replace')
    return line, offset - ls, context

for arg in sys.argv[1:]:
    # "file:offsets" format
    parts = arg.split(':')
    filepath = parts[0]
    offsets = [int(x) for x in parts[1].split(',')]
    print(f"\n{'='*60}")
    print(f"FILE: {filepath}")
    for off in offsets:
        line, col, ctx = map_offset(filepath, off)
        print(f"  offset {off} -> line {line}, col {col}")
        # Show just the relevant line
        with open(filepath, 'r', errors='replace') as f:
            lines = f.readlines()
            if line and line <= len(lines):
                start = max(0, line - 3)
                end = min(len(lines), line + 3)
                for i in range(start, end):
                    marker = ">>>" if i == line - 1 else "   "
                    print(f"    {marker} {i+1:4d}: {lines[i].rstrip()}")
