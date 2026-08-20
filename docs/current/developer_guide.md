# Developer Documentation — TG-GFX-UI-SPEC-001 v0.1

> Normative reference for §28 of the graphics/UI development checklist.

---

## 1. Module-by-Module Implementation Guides

Each guide maps to spec sections 4–14 and references the implementation file directly.

### 1.1 Error Model (§4 → `std/gfx_errors.tg`)

- **Goal:** Define a unified, typed error hierarchy for all GFX/UI subsystems.
- **Key types:** `ErrorCode` (8 variants), `Error` struct, plus per-module error enums (`GfxError`, `TextError`, `ImageError`, `GpuError`, `PlatformError`, `AbiError`).
- **Pattern:** Every fallible function returns `Result[T, E]` where `E` is the module-specific error.
- **Cross-reference:** docs/current/gfx_ui_invariants.md — Error propagation invariant.

### 1.2 Geometry (§5 → `std/geom.tg`)

- **Goal:** Provide the mathematical primitives used across all modules.
- **Key types:** `Vec2`, `Vec3`, `Rect`, `RRect`, `Color` (f32-based), `ColorSpace`, `Transform2D`, `Path`.
- **Color convention:** RGBA f32 in [0.0, 1.0]. **Not** the old u8-based Color from `std/ui.tg`.
- **Transform:** Column-major 3×2 affine matrix. `identity()`, `translate()`, `rotate()`, `scale()`, `concat()`.

### 1.3 Windowing & Events (§6 → `std/app.tg`)

- **Goal:** Lifecycle management + input event dispatch.
- **Key types:** `Event` (19 variants), `AppOpts`, `trait App`, `trait Window`, `SoftwareApp`/`SoftwareWindow`.
- **Event loop:** `App.run(callback)` → dispatches `Event` variants to user callback.
- **Thread model:** All window/event calls on UI thread only.

### 1.4 2D Drawing (§7 → `std/gfx.tg`)

- **Goal:** Immediate-mode 2D vector and raster drawing.
- **Key types:** `Paint`, `Stroke`, `BlendMode`, `trait Surface`, `trait Canvas` (15 methods).
- **State model:** `save()`/`restore()` stack for clip+transform state.
- **Reference impl:** `SoftwareCanvas` — pixel-exact reference for conformance.

### 1.5 GPU (§8 → `std/gfx_gpu.tg`)

- **Goal:** Optional GPU-accelerated rendering (Tier C).
- **Key types:** 16 opaque handles, 4 enums, `GpuError`.
- **All functions return `GpuError::Unsupported`** in reference impl — backends provide real implementations.

### 1.6 Image (§9 → `std/image.tg`)

- **Goal:** Image decode/encode/manipulation.
- **Key types:** `PixelFormat`, `Bitmap`, PNG decode/encode with CRC-32 + Adler-32.
- **Security:** All decoders validate headers/checksums; malformed input returns `ImageError`.

### 1.7 Text (§10 → `std/text.tg`)

- **Goal:** Font loading, text shaping, layout, hit-testing.
- **Key types:** `FontDb`, `Glyph`, `GlyphRun`, `TextLayout`.
- **Pipeline:** `FontDb.load()` → `shape()` → `layout()` → render/hit_test.

### 1.8 UI Toolkit (§11 → `std/ui_toolkit.tg`)

- **Goal:** Retained-mode widget tree with measure/layout/paint/event phases.
- **Key types:** `Widget` trait (6 methods), 12 built-in widgets, `PaintList` (11 commands).
- **Phases:** measure → layout → paint → event dispatch.

### 1.9 Platform Features (§12 → `std/platform.tg`)

- **Goal:** Capability-gated platform integration (clipboard, IME, drag-drop).
- **Pattern:** Each function takes a `Cap` proof parameter. Missing cap → `PlatformError::Unsupported`.

### 1.10 Supporting Modules (§13)

- `std/anim.tg` — Easing functions + `Timeline` for animation.
- `std/compositor.tg` — Layer compositing with damage tracking.
- `std/assets.tg` — Content-addressable asset loading and caching.
- `std/accessibility.tg` — a11y tree emission with `Role`, `A11yNode`, `tree_emit`.

### 1.11 Backend ABI (§14 → `std/backend_abi.tg`)

- **Goal:** Stable C ABI for backend plugins.
- **Key types:** `TgStr`, `TgSlice`, 8 interface structs, 18 event tags, `TgManifestV1`, `LoaderConfig`.
- **Pattern:** All interface structs start with `InterfaceHeader { name, version, size_bytes }`.

---

## 2. Backend Plugin Author Guide

### 2.1 Getting Started

1. Create a shared library exporting two symbols:
   ```c
   TgManifestV1* tg_backend_manifest_v1(void);
   TgInitResultV1 tg_backend_init_v1(TgHostV1* host);
   ```

2. Fill the manifest with your backend's name, version, capabilities, and interface list.

3. Implement the required interfaces:
   - `TgAppV1` — windowing + event loop
   - `TgGfxV1` — 2D drawing
   - `TgTextV1` — text shaping/layout

4. Optionally implement:
   - `TgImageV1`, `TgClipboardV1`, `TgImeV1`, `TgDragDropV1`, `TgGpuV1`

### 2.2 Interface Implementation Pattern

```c
// Every interface struct starts with a header
typedef struct {
    TgStr name;          // e.g., "tg.gfx.v1"
    uint32_t version;    // interface version
    uint32_t size_bytes; // sizeof this struct — for forward compatibility
} TgInterfaceHeader;

typedef struct {
    TgInterfaceHeader header;
    // Function pointers...
    uint64_t create_surface;  // fn(width: u32, height: u32) -> handle
    uint64_t destroy_surface; // fn(handle: u64) -> void
    // ...
} TgGfxV1;
```

### 2.3 Important Rules

- **Ownership:** Host owns `TgStr`/`TgSlice` data during the call. Copy if you need to retain.
- **Error handling:** Return typed error codes. Never panic/abort from a plugin function.
- **Thread safety:** All function pointers may be called from the UI thread only unless documented otherwise.
- **Version growth:** New fields are appended to interface structs. `size_bytes` gates access.

---

## 3. Capability Model Guide

### 3.1 Concept

Capabilities are proof tokens that gate access to optional platform features. They are:
- Granted at session init based on the backend's manifest
- Immutable for the session lifetime
- Required as parameters to capability-gated functions

### 3.2 Example: Clipboard

```tg
use std::platform

## Attempt to read clipboard — requires Cap::Clipboard
def try_read_clipboard(cap: Cap::Clipboard) -> Result[String, PlatformError]
  clipboard_read_text(cap)
end

## Without the cap, the function cannot be called (type system enforces)
```

### 3.3 Available Capabilities

| Capability      | Required By         | Granted When                    |
|-----------------|---------------------|---------------------------------|
| `Cap::Clipboard`| `clipboard_*`       | Backend exports TgClipboardV1   |
| `Cap::Ime`      | `ime_*`             | Backend exports TgImeV1         |
| `Cap::DragDrop` | `dragdrop_*`        | Backend exports TgDragDropV1    |
| `Cap::Gpu`      | `gpu_*`             | Backend exports TgGpuV1         |

---

## 4. Determinism/Replay Usage Guide

### 4.1 Concept

Determinism means: same inputs + same assets + same config → same pixel output.

### 4.2 Using Replay

1. **Record:** Enable event recording — all events + timestamps are captured.
2. **Replay:** Feed the recorded event stream back — output should be identical.
3. **Verify:** Compare frame hashes or pixel diffs.

### 4.3 Known Non-Determinism

- GPU rendering may produce per-driver rounding differences.
- The manifest flag `gpu_nondeterminism_possible` declares this.
- Tests should skip pixel-exact comparison when this flag is set.

### 4.4 Determinism Invariants

- Software backend (`SoftwareCanvas`) is fully deterministic.
- Font shaping is deterministic for the same font binary + text + locale.
- Image encoding is deterministic for the same pixel data + parameters.

---

## 5. Troubleshooting Guide

### 5.1 Backend Load Failures

| Symptom                            | Cause                                | Fix                                    |
|------------------------------------|--------------------------------------|----------------------------------------|
| "Backend not found"                | No SO/DLL at search paths            | Check `TG_BACKEND_PATH`; verify path   |
| "Manifest validation failed"       | Missing required fields in manifest  | Ensure all required fields are present |
| "ABI version mismatch"             | Plugin built against different ABI   | Rebuild plugin against current headers |
| "Required interface missing"       | Backend lacks `tg.app.v1`, etc.      | Implement all required interfaces      |

### 5.2 Rendering Issues

| Symptom                            | Cause                                | Fix                                    |
|------------------------------------|--------------------------------------|----------------------------------------|
| Blank window                       | No `begin_frame`/`end_frame` calls   | Check event loop + frame lifecycle     |
| Incorrect colors                   | Color space mismatch                 | Ensure SRGB or match backend space     |
| Clipping incorrect                 | Mismatched `save()`/`restore()`      | Audit state stack; use perf validator  |
| Text garbled                       | Font not loaded or wrong encoding    | Check `FontDb.load()` result           |

### 5.3 Performance Issues

| Symptom                            | Cause                                | Fix                                    |
|------------------------------------|--------------------------------------|----------------------------------------|
| Frame drops                        | Exceeding frame budget               | Check `FrameTimer.p95_ms()`           |
| Memory growth                      | Cache not evicting                   | Check `CacheMetrics.usage_pct()`       |
| Slow startup                       | Plugin discovery scanning too many dirs | Restrict `LoaderSearchOrder`        |

---

## 6. Quickstart Environment Setup

### 6.1 Local Development

```sh
# Clone
git clone <repo-url> && cd Tangerine

# Build
make build

# Run tests
make test

# Run GFX/UI tests
make test-gfx-ui

# Scan for stubs
make stub-scan

# Check ABI layout
make abi-layout-check
```

### 6.2 CI Setup

The CI pipeline is defined in `.github/workflows/ci.yml`. Key jobs:
- `gfx-ui`: Unit + integration + ABI tests, cross-platform matrix.
- `gfx-ui-visual`: Golden + determinism + fuzz tests with artifact upload.
- `gfx-ui-gate`: Required merge gate.
- `release-freeze`: Blocks non-conformance PRs on release branches.

### 6.3 Release Engineering

See docs/current/build_system.md for build profiles, artifact naming, and reproducibilty checks.

---

## 7. API Reference Generation

- All public types and functions are documented with `##` doc comments in the `.tg` source files.
- The `tg_compiler/docgen.tg` module extracts these into structured API reference.
- Generated docs are published alongside each release.
- Cross-references between modules use `use` import paths for navigation.
