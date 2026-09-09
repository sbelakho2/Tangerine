# Tangerine Embedded Systems Development Guide

> **Edition**: 2026 · **Module**: `std::embedded` · **Tier**: Tier 2+ targets

## Overview

Tangerine provides bare-metal development support through the `std::embedded`
module (the volatile/MMIO Register abstraction, the `@interrupt` /
`@link_section` / `@panic_handler` markers, the interrupt vector table and
the allocator-free `ArrayVec` / `RingBuffer` collections) and the driver's
embedded route (`compile_to_embedded_route`).

> **THE CODE-GEN TRUTH (P0.2, updated for the LIR routes).** Two code
> generation routes exist. (1) The DEFAULT (un-gated) route is the
> DIRECT emitter (codegen.tg) for the host targets (`aarch64-apple-
> darwin`, `x86_64-unknown-linux-gnu`, plus the wasm32 route). (2) The
> env-gated LIR route (`TANGERINE_LIR=1` + `TANGERINE_LIR_TARGET=...`,
> default off — driver.tg `compile_lir_route`) compiles native single
> files through the standalone LIR pipeline (lir.tg: MIR → LIR →
> linear-scan allocation → per-backend emission) for aarch64 and for
> the ARMv7-M and RISC-V backends below; it fails closed on any
> construct outside its legalization contract.
>
> The `--target`-triple embedded route (`compile_to_embedded_route`) is
> unchanged in scope: its only real code generation target remains
> **`aarch64-unknown-none`** (ARM64 bare-metal — the aarch64 backend).
> The Thumb triples (`thumbv6m-none-eabi`, `thumbv7em-none-eabi[f]`,
> `thumbv8m.main-none-eabihf`) and the RISC-V triples
> (`riscv32imc|imac-unknown-none-elf`, `riscv64gc-unknown-none-elf`)
> are **HARD-REJECTED by that route**: it has no generator for those
> triples, so it emits the stable rejection diagnostic and NO artifact
> (it never fabricates an aarch64 image under a foreign triple). The
> per-CPU ARMv7-M and RISC-V code generators live on the LIR route and
> are selected by `TANGERINE_LIR_TARGET`, not by `--target`.
> There is **no QEMU execution lane** — hardware execution is not
> claimed.

## Target Platforms

| Target Triple / route name | Architecture | Status |
|---------------------------|-------------|----------|
| `aarch64-unknown-none` (embedded route) | ARM64 (bare) | Supported — the real codegen of the `--target` embedded route (the aarch64 backend): the spec JSON + the linker script + the startup/vector artifacts + the bare-metal ELF image |
| `thumbv7em-none-eabihf` (embedded route) | ARM Cortex-M4F/M7 | REJECTED by the embedded route (no triple generator there); the ARMv7-M codegen is the LIR route's per-CPU backends (`TANGERINE_LIR_TARGET=cortex-m4f/cortex-m7`) |
| `thumbv6m-none-eabi` (embedded route) | ARM Cortex-M0/M0+ | REJECTED by the embedded route; ARMv6-M has no LIR-route instance this slice (fail-closed — no backend consumes it) |
| `thumbv8m.main-none-eabihf` (embedded route) | ARM Cortex-M33 | REJECTED by the embedded route; no LIR-route instance this slice |
| `riscv32imac-unknown-none-elf` (embedded route) | RISC-V RV32 | REJECTED by the embedded route; the RISC-V codegen is the LIR route's descriptors (`TANGERINE_LIR_TARGET=riscv32imac`/`riscv32imafc`/`riscv32imafdc`) |
| `riscv32imc-unknown-none-elf` (embedded route) | RISC-V RV32IMC | REJECTED by the embedded route; no LIR-route instance for the IMC profile (the imac descriptors require the A extension) |
| `riscv64gc-unknown-none-elf` (embedded route) | RISC-V RV64 | REJECTED by the embedded route; the RISC-V codegen is the LIR route's descriptors (`TANGERINE_LIR_TARGET=riscv64imac`/`riscv64gc`) |

## The LIR-route Thumb-2 and RISC-V backends

The env-gated LIR route (driver.tg `compile_lir_route`,
`TANGERINE_LIR=1`) emits REAL relocatable ELF objects through per-CPU /
per-profile descriptors — the old single "cortex-m" blob is replaced by
four per-CPU ARMv7-M instances and five RISC-V instances
(`target_desc.tg` `thumbv7m_cortex_m3_desc` /
`thumbv7em_cortex_m4_desc` / `thumbv7em_cortex_m4f_desc` /
`thumbv7em_cortex_m7_desc` / `riscv32imac_desc` /
`riscv32imafc_desc` / `riscv32imafdc_desc` / `riscv64imac_desc` /
`riscv64gc_desc`; the legacy names `cortex-m` → cortex-m4f and
`riscv32`/`riscv64` → the imac instances of their xlen). The route's
thumb/rv arms emit relocatable OBJECTS only (the `-c` / `--emit-obj`
object mode) — executable emission fails closed
(the objects are for an external arm-none-eabi / riscv-none-elf
linker); the aarch64 arm additionally links executables.

- **Cortex-M (backend_thumb.tg, ELF32 EM_ARM objects):** every member
  is AAPCS32, Thumb-2, 8-byte stack-aligned with the ARMv7-M
  byte/halfword/word LDREX/STREX exclusives and hardware
  SDIV/UDIV (`integer_div: Hardware` on the M3/M4/M4F/M7 descriptors).
  The descriptors carry the FPU as DATA: **cortex-m3 and cortex-m4
  have `fpu: None` / `float_abi: Soft` — no VFP instruction may be
  emitted for them**, and float content fails closed at the desc-driven
  FP gate; **cortex-m4f** carries `fpu: FPv4SP` (vfpv4-d16, the
  single-precision data-processing set) and **cortex-m7** `fpu:
  FPv5D16` (adds the double-precision VFP data processing), both
  `float_abi: Hard` (AAPCS32 VFP crossings: s0..s15/d0..d7). The
  implemented surface: the register-resident F64 float slice (F32 is
  memory-class on this route — the cm register model has no
  single-register F32 alias above d15), the atomic slice at the
  [1,2,4]-byte widths (LDREX/STREX loops with the per-ordering DMB
  discipline; `_u64` fails closed), the scalar-constant static subset
  (`.data` + MOVW/MOVT-address loads), and the **NVIC handler slice**:
  `@interrupt` functions are emitted with the EXC_RETURN prologue/
  epilogue discipline and registered into the object's `.isr_vector`
  section (declaration-order vector words, R_ARM_ABS32 over the
  handler symbols). Fail-closed: 64-bit payloads and shift counts the
  32-bit word model cannot hold, aarch64-convention LIR forms (fixed
  vregs 4..7), div/mod (the lowering gate stays closed this slice),
  static writes and non-scalar static images, aggregate returns/
  parameters, float-class variadic extern calls (GP-only variadic
  calls keep lowering — the base convention's word stream), and
  bare-metal image/startup linking (`thumb_compile_executable` fails
  closed — the route's objects are for an arm-none-eabi linker; the
  embedded-route cortex-m linker script + startup artifacts are the
  image contract).
- **RISC-V (backend_rv.tg, ELF32/ELF64 EM_RISCV objects):** the
  descriptors carry the atomic width classes as DATA:
  `native_atomic_widths` [4] on riscv32 and [4, 8] on riscv64 (the A
  extension's LR/SC widths), `emulated_atomic_widths` [1, 2] on every
  instance — sub-word atomics have no LR/SC encoding and no Zabha
  instance is modeled this slice — and `mmio_atomic_widths` equal to
  the native set (an emulated word-width RMW could touch a neighbour-
  ing MMIO register, so it is never MMIO-safe). The implemented
  surface: the LR/SC atomic forms (loads/stores, RMW loops, CAS) at
  the native widths with the per-ordering fences, and the
  scalar-constant static subset (`.data` + LUI/ADDI-address loads).
  The FPU split is descriptor data — `riscv32imac`/`riscv64imac` have
  `fpu: None`; `riscv32imafc` carries `fpu: RVF` (FLEN 32) and
  `riscv32imafdc`/`riscv64gc` `fpu: RVD` (FLEN 64), all with
  `float_abi: Hard` (the psABI fa0..fa7 float argument file modeled as
  data) — but the rv emitter's float arms are the
  stage-2 slice, so float statements stay fail-closed. Fail-closed:
  aggregate returns/parameters, sub-word (emulated-class) atomics,
  RV32 64-bit atomics and 64-bit-int conversion forms, statics beyond
  the scalar subset and static writes, div/rem encoders (the modeled
  M extension names the target capability, not this slice's), and
  float stack arguments beyond the eight fa0..fa7 registers.
- The route accepts the standard object/executable emit modes only;
  the thumb/rv arms fail closed on executable emission (objects only
  — link externally), while the aarch64 LIR arm links executables. Neither backend ever
  invokes an external toolchain — every encoding is emitted in-tree.
  The route is default-off and pending full-corpus parity with the
  DIRECT emitter; it fails closed on any construct outside its
  legalization contract rather than falling back silently.

## Getting Started

### Project Setup

```toml
# Tangerine.toml
[package]
name = "my_firmware"
version = "0.1.0"
edition = "2026"

[target]
triple = "aarch64-unknown-none"
features = ["no_std"]

[dependencies]
std_embedded = { path = "std/embedded" }

[profile.release]
opt_level = "s"       # Optimize for size
lto = true            # Link-time optimization
panic = "abort"       # No unwinding in embedded
```

### Minimal Blinky

```tangerine
use std::embedded::{
  PanicStrategy, volatile_write, Register,
  hal::{GpioPin, GpioMode, GpioState},
}

@[no_std]
@[entry]
def main() -> !
  ## Configure LED pin (PA5 on STM32F4)
  let mut led = GpioPin.new(Port.A, 5)
  led.configure(GpioMode.Output)

  loop
    led.set(GpioState.High)
    delay(500_000)
    led.set(GpioState.Low)
    delay(500_000)
  end
end

def delay(count: u32)
  for _ in 0..count do
    volatile_write(0 as *mut u32, 0)  ## prevent optimization
  end
end

@[panic_handler]
def panic_handler(info: &PanicInfo) -> !
  loop end
end
```

## Memory-Mapped I/O

### Volatile Access

All register access in embedded systems must be volatile to prevent the compiler from optimizing away reads/writes:

```tangerine
use std::embedded::{volatile_read, volatile_write, volatile_modify}

## Direct volatile access
let value = volatile_read(0x4002_0000 as *const u32)
volatile_write(0x4002_0000 as *mut u32, 0xFF)

## Read-modify-write with closure
volatile_modify(0x4002_0000 as *mut u32, |v| v | (1 << 5))
```

### Register Abstraction

The `Register[T]` type wraps an MMIO address with typed access:

```tangerine
use std::embedded::Register

let gpio_odr = Register[u32].at(0x4002_0014)
gpio_odr.write(0x0020)          ## Set bit 5
let state = gpio_odr.read()     ## Read current value
gpio_odr.modify(|v| v ^ 0x0020) ## Toggle bit 5
```

### Bitfield Extraction

```tangerine
use std::embedded::Bitfield

let reg_value: u32 = gpio_odr.read()
let bits_5_7 = Bitfield.extract(reg_value, 5, 3)  ## 3 bits starting at bit 5
let modified = Bitfield.insert(reg_value, 5, 3, 0b101)
```

## Hardware Abstraction Layer (HAL)

### GPIO

```tangerine
use std::embedded::hal::{GpioPin, GpioMode, GpioState, GpioPull}

let mut led = GpioPin.new(Port.A, 5)
led.configure(GpioMode.Output)
led.set(GpioState.High)

let mut button = GpioPin.new(Port.C, 13)
button.configure(GpioMode.Input)
button.set_pull(GpioPull.PullUp)
let pressed = button.read() == GpioState.Low
```

### UART

```tangerine
use std::embedded::hal::{UartConfig, Uart}

let config = UartConfig {
  baud_rate: 115_200,
  data_bits: 8,
  stop_bits: 1,
  parity: Parity.None,
  flow_control: FlowControl.None,
}

let mut uart = Uart.new(1, config)?  ## UART1
uart.write_bytes(b"Hello, embedded!\r\n")?
let byte = uart.read_byte()?
```

### SPI

```tangerine
use std::embedded::hal::{SpiConfig, Spi, SpiMode}

let config = SpiConfig {
  mode: SpiMode.Mode0,        ## CPOL=0, CPHA=0
  frequency: 1_000_000,       ## 1 MHz
  bit_order: BitOrder.MsbFirst,
}

let mut spi = Spi.new(1, config)?
let mut rx_buf = [0u8; 4]
spi.transfer(&[0x9F, 0, 0, 0], &mut rx_buf)?  ## Read JEDEC ID
```

### I2C

```tangerine
use std::embedded::hal::{I2cConfig, I2c}

let config = I2cConfig {
  frequency: 400_000,  ## 400 kHz (Fast mode)
}

let mut i2c = I2c.new(1, config)?
let mut buf = [0u8; 6]
i2c.write_read(0x68, &[0x3B], &mut buf)?  ## Read accelerometer data
```

### Timers and PWM

```tangerine
use std::embedded::hal::{Timer, Pwm}

## One-shot timer
let mut timer = Timer.new(2)?
timer.start(Duration.from_millis(100))
while !timer.has_elapsed() do end

## PWM output
let mut pwm = Pwm.new(1, Channel.Ch1)?
pwm.set_frequency(1000)   ## 1 kHz
pwm.set_duty_cycle(50)    ## 50%
pwm.enable()
```

### ADC / DAC

```tangerine
use std::embedded::hal::{Adc, AdcResolution, Dac}

let mut adc = Adc.new(1)?
adc.set_resolution(AdcResolution.Bits12)
let raw = adc.read_channel(0)?
let voltage = (raw as f32 / 4095.0) * 3.3

let mut dac = Dac.new(1)?
dac.write(2048)  ## ~1.65V on 12-bit DAC
```

## Interrupts

### Declaring Interrupt Handlers

```tangerine
use std::embedded::{interrupt, critical_section}

@[interrupt]
def TIM2_IRQHandler()
  ## Clear interrupt flag
  volatile_modify(TIM2_SR, |v| v & !1)
  ## Handle the timer tick
end

@[interrupt(priority = 2)]
def EXTI0_IRQHandler()
  ## External interrupt on line 0
end
```

### Critical Sections

```tangerine
use std::embedded::critical_section

## Disable interrupts for the duration of the closure
critical_section(||
  ## Safe to access shared state here
  SHARED_COUNTER += 1
)
```

## DMA

```tangerine
use std::embedded::{DmaChannel, DmaMode, DmaDirection, DmaPriority}

let mut dma = DmaChannel.new(1, 5)?  ## DMA1, Stream 5
dma.configure(
  source: uart_rx_addr,
  dest: buffer.as_mut_ptr(),
  count: 256,
  direction: DmaDirection.PeripheralToMemory,
  mode: DmaMode.Circular,
  priority: DmaPriority.High,
)
dma.enable()
```

## Power Management

```tangerine
use std::embedded::{PowerController, PowerMode}

let pwr = PowerController.new()
pwr.enter_mode(PowerMode.Sleep)       ## Wait for interrupt
pwr.enter_mode(PowerMode.DeepSleep)   ## Low-power stop
pwr.enter_mode(PowerMode.Standby)     ## Minimal power, RAM lost
```

## Linker Scripts

Tangerine supports custom linker scripts via `@[link_section]` and the build config:

```tangerine
## Place data in specific memory sections
@[link_section(".ccmram")]
static mut FAST_BUFFER: [u8; 1024] = [0; 1024]

@[link_section(".noinit")]
static mut PERSISTENT: u32 = 0
```

```toml
# Tangerine.toml
[target.linker]
script = "memory.ld"
```

Example linker script (`memory.ld`):
```
MEMORY {
  FLASH  (rx)  : ORIGIN = 0x08000000, LENGTH = 512K
  RAM    (rwx) : ORIGIN = 0x20000000, LENGTH = 128K
  CCMRAM (rwx) : ORIGIN = 0x10000000, LENGTH = 64K
}
```

## No-Alloc Collections

For environments without a heap allocator:

```tangerine
use std::embedded::{ArrayVec, RingBuffer}

## Stack-allocated vector with fixed capacity
let mut items = ArrayVec[u32, 16].new()
items.push(42)?   ## Returns Err if full
items.push(99)?

## Lock-free ring buffer for ISR → main communication
static RING: RingBuffer[u8, 256] = RingBuffer.new()

@[interrupt]
def USART1_IRQHandler()
  let byte = volatile_read(USART1_DR as *const u8)
  let _ = RING.push(byte)
end

def main() -> !
  loop
    if let Some(byte) = RING.pop() then
      process(byte)
    end
  end
end
```

## Real-Time Safety

Tangerine can enforce worst-case execution time (WCET) budgets:

```tangerine
@[real_time(wcet_us = 100)]
def control_loop()
  let sensor = adc.read_channel(0)?
  let output = pid_controller.update(sensor)
  dac.write(output)
end
```

The `@[no_heap]` attribute prevents any heap allocation in a function, enforced at compile time:

```tangerine
@[no_heap]
def isr_safe_function(data: &[u8]) -> u32
  ## Compile error if any heap allocation occurs here
  data.iter().fold(0u32, |acc, b| acc + *b as u32)
end
```

## Cross-Compilation

```bash
# Build for the REAL bare-metal target (aarch64 — the aarch64 backend)
tg build --target aarch64-unknown-none --release

# The Thumb (thumbv6m/thumbv7em/thumbv8m.main) and RISC-V
# (riscv32imc/riscv32imac/riscv64gc) embedded triples are HARD-REJECTED
# by the --target embedded route: the route emits the stable diagnostic
# and NO artifact (no triple generator there — no fabricated image).

# The ARMv7-M / RISC-V code generators live on the LIR route
# (env-gated, default off): compile a single file to a relocatable ELF
# object for a per-CPU descriptor
TANGERINE_LIR=1 TANGERINE_LIR_TARGET=cortex-m4f tg build file.tg --emit-obj
TANGERINE_LIR=1 TANGERINE_LIR_TARGET=riscv32imac tg build file.tg --emit-obj
# Accepted targets: aarch64 (default), cortex-m3/cortex-m4/cortex-m4f/
# cortex-m7 ("cortex-m" = the cortex-m4f legacy alias), riscv32imac/
# riscv32imafc/riscv32imafdc/riscv64imac/riscv64gc ("riscv32"/"riscv64"
# = the imac legacy aliases). Unknown values fail closed.
```

## Best Practices

1. **Always use volatile access** for memory-mapped peripherals
2. **Minimize critical section duration** to reduce interrupt latency
3. **Use `@[no_heap]`** on interrupt handlers and real-time functions
4. **Prefer `ArrayVec` and `RingBuffer`** over heap-allocated collections
5. **Enable LTO and size optimization** in release builds
6. **Test on host first** using the HAL trait abstraction for mocking
7. **Document WCET budgets** for all real-time paths

## See Also

- [std/embedded.tg](../std/embedded.tg) — Full API reference
- [std/simd.tg](../std/simd.tg) — SIMD for DSP on embedded
- [examples/embedded_blinky.tg](../examples/embedded_blinky.tg) — Minimal example
- [docs/current/memory_model.md](memory_model.md) — Ownership in no_std contexts
