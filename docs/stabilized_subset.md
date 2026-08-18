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

## F2: Container ABI (FROZEN)

One pointer-width handle (8 bytes) per container value, pointing at the heap
header listed. `repr_header_size` / `container_header_size` in
tg_compiler/layout_engine.tg is the single source of these numbers.

| Container | Handle ABI (Repr) | Heap Header | Fields |
|-----------|-------------------|-------------|--------|
| String | StringPtr (8) | none — raw pointer to null-terminated UTF-8, NO inline header | — |
| Vec[T] / Array[T] | HeapVecHeader (8) | 24 | data(0), len(8), cap(16) |
| Slice[T] | HeapVecHeader (8) | 24 (borrowed — no ownership) | data(0), len(8), cap(16) |
| Map[K,V] / HashMap[K,V] | HeapMapHeader (8) | 24 | buckets(0), len(8), cap(16) — no hash_fn/eq_fn fields in the actual header |
| Set[T] / HashSet[T] | HeapSetHeader (8) | 24 — Set is MAP-BACKED: the Set header IS the Map header (`_tg_set_*` tail-calls the map helpers) | buckets(0), len(8), cap(16) |
| FixedArray[T, N] ([T; N]) | Inline (0 — part of the enclosing value) | none — inline element storage | n elements, stride = align_up(size, align); n == 0 is a legal zero-length array |
| StrView | Inline (16-byte fat value) | none | ptr(0), len(8) — non-owning view, trivially copyable |

Historical facts REMOVED: the obsolete 48-byte Map header (hash_fn/eq_fn/aux)
and the 32-byte Set header (map/size/aux) no longer describe any layout; the
runtime Map header is the 24-byte `{buckets, len, cap}` shape, and Set shares
it. HashMap/HashSet are name-level aliases of Map/Set (same Repr, same header).

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

Raw-pointer access is spelled `Ptr[T]` (immutable) and `PtrMut[T]` (mutable);
there is no `*const T` / `*mut T` spelling in the dialect.

| Type | Size | Ownership |
|------|------|-----------|
| Ptr[T] | 8 | none — trivially copyable, no drop, no ownership |
| PtrMut[T] | 8 | none — trivially copyable, no drop, no ownership |
| Box[T] | 8 | owns the pointee (linear; never bit-copyable) |
| Rc[T] | 8 | shared refcount (never bit-copyable) |
| fn() | 8 | none |

## F5: Fat-Value Layout (FROZEN)

The fat-value forms (a 16-byte `{ptr, len}` pair — StrView, Slice):
```
+------------------+------------------+
| Data Pointer (8) | Length (8)       |
+------------------+------------------+
^ offset 0         ^ offset 8
```
StrView is `struct StrView { ptr: Ptr[u8], len: UInt }` (std/core.tg): a
non-owning UTF-8 view, needs_drop=false and is_trivially_copyable=true by the
compiler's structural walk (Ptr + UInt fields), and MUST NOT outlive its source.

## F6: Struct Layout Rules (FROZEN)

1. **Field order**: declaration order (no reordering)
2. **Field alignment**: each field aligned to its natural alignment
3. **Struct alignment**: max of field alignments
4. **Struct size**: aligned to struct alignment

## F7: Fixed-Array Layout (FROZEN)

`[T; N]` is the distinct `Type::FixedArray(elem, n)` form — inline element
storage, never a heap handle:

- Contiguous elements
- Element stride = align_up(element_size, element_alignment)
- Total size = element_stride * count (n == 0: size 0)
- Bit-copyable exactly when the element type is (structural walk)

The named `Array[T]` syntax (the heap vector) is the Adt form with the
LangItems array id: a pointer-sized handle to a 24-byte `{ptr, len, cap}`
header (F2), never inline.

## F8: Field Offsets (REMOVED — no fallback)

The former "unknown field offset = i * 8" fallback is **REMOVED**. There is no
fallback field-offset behavior: every field offset is computed by the layout
engine from the declared fields (F6 rules), and an unknown/opaque type is an
error at its use site — never a guess. Layout information is never "missing"
for a type that passed type checking; `layout_engine.tg` computes offsets for
every struct/enum/tuple/fixed-array shape, and the MIR verifier + codegen treat
any gap as a compiler bug (ICE), not a silent offset.

---

## Current Stabilized Facts (reviewer item 120)

### Adt / FixedArray forms

- `Vec[T]` and `Array[T]` are the Adt (registered container) forms of the heap
  vector: one 8-byte handle, 24-byte `{ptr, len, cap}` header.
- `[T; N]` is the distinct `Type::FixedArray` form: inline storage, count in
  the type, never a handle (F7).
- `Slice[T]` is the borrowed heap-vector view: HeapVecHeader shape, no
  ownership (bit-copyable).
- `Box[T]` / `Rc[T]` are RawPtr handles with ownership (move / shared refcount).

### Ptr-based access

All raw memory access goes through `Ptr[T]` (read) and `PtrMut[T]`
(read-write): 8 bytes, no ownership, trivially copyable, no drop. `String`
exposes `as_ptr()` for its owned buffer; `StrView` carries `{ptr, len}` as the
non-owning view. Borrows (`&T` / `&mut T`) are checker-managed and never appear
in layout tables.

### LangItems

The compiler's `lang_items` TypeIds (box_, rc, vec, array, map, set, slice,
option, result) are the classification authority for the builtin compound
types: layout (type_repr), ownership (type_props_walk), and bit-copyability
(is_named_trivially_copyable) all select by LangItems id. Name-based selection
survives ONLY for smart pointers with no LangItems entries (UniquePtr, WeakRc,
ArcStrong, WeakArc).

### Identity system

- Semantic node ids are globally unique per program (assigned once by
  `assign_node_ids`; never re-assigned) and key every downstream map.
- DefIds = owner ModuleId + per-module symbol index — collision-free across
  files; `ResolvedNames.item_defs` records one per top-level item.
- `InstanceId` = `CallableId` (wrapping the DefId) + the concrete generic
  substitutions — the single identity of a monomorphized callee; the mangled
  emission name derives deterministically from it (`instance_key`).
- `TypeId` / `FieldId` / `VariantId` (ids.tg) identify types, struct fields and
  enum variants; MIR projections resolve fields BY `FieldId`, with the owner
  TypeId verified against the projected type.
- `fn_owner_key_of_def` renders the canonical semantic key
  (`"<module path>::<index>::<kind>"`) from the crate module table + def_kinds.

### Copy / Clone model

- **Copy** = the compiler's `is_trivially_copyable` structural property: raw
  bit-duplication is valid. The primitives, Ptr/PtrMut, and aggregates of
  trivially-copyable fields (StrView, tuples, fixed arrays of bit-copyable
  elements) are Copy. `String` and `str` are NEVER bit-copyable.
- The `Copy` trait is the source-level marker used by generic bounds on the
  raw-read APIs (get/slice/entries in std::collections); the structural
  property IS the guarantee behind it.
- **Clone** = the explicit duplication operation with a REQUIRED body (there is
  no default); it may allocate (String::clone, from_str_view, from_cstr).
- **Move** = ownership transfer, the default for non-Copy values; moves transfer
  buffers, never duplicate them.
- **Drop** = destruction via the trait method or the standalone sink `drop`.
  String/StrView have no drop: String is arena-managed, StrView owns nothing.

---

## Implementation Notes

### Where to Find These Values

All frozen values are defined in:
- `tg_compiler/layout_engine.tg` — Central layout engine (Repr table,
  repr_header_size, container_header_size/field_offset, discriminant/payload
  offsets, string_abi_size)
- `tests/layout_tests.tg` — Golden test suite verifying frozen values

### How to Use

```tangerine
use tg_compiler::layout_engine::{
  container_header_size, container_field_offset,
  discriminant_offset, discriminant_size, payload_offset
}

# Get String ABI size (F2 - FROZEN)
# String values use the raw-pointer ABI: 8 bytes, no inline header.
let str_size = string_abi_size()  # 8

# Get Vec.len offset (F2 - FROZEN)
let len_off = container_field_offset(&"Vec".to_string(), &"length".to_string())  # 8

# Get enum tag offset (F3 - FROZEN)
let tag_off = discriminant_offset(&engine, type_id)  # 0
```

### Bug Classification

When a layout bug is found, classify it using `LayoutFailureClass`:

1. **LAYOUT_COMPUTATION_BUG**: Layout engine computed wrong values
2. **LAYOUT_CONSUMER_BUG**: Consumer used layout correctly but codegen/runtime used it wrong
3. **HEADER_MODEL_BUG**: Heap object / fat-value layout inconsistency
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
