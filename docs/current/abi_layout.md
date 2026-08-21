# Tangerine ABI Layout — the FFI C-Type Mapping Tables (generated)

> **GENERATED EVIDENCE — do not edit by hand.** This document is
> rendered by `scripts/gen_spec_docs.sh` from
> [`abi_schema.toml`](abi_schema.toml), the machine-readable FFI/layout
> facts: the C type -> the Tangerine type -> size -> alignment ->
> direction. The CI evidence-gate job regenerates it and runs
> `git diff --exit-code` — a stale hand-edited layout fact cannot merge.

## The direction legend

- `in` — a C-argument crossing (C -> Tangerine)
- `out` — a C-return / export value crossing (Tangerine -> C)
- `in/out` — both directions legal
- `none` — NOT an FFI boundary type

## The C type mappings

| C type | Tangerine type | Size | Alignment | Direction | Note |
|---|---|---|---|---|---|
| `int8_t` | I8 / i8 | 1 | 1 | in/out | FFI-safe scalar |
| `uint8_t` | U8 / u8 | 1 | 1 | in/out | FFI-safe scalar |
| `int16_t` | I16 / i16 | 2 | 2 | in/out | FFI-safe scalar |
| `uint16_t` | U16 / u16 | 2 | 2 | in/out | FFI-safe scalar |
| `int32_t` | I32 / i32 | 4 | 4 | in/out | FFI-safe scalar |
| `uint32_t` | U32 / u32 | 4 | 4 | in/out | FFI-safe scalar |
| `int64_t` | I64 / i64 / Int | 8 | 8 | in/out | FFI-safe scalar; Int is the i64 alias |
| `uint64_t` | U64 / u64 / UInt | 8 | 8 | in/out | FFI-safe scalar; UInt is the u64 alias |
| `intptr_t / size_t` | ISize / USize | 8 | 8 | in/out | pointer-sized on both supported targets |
| `uint8_t (0/1)` | Bool | 1 | 1 | in/out | the C bool is the uint8_t 0/1 convention |
| `float` | F32 / f32 | 4 | 4 | in/out | FFI-safe scalar |
| `double` | F64 / f64 / Float | 8 | 8 | in/out | FFI-safe scalar; Float is the f64 alias |
| `T*` | Ptr[T] (read) / PtrMut[T] (write) | 8 | 8 | in/out | raw pointer: no ownership, trivially copyable |
| `struct { const uint8_t* ptr; size_t len; }` | FfiStr | 16 | 8 | in | the FFI string view {ptr@0, len@8}; String is NOT FFI-safe — use FfiStr |
| `struct { const T* ptr; size_t len; }` | FfiSlice[T] | 16 | 8 | in | the FFI slice view {ptr@0, len@8}; Array[T]/Vec[T] are NOT FFI-safe — use FfiSlice |
| `struct { uint8_t ok; int32_t err_code; T value; }` | TgResult[T] | 16 + sizeof(T) | max(8, align(T)) | out | the FFI result struct: ok@0, err_code@4, value@8 |
| `tg_str` | tg_str (the runtime export form) | 16 | 8 | out | the runtime's exported {ptr, len} string form (tg_last_error_message) |
| `@repr(C) struct` | struct Name ... end (with the @repr(C) attribute) | varies | varies | in/out | declaration-order fields, natural alignment (F6) |
| `String` | String | not FFI-safe | not FFI-safe | none | ✗ — the owned String is not an FFI boundary type; use FfiStr |
| `Array[T]` | Vec[T] / Array[T] | not FFI-safe | not FFI-safe | none | ✗ — the heap vector is not an FFI boundary type; use FfiSlice[T] |

## The FFI-safe rule

`String` and `Array[T]`/`Vec[T]` are NOT FFI boundary types: the owned
String crosses as `FfiStr` and the heap vector crosses as `FfiSlice[T]`.
All data crossing FFI boundaries is auto-wrapped in `Tainted[T]` in the
strict/production/hardened modes (ffi_cheatsheet.md).

---

*Generated from `docs/current/abi_schema.toml`.*
