# Changelog

All notable changes to the Tangerine project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) as
described in [docs/versioning.md](docs/versioning.md).

## [Unreleased]

### Added
- `std/unicode.tg`: Unicode normalization (NFC/NFD/NFKC/NFKD), character properties, grapheme iteration, display width, and collation (GAP-001)
- `std/locale.tg`: Locale support with BCP 47 tags, number formatting, well-known locales (GAP-001)
- `rfcs/` directory with RFC template and first RFC (block closures) (GAP-003)
- `CHANGELOG.md` (this file) (GAP-002)
- `.gitignore` for build artifacts and target directory (SCRIPT-005)
- Arc[T] reference-counted wrapper in `std/async.tg` (BUG-046)
- Ptr[T] and NonNull[T] types in `std/ffi.tg` (INC-004)
- Interop between `std/replay.tg` and `std/snapshot.tg` via conversion functions (INC-009)
- display_width() function in `std/fmt.tg` (GAP-023)
- Hex/binary/octal literal scanning in `tg_compiler/lexer.tg` (GAP-006)
- Generic bounds, where clauses, and inherent impl parsing (GAP-007, GAP-008)
- Expression-body functions `def f(x) = expr` (GAP-009)
- Inclusive range `..=` operator (GAP-010)
- Associated types in traits (GAP-011)
- for-loop pattern destructuring (GAP-013)
- Default trait method body parsing (GAP-025)
- .bss section in Mach-O output (GAP-024)

### Fixed
- Production and hardened mode configs now differ (BUG-047)
- `net.tg` uses proper `TimeVal` struct for timeouts (BUG-048)
- `asm.tg` Adrp21/AddImm12 fixup handling (BUG-049)
- `test_gen.tg` template variable replacement corrected (BUG-050)
- Match arm syntax unified to `when...then` across all files (INC-001)
- Bare `unsafe` blocks annotated with reason strings (INC-002)
- `_TaintSeal` renamed to `_Seal` for convention consistency (INC-005)
- Duplicate `parse_int` removed from `budget.tg`, imports `fmt.tg` (INC-007)
- Duplicate `extract_function_body`/`extract_function_names` removed from `effects.tg` (INC-008)
- Buffer types unified to `Vec[u8]` in `io.tg` Read/Write traits (INC-010)
- `f32` → `Float` in 110 occurrences across `ui.tg` (INC-011)
- Weak hash_string() replaced with FNV-1a in `driver.tg` (INC-012)
- Brace-style blocks `{ }` → `do...end` in http.tg, ui.tg, style_guide.md (INC-013)
- `#[repr(C)]` → `@repr(C)` annotation syntax (INC-014)
- `profile.tg` rewritten from Rust to Tangerine (INC-015)
- Null pointer safety across entire std library (16 findings fixed)
- Capability baseline path corrected (GAP-004)
- Coverage schema version aligned to v0.2 (GAP-017)
- `continue` keyword added, coexists with `next` (GAP-014)
- Mode enforcement matrix contradiction resolved (GAP-019)
- Documentation syntax corrections (DOC-001 through DOC-010)

### Changed
- `io.tg` Read trait buffer types from `Array[Int]` to `Vec[u8]`
- `db.tg` pointer types from `*mut ()` to `Ptr[T]` (69 occurrences)

## [0.1.0] - 2025-01-01

### Added
- Initial implementation of Tangerine self-hosting compiler
- Lexer, parser, type checker, borrow checker, MIR, codegen pipeline
- Standard library: core, collections, io, fs, net, async, thread, time, fmt, json, toml, etc.
- CQS/CWS quality framework
- Deterministic replay and snapshot systems
- Agentic compiler features (contracts, capabilities, budgets, effects)
- VSCode extension with TextMate grammar
- Coverage tooling and merge script
