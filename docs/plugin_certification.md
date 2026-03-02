# Plugin Certification and Compatibility Program — TG-GFX-UI-SPEC-001 v0.1

> Normative reference for §37 of the graphics/UI development checklist.

---

## 1. Backend Certification Criteria

A backend is certified when it passes all required gates for its target tier.

### 1.1 Required Gates

| Gate                     | Tier A | Tier B | Tier C | Description                                   |
|--------------------------|--------|--------|--------|-----------------------------------------------|
| Manifest valid           | ✅     | ✅     | ✅     | `tg_backend_manifest_v1` returns valid manifest|
| Init succeeds            | ✅     | ✅     | ✅     | `tg_backend_init_v1` returns all required ifaces|
| `tg.app.v1` conformance  | ✅     | ✅     | ✅     | Window lifecycle + event dispatch              |
| `tg.gfx.v1` conformance  | ✅     | ✅     | ✅     | Canvas 15 methods + state stack                |
| `tg.text.v1` conformance | ✅     | ✅     | ✅     | Font load + shape + layout                     |
| `tg.image.v1` conformance| —      | ✅     | ✅     | PNG decode/encode round-trip                   |
| `tg.clipboard.v1`        | —      | ✅     | ✅     | Read/write text (if declared)                  |
| `tg.gpu.v1` conformance  | —      | —      | ✅     | GPU pipeline create/draw/present               |
| ABI layout check         | ✅     | ✅     | ✅     | All struct sizes match reference               |
| Determinism declared     | ✅     | ✅     | ✅     | Manifest flags set correctly                   |
| Zero stubs               | ✅     | ✅     | ✅     | No TODO/FIXME/STUB in exported paths           |

### 1.2 Quality Gates

| Gate                 | Requirement                                              |
|----------------------|----------------------------------------------------------|
| Performance          | Meets §23 budgets on target hardware                     |
| Security             | Passes §24 validation (no unchecked inputs, no panics)   |
| Stress               | Passes §34 soak + create/destroy tests                    |
| Thread safety        | Passes §35 UI-thread enforcement + TSAN clean            |

---

## 2. Certification Test Suite Package

### 2.1 Contents

The certification test suite is provided as a standalone package that backend authors use:

| Test File                              | Purpose                              |
|----------------------------------------|--------------------------------------|
| `tests/abi/test_abi_conformance.tg`     | ABI structure + symbol validation    |
| `tests/unit/test_geom.tg`              | Geometry math conformance            |
| `tests/unit/test_events.tg`            | Event translation conformance        |
| `tests/unit/test_paint.tg`             | Canvas/paint conformance             |
| `tests/unit/test_text.tg`             | Text pipeline conformance            |
| `tests/integration/test_pipelines.tg`  | Full pipeline integration            |
| `tests/golden/test_visual_regression.tg`| Visual output conformance           |
| `tests/determinism/test_replay.tg`     | Determinism verification             |
| `tests/consistency/test_consistency.tg`| Cross-backend consistency            |
| `tests/stress/test_stress.tg`          | Reliability under load               |
| `tests/concurrency/test_thread_safety.tg`| Thread safety                      |
| `scripts/conformance_gates.tg`         | Gate runner                          |

### 2.2 Usage

```sh
# Run certification suite against your backend
TG_BACKEND_PATH=/path/to/your/backend make test-gfx-ui

# Run individual gate
tg run scripts/conformance_gates.tg
```

---

## 3. Certification Report Template

```markdown
# Backend Certification Report

## Backend Information
- **Name:** [backend name]
- **Version:** [version]
- **Target Platform:** [platform]
- **ABI Version:** [major.minor]
- **Date:** [YYYY-MM-DD]

## Capabilities Declared
- [ ] tg.app.v1 (required)
- [ ] tg.gfx.v1 (required)
- [ ] tg.text.v1 (required)
- [ ] tg.image.v1 (optional)
- [ ] tg.clipboard.v1 (optional)
- [ ] tg.ime.v1 (optional)
- [ ] tg.dragdrop.v1 (optional)
- [ ] tg.gpu.v1 (optional)

## Determinism
- Deterministic raster: [yes/no]
- GPU non-determinism possible: [yes/no]

## Gate Results
| Gate              | Status  | Notes |
|-------------------|---------|-------|
| Manifest valid    | ✅/❌   |       |
| Init succeeds     | ✅/❌   |       |
| App conformance   | ✅/❌   |       |
| Gfx conformance   | ✅/❌   |       |
| Text conformance  | ✅/❌   |       |
| Image conformance | ✅/❌/NA|       |
| ABI layout        | ✅/❌   |       |
| Performance       | ✅/❌   |       |
| Security          | ✅/❌   |       |
| Stress            | ✅/❌   |       |

## Known Limitations
- [list any known limitations or deviations]

## Certification Decision
- **Certification Level:** [Tier A / Tier B / Tier C / Not Certified]
- **Approved By:** [name]
- **Valid Until:** [date or next ABI version]
```

---

## 4. Compatibility Badge Levels

| Badge              | Requirements                             | Display                      |
|--------------------|------------------------------------------|------------------------------|
| **Tier A Certified** | All required gates + quality gates pass | 🟢 `TG Certified: Tier A`  |
| **Tier B Certified** | Tier A + optional interfaces (image, clipboard) | 🟢 `TG Certified: Tier B`  |
| **Tier C Certified** | Tier B + GPU conformance                | 🟢 `TG Certified: Tier C`  |
| **Not Certified**   | Any required gate fails                  | 🔴 `Not Certified`          |

### Badge Display Rules

- Badges are displayed in the compatibility matrix published with each release.
- Badges are revoked if a certified backend fails conformance on re-test.
- Backend authors may display the badge in their documentation if currently valid.

---

## 5. Regression Policy for Certified Backends

### 5.1 Detection

- Certified backends are re-tested on each Tangerine release candidate.
- Regression = any previously-passing gate now fails.

### 5.2 Response

| Regression Severity | Response                                          | Timeline           |
|--------------------|---------------------------------------------------|--------------------|
| Required gate      | Badge suspended; backend author notified           | Immediate          |
| Quality gate       | Warning issued; grace period for fix               | 2 weeks            |
| Visual regression  | Investigate; may be host-side change               | 1 week             |

### 5.3 Re-Certification

- Backend author submits fix and re-runs certification suite.
- If all gates pass, badge is restored.
- If fix is not provided within grace period, badge is permanently revoked for that version.
