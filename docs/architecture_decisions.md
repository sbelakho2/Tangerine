# Architecture Decisions and Invariants
## TG-GFX-UI-SPEC-001 v0.1 §17

---

## Architecture Decision Records (ADRs)

### ADR-001: Backend-Agnostic API Semantics
- **Status:** Accepted
- **Context:** The graphics/UI stack must work identically across multiple platform backends.
- **Decision:** All public API types and traits are defined in host-owned modules (`std/*.tg`). Backends implement matching ABI interfaces but never leak backend-specific types into the public API.
- **Consequence:** Applications are portable across backends without source changes.

### ADR-002: Capability-Gated Side Effects
- **Status:** Accepted
- **Context:** Clipboard, IME, drag-drop, and GPU operations have security/permission implications.
- **Decision:** All side-effect APIs require an explicit capability parameter (e.g., `ClipboardCap`, `ImeCap`, `DragDropCap`). The runtime vends capabilities only when the platform and manifest permit.
- **Consequence:** Unauthorized operations fail at the type level — no runtime surprise.

### ADR-003: Opaque Handle Pattern for Resources
- **Status:** Accepted
- **Context:** GPU handles, font databases, paths, and other backend resources must be safely passed through the ABI boundary.
- **Decision:** All resource types use opaque structs containing `_opaque: u64`. The actual resource lives in the backend; the host holds only a handle token.
- **Consequence:** Handle types are trivially copyable across FFI, and lifetime is backend-managed.

### ADR-004: f32-Based Color Model
- **Status:** Accepted
- **Context:** The legacy `std/ui.tg` used `u8`-based Color which limits precision for HDR / Display P3.
- **Decision:** New spec uses `Color { r: f32, g: f32, b: f32, a: f32 }` in `std/geom.tg` with a `ColorSpace` enum (SRGB, DisplayP3).
- **Consequence:** Full precision for wide-gamut and HDR workflows. Backends convert to native format.

### ADR-005: Reference Implementations as Fallback
- **Status:** Accepted
- **Context:** Backends may not all be available; applications need a guaranteed functional path.
- **Decision:** Provide reference CPU implementations: `SoftwareApp/SoftwareWindow` (app.tg), `SoftwareCanvas/SoftwareSurface` (gfx.tg), PNG codec (image.tg), monospace shaper (text.tg).
- **Consequence:** Applications always work even without a hardware-accelerated backend.

### ADR-006: Stable C ABI for Plugins
- **Status:** Accepted
- **Context:** Backend plugins are loaded as dynamic libraries at runtime.
- **Decision:** Use a stable C ABI with `repr(c)` structs, function pointers as `u64`, and `TgStr/TgSlice` for cross-boundary data. Version with `TgInterfaceHeader` for forward compatibility.
- **Consequence:** Plugins can be built with any toolchain that targets C ABI. Minor version additions don't break existing plugins.

### ADR-007: Event-Driven Architecture (Single Event Enum)
- **Status:** Accepted
- **Context:** Need to represent all input, window, and platform events uniformly.
- **Decision:** Single `Event` enum with 19 variants covering keyboard, mouse, scroll, resize, focus, close, redraw, IME, and drag-drop.
- **Consequence:** Event dispatch is a single match expression. Backend maps native events to this canonical set.

---

## Recorded Invariants

| ID | Invariant | Enforcement |
|----|-----------|-------------|
| INV-001 | API semantics are backend-agnostic and host-owned | ADR-001: All traits/types in `std/*.tg` |
| INV-002 | Capability checks occur before side-effect operations | ADR-002: Capability params required at type level |
| INV-003 | UI-thread affinity for required calls is enforced by design | `App.run()`, `Window.*`, `Canvas.*` are main-thread only; documented in threading model |
| INV-004 | ABI boundary ownership and allocation rules are never violated | `TgHostV1.alloc/free` for all cross-boundary memory; documented in §14.1 |
| INV-005 | Deterministic behavior is declared (or non-determinism flagged) in manifest | `deterministic_raster` + `gpu_nondeterminism_possible` flags in manifest capabilities |
| INV-006 | No unchecked integer overflows in size/stride/buffer computations | Bounds checks in `SoftwareCanvas`, `encode_png`, `decode_png` |
| INV-007 | Error types provide `message()` and `code()` accessors for all failure modes | All 7 error enums implement `message() -> String` and `code() -> i32` |

## Compatibility Policy

### ABI Minor-Version Growth
- New fields **MAY** be appended to interface structs (e.g., `TgGfxV1`).
- Existing field offsets **MUST NOT** change.
- `TgInterfaceHeader.size_bytes` **MUST** be checked before reading new fields.
- `validate_interface_header()` enforces minimum size.

### Deprecation Policy
- Deprecated APIs are marked with `# @deprecated` comments for at least one minor version.
- Removal requires ABI major version bump (`TG_BACKEND_ABI_MAJOR` increment).
- Migration notes are published per §30.
