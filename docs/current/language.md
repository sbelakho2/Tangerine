# Tangerine Language Reference

## Overview

Tangerine is a systems programming language that combines:
- **Memory Safety** without garbage collection (access/resource ownership model)
- **High Performance** (compiles directly to native machine code — no C dependency)
- **Agentic AI Support** (contracts, capabilities, effects, budgets)
- **Modern Syntax** (clean, expressive, Ruby-influenced)

## Basic Syntax

> **Doctest discipline.** Every ` ```tangerine ` (and unlabeled) fenced block
> in the six doctested documents (`language.md`, `grammar.md`,
> `memory_model.md`, `stabilized_subset.md`, `feature_matrix.md`,
> `feature_registry.md`) is checked by `scripts/check_doctests.sh`: an
> unannotated block must be free of every forbidden legacy form (E100/E106)
> and, when a current compiler binary exists, must compile; a block that
> intentionally demonstrates a rejection is annotated `compile_fail: <the
> expected diagnostic substring>` on its first line, and the script verifies
> that substring against the compiler's diagnostic text. See
> `scripts/check_doctests.sh` for the exact convention.

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
- `UInt` - 64-bit unsigned integer
- `Float` - 64-bit floating point
- `Char` - Unicode scalar value
- `String` - owned, mutable UTF-8 string (mutable via `var` bindings or `inout` access)

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

#### FFI-Specific Sized Integer Types

When interfacing with C or other languages via FFI, Tangerine provides sized
integer types that map directly to their C equivalents:

| Tangerine FFI Type | C Equivalent | Size |
|--------------------|-------------|------|
| `i8` | `int8_t` | 1 byte |
| `u8` | `uint8_t` | 1 byte |
| `i16` | `int16_t` | 2 bytes |
| `u16` | `uint16_t` | 2 bytes |
| `i32` | `int32_t` | 4 bytes |
| `u32` | `uint32_t` | 4 bytes |
| `i64` / `Int` | `int64_t` | 8 bytes |
| `u64` / `UInt` | `uint64_t` | 8 bytes |
| `f32` | `float` | 4 bytes |
| `f64` / `Float` | `double` | 8 bytes |

These sized types are primarily used in `extern` declarations and `@repr(C)`
structs. In regular Tangerine code, prefer `Int`, `UInt`, and `Float`.

#### Array and Collection Types

Tangerine distinguishes three array-like types:

- **`[T; N]`** — Fixed-size array. Stack-allocated, size known at compile time.
- **`[T]`** — Slice. A view into contiguous memory (pointer + length).
- **`Array[T]` / `Vec[T]`** — Growable dynamic array (heap-allocated, ptr + len + cap). `Vec[T]` is a type alias for `Array[T]`.

#### Pointer and View Types

There are **no first-class safe reference types**: `&T` / `&mut T` in a
type position are a **hard error** (E106 — see §"Ownership and Access").
Access is expressed with parameter conventions and access markers; the
non-owning forms are raw pointers and views:

- **`Ptr[T]`** — non-owning raw pointer to `T` (FFI/unsafe boundary).
- **`PtrMut[T]`** — non-owning mutable raw pointer to `T`.
- **`*T`** / **`*mut T`** — the raw-pointer syntax spellings of
  `Ptr[T]` / `PtrMut[T]`, used in `unsafe` blocks and FFI boundaries.
- **`StrView`** — non-owning UTF-8 string view (`{ptr, len}`); the owned
  form is `String`.
- **`FfiStr`** / **`FfiSlice[T]`** — C-compatible borrowed views
  (`{ptr, len}`) for FFI signatures.
- **`Slice[T]`** — the non-owning 16-byte `{ptr, len}` view into
  contiguous memory (the `[T]` slice type).

Views never own their backing storage: keep the owner alive for the
duration of the view and clone when storing.

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

# Default parameters
def greet(name: String = "World") -> String
  "Hello, " + name + "!"
end

# Pure function (no side effects)
# A `pure` function may not perform I/O, mutate external state, call
# non-pure functions, or trigger effects. The compiler verifies purity
# via effect tracking. Pure functions are safe to memoize and parallelize.
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

# unless — executes when condition is false (sugar for if !cond)
unless is_valid then
  panic("invalid state")
end

# until — loops while condition is false (sugar for while !cond)
until queue.is_empty() do
  process(queue.pop())
end
```

### Blocks and Closures

```tangerine
# Map with closure syntax
results = data.map(|x| x * 2)

# Closures
let double = |x: Int| -> Int x * 2
let add = |a, b| a + b

# Do blocks
let result = do
  let x = compute()
  x + 1
end
```

## Ownership and Access

Tangerine uses an **access/resource ownership model** for memory safety
without garbage collection. There are **no first-class safe reference
types**: `&T` / `&mut T` / `&&T` in a type position are a hard error
(E106, `parser.tg` `diag_safe_ref_not_first_class`), and the legacy
Rust-style parameter spellings are hard errors too (E100 — see the
rejection table below). Shared/borrowed access is expressed through
**parameter conventions** and **access markers** instead. The removed
`&T` / `&mut T` dialect is archived (non-normatively) in
[`../history/safe_reference_types_deprecated.md`](../history/safe_reference_types_deprecated.md).

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

### Access Conventions

Every parameter and receiver carries an explicit access convention. The
default (no prefix) is `let` — the argument is **observed** (read-only
access, no move); `inout`, `sink`, and `set` are declared with a keyword
prefix:

| Convention | Meaning |
|------------|---------|
| `let` (default) | **observe** — read-only access to the caller's value: no move, no consume, never finalized by the callee (Read) |
| `inout` | exclusive mutation — the callee may read and write the caller's place (Modify) |
| `sink` | **by-value move** — ownership transfers into the callee (Consume); the callee finalizes it if still live |
| `set` | initialize dead storage — the callee writes into an uninitialized place (Initialize) |

The distinction is critical: **`let` observes; `sink` moves.** A `let`
parameter sees the caller's value without taking it (reads of a String
parameter are Copy-bound accessors or views), so the caller keeps its
value. Only `sink` transfers ownership — the caller's binding is consumed.

```tangerine
def observe(x: Int) -> Int        # let (default): observe — no move
  x * 2
end

def scale(inout v: Vec[Float], k: Float) -> Unit   # exclusive mutation
  for i in 0..v.len() do
    v[i] = v[i] * k
  end
end

def consume(sink buf: String) -> Unit   # ownership transfers in
  write_log(buf)
end

def fill(set slot: Option[Int], value: Int) -> Unit  # write dead storage
  slot = Option::Some(value)
end
```

Mutating methods use the **trailing `inout` receiver convention**:

```tangerine
def set_name(self, name: String) -> Unit inout
  self.name = name
end
```

### Access Markers at Call Sites

At a call site, `&place` / `&mut place` selects the callee-side
convention and lowers to a MIR `Place` argument. The marker is **only
valid as a call argument** — the type checker rejects it anywhere else
(`access marker '&' is only valid as a call argument`). The mutability of
the marker is not tracked; the callee's parameter convention governs the
effect.

```tangerine
mut buffer = String::new()
append(&mut buffer, "hello")   # &mut place marker → inout/sink callee
println(&buffer)               # & place marker → let callee
```

### Move and Copy

```tangerine
# Ownership moves by assignment
let s1 = String::from("hello")
let s2 = s1   # moved

# `move` / `copy` unary prefixes are accepted as legacy no-ops
# (grammar §4.1); parameter-prefix `move`/`own` are REJECTED (E100)
# — write `sink` instead.
def take_ownership(sink s: String) -> Unit
  # s is consumed here
end
```

An example that intentionally demonstrates a rejection is annotated on
its first line with `compile_fail: <the expected diagnostic substring>`
and machine-checked by `scripts/check_doctests.sh`:

```tangerine
# compile_fail: legacy parameter spelling
def take_ownership_legacy(move s: String) -> Unit
  # s is consumed here
end
```

### Rejected Legacy Forms (E100 / E106)

| Written | Diagnostics | Use instead |
|---------|-------------|-------------|
| `&T` / `&mut T` / `&&T` in a type position (returns, fields, annotations, generic args) | **E106** | views (`StrView`, `Slice[T]`), `Ptr[T]` / `PtrMut[T]`, or a convention |
| `ref value` / `&value` pattern binders | **E106** | bind by value; Copy-bound accessors or explicit `.clone()` |
| `mut x:`, `&x:`, `&mut x:`, `move x:`, `own x:` parameter prefixes | **E100** | `inout x`, `sink x`, `set x`, or `x` (`let`) |
| `x: &T` / `x: &mut T` parameter type markers | **E100** | the convention prefix, e.g. `inout x: T` |
| `fn(&T)`, `fn(mut T)`, `fn(move T)` fn-type conventions | **E100** | `fn(inout T)` / `fn(sink T)` / `fn(set T)` / default `let` |
| `&self` / `&mut self` receivers | **E100** | `self` (`let`), `inout self`, or the trailing `inout` |

The one exception: `&T` / `Option[&T]` type positions inside an `extern`
declaration whose name carries the `__intrinsic_` prefix denote the
internal address/reference ABI (typed `RefInternal`) and parse only there
(`parser.tg` `parse_extern_fn` / `parse_extern_static`, scoped by
`is_intrinsic_extern_name`). The five record-visit extern signatures in
`std/collections.tg` are the kernel's only reference positions.

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
  
  def distance(self, other: Point) -> Float
    let dx = self.x - other.x
    let dy = self.y - other.y
    (dx * dx + dy * dy).sqrt()
  end
  
  def translate(inout self, dx: Float, dy: Float) -> Unit
    self.x = self.x + dx
    self.y = self.y + dy
  end
end

let p1 = Point::new(0.0, 0.0)
let p2 = Point::new(3.0, 4.0)
let d = p1.distance(p2)  # 5.0
```

Receivers carry the access conventions: `self` is `let` by default,
`inout self` (or the trailing `inout` receiver convention) mutates, and a
call site passes a place with the `&place` access marker where the
callee needs the caller's storage (`p1.translate(&p1)` is a marker use;
the receiver slot is filled from the call's receiver place).

## Traits

```tangerine
trait Display
  def display(self) -> String
end

trait Clone
  def clone(self) -> Self
end

impl Display for Point
  def display(self) -> String
    format("({}, {})", self.x, self.y)
  end
end

# Trait bounds
def print_all[T: Display](items: [T]) -> Unit
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

## Progressive Strictness (Mode System)

Tangerine features a **progressive strictness** model: projects start in
`Dev` mode and can escalate to stricter modes as the codebase matures
(`--mode strict|production|hardened`, or the `[project] mode` key in
Tangerine.toml). Each mode maps to a `ModeConfig` bit set
(`tg_compiler/mode.tg`).

> **Enforcement status.** `ModeConfig` carries **only** the behavior the
> pipeline implements. The 2026-08 reduction deleted the configuration
> bits that claimed semantics no pass implements (effects, budgets,
> coverage, CQS, doc/test gates, the unsafe bans, the review /
> memory-safety / dependency-audit policies, stubs, auto-escalation —
> `tg_compiler/mode.tg` carries `ModeConfig { mode, enforce_contracts,
> enforce_capabilities }` only). The deleted behaviors themselves are
> stated below as pending, not as features.

### ModeConfig bits — enforcing pass or pending

| ModeConfig bit | Set true in | Enforcing pass (file/function) | Status |
|----------------|-------------|---------------------------------|--------|
| `enforce_contracts` | all modes | MIR lowering `lower_contract` (mir.tg) emits `MirContractCheck`; codegen.tg emits a runtime trap on a false condition — **unconditionally, not gated by the flag** | enforced |
| `enforce_capabilities` | all modes | resource_check.tg capability machinery (`validate_capability_exit`, capability consumption tracking, `contains_capability` via types.tg `type_properties_of`) — **unconditional** | enforced |

The two enforced bits are unconditional: they do not consult their
flag, so `--no-contracts` / `--no-capabilities` (see the option table
below) do not disable them today.

Behaviors formerly claimed by deleted `ModeConfig` bits — each is pending,
no config bit claims it:

| Former bit (deleted) | Pending behavior |
|----------------------|------------------|
| `enforce_effects` | effect lowering + effect-log runtime — `MirEffectRecord` is never constructed from source; the `__tg_effect_record` runtime body is a trap stub (runtime.tg) |
| `enforce_budgets` | budget lowering + budget-table runtime — `MirBudgetConsume` is never constructed from source; the `__tg_budget_*` data symbols have no definitions (runtime.tg) and fail closed at link if emitted |
| `enforce_coverage` | a coverage gate in the pipeline — `coverage.tg` exists but is not invoked by any compile/check path |
| `gate_on_score` | a CQS gate in the pipeline — `run_cqs_analysis` (cqs.tg) has no caller in the driver or pipeline |
| `require_docs_for_pub` / `require_tests_for_pub` | pub-API doc/test checks — no checker rejects |
| `forbid_unsafe_no_reason` / `forbid_all_unsafe` | compile-path unsafe-reason / unsafe ban — the `unsafe_usage` lint (linter.tg) warns only under `tg lint` |
| `enforce_memory_safety` | per-mode bounds-check instrumentation — no pass adds extra checks per mode |
| `audit_dependencies` | a dependency-audit gate — `merge_imported_deps` validates imports but performs no security audit |
| `require_code_review` | a review-gate integration — no pass can enforce a process requirement |
| `allow_stubs` / `auto_escalate` | stub rejection in the pipeline / maturity escalation — the flags were never read; the `tg lint` stub rules are a separate subcommand |

```tangerine
# Set in Tangerine.toml:
#   [project]
#   mode = "Production"

# Four modes (least to most strict):
#   Dev        — relaxed
#   Strict     — contracts + capabilities enforced (as in every mode)
#   Production — same enforced set; other gates are pending, not bits
#   Hardened   — same enforced set; the former hardened bits are pending
```

See `tg_compiler/mode.tg` for the full `Mode` enum and `ModeConfig` struct.

### Compiler option flags — responsible pass or deprecation

The CLI accepts capability/contract/effects/budget/warning-policy flags.
Each flag below is wired to exactly one responsible pass — or is marked
deprecated when no pass consumes it.

| Flag | Field | Responsible pass or deprecation |
|------|-------|--------------------------------|
| `--strict` | `strict_resolution` | enforced — forced `true` on every compile path (`analyze_parsed`, types.tg `type_check_typed`); permissive resolution is editor-recovery only |
| `--no-contracts` | `enable_contracts` | **deprecated, inert** — no pass reads it; contract checks are unconditional (`lower_contract`, mir.tg) |
| `--no-capabilities` | `enable_capabilities` | **deprecated, inert** — no pass reads it; capability enforcement is unconditional (resource_check.tg) |
| `--no-effects` | `enable_effects` | **deprecated, inert** — no pass reads it; effects are not enforced at all (see the mode table) |
| `--no-budgets` | `enable_budgets` | **deprecated, inert** — no pass reads it; budgets are not enforced at all (see the mode table) |
| `-W` / `--warn-all` | `warn_all` | **deprecated, inert** — no pass reads it; `tg lint` uses its own `LintConfig` |
| `-Werror` | `deny_warnings` | **deprecated, inert** — no pass reads it; the linter's `--deny` rules are the warning-policy application point |
| `-g` | `debug_info` | **deprecated, inert** — no pass reads it |
| `--check` | `check_only` | **deprecated, inert** — `--check` is kept for CLI compatibility; `tg check` / `StopAfter::Semantic` is the real gate |
| `warn_unused` (default `true`) | — | **deprecated, inert** — no pass reads it |

The flags that do have a responsible pass are the pipeline controls
(`--mode`, `--target`, `-O0`…`-O3`, `--pgo-gen`, `--pgo-use`, `--emit-obj`,
`--emit-mir`, `--print-ast`, `--print-tokens`, `--dump-*`, `--json`,
`--no-color`, `-o`, `-c`, `-v`, `-q`).

## Agentic Features

### Design by Contract

```tangerine
# Preconditions (pre)
# Postconditions (post)
def sqrt(x: Float) -> Float
  pre x >= 0.0, "sqrt requires non-negative input"
  post abs(result * result - x) <= 1e-9, "result squared is within floating-point tolerance"
  
  # implementation
end

# Invariants — contract clauses live on functions (the parser has no
# struct-level invariant clause; declare a checking method instead)
struct BankAccount
  balance: Float

  def check_invariant(self) -> Unit
    invariant self.balance >= 0.0, "balance must be non-negative"
  end
end
```

### Guard Keyword

The `guard` keyword is syntactic sugar for precondition checks that early-return
on failure. It desugars to an `if`/`return` or `if`/`panic`, and can optionally
narrow the type of a variable for the remainder of the function.

```tangerine
# Guard with early return
def process(input: Option[String]) -> Result[Int, Error]
  guard let value = input else return Result::Err("missing input")

  # `value` is now `String` (narrowed from Option[String])
  parse_int(value)
end

# Guard with panic
def require_positive(x: Int) -> Int
  guard x > 0 else panic("x must be positive")
  x * 2
end

# Guard with break/next in loops
def find_first_valid(items: Vec[Option[Int]]) -> Option[Int]
  for item in items do
    guard let val = item else next
    if val > 0 then
      return Option::Some(val)
    end
  end
  Option::None
end
```

Guard else-actions must **diverge** — they must `return`, `panic`, `break`, or
`next`. The compiler rejects guards whose else branch falls through.

See `std/contracts.tg` for the `GuardClause`, `GuardElseAction` types, and
`desugar_guard()` function.

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

### Security Profiles

A **security profile** restricts which capabilities are allowed in a project.
Set via `profile = "backend"` in `Tangerine.toml`.

```tangerine
# Built-in profiles:
#   Backend  — Net, Fs, DB, Env, Clock, Random allowed; Unsafe denied
#   Cli      — Fs, Env, Proc allowed; Net denied
#   Ui       — Clock, Random allowed; Fs, Net, DB denied
#   Library  — only Pure + Custom allowed; all system caps denied

# Custom profile
# [project]
# profile = "custom"
# [profile.custom]
# allowed = ["Net", "Fs"]
# denied  = ["Unsafe", "FFI"]
# audit_required = ["DB"]
```

The compiler does **not** yet run `validate_against_profile()`: the
function is declared in `std/capabilities.tg` (API-only, outside the
bootstrap closure) and no compile/CQS path calls it. The `SecurityProfile`
enum and `profile_check()` are declared surfaces, not enforced behavior
(the CQS gate itself has no pipeline caller — see the ModeConfig table in
§"Progressive Strictness").

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

# Handle effects (handle is a keyword; the expression is legal in
# statement position inside a function body)
def run_handled() -> Unit
  handle process_with_logging("input")
  with Logger
    log(level, msg) => println("[{}] {}", level, msg)
  end
end
```

### Budgets

Budget constraints are declared as function clauses using `budget` entries.
**Enforcement is not implemented:** `MirBudgetConsume` is never constructed
from source, the `__tg_budget_*` data symbols have no definitions
(runtime.tg), and the mode table's `enforce_budgets` bit (deleted in the
2026-08 reduction — the budget lowering + budget-table runtime) is
pending (see the ModeConfig table in §"Progressive Strictness"). The
declared surface:

```tangerine
# Budget clause (bounds are string literals; enforcement is NOT
# implemented — see the note above)
def expensive_operation() -> Result[Data, Error]
  budget time_ms: "5000", alloc_bytes: "104857600"
  
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

## Secure Types

Tangerine provides **sealed wrapper types** that prevent injection attacks at the
type level. These types cannot be constructed from raw strings — only through
validated constructors that enforce security invariants.

```tangerine
use std::secure_types::{sql_query, SqlParam, html_escape, url_parse, path_parse}

# SQL — parameterized queries only, no string interpolation
let query = sql_query("SELECT * FROM users WHERE id = $1", [SqlParam::Int(42)])?
# query is SqlQuery — cannot be constructed from a raw string

# HTML — auto-escapes, XSS-safe
let safe = html_escape("<script>alert('xss')</script>")
# safe.value == "&lt;script&gt;alert(&#39;xss&#39;)&lt;/script&gt;"

# URLs — blocks javascript: and vbscript: schemes
let url = url_parse("https://example.com/api")?
# url_parse("javascript:alert(1)") → Err(...)

# File paths — rejects traversal attacks
let path = path_parse("data/reports/q1.csv")?
# path_parse("../../etc/passwd") → Err(...)
```

See `std/secure_types.tg` for `SqlQuery`, `HtmlSafe`, `Url`, `SafePath`, and
`HeaderValue`.

## Taint Tracking

Data entering the program through **FFI boundaries** is automatically wrapped in
`Tainted[T]`. Tainted values cannot be used directly — they must pass through a
**validator** to produce a clean value.

```tangerine
use std::taint::{Tainted, taint, validate, MaxLengthValidator}

# FFI data is auto-tainted by the compiler
extern "C" def read_input() -> Tainted[String]

# Cannot use tainted data directly:
# let name = read_input()   # ERROR: expected String, got Tainted[String]

# Must validate first:
def read_user_input() -> Result[String, ValidationError]
  let raw = read_input()
  let validator = MaxLengthValidator { max_len: 255 }
  validate(raw, validator)  # Ok(String) or Err(ValidationError)
end
```

### Taint Labels

Each tainted value carries one or more `TaintLabel` values tracking its origin:
`FfiInput`, `FfiCallback`, `NetworkRead`, `FileRead`, `EnvVar`, `UserInput`,
`Deserialized`, `Custom(String)`.

### Built-in Validators

| Validator | Purpose |
|-----------|---------|
| `MaxLengthValidator` | String length ≤ max_len |
| `IntRangeValidator` | Integer in [min, max] |
| `PatternValidator` | String matches regex |
| `NonEmptyValidator` | Non-empty string |

### Custom Validators

```tangerine
use std::taint::{Validator, Tainted, ValidationError}

struct EmailValidator end

impl Validator[String, String] for EmailValidator
  def validate(tainted: Tainted[String]) -> Result[String, ValidationError]
    let val = tainted.value
    if val.contains("@") && val.contains(".") then
      Result::Ok(val.clone())
    else
      Result::Err(ValidationError {
        message: "invalid email",
        labels: tainted.labels.clone(),
        source_span: tainted.source_span,
      })
    end
  end
end
```

See `std/taint.tg` for the full API and `std/ffi.tg` for FFI boundary
integration (`FfiBoundary` trait, `__ffi_auto_taint()`).

## Deterministic Replay

The replay system captures non-deterministic events during execution and allows
exact reproduction of program behavior.

```tangerine
use std::replay::{ReplayRecorder, recorder_new, recorder_record_schedule,
                  trace_serialize, trace_save, player_load}

# Record
mut recorder = recorder_new()
recorder_record_schedule(&mut recorder, 0)
recorder_record_random(&mut recorder, [0x42, 0x00])
recorder_record_time(&mut recorder, 1700000000_000_000_000)

let trace = recorder.to_trace()
trace_save(&trace, "session.replay")?

# Replay
let player = player_load("session.replay")?
let event = player.next()?
```

Events captured: thread scheduling, RNG seeds, wall-clock queries, I/O
reads/writes, network receives, environment variable reads, filesystem stats,
channel receives, allocation addresses.

See `std/replay.tg` for `ReplayEvent` (11 variants), `ReplayRecorder`,
`ReplayPlayer`, and `DeterministicScheduler`.

## Semantic Refactoring

Tangerine provides compiler-guaranteed refactoring primitives. The compiler
either applies the refactoring correctly or refuses — it never silently breaks
code.

```bash
# Rename a symbol across the entire project
tg refactor rename old_name new_name

# Extract a code block into a new function
tg refactor extract src/lib.tg:10:1-25:1 new_function_name

# Inline a single-assignment variable
tg refactor inline src/lib.tg:15:5 variable_name
```

Supported refactoring kinds:
- **Rename** — collision detection, extern symbol checks, pub API guards in Production mode
- **Extract Function** — control flow integrity, live-in/live-out analysis
- **Extract Variable** — side-effect-free expression extraction
- **Inline Variable** — single-assignment verification, side-effect checks
- **Inline Function** — call-site substitution
- **Move Item** — cross-module relocation

See `tg_compiler/refactor.tg` for `RefactorKind`, `RefactorRequest`,
`RefactorResult`, and `TextEdit`.

## Supply Chain Security

Tangerine includes built-in supply chain security primitives for package
signing, lockfile integrity, reproducible builds, and dependency trust.

```tangerine
use std::supply_chain::{semver_parse, lockfile_verify, check_policy,
                        verify_reproducible, compute_trust_score}

# SemVer parsing
let ver = semver_parse("1.2.3-beta.1")?

# Lockfile integrity verification
let lockfile = lockfile_parse(contents)?
lockfile_verify(&lockfile)?

# Reproducible build verification (fields are illustrative)
let manifest = BuildManifest {
  build_id: "abc...",
  compiler_version: "0.1.0",
}
verify_reproducible(&manifest, "expected-output-hash")

# Trust score computation
let graph = build_trust_graph(packages)?
let score = compute_trust_score(&graph, target_package)?
```

See `std/supply_chain.tg` for `PackageId`, `SemVer`, `PackageSignature`,
`Lockfile`, `TrustGraph`, and `SupplyChainPolicy`.

## Completion & Quality System (CQS)

The CQS is a **static analysis** pass that assigns each symbol a completeness
score in [0, 100] based on evidence signals. Scores are deterministic and
reproducible.

```bash
# Run quality analysis
tg quality src/

# With JSON output (conforms to cqs_quality.schema.json)
tg quality src/ --json > report.json

# Bless the current state as baseline
tg quality --bless

# Merge coverage artifacts
tg cov merge target/cqs/coverage/*.tgcov -o merged.tgcov
```

### Signal Categories

| Category | Signals | What they detect |
|----------|---------|----|
| Control Flow (CF) | CF-1..CF-4 | Unreachable branches, non-exhaustive matches, panic exits, constant-return dominance |
| Data Flow (DF) | DF-1..DF-4 | Unused variables, uninitialized reads, dead stores, shadowing hiding live variables |
| Error Handling (EH) | EH-1..EH-3 | Ignored results, bare unwrap, panic in library code |
| Coverage (CV) | CV-1..CV-2 | Untested public symbols, low branch coverage |
| Capability (CP) | CP-1..CP-3 | Undeclared capabilities, capability drift, unused capabilities |
| Future-gating (FT) | FT-1..FT-2 | Stub functions (todo/unimplemented), feature-gated code |

### Surface Classes

Symbols are classified by their exposure surface, which determines penalty
weights:

| Surface | Description | Weight |
|---------|-------------|--------|
| `PublicStable` | Public API in stable modules | Highest |
| `PublicExperimental` | Public but feature-gated | High |
| `InternalHotPath` | Private but performance-critical | Medium |
| `InternalGlue` | Private boilerplate/glue code | Low |
| `TestOnly` | Test functions/helpers | Low |
| `PlatformShim` | OS/arch-specific bindings | Low |

### Enforcement

In `Production` and `Hardened` modes, the CQS gates CI:

| Mode | Score < threshold | Missing coverage | Capability drift |
|------|------------------|------------------|-----------------|
| Dev | warn | — | — |
| Strict | warn | warn | — |
| Production | **fail** | **fail** | **fail** |
| Hardened | **fail** | **fail** | **fail** |

See `tg_compiler/cqs.tg` for the full signal detection engine, and
`docs/cqs_quality.schema.json` for the JSON output schema.

## Context Widening System (CWS)

The CWS generates optimally-selected context packs (`ctxpack.json`) for AI
agents. It builds a **symbol dependency graph**, runs backward/forward SDG
slicing from seed symbols, and uses a **greedy submodular knapsack** algorithm to
maximize information within a CU budget.

```bash
# Generate context pack for a compile error
tg ctxpack --error src/lib.tg:42:5 -o ctxpack.json

# Generate context pack for a failing test
tg ctxpack --test test_login -o ctxpack.json

# Generate context pack for CQS gate failure
tg ctxpack --cqs-gate -o ctxpack.json
```

Key parameters (defaults in `docs/cws_defaults.toml`):

| Profile | Budget | K (candidates) | α (balance) |
|---------|--------|----------------|-------------|
| Backend | 160K CU | 2000 | 0.55 |
| CLI | 120K CU | 1500 | 0.70 |
| UI | 200K CU | 3000 | 0.45 |
| Library | 80K CU | 1000 | 0.80 |

1 CU = 4 bytes of UTF-8 text.

See `tg_compiler/symbol_graph.tg` for the graph engine,
`tg_compiler/context_pack.tg` for pack generation, and
`docs/ctxpack.schema.json` for the output schema.

## Async/Await

```tangerine
# Async function
async def fetch_data(url: String) -> Result[String, Error]
  let response = (await http_get(url))?
  let body = (await response.text())?
  Result::Ok(body)
end

# Running async code
async def main() -> Unit
  let data = await fetch_data("https://example.com")
  match data
  when Result::Ok(s) then println(s)
  when Result::Err(e) then println("Error: {}", e)
  end
end

# Concurrent execution
async def fetch_all(urls: [String]) -> Vec[String]
  let futures = urls.iter().map(|url| fetch_data(url))
  await join_all(futures)
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

pub def dot(a: Vec2, b: Vec2) -> Float
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

# Absolute path from current crate root
use crate::math::vector::Vec2 as LocalVec2

# Glob import
use std::collections::*

# Aliased import
use very::long::path::Name as Short

def main() -> Unit
  let v1 = Vec2 { x: 1.0, y: 0.0 }
  let v2 = Vec2 { x: 0.0, y: 1.0 }
  println("Dot product: {}", dot(v1, v2))
end
```

`use crate::...` paths are absolute within the current package/crate, while
`use std::...` refers to the standard library namespace.

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
unsafe def raw_copy(src: PtrMut[u8], dst: PtrMut[u8], len: Int) -> Unit
  # ...
end
```

## Foreign Function Interface (FFI)

Tangerine provides comprehensive FFI support for C, Rust, and Ruby interoperability.

### C Interop

```tangerine
# Export function to C (an exported function is an ordinary def; an
# `extern` declaration never carries a body)
@export("my_add")
def add(a: i32, b: i32) -> i32
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

# Compile-time computation (a comptime block is an expression — it goes
# inside a function body, not at item level)
def build_table() -> Unit
  comptime
    let table = build_lookup_table()
  end
end

# Conditional compilation / edition pinning (the edition is a string)
edition "2026"
```

## Generics

```tangerine
# Generic struct
struct Box[T]
  value: T
end

# Generic function
def swap[T](a: inout T, b: inout T) -> Unit
  let tmp = a
  a = b
  b = tmp
end

# Multiple type parameters with bounds
struct HashMap[K: Hash + Eq, V]
  buckets: Vec[Vec[(K, V)]]
end

# Associated types in traits
trait Iterator
  type Item
  def next(inout self) -> Option[Self::Item]
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

# Pattern binders are BY VALUE — `ref value` / `&value` binders are a
# hard error (E106): a shared read is a Copy-bound accessor or an
# explicit clone.

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

def demo() -> Unit
  let config = Config { host: "localhost".to_string(), port: 8080 }
  let json_str = Json::stringify(&config)
  let parsed: Config = Json::parse(&json_str)?
  let toml_str = Toml::stringify(&config)
end
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

app.get("/", |ctx: Context| ctx.text("Hello, World!"))
app.get("/users/:id", do |ctx: Context|
  let id = ctx.param("id")?
  ctx.json_response(get_user(id)?)
end)
app.post("/users", do |ctx: Context|
  let user: User = ctx.json()?
  ctx.status(StatusCode::Created).json_response(create_user(user)?)
end)

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

# Hashing (sha256 takes a byte slice)
let msg: [u8] = [0x6D, 0x65, 0x73, 0x73, 0x61, 0x67, 0x65]  # "message"
let hash = sha256(msg)
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
if matches.get_flag("verbose") then println("verbose") end

# Terminal output
terminal::print_colored("Success!", Color::Green)
let pb = ProgressBar::new(100)
for i in 0..100 do pb.set(i) end
pb.finish()
```

### Logging & Tracing (`std/log`)

```tangerine
use std::log::{Logger, Level, info, warn, error, Span, Metrics}

Logger::init(Level::Info)

info("Server started on port {}", port)
warn("Connection pool low: {} available", count)
error("Request failed: {}", err)

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

# Regex (the dialect has no raw-string literal — escape the pattern)
let re = Regex::new("\\d{3}-\\d{4}")?
if re.is_match("555-1234") then println("matched") end
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
for entry in reader.entries()? do println(entry.name()) end
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

# Async (await is a prefix operator)
async def fetch_all(urls: [String]) -> Vec[Response]
  let tasks = urls.iter().map(|u| spawn(fetch(u)))
  await join_all(tasks)
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
for line in reader.lines() do println(line) end

for entry in walk_dir("src")? do
  if entry.is_file() && entry.extension() == "tg" then println(entry.path()) end
end
```

### Testing (`std/test`, `std/bench`)

```tangerine
use std::test::{test, assert_eq, assert_throws, snapshot}
use std::bench::Benchmark

@test
def test_addition()
  assert_eq(2 + 2, 4)
end

@test
def test_snapshot()
  let output = render_template(data)
  snapshot::assert_eq("template_output", &output)
end

@bench
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
use std::contracts::{make_guard, GuardElseAction, check_invariant}

def sqrt(x: Float) -> Float
  pre x >= 0.0, "sqrt requires non-negative input"
  post result >= 0.0, "result must be non-negative"
  # implementation
end

# Guard keyword (desugars to early return)
def process(input: Option[String]) -> Result[Int, Error]
  guard let value = input else return Result::Err("missing")
  parse_int(value)
end

cap FileSystem implies FileRead, FileWrite end
cap Network implies NetworkRead, NetworkWrite end

def download(url: String) -> Result[Vec[u8], Error]
  requires Network, FileSystem
  # implementation
end

# Security profiles restrict capabilities per project
# profile = "backend"  →  Net, Fs, DB allowed; Unsafe denied
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
loop
  timer.begin_frame()
  # ... render ...
  let stats = timer.end_frame()
  println("FPS: {:.1}", stats.fps)
end

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
# `effect`, `handle` and `budget` are KEYWORDS (grammar §2.11 / §4.6);
# the std analysis surfaces carry different names:
use std::effects::{Effect, EffectKind}
use std::budget::{Budget, time_budget}

effect Logger
  log(level: Level, msg: String) -> Unit
end

def process_with_log(data: String) -> String
  effect Logger
  Logger::log(Level::Info, "Processing")
  transform(data)
end

def run_handled() -> Unit
  handle process_with_log(input)
  with Logger
    log(level, msg) => println("[{}] {}", level, msg)
  end
end

def expensive_op() -> Result[Data, Error]
  budget time: "5s", memory: "100MB"
  # implementation
end
```

### Memory Allocation (`std/alloc`)

```tangerine
use std::alloc::{Allocator, Layout, SystemAllocator, ArenaAllocator,
                 system_allocator, arena_new, arena_reset}

# System allocator (libc malloc/free)
let alloc = system_allocator()

# Arena allocator (bump allocation, bulk deallocation)
mut arena = arena_new(4096)
# ... allocate from arena ...
arena_reset(&mut arena)
```

### Backtrace (`std/backtrace`)

```tangerine
use std::backtrace::{capture, capture_force, Backtrace}

# Respects TANGERINE_BACKTRACE env var
let bt = capture()

# Force capture regardless of env
let bt = capture_force()
for frame in bt.frames do
  println("  {} at {}:{}", frame.symbol_name, frame.file, frame.line)
end
```

### Formatting (`std/fmt`)

```tangerine
use std::fmt::{format, print, puts, Display, Debug}

# {} positional, {0} indexed, {{ / }} literal braces
let msg = format("Hello, {}! You are #{}", ["Alice", "42"])
print(msg)
puts("with newline")
```

### Environment (`std/env`)

```tangerine
use std::env::{get_env, set_env, current_dir}

let home = get_env("HOME")
set_env("HOME", home)?
let cwd = current_dir()?
```

### Secure Types (`std/secure_types`)

```tangerine
use std::secure_types::{sql_query, SqlParam, html_escape, url_parse, path_parse}

let query = sql_query("SELECT * FROM users WHERE id = $1", [SqlParam::Int(1)])?
let safe_html = html_escape("<b>hello</b>")
let url = url_parse("https://example.com")?
let path = path_parse("data/report.csv")?
```

### Taint Tracking (`std/taint`)

```tangerine
use std::taint::{Tainted, taint, validate, MaxLengthValidator}

let raw: Tainted[String] = taint("user input", TaintLabel::UserInput)
let clean = validate(raw, MaxLengthValidator { max_len: 255 })?
```

### Deterministic Replay (`std/replay`)

```tangerine
use std::replay::{recorder_new, trace_save, player_load}

mut rec = recorder_new()
recorder_record_schedule(&mut rec, 0)
trace_save(&rec.to_trace(), "trace.replay")?

let player = player_load("trace.replay")?
```

### Semantic Diff (`std/semantic_diff`)

```tangerine
use std::semantic_diff::{extract_entities, compute_diff}

let old_entities = extract_entities(old_source)
let new_entities = extract_entities(new_source)
let diff = compute_diff(&old_entities, &new_entities)
# diff.changes: Vec[AnnotatedChange] with severity (Breaking/Compatible/Internal/Cosmetic)
```

### Supply Chain (`std/supply_chain`)

```tangerine
use std::supply_chain::{semver_parse, lockfile_verify, check_policy}

let ver = semver_parse("1.0.0")?
lockfile_verify(&lockfile)?
let violations = check_policy(&policy, &lockfile)
```

### Test Generation (`std/test_gen`)

```tangerine
use std::test_gen::{extract_function_info, generate_tests_from_info}

let info = extract_function_info(source, "my_function")?
let tests = generate_tests_from_info(info)
# Generates boundary value, contract-based, and fuzz test cases
```

### Collections (`std/collections`)

```tangerine
use std::collections::{Array, Map, Set, Iterator}

mut arr = array_new[Int]()
array_push(&mut arr, 42)

mut map = map_new[String, Int]()
map_insert(&mut map, "key", 1)

let val = map_get(&map, "key")  # Option[Int] — Copy-gated accessor
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

# Warning controls (DEPRECATED — inert: no pass reads these flags; use
# `tg lint --deny/--warn/--allow <LINT>` for the warning policy)
tg main.tg -W       # Enable warnings — accepted, no effect
tg main.tg -Werror  # Treat warnings as errors — accepted, no effect

# Disable agentic features selectively (DEPRECATED — inert: no pass reads
# these flags; contract/capability enforcement is unconditional)
tg main.tg --no-contracts
tg main.tg --no-capabilities
tg main.tg --no-effects
tg main.tg --no-budgets

# Set mode explicitly (overrides Tangerine.toml; the mode config carries
# only the enforced bits — see the ModeConfig table in §"Progressive
# Strictness")
tg main.tg --mode Production

# Quality analysis (CQS)
tg quality src/
tg quality src/ --json
tg quality --bless

# Coverage merge
tg cov merge target/cqs/coverage/*.tgcov -o merged.tgcov

# Context pack generation (CWS)
tg ctxpack --error src/lib.tg:42:5 -o ctxpack.json
tg ctxpack --test test_login -o ctxpack.json

# Semantic refactoring
tg refactor rename old_name new_name
tg refactor extract src/lib.tg:10:1-25:1 func_name
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

- [Feature Registry](feature_registry.md) - **Single source of truth for feature status**
- [Standard Library Reference](stdlib_reference.md) - **Comprehensive API documentation**
- [Grammar Reference](grammar.md) - Formal grammar specification
- [Style Guide](style_guide.md) - Code style conventions
- [Interoperability Guide](interop.md) - C/Rust/Ruby FFI
- [FFI Cheat Sheet](ffi_cheatsheet.md) - Quick FFI reference
- [Unicode Policy](unicode_policy.md) - Unicode handling
- [Versioning Policy](versioning.md) - Version numbering
- [RFC Process](rfc_process.md) - How to propose changes
- [Registry Policy](registry_policy.md) - Package registry rules
- [Safe Reference Types — deprecated syntax](../history/safe_reference_types_deprecated.md) - NON-NORMATIVE archive of the removed `&T` / `&mut T` dialect
