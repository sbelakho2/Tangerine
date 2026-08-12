# Tangerine Layout Engine — Frozen Feature Gates
# ================================================================
# This document defines which layout representation features are
# FROZEN (stable, must not change without a major version bump)
# and which are GATED (experimental, disabled by default).
#
# Any change to a frozen feature is a breaking ABI change.

## FROZEN FEATURES (must not change)

### F1: Primitive Type Sizes
All primitive type sizes are frozen at their current values.
Changing any of these is an ABI break.

| Type   | Size (bytes) | Align (bytes) | Frozen Since |
|--------|-------------|---------------|--------------|
| Bool   | 1           | 1             | v0.1         |
| u8     | 1           | 1             | v0.1         |
| i8     | 1           | 1             | v0.1         |
| u16    | 2           | 2             | v0.1         |
| i16    | 2           | 2             | v0.1         |
| Char   | 4           | 4             | v0.1         |
| u32    | 4           | 4             | v0.1         |
| i32    | 4           | 4             | v0.1         |
| f32    | 4           | 4             | v0.1         |
| Int    | 8           | 8             | v0.1         |
| UInt   | 8           | 8             | v0.1         |
| u64    | 8           | 8             | v0.1         |
| i64    | 8           | 8             | v0.1         |
| Float  | 8           | 8             | v0.1         |
| f64    | 8           | 8             | v0.1         |

### F2: Container Layouts
These container type layouts are frozen.

| Type     | Size | Layout (ptr, len, cap, ...)     | Frozen Since |
|----------|------|---------------------------------|--------------|
| String   | 8    | raw pointer to null-terminated UTF-8 | v0.1    |
| Vec[T]   | 24   | ptr:0, len:8, cap:16            | v0.1         |
| Map[K,V] | 48   | buckets:0, len:8, cap:16, hash_fn:24 | v0.1   |
| Set[T]   | 32   | map:0, len:8                    | v0.1         |

**String ABI note (FROZEN):** String values are an 8-byte raw pointer to a
null-terminated UTF-8 byte buffer. There is NO inline `{ptr,len,cap}` header
on String values. The 24-byte `{ptr:0, len:8, cap:16}` shape sometimes
described for String is ONLY the internal char-vector buffer produced by
`str.chars()` (a `Vec[Int]`), never the String value ABI. This must match
`layout_engine.string_abi_size()` and `codegen.normalize_string_arg0_for_current_arch`.
Changing it is a breaking ABI change.

### F3: Enum Representation
- Tag is always 8 bytes at offset 0
- Payload starts at offset 8
- Discriminants auto-increment from 0 unless explicitly specified
- Frozen since v0.1

### F4: Pointer-Width Types
All pointer and reference types are 8 bytes on LP64 targets.
- Box[T]: 8 bytes
- Ptr[T]: 8 bytes
- &T:     8 bytes
- &mut T: 8 bytes
- Frozen since v0.1

### F5: Function Type
- Function/closure: 8 bytes (raw fn pointer, no env pointer)
- Frozen since v0.1

### F6: Zero-Sized Types
- Unit: 0 bytes
- Never: 0 bytes
- Frozen since v0.1

### F7: Struct Layout Algorithm
- Fields are laid out in declaration order
- Each field is aligned to its natural alignment
- No field reordering
- Frozen since v0.1

### F8: field_type_size() Defaults
- Unknown user-defined struct types default to 8 bytes (pointer-width)
- This is a known limitation, not a feature
- Frozen since v0.1 (but see GATED: G3)

## GATED FEATURES (disabled by default, not available)

### G1: Niche Optimizations
Optimizing Option<&T> to a single pointer (null = None) is NOT
implemented and NOT planned for the bootstrap phase.
Status: DISABLED

### G2: Packed / Repr(C) Layouts
Explicit `#[repr(packed)]` or `#[repr(C)]` layout control is NOT
implemented.
Status: DISABLED

### G3: Dynamically-Sized Types (DST)
Types whose size is not known at compile time (e.g., `[T]` slices
as inline fields) are NOT supported as struct fields.
Status: DISABLED

### G4: Field Reordering Optimization
Reordering struct fields for optimal packing is NOT implemented.
Fields are always in declaration order.
Status: DISABLED

### G5: Custom Alignment
`#[align(N)]` annotations for overriding natural alignment are NOT
supported.
Status: DISABLED

### G6: Bit-level Layouts
Bitfields and sub-byte field packing are NOT supported.
Status: DISABLED

### G7: Recursive Type Size Computation
`field_type_size()` does NOT recursively compute sizes of
user-defined struct types. It defaults to 8 (pointer-width).
The correct size is computed later in `build_field_layouts()`.
Status: KNOWN LIMITATION — tracked for improvement

## INVARIANTS

1. `size_of(T) >= 0` for all types
2. `align_of(T) > 0` for all types
3. `stride_of(T) >= size_of(T)` for all types
4. `offset_of(field_N) >= offset_of(field_{N-1}) + size_of(field_{N-1})`
5. `offset_of(field_N) % align_of(field_N) == 0`
6. Enum tag is always at offset 0, payload at offset 8
7. Field order matches declaration order (no reordering)
