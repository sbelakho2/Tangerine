#!/usr/bin/env python3
"""Transform `for x in EXPR do` loops into zero-copy indexed loops:
`for _loop_iN in 0..EXPR.len() do let x = &EXPR[_loop_iN]`.

Rules:
- Pattern must be a single identifier (optionally preceded by `mut`).
- Iter expression must be a plain dotted path (no calls, brackets, ranges, &).
- Loop variable must not be reassigned in the body.
- Iterated expression must not be mutated (push/pop/insert/remove/set/clear/...)
  inside the loop body.
- Produces a per-loop log for manual review.
"""
import re
import sys

MUTATORS = ["push", "pop", "insert", "remove", "set", "clear", "sort",
            "reverse", "swap", "drain", "truncate", "retain", "append",
            "delete", "erase"]

def tokenize(text):
    """Yield (kind, value, start, end) tokens. kind: 'id', 'kw', 'punct', 'str', 'num', 'other'."""
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '#':
            while i < n and text[i] != '\n':
                i += 1
            continue
        if c == '"':
            j = i + 1
            while j < n and text[j] != '"':
                if text[j] == '\\':
                    j += 1
                j += 1
            j += 1
            yield ('str', text[i:j], i, j)
            i = j
            continue
        if c == "'":
            j = i + 1
            if j < n and text[j] == '\\':
                j += 1
            if j < n:
                j += 1
            j += 1
            yield ('str', text[i:j], i, j)
            i = j
            continue
        if c.isalpha() or c == '_':
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == '_'):
                j += 1
            yield ('id', text[i:j], i, j)
            i = j
            continue
        if c.isdigit():
            j = i + 1
            while j < n and (text[j].isalnum() or text[j] == '_'):
                j += 1
            yield ('num', text[i:j], i, j)
            i = j
            continue
        if c in ' \t\r\n':
            i += 1
            continue
        j = i + 1
        if text[i:i+2] in ('..', '->', '=>', '::', '>=', '<=', '==', '!=', '&&', '||', '+=', '-=', '*=', '/=', '%=', '&=', '|=', '^=', '<<', '>>'):
            j = i + 2
        yield ('punct', text[i:j], i, j)
        i = j

KEYWORDS = set("""for in do end if then else elsif while match when def fn struct enum trait
impl static extern typealias mut let return break continue loop use import as pub private
unsafe defer guard try catch finally with move copy await async comptime cast
handle self Self init new where const var mod macro true false nil capability effect
rationale edition window module""".split())

def is_ident_path(toks, start, end):
    """Tokens [start,end) form a dotted ident path."""
    if start >= end:
        return None
    for t in toks[start:end]:
        if t[0] != 'id' and t[1] != '.':
            return None
    if toks[start][0] != 'id':
        return None
    if toks[end-1][0] != 'id':
        return None
    return ''.join(t[1] for t in toks[start:end])

def find_loops(text):
    """Return list of loop dicts."""
    toks = list(tokenize(text))
    loops = []
    for idx, (kind, val, s, e) in enumerate(toks):
        if kind == 'id' and val == 'for':
            # pattern: [mut] ident
            pos = idx + 1
            if pos < len(toks) and toks[pos][0] == 'id' and toks[pos][1] == 'mut':
                pos += 1
            if pos >= len(toks) or toks[pos][0] != 'id' or toks[pos][1] in KEYWORDS:
                continue
            pat_name = toks[pos][1]
            pat_start, pat_end = toks[pos][2], toks[pos][3]
            pos += 1
            if pos >= len(toks) or toks[pos][0] != 'id' or toks[pos][1] != 'in':
                continue
            pos += 1
            # iter path: collect id/dot tokens until non-path token
            it_start = pos
            while pos < len(toks) and (toks[pos][0] == 'id' or toks[pos][1] == '.'):
                if toks[pos][0] == 'id' and toks[pos][1] in KEYWORDS:
                    break
                pos += 1
            it_end = pos
            iter_path = is_ident_path(toks, it_start, it_end)
            if iter_path is None:
                continue
            if iter_path in ('true', 'false', 'nil'):
                continue
            if pos < len(toks) and toks[pos][0] == 'id' and toks[pos][1] == 'do':
                do_end = toks[pos][3]
            elif pos < len(toks) and toks[pos][0] == 'punct' and toks[pos][1] == '.':
                # could be a range `0..n` — skip if iter path was numeric-ish; path has no '..' by construction
                continue
            else:
                continue
            loops.append({
                'for_start': s, 'pat_name': pat_name, 'pat_start': pat_start,
                'pat_end': pat_end, 'iter_path': iter_path, 'iter_start': toks[it_start][2],
                'iter_end': toks[it_end-1][3] if it_end > it_start else e,
                'do_end': do_end,
            })
    return loops

def body_text(text, loop):
    """Text of the loop body (from do_end to matching end)."""
    i = loop['do_end']
    n = len(text)
    # find matching end using depth counting from tokens after do_end
    toks = tokenize(text[loop['do_end']:])
    depth = 0
    for (kind, val, s, e) in toks:
        if kind == 'id' and val in ('end',):
            depth -= 1
            if depth < 0:
                return text[loop['do_end']:loop['do_end'] + e]
        if kind == 'id' and val in ('for', 'while', 'if', 'match', 'def', 'struct', 'enum', 'trait', 'impl', 'loop'):
            depth += 1
        elif kind == 'id' and val == 'extern':
            # peek next
            pass
        elif kind == 'id' and val == 'typealias':
            pass
    return text[loop['do_end']:]

def transform_file(path, dry_run=False):
    text = open(path).read()
    loops = find_loops(text)
    if not loops:
        return text, []
    # process from end to start to keep offsets valid
    used_names = set()
    for m in re.finditer(r'_loop_i\d+', text):
        used_names.add(m.group(0))
    next_counter = 0
    transformed = []
    out = text
    for loop in reversed(loops):
        body = body_text(out, loop)
        # reassignment check: \bname\s*=(?!=) or compound assigns
        re_asgn = re.compile(r'\b' + re.escape(loop['pat_name']) + r'\b\s*(?:[+\-*/%&|^]{0,2}=|\|\||&&)')
        for m in re_asgn.finditer(body):
            after = body[m.end()-1]
            if after != '=' or (m.start() > 0 and body[m.start()-1] in '!=<>'):
                pass
        bad = False
        # tuple field access on the loop var (var.0) — unproven on references; skip
        if re.search(r'\b' + re.escape(loop['pat_name']) + r'\s*\.\d', body):
            bad = True
        # simple assignment: name = or compound name op=
        m = re.search(r'\b' + re.escape(loop['pat_name']) + r'\b\s*(\+=|-=|\*=|/=|%=|&=|\|=|\^=|<<=|>>=|=)(?!=)', body)
        if m and not (m.group(1) == '=' and body[max(0,m.start()-1)] in '!=<>'):
            bad = True
        # mutation of iterated path inside body
        mut_re = re.compile(r'\b' + re.escape(loop['iter_path']) + r'\.(' + '|'.join(MUTATORS) + r')\s*\(')
        idx_assign = re.compile(r'\b' + re.escape(loop['iter_path']) + r'\s*\[[^\]]*\]\s*(?:=\s*|\.(set|push|insert|remove)\s*\()')
        if mut_re.search(body) or idx_assign.search(body):
            bad = True
        if bad:
            continue
        name = None
        while True:
            cand = f'_loop_i{next_counter}'
            next_counter += 1
            if cand not in used_names:
                name = cand
                break
        used_names.add(name)
        iter_path = loop['iter_path']
        new_header = f'for {name} in 0..{iter_path}.len() do'
        let_line = f'\n  let {loop["pat_name"]} = &{iter_path}[{name}]'
        # replace header span: for_start .. do_end (exclusive) with new_header; insert let_line after do_end
        header_old = out[loop['for_start']:loop['do_end']]
        out = out[:loop['for_start']] + new_header + out[loop['do_end']:]
        # insert after do_end: but do_end shifted? header length change:
        # new header length - old length = delta; insertion point = do_end + delta
        delta = len(new_header) - len(header_old)
        insert_at = loop['do_end'] + delta
        out = out[:insert_at] + let_line + out[insert_at:]
        transformed.append({
            'for_start': loop['for_start'], 'do_end': insert_at,
            'pat_name': loop['pat_name'], 'iter_path': iter_path, 'name': name,
        })
    if dry_run:
        return None, transformed
    return out, transformed

if __name__ == '__main__':
    mode = sys.argv[1]
    for path in sys.argv[2:]:
        out, transformed = transform_file(path, dry_run=(mode == 'report'))
        print(f"== {path}: {len(transformed)} loops")
        if mode == 'report':
            for t in transformed:
                print(f"  {t['for_start']} {t['iter_path']} -> {t['name']} ({t['pat_name']})")
        else:
            with open(path, 'w') as f:
                f.write(out)
