# Safe Reference Types (`&T` / `&mut T`) — Deprecated Syntax

> **NON-NORMATIVE — HISTORICAL.** This document archives the former
> first-class reference / Rust-like borrowing dialect of Tangerine. The
> current parser **hard-rejects** every form shown here (E106 for
> reference type positions and ref patterns, E100 for the legacy
> parameter spellings); nothing in this document is current syntax.
> The normative description of the current dialect is
> `../current/language.md`, `../current/grammar.md`, and
> `../current/memory_model.md`; the authoritative status of each feature
> is the [feature registry](../current/feature_registry.md).

**Status:** historical — the dialect described here was removed; the
stdlib E106 migration is complete (2026-08-20) and the parser rejects the
forms below instead of accepting or normalizing them.
**Normative model:** [`../current/memory_model.md`](../current/memory_model.md).
**Last Updated:** August 2026.

---

## What this document records

Earlier generations of the Tangerine documentation described the language
as having **first-class safe reference types** with **Rust-like borrowing**:
`&T` (shared/immutable borrow), `&mut T` (exclusive/mutable borrow),
borrow-checker-style rules (any number of shared references XOR exactly one
mutable reference), reference receivers (`&self` / `&mut self`), reference
parameters (`x: &T`), and reference patterns (`ref value`). That dialect
was **never implemented as described**; the language that shipped is the
access/resource model. This document preserves the old material so the
removed surface can be traced, and records the rejection mechanics that
replaced it.

## The removed dialect (archived prose)

### References

```tangerine
# Immutable reference (shared borrow)
let s = String::from("hello")
let r = &s        # borrow s
println(r)        # OK

# Mutable reference (exclusive borrow)
mut s = String::from("hello")
let r = &mut s    # mutable borrow
r.push_str(" world")
```

### Borrowing rules (removed)

1. Either any number of immutable references, or exactly one mutable
   reference.
2. References must always be valid (no dangling pointers).

```tangerine
mut s = String::from("hello")
let r1 = &s       # OK: immutable borrow
let r2 = &s       # OK: multiple immutable borrows
# let r3 = &mut s  # (old) error: cannot borrow mutably while borrowed immutably
println(r1, r2)   # borrows end here
let r3 = &mut s   # (old) OK: previous borrows have ended
```

### Reference receivers and parameters (removed)

```tangerine
def distance(&self, other: &Point) -> Float
def translate(&mut self, dx: Float, dy: Float) -> Unit
def print_all[T: Display](items: &[T]) -> Unit
def swap[T](a: &mut T, b: &mut T) -> Unit
```

### Reference patterns (removed)

```tangerine
match option
when Option::Some(ref value) then use_ref(value)
when Option::Some(&mut value) then modify(&mut value)
when Option::None then ()
end
```

### Reference-typed returns and annotations (removed)

```tangerine
def peek(&self) -> &T          # removed
let view: Option[&K] = ...     # removed
const X: &str = ...            # removed
```

## The rejection mechanics (what the compiler does today)

| Archived form | Today |
|---------------|-------|
| `&T` / `&mut T` / `&&T` in a general type position (returns, fields, annotations, generic args) | **E106** hard error — `parser.tg` `diag_safe_ref_not_first_class`; `parse_type` consumes the `&` and fails the parse |
| `ref` / `&` pattern binders | **E106** hard error — `parser.tg` `diag_ref_pattern_not_supported`; binders are never silently erased |
| `mut x:` / `&x:` / `&mut x:` / `move x:` / `own x:` parameter prefixes | **E100** hard error — `parser.tg` `parse_param` ("legacy parameter spelling … is removed; use the explicit access convention `let`/`inout`/`sink`/`set`") |
| `x: &T` / `x: &mut T` parameter type markers | **E100** hard error — consumed by `parse_param` before `parse_type` runs (recovery only) |
| `fn(&T)` / `fn(mut T)` / `fn(move T)` fn-type conventions | **E100** hard error — `parser.tg` `parse_fn_type_param`; only `inout` / `sink` / `set` + default `let` remain |
| `&self` / `&mut self` receivers | **E100** hard error — write `self: Self` (default `let`) or the trailing `inout` receiver convention |
| `Option[&T]`-style nested references | **E106** hard error everywhere except `__intrinsic_`-named extern declarations (the extern-ABI exception, typed `RefInternal`; `parser.tg` `parse_extern_fn`/`parse_extern_static`, scoped by `ids.tg` `is_intrinsic_extern_name`) |
| `&place` / `&mut place` expression markers | **legal, call arguments only** — `ExprAccess` (`parser.tg` `parse_unary`); the type checker rejects the marker anywhere else; the callee's parameter convention governs the effect |
| `*T` / `*mut T`, `Ptr[T]`, `PtrMut[T]` | **legal** — the raw-pointer forms (unsafe contexts, FFI boundaries) |
| `StrView` / `FfiStr` / `FfiSlice[T]` / `Slice[T]` | **legal** — non-owning views (`{ptr, len}`) replace reference returns |

## Migration record

The removal of the first-class reference model is documented in
[`access_resource_migration.md`](access_resource_migration.md) (the
borrow/lifetime model → access/resource model) and the migration classes
(a)–(g) of `../current/stdlib_reference.md` §Completeness Status. The
stdlib E106 migration is complete: every shipped module is parse-clean
under the current grammar, enforced by the two-layer gate
(`tests/run_stdlib_e106_sweep.sh`, required CI job `stdlib-e106-sweep`)
and the self-host grammar gate (`scripts/run_selfhost_grammar_gate.sh`,
wired into `run_bootstrap.sh`). The only remaining reference type
positions in the tree are the five `__intrinsic_map_visit_*` /
`__intrinsic_set_visit_*` record-visit extern signatures in
`std/collections.tg` — the documented extern-ABI exception, not a
migration remainder.

## See also

- [`../current/language.md`](../current/language.md) — the current dialect: access conventions, views, FFI pointer forms.
- [`../current/grammar.md`](../current/grammar.md) — the implemented grammar and the E100/E106 rejection surfaces.
- [`../current/feature_registry.md`](../current/feature_registry.md) — one-status-per-feature authority.
- [`../current/memory_model.md`](../current/memory_model.md) — the normative ownership/access model.
- [`access_resource_migration.md`](access_resource_migration.md) — the migration that produced the current model.
