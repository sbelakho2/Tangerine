# Tangerine Self-Hosting Gap Report

> Status: **stage0 bootstrap compiler → fully self-hosted compiler**
>
> Every item below is a workaround, stub, or accommodation made in **stage0_rs**,
> **tg_compiler**, or **std/** to cope with the limited bootstrap compiler.
> Each must be resolved for a proper self-hosted Tangerine compiler.

---

## A. stage0_rs Workarounds (Rust bootstrap compiler)

These are shortcuts in the Rust-based bootstrap that the self-hosted compiler must
not inherit — they must be replaced with correct implementations.

### A1. Semantic Analysis Shortcuts

- [ ] **Supertrait method resolution not implemented**
  - `stage0_rs/src/sema/mod.rs:283` — returns fallback signature instead of chasing supertraits
  - **Proper fix:** Recursively walk the supertrait chain to resolve methods inherited from parent traits.

- [ ] **External method fallback signature (zero params, Unit return)**
  - `stage0_rs/src/sema/mod.rs:5642` — `external_method_fallback_sig()` returns a dummy `FunctionSig` with no params and Unit return for every method on an unknown external type
  - `stage0_rs/src/sema/mod.rs:269,274,284,289,360` — called pervasively throughout method resolution
  - **Proper fix:** Fully resolve external module types and look up real method signatures. Reject calls to truly unknown methods.

- [ ] **Module-qualified function calls get stub signatures**
  - `stage0_rs/src/sema/mod.rs:2763` — calls like `parser::parse()` get a zero-param Unit-return stub; arity checking skipped
  - `stage0_rs/src/sema/mod.rs:2805` — when sig has 0 params (external fallback), arity validation bypassed
  - **Proper fix:** Load and resolve the actual function signatures from the target module.

- [ ] **Unit acts as wildcard type for unresolved externals**
  - `stage0_rs/src/sema/mod.rs:6920-6935` — `is_unresolved_unit()` / `is_externally_typed()` treat Unit as "maybe anything"
  - `stage0_rs/src/sema/mod.rs:6940-6942` — `is_type_compatible()` accepts Unit on either side as compatible with all types
  - **Proper fix:** Track truly-unresolved types distinctly from Unit. Never silently accept type mismatches.

- [ ] **Cast validation completely skipped**
  - `stage0_rs/src/sema/mod.rs:1239-1242` — all casts accepted; source type discarded (`let _ = source_ty`)
  - **Proper fix:** Verify cast legality (numeric↔numeric, pointer↔pointer, enum repr casts, etc.).

- [ ] **Trait implementation verification deferred**
  - `stage0_rs/src/sema/mod.rs:7054-7055` — `Named` ↔ `dyn Trait` always accepted without checking impl blocks
  - **Proper fix:** Verify that the concrete type actually implements the trait (check impl blocks, method signatures, associated types).

- [ ] **Named→String coercion blindly accepted**
  - `stage0_rs/src/sema/mod.rs:7002` — any Named type is "compatible" with String
  - **Proper fix:** Only accept if the type implements `Display` or `ToString`.

- [ ] **Mutability enforcement deferred**
  - `stage0_rs/src/sema/mod.rs:1701-1704` — assignment to immutable variables not rejected (warning only, no enforcement)
  - `stage0_rs/src/sema/mod.rs:1767-1771` — field/index assignment mutability checking skipped
  - **Proper fix:** Full mutability tracking through `self` parameters, nested field paths, and index expressions. Reject violations.

- [ ] **Pattern type checking is a no-op**
  - `stage0_rs/src/sema/mod.rs:6686-6690` — `expect_pattern_type()` discards both actual and expected types, always succeeds
  - **Proper fix:** Structurally compare pattern types against the matched expression type. Reject mismatches.

- [ ] **Forward type reference always accepted**
  - `stage0_rs/src/sema/mod.rs:1816` — bare names not found in scope accepted as "may be a forward reference to another compilation unit"
  - **Proper fix:** Resolve forward references within the same compilation unit; reject truly undefined types.

- [ ] **Forward type inference limited to unresolved generics**
  - `stage0_rs/src/sema/mod.rs:2032-2034` — only infers types for generic containers (e.g., `Vec` from `Vec::new()`), not concrete types
  - **Proper fix:** Full bidirectional type inference for all expression contexts.

- [ ] **Generic placeholder pairs bypass type checking**
  - `stage0_rs/src/sema/mod.rs:1363,1386` — `is_generic_placeholder_pair()` accepts certain type pairs without real checking
  - **Proper fix:** Full generic type unification and constraint solving.

- [ ] **Collection element type defaults to Unit**
  - `stage0_rs/src/sema/mod.rs:4645` — when element types can't be inferred, Unit used as placeholder
  - **Proper fix:** Proper generic type inference for collection elements.

### A2. Code Generation Shortcuts

- [ ] **External module support functions emit `unimplemented!()`**
  - `stage0_rs/src/codegen/mod.rs:636,657` — `emit_support_function()` generates Rust stubs with `unimplemented!()` bodies
  - **Proper fix:** Generate proper bridge code or link to real implementations.

- [ ] **Nested declaration lowering not implemented**
  - `stage0_rs/src/codegen/mod.rs:1181` — nested declarations beyond functions/variables cause an error
  - `stage0_rs/src/sema/mod.rs:779` — matching error in semantic analysis
  - **Proper fix:** Support all nested declaration kinds (structs, enums, traits, type aliases inside functions).

### A3. `@cfg` Attribute Evaluation Not Implemented

- [ ] **stage0 does not evaluate `@cfg()` gates at all**
  - 86 `@cfg` annotations in `std/*.tg`, 4 in `tg_compiler/*.tg` — none are evaluated by the bootstrap compiler
  - Forces monolithic platform-agnostic code paths instead of proper platform-specific compilation
  - **Proper fix:** Implement `@cfg` / conditional compilation in the front-end, gating items and expressions based on target triple, feature flags, etc.

---

## B. tg_compiler Workarounds (Self-hosted compiler)

These are code in the self-hosted compiler itself that was written to work within
stage0's limitations, or is deliberately incomplete.

### B1. Critical: Disabled Optimization Passes

- [ ] **SSA conversion disabled (pointer-aliasing bug)**
  - `tg_compiler/mir.tg:6590-6592` — SSA rename pass has bugs where shared `LocalId` objects cause one rename to corrupt unrelated `Place`s
  - **Proper fix:** Fix the pointer-aliasing / identity-sharing bug in the SSA rename pass. Ensure `LocalId` values are value-copied, not aliased.

- [ ] **Copy propagation disabled (depends on SSA)**
  - `tg_compiler/mir.tg:3746-3749` — commented out `propagate_copies(f)` because without SSA, copies of multiply-defined variables corrupt across basic blocks
  - **Proper fix:** Fix SSA first, then re-enable copy propagation.

### B2. Critical: Borrow Checker Skips Advanced Passes

- [ ] **NLL / escape analysis / drop-order verification skipped**
  - `tg_compiler/borrow_check.tg:2100-2101` — `borrow_check()` calls only `check_program()` (core checks), never calls `run_advanced_analysis()`
  - `run_advanced_analysis()` (line 2106+) is fully implemented: CFG-based NLL, lifetime constraints, drop order verification, use-after-drop detection
  - **Proper fix:** Enable the `run_advanced_analysis()` call path. Run NLL liveness, lifetime constraint checking, drop-order verification, and use-after-drop detection on every function.

### B3. Critical: Stub Implementations

- [ ] **Test runner is a no-op**
  - `tg_compiler/driver.tg:1684-1686` — `cmd_test()` always returns 0 with no test execution
  - **Proper fix:** Implement full test discovery, compilation, and execution pipeline.

- [ ] **Bench command not supported**
  - `tg_compiler/driver.tg:1962-1963` — "bench is not yet supported in the stage0 self-hosted driver" — cannot bind parsed benchmark functions to runtime closures
  - **Proper fix:** Implement runtime closure binding for benchmark harness.

- [ ] **`bootstrap_copy_self_binary()` is dead code**
  - `tg_compiler/driver.tg:1610-1612` — was a bootstrap workaround, now returns `false`
  - **Proper fix:** Remove entirely.

- [ ] **`current_time()` always returns 0**
  - `tg_compiler/driver.tg:2206-2208` — used for incremental compilation timestamps
  - **Proper fix:** Call a time intrinsic or `std::time` to get actual wall-clock time.

- [ ] **`bootstrap_call_system()` uses unsafe FFI**
  - `tg_compiler/driver.tg:2210-2211` — raw `system()` call via unsafe FFI
  - **Proper fix:** Use `std::process::Command` equivalent with proper error handling.

### B4. Simplified Implementations

- [ ] **SHA-256 is actually FNV-1a hash (not cryptographic)**
  - `tg_compiler/util.tg:60-67` — `sha256()` uses 4 FNV-1a rounds with different seeds; produces 256 bits but is NOT cryptographically secure
  - **Proper fix:** Implement real SHA-256 (or call `std::crypto::sha256`).

- [ ] **JSON serialization is manual string concatenation**
  - `tg_compiler/driver.tg:512` — `emit_all_diagnostics_json()` builds JSON by hand with string concat (no escaping of special chars)
  - **Proper fix:** Use a proper JSON serializer that handles escaping.

- [ ] **Register allocator is linear-scan only**
  - `tg_compiler/codegen.tg:257` — "linear-scan style, simplified" — falls back to scratch register when out of regs instead of spilling
  - **Proper fix:** Implement graph-coloring or at minimum proper spill/reload with live range splitting.

- [ ] **Type::Named size defaults to 8 bytes**
  - `tg_compiler/codegen.tg:128-129` — `type_size()` for `Type::Named` always returns 8 (pointer-size fallback)
  - **Proper fix:** Look up actual struct layout and compute real size.

- [ ] **WASM codegen emits nop for all instructions**
  - `tg_compiler/wasm_target.tg:346-351` — `emit_instruction()` pushes 0x01 (nop) for every MIR instruction
  - **Proper fix:** Implement full MIR→WASM instruction lowering.

- [ ] **Package manager TOML parsing is line-by-line string matching**
  - `tg_compiler/pkg_manager.tg` — simplified line-based TOML parser; no proper TOML spec support
  - **Proper fix:** Implement or use a real TOML parser.

- [ ] **Package manager download/extract is no-op**
  - `tg_compiler/pkg_manager.tg` — dependency fetching just creates directories without downloading or verifying
  - **Proper fix:** Implement actual HTTP download, checksum verification, extraction.

- [ ] **FFI bindgen uses simple line-by-line C header parsing**
  - `tg_compiler/bindgen.tg:189` — naïve C header parser
  - `tg_compiler/bindgen.tg:477` — `@export` detection uses string pattern matching
  - **Proper fix:** Integrate libclang or a proper C parser for reliable FFI generation.

- [ ] **Rationale block parser has compatibility fallback**
  - `tg_compiler/parser.tg:1943` — "Compatibility mode" consumes key/value blocks as raw string until `end`
  - **Proper fix:** Parse rationale blocks with proper structure (title, author, tags, structured body).

- [ ] **Macro expansion incomplete**
  - `tg_compiler/driver.tg:1106` — "Leave ordinary calls unchanged in stage0" — non-macro function calls are not expanded
  - **Proper fix:** Full macro resolution including procedural macros and attribute macros.

- [ ] **Captured variables in closures use Unit placeholder**
  - `tg_compiler/mir.tg:1541` — "Captured variable not found — use Unit placeholder"
  - **Proper fix:** Properly resolve captured variables from enclosing scope during MIR lowering.

- [ ] **MIR local type uses placeholder**
  - `tg_compiler/mir.tg:1252` — "return a placeholder - the actual type should come from the MirLocal"
  - **Proper fix:** Resolve actual types from MirLocal definitions.

---

## C. std/ Workarounds (Standard Library)

### C1. Critical: Exception Handling Non-Functional

- [ ] **`set_panic_hook()` is a no-op**
  - `std/core.tg:277-280` — hook assignment commented out; body is just `()`

- [ ] **`take_panic_hook()` always returns None**
  - `std/core.tg:282-286` — hook retrieval and reset commented out

- [ ] **`catch_unwind()` never actually catches panics**
  - `std/core.tg:307-338` — catch-frame push/pop entirely commented out; relies on `try_invoke()` which just calls the function directly

- [ ] **`try_invoke()` is pass-through (no exception catching)**
  - `std/core.tg:345-348` — simply calls `f()` and wraps in `Option::Some`; no setjmp/longjmp; panics propagate uncaught

- [ ] **`begin_unwind()` is incomplete**
  - `std/core.tg:351+` — catch-frame walking and panic payload storage commented out

- [ ] **Thread-local storage not available**
  - `std/core.tg:269,302-303` — `_panic_hook`, `_catch_frame_stack`, `_current_panic` all commented out because `@thread_local` / `thread_local` semantics are not implemented
  - **Proper fix for all above:** Implement `@thread_local` storage, `setjmp`/`longjmp` intrinsics or platform landing pads, and uncomment the catch-frame logic.

### C2. Critical: Cryptographic Placeholders

- [ ] **Ed25519 scalar multiplication uses hash-based placeholder**
  - `std/crypto.tg:2881` — `_sc_muladd()` returns a SHA-512 hash instead of doing real modular arithmetic
  - **Proper fix:** Implement proper 256-bit modular arithmetic for Ed25519.

### C3. Hardcoded / Insecure Values

- [ ] **WebSocket key is hardcoded**
  - `std/http.tg:2143-2144` — `Sec-WebSocket-Key` is always `"dGhlIHNhbXBsZSBub25jZQ=="` (the RFC example nonce)
  - **Proper fix:** Generate 16 random bytes and base64-encode for each connection.

- [ ] **WebSocket frame mask is hardcoded**
  - `std/http.tg:2229` — mask bytes are `[0x12, 0x34, 0x56, 0x78]` instead of random
  - **Proper fix:** Use `std::random` to generate mask per frame.

### C4. Simplified / Incomplete Implementations

- [ ] **DWARF line-number parsing is simplified (v4 only, partial)**
  - `std/backtrace.tg:300` — "simplified line number state machine (DWARF v4)"
  - **Proper fix:** Implement full DWARF v4/v5 line program decoding.

- [ ] **PNG decoder handles only 8-bit RGB/RGBA stored blocks**
  - `std/image.tg:91-220` — no interlacing, no 16-bit, no palette, no filtering, no compressed blocks
  - **Proper fix:** Implement full PNG spec (zlib decompression, filter reconstruction, all color types).

- [ ] **Image file I/O always errors**
  - `std/image.tg:196` — `load_file()` returns error; file capability not wired
  - **Proper fix:** Wire up `FsCap` file reading.

- [ ] **Software rendering only for App**
  - `std/app.tg:242` — "minimal software-rendered App for testing and fallback"
  - **Proper fix:** Add GPU-accelerated rendering backend.

- [ ] **Device detection returns mock hardware**
  - `std/device.tg:70` — returns hardcoded mock GPU/accelerator info
  - **Proper fix:** Query actual hardware via platform APIs.

- [ ] **Accessibility implementation incomplete**
  - `std/accessibility.tg:67` — partial implementation without platform integration
  - **Proper fix:** Integrate with platform accessibility APIs (AT-SPI on Linux, NSAccessibility on macOS, UIA on Windows).

- [ ] **Bidirectional text is simplified**
  - `std/i18n.tg:44` — "simplified bidirectional text"
  - **Proper fix:** Implement full Unicode Bidirectional Algorithm (UAX #9).

- [ ] **Process data transfer uses byte copying**
  - `std/process.tg:840` — byte-at-a-time data transfer
  - **Proper fix:** Use `splice`/`sendfile` for zero-copy I/O.

- [ ] **Temp file creation has race condition**
  - `std/fs.tg:705` — timestamp-based temp file names
  - **Proper fix:** Use `O_EXCL` atomic open with retry loop.

- [ ] **Random shuffle is partial**
  - `std/random.tg:150` — incomplete Fisher-Yates implementation
  - **Proper fix:** Complete Fisher-Yates shuffle over the entire array.

- [ ] **JSON Unicode limited to BMP**
  - `std/json.tg:1048` — only Basic Multilingual Plane codepoints
  - **Proper fix:** Support full Unicode (surrogate pairs, supplementary planes).

- [ ] **Animation uses simplified reference values**
  - `std/anim.tg:59` — "simplified for reference impl"
  - **Proper fix:** Use actual current values from the animation target.

### C5. Intrinsics Not Implemented by stage0

The following `extern def __intrinsic_*` declarations require runtime support that
must be provided either by the compiler's codegen or by a runtime library:

- [ ] **I/O intrinsics** (`std/io.tg:56-59`) — `__intrinsic_stdin`, `__intrinsic_stdout`, `__intrinsic_stderr`, `__intrinsic_read_line`
- [ ] **Environment intrinsics** (`std/env.tg:10-18`) — 9 functions: args, env_var, set_var, current_dir, remove_var, vars, home_dir, temp_dir, exe_path
- [ ] **Collection intrinsics** (`std/collections.tg:28-61`) — 29 functions: Array, Map, Set operations (new, push, pop, get, remove, insert, clear, slice, extend, etc.)
- [ ] **Unicode intrinsics** (`std/unicode.tg`) — 16 functions: codepoint classification, case mapping, normalization
- [ ] **SIMD intrinsics** (`std/simd.tg`) — 57 functions: Float32x4, Int32x4, Float64x2, Float32x8 operations, matrix ops, CPU feature detection
- [ ] **Core intrinsics** (`std/core.tg`) — 3 functions: `__intrinsic_type_name`, `__intrinsic_size_of`, `__intrinsic_align_of`
- [ ] **Signal intrinsic** (`std/signal.tg`) — 1 function
- [ ] **Locale intrinsic** (`std/locale.tg`) — 1 function
- [ ] **Asset intrinsics** (`std/assets.tg:94-102`) — `__intrinsic_assets_load_image`, `__intrinsic_assets_load_font`
- [ ] **Benchmark intrinsic** (`std/bench.tg:786`) — `__compiler_intrinsic_black_box`
- [ ] **Audit intrinsics** (`std/audit.tg:141-157`) — symbol scanning, capability drift, stub pattern detection, symbol location

### C6. Platform-Specific Code Not Compiled Correctly

Due to missing `@cfg` evaluation (see A3), these modules ship all platform variants
simultaneously instead of selecting the correct one:

- [ ] `std/debug.tg` — 30+ `@cfg` gates for macOS/Linux/x86_64/aarch64
- [ ] `std/embedded.tg` — 60+ `@cfg` gates for ARM/aarch64/riscv32/riscv64
- [ ] `std/net.tg` — 40+ `@cfg` gates for Linux/macOS socket definitions
- [ ] `std/gpu.tg` — 15+ `@cfg` gates for Metal/D3D12/Vulkan/WebGPU
- [ ] `std/profile.tg` — 20+ `@cfg` gates for Linux/macOS/Windows profiling
- [ ] `std/path.tg` — 5+ `@cfg` gates for Windows/Unix path separation
- [ ] `std/thread.tg` — monolithic `PthreadT` struct instead of platform-specific

---

## Summary

| Area | Critical | High | Medium | Total |
|------|----------|------|--------|-------|
| **A. stage0_rs** (sema + codegen) | 5 | 8 | 3 | **16** |
| **B. tg_compiler** | 3 | 6 | 9 | **18** |
| **C. std/** | 3 | 4 | 11+ | **18+** |
| **Intrinsics needed** | — | — | — | **120+** |
| **@cfg gates to evaluate** | — | — | — | **90** |
| **Total items** | **11** | **18** | **23+** | **52+ checklist items** |

