# Changelog

All notable changes to the Tangerine project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html) as
described in [docs/versioning.md](docs/versioning.md).

## [Unreleased]

### Added
- `std/unicode.tg`: Unicode normalization (NFC/NFD/NFKC/NFKD), character properties, grapheme iteration, display width, and collation
- `std/locale.tg`: Locale support with BCP 47 tags, number formatting, well-known locales
- `rfcs/` directory with RFC template and first RFC (block closures)
- `CHANGELOG.md` (this file)
- `.gitignore` for build artifacts and target directory
- Arc[T] reference-counted wrapper in `std/async.tg`
- Ptr[T] and NonNull[T] types in `std/ffi.tg`
- Interop between `std/replay.tg` and `std/snapshot.tg` via conversion functions
- display_width() function in `std/fmt.tg`
- Hex/binary/octal literal scanning in `tg_compiler/lexer.tg`
- Generic bounds, where clauses, and inherent impl parsing
- Expression-body functions `def f(x) = expr`
- Inclusive range `..=` operator
- Associated types in traits
- for-loop pattern destructuring
- Default trait method body parsing
- .bss section in Mach-O output

### Fixed
- Production and hardened mode configs now differ
- `net.tg` uses proper `TimeVal` struct for timeouts
- `asm.tg` Adrp21/AddImm12 fixup handling
- `test_gen.tg` template variable replacement corrected
- Match arm syntax unified to `when...then` across all files
- Bare `unsafe` blocks annotated with reason strings
- `_TaintSeal` renamed to `_Seal` for convention consistency
- Duplicate `parse_int` removed from `budget.tg`, imports `fmt.tg`
- Duplicate `extract_function_body`/`extract_function_names` removed from `effects.tg`
- Buffer types unified to `Vec[u8]` in `io.tg` Read/Write traits
- `f32` → `Float` in 110 occurrences across `ui.tg`
- Weak hash_string() replaced with FNV-1a in `driver.tg`
- Brace-style blocks `{ }` → `do...end` in http.tg, ui.tg, style_guide.md
- `#[repr(C)]` → `@repr(C)` annotation syntax
- `profile.tg` rewritten from Rust to Tangerine
- Null pointer safety across entire std library (16 findings fixed)
- Capability baseline path corrected
- Coverage schema compatibility updated (v0.2 and v1 artifacts accepted)
- `continue` keyword added, coexists with `next`
- Mode enforcement matrix contradiction resolved
- Documentation syntax corrections

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
