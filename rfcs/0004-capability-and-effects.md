# RFC 0004: Capability and Effects Contract

- RFC Number: 0004
- Title: Capability and Effects Contract
- Author: Tangerine Core Team
- Status: Accepted
- Created: 2025-03-10
- Edition: 2026

## Summary

Specify the relationship between declared effects, required capabilities, and
enforcement points in compilation and runtime checks.

## Motivation

Capability/effect concepts were implemented in multiple modules but lacked a clear
normative contract for propagation and enforcement.

## Detailed Design

### Core Rules

- Effect declarations describe side-effect intent.
- Capability requirements describe authorization requirements.
- Calls must satisfy callee capability requirements under current context.

### Analysis Model

- Direct effects and transitive effects contribute to symbol-level summaries.
- Capability drift is measured against project baseline artifacts.

### Effect-to-Capability Mapping

The 2026 edition baseline mapping used by CQS analysis is:

- `net.*` → `NetCap`
- `fs.read*` / `fs.*read*` → `FsReadCap`
- other `fs.*` writes/mutations → `FsCap`
- `process.*` → `ProcCap`
- `ffi.*` → `FfiCap`
- `env.*` → `EnvCap`
- `db.*` → `DbCap`
- `clock.*` / `time.*` → `ClockCap`
- `random.*` / `rand.*` → `RandomCap`

Compilers may additionally support exact aliases (for example `net.read`, `db.write`, `clock.now`) that normalize into the same capability classes above.

### Enforcement

- Violations produce mode-dependent diagnostics and may block builds in stricter modes.

## References

- `tg_compiler/agentic.tg`
- `tg_compiler/cap_baseline.tg`
- `docs/registry_policy.md`
