# Grammar conformance corpus

`tests/grammar_conformance/` is the deliberate grammar-conformance corpus for
the Tangerine parser pair:

- the OCaml seed parser (`stage0_ocaml/src/parser.ml`), and
- the bootstrap kernel parser (`tg_compiler/parser.tg`) run in the seed VM.

The corpus exists because **seed↔kernel parse parity is not a language
specification**. Commit `155f72d` made the kernel mirror every seed leniency
the closure exposed; parity then proves only that the two implementations
agree, not that the agreed language is intended. A stray top-level `end`, for
example, is accepted by the seed's skip-anything item loop, so parity alone can
never reject it.

Each specimen is written from a **decision** about the intended language,
recorded in its header comment with the spec/doc anchor (or explicitly marked
as a bootstrap-accommodation), not from either parser's observed behaviour.
`manifest.txt` registers every case as `accept` (zero error diagnostics) or
`reject` (at least one error diagnostic); both parsers must agree with the
manifest or the lane fails.

## Runners

| side | runner | mechanism |
|------|--------|-----------|
| seed parser | `stage0_ocaml/selfcheck/tg_parse_parity.ml` (seed-side corpus check, in process) | lexes+parses each manifest path with `Lexer`/`Parser`; `accept` must have zero error diagnostics, `reject` at least one |
| kernel parser | `tg_compiler/parse_parity_probe.tg` in the seed VM (invoked by the same selfcheck) | the real kernel `tokenize`+`parse` over the same manifest; same expectations, written to `build/parse_parity_report.txt` |
| gate | `scripts/run_selfhost_grammar_gate.sh` step 4 | runs the `tg_parse_parity` lane, which now covers the closure AND this corpus on both sides |

Because negatives run through **both** parsers, a negative is only admitted
after the seed also rejects it (verified when the case was added). That is what
lets the kernel be tightened against an accidental widening without breaking
seed/kernel parity. A negative where the seed is deliberately lenient is not
enforceable and would have to be documented as an accommodation positive
instead.

## Decision table (commit 155f72d's new leniencies)

"Intentional" = the form is part of the intended language, with the anchor
given. "Accommodation" = the canonical grammar does not define it, but the
seed accepts it and current closure sources require it; pinned so a future
migration is a conscious decision. "Accidental" = a kernel-only widening of
the seed (or of the canonical grammar) that the seed itself rejects; the
kernel was tightened and the case pinned negative.

| # | behaviour | decision | anchor / evidence | case |
|---|-----------|----------|-------------------|------|
| 1 | per-arm `end` closing a match arm before the next `when` (column rule + `match_arm_cols` stack) | accommodation | grammar.md §4.6 `match_arm` has no per-arm `end` (RFC 0002 canonical form); seed `parser.ml:2879-2895`, 2933-2936; 7 closure sites e.g. codegen.tg:6445 | pos/01 |
| 2 | stray top-level `end` consumed without a diagnostic | accommodation | no top-level `end` production; the formatter match-tail spill (bench.tg:451, 98 sites); seed `parse_program` skips any non-item token (`parser.ml:269-274`); kernel deliberately skips only `end` | pos/02 |
| 3 | inner match `end` followed by an enclosing match's `when` closes the inner match, not the arm | accommodation | seed `per_arm_end` column/stack rule (`parser.ml:2883-2893`) | pos/03 |
| 4 | soft keywords as identifier names (bindings/params/fields/methods) | intentional | grammar.md §1.3 contextual `super`/`crate`, §2.5 `deinit`; seed `soft_ident_kind` (`parser.ml:137-212`); kernel `soft_ident_name` | pos/04, pos/06 |
| 5 | soft keywords as primary expressions and pattern bindings | intentional | same soft-identifier set; kernel `parse_primary`/`parse_single_pattern` fallbacks | pos/04, pos/05 |
| 6 | contextual `copy`/`move`: `copy.field`, `move(x)`, bare `copy` are identifier uses | intentional | seed lexes `move`/`copy` as identifiers; grammar.md §4.1 (`( 'move' \| 'copy' ) unary` legacy no-ops) ; kernel `at_prefix_keyword_ident_context` | pos/05 |
| 7 | `end` as a field/name when followed by a continuation token (`:`, `=`, `.`, `(`, ...) | intentional | seed `at_kw_end_as_terminator` (`parser.ml:243-253`); kernel uses the same predicate in decls/loops | pos/06 |
| 8 | struct-literal fields with an optional comma (same line or newline-separated) | accommodation | grammar.md §4.5 `field_init_list` requires commas; seed eats an optional comma (`parser.ml:2586-2600`) | pos/07, pos/08 |
| 9 | newline-separated array elements without a comma | intentional leniency | seed documents it: `parser.ml:124-125`, loop at 2216-2222 | pos/09, pos/10 |
| 10 | doc-comment/newline trivia between array elements | intentional leniency | comments are trivia; a newline in the raw span is the seed's test (`parser.ml:2216-2222`) | pos/10 |
| 11 | multi-line or-pattern (`|` on a later line) | intentional | grammar.md §5 puts no line restriction; seed drops newlines (`parser.ml:3154-3166`) | pos/11 |
| 12 | `..` rest and comma-less fields in struct patterns | accommodation | grammar.md §5 `field_pattern_list` requires commas and has no rest; seed skips `..` and eats optional commas (`parser.ml:3245-3262`) | pos/12 |
| 13 | single-expression else in value position (delimiter/`end`/EOF/shallower next statement) | intentional | grammar.md §4.6 `[ 'end' ]` short form; seed `parser.ml:2747-2805`; kernel `parse_if_else_value_block` | pos/13 |
| 14 | contextual `next` (continue vs identifier) and `guard` (statement vs identifier) | intentional | grammar.md §1.3 `next`/`continue`; seed statement-boundary rule `parser.ml:736-755`; kernel `at_soft_ident_continuation` | pos/14 |

### Accidental divergences fixed (kernel-only widenings + one strictness fix)

| # | construct | why accidental | seed evidence | case |
|---|-----------|----------------|---------------|------|
| A1 | `S { end }` / `S { a: 1 end }`: `end` read as a struct-literal field | the seed stops the field list at a terminator `end`; the kernel's soft-ident loop must not read it as a shorthand field | seed `parse_struct_literal` loop guard `at_kw_end_as_terminator` (`parser.ml:2586`) rejects (stray `}`) | neg/01, neg/02 |
| A2 | `when S { a end }`: `end` read as a struct-pattern field | same terminator rule in the pattern loop | seed `parse_single_pattern` loop guard (`parser.ml:3245-3262`) rejects | neg/03 |
| A3 | `V(finally: Int)`: soft keyword as a PARENTHESIZED variant field name | the seed's paren form requires a plain `IDENT` before `:`; only the brace form softens names | seed `parse_enum_decl` paren branch `at_ident p` (`parser.ml:1054-1057`) rejects; brace branch `expect_ident` (`1070-1078`) accepts | neg/04 |
| A4 | doc-comment trivia between array elements being missed (kernel was stricter), fixed to the seed's trivia-order rule | parity fix for pos/10: the kernel skipped newlines before doc comments, so `[1` / `## c` / `2]` failed | seed checks the raw span for a newline with comments already dropped (`parser.ml:2216-2222`) | pos/10 |

### Boundary guards (both parsers already reject)

neg/05 `[1 2 3]` (same-line array elements need a comma), neg/06 empty
or-alternative, neg/07 match without its final `end`, neg/08 `name:` in a
struct pattern with no pattern, neg/09 `name:` in a struct literal with no
value. These keep the new lenient loops from swallowing malformed input.

## Notes / open residue

- The kernel's `parse_block_body` (parser.tg:4752-4779) unconditionally
  treats `finally`, `catch`, `else`, `when`, `elsif` as block terminators —
  correct inside try/catch/if/match, but it also stops a FUNCTION body at a
  statement that merely BEGINS with one of those soft keywords. The seed
  accepts `let f = ...` then `finally + next` as two statements there. This
  kernel-strictness gap predates the corpus and is not enforced by it (a
  positive would fail the kernel side); pos/04 keeps every soft-keyword use
  inside a statement that starts with a non-terminator token. The same class
  covers a statement beginning with `end`: the seed ends the block and then
  silently discards the leftover tokens, so no diagnostic exists to pin.
- The seed has an END-TERMINATED struct-literal form (`Name { a: 1 end`, no
  closing brace; `parse_struct_literal`:2602-2603). The kernel predates
  155f72d with a `}`-only struct literal, so it still rejects that form
  (seed-accepted); the kernel closure does not use it, so the lane does not
  enforce it either way. The corpus negatives neg/01/02 are the separate
  spelling `Name { a: 1 end }` — terminator `end` followed by a stray `}` —
  which the seed itself rejects and the kernel was silently accepting.
- The kernel's soft-identifier set is a superset of the seed's in *acceptance*
  (`alias`, `ensures`, `move`, `copy`, `own`, `drop`, `ref` are seed
  identifiers rather than keyword tokens), but it is **stricter** for kernel
  keywords the seed lexes as plain identifiers: `nil`, `is`, `private` are
  identifier spellings in the seed and keyword tokens with no soft-name entry
  in the kernel. That pre-dates 155f72d and is not corpus-enforced.
- `mod` and `typealias` are alias tokens in the kernel (`TokenKind::Module` /
  `TokenKind::Type`), so an identifier use parses to the canonical spelling
  (`module` / `type`) while the seed keeps `mod` / `typealias`. Acceptance is
  at parity; the AST spelling differs (out of scope for this parse-only
  corpus).
- The seed accepts arbitrary top-level junk silently (`parse_program`
  advances on any non-item token). The kernel diagnoses all top-level junk
  except `end`; a negative for general junk would not run through both
  parsers, so it is not in the corpus. The accommodation is only the `end`
  spill (pos/02).
