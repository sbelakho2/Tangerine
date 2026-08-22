# Stabilized Subset — Frozen Layout Features

This document defines the layout-affecting features that are **FROZEN** during stabilization.
These values MUST NOT change. Any bug in these values is a bug in the layout engine.

> **The tables below are GENERATED EVIDENCE.** The machine-readable layout
> facts live in [`abi_schema.toml`](abi_schema.toml) (`[layout.frozen]`),
> rendered as [`stabilized_layout_tables.md`](stabilized_layout_tables.md)
> by `scripts/gen_spec_docs.sh`; the CI evidence-gate job regenerates and
> diff-gates the generated tables, so a stale hand-edited frozen value
> cannot merge. The tables below are kept in agreement with the generated
> document (the F-numbers match).

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
object listed. `repr_header_size` / `container_header_size` in
tg_compiler/layout_engine.tg is the single source of these numbers; the
Wave-A safe views (StrView / the source-spelled Slice) are the 8-byte
Arc-class handles to the 24-byte pinned backings.

| Container | Handle ABI (Repr) | Heap Object | Fields |
|-----------|-------------------|-------------|--------|
| String | StringPtr (8) | 32 — the OWNED String object (no inline header on the VALUE; the pointee is the stride-carrying object) | data(0), len(8), cap(16), stride(24) |
| Vec[T] / Array[T] | HeapVecHeader (8) | 32 — the stride-carrying heap vector header | data(0), len(8), cap(16), stride(24) |
| UnsafeSlice[T] (the RAW view — the explicit unsafe/FFI spelling) | Inline (16-byte fat value) | none — the non-owning borrowed `{ptr, len}` view, never a heap header | ptr(0), len(8) |
| Slice[T] (the SAFE Slice — the SOURCE-spelled shared/pinned form) | 8-byte Arc-class handle `{ inner: ArcStrong[SliceBacking[T]] }` | 24 — the pinned backing | ptr(0), len(8), offset(16) |
| Map[K,V] / HashMap[K,V] | HeapMapHeader (8) | 96 — the runtime's actual Map header (`map_header_total_size`) | buckets(0), size(8), capacity(16), key_stride(24), key_align(32), value_stride(40), value_align(48), key_off(56), value_off(64), next_off(72), bucket_stride(80), free_list(88) |
| Set[T] / HashSet[T] | HeapSetHeader (8) | 96 — Set is MAP-BACKED: the Set header IS the Map header (`_tg_set_*` tail-calls the map helpers) | same as Map |
| FixedArray[T, N] ([T; N]) | Inline (0 — part of the enclosing value) | none — inline element storage | n elements, stride = align_up(size, align); n == 0 is a legal zero-length array |
| StrView (the SAFE string view) | 8-byte Arc-class handle `{ inner: ArcStrong[StrViewBacking] }` | 24 — the pinned backing | ptr(0), len(8), offset(16) |

Historical facts REMOVED: the obsolete 48-byte Map header (hash_fn/eq_fn/aux)
and the 32-byte Set header (map/size/aux) no longer describe any layout; the
runtime Map header is the 96-byte `{buckets, size, capacity, ...}` shape, and
Set shares it. HashMap/HashSet are name-level aliases of Map/Set (same Repr,
same header). The former 24-byte `{ptr,len,cap}` Vec/Slice descriptions are
also STALE: the heap vector header is the 32-byte stride-carrying shape, the
RAW UnsafeSlice is a 16-byte inline view, and the SAFE Slice/StrView (the
source-spelled Slice[T] / StrView) are the 8-byte Arc-class handles to the
pinned backings.

## F3: Enum Layout (FROZEN)

- **Discriminant (tag)**: offset 0, size 8 bytes
- **Payload**: starts at offset 8
- **Alignment**: max of tag (8) and max payload field
- **Total size**: aligned to max alignment

```text
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

The fat-value form (the 16-byte `{ptr, len}` pair) is the RAW VIEW only —
`UnsafeSlice[T]` (`slice_view_layout`) — the explicit unsafe/FFI spelling:
```text
+------------------+------------------+
| Data Pointer (8) | Length (8)       |
+------------------+------------------+
^ offset 0         ^ offset 8
```
The SAFE views are NOT fat values: `StrView` and the source-spelled
`Slice[T]` are the 8-byte Arc-class handles
(`{ inner: ArcStrong[StrViewBacking] }` /
`{ inner: ArcStrong[SliceBacking[T]] }`) to the 24-byte pinned backings
`{ ptr@0, len@8, offset@16 }` (std/core.tg / std/collections.tg; the Wave-A
safe-view authority). The views SURVIVE their source's drop — the Arc keeps
the pinned backing alive (the backing owns; NO escape tracking, no
"eventual mechanism"). The old "StrView = 16-byte {ptr, len} fat value"
description is STALE; the 16-byte form survives only as the raw view
(UnsafeSlice) and the FFI FfiStr/FfiSlice.

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

## Current Stabilized Facts

### Adt / FixedArray forms

- `Vec[T]` and `Array[T]` are the Adt (registered container) forms of the heap
  vector: one 8-byte handle, 24-byte `{ptr, len, cap}` header.
- `[T; N]` is the distinct `Type::FixedArray` form: inline storage, count in
  the type, never a handle (F7).
- `UnsafeSlice[T]` (the RAW view — the explicit unsafe/FFI spelling) is the
  16-byte borrowed `{ptr, len}` view (`slice_view_layout`) — never a heap
  header. The SOURCE-spelled `Slice[T]` IS the SAFE shared/pinned form:
  `Slice[T] { inner: ArcStrong[SliceBacking[T]] }` — the 8-byte
  Arc-class handle to the 24-byte pinned backing
  `{ ptr @ 0, len @ 8, offset @ 16 }` (std/collections.tg; memory_model.md §9).
- `Box[T]` / `Rc[T]` are RawPtr handles with ownership (move / shared refcount).

### Ptr-based access

All raw memory access goes through `Ptr[T]` (read) and `PtrMut[T]`
(read-write): 8 bytes, no ownership, trivially copyable, no drop. `String`
exposes `as_ptr()` for its owned buffer. `StrView` is the shared/pinned
UTF-8 view: the 8-byte Arc-class handle `{ inner: ArcStrong[StrViewBacking] }`
to the 24-byte pinned byte backing `{ ptr @ 0, len @ 8, offset @ 16 }`
(std/core.tg; memory_model.md §9). Access markers (`&x` places) are checker-managed access operations and never appear
in layout tables; `&T`/`&mut T` in type position is the E106 hard error.

### LangItems

The compiler's `lang_items` TypeIds (box_, rc, vec, array, map, set, slice,
option, result) are the classification authority for the builtin compound
types: layout (type_repr), ownership (type_props_walk), and bit-copyability
(is_named_trivially_copyable) all select by LangItems id. The `slice` id IS
the RAW `UnsafeSlice` view; the SAFE source-spelled `Slice[T]` is the
std-declared shared struct and needs no LangItems entry (its layout and
ownership come from its MirTypeDef / Arc field). Name-based selection
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
  `String` HAS a drop: the MIR `DeinitPlan::String` emits `_tg_string_drop`,
  which frees BOTH the 32-byte owned String object and its buffer (real-heap
  allocation — never the bump arena; memory_model.md §9). `StrView`/`Slice`
  (the source-spelled shared forms) drop the Arc handle (the pinned backing
  is freed when the last Arc dies); `UnsafeSlice`/`CStringPtr` are the raw
  borrowed forms and own nothing.

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
  discriminant_offset, discriminant_size, payload_offset, string_abi_size
}

# Get String ABI size (F2 - FROZEN)
# String values use the raw-pointer ABI: 8 bytes, no inline header.
let str_size = string_abi_size()  # 8

# Get Vec.len offset (F2 - FROZEN)
let len_off = container_field_offset("Vec".to_string(), "length".to_string())  # 8

# Get enum tag offset (F3 - FROZEN)
let tag_off = discriminant_offset(engine, type_id)  # 0
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
