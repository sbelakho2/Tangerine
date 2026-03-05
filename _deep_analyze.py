#!/usr/bin/env python3
"""Deep analysis of all parser failures across golden tests, self-parse, 
and identify every unique construct the parser cannot handle."""
import subprocess, re, os, sys

def run_parse(filepath):
    r = subprocess.run(['./build/tg_bootstrap', 'parse', filepath],
                       capture_output=True, text=True, timeout=10)
    out = r.stdout + r.stderr
    errs = re.findall(r'error\[(\d+)\]: (.+)', out)
    return errs

def offset_to_line(filepath, offset):
    with open(filepath, 'r', errors='replace') as f:
        content = f.read()
    if offset >= len(content.encode('utf-8')):
        return len(content.split('\n')), ''
    # Use byte offset
    with open(filepath, 'rb') as f:
        raw = f.read()
    text_before = raw[:offset].decode('utf-8', errors='replace')
    line_num = text_before.count('\n') + 1
    lines = content.split('\n')
    if line_num <= len(lines):
        return line_num, lines[line_num - 1]
    return line_num, ''

def get_context(filepath, line_num, radius=5):
    with open(filepath, 'r', errors='replace') as f:
        lines = f.readlines()
    result = []
    for i in range(max(0, line_num - radius - 1), min(len(lines), line_num + radius)):
        marker = ">>>" if i == line_num - 1 else "   "
        result.append(f"  {marker} {i+1:4d}: {lines[i].rstrip()}")
    return '\n'.join(result)

# Analyze all failing files
golden_dir = 'golden'
compiler_dir = 'tg_compiler'

all_files = []
for d in [golden_dir, compiler_dir]:
    for f in sorted(os.listdir(d)):
        if f.endswith('.tg'):
            all_files.append(os.path.join(d, f))

print("=" * 70)
print("COMPLETE PARSER FAILURE ANALYSIS")
print("=" * 70)

total_pass = 0
total_fail = 0
all_issues = []

for filepath in all_files:
    errs = run_parse(filepath)
    if not errs:
        total_pass += 1
        continue
    total_fail += 1
    print(f"\n{'='*70}")
    print(f"FAIL: {filepath} ({len(errs)} errors)")
    print(f"{'='*70}")
    
    for offset_str, msg in errs:
        offset = int(offset_str)
        line_num, line_text = offset_to_line(filepath, offset)
        print(f"\n  Error at line {line_num}: {msg}")
        print(get_context(filepath, line_num, radius=4))
        all_issues.append({
            'file': filepath,
            'line': line_num,
            'msg': msg,
            'context': line_text.strip()
        })

print(f"\n\n{'='*70}")
print(f"SUMMARY: {total_pass} PASS, {total_fail} FAIL")
print(f"{'='*70}")

# Categorize issues
categories = {}
for issue in all_issues:
    key = issue['msg']
    if key not in categories:
        categories[key] = []
    categories[key].append(issue)

print("\nERROR CATEGORIES:")
for msg, issues in sorted(categories.items(), key=lambda x: -len(x[1])):
    print(f"\n  '{msg}' ({len(issues)} occurrences):")
    for iss in issues[:8]:
        print(f"    - {iss['file']}:{iss['line']} -> {iss['context'][:80]}")
    if len(issues) > 8:
        print(f"    ... and {len(issues)-8} more")
