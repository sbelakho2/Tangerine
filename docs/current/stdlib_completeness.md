# Tangerine Stdlib Completeness Model

> **GENERATED EVIDENCE — do not edit by hand.** This document is
> rendered by `scripts/gen_stdlib_completeness.sh` from
> [`stdlib_contracts.toml`](stdlib_contracts.toml), the machine-readable
> completeness manifest: module → verification family → the proof tests.
> The CI enumeration gate regenerates it and runs `git diff --exit-code`,
> so a drifted completeness model cannot merge.

## The completeness model (the reviewer's item 32)

Every shipped `std/*.tg` module belongs to **exactly one verification
family**, and every family names its **minimum proof** — the weakest
evidence the module must carry to stay shipped. The family assignment
is the contract: it states what is CLAIMED for the module and what is
NOT. A module's family is never stronger than its committed evidence,
and the shipped-std claims are never stronger than the families.

**The enumeration is the gate.** The module list is COMPUTED from the
`std/*.tg` glob — never typed. This tree enumerates **133 modules**
(the reviewer's table enumerated 133: `std/postgres.tg` was merged into
`std/db.tg` and `std/hash_tests.tg` was removed in earlier waves). A
**new** `std/*.tg` file (a 134th module) has no contract, and the
completeness gate FAILS until it receives a contract + proof tests —
adding a module to std/ without completing its verification is
impossible by construction.

## The verification families

| Family | Minimum proof (the contract) | Modules |
|--------|-------------------------------|---------|
| `kernel` | the bootstrap ladder compiles the module at every stage (bootstrap/compiler_kernel.manifest + run_bootstrap.sh); the E106 sweep keeps it parse-clean | 14 |
| `native` | a committed native behavior suite (tests/unit/*_rigor.tg, tests/*_test.tg) exercises the module's public API via `tg test` | 49 |
| `lane` | a committed CI lane verifies check + object + link/import smoke and the module's own @test suites where declared | 7 |
| `parse-clean` | the E106 sweep only: `tg check` zero-diagnostics + the forbidden-syntax backstop (tests/run_stdlib_e106_sweep.sh) | 45 |
| `experimental` | parse-clean only; the module is flagged experimental (item 33 stable-subset policy) and is EXPLICITLY EXCLUDED from the shipped-std behavior claims | 18 |

- **kernel** — the 14-module bootstrap closure (`bootstrap/compiler_kernel.manifest`)
  compiled by every stage of the ladder; the strongest tier.
- **native** — a committed native behavior suite (`tests/unit/*_rigor.tg`,
  `tests/*_test.tg`) exercises the module's public API through `tg test`.
- **lane** — a committed CI lane verifies `tg check` + object emission +
  link/import smoke and the module's own `@test` suites where declared
  (the `stdlib-new-modules` lane).
- **parse-clean** — the E106 sweep only (`tg check` zero-diagnostics + the
  forbidden-syntax backstop). The module is parse-clean; NO behavior claim.
- **experimental** — the item 33 stable-subset policy: platform-only modules
  whose targets are unsupported/API-only. Parse-clean only, and
  **explicitly excluded from the shipped-std behavior claims** (see
  [the stable-subset policy](#the-stable-subset-policy-reviewers-item-33)).

## The module registry

| Module | Family | Proof tests (the contract) |
|--------|--------|----------------------------|
| `accessibility` | native | `tests/unit/test_a11y_rigor.tg`; `tests/unit/test_a11y.tg` |
| `alloc` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh`; `tests/allocator_churn_test.tg`; `tests/allocator_large_test.tg`; `tests/allocator_oom_test.tg`; `tests/allocator_reuse_test.tg`; `tests/allocator_threaded_test.tg`; `tests/allocator_alignment_test.tg` |
| `android` | experimental | `tests/run_stdlib_e106_sweep.sh`; `tests/platform/platform_surface_smoke_test.tg` — the pure JNI surface (the version constants, the device-density no-op off-Android) is host-tested |
| `anim` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `app` | native | `tests/unit/test_app_rigor.tg`; `tests/unit/test_events.tg`; `tests/integration/test_pipelines.tg`; `tests/determinism/test_replay.tg` |
| `args` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh` |
| `assets` | native | `tests/unit/test_assets_rigor.tg` |
| `async` | native | `tests/unit/test_async_rigor.tg`; `tests/task_scope_test.tg`; `tests/cancellation_token_test.tg`; `tests/reactor_readiness_test.tg`; `tests/async_mutex_waiter_test.tg`; `tests/async_channel_waiter_test.tg`; `tests/async_semaphore_waiter_test.tg`; `tests/join_cancel_test.tg`; `tests/executor_clock_test.tg`; `tests/cancellation_late_child_test.tg`; `tests/channel_zero_capacity_test.tg`; `tests/deterministic_gate_w_test.tg`; `tests/timer_cancelled_root_test.tg`; `tests/db_async_pool_test.tg` |
| `atomic` | native | `tests/atomic_litmus_sb_test.tg`; `tests/atomic_litmus_mp_test.tg`; `tests/atomic_litmus_wrc_test.tg`; `tests/atomic_litmus_acqrel_test.tg`; `tests/atomic_litmus_cas_pub_test.tg`; `tests/atomic_litmus_cas_fail_test.tg` |
| `audio` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `audit` | native | `tests/unit/test_audit_rigor.tg` |
| `auth` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `autotune` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `backend_abi` | native | `tests/abi/test_abi_conformance.tg` |
| `backtrace` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `bench` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh` |
| `blas` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `budget` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `capabilities` | native | `tests/unit/test_capability.tg` |
| `cbor` | native | `tests/unit/test_cbor_rigor.tg` — the RFC 8949 vector suite: the Appendix A definite + indefinite-length forms (additional info 31, the 0xFF break), the strict decode, and the encode round-trips |
| `cli` | native | `tests/unit/test_cli_rigor.tg` |
| `cocoa` | experimental | `tests/run_stdlib_e106_sweep.sh`; `tests/platform/cocoa_ffi_smoke_test.tg` — the ObjC FFI round trip (get_nsstring / nsstring_to_string through objc_getClass / sel_registerName / objc_msgSend) is the macOS-host smoke |
| `collections` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh` |
| `compositor` | native | `tests/unit/test_compositor_rigor.tg` |
| `compress` | native | `tests/unit/test_compress_rigor.tg` |
| `config` | native | `tests/unit/test_config_rigor.tg` |
| `contracts` | native | `tests/unit/test_contracts_rigor.tg`; `tests/run_mode_behavior_tests.sh` |
| `core` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh` |
| `crypto` | native | `tests/unit/test_crypto_rigor.tg` |
| `csv` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `ctx` | native | `tests/unit/test_ctx_rigor.tg` |
| `db` | native | `tests/db_integration_test.tg`; `tests/db_lifecycle_test.tg`; `tests/db_async_pool_test.tg`; `tests/db_postgres_integration_test.tg`; `tests/db_mysql_integration_test.tg`; `tests/db_postgres_lexer_test.tg`; `tests/db_mysql_layout_probe_test.tg`; `tests/db_mysql_large_result_test.tg`; `tests/db_pool_capacity_test.tg`; `tests/db_pool_init_failure_test.tg` |
| `debug` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `device` | native | `tests/unit/test_device_rigor.tg` |
| `diagnostics` | native | `tests/unit/test_diag_rigor.tg` |
| `doc_gen` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `dynload` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `effects` | experimental | `tests/run_stdlib_e106_sweep.sh` |
| `embed_trace` | native | `tests/unit/test_embed_trace_rigor.tg` |
| `embedded` | experimental | `tests/run_stdlib_e106_sweep.sh`; `tests/embedded/embedded_mmio_behavior_test.tg` — the volatile/MMIO Register abstraction, the bitfield helpers, the allocator-free ArrayVec/RingBuffer and the atomicity availability are host-tested; the bare-metal route (P0.2): aarch64-unknown-none is the REAL target (the aarch64 backend); the Thumb (thumbv6m/thumbv7em/thumbv8m.main) and RISC-V (riscv32imc/riscv32imac/riscv64gc) triples are HARD-REJECTED — no code generator, the stable diagnostic, no artifact |
| `encoding` | native | `tests/unit/test_encoding_rigor.tg` |
| `env` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh` |
| `exec` | native | `tests/exec_conservation_test.tg`; `tests/exec_admission_freeze_test.tg`; `tests/exec_global_executor_test.tg`; `tests/exec_par_family_test.tg`; `tests/exec_victim_range_test.tg` |
| `ffi` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh` |
| `fft` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `fixed` | native | `tests/unit/test_fixed_containers.tg` — the fixed-capacity collections (ArrayVec/RingBuffer/SpscQueue with split endpoints): the ownership-transferring push/pop semantics, the full-queue rejection that returns the item unconsumed, the ring wrap through the mask fast path, and the SPSC round trip (test_fixed_containers.tg); the capacity-per-type concrete structs are the kernel's expressible form (no const-generic value parameters) |
| `float_control` | lane | `tests/run_stdlib_e106_sweep.sh`; `std/float_control.tg` |
| `fmt` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh` |
| `fs` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh` |
| `fuzz` | native | `tests/unit/test_fuzz_rigor.tg`; `tests/fuzz/test_fuzz.tg` |
| `geom` | native | `tests/unit/test_geom.tg`; `tests/unit/test_paint.tg`; `tests/consistency/test_consistency.tg` |
| `gfx` | native | `tests/unit/test_gfx_rigor.tg`; `tests/unit/test_paint.tg`; `tests/integration/test_pipelines.tg`; `tests/consistency/test_consistency.tg`; `tests/golden/test_visual_regression.tg` |
| `gfx_errors` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh` |
| `gfx_gpu` | experimental | `tests/run_stdlib_e106_sweep.sh` — committed host-side rigor artifact(s) exist but are non-claiming for the unserved platform target |
| `gpu` | experimental | `tests/run_stdlib_e106_sweep.sh`; `tests/gpu/gpu_software_backend_test.tg` — the software/reference backend (the device enumeration, the mapped-host-pointer buffers, the opcode-parse kernel compile + the elementwise CPU dispatch) is host-tested; the hardware backends probe-and-fail-closed |
| `gpu_metal` | experimental | `tests/run_stdlib_e106_sweep.sh` |
| `gpu_vulkan` | experimental | `tests/run_stdlib_e106_sweep.sh` — the physical-device properties are UNSUPPORTED (P1.11) — the vkGetPhysicalDeviceProperties FFI is not bound to a Vulkan loader, so the enumeration returns the Unsupported error and never fabricates device values; the software/reference backend (std::gpu) is the supported path |
| `gpu_webgpu` | experimental | `tests/run_stdlib_e106_sweep.sh` |
| `graph` | native | `tests/unit/test_graph_rigor.tg` |
| `gui` | experimental | `tests/run_stdlib_e106_sweep.sh`; `tests/gui/gui_software_canvas_test.tg` — the software CanvasBuffer rasterizer (clear/put_pixel/fill_rect/frame_rect/blit) is host-tested — the always-available rendering path |
| `hal` | experimental | `tests/run_stdlib_e106_sweep.sh`; `tests/hal/hal_software_backend_test.tg` — the backend support probe + the device enumeration + init_hal with the always-available software backend are host-tested; the hardware probes fail closed when the library is absent |
| `hash` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `http` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `http2` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `i18n` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `image` | native | `tests/integration/test_pipelines.tg`; `tests/consistency/test_consistency.tg`; `tests/determinism/test_replay.tg` |
| `input` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `io` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh` |
| `ios` | experimental | `tests/run_stdlib_e106_sweep.sh`; `tests/platform/platform_surface_smoke_test.tg` — the pure platform helpers (the device-name/version no-ops off-iOS) are host-tested |
| `json` | native | `tests/unit/test_json_rigor.tg` — the RFC 8259 document policy: parse_document = value + whitespace + required EOF — the JSONTestSuite n_* class (trailing data, the second value, the leading-zero prefix) is rejected |
| `kernel` | experimental | `tests/run_stdlib_e106_sweep.sh`; `tests/kernel/kernel_primitives_test.tg` — the real implementations (the alpha stubs completed) — the round-robin scheduler, the CAS-backed mutex, the counting semaphore, the PCB table — are host-tested |
| `linalg` | lane | `tests/run_stdlib_e106_sweep.sh`; `std/linalg.tg` |
| `lint` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `locale` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `log` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `lsp` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `math` | native | `tests/unit/test_math_rigor.tg` |
| `metrics` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `migrate` | native | `tests/unit/test_migrate_rigor.tg` |
| `mmap` | lane | `tests/run_stdlib_e106_sweep.sh` |
| `msgpack` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `net` | native | `tests/net_loopback_test.tg`; `tests/net_negative_abi_test.tg` |
| `obligations` | native | `tests/unit/test_obligations_rigor.tg` |
| `opentelemetry` | lane | `tests/run_stdlib_e106_sweep.sh`; `std/opentelemetry.tg` |
| `package` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `patch` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `path` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `perf` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `platform` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `process` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh` |
| `profile` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `rand` | native | `tests/rand_entropy_test.tg`; `tests/unit/test_rand_behavior.tg` — the published reference vectors for every exported PRNG (xoshiro256++ rotl(s0 + s3, 23) + s0 formula; the ChaCha20 zero block; the PCG32 XSH-RR outputs) plus the entropy contract |
| `random` | native | `tests/unit/test_random_rigor.tg` |
| `regex` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `replay` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `secure_types` | native | `tests/unit/test_secure_types_rigor.tg` |
| `semantic_diff` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `semver` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `serde` | native | `tests/unit/test_serde_rigor.tg` |
| `signal` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `simd` | experimental | `tests/run_stdlib_e106_sweep.sh` — the honest proof state (P1.12): the __intrinsic_simd_* externs, the aarch64 NEON + x86 SSE/AVX codegen arms and the vector-row layout ARE implemented; the NATIVE EXACT-VECTOR execution tests are NOT yet run (the tests/simd/ suite executes on the host; the machine-vector equality is unobserved at this SHA) |
| `snapshot` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `sql` | native | `tests/unit/test_sql_rigor.tg` — the facade SQL contract: PreparedStatement::execute is the explicit Err(Unsupported) — never the silent Ok(empty) result set — the concrete driver's Connection::execute is the execution surface |
| `sqlite` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `stats` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `supply_chain` | native | `tests/unit/test_supply_chain_rigor.tg` |
| `sync` | native | `tests/unit/test_sync_rigor.tg`; `tests/sync_contention_test.tg`; `tests/condvar_waiter_queue_test.tg`; `tests/once_cas_test.tg`; `tests/arc_lifecycle_test.tg`; `tests/thread_channel_ownership_test.tg` |
| `taint` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh`; `tests/unit/test_taint_rigor.tg` |
| `tensor` | native | `tests/unit/test_tensor_rigor.tg` |
| `term` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `test` | native | `tests/unit/test_test_rigor.tg`; `tests/run_test_runner_integrity.sh`; `tests/run_bench_runner_integrity.sh` |
| `test_gen` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `text` | native | `tests/unit/test_text_rigor.tg`; `tests/unit/test_text.tg` |
| `thread` | native | `tests/thread_channel_ownership_test.tg`; `tests/thread_local_drop_test.tg`; `tests/thread_result_cell_test.tg`; `tests/thread_spawn_failure_test.tg`; `tests/pthread_abi_test.tg` |
| `time` | kernel | `bootstrap/compiler_kernel.manifest`; `tests/run_stdlib_e106_sweep.sh`; `tests/timer_cancel_test.tg`; `tests/timer_cancelled_root_test.tg`; `tests/executor_clock_test.tg` |
| `tls` | native | `tests/unit/test_tls_rigor.tg`; `tests/tls_interop_test.tg`; `tests/tls_handshake_test.tg` |
| `toml` | native | `tests/unit/test_toml_rigor.tg` |
| `tui` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `ui` | native | `tests/unit/test_ui_rigor.tg` |
| `ui_toolkit` | lane | `tests/run_stdlib_e106_sweep.sh` |
| `unicode` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `url` | native | `tests/unit/test_url_rigor.tg` |
| `validation` | lane | `tests/run_stdlib_e106_sweep.sh`; `std/validation.tg` |
| `wasi` | experimental | `tests/run_stdlib_e106_sweep.sh`; `tests/run_wasi_conformance.sh`; `tests/wasi/wasi_guest_surface_test.tg` — the guest WASI preview1 surface (the externs + iovec wrappers); the import wiring + the host-side ABI live in the compiler (wasm_target add_wasi_imports, runtime emit_wasi_host_runtime); the wasmtime lane reports when the runtime is installed; the pure guest-surface suite (the errno mapping, the clock ids, the iovec wire shape) is host-tested |
| `wasm` | experimental | `tests/run_stdlib_e106_sweep.sh` — committed host-side rigor artifact(s) exist but are non-claiming for the unserved platform target |
| `wasm_js` | experimental | `tests/run_stdlib_e106_sweep.sh` — host-side @test suite (CI stdlib-new-modules lane); the wasm32/js target itself is unserved |
| `web` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `web_ext` | lane | `tests/run_stdlib_e106_sweep.sh`; `std/web_ext.tg` |
| `web_server` | native | `tests/unit/test_web_server_rigor.tg` |
| `websocket` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `window` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |
| `windows` | experimental | `tests/run_stdlib_e106_sweep.sh`; `tests/platform/platform_surface_smoke_test.tg` — the pure Win32 surface (the wide-string bridge round trip, the version-surface no-op off-Windows) is host-tested |
| `yaml` | parse-clean | `tests/run_stdlib_e106_sweep.sh` |

## The stable-subset policy (the reviewer's item 33)

**The choice: the stable-subset policy.** Two policies were considered:

1. **Everything-in-std-guaranteed** — every module in `std/` must reach
   native-tested + target-complete status on every advertised target.
   The honest registry forbids this: the targets of the modules below are
   unsupported or API-only (`wasm-target` = api-only, `embedded-targets` =
   unsupported, `wasi` = unsupported, `simd` = api-only,
   `algebraic-effects` = api-only, the GPU and platform-only surfaces have
   no target row at all — see the feature registry + target_capabilities.md).
   Under this policy the shipped-std-100%% claim would be permanently
   unreachable or dishonest.
2. **The stable-subset policy (CHOSEN)** — the experimental modules are
   flagged experimental in the registry (`experimental = true` on the
   feature rows, with the affected modules listed in `modules = [...]`),
   grouped here in the `experimental` family with the parse-clean minimum
   proof, and **explicitly excluded from the shipped-std-100%% claim**.
   The claim covers the 115 non-experimental modules; the 18 experimental
   modules remain in `std/` (parse-clean, never removed) but carry no
   behavior or target claim until their targets are served and their
   evidence lands.

**The affected modules (18):** `android`, `cocoa`, `effects`, `embedded`, `gfx_gpu`, `gpu`, `gpu_metal`, `gpu_vulkan`, `gpu_webgpu`, `gui`, `hal`, `ios`, `kernel`, `simd`, `wasi`, `wasm`, `wasm_js`, `windows`.

**The shipped-std-100% claim.** The claim is: every one of the 115
shipped (non-experimental) modules belongs to a family with a committed
minimum proof, and every module — shipped or experimental — is
parse-clean under the E106 sweep. The experimental modules are named
above; any claim about them is outside the shipped claim by explicit
exclusion.

## Cross-references

- [`stdlib_contracts.toml`](stdlib_contracts.toml) — the machine-readable source.
- [Standard Library Reference](stdlib_reference.md) — module surfaces and the migration-complete gate.
- [Feature Registry](feature_registry.md) — the feature-level statuses and the item 36 status ladder.
- [Target Capabilities](target_capabilities.md) — the honest per-target capability matrix.
- `tests/run_stdlib_completeness_gate.sh` — the enumeration gate (run first by the E106 sweep).
- `scripts/gen_api_manifest.sh` — the public-API manifest over the same module list.

---

*Generated by `scripts/gen_stdlib_completeness.sh` from
`docs/current/stdlib_contracts.toml` — deterministic output, so the CI
enumeration gate can regenerate it and run `git diff --exit-code`.
Do not edit this file by hand.*
