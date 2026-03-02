# Platform-Specific Quality Matrix — TG-GFX-UI-SPEC-001 v0.1

> Normative reference for §26 of the graphics/UI development checklist.

## 1. Platform Behavior Matrix

| Feature                | macOS                         | Linux (X11/Wayland)            | Windows                       |
|------------------------|-------------------------------|-------------------------------|-------------------------------|
| **Windowing**          | NSWindow / AppKit             | X11 or Wayland compositor      | HWND / Win32                  |
| **DPI model**          | Backing scale factor (float)  | Xrandr scale or Wayland output | Per-monitor DPI awareness (v2)|
| **DPI change trigger** | Window moved across displays  | Output scale change event      | WM_DPICHANGED message         |
| **IME**               | NSTextInputClient             | IBus / Fcitx / Wayland IME     | TSF / IMM32                   |
| **Clipboard**          | NSPasteboard                  | X11 selections / wl_data_offer | OLE clipboard                 |
| **Drag-and-drop**      | NSDraggingDestination         | XDnD / wl_data_device          | OLE IDropTarget               |
| **Scroll model**       | Momentum (trackpad) / discrete| Smooth or discrete             | WM_MOUSEWHEEL (discrete/smooth)|
| **Font fallback**      | Core Text cascade list        | Fontconfig + FreeType           | DirectWrite fallback chain     |

## 2. High-DPI Scaling Transitions

### 2.1 Runtime Behavior

- On display change, the backend receives a scale-factor-changed event.
- The host must re-request surface dimensions in physical pixels.
- All cached rasterized content (glyph cache, compositor layers) must be invalidated.
- The UI tree must re-layout at the new scale.

### 2.2 Validation Criteria

| Test Case                              | Expected Behavior                            |
|----------------------------------------|----------------------------------------------|
| Move window from 1× to 2× display     | Surface resized; UI re-rendered at 2×        |
| Move window from 2× to 1× display     | Surface resized; no blurry downscale         |
| Change system DPI while app is running | Scale event dispatched; full re-layout       |
| Fractional scale (1.25×, 1.5×)        | Correct rounding; no pixel gaps              |

## 3. Input Differences

### 3.1 Scroll Modes

| Input Device     | Platform  | Event Type          | Handling                         |
|------------------|-----------|---------------------|----------------------------------|
| Trackpad         | macOS     | Momentum scroll     | Smooth, inertial; report phase   |
| Mouse wheel      | macOS     | Discrete scroll     | Fixed delta per notch            |
| Trackpad         | Linux     | Smooth scroll       | Depends on compositor support    |
| Mouse wheel      | Linux     | Discrete scroll     | Fixed delta per notch            |
| Precision wheel  | Windows   | Smooth scroll       | High-resolution WM_MOUSEWHEEL    |
| Standard wheel   | Windows   | Discrete scroll     | 120-unit clicks                  |

### 3.2 Validation

- Scroll events must report consistent units regardless of input device.
- Backend must normalize device-specific deltas to a common scroll unit.
- Momentum (inertial) scrolling generates `ScrollPhase` begin/update/end events.

## 4. IME Composition

### 4.1 Cross-Platform IME Behavior

| Phase         | macOS (NSTextInputClient)      | Linux (IBus/Fcitx)              | Windows (TSF)                  |
|---------------|-------------------------------|---------------------------------|-------------------------------|
| Start         | `markedText` begins           | `preedit_start`                 | `ITfComposition::Start`        |
| Update        | `setMarkedText` with range    | `preedit_changed`               | `ITfRange` update             |
| Commit        | `insertText`                  | `commit_text`                   | `ITfComposition::End`          |
| Cancel        | `unmarkText`                  | `preedit_end` with no commit    | `ITfComposition::End` (empty)  |

### 4.2 Validation Criteria

- Composition string displayed inline at cursor position.
- Candidate window positioned relative to composition start.
- Commit replaces composition range (not appended).
- Cancel restores pre-composition state exactly.

## 5. Drag-and-Drop Path Normalization

### 5.1 File URI Handling

| Platform | Raw Format                    | Normalized Format               |
|----------|------------------------------|---------------------------------|
| macOS    | `file:///Users/...`          | `/Users/...`                    |
| Linux    | `file:///home/...`           | `/home/...`                     |
| Windows  | `file:///C:/...` or `C:\...` | `C:/...` (forward slashes)      |

### 5.2 Security Rules

- Path traversal (`../`) sequences are rejected.
- Symlinks are resolved before path validation.
- Null bytes in path strings are rejected.
- Maximum path length: 4096 bytes.

## 6. Font Fallback/Resolution

### 6.1 Platform Differences

| Platform | Primary Engine | Fallback Mechanism          | Known Differences                |
|----------|---------------|----------------------------|----------------------------------|
| macOS    | Core Text     | System cascade list        | Broader emoji coverage by default|
| Linux    | FreeType      | Fontconfig pattern match   | Depends on installed fonts       |
| Windows  | DirectWrite   | System fallback chain      | CJK fallback varies by edition   |

### 6.2 Validation

- Same text content must produce valid glyph runs on all platforms (no `.notdef` / tofu).
- Font fallback results may differ visually but must cover all codepoints.
- Missing-glyph detection must use `TextError::GlyphNotFound` for unreachable codepoints.
