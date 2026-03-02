# TG-GFX-UI-SPEC-001 v0.1 — Conformance Policy

**Document ID:** TG-GFX-UI-SPEC-001  
**Version:** 0.1  
**Status:** Normative  
**Date:** 2026-03-02  

## 1. Scope

This specification defines the normative requirements for the Tangerine Graphics &
UI stack v0.1 release. All modules, APIs, ABI surfaces, and backend plugin contracts
described herein are **binding** for any implementation claiming conformance.

## 2. Backend-Agnostic Semantics

Tangerine owns all API semantics. Backends are interchangeable implementations that
conform to the stable C ABI described in Section 14 of the master checklist.

- **Tangerine defines** types, enums, trait signatures, error codes, capability
  requirements, threading rules, and determinism guarantees.
- **Backends implement** the specified interfaces via exported C ABI symbol tables.
- **Behavior** for identical inputs MUST be consistent across all conforming backends,
  within declared tolerance bounds (≤ 1 LSB per sRGB channel for raster output).

## 3. Target Application Classes

The v0.1 stack MUST support the following application classes:

| Class | Description | Example |
|-------|-------------|---------|
| **Simple desktop apps** | Single-window, standard controls, minimal GPU | Calculator, preferences panel |
| **Modern UI apps** | Multi-window, rich text, images, animation, accessibility | Code editors, design tools |
| **Browser shells** | Chrome/toolbar UI hosting an embedded web view | Tangerine-based browser frame |

## 4. Explicit Exclusions

- A full browser engine (HTML/CSS/JS rendering) is **explicitly out of scope** for v0.1.
- The stack architecture MUST be designed so that a future release can host an
  embedded browser engine within a `tg::ui` widget without breaking API contracts.

## 5. Normative Keyword Definitions

Per RFC 2119:

| Keyword | Meaning |
|---------|---------|
| **MUST / MUST NOT** | Absolute requirement or prohibition. Non-conformance is a spec violation. |
| **SHOULD / SHOULD NOT** | Recommended behavior. Deviation requires documented justification. |
| **MAY** | Truly optional. Implementations may include or omit without justification. |

## 6. Terminology

| Term | Definition |
|------|-----------|
| **Host** | The Tangerine runtime/toolchain that loads and manages backend plugins. |
| **Plugin** | A dynamic or static backend library providing interface tables via stable C ABI. |
| **Capability** | An opaque token gating access to side-effecting operations (display, clipboard, etc.). |
| **Surface** | A render target bound to a window or offscreen buffer. |
| **Canvas** | A stateful drawing context obtained from a Surface for issuing draw commands. |

## 7. Evidence Requirements

Every checklist item MUST have an associated implementation evidence link before it
can be marked complete. Acceptable evidence types:

- Source file path and line range
- Test file path demonstrating the behavior
- Build/CI artifact reference
- Architecture decision record (ADR) reference

## 8. Waiver Policy

Any exception to a normative requirement MUST include:

- **Owner**: Person responsible for the waiver
- **Reason**: Technical justification
- **Risk**: Impact assessment
- **Expiry date**: When the waiver must be resolved
- **Rollback plan**: How to achieve conformance if the waiver expires

## 9. Conformance Tiers

### Tier A — Core GUI (Minimum Viable)

Required modules: `tg-app`, `tg-geom`, `tg-gfx`, `tg-text`, `tg-ui`.

A Tier A implementation provides windowing, 2D drawing, text rendering, and a
basic retained-mode widget toolkit. This is the minimum tier for any conforming
Tangerine graphics application.

### Tier B — Modern UI

Required modules: Tier A + `tg-image`, `tg-anim`, `tg-compositor`, `tg-assets`,
`tg-accessibility`, `tg-clipboard`, `tg-ime`, `tg-dragdrop`.

A Tier B implementation adds image codecs, animation, compositing with damage
tracking, asset management, accessibility tree emission, and platform integration
(clipboard, IME, drag-and-drop).

### Tier C — GPU / Pro

Required modules: Tier B + `tg-gfx-gpu`.

A Tier C implementation exposes explicit GPU resource management for applications
requiring direct control over buffers, textures, shaders, and render pipelines.

### Backend ABI Conformance Minimum

Every backend plugin MUST:

1. Export `tg_backend_init_v1` with the exact signature defined in §14.4.
2. Provide at minimum the following interface tables via `query_interface`:
   - `tg.app.v1` (windowing + events)
   - `tg.gfx.v1` (2D drawing)
   - `tg.text.v1` (font + shaping)
3. Return `TgResult { ok: false, ... }` for any unsupported optional interface.
