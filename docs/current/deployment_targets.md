# Tangerine Deployment Targets Guide

**Version:** 0.1.0  
**Last Updated:** March 2026

How to build and deploy Tangerine applications across platforms.

---

## Table of Contents

1. [Supported Targets](#supported-targets)
2. [Native Compilation](#native-compilation)
3. [Cross-Compilation](#cross-compilation)
4. [WebAssembly](#webassembly)
5. [Container Deployment](#container-deployment)
6. [Static Linking](#static-linking)
7. [Release Profiles](#release-profiles)
8. [Platform-Specific Code](#platform-specific-code)
9. [CI/CD Integration](#cicd-integration)

---

## Supported Targets

### Tier 1 (Full Support, CI-Tested)

| Target Triple | OS | Architecture | Notes |
|--------------|-----|--------------|-------|
| `x86_64-unknown-linux-gnu` | Linux | x86_64 | Primary target |
| `x86_64-apple-darwin` | macOS | x86_64 | Intel Mac |
| `aarch64-apple-darwin` | macOS | ARM64 | Apple Silicon |
| `x86_64-pc-windows-msvc` | Windows | x86_64 | MSVC toolchain |

### Tier 2 (Builds, Limited Testing)

| Target Triple | OS | Architecture | Notes |
|--------------|-----|--------------|-------|
| `aarch64-unknown-linux-gnu` | Linux | ARM64 | Servers, Raspberry Pi 4+ |
| `aarch64-unknown-linux-musl` | Linux | ARM64 | Static linking |
| `x86_64-unknown-linux-musl` | Linux | x86_64 | Static linking, Alpine |
| `x86_64-pc-windows-gnu` | Windows | x86_64 | MinGW toolchain |
| `wasm32-wasi` | WASI | WebAssembly | Server-side WASM |
| `wasm32-unknown-unknown` | None | WebAssembly | Browser WASM |

### Tier 3 (Experimental)

| Target Triple | OS | Architecture |
|--------------|-----|--------------|
| `aarch64-linux-android` | Android | ARM64 |
| `x86_64-unknown-freebsd` | FreeBSD | x86_64 |
| `riscv64gc-unknown-linux-gnu` | Linux | RISC-V 64 |
| `armv7-unknown-linux-gnueabihf` | Linux | ARM32 |

---

## Native Compilation

### Basic Build

```bash
# Debug build (fast compile, no optimizations)
tg build

# Release build (optimized)
tg build --release

# Check only (no code generation)
tg check
```

### Build Output

```
target/
├── debug/
│   ├── my_app          # debug binary
│   ├── my_app.dwarf    # debug symbols
│   └── deps/           # compiled dependencies
└── release/
    ├── my_app          # optimized binary
    └── deps/
```

---

## Cross-Compilation

### Setup

```bash
# Install a cross-compilation toolchain
tg target add aarch64-unknown-linux-gnu

# List installed targets
tg target list
```

### Building for Another Target

```bash
# Cross-compile for Linux ARM64
tg build --release --target aarch64-unknown-linux-gnu

# Cross-compile for Windows from macOS
tg build --release --target x86_64-pc-windows-msvc

# Cross-compile for musl (static binary)
tg build --release --target x86_64-unknown-linux-musl
```

### Toolchain Configuration

In `Tangerine.toml`:

```toml
[target.aarch64-unknown-linux-gnu]
linker = "aarch64-linux-gnu-gcc"
ar = "aarch64-linux-gnu-ar"

[target.x86_64-unknown-linux-musl]
linker = "musl-gcc"
rustflags = ["-C", "target-feature=+crt-static"]
```

### Multi-Target Build

```bash
# Build for multiple targets at once
tg build --release \
  --target x86_64-unknown-linux-gnu \
  --target aarch64-unknown-linux-gnu \
  --target x86_64-apple-darwin \
  --target aarch64-apple-darwin
```

---

## WebAssembly

### Browser Target (`wasm32-unknown-unknown`)

```bash
# Build for browser
tg build --release --target wasm32-unknown-unknown

# Output: target/wasm32-unknown-unknown/release/my_app.wasm
```

#### Integration with JavaScript

```javascript
// Load and run the WASM module
const response = await fetch('my_app.wasm');
const bytes = await response.arrayBuffer();
const { instance } = await WebAssembly.instantiate(bytes, {
  env: {
    // Import functions the WASM module needs
  }
});

// Call exported functions
const result = instance.exports.compute(42);
```

### WASI Target (`wasm32-wasi`)

Server-side WebAssembly with system interface:

```bash
# Build for WASI
tg build --release --target wasm32-wasi

# Run with a WASI runtime
wasmtime target/wasm32-wasi/release/my_app.wasm
wasmer target/wasm32-wasi/release/my_app.wasm
```

### WASM Component Model

```toml
# Tangerine.toml
[target.wasm32-wasi]
component = true    # Enable component model output

[package.wit]
world = "my-world"
path = "wit/my-world.wit"
```

### WASM Optimization

```bash
# Optimize WASM binary size
tg build --release --target wasm32-unknown-unknown

# Further optimization with wasm-opt
wasm-opt -O3 -o output.wasm target/wasm32-unknown-unknown/release/my_app.wasm

# Strip debug info
wasm-strip output.wasm
```

| Optimization | Typical Size Reduction |
|-------------|----------------------|
| Release build | 50-70% vs. debug |
| `wasm-opt -O3` | Additional 10-30% |
| `wasm-strip` | Additional 5-15% |
| LTO | Additional 5-20% |

---

## Container Deployment

### Dockerfile (Multi-Stage)

```dockerfile
# Build stage
FROM tangerine:latest AS builder
WORKDIR /app
COPY . .
RUN tg build --release --target x86_64-unknown-linux-musl

# Runtime stage (minimal)
FROM scratch
COPY --from=builder /app/target/x86_64-unknown-linux-musl/release/my_app /
ENTRYPOINT ["/my_app"]
```

### Static Binary for Containers

```bash
# Build fully static binary (no libc dependency)
tg build --release --target x86_64-unknown-linux-musl

# Result: single binary, runs on `scratch` or `distroless` images
file target/x86_64-unknown-linux-musl/release/my_app
# my_app: ELF 64-bit LSB executable, statically linked
```

### Minimal Container Size

| Approach | Typical Image Size |
|----------|-------------------|
| Ubuntu + dynamic binary | ~80 MB |
| Alpine + static binary | ~10 MB |
| `scratch` + static binary | ~5 MB |
| `distroless` + static binary | ~7 MB |

---

## Static Linking

### Full Static Build

```toml
# Tangerine.toml
[profile.release]
link = "static"       # Link all dependencies statically
lto = true            # Link-time optimization
strip = "symbols"     # Strip debug symbols
```

```bash
tg build --release --target x86_64-unknown-linux-musl
```

### Selective Static Linking

```toml
[dependencies]
openssl = { version = "1.0", features = ["vendored"] }  # Statically link OpenSSL
```

---

## Release Profiles

### Built-in Profiles

```toml
[profile.dev]
opt_level = 0          # No optimization
debug = true           # Full debug info
overflow_checks = true # Integer overflow checks

[profile.release]
opt_level = 3          # Maximum optimization
debug = false          # No debug info
lto = true             # Link-time optimization
strip = "symbols"      # Strip symbols
panic = "abort"        # Abort on panic (smaller binary)

[profile.bench]
opt_level = 3
debug = true           # Debug info for profiling

[profile.hardened]
opt_level = 2
debug = false
overflow_checks = true
sanitizers = ["address", "undefined"]
stack_protector = true
```

### Size Optimization

```toml
[profile.release-small]
opt_level = "z"        # Optimize for size
lto = true
strip = "symbols"
panic = "abort"
codegen_units = 1      # Fewer codegen units = better optimization
```

---

## Platform-Specific Code

### Compile-Time Platform Detection

```tangerine
@[cfg(target_os = "linux")]
def platform_init() -> Unit
  # Linux-specific initialization
end

@[cfg(target_os = "macos")]
def platform_init() -> Unit
  # macOS-specific initialization
end

@[cfg(target_os = "windows")]
def platform_init() -> Unit
  # Windows-specific initialization
end

@[cfg(target_arch = "wasm32")]
def platform_init() -> Unit
  # WebAssembly-specific initialization
end
```

### Runtime Detection

```tangerine
use std::env

match env::consts::OS
when "linux" then linux_setup()
when "macos" then macos_setup()
when "windows" then windows_setup()
when _ then generic_setup()
end
```

---

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Build and Release
on:
  push:
    tags: ['v*']

jobs:
  build:
    strategy:
      matrix:
        include:
          - os: ubuntu-latest
            target: x86_64-unknown-linux-gnu
          - os: ubuntu-latest
            target: x86_64-unknown-linux-musl
          - os: ubuntu-latest
            target: aarch64-unknown-linux-gnu
          - os: macos-latest
            target: x86_64-apple-darwin
          - os: macos-latest
            target: aarch64-apple-darwin
          - os: windows-latest
            target: x86_64-pc-windows-msvc

    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: tangerine-lang/setup-tg@v1
      - run: tg target add ${{ matrix.target }}
      - run: tg build --release --target ${{ matrix.target }}
      - run: tg test --release --target ${{ matrix.target }}
      - uses: actions/upload-artifact@v4
        with:
          name: binary-${{ matrix.target }}
          path: target/${{ matrix.target }}/release/my_app*
```

### Release Artifacts

```bash
# Create release archives for all platforms
for target in x86_64-unknown-linux-gnu aarch64-apple-darwin; do
  tg build --release --target $target
  tar czf "my_app-${VERSION}-${target}.tar.gz" \
    -C "target/${target}/release" my_app
done
```
