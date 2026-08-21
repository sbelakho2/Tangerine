# Stabilized Layout Tables — FROZEN (generated)

> **GENERATED EVIDENCE — do not edit by hand.** These tables are rendered
> by `scripts/gen_spec_docs.sh` from the `[layout.frozen]` section of
> [`abi_schema.toml`](abi_schema.toml), the machine-readable layout facts
> (the layout authority: tg_compiler/layout_engine.tg + the Wave-A
> shared/pinned safe views in std/core.tg + std/collections.tg +
> memory_model.md §9). The CI evidence-gate job regenerates them and
> runs `git diff --exit-code` — a stale hand-edited frozen value cannot
> merge. The values MUST NOT change during stabilization (stabilized_subset.md
> change policy); any bug in these values is a bug in the layout engine.

## F1: Primitive Sizes (FROZEN)

| Type | Size (bytes) | Alignment |
|---|---|---|
| Unit | 0 | 1 |
| Bool | 1 | 1 |
| Char | 4 | 4 |
| Int / UInt | 8 | 8 |
| Float (f64) | 8 | 8 |
| f32 | 4 | 4 |
| i8 / u8 | 1 | 1 |
| i16 / u16 | 2 | 2 |
| i32 / u32 | 4 | 4 |
| i64 / u64 | 8 | 8 |
| i128 / u128 | 16 | 16 |
| isize / usize | 8 | 8 |

## F2: Container / Value ABI (FROZEN)

One pointer-width handle (8 bytes) per container value, pointing at the
heap object listed. The sizes are the layout engine's
(`string_handle_layout_size` / `owned_string_object_size` /
`container_header_size` / `map_header_total_size`).

| Type | Handle ABI (Repr) | Handle size | Heap object size | Fields | Ownership | Copy op | Drop | Note |
|---|---|---|---|---|---|---|---|---|
| String | StringPtr (8) | 8 | 32 | data@0, len@8, cap@16, stride@24 | owned — the 8-byte handle points at the 32-byte OwnedStringObject; data points to the null-terminated UTF-8 buffer | clone (never bit-copyable) | MIR DeinitPlan::String -> _tg_string_drop (frees the object AND the buffer; real-heap allocation, never the bump arena) | the OLD 'no inline header' description is WRONG — the handle points at the 32-byte owned String object (memory_model.md §9) |
| Vec[T] / Array[T] | HeapVecHeader (8) | 8 | 32 | data@0, len@8, cap@16, stride@24 | owned — the heap vector (the named Array[T] syntax IS the Vec Adt form) | move + clone | the element buffer is released by the runtime | the 24-byte {ptr,len,cap} header is STALE — the current header is the stride-carrying 32-byte shape (the stride is the runtime's element-addressing authority) |
| Map[K,V] / HashMap[K,V] | HeapMapHeader (8) | 8 | 96 | buckets@0, size@8, capacity@16, key_stride@24, key_align@32, value_stride@40, value_align@48, key_off@56, value_off@64, next_off@72, bucket_stride@80, free_list@88 | owned | move + clone | the runtime map helpers | the 24-byte {buckets,len,cap} header is STALE — the runtime's Map header is the 96-byte raw arena + the concrete layout parameters (map_header_total_size); the canonical offsets are MAP_HEADER_FIELDS in layout_engine.tg |
| Set[T] / HashSet[T] | HeapSetHeader (8) | 8 | 96 | the SAME 96-byte map header (Set is map-backed — the _tg_set_* helpers tail-call the map helpers) | owned | move + clone | the runtime set helpers | HashMap/HashSet are name-level aliases of Map/Set (same Repr, same header) |
| FixedArray[T, N] ([T; N]) | Inline (0 — part of the enclosing value) | 0 | n * stride | n elements, stride = align_up(element_size, element_alignment) | the enclosing value | structural | element-wise | n == 0 is a legal zero-length array |
| UnsafeSlice[T] (the raw view) | Inline (16-byte fat value {ptr@0, len@8}) | 16 | none — the non-owning borrowed view | ptr@0, len@8 | none — borrowed, trivially copyable, no drop | bit | none | the compiler-scoped Slice[T] view (slice_view_layout); the unsafe/FFI-only form, NEVER a heap header |
| SharedSlice[T] (the SAFE Slice) | 8-byte Arc-class handle { inner: ArcStrong[SliceBacking[T]] } | 8 | 24 | the pinned backing SliceBacking[T] = { ptr@0, len@8, offset@16 } | shared — the Arc keeps the pinned backing alive; the view SURVIVES its source's drop | the Arc-class clone | the Arc drop | the Wave-A safe-view authority (std/collections.tg; memory_model.md §9) — source-spelled Slice[T] is this shared/pinned form |
| StrView (the SAFE string view) | 8-byte Arc-class handle { inner: ArcStrong[StrViewBacking] } | 8 | 24 | the pinned backing StrViewBacking = { ptr@0, len@8, offset@16 } | shared — the Arc keeps the pinned backing alive; the view SURVIVES its source's drop and its String's growth | the Arc-class clone | the Arc drop | the Wave-A safe-view authority (std/core.tg; memory_model.md §9) — the OLD 16-byte {ptr,len} fat-value description is STALE for the source-level StrView; the 16-byte form survives only as the internal raw view (UnsafeSlice) and the FFI FfiStr/FfiSlice |
| CStringPtr | 8-byte raw pointer | 8 | none | — | borrowed — the raw pointer to NUL-terminated bytes | bit | none | the borrowed c-string form |

## F3: Enum Layout (FROZEN)

- **Discriminant (tag)**: offset 0, size 8 bytes
- **Payload**: starts at offset 8
- **Alignment**: max of tag (8) and max payload field
- **Total size**: aligned to max alignment
- Rule: the discriminant (tag) sits at offset 0 with size 8; the payload starts at offset 8; the alignment is max(tag alignment, max payload field alignment); the total size is aligned to the max alignment

## F4: Pointer Sizes (FROZEN)

Raw-pointer access is spelled `Ptr[T]` (immutable) and `PtrMut[T]`
(mutable); there is no `*const T` / `*mut T` spelling in the dialect.

| Type | Size | Ownership | Spelling |
|---|---|---|---|
| Ptr[T] | 8 | none — trivially copyable, no drop | immutable raw-pointer access (no *const T spelling in the dialect) |
| PtrMut[T] | 8 | none — trivially copyable, no drop | mutable raw-pointer access (no *mut T spelling in the dialect) |
| Box[T] | 8 | owns the pointee (linear; never bit-copyable) | — |
| Rc[T] | 8 | shared refcount (never bit-copyable) | — |
| fn() | 8 | none | — |

## F5: The Fat-Value Forms (FROZEN)

The 16-byte `{ptr, len}` fat value is the RAW VIEW form only (`UnsafeSlice[T]` — `slice_view_layout`):

```text
+------------------+------------------+
| Data Pointer (8) | Length (8)       |
+------------------+------------------+
^ offset 0         ^ offset 8
```

The SAFE views (the Wave-A safe-view authority) are the Arc-class
handles to the pinned backings — 8-byte handles, NOT fat values:

- `StrView` = `{ inner: ArcStrong[StrViewBacking] }` (8 bytes) -> the
  24-byte pinned `StrViewBacking` `{ ptr@0, len@8, offset@16 }`
  (std/core.tg). The view SURVIVES its source's drop and its String's
  growth (the Arc keeps the pinned backing alive).
- `SharedSlice[T]` = `{ inner: ArcStrong[SliceBacking[T]] }` (8 bytes) ->
  the 24-byte pinned `SliceBacking[T]` `{ ptr@0, len@8, offset@16 }`
  (std/collections.tg). The view SURVIVES its source's drop.

## F6: Struct Layout Rules (FROZEN)

1. field order: declaration order (no reordering)
2. field alignment: each field aligned to its natural alignment
3. struct alignment: max of the field alignments
4. struct size: aligned to the struct alignment

## F7: Fixed-Array Layout (FROZEN)

`Type::FixedArray(elem, n) — the [T; N] annotation, distinct from the heap vector` — inline element storage, never a heap handle:
- Element stride = align_up(element_size, element_alignment)
- Total size = element_stride * count (n == 0: size 0, a legal zero-length fixed array)
- Bit-copyable exactly when the element type is (exactly when the element type is (structural walk))
- Note: the named Array[T] syntax is the Adt (heap vector) form, never inline

## The FFI-opaque alignment table (FROZEN)

``PthreadT`, `PthreadAttrT`, `PthreadMutexT`, `PthreadCondT`, `PthreadBarrierT``: the [u8; N] pthread opaques keep their byte SIZE but take the native C ALIGNMENT — the target pointer alignment (8 on both supported targets) — via ffi_opaque_native_align; a PthreadMutexT local can never land at a misaligned offset

## The removed fallback (F8)

The former "unknown field offset = i * 8" fallback is REMOVED: every field
offset is computed by the layout engine from the declared fields (F6);
an unknown/opaque type is an error at its use site — never a guess
(stabilized_subset.md F8).

---

*Generated from `docs/current/abi_schema.toml` (`[layout.frozen]`).*
