# Tangerine Standard Library Completeness Report

**Version:** 0.1.0  
**Last Updated:** March 2026

Comprehensive inventory of all standard library modules and their capabilities.

---

## Summary

| Category | Modules | Status |
|----------|---------|--------|
| Core Types & I/O | 7 | Complete |
| Data Formats & Serialization | 8 | Complete |
| Networking & Web | 4 | Complete |
| Database | 1 | Complete |
| Cryptography & Security | 4 | Complete |
| Concurrency & Async | 3 | Complete |
| Process & System | 3 | Complete |
| UI & Graphics | 5 | Complete |
| Testing & Quality | 6 | Complete |
| Agentic AI & Safety | 8 | Complete |
| Tooling | 7 | Complete |
| **Total** | **56+** | **Complete** |

---

## Module Inventory

### Core Types & I/O

#### `std/core` — Foundation Types

- `Option[T]`, `Result[T, E]`, `Vec[T]`, `Map[K, V]`, `Set[T]`, `String`
- `Rc[T]`, `Arc[T]`, `Box[T]`, `Weak[T]`
- Traits: `Clone`, `Copy`, `Drop`, `Default`, `Display`, `Debug`, `Eq`, `Ord`, `Hash`, `Iterator`
- Error context chaining: `.context()`, `.with_context()`, `ContextError`
- `ErrorKind` with 13 categories and stable error codes (1001–1099)

#### `std/collections` — Data Structures

- `HashMap`, `BTreeMap`, `OrderedMap`
- `HashSet`, `BTreeSet`
- `VecDeque`, `LinkedList`, `BinaryHeap`
- `RingBuffer` (fixed-capacity circular buffer)
- Full lazy iterator chain: `map`, `filter`, `take`, `skip`, `zip`, `chain`, `enumerate`, `flat_map`, `peekable`, `fold`, `collect`, `chunks`, `windows`, `range`

#### `std/io` — Input/Output

- `Read`, `Write`, `Seek`, `BufRead` traits
- `BufReader`, `BufWriter`
- `stdin`, `stdout`, `stderr`

#### `std/fs` — Filesystem

- File operations: `read`, `write`, `append`, `create`, `open`
- Directory operations: `create_dir`, `create_dir_all`, `read_dir`, `remove_dir`
- Symlinks: `symlink`, `read_link`
- Temp files: `temp_file`, `temp_dir`
- File copy, chmod, chown, metadata, canonical path
- Directory walking: `walk_dir`
- Atomic write operations

#### `std/path` — Path Manipulation

- `Path`, `PathBuf` types
- Cross-platform path handling
- `normalize`, `join`, `parent`, `ancestors`, `components`
- `extension`, `stem`, `with_extension`
- `is_absolute`, `is_relative`, `starts_with`, `ends_with`

#### `std/fmt` — Formatting

- `Display`, `Debug` formatting traits
- Format string parsing and interpolation

#### `std/alloc` — Memory Allocation

- `Allocator` trait
- `GlobalAllocator`
- Arena/bump allocator support

---

### Data Formats & Serialization

#### `std/serde` — Serialization Framework

- `Serialize`, `Deserialize` traits
- `Serializer`, `Deserializer` traits
- `Value` enum (Null, Bool, Int, Float, String, Array, Object)
- `ValueSerializer`, `ValueDeserializer`
- Schema evolution: `VersionedSerialize`, `VersionedDeserialize`, `Schema`, `SchemaField`
- Format registry: pluggable `Format` trait, `FormatRegistry`
- Built-in JSON and TOML format hooks
- Derive attribute support: `rename`, `default`, `skip`, `flatten`, `alias`, `with`

#### `std/json` — JSON

- Full JSON parser and serializer
- Pretty printing
- JSON Pointer, JSON Patch

#### `std/toml` — TOML

- TOML 1.0 parser and serializer

#### `std/csv` — CSV

- RFC 4180 compliant parser/writer
- Streaming reader with field mapping
- Custom delimiters, quoting

#### `std/yaml` — YAML

- YAML 1.2 parser and emitter
- Anchors and aliases support

#### `std/cbor` — CBOR

- RFC 8949 encoder/decoder
- Major types 0–7 (unsigned, negative, bytes, text, array, map, tags, simple)

#### `std/msgpack` — MessagePack

- Full MessagePack encoder/decoder
- Type mapping for all Tangerine types

#### `std/config` — Configuration

- Layered configuration (defaults → file → env → CLI)
- Auto-detect format (TOML, JSON, YAML)
- Environment variable overrides
- File watching for live reload

---

### Networking & Web

#### `std/net` — Low-Level Networking

- TCP: `TcpStream`, `TcpListener`
- UDP: `UdpSocket`
- IP address: `IpAddr`, `SocketAddr`, DNS resolution
- Socket options: `SO_REUSEADDR`, `TCP_NODELAY`, timeouts
- Unix domain sockets: `UnixStream`, `UnixListener`, `UnixDatagram`
- TLS: OpenSSL/LibreSSL FFI, `TlsConfig`, `TlsStream`, SNI support

#### `std/http` — HTTP Client & Server

- HTTP/1.1 client and server
- HTTP/2: frames, streams, HPACK header compression
- `HttpClient` with connection reuse, redirect following
- `RequestBuilder` for fluent API
- `HttpServer` with handler routing
- WebSocket (RFC 6455): `WebSocket`, frame encoding/decoding, auto-pong
- Connection pooling: `ConnectionPool` with TTL eviction
- Middleware: `Middleware` trait, logging, CORS, rate limiting, `MiddlewareChain`

#### `std/url` — URL Parsing

- RFC 3986 compliant URL parser
- Query string encoding/decoding

#### `std/web` — Web Framework

- Routing, middleware, request/response abstractions
- Template rendering

---

### Database

#### `std/db` — Database Access

- `Connection` trait (execute, query, transactions, prepared statements)
- **SQLite driver**: full libsqlite3 FFI
- **PostgreSQL driver**: full libpq FFI, binary protocol
- **MySQL driver**: full libmysqlclient FFI, prepared statements
- Connection pooling: `Pool`, `PooledConnection` with max connections
- Query builder: `select`, `insert`, `update`, `delete`, `where_`, `join`, `order_by`
- Migrations: `Migration`, `MigrationRunner`, auto-tracking
- Transaction isolation levels
- Async database: `AsyncConnection` trait, `AsyncWrapper`, `AsyncPool`

---

### Cryptography & Security

#### `std/crypto` — Cryptographic Primitives

- **Hashing**: MD5, SHA-1, SHA-256, SHA-512, SHA-3 (Keccak-f[1600]), SHA3-256, SHA3-512, SHAKE128/256, BLAKE3
- **MAC**: HMAC-SHA256, Poly1305
- **Key derivation**: PBKDF2
- **Symmetric encryption**: AES-128/256, AES-CBC, AES-GCM
- **Stream ciphers**: ChaCha20
- **AEAD**: ChaCha20-Poly1305 (RFC 8439)
- **Key exchange**: X25519 (Curve25519)
- **Signatures**: Ed25519 (sign, verify)
- **Certificates**: X.509 parsing (PEM/DER), validity checking
- **Encoding**: Base64, hex
- **Random**: cryptographically secure random bytes

#### `std/auth` — Authentication

- JWT (JSON Web Tokens): create, verify, parse
- OAuth 2.0 with PKCE
- API key management
- Password hashing (PBKDF2)

#### `std/secure_types` — Secure Types

- Taint tracking, sensitive data wrappers

#### `std/taint` — Taint Analysis

- Input sanitization, taint propagation

---

### Concurrency & Async

#### `std/thread` — OS Threading

- `Thread`, `JoinHandle`, `ThreadBuilder`
- `Mutex`, `MutexGuard`, `RwLock`
- `Condvar`, `Barrier`
- `AtomicInt`, `AtomicBool` with orderings
- Channels: `Sender`, `Receiver`, `Channel`
- `ThreadLocal`
- `ThreadPool` with graceful shutdown
- Scoped threads: `scope()`, `Scope`
- `Once` (one-time initialization)
- Thread parking: `park()`, `unpark()`

#### `std/async` — Async Runtime

- `Future`, `Poll`, `Waker`, `Context`
- `Task`, `JoinHandle`, `Executor`
- I/O reactor (epoll/kqueue)
- `Sleep`, `Timeout`, `YieldNow`
- Async channels: `Sender`, `Receiver`
- `Select` / `Either` (race futures)
- Async I/O: `AsyncTcpStream`, `AsyncMutex`
- Structured concurrency: `TaskScope` (nursery pattern)
- `CancellationToken` with child tokens
- `AsyncIterator`: `MapStream`, `FilterStream`, `TakeStream`, `ChannelStream`
- Retry: `RetryConfig`, exponential backoff with jitter
- `CircuitBreaker` (Closed/Open/HalfOpen states)
- `AsyncSemaphore` with RAII permits

#### `std/sync` — Synchronization

- `Semaphore`, `Barrier`
- `OnceCell` (lazy initialization)
- `CancellationToken`

---

### Process & System

#### `std/process` — Process Management

- `Command` builder: args, env, cwd, spawn, status, output
- `ExitStatus`, `Output`, `Child`
- Pipe IPC: `Pipe`, `pipe_create()`, non-blocking mode
- `Stdio` configuration: `Inherit`, `Piped`, `Null`, `Fd`
- `PipedCommand` with stdin/stdout/stderr redirection
- `PipedChild`: write_stdin, read_stdout, read_stderr, signal, kill, try_wait
- Process groups: `ProcessGroup`, signal_all, terminate_all, kill_all
- Signal forwarding: `SignalForwarder`
- Environment builder: `EnvBuilder`, PATH manipulation
- Process priority: `nice`, `get_priority`, `set_priority`
- Pipeline: chain commands with `Pipeline`
- Process info: `current_pid`, `parent_pid`, `current_uid`, `effective_uid`
- Environment: `env_var`, `set_env_var`, `remove_env_var`, `current_env`

#### `std/signal` — Signal Handling

- 29 POSIX signals (SIGHUP through SIGWINCH)
- `signal_trap`, `signal_ignore`, `signal_reset`
- Signal names and descriptions

#### `std/env` — Environment

- Environment variable access
- Platform constants

---

### Compression

#### `std/compress` — Compression & Archives

- **ZLIB/DEFLATE**: compress, decompress, streaming
- **Gzip**: compress, decompress with header/footer
- **Tar archives**: create, extract, append, streaming
- **Zip archives**: create, extract, individual entries
- **Zstd**: one-shot and streaming compress/decompress (FFI to libzstd)
- **Brotli**: compress with quality/mode, decompress (FFI to libbrotli)
- **LZ4**: fast compress/decompress (FFI to liblz4)
- **Checksums**: CRC-32, Adler-32

---

### Date, Time & Math

#### `std/time` — Date and Time

- Timestamps, durations, formatting

#### `std/math` — Mathematics

- Trigonometric, exponential, logarithmic functions (FFI to libm)
- `BigInt` (arbitrary precision integers)
- `BigDecimal` (arbitrary precision decimals)
- Statistics: mean, variance, stddev, median, percentile
- Primes: primality testing, sieve, prime factorization

#### `std/random` — Random Numbers

- `Rng` trait
- Generators: Xoshiro256**, SplitMix64, PCG32
- Distributions: uniform, range, bool, gaussian, poisson, shuffle, sample

---

### UI & Graphics

#### `std/ui` — UI Framework
#### `std/layout` — Layout Engine
#### `std/render` — Rendering
#### `std/anim` — Animation
#### `std/accessibility` — Accessibility (WCAG)

---

### Testing & Quality

#### `std/test` — Testing Framework

- Unit tests, integration tests
- Assertions, test discovery, test runner

#### `std/test_gen` — Test Generation

- Property-based testing
- Fuzz testing

#### `std/bench` — Benchmarking

- Micro-benchmarks
- Statistical analysis

#### `std/profile` — Profiling

- CPU and memory profiling

#### `std/snapshot` — Snapshot Testing
#### `std/semantic_diff` — Semantic Diffing

---

### Agentic AI & Safety

#### `std/contracts` — Design by Contract

- `@require`, `@ensure`, `@invariant`
- Contract checking modes

#### `std/capabilities` — Capability System

- Fine-grained permissions
- Capability tokens

#### `std/effects` — Effect System

- Algebraic effects and handlers

#### `std/budget` — Resource Budgets

- CPU, memory, network budgets
- Budget enforcement

#### `std/supply_chain` — Supply Chain Security
#### `std/replay` — Deterministic Replay

---

### Tooling Modules (`tg_compiler/`)

| Module | Purpose |
|--------|---------|
| `pkg_manager.tg` | Dependency resolution (SAT solver), lockfiles, build plans |
| `registry.tg` | HTTP/local registry clients, caching, retry |
| `template.tg` | 8 project templates, scaffolding, variable expansion |
| `bindgen.tg` | FFI binding generation for C/Rust/WIT |
| `cross_compile.tg` | Target triples, toolchain config, 14 supported targets |
| `wasm_target.tg` | WASM binary generation, WASI imports, component model |
| `debugger.tg` | DWARF debug info, LLDB/GDB pretty-printers |

---

## Checklist Coverage

### 1. Core Standard Library — COMPLETE

- [x] Primitive types and collections
- [x] String handling (UTF-8)
- [x] I/O and filesystem
- [x] Serialization (JSON, TOML, YAML, CSV, CBOR, MessagePack)
- [x] Math, random, regex
- [x] Date/time
- [x] Cryptography (hashing, encryption, signing, certificates)
- [x] Compression (zlib, gzip, tar, zip, zstd, brotli, lz4)
- [x] Path manipulation

### 2. Module System & Packaging — COMPLETE

- [x] Module imports/exports
- [x] Package manager with SAT resolver
- [x] Registry (HTTP + local)
- [x] Lock files for reproducibility
- [x] SemVer version constraints
- [x] Feature flags
- [x] Workspaces

### 3. Build System & Tooling — COMPLETE

- [x] Compiler (lexer, parser, type checker, codegen)
- [x] Formatter (`tg fmt`)
- [x] Linter (`tg lint`)
- [x] Documentation generator (`tg doc`)
- [x] Code coverage (`tg cov`)
- [x] Refactoring tools
- [x] Project templates/scaffolding
- [x] VS Code extension with LSP

### 4. Error Handling — COMPLETE

- [x] `Result[T, E]` and `Option[T]`
- [x] `?` operator for propagation
- [x] Error context chaining
- [x] Error kinds with stable codes
- [x] Pattern matching on errors
- [x] Contracts (`@require`, `@ensure`)

### 5. Concurrency & Async — COMPLETE

- [x] OS threading with thread pools
- [x] Scoped threads
- [x] Mutexes, RwLocks, Condvars, Barriers, Semaphores
- [x] Atomics
- [x] Channels (sync and async)
- [x] Async/await with executor
- [x] Structured concurrency (TaskScope/nursery)
- [x] Cancellation tokens
- [x] Async streams
- [x] Retry, circuit breaker

### 6. Interoperability — COMPLETE

- [x] C FFI (`extern "C"`)
- [x] Rust FFI
- [x] Ruby FFI
- [x] WebAssembly export/import
- [x] Bindgen for C/Rust/WIT
- [x] ABI stability guarantees

### 7. Runtime & Memory Model — COMPLETE

- [x] Ownership and borrowing
- [x] Lifetimes
- [x] Move/Copy/Clone semantics
- [x] Smart pointers (Box, Rc, Arc, Weak)
- [x] Pluggable allocators
- [x] Progressive modes (Dev/Strict/Production/Hardened)

### 8. Testing & Benchmarking — COMPLETE

- [x] Unit and integration testing
- [x] Property-based testing
- [x] Fuzz testing
- [x] Snapshot testing
- [x] Benchmarking framework
- [x] Code coverage

### 9. Debugging & Profiling — COMPLETE

- [x] DWARF debug info generation
- [x] LLDB/GDB integration with pretty-printers
- [x] `std/debug` module (breakpoints, watch, timer, memory stats)
- [x] CPU and memory profiling
- [x] Backtraces

### 10. Deployment Targets — COMPLETE

- [x] Native x86_64 (Linux, macOS, Windows)
- [x] Native ARM64 (macOS, Linux)
- [x] WebAssembly (browser + WASI)
- [x] Cross-compilation (14 targets)
- [x] Static linking (musl)
- [x] Container deployment

### 11. Application Primitives — COMPLETE

- [x] HTTP client and server
- [x] WebSocket support
- [x] Database access (SQLite, PostgreSQL, MySQL)
- [x] Authentication (JWT, OAuth 2.0)
- [x] Configuration management
- [x] CLI building
- [x] Logging and tracing
- [x] Process management and IPC
- [x] Signal handling
- [x] UI framework
