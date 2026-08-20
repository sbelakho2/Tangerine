# Security, Safety, and Robustness — TG-GFX-UI-SPEC-001 v0.1

> Normative reference for §24 of the graphics/UI development checklist.

## 1. Threat Model — Plugin Loading and ABI Boundary

### 1.1 Threat Surface

| Entry Point          | Threat                                           | Mitigation                                           |
|----------------------|--------------------------------------------------|------------------------------------------------------|
| Plugin SO/DLL load   | Malicious or corrupted binary                    | Restrict search paths (§1.2); validate manifest first |
| `tg_backend_init_v1` | Crafted init response returns invalid pointers   | Validate all interface headers before use             |
| Interface fn ptrs    | Tampered function pointers                       | Verify `size_bytes` covers expected fields; never call beyond declared size |
| `TgStr` / `TgSlice`  | Out-of-bounds `ptr` + `len` combinations         | Bounds-check every slice before dereference           |
| Event payloads       | Oversized or malformed event data                | Validate tag range and payload size before dispatch   |
| Asset data           | Crafted PNG/font triggering parser bugs          | Fail-safe decode; reject on any structural violation  |

### 1.2 Plugin Search Path Restriction

- **Default policy:** Only load backends from:
  1. Compile-time embedded paths (bundled backends).
  2. An explicit `TG_BACKEND_PATH` environment variable.
  3. The application's own binary directory.
- **Forbidden:** Current working directory, user home, temp directories.
- **Runtime override:** Only via explicit `LoaderConfig.search_order` with documented risk acknowledgment.
- **Symlink handling:** Resolve symlinks *before* path validation to prevent TOCTOU bypass.

### 1.3 ABI Boundary Misuse

- Function pointers received from plugins are never called if `size_bytes` check fails.
- The host never writes to plugin-owned memory.
- The plugin never frees host-allocated memory (and vice versa).
- All `extern "C"` functions use `repr(c)` types only — no language-specific types cross the boundary.

## 2. Input Validation — Fail-Safe Handling

### 2.1 Asset Validation

| Input Type   | Validation                                                      | Failure Mode             |
|-------------|----------------------------------------------------------------|--------------------------|
| PNG data     | Signature, IHDR bounds, CRC-32 per chunk, IDAT length          | `ImageError::CorruptData` |
| Font data    | Header magic, table checksums, glyph index bounds               | `TextError::FontLoadFailed` |
| Event payload | Tag in `[0, EVENT_TAG_MAX]`, payload length matches tag schema | Drop event; log warning   |
| Text input   | Valid UTF-8 or UTF-16; grapheme cluster bounds                  | Replace with U+FFFD       |
| Geometry     | Finite f32 (no NaN/Inf); non-negative dimensions               | Clamp or return error     |

### 2.2 Network/IPC Inputs

- No network inputs in v0.1 scope.
- IPC inputs (if any) follow the same `TgStr`/`TgSlice` validation as ABI boundary.

## 3. Integer Safety

### 3.1 Overflow Prevention

- All size/stride/buffer computations use checked arithmetic.
- Multiplication of dimensions (width × height × bytes_per_pixel) must be checked for overflow before allocation.
- Pattern:
  ```
  let total = checked_mul(width, height)?
  let bytes = checked_mul(total, bpp)?
  ```
- Any overflow returns a typed error, never wraps silently.

### 3.2 FFI Boundary Conversions

- `u64` → `usize` conversions are checked on 32-bit targets.
- `i64` → `u64` conversions are checked for negative values.
- `f32` → integer casts clamp to target range (no UB on out-of-range).
- All conversions have explicit error paths; no `as` casts in ABI-adjacent code without validation.

## 4. Bounds Checking

- Every `TgSlice` dereference validates `ptr != null && len <= MAX_SANE_LENGTH`.
- Every array index from plugin data is bounds-checked before access.
- Every `TgStr` is validated as UTF-8 (or rejected with `AbiError`).
- Stack depth limits are enforced for recursive operations (UI tree traversal, path tessellation).

## 5. Lifetime and Ownership Audit

### 5.1 Ownership Rules

| Resource          | Owner   | Transfer Boundary              | Rule                                |
|-------------------|---------|-------------------------------|-------------------------------------|
| `TgStr` data      | Caller  | Function call duration         | Callee must copy if retained        |
| `TgSlice` data    | Caller  | Function call duration         | Callee must copy if retained        |
| Interface structs | Host    | Entire backend session         | Plugin must not free                |
| Bitmap pixels     | Creator | Explicit ownership transfer    | `Bitmap.from_owned()` takes ownership |
| Path segments     | Path    | Lifetime of `Path` object      | Segments freed on `Path` drop       |
| Font handles      | `FontDb`| Lifetime of `FontDb` instance  | Freed on `FontDb` drop              |

### 5.2 Use-After-Free Prevention

- All handle-based APIs (opaque `u64` handles) validate handle liveness before dispatch.
- Handles are **generation-counted**: freed handle slots increment generation, stale handles are detected.
- Plugin shutdown invalidates all handles; any post-shutdown call returns `AbiError::SessionClosed`.

## 6. Denial-of-Service Resilience

| Vector                        | Limit                          | Response                               |
|-------------------------------|--------------------------------|----------------------------------------|
| Pathological PNG (zip bomb)   | Raw pixel limit: 64 MiB       | `ImageError::ResourceExhausted`        |
| Infinite loop in event stream | Frame timeout: 5 s             | Force `end_frame`; log error           |
| Deeply nested UI tree         | Max depth: 256 levels          | Reject insertion; return error         |
| Rapidly spawned windows       | Max windows: 64                | `AppError::ResourceExhausted`          |
| Oversized text layout         | Max chars per layout: 1 M      | `TextError::ResourceExhausted`         |
| Oversized path                | Max segments: 100 000          | `GfxError::ResourceExhausted`          |

## 7. Capability Gate Verification

All capability-gated operations are verified by the following contract:

1. **Before any side-effect call**, the capability token is checked.
2. Missing capability → typed error (`PlatformError::Unsupported`, `GpuError::Unsupported`).
3. Capabilities are **immutable** after session init — they cannot be escalated at runtime.
4. Capability checks are centralized in the host dispatcher, not scattered in business logic.

**Verified subsystems:**
- Clipboard: requires `Cap::Clipboard`
- IME: requires `Cap::Ime`
- DragDrop: requires `Cap::DragDrop`
- GPU: requires `Cap::Gpu`

## 8. Clipboard/IME/DragDrop Security

- **Clipboard:** Content-type whitelist (`text/plain`, `image/png`). Maximum payload size: 16 MiB. Content is sanitized (no embedded null bytes in text).
- **IME:** Composition strings are length-bounded. Invalid sequences replaced with U+FFFD.
- **DragDrop:** File URIs are resolved and normalized. Symlinks resolved before access. Path traversal (`../`) is rejected.

## 9. Panic/Abort Path Analysis

### 9.1 Policy

- **No panic/abort path may be reachable from untrusted input.**
- All public API functions return `Result` types for fallible operations.
- Internal `assert` / `debug_assert` are only used for invariants that are logically impossible given correct host code (not for input validation).

### 9.2 Audit Checklist

| Module         | Panic-Free Status | Notes                                    |
|----------------|-------------------|------------------------------------------|
| `gfx_errors`   | ✅ Yes            | All error constructors are infallible    |
| `geom`         | ✅ Yes            | NaN/Inf handled by clamping              |
| `app`          | ✅ Yes            | Event dispatch returns Result            |
| `gfx`          | ✅ Yes            | Canvas ops return Result                 |
| `image`        | ✅ Yes            | All decode paths return ImageError       |
| `text`         | ✅ Yes            | All layout paths return TextError        |
| `ui_toolkit`   | ✅ Yes            | Widget trait methods return Result        |
| `gfx_gpu`      | ✅ Yes            | All paths return GpuError                |
| `platform`     | ✅ Yes            | All paths return PlatformError           |
| `backend_abi`  | ✅ Yes            | Validation functions return Result        |
| `anim`         | ✅ Yes            | `ease()` clamps input to [0,1]           |
| `compositor`   | ✅ Yes            | Layer ops return Result                  |
| `assets`       | ✅ Yes            | Load/cache ops return Result             |
| `accessibility`| ✅ Yes            | Tree emit returns Result                 |

## 10. Pointer/Handle Validity

- All opaque handles (`_opaque: u64`) are validated via a handle table before dispatch.
- A null or zero handle always returns `AbiError::InvalidHandle`.
- Handle validation is O(1) via indexed table + generation check.
- Invalid handles produce deterministic errors, never undefined behavior.
- After backend unload, all handles from that backend are invalidated and return `AbiError::SessionClosed`.
