# RFC 0002: Match Arm Syntax Unification

- RFC Number: 0002
- Title: Match Arm Syntax Unification
- Author: Tangerine Core Team
- Status: Accepted
- Created: 2025-02-01
- Edition: 2026

## Summary

Standardize all `match` arm syntax to use explicit `when ... then ...` form and
remove legacy variants that omit `then` or use alternate separators.

## Motivation

Early examples and prototype grammar allowed multiple arm spellings, which created
inconsistency in parser behavior, diagnostics, and formatter output.

A single canonical form improves:

- Readability across codebases
- Tooling determinism (`tg fmt`, linting, diagnostics)
- Grammar simplicity and parser maintenance

## Detailed Design

### Syntax

Canonical match arm syntax:

```tangerine
match value
when Pattern then expr
when OtherPattern if guard_expr then do
  handle_case()
end
end
```

### Semantics

- `when` introduces a match arm.
- Optional guard is written as `when <pattern> if <expr> then ...`.
- `if let` integration: arm guards remain boolean expressions; if-let pattern binding is not introduced as a distinct arm-guard form by this RFC and should be modeled using canonical `when <pattern> if <expr> then ...` with equivalent predicate expressions.
- Arm body is either a single expression or a `do...end` block.

### Type System Impact

No type-system changes. This RFC is syntax/normalization only.

### Effect on Existing Code

Non-canonical legacy arm forms must be rewritten to the canonical syntax. This can
be performed mechanically by formatter/refactor tooling.

## Alternatives Considered

1. Allow multiple arm syntaxes permanently (rejected: tooling instability).
2. Use `=>` separators (rejected: conflicts with Tangerine syntax direction).

## Unresolved Questions

None.

## References

- Grammar: `docs/grammar.md` (`match_arm` production)
- Style guide: `docs/style_guide.md`
