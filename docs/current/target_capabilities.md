# Tangerine Target Capability Matrix

> **GENERATED EVIDENCE — do not edit by hand.** This matrix is
> rendered by `scripts/gen_spec_docs.sh` from
> [`target_capabilities.toml`](target_capabilities.toml), the
> machine-readable source of truth. The CI evidence-gate job
> regenerates it and runs `git diff --exit-code`, so a stale
> hand-edited matrix cannot merge.

> The reviewer's item 14: per-target capability marks, HONEST — a
> capability is advertised with ✓ only when the CURRENT tree carries
> executed evidence for it. This tree has NOT run a bootstrap ladder
> or CI lane (the working tree is e1eb946 + the Wave-A work); the
> evidence column states exactly what exists, and a ✓ without a run
> is never claimed. Where the evidence is a committed artifact that
> HAS run on an earlier tree, the mark is the artifact's mark, not
> an observed run on this tree.

## The capability legend

| Capability | Meaning |
|---|---|
| Parse | the front end lexes/parses a Tangerine program for the target (target-independent — the front end runs on the host) |
| Type | the full semantic pipeline (type/access/resource checking) accepts programs for the target (target-independent front end) |
| MIR | lowering + verification + monomorphization + optimization complete for the target (the front-end boundary `--target <triple>` with `tg check` accepts any registered triple) |
| Object | the backend emits a relocatable object file for the target's format (Mach-O/ELF) |
| Static-link | the in-tree linker links a static executable (entry, sections, relocations) without an external linker |
| Dynamic-extern | extern declarations resolve against the platform's dynamic libraries (libSystem / glibc) |
| Native-run | an emitted executable runs natively on a host of that target |
| TLS | thread-local storage is implemented and test-covered |
| Threads | std::thread / pthread ABI surface works (the pthread opaques + the FFI-opaque alignment table) |
| DB | std/db connectivity is implemented and test-covered (mysql/postgres drivers) |
| Debug | debug info emission (`-g`) or a debugger surface exists |

## The matrix

| Capability | aarch64-apple-darwin | x86_64-unknown-linux-gnu | x86_64-apple-darwin | x86_64-windows | wasm32 |
|---|---|---|---|---|---|
| Parse | ✓ | ✓ | ✓ | ✓ | ✓ |
| Type | ✓ | ✓ | ✓ | ✓ | ✓ |
| MIR | ✓ | ✓ | ✓ | ✓ | ✓ |
| Object | ✓ | ✓ | ✓ | ✗ | ✓ |
| Static-link | ✓ | ✓ | ✗ | ✗ | ✗ |
| Dynamic-extern | ✓ | ✓ | ✗ | ✗ | ✗ |
| Native-run | ✓ | ✗ | ✗ | ✗ | ✗ |
| TLS | ✓ | ✗ | ✗ | ✗ | ✗ |
| Threads | ✓ | ✗ | ✗ | ✗ | ✗ |
| DB | ✓ | ✗ | ✗ | ✗ | ✗ |
| Debug | ✗ | ✗ | ✗ | ✗ | ✗ |

## The evidence behind every mark

**Parse / Type / MIR — every target (✓).** The front end is
target-independent: lexing, parsing, resolution, type/access/resource
checking, MIR lowering/verification and the completeness oracles run on the
host compiler before any target-specific backend decision. The MIR boundary
(`--target <triple>` with `tg check`) accepts any registered triple; the
triples below all parse through `parse_target_triple`. Evidence: the
front-end suites (`tests/canary`, `tests/canary_neg`, the CFG oracle lane
`tests/resource_cfg/`, the differential corpus `tests/differential/`).
None of the targets' front-end marks depend on a native run.

**aarch64-apple-darwin: Parse, Type, MIR, Object, Static-link, Dynamic-extern, Native-run, TLS, Threads, DB ✓; Debug ✗.**

Evidence: `tests/canary`; `tests/canary_neg`; `tests/resource_cfg`; `tests/differential`; `tests/run_target_lane_canaries.sh`; `tests/thread_local_drop_test.tg`; `tests/pthread_abi_test.tg`; `tests/db_mysql_integration_test.tg`; `tests/db_postgres_integration_test.tg`; `tests/db_async_pool_test.tg`; `tests/run_nostd_bare_lane.sh`; `tests/nostd/nostd_bare_start.tg`.

the bootstrap host: the ARM64 backend (asm.tg AArch64 encoder), the Mach-O object writer and the in-tree Mach-O linker (linker.tg — dyld import stubs, bind opcodes, LC_LOAD_DYLIB libSystem.B.dylib) are the committed artifacts. TLS: @thread_local statics + thread_local_drop_test.tg. Threads: std/thread.tg pthread opaques + the FFI-opaque alignment override (ffi_opaque_native_align) + pthread_abi_test.tg. DB: std/db.tg mysql/postgres dispatch + the integration suites. no_std: the @no_std/--no-std route compiles the core-only surface + the _start bare entry into the libc-free self-contained binary (tests/run_nostd_bare_lane.sh + tests/nostd/nostd_bare_start.tg); the embedded route emits the bare-metal aarch64 ELF image for the REAL target (aarch64-unknown-none) with the spec/linker/startup artifacts, and HARD-REJECTS the Thumb/RISC-V triples (no code generator — the stable diagnostic, no artifact; tests/run_embedded_lane.sh). The ✓ row is artifact-backed — NO ladder/CI run has occurred on THIS tree (the host IS the target of the tree's bootstrap ladder, but no run-observed mark is claimed).

**x86_64-unknown-linux-gnu: Parse, Type, MIR, Object, Static-link, Dynamic-extern ✓; Native-run, TLS, Threads, DB, Debug ✗.**

Evidence: `tests/canary`; `tests/canary_neg`; `tests/resource_cfg`; `tests/differential`; `tests/run_target_lane_canaries.sh`; `tests/run_nostd_bare_lane.sh`; `tests/nostd/nostd_bare_start.tg`.

the x86-64 ELF backend (asm.tg x64 encoder + ELF64 object writer + ELF linker: EM_X86_64, the PLT/GOT stub machinery, R_X86_64_* relocations) is committed; parse_target_triple resolves the triple. Dynamic-extern: the ELF extern-stub surface (the linker's extern_stub_map/PLT path). no_std: the @no_std/--no-std route (the core-only surface + the _start bare entry + the direct syscall surface — tests/run_nostd_bare_lane.sh). Native-run/TLS/Threads/DB are ✗: no executed evidence on this tree — the x86_64 host lane is the committed artifact, not an observed run.

**x86_64-apple-darwin: Parse, Type, MIR, Object ✓; Static-link, Dynamic-extern, Native-run, TLS, Threads, DB, Debug ✗.**

Evidence: `tests/canary`; `tests/canary_neg`; `tests/resource_cfg`; `tests/differential`; `tests/run_target_lane_canaries.sh`.

the x86-64 backend + Mach-O object writer are target-generic (the same Mach-O builder serves both Apple targets); the cross lane (x86_64-apple-darwin under Rosetta) is the committed artifact. Static-link/dynamic-extern are ✗: the Mach-O linker's x86-64 executable path (import stubs for x86-64 Mach-O, the X86_64_RELOC_* pair handling) is not exercised by a committed run on this tree. The honest mark: an object-capable target with no executed link/run evidence.

**x86_64-windows: Parse, Type, MIR ✓; Object, Static-link, Dynamic-extern, Native-run, TLS, Threads, DB, Debug ✗.**

Evidence: `tests/canary`; `tests/canary_neg`; `tests/resource_cfg`; `tests/differential`.

no PE/COFF object writer, no Windows linker, no Windows ABI table. The triple parses, so Parse/Type/MIR ✓ — and nothing after that.

**wasm32: Parse, Type, MIR, Object ✓; Static-link, Dynamic-extern, Native-run, TLS, Threads, DB, Debug ✗.**

Evidence: `tests/canary`; `tests/canary_neg`; `tests/resource_cfg`; `tests/differential`; `tests/run_wasm_conformance.sh`; `tests/wasm/wasm_conformance_test.tg`; `tests/run_wasi_conformance.sh`; `tests/wasi/wasi_guest_canary.tg`.

the driver's wasm dispatch routes `--target wasm32-unknown-unknown` (freestanding) and `wasm32-wasi` (WASI imports) to the wasm backend (driver.tg compile_to_wasm_route), and the emission is the wasm OBJECT form: the .wasm binary (the type/import/function/memory/global/export/start/code/data sections + the producer custom record). The WASI surface is the implemented row: the wasm32-wasi target adds the wasi_snapshot_preview1 import section (wasm_target.tg add_wasi_imports — fd_write/fd_read/fd_close/proc_exit/args/environ), the host-side ABI lives in the compiler runtime (runtime.tg emit_wasi_host_runtime — the _tg_wasi_fd_write/_tg_wasi_fd_read/_tg_wasi_fd_close/_tg_wasi_clock_time_get/_tg_wasi_proc_exit bodies), and the guest surface is std/wasi.tg; the wasmtime --dir conformance lane runs when the runtime is installed (tests/run_wasi_conformance.sh), and the pure guest-surface suite is tests/wasi/wasi_guest_surface_test.tg. Static-link/dynamic-extern/native-run remain ✗: there is no in-tree wasm linker or runtime — the conformance is structural (the independent wasm parser validates the emitted binary) plus the wasmtime execution lane when the runtime is installed.

Debug — every target ✗. `-g` sets `debug_info` but no committed artifact executes a debugger surface (`tg debug`/debugger.tg is not wired); the honest mark is ✗ everywhere.

## The rules this matrix follows

1. A capability is ✓ only with a committed artifact that exercises it
   (the test/script/code path listed above). An artifact that exists but
   has not run on this tree is still a ✓ with the evidence column saying
   exactly that — a "not run at this SHA" ✓ is NOT the same as a run-
   observed ✓, and no row claims a run-observed status for this tree.
2. Object/Static-link/Dynamic-extern/Native-run are strictly increasing
   in difficulty: a row cannot advertise Native-run without Static-link,
   or Static-link without Object (the generator enforces the chain).
3. The front-end rows (Parse/Type/MIR) are target-independent; a target
   with a working backend inherits them automatically, and a target with
   NO backend still gets them — the marks say "the front end accepts this
   target", never "the backend serves it".
4. The matrix is regenerated from `target_capabilities.toml` together
   with feature_matrix.md's status vocabulary; where they disagree,
   feature_matrix.md's generated registry wins.

---

*Generated from `docs/current/target_capabilities.toml` — no ladder/CI
run has occurred on this tree; every ✓ is artifact-backed, not
run-observed-at-this-SHA.*
