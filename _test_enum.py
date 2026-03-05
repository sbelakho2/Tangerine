#!/usr/bin/env python3
"""Test various enum parsing scenarios."""
import subprocess, os

def parse_test(name, content):
    path = '/tmp/test_parse_scenario.tg'
    with open(path, 'w') as f:
        f.write(content)
    r = subprocess.run(['./build/tg_bootstrap', 'parse', path],
                       capture_output=True, text=True, timeout=10)
    out = (r.stdout + r.stderr).strip()
    print(f"{name}: {out}")

# Test 1: Plain enum
parse_test("Plain enum", """\
enum Foo
  Ok
  Error(code: String)
  AnyError
end
""")

# Test 2: Enum with inline comments
parse_test("Enum with comments", """\
enum Foo
  Ok                              # comment
  Error(code: String)             # comment
end
""")

# Test 3: Enum variant named 'Ok' 
parse_test("Variant 'Ok'", """\
enum Foo
  Ok
  Err
end
""")

# Test 4: from conformance_runner exact bytes
with open('golden/conformance_runner.tg', 'r') as f:
    lines = f.readlines()
# Lines 42-54 (0-indexed 42 = blank, 43=enum start, 54=end)
subset = ''.join(lines[42:55])
parse_test("Conformance subset (line 43-55)", subset)

# Lines 27-55 (includes use statements)
subset2 = ''.join(lines[27:55])
parse_test("With use stmts (line 28-55)", subset2)

# Just enum from actual file
subset3 = ''.join(lines[42:54])  # without `end`
parse_test("Enum without end (should fail)", subset3)

# Line 1-55 exactly 
subset4 = ''.join(lines[0:55])
parse_test("First 55 lines exactly", subset4)

# Test 5: Multiple enums (to check clean state)
parse_test("Two enums", """\
enum A
  X
  Y
end
enum B
  Z(s: String)
end
""")

# Test 6: Check if `##` doc comment breaks things
parse_test("Doc comment + enum", """\
## Some docs
enum A
  X
end
""")

# Test 7: em-dash as in actual file  
parse_test("Em-dash comment + enum", "# \u2014\u2014\u2014\n## test\nenum A\n  X\nend\n")

# Test 8: Exact first 42 lines + blank + manual simple enum
subset5 = ''.join(lines[0:42])
parse_test("First 42 lines", subset5)

# Test 9: First 42 + simple enum
subset6 = subset5 + "\nenum Foo\n  X\nend\n"
parse_test("First 42 + simple enum", subset6)

# Test 10: Check what the exact line 42 content is
print(f"\nLine 42 repr: {repr(lines[41])}")
print(f"Line 43 repr: {repr(lines[42])}")
