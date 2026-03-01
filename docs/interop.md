# Tangerine Interoperability Guide

This document provides comprehensive guidance for developers working with Tangerine's foreign function interface (FFI) and language interoperability features. It covers C, Rust, and Ruby integration with detailed examples and best practices.

## Table of Contents

1. [Overview](#overview)
2. [ABI Families](#abi-families)
3. [FFI-Safe Types](#ffi-safe-types)
4. [Data Layout](#data-layout)
5. [Ownership and Memory](#ownership-and-memory)
6. [Error Handling](#error-handling)
7. [C Interoperability](#c-interoperability)
8. [Rust Interoperability](#rust-interoperability)
9. [Ruby Interoperability](#ruby-interoperability)
10. [Bindgen Tools](#bindgen-tools)
11. [ABI Validation](#abi-validation)
12. [Best Practices](#best-practices)
13. [Troubleshooting](#troubleshooting)

---

## Overview

Tangerine provides stable, well-defined interoperability with C, Rust, and Ruby through its FFI system. The design prioritizes:

- **Stability**: ABI contracts remain stable within an edition (e.g., Edition 2026)
- **Safety**: Zero undefined behavior at boundaries for safe code
- **Determinism**: Predictable layouts for all FFI types
- **Explicitness**: Ownership transfer is always explicit

### Version Information

| Property | Value |
|----------|-------|
| ABI Edition | 2026 |
| ABI Revision | 1 |
| Specification | v0.1 |

### Supported Platforms

Tangerine v0.1 provides stable ABI guarantees on these 64-bit little-endian targets:

| Target Triple | ABI | Notes |
|--------------|-----|-------|
| `x86_64-unknown-linux-gnu` | SysV AMD64 | Primary Linux target |
| `x86_64-apple-darwin` | SysV-like | macOS |
| `x86_64-pc-windows-msvc` | Win64 | Windows with MSVC |
| `aarch64-apple-darwin` | ARM64 | Apple Silicon |

Other targets are supported but not ABI-stable in v0.1.

---

## ABI Families

Tangerine supports four ABI "families" for different interop scenarios:

### `extern "C"`

The standard C ABI for maximum compatibility:

```tangerine
extern "C" def add(a: Int, b: Int) -> Int
    a + b
end
```

- Uses platform's native C calling convention
- No name mangling by default
- Compatible with any language that supports C FFI

### `extern "Tangerine"`

Tangerine's stable native ABI for Tangerine-to-Tangerine dynamic linking:

```tangerine
extern "Tangerine" def process(data: Array[Int]) -> Result[Int, Error]
    # Tangerine-native types allowed
end
```

- Uses Tangerine symbol mangling (see [Symbol Mangling](#symbol-mangling))
- Stable within an ABI edition
- Supports richer type system than C ABI

### `extern "Ruby"`

MRI Ruby extension ABI:

```tangerine
extern "Ruby" def my_method(self_: RubyValue, arg: RubyValue) -> RubyValue {
    // Ruby C API conventions
}
```

- C ABI with Ruby C API conventions
- Uses `VALUE` (word-sized) for Ruby objects
- Requires GC rooting for stored references

### `extern "Rust"`

Rust interop through C ABI + generated shims:

```tangerine
extern "Rust" def rust_process(data: *const u8, len: usize) -> i32 {
    // Callable from Rust as extern "C"
}
```

- **Important**: Not Rust's native ABI—always goes through C ABI
- Use `tg bindgen rust` to generate Rust shim crate

---

## FFI-Safe Types

Only specific types may cross FFI boundaries by value. Using non-FFI-safe types at boundaries is a compile error.

### FFI-Safe Type List

| Category | Types | Size (64-bit) | Alignment |
|----------|-------|---------------|-----------|
| Integers | `i8`, `u8` | 1 | 1 |
| | `i16`, `u16` | 2 | 2 |
| | `i32`, `u32` | 4 | 4 |
| | `i64`, `u64` | 8 | 8 |
| | `isize`, `usize` | 8 | 8 |
| Boolean | `Bool` | 1 | 1 |
| Floats | `f32` | 4 | 4 |
| | `f64` | 8 | 8 |
| Pointers | `*T`, `*mut T`, `*const T` | 8 | 8 |
| Structs | `@repr(C)` structs | varies | varies |
| Enums | `@repr(C)` C-like enums | varies | varies |

### Non-FFI-Safe Types

These types **cannot** cross FFI boundaries by value:

- `String` (use `FfiStr` view instead)
- `Array[T]` (use `FfiSlice[T]` view instead)
- `Map[K, V]`
- Trait objects
- Closures
- Non-`@repr(C)` enums with payloads
- Unmonomorphized generics

To pass these types, use pointers or convert to FFI-safe views.

### FFI View Types

Tangerine provides standard FFI view types in `std/ffi`:

```tangerine
# Borrowed slice view
@repr(C)
struct FfiSlice[T] {
    ptr: *const T,
    len: usize,
}

# Borrowed UTF-8 string view
@repr(C)
struct FfiStr {
    ptr: *const u8,
    len: usize,
}
```

**Example usage:**

```tangerine
use std::ffi::{FfiStr, FfiSlice}

# Export a function that accepts a string view
@export("process_string")
extern "C" def process_string(s: FfiStr) -> i32 {
    # s.ptr points to UTF-8 data, s.len is byte length
    # Valid only for duration of call
    0
}

# Export a function that accepts a slice view
@export("sum_array")
extern "C" def sum_array(arr: FfiSlice[i32]) -> i32 {
    let mut total = 0
    for i in 0..arr.len {
        total += unsafe { *arr.ptr.offset(i as isize) }
    }
    total
}
```

---

## Data Layout

### Primitive Type Sizes

All sizes are for 64-bit targets:

| Tangerine Type | Size (bytes) | Alignment | Notes |
|----------------|--------------|-----------|-------|
| `Int` | 8 | 8 | Signed 64-bit |
| `Bool` | 1 | 1 | Must be 0 or 1 |
| `Float` | 8 | 8 | IEEE 754 f64 |
| `Ref[T]` | 8 | 8 | Pointer |
| `String` | 24 | 8 | ptr + len + cap |
| `Slice[T]` | 16 | 8 | ptr + len |

### `@repr(C)` Struct Layout

Structs marked with `@repr(C)` follow C ABI layout rules:

1. Fields are placed in declaration order
2. Each field starts at the smallest offset ≥ current size, aligned to field's alignment
3. Struct alignment is the maximum alignment of all fields
4. Total size is padded to a multiple of struct alignment

**Example:**

```tangerine
@repr(C)
struct Example {
    a: u8,   # offset 0, size 1
    # padding: 3 bytes
    b: u32,  # offset 4, size 4
    c: u8,   # offset 8, size 1
    # padding: 7 bytes
    d: u64,  # offset 16, size 8
}
# Total: size 24, align 8
```

Layout visualization:
```
Offset:  0   1   2   3   4   5   6   7   8   9  10  11  12  13  14  15  16  ...  23
       [a] [pad pad pad] [  b (4 bytes) ] [c] [  padding (7 bytes)  ] [  d (8)  ]
```

### `@repr(C)` Enum Layout

C-like enums (no payloads) with explicit tag type:

```tangerine
@repr(C, tag = u32)
enum Color {
    Red,    # = 0
    Green,  # = 1
    Blue,   # = 2
}
# Size: 4, Align: 4
```

For enums with payloads, use explicit tagged unions:

```tangerine
@repr(C)
struct OptionI64 {
    tag: u8,      # 0 = None, 1 = Some
    # padding for alignment
    payload: i64, # valid only if tag == 1
}
```

The compiler can auto-generate these via `@ffi_union`.

---

## Ownership and Memory

### Ownership Qualifiers

Every FFI function must explicitly declare ownership semantics for pointer parameters:

| Qualifier | Meaning | Callee Responsibility |
|-----------|---------|----------------------|
| `Borrowed[T]` | Temporary borrow | Cannot store beyond call; no cleanup |
| `Owned[T]` | Ownership transfers | Must eventually free with specified allocator |
| `Shared[T]` | Reference-counted/GC-managed | Handle managed by runtime |

**Example with attributes:**

```tangerine
use std::ffi::{Borrowed, Owned, FfiSlice}

# Borrowed: callee does not take ownership
@export("process_borrowed")
extern "C" def process_borrowed(data: Borrowed[FfiSlice[u8]]) -> i32 {
    # data valid only during this call
    0
}

# Owned: callee takes ownership and must free
@ffi(alloc = "tangerine")
@export("take_owned")
extern "C" def take_owned(data: Owned[*mut u8], len: usize) -> Unit {
    # Must call tg_free(data.ptr, len, 1) when done
}
```

### Allocation Domains

Owned pointers must specify their allocator domain:

| Domain | Freed By | Attribute |
|--------|----------|-----------|
| `tangerine` | `tg_free()` | `@ffi(alloc = "tangerine")` |
| `c` | `free()` | `@ffi(alloc = "c")` |
| `ruby` | Ruby GC | `@ffi(alloc = "ruby")` |

**Compile error** if allocator domain is unspecified for owned pointers.

### Tangerine Runtime Allocator

The Tangerine runtime exports these allocation functions:

```tangerine
# Allocate memory
@export("tg_alloc")
extern "C" def tg_alloc(size: usize, align: usize) -> *mut u8

# Reallocate memory
@export("tg_realloc")
extern "C" def tg_realloc(ptr: *mut u8, new_size: usize, align: usize) -> *mut u8

# Free memory
@export("tg_free")
extern "C" def tg_free(ptr: *mut u8, size: usize, align: usize) -> Unit
```

**C usage example:**

```c
#include <stdint.h>

extern uint8_t* tg_alloc(size_t size, size_t align);
extern void tg_free(uint8_t* ptr, size_t size, size_t align);

void example() {
    // Allocate 1024 bytes, 8-byte aligned
    uint8_t* buffer = tg_alloc(1024, 8);
    
    // Use buffer...
    
    // Free with same size and alignment
    tg_free(buffer, 1024, 8);
}
```

---

## Error Handling

### Panic Strategy

Tangerine v0.1 uses `panic = abort` by default:

- No stack unwinding across FFI boundaries
- Panics terminate the process immediately
- No exception handling overhead

### TgResult Pattern

For returning errors across C ABI, use `TgResult[T]`:

```tangerine
@repr(C)
struct TgResult[T] {
    ok: Bool,       # true if success
    err_code: i32,  # 0 if ok, error code otherwise
    value: T,       # valid only if ok == true
}
```

**Helper functions:**

```tangerine
use std::ffi::{TgResult, tg_result_ok, tg_result_err}

@export("divide")
extern "C" def divide(a: i64, b: i64) -> TgResult[i64] {
    if b == 0 {
        tg_result_err[i64](1)  # Error code 1: division by zero
    } else {
        tg_result_ok(a / b)
    }
}
```

**C consumer:**

```c
typedef struct {
    uint8_t ok;
    int32_t err_code;
    int64_t value;
} TgResult_i64;

extern TgResult_i64 divide(int64_t a, int64_t b);

int main() {
    TgResult_i64 result = divide(10, 2);
    if (result.ok) {
        printf("Result: %lld\n", result.value);
    } else {
        printf("Error code: %d\n", result.err_code);
    }
}
```

### Error Message Retrieval

For detailed error messages:

```tangerine
@export("tg_last_error_code")
extern "C" def tg_last_error_code() -> i32

@export("tg_last_error_message") 
extern "C" def tg_last_error_message() -> FfiStr
```

**C usage:**

```c
extern int32_t tg_last_error_code(void);
extern TgStr tg_last_error_message(void);

void handle_error() {
    int32_t code = tg_last_error_code();
    TgStr msg = tg_last_error_message();
    fprintf(stderr, "Error %d: %.*s\n", code, (int)msg.len, msg.ptr);
}
```

---

## C Interoperability

### Exposing Tangerine Functions to C

```tangerine
use std::ffi::{FfiStr, FfiSlice, TgResult}

# Simple function export
@export("tg_add")
extern "C" def add(a: i32, b: i32) -> i32 {
    a + b
}

# Struct export
@repr(C)
struct Point {
    x: f64,
    y: f64,
}

@export("tg_point_distance")
extern "C" def point_distance(p1: Point, p2: Point) -> f64 {
    let dx = p2.x - p1.x
    let dy = p2.y - p1.y
    (dx * dx + dy * dy).sqrt()
}

# Array processing
@export("tg_sum_array")
extern "C" def sum_array(data: FfiSlice[i32]) -> i64 {
    let mut sum: i64 = 0
    for i in 0..data.len {
        sum += unsafe { *data.ptr.offset(i as isize) } as i64
    }
    sum
}
```

### Calling C Functions from Tangerine

```tangerine
# Declare external C functions
extern "C" {
    def malloc(size: usize) -> *mut u8
    def free(ptr: *mut u8)
    def strlen(s: *const u8) -> usize
    def memcpy(dest: *mut u8, src: *const u8, n: usize) -> *mut u8
}

def example() {
    # Allocate with C malloc
    let ptr = malloc(1024)
    
    # Use memory...
    
    # Free with C free
    free(ptr)
}
```

### Generating C Headers

Use `tg bindgen c` to generate C header files:

```bash
$ tg bindgen c src/lib.tg -o tangerine_api.h
```

**Generated header example:**

```c
/* tangerine_api.h - Auto-generated by tg bindgen c */
#ifndef TANGERINE_API_H
#define TANGERINE_API_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Type aliases */
typedef int64_t tg_int;
typedef uint64_t tg_uint;
typedef double tg_float;
typedef uint8_t tg_bool;

typedef struct {
    const uint8_t* ptr;
    size_t len;
} tg_str;

typedef struct {
    const void* ptr;
    size_t len;
} tg_slice;

/* Struct definitions */
typedef struct {
    double x;
    double y;
} Point;

/* Function declarations */
int32_t tg_add(int32_t a, int32_t b);
double tg_point_distance(Point p1, Point p2);
int64_t tg_sum_array(tg_slice data);

#ifdef __cplusplus
}
#endif

#endif /* TANGERINE_API_H */
```

---

## Rust Interoperability

### Core Principle

Tangerine-Rust interop uses **C ABI + generated shims**, not Rust's native ABI:

```
[Tangerine Code] <--C ABI--> [Rust Shim Crate] <--Rust--> [Rust Code]
```

### Generating Rust Shims

```bash
$ tg bindgen rust src/lib.tg -o tangerine_shim
```

This generates a Rust crate:

```
tangerine_shim/
├── Cargo.toml
└── src/
    └── lib.rs
```

**Generated Cargo.toml:**

```toml
[package]
name = "tangerine_shim"
version = "0.1.0"
edition = "2021"

[lib]
crate-type = ["cdylib", "staticlib"]

[dependencies]
```

**Generated lib.rs:**

```rust
//! Tangerine FFI shim crate
//! Auto-generated by tg bindgen rust

#![allow(non_camel_case_types)]
#![allow(non_snake_case)]

use std::os::raw::*;

// Type aliases
pub type tg_int = i64;
pub type tg_uint = u64;
pub type tg_float = f64;
pub type tg_bool = u8;

#[repr(C)]
pub struct tg_str {
    pub ptr: *const u8,
    pub len: usize,
}

#[repr(C)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

// Extern declarations for Tangerine functions
extern "C" {
    pub fn tg_add(a: i32, b: i32) -> i32;
    pub fn tg_point_distance(p1: Point, p2: Point) -> f64;
}

// Safe Rust wrappers (optional)
pub fn add(a: i32, b: i32) -> i32 {
    unsafe { tg_add(a, b) }
}

pub fn point_distance(p1: Point, p2: Point) -> f64 {
    unsafe { tg_point_distance(p1, p2) }
}
```

### Calling Tangerine from Rust

```rust
use tangerine_shim::{add, point_distance, Point};

fn main() {
    let sum = add(5, 3);
    println!("5 + 3 = {}", sum);
    
    let p1 = Point { x: 0.0, y: 0.0 };
    let p2 = Point { x: 3.0, y: 4.0 };
    let dist = point_distance(p1, p2);
    println!("Distance: {}", dist);  // 5.0
}
```

### Calling Rust from Tangerine

First, create a Rust library with C ABI exports:

```rust
// rust_lib/src/lib.rs
#[no_mangle]
pub extern "C" fn rust_multiply(a: i64, b: i64) -> i64 {
    a * b
}

#[repr(C)]
pub struct RustData {
    pub value: i64,
    pub valid: bool,
}

#[no_mangle]
pub extern "C" fn rust_create_data(value: i64) -> RustData {
    RustData { value, valid: true }
}
```

Then declare in Tangerine:

```tangerine
extern "C" {
    def rust_multiply(a: i64, b: i64) -> i64
}

@repr(C)
struct RustData {
    value: i64,
    valid: Bool,
}

extern "C" {
    def rust_create_data(value: i64) -> RustData
}

def main() {
    let product = rust_multiply(6, 7)
    println("6 * 7 = {product}")
    
    let data = rust_create_data(42)
    println("Data: {data.value}, valid: {data.valid}")
}
```

### String Passing Convention

Strings are passed as `(ptr, len)` pairs:

```tangerine
# Tangerine side
@export("tg_process_string")
extern "C" def process_string(ptr: *const u8, len: usize) -> i32 {
    # ptr points to UTF-8 data
    0
}
```

```rust
// Rust side
extern "C" {
    fn tg_process_string(ptr: *const u8, len: usize) -> i32;
}

fn process(s: &str) -> i32 {
    unsafe {
        tg_process_string(s.as_ptr(), s.len())
    }
}
```

**Important**: Rust shims MUST be compiled with `panic = abort` for boundary functions, or must catch panics and translate to error codes.

---

## Ruby Interoperability

### Ruby Extension Basics

Tangerine can create native Ruby extensions loaded by MRI Ruby:

```tangerine
use std::ffi::{RubyValue, ruby_nil, ruby_int_new, ruby_string_new}

# Required init function - called when Ruby loads the extension
@export("Init_my_extension")
extern "C" def init_my_extension() {
    # Register module and methods with Ruby
    let module = ruby_define_module("MyExtension")
    ruby_define_module_function(module, "add", tg_add, 2)
    ruby_define_module_function(module, "greet", tg_greet, 1)
}

# Method implementations receive RubyValue arguments
extern "C" def tg_add(self_: RubyValue, a: RubyValue, b: RubyValue) -> RubyValue {
    let a_int = ruby_num2long(a)
    let b_int = ruby_num2long(b)
    ruby_int_new(a_int + b_int)
}

extern "C" def tg_greet(self_: RubyValue, name: RubyValue) -> RubyValue {
    let name_str = ruby_string_to_str(name)
    let greeting = "Hello, " + name_str + "!"
    ruby_string_new(greeting.ptr, greeting.len)
}
```

### RubyValue Type

```tangerine
@repr(C)
struct RubyValue {
    raw: usize,  # Mirrors Ruby's VALUE type
}
```

`RubyValue` is an opaque handle—only Ruby C API functions may inspect or modify it.

### GC Rooting Rules

**Critical**: Any `RubyValue` stored beyond the immediate call must be registered as a GC root:

```tangerine
use std::ffi::{RubyValue, tg_ruby_gc_register, tg_ruby_gc_unregister}

struct CachedValue {
    value: RubyValue,
}

def cache_value(v: RubyValue) -> CachedValue {
    # MUST register if storing beyond call
    tg_ruby_gc_register(v)
    CachedValue { value: v }
}

def release_cached(cache: CachedValue) {
    # MUST unregister when done
    tg_ruby_gc_unregister(cache.value)
}
```

**Runtime GC Functions:**

```tangerine
@export("tg_ruby_gc_register")
extern "C" def tg_ruby_gc_register(v: RubyValue) -> Unit

@export("tg_ruby_gc_unregister")
extern "C" def tg_ruby_gc_unregister(v: RubyValue) -> Unit
```

### Ruby String/Array Conversions

Two modes for converting Ruby strings:

**Copy Mode (default, safe):**

```tangerine
def process_ruby_string(rv: RubyValue) -> String {
    # Copies Ruby string bytes into Tangerine String
    ruby_string_to_tangerine(rv)
}
```

**Borrow Mode (advanced, requires explicit attribute):**

```tangerine
@ffi(ruby_borrow = "true")
def process_ruby_string_borrowed(rv: RubyValue) -> FfiStr {
    # Borrows pointer+len - only valid if Ruby string is frozen and pinned
    ruby_string_borrow(rv)
}
```

### Generating Ruby Extensions

```bash
$ tg bindgen ruby src/lib.tg -o my_extension
```

Generates:

```
my_extension/
├── extconf.rb
└── my_extension.c
```

**extconf.rb:**

```ruby
require 'mkmf'
create_makefile('my_extension')
```

**my_extension.c:**

```c
#include <ruby.h>

/* Forward declarations */
extern VALUE tg_add(VALUE self, VALUE a, VALUE b);
extern VALUE tg_greet(VALUE self, VALUE name);

void Init_my_extension(void) {
    VALUE mMyExtension = rb_define_module("MyExtension");
    rb_define_module_function(mMyExtension, "add", tg_add, 2);
    rb_define_module_function(mMyExtension, "greet", tg_greet, 1);
}
```

### Ruby Usage

```ruby
require 'my_extension'

puts MyExtension.add(5, 3)       # => 8
puts MyExtension.greet("World")  # => "Hello, World!"
```

### Ruby Exception Handling

Ruby calls may raise exceptions. Tangerine translates them to `TgResult` at boundaries:

```tangerine
use std::ffi::{TgResult, RubyValue, tg_ruby_eval}

def safe_eval(code: String) -> TgResult[RubyValue] {
    # Returns TgResult - check ok field before using value
    tg_ruby_eval(code)
}
```

For explicit exception propagation:

```tangerine
@ffi(throws = "ruby")
extern "C" def may_raise(v: RubyValue) -> RubyValue {
    # Exceptions propagate to Ruby caller
}
```

---

## Bindgen Tools

### Overview

Tangerine provides bindgen tools to generate bindings for other languages:

| Command | Output | Use Case |
|---------|--------|----------|
| `tg bindgen c <file>` | C header (.h) | C/C++ integration |
| `tg bindgen rust <file>` | Rust crate | Rust integration |
| `tg bindgen ruby <file>` | Ruby extension | Ruby integration |

### Common Options

```bash
# Output to specific location
tg bindgen c src/lib.tg -o include/tangerine.h

# Generate for multiple files
tg bindgen c src/*.tg -o include/

# Include all @repr(C) types
tg bindgen c src/lib.tg --all-types
```

### What Gets Exported

Bindgen includes:

- Functions marked with `@export`
- Structs marked with `@repr(C)`
- Enums marked with `@repr(C)`

```tangerine
# This function will appear in generated bindings
@export("my_function")
extern "C" def my_function(x: i32) -> i32 { x * 2 }

# This struct will appear in generated bindings
@repr(C)
struct MyStruct {
    value: i64,
}

# This will NOT appear (no @export)
def internal_function(x: i32) -> i32 { x + 1 }

# This will NOT appear (no @repr(C))
struct InternalStruct {
    data: Array[Int],
}
```

---

## ABI Validation

### ABI Test Suite

Run comprehensive ABI validation:

```bash
$ tg abi test
```

This validates:

- Size/alignment of all primitive types
- `@repr(C)` struct layouts
- Symbol naming conventions
- Error ABI conformance (`TgResult` structs)
- Allocator domain correctness

**Sample output:**

```
ABI Test Suite - Edition 2026, Revision 1
==========================================

Primitive Types:
  Int:    size=8, align=8  ✓
  Bool:   size=1, align=1  ✓
  Float:  size=8, align=8  ✓
  Ref[T]: size=8, align=8  ✓
  String: size=24, align=8 ✓
  Slice:  size=16, align=8 ✓

All ABI tests passed.
```

### ABI Dump

Dump detailed type layouts for a source file:

```bash
$ tg abi dump src/lib.tg
```

**Output:**

```
Type Layout Dump: src/lib.tg
============================

struct Point:
  size: 16, align: 8
  fields:
    x: f64 @ offset 0 (size 8, align 8)
    y: f64 @ offset 8 (size 8, align 8)

struct Rectangle:
  size: 32, align: 8
  fields:
    top_left:  Point @ offset 0  (size 16, align 8)
    bottom_right: Point @ offset 16 (size 16, align 8)

enum Color:
  tag_type: u32
  size: 4, align: 4
  variants:
    Red   = 0
    Green = 1
    Blue  = 2
```

### ABI Compatibility Check

Compare exported symbols between two versions:

```bash
$ tg abi check v1/lib.tg v2/lib.tg
```

**Output:**

```
ABI Compatibility Check
=======================

Removed exports (BREAKING):
  - process_data(FfiSlice[u8]) -> i32

Changed signatures (BREAKING):
  - calculate: (i32, i32) -> i32  =>  (i64, i64) -> i64

New exports (compatible):
  + process_data_v2(FfiSlice[u8], i32) -> i32
  + get_version() -> i32

Summary: 2 breaking changes, 2 additions
```

---

## Best Practices

### 1. Use Explicit Ownership Annotations

Always annotate ownership for pointer parameters:

```tangerine
# Good: explicit ownership
@ffi(alloc = "tangerine")
extern "C" def good_api(data: Owned[*mut u8]) -> Unit

# Bad: implicit ownership (compile error)
extern "C" def bad_api(data: *mut u8) -> Unit
```

### 2. Prefer FFI View Types

Use `FfiStr` and `FfiSlice[T]` instead of raw pointers:

```tangerine
# Good: self-documenting, includes length
@export("process")
extern "C" def process(data: FfiSlice[u8]) -> i32

# Okay but less clear: raw pointer + length
@export("process_raw")
extern "C" def process_raw(ptr: *const u8, len: usize) -> i32
```

### 3. Return Errors via TgResult

Use `TgResult[T]` for fallible operations:

```tangerine
# Good: structured error handling
@export("parse")
extern "C" def parse(input: FfiStr) -> TgResult[i64]

# Bad: error codes via return value
@export("parse_bad")
extern "C" def parse_bad(input: FfiStr, out: *mut i64) -> i32
```

### 4. Document Allocator Domains

When returning allocated memory, document the domain:

```tangerine
/// Returns a newly allocated buffer.
/// Caller must free with tg_free(ptr, size, 8).
@export("create_buffer")
@ffi(alloc = "tangerine")
extern "C" def create_buffer(size: usize) -> *mut u8
```

### 5. Use @repr(C) for FFI Types

All types crossing FFI boundaries must use `@repr(C)`:

```tangerine
# Good: deterministic C layout
@repr(C)
struct FfiPoint {
    x: f64,
    y: f64,
}

# Bad: Tangerine native layout (not portable)
struct NativePoint {
    x: Float,
    y: Float,
}
```

### 6. Validate ABI Before Release

Run `tg abi test` and `tg abi check` before releases:

```bash
# In CI pipeline
tg abi test
tg abi check last_release/lib.tg current/lib.tg
```

### 7. Use Symbol Versioning

For long-lived APIs, version your exports:

```tangerine
@export("my_api_v1")
extern "C" def my_api_v1(x: i32) -> i32

@export("my_api_v2")  
extern "C" def my_api_v2(x: i64) -> i64
```

### 8. Handle Ruby GC Correctly

Always root Ruby values stored beyond call scope:

```tangerine
# Pattern: register on store, unregister on release
def store_ruby_value(v: RubyValue, storage: *mut RubyValue) {
    tg_ruby_gc_register(v)
    unsafe { *storage = v }
}

def clear_ruby_value(storage: *mut RubyValue) {
    let old = unsafe { *storage }
    tg_ruby_gc_unregister(old)
    unsafe { *storage = ruby_nil() }
}
```

---

## Troubleshooting

### Common Errors

#### "Type is not FFI-safe"

```
error[E0277]: `String` is not FFI-safe
  --> src/lib.tg:10:5
   |
10 | extern "C" def bad(s: String) -> i32
   |                       ^^^^^^ cannot pass by value across FFI
   |
   = help: use FfiStr for borrowed string views
```

**Fix**: Use `FfiStr` or pass by pointer.

#### "Missing allocator domain"

```
error[E0301]: owned pointer missing allocator domain
  --> src/lib.tg:15:5
   |
15 | extern "C" def alloc() -> *mut u8
   |                           ^^^^^^^ add @ffi(alloc = "...")
```

**Fix**: Add `@ffi(alloc = "tangerine")` or `@ffi(alloc = "c")`.

#### "Symbol collision"

```
error[E0303]: symbol collision: `process` exported twice
  --> src/lib.tg:20:1
   |
20 | extern "C" def process(x: i32) -> i32
   | ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^
   |
   = help: use @export("process_v2") to disambiguate
```

**Fix**: Use explicit `@export("unique_name")`.

### Debugging Tips

1. **Check layouts**: Use `tg abi dump` to verify struct layouts match expectations

2. **Test round-trips**: Write tests that pass data across FFI and back

3. **Validate sizes**: Compare `sizeof()` in C with Tangerine's `type_size()`

4. **Enable debug symbols**: Compile with `-g` for better crash debugging

5. **Use sanitizers**: Link with AddressSanitizer to catch memory errors

---

## Symbol Mangling

### Tangerine Symbol Format

`extern "Tangerine"` functions use this mangling scheme:

```
_TG{edition}_{pkgHash}_{moduleLen}:{module}_{nameLen}:{name}_{sigHash}
```

| Component | Description |
|-----------|-------------|
| `edition` | ABI edition (e.g., `2026`) |
| `pkgHash` | 16-char hex of FNV-1a(package name + version) |
| `moduleLen` | Length of module path |
| `module` | Module path (e.g., `std::collections`) |
| `nameLen` | Length of function name |
| `name` | Function name |
| `sigHash` | 16-char hex of FNV-1a(signature) |

**Example:**

```
_TG2026_a1b2c3d4e5f67890_15:std::collections_6:insert_fedcba9876543210
```

### Demangling

Use `tg demangle` to convert mangled symbols to readable form:

```bash
$ tg demangle _TG2026_a1b2c3d4e5f67890_15:std::collections_6:insert_fedcba9876543210
std::collections::insert (edition 2026, pkg a1b2c3d4e5f67890)
```

---

## Appendix: Runtime Exports Reference

### Allocation Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `tg_alloc` | `(size: usize, align: usize) -> *mut u8` | Allocate memory |
| `tg_realloc` | `(ptr: *mut u8, new_size: usize, align: usize) -> *mut u8` | Reallocate |
| `tg_free` | `(ptr: *mut u8, size: usize, align: usize) -> Unit` | Free memory |

### Error Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `tg_last_error_code` | `() -> i32` | Get last error code |
| `tg_last_error_message` | `() -> FfiStr` | Get last error message |
| `tg_set_last_error` | `(code: i32, msg: FfiStr) -> Unit` | Set error state |
| `tg_clear_last_error` | `() -> Unit` | Clear error state |

### Ruby Bridge Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `tg_ruby_init` | `() -> Bool` | Initialize Ruby runtime |
| `tg_ruby_eval` | `(code: FfiStr) -> TgResult[RubyValue]` | Evaluate Ruby code |
| `tg_ruby_gc_register` | `(v: RubyValue) -> Unit` | Register GC root |
| `tg_ruby_gc_unregister` | `(v: RubyValue) -> Unit` | Unregister GC root |

### Version Functions

| Function | Signature | Description |
|----------|-----------|-------------|
| `tg_abi_edition` | `() -> FfiStr` | Get ABI edition string |
| `tg_abi_revision` | `() -> i32` | Get ABI revision number |

---

## Standard Library FFI Examples

The Tangerine standard library uses FFI extensively. Here are production examples:

### Database Drivers (`std/db`)

```tangerine
# SQLite FFI bindings
extern "C" {
  def sqlite3_open(filename: *const u8, ppDb: *mut *mut SqliteDb) -> i32
  def sqlite3_close(db: *mut SqliteDb) -> i32
  def sqlite3_prepare_v2(db: *mut SqliteDb, sql: *const u8, nByte: i32,
    ppStmt: *mut *mut SqliteStmt, pzTail: *mut *const u8) -> i32
  def sqlite3_step(stmt: *mut SqliteStmt) -> i32
  def sqlite3_finalize(stmt: *mut SqliteStmt) -> i32
  def sqlite3_column_text(stmt: *mut SqliteStmt, col: i32) -> *const u8
  def sqlite3_column_int64(stmt: *mut SqliteStmt, col: i32) -> i64
}

# PostgreSQL FFI bindings  
extern "C" {
  def PQconnectdb(conninfo: *const u8) -> *mut PGconn
  def PQstatus(conn: *const PGconn) -> i32
  def PQexec(conn: *mut PGconn, query: *const u8) -> *mut PGresult
  def PQntuples(res: *const PGresult) -> i32
  def PQgetvalue(res: *const PGresult, row: i32, col: i32) -> *const u8
}
```

### Compression (`std/compress`)

```tangerine
# Zlib FFI for deflate/gzip compression
@repr(C)
struct ZStream {
  next_in: *const u8,
  avail_in: u32,
  total_in: u64,
  next_out: *mut u8,
  avail_out: u32,
  total_out: u64,
  msg: *const u8,
  state: *mut Unit,
  zalloc: *const Unit,
  zfree: *const Unit,
  opaque: *const Unit,
  data_type: i32,
  adler: u64,
  reserved: u64,
}

extern "C" {
  def deflateInit_(strm: *mut ZStream, level: i32, 
    version: *const u8, stream_size: i32) -> i32
  def deflate(strm: *mut ZStream, flush: i32) -> i32
  def deflateEnd(strm: *mut ZStream) -> i32
  def inflateInit_(strm: *mut ZStream, version: *const u8, stream_size: i32) -> i32
  def inflate(strm: *mut ZStream, flush: i32) -> i32
  def inflateEnd(strm: *mut ZStream) -> i32
}
```

### Cryptography (`std/crypto`)

```tangerine
# OpenSSL FFI for hashing and encryption
extern "C" {
  def SHA256(data: *const u8, len: usize, md: *mut u8) -> *mut u8
  def SHA512(data: *const u8, len: usize, md: *mut u8) -> *mut u8
  def HMAC(evp_md: *const EVP_MD, key: *const u8, key_len: i32,
    data: *const u8, data_len: usize, md: *mut u8, md_len: *mut u32) -> *mut u8
  def EVP_sha256() -> *const EVP_MD
  def AES_set_encrypt_key(key: *const u8, bits: i32, ks: *mut AES_KEY) -> i32
  def AES_cbc_encrypt(in_: *const u8, out: *mut u8, length: usize,
    key: *const AES_KEY, iv: *mut u8, enc: i32)
  def RAND_bytes(buf: *mut u8, num: i32) -> i32
}
```

### TLS/HTTP (`std/http`)

```tangerine
# OpenSSL TLS FFI for HTTPS
extern "C" {
  def SSL_library_init() -> i32
  def SSL_CTX_new(method: *const SSL_METHOD) -> *mut SSL_CTX
  def TLS_client_method() -> *const SSL_METHOD
  def SSL_new(ctx: *mut SSL_CTX) -> *mut SSL
  def SSL_set_fd(ssl: *mut SSL, fd: i32) -> i32
  def SSL_connect(ssl: *mut SSL) -> i32
  def SSL_read(ssl: *mut SSL, buf: *mut u8, num: i32) -> i32
  def SSL_write(ssl: *mut SSL, buf: *const u8, num: i32) -> i32
  def SSL_shutdown(ssl: *mut SSL) -> i32
  def SSL_free(ssl: *mut SSL)
  def SSL_CTX_free(ctx: *mut SSL_CTX)
}
```

### Terminal I/O (`std/cli`)

```tangerine
# POSIX terminal control FFI
@repr(C)
struct Termios {
  c_iflag: u64,
  c_oflag: u64,
  c_cflag: u64,
  c_lflag: u64,
  c_cc: [u8; 20],
  c_ispeed: u64,
  c_ospeed: u64,
}

extern "C" {
  def tcgetattr(fd: i32, termios: *mut Termios) -> i32
  def tcsetattr(fd: i32, action: i32, termios: *const Termios) -> i32
  def isatty(fd: i32) -> i32
}
```

---

## See Also

- [Language Reference](language.md) - Core language documentation and stdlib overview
- [FFI Cheat Sheet](ffi_cheatsheet.md) - Quick reference for FFI patterns
- [Style Guide](style_guide.md) - Code style conventions
- [Versioning Policy](versioning.md) - Version numbering scheme
- [RFC Process](rfc_process.md) - How to propose changes
