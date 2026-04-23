# Stabilized Subset — Frozen Layout Features

This document defines the layout-affecting features that are **FROZEN** during stabilization.
These values MUST NOT change. Any bug in these values is a bug in the layout engine.

## F1: Primitive Sizes (FROZEN)

| Type | Size (bytes) | Alignment |
|------|-------------|-----------|
| Unit | 0 | 1 |
| Bool | 1 | 1 |
| Char | 4 | 4 |
| Int/UInt | 8 | 8 |
| Float (f64) | 8 | 8 |
| f32 | 4 | 4 |
| i8/u8 | 1 | 1 |
| i16/u16 | 2 | 2 |
| i32/u32 | 4 | 4 |
| i64/u64 | 8 | 8 |
| i128/u128 | 16 | 16 |
| isize/usize | 8 | 8 |

## F2: Container Header Sizes (FROZEN)

| Container | Header Size | Fields |
|-----------|-------------|--------|
| String | 24 | ptr(0), len(8), cap(16) |
| Vec[T] | 24 | data(0), length(8), capacity(16) |
| Array[T] | 24 | data(0), length(8), capacity(16) |
| Map[K,V] | 48 | buckets(0), size(8), cap(16), hash_fn(24), eq_fn(32), aux(40) |
| HashMap[K,V] | 48 | buckets(0), size(8), cap(16), hash_fn(24), eq_fn(32), aux(40) |
| Set[T] | 32 | map(0), size(8), aux(16) |
| HashSet[T] | 32 | map(0), size(8), aux(16) |

## F3: Enum Layout (FROZEN)

- **Discriminant (tag)**: offset 0, size 8 bytes
- **Payload**: starts at offset 8
- **Alignment**: max of tag (8) and max payload field
- **Total size**: aligned to max alignment

```
+------------------+------------------+
| Tag (8 bytes)    | Payload...       |
+------------------+------------------+
^ offset 0         ^ offset 8
```

## F4: Pointer Sizes (FROZEN)

| Type | Size |
|------|------|
| &T | 8 |
| &mut T | 8 |
| Box[T] | 8 |
| *const T | 8 |
| *mut T | 8 |
| fn() | 8 |

## F5: Fat Pointer Layout (FROZEN)

Fat pointers (slices, trait objects):
```
+------------------+------------------+
| Data Pointer (8) | Length/Metadata (8) |
+------------------+------------------+
^ offset 0         ^ offset 8
```

## F6: Struct Layout Rules (FROZEN)

1. **Field order**: declaration order (no reordering)
2. **Field alignment**: each field aligned to its natural alignment
3. **Struct alignment**: max of field alignments
4. **Struct size**: aligned to struct alignment

## F7: Array Layout (FROZEN)

- Contiguous elements
- Element stride = align_up(element_size, element_alignment)
- Total size = element_stride * count

## F8: Unknown Field Offsets (FROZEN)

For unknown fields (no layout info available):
- Field i offset = i * 8

This ensures forward compatibility when layout info is missing.

---

## Postponed Features (NOT Frozen)

These features are explicitly **NOT** frozen and may change:

1. **Niche optimizations** for enums (e.g., using invalid pointer values for None)
2. **Field reordering** for better packing
3. **Custom alignment** annotations
4. **Packed structs** with reduced alignment
5. **SIMD vector types** with special alignment
6. **Async generator frames** layout
7. **Closure capture** layout optimization

---

## Implementation Notes

### Where to Find These Values

All frozen values are defined in:
- `tg_compiler/layout_engine.tg` — Central layout engine
- `tests/layout_tests.tg` — Golden test suite verifying frozen values

### How to Use

```tangerine
use tg_compiler::layout_engine::{
  container_header_size, container_field_offset,
  discriminant_offset, discriminant_size, payload_offset
}

# Get String header size (F2 - FROZEN)
let str_size = container_header_size(&"String".to_string())  # 24

# Get Vec.len offset (F2 - FROZEN)
let len_off = container_field_offset(&"Vec".to_string(), &"length".to_string())  # 8

# Get enum tag offset (F3 - FROZEN)
let tag_off = discriminant_offset(&engine, type_id)  # 0
```

### Bug Classification

When a layout bug is found, classify it using `LayoutFailureClass`:

1. **LAYOUT_COMPUTATION_BUG**: Layout engine computed wrong values
2. **LAYOUT_CONSUMER_BUG**: Consumer used layout correctly but codegen/runtime used it wrong
3. **HEADER_MODEL_BUG**: Heap object / fat pointer layout inconsistency
4. **ABI_BOUNDARY_BUG**: FFI or call lowering convention mismatch
5. **TARGET_DESCRIPTOR_BUG**: Wrong target info (pointer size, endianness, etc.)

---

## Change Policy

**These values MUST NOT change during stabilization.**

If a bug is found:
1. File an issue with the `layout-frozen` label
2. Include the failure class
3. Include expected vs actual values
4. Include reproduction steps

Changes to frozen values require:
- Explicit sign-off from project lead
- Full test suite update
- Version bump with migration guide