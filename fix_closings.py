#!/usr/bin/env python3
with open('stage0/lib/c_codegen.ml', 'r') as f:
    lines = f.readlines()

count = 0
for i in range(1, len(lines)):
    prev = lines[i-1]
    line = lines[i]
    if 'emit_block_expr ctx arm.arm_body' in prev:
        if 'emit ctx "); } "' in line:
            lines[i] = line.replace('emit ctx "); } "', 'emit ctx "}); } "')
            count += 1
        elif 'emit ctx "); "' in line:
            lines[i] = line.replace('emit ctx "); "', 'emit ctx "}); "')
            count += 1

with open('stage0/lib/c_codegen.ml', 'w') as f:
    f.writelines(lines)

print(f'Fixed {count} closing delimiters')
