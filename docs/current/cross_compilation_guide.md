# Tangerine Cross-Compilation Guide

> **Edition**: 2026 · **Spec**: §deployment

## Overview

Tangerine supports cross-compilation to multiple platforms and architectures from a single host machine. The compiler uses a target triple system similar to LLVM to identify the target platform.

## Target Tiers

### Tier 1 — Full Support (CI-tested, pre-built binaries)

| Target Triple | OS | Architecture | Notes |
|---|---|---|---|
| `x86_64-unknown-linux-gnu` | Linux | x86-64 | Primary development target |
| `x86_64-apple-darwin` | macOS | x86-64 | Intel Macs |
| `aarch64-apple-darwin` | macOS | ARM64 | Apple Silicon |
| `x86_64-pc-windows-msvc` | Windows | x86-64 | MSVC toolchain |

### Tier 2 — Guaranteed to Build

| Target Triple | OS | Architecture | Notes |
|---|---|---|---|
| `aarch64-unknown-linux-gnu` | Linux | ARM64 | Servers, Raspberry Pi 4+ |
| `wasm32-unknown-unknown` | WebAssembly | WASM32 | Browser targets |
| `wasm32-wasi` | WASI | WASM32 | Server-side WASM |
| `thumbv7em-none-eabihf` | Bare metal | ARM Cortex-M4/M7 | REJECTED by the embedded route — no Thumb code generator (the stable diagnostic, no artifact) |
| `thumbv6m-none-eabi` | Bare metal | ARM Cortex-M0/M0+ | REJECTED by the embedded route — no Thumb code generator |

### Tier 3 — Community-Supported

| Target Triple | OS | Architecture | Notes |
|---|---|---|---|
| `riscv64gc-unknown-linux-gnu` | Linux | RISC-V 64 | Emerging architecture |
| `riscv32imac-unknown-none-elf` | Bare metal | RISC-V 32 | REJECTED by the embedded route — no RISC-V code generator (no artifact) |
| `riscv32imc-unknown-none-elf` | Bare metal | RISC-V 32 | REJECTED by the embedded route — no RISC-V code generator |
| `aarch64-linux-android` | Android | ARM64 | Android NDK required |
| `x86_64-unknown-freebsd` | FreeBSD | x86-64 | Server deployments |
| `aarch64-unknown-none` | Bare metal | ARM64 | AArch64 baremetal — the embedded route's REAL target (the aarch64 backend) |

## Basic Cross-Compilation

### Command Line

```bash
# Build for a specific target
tg build --target aarch64-unknown-linux-gnu

# Build release with a specific target
tg build --target wasm32-unknown-unknown --release

# List all available targets
tg target list

# Add the real bare-metal toolchain
tg target add aarch64-unknown-none
```

### Tangerine.toml Configuration

```toml
[package]
name = "my_project"
version = "1.0.0"
edition = "2026"

# Default target (host)
[target]
triple = "x86_64-unknown-linux-gnu"

# Per-target configuration
[target.x86_64-pc-windows-msvc]
features = ["windows_service"]

[target.wasm32-unknown-unknown]
features = ["web_ui"]
opt_level = "s"

[target.aarch64-unknown-none]
features = ["no_std", "embedded"]
linker = "aarch64-none-elf-ld"
linker_script = "memory.ld"
```

## Platform-Specific Builds

### Linux → macOS

```bash
# Install macOS cross-compilation toolchain
tg target add x86_64-apple-darwin
tg target add aarch64-apple-darwin

# Build universal binary (both architectures)
tg build --target x86_64-apple-darwin --release
tg build --target aarch64-apple-darwin --release
tg lipo target/x86_64-apple-darwin/release/myapp \
        target/aarch64-apple-darwin/release/myapp \
        -output target/universal/myapp
```

### Linux/macOS → Windows

```bash
tg target add x86_64-pc-windows-msvc

# Build a Windows executable
tg build --target x86_64-pc-windows-msvc --release
```

### Any Host → WebAssembly

```bash
tg target add wasm32-unknown-unknown

# Build WASM module
tg build --target wasm32-unknown-unknown --release

# Output: target/wasm32-unknown-unknown/release/myapp.wasm

# Optimize WASM binary size
tg wasm-opt target/wasm32-unknown-unknown/release/myapp.wasm \
  -Os -o myapp_optimized.wasm
```

### Any Host → Embedded AArch64

```bash
# Install the bare-metal ARM64 toolchain
tg target add aarch64-unknown-none

# Build firmware (the REAL embedded target — the aarch64 backend)
tg build --target aarch64-unknown-none --release

# Output: target/aarch64-unknown-none/release/firmware.elf

# Convert to binary for flashing
tg objcopy -O binary \
  target/aarch64-unknown-none/release/firmware.elf \
  firmware.bin
```

The Thumb (`thumbv6m-none-eabi` / `thumbv7em-none-eabi[f]` /
`thumbv8m.main-none-eabihf`) and RISC-V (`riscv32imc|imac-unknown-none-elf`
/ `riscv64gc-unknown-none-elf`) embedded triples are HARD-REJECTED by the
embedded route: the compiler has no Thumb/RISC-V code generator, so the
route emits the stable rejection diagnostic and NO artifact — it never
fabricates an aarch64 image under a foreign triple.

## Conditional Compilation

```tangerine
## Platform-specific code blocks
@cfg(target_os = "linux")
def platform_init()
  use_epoll()
end

@cfg(target_os = "macos")
def platform_init()
  use_kqueue()
end

@cfg(target_os = "windows")
def platform_init()
  use_iocp()
end

## Architecture-specific
@cfg(target_arch = "x86_64")
def fast_memcpy(dst: *mut u8, src: *const u8, len: usize)
  use std::simd::f32x8  ## AVX available
  ## ...
end

@cfg(target_arch = "aarch64")
def fast_memcpy(dst: *mut u8, src: *const u8, len: usize)
  use std::simd::f32x4  ## NEON available
  ## ...
end

## Feature gates
@cfg(feature = "no_std")
use std::embedded::{ArrayVec as Vec}

@cfg(not(feature = "no_std"))
use std::collections::Vec

## Combining conditions
@cfg(all(target_os = "linux", target_arch = "x86_64"))
def linux_x86_specific() end

@cfg(any(target_os = "macos", target_os = "ios"))
def apple_specific() end
```

## WebAssembly Specifics

### Browser Target

```toml
# Tangerine.toml
[target.wasm32-unknown-unknown]
features = ["web_ui"]
opt_level = "s"

[wasm]
# Generate JS bindings
bindgen = true
# Generate TypeScript definitions
typescript = true
# Target ESM modules
module_type = "esm"
```

```tangerine
use std::wasm_js::{JsValue, Element, JsClosure, wasm_bindgen}

@[wasm_bindgen]
pub def greet(name: &str) -> String
  "Hello, " + name + "!"
end

@[wasm_bindgen]
pub def init()
  let button = Element.query_selector("#my-button").unwrap()
  let callback = JsClosure.new(|_event| 
    let output = Element.query_selector("#output").unwrap()
    output.set_text_content("Clicked!")
  end)
  button.add_event_listener("click", callback)
  callback.forget()  ## Prevent deallocation
end
```

### WASI Target

```toml
[target.wasm32-wasi]
features = ["wasi"]
```

```tangerine
## WASI modules can use filesystem, stdio, etc.
use std::io::{println, File}
use std::env

def main()
  let args = env.args()
  println("Running in WASI with {} args", args.len())

  let file = File.open("/data/input.txt")?
  ## ...
end
```

## Embedded Cross-Compilation

### Memory Layout

```toml
# Tangerine.toml
[target.aarch64-unknown-none]
linker_script = "memory.ld"
panic = "abort"

[target.aarch64-unknown-none.memory]
flash_origin = "0x00000000"
flash_size = "512K"
ram_origin = "0x40000000"
ram_size = "64K"
stack_size = "8K"
```

### Feature Detection at Build Time

```tangerine
## Detect SIMD capability
const HAS_NEON: Bool = cfg!(target_feature = "neon")
const HAS_AVX2: Bool = cfg!(target_feature = "avx2")

def process_data(data: &mut [f32])
  if HAS_AVX2 then
    process_avx2(data)
  elsif HAS_NEON then
    process_neon(data)
  else
    process_scalar(data)
  end
end
```

## CI/CD Cross-Compilation

### GitHub Actions Matrix

```yaml
name: Cross-Platform Build
on: [push]

jobs:
  build:
    strategy:
      matrix:
        include:
          - target: x86_64-unknown-linux-gnu
            os: ubuntu-latest
          - target: x86_64-apple-darwin
            os: macos-latest
          - target: aarch64-apple-darwin
            os: macos-latest
          - target: x86_64-pc-windows-msvc
            os: windows-latest
          - target: wasm32-unknown-unknown
            os: ubuntu-latest
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: tangerine-lang/setup-tangerine@v1
      - run: tg target add ${{ matrix.target }}
      - run: tg build --target ${{ matrix.target }} --release
      - run: tg test --target ${{ matrix.target }}
        if: matrix.target != 'wasm32-unknown-unknown'
```

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|---------|
| Missing linker | Cross-linker not installed | `tg target add <triple>` |
| Undefined symbols | Platform API not available | Use `@cfg()` guards |
| Binary too large | Debug info in release | Enable `strip = true` in profile |
| WASM memory error | Linear memory too small | Set `[wasm] initial_memory = "16MB"` |
| Embedded hardfault | Stack overflow | Increase `stack_size` in linker script |

### Checking Target Info

```bash
# Show target details
tg target info aarch64-unknown-none

# Check what features are available
tg target features x86_64-unknown-linux-gnu

# Show default linker for a target
tg target linker aarch64-unknown-linux-gnu
```

## See Also

- [docs/current/deployment_targets.md](deployment_targets.md) — Full target tier definitions
- [docs/current/embedded_guide.md](embedded_guide.md) — Embedded development guide
- [docs/current/build_system.md](build_system.md) — Build system reference
- [docs/current/packaging.md](packaging.md) — Package distribution
