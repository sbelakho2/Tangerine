#!/usr/bin/env python3
"""Find all 'else' lines followed (after whitespace/comments) by 'if' in the next non-blank line."""
import sys, re

for filepath in sys.argv[1:]:
    with open(filepath) as f:
        lines = f.readlines()
    for i in range(len(lines)-1):
        stripped = lines[i].strip()
        if stripped == 'else':
            # Find next non-blank, non-comment line
            for j in range(i+1, min(i+5, len(lines))):
                ns = lines[j].strip()
                if ns == '' or ns.startswith('#'):
                    continue
                if ns.startswith('if ') or ns.startswith('if('):
                    print(f"{filepath}:{i+1}: else -> {j+1}: {ns[:60]}")
                break
