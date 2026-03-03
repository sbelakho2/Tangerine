# Tangerine Feature Matrix

> Complete feature comparison: Tangerine vs Rust across all major domains

## Legend

| Symbol | Meaning |
|--------|---------|
| ✅ | Fully implemented |
| 🔶 | Partially implemented / API-complete awaiting backend |
| ❌ | Not yet implemented |

---

## I. Core Systems Programming

| Feature | Tangerine | Rust | Module/Notes |
|---------|-----------|------|-------------|
| Ownership & borrowing | ✅ | ✅ | Core language feature |
| Move semantics | ✅ | ✅ | Core language feature |
| Lifetimes | ✅ | ✅ | Core language feature |
| Zero-cost abstractions | ✅ | ✅ | Trait system, generics |
| Algebraic data types | ✅ | ✅ | `enum`, pattern matching |
| Generic programming | ✅ | ✅ | `[T: Trait]` syntax |
| Trait system | ✅ | ✅ | Similar to Rust traits |
| Async/await | ✅ | ✅ | `std::async_` |
| Closures | ✅ | ✅ | `Fn`, `FnMut`, `FnOnce` |
| Macros | ✅ | ✅ | Hygenic macros with `macro` keyword |
| Modules & visibility | ✅ | ✅ | `module`, `pub`, `use` |
| Error handling (Result/Option) | ✅ | ✅ | `std::core` |
| Algebraic effects | ✅ | ❌ | Unique to Tangerine |
| Capability-based security | ✅ | ❌ | Unique to Tangerine |
| 4-mode progressive system | ✅ | ❌ | Dev→Strict→Production→Hardened |
| SIMD intrinsics | ✅ | ✅ | `std::simd` — f32x4/x8, i32x4, etc. |
| Inline assembly | 🔶 | ✅ | Compiler directive support |

## I.3 SIMD & High-Performance Math

| Feature | Tangerine | Rust | Module/Notes |
|---------|-----------|------|-------------|
| f32x4 / f64x2 (128-bit) | ✅ | ✅ | `std::simd` |
| f32x8 / f64x4 (256-bit) | ✅ | ✅ | `std::simd` (AVX) |
| i32x4 / i16x8 / i8x16 | ✅ | ✅ | `std::simd` |
| Platform feature detection | ✅ | ✅ | `std::simd::has_sse2()`, etc. |
| SSE/SSE2/AVX/AVX2/AVX-512 | ✅ | ✅ | x86_64 intrinsics |
| NEON (AArch64) | ✅ | ✅ | ARM intrinsics |
| Prefetch & memory fences | ✅ | ✅ | `std::simd` |
| Non-temporal stores | ✅ | ✅ | `std::simd` |
| Auto-vectorization hints | ✅ | ✅ | `@[simd]` attribute |

## II. Embedded / Bare-Metal

| Feature | Tangerine | Rust | Module/Notes |
|---------|-----------|------|-------------|
| `no_std` support | ✅ | ✅ | `@[no_std]` attribute |
| Volatile read/write | ✅ | ✅ | `std::embedded` |
| Register[T] MMIO | ✅ | ✅ | `std::embedded` |
| Bitfield manipulation | ✅ | ✅ | `std::embedded::Bitfield` |
| Custom linker scripts | ✅ | ✅ | `@[link_section]`, `.ld` files |
| `@[packed]` / `@[align]` | ✅ | ✅ | Memory layout attributes |
| Interrupt handlers | ✅ | ✅ | `@[interrupt]` attribute |
| Critical sections | ✅ | ✅ | `std::embedded::critical_section` |
| GPIO HAL | ✅ | ✅ | `std::embedded::hal::GpioPin` |
| UART HAL | ✅ | ✅ | `std::embedded::hal::Uart` |
| SPI HAL | ✅ | ✅ | `std::embedded::hal::Spi` |
| I2C HAL | ✅ | ✅ | `std::embedded::hal::I2c` |
| Timer/PWM HAL | ✅ | ✅ | `std::embedded::hal::Timer/Pwm` |
| ADC/DAC HAL | ✅ | ✅ | `std::embedded::hal::Adc/Dac` |
| Watchdog | ✅ | ✅ | `std::embedded::hal::Watchdog` |
| DMA channels | ✅ | ✅ | `std::embedded::DmaChannel` |
| Power management | ✅ | ✅ | `std::embedded::PowerController` |
| Real-time WCET attributes | ✅ | ❌ | `@[real_time(wcet_us=N)]` |
| `@[no_heap]` compile check | ✅ | ❌ | Unique to Tangerine |
| No-alloc collections | ✅ | ✅ | `ArrayVec`, `RingBuffer` |
| Cortex-M targets | ✅ | ✅ | `thumbv7em`, `thumbv6m` |
| RISC-V targets | 🔶 | ✅ | Tier 3 support |

## III. Web & Cloud

| Feature | Tangerine | Rust | Module/Notes |
|---------|-----------|------|-------------|
| HTTP server | ✅ | ✅ | `std::web::App` |
| Routing (path params, query) | ✅ | ✅ | `std::web` |
| Middleware pipeline | ✅ | ✅ | `std::web::Middleware` |
| Static file serving | ✅ | ✅ | `std::web` |
| Template engine | ✅ | ✅ | `std::web` (built-in) |
| JWT authentication | ✅ | ✅ | `std::web::auth` |
| Session management | ✅ | ✅ | `std::web::auth` |
| File upload handling | ✅ | ✅ | `std::web_ext::parse_multipart` |
| Rate limiting | ✅ | ✅ | `std::web_ext::RateLimiter` |
| CORS | ✅ | ✅ | `std::web_ext::CorsMiddleware` |
| Request ID tracking | ✅ | ✅ | `std::web_ext::RequestIdMiddleware` |
| Background tasks | ✅ | ✅ | `std::web_ext::TaskPool` |
| Graceful shutdown | ✅ | ✅ | `std::web_ext::GracefulShutdown` |
| Health checks | ✅ | ✅ | `std::web_ext::add_health_checks` |
| Input validation | ✅ | ✅ | `std::validation` |
| OpenTelemetry tracing | ✅ | ✅ | `std::opentelemetry` |
| OpenTelemetry metrics | ✅ | ✅ | `std::opentelemetry::Counter`, etc. |
| W3C Trace Context propagation | ✅ | ✅ | `std::opentelemetry::TraceContextPropagator` |
| Database connectivity | 🔶 | ✅ | `std::db` (interface defined) |
| JSON (de)serialization | ✅ | ✅ | `std::json` |

## III.4 WebAssembly

| Feature | Tangerine | Rust | Module/Notes |
|---------|-----------|------|-------------|
| WASM compile target | ✅ | ✅ | `wasm32-unknown-unknown` |
| WASI support | ✅ | ✅ | `wasm32-wasi` |
| WASM host API | ✅ | ✅ | `std::wasm` |
| Component Model (WIT) | ✅ | ✅ | `std::wasm::component` |
| WASM fuel metering | ✅ | ✅ | `std::wasm::FuelConfig` |
| JS value interop | ✅ | ✅ | `std::wasm_js::JsValue` |
| DOM bindings | ✅ | ✅ | `std::wasm_js::Element` |
| JS closures (callbacks) | ✅ | ✅ | `std::wasm_js::JsClosure` |
| Fetch API | ✅ | ✅ | `std::wasm_js::FetchRequest` |
| Console API | ✅ | ✅ | `std::wasm_js::console` |
| Timers (setTimeout, etc.) | ✅ | ✅ | `std::wasm_js` |
| Promise ↔ async interop | ✅ | ✅ | `std::wasm_js::to_promise` |
| TypedArray zero-copy | ✅ | ✅ | `std::wasm_js::u8_slice_to_js` |
| `@[wasm_bindgen]` codegen | ✅ | ✅ | `std::wasm_js` |
| Web Workers | ✅ | ✅ | `std::wasm_js::Worker` |

## IV. Graphics & GPU

| Feature | Tangerine | Rust | Module/Notes |
|---------|-----------|------|-------------|
| Vulkan backend | ✅ | ✅ | `std::gpu` (Backend.Vulkan) |
| Metal backend | ✅ | ✅ | `std::gpu` (Backend.Metal) |
| DirectX 12 backend | ✅ | ✅ | `std::gpu` (Backend.DirectX12) |
| OpenGL 4.6 backend | ✅ | ✅ | `std::gpu` (Backend.OpenGL46) |
| WebGPU backend | ✅ | ✅ | `std::gpu` (Backend.WebGPU) |
| Auto backend selection | ✅ | ✅ | `std::gpu` (Backend.Auto) |
| Buffer creation & mapping | ✅ | ✅ | `std::gpu::GpuBuffer` |
| Texture formats (22+) | ✅ | ✅ | Including BC/ASTC compression |
| Samplers | ✅ | ✅ | `std::gpu::GpuSampler` |
| Render pipelines | ✅ | ✅ | Full vertex/fragment config |
| Compute pipelines | ✅ | ✅ | `std::gpu::ComputePipeline` |
| Command encoding | ✅ | ✅ | `std::gpu::CommandEncoder` |
| Descriptor sets / bind groups | ✅ | ✅ | `std::gpu::BindGroup` |
| Synchronization (fence/semaphore) | ✅ | ✅ | `std::gpu::Fence/Semaphore` |
| Swapchain presentation | ✅ | ✅ | `std::gpu::Swapchain` |
| SPIR-V compilation | ✅ | ✅ | `std::gpu::spirv` |
| Shader cross-compilation | ✅ | ✅ | GLSL→HLSL→MSL→WGSL |
| Shader reflection | ✅ | ✅ | `std::gpu::spirv::reflect` |
| Ray tracing (feature flag) | 🔶 | 🔶 | Feature detection present |
| Mesh shading (feature flag) | 🔶 | 🔶 | Feature detection present |

## IV.1 Linear Algebra

| Feature | Tangerine | Rust | Module/Notes |
|---------|-----------|------|-------------|
| Vec2/Vec3/Vec4 (f32) | ✅ | ✅ | `std::linalg` |
| DVec2/DVec3/DVec4 (f64) | ✅ | ✅ | `std::linalg` |
| IVec2/IVec3/IVec4 (i32) | ✅ | ✅ | `std::linalg` |
| Mat2/Mat3/Mat4 | ✅ | ✅ | Column-major |
| Quaternions | ✅ | ✅ | `std::linalg::Quat` |
| Slerp interpolation | ✅ | ✅ | `std::linalg::Quat.slerp` |
| Transform (TRS) | ✅ | ✅ | `std::linalg::Transform` |
| Perspective projection | ✅ | ✅ | Both OpenGL and Vulkan NDC |
| Orthographic projection | ✅ | ✅ | `Mat4.orthographic` |
| Look-at matrix | ✅ | ✅ | `Mat4.look_at` |
| SIMD-accelerated Vec4/Mat4 | ✅ | ✅ | Uses `std::simd::f32x4` |
| Euler ↔ Quaternion | ✅ | ✅ | `Quat.from_euler`, `to_euler` |

## IV.4 Memory-Mapped I/O

| Feature | Tangerine | Rust | Module/Notes |
|---------|-----------|------|-------------|
| Read-only mmap | ✅ | ✅ | `std::mmap::Mmap` |
| Read-write mmap | ✅ | ✅ | `std::mmap::MmapMut` |
| Anonymous mmap | ✅ | ✅ | `std::mmap::AnonMmap` |
| madvise hints | ✅ | ✅ | Sequential/Random/WillNeed/HugePage |
| Memory locking | ✅ | ✅ | `mmap.lock()`/`unlock()` |
| Sync/flush | ✅ | ✅ | `mmap.flush()` |
| RAII auto-unmap | ✅ | ✅ | `Drop` implementation |
| Builder pattern | ✅ | ✅ | `MmapBuilder` |
| Cross-platform | ✅ | ✅ | Unix mmap + Windows MapViewOfFile |

## IV.5 Deterministic Floating Point

| Feature | Tangerine | Rust | Module/Notes |
|---------|-----------|------|-------------|
| Rounding mode control | ✅ | 🔶 | `std::float_control` |
| Denormal mode control | ✅ | 🔶 | FlushToZero, DAZ |
| Fast-math flags | ✅ | 🔶 | `@[fast_math]` attribute |
| `@[deterministic_float]` | ✅ | ❌ | Compile-time determinism |
| RAII rounding mode guard | ✅ | ❌ | `RoundingModeGuard` |
| ULP distance | ✅ | ❌ | `ulp_distance_f32/f64` |
| FP exception checking | ✅ | 🔶 | `check_exceptions` |
| Cross-platform reproducibility | ✅ | ❌ | `DeterministicConfig.FULL` |
| Platform intrinsics (MXCSR/FPCR) | ✅ | 🔶 | x86_64 and AArch64 |

## V. Standard Library Completeness

| Category | Modules | Status |
|----------|---------|--------|
| Core types | `core`, `ops`, `convert` | ✅ |
| Collections | `collections`, `btree`, `hashmap` | ✅ |
| String handling | `string`, `fmt`, `regex` | ✅ |
| I/O | `io`, `fs`, `path`, `net` | ✅ |
| Concurrency | `sync`, `async_`, `thread`, `channel` | ✅ |
| Math | `math`, `linalg`, `simd` | ✅ |
| Memory | `alloc`, `mmap` | ✅ |
| Time | `time`, `chrono` | ✅ |
| Serialization | `json`, `toml`, `serde` | ✅ |
| Crypto | `crypto`, `hash`, `rand` | ✅ |
| Web | `web`, `web_ext`, `http` | ✅ |
| Database | `db`, `sql` | 🔶 |
| Graphics | `gpu`, `gfx_*` (8 modules) | ✅ |
| WASM | `wasm`, `wasm_js` | ✅ |
| Embedded | `embedded` | ✅ |
| Observability | `opentelemetry` | ✅ |
| Validation | `validation` | ✅ |
| Logging | `log` | ✅ |
| Testing | `test` | ✅ |
| FFI | `ffi` | ✅ |

## VI. Developer Experience

| Feature | Tangerine | Rust | Notes |
|---------|-----------|------|-------|
| LSP server | ✅ | ✅ | `tangerine-lsp` |
| VS Code extension | ✅ | ✅ | `tangerine-vscode/` |
| Syntax highlighting | ✅ | ✅ | TextMate grammar |
| Code formatting | ✅ | ✅ | `tg fmt` |
| Linting | ✅ | ✅ | Built-in diagnostics |
| Test runner | ✅ | ✅ | `tg test` |
| Package manager | ✅ | ✅ | `tg` CLI |
| REPL | 🔶 | ❌ | Planned |
| Documentation generator | ✅ | ✅ | `tg doc` |
| Benchmark framework | ✅ | ✅ | `std::test::bench` |

## VII. Documentation Quality

| Document | Status | Path |
|----------|--------|------|
| Language reference | ✅ | `docs/language.md` |
| Style guide | ✅ | `docs/style_guide.md` |
| Memory model | ✅ | `docs/memory_model.md` |
| Error handling | ✅ | `docs/error_handling.md` |
| Concurrency guide | ✅ | `docs/concurrency.md` |
| FFI cheatsheet | ✅ | `docs/ffi_cheatsheet.md` |
| Security policy | ✅ | `docs/security.md` |
| Embedded guide | ✅ | `docs/embedded_guide.md` |
| Web development guide | ✅ | `docs/web_guide.md` |
| Graphics/GPU guide | ✅ | `docs/graphics_guide.md` |
| Cross-compilation guide | ✅ | `docs/cross_compilation_guide.md` |
| Build system reference | ✅ | `docs/build_system.md` |
| Deployment targets | ✅ | `docs/deployment_targets.md` |
| Release engineering | ✅ | `docs/release_engineering.md` |
| RFC process | ✅ | `docs/rfc_process.md` |
| Developer guide | ✅ | `docs/developer_guide.md` |
| Stdlib reference | ✅ | `docs/stdlib_reference.md` |
| Architecture decisions | ✅ | `docs/architecture_decisions.md` |

---

*Last updated: 2026-01 · Tangerine v0.1.0*
