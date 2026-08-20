# Tangerine Feature Matrix

> Honest feature comparison: Tangerine vs Rust, derived from the executable
> state of the self-hosted compiler, not from declared module surfaces.

## Legend — status definitions

| Status | Meaning |
|--------|---------|
| **implemented+tested** | The compiler implements the feature and the repo contains tests that exercise it (canaries, native tests, or the self-hosted compiler itself as the workload) |
| **implemented-unverified** | The feature is implemented in the compiler/runtime but has no dedicated test evidence on this host |
| **partial** | A working subset exists; the full feature is not present |
| **API-only** | The std module / interface is declared, but the compiler does not wire it into the pipeline and it is not part of the bootstrap closure (it is not parse-verified under the current compiler) |
| **design** | Specified in docs/RFCs only; no implementation |
| **unsupported** | Explicitly removed or rejected by the compiler (e.g. E106) |

## Kernel closure note

"Bootstrap closure" below means the 37 files in
`bootstrap/compiler_kernel.manifest` (14 std modules + the compiler kernel)
that the stage0→stage1 ladder compiles. Everything outside the closure is
**API-only** until it parses and type-checks under the current compiler
(the E106 migration of the non-kernel stdlib is in progress — see
[`stdlib_reference.md`](stdlib_reference.md) §Completeness).

---

## I. Core Systems Programming

| Feature | Tangerine | Rust | Status basis |
|---------|-----------|------|-------------|
| Ownership (access conventions, resources, capabilities) | implemented+tested | ✅ | resource_check.tg dataflow + capability machinery; `tests/canary_neg`, `canary_capability.tg`; the self-hosted compiler |
| Borrowing (`&T` first-class references) | unsupported | ✅ | no first-class reference types; `&T`/`&mut T` in type position is the E106 hard error (parser.tg `parse_type`) |
| Lifetimes | unsupported | ✅ | no lifetime system exists; the borrow/lifetime model was removed by design (see `../history/access_resource_migration.md`) |
| Move semantics (`sink`, `move`) | implemented+tested | ✅ | access/resource model; `tests/canary_neg` move/consume negatives |
| Zero-cost abstractions | implemented-unverified | ✅ | trait system + generics + monomorphization exist; no benchmark evidence for the claim |
| Algebraic data types | implemented+tested | ✅ | `enum` + pattern matching; exercised by the compiler itself |
| Generic programming | implemented+tested | ✅ | `[T: Trait]` syntax, zero-inference monomorphization (mono.tg) |
| Trait system | implemented+tested | ✅ | trait_resolve.tg facade over the one solver; exercised by the compiler |
| Async/await | partial (alpha) | ✅ | `std/async.tg` carries `status: alpha`; module exists with an executor, but it is not in the bootstrap closure |
| Closures | implemented+tested | ✅ | value-ABI closure lowering; `tests/canary` closure canaries |
| Macros | implemented+tested | ✅ | `macro` keyword, 64-pass expansion fixpoint with E105 hard stop |
| Modules & visibility | implemented+tested | ✅ | `module`, `pub`, `use`; module table is the identity authority (ast.tg Crate) |
| Error handling (Result/Option) | implemented+tested | ✅ | `std/core`; error codes E0xxx through the diagnostic registry |
| Algebraic effects | API-only | ❌ | `std/effects.tg` declares the types; `MirEffectRecord` is never lowered from source and the runtime body is a trap stub (runtime.tg) |
| Capability-based security | implemented+tested | ❌ | capability linearity enforced in resource_check.tg; `tests/canary/canary_capability.tg` |
| 4-mode progressive system | partial (config carries only the enforced bits) | ❌ | `ModeConfig` holds the two unconditional enforcements only — contracts (`lower_contract`, mir.tg) and capabilities (`validate_capability_exit`, resource_check.tg); every other gate is pending, no config bit claims it (see `language.md` §Progressive Strictness) |
| SIMD intrinsics | API-only | ✅ | `std/simd.tg` declares vector types (87 defs); no SIMD instruction support in asm.tg/codegen.tg; not in the bootstrap closure |
| Inline assembly | unsupported | ✅ | no `asm` directive in token/ast/parser |

## II. Embedded / Bare-Metal

| Feature | Tangerine | Rust | Status basis |
|---------|-----------|------|-------------|
| `@[no_std]` attribute | unsupported | ✅ | no such attribute in ast.tg/parser.tg |
| `std/embedded` module | API-only | ✅ | module declared (151 defs); not in the bootstrap closure, not parse-verified under the current compiler |
| `@[packed]` / `@[align]` attributes | design | ✅ | documented (`../history/frozen_layout_features.md` lists them GATED); not implemented in the compiler |
| Cortex-M targets (`thumbv7em`, `thumbv6m`) | unsupported | ✅ | no such target in cross_compile.tg / asm.tg |
| RISC-V targets | unsupported | ✅ | no RISC-V backend |
| No-alloc collections (`ArrayVec`, `RingBuffer`) | API-only | ✅ | declared in std; not in the bootstrap closure |
| `@[real_time(wcet_us=N)]` | design | ❌ | documented only |

## III. Web & Cloud

| Feature | Tangerine | Rust | Status basis |
|---------|-----------|------|-------------|
| `std/web`, `std/web_ext`, `std/http`, `std/http2`, `std/websocket`, `std/url`, `std/net` | API-only | ✅ | declared; none in the bootstrap closure; web.tg/http.tg still carry `-> &T`-style type positions (E106-pending) |
| `std/json`, `std/toml`, `std/cbor`, `std/msgpack`, `std/yaml`, `std/csv`, `std/serde` | API-only | ✅ | declared; not in the bootstrap closure |
| `std/db`, `std/sql`, `std/postgres`, `std/sqlite` | API-only | ✅ | declared; not in the bootstrap closure |
| `std/opentelemetry` | API-only | ✅ | declared; not in the bootstrap closure |
| `std/validation` | API-only | ✅ | declared; not in the bootstrap closure |

## III.4 WebAssembly

| Feature | Tangerine | Rust | Status basis |
|---------|-----------|------|-------------|
| WASM compile target | API-only | ✅ | `wasm_target.tg` builds WASM sections, but nothing calls it: no `--target wasm32*` route in driver.tg/codegen.tg, no tests |
| WASI support | unsupported | ✅ | no WASI runtime |
| `std/wasm`, `std/wasm_js` | API-only | ✅ | declared; not in the bootstrap closure; wasm.tg still carries `-> &T`-style positions (E106-pending) |

## IV. Graphics & GPU

| Feature | Tangerine | Rust | Status basis |
|---------|-----------|------|-------------|
| `std/gpu`, `std/gpu_vulkan`, `std/gpu_metal`, `std/gpu_webgpu`, `std/gfx*` | API-only | ✅ | declared; not in the bootstrap closure |
| `std/linalg`, `std/simd`-based math | API-only | ✅ | declared; not in the bootstrap closure |
| `std/mmap` | API-only | ✅ | declared; not in the bootstrap closure |
| `std/float_control` | API-only | ✅ | declared; not in the bootstrap closure |

## V. Standard Library Completeness

"Complete" requires every public module to parse, type-check, compile, link
and pass native tests on every advertised Tier-1 target. That is NOT the
current state: the E106 migration of the non-kernel modules is in progress
(see [`stdlib_reference.md`](stdlib_reference.md) §Completeness for the
pending list).

| Category | Modules | Status |
|----------|---------|--------|
| Core types | `core`, `ops`-level primitives | implemented+tested — `core` is in the bootstrap closure and the compiler is self-hosted on it |
| Collections | `collections` | implemented-unverified — in the bootstrap closure; the record-visit `Option[&K]` extern signatures (working tree) are the kernel's last reference type positions (extern-ABI exception only; see `stdlib_reference.md` §Completeness) |
| Kernel closure std | `alloc`, `args`, `bench`, `core`, `env`, `ffi`, `fmt`, `fs`, `gfx_errors`, `io`, `process`, `taint`, `time`, `collections` | implemented-unverified — compile in every bootstrap stage; no per-module native test evidence |
| String handling | `string` (core), `regex` | partial — owned-String ABI implemented+tested; `regex` is API-only (not in the bootstrap closure) |
| I/O | `io`, `fs`, `path`, `net` | partial — `io`/`fs` in the closure; `path`/`net` API-only |
| Concurrency | `sync`, `async_`, `thread`, `channel` | API-only — async is alpha (partial); none in the bootstrap closure |
| Memory | `alloc`, `mmap` | partial — `alloc` in the closure; `mmap` API-only |
| Time | `time`, `chrono` | partial — `time` in the closure; `chrono` API-only |
| Serialization | `json`, `toml`, `serde` | API-only |
| Crypto | `crypto`, `hash`, `rand` | API-only |
| Web | `web`, `web_ext`, `http` | API-only |
| Database | `db`, `sql` | API-only |
| Graphics | `gpu`, `gfx_*` (8 modules) | API-only |
| WASM | `wasm`, `wasm_js` | API-only |
| Embedded | `embedded` | API-only |
| Observability | `opentelemetry` | API-only |
| Validation | `validation` | API-only |
| Logging | `log` | API-only |
| Testing | `test` | API-only — the native test runner is the bootstrap harness, not `std::test` |
| FFI | `ffi` | implemented-unverified — in the bootstrap closure |
| Contracts/capabilities/effects/budgets | `contracts`, `capabilities`, `effects`, `budget` | partial — `capabilities` enforced by resource_check.tg; `effects`/`budget` are API-only (never lowered); none in the bootstrap closure |

## VI. Backend / Target Status

| Target | Status | Status basis |
|--------|--------|-------------|
| aarch64-apple-darwin (host) | implemented+tested | the bootstrap ladder and native canaries run on it (`tests/arm64` encoder/ABI tests, `run_bootstrap.sh`) |
| x86_64 (System V / Windows x64) | implemented-unverified | x64 emitter exists in asm.tg/codegen.tg; the cross lane (`tests/run_target_lane_canaries.sh`) compiles and runs under Rosetta/qemu when available, else a disassembly gate; no dedicated x86 host tests |
| wasm32 | API-only | `wasm_target.tg` is not wired into the driver or codegen |
| Embedded targets (Cortex-M, RISC-V) | unsupported | no target descriptors |

## VII. Developer Experience

| Feature | Tangerine | Rust | Status basis |
|---------|-----------|------|-------------|
| LSP server | partial | ✅ | `tg lsp` subcommand exists (the LSP server lives in `tg_compiler/driver.tg`); editor recovery path is permissive resolution only |
| VS Code extension | implemented-unverified | ✅ | `tangerine-vscode/` tree present; no test evidence |
| Syntax highlighting | implemented-unverified | ✅ | TextMate grammar present |
| Code formatting | implemented+tested | ✅ | `tg fmt` (formatter.tg) |
| Linting | partial | ✅ | `tg lint` (linter.tg) is a separate subcommand; lint rules are not part of the compile pipeline |
| Test runner | partial | ✅ | `tg test` (cmd_test); the authoritative gate is the bootstrap harness |
| Package manager | partial | ✅ | `tg dep` / `tg install` (pkg_manager.tg); registry operations are local |
| REPL | design | ❌ | `tg repl` listed; no implementation |
| Documentation generator | implemented-unverified | ✅ | `tg doc` (docgen.tg) |
| Benchmark framework | API-only | ✅ | `std::bench` not in the bootstrap closure; CI uses a pinned baseline release |

## VIII. Documentation Quality

| Document | Status | Path |
|----------|--------|------|
| Language reference | current | `docs/current/language.md` |
| Style guide | current | `docs/current/style_guide.md` |
| Memory model | current | `docs/current/memory_model.md` |
| Grammar | current | `docs/current/grammar.md` |
| Pipeline manifest | current | `docs/current/pipeline_manifest.md` |
| Stdlib reference | current | `docs/current/stdlib_reference.md` |
| Stabilized layout subset | current | `docs/current/stabilized_subset.md` |
| Access/resource migration | NON-NORMATIVE history | `docs/history/access_resource_migration.md` |
| Frozen layout features (old Map header data) | NON-NORMATIVE history | `docs/history/frozen_layout_features.md` |

---

*Last updated: 2026-08 · working tree commit 65dfe07 + the ref/allocator/
verifier work (docs reconciled with the executable state)*
