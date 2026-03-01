# Tangerine Versioning & Compatibility Policy

## Semantic Versioning

Tangerine follows [Semantic Versioning 2.0.0](https://semver.org/):

- **MAJOR** (X.0.0): Breaking language or stdlib changes.
- **MINOR** (0.X.0): New features, new stdlib APIs, new compiler capabilities.
- **PATCH** (0.0.X): Bug fixes, performance improvements, diagnostic improvements.

Current version: **0.1.0** (pre-1.0, all APIs are unstable).

## Pre-1.0 Policy

During the 0.x series:
- Minor version bumps (0.1 → 0.2) may include breaking changes.
- Breaking changes are documented in `CHANGELOG.md`.
- A migration guide is provided for each breaking minor release.
- The `tg check --edition` flag helps identify code that needs updating.

## Post-1.0 Stability Promise

Once Tangerine reaches 1.0:

1. **No silent breakage**: Code that compiles on version X.Y.Z will compile on
   X.Y.(Z+1) and X.(Y+1).0 without changes.

2. **Deprecation cycle**: Features are deprecated for at least one minor release
   before removal (which requires a major version bump).

3. **Feature gates**: New experimental features are available behind
   `@feature(...)` gates and are not subject to stability guarantees.

4. **Compiler warnings**: Deprecated features emit warnings that reference the
   replacement API and the version when the feature will be removed.

## Editions

Tangerine supports **editions** to evolve the language without breaking existing code.

### How Editions Work

- Each Tangerine source file declares an edition: `edition = "2026"` in `Tangerine.toml`.
- The compiler supports all active editions simultaneously.
- New editions can change syntax, keywords, and default behaviors.
- Editions are opt-in: updating your edition is never forced.
- Different packages in a dependency tree can use different editions.

### Edition Migration

The `tg migrate` tool automates edition transitions:

```bash
# Check what would change
tg migrate --edition 2026 --dry-run

# Apply migration
tg migrate --edition 2026
```

The migration tool:
- Rewrites syntax that changed between editions.
- Updates deprecated API calls to their replacements.
- Preserves formatting and comments.
- Produces a diff for review before applying.

### Planned Editions

| Edition | Status    | Key Changes |
| ------- | --------- | ----------- |
| 2025    | Frozen    | Initial edition; spec frozen (all APIs remain unstable pre-1.0) |
| 2026    | Current   | ABI updates, stdlib and tooling expansion |

## Standard Library Stability

### Stability Attributes

Public items in the standard library are annotated with stability:

```tangerine
@stable(since = "0.1.0")
def println(s: String) -> Unit

@unstable(feature = "async_io", reason = "API under review")
def async_read(fd: Int, buf: &mut Vec[u8]) -> Future[Result[UInt, IoError]]
```

### Stability Tiers

| Tier | Meaning | Guarantees |
| ---- | ------- | ---------- |
| `@stable` / `#[stable]` | Permanent API | Will not be removed or have signature changes. |
| `@unstable` / `#[unstable]` | Experimental | May change or be removed. Requires feature gate. |
| `@deprecated` / `#[deprecated]` | Scheduled for removal | Emits warning. Replacement documented. |
| (no annotation) | Internal | No stability guarantee. Not part of public API. |

> Both `@attr` and `#[attr]` syntaxes are accepted; `@attr` is preferred (see Style Guide).

### Standard Library Versioning

The standard library is versioned together with the compiler. A compiler version
X.Y.Z ships with stdlib version X.Y.Z. Users cannot independently update the stdlib.

### Standard Library Modules (v0.1.0)

The following modules are included in the standard library.

> **Note:** While the v0.1.0 standard library ships with all modules below,
> all APIs are **unstable** (pre-1.0). Signatures and behavior may change
> between minor versions without deprecation. Post-1.0, modules will graduate
> to `@stable` individually.

| Module | Description | Status |
|--------|-------------|--------|
| `std/core` | Core types (Option, Result, String) | Unstable (pre-1.0) |
| `std/collections` | Array, Map, Set, iterators | Unstable (pre-1.0) |
| `std/fmt` | Display, Debug, formatting, printing | Unstable (pre-1.0) |
| `std/alloc` | Allocator trait, system/arena allocators | Unstable (pre-1.0) |
| `std/env` | Environment variables, process arguments | Unstable (pre-1.0) |
| `std/backtrace` | Stack trace capture and display | Unstable (pre-1.0) |
| `std/io` | I/O traits and buffering | Unstable (pre-1.0) |
| `std/fs` | Filesystem operations | Unstable (pre-1.0) |
| `std/net` | Network sockets | Unstable (pre-1.0) |
| `std/async` | Async runtime and futures | Unstable (pre-1.0) |
| `std/thread` | Threading and synchronization | Unstable (pre-1.0) |
| `std/time` | Date, time, and duration | Unstable (pre-1.0) |
| `std/test` | Testing framework | Unstable (pre-1.0) |
| `std/bench` | Benchmarking | Unstable (pre-1.0) |
| `std/test_gen` | Automatic test generation | Unstable (pre-1.0) |
| `std/serde` | Serialization traits | Unstable (pre-1.0) |
| `std/json` | JSON parsing/generation | Unstable (pre-1.0) |
| `std/toml` | TOML parsing/generation | Unstable (pre-1.0) |
| `std/http` | HTTP client and server | Unstable (pre-1.0) |
| `std/url` | URL parsing | Unstable (pre-1.0) |
| `std/crypto` | Cryptographic primitives | Unstable (pre-1.0) |
| `std/log` | Logging, tracing, metrics | Unstable (pre-1.0) |
| `std/cli` | CLI argument parsing, terminal | Unstable (pre-1.0) |
| `std/regex` | Regular expressions, parser combinators | Unstable (pre-1.0) |
| `std/db` | Database drivers (SQLite, PostgreSQL) | Unstable (pre-1.0) |
| `std/compress` | Compression (gzip, deflate, tar, zip) | Unstable (pre-1.0) |
| `std/ui` | 2D graphics, images, fonts | Unstable (pre-1.0) |
| `std/web` | Web framework (routing, templates, auth) | Unstable (pre-1.0) |
| `std/ffi` | FFI types, pointers, taint integration | Unstable (pre-1.0) |
| `std/contracts` | Design by contract, guard keyword | Unstable (pre-1.0) |
| `std/capabilities` | Capability-based security, profiles | Unstable (pre-1.0) |
| `std/effects` | Algebraic effects | Unstable (pre-1.0) |
| `std/budget` | Resource budgets | Unstable (pre-1.0) |
| `std/profile` | Profiling and observability | Unstable (pre-1.0) |
| `std/snapshot` | Execution recording | Unstable (pre-1.0) |
| `std/secure_types` | Injection-safe types (SQL, HTML, URL, Path) | Unstable (pre-1.0) |
| `std/taint` | FFI taint tracking and validators | Unstable (pre-1.0) |
| `std/replay` | Deterministic replay | Unstable (pre-1.0) |
| `std/semantic_diff` | Semantic code diffing | Unstable (pre-1.0) |
| `std/supply_chain` | Package signing, lockfile, trust | Unstable (pre-1.0) |

## Dependency Version Resolution

### Version Constraints

Tangerine.toml supports these version constraint formats:

```toml
[dependencies]
# Exact version
json = "1.2.3"

# Caret (compatible updates): >=1.2.3, <2.0.0
json = "^1.2.3"

# Tilde (patch updates only): >=1.2.3, <1.3.0
json = "~1.2.3"

# Wildcard: any 1.x version
json = "1.*"

# Range
json = ">=1.0, <2.0"
```

### Resolution Algorithm

1. Read `Tangerine.toml` from root project and all workspace members.
2. Collect all dependency constraints (direct + transitive).
3. If `Tangerine.lock` exists, prefer locked versions.
4. For each unresolved dependency:
   a. Query the registry for available versions.
   b. Select the newest version satisfying all constraints.
   c. Recursively resolve its dependencies.
5. If no solution exists, report the conflict with a clear diagnostic showing
   which packages require incompatible versions.
6. Write the resolved graph to `Tangerine.lock`.

### Lockfile Policy

- `Tangerine.lock` **should be committed** for binary projects (applications).
- `Tangerine.lock` **should NOT be committed** for library packages.
- `tg dep update` re-resolves and updates the lockfile.
- `tg dep update <name>` updates only the specified package.

## Reproducible Builds

Tangerine aims for **bit-for-bit reproducible builds**:

- Compilation output is deterministic given the same source, dependencies, target, and compiler version.
- No timestamps or random values are embedded in output.
- Stable symbol ordering via deterministic hash maps.
- The `Tangerine.lock` file pins exact dependency versions and checksums.
- Cross-compilation support ensures builds can be reproduced on any platform.

To verify reproducibility:

```bash
tg build --release
sha256sum build/my_app

# On another machine with same tg version:
tg build --release
sha256sum build/my_app
# Should match
```
