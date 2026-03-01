# Tangerine Standard Library Reference

**Version:** 0.1.0  
**Last Updated:** March 1, 2026

This document provides a comprehensive reference for all modules in the Tangerine standard library.

---

## Table of Contents

1. [Core Types](#core-types) - `std/core`
2. [Serialization](#serialization) - `std/serde`, `std/json`, `std/toml`
3. [HTTP & Networking](#http--networking) - `std/http`, `std/url`, `std/net`
4. [Web Framework](#web-framework) - `std/web`
5. [Database](#database) - `std/db`
6. [Cryptography](#cryptography) - `std/crypto`
7. [CLI & Terminal](#cli--terminal) - `std/cli`
8. [Logging & Tracing](#logging--tracing) - `std/log`
9. [Regular Expressions & Parsing](#regular-expressions--parsing) - `std/regex`
10. [Compression & Archives](#compression--archives) - `std/compress`
11. [Date & Time](#date--time) - `std/time`
12. [Async & Concurrency](#async--concurrency) - `std/async`, `std/thread`
13. [I/O & Filesystem](#io--filesystem) - `std/io`, `std/fs`
14. [Testing](#testing) - `std/test`
15. [UI & Graphics](#ui--graphics) - `std/ui`
16. [Contracts & Capabilities](#contracts--capabilities) - `std/contracts`, `std/capabilities`
17. [Profiling & Observability](#profiling--observability) - `std/profile`, `std/snapshot`
18. [Effects & Budgets](#effects--budgets) - `std/effects`, `std/budget`

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
loop {
  let request = server.accept()?
  let response = handle_request(request)
  server.respond(response)?
}
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
app.get("/", |ctx: &mut Context| {
  ctx.html("<h1>Home</h1>")
})

app.get("/users/:id", |ctx: &mut Context| {
  let id = ctx.param("id").unwrap()
  let user = get_user(id)?
  ctx.json_response(&user)
})

app.post("/users", |ctx: &mut Context| {
  let user: User = ctx.json()?
  let created = create_user(user)?
  ctx.status(StatusCode::Created).json_response(&created)
})

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
- WebSocket support (planned)

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
for row in rows {
  let id: Int = row.get(0)?
  let name: String = row.get(1)?
}

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

if matches.get_flag("verbose") {
  println!("Verbose mode enabled")
}

if let Option::Some(output) = matches.get_value("output") {
  println!("Output: {}", output)
}

# Terminal colors
terminal::print_colored("Success!", Color::Green)
terminal::print_bold("Important message")

# Progress bars
let pb = ProgressBar::new(100)
pb.set_message("Processing...")
for i in 0..100 {
  pb.set(i)
  # ... work ...
}
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

# Simple logging
info!("Server started on port {}", port)
warn!("Connection pool at {}% capacity", percent)
error!("Failed to process request: {}", error)

# Structured logging
info!(
  "user_action",
  "action" => "login",
  "user_id" => user_id,
  "ip" => ip_addr
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
for m in re.find_all(text) {
  println!("Found: {}", m.as_str())
}

let replaced = re.replace_all(text, "XXX-XXXX")

# Parser combinators
let digit = Parser::digit()
let digits = many(digit).map(|ds| ds.join("").parse_int())
let number = digits

let plus = char_p('+')
let minus = char_p('-')
let op = choice([plus, minus])

let expr = number.and(op).and(number)
  .map(|((a, op), b)| {
    if op == '+' then a + b else a - b
  })

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
for entry in reader.entries()? {
  println!("{}: {} bytes", entry.path(), entry.size())
}

# Zip archives
let reader = zip::ZipReader::open("archive.zip")?
for entry in reader.entries()? {
  let data = reader.extract(&entry)?
}

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
let handle = spawn(async {
  compute_heavy().await
})
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
let handle = Thread::spawn(|| {
  compute_result()
})
let result = handle.join()?

# Mutex
let counter = Mutex::new(0)
{
  let mut guard = counter.lock()
  *guard += 1
}

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
for line in reader.lines() {
  println!("{}", line?)
}

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
for entry in walk_dir("src")? {
  if entry.is_file() {
    println!("File: {}", entry.path())
  }
}

# Recursive with filtering
for entry in walk_dir("src")?.filter(|e| e.extension() == Some("tg")) {
  process_file(entry.path())?
}
```

---

## Testing

### `std/test` - Testing Framework

Unit tests, integration tests, and snapshot testing.

```tangerine
use std::test::{test, assert_eq, assert_ne, assert_throws, snapshot}

#[test]
def test_addition()
  assert_eq(2 + 2, 4)
  assert_eq(add(10, 20), 30)
end

#[test]
def test_error_handling()
  assert_throws(|| {
    divide(10, 0)
  })
end

#[test]
def test_snapshot()
  let output = render_template(test_data)
  snapshot::assert_eq("template_output", &output)
end

# Property testing
#[test_prop]
def test_reverse_twice(list: Vec[Int])
  assert_eq(list.reverse().reverse(), list)
end
```

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

Preconditions, postconditions, and invariants.

```tangerine
use std::contracts::{pre, post, invariant}

def sqrt(x: Float) -> Float
  pre x >= 0.0, "sqrt requires non-negative input"
  post result >= 0.0 && (result * result - x).abs() < 0.001, "result² ≈ x"
  
  x.sqrt()
end

struct BankAccount {
  balance: Float
  
  invariant self.balance >= 0.0, "balance must be non-negative"
}

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

### `std/capabilities` - Capability System

Fine-grained access control for resources.

```tangerine
use std::capabilities::{cap, requires}

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
loop {
  timer.begin_frame()
  
  # Render frame...
  
  let stats = timer.end_frame()
  if stats.fps < 55.0 {
    warn!("Low FPS: {:.1}", stats.fps)
  }
}

# Benchmarking
let mut bench = Benchmark::new("sort_1000")
  .iterations(1000)
  .warmup(100)

let result = bench.run(|| {
  let mut data = generate_data()
  sort(&mut data)
})

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
println!("Recorded {} events", stats.event_count)

# Replay
let player = Player::new("session.replay")
player.open()?

# Step through execution
loop {
  match player.step() {
    Result::Ok(event) => println!("Event: {:?}", event),
    Result::Err(PlayerError::EndOfRecording) => break,
    Result::Err(e) => return Result::Err(e),
  }
}

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
  log(level, msg) => println!("[{}] {}", level, msg)
end
```

### `std/budget` - Resource Budgets

Enforce resource limits at runtime.

```tangerine
use std::budget::{budget, budget_remaining, budget_exceeded}

def expensive_operation(data: Data) -> Result[Output, Error]
  budget time: 5s, memory: 100MB, api_calls: 10
  
  for item in data {
    if budget_remaining("api_calls") < 2 {
      # Use cached data instead
      use_cache(item)?
    } else {
      fetch_remote(item)?
    }
  }
  
  Result::Ok(result)
end
```

---

## See Also

- [Language Reference](language.md) - Complete language specification
- [Interoperability Guide](interop.md) - FFI and foreign language integration
- [Style Guide](style_guide.md) - Code formatting and conventions
- [FFI Cheat Sheet](ffi_cheatsheet.md) - Quick FFI reference
