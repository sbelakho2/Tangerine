# Tangerine Embedded Systems Development Guide

> **Edition**: 2026 · **Module**: `std::embedded` · **Tier**: Tier 2+ targets

## Overview

Tangerine provides first-class support for bare-metal and embedded development through the `std::embedded` module. Combined with the ownership system and zero-cost abstractions, Tangerine delivers Rust-level safety guarantees in embedded contexts with a cleaner syntax.

## Target Platforms

| Target Triple             | Architecture | Tier | Status   |
|---------------------------|-------------|------|----------|
| `thumbv7em-none-eabihf`  | ARM Cortex-M4/M7 | 2 | Supported |
| `thumbv6m-none-eabi`     | ARM Cortex-M0/M0+ | 2 | Supported |
| `riscv32imac-unknown-none-elf` | RISC-V RV32 | 3 | Experimental |
| `aarch64-unknown-none`   | ARM Cortex-A (bare) | 3 | Experimental |

## Getting Started

### Project Setup

```toml
# Tangerine.toml
[package]
name = "my_firmware"
version = "0.1.0"
edition = "2026"

[target]
triple = "thumbv7em-none-eabihf"
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
# Build for Cortex-M4
tg build --target thumbv7em-none-eabihf --release

# Flash via OpenOCD
tg flash --probe openocd --chip stm32f407

# Debug with GDB
tg debug --probe openocd --chip stm32f407
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
