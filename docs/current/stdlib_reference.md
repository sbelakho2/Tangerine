# Tangerine Standard Library Reference

**Version:** 0.1.0  
**Last Updated:** 2026-08-20

This document provides a comprehensive reference for all modules in the Tangerine standard library.

---

## Completeness Status (current, 2026-08)

> **"Stdlib complete" is NOT yet claimable.** That claim requires every
> public module to parse, type-check, compile, link, and pass native tests
> on every advertised Tier-1 target. The current state:

1. **The completeness model (the reviewer's item 32):** every shipped
   `std/*.tg` module belongs to exactly one verification family with a
   minimum proof — the machine-readable contract lives in
   `docs/current/stdlib_contracts.toml`, the rendered model in
   [the Stdlib Completeness Model](stdlib_completeness.md), and the
   automated enumeration gate (`tests/run_stdlib_completeness_gate.sh`,
   run first by the E106 sweep — a REQUIRED CI job) fails on any
   un-contracted module: **a new `std/*.tg` file fails the gate until it
   receives a contract + proof tests.** The module count is computed
   from the `std/*.tg` glob, never typed (the reviewer's table enumerated
   133; the current tree enumerates 131 — `std/postgres.tg` was merged
   into `std/db.tg` and `std/hash_tests.tg` was removed in earlier
   waves).
2. **Bootstrap closure (implemented-unverified):** the 14 std modules in
   `bootstrap/compiler_kernel.manifest` (`alloc`, `args`, `bench`,
   `collections`, `core`, `env`, `ffi`, `fmt`, `fs`, `gfx_errors`, `io`,
   `process`, `taint`, `time`) are compiled by every stage of the bootstrap
   ladder. They have no per-module native test suites.
3. **E106 migration COMPLETE (parse-clean, CI-verified):** every shipped
   std module (all `std/*.tg` files — the count is computed, currently
   131: the 14 kernel modules in
   `bootstrap/compiler_kernel.manifest` plus the 117 non-kernel modules) is
   free of every forbidden syntax class: zero `-> &T` / `-> &mut T`
   returns, zero nested `&` in generic args (`Option[&T]`, `Vec[&T]`,
   `Option<&T>`), zero `&T`-typed fields/consts/let-annotations, zero
   legacy parameter spellings (`x: &T`, `&self`, `&mut self`, fn-type
   conventions `Fn(&T)` — all hard E100 errors in the current dialect),
   zero `as &T` casts, zero `ref`/`for &` patterns, zero lifetime tokens
   (`'static` — the language has no lifetimes), zero `when`-in-enum
   older-dialect variants, zero angle-bracket generic forms
   (`Option<u32>`, `Option[u32>` — the grammar's generics are `[...]`
   only), and zero `Box[dyn Any]` erased results. The gate
   `tests/run_stdlib_e106_sweep.sh` is a **required CI job**
   (`stdlib-e106-sweep` in `.github/workflows/ci.yml`) and enforces this
   in two layers: (1) `tg check` on every std/*.tg module must succeed
   with zero diagnostics (E106/E100/E1100 and any syntax error fail the
   module), and (2) a grep backstop re-scans every module for the
   forbidden syntax classes above, so a module that slips through a
   parsing gap (an angle-bracket form or lifetime token that happens to
   lex as junk) fails even if the check passes. The claim is only as
   strong as the gate: it is CI-required and backstopped. The module
   reference sections below still describe declared surfaces, not
   verified behavior — the modules remain **API-only** until they pass
   per-module native test suites.
4. **The experimental exclusion (the reviewer's item 33 stable-subset
   policy):** the platform-only modules whose targets are
   unsupported/API-only — `wasm`, `wasm_js`, `gpu`, `gpu_metal`,
   `gpu_vulkan`, `gpu_webgpu`, `gfx_gpu`, `hal`, `embedded`, `simd`,
   `effects`, `android`, `ios`, `cocoa`, `windows`, `gui`, `kernel` —
   are flagged experimental in the feature registry (`experimental =
   true` rows with the affected modules listed in `modules = [...]`),
   carry the parse-clean minimum proof only, and are **explicitly
   excluded from the shipped-std behavior claims**. The shipped claim
   covers the non-experimental modules only.
5. **Kernel remainder:** `std/collections.tg` (in the closure) keeps 5
   record-visit extern signatures (`__intrinsic_map_visit_*`,
   `__intrinsic_set_visit_*`) with `Option[&K]`/`&V` returns. They parse
   only through the extern-declaration exception
   (`parse_extern_abi_type`, parser.tg — `&T`/`&mut T` in an `extern`
   declaration whose name carries the `__intrinsic_` prefix denotes the
   internal address/reference ABI); anywhere else the native parser
   records the E106 hard error (`parse_type`). These signatures are the
   kernel's ONLY remaining reference type positions — the documented
   extern-ABI exception, not a migration remainder, and the sweep's
   backstop exempts only the `__intrinsic_`-named extern lines.

### Migration status (former E106-pending table — MIGRATED 2026-08-20)

The former pending table (71 modules / 374 sites: return types and
generic type args containing `&`, including `&mut` and `&` inside generic
arguments such as `Option[&T]`, `Vec[&T]`, and `impl Iterator[Item = &T]`;
one per definition) is EMPTY: all non-kernel modules were converted to the
access model. The conversion classes:

- (a) FFI extern surfaces → raw pointer forms: `&T`/`&mut T` byte-pointer
  params and reference returns became `Ptr[T]`/`PtrMut[T]` (thread's
  pthread externs, mmap's syscall externs, windows' Win32 API
  `Ptr[CHAR]`/`PtrMut[CHAR]`, gpu's Vulkan/CUDA/OpenCL bindings,
  signal/rand syscall externs), with struct-typed conventions
  (`&PthreadT`, `&termios`, `&HANDLE`, ...) kept as parameter conventions.
- (b) Internal view accessors → owned erased-value forms (the kernel
  pattern: `-> &String` → `-> String` with `.clone()`/`&place` bodies,
  `Option[&T]` → `Option[T]`, `Vec[&T]` → `Vec[T]`, `&str` returns →
  `String`, `&[T]`/`&[u8]` views → `Vec[T]`/`FfiSlice[T]`).
- (c) Builder setters (`-> &mut Self`) → owned sink receivers returning
  the owned value (`sink self: X ... -> X`), preserving call chains.
- (d) Generic accessors (`-> &T` / `-> &mut T` on unbound `T`) → the raw
  non-owning pointer surface (`-> Ptr[T]` / `-> PtrMut[T]`, the
  `Box::get` kernel pattern); guard/lock fields holding references became
  `Ptr`/`PtrMut` fields with `&place as Ptr[T]` construction.
- (e) `const X: &str` → `const X: String`; `let x: Vec[&str]` annotations
  → owned element forms; `as &T` casts → `as Ptr[T]`; `impl X for &T` →
  the owned/view type; `for &x in ...` ref patterns → by-value bindings.
- (f) Legacy parameter spellings (`x: &T`, `x: &mut T`, `&self`,
  `&mut self`, fn-type param conventions `Fn(&T)`, closure params
  `|x: &T|`) → the explicit access conventions (`let`/`inout`/`sink`/
  `set`) and owned fn-type conventions (`Fn(inout T)`); these spellings
  are hard E100 errors in the current dialect.
- (g) Older-dialect forms in the same modules: `when`-in-enum variant
  prefixes removed (673 variant lines across 11 modules), `+ 'static`
  lifetime suffixes dropped (8 sites in 4 modules), angle-bracket
  generics converted to `[...]` (50 sites on 25 lines across 7 modules,
  including mixed `Option[u32>` brackets), `Box[dyn Any]` → `Box[Any]`.

Remaining reference-typed positions in std: **zero** outside the
documented `__intrinsic_` extern-ABI exception. The sweep gate
`tests/run_stdlib_e106_sweep.sh` asserts every shipped module (the
computed `std/*.tg` count — currently 131) checks clean AND passes the
forbidden-syntax grep backstop; the gate is a **required CI job**
(`stdlib-e106-sweep` in `.github/workflows/ci.yml`).

---

## Table of Contents

1. [Core Types](#core-types) - `std/core`
2. [Collections](#collections) - `std/collections`
3. [Formatting](#formatting) - `std/fmt`
4. [Memory Allocation](#memory-allocation) - `std/alloc`
5. [Environment](#environment) - `std/env`
6. [Backtrace](#backtrace) - `std/backtrace`
7. [Serialization](#serialization) - `std/serde`, `std/json`, `std/toml`
8. [HTTP & Networking](#http--networking) - `std/http`, `std/url`, `std/net`
9. [Web Framework](#web-framework) - `std/web`
10. [Database](#database) - `std/db`
11. [Cryptography](#cryptography) - `std/crypto`
12. [CLI & Terminal](#cli--terminal) - `std/cli`
13. [Logging & Tracing](#logging--tracing) - `std/log`
14. [Regular Expressions & Parsing](#regular-expressions--parsing) - `std/regex`
15. [Compression & Archives](#compression--archives) - `std/compress`
16. [Date & Time](#date--time) - `std/time`
17. [Async & Concurrency](#async--concurrency) - `std/async`, `std/thread`
18. [I/O & Filesystem](#io--filesystem) - `std/io`, `std/fs`
19. [FFI](#ffi) - `std/ffi`
20. [Testing & Benchmarking](#testing--benchmarking) - `std/test`, `std/bench`
21. [Test Generation](#test-generation) - `std/test_gen`
22. [UI & Graphics](#ui--graphics) - `std/ui`
23. [Contracts & Capabilities](#contracts--capabilities) - `std/contracts`, `std/capabilities`
24. [Profiling & Observability](#profiling--observability) - `std/profile`, `std/snapshot`
25. [Effects & Budgets](#effects--budgets) - `std/effects`, `std/budget`
26. [Secure Types](#secure-types) - `std/secure_types`
27. [Taint Tracking](#taint-tracking) - `std/taint`
28. [Deterministic Replay](#deterministic-replay) - `std/replay`
29. [Semantic Diff](#semantic-diff) - `std/semantic_diff`
30. [Supply Chain Security](#supply-chain-security) - `std/supply_chain`
31. [Mathematics](#mathematics) - `std/math`
32. [Random Numbers](#random-numbers) - `std/random`
33. [Path Manipulation](#path-manipulation) - `std/path`
34. [CSV](#csv) - `std/csv`
35. [YAML](#yaml) - `std/yaml`
36. [CBOR](#cbor) - `std/cbor`
37. [MessagePack](#messagepack) - `std/msgpack`
38. [Signal Handling](#signal-handling) - `std/signal`
39. [Authentication](#authentication) - `std/auth`
40. [Configuration](#configuration) - `std/config`
41. [Debug Utilities](#debug-utilities) - `std/debug`
42. [Semantic Versioning](#semantic-versioning) - `std/semver`
43. [WebAssembly Runtime](#webassembly-runtime) - `std/wasm`
44. [Process Management](#process-management) - `std/process`
45. [Synchronization](#synchronization) - `std/sync`

---

## Core Types

**Module:** `std/core`

Foundation types and traits built into the language.

### Types

- **`Option[T]`** - Optional value that can be `Some(T)` or `None`
- **`Result[T, E]`** - Success `Ok(T)` or error `Err(E)`
- **`Vec[T]`** - Growable array
- **`Map[K, V]`** - Hash map with key-value pairs
- **`Set[T]`** - Hash set of unique values
- **`String`** - UTF-8 encoded string
- **`Rc[T]`** - Single-threaded reference counted pointer
- **`Arc[T]`** - Thread-safe atomic reference counted pointer
- **`Box[T]`** - Heap-allocated value

### Traits

- **`Clone`** - Explicit duplication via `.clone()`
- **`Copy`** - Implicit bitwise copy (opt-in via `@derive(Copy)`)
- **`Drop`** - Destructor called when value goes out of scope
- **`Default`** - Construct default value via `T::default()`
- **`Display`** - User-facing string representation
- **`Debug`** - Debug string representation
- **`Eq`, `PartialEq`** - Equality comparison `==` and `!=`
- **`Ord`, `PartialOrd`** - Ordering comparison `<`, `>`, `<=`, `>=`
- **`Hash`** - Compute hash for use in hash maps/sets
- **`Iterator`** - Iterate over a sequence with `.next()`

---

### `std/diagnostics` - Diagnostics & Observability

Runtime diagnostics, structured logging, and observability (TG-GFX-UI-SPEC-001 v0.1, Section 27).

```tangerine
use std::diagnostics::{LogEntry, LogLevel, LogCategory, FilteredLogger}

let mut logger = FilteredLogger::new(LogLevel::Info, 1000u64)
logger.log(LogEntry {
  timestamp_ns: 123456789u64,
  level: LogLevel::Info,
  category: LogCategory::App,
  message: "Application started".to_string(),
  correlation_id: "req-001".to_string(),
})
```

#### How it fails
- **`InvalidArg`**: Provided logging parameters or capture dimensions are invalid.
- **`Internal`**: Unexpected failure in the diagnostics system or when capturing system state.

#### Security & Capabilities
- Diagnostics are primarily for observability and do not require special capabilities for basic logging.
- Advanced captures (like frame capture or memory snapshots) might be gated by system-specific security policies in the future.

#### Performance
- Logging uses an efficient buffered approach.
- `FilteredLogger` performs O(1) removals when the maximum entry count is reached.
- Large dumps (UI tree, compositor) are generated on-demand to minimize runtime overhead.

#### Compatibility
- Pure Tangerine implementation; consistent across all platforms.
- Structured logs can be exported to platform-specific sinks (e.g., syslog, Windows Event Log) by a custom `Logger` implementation.

---

### `std/config` - Unified Configuration

Layered configuration from environment variables, files (TOML, JSON, YAML), defaults, and overrides.

```tangerine
use std::config::{ConfigBuilder, Value}

let config = ConfigBuilder::new()
  .defaults(my_defaults)
  .file_optional("config.toml")
  .env("MYAPP")
  .set("debug", Value::Bool(true))
  .build()?;

let port = config.get_int("server.port")?;
```

#### How it fails
- **`NotFound`**: A requested configuration key does not exist.
- **`TypeError`**: The configuration value exists but cannot be converted to the requested type.
- **`ParseError`**: A configuration file contains syntax errors.
- **`IoError`**: A configuration file could not be read.
- **`MergeConflict`**: A structural conflict occurred during source merging (e.g., trying to merge a table with a scalar).

#### Security & Capabilities
- Loading configuration from files requires the `File` capability.
- Loading from environment variables requires the `Env` capability.
- Programmatic overrides (`set`, `set_all`, `defaults`) are pure and do not require capabilities.

#### Performance
- Source merging is performed once during `build()`.
- Access via `get` is O(D) where D is the depth of the nested key path.
- Reference implementations use efficient hash maps for storage.

#### Compatibility
- Consistent behavior across Linux, macOS, Windows, and Web.
- Path handling is platform-aware.
- Environment variable case-sensitivity follows platform conventions (case-insensitive on Windows, case-sensitive on others).

---

### `std/crypto` - Cryptography

Safe cryptographic primitives and binary encoding utilities (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::crypto::{sha256, aes_encrypt, aes_decrypt}

let data = "hello world".as_bytes()
let hash = sha256(data)

let key = [0u8; 16] # 128-bit key
let encrypted = aes_encrypt(&key, data)?
let decrypted = aes_decrypt(&key, &encrypted)?
```

#### How it fails
- **`InvalidKey`**: The provided key length is incorrect for the chosen algorithm (e.g., 10 bytes for AES-128).
- **`InvalidInput`**: The input data is malformed or has an incorrect size for the operation (e.g., ciphertext block size mismatch).
- **`Unsupported`**: The requested cryptographic algorithm or mode is not supported by the current backend.
- **`Internal`**: An unexpected error occurred within the cryptographic provider.

#### Security & Capabilities
- Cryptographic operations are pure CPU-bound tasks and do not require special capabilities themselves.
- Key generation (randomness) requires the `Random` capability.
- Hardware-backed key storage (Secure Enclave, TPM) requires specific platform capabilities.

#### Performance
- Hash functions (SHA-2, SHA-3) are highly optimized for streaming data.
- AES implementation uses hardware acceleration (AES-NI, ARM Cryptography Extensions) when available.
- Reference implementations are constant-time where required to prevent side-channel attacks.

#### Compatibility
- Consistent behavior across Linux, macOS, Windows, and Web (Wasm).
- Uses platform-native providers (CommonCrypto, BCrypt, OpenSSL) for performance and security.

---

### `std/ctx` - Context Packs

Deterministic, budgeted context pack generation for agent consumption (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::ctx::{build_pack}

let seeds = ["my_module::my_function".to_string()]
let pack = build_pack(seeds, 10000)?
println("Generated pack with ID: " + pack.id)
```

#### How it fails
- **`BudgetExceeded`**: The requested budget is too small to include the minimum necessary context (e.g., the seed itself).
- **`InvalidArg`**: One or more provided seed symbols could not be found in the symbol graph.
- **`Internal`**: An error occurred during the submodular optimization or pack serialization.

#### Security & Capabilities
- Context pack generation is a pure analysis task based on the project's symbol graph.
- It does not require special capabilities, but its output might contain sensitive information (source code excerpts).
- Access to the underlying symbol graph and source files is governed by the compiler's safety policies.

#### Performance
- Pack selection uses a submodular greedy algorithm with O(N * K) complexity, where N is the number of candidates and K is the budget.
- The reference implementation is optimized for typical project sizes (10k-100k symbols).

#### Compatibility
- Context packs are serialized to a canonical JSON format (`ctxpack.schema.json`) for cross-tool and cross-agent compatibility.
- Hashing (SHA-256) ensures pack IDs are consistent across different machines and OSs.

---

### `std/serde` - Serialization

Format-agnostic serialization and deserialization framework (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
#[derive(Serialize, Deserialize)]
struct User {
  id: Int,
  name: String,
}

let user = User { id: 1, name: "Alice".to_string() };
let value = to_value(&user)?;
let json = std::json::stringify(&value);
```

#### How it fails
- **`InvalidType`**: Data type mismatch during deserialization (e.g., expected `Int`, got `String`).
- **`MissingField`**: A required struct field is missing from the input.
- **`UnexpectedToken`**: Malformed input format.
- **`InvalidValue`**: A value was successfully parsed but is invalid for the target type (e.g., out-of-range integer).
- **`Eof`**: Unexpected end of input.
- **`Io`**: Error reading from or writing to an I/O stream.

#### Security & Capabilities
- `serde` is a pure data transformation library and does not require special capabilities.
- Format-specific parsers (like `std/json`) implement depth limits to prevent stack overflow attacks.

#### Performance
- Zero-copy deserialization is supported for some formats.
- Derived implementations are generated at compile-time for maximum efficiency.
- Intermediate `Value` representation allows for flexible, though slightly less performant, dynamic data handling.

#### Compatibility
- Pluggable format registry allows adding support for new formats (JSON, TOML, YAML, MsgPack, etc.).
- Consistent behavior across all Tangerine platforms and targets.

---

### `std/json` - JSON Format

Full RFC 8259 compliant JSON parsing and generation.

```tangerine
use std::json::{parse, stringify}

let obj = parse("{\"key\": 42}")?;
let s = stringify(&obj);
```

#### How it fails
- **`UnexpectedChar`**: An invalid character was encountered at a given line/column.
- **`UnexpectedEof`**: The JSON string ended prematurely.
- **`MaxDepthExceeded`**: The nesting depth of the JSON exceeded the safe limit (`MAX_JSON_DEPTH`).
- **`TrailingComma`**: A trailing comma was found in an object or array (forbidden by spec).

#### Security & Capabilities
- Implements strict RFC 8259 compliance.
- Depth limiting (default 128) prevents recursion-based DoS.

---

### `std/math` - Mathematics

Floating point math, integer utilities, and arbitrary-precision arithmetic (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::math::{PI, sin, BigInt, BigDecimal}

let y = sin(PI / 2.0); # 1.0

let large = BigInt::from_string("123456789012345678901234567890".to_string())?;
let precise = BigDecimal::from_string("1.23456789".to_string())?;
```

#### How it fails
- **`InvalidArg`**: Provided arguments are outside the domain of the function (e.g., negative factorial, division by zero).
- **`Internal`**: Unexpected error in the mathematical provider or hardware.

#### Security & Capabilities
- Pure computational library; no special capabilities required.
- Contract-gated functions provide runtime protection against invalid inputs.

#### Performance
- Floating point operations delegate to platform-optimized `libm` via FFI.
- BigInt/BigDecimal implementations are optimized for common financial and engineering use cases.

#### Compatibility
- Consistent behavior across all Tangerine platforms.
- IEEE 754 compliance for floating point operations.

---

### `std/random` - Randomness

Fast pseudo-random and cryptographically-secure random number generation (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::random::{Xoshiro256StarStar, Rng, thread_rng}

let mut rng = Xoshiro256StarStar::from_seed(42u64);
let x = rng.next_float(); # [0.0, 1.0)
let i = rng.next_int_range(1, 100);

let mut secure_rng = CryptoRng::new();
let bytes = secure_rng.fill_bytes(&mut buf);
```

#### How it fails
- **`InvalidArg`**: Provided range or distribution parameters are invalid (e.g., negative standard deviation).
- **`Internal`**: Unexpected failure in the entropy source or the PRNG state.

#### Security & Capabilities
- Fast PRNGs (`Xoshiro256StarStar`, `Pcg32`) are for simulation and non-security tasks.
- Cryptographically secure RNGs (`CryptoRng`) are backed by OS entropy and should be used for all security-sensitive operations.
- `from_entropy()` and `CryptoRng` require the `Random` capability.

#### Performance
- `Xoshiro256StarStar` is among the fastest 64-bit PRNGs.
- `thread_rng()` provides a pre-seeded, high-performance RNG to minimize initialization overhead.
- `CryptoRng` may be slower as it potentially involves syscalls to the OS entropy source.

#### Compatibility
- Floating point generation uses a standard 53-bit shift for consistency.
- Distributions (Uniform, Normal, Bernoulli, Exponential) are implemented using deterministic algorithms.

---

### `std/cli` - CLI Foundation

Command-line argument parsing, terminal handling, and utilities (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::cli::{App, Arg, Flag}

let mut app = App::new("myapp", "A sample app")
  .arg(Arg::new("input").required(true))
  .flag(Flag::new("verbose").short('v'));

let matches = app.parse()?;
if matches.get_bool("verbose") {
  println("Verbose mode enabled");
}
```

#### How it fails
- **`UnknownFlag`**: An unrecognized flag was provided on the command line.
- **`MissingArg`**: A required positional argument was not provided.
- **`MissingValue`**: A flag that requires a value was provided without one.
- **`HelpDisplayed` / `VersionDisplayed`**: Special "errors" returned when help or version information is printed, to signal that the program should exit.

#### Security & Capabilities
- Parsing arguments requires the `Env` capability to access `env::args()`.
- Terminal control and cursor manipulation require the `Io` capability.
- Password prompts mask input to prevent sensitive data from leaking to the terminal.

#### Performance
- Argument parsing is O(N) where N is the number of provided arguments.
- Minimal allocations during parsing; use of internal hash maps for fast lookup of matched values.

#### Compatibility
- ANSI color and style codes are used for terminal output; these are automatically disabled if stdout is not a TTY.
- Cross-platform support for terminal size detection (`ioctl` on Linux/macOS, Win32 API on Windows).

---

### `std/assets` - Asset Management

Asset loading, content-addressable caching, and hot reloading (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::assets::{load_image, load_font}

let fs = fs_cap();
let (id, bitmap) = load_image("assets/player.png".to_string(), &fs)?;
println("Loaded asset with SHA-256: " + id.hash_hex());
```

#### How it fails
- **`IOError`**: The asset file could not be found or read from disk.
- **`InvalidData`**: The asset file format is recognized but the content is malformed.
- **`Unsupported`**: The asset format (e.g., a specific image codec) is not supported by the backend.

#### Security & Capabilities
- Asset loading from the filesystem requires the `Fs` capability.
- Assets are identified by their SHA-256 content hash, enabling secure content-addressable storage.

#### Performance
- Decoded assets are cached by their `AssetId` to prevent redundant processing.
- Loading is asynchronous in production backends to avoid blocking the main thread.

#### Compatibility
- Consistent asset ID generation across all platforms.
- Pluggable decoders for various formats (PNG, JPEG, TrueType, etc.).

---

### `std/audit` - Code Audit

Deterministic audit reports covering safety, security, and quality signals (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::audit::{run_audit, Severity}

let report = run_audit("std/".to_string())?;
for finding in report.findings {
  if finding.severity == Severity::Critical {
    println("CRITICAL: " + finding.message);
  }
}
```

#### How it fails
- **`InvalidArg`**: The provided audit scope is invalid or inaccessible.
- **`Internal`**: Unexpected error during static analysis or report generation.

#### Security & Capabilities
- Auditing is a pure analysis task and does not require special capabilities.
- It provides visibility into "capability drift" and "taint flows" across the codebase.

#### Performance
- Audit passes are designed to be run in parallel where possible.
- The reference implementation is a skeletal reporter; production versions integrate with the compiler's analysis engine.

#### Compatibility
- Consistent finding IDs across all Tangerine tools.
- Normalized location reporting for cross-platform IDE integration.

---

### `std/async` - Async Runtime

Cooperative multitasking with `async/await`, task spawning, and I/O multiplexing (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::async::{Executor, sleep}

let mut ex = Executor::new()?;
ex.spawn(async {
  println("Hello from task!");
  sleep(Duration::from_secs(1)).await;
  println("Goodbye from task!");
});

ex.run();
```

#### How it fails
- **`TaskPanic`**: An async task panicked during execution.
- **`Io`**: An error occurred in the underlying I/O reactor (e.g., `epoll` or `kqueue` failure).
- **`Internal`**: Unexpected error in the task scheduler or waker mechanism.

#### Security & Capabilities
- Spawning tasks and running the executor is an effectful operation (`Async`).
- I/O reactor handles file descriptors securely, ensuring tasks only access authorized resources.

#### Performance
- Zero-allocation futures for simple state machines.
- O(1) task scheduling and O(log N) timer management.
- Efficient I/O multiplexing using platform-native APIs.

#### Compatibility
- **Linux**: Uses `epoll`.
- **macOS/BSD**: Uses `kqueue`.
- **Windows/Embedded**: Uses a portable fallback based on `select` or a simple polling loop.

---

### `std/compositor` - Layer Composition

Layer-based composition, damage tracking, and hardware-accelerated blending (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::compositor::{layer_tree_new, add_layer, compose}

let mut tree = layer_tree_new();
let layer_id = add_layer(&mut tree, rect, 1.0, Transform2D::identity());

compose(&tree, &mut canvas)?;
```

#### How it fails
- **`BackendUnavailable`**: The graphics backend required for hardware composition is lost or unavailable.
- **`InvalidLayer`**: Attempted to manipulate a layer ID that no longer exists.
- **`Unsupported`**: The current hardware does not support the requested blending mode or layer count.
- **`OutOfMemory`**: Failed to allocate backing store for a new layer or cached surface.

#### Security & Capabilities
- Composition requires the `Display` capability to output to a window or screen.
- Layer isolation ensures that one layer's drawing commands cannot read from or interfere with another's memory unless explicitly shared.

#### Performance
- Damage tracking ensures only modified regions are re-composed, minimizing GPU bandwidth.
- Cached surfaces (`Layer::cached`) allow complex sub-trees to be drawn once and reused as textures.

#### Compatibility
- Consistent blending behavior across all supported GPU backends (Vulkan, Metal, DX12).
- Pure software fallback for platforms without hardware acceleration.

---

### `std/device` - Device Abstraction

Physical and logical device abstraction for input, sensors, and hardware state (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::device::{list_devices, DeviceKind}

let devices = list_devices(Some(DeviceKind::Keyboard))?;
for dev in devices {
  println("Found device: " + dev.name);
}
```

#### How it fails
- **`NotFound`**: A specifically requested device ID could not be found.
- **`PermissionDenied`**: The application does not have permission to access the requested hardware device.
- **`Unsupported`**: The current platform or hardware does not support the requested device type (e.g., gyroscope on a desktop).
- **`Internal`**: An error occurred in the platform's device driver or subsystem.

#### Security & Capabilities
- Accessing hardware devices requires the `Display` or specific hardware capabilities.
- Device IDs are anonymized where possible to prevent hardware-based fingerprinting.

#### Performance
- Device listing is O(N) where N is the number of connected devices.
- State updates (e.g., sensor data) use a high-frequency event stream or shared memory buffers.

#### Compatibility
- Maps to `udev` on Linux, `IOKit` on macOS, and `Win32/HID` on Windows.
- Standardized `DeviceKind` enum ensures portable input handling.

---

### `std/embed_trace` - Embedded Tracing

Embedded-friendly deterministic tracing and transcript capture for replay and emulator comparison (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::embed_trace::{TraceBuffer, create_transcript}

let mut buffer = TraceBuffer::new(1024);
buffer.record(0x01, [1, 2, 3, 0, 0, 0, 0, 0])?;

let csv = create_transcript(&buffer);
```

#### How it fails
- **`BufferFull`**: The fixed-size trace buffer has reached its capacity.
- **`InvalidArg`**: Provided event ID or data payload is invalid.
- **`Internal`**: Unexpected error in the timing source or buffer management.

#### Security & Capabilities
- Recording traces requires the `Io` capability if they are to be persisted to disk.
- Fixed-size data payloads prevent memory exhaustion attacks in memory-constrained environments.

#### Performance
- Recording is O(1) and designed to be called from high-frequency loops or interrupt handlers.
- Minimal overhead; no dynamic allocation during `record()` once the buffer is initialized.

#### Compatibility
- Deterministic timestamps and event ordering allow for exact replay across physical hardware and emulators.
- CSV transcript format is portable across all analysis tools.

---

### `std/encoding` - Binary Encoding

Strict, efficient binary-to-text and text-to-binary encodings (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::encoding::{hex_encode, hex_decode}

let data = [0x41, 0x42, 0x43];
let hex = hex_encode(&data); # "414243"
let back = hex_decode(&hex)?;
```

#### How it fails
- **`InvalidInput`**: The input string contains characters that are not valid for the chosen encoding (e.g., 'G' in hex) or has an invalid length.
- **`BufferFull`**: The provided output buffer is too small for the encoded/decoded result.
- **`Internal`**: Unexpected error in the encoding engine.

#### Security & Capabilities
- Encodings are pure data transformations and do not require special capabilities.
- Strict validation prevents "encoding-based attacks" like null-byte injection or invalid UTF-8 sequences.

#### Performance
- Highly optimized loops for Base64 and Hex.
- Minimal allocations; supports encoding/decoding directly into provided buffers.

#### Compatibility
- RFC 4648 compliant for Base64 and Hex.
- Consistent behavior across all platforms and endians.

---

### `std/fuzz` - Fuzzing Foundation

Fuzz harness support including corpus capture, deterministic seeds, and minimization (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::fuzz::{FuzzHarness}

let mut h = FuzzHarness::new("my_parser".to_string(), 42u64);
let input = h.next_input(1024);
# Test your function with input
```

#### How it fails
- **`InvalidArg`**: Provided harness parameters are invalid.
- **`CorpusFull`**: The in-memory corpus has reached its size limit.
- **`Internal`**: Unexpected error in the fuzzing engine.

#### Security & Capabilities
- Fuzzing requires the `Random` capability for generating inputs.
- Corpus persistence requires the `Fs` capability.

#### Performance
- Input generation is O(N) where N is the requested length.
- Minimal overhead; designed for high-throughput fuzzing loops.

#### Compatibility
- Deterministic seeds ensure identical input sequences across all platforms.
- Corpus format is portable between different OS/arch combinations.

---

### `std/hal` - Hardware Abstraction

Hardware Abstraction Layer for CPU, GPU, and specialized accelerators (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::hal::{init_hal, HalConfig, BackendKind}

let config = HalConfig {
  preferred_backend: Some(BackendKind::Vulkan),
  enable_validation: true,
};

let instance = init_hal(config)?;
println("Initialized HAL with " + instance.device_count.fmt() + " devices");
```

#### How it fails
- **`InvalidBackend`**: The requested hardware backend (e.g., Vulkan) is not available on this system.
- **`DeviceLost`**: The connection to the physical hardware device was lost during or after initialization.
- **`Internal`**: Unexpected error in the HAL provider or native driver.

#### Security & Capabilities
- Hardware initialization requires the `Display` capability.
- Memory isolation is enforced between different hardware contexts.

#### Performance
- Zero-cost abstractions over native graphics APIs.
- Minimized overhead for command submission and buffer synchronization.

#### Compatibility
- Supports Vulkan (Linux/Windows), Metal (macOS/iOS), D3D12 (Windows), and Software fallback.
- Unified interface for compute and graphics tasks across all backends.

---

### `std/gfx` - 2D Graphics

Normative 2D drawing API including Paint, Stroke, Blend, Surface, and Canvas (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::gfx::{surface_offscreen, Paint, Color}

let cap = display_cap();
let mut surface = surface_offscreen(800, 600, cap)?;
let mut canvas = surface.begin_frame()?;

canvas.clear(Color::WHITE);
canvas.fill_rect(Rect::new(10, 10, 100, 100), &Paint::solid(Color::RED));

surface.end_frame()?;
```

#### How it fails
- **`InvalidArg`**: Provided coordinates, dimensions, or state stack operations are invalid.
- **`Unsupported`**: The requested blending mode or path operation is not supported by the current backend.
- **`BackendLost`**: The connection to the GPU backend was lost.
- **`Internal`**: Unexpected error in the rendering engine.

#### Security & Capabilities
- Accessing the display or offscreen surfaces requires the `Display` capability.
- Drawing commands are validated to ensure they stay within surface bounds.

#### Performance
- Command batching and hardware acceleration (Vulkan/Metal) are used where available.
- Software rasterizer provides a deterministic CPU reference path for testing.

#### Compatibility
- Consistent rendering output across all platforms through the use of a shared reference rasterizer.
- Supports sRGB and other high-dynamic-range color spaces.

---

### `std/gfx_gpu` - GPU Abstraction

Explicit GPU resource management and compute/graphics pipeline control (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::gfx_gpu::{instance_new, BufferUsage}

let instance = instance_new()?;
let adapters = instance_adapters(&instance);
let (device, queue) = adapter_request_device(&adapters[0])?;

let buffer = buffer_create(&device, 1024, [BufferUsage::Vertex].to_vec())?;
```

#### How it fails
- **`OutOfMemory`**: Failed to allocate GPU-resident memory for a buffer or texture.
- **`DeviceLost`**: The physical GPU device was disconnected or reset by the OS.
- **`Unsupported`**: The requested feature (e.g., specific texture format) is not supported by the hardware.
- **`InvalidArg`**: Provided resource handles or parameters are invalid.

#### Security & Capabilities
- Explicit resource management prevents hidden side effects.
- Access to the GPU is gated by the `Display` capability.
- Memory isolation between different application contexts is enforced by the hardware and driver.

#### Performance
- Zero-overhead mapping to Vulkan, Metal, and D3D12.
- Supports asynchronous command submission and multi-threaded resource creation.

#### Compatibility
- Consistent behavior across a wide range of hardware through a unified abstraction.
- Automatic feature probing and fallback to software rendering where necessary.

---

### `std/graph` - Symbol Graph

Persistent symbol, effect, contract, and test graph with incremental indexing and query engine (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::graph::{load_graph, SymbolGraph}

let graph = load_graph("project.tg")?;
let deps = graph.query_dependencies("my_module::my_function");
```

#### How it fails
- **`NotFound`**: A requested symbol or edge does not exist in the graph.
- **`InvalidGraph`**: The persisted graph file is malformed or uses an incompatible version.
- **`Internal`**: Unexpected error in the graph indexing or query engine.

#### Security & Capabilities
- Loading and saving the graph requires the `Fs` capability.
- The graph provides a "view" of the codebase that respects visibility and safety boundaries.

#### Performance
- Incremental indexing ensures that only modified files are re-processed, maintaining O(1) performance for most changes.
- Dependency queries use optimized adjacency lists for fast traversal.

#### Compatibility
- Consistent graph schema across all Tangerine platforms.
- Stable symbol IDs ensure portability of analysis results.

---

### `std/secure_types` - Secure Wrappers

Sealed wrappers for sensitive data including `Secret`, `SqlQuery`, `HtmlSafe`, `SafeUrl`, and `SafePath`.
**Module status: experimental** — the wrappers scope what code can accidentally do with the value; the Secret zeroization guarantees are the FUTURE production behavior (volatile/non-elidable zero-on-drop is not implemented today).

```tangerine
use std::secure_types::{Secret, sql_query, html_escape, safe_url_parse, path_parse}

let password = Secret::new("p@ssword".to_string());
# password is not reachable through the type's public surface (only the
# capability-gated expose() returns it)

let q = sql_query("SELECT * FROM users WHERE id = $1".to_string(), Vec::from([SqlParam::Int(1)]));
let html = html_escape("<script>".to_string()); # "&lt;script&gt;"
let url = safe_url_parse("https://example.com"); # Result — the built-in parser
let path = path_parse("data/report.csv");        # Result — traversal-rejecting
```

#### How it fails
- **`AccessDenied`**: Attempted to expose a `Secret` without the `Unsafe` capability.
- **`InvalidInput`**: Provided a malformed SQL template or an unsafe URL/path traversal.
- **`Internal`**: Unexpected error in the security provider.

#### Security & Capabilities
- `Secret::expose` requires the `Unsafe` capability.
- `SqlQuery` prevents SQL injection by enforcing parameterized templates at construction time.
- `HtmlSafe` prevents XSS by requiring explicit escaping or trusted-source marking.
- `SafeUrl` validation is PARSER-BASED: the built-in split_url blocks the javascript:/vbscript: schemes; it is not the full RFC 3986 grammar.

#### Performance
- The wrappers are plain structs — no runtime indirection beyond the sealed constructors.
- Memory for `Secret` types is NOT zeroed when dropped (the zeroization is the future production behavior).

#### Compatibility
- The sealed construction and validation behavior is platform-independent.
- `SafeUrl`/`SafePath` validation follows the built-in parser rules documented above, not a platform URL library.

---

### `std/taint` - Taint Tracking

Static and dynamic taint analysis for tracking and validating untrusted data (TG-GFX-UI-SPEC-001 v0.1).

```tangerine
use std::taint::{taint, validate, TaintLabel, MaxLengthValidator}

let data = taint("user_input".to_string(), TaintLabel::UserInput);
let clean = validate(&data, &MaxLengthValidator { max_len: 10 })?;
```

#### How it fails
- **`ValidationError`**: Tainted data failed to satisfy the requirements of the chosen validator.
- **`Internal`**: Unexpected error in the taint propagation engine.

#### Security & Capabilities
- Integrates with the compiler's static analysis to prevent unvalidated data from reaching sensitive sinks (SQL, Shell, HTML).
- Taint labels track the provenance of untrusted data across function boundaries.

---

## Collections

**Module:** `std/collections`

Core collection types backed by compiler intrinsics.

```tangerine
use std::collections::{Array, Map, Set, array_new, array_push, array_pop,
                       map_new, map_get, map_insert, set_new, set_insert}

# Array (growable)
mut arr = array_new[Int]()
array_push(&mut arr, 42)
array_push(&mut arr, 7)
let len = array_len(&arr)       # 2
let item = array_get(&arr, 0)   # &42
let popped = array_pop(&mut arr) # Option::Some(7)

# Map (hash map)
mut map = map_new[String, Int]()
map_insert(&mut map, "x", 10)
let val = map_get(&map, "x")    # Option::Some(&10)

# Set (hash set)
mut set = set_new[Int]()
set_insert(&mut set, 1)
let has = set_contains(&set, 1) # true
```

**Traits:**
- `Iterator[T]` - `advance(&mut Self) -> Option[T]`
- `IntoIterator[T]` - `into_iter(self) -> Iterator[T]`
- `Iterable[T]` - `iter(&Self) -> Iterator[T]`

---

## Formatting

**Module:** `std/fmt`

Printing, Display/Debug traits, and string formatting.

```tangerine
use std::fmt::{format, print, puts, Display, Debug}

# {} positional substitution, {N} indexed, {{ / }} literal braces
let msg = format("Hello, {}! You are #{}", ["Alice", "42"])
print(msg)       # no newline
puts("world")    # with newline

# Trait-based formatting
impl Display for MyStruct
  def display(&self) -> String
    format("MyStruct({})", [self.name])
  end
end
```

**API:**
- `format(fmt: String, args: Array[String]) -> String`
- `print(x: String) -> Unit`
- `puts(x: String) -> Unit`
- `parse_int(s: String) -> Option[Int]`
- `int_to_string(x: Int) -> String`
- `bool_to_string(x: Bool) -> String`

---

## Memory Allocation

**Module:** `std/alloc`

Pluggable memory allocator interface with libc integration.

```tangerine
use std::alloc::{Allocator, Layout, SystemAllocator, ArenaAllocator,
                 system_allocator, arena_new, arena_reset, arena_destroy}

# System allocator (wraps libc malloc/free)
let sys = system_allocator()

# Layout for memory requests
let layout = layout_new(256, 8)?  # 256 bytes, 8-byte alignment

# Arena (bump) allocator — fast bulk allocation/deallocation
mut arena = arena_new(65536)
# ... allocate from arena ...
arena_reset(&mut arena)    # reset without freeing backing memory
arena_destroy(&mut arena)  # release backing memory
```

**Trait:** `Allocator`
- `allocate(&Self, Layout) -> Result[*mut u8, String]`
- `deallocate(&Self, *mut u8, Layout)`
- `reallocate(&Self, *mut u8, Layout, new_size: UInt) -> Result[*mut u8, String]`

**Types:**
- `Layout` - Size + alignment descriptor
- `SystemAllocator` - Stateless libc allocator
- `ArenaAllocator` - Bump allocator with buffer, capacity, offset

---

## Environment

**Module:** `std/env`

Environment variables and process arguments.

```tangerine
use std::env::{args, var, set_var, current_dir}

let arguments = args()                  # Array[String]
let home = var("HOME")                  # Option[String]
set_var("MY_VAR", "value")
let cwd = current_dir()?               # Result[String, IOError]
```

---

## Backtrace

**Module:** `std/backtrace`

Runtime backtrace capture and display using DWARF/dladdr.

```tangerine
use std::backtrace::{capture, capture_force, Backtrace, BacktraceStatus}

# Respects TANGERINE_BACKTRACE env var
let bt = capture()
if bt.status == BacktraceStatus::Captured then
  for frame in bt.frames do
    puts(format("  {} at {}:{}", [frame.symbol_name, frame.file,
                                   int_to_string(frame.line)]))
  end
end

# Force capture regardless of env setting
let forced = capture_force()
```

**Types:**
- `Backtrace` - `frames: Vec[StackFrame]`, `status: BacktraceStatus`
- `StackFrame` - `ip`, `symbol_name`, `file`, `line`, `column`, `module_name`, `offset`
- `BacktraceStatus` - `Captured`, `Disabled`, `Unsupported`

**Constants:**
- `MAX_FRAMES: UInt = 128`

---

## Serialization

### `std/serde` - Serialization Framework

Core traits for serialization and deserialization.

```tangerine
use std::serde::{Serialize, Deserialize}

@derive(Serialize, Deserialize)
struct User
  name: String
  age: Int
  email: String
end
```

**Key Traits:**
- `Serialize` - Serialize value to bytes
- `Deserialize` - Deserialize from bytes
- `Serializer` - Backend that writes serialized data
- `Deserializer` - Backend that reads serialized data

### `std/json` - JSON Support

RFC 8259 compliant JSON parsing and generation.

```tangerine
use std::json::{Json, JsonValue}

# Parsing
let value: JsonValue = Json::parse_value(r#"{"name": "Alice", "age": 30}"#)?
let user: User = Json::parse(json_str)?

# Generation
let json = Json::stringify(&user)
let pretty = Json::stringify_pretty(&user, 2)

# Manual construction
let obj = JsonValue::Object(Map::from([
  ("name".to_string(), JsonValue::String("Alice".to_string())),
  ("age".to_string(), JsonValue::Number(30.0))
]))
```

**API:**
- `Json::parse[T](s: &str) -> Result[T, JsonError]` - Parse JSON into typed struct
- `Json::parse_value(s: &str) -> Result[JsonValue, JsonError]` - Parse into dynamic value
- `Json::stringify[T](value: &T) -> String` - Serialize to compact JSON
- `Json::stringify_pretty[T](value: &T, indent: UInt) -> String` - Pretty-print

### `std/toml` - TOML Configuration

TOML v1.0.0 configuration file parsing.

```tangerine
use std::toml::{Toml, TomlValue}

let config: Config = Toml::parse(toml_str)?
let value: TomlValue = Toml::parse_value(toml_str)?
let output = Toml::stringify(&config)
```

Supports all TOML features:
- Tables and inline tables
- Arrays and array of tables
- Strings (basic, literal, multi-line)
- Integers (decimal, hex, octal, binary)
- Floats (including inf, nan)
- Booleans
- Dates and times (RFC 3339)

---

## HTTP & Networking

### `std/http` - HTTP Client & Server

Full-featured HTTP/1.1 implementation with TLS support via OpenSSL.

```tangerine
use std::http::{HttpClient, HttpServer, HttpRequest, HttpResponse, HttpMethod}

# HTTP Client
let client = HttpClient::new()
let response = client.get("https://api.example.com/users")?
let json: Vec[User] = response.json()?

# With headers
let response = client.post("https://api.example.com/users")
  .header("Content-Type", "application/json")
  .body(Json::stringify(&new_user))
  .send()?

# HTTP Server
let server = HttpServer::bind("0.0.0.0:8080")?
loop
  let request = server.accept()?
  let response = handle_request(request)
  server.respond(response)?
end
```

**Features:**
- TLS/SSL via OpenSSL FFI
- Streaming request/response bodies
- Connection pooling
- Redirects following
- Timeout support

### `std/url` - URL Parsing

RFC 3986 compliant URL parsing and manipulation.

```tangerine
use std::url::{Url, UrlBuilder}

# Parsing
let url = Url::parse("https://example.com:8080/path?key=value#fragment")?

# Construction
let url = UrlBuilder::new()
  .scheme("https")
  .host("api.example.com")
  .path("/v1/users")
  .query_param("limit", "10")
  .build()?

# Manipulation
let resolved = base_url.join("/relative/path")?
```

---

## Web Framework

### `std/web` - Web Application Framework

High-level web framework with routing, middleware, templates, and authentication.

```tangerine
use std::web::{App, Context, Router, StatusCode, middleware}

# Basic application
let app = App::new()

# Middleware
app.middleware(middleware::logger)
app.middleware(middleware::cors)
app.middleware(middleware::compression)

# Routes
app.get("/", |ctx: &mut Context| do
  ctx.html("<h1>Home</h1>")
end)

app.get("/users/:id", |ctx: &mut Context| do
  let id = ctx.param("id").unwrap()
  let user = get_user(id)?
  ctx.json_response(&user)
end)

app.post("/users", |ctx: &mut Context| do
  let user: User = ctx.json()?
  let created = create_user(user)?
  ctx.status(StatusCode::Created).json_response(&created)
end)

# Static files
app.static_files("/static", "./public")

# Start server
app.listen("0.0.0.0:8080")?
```

**Features:**
- Pattern-based routing with path parameters
- Built-in middleware (CORS, compression, rate limiting, logging)
- Template engine (Jinja2-like syntax)
- JWT and session-based authentication
- Cookie management
- File uploads
- WebSocket support is not yet available in `std::web`

**Template Example:**

```tangerine
use std::web::{Template}

let tmpl = Template::parse(r#"
  <h1>Hello {{ name }}!</h1>
  {% for item in items %}
    <li>{{ item }}</li>
  {% endfor %}
"#)?

let html = tmpl.render(&Map::from([
  ("name", JsonValue::String("Alice".to_string())),
  ("items", JsonValue::Array(vec![...]))
]))?
```

**Authentication:**

```tangerine
use std::web::auth::{create_jwt, verify_jwt, jwt_middleware, hash_password}

# Create JWT
let payload = Map::from([("user_id", JsonValue::Number(123.0))])
let token = create_jwt(&payload, secret)?

# Verify JWT
let claims = verify_jwt(&token, secret)?

# Password hashing
let hashed = hash_password("user_password")
let valid = verify_password("user_password", &hashed)

# JWT middleware
app.middleware(jwt_middleware(secret))
```

---

## Database

### `std/db` - Database Abstraction Layer

Unified interface for SQL databases with drivers for SQLite and PostgreSQL.

```tangerine
use std::db::{Connection, Sqlite, Postgres, QueryBuilder, Pool}

# SQLite
let db = Sqlite::open("app.db")?
db.execute("CREATE TABLE users (id INTEGER PRIMARY KEY, name TEXT, email TEXT)")?

let rows = db.query("SELECT * FROM users WHERE age > ?", (18,))?
for row in rows do
  let id: Int = row.get(0)?
  let name: String = row.get(1)?
end

# Prepared statements
db.execute_params("INSERT INTO users (name, email) VALUES (?, ?)", 
  ("Alice", "alice@example.com"))?

# PostgreSQL
let pg = Postgres::connect("postgres://user:pass@localhost/mydb")?
let rows = pg.query("SELECT * FROM users WHERE active = $1", (true,))?

# Query Builder
let (sql, params) = QueryBuilder::new()
  .select("id, name, email")
  .from("users")
  .where_clause("age > ? AND active = ?")
  .order_by("created_at DESC")
  .limit(10)
  .build()

let rows = db.query(&sql, params)?

# Connection Pool
let pool = Pool::new(|| Postgres::connect(conn_string), 10)?
let conn = pool.get()?
let result = conn.query("SELECT * FROM users", ())?
```

**Migration Support:**

```tangerine
use std::db::Migrator

let migrator = Migrator::new(db)
migrator.create_migration_table()?
migrator.run_migration("001_create_users", r#"
  CREATE TABLE users (
    id SERIAL PRIMARY KEY,
    name VARCHAR(255),
    created_at TIMESTAMP
  )
"#)?
```

---

## Cryptography

### `std/crypto` - Cryptographic Primitives

Safe crypto operations via OpenSSL FFI with high-level API.

```tangerine
use std::crypto::{sha256, sha512, hmac_sha256, aes, random_bytes}
use std::crypto::{base64, hex}

# Hashing
let hash = sha256(b"message")
let hash512 = sha512(b"message")

# HMAC
let mac = hmac_sha256(key, message)

# Random bytes
let nonce = random_bytes(16)
let key = random_bytes(32)

# AES Encryption
let plaintext = b"secret message"
let key = random_bytes(32)  # AES-256
let iv = random_bytes(16)

let ciphertext = aes::encrypt_cbc(plaintext, &key, &iv)?
let decrypted = aes::decrypt_cbc(&ciphertext, &key, &iv)?

# Encoding
let encoded = base64::encode(data)
let decoded = base64::decode(&encoded)?
let hex_str = hex::encode(bytes)
let bytes = hex::decode(&hex_str)?
```

**Supported Algorithms:**
- **Hashing:** SHA-256, SHA-512, SHA-1, MD5
- **HMAC:** HMAC-SHA256, HMAC-SHA512
- **Symmetric:** AES-128/192/256 (CBC, CTR, GCM), ChaCha20-Poly1305
- **Key Derivation:** PBKDF2, HKDF
- **Encoding:** Base64 (standard, URL-safe), Hex

---

## CLI & Terminal

### `std/cli` - Command-Line Interface Framework

Build CLI applications with argument parsing, subcommands, and terminal UI.

```tangerine
use std::cli::{App, Arg, Command, terminal, ProgressBar, Color}

# Argument parsing
let app = App::new("myapp", "My CLI Application")
  .version("1.0.0")
  .author("Your Name")
  .arg(Arg::new("verbose")
    .short('v')
    .long("verbose")
    .flag()
    .help("Enable verbose output"))
  .arg(Arg::new("output")
    .short('o')
    .long("output")
    .takes_value()
    .help("Output file"))
  .subcommand(Command::new("build")
    .about("Build the project")
    .arg(Arg::new("release").long("release").flag()))

let matches = app.parse()?

if matches.get_flag("verbose") then
  println("Verbose mode enabled")
end

if let Option::Some(output) = matches.get_value("output") then
  println("Output: {}", output)
end

# Terminal colors
terminal::print_colored("Success!", Color::Green)
terminal::print_bold("Important message")

# Progress bars
let pb = ProgressBar::new(100)
pb.set_message("Processing...")
for i in 0..100 do
  pb.set(i)
  # ... work ...
end
pb.finish_with_message("Done!")

# Spinner
let spinner = terminal::Spinner::new("Loading...")
# ... work ...
spinner.stop()
```

---

## Logging & Tracing

### `std/log` - Structured Logging

Comprehensive logging with structured fields, distributed tracing, and metrics.

```tangerine
use std::log::{Logger, Level, info, warn, error, debug, Span, Metrics}

# Initialize logger
Logger::init(Level::Info)

# Simple logging (function API)
let port_str = port.to_string()
let percent_str = percent.to_string()
let err_str = error.to_string()
info("Server started", [("port", port_str.as_str())])
warn("Connection pool pressure", [("capacity_pct", percent_str.as_str())])
error("Failed to process request", [("error", err_str.as_str())])

# Structured logging
let user_id_str = user_id.to_string()
info(
  "user_action",
  [
    ("action", "login"),
    ("user_id", user_id_str.as_str()),
    ("ip", ip_addr)
  ]
)

# Distributed tracing
let span = Span::new("handle_request")
span.set("http.method", "GET")
span.set("http.url", "/api/users")
span.set("user.id", user_id)

# ... handle request ...

span.finish()

# Metrics (Prometheus-compatible)
Metrics::counter("http_requests_total", ["method", "status"]).inc()
Metrics::histogram("http_request_duration_seconds").observe(elapsed.as_secs_f64())
Metrics::gauge("active_connections").set(active_count as f64)
```

---

## Regular Expressions & Parsing

### `std/regex` - Regular Expressions

NFA-based regex engine with Thompson's construction plus parser combinators.

```tangerine
use std::regex::{Regex, Parser, many, choice, char_p}

# Regular expressions
let re = Regex::new(r"\d{3}-\d{4}")?
assert!(re.is_match("555-1234"))

let text = "Phone: 555-1234, Fax: 555-5678"
for m in re.find_all(text) do
  println("Found: {}", m.as_str())
end

let replaced = re.replace_all(text, "XXX-XXXX")

# Parser combinators
let digit = Parser::digit()
let digits = many(digit).map(|ds| ds.join("").parse_int())
let number = digits

let plus = char_p('+')
let minus = char_p('-')
let op = choice([plus, minus])

let expr = number.and(op).and(number)
  .map(|((a, op), b)| do
    if op == '+' then a + b else a - b
  end)

let result = expr.parse("42+58")?  # Result::Ok(100)
```

---

## Compression & Archives

### `std/compress` - Compression Algorithms

Support for gzip, deflate, tar, and zip via zlib FFI.

```tangerine
use std::compress::{gzip, deflate, tar, zip}

# Gzip compression
let compressed = gzip::compress(data)?
let decompressed = gzip::decompress(&compressed)?

# Streaming compression
let encoder = DeflateEncoder::new(output_file)
encoder.write_all(&large_data)?
encoder.finish()?

# Tar archives
let builder = tar::TarBuilder::new(File::create("archive.tar")?)
builder.add_file("README.md", readme_content)?
builder.add_dir("src/")?
builder.finish()?

let reader = tar::TarReader::open("archive.tar")?
for entry in reader.entries()? do
  println("{}: {} bytes", entry.path(), entry.size())
end

# Zip archives
let reader = zip::ZipReader::open("archive.zip")?
for entry in reader.entries()? do
  let data = reader.extract(&entry)?
end

let writer = zip::ZipWriter::create("output.zip")?
writer.add_file("data.txt", content)?
writer.finish()?
```

---

## Date & Time

### `std/time` - Date and Time

Timezone-aware datetime, duration arithmetic, and time formatting.

```tangerine
use std::time::{DateTime, Duration, Instant, TimeZone}

# Current time
let now = DateTime::now()           # Local time
let utc = DateTime::now_utc()       # UTC

# Parsing
let dt = DateTime::parse("2026-03-01T12:00:00Z", "%Y-%m-%dT%H:%M:%SZ")?
let dt = DateTime::parse_iso8601("2026-03-01T12:00:00+00:00")?

# Formatting
let formatted = dt.format("%Y-%m-%d %H:%M:%S")
let iso = dt.to_iso8601()

# Duration arithmetic
let duration = Duration::from_secs(3600)  # 1 hour
let later = now + duration
let diff = later - now

# Timezone conversion
let la_time = utc.to_timezone(TimeZone::from_name("America/Los_Angeles")?)

# Relative time
let elapsed = start.elapsed()
let remaining = deadline.remaining()
```

---

## Async & Concurrency

### `std/async` - Asynchronous Runtime

Green threads, async/await, and asynchronous I/O primitives.

```tangerine
use std::async::{spawn, join_all, sleep, timeout}

# Async functions
async def fetch_data(url: String) -> Result[String, Error]
  let response = http::get(&url).await?
  let text = response.text().await?
  Result::Ok(text)
end

# Spawning tasks
let handle = spawn(async do
  compute_heavy().await
end)
let result = handle.await?

# Concurrent execution
let urls = vec![url1, url2, url3]
let tasks = urls.iter().map(|u| spawn(fetch_data(u)))
let results = join_all(tasks).await

# Timeouts
let result = timeout(Duration::from_secs(5), slow_operation()).await?
```

### `std/thread` - Threading Primitives

OS threads, synchronization primitives, and message passing.

```tangerine
use std::thread::{Thread, spawn, Mutex, RwLock, Channel, AtomicInt}

# Thread spawning
let handle = Thread::spawn(|| do
  compute_result()
end)
let result = handle.join()?

# Mutex
let counter = Mutex::new(0)
do
  let mut guard = counter.lock()
  *guard += 1
end

# Read-write lock
let data = RwLock::new(HashMap::new())
let read_guard = data.read()
let write_guard = data.write()

# Channels (MPSC)
let (tx, rx) = Channel::new()
tx.send(42)?
let value = rx.recv()?

# Atomics
let counter = AtomicInt::new(0)
counter.fetch_add(1, Ordering::SeqCst)
let value = counter.load(Ordering::Acquire)
```

---

## I/O & Filesystem

### `std/io` - I/O Traits

Traits for reading, writing, and seeking.

```tangerine
use std::io::{Read, Write, BufReader, BufWriter}

# Buffered I/O
let file = File::open("large.txt")?
let reader = BufReader::new(file)
for line in reader.lines() do
  println("{}", line?)
end

let file = File::create("output.txt")?
let writer = BufWriter::new(file)
writer.write_all(b"Hello, world!")?
writer.flush()?
```

### `std/fs` - Filesystem Operations

File and directory manipulation.

```tangerine
use std::fs::{File, read_to_string, write, create_dir, remove_file, walk_dir}

# Read/Write convenience
let content = read_to_string("config.toml")?
write("output.txt", &data)?

# File operations
let file = File::open("data.bin")?
let metadata = file.metadata()?
let size = metadata.len()

# Directory operations
create_dir("output")?
create_dir_all("path/to/nested/dir")?

# Walking directories
for entry in walk_dir("src")? do
  if entry.is_file() then
    println("File: {}", entry.path())
  end
end

# Recursive with filtering
for entry in walk_dir("src")?.filter(|e| e.extension() == Some("tg")) do
  process_file(entry.path())?
end
```

---

## FFI

**Module:** `std/ffi`

Foreign Function Interface types, pointer operations, and FFI boundary taint
integration.

```tangerine
use std::ffi::{Ptr, CStr, CString, FfiStr, FfiSlice, Opaque, CType}

# Raw pointer
let ptr: Ptr[Int] = null_ptr[Int]()
let is_null = is_null(&ptr)

# C string conversion
let cs = cstring_new("hello")
let s = cstring_to_string(&cs)

# Export ABI info
let edition = tg_abi_edition()    # FfiStr = "2026"
let rev = tg_abi_revision()       # UInt = 1
```

**Types:**
- `Ptr[T]` - Raw pointer with `address: UInt`
- `Opaque` - Opaque foreign handle
- `CStr` - Borrowed NUL-terminated C string
- `CString` - Owned NUL-terminated C string
- `FfiStr` - Borrowed UTF-8 view for C
- `FfiSlice[T]` - Borrowed slice view for C
- `CType` - 17-variant enum of C types

**Taint Integration:**
- `FfiBoundary` trait — marker for types crossing FFI boundaries
- `__ffi_auto_taint[T]()` — compiler-inserted taint wrapper for FFI return values
- `__ffi_callback_taint[T]()` — compiler-inserted taint for callback arguments

**Constants:**
- `FFI_ABI_EDITION: String = "2026"`
- `FFI_ABI_REVISION: UInt = 1`

---

### `std/contracts` - Design-by-Contract

Lightweight contracts/invariants usable by humans, tooling, and agents (TG-GFX-UI-SPEC-001 v0.1, Section 2).

```tangerine
use std::contracts::{check_pre, check_post, make_guard, GuardElseAction}

def divide(a: Int, b: Int) -> Int
  check_pre(b != 0, "denominator must not be zero".to_string())
  let result = a / b
  check_post(result * b == a, "division must be precise".to_string())
  result
end

def process(x: Option[Int]) -> Int
  guard let Some(val) = x else { return 0 }
  val * 2
end
```

#### How it fails
- **`ContractViolation`**: A precondition, postcondition, or invariant was violated at runtime. Triggers a `panic` and an error log.
- **`GuardViolation`**: A `guard` clause condition was false, and the `else` branch triggered a panic.

#### Security & Capabilities
- Contracts are pure logic and have no direct side effects other than logging and panicking.
- In `release` mode, some contracts may be elided by the compiler, but `guard` statements are always preserved as they affect control flow.

#### Performance
- Runtime checks are O(1) per check.
- The overhead of a contract check is minimal, typically a branch and a potential call to the logger.

#### Compatibility
- Pure Tangerine implementation; consistent across all platforms.
- Integrated with the global diagnostics system for consistent error reporting.

---

## Testing & Benchmarking

### `std/test` - Testing Framework

Unit tests, integration tests, and snapshot testing.

```tangerine
use std::test::{test, assert_eq, assert_ne, assert_throws, snapshot}

@test
def test_addition()
  assert_eq(2 + 2, 4)
  assert_eq(add(10, 20), 30)
end

@test
def test_error_handling()
  assert_throws(|| do
    divide(10, 0)
  end)
end

@test
def test_snapshot()
  let output = render_template(test_data)
  snapshot::assert_eq("template_output", &output)
end

# Property testing
@test_prop
def test_reverse_twice(list: Vec[Int])
  assert_eq(list.reverse().reverse(), list)
end
```

### `std/bench` - Benchmarking Framework

Micro-benchmarking with statistical analysis, warmup, auto-calibration, and
outlier detection.

```tangerine
use std::bench::{bench_suite_new, bench_case_new, default_bench_config}

mut suite = bench_suite_new("sort benchmarks")
suite.add(bench_case_new("quicksort", || sort_quick(&mut data) ))
suite.add(bench_case_new("mergesort", || sort_merge(&mut data) ))

let config = default_bench_config()
for case in suite.cases do
  let result = run_benchmark(case, config)
  # result: BenchResult { min_ns, max_ns, mean_ns, median_ns, std_dev, ... }
end
```

**Types:**
- `BenchResult` - `iterations`, `min_ns`, `max_ns`, `mean_ns`, `median_ns`, `std_dev`, `throughput`
- `BenchConfig` - `min_iterations`, `max_iterations`, `warmup_iterations`, `target_time_ms`, `outlier_threshold`
- `BenchOutcome` - `Passed(BenchResult)`, `Failed(String)`, `Skipped`
- `BenchSuite` - Named collection of benchmark cases

---

## Test Generation

**Module:** `std/test_gen`

Automatic test case generation from function signatures, contracts, and boundary
analysis.

```tangerine
use std::test_gen::{extract_function_info, generate_tests_from_info, TestSuite}

let info = extract_function_info(source, "clamp")?
let tests = generate_tests_from_info(info)
# Generates: boundary value tests, contract-based tests, fuzz seeds

for test in tests do
  puts(format("[{}] {} — expects: {}", [test.kind.name(), test.name, test.expected]))
end
```

**Types:**
- `TestKind` - `Unit`, `Property`, `Boundary`, `Contract`, `Fuzz`
- `TestCase` - `name`, `kind`, `fn_under_test`, `inputs`, `expected`, `generated`
- `FunctionInfo` - `name`, `params`, `return_type`, `contracts`
- `TestExpectation` - `Returns(String)`, `Panics(String)`, `Satisfies(String)`, `NoException`

### `std/app` - Application & Windowing

Cross-platform windowing, event loop, input, timers, and surface acquisition (TG-GFX-UI-SPEC-001 v0.1, Section 6).

```tangerine
use std::app::{SoftwareApp, AppOpts, App, Window, display_cap}
use std::core::{Result}

let opts = AppOpts::default()
mut app = SoftwareApp::new(opts)
let cap = display_cap()

let mut win = app.window_new("My App".to_string(), 800, 600, cap)?
win.set_title("Updated Title".to_string())

while let Some(ev) = win.poll_event() do
  # Handle events
end
```

#### How it fails
- **`BackendUnavailable`**: The requested graphics backend (e.g., Vulkan, Metal) could not be initialized.
- **`InvalidArg`**: Invalid window dimensions or malformed title string.
- **`Unsupported`**: The current platform does not support the requested operation (e.g., high-DPI surfaces on some backends).
- **`PermissionDenied`**: A capability-gated operation (like clipboard access) was attempted without a valid capability token.
- **`Internal`**: An unexpected error occurred in the platform's windowing system.

#### Security & Capabilities
- Side effects like window creation, clipboard access, and filesystem interaction (via the recorder) are capability-gated.
- Capabilities include `DisplayCap`, `ClipboardCap`, `ImeCap`, `DragDropCap`, `ClockCap`, `RandomCap`, and `FsCap`.

#### Performance
- Event polling is O(1) and non-blocking.
- Timer management uses a high-efficiency heap in production backends (O(log N)).
- Reference implementation `SoftwareApp` is optimized for testing and minimal overhead.

#### Compatibility
- **Linux**: X11 and Wayland support.
- **macOS**: AppKit integration.
- **Windows**: Win32 / WinUI 3 support.
- **Web**: Canvas-based windowing via WebAssembly.

---

## UI & Graphics

### `std/accessibility` - Accessibility Tree

Accessibility tree emission for platform screen readers (TG-GFX-UI-SPEC-001 v0.1, Section 13.4).

```tangerine
use std::accessibility::{A11yNode, Role, tree_emit, accessibility_cap}
use std::geom::{Rect}

let cap = accessibility_cap()
let root = A11yNode {
  id: 1,
  role: Role::Window,
  label: "Main Window",
  rect: Rect { x: 0.0, y: 0.0, width: 800.0, height: 600.0 },
  focusable: false,
  children: Vec::of(
    A11yNode {
      id: 2,
      role: Role::Button,
      label: "Submit",
      rect: Rect { x: 10.0, y: 10.0, width: 80.0, height: 30.0 },
      focusable: true,
      children: Vec::new(),
    }
  ),
}

match tree_emit(&root, &cap)
when Ok(_) then println("Accessibility tree emitted")
when Err(e) then println("Error emitting tree: " + e.message())
end
```

#### How it fails
- **`PermissionDenied`**: The required `Accessibility` capability was not provided to `tree_emit`.
- **`Unsupported`**: The current platform or backend does not support accessibility tree emission.
- **`BackendUnavailable`**: The connection to the platform accessibility bridge was lost.
- **`InvalidArg`**: The provided accessibility tree is malformed (e.g., circular references or invalid coordinates).

#### Security & Capabilities
- All side effects are gated by the `Accessibility` capability.
- Use `accessibility_cap()` to obtain a capability handle (subject to system security policy).

#### Performance
- Tree traversal is O(N) where N is the number of nodes.
- Reference implementation is non-allocating during traversal.
- Production implementations may involve IPC overhead to the platform bridge.

#### Compatibility
- **Linux**: Maps to AT-SPI2.
- **macOS**: Maps to NSAccessibility.
- **Windows**: Maps to UI Automation (UIA).
- **Web**: Maps to ARIA live regions and tree updates.

### `std/ui` - 2D Graphics

Foundation for 2D graphics, images, fonts, and animation.

```tangerine
use std::ui::{Canvas, Color, Image, Font, Animation, Point, Rect}

# Drawing
let canvas = Canvas::new(800, 600)
canvas.fill(Color::WHITE)
canvas.fill_rect(100, 100, 200, 150, Color::rgb(255, 128, 0))
canvas.stroke_rect(100, 100, 200, 150, Color::BLACK, 2)
canvas.fill_circle(400, 300, 50, Color::RED)
canvas.draw_line(0, 0, 800, 600, Color::BLUE, 1)

# Images
let image = Image::load_png("sprite.png")?
canvas.draw_image(&image, 200, 200)
image.resize(128, 128)
let cropped = image.crop(Rect::new(0, 0, 64, 64))

# Text rendering
let font = Font::load("Roboto-Regular.ttf")?
canvas.draw_text("Hello, World!", 100, 100, &font, 24, Color::BLACK)

# Animation
let anim = Animation::new(0.0, 100.0, Duration::from_secs(2))
  .with_easing(easing::ease_in_out_cubic)

let t = 0.5  # 50% through animation
let value = anim.sample(t)  # Interpolated value with easing
```

---

## Contracts & Capabilities

### `std/contracts` - Design by Contract

Preconditions, postconditions, invariants, and the **guard** keyword.

```tangerine
use std::contracts::{pre, post, invariant, make_guard, GuardClause, GuardElseAction}

def sqrt(x: Float) -> Float
  pre x >= 0.0, "sqrt requires non-negative input"
  post result >= 0.0 && (result * result - x).abs() < 0.001, "result² ≈ x"
  
  x.sqrt()
end

struct BankAccount
  balance: Float
  
  invariant self.balance >= 0.0, "balance must be non-negative"
end

impl BankAccount
  def withdraw(self: &mut BankAccount, amount: Float) -> Result[Unit, String]
    pre amount > 0.0, "amount must be positive"
    post self.balance == old(self.balance) - amount, "balance decreased by amount"
    
    if self.balance >= amount then
      self.balance -= amount
      Result::Ok(())
    else
      Result::Err("insufficient funds")
    end
  end
end
```

**Guard Keyword:**

`guard` is syntactic sugar for precondition checks that early-return on failure.

```tangerine
# Guard with early return
def process(input: Option[String]) -> Result[Int, Error]
  guard let value = input else return Result::Err("missing")
  parse_int(value)
end

# Guard with panic
def require_positive(x: Int) -> Int
  guard x > 0 else panic("x must be positive")
  x * 2
end
```

**Types:**
- `ContractKind` - `Pre`, `Post`, `Invariant`
- `Contract` - `kind`, `expr`, `has_message`, `message`
- `ProofObligation` - `origin`, `kind`, `expr`, `verified`
- `GuardClause` - `condition`, `else_action`, `narrows_type`, `promoted_contract`
- `GuardElseAction` - `Return(expr)`, `Panic(msg)`, `Break(label)`, `Next(label)`

### `std/capabilities` - Capability System

Fine-grained access control for resources.

```tangerine
use std::capabilities::{cap, requires, SecurityProfile, profile_check,
                        validate_against_profile, parse_profile}

cap FileSystem implies FileRead, FileWrite end
cap Network implies NetworkRead, NetworkWrite end
cap Console implies ConsoleRead, ConsoleWrite end

def download_file(url: String, path: String) -> Result[Unit, Error]
  requires Network, FileSystem
  
  let data = http_get(url)?
  fs::write(path, data)?
  Result::Ok(())
end

def safe_compute(data: String) -> String
  requires !Network  # Explicitly no network access
  
  process_locally(data)
end
```

**Security Profiles:**

Profiles restrict which capabilities are allowed per project.

```tangerine
# Built-in profiles
let prof = parse_profile("backend")  # Backend profile

# Check a capability against a profile
let result = profile_check(&prof, "Net")  # Satisfied (Net allowed in Backend)
let result = profile_check(&prof, "Unsafe")  # Missing (Unsafe denied in Backend)

# Validate an entire capability context
let violations = validate_against_profile(&ctx, &prof)
```

| Profile | Allowed | Denied |
|---------|---------|--------|
| `Backend` | Net, Fs, DB, Env, Clock, Random | Unsafe |
| `Cli` | Fs, Env, Proc | Net |
| `Ui` | Clock, Random | Fs, Net, DB |
| `Library` | Pure, Custom | all system caps |

---

## Profiling & Observability

### `std/profile` - Performance Profiling

CPU profiling, memory tracking, frame timing, and benchmarking.

```tangerine
use std::profile::{Profiler, FrameTimer, Benchmark, MemoryProfiler}

# CPU profiling
let profiler = Profiler::new()
profiler.start()
# ... code to profile ...
profiler.stop()

let report = profiler.report()
report.print()
profiler.write_flamegraph("profile.svg")?

# Frame timing (games/UI)
let timer = FrameTimer::with_target_fps(60.0)
loop
  timer.begin_frame()
  
  # Render frame...
  
  let stats = timer.end_frame()
  if stats.fps < 55.0 then
    let fps_str = stats.fps.to_string()
    warn("Low FPS", [("fps", fps_str.as_str())])
  end
end

# Benchmarking
let mut bench = Benchmark::new("sort_1000")
  .iterations(1000)
  .warmup(100)

let result = bench.run(|| do
  let mut data = generate_data()
  sort(&mut data)
end)

result.print()
```

### `std/snapshot` - Execution Replay

Record and replay execution for debugging.

```tangerine
use std::snapshot::{Recorder, Player, start_recording, stop_recording}

# Recording
let recorder = Recorder::new("session.replay")
recorder.start()

# ... program execution ...
recorder.checkpoint("before_critical_section", data)
# ... critical code ...
recorder.checkpoint("after_critical_section", result)

let stats = recorder.stop()?
println("Recorded {} events", stats.event_count)

# Replay
let player = Player::new("session.replay")
player.open()?

# Step through execution
loop
  match player.step()
    when Result::Ok(event) then println("Event: {:?}", event)
    when Result::Err(PlayerError::EndOfRecording) then break
    when Result::Err(e) then return Result::Err(e)
  end
end

# Seek to checkpoint
player.seek_to_checkpoint("before_critical_section")?

# Analysis
let analyzer = ReplayAnalyzer::load("session.replay")?
let hot_functions = analyzer.hot_functions()
let (peak_time, peak_bytes) = analyzer.memory_peak()
```

---

## Effects & Budgets

### `std/effects` - Algebraic Effects

Effect handlers for controlled side effects.

```tangerine
use std::effects::{effect, handle}

effect Logger
  log(level: Level, msg: String) -> Unit
end

def process_data(data: String) -> String
  effect Logger
  
  Logger::log(Level::Info, "Starting processing")
  let result = transform(data)
  Logger::log(Level::Info, "Processing complete")
  result
end

# Handle effects
handle process_data(input)
with Logger
  log(level, msg) => println("[{}] {}", level, msg)
end
```

### `std/budget` - Resource Budgets

Enforce resource limits at runtime.

```tangerine
use std::budget::{budget, budget_remaining, budget_exceeded}

def expensive_operation(data: Data) -> Result[Output, Error]
  budget time: 5s, memory: 100MB, api_calls: 10
  
  for item in data do
    if budget_remaining("api_calls") < 2 then
      # Use cached data instead
      use_cache(item)?
    else
      fetch_remote(item)?
    end
  end
  
  Result::Ok(result)
end
```

---

## Secure Types

**Module:** `std/secure_types`

Sealed wrapper types that prevent injection attacks at the type level. These
types cannot be constructed from raw strings — only through validated constructors.

### `SqlQuery` - Parameterized SQL

```tangerine
use std::secure_types::{sql_query, SqlParam, sql_debug_string}

# Only way to create a SqlQuery — validates placeholders
let query = sql_query(
  "SELECT * FROM users WHERE id = $1 AND name = $2",
  [SqlParam::Int(42), SqlParam::Text("Alice")]
)?

# Debug output (safe to log, not for execution)
let debug = sql_debug_string(&query)
```

### `HtmlSafe` - XSS-Safe HTML

```tangerine
use std::secure_types::{html_escape, html_safe_trusted, html_concat}

let safe = html_escape("<script>alert('xss')</script>")
# safe.value == "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"

# Trusted HTML (requires @capability(Unsafe))
let raw = html_safe_trusted("<b>bold</b>")

let combined = html_concat(&safe, &raw)
```

### `Url` - Validated URLs

```tangerine
use std::secure_types::{url_parse}

let url = url_parse("https://example.com/api?q=hello")?
# Blocks javascript: and vbscript: schemes automatically
```

### `SafePath` - Traversal-Safe File Paths

```tangerine
use std::secure_types::{path_parse, path_join, path_extension}

let path = path_parse("data/reports/q1.csv")?
# Rejects: "../etc/passwd", paths with null bytes, absolute paths
let joined = path_join(&path, "summary.txt")?
let ext = path_extension(&path)  # Option::Some("csv")
```

### `HeaderValue` - HTTP Header Injection Prevention

```tangerine
use std::secure_types::{header_new}

let hdr = header_new("application/json")?
# Rejects values containing \r or \n (CRLF injection prevention)
```

---

## Taint Tracking

**Module:** `std/taint`

Data entering through FFI boundaries is automatically wrapped in `Tainted[T]`.
Tainted values must pass through a `Validator` to produce clean values.

```tangerine
use std::taint::{Tainted, taint, taint_with_span, taint_merge,
                 validate, validate_with, TaintLabel}

# Create tainted values
let raw = taint("user input", TaintLabel::UserInput)
let merged = taint_merge("combined", [&raw, &other])

# Validate to clean
let clean = validate(raw, MaxLengthValidator { max_len: 255 })?

# Inline validation with predicate
let validated = validate_with(
  raw_int,
  |v| v > 0 && v < 1000,
  "must be between 1 and 999"
)?
```

**Taint Labels:** `FfiInput`, `FfiCallback`, `NetworkRead`, `FileRead`, `EnvVar`,
`UserInput`, `Deserialized`, `Custom(String)`

**Built-in Validators:**

| Validator | Validates |
|-----------|-----------|
| `MaxLengthValidator` | `String` length ≤ `max_len` |
| `IntRangeValidator` | `Int` in `[min, max]` |
| `PatternValidator` | `String` matches regex `pattern` |
| `NonEmptyValidator` | `String` is non-empty |

**Propagation:**
- `taint_map[T, U](&Tainted[T], fn(&T) -> U) -> Tainted[U]` — transform value, preserve taint
- `taint_flat_map[T, U](&Tainted[T], fn(&T) -> Tainted[U]) -> Tainted[U]` — chain tainted operations

**Static Analysis Types:**
- `TaintFlow` / `TaintSource` / `TaintSink` / `TaintStep` — for `analyze_taint_flows()` static analysis pass
- `FfiTaintConfig` — controls auto-taint behavior at FFI boundaries

---

## Deterministic Replay

**Module:** `std/replay`

Captures non-deterministic events during execution and allows exact
reproduction of program behavior. Serialized as JSONL.

```tangerine
use std::replay::{ReplayRecorder, ReplayPlayer, ReplayEvent, ReplayTrace,
                  recorder_new, trace_serialize, trace_save, player_load}

# Recording
mut recorder = recorder_new()
recorder_record_schedule(&mut recorder, 0)        # thread schedule decision
recorder_record_random(&mut recorder, [0x42])      # RNG seed
recorder_record_time(&mut recorder, 1700000000)    # wall clock query
recorder_record_io_read(&mut recorder, 0, bytes)   # I/O read result
recorder_record_env(&mut recorder, "HOME", Option::Some("/home/user"))

let trace = recorder.to_trace()
trace_save(&trace, "session.replay")?

# Replay
let player = player_load("session.replay")?
let event = player.next()?   # ReplayEvent
```

**Event Types (11):** `ScheduleThread`, `RandomSeed`, `TimeQuery`, `IoRead`,
`IoWrite`, `NetRecv`, `EnvRead`, `FsStat`, `ChanRecv`, `AllocAddr`

**Deterministic Scheduler:**
- `DeterministicScheduler` with `SchedulerMode::Normal | Recording | Replaying`
- `scheduler_pick_thread()` — uses recorded schedule during replay

**Trace Format:**
- Line 1: `TraceHeader` (format_version `"tg.replay.v1"`, tangerine_version, program_hash, etc.)
- Lines 2..N: One `ReplayEvent` per line as JSON

---

## Semantic Diff

**Module:** `std/semantic_diff`

Extracts code entities from source files and computes meaningful diffs with
severity annotation.

```tangerine
use std::semantic_diff::{extract_entities, compute_diff, SemanticDiff,
                         AnnotatedChange, DiffSeverity}

let old_entities = extract_entities(old_source)
let new_entities = extract_entities(new_source)
let diff = compute_diff(&old_entities, &new_entities)

for change in diff.changes do
  let severity = classify_change_severity(&change)
  puts(format("[{}] {} {} — {}", [severity, change.kind, change.entity_name,
                                    change.description]))
end
```

**Entity Kinds:** `Function`, `Struct`, `Enum`, `Trait`, `Impl`, `Const`,
`Module`, `Import`, `Contract`, `Capability`

**Change Kinds:** `Added`, `Removed`, `Modified`, `Renamed`, `Moved`

**Severity Levels:**
| Severity | Meaning |
|----------|---------|
| `Breaking` | Public API removed or signature changed |
| `Compatible` | New API added, no existing API affected |
| `Internal` | Private implementation changed |
| `Cosmetic` | Whitespace, comments, or formatting only |

---

## Supply Chain Security

**Module:** `std/supply_chain`

Package signing, lockfile verification, reproducible builds, and dependency
trust computation.

### Package Signing

```tangerine
use std::supply_chain::{PackageSignature, SignerIdentity, TrustLevel,
                        verify_package_signature}

let sig = PackageSignature {
  signer: SignerIdentity { name: "maintainer", public_key: key, trust_level: TrustLevel::Owner },
  signature: sig_bytes,
  signed_hash: pkg_hash,
  timestamp: now,
  algorithm: "ed25519",
}
verify_package_signature(pkg_hash, &sig)?
```

### Lockfile Integrity

```tangerine
use std::supply_chain::{lockfile_parse, lockfile_verify, Lockfile}

let lockfile = lockfile_parse(contents)?
lockfile_verify(&lockfile)?  # Verifies integrity_hash and all package checksums
```

### SemVer

```tangerine
use std::supply_chain::{semver_parse, semver_to_string, SemVer}

let ver = semver_parse("1.2.3-beta.1+build.42")?
# ver.major == 1, ver.minor == 2, ver.patch == 3
# ver.pre == "beta.1", ver.build == "build.42"
```

### Trust Graph

```tangerine
use std::supply_chain::{build_trust_graph, compute_trust_score}

let graph = build_trust_graph(packages)?
let score = compute_trust_score(&graph, target_id)?
# score: Float in [0.0, 1.0] — iterative convergence over trust edges
```

### Supply Chain Policy

```tangerine
use std::supply_chain::{SupplyChainPolicy, check_policy}

let policy = SupplyChainPolicy {
  require_signatures: true,
  min_trust_score: 0.7,
  max_transitive_deps: 100,
  allow_git_sources: false,
  require_lockfile: true,
}
let violations = check_policy(&policy, &lockfile)
```

**Types:**
- `PackageId` - `name`, `version`, `registry`
- `SemVer` - `major`, `minor`, `patch`, `pre`, `build`
- `PackageSource` - `Registry(url)`, `Git(url, rev)`, `Path(path)`
- `TrustLevel` - `Owner`, `Contributor`, `Auditor`, `Registry`
- `PolicyViolation` / `ViolationKind` - detailed policy violation reporting

### Additional Core Modules

```tangerine
# std/locale — locale-aware formatting and parsing
use std::locale::{Locale, format_number, parse_number}

# std/process — process spawning and status/output capture
use std::process::{Command, ProcessStatus}

# std/sync — synchronization primitives (Mutex, RwLock, atomics)
use std::sync::{Mutex, RwLock, AtomicInt}

# std/unicode — normalization, grapheme handling, width calculations
use std::unicode::{normalize_nfc, grapheme_clusters, display_width}
```

---

## See Also

- [Language Reference](language.md) - Complete language specification
- [Interoperability Guide](interop.md) - FFI and foreign language integration
- [Memory Model](memory_model.md) - Access conventions, resources, and capabilities
- [Error Handling Guide](error_handling.md) - Error handling patterns and best practices
- [Concurrency Guide](concurrency.md) - Threading and async programming
- [Packaging Guide](packaging.md) - Package management and publishing
- [Deployment Targets](deployment_targets.md) - Cross-compilation and deployment
- [Completeness Status](#completeness-status-current-2026-08) - Full module inventory and checklist
- [Style Guide](style_guide.md) - Code formatting and conventions
- [FFI Cheat Sheet](ffi_cheatsheet.md) - Quick FFI reference
