# Improvements Tracking

Progress on resolving all hack.md items for full self-hosting.

## A. stage0_rs Fixes

- [x] A1a. Supertrait method resolution
- [x] A1b. External method fallback signature removal
- [x] A1c. Module-qualified function call resolution
- [x] A1d. Remove Unit-as-wildcard for unresolved externals
- [x] A1e. Cast validation
- [x] A1f. Trait implementation verification
- [x] A1g. Named→String coercion — require Display/ToString
- [x] A1h. Mutability enforcement
- [x] A1i. Pattern type checking
- [x] A1j. Forward type reference validation
- [x] A1k. Bidirectional type inference
- [x] A1l. Generic placeholder type unification
- [x] A1m. Collection element type inference
- [x] A2a. External module support function codegen
- [x] A2b. Nested declaration lowering
- [x] A3. @cfg attribute evaluation

## B. tg_compiler Fixes

- [x] B1a. SSA conversion pointer-aliasing fix
- [x] B1b. Re-enable copy propagation
- [x] B2. NLL / escape analysis / drop-order verification
- [x] B3a. Test runner implementation
- [x] B3b. Bench command implementation
- [x] B3c. Remove bootstrap_copy_self_binary dead code
- [x] B3d. current_time() real implementation
- [x] B3e. Replace bootstrap_call_system with safe process API
- [x] B4a. Real SHA-256 implementation
- [x] B4b. Proper JSON serialization with escaping
- [x] B4c. Register allocator with spill/reload
- [x] B4d. Type::Named real size computation
- [x] B4e. WASM codegen MIR→WASM lowering
- [x] B4f. TOML parser proper implementation
- [x] B4g. Package manager download/extract
- [x] B4h. FFI bindgen proper C parser
- [x] B4i. Rationale block parser
- [x] B4j. Macro expansion complete
- [x] B4k. Closure captured variable resolution
- [x] B4l. MIR local type resolution

## C. std/ Fixes

- [x] C1a. set_panic_hook implementation
- [x] C1b. take_panic_hook implementation
- [x] C1c. catch_unwind implementation
- [x] C1d. try_invoke implementation
- [x] C1e. begin_unwind implementation
- [x] C1f. Thread-local storage
- [x] C2. Ed25519 scalar multiplication
- [x] C3a. WebSocket key generation
- [x] C3b. WebSocket frame mask randomization
- [x] C4a. DWARF v4/v5 line program decoding
- [x] C4b. Full PNG decoder
- [x] C4c. Image file I/O with FsCap
- [x] C4d. GPU-accelerated App rendering
- [x] C4e. Real device detection
- [x] C4f. Accessibility platform integration
- [x] C4g. Full Unicode Bidirectional Algorithm
- [x] C4h. Zero-copy process data transfer
- [x] C4i. Atomic temp file creation
- [x] C4j. Complete Fisher-Yates shuffle (already correct)
- [x] C4k. Full JSON Unicode support
- [x] C4l. Animation real current values
- [x] C5. Compiler intrinsics implementation
  - I/O: Stdout/Stderr/Stdin use POSIX fd 0/1/2 via syscall3
  - Environment: libc FFI (getenv/setenv/unsetenv/getcwd/readlink)
  - Unicode: pure Tangerine implementations for all 16 functions
  - Locale: reads LC_ALL/LANG env vars
  - Assets: reads files via std::fs, decodes with std::image
  - Benchmark: @intrinsic("black_box")
  - Audit: @intrinsic declarations for 4 functions
  - SIMD: all 57+5 intrinsics replaced with portable scalar implementations
  - Collections: 29 intrinsics remain as compiler builtins (correct)
  - Core: size_of/align_of/type_name properly declared as compiler builtins
  - Signal: already uses proper @ffi("c") extern POSIX calls
- [x] C6. Platform @cfg gates
  - debug.tg: already properly gated (18 @cfg)
  - embedded.tg: already properly gated (32 @cfg)
  - gpu.tg: already properly gated (10 @cfg)
  - path.tg: already properly gated (2 @cfg)
  - thread.tg: added @cfg gates with per-platform opaque struct sizes
  - net.tg: migrated #[cfg]→@cfg syntax, added platform-specific SockAddrIn6/SockAddrUn
  - profile.tg: migrated #[cfg]→@cfg syntax, gated Linux/macOS-specific constants
