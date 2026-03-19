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

## F. Final 4 scan failures (30/34 → 34/34)

These are the last 4 source code bugs preventing a clean scan. All are genuine
.tg source errors — NOT scanner limitations.

### F1. `Dependency` struct missing fields used in `driver.tg`

`tg_compiler/driver.tg:2999` — `match dep.path` accesses a `path` field that
does not exist on `Dependency`. The struct (defined in `tg_compiler/pkg_manager.tg:521`)
has only: `name`, `requirement`, `registry`, `features`, `optional`, `dev_only`.

`resolve_single_dep` (line 2996) accesses three missing fields:
- `dep.path` (line 2999) — used to detect local path dependencies
- `dep.git` (line 3009) — used to detect git dependencies
- `dep.version` (line 3003) — used in `ResolvedPackage` literal, but the actual
  field is `requirement: Requirement`

The scanner error surfaces at line 3004: `hash_directory(p)` where `p` binds from
`Option::Some(ref p)` on the Unit result of `dep.path` → `p` is Unit →
`expected &String, found Unit`.

- [ ] **Add missing fields to `Dependency` in `tg_compiler/pkg_manager.tg:521`**
  - Add `pub path: Option[String]` — local path override for development
  - Add `pub git: Option[String]` — git repository URL
  - Add `pub version: String` — version string (or change `driver.tg:3003` to
    use `dep.requirement.to_string()`)
  - Also update any `Dependency { … }` struct literals in `pkg_manager.tg` to
    include the new fields (defaulting to `Option::None` / `""` as appropriate).

### F2. `.value` accessor on `String` element in `linter.tg`

`tg_compiler/linter.tg:903` — `attr.args[0].value.clone()` accesses `.value` on
a `String`. The `Attribute` struct (defined in `tg_compiler/ast.tg:61`) has
`args: Vec[String]`, so `attr.args[0]` is already a `String` — there is no
`.value` field.

`.value` on `String` resolves to Unit → `.clone()` → Unit → `ctx.push_allow(lint_name)`
expects `String`, found Unit.

Same pattern repeats at line 945 for `pop_allow`.

- [ ] **Remove `.value` accessor — index directly into `Vec[String]`**
  - Line 903: `attr.args[0].value.clone()` → `attr.args[0].clone()`
  - Line 945: `attr.args[0].value.clone()` → `attr.args[0].clone()`

### F3. `v.as_str()` returns `String`, not `Option[String]`

`tg_compiler/pkg_manager.tg:1123` — `_extract_toml_field` has return type
`Option[String]`. In the `when Option::Some(v) then v.as_str()` arm, `v.as_str()`
returns a bare `String`, which doesn't match the declared `Option[String]` return.

- [ ] **Wrap return value in `Option::Some`**
  - Line 1123: `when Option::Some(v) then v.as_str()`
    → `when Option::Some(v) then Option::Some(v.as_str())`

### F4. Iterating `Block` directly instead of `.stmts` in `refactor.tg`

`tg_compiler/refactor.tg:471` — `for s in &arm.body do` attempts to iterate a
`Block` value. The `MatchArm` struct (defined in `tg_compiler/ast.tg:565`) has
`body: Block`, and `Block` (line 490) has `stmts: Vec[Stmt]`. `Block` itself is
not iterable — must access `.stmts`.

Since `arm.body` is `Block` (not iterable), the scanner resolves the loop
variable `s` as Unit → `_check_cf_stmt(s, selection)` expects `&Stmt`, found Unit.

- [ ] **Access `.stmts` on the `Block` value**
  - Line 471: `for s in &arm.body do` → `for s in &arm.body.stmts do`

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

---

## G. Full End-to-End Compiler Blockers (Current Scan: 2026-03-15)

> **Build command:** `stage0_rs build-bin tg_compiler /tmp/tg_selfhost`
> **Result:** Fails immediately on `std/async.tg` parse error (std is parsed as part of the build).
>
> Before `build-bin` can succeed, **every** `std/*.tg` and `tg_compiler/*.tg` file
> must parse and pass semantic analysis. Current status:
>
> | Directory | Total | Pass | Fail (Parse) | Fail (Sema) |
> |-----------|-------|------|-------------|-------------|
> | `std/`  | 105 | 18 | 35 | 52 |
> | `tg_compiler/` | 34 | 29 | 0 | 5 |

### G1. Parser Gaps — 35 parse errors in `std/*.tg`

These are language constructs present in the Tangerine spec/std library that the
stage0 parser does not yet handle. Grouped by root cause.

#### G1a. Multi-parameter generics in expression context: `Type[A, B].method()` / `Type[A, B]::method()` (6 files)

**Files:** `std/auth.tg:55`, `std/config.tg:214`, `std/device.tg:109`, `std/io.tg:177`, `std/log.tg:747` (cascade from Map[String, SpanValue] at line 710), `std/thread.tg:1052`

**Error messages:** `expected RBracket, found Comma` / `expected statement separator`

**Example code:**
```
var obj = Map[String, json::Value].new()
mut b = Vec[u8]::new()
job_queue: Mutex[VecDeque[Box[dyn FnOnce()]]]
```

**Root cause:** In `parser/mod.rs` lines 1688-1693, the expression parser's generic-type-args
lookahead (`parse_optional_type_args`) only succeeds when followed by `LParen`. For
`Type[A, B].method()` or `Type[A, B]::method()`, the next token is `.` or `::`,
so the parser falls back to the index-expression path (line 1695) which does not
support commas — it parses one expression, then expects `]`.

Additionally, nested generics with bounds like `I: Iterator[T]` (collections.tg:657)
and `FnOnce()` inside brackets (thread.tg:1052) hit the same limitation since the
inner `[T]` or `(` after parsing the first type arg causes the same error.

**Proper fix:** In the expression postfix loop (lines 1688-1693), after
`parse_optional_type_args()` succeeds, also accept `.` and `::` as valid
continuations (not only `LParen`). Specifically:
1. After parsing type args, check for `LParen`, `Dot`, or `ColonColon`
2. If `.` or `::` follows, emit the expression as a `TypeQualified` call base
   (the type with its args) and continue the postfix loop
3. For the `Type[A, B]` case where it's a type in struct-field position (like
   thread.tg), the type parser (`parse_type` → `parse_optional_type_args`) already
   handles commas correctly; these errors cascade from earlier expression-context
   parsing failures

#### G1b. Match arm guards: `pattern if condition =>` (3 files)

**Files:** `std/opentelemetry.tg:375`, `std/validation.tg:160`, `std/wasm_js.tg:252`

**Error message:** `expected FatArrow, found KeywordIf`

**Example code:**
```
match parent
  Some(ctx) if ctx.trace_flags.is_sampled() =>
    SamplingResult { decision: SamplingDecision.RecordAndSample, ... }
```

**Root cause:** The `parse_match_arm` function expects `pattern => expr` or
`when pattern then expr`. It does not recognize an optional `if guard_expr`
between the pattern and `=>`.

**Proper fix:** In `parse_match_arm`, after parsing the pattern and before
expecting `FatArrow`, check for `KeywordIf`. If present, parse a guard
expression:
```rust
let guard = if self.match_kind(&TokenKind::KeywordIf) {
    Some(Box::new(self.parse_expr()?))
} else {
    None
};
```
Store the guard in the `MatchArm` AST node. Add a `guard: Option<Box<Expr>>`
field to `MatchArm` in `ast/expr.rs`. For codegen, emit `if guard { body } else { continue_matching }`.

#### G1c. `@attribute(...)` syntax on declarations and in expressions (3 files)

**Files:** `std/linalg.tg:326`, `std/mmap.tg:338`, `std/simd.tg:140`

**Error messages:** `expected function keyword, found At` / `unexpected expression token: At`

**Example code:**
```
@inline(always)
def to_simd(self) -> f32x4

const MAP_ANONYMOUS: i32 = @cfg(target_os = "linux") { 0x20 } @cfg(target_os = "macos") { 0x1000 }

@inline_asm("x86_64", "cpuid", in("eax") = leaf, ...)
```

**Root cause:** The parser does not handle `@` as a prefix for attributes.
In declaration context, `@attr` should be consumed before `def`/`fn`/`const`/etc.
In expression context, `@cfg(...)` should be parsed as a conditional compilation expression.

**Proper fix:**
1. In `parse_decl()`, before checking for `KeywordDef`/`KeywordFn` etc., check
   for `At` token. If found, consume `@ident(args)` as an attribute annotation,
   then continue parsing the modified declaration. Store attributes as a
   `Vec<Attribute>` on each `Decl` variant.
2. In `parse_expr()`, recognize `@cfg(...)` as a expression-level
   conditional compilation macro.
3. In `parse_expr()`, recognize `@inline_asm(...)` as an intrinsic call expression.

#### G1d. `unsafe "reason" do ... end` blocks (2 files)

**Files:** `std/async.tg:314`, `std/process.tg:179` (cascade)

**Error message:** `expected statement separator or branch terminator`

**Example code:**
```
unsafe "dereference executor pointer" do
  let exec = &mut *self.executor
  exec.wake_task(self.task_id)
end
```

**Root cause:** The parser handles `unsafe do ... end` but when a string literal
follows `unsafe`, it doesn't recognize it as a safety-reason annotation and fails.
The parser sees `unsafe`, then the string literal is not `do`, so it tries to
parse an unsafe expression — the string is consumed as an expr, then the
rest (`do ... end`) is orphaned.

**Proper fix:** In the `KeywordUnsafe` handler in `parse_expr()`, after matching
`unsafe`, optionally consume a `TokenKind::Str(...)` (the reason string), then
continue looking for `do`. Store the reason as `Option<String>` in the
`UnsafeBlock` AST node.

#### G1e. Turbofish syntax `::<Type>` in expressions (2 files)

**Files:** `std/http.tg:291`, `std/web.tg:87`

**Error messages:** `unexpected pattern token: ColonColon` / `expected identifier, found Lt`

**Example code:**
```
match kv[1].parse::<Int>()
match Json::parse::<T>(&body)
```

**Root cause:** When the parser encounters `::` in expression context, it expects
an identifier to follow (for path resolution like `Mod::func`). The turbofish
syntax uses `::` followed by `<Type>` with angle brackets, which the parser does
not recognize.

**Proper fix:** In the expression postfix loop, when `ColonColon` is encountered
followed by `Lt`, parse a turbofish type argument list:
1. Consume `::`
2. Consume `<`
3. Parse comma-separated types until `>`
4. Continue parsing the call `(args)`
Store turbofish type args as `type_args: Vec<TypeRef>` on `Expr::Call` or
`Expr::MethodCall`.

#### G1f. `struct` inside `extern "C"` blocks (1 file)

**Files:** `std/cli.tg:902`

**Error message:** `expected function keyword, found KeywordStruct`

**Example code:**
```
extern "C"
  struct Winsize
    ws_row: u16
    ws_col: u16
    ws_xpixel: u16
    ws_ypixel: u16
  end
  def ioctl(fd: Int, request: UInt, arg: &mut Winsize) -> Int
end
```

**Root cause:** The extern block parser only accepts `def`/`fn` declarations.
FFI headers commonly contain struct definitions alongside function declarations.

**Proper fix:** In `parse_extern_block_body()`, alongside the function case, add
a `KeywordStruct` case that calls `parse_struct_decl()` and stores the struct in
the extern block's items. Add a `structs: Vec<StructDecl>` field to
`ExternBlockDecl` in `ast/decl.rs`.

#### G1g. `const` declarations at module level / inside impl blocks (1 file)

**Files:** `std/gfx_gpu.tg:380`

**Error message:** `expected function keyword, found KeywordConst`

**Example code:**
```
const VK_SUCCESS: i32 = 0
const VK_NOT_READY: i32 = 1
```

**Root cause:** These `const` declarations appear after an `extern "C"` block ends,
at module level. The parser's `parse_decl()` should already handle `KeywordConst`,
but if they appear inside an impl block or the const is preceded by something
that confuses the parser context, the error surfaces.

**Proper fix:** Verify that `parse_decl()` correctly dispatches `KeywordConst` at
module level. If these `const` declarations appear inside an `impl` block body,
extend `parse_impl_members()` to accept `const` items alongside `def`/`fn`.
Add `consts: Vec<ConstDecl>` to the impl AST node.

#### G1h. Tuple patterns `(val, val)` in match arms (1 file)

**Files:** `std/float_control.tg:103`

**Error message:** `unexpected pattern token: FatArrow`

**Example code:**
```
match (ftz, daz)
  (false, false) => DenormalMode.Preserve
  (true, false)  => DenormalMode.FlushToZero
```

**Root cause:** The pattern parser does not recognize `(` as a valid pattern-start
token for tuple destructuring. It fails to parse `(false, false)` as a pattern.

**Proper fix:** In `parse_pattern()`, add a `TokenKind::LParen` case. Parse
comma-separated sub-patterns until `)`. Produce a `Pattern::Tuple { elements }` node.
Add this variant to the Pattern enum in `ast/expr.rs`.

#### G1i. Postfix `.await` (1 file)

**Files:** `std/web_ext.tg:171`

**Error message:** `expected statement separator or branch terminator`

**Example code:**
```
next(ctx).await
```

**Root cause:** The expression postfix loop handles `.field` and `.method()` but
does not recognize `.await` as a special postfix operator.

**Proper fix:** In the expression postfix loop's `Dot` handler, after consuming
`.`, check if the next token is `KeywordAwait`. If so, wrap the expression in
an `Expr::Await { inner }` node. Add `Await { inner: Box<Expr>, span: Span }`
to the Expr enum.

#### G1j. `pre` precondition clauses (1 file)

**Files:** `std/random.tg:91`

**Error message:** `expected statement separator or branch terminator`

**Example code:**
```
def next_int_below(self, bound: Int) -> Int
  pre bound > 0, "bound must be positive"
  ...
```

**Root cause:** The `pre` keyword is already a known keyword token (`KeywordPre`),
but the function body parser does not recognize it as a precondition clause at
the start of a function body.

**Proper fix:** In `parse_function_body()` (or wherever the block body starts),
before parsing statements, check for `KeywordPre`. If found, parse
`pre <expr>, <string>` as a contract clause. Store contracts as
`Vec<Contract>` on `FunctionDecl`. For runtime, emit `assert!(condition, message)`.

#### G1k. Struct literal without braces (1 file)

**Files:** `std/ui.tg:39`

**Error message:** `expected statement separator or branch terminator`

**Example code:**
```
def rgba(r: u8, g: u8, b: u8, a: u8) -> Color
  Color
  r: r, g: g, b: b, a: a
end
```

**Root cause:** The parser sees `Color` as a standalone name expression, expects
a statement terminator, then `r: r, ...` on the next line is orphaned.

**Proper fix:** This is whitespace-sensitive struct literal syntax. In the
expression parser, when a `Name` expression is followed by a newline and then
`ident:` pattern (field initializer), parse it as a struct literal. Alternatively,
this could be treated as a source-level style issue — require `Color { r: r, ... }`
with braces. Check the language spec for which syntax is canonical. If braces are
required, fix the source file. If braceless is valid, extend the parser.

#### G1l. Struct literal with braces `{ }` in expression context (1 file)

**Files:** `std/ffi.tg:683`

**Error message:** `expected RParen, found LBrace`

**Example code:**
```
if is_null(&Ptr[u8] { address: err.address }) then
```

**Root cause:** The parser sees `Ptr[u8]` as a type/expr, but when `{` follows
inside a function argument list, it's ambiguous — is `{` a block start or a
struct literal start? The expression parser doesn't recognise `Type { fields }`
as a struct literal in non-statement position.

**Proper fix:** In the expression parser, when a `Name` (potentially with type
args) is followed by `{`, parse it as a struct literal expression:
`Type { field: value, ... }`. This requires careful disambiguation with block
expressions, but since `Name {` is unambiguous (blocks don't start with a type
name), this is safe.

#### G1m. `impl Trait for &Type` reference types (1 file)

**Files:** `std/db.tg:106`

**Error message:** `impl target must be a concrete named type`

**Example code:**
```
impl ToSqlParam for &str
```

**Root cause:** `parse_impl_decl()` expects the `for` type to be a simple named
type. Reference types (`&Type`) are rejected.

**Proper fix:** In `parse_impl_decl()`, after `for`, call `parse_type()` instead
of only accepting an identifier. Allow `&Type`, `&mut Type`, and other compound
types as impl targets. The parsed type goes into `impl_decl.for_type: TypeRef`.

#### G1n. Never type `!` (1 file)

**Files:** `std/embedded.tg:41`

**Error message:** `unexpected type token: Bang`

**Example code:**
```
pub type PanicHandler = def(info: &PanicInfo) -> !
```

**Root cause:** `parse_type()` does not handle `Bang` (`!`) as a valid type token.
The never/diverging type is used in function types that never return.

**Proper fix:** In `parse_type()`, add a case for `TokenKind::Bang`:
```rust
TokenKind::Bang => Ok(TypeRef::Named {
    name: "Never".to_string(),
    type_args: vec![],
    span: token.span,
})
```

#### G1o. Const generics (integer in type parameters) (1 file)

**Files:** `std/backtrace.tg:180`

**Error message:** `unexpected type token: Integer("128")`

**Example code:**
```
mut buffer: Array[Ptr[Unit], 128] = ...
```

**Root cause:** `parse_optional_type_args()` calls `parse_type()` for each type
argument. `parse_type()` does not recognize an integer literal as a valid type
argument (const generic).

**Proper fix:** In `parse_optional_type_args()`, before calling `parse_type()`,
check if the next token is an integer literal. If so, parse it as a const
generic argument. Either:
1. Add `Integer` handling in `parse_type()` → return `TypeRef::Named { name: "128", ... }`
2. Or change `parse_optional_type_args()` to handle `TypeRef` OR integer values

#### G1p. Variable expression as array-repeat length in `vec![]` (1 file)

**Files:** `std/compress.tg:1024`

**Error message:** `expected array repeat length integer, found Ident("padding")`

**Example code:**
```
let zeros = vec![0u8; padding]
```

**Root cause:** The `vec!` macro parser only accepts integer literals for the
repeat count. It requires a constant but `padding` is a runtime variable.

**Proper fix:** In `try_parse_vec_macro_expr()`, when parsing the `; count` part,
accept any expression (not just integer literals). Parse with `parse_expr()`
instead of matching only `TokenKind::Integer`.

#### G1q. `static` / `static mut` declarations in function bodies (1 file)

**Files:** `std/profile.tg:264`

**Error message:** `unexpected expression token: KeywordStatic`

**Example code:**
```
static mut sym_initialized: Bool = false
```

**Root cause:** The statement parser inside function bodies does not recognize
`KeywordStatic` as a valid statement-start token.

**Proper fix:** In `parse_stmt()`, add `KeywordStatic` dispatch. Parse
`static [mut] name: Type = value` as a local static declaration. Store as
`Stmt::Static { name, ty, value, mutable }`. For codegen, emit a
Rust `thread_local!` or `static` depending on semantics.

#### G1r. `pure` keyword used as identifier/function call (1 file)

**Files:** `std/regex.tg:1584`

**Error message:** `unexpected expression token: KeywordPure`

**Example code:**
```
self.sep_by1(sep).or_else(pure(Vec::new()))
```

**Root cause:** `pure` is reserved as `KeywordPure` in the lexer, so it cannot
be used as a function name in expression position. But the language uses `pure()`
as a combinator function (monadic pure/return).

**Proper fix:** Add `KeywordPure` to `expect_ident()` so it can be used as an
identifier. Also in `parse_primary_expr()`, add `KeywordPure` as a case that
creates an `Expr::Name { name: "pure", ... }` and continues parsing as a
function call.

#### G1s. Semicolons in match arms (1 file)

**Files:** `std/i18n.tg:153`

**Error message:** `expected KeywordEnd, found Semi`

**Example code:**
```
when BidiClass::R then paragraph_level = 1u32; break
```

**Root cause:** The match arm body parser treats `;` as ending the entire match
block rather than as a statement separator within the arm.

**Proper fix:** In the `when ... then ...` arm body parser, allow `;` and newline
as statement separators. Parse multiple statements until the next `when`,
`else`, or `end` keyword. The match arm body should be a `Block` (list of
statements), not a single expression.

#### G1t. `..expr` struct spread syntax (1 file)

**Files:** `std/snapshot.tg:429`

**Error message:** `expected identifier, found DotDot`

**Example code:**
```
RecorderConfig { record_memory: true, ..self }
```

**Root cause:** The struct literal parser does not recognize `..` as a field-rest
/ spread operator.

**Proper fix:** In the struct literal parser, when encountering `DotDot` inside
`{ ... }`, parse the following expression as the "base" for remaining fields.
Store as `rest: Option<Box<Expr>>` on the struct literal AST node.

#### G1u. `match` arm separators: `=>` mixed with `then` (cascading) (2 files)

**Files:** `std/toml.tg:491`, `std/log.tg:747` (cascade from other errors)

**Error message:** `unexpected expression token: KeywordWhen`

**Root cause for toml.tg:** Three `end` keywords close nested if/elsif/else
blocks inside a for-loop inside a match arm, which is correct. But the
match arm's body parser loses track and the closing `end end end` terminates
blocks prematurely, orphaning the subsequent `when` arm.

**Root cause for log.tg:** Cascade from `Map[String, SpanValue]` multi-param
generic failure at line 710 (see G1a).

**Proper fix:** These are cascading errors. Fixing G1a (generics in expression
context) will fix log.tg. For toml.tg, the issue is nested block tracking in
match arms — verify that `end end end` correctly closes `if`+`elsif`+`for`
blocks without also closing the match.

#### G1v. Source bug: stray `>` brackets (1 file)

**Files:** `std/gpu.tg:590`

**Error message:** `expected RBracket, found Gt`

**Example code:**
```
pub descriptor_sets: Vec[DescriptorSetLayout>]
pub push_constants: Vec[PushConstantRange>]
```

**Root cause:** Stray `>` characters from an incomplete `Vec<T>` → `Vec[T]`
bracket conversion. This is a source file bug, not a parser limitation.

**Proper fix (source):** Remove the stray `>`:
```
pub descriptor_sets: Vec[DescriptorSetLayout]
pub push_constants: Vec[PushConstantRange]
pub input_attributes: Vec[VertexAttribute]
pub output_attributes: Vec[ShaderOutput]
```

#### G1w. Associated type bindings `Trait[Assoc = Type]` (1 file)

**Files:** `std/csv.tg:137`

**Error message:** `expected RBracket, found Eq`

**Example code:**
```
pub def iter(self) -> impl Iterator[Item = &String]
```

**Root cause:** `parse_optional_type_args()` calls `parse_type()` for each arg.
When it parses `Item`, that's a valid type name, then `=` is unexpected.

**Proper fix:** In `parse_optional_type_args()`, before calling `parse_type()`,
check if the pattern is `Ident = Type` (associated type binding). If the next
two tokens are `Ident` then `Eq`, parse as a named type parameter binding.
Store as `TypeArg::Binding { name, ty }` alongside `TypeArg::Positional { ty }`.

---

### G2. Semantic Errors — 52 in `std/`, 5 in `tg_compiler/`

#### G2a. `Nil` vs `Unit` type mismatch (15 files)

**Files:** `std/assets.tg:29`, `std/autotune.tg:87`, `std/compositor.tg:55`,
`std/fuzz.tg:94`, `std/graph.tg:103`, `std/hal.tg:140`, `std/kernel.tg:77`,
`std/metrics.tg:95`, `std/patch.tg:105`, `std/serde.tg:82`, `std/sql.tg:84`,
`std/sqlite.tg:56`, `std/sync.tg:46`, `std/tensor.tg:112`,
`std/diagnostics.tg:95` (reverse: expected Nil, found Unit)

**Error messages:** `function '...' expected return type Unit, found Nil`
(and one reverse: `expected return type Nil, found Unit`)

**Example pattern:**
```tg
# Function declared -> Unit, but tail expression is logger.log(entry) which returns Nil
def _log_asset_event(kind: String, name: String) -> Unit
  ...
  logger.log(entry)  # Logger.log returns Nil
end
```

**Root cause:** The language has both `Nil` (explicit nothing type from the spec)
and `Unit` (implicit void type). Stage0's `is_type_compatible()` in
`sema/mod.rs` treats them as different types. But the codebase uses them
interchangeably as "no meaningful return value".

**Proper fix:** In `sema/mod.rs` `is_type_compatible()`, treat `Nil` and `Unit`
as mutually compatible:
```rust
// Near the top of is_type_compatible:
if (matches!(a, TypeRef::Unit { .. }) && is_nil_named(b))
|| (is_nil_named(a) && matches!(b, TypeRef::Unit { .. })) {
    return true;
}
```
Where `is_nil_named(ty)` checks for `TypeRef::Named { name: "Nil", .. }`.

#### G2b. `Vec[T].new()` / `Type[T].method()` in expression context (5 files)

**Files:** `std/audit.tg:62`, `std/ctx.tg:79`, `std/encoding.tg:59`,
`std/migrate.tg:69`, `std/msgpack.tg:412`

**Error messages:** `index type must be Int, found Unit`

**Example:**
```tg
let findings = Vec[AuditFinding].new()
```

**Root cause:** Same as G1a. In expression context, `Vec[AuditFinding]` is parsed
as an index expression `Vec[AuditFinding]`. The sema then checks the index type:
`AuditFinding` (a type name, not an Int) → fails. The cascading `.new()` also
fails.

**Proper fix:** Same as G1a — fix the expression parser to recognize
`Name[TypeArgs].method()` as a generic type constructor call. Once parsing
succeeds, sema will correctly see `Vec[AuditFinding]::new()` as a static method
call on a parameterized type.

#### G2c. Cross-module enum variant payload types resolve as Unit (5 files — tg_compiler)

**Files:** `tg_compiler/borrow_check.tg:374`, `tg_compiler/cap_baseline.tg:539`,
`tg_compiler/linter.tg:536`, `tg_compiler/mir.tg:1093`,
`tg_compiler/refactor.tg:162`

**Error messages:** `expected String, found Unit` / `'-' requires numeric operands, found Int and Unit` / `struct field 'file' expected String, found Unit`

**Example:**
```tg
# borrow_check.tg:374
when ExprKind::ExprIdent(name) then names.push(name.clone())
# → 'name' destructured from variant payload, but ExprKind is defined
#   in ast.tg → variant payload type (String) not loaded → typed as Unit
```

**Root cause:** During `scan tg_compiler`, enum variant payload types from
cross-module enums are not populated in the semantic environment. `bind_pattern`
looks up the enum definition, finds the variant, but the payload type is either
missing or defaulted to `Unit`. This affects all pattern-match destructurings
of enum variants defined in other files.

**Proper fix:** In `driver.rs` `analyze_directory()`, during Phase 1 (collecting
definitions), also collect enum variant payload types — not just variant names.
In `sema/mod.rs` `bind_pattern`, when the enum is loaded from the cross-module
environment, use the variant's declared payload type to bind the pattern variable.
If payload types are stored as `Vec<TypeRef>`, each positional binding gets the
corresponding type.

#### G2d. Missing intrinsic method signatures (12 files)

**Files:** Various `std/` files

**Sub-group D1: Missing Char methods (2 files)**

| File | Error | Missing Method |
|------|-------|----------------|
| `std/fmt.tg:108` | `'-' found Unit and Unit` | `Char.to_int() -> Int` |
| `std/url.tg:155` | `expected Char, found Unit` | `Char.to_lowercase() -> Char` |

**Proper fix:** Add to `char_intrinsic_method_sig()` in `sema/mod.rs`:
- `"to_int"` → `Int`
- `"to_lowercase"` → `Char`
- `"to_uppercase"` → `Char`
- `"is_alphabetic"` → `Bool`
- `"is_digit"` → `Bool`

**Sub-group D2: Missing Float/f32 math methods (2 files)**

| File | Error | Missing Method |
|------|-------|----------------|
| `std/geom.tg:360` | `unary '-' found extern::unresolved` | `f32.sin() -> f32`, `f32.cos() -> f32` |
| `std/gfx.tg:396` | `expected f32, found Unit` | `f32.sqrt() -> f32`, `f32.max() -> f32` |

**Root cause:** `f32` is treated as `Named("f32")` not `Float`, so it doesn't
enter the `float_intrinsic_method_sig()` path. The Named-type fallback returns
Unit.

**Proper fix:** In `check_method_call()`, recognize `f32`/`f64` as float types
and route them to the float intrinsic method table. Add math methods:
`sin`, `cos`, `tan`, `asin`, `acos`, `atan`, `atan2`, `abs`, `max`, `min`,
`floor`, `ceil`, `round`, `powi`, `powf`, `log`, `log2`, `log10`, `exp`.

**Sub-group D3: Missing String methods (2 files)**

| File | Error | Missing Method |
|------|-------|----------------|
| `std/semantic_diff.tg:134` | `expected Int, found Unit` | `String.find_first_of(...) -> Int` |
| `std/test_gen.tg:132` | `expected Int, found Unit` | `String.find_first_of(...) -> Int` |

**Proper fix:** Add `"find_first_of"` to `string_intrinsic_method_sig()` → returns `Option[Int]`.

**Sub-group D4: `parse_int()` returns wrong type (2 files)**

| File | Error | Code |
|------|-------|------|
| `std/secure_types.tg:274` | `Option has no variant 'Ok'` | `match s.parse_int() { Ok(n) => ... }` |
| `std/supply_chain.tg:51` | `Option has no variant 'Ok'` | `match parse_int(s) { Ok(n) => ... }` |

**Root cause:** `string_intrinsic_method_sig` returns `Option[Int]` for `parse_int`,
but the source code matches against `Result::Ok(n)` / `Result::Err(e)`.

**Proper fix:** Change `parse_int` return type in `string_intrinsic_method_sig`
from `Option[Int]` to `Result[Int, String]`. Add variants `parse_float` →
`Result[Float, String]`.

**Sub-group D5: Missing enum construction via dot syntax (1 file)**

| File | Error | Code |
|------|-------|------|
| `std/path.tg:18` | `expected PathSeparator, found Unit` | `PathSeparator.Unix` (enum variant) |

**Root cause:** When a dot expression like `PathSeparator.Unix` appears in value
context, the sema tries field access on `PathSeparator` type. Since there's no
struct field `Unix`, it returns Unit. It should recognize this as enum variant
construction.

**Proper fix:** In `type_of_field_access()`, when field access on a type name
fails (no struct field), check if the type name is an enum and the field is a
variant name. If so, return the enum type.

**Sub-group D6: Missing YAML/enum variant payload resolution (1 file)**

| File | Error | Code |
|------|-------|------|
| `std/yaml.tg:83` | `expected Option[Value], found Unit` | Method chaining on locally-defined enum |

**Root cause:** `Value` enum is defined locally in `yaml.tg` but the match
destructuring returns Unit for the payload type. Forward type inference doesn't
propagate through the match arms.

**Proper fix:** In `check_match_expr()`, when the matched value's type is known
(local enum), propagate variant payload types to the pattern bindings even when
the enum is not in `env.enums` yet (forward reference within the same file).

#### G2e. Cross-module struct field access returns Unit (7 files)

**Files:** `std/bench.tg:262`, `std/embed_trace.tg:82`, `std/env.tg:41`,
`std/gfx.tg:396` (partial), `std/net.tg:387`, `std/perf.tg:26`,
`std/web_server.tg:67`

**Error messages:** Various type mismatches cascading from field access on
unloaded struct returning Unit

**Root cause:** When `scan std` analyzes each file independently, cross-module
type definitions are not loaded. Field access on unknown types returns `Unit`
via `type_of_field_from_type()` fallback. This cascades: `obj.field` → Unit →
`obj.field.method()` → Unit → type mismatch.

**Proper fix:** Same root strategy as G2c — load `std/` struct definitions into
the shared environment during directory scanning Phase 1. When a struct field
is accessed on an unresolved type, return a distinct `TypeRef::Unresolved`
instead of `Unit` to prevent cascading false positives.

#### G2f. Source bugs in .tg files (5 files)

These are genuine errors that any correct compiler would reject.

| File:Line | Error | Bug | Fix |
|-----------|-------|-----|-----|
| `std/accessibility.tg:108` | `&A11yNode vs &Option[&A11yNode]` | `&node.children.get(i)` passes wrapped Option | Use `&node.children[i]` or `.get(i).unwrap()` |
| `std/semver.tg:95` | `expected Unit, found Int` | `Hash::hash` impl returns Int from `n.hash()` | Append `; ()` after hash calls or change return type |
| `std/text.tg:211` | `cannot assign to 'i'` | `let i = 0` then `i = i + 1` | Change to `mut i = 0` |
| `std/ui_toolkit.tg:174` | `cannot assign to '_next_ui_id'` | `let _next_ui_id: u64 = 1` then assigned | Change to `mut _next_ui_id: u64 = 1u64` |
| `std/time.tg:428` | `expected &mut Int, found &Int` | `time(&timestamp)` passes immutable ref | Change to `time(&mut timestamp)` or declare `mut timestamp` |

#### G2g. `Byte` not recognized as integer type (1 file)

**Files:** `std/replay.tg:358`

**Error message:** `bitwise operator requires integer operands, found Byte and Int`

**Root cause:** The sema's `is_integer_type()` / bitwise-op handler doesn't
recognize `Byte` (aka `u8`) as an integer type.

**Proper fix:** Add `"Byte"` (and `"u8"`) to `is_integer_type()` / the
bitwise operator handler in `sema/mod.rs`.

#### G2h. Mutability flag lost during directory scanning (1 file)

**Files:** `std/math.tg:46`

**Error message:** `cannot assign to immutable variable 'GLOBAL_LOGGER'`

**Root cause:** The variable is declared `mut GLOBAL_LOGGER = ...` but during
multi-file directory scanning, the global's `mutable` flag is not preserved
when merging into the shared environment.

**Proper fix:** In `driver.rs` `analyze_directory()`, when merging global
declarations into the shared environment, preserve the `mutable` flag from the
original declaration.

#### G2i. `asm!()` macro parsed as logical NOT (1 file)

**Files:** `std/debug.tg:29`

**Error message:** `'!' requires Bool or Int operand, found String`

**Root cause:** `asm!("int3")` — the `!` after `asm` is parsed as the logical
NOT unary operator applied to the string `"int3"`. The parser does not recognize
`ident!()` as a macro invocation.

**Proper fix:** In `parse_primary_expr()`, when an identifier is followed by `!`
then `(`, recognize it as a macro call (similar to Rust's `asm!(...)`,
`println!(...)`, etc.). Parse as `Expr::MacroCall { name, args }`.

#### G2j. Generic type parameter forwarding (1 file)

**Files:** `std/alloc.tg:66`

**Error message:** `could not infer type argument 'T' for function 'size_of'`

**Root cause:** `layout_for[T]()` calls `size_of[T]()` — the enclosing function's
generic type parameter `T` is not available for resolving the nested call's type
argument.

**Proper fix:** In `sema/mod.rs`, when resolving type arguments for a function
call, check if unresolved type args match the enclosing function's generic
parameters. If `T` appears in both the caller's and callee's parameter lists,
forward it.

#### G2k. `Self` parameter type loses `&mut` wrapper (1 file)

**Files:** `std/app.tg:295`

**Error message:** `expected &mut Self, found SoftwareApp`

**Root cause:** In `sema/mod.rs` (circa line 720-721), when processing `self`
parameters in impl methods, the `&mut` wrapper is discarded and `self` is bound
to the bare type `SoftwareApp` instead of `&mut SoftwareApp`.

**Proper fix:** In the self-parameter handling code, preserve the declared
reference wrapper. If the parameter is `self: &mut Self`, bind `self` in locals
as `&mut <impl_type>`, not just `<impl_type>`.

#### G2l. Vec.get return type cascading (1 file)

**Files:** `std/image.tg:185`

**Error message:** `expected &Vec[u8], found &Vec[Option[&u8]]`

**Root cause:** `Vec.get()` returns `Option[&T]` in stage0's intrinsic table.
The code builds up an `Option[&u8]` list when it expects plain `u8` references.
The types cascade through Vec construction into a type mismatch.

**Proper fix:** Review the intrinsic return type for `Vec.get()`. In Tangerine,
if `.get()` is meant to be bounds-checked-and-panic (like `[]`), change the
return type to `&T`. If it's meant to be safe (like Rust's `.get()`), keep
`Option[&T]` and fix the source file to handle the Option.

#### G2m. Function call on cross-module return types (2 files)

**Files:** `std/json.tg:215`, `std/wasm.tg:216`

**Error messages:** `expected Result[Value, JsonError], found Unit` /
`expected Result[WasmModule, WasmError], found Unit`

**Root cause:** Function body ends in a loop where all exits use `return`.
Stage0 types the loop expression as `Unit` instead of using the return type.
Alternatively, method chains on cross-module types cascade to Unit.

**Proper fix:** In `check_loop_expr()`, when all branches contain `return`
statements with values, and the function has a declared return type, propagate
the declared return type as the expression type of the loop. Alternatively,
recognize that a loop containing only `return` paths is typed as `Never`.

---

### G3. Priority Fix Order

| Priority | Fix | Unblocks | Files Fixed |
|----------|-----|----------|-------------|
| **P0** | G1a: Multi-param generics in expression context | Parser | 6 parse + 5 sema = **11** |
| **P1** | G2a: Nil↔Unit compatibility | Sema | **15** |
| **P2** | G1b: Match arm guards | Parser | **3** |
| **P3** | G1c: @attribute syntax | Parser | **3** |
| **P4** | G1d: unsafe "reason" do | Parser | **2** |
| **P5** | G1e: Turbofish ::<Type> | Parser | **2** |
| **P6** | G2d: Missing intrinsic methods | Sema | **12** |
| **P7** | G2c: Cross-module enum payloads | Sema (tg_compiler) | **5** |
| **P8** | G2e: Cross-module struct fields | Sema | **7** |
| **P9** | G1f-G1t: Remaining parser constructs | Parser | 1 each, **15 total** |
| **P10** | G2f: Source file bugs | Source | **5** |
| **P11** | G2g-G2m: Remaining sema gaps | Sema | 1-2 each, **8 total** |

---

## H. Remaining Failures After Section G (Current Scan: 2026-03-16)

Section G removed the first major parser/sema wall, but the codebase still has a
second layer of blockers:

| Scope | Parse Failures | Semantic Failures | Total |
|-------|----------------|-------------------|-------|
| `std/` | 30 | 35 | 65 |
| `tg_compiler/` | 0 | 7 | 7 |
| **Total** | **30** | **42** | **72** |

These remaining failures are not one class of bug. They split into four distinct
categories, and they should be fixed accordingly:

1. **Real source bugs**: incorrect mutability, missing `self`, wrong tail
   expression, or calling APIs with the wrong argument shape. These should be
   fixed in the `.tg` source.
2. **Parser coverage gaps**: stage0 still misses a number of real Tangerine
   surface forms that appear in `std/`. These must be fixed in the parser, not
   papered over by rewriting every caller.
3. **Sema/model gaps**: stage0 still collapses valid expressions to `Unit` in a
   few important cases: `Self` equivalence, static method calls on named types,
   borrowed-container indexing, collection/string helper methods, intrinsic-body
   declarations, and field access through inferred loop variables.
4. **API contract mismatches introduced by stage0 assumptions**: the clearest
   example is `Vec.get`. The language/library contract must be decided once and
   then enforced consistently across stage0 and `std/`; source edits that merely
   silence one file are not an acceptable long-term fix.

### H1. `tg_compiler/` Remaining Semantic Failures (7)

- [ ] **tg_compiler/driver.tg:1415 — `args[i].clone()` typed as `Vec[Expr]` instead of `Expr`**
  - Error: `method argument type mismatch: expected Expr, found Vec[Expr]`
  - Context: `subst_map.insert(macro_decl.params[i].name.clone(), args[i].clone())`
  - Root cause: element access through borrowed generic containers is still not
    modeled consistently. `args` is `&Vec[Expr]`; `args[i]` should resolve to an
    element expression, not the whole collection.
  - **Proper fix:** in stage0 sema, make indexing on `&Vec[T]`, `&Array[T]`, and
    equivalent borrowed containers return the element type for scalar indices and
    the container type only for range indices.

- [ ] **tg_compiler/lib.tg:561 — map lookup key borrowing is inconsistent**
  - Error: `method argument type mismatch: expected &String, found Unit`
  - Context: `ctx.variables.get(p_name)`
  - Root cause: `Map.get` is modeled as taking `&K`, but stage0 is not robustly
    preserving the type of the local key expression in this call path.
  - **Proper fix:** standardize `Map.get`/`contains_key` lookup semantics around
    borrowed keys, then fix the call site to use `&p_name` if that is the
    language contract. Do not weaken sema to accept arbitrary `Unit` fallbacks.

- [ ] **tg_compiler/linker.tg:1299 — MIR function indexing / field access degrades to `Unit`**
  - Error: `method argument type mismatch: expected String, found Unit`
  - Context: `index.insert(func.name.clone(), FunctionIndexEntry { ... })`
  - Root cause: the expression `ctx.modules[mi].mir_functions[fi]` is not being
    carried through as a concrete MIR function value in this path, so `func.name`
    collapses downstream.
  - **Proper fix:** repair stage0's field/index typing for nested collection and
    struct access so values fetched from `Vec[MirFunction]` retain their nominal
    struct type and fields.

- [ ] **tg_compiler/mir.tg:4935 — control-flow edge values still collapse to container shape**
  - Error: `argument type mismatch for 'get_block_index': expected BlockId, found Vec[BlockId]`
  - Root cause: a successor edge or block id extracted from a terminator still
    resolves to the whole target vector in at least one optimization path.
  - **Proper fix:** fix terminator-pattern destructuring and element extraction so
    single CFG edges are typed as `BlockId` everywhere. This belongs in stage0
    sema, not in MIR pass rewrites.

- [ ] **tg_compiler/refactor.tg:162 — `symbol.def_span.file` still resolves to `Unit`**
  - Error: `struct field 'file' expected String, found Unit`
  - Root cause: a struct-valued symbol imported from `resolver.tg` is still not
    being recognized as a concrete struct in all refactoring paths.
  - **Proper fix:** complete cross-module struct field typing so imported nominal
    structs retain their field maps after name resolution and inference.

- [ ] **tg_compiler/resolver.tg:1450 — local scope lookup still loses the local name type**
  - Error: `method argument type mismatch: expected Int, found &String`
  - Context: `ctx.local_scopes[i].get(name)`
  - Root cause: this is another borrowed-container lookup path where the key
    expression and the expected index/key type are being conflated.
  - **Proper fix:** separate integer indexing from associative lookup in the sema
    rules for `Vec[...]` vs `Map.get(...)`, and preserve the actual local name
    type through the call.

- [ ] **tg_compiler/types.tg:444 — scope lookup helper still mis-types its access path**
  - Error: `method argument type mismatch: expected Int, found String`
  - Context: `env.scopes[i].get(name)`
  - Root cause: same family as the resolver failure above: the nested access path
    mixes vector indexing and map lookup typing.
  - **Proper fix:** fix sema's nested access typing once, then re-scan both
    `resolver.tg` and `types.tg`. These are symptoms of one defect class.

### H2. `std/` Remaining Parser Gaps (30)

- [ ] **std/async.tg:314 — block-form `unsafe "reason" do ... end` still fails in expression position**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** make block-form `unsafe` parse anywhere an expression can
    appear, including `guard`/`if` conditions and inline method bodies.

- [ ] **std/backtrace.tg:975 — item-level `unsafe def` is still not accepted**
  - Error: `unexpected token at top level: KeywordUnsafe`
  - Context: `unsafe def cstr_to_string(ptr: Ptr[u8]) -> String`
  - **Proper fix:** extend item grammar so function declarations may carry an
    `unsafe` modifier before `def`.

- [ ] **std/collections.tg:657 — bounded generics in impl headers still misparse**
  - Error: `expected RBracket, found LBracket`
  - Context: `impl[T, U, I: Iterator[T]] Iterator[U] for MapIter[T, U, I]`
  - **Proper fix:** teach the parser to handle nested bracketed type arguments and
    bounded generic parameters inside impl/trait headers without prematurely
    closing the outer generic list.

- [ ] **std/config.tg:550 — Rust-style brace match arms with `return` are still unsupported**
  - Error: `unexpected expression token: KeywordReturn`
  - Context: `match Int.parse(val) { when Ok(i) then return ... when Err(_) then {} }`
  - **Proper fix:** either implement brace-form match expressions with inline
    `return`, or normalize the grammar and parser so this Rust-form is rejected
    earlier with a structured rewrite diagnostic. Long-term, parser support is
    preferable because this form appears repeatedly in modern `std/` code.

- [ ] **std/db.tg:107 — nested reference types such as `&&str` still fail in type grammar**
  - Error: `unexpected type token: AmpAmp`
  - **Proper fix:** permit repeated `&` / `&mut` prefixes in type parsing rather
    than tokenizing the second `&` as an impossible type token.

- [ ] **std/embedded.tg:147 — `pub const def ...` / declaration modifiers still not parsed together**
  - Error: `expected Eq, found Ident("at")`
  - Context: `pub const def at(address: UInt) -> Register[T]`
  - **Proper fix:** support modifier stacks on function declarations (`pub`,
    `const`, `unsafe`, `inline`) in the item parser instead of handling each as an
    isolated special case.

- [ ] **std/ffi.tg:683 — constructor-like pointer literal inside condition still confuses expression parsing**
  - Error: `expected RParen, found LBrace`
  - Context: `is_null(&Ptr[u8] { address: err.address })`
  - **Proper fix:** support typed struct literals after generic/type applications
    in ordinary expression position.

- [ ] **std/float_control.tg:103 — match still rejects `=>` arm syntax**
  - Error: `unexpected pattern token: FatArrow`
  - **Proper fix:** add `pattern => expr` arm support, or normalize all parser
    entry points onto one canonical arm grammar instead of partly supporting only
    `when ... then`.

- [ ] **std/gfx_gpu.tg:380 — module-level `const` items are still not fully accepted in all contexts**
  - Error: `expected function keyword, found KeywordConst`
  - **Proper fix:** complete top-level `const` item parsing across modules and
    extern-heavy files, not just the simple cases fixed earlier.

- [ ] **std/gpu.tg:1125 — one expression form still leaves a trailing `}` unmatched**
  - Error: `unexpected expression token: RBrace`
  - **Proper fix:** fix block/struct-literal disambiguation so a braced
    expression used as a tail value does not leak its closing brace into the
    enclosing parser state.

- [ ] **std/http.tg:2168 — slice-range syntax in indexing is still incomplete**
  - Error: `unexpected expression token: DotDot`
  - Context: `resp_buf[..n]`
  - **Proper fix:** finish parser support for open-ended and bounded range
    expressions inside indexing/slicing forms.

- [ ] **std/i18n.tg:492 — one enum/match construct still leaves the parser inside the wrong block**
  - Error: `expected KeywordEnd, found Ident("LineBreakOpportunity")`
  - **Proper fix:** fix block termination around nested enum/type declarations so
    the parser does not treat the next item header as a stray identifier.

- [ ] **std/io.tg:177 — one statement form still fails to terminate correctly**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** make the statement parser accept the relevant tail-expression
    or early-return form instead of requiring a separator that the language form
    should not need.

- [ ] **std/linalg.tg:326 — declaration-level `@inline(always)` + `def` still misparse together**
  - Error: `expected function keyword, found KeywordInline`
  - **Proper fix:** treat `inline` as a declaration modifier in the function item
    grammar, not only as an attribute-like annotation.

- [ ] **std/log.tg:747 — statement termination around modern expression syntax remains incomplete**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** finish the parser's handling of tail-expression blocks and
    chained expressions so explicit separators are not required where the grammar
    already implies a boundary.

- [ ] **std/mmap.tg:630 — same statement-boundary defect class as `std/log.tg`**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** same parser boundary repair; do not rewrite source into a less
    idiomatic style just to placate stage0.

- [ ] **std/opentelemetry.tg:377 — async/middleware-style control flow still hits statement-boundary bugs**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** same expression-vs-statement boundary repair in the parser.

- [ ] **std/process.tg:179 — one declaration form around `Self`/method syntax still misparses**
  - Error: `expected function keyword, found KeywordSelfValue`
  - **Proper fix:** allow the receiver-form grammar to parse the exact method
    declaration form used in `std/process.tg` rather than rejecting `self` in
    that position.

- [ ] **std/profile.tg:264 — expression-body declaration syntax still leaves the parser expecting separators**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** normalize expression-bodied defs and inline control flow to a
    single parser path; `std/profile.tg` uses these forms heavily.

- [ ] **std/random.tg:91 — same statement-boundary defect class**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** same parser repair as above.

- [ ] **std/regex.tg:1628 — closure/match parser still loses the intended branch delimiter**
  - Error: `expected Pipe, found Ident("state")`
  - Context: parser-combinator closures such as `|state| { ... }`
  - **Proper fix:** finish closure/lambda parsing so `|param|` forms inside method
    chains are not mistaken for match-pattern separators.

- [ ] **std/simd.tg:140 — same statement-boundary defect class**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** same parser repair as above.

- [ ] **std/snapshot.tg:1197 — local `extern` item inside a function still misparses**
  - Error: `expected statement separator or branch terminator`
  - Context: `extern "C" def pthread_self() -> u64`
  - **Proper fix:** support local extern declarations or explicitly reserve them
    to item scope with a purposeful diagnostic. Long-term, local extern support is
    the better fit for the existing `std/` style.

- [ ] **std/thread.tg:1052 — trait-object function types inside nested generics still confuse bracket parsing**
  - Error: `expected RBracket, found LParen`
  - Context: `VecDeque[Box[dyn FnOnce()]]`
  - **Proper fix:** finish nested generic parsing where a trait object contains a
    callable type with parentheses.

- [ ] **std/toml.tg:491 — condensed `end end end` form still trips statement parsing**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** make nested block termination deterministic even when several
    `end` tokens close compactly written inner constructs.

- [ ] **std/ui.tg:39 — one early module item still hits the same separator/termination bug family**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** repair parser state transitions between adjacent declarations
    and compact expression-bodied items.

- [ ] **std/validation.tg:335 — nested trait-object generics still fail**
  - Error: `expected RBracket, found LBracket`
  - Context: `_validators: Vec[Box[dyn Validator[T]]]`
  - **Proper fix:** same nested generic / trait-object parser repair as
    `std/thread.tg`.

- [ ] **std/wasm_js.tg:271 — Rust-style inline unsafe blocks / compact statement forms still fail**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** support the compact block-expression style used in the WASM JS
    bindings instead of forcing a wholesale rewrite.

- [ ] **std/web.tg:87 — turbofish/generic call parsing is still incomplete in some method-call contexts**
  - Error: `expected identifier, found Lt`
  - Context: `Json::parse::<T>(&body)`
  - **Proper fix:** complete `::<...>` parsing after paths and before calls across
    all expression contexts, not only the simpler cases already fixed.

- [ ] **std/web_ext.tg:171 — async/await-heavy middleware code still triggers statement-boundary parser bugs**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** same parser boundary repair as `std/opentelemetry.tg` and
    `std/profile.tg`.

### H3. `std/` Remaining Semantic Failures (35)

#### H3a. Real source bugs: mutability, receiver spelling, and wrong tail expressions

- [ ] **std/accessibility.tg:109 — local loop counter is reassigned without mutable binding**
  - Error: `cannot assign to immutable variable 'i'`
  - **Proper fix:** make the binding mutable at its declaration site.

- [ ] **std/compositor.tg:112 — same immutable-reassignment bug as accessibility**
  - Error: `cannot assign to immutable variable 'i'`
  - **Proper fix:** same source fix.

- [ ] **std/csv.tg:38 — config struct is mutated after immutable initialization**
  - Error: `assignment type mismatch: expected Unit, found Char`
  - Context: `cfg.delimiter = '\t'`
  - **Proper fix:** make the local config binding mutable; this is a real source
    mutability error, not a sema gap.

- [ ] **std/image.tg:673 — local coordinate/state variable is reassigned without mutability**
  - Error: `cannot assign to immutable variable 'x'`
  - **Proper fix:** make the binding mutable.

- [ ] **std/math.tg:46 — module logger is reassigned without mutable global binding**
  - Error: `cannot assign to immutable variable 'GLOBAL_LOGGER'`
  - **Proper fix:** declare the global as mutable if runtime replacement is part
    of the API contract.

- [ ] **std/perf.tg:26 — `FrameTimings` instance methods are missing `self`**
  - Error: `'/' requires numeric operands, found Unit and Float`
  - Context: methods such as `def total_ms() -> f32` read `self.present_end_ns`
  - **Proper fix:** define these as real methods (`self: &Self` or equivalent)
    rather than relying on an implicit receiver the current source does not declare.

- [ ] **std/secure_types.tg:318 — local string accumulator is reassigned without mutability**
  - Error: `cannot assign to immutable variable 's'`
  - **Proper fix:** make the binding mutable.

- [ ] **std/text.tg:368 — width accumulator is reassigned without mutable binding**
  - Error: `cannot assign to immutable variable 'max_line_w'`
  - **Proper fix:** make the binding mutable.

- [ ] **std/ui_toolkit.tg:202 — layout accumulator is reassigned without mutable binding**
  - Error: `cannot assign to immutable variable 'total_w'`
  - **Proper fix:** make the binding mutable.

- [ ] **std/alloc.tg:139 — deallocator leaks the raw C return value into a `Unit` API**
  - Error: `function 'deallocate' expected return type Unit, found Int`
  - Context: `munmap(ptr, size)` as the tail expression of a `-> Unit` method
  - **Proper fix:** choose one contract and implement it honestly: either make the
    allocator deallocation API fallible and return `Result`, or consume/check the
    `munmap` status internally and keep the public API `Unit`.

#### H3b. Stage0 sema still needs more nominal-type, `Self`, and control-flow work

- [ ] **std/app.tg:295 — `Self` in function types is still not canonicalized to the impl type**
  - Error: `expected &mut Self, found &mut SoftwareApp`
  - Context: `main(self)` where the trait contract is `Fn(&mut Self) -> Unit`
  - **Proper fix:** in sema, treat `Self` and the concrete impl receiver type as
    equivalent inside impl bodies and nested function-type arguments.

- [ ] **std/audit.tg:142 — intrinsic-backed helper body still types as `Unit` despite declared return type**
  - Error: `function '_scan_scope_symbols' expected return type Vec[String], found Unit`
  - Context: declaration-style body with `@intrinsic("scan_scope_symbols")`
  - **Proper fix:** stage0 must recognize intrinsic-body declarations as typed by
    their signature rather than by the annotation expression itself.

- [ ] **std/debug.tg:118 — tail-expression typing across `@cfg(debug)` still degrades the tuple return**
  - Error: `function 'timed' expected return type (T, Float), found (T, Unit)`
  - Context: `let ms = timer.elapsed_ms(); @cfg(debug) eprintln(...); (result, ms)`
  - **Proper fix:** `@cfg`-filtered statements inside a function body must not
    perturb the type of the following tail expression.

- [ ] **std/diagnostics.tg:169 — `List[String].join(", ")` is still missing from sema/model coverage**
  - Error: `function 'capability_list' expected return type String, found Unit`
  - **Proper fix:** add the actual collection/string helper method signature used
    here (`join`) instead of rewriting diagnostics code away from the library API.

- [ ] **std/json.tg:334 — loop/return typing is still incomplete in parser helpers**
  - Error: `function 'parse_string' expected return type Result[Value, JsonError], found Unit`
  - Context: function exits from inside a `loop` with `return Result::Err(...)`
  - **Proper fix:** type a loop that only exits via `return` or typed `break` as
    `Never` / compatible with the enclosing declared return type.

- [ ] **std/path.tg:18 — `@cfg`-selected expression bodies still collapse to `Unit`**
  - Error: `function 'native_separator' expected return type PathSeparator, found Unit`
  - Context: two adjacent `@cfg(...)` expression branches
  - **Proper fix:** make cfg-filtered function bodies preserve the surviving tail
    expression rather than leaving an empty/`Unit` body.

- [ ] **std/wasm.tg:216 — static call through `Self` is still not fully resolved**
  - Error: `function 'from_file' expected return type Result[WasmModule, WasmError], found Unit`
  - Context: `Self.from_bytes(&bytes)` inside `impl WasmModule`
  - **Proper fix:** complete static method resolution for `Self.method(...)` in
    impl scope; it must resolve exactly as `WasmModule::from_bytes(...)`.

- [ ] **std/web_server.tg:129 — named-type static calls still sometimes bind to enclosing `Self`**
  - Error: `struct field 'transcripts' expected TranscriptStore, found Self`
  - Context: `transcripts: TranscriptStore::new()` inside `HttpServer::new`
  - **Proper fix:** when the receiver is an explicit named type, sema must ignore
    the surrounding impl `Self` and resolve the constructor on that named type.

#### H3c. Collection and field-access typing still loses element/field information in a few paths

- [ ] **std/bench.tg:262 — field access on locally returned structs still collapses upstream to `Unit`**
  - Error: `'/' requires numeric operands, found Unit and Float`
  - Context: `stats.mean_ns / 1_000_000_000.0`
  - **Proper fix:** preserve the nominal return type of `compute_statistics(&cleaned)` so
    field reads like `stats.mean_ns` remain `Float`.

- [ ] **std/device.tg:88 — loop variable element typing still loses struct fields or enum payload type**
  - Error: `argument type mismatch for '_device_class_eq': expected &DeviceClass, found &Unit`
  - Context: `_device_class_eq(&dev.class, &cls)` inside `for dev in devices`
  - **Proper fix:** ensure `for`-loop element binding over `Vec[Device]` yields
    `Device`, and that field access on the bound element retains `DeviceClass`.

- [ ] **std/gfx.tg:531 — integer helper method typing is incomplete**
  - Error: `'/' requires numeric operands, found Int and Unit`
  - Context: denominator comes from `(dst.w as Int).max(1)` / `(dst.h as Int).max(1)`
  - **Proper fix:** add the missing integer numeric helper methods (`min`, `max`,
    `clamp`, and any peers used in `std/`) to the intrinsic method tables.

- [ ] **std/msgpack.tg:412 — cross-module helper call still collapses before reaching a well-typed argument**
  - Error: `argument type mismatch for 'std::cbor::_f32_bits_to_float': expected UInt, found Unit`
  - Context: `_f32_bits_to_float(bits)` where `bits` comes from `self._read_u32()?`
  - **Proper fix:** preserve the `Result[UInt, ...]` / `?` value type through this
    call chain; do not patch the callee signature to accept `Unit`.

- [ ] **std/semver.tg:135 — element access on `Vec[PreRelease]` still degrades in reference position**
  - Error: `argument type mismatch for '_cmp_pre': expected &PreRelease, found &Unit`
  - Context: `_cmp_pre(&self.pre[i], &other.pre[i])`
  - **Proper fix:** make indexing on vectors return the element type for scalar
    indices in both owned and borrowed/reference contexts.

- [ ] **std/serde.tg:168 — `Vec.get` contract is currently inconsistent across stage0 and `std/`**
  - Error: `function 'value_index' expected return type Option[&Value], found Unit`
  - Context: `when Value::Array(arr) then arr.get(idx)`
  - **Proper fix:** settle the language contract. If `get` is the safe accessor,
    it must return `Option[&T]`; panicking access belongs to indexing. Then align
    stage0 intrinsics and all call sites to that contract.

- [ ] **std/sync.tg:71 — generic type argument inference from struct literal fields is still incomplete**
  - Error: `could not infer type parameter 'T' for struct literal 'Mutex'`
  - Context: `Mutex { inner: mutex_new(value) }`
  - **Proper fix:** infer generic arguments for struct literals from field
    initializers, exactly as function-call inference already does.

#### H3d. String / char / pointer helper coverage is still incomplete

- [ ] **std/compress.tg:189 — pointer view helpers on byte buffers still collapse to `Unit` in FFI calls**
  - Error: `argument type mismatch for 'compress2': expected &u8, found Unit`
  - Context: `data.as_ptr()` / `output.as_mut_ptr()` in zlib call setup
  - **Proper fix:** add or repair the actual pointer-view methods for byte buffers
    (`as_ptr`, `as_mut_ptr`) in stage0 sema so FFI wrappers type-check without
    source-level contortions.

- [ ] **std/env.tg:41 — C-string pointer extraction still collapses before FFI call sites**
  - Error: `argument type mismatch for 'getenv': expected &u8, found Unit`
  - Context: `getenv(cs.as_ptr())` after `name.to_cstr()`
  - **Proper fix:** ensure the `CString` / C-string wrapper methods are visible to
    sema and return the real pointer type consumed by the extern signature.

- [ ] **std/locale.tg:72 — `String.find` needs a `Char` overload**
  - Error: `method argument type mismatch: expected String, found Char`
  - Context: `v.find('.')`
  - **Proper fix:** support both substring and single-character search in the
    string intrinsic/model layer; this usage is common and idiomatic.

- [ ] **std/url.tg:189 — same `String.find(Char)` gap**
  - Error: `method argument type mismatch: expected String, found Char`
  - Context: `authority.find('@')`
  - **Proper fix:** same overload repair as `std/locale.tg`.

- [ ] **std/yaml.tg:755 — same `String.contains(Char)` gap**
  - Error: `method argument type mismatch: expected String, found Char`
  - Context: `s.contains(':')`, `s.contains('#')`, etc.
  - **Proper fix:** support `contains(Char)` alongside `contains(&str)`.

- [ ] **std/net.tg:387 — networking FFI/pointer helper path still collapses to a scalar**
  - Error: `argument type mismatch: expected &TcpStream, found Int`
  - **Proper fix:** repair the upstream receiver/path typing so methods operating
    on `TcpStream` do not degrade to raw file-descriptor arithmetic in sema.

#### H3e. Numeric and time helper modeling still needs more real signatures

- [ ] **std/anim.tg:95 — animation progress math still mixes float and integer semantics incorrectly**
  - Error: `argument type mismatch for 'ease': expected f32, found Int`
  - Context: `let t = e.elapsed_ms / e.duration_ms; ease(e.easing, t)`
  - **Proper fix:** make the source and the type model agree on float progress.
    If the fields are float-like, preserve them as such; if they are integer
    counters, cast explicitly at the division site.

- [ ] **std/auth.tg:111 — `Duration.as_secs()` / `SystemTime.as_unix_secs()` are still not modeled cleanly through sema**
  - Error: `'+' requires Int, Float, or String operands of the same type, found Unit and u64`
  - Context: `now + dur.as_secs()`
  - **Proper fix:** add the real time-method signatures used by `std/auth` and
    normalize integer/time arithmetic types rather than coercing the result later.

- [ ] **std/bench.tg:262 — throughput math is downstream of a collapsed struct field**
  - Error: `'/' requires numeric operands, found Unit and Float`
  - **Proper fix:** same as `stats.mean_ns` above; the arithmetic is fine.

- [ ] **std/geom.tg:517 — one geometry constructor still feeds integer literals into `f32` fields**
  - Error: `struct field 'w' expected f32, found Int`
  - **Proper fix:** use `f32` literals or explicit conversion at the constructor
    site. This is a real source-level numeric mismatch.

- [ ] **std/perf.tg:26 — downstream arithmetic failure caused by missing receiver methods**
  - Error: `'/' requires numeric operands, found Unit and Float`
  - **Proper fix:** fix the receiver-bearing method declarations first; do not
    patch the arithmetic itself.

#### H3f. Remaining API-shape mismatches that should be corrected at the real boundary

- [ ] **std/test_gen.tg:468 — map lookup uses the wrong key passing convention**
  - Error: `method argument type mismatch: expected &Unit, found Int`
  - Context: `by_kind.get(kind_name).unwrap_or(0)`
  - **Proper fix:** align the call with the real `Map.get(&K)` contract and keep
    the fallback typed as the map's value type.

- [ ] **std/web_server.tg:129 — constructor/static call resolution still confused by surrounding impl `Self`**
  - Error: `struct field 'transcripts' expected TranscriptStore, found Self`
  - **Proper fix:** same named-type static call repair described above.

- [ ] **std/wasm.tg:216 — `Self.from_bytes` still not recognized as a real typed call**
  - Error: `function 'from_file' expected return type Result[WasmModule, WasmError], found Unit`
  - **Proper fix:** same `Self` static dispatch repair described above.

### H4. 2026-03-16 Refresh: Current 62 `std/` Blocks

The earlier `H2` / `H3` split is now stale. The latest direct scan is:

- `supported=43 unsupported=62`

The 62 remaining `std/` failures break down into 16 parser blockers and 46
semantic / source-shape blockers. Every file in the current scan is accounted
for exactly once below. The point of this section is not to preserve the current
messages; it is to capture the real fix location for each remaining block.

#### H4a. Residual parser blockers still left in stage0 (16)

- [ ] **std/gfx_gpu.tg:380 — item-list parsing still misclassifies `const` at this site**
  - Error: `expected function keyword, found KeywordConst`
  - Root cause: the current item parser still falls back to "method expected"
    in one remaining item-list path after annotations/newlines.
  - **Proper fix:** complete the parser-side item dispatcher so `const` items are
    accepted anywhere the Tangerine grammar permits them inside module / impl /
    extern item lists; only normalize source if the concrete item is actually
    malformed.
  - Fix scope: `stage0_rs` parser.

- [ ] **std/gpu.tg:1125 — brace/body completion still loses one expression boundary**
  - Error: `unexpected expression token: RBrace`
  - Root cause: a nested block / match / inline-control-flow body is being
    parsed as though another expression must follow, so the closing brace is
    consumed as the start of the next expression.
  - **Proper fix:** finish the remaining brace-body termination repair so a
    complete expression body can end immediately before `}` without demanding a
    synthetic separator.
  - Fix scope: `stage0_rs` parser.

- [ ] **std/i18n.tg:492 — nested declaration/end-balance still falls out of sync**
  - Error: `expected KeywordEnd, found Ident("LineBreakOpportunity")`
  - Root cause: the parser is still dropping one `end` balance in this nested
    type/member region and resumes as though the next identifier were a fresh
    top-level item.
  - **Proper fix:** make nested type/member parsing keep strict `end` balance in
    enum / impl / module sub-bodies instead of recovering early.
  - Fix scope: `stage0_rs` parser.

- [ ] **std/log.tg:747 — multiline expression continuation is still not preserved here**
  - Error: `expected statement separator or branch terminator`
  - Root cause: a logically-continuous multiline expression is still being cut
    at a newline before its body / constructor / continuation finishes.
  - **Proper fix:** finish the remaining statement-continuation work so newline
    does not terminate an expression when the following tokens clearly continue
    the same expression.
  - Fix scope: `stage0_rs` parser.

- [ ] **std/mmap.tg:630 — same remaining multiline continuation gap as `std/log.tg`**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** same continuation repair; do not paper over this by forcing
    ad hoc semicolons into std unless the source is genuinely ambiguous.
  - Fix scope: `stage0_rs` parser.

- [ ] **std/opentelemetry.tg:377 — same remaining multiline continuation gap as `std/log.tg`**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** same continuation repair in the parser's block-expression
    boundary rules.
  - Fix scope: `stage0_rs` parser.

- [ ] **std/profile.tg:264 — same remaining multiline continuation gap as `std/log.tg`**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** same parser continuation repair.
  - Fix scope: `stage0_rs` parser.

- [ ] **std/random.tg:91 — compact contract / statement-boundary form still not fully accepted**
  - Error: `expected statement separator or branch terminator`
  - Root cause: this compact function-body form is still being split into two
    statements too early.
  - **Proper fix:** finish parser support for compact contract / clause / inline
    control-flow bodies so they count as complete statements without extra
    separators.
  - Fix scope: `stage0_rs` parser.

- [ ] **std/simd.tg:140 — macro / inline-asm style expression still fails the statement boundary rules**
  - Error: `expected statement separator or branch terminator`
  - Root cause: this expression form is parsed, but not yet accepted as a
    complete statement/tail in its current position.
  - **Proper fix:** let macro / asm expression bodies satisfy the same
    statement-completion rules as ordinary calls/blocks.
  - Fix scope: `stage0_rs` parser.

- [ ] **std/snapshot.tg:1197 — nested match/body separator tracking still drops one boundary**
  - Error: `expected statement separator or branch terminator`
  - Root cause: one remaining match-arm/body path still loses its separator
    state after nested control flow.
  - **Proper fix:** unify brace and non-brace match-arm separator handling so
    nested bodies cannot fall through into the outer statement parser.
  - Fix scope: `stage0_rs` parser.

- [ ] **std/thread.tg:597 — newline-sensitive expression body still breaks mid-expression**
  - Error: `unexpected expression token: Newline`
  - Root cause: the parser still treats this newline as hard termination even
    though the preceding tokens leave the expression incomplete.
  - **Proper fix:** extend continuation heuristics for operator / call / closure
    bodies so incomplete expressions survive across the newline.
  - Fix scope: `stage0_rs` parser.

- [ ] **std/toml.tg:491 — same remaining multiline continuation gap as `std/log.tg`**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** same continuation repair in block-expression parsing.
  - Fix scope: `stage0_rs` parser.

- [ ] **std/ui.tg:39 — compact constructor/helper body still terminates too early**
  - Error: `expected statement separator or branch terminator`
  - Root cause: this small helper still relies on a compact expression form the
    bootstrap parser is not treating as a complete body.
  - **Proper fix:** same continuation repair; only rewrite the helper source if
    it remains ambiguous after the parser accepts the intended grammar.
  - Fix scope: `stage0_rs` parser, possibly small std normalization after.

- [ ] **std/validation.tg:403 — parser still confuses a following member/identifier with a new method item**
  - Error: `expected function keyword, found Ident("_validators")`
  - Root cause: one preceding member/method body is still not being closed in a
    way that leaves the parser in the correct item-list state.
  - **Proper fix:** finish member/body boundary handling in item lists; then fix
    the std source only if this region is genuinely malformed.
  - Fix scope: `stage0_rs` parser, possibly std source.

- [ ] **std/wasm_js.tg:271 — same remaining multiline continuation gap as `std/log.tg`**
  - Error: `expected statement separator or branch terminator`
  - **Proper fix:** same parser continuation repair.
  - Fix scope: `stage0_rs` parser.

- [ ] **std/web_ext.tg:175 — `..` is still not accepted in this expression context**
  - Error: `expected identifier, found DotDot`
  - Root cause: the remaining spread / range token path for this context still
    insists on a plain identifier.
  - **Proper fix:** add `..` support to the relevant expression/pattern form
    instead of forcing the source to encode the same semantics indirectly.
  - Fix scope: `stage0_rs` parser.

#### H4b. Function/block tail typing still collapses real return values to `Unit` (17)

- [ ] **std/app.tg:307 — declared `Unit`, body still leaves an `Option[Int]` tail live**
  - Error: `function 'cancel_timer' expected return type Unit, found Option[Int]`
  - Root cause: this API contract is still inconsistent between the source body
    and the declared return type.
  - **Proper fix:** make the source explicit: either return the `Option[Int]`
    honestly or discard it and end the function with `()`.
  - Fix scope: std source.

- [ ] **std/backtrace.tg:751 — never-returning path still degrades to `Unit`**
  - Error: `function 'panic_with_backtrace' expected return type Never, found Unit`
  - Root cause: sema still does not preserve `Never` through this panic/abort
    control-flow path.
  - **Proper fix:** propagate `Never` through blocks whose only exits are panic /
    abort / return-never paths instead of unifying them to `Unit`.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/bench.tg:262 — arithmetic is downstream of a tail value that already collapsed to `Unit`**
  - Error: `'/' requires numeric operands, found Unit and Float`
  - **Proper fix:** repair tail-expression propagation in the upstream block;
    the division itself is not the real bug.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/debug.tg:118 — tuple-returning helper still loses its non-first tail value**
  - Error: `function 'timed' expected return type (T, Float), found (T, Unit)`
  - **Proper fix:** preserve tuple tail expressions through the timing block and
    keep receiver method calls typed all the way to the final tuple.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/diagnostics.tg:169 — final rendered string still collapses to `Unit`**
  - Error: `function 'capability_list' expected return type String, found Unit`
  - **Proper fix:** keep the final expression of the block/match as the
    function's return value instead of defaulting to `Unit` after statement
    checking succeeds.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/embedded.tg:93 — generic `volatile_read` wrapper still loses its typed tail through the unsafe body**
  - Error: `function 'volatile_read' expected return type T, found Unit`
  - **Proper fix:** preserve typed tails through `unsafe` blocks and intrinsic /
    extern wrappers rather than collapsing them to `Unit`.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/float_control.tg:40 — match-expression return still collapses to `Unit`**
  - Error: `function 'get_rounding_mode' expected return type RoundingMode, found Unit`
  - **Proper fix:** keep match-arm expression results unified as the block tail
    when all arms produce a concrete type.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/gfx.tg:621 — color-producing helper still loses its final branch value**
  - Error: `return type mismatch: expected Color, found Unit`
  - **Proper fix:** preserve final branch/tail expressions from nested `if` /
    match bodies instead of treating the whole helper body as statement-only.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/io.tg:117 — `print` still leaks the raw syscall result instead of an explicit `Unit` tail**
  - Error: `function 'print' expected return type Unit, found Int`
  - **Proper fix:** discard the syscall return explicitly in the source and end
    the function with `()`; this is a real API-shape cleanup, not a type-system
    feature.
  - Fix scope: std source.

- [ ] **std/json.tg:334 — `Result`-producing parse path still collapses to `Unit`**
  - Error: `function 'parse_string' expected return type Result[Value, JsonError], found Unit`
  - **Proper fix:** preserve the final `match` / `Result` expression as the
    function tail; do not drop it after type-checking the arms.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/linalg.tg:327 — `to_simd` still loses the final vector construction/value expression**
  - Error: `function 'to_simd' expected return type f32x4, found Unit`
  - **Proper fix:** same tail-expression preservation as `std/json.tg`; the
    final vector expression must survive block typing.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/path.tg:18 — enum/static value selection still degrades to `Unit` at return position**
  - Error: `function 'native_separator' expected return type PathSeparator, found Unit`
  - **Proper fix:** keep enum-associated value access typed all the way through
    the final return path rather than falling back to `Unit`.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/perf.tg:25 — final numeric expression still collapses to `Unit`**
  - Error: `function 'total_ms' expected return type f32, found Unit`
  - **Proper fix:** same tail-expression preservation as `std/json.tg`; do not
    patch the arithmetic while the enclosing block is still typed as `Unit`.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/semver.tg:156 — ordering-producing match still collapses to `Unit`**
  - Error: `function '_cmp_pre' expected return type Ordering, found Unit`
  - **Proper fix:** same match-arm result preservation as `std/float_control.tg`.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/serde.tg:168 — optional lookup helper still loses its final expression**
  - Error: `function 'value_index' expected return type Option[&Value], found Unit`
  - **Proper fix:** same tail-expression preservation as `std/json.tg`.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/web.tg:85 — web deserialization helper still loses its final `Result` expression**
  - Error: `function 'json' expected return type Result[T, WebError], found Unit`
  - **Proper fix:** same `match`/tail preservation as `std/json.tg`.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/web_server.tg:49 — function contract and builder-style tail still disagree**
  - Error: `function 'get' expected return type Unit, found &mut Router`
  - Root cause: the source still returns a fluent `&mut Router` chain into a
    function declared `Unit`.
  - **Proper fix:** choose the real API contract and encode it honestly in the
    source: either declare `-> &mut Router` or discard the builder return and
    end with `()`.
  - Fix scope: std source.

#### H4c. Generic/container inference and collection-shape recovery still has holes (8)

- [ ] **std/audit.tg:75 — concrete element type still does not bind back into the generic helper path**
  - Error: `method argument type mismatch: expected T, found AuditFinding`
  - **Proper fix:** propagate concrete type arguments through the container /
    helper call chain instead of leaving the callee parameter as an unbound `T`.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/collections.tg:213 — source is still feeding the wrong container shape into `entries`**
  - Error: `struct field 'entries' expected Vec[(K, V)], found Map[K, V]`
  - Root cause: this is not an inference problem; it is a real source-level
    shape mismatch.
  - **Proper fix:** pass the actual entries vector / iterator materialization
    expected by the field instead of the raw map object.
  - Fix scope: std source.

- [ ] **std/ctx.tg:100 — same unbound-generic call path as `std/audit.tg`**
  - Error: `method argument type mismatch: expected T, found StdCtxItem`
  - **Proper fix:** same generic forwarding repair as `std/audit.tg`.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/device.tg:75 — same unbound-generic call path as `std/audit.tg`**
  - Error: `method argument type mismatch: expected T, found Device`
  - **Proper fix:** same generic forwarding repair as `std/audit.tg`.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/encoding.tg:64 — byte element type still degrades to a generic placeholder in this helper path**
  - Error: `method argument type mismatch: expected T, found u8`
  - **Proper fix:** preserve concrete element types from byte containers and
    indexes instead of defaulting back to a placeholder `T`.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/migrate.tg:74 — same unbound-generic call path as `std/audit.tg`**
  - Error: `method argument type mismatch: expected T, found Migration`
  - **Proper fix:** same generic forwarding repair as `std/audit.tg`.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/sync.tg:71 — struct literal inference still cannot recover `Mutex[T]` from its field/value types**
  - Error: `could not infer type parameter 'T' for struct literal 'Mutex'`
  - **Proper fix:** infer bare generic struct literal type arguments from the
    field/value types supplied at the literal site.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/test_gen.tg:468 — map key/value inference still collapses through `Map.get` on this late-inferred map**
  - Error: `method argument type mismatch: expected &Unit, found Int`
  - **Proper fix:** preserve `Map[K, V]` key/value inference through empty-map
    creation and later `get(&K)` calls instead of leaving the key type as `Unit`.
  - Fix scope: `stage0_rs` sema.

#### H4d. Pointer/ref/FFI boundary typing is still losing concrete pointee types (8)

- [ ] **std/async.tg:252 — event buffer/reference still collapses to `&mut Unit` at the FFI boundary**
  - Error: `argument type mismatch for 'kevent': expected &mut Kevent, found &mut Unit`
  - **Proper fix:** preserve concrete pointee types through zero-init / buffer /
    mutable-borrow paths instead of degrading them to `Unit` before the extern call.
  - Fix scope: `stage0_rs` sema.

- [ ] **std/compress.tg:187 — pointer-view helper still erases the element type**
  - Error: `argument type mismatch for 'compress2': expected &mut u8, found Ptr[Unit]`
  - **Proper fix:** make `as_ptr` / `as_mut_ptr` preserve the backing element
    type all the way to the FFI signature.
  - Fix scope: `stage0_rs` sema/model.

- [ ] **std/env.tg:41 — c-string / getenv boundary still collapses to `Unit`**
  - Error: `argument type mismatch for 'getenv': expected &u8, found Unit`
  - **Proper fix:** keep `CString`/byte-pointer helpers typed as byte pointers,
    not `Unit`, through the extern call path.
  - Fix scope: `stage0_rs` sema/model.

- [ ] **std/ffi.tg:62 — raw-pointer dereference still stops one layer too early**
  - Error: `function 'deref' expected return type &T, found &Ptr[T]`
  - **Proper fix:** make unary/raw dereference on `Ptr[T]` yield the real pointee
    type instead of another pointer wrapper.
  - Fix scope: `stage0_rs` sema/model.

- [ ] **std/fs.tg:910 — pointer/null comparison still is not modeled as a real pointer comparison**
  - Error: `equality comparison requires matching types, found Ptr[u8] and Int`
  - **Proper fix:** add explicit pointer-null comparison support in sema, or
    normalize the source to compare against a typed null helper instead of raw `0`.
  - Fix scope: `stage0_rs` sema, possibly std source normalization.

- [ ] **std/msgpack.tg:412 — numeric helper call still receives `Unit` because the upstream bit/buffer path lost its concrete type**
  - Error: `argument type mismatch for 'std::cbor::_f32_bits_to_float': expected UInt, found Unit`
  - **Proper fix:** keep the upstream integer/bit-buffer expression typed as
    `UInt` instead of collapsing to `Unit` before the helper call.
  - Fix scope: `stage0_rs` sema/model.

- [ ] **std/net.tg:387 — receiver typing still collapses a socket wrapper to its raw scalar internals**
  - Error: `argument type mismatch: expected &TcpStream, found Int`
  - **Proper fix:** preserve wrapper nominal types through receiver/field paths
    instead of degrading them to the underlying descriptor scalar.
  - Fix scope: `stage0_rs` sema/model.

- [ ] **std/wasm.tg:219 — borrowed byte slice still collapses to `&Unit` on the loader path**
  - Error: `method argument type mismatch: expected &[u8], found &Unit`
  - **Proper fix:** preserve slice element types through borrowed container and
    helper-return paths instead of erasing them to `Unit`.
  - Fix scope: `stage0_rs` sema/model.

#### H4e. Primitive/helper signature gaps and scalar coercion mistakes remain (8)

- [ ] **std/alloc.tg:228 — source still relies on an invalid Bool→integer bitwise coercion**
  - Error: `bitwise operator requires integer operands, found UInt and Bool`
  - **Proper fix:** make the source explicit: branch or cast the Bool to an
    integer mask; do not teach the language an implicit Bool→integer coercion.
  - Fix scope: std source.

- [ ] **std/anim.tg:95 — progress math is still integer-typed when `ease` expects `f32`**
  - Error: `argument type mismatch for 'ease': expected f32, found Int`
  - **Proper fix:** cast/normalize the progress computation to `f32` at the
    source site, or fix the surrounding duration helpers if they are supposed to
    produce float progress already.
  - Fix scope: std source, possibly time-helper signature cleanup if upstream is wrong.

- [ ] **std/auth.tg:111 — one operand in the time/arithmetic path still collapses to `Unit`**
  - Error: `'+' requires Int, Float, or String operands of the same type, found Unit and u64`
  - **Proper fix:** add the real time-helper signatures used here and keep their
    numeric return types intact; if the source is concatenating unlike values,
    make the conversion explicit there.
  - Fix scope: `stage0_rs` sema/model, possibly std source normalization.

- [ ] **std/csv.tg:38 — local/field typing still treats the destination as `Unit` where a `Char` is written**
  - Error: `assignment type mismatch: expected Unit, found Char`
  - **Proper fix:** give the destination its real `Char` type at the source or
    preserve that declaration type through sema instead of defaulting it to `Unit`.
  - Fix scope: std source if declaration is underspecified; otherwise `stage0_rs` sema.

- [ ] **std/geom.tg:517 — numeric literal still feeds an `Int` into an `f32` field**
  - Error: `struct field 'w' expected f32, found Int`
  - **Proper fix:** use an `f32` literal or an explicit conversion at the
    constructor site. This is a real source-level numeric mismatch.
  - Fix scope: std source.

- [ ] **std/http.tg:262 — string helper still sees a `Char` where its current signature only accepts `String`**
  - Error: `method argument type mismatch: expected String, found Char`
  - **Proper fix:** add the real `Char` overload if this API is supposed to
    accept a character, otherwise normalize the source to pass a one-character string.
  - Fix scope: `stage0_rs` sema/model, possibly std source normalization.

- [ ] **std/regex.tg:175 — primitive `char` and `Char` are still not treated as the same scalar type**
  - Error: `equality comparison requires matching types, found char and Char`
  - **Proper fix:** unify bootstrap scalar modeling so lexer/parser `char` and
    std `Char` resolve to the same primitive type in sema.
  - Fix scope: `stage0_rs` sema/model.

- [ ] **std/url.tg:568 — same remaining Char-vs-String helper gap as `std/http.tg`**
  - Error: `method argument type mismatch: expected String, found Char`
  - **Proper fix:** same helper-overload/source-normalization repair as `std/http.tg`.
  - Fix scope: `stage0_rs` sema/model, possibly std source normalization.

#### H4f. Real mutability/global-shape source defects still left in `std/` (5)

- [ ] **std/config.tg:268 — global logger binding is still treated as immutable at the assignment site**
  - Error: `cannot assign to immutable variable 'GLOBAL_LOGGER'`
  - **Proper fix:** make the global declaration honestly mutable at the source
    boundary and keep that mutability through sema; do not rely on bootstrap leniency.
  - Fix scope: std source, with sema mutability preservation if needed.

- [ ] **std/image.tg:757 — loop/local variable `t` is still missing mutability**
  - Error: `cannot assign to immutable variable 't'`
  - **Proper fix:** declare `t` mutable where it is incremented/reassigned.
  - Fix scope: std source.

- [ ] **std/math.tg:46 — same global mutability issue as `std/config.tg`**
  - Error: `cannot assign to immutable variable 'GLOBAL_LOGGER'`
  - **Proper fix:** same source-level mutable-global cleanup as `std/config.tg`.
  - Fix scope: std source, with sema mutability preservation if needed.

- [ ] **std/text.tg:410 — loop/index variable `line_idx` is still missing mutability**
  - Error: `cannot assign to immutable variable 'line_idx'`
  - **Proper fix:** declare `line_idx` mutable where it is reassigned.
  - Fix scope: std source.

- [ ] **std/ui_toolkit.tg:226 — loop counter `i` is still missing mutability**
  - Error: `cannot assign to immutable variable 'i'`
  - **Proper fix:** declare `i` mutable where it is incremented/reassigned.
  - Fix scope: std source.

### H5. Recommended Execution Order For Section H

The most leverage comes from fixing the remaining stage0 model gaps before doing
large source sweeps:

1. **Parser:** item modifiers (`unsafe def`, `const def`, `inline def`), nested
   generics/trait objects, range slicing, `=>` match arms, local externs, and
   the remaining statement-boundary bugs.
2. **Sema:** borrowed-container indexing, explicit named-type static dispatch,
   `Self` equivalence inside impls and function types, intrinsic-body functions,
   `@cfg` tail-expression preservation, `join`, string `find/contains(Char)`,
   integer helpers (`min`/`max`), pointer-view helpers, and generic inference for
   struct literals.
3. **API contract cleanup:** decide and enforce the real `Vec.get` contract.
4. **Source repairs only after the above:** mutability fixes, missing `self`,
   explicit float literals/casts, honest handling of fallible FFI return codes,
   and borrowed-key call-site normalization.

### H6. Remaining self-host build blockers (2026-03-17)

These are the blockers still preventing `./stage0_rs/target/release/stage0_rs build-bin tg_compiler build/tg_selfhost`
from producing a working independent compiler after the parse, const-lowering,
and declaration-body fixes already landed. This section is limited to blockers
that are still active in the current build.

- [ ] **Imported-module codegen is still body-blind**
  - `stage0_rs/src/driver.rs:417-460` and `stage0_rs/src/driver.rs:790-875` build support state from imported modules, then discard those module AST bodies before codegen.
  - `stage0_rs/src/codegen/mod.rs:1039-1088` reconstructs support code only from `SemanticEnv`, so imported helper function bodies, impl method bodies, nested declarations, and initializer expressions are unavailable when the Rust backend tries to emit support code.
  - Current symptom: the generated Rust includes imported std / tg_compiler APIs whose bodies depend on additional helpers, but those helper bodies never get emitted, producing the large unresolved symbol set in the self-host build.
  - **Proper fix:** Preserve an imported module graph through codegen and compute a transitive reachable-declaration closure from real AST bodies, not from signatures alone. Emit every reachable function body, impl method body, const/global initializer, and nested declaration required by the selected support items.

- [ ] **Imported `extern` declarations are still erased into plain signatures**
  - `stage0_rs/src/sema/env.rs:404-410` inserts imported `Decl::Extern` items into `env.functions` as plain `FunctionSig`s, discarding ABI and extern-block structure.
  - `stage0_rs/src/codegen/mod.rs:528-543` can emit extern blocks, but only for `Decl::Extern` nodes present in the root module AST.
  - `stage0_rs/src/codegen/mod.rs:663-673` and `stage0_rs/src/codegen/mod.rs:814-826` treat imported extern functions as ordinary support functions, so imported libc / pthread / platform declarations are never re-emitted as Rust `extern` blocks.
  - Current symptom: generated Rust calls `closedir`, `realpath`, `pthread_mutex_init`, `pthread_key_create`, and similar imported functions without corresponding Rust `extern "C"` declarations.
  - **Proper fix:** Preserve imported `Decl::Extern` as first-class support declarations, including ABI strings and grouping. Support emission must emit those imported extern blocks verbatim into generated Rust before any body that references them.

- [ ] **The runtime/intrinsic surface is still incomplete after support emission**
  - Examples visible in the current failing build:
    - `std/json.tg:835` — `base64_encode(...)`
    - `std/supply_chain.tg:208-210` — `toml_parse(...)`
    - `std/core.tg:106` — `__intrinsic_string_len(...)`
    - `std/gpu.tg:99-104` — `_backend_create_instance(...)`, `_backend_enumerate_adapters(...)`, and the rest of the `_backend_*` family
    - `std/fuzz.tg:77-82` — `__intrinsic_fuzz_add_to_corpus(...)`, `__intrinsic_fuzz_next_input(...)`
  - Current symptom: even with correct support-body emission, the build will still fail for symbols that are neither defined in TG source nor provided by a linked runtime/object library.
  - **Proper fix:** Split this surface explicitly and implement each layer correctly:
    - standard-library APIs such as `base64_encode` and `toml_parse`: add real TG implementations in the owning std modules;
    - compiler/runtime intrinsics such as `__intrinsic_string_len` and the `__intrinsic_*` families: add explicit lowering in `stage0_rs` or link a real Tangerine runtime per target;
    - subsystem/backend shims such as `_backend_*`, `_spirv_*`, fuzz, replay, SQL, tensor, and WASM hooks: provide target libraries with stable ABIs and include them during link.

- [ ] **Shared string-to-bytes lowering is still generating invalid Rust across architectures**
  - Generated Rust currently contains invalid calls such as:
    - `build/tg_selfhost.rs:33947` — `self.writer.write_all(b("\n".to_string()));`
    - `build/tg_selfhost.rs:56788-56916` — `b("IHDR".to_string())`, `b("IDAT".to_string())`, `b("IEND".to_string())`
  - The corresponding TG source uses ordinary strings, e.g. `std/image.tg:319-326`, so `b(...)` is not a source-level helper.
  - `stage0_rs/src/codegen/mod.rs:2259-2661` remains too type-blind in string/array contexts and has no first-class byte-string coercion model.
  - Current symptom: Rust compilation fails with `cannot find function 'b' in this scope`.
  - **Proper fix:** Add type-aware lowering for string-to-byte contexts. When the expected Rust type is `&[u8]`, `Vec<u8>`, or a fixed byte array, lower TG string/byte data explicitly to `.as_bytes()`, `b"..."`, or `vec![...]` as appropriate. Do not synthesize helper calls. Add regression tests covering logging, file I/O, PNG chunk tags, and other `&[u8]` APIs.

- [ ] **AArch64 backend parity is still incomplete**
  - `tg_compiler/codegen.tg:1153` — `emit_pop()` on `Arch::AArch64` calls `a64_ldr_post(&mut ctx.text, ar, A64::SP, 16)`.
  - `tg_compiler/asm.tg:1000-1065` has `a64_blr`, `a64_ret`, `a64_stp_pre`, `a64_ldp_post`, and related helpers, but no `a64_ldr_post` implementation.
  - Current symptom: the generated Rust fails with `cannot find function 'a64_ldr_post' in this scope` when the self-host compiler lowers the ARM64 native backend.
  - **Proper fix:** Complete the ARM64 helper surface in `tg_compiler/asm.tg` and keep it in parity with the x86_64 helper surface. Add a real `a64_ldr_post` implementation for single-register post-index loads, import it into `tg_compiler/codegen.tg`, and add parity tests for prologue/epilogue, push/pop, frame teardown, and spill/reload sequences on AArch64.

- [ ] **Architecture coverage is still incomplete beyond x86_64 and AArch64**
  - `tg_compiler/asm.tg:1322-1335` — `Arch` currently contains only `X86_64` and `AArch64`.
  - `tg_compiler/object.tg:293-294` and `tg_compiler/object.tg:730-731` specialize object emission to those same two architectures.
  - Current implication:
    - `x86_64`: no active instruction-helper hole is exposed by the current failing build, but it is still blocked by the shared support/import/runtime issues above.
    - `AArch64`: blocked by the same shared issues plus the missing `a64_ldr_post` parity gap.
    - Any additional native architecture is not implemented end-to-end at all.
  - **Proper fix:** Treat architecture support as an end-to-end contract. For every claimed architecture, implement and test instruction selection, asm helpers, relocations/object emission, linker/startup/runtime bindings, intrinsic lowering, and platform `@cfg` filtering. For architectures beyond x86_64 and AArch64, add first-class backends instead of routing through placeholder paths.

#### H6.1 Frontmost self-host stop blockers after the 2026-03-17 nested-declaration and macro-call fixes

These are the blockers exposed by the latest real self-host attempt after the
`Stmt::Decl` lowering fix and the `asm!`/macro-name normalization fix landed.
They are the current first-order reasons `build-bin tg_compiler build/tg_selfhost`
still fails. Once these are fixed, the earlier H6 bullets above are still
expected to matter, but they are not the frontmost stop surface right now.

- [ ] **Type-qualified methods are still emitted as free functions instead of associated methods**
  - Latest symptom from `/tmp/tg_selfhost_build.log`:
    - ``self parameter is only allowed in associated functions`` for generated Rust methods such as:
      - `matches`, `parse_bool`, `parse_null`, `parse_number`
      - `has_binding`, `has_uses_after`, `scopes_containing`
  - Concrete source patterns currently triggering it:
    - `std/json.tg:426-555` keeps `parse_number`, `parse_bool`, `parse_null`, and `matches` inside `impl JsonParser`, but they are written in Tangerine as ordinary method declarations with `self` parameters and later appear in generated Rust as top-level `pub fn ...(&mut self, ...)`.
    - `tg_compiler/resolver.tg:298-320` defines `scopes_containing`, `has_binding`, and `has_uses_after` as free declarations with receiver syntax, and those also become top-level Rust functions with `self` parameters.
  - Strongly indicated stage0 cause:
    - `stage0_rs/src/parser/mod.rs:945-1035` parses signatures generically and allows `self` parameters.
    - `stage0_rs/src/parser/mod.rs:2812-2819` treats `Type::method` names as plain qualified names.
    - `stage0_rs/src/codegen/mod.rs:281-304` then emits every `Decl::Function` as a free Rust function, regardless of whether the function name or receiver shape implies an associated method.
  - **Best fix:** Normalize receiver-style method declarations before Rust emission. The correct solution is to lower `def Type::method(...)` and any receiver-bearing function that semantically belongs to a type into `Decl::Impl` entries during parsing or an AST normalization pass, then emit them only through impl-item codegen. A weaker fallback in codegen alone would be to detect receiver-bearing `Decl::Function` names containing `::` and synthesize `impl Type { ... }`, but the real fix is to canonicalize the AST so sema, support closure, and codegen all agree on method ownership.

- [ ] **Imported/support externs are still emitted multiple times without symbol-level deduplication**
  - Latest symptom from `/tmp/tg_selfhost_build.log`:
    - duplicate Rust declaration of `getpid` in the same generated crate.
  - Current source evidence:
    - `std/process.tg:7-11` declares `getpid` in the top-level `extern "C"` process block.
    - `std/process.tg:613-621` declares `getpid` again in the process-group extern cluster.
    - `std/debug.tg:282-288` also declares `getpid` for the macOS debugger probe path.
    - `std/signal.tg:221` declares `getpid` again via FFI.
  - Latest generated symptom confirms stage0 is not coalescing repeated externs before emission.
  - **Best fix:** Preserve imported extern blocks as first-class support declarations, but deduplicate their members by ABI + symbol name + Rust signature + owning support module before final emission. The important point is not to drop extern provenance; it is to avoid re-emitting semantically identical libc bindings multiple times in the same generated Rust namespace. Add a regression that imports `std::process`, `std::debug`, and `std::signal` together and asserts only one `getpid` declaration is emitted per final Rust module.

- [ ] **Support-use rewriting still points at crate-root support modules that are never emitted**
  - Latest symptom from `/tmp/tg_selfhost_build.log`:
    - unresolved imports for `crate::thread::*`, `crate::net::*`, `crate::simd::*`, and `crate::async_::*`.
  - Latest generated Rust confirms the mismatch directly:
    - imports such as `use crate::thread::Mutex;`, `use crate::net::TcpStream;`, and `use crate::async_::Channel;` are present,
    - but the generated file contains no matching `pub mod thread`, `pub mod net`, `pub mod simd`, `pub mod async_`, or `pub mod lib` declarations at all.
  - Strongly indicated stage0 cause:
    - `stage0_rs/src/codegen/mod.rs:1193-1207` rewrites `std::...` support uses to `crate::...` paths.
    - `stage0_rs/src/codegen/mod.rs:1307-1314` can infer the target support module path from a rewritten use path.
    - But the current support-closure pipeline is still not forcing the imported target modules and their members into the emitted support tree consistently, so the `use` sites survive while the backing modules do not.
  - **Best fix:** Make rewritten support imports participate in the same transitive closure as ordinary referenced support declarations. Every emitted support `use crate::thread::Mutex` must enqueue both `thread` as a required module shell and `thread::Mutex` as a required reachable support declaration before final support emission. Keep `async`/`async_` name normalization in the same pipeline so rewritten imports and emitted module names are guaranteed to agree.

- [ ] **`tg_compiler::lib::*` imports are still being rewritten through the wrapper crate root in places where local module paths are required**
  - Latest symptom from `/tmp/tg_selfhost_build.log`:
    - unresolved import `crate::run_repl`.
  - Current source and generated evidence:
    - `tg_compiler/lib.tg:421` defines `pub def run_repl() -> Unit`.
    - The generated Rust still contains `use crate::run_repl;` in a nested module import cluster, while `run_repl` itself is emitted later from the generated Tangerine entry module.
  - Strongly indicated stage0 cause:
    - `stage0_rs/src/codegen/mod.rs:1193-1207` rewrites `tg_compiler::lib::...` directly to `crate::...`.
    - That rewrite assumes wrapper-root re-exports are a safe stand-in for local references inside the generated entry module, but the current self-host failure shows this assumption is still wrong for some imports.
  - **Best fix:** Stop routing same-generated-module references through wrapper-root `crate::...` paths. When a use/import resolves to the generated entry module itself, rewrite it to a module-local form (`self::run_repl`, `super::...`, or a bare in-module name, depending on scope) instead of relying on wrapper re-exports. Add a regression that compiles a generated module containing both a public root function and a nested module importing that function.

- [ ] **The latest rustc stop surface is now dominated by namespace/model mismatches rather than syntax lowering**
  - The important status change is that the recent fixes did move the build forward:
    - nested declarations are no longer the frontmost blocker,
    - duplicate `asm!!(...)` emission is no longer the frontmost blocker.
  - The remaining active stop surface is now concentrated in four real compiler/model gaps:
    - associated-method ownership,
    - extern deduplication,
    - support-module closure/emission,
    - local-vs-wrapper import rewriting.
  - **Best fix order:**
    1. Normalize receiver-style methods into impl ownership.
    2. Deduplicate imported externs during support emission.
    3. Make support-use rewriting drive target-module inclusion.
    4. Rewrite `tg_compiler::lib::*` self-imports to local module paths instead of wrapper-root paths.
  - After those land, rerun the real self-host build immediately and expect the older H6 items above to become the next visible blockers.

## I. Complete Self-Host Compilation Blocker Analysis (1,931 rustc Errors)

**Date:** 2025-07-14
**Build:** `./stage0_rs/target/release/stage0_rs build-bin tg_compiler build/tg_selfhost`
**Generated file:** 67,088 lines, 3.1 MB
**Total rustc errors:** 1,931

All errors cluster into **12 distinct root causes** in the codegen pipeline. Each needs a
proper fix in `stage0_rs/src/codegen/mod.rs` or `stage0_rs/src/parser/mod.rs`.
No source-file hacks.  No stubs.

---

### I.1  Missing `Ptr<T>` type alias (169 errors)

**Errors:** 134× E0425 + 35× E0433 (`cannot find type Ptr`)
**Root cause:** Tangerine defines `Ptr<T>` as its raw pointer type. The prelude
(`emit_prelude`) does not emit a corresponding Rust alias.

**Proper fix (codegen/mod.rs `emit_prelude`):**
Add `type Ptr<T> = *mut T;\n` to the prelude block, right after the existing
`type Array<T> = Vec<T>;` line. Also add the inverse: if the Tangerine source
uses `Nil` as a type, emit `type Nil = ();`.

---

### I.2  Methods missing `&self` parameter (40 errors)

**Errors:** 40× E0424 (`expected value, found module self`)
**Root cause:** `normalize_method_like_function` in parser/mod.rs handles two
cases for detecting methods:

1. **Qualified name** (`TypeName::method_name`) — the function is wrapped
   in an `ImplDecl` but NO `self` parameter is injected into its param list.
   The body continues to use `self.field`.
2. **Explicit self param** — works correctly.

Case 1 produces `impl Foo { fn bar() -> T { self.x } }` — rustc says
"expected value, found module `self`" because `self` is not a parameter.

**Affected methods (all in diagnostics module):** `CompositorDiag::dump`,
`ConsistencyReport::header`, `FilteredLogger::enable_all`,
`Logger::log`, `Logger::is_enabled`, `FirstFailureContext::dump_to_string`,
`FrameCapture::is_valid`, `FrameCapture::size_bytes`,
`RuntimeError::formatted`, `StartupDiagnostics::summary`,
`StartupDiagnostics::capability_list`.

**Proper fix (parser/mod.rs `normalize_method_like_function`):**
After identifying a qualified-name method (case 1), check whether the body
references `self`.  If it does, prepend a synthetic `self` parameter:
```rust
let has_self_param = method_decl.sig.params.first().is_some_and(|p| p.name == "self");
if !has_self_param && function_body_references_self(&method_decl.body) {
    method_decl.sig.params.insert(0, Param {
        name: "self".to_string(),
        mutable: false,
        ty: TypeRef::Ref {
            inner: Box::new(owner_type.clone()),
            mutable: false,
            span: function_decl.span,
        },
        span: function_decl.span,
    });
}
```
`function_body_references_self` can reuse the existing `expr_roots_in_self`
walk from codegen.

---

### I.3  Dot-call on types: `Vec.new()` instead of `Vec::new()` (92 errors)

**Errors:** 22× `Vec`, 19× `BigInt`, 13× `String`, 12× `Vec4`, 12× `Path`,
11× `Vec3`, 11× `List`, 6× `Quat`, 5× `Mat4`, + others (total 92 E0423)
**Root cause:** `emit_callee_expr` always renders `Expr::Field { base, field }`
as `base.field`.  When `base` is a type name (capitalized, no variable binding),
this should be `base::field` (associated function call syntax).

**Proper fix (codegen/mod.rs `emit_callee_expr`):**
When the base is an `Expr::Name` whose name looks like a type
(starts with uppercase, or is a known type like `Vec`/`String`/etc.),
emit `::` instead of `.`:
```rust
Expr::Field { base, field, .. } => {
    if is_type_name_expr(base) {
        Ok(format!("{}::{}", emit_expr(base, state)?, rust_identifier(field)))
    } else {
        Ok(format!("{}.{}", emit_expr(base, state)?, rust_identifier(field)))
    }
}
```
`is_type_name_expr` checks: name starts with uppercase, or is in a known
type set (`Vec`, `String`, `BigInt`, `Path`, `Mat4`, `Quat`, `Vec2`, `Vec3`,
`Vec4`, `Box`, `Mutex`, `Duration`, `SystemTime`, `CsvReader`, `CsvWriter`,
`Backtrace`, `TraceId`, `TraceFlags`, `SpanId`, `Resource`, `Version`,
`Requirement`, `TraceContextPropagator`, `Transform`).

---

### I.4  `pub mod core` conflicts with Rust's built-in `core` crate (25 errors)

**Errors:** 25× E0659 (`core is ambiguous`)
**Root cause:** Tangerine has `std/core.tg` which becomes `pub mod core { ... }`
in the generated Rust.  This shadows Rust's `core` crate, making
`pub use core::Clone;` etc. ambiguous.

**Proper fix (codegen/mod.rs `emit_support_module`):**
Rename the generated module: when the support module name is `"core"`, emit it
as `pub mod tg_core` instead.  Update `support_module_path()` and
`insert_support_item()` to map `core` → `tg_core` in module path segments.
Also update `qualify_generated_use_path` so that `super::core::X` becomes
`super::tg_core::X`.

---

### I.5  Empty support modules: `thread`, `async_`, `fmt` (11 E0432 import errors + cascading)

**Errors:** 3× `super::thread::Mutex`, 2× `super::thread::Ordering`,
2× `super::thread::AtomicInt`, 1× each for `RwLock`, `RwLockReadGuard`,
`RwLockWriteGuard`, `MutexGuard`, `super::async_::Channel`,
`super::async_::sleep`, `super::fmt::Formatter`, `super::ast::Contract`
**Root cause:** `ensure_support_module_path` creates child module nodes for
use-path targets, but doesn't populate them with items.  When `sync.tg` does
`use std::thread::{Mutex, ...}`, the `thread` module node is created (empty),
and then `sync` emits `pub use super::thread::Mutex;` which fails because
`thread` only has `use super::*;`.

**Proper fix (codegen/mod.rs `collect_support_modules`):**
When a use-path targets a module (`super::thread::Mutex`), check whether the
target module has actually been populated.  If not, pull in the referenced
items from that module via `collect_module_members` and insert them.
Specifically: after all top-level items are inserted, do a second pass over
all `use_paths` in every module node.  For each `super::X::Name` path, check
whether module `X` contains `Name`.  If not, look it up in the env and insert
it.  This ensures transitive dependencies are fully materialized.

---

### I.6  Duplicate struct definitions in `sync` module (7 E0428 errors)

**Errors:** 1× each: `AtomicInt`, `Channel`, `Mutex`, `MutexGuard`, `RwLock`,
`RwLockReadGuard`, `RwLockWriteGuard`
**Root cause:** `collect_support_modules` inserts items from both the
source-index (AST decls from `sync.tg` which re-declares wrappers) AND from
the env (which also has these types from `thread.tg`).  Both get inserted
into the `sync` module node, producing duplicates.

**Proper fix (codegen/mod.rs `collect_support_modules`):**
Before inserting an item into a module node, check for duplicates.
Add a `seen_items: OrderedSet<String>` per module that tracks the leaf
name of every struct/enum/trait inserted.  Skip re-insertion if already
present.  Also deduplicate at the `SupportModuleTree` level: add a
`deduplicate_items()` pass after construction that removes duplicates by
leaf name within each module node.

---

### I.7  `Display` trait impl has wrong signature (9 errors)

**Errors:** 6× E0050 (method `fmt` has 1 param, trait has 2),
3× E0407 (`to_string` is not a member of Display)
**Root cause:** Tangerine's `Display` trait has
`fn fmt(self) -> String` and `fn to_string(self) -> String`.
The codegen emits these verbatim into `impl std::fmt::Display`, but Rust's
Display trait requires `fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result`.

**Proper fix (codegen/mod.rs `emit_impl_decl`):**
When emitting an `impl` with `trait_name == "Display"`, rewrite:
- `fn fmt(&self) -> String` → `fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result { write!(f, "{}", { <original body> }) }`
- Drop `fn to_string(&self) -> String` from the impl block (Rust auto-generates it).

---

### I.8  Missing lifetime annotations on struct reference fields (31 errors)

**Errors:** 31× E0106 (`missing lifetime specifier`)
**Root cause:** `format_struct_field_type` renders `TypeRef::Ref` as `&T` or
`&mut T` without a lifetime.  Rust requires explicit lifetimes on struct
fields: `&'a T`.

**Proper fix (codegen/mod.rs `format_struct_field_type` + `gen_struct`):**
When a struct has any reference-typed field, add a `<'a>` lifetime param to
the struct declaration and render all `&T` fields as `&'a T`.  This
requires:
1. A pre-pass in `gen_struct` that checks whether any field type contains a
   `TypeRef::Ref`.
2. If so, append `<'a>` to the struct's type params.
3. Pass a `needs_lifetime: bool` flag into `format_struct_field_type` so
   `Ref` branches emit `&'a T` instead of `&T`.

---

### I.9  Generic type params out of scope: `T`, `K`, `V` (80 errors)

**Errors:** 54× `T`, 13× `K`, 13× `V`
**Root cause:** Support items (structs, functions) that are generic over `T`,
`K`, `V` are emitted into the support tree.  But their type params may
not carry over correctly.  For example, a `SummaryFunction` for
`fn foo<T>(x: T) -> T` emits `pub fn foo(x: T) -> T { unimplemented!() }`
without the `<T>` type param on the function.

**Proper fix (codegen/mod.rs `emit_support_function_summary` / `emit_support_struct`):**
When emitting support function summaries, extract type params from the
function signature.  Scan all parameter types and the return type for
single-letter uppercase names (`T`, `K`, `V`, `E`, etc.) that aren't known
types.  Emit them as generic params: `pub fn foo<T>(x: T) -> T`.
Similarly for support struct summaries.

---

### I.10  Missing support types: compiler-internal & platform types (~350 errors)

**Errors:** A large cluster of E0433/E0425 for types that exist in the env
but aren't included in the support tree:

| Count | Type | Source module |
|-------|------|--------------|
| 77 | `A64` | codegen (ARM64) |
| 39 | `MirTerminatorKind` | mir |
| 28 | `MirRvalueKind` | mir |
| 27 | `a64_code` (fn) | codegen |
| 24 | `OsError` | core / gfx_errors |
| 19 | `PatternKind` | ast |
| 18 | `PixelFormat` | gfx |
| 18 | `MirStatementKind` | mir |
| 18 | `MirOperandKind` | mir |
| 17 | `TomlError` | toml |
| 16 | `MirBinOp` | mir |
| 16 | `GuardElse` | ast |
| 15 | `Component` | ui |
| 14 | `BinOp` | ast |
| 12 | `AssertMessage` | ast |
| 10 | `X64` | codegen (x86-64) |
| + many more at counts 1–9 |

**Root cause:** `collect_transitive_support_references` walks the main module's
AST to find referenced types.  But it misses types that are only referenced
*indirectly* — e.g., enum variant payloads, match arm patterns, or types
used inside support items themselves.

**Proper fix (codegen/mod.rs `collect_transitive_support_references`):**
Extend the reference collection to also:
1. Walk the types of all *already-included* support items recursively —
   if a support struct has a field of type `MirTerminatorKind`, that type
   must also be included.
2. Walk enum variant payload types for all included enums.
3. Walk function parameter and return types for all included functions.
4. Iterate until a fixed point is reached (no new types added).

---

### I.11  Custom `Iterator<T>` trait shadows std (18 errors)

**Errors:** 18× E0107 (`missing generics for trait Iterator`)
**Root cause:** Tangerine's `collections` module defines
`pub trait Iterator<T>` with a generic param.  This shadows
`std::iter::Iterator` which uses associated types.  When code does
`impl Iterator for Foo`, rustc expects the generic param.

**Proper fix (codegen/mod.rs `emit_support_trait` or `skip_support_symbol`):**
Add `"Iterator"` to `skip_support_symbol` so the custom trait definition
isn't emitted.  The generated code should use `std::iter::Iterator` instead.
If Tangerine's Iterator trait has methods beyond what std provides, emit
them under a different name (e.g., `TgIterator`).  Also update
`emit_impl_decl`: when `trait_name == "Iterator"`, use `std::iter::Iterator`
and map the Tangerine method names to Rust's associated-type Iterator
interface (`type Item = T; fn next(&mut self) -> Option<Self::Item>`).

---

### I.12  Global/static variables not materialized (82 errors)

**Errors:** Scattered E0425 for global names:
16× `GLOBAL_LOGGER`, 14× `METRICS_LOCK`, 10× `_glyph_run_registry`,
9× `GLOBAL_METRICS`, 9× `_catch_frame_stack`, 8× `Z_OK`,
7× `LOGGER_LOCK`, 7× `f32x4`, 6× `_next_image_id`, 6× `_image_registry`,
5× `SPAN_STACK`, 5× `GLOBAL_PACK_REGISTRY`, 5× `AES_SBOX`, + many more

**Root cause:** `collect_transitive_support_references` collects functions,
structs, enums, and traits from the env.  But it doesn't collect
**globals** (`env.globals`) or **consts** (`env.consts`).  These are
`static mut` / `const` values that the main module references but which
live in support modules.

**Proper fix (codegen/mod.rs `collect_transitive_support_references`):**
Extend the reference collector to also check `env.globals` and `env.consts`
for names that appear in the main module's expressions.  When found,
include them via `insert_support_item` with `SummaryGlobal` or
`SummaryConst` items.  The existing `emit_support_global_decl` and
`emit_support_const_decl` will render them correctly.

---

### I.13  `Send`/`Sync` impls need `unsafe` (6 errors)

**Errors:** 3× E0200 (`Send requires unsafe impl`),
3× E0200 (`Sync requires unsafe impl`)
**Root cause:** Tangerine's `impl Send for X {}` / `impl Sync for X {}` get
emitted verbatim, but Rust requires `unsafe impl Send` / `unsafe impl Sync`.

**Proper fix (codegen/mod.rs `emit_impl_decl`):**
When `trait_name` is `"Send"` or `"Sync"`, prefix the impl with `unsafe`:
```rust
if matches!(impl_decl.trait_name.as_str(), "Send" | "Sync") {
    write!(out, "unsafe ").expect("...");
}
```

---

### I.14  `assert` used as function instead of macro (4 errors)

**Errors:** 4× E0423 (`expected function, found macro assert`)
**Root cause:** Some call sites emit `assert(expr)` instead of going through
`emit_named_call_expr`.  This happens when `assert` is called with more than
one argument in a pattern not matched by the named-call lowering.

**Proper fix (codegen/mod.rs `emit_named_call_expr`):**
Extend the `"assert"` arm to handle 2-argument form:
`("assert", [cond, msg])` → `assert!({cond}, "{}", {msg})`.
Also add `("assert", args)` as a catch-all that wraps in `assert!()`.

---

### I.15  `time`/`taint`/`borrow_check` used as function calls (6 errors)

**Errors:** 2× `expected function, found module time`,
2× `expected function, found module taint`,
2× `expected function, found module borrow_check`
**Root cause:** Expressions like `time(...)` or `taint(...)` are emitted as
function calls, but `time` / `taint` / `borrow_check` are module names in
the generated code.  These are likely module-qualified function calls that
lost their qualification.

**Proper fix:** Investigate each call site in the Tangerine source to
determine the intended function.  For `time(...)`, it may be
`time::instant_now()` or similar.  For `taint(...)` and `borrow_check(...)`,
they may be constructors or module path calls.  Fix the emit logic to
preserve full qualification.

---

### Fix Priority Order

The fixes should be implemented in this order to maximize error reduction
per change:

| Priority | Fix | Est. Errors Fixed |
|----------|-----|-------------------|
| 1 | I.10: Transitive support type inclusion (fixed-point) | ~350 |
| 2 | I.1: `Ptr<T>` type alias in prelude | ~169 |
| 3 | I.3: Dot→double-colon for associated fn calls | ~92 |
| 4 | I.12: Global/const variable materialization | ~82 |
| 5 | I.9: Generic type param inference for support items | ~80 |
| 6 | I.2: Inject `&self` for qualified-name methods | ~40 |
| 7 | I.8: Lifetime annotations on struct ref fields | ~31 |
| 8 | I.4: Rename `core` module to avoid conflict | ~25 |
| 9 | I.11: Skip/remap custom `Iterator<T>` trait | ~18 |
| 10 | I.5: Materialize items in empty support modules | ~11 |
| 11 | I.7: Rewrite `Display` impl to Rust signature | ~9 |
| 12 | I.6: Dedup support items within modules | ~7 |
| 13 | I.13: `unsafe impl Send/Sync` | ~6 |
| 14 | I.15: Module-name-as-function disambiguation | ~6 |
| 15 | I.14: `assert` macro catch-all | ~4 |

**Total coverage:** ~930 unique root-cause errors. The remaining ~1,000 are
cascading failures (rustc stops reporting after the first error in a scope,
so fixing root causes eliminates cascading errors too).  Expected residual
after all 15 fixes: <100 errors, down from 1,931.
