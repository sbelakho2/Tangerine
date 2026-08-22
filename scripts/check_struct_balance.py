#!/usr/bin/env python3
# scripts/check_struct_balance.py — structural balance/arity/end-token gate.
#
# A deterministic, dependency-free stand-in for the compiler's parse gate
# (the stage binaries are flaky on large files). Checks, per file:
#   1. END-TOKEN BALANCE: every block opener (def/if/while/loop/for/match/
#      do/unsafe/defer/try/with/struct/enum/resource/impl/trait/module/
#      test/capability/effect/macro/block/handle) is closed by exactly one
#      `end`; `when`/`elsif`/`else`/`catch`/`finally` are mid-block, not
#      openers. Context rules: `for` in `impl Drop for X` is not a loop;
#      `do` after while/for/test is not a separate opener.
#   2. DELIMITER ARITY: paren/bracket/brace balance tracked across lines.
#   3. String-literal awareness: keywords inside "..." / '...' literals are
#      not openers.
#
# Usage: scripts/check_struct_balance.py <file>...
# Exit 0 when every file balances; 1 otherwise.
import re
import sys

OPENERS = [
    "def", "fn", "if", "while", "loop", "for", "match", "do", "unsafe",
    "defer", "try", "with", "struct", "enum", "resource", "impl",
    "trait", "module", "mod", "capability", "effect", "macro",
    "guard", "handle", "comptime", "extern",
]
# Keywords that also appear as identifiers (parameter/field names) in the
# codebase: counted as openers ONLY at statement position (line start).
LINE_START_ONLY = {
    "def", "fn", "with", "struct", "enum", "resource", "impl", "trait",
    "module", "mod", "capability", "effect", "macro", "guard", "handle",
    "comptime", "extern",
}
OPENER_RE = re.compile(r"\b(" + "|".join(OPENERS) + r")\b")
END_RE = re.compile(r"\bend\b")


def strip_strings(line):
    out = []
    i = 0
    n = len(line)
    in_str = False
    quote = ""
    while i < n:
        c = line[i]
        if in_str:
            out.append(" ")
            if c == "\\":
                out.append(" ")
                i += 1
            elif c == quote:
                in_str = False
        else:
            if c in "\"'":
                in_str = True
                quote = c
                out.append(" ")
            elif c == "#":
                break
            else:
                out.append(c)
        i += 1
    return "".join(out)


def strip_generics(s):
    # Remove a leading bracketed generic-argument group, honoring NESTED
    # brackets: `impl[T: Copy, I: Iterator[T]] Name` must strip the whole
    # `[T: Copy, I: Iterator[T]]` (a naive `^\[[^\]]*\]` stops at the inner
    # closing bracket and leaves `]] Name`, failing the name-position check).
    if not s or s[0] != "[":
        return s
    depth = 0
    for i, c in enumerate(s):
        if c == "[":
            depth += 1
        elif c == "]":
            depth -= 1
            if depth == 0:
                return s[i + 1 :]
    return s


def top_level_index(code, target):
    # First index of `target` outside any (), [], {} group — a `=` inside a
    # generic list (`Future[Output = T]`) or a default parameter
    # (`a: Int = 5`) is NOT a top-level `=`.
    depth = 0
    for i, c in enumerate(code):
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == target and depth == 0:
            return i
    return -1


def count_openers(code, lineno, stack, lines, idx):
    next_code = lines[idx] if idx < len(lines) else ""
    stripped = code.lstrip()
    first_word = stripped.split()[0] if stripped.split() else ""
    # `impl[T] Option[T]` — the generic list precedes the name; strip it
    # for the declaration-position comparison.
    lead_word = re.sub(r"\[.*$", "", first_word)
    for m in OPENER_RE.finditer(code):
        word = m.group(1)
        if word in LINE_START_ONLY:
            # Statement position only: `module`/`guard`/`handle`/... as a
            # parameter or field name is an identifier, not an opener.
            # `pub def` / `extern def` normalize to def.
            lead = lead_word
            if lead == "pub":
                lead = stripped.split()[1] if len(stripped.split()) > 1 else ""
                lead = re.sub(r"\[.*$", "", lead)
            if lead == "async" and word in ("def", "fn"):
                lead = word  # `async def ...` / `async fn ...` normalize to def/fn
            if lead == "extern" and word == "def":
                lead = "def"  # `extern def ...` routes through the def rules
            if lead != word:
                continue
            # A declaration keyword is followed by the declared NAME — a
            # line that starts with the word followed by an operator
            # (`module + "::" + ...` — the `module` PARAMETER used in an
            # expression) is not a declaration. guard/handle/with take
            # expressions, not names. extern takes an ABI string
            # (`extern "C"`).
            if word not in ("guard", "handle", "with", "extern"):
                after = code[m.end():]
                after = strip_generics(after)  # `impl[T, U: Iterator[T]] Name`
                # The declared NAME: ASCII or unicode letters (the UCD
                # XID_Start classes — the lexer accepts them; the
                # adversarial formatter corpus uses them).
                if not re.match(r"\s+[^\W\d]", after):
                    continue
        if word == "unsafe":
            # `unsafe { ... }` — the brace-delimited one-line form has no
            # `end`; only `unsafe` with a do/body block opens.
            if re.search(r"\s*\{", code[m.end():]):
                continue
        if word == "if":
            # `else if` is ONE chained construct (elsif) — no new block.
            if re.search(r"\belse\s+if\b", code[: m.start() + 2]):
                continue
            # An INLINE if-expr closes in one of two forms: with an `end`
            # (`path: if x then y else z end`, or a multi-line
            # `let x = if c then a else\n  b\nend`) or without
            # (`(if c then a else b)` — the ternary-like form, no end).
            # Only the end-less form is skipped.
            rest = code[m.start():]
            if code[: m.start()].strip() != "" and re.search(r"then.*else\s*\S", rest) and not re.search(r"else.*\bend\b", rest):
                continue
        if word == "do":
            prefix = code[: m.start()]
            if re.search(r"\b(while|for|unsafe|loop)\b", prefix):
                continue  # `while x do` / `for x in y do` / `unsafe ... do` / `loop do`
        if word == "for":
            # `impl Trait for Type` / `impl[T, U: Iterator[T]] Trait for
            # Type` — the trait-impl clause, NOT a loop. The impl's generic
            # list may carry NESTED brackets (`Iterator[T]`), so the check
            # scans backward to the `impl` keyword and strips a balanced
            # generic group before the type name.
            prefix = code[: m.start()]
            im = re.search(r"\bimpl\b", prefix)
            if im is not None:
                between = strip_generics(prefix[im.end() :]).strip()
                if between and re.match(r"^[A-Za-z_][\w\[\]\(\), :]*$", between):
                    continue  # `impl ... for Type` — a trait impl, not a loop
        if word == "extern":
            # `extern "C" do ... end` — the do is the block opener;
            # `extern def ...` — the def carries its own body-less rule.
            if re.search(r"\b(do|def)\b", code[m.end():]):
                continue
        if word == "def":
            if first_word == "extern":
                # `extern def ... -> T` — no body, no end — EXCEPT the
                # @-attributed form (`@cfg(...)\nextern def ... -> T\nend`),
                # which carries an explicit end.
                prev = ""
                ki = idx - 1
                while ki >= 0:
                    cand = lines[ki].strip()
                    if cand == "" or cand.startswith("#"):
                        ki = ki - 1
                        continue
                    prev = cand
                    break
                if not prev.startswith("@"):
                    continue
            if re.search(r"\)\s*->\s*[^=]*=.*$", code):
                # One-line VALUE def: `def X() -> T = <expr>`. The `=` must
                # sit at TOP LEVEL — `-> impl Future[Output = T]` puts the
                # `=` inside the generic bracket group (an associated-type
                # clause, NOT a value-def `=`) and must not skip the def.
                eq = top_level_index(code, "=")
                if eq >= 0 and re.search(r"\)\s*->\s*[^=]*$", code[:eq]):
                    continue  # one-line value def: `def X() -> T = <expr>` — no end
            if stack and (stack[-1][1] == "trait" or stack[-1][1] == "do" or stack[-1][1] == "extern"):
                # A trait method SIGNATURE has no body: the following
                # non-comment, non-blank line is the trait's `end`
                # (single-signature trait) or another signature `def`
                # (multi-signature trait). A trait method with a default
                # BODY opens a real block (the body starts on the
                # following line). A signature that SPANS LINES (an
                # unclosed `(` on the declaration line — the parameter
                # list continues on the next line) is a signature too:
                # its continuation lines are parameter text, never body
                # statements, so the def opens no block.
                if code.count("(") > code.count(")"):
                    continue
                nxt = ""
                ki = idx + 1
                while ki < len(lines):
                    cand = lines[ki].strip()
                    if cand == "" or cand.startswith("#"):
                        ki = ki + 1
                        continue
                    nxt = cand
                    break
                if nxt == "end" or nxt.startswith("def "):
                    continue
        stack.append((lineno, word))


def check_file(path):
    problems = []
    stack = []
    delims = []  # (char, line) of open delimiters
    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    for lineno, raw in enumerate(lines, start=1):
        code = strip_strings(raw)
        for c in code:
            if c in "([{":
                delims.append((c, lineno))
            elif c in ")]}":
                if not delims:
                    problems.append(f"{path}:{lineno}: unmatched closing delimiter `{c}`")
                else:
                    d, dline = delims.pop()
                    pair = {"(": ")", "[": "]", "{": "}"}
                    if pair[d] != c:
                        problems.append(
                            f"{path}:{lineno}: delimiter mismatch (`{d}` at line {dline} closed by `{c}`)"
                        )
        count_openers(code, lineno, stack, lines, lineno - 1)
        for _ in range(len(END_RE.findall(code))):
            if not stack:
                problems.append(f"{path}:{lineno}: stray `end` (no open block)")
            else:
                stack.pop()
    for d, dline in delims:
        problems.append(f"{path}:{dline}: unclosed delimiter `{d}`")
    for bline, word in stack:
        problems.append(f"{path}:{bline}: unclosed block opened by `{word}`")
    return problems


def main(argv):
    if not argv:
        print("usage: check_struct_balance.py <file>...", file=sys.stderr)
        return 2
    bad = 0
    for path in argv:
        problems = check_file(path)
        if problems:
            bad += 1
            for p in problems:
                print(p)
        else:
            print(f"OK  {path}")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
