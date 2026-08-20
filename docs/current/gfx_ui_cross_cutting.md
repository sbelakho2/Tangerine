# Cross-Cutting Requirements — TG-GFX-UI-SPEC-001 v0.1

**Date:** 2026-03-02  

## 1. Capabilities & Side Effects

Every side-effecting operation in the graphics/UI stack is gated behind a
capability token. Capability tokens are opaque handles granted by the host
runtime; they cannot be forged or manufactured by application code.

| Capability | Gates | Module(s) |
|------------|-------|-----------|
| `DisplayCap` | Window creation, surface presentation, UI rendering | `tg::app`, `tg::gfx`, `tg::ui` |
| `ClipboardCap` | Clipboard read/write | `tg::clipboard` |
| `FsCap` | File-based asset loading (fonts, images) | `tg::assets`, `tg::text`, `tg::image` |
| `ImeCap` | Input method editor services | `tg::ime` |
| `DragDropCap` | Drag-and-drop operations | `tg::dragdrop` |
| `ClockCap` | Time access (animation, timers) | `tg::app`, `tg::anim` |
| `RandomCap` | Randomness | Application code |
| `NetCap` | Remote asset fetch (out of scope for this spec) | — |

## 2. Coordinates & DPI

- All UI coordinates use DIP (device-independent pixels).
- Backend provides per-window DPI scale factor via `Window::dpi() -> Dpi`.
- Backends SHOULD perform raster snapping to physical pixels for text baselines
  and hairline strokes using backend-specific hinting.
- The host converts DIP → physical pixels at the Surface/Canvas boundary.

## 3. Determinism & Replayability

- `tg::app` exposes an optional event recorder API (`recorder_start`/`recorder_stop`).
- Event streams SHOULD be recordable and replayable for testing.
- With identical events, assets, and config, output SHOULD be deterministic
  within ≤ 1 LSB per sRGB channel tolerance.
- If a backend cannot guarantee determinism (e.g., GPU driver variance), it
  MUST declare `gpu_nondeterminism_possible: true` in its manifest capabilities.

## 4. Threading Model

### UI Thread (required for):
- Window creation and destruction
- Event polling (`poll_event`)
- Surface presentation (`present`)
- Most backend calls unless explicitly documented as thread-safe

### Worker Threads (allowed for):
- Image/raster decode
- Font shaping and layout computation
- Asset I/O (file reads)

### Marshaling Rule:
Worker thread results MUST be marshaled back to the UI thread before
presentation. The host provides no implicit synchronization.

### Backend Thread-Affinity:
Backends MUST publish additional thread-affinity constraints via manifest
flags (e.g., `threadsafe_calls: ["image_decode", "text_shape"]`).

## 5. Consistency Checks

- Capability behavior is consistent between documentation, runtime checks,
  and returned error types.
- Determinism/threading declarations in manifests match actual runtime behavior.
- No capability/threading path uses placeholder logic in release profile.
