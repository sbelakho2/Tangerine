# Tangerine Memory Model

**Version:** 0.1.0  
**Last Updated:** March 2026

This document describes Tangerine's ownership-based memory model, which provides memory safety without garbage collection.

---

## Table of Contents

1. [Overview](#overview)
2. [Ownership](#ownership)
3. [Borrowing](#borrowing)
4. [Lifetimes](#lifetimes)
5. [Move Semantics](#move-semantics)
6. [Copy and Clone](#copy-and-clone)
7. [Drop and Destructors](#drop-and-destructors)
8. [Smart Pointers](#smart-pointers)
9. [Interior Mutability](#interior-mutability)
10. [Allocators](#allocators)
11. [Progressive Modes](#progressive-modes)
12. [FFI Memory Safety](#ffi-memory-safety)

---

## Overview

Tangerine's memory model enforces three invariants at compile time:

1. **Every value has exactly one owner.**
2. **Mutable access is exclusive** — at most one `&mut` reference to a value at any time.
3. **Shared references are immutable** — any number of `&` references, but no concurrent `&mut`.

These rules eliminate data races, use-after-free, double-free, and dangling references at compile time.

---

## Ownership

Every value in Tangerine has a single variable that "owns" it. When the owner goes out of scope, the value is dropped (its destructor runs and memory is freed).

```tangerine
def example() -> Unit
  let s = String::from("hello")   # s owns the string
  do_something(s)                 # ownership moves to do_something
  # s is no longer valid here — compile error if used
end
```

### Ownership Rules

| Rule | Description |
|------|-------------|
| Single owner | Each value has exactly one owner at a time |
| Scope-based | Owner's scope determines the value's lifetime |
| Move on assignment | Assignment transfers ownership (unless `Copy`) |
| Drop on scope exit | Destructor runs when owner goes out of scope |

---

## Borrowing

Instead of transferring ownership, you can *borrow* a reference to a value.

### Shared References (`&T`)

Read-only access. Multiple shared references can coexist.

```tangerine
def print_len(s: &String) -> Unit
  println(s.len().to_string())   # read-only access
end

def example() -> Unit
  let s = String::from("hello")
  print_len(&s)       # borrow s
  println(s)           # s is still valid
end
```

### Mutable References (`&mut T`)

Exclusive read-write access. Only one `&mut` at a time, and no `&` while `&mut` exists.

```tangerine
def append_world(s: &mut String) -> Unit
  s.push_str(" world")
end

def example() -> Unit
  mut s = String::from("hello")
  append_world(&mut s)
  println(s)   # "hello world"
end
```

### Borrowing Rules

```
 ┌──────────────────────────────────────────┐
 │  At any given time, you can have EITHER: │
 │  • One mutable reference (&mut T)        │
 │          OR                              │
 │  • Any number of shared references (&T)  │
 │          (but NOT both)                  │
 └──────────────────────────────────────────┘
```

---

## Lifetimes

Lifetimes are compile-time annotations that track how long references remain valid. Most lifetimes are inferred; explicit annotations are needed when the compiler cannot determine the relationship.

### Explicit Lifetime Syntax

```tangerine
def longest['a](x: &'a String, y: &'a String) -> &'a String
  if x.len() > y.len() then x else y end
end
```

### Lifetime Elision Rules

Tangerine applies these rules automatically:

1. Each input reference gets its own lifetime parameter.
2. If there is exactly one input lifetime, it is assigned to all output lifetimes.
3. If one of the inputs is `&self` or `&mut self`, that lifetime is assigned to all outputs.

### Struct Lifetimes

```tangerine
struct StringRef['a]
  data: &'a String
end

impl['a] StringRef['a]
  def new(s: &'a String) -> StringRef['a]
    StringRef { data: s }
  end
end
```

---

## Move Semantics

By default, assignment and function calls *move* ownership:

```tangerine
let a = Vec::new()
let b = a          # a is moved to b
# a is invalid here

def take_vec(v: Vec[Int]) -> Unit
  # v is dropped at end of this function
end
take_vec(b)        # b is moved into the function
```

### Partial Moves

Moving a field out of a struct makes the whole struct partially moved:

```tangerine
struct Pair
  first: String
  second: String
end

let p = Pair { first: "hello".to_string(), second: "world".to_string() }
let s = p.first    # partial move
# p.second is still valid, but p as a whole is not
```

---

## Copy and Clone

### `Copy` Trait

Types that implement `Copy` are bitwise-copied instead of moved. This is opt-in:

```tangerine
@derive(Copy, Clone)
struct Point
  x: Float
  y: Float
end

let a = Point { x: 1.0, y: 2.0 }
let b = a          # copied, a is still valid
```

Types eligible for `Copy`:
- All primitive types (`Int`, `Float`, `Bool`, `Char`, `UInt`)
- Tuples of `Copy` types
- Fixed-size arrays of `Copy` types
- Structs where all fields are `Copy` (must opt-in with `@derive(Copy)`)

### `Clone` Trait

Explicit deep duplication:

```tangerine
let a = vec![1, 2, 3]
let b = a.clone()  # explicit deep copy
```

---

## Drop and Destructors

The `Drop` trait provides a destructor that runs when a value goes out of scope:

```tangerine
struct FileHandle
  fd: Int
end

impl Drop for FileHandle
  def drop(self: &mut FileHandle) -> Unit
    close_fd(self.fd)
  end
end
```

### Drop Order

- Local variables are dropped in **reverse** order of declaration.
- Struct fields are dropped in **declaration** order.
- `Drop::drop()` is called automatically; you cannot call it explicitly.
- Use `std::mem::drop(value)` to drop early.

---

## Smart Pointers

### `Box[T]` — Heap Allocation

```tangerine
let b = Box::new(42)         # heap-allocated Int
let val: Int = *b            # dereference
```

### `Rc[T]` — Reference Counting (Single-Threaded)

```tangerine
let a = Rc::new(vec![1, 2, 3])
let b = a.clone()            # increments reference count
# Both a and b point to the same Vec
# Dropped when count reaches zero
```

### `Arc[T]` — Atomic Reference Counting (Thread-Safe)

```tangerine
let data = Arc::new(Mutex::new(0))
let data2 = data.clone()
thread::spawn(move || {
  let mut guard = data2.lock()
  *guard = *guard + 1
})
```

### `Weak[T]` — Non-Owning Reference

```tangerine
let strong = Rc::new(42)
let weak: Weak[Int] = Rc::downgrade(&strong)
match weak.upgrade()
when Option::Some(val) then println(val.to_string())
when Option::None then println("value dropped")
end
```

---

## Interior Mutability

When you need mutation through a shared reference:

### `Cell[T]` (for `Copy` types)

```tangerine
let c = Cell::new(5)
c.set(10)
let v = c.get()   # 10
```

### `RefCell[T]` (runtime borrow checking)

```tangerine
let rc = RefCell::new(vec![1, 2, 3])
{
  let mut r = rc.borrow_mut()  # runtime check
  r.push(4)
}
let r = rc.borrow()           # read access
```

---

## Allocators

Tangerine supports pluggable allocators via the `Allocator` trait in `std/alloc`:

```tangerine
trait Allocator
  def allocate(self: &Self, layout: Layout) -> Result[NonNull[u8], AllocError]
  def deallocate(self: &Self, ptr: NonNull[u8], layout: Layout) -> Unit
end
```

### Global Allocator

Set the default allocator for the entire program:

```tangerine
@[GlobalAllocator]
let ALLOC = BumpAllocator::new(1024 * 1024)
```

### Arena/Region Allocation

```tangerine
let arena = Arena::new(4096)    # 4 KB arena
let s = arena.alloc(String::from("hello"))
# All arena allocations freed at once when arena drops
```

---

## Progressive Modes

Tangerine's mode system affects memory model strictness:

| Mode | Memory Behavior |
|------|----------------|
| **Dev** | Full ownership checks; warnings for common pitfalls |
| **Strict** | All ownership + lifetime checks enforced, no `unsafe` without justification |
| **Production** | Strict + optimizations, dead code elimination |
| **Hardened** | Production + stack canaries, ASLR, address sanitizer integration |

### `unsafe` Blocks

Opt out of borrow checking for FFI or performance-critical code:

```tangerine
unsafe
  let ptr = alloc::allocate(Layout::new::[Int]())
  ptr.write(42)
  let val = ptr.read()
  alloc::deallocate(ptr, Layout::new::[Int]())
end
```

---

## FFI Memory Safety

When crossing FFI boundaries, ownership must be explicitly managed:

```tangerine
# Transfer ownership TO C
extern "C" def c_takes_ownership(ptr: *mut MyStruct) -> Unit

let boxed = Box::new(MyStruct::new())
let raw = Box::into_raw(boxed)
c_takes_ownership(raw)  # C now owns the memory

# Transfer ownership FROM C
extern "C" def c_creates() -> *mut MyStruct

let raw = c_creates()
let boxed = unsafe { Box::from_raw(raw) }  # Tangerine now owns it
```

### FFI Safety Annotations

```tangerine
@[FFI(lib: "mylib", safety: "unsafe")]
extern def risky_function(ptr: *mut Void) -> Int

@[FFI(lib: "mylib", safety: "safe")]
extern def safe_function(x: Int) -> Int
```

See the [Interoperability Guide](interop.md) for comprehensive FFI documentation.
