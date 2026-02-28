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

### Core Types
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
