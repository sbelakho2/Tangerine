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
   `#[feature(...)]` gates and are not subject to stability guarantees.

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
| 2025    | Stable    | Initial release |
| 2026    | Current   | ABI updates, stdlib and tooling expansion |

## Standard Library Stability

### Stability Attributes

Public items in the standard library are annotated with stability:

```tangerine
#[stable(since = "0.1.0")]
def println(s: String) -> Unit

#[unstable(feature = "async_io", reason = "API under review")]
def async_read(fd: Int, buf: &mut Vec[u8]) -> Future[Result[UInt, IoError]]
```

### Stability Tiers

| Tier | Meaning | Guarantees |
| ---- | ------- | ---------- |
| `#[stable]` | Permanent API | Will not be removed or have signature changes. |
| `#[unstable]` | Experimental | May change or be removed. Requires feature gate. |
| `#[deprecated]` | Scheduled for removal | Emits warning. Replacement documented. |
| (no annotation) | Internal | No stability guarantee. Not part of public API. |

### Standard Library Versioning

The standard library is versioned together with the compiler. A compiler version
X.Y.Z ships with stdlib version X.Y.Z. Users cannot independently update the stdlib.

### Standard Library Modules (v0.1.0)

The following modules are included in the standard library:

| Module | Description | Status |
|--------|-------------|--------|
| `std/core` | Core types (Option, Result, Vec, Map, String) | Stable |
| `std/collections` | Additional collections | Stable |
| `std/io` | I/O traits and buffering | Stable |
| `std/fs` | Filesystem operations | Stable |
| `std/net` | Network sockets | Stable |
| `std/async` | Async runtime and futures | Stable |
| `std/thread` | Threading and synchronization | Stable |
| `std/time` | Date, time, and duration | Stable |
| `std/test` | Testing framework | Stable |
| `std/bench` | Benchmarking | Stable |
| `std/serde` | Serialization traits | Stable |
| `std/json` | JSON parsing/generation | Stable |
| `std/toml` | TOML parsing/generation | Stable |
| `std/http` | HTTP client and server | Stable |
| `std/url` | URL parsing | Stable |
| `std/crypto` | Cryptographic primitives | Stable |
| `std/log` | Logging, tracing, metrics | Stable |
| `std/cli` | CLI argument parsing, terminal | Stable |
| `std/regex` | Regular expressions, parser combinators | Stable |
| `std/db` | Database drivers (SQLite, PostgreSQL) | Stable |
| `std/compress` | Compression (gzip, deflate, tar, zip) | Stable |
| `std/ui` | 2D graphics, images, fonts | Stable |
| `std/web` | Web framework (routing, templates, auth) | Stable |
| `std/snapshot` | Execution recording and replay | Stable |
| `std/profile` | Profiling and observability | Stable |
| `std/ffi` | FFI helpers and types | Stable |
| `std/contracts` | Design by contract | Stable |
| `std/capabilities` | Capability-based security | Stable |
| `std/effects` | Algebraic effects | Stable |
| `std/budget` | Resource budgets | Stable |

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
