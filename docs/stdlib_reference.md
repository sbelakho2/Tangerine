# Tangerine Standard Library Reference

**Version:** 0.1.0  
**Last Updated:** March 1, 2026

This document provides a comprehensive reference for all modules in the Tangerine standard library.

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

---

## UI & Graphics

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
- [Memory Model](memory_model.md) - Ownership, borrowing, and lifetimes
- [Error Handling Guide](error_handling.md) - Error handling patterns and best practices
- [Concurrency Guide](concurrency.md) - Threading and async programming
- [Packaging Guide](packaging.md) - Package management and publishing
- [Deployment Targets](deployment_targets.md) - Cross-compilation and deployment
- [Completeness Report](stdlib_completeness.md) - Full module inventory and checklist
- [Style Guide](style_guide.md) - Code formatting and conventions
- [FFI Cheat Sheet](ffi_cheatsheet.md) - Quick FFI reference
