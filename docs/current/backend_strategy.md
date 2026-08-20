# Backend Strategy and Compatibility Matrix
## TG-GFX-UI-SPEC-001 v0.1 §18

---

## Reference Backends

| Platform | Reference Backend | Status |
|----------|-------------------|--------|
| macOS | `tg-backend-macos` (CoreGraphics + AppKit) | Planned — reference |
| Linux | `tg-backend-linux` (X11/Wayland + Cairo/Skia) | Planned — reference |
| Windows | `tg-backend-win32` (Direct2D + Win32) | Planned — reference |
| Cross-platform (software) | Built-in `SoftwareApp/SoftwareCanvas` | **Implemented** — fallback |

## Optional Backends and Maturity Levels

| Backend | Maturity | Notes |
|---------|----------|-------|
| `tg-backend-skia` | Experimental | Skia-based cross-platform GPU path |
| `tg-backend-wgpu` | Experimental | WebGPU/wgpu for Tier C GPU |
| `tg-backend-web` | Planned | Browser via Canvas2D / WebGL / WebGPU |

## Feature Matrix by Backend

| Feature | Software (built-in) | macOS (planned) | Linux (planned) | Windows (planned) |
|---------|:-------------------:|:---------------:|:---------------:|:-----------------:|
| **Required interfaces** | | | | |
| `tg.app.v1` | ✅ | ✅ | ✅ | ✅ |
| `tg.gfx.v1` | ✅ | ✅ | ✅ | ✅ |
| `tg.text.v1` | ✅ (monospace) | ✅ | ✅ | ✅ |
| **Optional interfaces** | | | | |
| `tg.image.v1` | ✅ (PNG only) | ✅ | ✅ | ✅ |
| `tg.clipboard.v1` | ❌ | ✅ | ✅ | ✅ |
| `tg.ime.v1` | ❌ | ✅ | ✅ | ✅ |
| `tg.dragdrop.v1` | ❌ | ✅ | ✅ | ✅ |
| `tg.gpu.v1` | ❌ | ✅ (Metal) | ✅ (Vulkan) | ✅ (D3D12) |
| **Qualities** | | | | |
| Deterministic raster | ✅ | ⚠️ (backend-dependent) | ⚠️ | ⚠️ |
| Thread-safe calls | ❌ (single-threaded) | ⚠️ (main-thread) | ⚠️ | ⚠️ |
| Color space: SRGB | ✅ | ✅ | ✅ | ✅ |
| Color space: DisplayP3 | ❌ | ✅ | ❌ | ❌ |

**Legend:** ✅ = supported, ❌ = not available, ⚠️ = conditional/limited

## Known Backend Limitations

1. **Software fallback** — No clipboard, IME, drag-drop, or GPU. Monospace-only text shaping. Single-threaded only. No wide-gamut color space.
2. **GPU backends** — Non-deterministic rasterization across driver versions. Declared via `gpu_nondeterminism_possible` manifest flag.
3. **macOS** — AppKit requires main-thread for all UI calls. Display P3 supported on compatible displays only.
4. **Linux** — Wayland clipboard requires compositor cooperation. Some X11 IMEs have incomplete protocol support.
5. **Windows** — High-DPI scaling requires per-monitor DPI awareness manifest setting.

## Runtime Capability Query

Applications query backend capabilities at runtime:
1. Load backend via `tg_backend_init_v1()`.
2. Call `query_interface()` for each needed interface.
3. If `ok=false`, the interface is unavailable — fall back or inform the user.
4. Read manifest JSON for determinism/threading/platform capability flags.

Diagnostics for unsupported features are emitted via `TgHostV1.log()` with level `WARN`.
