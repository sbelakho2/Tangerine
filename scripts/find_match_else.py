#!/usr/bin/env python3
"""Find 'else' used inside match blocks across tg_compiler source files."""
import re, os, glob

for path in sorted(glob.glob("tg_compiler/*.tg")):
    with open(path) as f:
        lines = f.readlines()
    depth = 0
    in_match_depth = set()
    for i, line in enumerate(lines):
        s = line.strip()
        # Track match entry
        if re.match(r'match\b', s):
            depth += 1
            in_match_depth.add(depth)
        # Track end
        if s == 'end' or s.startswith('end ') or s.startswith('end#'):
            if depth in in_match_depth:
                in_match_depth.discard(depth)
            depth = max(0, depth - 1)
        # Check for else at same level as a match
        if re.match(r'else\b', s) and any(d <= depth+1 for d in in_match_depth):
            print(f"{path}:{i+1}: {s[:100]}")
