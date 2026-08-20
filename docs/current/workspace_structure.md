# Workspace and Repository Execution Structure
## TG-GFX-UI-SPEC-001 v0.1 §19

---

## Folder Ownership and Code Review Map

| Directory | Contents | Owner | Reviewer |
|-----------|----------|-------|----------|
| `std/gfx_errors.tg` | Error model | Error-model lead | Peer + release lead |
| `std/geom.tg` | Geometry types | Geometry lead | Peer |
| `std/app.tg` | Windowing / events | App lead | Peer + ABI lead |
| `std/gfx.tg` | 2-D Canvas drawing | Gfx lead | Peer |
| `std/gfx_gpu.tg` | GPU API (Tier C) | GPU lead | Peer + ABI lead |
| `std/image.tg` | Image codecs | Image lead | Peer |
| `std/text.tg` | Text / fonts | Text lead | Peer |
| `std/ui_toolkit.tg` | Widget toolkit | UI lead | Peer + a11y lead |
| `std/platform.tg` | Clipboard / IME / DnD | Platform lead | Peer + security lead |
| `std/anim.tg` | Animation | Animation lead | Peer |
| `std/compositor.tg` | Compositor | Compositor lead | Peer + perf lead |
| `std/assets.tg` | Asset loading | Assets lead | Peer |
| `std/accessibility.tg` | Accessibility tree | A11y lead | Peer |
| `std/backend_abi.tg` | Backend plugin ABI | ABI lead | Peer + security lead |
| `docs/` | Specifications & guides | Doc lead | Module owners |
| `scripts/` | Build/CI/conformance | Infra lead | Release lead |
| `golden/` | Golden test files | Test lead | Module owners |
| `tests/` | Test suites | Test lead | Module owners |

## Status Board

The single source of truth status board is the repository-root checklist
file: [`checklist.md`](../checklist.md).

Each section maps to a milestone. Items marked `[x]` are complete with evidence links.
Items marked `[ ]` are open work.

## Issue Templates

### Consistency Gap
```
Title: [Consistency] <module> — <brief description>
Labels: consistency, <module>
Checklist item: §<N>.<M> — <text>
Expected: <what the spec says>
Actual: <what the code does>
Impact: <which interfaces/backends affected>
```

### Conformance Gap
```
Title: [Conformance] <module> — <brief description>
Labels: conformance, <module>
Checklist item: §<N>.<M>
Signature expected: <type/function sig>
Signature actual: <what exists>
```

### Stub Removal
```
Title: [Stub] <module> — <stub description>
Labels: stub-removal, <module>
Location: <file>:<line>
Stub marker: TODO / FIXME / STUB / unimplemented
Required implementation: <brief>
```

### Backend Implementation Gap
```
Title: [Backend] <backend> — <missing interface>
Labels: backend, <platform>
Interface: <e.g., tg.clipboard.v1>
Backend: <e.g., tg-backend-macos>
Status: not started / partial / blocked
```

## Pull Request Template

```markdown
## Checklist Items Addressed
- [ ] §<N>.<M> — <item text>

## Conformance / Test / Perf / Security
- [ ] Conformance test added or updated
- [ ] Unit/integration test covers change
- [ ] Performance impact assessed (no budget regression)
- [ ] Security impact assessed (no new unvalidated inputs)

## Consistency Impact
<!-- Describe any public API, ABI, or cross-backend behavior changes -->

## Stub Introduction
- [ ] **No new stubs introduced** (default: forbidden on main/release branches)
- [ ] Waiver attached if stub is required: <link>

## Cross-Section Consistency Tags
<!-- Check all that apply -->
- [ ] `api` — Public type/function signature change
- [ ] `abi` — ABI struct/function pointer change
- [ ] `docs` — Documentation change
- [ ] `tests` — Test change
- [ ] `manifest` — Backend manifest change

## Risk Profile
<!-- Low / Medium / High — with rationale -->
```

## Tracking Rules

1. Every checklist item maps to one or more issues/tasks.
2. Every PR must reference the checklist items it addresses.
3. Every PR requires explicit "consistency impact" note for API/ABI/behavior changes.
4. Stub introduction checkbox defaults to **forbidden** for main/release branches.
5. Cross-section consistency tags required on every implementation PR.
