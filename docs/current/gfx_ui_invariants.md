# Global Consistency & Non-Stub Invariants

**Document:** TG-GFX-UI-SPEC-001 v0.1 — §2.1  
**Date:** 2026-03-02  

## Invariant INV-001: No Placeholder Implementations

Production code paths MUST NOT contain any of:
- `todo`, `todo!`, `stub`, `unimplemented`, `unimplemented!`
- `panic("not implemented")` or equivalent markers
- Functions that return hard-coded dummy values without performing their contract

**Enforcement:** Automated scan in CI via `scripts/scan_stubs.py`. See §20.

## Invariant INV-002: No Temporary Bypass Flags

Release builds MUST NOT contain flags that bypass:
- Conformance checks (capability verification, ABI validation)
- Security checks (bounds checking, ownership verification)
- Performance checks (budget enforcement, resource limits)

**Enforcement:** Build-profile-gated `#[cfg(debug)]` attributes only. Release profile strips all bypass paths.

## Invariant INV-003: No Silent Error Swallowing

All recoverable failures MUST return typed errors with actionable messages.
Specifically:
- No empty `catch` blocks that discard errors
- No `_ => ()` or `_ => Unit` match arms that silently consume error variants
- All `Result::Err` values carry a descriptive `message` field

**Enforcement:** Lint rule `no-silent-error` in `tg_compiler/linter.tg`.

## Invariant INV-004: No Undefined Behavior at FFI Boundaries

All `unsafe`/FFI boundaries MUST have explicit precondition checks:
- Null pointer checks before dereference
- Size/alignment validation before memory operations
- Handle validity checks before use
- String encoding validation (UTF-8) before conversion

**Enforcement:** `unsafe` blocks require justification string per Tangerine language rules.

## Invariant INV-005: Cross-Backend Consistency

API behavior MUST be consistent across backends for identical inputs, within
declared tolerance bounds:
- Raster output: ≤ 1 LSB per sRGB channel
- Coordinate transforms: exact IEEE 754 float semantics
- Event ordering: deterministic for identical input sequences
- Error codes: same error variant for same failure condition

**Enforcement:** Cross-backend differential tests in §21.7.

## Invariant INV-006: Evidence-Linked Completion

Every checklist item requires implementation evidence before marking complete:
- PR/commit reference, test path, artifact, or ADR link
- Evidence is recorded inline in the checklist markdown

**Enforcement:** Manual review + automated markdown lint.

## Invariant INV-007: Waiver Discipline

Any exception to a normative requirement MUST include:
- Owner, reason, risk assessment, expiry date, rollback plan
- Waivers are tracked in `docs/waivers/` with unique IDs

**Enforcement:** Waiver template in `docs/waivers/template.md`.
