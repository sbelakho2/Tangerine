# Knowledge Transfer and Maintainability — TG-GFX-UI-SPEC-001 v0.1

> Normative reference for §40 of the graphics/UI development checklist.

---

## 1. Onboarding Guide for New Contributors

### 1.1 Prerequisites

- Familiarity with Tangerine language syntax (Ruby/Rust-inspired).
- Read the spec overview: `tangerine_graphics_ui_development_checklist.md` §0–3.
- Read the developer guide: `docs/developer_guide.md`.

### 1.2 Getting Started

1. **Clone and build:**
   ```sh
   git clone <repo> && cd Tangerine
   make build
   make test
   ```

2. **Explore the architecture:**
   - `std/geom.tg` → Geometry primitives (start here)
   - `std/gfx_errors.tg` → Error model (understand error patterns)
   - `std/app.tg` → Windowing/events (understand lifecycle)
   - `std/gfx.tg` → 2D drawing (core rendering)

3. **Run the GFX/UI tests:**
   ```sh
   make test-gfx-ui
   ```

4. **Read the module-by-module guide:** `docs/developer_guide.md` §1.

### 1.3 Key Concepts

| Concept            | Location                        | Summary                              |
|--------------------|----------------------------------|--------------------------------------|
| Error model        | `std/gfx_errors.tg`             | Typed errors per module              |
| Color convention   | `std/geom.tg`                   | f32 RGBA in [0,1]                    |
| Widget lifecycle   | `std/ui_toolkit.tg`             | measure → layout → paint → event    |
| Backend ABI        | `std/backend_abi.tg`            | C ABI with interface headers         |
| Capability model   | `std/platform.tg`               | Proof tokens gate optional features  |
| State stack        | `std/gfx.tg`                    | save()/restore() for clip+transform  |

### 1.4 First Contribution Ideas

- Add a new widget to `std/ui_toolkit.tg` + test in `tests/unit/`.
- Add a new geometry helper to `std/geom.tg`.
- Improve error messages in `std/gfx_errors.tg`.
- Add a new reference example in `examples/`.

---

## 2. Architecture Walkthroughs

### 2.1 Core Module Walkthrough

| Module               | File                      | Key Concept                         | Duration |
|----------------------|---------------------------|-------------------------------------|----------|
| Geometry             | `std/geom.tg`             | Vec2/Rect/Color/Transform/Path      | 30 min   |
| Error model          | `std/gfx_errors.tg`       | ErrorCode + per-module enums        | 15 min   |
| Windowing            | `std/app.tg`              | Event enum + App/Window traits      | 30 min   |
| 2D Drawing           | `std/gfx.tg`              | Canvas trait + state stack          | 45 min   |
| Text pipeline        | `std/text.tg`             | FontDb → shape → layout → render   | 30 min   |
| Widget toolkit       | `std/ui_toolkit.tg`       | Widget trait + 12 built-in widgets  | 45 min   |
| Backend ABI          | `std/backend_abi.tg`      | Interface structs + manifest + loader| 60 min   |

### 2.2 ABI Boundary Walkthrough

1. **Manifest:** How `tg_backend_manifest_v1` declares capabilities.
2. **Init:** How `tg_backend_init_v1` returns interface pointers.
3. **Interface dispatch:** How `query_interface` routes to typed structs.
4. **Lifetime:** Ownership rules for `TgStr`, `TgSlice`, handles.
5. **Version growth:** How `size_bytes` enables forward compatibility.

---

## 3. Bus-Factor Mitigation

### 3.1 Minimum Maintainer Coverage

| Subsystem            | Primary Owner | Secondary Owner | Status    |
|----------------------|---------------|-----------------|-----------|
| Geometry             | TBD           | TBD             | ⚠️ Needed |
| Error model          | TBD           | TBD             | ⚠️ Needed |
| Windowing/Events     | TBD           | TBD             | ⚠️ Needed |
| 2D Drawing           | TBD           | TBD             | ⚠️ Needed |
| Text                 | TBD           | TBD             | ⚠️ Needed |
| UI Toolkit           | TBD           | TBD             | ⚠️ Needed |
| Backend ABI          | TBD           | TBD             | ⚠️ Needed |
| GPU                  | TBD           | TBD             | ⚠️ Needed |
| Image                | TBD           | TBD             | ⚠️ Needed |
| Platform features    | TBD           | TBD             | ⚠️ Needed |
| Performance/Perf     | TBD           | TBD             | ⚠️ Needed |
| Diagnostics          | TBD           | TBD             | ⚠️ Needed |
| CI/Build             | TBD           | TBD             | ⚠️ Needed |
| Release engineering  | TBD           | TBD             | ⚠️ Needed |

> **Action:** Assign at least two maintainers per subsystem before M2 milestone.

---

## 4. Code Ownership and Reviewer Rotation

### 4.1 Ownership

- Each `std/*.tg` module has a designated owner (see `docs/governance.md`).
- PRs modifying a module require approval from the module owner.
- Cross-module PRs require approval from all affected owners.

### 4.2 Rotation

- Review assignments rotate weekly to prevent bottlenecks.
- No single reviewer handles more than 5 PRs per week without escalation.
- Rotation schedule is maintained in the engineering calendar.

---

## 5. Recurring Checklist Refresh

### 5.1 Cadence

- Checklist is refreshed at the start of each release cycle.
- See `docs/post_release.md` §5 for the refresh process.

### 5.2 Triggers for Off-Cycle Refresh

- New section added to the spec.
- Major architecture decision (ADR) that affects multiple sections.
- Post-mortem finding that requires new checklist items.

---

## 6. Evidence Archive

### 6.1 What Is Archived

| Evidence Type        | Location                          | Retention        |
|----------------------|-----------------------------------|-----------------|
| Test run results     | CI artifacts                      | 1 year          |
| Performance reports  | CI benchmark artifacts             | 1 year          |
| Security reviews     | `docs/security.md` + issue tracker | Permanent       |
| Certification reports| `docs/plugin_certification.md`     | Per version     |
| Checklist snapshots  | Git tags (per release)             | Permanent       |
| SBOM                 | Release artifacts                  | Per version     |

### 6.2 Linking

- Every completed checklist item has an `**Evidence:**` link to the implementation.
- Evidence links use relative paths that are stable across repository moves.
- Orphaned evidence links are detected by CI (broken link checker).
