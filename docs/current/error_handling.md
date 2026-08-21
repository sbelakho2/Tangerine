# Tangerine Error Handling Guide

**Version:** 0.1.0  
**Last Updated:** March 2026

Comprehensive guide to error handling patterns, types, and best practices in Tangerine.

---

## Table of Contents

1. [Philosophy](#philosophy)
2. [Result Type](#result-type)
3. [Option Type](#option-type)
4. [The `?` Operator](#the--operator)
5. [Error Types](#error-types)
6. [Error Context and Chaining](#error-context-and-chaining)
7. [Error Codes and Categories](#error-codes-and-categories)
8. [Pattern Matching Errors](#pattern-matching-errors)
9. [Custom Error Types](#custom-error-types)
10. [Panic and Unrecoverable Errors](#panic-and-unrecoverable-errors)
11. [Contracts and Preconditions](#contracts-and-preconditions)
12. [Best Practices](#best-practices)

---

## Philosophy

Tangerine follows these principles for error handling:

- **Errors are values** — no exceptions, no hidden control flow
- **Explicit propagation** — callers decide how to handle errors
- **Rich context** — errors carry source location, context chain, and error codes
- **Type safety** — the compiler ensures all error paths are handled

---

## Result Type

The primary error handling mechanism:

```tangerine
enum Result[T, E]
  Ok(T)
  Err(E)
end
```

### Basic Usage

```tangerine
def parse_int(s: &str) -> Result[Int, String]
  # ... parsing logic ...
  if valid then
    Result::Ok(value)
  else
    Result::Err("invalid integer: ".to_string() + s)
  end
end

# Using the result
match parse_int("42")
when Result::Ok(n) then println("got: " + n.to_string())
when Result::Err(e) then println("error: " + e)
end
```

### Combinators

```tangerine
let result = parse_int("42")
  .map(|n| n * 2)                    # Transform Ok value
  .map_err(|e| MyError::Parse(e))    # Transform Err value
  .unwrap_or(0)                      # Default on error
  
# Chaining fallible operations
let result = read_file("config.toml")
  .and_then(|content| parse_config(&content))
  .and_then(|config| validate_config(&config))
```

---

## Option Type

For values that may or may not exist (not an error condition):

```tangerine
enum Option[T]
  Some(T)
  None
end
```

### Converting Between Option and Result

```tangerine
let opt: Option[Int] = some_lookup()

# Option -> Result
let result: Result[Int, String] = opt.ok_or("not found".to_string())
let result: Result[Int, String] = opt.ok_or_else(|| format_error())

# Result -> Option
let opt: Option[Int] = parse_int("42").ok()
```

---

## The `?` Operator

Propagate errors concisely:

```tangerine
def load_config(path: &str) -> Result[Config, AppError]
  let content = read_file(path)?          # Returns early if Err
  let parsed = parse_toml(&content)?      # Returns early if Err
  let config = Config::from_value(parsed)? 
  Result::Ok(config)
end
```

The `?` operator:
- On `Result::Ok(v)`, unwraps to `v`
- On `Result::Err(e)`, converts `e` via `From` trait and returns `Err` early
- Works on `Option` too: `None` returns early

---

## Error Types

### Standard Error Traits

```tangerine
trait Error: Display + Debug
  ## Short description of the error
  def description(self: &Self) -> &str

  ## The underlying cause, if any
  def source(self: &Self) -> Option[&dyn Error] = Option::None
end
```

### Built-in Error Kinds (`std/core`)

Tangerine provides `ErrorKind` for categorizing errors with stable numeric codes:

| Error Kind | Code | Description |
|-----------|------|-------------|
| `NotFound` | 1001 | Resource not found |
| `PermissionDenied` | 1002 | Insufficient permissions |
| `AlreadyExists` | 1003 | Resource already exists |
| `InvalidInput` | 1004 | Invalid argument or input |
| `Timeout` | 1005 | Operation timed out |
| `ConnectionRefused` | 1006 | Connection refused |
| `ConnectionReset` | 1007 | Connection reset |
| `BrokenPipe` | 1008 | Pipe closed unexpectedly |
| `OutOfMemory` | 1009 | Memory allocation failed |
| `Interrupted` | 1010 | Operation interrupted |
| `Unsupported` | 1011 | Operation not supported |
| `InvalidData` | 1012 | Data format error |
| `Other` | 1099 | Other/uncategorized |

---

## Error Context and Chaining

Add context to errors as they propagate up the call stack:

### `.context()` Method

```tangerine
def open_database(url: &str) -> Result[Db, ContextError]
  let conn = connect(url)
    .context("failed to connect to database")?
  
  let db = conn.select_db("myapp")
    .context("failed to select database 'myapp'")?
  
  Result::Ok(db)
end
```

### `.with_context()` for Lazy Messages

```tangerine
let file = read_file(path)
  .with_context(|| "failed to read config file: ".to_string() + path)?
```

### Error Chain

`ContextError` maintains the full chain:

```tangerine
match open_database("postgres://localhost/myapp")
when Result::Err(e) then
  println("Error: " + e.to_string())
  # "failed to select database 'myapp'"
  
  if let Option::Some(source) = e.source() then
    println("Caused by: " + source.to_string())
    # "failed to connect to database"
    
    if let Option::Some(root) = source.source() then
      println("Root cause: " + root.to_string())
      # "connection refused: port 5432"
    end
  end
end
```

### `map_err` for Error Conversion

```tangerine
def load_user(id: Int) -> Result[User, AppError]
  let row = db.query("SELECT * FROM users WHERE id = ?", &[id])
    .map_err(|e| AppError::Database(e))?
  
  let user = User::from_row(&row)
    .map_err(|e| AppError::Deserialization(e))?
  
  Result::Ok(user)
end
```

---

## Error Codes and Categories

### Defining Error Codes

```tangerine
enum AppErrorCode: UInt
  ConfigMissing = 2001
  ConfigInvalid = 2002
  AuthFailed = 2003
  RateLimited = 2004
end
```

### Matching on Error Kinds

```tangerine
match result
when Result::Err(e) if e.kind() == ErrorKind::NotFound then
  # Handle missing resource
  create_default()
when Result::Err(e) if e.kind() == ErrorKind::PermissionDenied then
  # Request elevated permissions
  request_access()
when Result::Err(e) then
  # Unknown error — propagate
  return Result::Err(e)
when Result::Ok(val) then val
end
```

---

## Pattern Matching Errors

Tangerine's `match` expression provides exhaustive error handling:

```tangerine
match parse_and_validate(input)
when Result::Ok(data) then
  process(data)
when Result::Err(ParseError::InvalidSyntax(line, col)) then
  println("Syntax error at " + line.to_string() + ":" + col.to_string())
when Result::Err(ParseError::UnexpectedEof) then
  println("Unexpected end of input")
when Result::Err(ParseError::Validation(errors)) then
  for e in errors do
    println("  - " + e)
  end
end
```

---

## Custom Error Types

### Enum-Based Errors

```tangerine
enum HttpClientError
  ConnectionFailed(String)
  Timeout(Duration)
  StatusError(UInt, String)
  BodyTooLarge(UInt)
  TlsError(String)
end

impl Display for HttpClientError
  def to_string(self: &HttpClientError) -> String
    match self
    when HttpClientError::ConnectionFailed(host) then
      "connection failed: " + host
    when HttpClientError::Timeout(d) then
      "request timed out after " + d.as_secs().to_string() + "s"
    when HttpClientError::StatusError(code, msg) then
      "HTTP " + code.to_string() + ": " + msg
    when HttpClientError::BodyTooLarge(size) then
      "response body too large: " + size.to_string() + " bytes"
    when HttpClientError::TlsError(msg) then
      "TLS error: " + msg
    end
  end
end

impl Error for HttpClientError
  def description(self: &HttpClientError) -> &str = "HTTP client error"
end
```

### From Conversions for `?` Operator

```tangerine
impl From[IoError] for AppError
  def from(e: IoError) -> AppError
    AppError::Io(e)
  end
end

impl From[DbError] for AppError
  def from(e: DbError) -> AppError
    AppError::Database(e)
  end
end

# Now ? automatically converts:
def load(path: &str) -> Result[Data, AppError]
  let content = read_file(path)?         # IoError -> AppError
  let rows = db.query(&content)?         # DbError -> AppError
  Result::Ok(Data::from(rows))
end
```

---

## Panic and Unrecoverable Errors

> **STATE A — panic=abort is the ONLY stable panic strategy.** A panic
> runs the panic hook and then terminates the process immediately
> (`__intrinsic_abort`). There is no unwinding, no catch, no resumption on
> the stable path. The compiler REJECTS any request for a stable
> panic=unwind (`--panic-strategy unwind` is an option-boundary error —
> see driver.tg's parse_args). The `catch_unwind`/`catch_panic`/
> `resume_unwind`/`try_invoke` APIs in std/core.tg are EXPERIMENTAL
> (unstable) surfaces kept for API compatibility; they are not part of the
> stable std contract and make no cleanup claims.
>
> **Resource safety with abort:** because the process ends at the panic
> site, there is no partial destruction to reason about — the cleanup
> contract is "the process terminates; whatever the OS reclaims is
> reclaimed by the OS". NO partial-destruction claim is made: the abort
> path does NOT run resource finalizers, does NOT run defers, and does NOT
> unwind any stack. Code that must observe cleanup must not rely on panic
> paths (use `Result` for recoverable failure).

For truly unrecoverable situations:

```tangerine
# Explicit panic
panic("invariant violated: negative count")

# Unwrap (panics on Err/None)
let value = result.unwrap()          # panics if Err
let value = option.unwrap()          # panics if None

# Expect (panics with message)
let config = load_config().expect("config file must exist")

# Debug assertions (only in Dev/Strict modes)
debug_assert(count >= 0, "count must be non-negative")
```

A panicking program prints the hook's diagnostic ("thread panicked at
'<message>'") to stderr and terminates with the abort trap — the process
exit is non-zero and the stack is not unwound. The panic hook
(`set_panic_hook`/`take_panic_hook`) runs BEFORE the abort and is the only
user code the abort path executes.

### Panic vs. Errors Decision Guide

| Use `Result` when... | Use `panic!` when... |
|----------------------|---------------------|
| Failure is expected (file not found, network error) | Invariant is violated (bug in code) |
| Caller can meaningfully recover | Continuing would cause undefined behavior |
| External input may be invalid | Internal logic error |
| Error is part of API contract | Index out of bounds in debug mode |
| Cleanup must run before the program ends | The process should end NOW (abort-only) |

---

## Contracts and Preconditions

Tangerine supports contract-based error prevention via `std/contracts`:

```tangerine
@require(amount > 0, "amount must be positive")
@require(balance >= amount, "insufficient funds")
@ensure(|result| result.balance == old(self.balance) - amount)
def withdraw(self: &mut Account, amount: Float) -> Result[Account, BankError]
  # Contract violations become compile-time errors in Strict mode
  # and runtime panics in Dev mode
  self.balance = self.balance - amount
  Result::Ok(self.clone())
end
```

---

## Best Practices

### DO

- Return `Result` for all fallible operations
- Add `.context()` when propagating errors across abstraction layers
- Define domain-specific error enums for library crates
- Implement `From` conversions for seamless `?` usage
- Use `ErrorKind` for programmatic error matching
- Provide both `Display` (user-facing) and `Debug` (developer) output

### DON'T

- Don't use `unwrap()` in library code — use `?` instead
- Don't use `panic!` for expected failure modes
- Don't discard errors silently — at minimum, log them
- Don't create "god" error types that cover everything — keep them focused
- Don't expose internal error types in public APIs — wrap them

### Error Handling Pattern Summary

```
                ┌─────────────────────┐
                │   Operation fails   │
                └─────────┬───────────┘
                          │
              ┌───────────┴───────────┐
              │   Expected failure?   │
              └───────────┬───────────┘
                    ┌─────┴─────┐
                   Yes          No
                    │           │
               Return       panic!()
             Result::Err      │
                    │     (unrecoverable)
                    │
          ┌─────────┴─────────┐
          │  Can caller handle │
          │     this error?   │
          └─────────┬─────────┘
                ┌───┴───┐
               Yes      No
                │       │
             match   .context()
            on Err   then ?
```
