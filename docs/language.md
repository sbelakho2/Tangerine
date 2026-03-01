# Tangerine Language Reference

## Overview

Tangerine is a systems programming language that combines:
- **Memory Safety** without garbage collection (Rust-like ownership model)
- **High Performance** (compiles directly to native machine code — no C dependency)
- **Agentic AI Support** (contracts, capabilities, effects, budgets)
- **Modern Syntax** (clean, expressive, Ruby-influenced)

## Basic Syntax

### Comments

```tangerine
# Single-line comment

#| 
   Multi-line (block) comment.
   Supports nesting:
   #| inner comment |#
   still in outer comment.
|#
```

### Variables

```tangerine
# Immutable binding
let x = 42

# Mutable binding
mut y = 10
y = y + 1

# With type annotation
let z: Int = 100
mut w: Float = 3.14
```

### Types

#### Primitive Types
- `Unit` - empty type (like `void`)
- `Bool` - `true` or `false`
- `Int` - 64-bit signed integer
- `Float` - 64-bit floating point
- `Char` - Unicode scalar value
- `String` - UTF-8 string

#### Composite Types
```tangerine
# Tuples
let pair: (Int, String) = (42, "hello")

# Arrays (fixed size)
let arr: [Int; 5] = [1, 2, 3, 4, 5]

# Slices (dynamic view)
let slice: [Int] = arr[1..4]

# Option (nullable)
let maybe: Option[Int] = Option::Some(42)

# Result (error handling)
let result: Result[Int, String] = Result::Ok(42)
```

### Functions

```tangerine
# Basic function
def add(a: Int, b: Int) -> Int
  a + b
end

# Expression body
def square(x: Int) -> Int = x * x

# Generic function
def identity[T](x: T) -> T = x

# Function with multiple statements
def greet(name: String) -> String
  let greeting = "Hello, "
  greeting + name + "!"
end

# Pure function (no side effects)
pure def add(a: Int, b: Int) -> Int
  a + b
end

# Inline function
inline def min(a: Int, b: Int) -> Int
  if a < b then a else b end
end
```

### Control Flow

```tangerine
# If expressions (with optional 'then')
let max = if a > b then a else b end

# If statements
if condition then
  do_something()
elsif other_condition then
  do_other()
else
  do_default()
end

# 'then' is optional in multi-line if
if condition
  do_something()
end

# Match expressions (pattern matching)
match value
when 0 then "zero"
when 1 then "one"
when n if n < 10 then "small"
when _ then "large"
end

# Loops
while condition do
  # ...
end

for item in collection do
  # ...
end

# Range iteration
for i in 0..10 do
  # exclusive range
end

for i in 0..=10 do
  # inclusive range
end

# Infinite loop (break to exit)
loop
  if done then
    break value
  end
end

# 'next' skips to next iteration (like 'continue' in C)
for i in 0..10 do
  if i == 5 then next end
  println(i)
end
```

### Blocks and Closures

```tangerine
# Block with parameters (Ruby-style)
items.each do |item|
  println(item)
end

# Trailing block on method call
results = data.map do |x|
  x * 2
end

# Closures
let double = |x: Int| -> Int = x * 2
let add = |a, b| a + b

# Do blocks
let result = do
  let x = compute()
  x + 1
end
```

## Ownership and Borrowing

Tangerine uses Rust-like ownership semantics for memory safety without garbage collection.

### Ownership Rules

1. Each value has exactly one owner
2. When the owner goes out of scope, the value is dropped
3. Ownership can be transferred (moved)

```tangerine
let s1 = String::from("hello")
let s2 = s1  # s1 is moved to s2, s1 is now invalid

# This would be a compile error:
# println(s1)  # Error: use of moved value

# Copy types (Int, Float, Bool, Char) are copied, not moved
let x = 42
let y = x  # x is copied to y
println(x)  # OK: x is still valid
```

### References

```tangerine
# Immutable reference (shared borrow)
let s = String::from("hello")
let r = &s  # borrow s
println(r)  # OK

# Mutable reference (exclusive borrow)
mut s = String::from("hello")
let r = &mut s  # mutable borrow
r.push_str(" world")
```

### Borrowing Rules

1. You can have either:
   - Any number of immutable references, OR
   - Exactly one mutable reference
2. References must always be valid (no dangling pointers)

```tangerine
mut s = String::from("hello")

let r1 = &s     # OK: immutable borrow
let r2 = &s     # OK: multiple immutable borrows

# let r3 = &mut s  # Error: cannot borrow mutably while borrowed immutably

println(r1, r2)  # Borrows end here

let r3 = &mut s  # OK now: previous borrows have ended
```

### Move and Copy

```tangerine
# Explicit move
let s1 = String::from("hello")
let s2 = move s1

# Explicit copy (for Copy types)
let x = 42
let y = copy x

# own - take ownership from reference
def take_ownership(s: own String) -> Unit
  # s is consumed here
end
```

## Structs and Enums

### Structs

```tangerine
struct Point
  x: Float
  y: Float
end

# With visibility
struct User
  pub name: String
  pub email: String
  password_hash: String  # private by default
end

# Constructor
let p = Point { x: 1.0, y: 2.0 }

# Field access
let x = p.x
```

### Enums

```tangerine
enum Color
  Red
  Green
  Blue
  RGB(Int, Int, Int)
  Named(String)
end

let c = Color::RGB(255, 128, 0)

match c
when Color::Red then "red"
when Color::RGB(r, g, b) then format("{}, {}, {}", r, g, b)
when _ then "other"
end
```

### Methods

```tangerine
impl Point
  def new(x: Float, y: Float) -> Self
    Point { x: x, y: y }
  end
  
  def distance(&self, other: &Point) -> Float
    let dx = self.x - other.x
    let dy = self.y - other.y
    (dx * dx + dy * dy).sqrt()
  end
  
  def translate(&mut self, dx: Float, dy: Float) -> Unit
    self.x = self.x + dx
    self.y = self.y + dy
  end
end

let p1 = Point::new(0.0, 0.0)
let p2 = Point::new(3.0, 4.0)
let d = p1.distance(&p2)  # 5.0
```

## Traits

```tangerine
trait Display
  def display(&self) -> String
end

trait Clone
  def clone(&self) -> Self
end

impl Display for Point
  def display(&self) -> String
    format("({}, {})", self.x, self.y)
  end
end

# Trait bounds
def print_all[T: Display](items: &[T]) -> Unit
  for item in items do
    println(item.display())
  end
end

# Where clauses (on function declarations)
def complex[T, U](a: T, b: U) -> T
  where T: Clone + Display, U: Into[T]
  # implementation
end
```

## Error Handling

```tangerine
# Result type
def divide(a: Int, b: Int) -> Result[Int, String]
  if b == 0 then
    Result::Err("division by zero")
  else
    Result::Ok(a / b)
  end
end

# Using match
match divide(10, 2)
when Result::Ok(value) then println("Result: {}", value)
when Result::Err(msg) then println("Error: {}", msg)
end

# Using ? operator (early return on error)
def calculate() -> Result[Int, String]
  let x = divide(10, 2)?
  let y = divide(x, 3)?
  Result::Ok(x + y)
end

# Try/catch
try
  risky_operation()
catch e: IoError then
  println("IO error: {}", e)
catch e: ParseError then
  println("Parse error: {}", e)
finally
  cleanup()
end
```

## Agentic Features

### Design by Contract

```tangerine
# Preconditions (pre)
# Postconditions (post)
def sqrt(x: Float) -> Float
  pre x >= 0.0, "sqrt requires non-negative input"
  post result * result == x, "result squared equals input"
  
  # implementation
end

# Invariants (for structs)
struct BankAccount
  balance: Float
  
  invariant self.balance >= 0.0, "balance must be non-negative"
end
```

### Capabilities

```tangerine
# Declare a capability
cap Filesystem
  implies FileRead, FileWrite
end

cap Network
  implies NetworkRead, NetworkWrite
end

# Function requiring capabilities
def download_file(url: String, path: String) -> Result[Unit, Error]
  requires Network, Filesystem
  
  let data = http_get(url)?
  write_file(path, data)
end

# Capability narrowing
def safe_process(data: String) -> String
  requires !Network  # explicitly no network access
  
  process_locally(data)
end
```

### Effects

```tangerine
# Declare an effect
effect Logger
  log(level: LogLevel, message: String) -> Unit
end

effect State[S]
  get() -> S
  put(s: S) -> Unit
end

# Function with effects
def process_with_logging(data: String) -> String
  effect Logger
  
  Logger::log(LogLevel::Info, "Processing started")
  let result = transform(data)
  Logger::log(LogLevel::Info, "Processing complete")
  result
end

# Handle effects
handle process_with_logging("input")
with Logger
  log(level, msg) => println("[{}] {}", level, msg)
end
```

### Budgets

```tangerine
# Budget annotation
def expensive_operation() -> Result[Data, Error]
  budget time: 5s, memory: 100MB, api_calls: 10
  
  # implementation with resource tracking
end

# Budget checking
if budget_remaining("api_calls") < 5 then
  use_cached_result()
else
  fetch_fresh_data()
end
```

### Rationale Documentation

```tangerine
rationale
  objective: "Implement efficient string interning"
  why: "Reduces memory usage for repeated strings"
  how: "Use a global hash set with reference counting"
  tradeoffs:
    - "Slightly slower string creation"
    - "Uses global state"
  alternatives:
    - "Arena allocation: rejected, doesn't deduplicate"
    - "Copy-on-write: rejected, more complex implementation"
end
```

## Async/Await

```tangerine
# Async function
async def fetch_data(url: String) -> Result[String, Error]
  let response = http_get(url).await?
  let body = response.text().await?
  Result::Ok(body)
end

# Running async code
async def main() -> Unit
  let data = fetch_data("https://example.com").await
  match data
  when Result::Ok(s) then println(s)
  when Result::Err(e) then println("Error: {}", e)
  end
end

# Concurrent execution
async def fetch_all(urls: &[String]) -> Vec[String]
  let futures = urls.iter().map(|url| fetch_data(url))
  join_all(futures).await
end
```

## Modules

```tangerine
# File: src/math/vector.tg
module vector

pub struct Vec2
  pub x: Float
  pub y: Float
end

pub def dot(a: &Vec2, b: &Vec2) -> Float
  a.x * b.x + a.y * b.y
end

# Private helper
def internal_helper() -> Unit
  # not accessible outside module
end
```

```tangerine
# File: src/main.tg
use math::vector::{Vec2, dot}

# Glob import
use std::collections::*

# Aliased import
use very::long::path::Name as Short

def main() -> Unit
  let v1 = Vec2 { x: 1.0, y: 0.0 }
  let v2 = Vec2 { x: 0.0, y: 1.0 }
  println("Dot product: {}", dot(&v1, &v2))
end
```

## Unsafe Code

```tangerine
# Unsafe block with mandatory justification string
unsafe "raw pointer manipulation"
  let ptr = raw_alloc(size)
  write_bytes(ptr, data)
  let result = read_bytes(ptr, size)
  raw_dealloc(ptr)
end

# Unsafe function
unsafe def raw_copy(src: RawPtr, dst: RawPtr, len: Int) -> Unit
  # ...
end
```

## Foreign Function Interface (FFI)

Tangerine provides comprehensive FFI support for C, Rust, and Ruby interoperability.

### C Interop

```tangerine
# Export function to C
@export("my_add")
extern "C" def add(a: i32, b: i32) -> i32
  a + b
end

# Import C function
extern "C" {
    def malloc(size: usize) -> *mut u8
    def free(ptr: *mut u8)
}

# FFI-safe struct
@repr(C)
struct Point
  x: f64
  y: f64
end
```

### FFI Types

```tangerine
use std::ffi::{FfiStr, FfiSlice, TgResult}

# String view (borrowed UTF-8)
@export("process_string")
extern "C" def process_string(s: FfiStr) -> i32
  # ...
end

# Slice view (borrowed array)
@export("sum_array")
extern "C" def sum_array(arr: FfiSlice[i32]) -> i64
  # ...
end

# Error handling across FFI
@export("parse")
extern "C" def parse(s: FfiStr) -> TgResult[i64]
  # ...
end
```

### Ownership Across FFI

```tangerine
use std::ffi::{Borrowed, Owned}

# Borrowed: temporary access, no cleanup
@export("read_data")
extern "C" def read_data(buf: Borrowed[FfiSlice[u8]]) -> i32
  # ...
end

# Owned: caller transfers ownership, must specify allocator
@ffi(alloc = "tangerine")
@export("create_buffer")
extern "C" def create_buffer(size: usize) -> Owned[*mut u8]
  # ...
end
```

For complete FFI documentation, see:
- [Interoperability Guide](interop.md) - Full reference
- [FFI Cheat Sheet](ffi_cheatsheet.md) - Quick reference

## Compile-time Evaluation

```tangerine
# Compile-time constants
const MAX_SIZE: Int = 1024
const PI: Float = 3.14159265359

# Compile-time computation
comptime
  let table = build_lookup_table()
end

# Conditional compilation
edition 2024
  # Use new syntax
end
```

## Generics

```tangerine
# Generic struct
struct Box[T]
  value: T
end

# Generic function
def swap[T](a: &mut T, b: &mut T) -> Unit
  let tmp = move *a
  *a = move *b
  *b = move tmp
end

# Multiple type parameters with bounds
struct HashMap[K: Hash + Eq, V]
  buckets: Vec[Vec[(K, V)]]
end

# Associated types in traits
trait Iterator
  type Item
  def next(&mut self) -> Option[Self::Item]
end
```

## Pattern Matching

```tangerine
# Destructuring structs
let Point { x, y } = point

# Tuple destructuring
let (first, second) = tuple

# Match guards
match value
when n if n > 0 then "positive"
when n if n < 0 then "negative"
when 0 then "zero"
end

# Or patterns
match char
when 'a' | 'e' | 'i' | 'o' | 'u' then "vowel"
when _ then "consonant"
end

# Ref patterns
match option
when Option::Some(ref value) then use_ref(value)
when Option::Some(&mut value) then modify(&mut value)
when Option::None then ()
end

# Struct patterns
match point
when Point { x: 0, y } then "on y-axis"
when Point { x, y: 0 } then "on x-axis"
when Point { x, y } then "elsewhere"
end

# Enum variant patterns with path
match result
when Result::Ok(value) then use(value)
when Result::Err(msg) then report(msg)
end
```

## Macros

```tangerine
# Macro declaration
macro assert(cond: Expr)
  if !cond then
    panic("Assertion failed: " + stringify(cond))
  end
end

macro debug_print(value: Expr)
  println("[DEBUG] {} = {}", stringify(value), value)
end
```

## Standard Library

The Tangerine standard library provides comprehensive modules for building real-world applications.

### Core (`std/core`)

Foundation types and traits:

- `Option[T]` - Optional value (`Some(T)` / `None`)
- `Result[T, E]` - Result or error (`Ok(T)` / `Err(E)`)
- `Vec[T]` - Dynamic array
- `Map[K, V]` - Hash map
- `Set[T]` - Hash set
- `String` - UTF-8 string
- `Rc[T]` - Reference counted pointer
- `Arc[T]` - Atomic reference counted pointer

### Common Traits

- `Clone` - Explicit duplication
- `Copy` - Implicit copy
- `Drop` - Destructor
- `Default` - Default value
- `Display` - User-facing string representation
- `Debug` - Debug string representation
- `Eq`, `PartialEq` - Equality comparison
- `Ord`, `PartialOrd` - Ordering comparison
- `Hash` - Hashing
- `Iterator` - Iteration protocol

### Serialization (`std/serde`, `std/json`, `std/toml`)

```tangerine
use std::serde::{Serialize, Deserialize}
use std::json::Json
use std::toml::Toml

@derive(Serialize, Deserialize)
struct Config
  host: String
  port: Int
end

let config = Config { host: "localhost".to_string(), port: 8080 }
let json_str = Json::stringify(&config)
let parsed: Config = Json::parse(&json_str)?

let toml_str = Toml::stringify(&config)
```

### HTTP & Networking (`std/http`, `std/url`, `std/net`)

```tangerine
use std::http::{HttpClient, HttpServer, HttpRequest, HttpResponse}
use std::url::Url

# HTTP client
let client = HttpClient::new()
let response = client.get("https://api.example.com/data")?

# HTTP server
let server = HttpServer::bind("0.0.0.0:8080")?
server.route("/api", handle_api)
server.listen()?

# URL parsing
let url = Url::parse("https://example.com/path?query=value")?
```

### Web Framework (`std/web`)

```tangerine
use std::web::{App, Context, middleware}

let app = App::new()
app.middleware(middleware::logger)
app.middleware(middleware::cors)

app.get("/", |ctx: &mut Context| ctx.text("Hello, World!"))
app.get("/users/:id", |ctx: &mut Context| {
  let id = ctx.param("id")?
  ctx.json_response(&get_user(id)?)
})
app.post("/users", |ctx: &mut Context| {
  let user: User = ctx.json()?
  ctx.status(StatusCode::Created).json_response(&create_user(user)?)
})

app.listen("0.0.0.0:8080")?
```

### Database (`std/db`)

```tangerine
use std::db::{Connection, Sqlite, Postgres, QueryBuilder, Pool}

# SQLite
let db = Sqlite::open("app.db")?
db.execute("CREATE TABLE users (id INTEGER, name TEXT)")?
db.execute_params("INSERT INTO users VALUES (?, ?)", (1, "Alice"))?

# PostgreSQL
let pg = Postgres::connect("postgres://user:pass@localhost/db")?
let rows = pg.query("SELECT * FROM users WHERE age > $1", (18,))?

# Query builder
let query = QueryBuilder::new()
  .select("*").from("users").where_clause("active = ?").order_by("name")
let (sql, params) = query.build()

# Connection pooling
let pool = Pool::new(Postgres::connect_string, 10)?
let conn = pool.get()?
```

### Cryptography (`std/crypto`)

```tangerine
use std::crypto::{sha256, hmac_sha256, aes, random_bytes, base64, hex}

# Hashing
let hash = sha256(b"message")
let mac = hmac_sha256(key, message)

# Encryption
let key = random_bytes(32)
let iv = random_bytes(16)
let ciphertext = aes::encrypt_cbc(plaintext, &key, &iv)?
let decrypted = aes::decrypt_cbc(ciphertext, &key, &iv)?

# Encoding
let encoded = base64::encode(data)
let decoded = base64::decode(&encoded)?
```

### CLI & Terminal (`std/cli`)

```tangerine
use std::cli::{App, Arg, terminal, ProgressBar}

let app = App::new("myapp", "My CLI application")
  .version("1.0.0")
  .arg(Arg::new("verbose").short('v').flag())
  .arg(Arg::new("output").short('o').takes_value())
  .subcommand(Command::new("build").about("Build the project"))

let matches = app.parse()?
if matches.get_flag("verbose") { ... }

# Terminal output
terminal::print_colored("Success!", Color::Green)
let pb = ProgressBar::new(100)
for i in 0..100 { pb.set(i); }
pb.finish()
```

### Logging & Tracing (`std/log`)

```tangerine
use std::log::{Logger, Level, info, warn, error, Span, Metrics}

Logger::init(Level::Info)

info!("Server started on port {}", port)
warn!("Connection pool low: {} available", count)
error!("Request failed: {}", err)

# Distributed tracing
let span = Span::new("handle_request")
span.set("user_id", user_id)
# ... work ...
span.finish()

# Prometheus metrics
Metrics::counter("requests_total").inc()
Metrics::histogram("request_duration").observe(elapsed)
```

### Regular Expressions & Parsing (`std/regex`)

```tangerine
use std::regex::{Regex, Parser, many, choice}

# Regex
let re = Regex::new(r"\d{3}-\d{4}")?
if re.is_match("555-1234") { ... }
let captures = re.captures("Phone: 555-1234")?

# Parser combinators
let digit = Parser::digit()
let number = many(digit).map(|ds| ds.join("").parse_int())
let expr = choice([add_expr, mul_expr, number])
```

### Compression & Archives (`std/compress`)

```tangerine
use std::compress::{gzip, deflate, tar, zip}

# Gzip compression
let compressed = gzip::compress(data)?
let decompressed = gzip::decompress(&compressed)?

# Tar archives
let builder = tar::TarBuilder::new(file)
builder.add_file("README.md", readme_content)?
builder.finish()?

# Zip archives
let reader = zip::ZipReader::open("archive.zip")?
for entry in reader.entries()? { ... }
```

### Date, Time & Duration (`std/time`)

```tangerine
use std::time::{DateTime, Duration, Instant, TimeZone}

let now = DateTime::now()
let utc = DateTime::now_utc()
let parsed = DateTime::parse("2026-03-01T12:00:00Z", "%Y-%m-%dT%H:%M:%SZ")?

let duration = Duration::from_secs(60)
let later = now + duration

let start = Instant::now()
# ... work ...
let elapsed = start.elapsed()
```

### Async & Concurrency (`std/async`, `std/thread`)

```tangerine
use std::async::{spawn, join_all, sleep}
use std::thread::{Thread, Mutex, Channel, AtomicInt}

# Async
async def fetch_all(urls: &[String]) -> Vec[Response]
  let tasks = urls.iter().map(|u| spawn(fetch(u)))
  join_all(tasks).await
end

# Threads
let handle = Thread::spawn(|| compute_heavy())
let result = handle.join()?

# Channels
let (tx, rx) = Channel::new()
tx.send(message)?
let msg = rx.recv()?

# Atomics
let counter = AtomicInt::new(0)
counter.fetch_add(1, Ordering::SeqCst)
```

### I/O & Filesystem (`std/io`, `std/fs`)

```tangerine
use std::fs::{File, read_to_string, write, create_dir, walk_dir}
use std::io::{BufReader, BufWriter}

let content = read_to_string("config.toml")?
write("output.txt", &data)?

let file = File::open("large.bin")?
let reader = BufReader::new(file)
for line in reader.lines() { ... }

for entry in walk_dir("src")? {
  if entry.is_file() && entry.extension() == "tg" { ... }
}
```

### Testing (`std/test`, `std/bench`)

```tangerine
use std::test::{test, assert_eq, assert_throws, snapshot}
use std::bench::Benchmark

#[test]
def test_addition()
  assert_eq(2 + 2, 4)
end

#[test]
def test_snapshot()
  let output = render_template(data)
  snapshot::assert_eq("template_output", &output)
end

#[bench]
def bench_sort()
  let mut bm = Benchmark::new("sort_1000")
  bm.run(|| sort(&mut data))
end
```

### UI & Graphics (`std/ui`)

```tangerine
use std::ui::{Canvas, Color, Image, Font, Animation}

let canvas = Canvas::new(800, 600)
canvas.fill_rect(0, 0, 800, 600, Color::WHITE)
canvas.draw_text("Hello!", 100, 100, &font, Color::BLACK)
canvas.fill_circle(400, 300, 50, Color::RED)

let image = Image::load_png("sprite.png")?
canvas.draw_image(&image, 200, 200)

let anim = Animation::new(0.0, 1.0, Duration::from_secs(1))
  .with_easing(easing::ease_in_out_quad)
```

### Contracts & Capabilities (`std/contracts`, `std/capabilities`)

```tangerine
use std::contracts::{pre, post, invariant}

def sqrt(x: Float) -> Float
  pre x >= 0.0, "sqrt requires non-negative input"
  post result >= 0.0, "result must be non-negative"
  # implementation
end

cap FileSystem implies FileRead, FileWrite end
cap Network implies NetworkRead, NetworkWrite end

def download(url: String) -> Result[Vec[u8], Error]
  requires Network, FileSystem
  # implementation
end
```

### Profiling & Observability (`std/profile`, `std/snapshot`)

```tangerine
use std::profile::{Profiler, FrameTimer, Benchmark, profile}
use std::snapshot::{Recorder, Player}

# CPU profiling
let profiler = Profiler::new()
profiler.start()
# ... work ...
profiler.stop()
profiler.report().print()
profiler.write_flamegraph("profile.svg")?

# Frame timing (for games/UI)
let timer = FrameTimer::with_target_fps(60.0)
loop {
  timer.begin_frame()
  # ... render ...
  let stats = timer.end_frame()
  println!("FPS: {:.1}", stats.fps)
}

# Execution recording/replay
let recorder = Recorder::new("session.replay")
recorder.start()
# ... program execution ...
recorder.stop()

let player = Player::new("session.replay")
player.play()
```

### Effects & Budgets (`std/effects`, `std/budget`)

```tangerine
use std::effects::{effect, handle}
use std::budget::{budget, budget_remaining}

effect Logger
  log(level: Level, msg: String) -> Unit
end

def process_with_log(data: String) -> String
  effect Logger
  Logger::log(Level::Info, "Processing")
  transform(data)
end

handle process_with_log(input)
with Logger
  log(level, msg) => println!("[{}] {}", level, msg)
end

def expensive_op() -> Result[Data, Error]
  budget time: 5s, memory: 100MB
  # implementation
end
```

## Compiler Invocation

```bash
# Compile to native executable (directly — no C dependency)
tg main.tg -o main

# Compile with optimizations
tg main.tg -O2 -o main

# Maximum optimization
tg main.tg -O3 -o main

# Check only (no code generation)
tg main.tg --check

# Emit object file
tg main.tg --emit-obj -o main.o

# Emit MIR (mid-level IR)
tg main.tg --emit-mir

# Print AST
tg main.tg --print-ast

# Print tokens
tg main.tg --print-tokens

# Compile only (don't link)
tg main.tg -c

# Verbose / quiet output
tg main.tg -v
tg main.tg -q

# Include debug info
tg main.tg -g -o main

# Warning controls
tg main.tg -W       # Enable warnings
tg main.tg -Werror  # Treat warnings as errors

# Disable agentic features selectively
tg main.tg --no-contracts
tg main.tg --no-capabilities
tg main.tg --no-effects
tg main.tg --no-budgets
```

### Target Architecture

Tangerine compiles directly to native machine code for:
- **x86-64** (System V AMD64, Windows x64 calling conventions)
- **ARM64** (AAPCS64 calling convention)

Object file formats supported:
- **ELF64** (Linux, BSD)
- **Mach-O 64** (macOS)
- **COFF/PE** (Windows)

### FFI and Bindgen Commands

```bash
# Generate C header for extern "C" exports
tg bindgen c src/lib.tg -o tangerine.h

# Generate Rust shim crate
tg bindgen rust src/lib.tg -o tangerine_shim

# Generate Ruby extension scaffold
tg bindgen ruby src/lib.tg -o my_extension

# Test ABI conformance
tg abi test

# Dump type layouts
tg abi dump src/lib.tg

# Check ABI compatibility between versions
tg abi check v1/lib.tg v2/lib.tg
```

## See Also

- [Standard Library Reference](stdlib_reference.md) - **Comprehensive API documentation**
- [Grammar Reference](grammar.md) - Formal grammar specification
- [Style Guide](style_guide.md) - Code style conventions
- [Interoperability Guide](interop.md) - C/Rust/Ruby FFI
- [FFI Cheat Sheet](ffi_cheatsheet.md) - Quick FFI reference
- [Unicode Policy](unicode_policy.md) - Unicode handling
- [Versioning Policy](versioning.md) - Version numbering
- [RFC Process](rfc_process.md) - How to propose changes
- [Registry Policy](registry_policy.md) - Package registry rules
