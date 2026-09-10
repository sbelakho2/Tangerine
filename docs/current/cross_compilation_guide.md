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
| `thumbv7em-none-eabihf` | Bare metal | ARM Cortex-M4F | The embedded route's desc'd LIR triple: `--target` routes to the cortex-m4f LIR backend (ELF32 ARM object; `TANGERINE_LIR_TARGET=cortex-m4f` is the legacy alias of the same descriptor); object emission only — executable linking fails closed (`--emit=obj`) |
| `thumbv7em-none-eabi` | Bare metal | ARM Cortex-M4 | The M4 WITHOUT its optional FPU: `--target` routes to the cortex-m4 LIR backend (`fpu: None`, `float_abi: Soft` — float content fails closed; name `thumbv7em-none-eabihf` for the m4f descriptor) |
| `thumbv7m-none-eabi` | Bare metal | ARM Cortex-M3 | `--target` routes to the cortex-m3 LIR backend (ELF32 ARM object; `fpu: None`) |
| `thumbv6m-none-eabi` | Bare metal | ARM Cortex-M0/M0+ | REJECTED by the embedded route; no ARMv6-M `TargetDesc` instance exists (no backend consumes it) |

### Tier 3 — Community-Supported

| Target Triple | OS | Architecture | Notes |
|---|---|---|---|
| `riscv64gc-unknown-linux-gnu` | Linux | RISC-V 64 | Emerging architecture |
| `riscv32imac-unknown-none-elf` | Bare metal | RISC-V 32 | The embedded route's desc'd LIR triple: `--target` routes to the riscv32imac LIR backend (ELF32 RISC-V object; `TANGERINE_LIR_TARGET=riscv32imac` is the legacy alias of the same descriptor) |
| `riscv32imafc-unknown-none-elf` | Bare metal | RISC-V 32 | `--target` routes to the riscv32imafc LIR backend (ELF32 object; `fpu: RVF`/FLEN 32 modeled, float emission is the stage-2 slice — fail-closed) |
| `riscv32imafdc-unknown-none-elf` | Bare metal | RISC-V 32 | `--target` routes to the riscv32imafdc LIR backend (ELF32 object; `fpu: RVD`/FLEN 64 modeled) |
| `riscv32imc-unknown-none-elf` | Bare metal | RISC-V 32 | REJECTED by the embedded route; no LIR-route instance for the IMC profile (the imac descriptors require the A extension) |
| `riscv64imac-unknown-none-elf` | Bare metal | RISC-V 64 | `--target` routes to the riscv64imac LIR backend (ELF64 object; `fpu: None`) |
| `riscv64gc-unknown-none-elf` | Bare metal | RISC-V 64 | `--target` routes to the riscv64gc LIR backend (ELF64 object; `fpu: RVD`) |
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

The `--target` embedded route's image/artifact contract (the target
spec JSON + the linker script + the startup/vector artifacts + the
bare-metal ELF image) belongs to `aarch64-unknown-none` (the aarch64
backend). The Thumb/RISC-V triples WITH a descriptor — `thumbv7m-none-
eabi`, `thumbv7em-none-eabi[f]`, `riscv32imac|imafc|imafdc-unknown-none-
elf`, `riscv64imac|riscv64gc-unknown-none-elf` — route through the LIR
pipeline for the descriptor the triple names (see the next section);
the spec'd triples with NO descriptor instance (`thumbv6m-none-eabi` /
`thumbv8m.main-none-eabihf` / `riscv32imc-unknown-none-elf`) are
HARD-REJECTED with the stable diagnostic and NO artifact — the route
never fabricates an aarch64 image under a foreign triple.

### Any Host → ARMv7-M / RISC-V (the LIR backends)

The ARMv7-M and RISC-V code generators are the LIR route, and the
**`--target` triple is the backend identity**: `target_desc.tg`'s ONE
lookup (`target_desc_of_triple`) maps the canonical triples (and the
legacy route names as alias keys of the SAME table) to the per-CPU /
per-profile descriptors, and the driver routes a desc'd triple to the
LIR pipeline for that descriptor — no environment-only target universe
(`TANGERINE_LIR=1` still gates "LIR vs direct" for the aarch64 host
slice; `TANGERINE_LIR_TARGET` works only as a legacy alias through the
same table). The route compiles ONE native input file through the
standalone LIR pipeline (MIR → LIR → linear-scan register allocation →
per-backend emission), emitting ELF relocatable OBJECTS (`--emit=obj`;
executable linking fails closed — link with an arm-none-eabi /
riscv-none-elf toolchain). Targets are per-CPU / per-profile
DESCRIPTORS, not one generic core:

- **ARMv7-M** (`cortex-m3` / `cortex-m4` / `cortex-m4f` / `cortex-m7`;
  `cortex-m` is the legacy alias of `cortex-m4f`): the descriptors
  carry `fpu` / `float_abi` as data — **cortex-m3 and cortex-m4 have NO
  FPU** (`fpu: None`, `float_abi: Soft`; no VFP instruction may be
  emitted for them), cortex-m4f carries FPv4SP and cortex-m7 FPv5D16
  with the AAPCS32 hard-float crossings. Integer divide is Hardware
  (SDIV/UDIV) on all four. Emission: ELF32 ARM relocatable objects
  (backend_thumb.tg) with the LDREX/STREX atomic slice (widths 1/2/4),
  the desc-gated float slice, the scalar-constant static subset and
  the `.isr_vector` NVIC table for `@interrupt` functions.
- **RISC-V** (`riscv32imac` / `riscv32imafc` / `riscv32imafdc` /
  `riscv64imac` / `riscv64gc`; `riscv32`/`riscv64` are the legacy
  aliases of the imac instances): the descriptors carry the atomic
  width classes — native [4] on riscv32 and [4, 8] on riscv64 (the A
  extension's LR/SC), the sub-word widths 1/2 emulated-class on every
  instance (no Zabha instance is modeled), and mmio equal to native.
  The imac instances have no FPU; the F/D instances (imafc/imafdc/gc)
  model the psABI hard-float registers, while float emission on the rv
  backend is the stage-2 slice (fail-closed). Emission: ELF32/ELF64
  RISC-V relocatable objects (backend_rv.tg) with the LR/SC atomic
  slice at the native widths and the scalar-constant static subset.

There is no separate `--cpu` / `--features` flag surface this slice:
the per-CPU variance is carried by the descriptor table — a `--target`
triple selects exactly one canonical instance (`thumbv7em-none-eabihf`
→ cortex-m4f, `thumbv7em-none-eabi` → the no-FPU cortex-m4,
`thumbv7m-none-eabi` → cortex-m3, ...), and the instances without a
canonical triple (cortex-m7's FPv5-D16 class) stay reachable through
the table's alias keys (`TANGERINE_LIR_TARGET=cortex-m7`).

Both arms emit objects only (executable emission fails closed — link
with an arm-none-eabi / riscv-none-elf toolchain) and fail closed on
any construct outside their legalization contract (aggregates,
unsupported static images, sub-word atomics, and — per descriptor —
float content on the no-FPU instances). A desc'd embedded triple ALWAYS
uses its descriptor's LIR backend (`--target thumbv7m-none-eabi`, etc.;
the env gate is not required); the `TANGERINE_LIR=1` host slice is
still default-off and pending full-corpus parity with the direct
emitter, and unknown `TANGERINE_LIR_TARGET` legacy alias values fail
closed with the accepted set.

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
