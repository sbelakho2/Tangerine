import re

with open('docs/interop.md', 'r') as f:
    content = f.read()

def replace_struct(m):
    indent = m.group(1)
    header = m.group(2)
    body = m.group(3)
    fields = body.strip().rstrip(',').strip()
    if not fields:
        return f'{indent}{header}\nend'
    field_lines = [f.strip().rstrip(',') for f in fields.split('\n') if f.strip()]
    result = f'{indent}{header}\n'
    for field in field_lines:
        result += f'{indent}  {field}\n'
    result += f'{indent}end'
    return result

content = re.sub(
    r'^( *)(struct \w+(?:\[[\w, ]+\])?) \{\n(.*?)\n *\}',
    replace_struct,
    content,
    flags=re.MULTILINE | re.DOTALL
)

with open('docs/interop.md', 'w') as f:
    f.write(content)
print('Done')
