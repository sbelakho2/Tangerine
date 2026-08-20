# Migration and Compatibility Planning — TG-GFX-UI-SPEC-001 v0.1

> Normative reference for §30 of the graphics/UI development checklist.

---

## 1. Migration Notes: Pre-v0.1 Prototypes → v0.1

### 1.1 Breaking Changes

| Area                | Old (pre-v0.1)                     | New (v0.1)                          | Remediation                             |
|---------------------|-------------------------------------|--------------------------------------|-----------------------------------------|
| Color type          | `u8`-based `Color` in `std/ui.tg`  | `f32`-based `Color` in `std/geom.tg`| Replace `Color(r, g, b, a)` with `Color { r: r/255.0, ... }` |
| Error model         | Ad-hoc string errors                | Typed enums (`GfxError`, etc.)       | Match on error variants instead of strings |
| Event model         | Platform-specific event structs     | Unified `Event` enum (19 variants)   | Map old event handlers to `match event` |
| Widget system       | Imperative draw calls               | `Widget` trait with measure/layout/paint | Implement `Widget` trait for custom widgets |
| Canvas API          | Loose function set                  | `trait Canvas` with 15 methods       | Adopt `Surface.begin()` → `Canvas` workflow |
| Font loading        | Direct file path                    | `FontDb.load(family, size)`          | Use `FontDb` registry pattern           |
| Backend interface   | Direct function calls               | Stable C ABI with `TgManifestV1`     | Rewrite backends against ABI spec §14   |

### 1.2 Non-Breaking Changes

| Area                | Change                               | Impact                               |
|---------------------|--------------------------------------|--------------------------------------|
| Geometry types      | Added `RRect`, `Path`, `ColorSpace`  | Additive; existing code unaffected   |
| Text layout         | Added `hit_test`, `selection_rects`  | Additive; existing code unaffected   |
| Accessibility       | Added `A11yNode`, `tree_emit`        | Additive; optional integration       |

---

## 2. Compatibility Shims

### 2.1 Policy

Compatibility shims are provided **only** where:
1. The migration path is non-trivial (requires significant refactoring).
2. The old API was in widespread use.
3. The shim can be implemented without compromising the new API's semantics.

All shims are **time-bounded**: they will be removed no later than v0.3.

### 2.2 Provided Shims

| Shim                         | Location           | Bridges                        | Removal Target |
|------------------------------|--------------------|---------------------------------|----------------|
| `Color.from_u8(r, g, b, a)` | `std/geom.tg`     | u8 Color → f32 Color           | v0.3          |
| `legacy_draw_rect(x,y,w,h)` | (not provided)     | —                               | —             |

> **Note:** The number of shims is intentionally minimal. The v0.1 API is the
> authoritative interface. Consumers should migrate directly.

---

## 3. Intentional Breakage Registry

| ID     | Breakage                                  | Rationale                                               | Remediation                                |
|--------|-------------------------------------------|---------------------------------------------------------|--------------------------------------------|
| BRK-01 | u8 Color removed from public API          | f32 Color is more precise, avoids gamma errors          | Use `Color { r: v/255.0, ... }`           |
| BRK-02 | String-based errors replaced              | Typed errors enable programmatic handling               | Match on error enum variants              |
| BRK-03 | Event model changed to unified enum       | Single dispatch point simplifies backends               | Convert match arms                        |
| BRK-04 | Canvas API formalized as trait            | Enables backend polymorphism                            | Implement against `trait Canvas`          |
| BRK-05 | Backend loading changed to ABI plugin     | Enables decoupled versioning and 3rd-party backends     | Rewrite against `backend_abi.tg` spec     |
| BRK-06 | Widget system changed to retained mode    | Enables layout optimization, a11y, and testing          | Implement `Widget` trait                  |

---

## 4. ABI Minor-Increment Compatibility Verification

### 4.1 Policy

See docs/current/architecture_decisions.md — Compatibility Policy.

### 4.2 Verification Process

For each ABI minor version bump:

1. **Additive check:** New fields are appended only. Existing fields are unchanged.
2. **Size check:** `size_bytes` in interface headers increases monotonically.
3. **Symbol check:** Existing exported symbols (`tg_backend_manifest_v1`, `tg_backend_init_v1`) remain unchanged.
4. **Behavior check:** Existing function pointer slots maintain their documented semantics.
5. **Test:** Run the full ABI conformance suite (`tests/abi/test_abi_conformance.tg`) against both the old and new interface definitions.

### 4.3 Automated Verification

The `abi-layout-check` Makefile target verifies layout compatibility on each build.
The `gfx-ui-gate` CI job blocks merges that would break ABI compatibility.
