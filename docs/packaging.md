# Tangerine Package Management Guide

**Version:** 0.1.0  
**Last Updated:** March 2026

How to create, publish, and manage Tangerine packages.

---

## Table of Contents

1. [Overview](#overview)
2. [Project Structure](#project-structure)
3. [Tangerine.toml](#tangerinetoml)
4. [Dependencies](#dependencies)
5. [Package Manager CLI](#package-manager-cli)
6. [Dependency Resolution](#dependency-resolution)
7. [Lock Files](#lock-files)
8. [Registry](#registry)
9. [Publishing](#publishing)
10. [Templates and Scaffolding](#templates-and-scaffolding)
11. [Workspaces](#workspaces)
12. [Security](#security)

---

## Overview

Tangerine's package system consists of:

| Component | Description |
|-----------|-------------|
| **`tg pkg`** | CLI for dependency management |
| **`Tangerine.toml`** | Project manifest |
| **`Tangerine.lock`** | Reproducible dependency lock file |
| **Registry** | HTTP-based package index (default: `registry.tangerine-lang.org`) |

---

## Project Structure

```
my_project/
├── Tangerine.toml        # Project manifest
├── Tangerine.lock        # Generated lock file (commit to VCS)
├── src/
│   ├── main.tg           # Binary entry point
│   └── lib.tg            # Library entry point
├── tests/
│   ├── unit_test.tg
│   └── integration_test.tg
├── examples/
│   └── demo.tg
├── benches/
│   └── perf_test.tg
└── docs/
    └── guide.md
```

---

## Tangerine.toml

The project manifest:

```toml
[package]
name = "my_app"
version = "1.2.3"
edition = "2026"
authors = ["Alice <alice@example.com>"]
license = "MIT"
description = "A sample Tangerine application"
repository = "https://github.com/user/my_app"
keywords = ["web", "api"]
categories = ["web-programming"]

[dependencies]
http_server = "^2.0"
json_parser = "~1.5.0"
db_driver = { version = "3.0", features = ["async", "tls"] }
local_lib = { path = "../my_lib" }
git_dep = { git = "https://github.com/user/lib.git", branch = "main" }

[dev-dependencies]
test_utils = "1.0"
mock_server = "0.5"

[build-dependencies]
codegen_tool = "2.1"

[features]
default = ["json"]
json = []
yaml = ["dep:yaml_parser"]
full = ["json", "yaml", "toml_support"]

[profile.release]
opt_level = 3
lto = true
strip = "symbols"

[profile.dev]
opt_level = 0
debug = true
```

---

## Dependencies

### Version Requirements

| Syntax | Meaning | Example |
|--------|---------|---------|
| `"1.2.3"` | Exact version | Only `1.2.3` |
| `"^1.2.3"` | Compatible (caret) | `>=1.2.3, <2.0.0` |
| `"~1.2.3"` | Patch-level (tilde) | `>=1.2.3, <1.3.0` |
| `">=1.0, <2.0"` | Range | Between 1.0 and 2.0 |
| `"*"` | Any version | Latest compatible |

### Source Types

```toml
# Registry (default)
serde = "1.0"

# Local path
my_lib = { path = "../my_lib" }

# Git repository
my_dep = { git = "https://github.com/user/dep.git", tag = "v1.0.0" }
my_dep = { git = "https://github.com/user/dep.git", branch = "main" }
my_dep = { git = "https://github.com/user/dep.git", rev = "abc123" }
```

### Feature Flags

```toml
# Enable specific features
db_driver = { version = "3.0", features = ["async", "postgres", "tls"] }

# Disable default features
json_parser = { version = "1.5", default-features = false, features = ["serde"] }
```

---

## Package Manager CLI

### Core Commands

```bash
# Create a new project
tg new my_project
tg new my_project --template lib        # library template
tg new my_project --template web-api    # web API template

# Add dependencies
tg pkg add http_server
tg pkg add http_server@^2.0
tg pkg add db_driver --features async,tls

# Remove dependencies
tg pkg remove http_server

# Update dependencies
tg pkg update                 # update all within constraints
tg pkg update http_server     # update specific package

# Install (download and compile)
tg pkg install

# Show dependency tree
tg pkg tree
tg pkg tree --depth 2

# Check for outdated packages
tg pkg outdated

# Audit for security vulnerabilities
tg pkg audit
```

### Build Commands

```bash
# Build the project
tg build
tg build --release
tg build --target aarch64-apple-darwin

# Run
tg run
tg run -- --arg1 --arg2

# Test
tg test
tg test --filter "test_name"

# Benchmark
tg bench

# Format code
tg fmt

# Lint
tg lint
```

---

## Dependency Resolution

Tangerine uses a SAT-solver-based dependency resolver:

1. **Fetch metadata** for all requested packages
2. **Build constraint graph** from version requirements
3. **Solve** using backtracking with unit propagation
4. **Verify** no conflicts in the solution
5. **Generate lock file** with exact versions and hashes

### Resolution Rules

- **Minimal version selection** by default (smallest version satisfying all constraints)
- **SemVer compatibility** — `^1.2.3` allows `1.x.y` where `x.y >= 2.3`
- **Feature unification** — if multiple dependents enable different features, the union is used
- **Duplicate rejection** — only one version of each package in the dependency graph

---

## Lock Files

`Tangerine.lock` ensures reproducible builds:

```toml
# Auto-generated — do not edit manually

[[package]]
name = "http_server"
version = "2.1.4"
source = "registry"
checksum = "sha256:abc123..."
dependencies = ["io_core ^1.0", "tls_lib ^0.5"]

[[package]]
name = "io_core"
version = "1.3.2"
source = "registry"
checksum = "sha256:def456..."
```

**Rule:** Always commit `Tangerine.lock` to version control for applications. Libraries should not commit lock files.

---

## Registry

### Default Registry

The official registry at `registry.tangerine-lang.org` provides:

- Package search and discovery
- Version metadata and checksums
- Download statistics
- Security advisories
- API key authentication

### Custom Registries

```toml
# In Tangerine.toml
[registries]
my_company = { url = "https://registry.company.com", auth = "token" }

[dependencies]
internal_lib = { version = "1.0", registry = "my_company" }
```

### Local Registry (Offline)

```toml
[registries]
local = { path = "/path/to/local/registry" }
```

---

## Publishing

```bash
# Login to registry
tg registry login

# Verify package before publishing
tg pkg publish --dry-run

# Publish to default registry
tg pkg publish

# Publish to custom registry
tg pkg publish --registry my_company

# Yank a published version (prevent new installs)
tg pkg yank my_package@1.2.3
```

### Pre-publish Checklist

- [ ] Version bumped in `Tangerine.toml`
- [ ] `CHANGELOG.md` updated
- [ ] All tests pass (`tg test`)
- [ ] No lint warnings (`tg lint`)
- [ ] Documentation builds (`tg doc`)
- [ ] License file present

---

## Templates and Scaffolding

Create projects from templates:

```bash
tg new hello --template binary          # Binary application
tg new mylib --template lib             # Library
tg new myapi --template web-api         # Web API server
tg new mycli --template cli-tool        # CLI application
tg new mygui --template gui-app         # GUI application
tg new mymod --template wasm-module     # WebAssembly module
tg new mypkg --template workspace       # Multi-package workspace
tg new myext --template vscode-ext      # VS Code extension
```

---

## Workspaces

Manage multiple packages in one repository:

```toml
# Root Tangerine.toml
[workspace]
members = [
  "core",
  "cli",
  "server",
  "shared/utils",
]

# Shared dependency versions
[workspace.dependencies]
serde = "1.0"
http = "2.0"
```

Each member has its own `Tangerine.toml`:

```toml
[package]
name = "my_server"
version = "1.0.0"

[dependencies]
serde = { workspace = true }              # inherit version from workspace
utils = { path = "../shared/utils" }      # local path dep
```

---

## Security

### Supply Chain Protections

- **Checksum verification** — every package download is verified against SHA-256 hash
- **Signature verification** — packages can be signed with Ed25519 keys
- **Dependency auditing** — `tg pkg audit` checks against known vulnerability database
- **Lockfile integrity** — lockfile checksums prevent tampering
- **Minimal permissions** — build scripts run in a sandboxed environment

### `tg pkg audit`

```bash
$ tg pkg audit
Scanning 47 packages for vulnerabilities...

VULN-2026-001 (HIGH): Buffer overflow in json_parser < 1.5.2
  Affected: json_parser 1.5.0
  Fix: upgrade to >= 1.5.2

1 vulnerability found (1 high, 0 medium, 0 low)
```

See [Supply Chain Security](supply_chain.md) for detailed security policies.
