#!/usr/bin/env python3
"""Find exact failing construct in conformance_runner.tg by progressively adding lines."""
import subprocess, re

with open('golden/conformance_runner.tg') as f:
    lines = f.readlines()

# Find all transition points where error count changes
prev_errs = 0
prev_pass = True
for i in range(1, len(lines)+1):
    with open('/tmp/cr_progressive.tg', 'w') as f:
        f.writelines(lines[:i])
    r = subprocess.run(['./build/tg_bootstrap', 'parse', '/tmp/cr_progressive.tg'],
                       capture_output=True, text=True, timeout=10)
    errs = len(re.findall(r'error\[', r.stdout + r.stderr))
    cur_pass = (errs == 0)
    if cur_pass != prev_pass:
        status = "PASS→FAIL" if not cur_pass else "FAIL→PASS"
        print(f"Line {i}: {status} (errors={errs}): {lines[i-1].rstrip()[:80]}")
    prev_pass = cur_pass
    prev_errs = errs
