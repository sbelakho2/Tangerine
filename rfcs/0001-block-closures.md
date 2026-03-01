# RFC 0001: Block Closures

- RFC Number: 0001
- Title: Block Closures
- Author: Tangerine Core Team
- Status: Accepted
- Created: 2025-01-15
- Edition: 2026

## Summary

Define closure syntax using `do...end` blocks consistent with the rest of the language,
replacing any `{ }` brace-style closure notation found in early examples.

## Motivation

Tangerine uses `do...end` as its universal block delimiter. Early documentation and
prototypes used `|args| { body }` closures (inherited from Rust/Ruby), creating an
inconsistency with the language's block syntax.

This RFC standardizes closure syntax to use `do...end`:
```tangerine
|args| do body end
```

## Detailed Design

### Syntax

The closure expression grammar is:

```
closure_expr = '|' param_list '|' block
             | '|' param_list '|' expr
block        = 'do' stmt* 'end'
```

Single-expression closures omit `do...end`:
```tangerine
let double = |x| x * 2
```

Multi-statement closures use `do...end`:
```tangerine
let process = |x| do
  let y = x * 2
  y + 1
end
```

### Semantics

- Closures capture variables from the enclosing scope.
- By default, closures capture by reference (`&`). Use `move` for owning captures.
- Closure types implement the appropriate `Fn`, `FnMut`, or `FnOnce` trait
  based on how captured variables are used.

### Type System Impact

No change from current behavior. This RFC only standardizes syntax.

### Effect on Existing Code

Any code using `|args| { body }` must be updated to `|args| do body end`.
This is a mechanical transformation and can be automated with `tg fmt`.

## Examples

```tangerine
# Single expression — no block needed
let nums = vec.map(|x| x * 2)

# Multi-statement — use do...end  
let results = vec.filter_map(|item| do
  let processed = transform(item)
  if processed.is_valid() then
    Option::Some(processed)
  else
    Option::None
  end
end)

# Move closure
let callback = move |event| do
  handle_event(event)
end
```

## Alternatives Considered

1. **Brace-style `{ }`**: Rejected as inconsistent with Tangerine's `do...end` block syntax.
2. **Ruby-style `do |args| body end`**: Rejected as parameter list position is inconsistent with function definitions.
3. **Arrow syntax `(args) => body`**: Rejected as `=>` was removed from the language (see INC-001).

## Unresolved Questions

None — this RFC codifies existing practice.

## References

- Tangerine grammar: `docs/grammar.md`
- Style guide: `docs/style_guide.md`
- INC-001: Match arm syntax unification
- INC-013: Block syntax unification
