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

## D. tg_compiler Scan Failures (stage0 compilation errors)

These are errors reported by `stage0_rs scan tg_compiler`. Each prevents stage0
from compiling the corresponding tg_compiler module. After D1–D3 fixes, 21 files
still fail out of 34. Root causes below.

### D1. Parse Errors

- [ ] **`extern def` inside function body not supported by parser**
  - `tg_compiler/object.tg:1745` — `extern def time(tloc: *mut Int) -> Int` declared inside `generate_pdb_guid()` body; parser reports "expected statement separator or branch terminator"
  - **Proper fix:** Move the `extern def time(...)` declaration to module-level scope, outside the function body.

- [ ] **Semicolons in match arms confuse parser**
  - `tg_compiler/bindgen.tg:1518` — `when CToken::LBrace then depth = depth + 1; self.advance()` uses semicolons as statement separators inside `when` arms; parser reports "expected KeywordEnd, found Semi"
  - **Proper fix:** Replace semicolons with newlines as statement separators in match arms, putting each statement on its own line.

### D2. Real Type and Logic Errors

These are genuine bugs that would fail under any correct type checker.

- [ ] **`parts.push(input)` passes ContractValue where String expected**
  - `tg_compiler/agentic.tg:1367` — `input` iterates over `t.inputs` (typed `ContractValue`), but `parts` is `Vec[String]`
  - **Proper fix:** Change `parts.push(input)` to `parts.push(input.to_string())`.

- [ ] **`lower_stmt` returns MirOperand instead of declared Unit**
  - `tg_compiler/mir.tg:1300` — function signature is `-> Unit`, but the `StmtKind::StmtExpr` match arm calls `lower_expr(b, &expr, stmt.span)` whose MirOperand return becomes the arm's value
  - **Proper fix:** Add `()` after the `lower_expr()` call in the `StmtKind::StmtExpr` arm to discard the return value.

- [ ] **Assignment to immutable variable `utility`**
  - `tg_compiler/symbol_graph.tg:498` — `let utility = 0.0` followed by `utility = utility + need.weight` inside a loop
  - **Proper fix:** Change to `mut utility = 0.0`.

- [ ] **`pop_scope` returns Option instead of declared Unit**
  - `tg_compiler/types.tg:428` — function signature is `-> Unit` but body is `env.scopes.pop()` which returns `Option[Map[String,Type]]`
  - **Proper fix:** Discard the pop result: change to `let _ = env.scopes.pop()` or add a trailing `()`.

### D3. Stage0 Sema / Parser Improvements Required

These 20 errors all stem from stage0_rs resolving types as Unit where real types
exist. The fixes belong in `stage0_rs/src/sema/mod.rs` and `stage0_rs/src/parser/mod.rs`,
**not** in the .tg source files.

#### D3a. Populate cross-module environment during multi-module scan

When `stage0_rs scan tg_compiler` processes each module, `env.functions` and
`env.structs` only contain the current file's declarations. Functions and structs
from sibling modules are missing, so calls/field-access on them resolve as Unit.

- [ ] **Pre-load all project function signatures into `env.functions`**
  - `stage0_rs/src/sema/mod.rs:2869,2877` — bare and module-qualified function calls fall back to `unresolved_external_type` when not found in `env.functions`
  - Surfaces as: `driver.tg:1043` (`expand_item()` return → Unit), `cross_compile.tg:294` (`supported_targets()` chain → Unit)
  - **Proper fix:** In the `scan` driver, do a two-pass approach: first pass collects all `pub def` signatures from every module into a shared `ProjectEnv`; second pass runs sema per-file with those signatures pre-populated in `env.functions`.

- [ ] **Pre-load all project struct/enum definitions into `env.structs`**
  - `stage0_rs/src/sema/mod.rs:6535` — `type_of_field_from_type` returns `Unit` when struct definition not loaded
  - `stage0_rs/src/sema/mod.rs:6553` — field access on Unit cascades: all subsequent `.field` accesses also return Unit
  - Surfaces as: `refactor.tg:152` (`symbol.def_span.file` → Unit), `template.tg:311` (`entry.path` → Unit), `linter.tg:241` (Map iteration entry fields → Unit)
  - **Proper fix:** First pass collects all `pub struct` / `pub enum` definitions. Second pass runs sema with those definitions in `env.structs` so chained field access resolves correctly.

#### D3b. Propagate generic type_args for Map/Vec

When `Map` or `Vec` variables have empty `type_args` (no generic parameters
propagated from declarations), intrinsic method signatures use Unit as the
key/value/element type.

- [ ] **Infer Vec/Map type_args from let-binding and struct field declarations**
  - `stage0_rs/src/sema/mod.rs:4783` — `Vec` with empty `type_args` passes `Unit` to `vec_intrinsic_method_sig`
  - `stage0_rs/src/sema/mod.rs:4793` — `Map` with empty `type_args` passes `Unit`/`Unit` to `map_intrinsic_method_sig`
  - Surfaces as: `borrow_check.tg:597` (Map.get_mut → push expects Unit), `cap_baseline.tg:231` (attr.args iteration → Unit), `codegen.tg:1697` (Map.get → Unit), `coverage.tg:182` (Vec::new element → Unit), `docgen.tg:466` (Vec::new element → Unit), `lib.tg:561` (Map.get match → Unit), `linker.tg:96` (Map.get match → Unit), `resolver.tg:585` (Map.get_mut → Unit), `trait_resolve.tg:508` (Vec element → Unit)
  - **Proper fix:** In `type_of_method_call` (line 3181), when `base_ty` is `Vec`/`Map` with empty `type_args`, look up the variable's declared type in `locals` or `env.structs` (for struct fields) to retrieve the populated type_args. Thread these through to the intrinsic sig builders.

#### D3c. Add missing intrinsic method signatures

Some standard methods are missing from the intrinsic method tables, causing
the Named-type fallback to return Unit.

- [ ] **Add `sorted_by` to `vec_intrinsic_method_sig`**
  - `stage0_rs/src/sema/mod.rs:5095` — `sorted_by` not listed; falls through `_ => None` to Named fallback (line 410) returning Unit
  - Surfaces as: `cqs.tg:767` (`sorted_by().len()` → Unit)
  - **Proper fix:** Add `"sorted_by"` entry near the existing `"sort_by"` entry. Unlike `sort_by` (returns Unit, in-place), `sorted_by` returns `base_ty.clone()` (new sorted collection).

- [ ] **Add `as_str` to String/Named type intrinsic methods**
  - `stage0_rs/src/sema/mod.rs:410` — `.as_str()` on Named types hits the fallback returning Unit
  - Surfaces as: `formatter.tg:412` (`clause.ty.as_str()` → Unit)
  - **Proper fix:** Add `"as_str"` to the intrinsic method table for String/Named types, returning `&str`.

- [ ] **Add `is_empty` return type for all collection/container types**
  - `stage0_rs/src/sema/mod.rs:410` — `.is_empty()` on struct fields not tracked through Named fallback
  - Surfaces as: `mode.tg:595` (`func.contracts.is_empty()` → Unit in `&&`)
  - **Proper fix:** In `check_method_call` for Named types, recognize `.is_empty()` as always returning `Bool` (like `.len()` returns `Int`).

- [ ] **Add `find` to iterator intrinsic methods**
  - `stage0_rs/src/sema/mod.rs:410` — `.find()` on iterator falls through to Unit return
  - Surfaces as: `registry.tg:176` (`.iter().find()` → `&Unit`)
  - **Proper fix:** Add `"find"` to `vec_intrinsic_method_sig` returning `Option[Ref[item_ty]]`.

#### D3d. Track tuple element types through Map iteration

- [ ] **Propagate Map type_args to iteration tuple elements**
  - `stage0_rs/src/sema/mod.rs:6883` — `iterable_item_type` for Map with empty `type_args` creates tuple with `unresolved_external_type` elements
  - Surfaces as: `linter.tg:241` (`entry.value.1` tuple field → Unit), `pkg_manager.tg:99` (enumerate destructuring → Unit)
  - **Proper fix:** Same root cause as D3b — once Map type_args are properly propagated, `iterable_item_type` will produce correct `Tuple[K, V]` elements. For enumerate, ensure `vec_intrinsic_method_sig` for `"enumerate"` (line 5042) also propagates the correct `item_ty` from the resolved Vec element type.

#### D3e. Implement `matches!()` macro desugaring in parser

- [ ] **Add `matches!()` macro support to stage0 parser**
  - `stage0_rs/src/parser/mod.rs:1524` — only `vec!` is recognized as a macro; `matches!` is parsed as identifier + `!` (logical NOT)
  - Surfaces as: `wasm_target.tg:324` (`matches!(&func.ret_type, Type::Unit | Type::Never)` → `!` on non-boolean)
  - **Proper fix:** Add `try_parse_matches_macro_expr` alongside `try_parse_vec_macro_expr`. Desugar `matches!(expr, pat1 | pat2 | ...)` into `match expr { when pat1 then true when pat2 then true when _ then false end }`.

### D4. Positional matching of named-field enum variants

When an enum variant is defined with named fields (`{ field: Type, … }`) but the
match pattern uses positional syntax (`(a, b, c)`), `bind_pattern` enters the
named-field path (because `variant.named_fields` is non-empty), finds zero
matches in the pattern's `named_fields` map (which is empty since positional
syntax was used), and returns without binding anything. The positional elements
in `pattern.fields` are silently ignored. Every downstream use of the would-be
bindings resolves as Unit.

`stage0_rs/src/sema/mod.rs` — `bind_pattern`, circa line 6084:

```rust
if !variant.named_fields.is_empty() {
    // iterates declared fields, matches by NAME in pattern.named_fields
    // → pattern.named_fields is empty → nothing bound
    return Ok(scoped);           // ← early return
}
// positional path never reached
```

- [ ] **Fall through to positional matching when pattern uses positional fields for a named-field variant**
  - When `variant.named_fields.is_empty()` is false AND `pattern.named_fields` is empty AND `pattern.fields` is non-empty, zip `pattern.fields` with `variant.named_fields` (in declaration order) and bind each pattern element to the corresponding declared field type.
  - Surfaces as:
    - `codegen.tg:1697` — `MirTerminatorKind::MirSwitchInt(discr, targets, default_target)` where `MirSwitchInt` is defined with `{ op: MirOperand, targets: Vec[SwitchTarget], default_target: BlockId }`. Bindings `discr`, `targets`, `default_target` all resolve as Unit. Error: method argument type mismatch: expected `&Int`, found Unit (from `sw.target.id` on Unit `sw`).
    - `lib.tg:617` — `MirTerminatorKind::MirCall(dest, _callee, _args, success_block, _unwind)` where `MirCall` has named fields `{ dest: Place, func: MirOperand, args: Vec[MirOperand], success: BlockId, unwind: Option[BlockId] }`. Error: method argument type mismatch: expected Int, found Unit.
    - `linker.tg:1576` — `MirTerminatorKind::MirCall(dest, func_op, args, ...)`, same enum variant. Error: argument type mismatch for `extract_operand_local`: expected `&MirOperand`, found `&Unit`.

### D5. Ambiguous raw name "ItemKind" blocks enum lookup

`ItemKind` is defined in **two** tg_compiler modules:
- `tg_compiler/ast.tg:77` — the real AST enum (`ItemFunction(FunctionDecl)`, etc.)
- `tg_compiler/symbol_graph.tg:467` — a summary enum (all unit variants)

Phase 2 of `analyze_directory` only merges raw (non-qualified) names when the
count is exactly 1. Since `ItemKind` appears in 2 files, the raw name is NOT
merged into `shared_env`. Only qualified keys `ast::ItemKind` and
`symbol_graph::ItemKind` exist. When `bind_pattern` looks up `"ItemKind"` in
`env.enums`, `canonical_map_key` tries `fallback_map_key` which finds both
qualified keys → ambiguous → returns `None`. The "Enum definition not loaded"
fallback triggers, binding all variant payload fields as Unit.

- [ ] **Disambiguate ambiguous raw enum names by variant match**
  - In `bind_pattern`'s Variant handler, when the enum_key lookup fails AND the pattern specifies a variant name (e.g., `Function`), iterate all enum definitions in `env.enums` whose suffix matches (e.g., `ast::ItemKind`, `symbol_graph::ItemKind`) and pick the one that contains a variant matching the requested name (using `enum_variant_matches`). `ast::ItemKind` has `ItemFunction` which matches `Function`; `symbol_graph::ItemKind` does not.
  - Alternatively: in Phase 2, when a raw name is ambiguous, prefer the definition with the most variants or the one with payload fields, since summary enums are typically simpler.
  - Surfaces as:
    - `mode.tg:595` — `when ItemKind::Function(func) then` → `func` is Unit → `func.contracts.is_empty()` returns Unit → `Bool && Unit` → error: logical operators require Bool operands.
    - `driver.tg:1043` — `when ItemKind::ImplBlock(impl_block) then` → `impl_block` is Unit → `impl_block.methods` is Unit → iteration yields Unit elements → `expand_item(env, method)` gives `method: Unit` when `Item` expected.

### D6. Missing intrinsic methods in sema tables

Several standard methods are absent from the intrinsic method signature tables,
causing the Named-type/Unknown fallback to return Unit.

- [ ] **Add `expect` to `option_intrinsic_method_sig`**
  - `stage0_rs/src/sema/mod.rs` — `option_intrinsic_method_sig` (circa line 5690) has `unwrap`, `unwrap_or`, `is_some`, `is_none`, `map`, `as_ref`, `clone`, `to_string` — but NOT `expect`.
  - `expect(&str) -> T` is functionally identical to `unwrap()` (returns `item_ty.clone()`) but accepts an error message argument.
  - Surfaces as: `resolver.tg:585` — `module.submodules.get_mut(&segment).expect("module not found")` → return type is Unit instead of `&mut ModuleSymbols` → assignment type mismatch.

- [ ] **Add `entries` to `map_intrinsic_method_sig`**
  - `stage0_rs/src/sema/mod.rs` — `map_intrinsic_method_sig` (circa line 5200) has `iter`, `insert`, `get`, `get_mut`, `remove`, `contains_key`, `keys`, `values`, `len`, `is_empty` — but NOT `entries`.
  - `entries()` returns an iterable of `(key_ty, value_ty)` tuples, same as `iter()`. Return type: `base_ty.clone()`.
  - Surfaces as: `trait_resolve.tg:508` — `by_trait.entries()` on `Map[String, Vec[UInt]]` → returns Unit → `indices` iterates as Unit → `indices[i]` index type is Unit → error: index type must be Int, found Unit.

- [ ] **Add `entries` to `vec_intrinsic_method_sig`**
  - Tangerine code uses `.entries()` on Vec of tuples as an alias for `.iter()`.
  - Return type: `base_ty.clone()`.
  - Surfaces as: `mir.tg:1865` — `fields.entries()` on `Vec[(String, Pattern)]` → returns Unit → iterating yields Unit → `entry.1` is Unit → `&field_pattern` is `&Unit` → error: expected `&Pattern`, found `&Unit`.

- [ ] **Add `enumerate` to `array_intrinsic_method_sig`**
  - `stage0_rs/src/sema/mod.rs` — `array_intrinsic_method_sig` (circa line 5605) has `clone`, `iter`, `len`, `is_empty`, `push`, `remove`, `map`, `filter`, `fold` — but NOT `enumerate`. It IS present in `vec_intrinsic_method_sig`.
  - Return type: `Vec[Tuple[Int, item_ty]]`.
  - Surfaces as: `pkg_manager.tg:99` — `path.iter().enumerate()` where `path: Array[String]` → `iter()` returns `Array[String]` → `enumerate()` not found → falls through to Named fallback → Unit → `segment` destructured as Unit → error: expected `&String`, found Unit.

- [ ] **Add `find` to `array_intrinsic_method_sig`**
  - `find` is in `vec_intrinsic_method_sig` but NOT in `array_intrinsic_method_sig`.
  - Return type: `Option[Ref[item_ty]]`.
  - Surfaces as: `registry.tg:176` — `entries.iter().find(|e| ...).ok_or(...)` where `entries: Array[RegistryEntry]` → `find` → Unit → `ok_or` on Unit → Unit → `?` → Unit → error: expected `&RegistryEntry`, found `&Unit`.

### D7. Or-pattern span-sensitive equality

`TypeRef` derives `Eq`/`PartialEq` including the `Span` field. When
`bind_pattern` checks or-pattern alternatives with `scope != first_scope`,
identical types at different source positions compare as unequal, producing
a false-positive "must bind the same names with the same types" error.

- [ ] **Use `same_type_shape` instead of `!=` for or-pattern scope comparison**
  - `stage0_rs/src/sema/mod.rs` — `bind_pattern` Or handler (circa line 5999): change `if scope != first_scope` to a comparison that ignores Span differences. Iterate scope1/scope2, compare values with `same_type_shape()`.
  - Surfaces as: `wasm_target.tg:461` — `MirRvalueKind::Ref(place) | MirRvalueKind::RefMut(place)` → `place` bound as `Unit{span=A}` vs `Unit{span=B}` (both Unit because MirRvalueKind has named fields — see D4). Once D4 is fixed, the actual types (`Place`) should be equal, but Spans will still differ → false positive without this fix.

### D8. Vec/Map/Array::new() forward-inference gaps

The forward-inference system (`infer_binding_type_from_future_stmts`) handles
many patterns: `.push()`, `.insert()`, argument-position inference from function
calls, etc. But some patterns are still missed, leaving container `type_args`
empty → element types resolve as Unit.

Common gaps:
1. The variable is passed to a **function via `&mut` reference** and the inference
   doesn't propagate the parameter type back (e.g., `collect_declarations(&block, &mut declared)` where the parameter is `Map[String, (Span, Bool)]`).
2. The container is populated inside **nested control flow** (if/match inside
   for-loop) and the inference depth limit triggers.
3. The first use is a **struct field assignment** or **return position** whose
   expected type isn't propagated back.

- [ ] **Improve `infer_type_from_arg_position` for `&mut` references**
  - When a variable with unparameterized container type is passed as `&mut T` to a function, unwrap the `&mut` to recover the inner parameter type `T` and use it to refine the variable's container type_args.
  - Surfaces as:
    - `linter.tg:241` — `mut declared = Map::new()` → passed to `collect_declarations(…, &mut declared)` which expects `&mut Map[String, (Span, Bool)]` → Map type_args should be `[String, (Span, Bool)]`.
    - `borrow_check.tg:597` — `mut by_file = Map::new()` → `by_file.get_mut(...)` and later `by_file.insert(...)` → value type is `Vec[&UnsafeUsage]`.

- [ ] **Refine container type from return-position struct fields**
  - When a let binding is used as a field value in a struct literal that is returned, propagate the struct field's declared type back to the variable.
  - Surfaces as:
    - `coverage.tg:182` — `let records = Vec::new()` → later `Result::Ok(CoverageArtifact { records: records })` where `CoverageArtifact.records: Vec[CoverageRecord]`.
    - `bindgen.tg:1210` — `mut params = Array::new()` → later `Result::Ok((params, false))` with return type `Result[(Array[(String, CType)], Bool), String]`.
    - `cqs.tg:1761` — `mut actions = Vec::new()` → returned by function with expected return type containing `Vec[SuggestedAction]`.
    - `docgen.tg:466` — `mut lines = Vec::new()` → later `lines.push(content)` where `content: String`.

### D9. Cross-module / cross-package struct field access gaps

When the sema encounters field access on a type whose struct definition is not
loaded into `env.structs`, it returns Unit. This covers two distinct sub-problems:

#### D9a. `std/` types not loaded during `tg_compiler/` scan

`template.tg` calls `fs::read_dir(…)` which returns `Vec[DirEntry]`. `DirEntry`
is defined in `std/fs.tg:832` with fields `name`, `path`, `is_file`, `is_dir`.
During `stage0_rs scan tg_compiler`, `std/` files are not analyzed, so `DirEntry`
is not in `env.structs` → field access returns Unit.

- [ ] **Load `std/*.tg` struct/enum definitions into the shared environment**
  - In `analyze_directory` (driver.rs), when the scan target is a directory,
    also parse `std/*.tg` and collect their struct/enum definitions into
    `shared_env` before Phase 3 analysis.
  - This is the same mechanism already used for cross-module sharing within
    the target directory — just extended to include `std/`.
  - Surfaces as: `template.tg:311` — `entry.path` → Unit. `entry` is `DirEntry`
    from `std/fs.tg:832`.

#### D9b. Missing struct definition: `ResolvedSymbol` (genuine .tg source bug)

`refactor.tg:12` imports `use tg_compiler::resolver::{ResolvedSymbol, ScopeMap, Binding}`
but **none** of these three types are defined in `resolver.tg`. The struct
`ResolvedSymbol` is used throughout `refactor.tg` with fields `id`, `name`,
`is_extern`, `def_span`. Similarly, `ScopeMap` is used with method
`scopes_containing(id)`.

- [ ] **Add missing struct definitions to `resolver.tg`**
  - Add `struct ResolvedSymbol` with fields: `id: Int`, `name: String`,
    `is_extern: Bool`, `def_span: Span`.
  - Add `struct ScopeMap` with field: `scopes: Vec[Scope]` (and associated
    `Scope` type / `scopes_containing` method).
  - Add `struct Binding` (placeholder with relevant fields).
  - These are genuine missing definitions, not a compiler limitation.
  - Surfaces as: `refactor.tg:152` — `symbol.def_span.file` → Unit.

### D10. Genuine .tg source bugs (remaining)

- [ ] **`check_pattern` declares `-> Unit` but returns `Bool` from `unify()` calls**
  - `tg_compiler/types.tg:1492` — function signature: `def check_pattern(env: &mut TypeEnv, pat: &Pattern, expected: Type) -> Unit`. Multiple match arms end with `unify(env, lit_type, expected, pat.span)` which returns `Bool`. The function's declared return type is `Unit` but the actual tail expression is `Bool`.
  - **Proper fix:** Discard the `unify()` return values by appending `()` after each `unify(…)` call, OR change return type to `Bool`.

- [ ] **`func.attrs` accessed on `FunctionDecl` which has no `attrs` field**
  - `tg_compiler/cap_baseline.tg:231` — `for attr in func.attrs do` where `func: &FunctionDecl`. The `FunctionDecl` struct (defined in `ast.tg:110`) does NOT have an `attrs` field — `attrs` is a field on `Item` (defined in `ast.tg:72`). So `func.attrs` → Unit → iterating Unit → Unit elements → `attr.args` → Unit → `arg.clone()` → Unit → push expects String, found Unit.
  - **Proper fix (tg):** Change the function signature to accept `&Item` (which has both `.kind` for the function body and `.attrs` for annotations), or pass attrs as a separate parameter.

---

## E. Remaining scan failures (18 → 0)

After applying sections A–D, the scan sat at 18 failures. Two forward-inference
bugs in `sema/mod.rs` (error-propagation abort + tail-expression scope blinding)
were fixed, dropping the count to 15. This section covers the remaining 15
failures, grouped by root cause.

### E1. Forward-inference: expression stmts not refining empty containers

`extend_inference_scope_from_stmt` only handles `Stmt::Let`. Expression
statements such as `list.push(usage)` — which refine an empty `Vec` into
`Vec[&UnsafeUsage]` — are ignored, so when the variable is later used as an
argument to another call (e.g. `by_file.insert(key, list)`), the type is still
`Vec[]` and the containing Map value type stays Unit.

- [x] **Handle `Stmt::Expr` containing method calls on empty containers**
  - `stage0_rs/src/sema/mod.rs` — `extend_inference_scope_from_stmt` (line 2166):
    add an `Expr::Call` arm for expression stmts. When the callee is
    `<local>.method(args)` and the local has an empty container type in
    `scoped_locals`, call `refine_empty_container_type` exactly as the forward
    inference does and update `scoped_locals` with the refined type.
  - Surfaces as: `borrow_check.tg:605` — `by_file = Map::new()` → value type
    stays `Vec[]` because `list.push(usage)` inside a match arm doesn't refine
    `list` in scoped locals → downstream `entry.value` iteration yields Unit.

### E2. Forward-inference: `.entry(k).or_insert(v)` chain unrecognised

`refine_empty_container_type` recognises `Map.insert` but NOT the idiomatic
`.entry(key).or_insert(default)` pattern. The chained call is never matched by
the forward-inference because the callee is
`Field { base: Call { … "entry" … }, field: "or_insert" }`, not a simple
`Name.method`.

- [x] **Recognise `target.entry(k).or_insert(v)` in `infer_local_type_from_call_expr`**
  - When the outer callee is `<something>.or_insert(default)` and that
    `<something>` is a Call whose own callee is `target.entry(key)`, refine the
    target Map from empty type_args to `Map[key_ty, value_ty]`.
  - Surfaces as: `cqs.tg:2046` — `module_reports = Map::new()` populated only
    via `.entry(sym.module_path).or_insert(Vec::new())` → stays `Map[]` → tuple
    destructuring in for-loop yields Unit.

### E3. `Map::get_mut` returns immutable reference

`map_intrinsic_method_sig` returns `Option[&V]` for both `get` and `get_mut`.
The `get_mut` arm must set `mutable: true` in the Ref wrapper.

- [x] **Set `mutable: true` for `get_mut` return type**
  - `stage0_rs/src/sema/mod.rs` — `map_intrinsic_method_sig`, the `"get" | "get_mut"`
    arm: split into two cases, one for `get` (mutable=false) and one for
    `get_mut` (mutable=true).
  - Surfaces as: `resolver.tg:638` — `module.submodules.get_mut(&segment).expect(…)`
    returns `&ModuleSymbols` instead of `&mut ModuleSymbols` → type mismatch
    against declared `-> &mut ModuleSymbols`.

### E4. `char::from_u32()` static method not recognised

`lookup_associated_function` searches `env.impls` for an `impl char` block.
There is none, so the call returns Unit.

- [x] **Add primitive static method fallback in `lookup_associated_function`**
  - After the impl search fails, add a match on `(type_name, method_name)`:
    `("char", "from_u32")` → returns `Option[Char]`.
    `("Int", "from_str_radix")` → returns `Result[Int, String]`.
  - Surfaces as: `pkg_manager.tg:236` — `char::from_u32(cp as u32).unwrap_or('?')`
    → `from_u32` returns Unit → `.unwrap_or` on Unit → Unit → push expects Char.

### E5. `Span` struct missing `file` field

`token.tg` defines `Span` with only `start: Int` and `end_pos: Int`. Multiple
tg_compiler files access `span.file` (e.g. `symbol.def_span.file`). Field
access on the wrong struct returns Unit.

- [x] **Add `file: String` to `Span` in `tg_compiler/token.tg`**
  - Surfaces as: `refactor.tg:152` — `symbol.def_span.file` → Unit → expected
    String.

### E6. `_skip_int_keyword` match arm returns `&CToken` instead of Unit

`self.advance()` returns `&CToken`. The `when _ then ()` arm returns Unit. The
match unifies to `&CToken` (Non-Unit takes precedence). The function has no
declared return type (implicit Unit) → mismatch.

- [x] **Discard `self.advance()` result in `tg_compiler/bindgen.tg`**
  - Change `when CToken::KwInt then self.advance()` to
    `when CToken::KwInt then self.advance(); ()`.
  - Surfaces as: `bindgen.tg:1441` — expected Unit, found `&CToken`.

### E7. Wrong pattern for `FnBody` match in `cap_baseline.tg`

`FunctionDecl.body` is `FnBody` (not `Option[FnBody]`). The pattern
`when Option::Some(FnBody::FnBlock(block)) then` wraps in `Option::Some` when
the match value is already `FnBody` — the Option pattern short-circuits and
`block` binds as Unit.

- [x] **Match directly against `FnBody` variant**
  - Change `when Option::Some(FnBody::FnBlock(block)) then` to
    `when FnBody::FnBlock(block) then`.
  - Surfaces as: `cap_baseline.tg:269` — expected Block, found Unit.

### E8. Undefined function `target_triple` in `codegen.tg`

`target_triple(arch, os)` is called but never defined. The correct function is
`asm_target(arch: Arch, os: OsAbi) -> AsmTarget` in `tg_compiler/asm.tg`.

- [x] **Replace `target_triple(arch, os)` with `asm_target(arch, os)`**
  - `tg_compiler/codegen.tg` — line containing `target_triple(arch, os)`.
  - Surfaces as: `codegen.tg:2202` — return type resolves to Unit instead of
    AsmTarget.

### E9. `ItemKind::ImplBlock` / `ImplBlock` literal mismatch in `driver.tg`

The AST defines `ItemKind::ItemImpl(ImplDecl)`. The driver.tg code uses variant
name `ImplBlock` and struct name `ImplBlock`. The scanner's semi-fuzzy variant
matching strips prefix `"Item"` from `"ItemKind"`, but `"ImplBlock"` still
doesn't match `"ItemImpl"` → falls back to first variant → field access gives
Unit.

- [x] **Fix variant + struct names in `tg_compiler/driver.tg`**
  - `ItemKind::ImplBlock(impl_block)` → `ItemKind::ItemImpl(impl_block)`
  - `ImplBlock { … }` struct literal → `ImplDecl { … }`
  - `ItemKind::ImplBlock(new_impl)` → `ItemKind::ItemImpl(new_impl)`
  - Surfaces as: `driver.tg:1043` — `impl_block.methods` → Unit.

### E10. Logical NOT `!` used for bitwise NOT in `lib.tg`

The scanner correctly returns `Bool` for `!Int` (logical NOT). The code intends
bitwise NOT (`~`). Match arm types become `[Int, Int, Bool]` → unification fails
→ match returns Unit.

- [x] **Change `!v.data` to `~v.data` in `tg_compiler/lib.tg`**
  - Line `when MirUnOp::BitNot then !v.data` → `when MirUnOp::BitNot then ~v.data`.
  - Surfaces as: `lib.tg:682` — match resolves to Unit → downstream operations
    on Unit.

### E11. Undefined function `read_file_string` in `mir.tg`

`read_file_string(path)` is called but not defined in `std/`. The correct
function is `read_file(path: String) -> Result[String, IOError]` in `std/fs.tg`.

- [x] **Replace `read_file_string` with `read_file`**
  - `tg_compiler/mir.tg` — line 5475.
  - Surfaces as: `mir.tg:5477` — `Result::Ok(content)` extracts `content: Unit`
    → expected String, found Unit.

### E12. Incorrect `Projection` variant names in `wasm_target.tg`

The enum `Projection` in `mir.tg` defines variants `ProjDeref`, `ProjField`,
`ProjIndex`. The code uses shortened names `Deref`, `Field`, `Index`. The
scanner's semi-fuzzy prefix stripping from "Projection" does NOT produce prefix
"Proj" (it strips suffix "ion" → prefix "Project", not "Proj"), so the patterns
fail → bindings resolve as Unit.

- [x] **Use correct variant names in `tg_compiler/wasm_target.tg`**
  - `Projection::Field(idx, _)` → `Projection::ProjField(idx, _)`
  - `Projection::Deref` → `Projection::ProjDeref`
  - `Projection::Index(idx_local)` → `Projection::ProjIndex(idx_local)`
  - Surfaces as: `wasm_target.tg:488` — `*idx > 0` where `idx` is Unit →
    expected Bool, found Unit.

---

## Summary

| Area | Critical | High | Medium | Total |
|------|----------|------|--------|-------|
| **A. stage0_rs** (sema + codegen) | 5 | 8 | 3 | **16** |
| **B. tg_compiler** | 3 | 6 | 9 | **18** |
| **C. std/** | 3 | 4 | 11+ | **18+** |
| **D. tg_compiler scan failures** | 4 | 8 | 12 | **24** |
| **Intrinsics needed** | — | — | — | **120+** |
| **@cfg gates to evaluate** | — | — | — | **90** |
| **Total items** | **15** | **26** | **35+** | **76+ checklist items** |

### D section breakdown

| Sub-section | Items | Fixes 21 remaining failures? |
|-------------|-------|-----|
| D1. Parse errors | 2 | ✅ done |
| D2. Real type/logic errors | 4 | ✅ done |
| D3. Sema/parser improvements | 9 | ✅ done (5 files fixed) |
| D4. Named-field variant positional matching | 1 | codegen, lib, linker |
| D5. Ambiguous "ItemKind" | 1 | mode, driver |
| D6. Missing intrinsic methods | 5 | resolver, trait_resolve, mir, pkg_manager, registry |
| D7. Or-pattern span equality | 1 | wasm_target |
| D8. Forward-inference gaps | 2 | linter, borrow_check, coverage, bindgen, cqs, docgen |
| D9a. Load std/ types | 1 | template |
| D9b. Missing ResolvedSymbol (tg bug) | 1 | refactor |
| D10. Genuine .tg bugs | 2 | types, cap_baseline |

