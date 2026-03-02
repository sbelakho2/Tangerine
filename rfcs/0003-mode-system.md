# RFC 0003: Mode System and Escalation Policy

- RFC Number: 0003
- Title: Mode System and Escalation Policy
- Author: Tangerine Core Team
- Status: Accepted
- Created: 2025-03-01
- Edition: 2026

## Summary

Define canonical compiler/runtime modes (`Dev`, `Strict`, `Production`, `Hardened`)
and specify enforcement escalation behavior across diagnostics, contracts, capabilities,
and quality gates.

## Motivation

Mode behavior appeared across implementation and tests but lacked a single normative
RFC. This caused ambiguity in tooling integration and policy interpretation.

## Detailed Design

### Mode Set

- `Dev`: fast iteration, low friction
- `Strict`: reliability-oriented defaults
- `Production`: quality gates enabled
- `Hardened`: strongest security posture

### Escalation Rules

- Diagnostic severities may escalate by mode.
- Unsafe usage restrictions tighten monotonically from `Dev` to `Hardened`.
- Coverage and quality score gating activates in production-oriented modes.

### Compatibility

Existing mode names are preserved. This RFC codifies semantics and precedence.

## References

- `tg_compiler/mode.tg`
- `docs/language.md`
- `docs/security.md`
