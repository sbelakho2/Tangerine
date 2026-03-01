# Tangerine Codebase Bug Report

**Date**: March 1, 2026  
**Scope**: Complete analysis of all files in tg_compiler/, std/, golden/, docs/, and root  
**Total Issues Found**: **127**

---

## Executive Summary

| Severity | Count | Description |
|----------|-------|-------------|
| **CRITICAL** | 8 | Infinite recursion, syntax errors preventing compilation |
| **HIGH** | 23 | Logic bugs, memory safety issues, undefined functions |
| **MEDIUM** | 47 | Rust-isms, incomplete implementations, inconsistencies |
| **LOW** | 49 | Style issues, missing docs, minor inconsistencies |

### Top Issues by Impact

1. **Infinite Recursion in Core Modules** (Critical): `collections.tg`, `io.tg`, `env.tg` have functions that recursively call themselves
2. **Rust Syntax in Tangerine Code** (Medium-High): Extensive use of `vec![]`, `format!()`, `println!()` macros
3. **Syntax Inconsistency** (High): Mixed `{ }` brace and `def ... end` syntax across documentation
4. **Missing Test Coverage** (Medium): Multiple golden test files lack assertions or `# expect:` directives
5. **Version/Edition Mismatch** (Medium): Some files say Edition 2025, others say 2026

---

## Fix Execution Log (Before/After Evidence)

### Completed Fixes

- [x] **Fix 1 — `std/collections.tg` recursion removed**
  - Before: wrappers called themselves (`array_get(arr, index)`, `array_new()`, `set_new()`), causing stack overflow.
  - After: wrappers delegate to explicit intrinsics (`__intrinsic_array_get`, `__intrinsic_array_new`, `__intrinsic_set_new`).
  - Evidence: [std/collections.tg](std/collections.tg#L20), [std/collections.tg](std/collections.tg#L61), [std/collections.tg](std/collections.tg#L87)

- [x] **Fix 2 — `std/io.tg` recursion removed**
  - Before: `stdin()`, `stdout()`, `stderr()`, `read_line()` called themselves or returned placeholders.
  - After: all four now delegate to intrinsics (`__intrinsic_stdin`, `__intrinsic_stdout`, `__intrinsic_stderr`, `__intrinsic_read_line`).
  - Evidence: [std/io.tg](std/io.tg#L31), [std/io.tg](std/io.tg#L38), [std/io.tg](std/io.tg#L53)

- [x] **Fix 3 — `std/env.tg` stub behavior replaced**
  - Before: `args()` always `[]`, `var()` always `None`, `current_dir()` always `"."`.
  - After: uses env intrinsics (`__intrinsic_env_args`, `__intrinsic_env_var`, `__intrinsic_env_current_dir`) and imports `IOError`.
  - Evidence: [std/env.tg](std/env.tg#L6), [std/env.tg](std/env.tg#L13), [std/env.tg](std/env.tg#L28)

- [x] **Fix 4 — stray `end` removed in MIR builder**
  - Before: unmatched `end` between `push_stmt` and `push_assign`.
  - After: functions are now contiguous with balanced block structure.
  - Evidence: [tg_compiler/mir.tg](tg_compiler/mir.tg#L475-L488)

- [x] **Fix 5 — `type_check` arity mismatch in conformance runner**
  - Before: memory path called `type_check(&ast)` while other call sites used `(ast, resolved)`.
  - After: resolves names first, then calls `type_check(&ast, &resolved)` consistently.
  - Evidence: [golden/conformance_runner.tg](golden/conformance_runner.tg#L982-L983)

- [x] **Fix 6 — unknown test directives no longer silently pass**
  - Before: unknown directives were mapped to `ExpectedOutcome::Ok`.
  - After: unknown directives now map to `ExpectedOutcome::Warning` for visibility.
  - Evidence: [golden/conformance_runner.tg](golden/conformance_runner.tg#L79-L80)

- [x] **Fix 7 — import style consistency in `trait_resolve`**
  - Before: file used `import ...` while project convention uses `use ...`.
  - After: top-level imports converted to `use`.
  - Evidence: [tg_compiler/trait_resolve.tg](tg_compiler/trait_resolve.tg#L7-L8)

- [x] **Fix 8 — FFI examples in `language.md` standardized to `def ... end`**
  - Before: brace-style examples (`extern "C" def ... { ... }`, `struct Point { ... }`).
  - After: canonical Tangerine block style (`def ... end`, `struct ... end`).
  - Evidence: [docs/language.md](docs/language.md#L599), [docs/language.md](docs/language.md#L611), [docs/language.md](docs/language.md#L636)

- [x] **Fix 9 — quick FFI examples in `ffi_cheatsheet.md` standardized**
  - Before: brace-style one-line function/struct forms.
  - After: canonical block-style forms for function and struct examples.
  - Evidence: [docs/ffi_cheatsheet.md](docs/ffi_cheatsheet.md#L27), [docs/ffi_cheatsheet.md](docs/ffi_cheatsheet.md#L46)

- [x] **Fix 10 — ABI examples in `interop.md` standardized**
  - Before: `extern "C"` and `extern "Tangerine"` showed brace-style bodies.
  - After: both examples now use canonical block style.
  - Evidence: [docs/interop.md](docs/interop.md#L64), [docs/interop.md](docs/interop.md#L78)

- [x] **Fix 11 — grammar/version consistency updates**
  - Before: grammar header said Edition 2025 and lacked block comment lexical rule.
  - After: grammar now says Edition 2026 and includes `BLOCK_COMMENT` production.
  - Evidence: [docs/grammar.md](docs/grammar.md#L2), [docs/grammar.md](docs/grammar.md#L25)

- [x] **Fix 12 — version status table updated for current edition**
  - Before: `2026` was marked Planned.
  - After: `2026` is marked Current with notes.
  - Evidence: [docs/versioning.md](docs/versioning.md#L72)

- [x] **Fix 13 — `stdlib_reference.md` struct example standardized**
  - Before: `struct User { ... }` brace form.
  - After: `struct User ... end` form.
  - Evidence: [docs/stdlib_reference.md](docs/stdlib_reference.md#L76)

- [x] **Fix 14 — binary artifact ignore rule added**
  - Before: generated `golden/smoke_test` binary was not ignored.
  - After: explicit ignore entry added.
  - Evidence: [.gitignore](.gitignore#L36)

- [x] **Fix 15 — `tg_compiler/types.tg` macro-style vector initializers replaced in core registrations**
  - Before: built-in type/trait setup used `vec![...]` macro syntax in `TypeDefKind` and method signatures.
  - After: replaced with Tangerine array literals (`[...]`) for those registration tables.
  - Evidence: [tg_compiler/types.tg](tg_compiler/types.tg#L202), [tg_compiler/types.tg](tg_compiler/types.tg#L224), [tg_compiler/types.tg](tg_compiler/types.tg#L242)

- [x] **Fix 16 — `tg_compiler/agentic.tg` macro-style vectors replaced in capability/effect bootstrap**
  - Before: capability grants and effect definitions used `vec![...]` initializers.
  - After: replaced with literal arrays (`[...]`) for `implies`, `operations`, and `param_types` values.
  - Evidence: [tg_compiler/agentic.tg](tg_compiler/agentic.tg#L326), [tg_compiler/agentic.tg](tg_compiler/agentic.tg#L474), [tg_compiler/agentic.tg](tg_compiler/agentic.tg#L475)

- [x] **Fix 17 — `std/web.tg` CORS presets no longer rely on `vec![]` + iterator/map chains**
  - Before: CORS defaults used macro/vector-chaining forms (`vec![...].iter().map(...).collect()`).
  - After: replaced with direct Tangerine-compatible array initializers.
  - Evidence: [std/web.tg](std/web.tg#L589), [std/web.tg](std/web.tg#L590), [std/web.tg](std/web.tg#L600)

- [x] **Fix 18 — `std/snapshot.tg` sized `vec![0u8; n]` buffers replaced with explicit allocation loops**
  - Before: header/event readers created byte buffers with `vec![0u8; len]` macro form.
  - After: buffers are built with `Vec::new()` plus bounded push loops, then read into.
  - Evidence: [std/snapshot.tg](std/snapshot.tg#L1155), [std/snapshot.tg](std/snapshot.tg#L1157), [std/snapshot.tg](std/snapshot.tg#L1183)

- [x] **Fix 19 — `std/db.tg` connection string builder no longer uses `format!()`**
  - Before: Postgres connection string assembly depended on Rust-style `format!(...)`.
  - After: fields are assembled via direct string concatenation and `to_string()`.
  - Evidence: [std/db.tg](std/db.tg#L893), [std/db.tg](std/db.tg#L894), [std/db.tg](std/db.tg#L900)

- [x] **Fix 20 — missing golden test expectations added for borrow/types/capabilities/budget suites**
  - Before: four golden test files lacked explicit `# expect:` directives.
  - After: each file now declares `# expect: ok` at file top.
  - Evidence: [golden/borrow_01.tg](golden/borrow_01.tg#L2), [golden/types_01.tg](golden/types_01.tg#L2), [golden/capabilities_01.tg](golden/capabilities_01.tg#L3), [golden/budget_01.tg](golden/budget_01.tg#L3)

- [x] **Fix 21 — project edition aligned to 2026 in `Tangerine.toml`**
  - Before: root project metadata still set `edition = "2025"`.
  - After: root project metadata now declares `edition = "2026"`.
  - Evidence: [Tangerine.toml](Tangerine.toml#L5)

- [x] **Fix 22 — unused import removed from `golden/frontend_06.tg`**
  - Before: `use std::fmt` import was unused.
  - After: file starts directly with module/test content and no unused import line.
  - Evidence: [golden/frontend_06.tg](golden/frontend_06.tg#L4)

- [x] **Fix 23 — registry policy edition example aligned with Edition 2026**
  - Before: registry metadata table still used edition example `"2025"`.
  - After: example now reads `"2026"`.
  - Evidence: [docs/registry_policy.md](docs/registry_policy.md#L28)

- [x] **Fix 24 — `std/ui.tg` HSLA conversion channel clamp added**
  - Before: HSLA conversion cast floating channel values directly to `u8`, which could underflow/overflow if inputs were out of expected range.
  - After: `r/g/b/a` channels are clamped to `[0.0, 255.0]` before conversion.
  - Evidence: [std/ui.tg](std/ui.tg#L78), [std/ui.tg](std/ui.tg#L81)

- [x] **Fix 25 — `conformance_runner` now guards empty type-error vectors**
  - Before: code indexed `e[0]` / `errors[0]` unconditionally, risking runtime failure on empty diagnostics.
  - After: both paths check `len() > 0` and fallback to `"unknown type error"` when empty.
  - Evidence: [golden/conformance_runner.tg](golden/conformance_runner.tg#L240), [golden/conformance_runner.tg](golden/conformance_runner.tg#L618), [golden/conformance_runner.tg](golden/conformance_runner.tg#L621)

- [x] **Fix 26 — missing agentic grammar rules added to formal grammar**
  - Before: grammar lacked explicit productions for `requires`, `budget` forms, `handle ... with` handlers, capability/effect/rationale declarations, and `unsafe "reason"`.
  - After: `docs/grammar.md` includes `fn_clause` extensions (`requires_clause`, `budget_clause`, contracts), `handle_expr`, capability/effect/rationale declarations, and `unsafe` optional reason string.
  - Evidence: [docs/grammar.md](docs/grammar.md#L127), [docs/grammar.md](docs/grammar.md#L136), [docs/grammar.md](docs/grammar.md#L336), [docs/grammar.md](docs/grammar.md#L392)

- [x] **Fix 27 — `trait_resolve` loop control keyword normalized**
  - Before: orphan-rule scan used `continue`, inconsistent with Tangerine `next` loop control.
  - After: now uses `next` in loop skip path.
  - Evidence: [tg_compiler/trait_resolve.tg](tg_compiler/trait_resolve.tg#L368)

- [x] **Fix 28 — `conformance_runner` mutation/corpus helpers migrated off `vec![]` macros**
  - Before: mutation token/literal/template tables and seed corpus used Rust-style `vec![...]` initializers.
  - After: replaced with literal array forms (`[...]`) across those helpers.
  - Evidence: [golden/conformance_runner.tg](golden/conformance_runner.tg#L651), [golden/conformance_runner.tg](golden/conformance_runner.tg#L694), [golden/conformance_runner.tg](golden/conformance_runner.tg#L736)

- [x] **Fix 29 — additional `std/db.tg` `format!()` hot paths converted to concatenation**
  - Before: several frequently used error/label paths still relied on Rust-style `format!()` (bind/type errors, column fallback names, statement naming).
  - After: these paths now use direct string concatenation and `to_string()`.
  - Evidence: [std/db.tg](std/db.tg#L64), [std/db.tg](std/db.tg#L258), [std/db.tg](std/db.tg#L621), [std/db.tg](std/db.tg#L949), [std/db.tg](std/db.tg#L1205)

- [x] **Fix 30 — `std/db.tg` query-builder and migrator `format!()` usage removed**
  - Before: query composition and migration SQL strings depended on Rust-style `format!()` throughout `QueryBuilder` and `Migrator`.
  - After: SQL fragments now use explicit string concatenation and placeholder synthesis via `to_string()`.
  - Evidence: [std/db.tg](std/db.tg#L1356), [std/db.tg](std/db.tg#L1361), [std/db.tg](std/db.tg#L1501)

- [x] **Fix 31 — `std/log.tg` file-rotation and histogram macro patterns normalized**
  - Before: file rotation used `format!("{}.{}", ...)`; histogram defaults used `vec![...]` and `vec![0; n]` macro forms.
  - After: rotation paths use direct concatenation; histogram buckets use literal arrays and counts are allocated via explicit loops.
  - Evidence: [std/log.tg](std/log.tg#L374), [std/log.tg](std/log.tg#L937), [std/log.tg](std/log.tg#L940)

- [x] **Fix 32 — `std/test_gen.tg` boundary generator macro syntax and float bounds normalized**
  - Before: `generate_boundary_values` used `vec![...]` tables and Rust-style `f64::MAX/MIN` literals.
  - After: uses literal arrays and language-consistent `Float::MAX` / `Float::MIN` strings.
  - Evidence: [std/test_gen.tg](std/test_gen.tg#L172)

- [x] **Fix 33 — `std/log.tg` trace/span hex rendering no longer depends on `format!`**
  - Before: `TraceId::to_hex` and `SpanId::to_hex` used Rust-style formatting specifiers (`{:016x}`).
  - After: both delegate to explicit fixed-width hex encoder `to_hex_fixed_u64`.
  - Evidence: [std/log.tg](std/log.tg#L528), [std/log.tg](std/log.tg#L544), [std/log.tg](std/log.tg#L550)

- [x] **Fix 34 — `docs/versioning.md` edition example aligned with current metadata**
  - Before: edition walkthrough still referenced `edition = "2025"` in `Tangerine.toml`.
  - After: edition walkthrough now references `edition = "2026"`.
  - Evidence: [docs/versioning.md](docs/versioning.md#L43)

- [x] **Fix 35 — `std/web.tg` straightforward `format!()` assembly replaced in routing/template/auth/cookie paths**
  - Before: multiple string-assembly paths used Rust-style `format!()` where direct concatenation was sufficient.
  - After: migrated these paths to concatenation (`default_error_response`, static file path construction, template end-marker/error strings, JWT concatenation, and cookie attribute assembly).
  - Evidence: [std/web.tg](std/web.tg#L443), [std/web.tg](std/web.tg#L523), [std/web.tg](std/web.tg#L824), [std/web.tg](std/web.tg#L1008), [std/web.tg](std/web.tg#L1264)

- [x] **Fix 36 — `std/snapshot.tg` checkpoint-not-found message no longer uses `format!()`**
  - Before: checkpoint lookup miss path built error text via `format!(...)`.
  - After: now uses direct concatenation for the same message.
  - Evidence: [std/snapshot.tg](std/snapshot.tg#L790)

- [x] **Fix 37 — additional parse-error message macros removed in `std/web.tg` and `std/snapshot.tg`**
  - Before: JSON parse failure paths still used Rust-style `format!()` string assembly.
  - After: both paths now concatenate prefix + `to_string()` error payload directly.
  - Evidence: [std/web.tg](std/web.tg#L82), [std/snapshot.tg](std/snapshot.tg#L1196)

- [x] **Fix 38 — remaining formatting-specifier macros removed in URL encoding and replay diff rendering**
  - Before: URL encoding used `%{:02X}` formatting; replay diff rendering used `{:?}` formatting for events.
  - After: URL encoding now uses explicit `percent_encode_byte`; replay diffs serialize events via `Json::stringify`.
  - Evidence: [std/web.tg](std/web.tg#L1228), [std/web.tg](std/web.tg#L1235), [std/snapshot.tg](std/snapshot.tg#L1344), [std/snapshot.tg](std/snapshot.tg#L1345)

- [x] **Fix 39 — targeted stdlib macro-cleanup cluster fully closed**
  - Before: the five-file high-priority Rust-ism cluster still contained scattered `format!` / `vec!` usages.
  - After: zero remaining `format!` / `vec!` matches in `std/web.tg`, `std/snapshot.tg`, `std/db.tg`, `std/log.tg`, and `std/test_gen.tg`.
  - Evidence: [std/web.tg](std/web.tg), [std/snapshot.tg](std/snapshot.tg), [std/db.tg](std/db.tg), [std/log.tg](std/log.tg), [std/test_gen.tg](std/test_gen.tg)

- [x] **Fix 40 — `std/thread.tg` `JoinHandle` now has deterministic drop cleanup**
  - Before: `JoinHandle` had no `Drop` path, so unjoined handles could leak join resources/result allocation.
  - After: `JoinHandle` tracks `joined`, `join()` marks ownership consumed, and `Drop` now joins+cleans result memory (or detaches on join failure).
  - Evidence: [std/thread.tg](std/thread.tg#L163), [std/thread.tg](std/thread.tg#L269), [std/thread.tg](std/thread.tg#L293)

- [x] **Fix 41 — `std/db.tg` SQLite error-code handling expanded beyond generic failures**
  - Before: multiple SQLite prepare/step failures collapsed into generic `QueryFailed(...)` strings with limited signal.
  - After: added `sqlite_error_from_code` mapping to classify busy/locked/constraint/io/full/readonly cases into richer `DbError` variants and applied it across raw/statement execution paths.
  - Evidence: [std/db.tg](std/db.tg#L537), [std/db.tg](std/db.tg#L558), [std/db.tg](std/db.tg#L590), [std/db.tg](std/db.tg#L790)

- [x] **Fix 42 — `std/net.tg` DNS resolution now returns contextual resolver errors**
  - Before: DNS failures returned generic strings (`"DNS resolution failed"`, `"No addresses found"`) without resolver detail.
  - After: added `gai_error_message` and host-context messages for both resolver failures and empty-result cases.
  - Evidence: [std/net.tg](std/net.tg#L598), [std/net.tg](std/net.tg#L627), [std/net.tg](std/net.tg#L653)

- [x] **Fix 43 — `std/compress.tg` zlib return-code handling expanded across raw and streaming paths**
  - Before: several init/deflate/inflate/streaming branches returned generic `StreamError` / `"inflate failed"` without mapping zlib codes.
  - After: introduced `zlib_error_from_code` and routed deflate/raw/streaming error branches through contextual code mapping (`DataError`/`BufferError`/`MemoryError`/`IoError`).
  - Evidence: [std/compress.tg](std/compress.tg#L123), [std/compress.tg](std/compress.tg#L264), [std/compress.tg](std/compress.tg#L323), [std/compress.tg](std/compress.tg#L1453), [std/compress.tg](std/compress.tg#L1562)

- [x] **Fix 44 — `std/http.tg` TCP/network failures now map to timeout/contextual connection errors**
  - Before: `tcp_connect` and socket I/O failures were surfaced with limited context and no timeout classification.
  - After: added `map_tcp_connect_error` + `map_io_error`; timeout-like failures map to `HttpError::Timeout`, and connection failures include `host:port` context.
  - Evidence: [std/http.tg](std/http.tg#L375), [std/http.tg](std/http.tg#L385), [std/http.tg](std/http.tg#L525), [std/http.tg](std/http.tg#L668), [std/http.tg](std/http.tg#L675)

- [x] **Fix 45 — `std/crypto.tg` key/decode/auth failures now carry contextual error details**
  - Before: AES/GCM and hex/base64 decode paths returned generic strings (invalid key size/padding/authentication/invalid digit) with little context.
  - After: added `crypto_error` and propagated context-rich messages including operation name, observed lengths, and decode indices/offending characters.
  - Evidence: [std/crypto.tg](std/crypto.tg#L987), [std/crypto.tg](std/crypto.tg#L1033), [std/crypto.tg](std/crypto.tg#L1108), [std/crypto.tg](std/crypto.tg#L1398), [std/crypto.tg](std/crypto.tg#L1476)

- [x] **Fix 46 — `std/http.tg` TLS handshake/read/write now surface `SSL_get_error` context**
  - Before: TLS read/write failures returned generic `"SSL read error"` / `"SSL write error"`, and handshake error detail was limited to raw code.
  - After: added `ssl_error_message` to include `SSL_get_error` (and OpenSSL error code when available) for handshake/read/write failures.
  - Evidence: [std/http.tg](std/http.tg#L724), [std/http.tg](std/http.tg#L764), [std/http.tg](std/http.tg#L781), [std/http.tg](std/http.tg#L790)

- [x] **Fix 47 — `std/db.tg` SQLite statement lifecycle paths now consistently use typed code mapping**
  - Before: several statement-level/reset/finalize/close failures still returned generic/internal errors or bind-code strings.
  - After: `close`, statement `reset`, bind failures, and `finalize` now route through `sqlite_error_from_code` for consistent typed `DbError` mapping.
  - Evidence: [std/db.tg](std/db.tg#L511), [std/db.tg](std/db.tg#L694), [std/db.tg](std/db.tg#L715), [std/db.tg](std/db.tg#L731), [std/db.tg](std/db.tg#L806)

- [x] **Fix 48 — `std/compress.tg` now maps zlib finalize/teardown return codes in raw and streaming flows**
  - Before: several success-path teardown calls (`deflateEnd` / `inflateEnd`) ignored return codes, so finalize failures were silently dropped.
  - After: raw deflate/inflate and streaming encoder/decoder finalize paths now check teardown rc and map errors through `zlib_error_from_code` with operation context.
  - Evidence: [std/compress.tg](std/compress.tg#L286), [std/compress.tg](std/compress.tg#L332), [std/compress.tg](std/compress.tg#L1501), [std/compress.tg](std/compress.tg#L1571)

- [x] **Fix 49 — `std/ffi.tg` shared/ref and exported string-out paths now guard null-pointer misuse**
  - Before: `shared_new` could dereference a null refcount allocation; `shared_clone` / `shared_drop` dereferenced `refcount` without guard; `tg_last_error_message` wrote through unvalidated output pointer; `ffi_str_to_string` accepted null pointers with non-zero length.
  - After: added explicit guards/panic-on-allocation-failure for shared refcount lifecycle, null-safe early returns for `shared_drop` and `tg_last_error_message`, and null/zero-length checks in `ffi_str_to_string`.
  - Evidence: [std/ffi.tg](std/ffi.tg#L726), [std/ffi.tg](std/ffi.tg#L736), [std/ffi.tg](std/ffi.tg#L744), [std/ffi.tg](std/ffi.tg#L791), [std/ffi.tg](std/ffi.tg#L837)

- [x] **Fix 50 — `std/alloc.tg` arena allocator now validates alignment/null/overflow before pointer math**
  - Before: arena allocation accepted zero-size/invalid alignment and performed offset arithmetic without explicit overflow guards; reset semantics lacked destroyed-buffer safety guard.
  - After: `ArenaAllocator::allocate` now rejects zero-size, null/empty arena state, invalid alignment, and offset/end overflow; `arena_reset` now safely handles destroyed/empty arenas.
  - Evidence: [std/alloc.tg](std/alloc.tg#L192), [std/alloc.tg](std/alloc.tg#L208)

### Re-validated Findings (Not a code defect)

- [x] **`replace_first_matching` undefined** — Re-checked and found valid method calls on `String`; no missing symbol in this usage path.
  - Evidence: [golden/conformance_runner.tg](golden/conformance_runner.tg#L691), [golden/conformance_runner.tg](golden/conformance_runner.tg#L697)

- [x] **`golden/stdlib_tests.tg` duplicate generic helper claim** — Re-checked and found single definitions only for each helper (`identity[T]`, `max_of[T: Ord]`).
  - Evidence: [golden/stdlib_tests.tg](golden/stdlib_tests.tg#L554), [golden/stdlib_tests.tg](golden/stdlib_tests.tg#L558)

- [x] **`golden/diagnostics_quality.tg` unclosed block fixture** — Re-checked and confirmed intentional parse-error test case (`# expect: parse_error`), not an accidental broken file.
  - Evidence: [golden/diagnostics_quality.tg](golden/diagnostics_quality.tg#L105), [golden/diagnostics_quality.tg](golden/diagnostics_quality.tg#L107)

---

## CRITICAL Issues (8)

### 1. Infinite Recursion in collections.tg

**File**: [std/collections.tg](std/collections.tg#L44-L52)  
**Category**: Logic Bug / Stack Overflow  
**Lines**: 44-52, 65-67, 69-71

```tangerine
def array_get[T](arr: &Array[T], index: Int) -> &T
  # Compiler intrinsic
  array_get(arr, index)  # ← CALLS ITSELF!
end

def array_new[T]() -> Array[T]
  # Compiler intrinsic
  array_new()  # ← CALLS ITSELF!
end

def set_new[T]() -> Set[T]
  set_new()  # ← CALLS ITSELF!
end
```

**Impact**: Any use of collections will cause stack overflow.  
**Fix**: Replace with proper compiler intrinsic invocation or `@intrinsic` attribute.

---

### 2. Infinite Recursion in io.tg

**File**: [std/io.tg](std/io.tg#L31-L43)  
**Category**: Logic Bug / Stack Overflow  
**Lines**: 31-43

```tangerine
def stdin() -> Stdin
  # Compiler intrinsic
  stdin()  # ← CALLS ITSELF!
end

def stdout() -> Stdout
  # Compiler intrinsic
  stdout()  # ← CALLS ITSELF!
end

def stderr() -> Stderr
  # Compiler intrinsic
  stderr()  # ← CALLS ITSELF!
end
```

**Impact**: Any I/O operation will cause stack overflow.  
**Fix**: Use `@intrinsic` attribute or proper intrinsic call syntax.

---

### 3. Stub Functions in env.tg Return Empty Values

**File**: [std/env.tg](std/env.tg#L1-L22)  
**Category**: Incomplete Implementation  

```tangerine
def args() -> Array[String]
  []  # Always returns empty array!
end

def var(name: String) -> Option[String]
  Option::None  # Always returns None!
end

def current_dir() -> Result[String, IOError]
  Result::Ok(".")  # Always returns "."!
end
```

**Impact**: All command-line argument parsing and environment variable access silently fails.  
**Fix**: Implement proper FFI calls to libc `getenv`, `getcwd`, etc.

---

### 4. Syntax Mixing in language.md

**File**: [docs/language.md](docs/language.md#L576-L600)  
**Category**: Documentation Error  

FFI examples use `{ }` brace syntax:
```tangerine
extern "C" def add(a: Int, b: Int) -> Int { a + b }
```

But standard Tangerine uses `def ... end`:
```tangerine
def add(a: Int, b: Int) -> Int
  a + b
end
```

**Impact**: Users will be confused about correct syntax.  
**Fix**: Decide on one syntax and update all documentation consistently.

---

### 5. Stray `end` Keyword in mir.tg

**File**: [tg_compiler/mir.tg](tg_compiler/mir.tg#L460)  
**Category**: Syntax Error  

```tangerine
  push_stmt(&mut func.blocks[current_block], stmt)
end  # ← Stray `end` without matching block!
```

**Impact**: File may not compile correctly.  
**Fix**: Remove stray `end` or restructure code.

---

### 6. Block Comment Syntax Undefined

**File**: [docs/language.md](docs/language.md#L16-L22)  
**Category**: Grammar Inconsistency  

Shows `#| ... |#` for block comments but [grammar.md](docs/grammar.md) doesn't define this syntax.

**Impact**: Grammar spec is incomplete.  
**Fix**: Add block comment rule to grammar.md Section 1.

---

### 7. Undefined Functions in conformance_runner.tg

**File**: [golden/conformance_runner.tg](golden/conformance_runner.tg#L556-L563)  
**Category**: Missing Implementation  

```tangerine
def mutate_replace_identifier(source: &String) -> String
  replace_first_matching(source, identifier_pattern, "MUTATED_IDENT")  # ← Not defined!
end

def mutate_replace_literal(source: &String) -> String
  replace_first_matching(source, literal_pattern, "999")  # ← Not defined!
end
```

**Impact**: Mutation testing features don't work.  
**Fix**: Implement `replace_first_matching` function or import from std::regex.

---

### 8. Inconsistent `type_check` Arity in conformance_runner.tg

**File**: [golden/conformance_runner.tg](golden/conformance_runner.tg#L760)  
**Category**: API Mismatch  

```tangerine
# Line ~170: type_check(&ast, &resolved) — 2 arguments
# Line ~760: type_check(&ast) — 1 argument
```

**Impact**: One of these calls will fail at runtime.  
**Fix**: Ensure consistent function signature.

---

## HIGH Priority Issues (23)

### Rust Macro Syntax Used Throughout (resolved in targeted files)

The originally flagged five-file set has been remediated via Fixes 15–20, 29–33, and 35–38.

| File | Current |
|------|---------|
| [tg_compiler/types.tg](tg_compiler/types.tg#L202) | Macro-style table initializers removed |
| [tg_compiler/agentic.tg](tg_compiler/agentic.tg#L326) | Macro-style capability/effect initializers removed |
| [std/web.tg](std/web.tg#L589) | `vec![]` CORS initializers removed; no remaining `format!` in file |
| [std/snapshot.tg](std/snapshot.tg#L1155) | Sized `vec!` allocation removed; no remaining `format!` in file |
| [std/db.tg](std/db.tg#L893) | Query/migration/error `format!` usage removed |

**Fix**: Replace `vec![]` with `Array::new()` + `.push()` or array literal `[a, b, c]`.  
**Fix**: Replace `format!()` with string concatenation or a Tangerine interpolation syntax.

---

### Missing Test Assertions (resolved)

All four files now include explicit expected outcomes (`# expect: ok`) via Fix 20.

| File | Current |
|------|---------|
| [golden/borrow_01.tg](golden/borrow_01.tg#L2) | `# expect: ok` present |
| [golden/types_01.tg](golden/types_01.tg#L2) | `# expect: ok` present |
| [golden/capabilities_01.tg](golden/capabilities_01.tg#L3) | `# expect: ok` present |
| [golden/budget_01.tg](golden/budget_01.tg#L3) | `# expect: ok` present |

---

### Memory Safety Issues (partially resolved)

| File | Line | Current |
|------|------|---------|
| [std/ffi.tg](std/ffi.tg#L726) | ~726 | Partially resolved: shared/refcount lifecycle + exported string-out null guards added; broader raw-pointer audit still open |
| [std/thread.tg](std/thread.tg#L160) | ~160 | Resolved: `JoinHandle` now has guarded `Drop` cleanup |
| [std/alloc.tg](std/alloc.tg#L208) | ~208 | Partially resolved: arena allocate/reset now guard null/invalid-align/overflow; bump-allocation semantics remain intentional |
| [std/ui.tg](std/ui.tg#L78) | ~78 | Resolved: HSLA conversion channels clamped before cast |

---

### Incomplete Trait Implementations (resolved / revalidated)

| File | Current |
|------|---------|
| [tg_compiler/trait_resolve.tg](tg_compiler/trait_resolve.tg#L7-L8) | Resolved: imports normalized to `use` |
| [tg_compiler/trait_resolve.tg](tg_compiler/trait_resolve.tg#L368) | Resolved: `continue` normalized to `next` |
| [tg_compiler/trait_resolve.tg](tg_compiler/trait_resolve.tg#L341) | Revalidated: `++` is used consistently as in-file string concatenation style |

---

### Documentation Brace Syntax Inconsistency (resolved)

All four originally flagged docs were standardized to canonical block style in Fixes 8–10 and 13.

| File | Current |
|------|---------|
| [docs/ffi_cheatsheet.md](docs/ffi_cheatsheet.md#L27) | Canonical `def ... end` / `struct ... end` style |
| [docs/interop.md](docs/interop.md#L64) | ABI examples in canonical block style |
| [docs/stdlib_reference.md](docs/stdlib_reference.md#L76) | Struct example in block form |
| [docs/language.md](docs/language.md#L599) | FFI examples in canonical block style |

---

### Missing ARM64 Code Generation (3 issues)

| File | Line | Issue |
|------|------|-------|
| [tg_compiler/codegen.tg](tg_compiler/codegen.tg#L1200) | ~1200 | ARM64 register definitions incomplete |
| [tg_compiler/codegen.tg](tg_compiler/codegen.tg#L1400) | ~1400 | ARM64 instruction encoding gaps |
| [tg_compiler/asm.tg](tg_compiler/asm.tg#L600) | ~600 | ARM64 assembler has fewer instructions than x86-64 |

---

## MEDIUM Priority Issues (47)

### Version/Edition Inconsistencies (resolved)

All previously flagged edition/version mismatches in this section were resolved in Fixes 11, 12, 21, 23, and 34.

| File | Current |
|------|---------|
| [docs/grammar.md](docs/grammar.md#L2) | Edition 2026 |
| [docs/versioning.md](docs/versioning.md#L72) | 2026 marked Current |
| [docs/registry_policy.md](docs/registry_policy.md#L28) | `edition = "2026"` example |
| [Tangerine.toml](Tangerine.toml#L5) | `edition = "2026"` |
| [docs/interop.md](docs/interop.md#L47) | ABI Edition 2026 |

---

### Duplicate Function Definitions (revalidated)

| File | Functions | Issue |
|------|-----------|-------|
| [golden/stdlib_tests.tg](golden/stdlib_tests.tg#L554-L558) | `identity[T]`, `max_of[T]` | Revalidated single definitions (not duplicated) |
| [golden/diagnostics_quality.tg](golden/diagnostics_quality.tg#L88-L95) | `dup_func()` | Intentional duplicate for testing |

---

### Missing Error Handling (partially resolved)

| File | Line | Current |
|------|------|---------|
| [golden/conformance_runner.tg](golden/conformance_runner.tg#L240) | ~240 | Resolved: empty-error vector guarded (Fix 25) |
| [std/http.tg](std/http.tg#L724) | ~724 | Partially resolved: TCP timeout/classification + TLS handshake/read/write now include contextual SSL error codes |
| [std/crypto.tg](std/crypto.tg#L987) | ~987 | Partially resolved: AES/GCM + decode paths now emit contextual errors; broader crypto API unification still open |
| [std/db.tg](std/db.tg#L537) | ~537 | Partially resolved: SQLite code mapping now covers prepare/step plus statement reset/bind/finalize/close paths |
| [std/compress.tg](std/compress.tg#L123) | ~123 | Partially resolved: zlib error-code mapping now covers deflate/raw/streaming failures plus raw/streaming finalize teardown paths |
| [std/net.tg](std/net.tg#L627) | ~627 | Partially resolved: DNS failures now include host + resolver error string |

---

### Hardcoded Platform-Specific Values (8 issues)

| File | Line | Issue |
|------|------|-------|
| [std/thread.tg](std/thread.tg#L50) | ~50 | Hardcoded pthread struct sizes (Linux-specific) |
| [std/time.tg](std/time.tg#L100) | ~100 | Clock IDs hardcoded for POSIX |
| [std/fs.tg](std/fs.tg#L200) | ~200 | Path separator hardcoded as `/` |
| [std/net.tg](std/net.tg#L100) | ~100 | Socket constants for Linux |
| [std/cli.tg](std/cli.tg#L300) | ~300 | Terminal control codes for Unix |
| [tg_compiler/object.tg](tg_compiler/object.tg#L100) | ~100 | ELF magic numbers |
| [tg_compiler/linker.tg](tg_compiler/linker.tg#L200) | ~200 | Default library paths for Linux |
| [std/profile.tg](std/profile.tg#L400) | ~400 | /proc/self/maps (Linux-specific) |

---

### API Inconsistencies (10 issues)

| Issue | Files | Description |
|-------|-------|-------------|
| Error type mismatch | std/db.tg, std/http.tg | `DbError` vs `HttpError` have different structures |
| Result vs Option | std/collections.tg | Some functions return `Option`, others `Result` |
| Reference types | std/ | Mixed `&T` and `T` for similar operations |
| Generic bounds | Multiple | Missing `Clone` bounds on some generic returns |
| Naming | std/ | `new()` vs `create()` vs `open()` inconsistent |
| Method receivers | std/ | `self` vs `&self` vs `&mut self` inconsistent |
| Async support | std/http.tg, std/db.tg | Some APIs async, some sync |
| Iterator patterns | std/collections.tg | `iter()` vs `into_iter()` inconsistent |
| Builder patterns | std/http.tg, std/db.tg | Some use builders, some don't |
| String handling | Multiple | `String` vs `&str` vs `&String` mixed |

---

### Missing Grammar Rules (resolved)

All six originally flagged grammar gaps were addressed by grammar updates in Fixes 11 and 26.

| Feature | Current Status |
|---------|----------------|
| `unsafe "reason"` | Explicit optional reason modeled in grammar |
| Block comments `#\| \|#` | `BLOCK_COMMENT` lexical production present |
| Budget expressions | `budget_clause` / `budget_entry` rules present |
| Effect handlers | `handle_expr` and `handler_arm` rules present |
| Capability grants | `requires_clause` and `capability_decl` rules present |
| Rationale blocks | `rationale_block` and `rationale_field` rules present |

---

### Incomplete Pattern Matching (5 issues)

| File | Line | Issue |
|------|------|-------|
| [tg_compiler/types.tg](tg_compiler/types.tg#L800) | ~800 | Match doesn't cover all Type variants |
| [tg_compiler/mir.tg](tg_compiler/mir.tg#L2000) | ~2000 | Missing MirInstr cases |
| [tg_compiler/codegen.tg](tg_compiler/codegen.tg#L1000) | ~1000 | Not all MIR ops have codegen |
| [std/json.tg](std/json.tg#L400) | ~400 | JSON value types partially covered |
| [std/toml.tg](std/toml.tg#L300) | ~300 | TOML datetime parsing incomplete |

---

### Test File Issues (resolved / reclassified)

| File | Current |
|------|---------|
| [golden/smoke_test](golden/smoke_test) | Ignored via [.gitignore](.gitignore#L36) |
| [golden/diagnostics_quality.tg](golden/diagnostics_quality.tg#L105) | Intentional parse-error fixture (`# expect: parse_error`) |
| [golden/conformance_runner.tg](golden/conformance_runner.tg#L80) | Unknown directives now map to warning |
| [golden/frontend_06.tg](golden/frontend_06.tg#L4) | Unused import removed |

---

## LOW Priority Issues (49)

### Naming Convention Issues (10)

| File | Issue |
|------|-------|
| Multiple files | Mixed `snake_case` and `camelCase` |
| std/crypto.tg | `SHA256` vs `sha256` function names |
| std/http.tg | `HttpClient` vs `http_client` |
| tg_compiler/types.tg | `TypeKind` vs `type_kind` |

### Missing Documentation Comments (15)

| Module | Coverage |
|--------|----------|
| std/collections.tg | No doc comments |
| std/env.tg | No doc comments |
| std/io.tg | No doc comments |
| std/ffi.tg | Partial |
| tg_compiler/asm.tg | Minimal |
| tg_compiler/object.tg | Partial |
| golden/*.tg | Most lack file-level docs |

### Cosmetic/Style Issues (12)

- Extra blank lines in various files
- Inconsistent indentation (tabs vs spaces) in some places
- Long lines exceeding 100 characters
- Missing trailing newlines

### Minor Test Coverage Gaps (12)

| Test File | Missing Coverage |
|-----------|------------------|
| [golden/borrow_01.tg](golden/borrow_01.tg) | Double mutable borrow, dangling reference |
| [golden/types_01.tg](golden/types_01.tg) | Trait implementation, associated types |
| [golden/mir_01.tg](golden/mir_01.tg) | Optimization passes |
| [golden/ssa_01.tg](golden/ssa_01.tg) | Phi node insertion edge cases |

---

## Recommendations (Priority Order)

### Immediate (High)

1. **Harden FFI/thread/allocator memory-safety edges** — Audit remaining raw-pointer/null-check paths in [std/ffi.tg](std/ffi.tg), and clarify/guard arena reset semantics in [std/alloc.tg](std/alloc.tg).
2. **Close remaining error-handling gaps** — Improve error mapping/propagation in [std/http.tg](std/http.tg), [std/crypto.tg](std/crypto.tg), [std/db.tg](std/db.tg), [std/compress.tg](std/compress.tg), and [std/net.tg](std/net.tg).
3. **Address platform hardcoding risks** — Replace fixed Linux/POSIX assumptions with explicit platform gates or runtime adaptation in thread/time/fs/net/linker/profile paths.

### Short-Term (High)

4. **Expand architecture coverage** — Improve ARM64 codegen/assembler parity in [tg_compiler/codegen.tg](tg_compiler/codegen.tg) and [tg_compiler/asm.tg](tg_compiler/asm.tg).
5. **Improve exhaustiveness checks** — Fill known pattern-match coverage gaps in compiler and parsers (`types`, `mir`, `codegen`, `json`, `toml`).
6. **Prioritize regression tests for recent fixes** — Add targeted golden/runtime tests for thread handle drop behavior, env/io/collections intrinsic wrappers, and grammar agentic forms.

### Medium-Term (Medium)

7. **Unify API surface conventions** — Rationalize `Result`/`Option`, naming, receiver style, and async/sync consistency across std modules.
8. **Add explicit portability strategy** — Document supported targets and add CI matrix checks for Linux/macOS/ARM64 where applicable.

### Long-Term (Low)

9. **Documentation cleanup** — Add missing API docs and module-level rationale where absent.
10. **Style consistency** — Run formatter/lint passes once semantic churn stabilizes.
11. **Coverage expansion** — Add edge-case tests for borrow/type/MIR/SSA scenarios listed above.

---

## Files Analyzed

### tg_compiler/ (19 files)
- [x] agentic.tg
- [x] asm.tg
- [x] ast.tg
- [x] borrow_check.tg
- [x] codegen.tg
- [x] docgen.tg
- [x] driver.tg
- [x] formatter.tg
- [x] lexer.tg
- [x] lib.tg
- [x] linker.tg
- [x] linter.tg
- [x] mir.tg
- [x] object.tg
- [x] parser.tg
- [x] resolver.tg
- [x] token.tg
- [x] trait_resolve.tg
- [x] types.tg

### std/ (36 files)
- [x] alloc.tg
- [x] async.tg
- [x] backtrace.tg
- [x] bench.tg
- [x] budget.tg
- [x] capabilities.tg
- [x] cli.tg
- [x] collections.tg
- [x] compress.tg
- [x] contracts.tg
- [x] core.tg
- [x] crypto.tg
- [x] db.tg
- [x] effects.tg
- [x] env.tg
- [x] ffi.tg
- [x] fmt.tg
- [x] fs.tg
- [x] http.tg
- [x] io.tg
- [x] json.tg
- [x] log.tg
- [x] net.tg
- [x] profile.tg
- [x] regex.tg
- [x] semantic_diff.tg
- [x] serde.tg
- [x] snapshot.tg
- [x] test_gen.tg
- [x] test.tg
- [x] thread.tg
- [x] time.tg
- [x] toml.tg
- [x] ui.tg
- [x] url.tg
- [x] web.tg

### golden/ (17 files)
- [x] agentic_combined.tg
- [x] borrow_01.tg
- [x] budget_01.tg
- [x] capabilities_01.tg
- [x] conformance_runner.tg
- [x] contracts_01.tg
- [x] diagnostics_quality.tg
- [x] frontend_01-06.tg (6 files)
- [x] mir_01.tg
- [x] rationale_01.tg
- [x] simple_test.tg
- [x] smoke_test / smoke_test.tg
- [x] ssa_01.tg
- [x] stdlib_tests.tg
- [x] types_01.tg

### docs/ (10 files)
- [x] ffi_cheatsheet.md
- [x] grammar.md
- [x] interop.md
- [x] language.md
- [x] registry_policy.md
- [x] rfc_process.md
- [x] stdlib_reference.md
- [x] style_guide.md
- [x] unicode_policy.md
- [x] versioning.md

### Root Files (4 files)
- [x] COMPLETENESS_REPORT.md
- [x] SECURITY.md
- [x] Tangerine.toml
- [x] needed.txt

---

**Report Generated**: March 1, 2026  
**Total Files Analyzed**: 86  
**Analyzer**: Comprehensive automated + manual verification
