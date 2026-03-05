#!/usr/bin/env python3
import subprocess, os, sys

golden = sorted(f for f in os.listdir('golden') if f.endswith('.tg'))
results = []
for f in golden:
    try:
        r = subprocess.run(['./target/stage1/tg', 'parse', 'golden/' + f],
                          capture_output=True, text=True, timeout=5)
        status = 'PASS' if r.returncode == 0 else 'FAIL'
    except subprocess.TimeoutExpired:
        status = 'HANG'
        r = None
    results.append((status, f))
    if status != 'PASS':
        if status == 'HANG':
            print(f'HANG {f}')
        else:
            output = (r.stdout or '') + (r.stderr or '')
            lines = output.split('\n')
            errs = [l.strip() for l in lines if 'error' in l.lower() and '-->' in l][:1]
            print(f'{status} {f}: {errs[0] if errs else "?"}')

npass = sum(1 for s,_ in results if s == 'PASS')
nfail = sum(1 for s,_ in results if s == 'FAIL')
nhang = sum(1 for s,_ in results if s == 'HANG')
print(f'---')
print(f'PASS: {npass}  FAIL: {nfail}  HANG: {nhang}  TOTAL: {len(results)}')
