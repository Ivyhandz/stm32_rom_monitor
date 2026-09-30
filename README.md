# STM32 ROM Monitor

A bare-metal, hand-written ARM assembly ROM monitor for the STM32F103C8T6 (Blue Pill).
No HAL, no CMSIS, no C runtime — the vector table, boot sequence, UART driver, command
parser, and exception handler are all written directly in Thumb-2 assembly.

Once flashed, the chip boots straight into an interactive command prompt over UART,
giving direct read/write access to memory and CPU registers, the ability to load and
execute arbitrary code, and automatic recovery from a crashed program — no debugger
attached, just a serial cable.

## Why

Most student microcontroller projects go through HAL or a framework, which hides exactly
the register-level detail that matters for embedded roles. This project goes the other
direction: every peripheral is configured by hand, from the datasheet, to demonstrate a
real understanding of the STM32F103's memory map, boot sequence, and exception model.

## Hardware

- STM32F103C8T6 (Blue Pill)
- ST-Link V2 — used once, to flash the monitor into flash memory
- Any 3.3V-logic USB-to-TTL adapter (CH340G / CP2102) — the serial console, used every time you run the monitor

Wiring:

| Signal | Blue Pill pin |
|---|---|
| UART TX (adapter RXD) | PA10 |
| UART RX (adapter TXD) | PA9  |
| GND | GND |
| 3.3V (only if powering from the adapter) | 3V3 |

## Command set

```
d <addr>          dump 64 bytes of memory (hex + ASCII)
w <addr> <byte>    write one byte
W <addr> <word>    write one 32-bit word
g <addr>          load-and-execute: jump to and run code at addr
r                 dump MSP, PSP, PRIMASK, CONTROL
?  /  h            this help
```

`d` and `w`/`W` work on any memory-mapped address — flash, RAM, or peripheral registers.
`g` repoints the CPU's program counter directly to the given address, so code
poked into RAM with `W` can be run with nothing more than a serial cable — no debugger
needed. If that code crashes, the Cortex-M3's hardware traps it, `HardFault_Handler`
prints the exact register frame at the moment of the fault, and control returns cleanly
to the prompt.

## Repository contents

| File | Purpose |
|---|---|
| `monitor.s` | The entire firmware — vector table, boot code, UART driver, parser, commands, fault handler |
| `linker.ld` | Memory map for this chip (64K flash / 20K RAM) and section placement |
| `rom_monitor.resc` | Renode script to run the firmware in simulation, no hardware required |
| `.gitignore` | Excludes build output (`.elf`/`.bin`/`.o`) from version control |

## Building

Requires the [Arm GNU Toolchain](https://developer.arm.com/downloads/-/arm-gnu-toolchain-downloads) (`arm-none-eabi-gcc`/`objcopy`) on your PATH.

```bash
arm-none-eabi-gcc -mcpu=cortex-m3 -mthumb -nostdlib -nostartfiles \
    -T linker.ld monitor.s -o monitor.elf

arm-none-eabi-objcopy -O binary monitor.elf monitor.bin
```

## Flashing

Using [STM32CubeProgrammer](https://www.st.com/en/development-tools/stm32cubeprog.html) with an ST-Link V2 connected via SWD (SWDIO/SWCLK/GND/3.3V):

```
STM32_Programmer_CLI -c port=SWD -w monitor.bin 0x08000000 -v -rst
```

Or use the GUI: connect, open `monitor.bin`, set the download address to `0x08000000`, and click Download.

## Running

1. Wire up a 3.3V USB-to-TTL adapter as described above (no ST-Link needed for this — the chip runs standalone from flash)
2. Open a serial terminal (PuTTY, `screen`, `minicom`) at **9600 8N1**
3. Reset the board
4. You should see:

```
=== STM32F103 ROM Monitor v0.1 ===
Type ? for help

>
```

## Simulating without hardware (Renode)

The same `monitor.elf` runs unmodified in [Renode](https://renode.io/), useful for
validating firmware logic independent of any wiring or hardware fault:

```bash
renode rom_monitor.resc
```

This loads the ELF against Renode's STM32F103 CPU model, maps USART1 to a live terminal
window, and boots the monitor — the banner and prompt appear identically to real
hardware, with zero physical connections.

**Known simulation limitations:** Renode's bundled STM32F1 peripheral models are
incomplete in a few places — the RCC clock-enable register is a stub (reads/writes are
logged but don't gate anything), and GPIO ports only support word-sized register access,
so `d`-ing a GPIO address will log warnings in Renode that don't occur on real silicon.
Memory (RAM/flash) access, the full command set, and fault handling are unaffected and
behave identically to hardware.

## Example session

```
> ?
d <addr>          dump 64 bytes
w <addr> <byte>   write byte
W <addr> <word>   write word
g <addr>          execute at addr
r                 system registers
?                 this help

> d 08000000
08000000: 00 50 00 20 41 00 00 08 73 00 00 08 2D 03 00 08 |.P. A...s...-...|
...

> W 20000100 DEADBEEF
OK
> d 20000100
20000100: EF BE AD DE 00 00 00 00 00 00 00 00 00 00 00 00 |................|
...

> W 20000200 FFFFFFFF
OK
> g 20000200
*** HARD FAULT ***
R0   = 20005000
R1   = 00000008
R2   = 000000C0
R3   = 00000000
R12  = 00000000
LR   = 080002D9
PC   = 20000200
xPSR = 21000000

>
```

The last sequence deliberately writes an invalid Thumb instruction into RAM and jumps to
it. The CPU's hardware detects the illegal opcode, traps into `HardFault_Handler`, which
prints the automatically-saved register frame and hands control back to the prompt —
demonstrating exception handling without a debugger attached, and without requiring a
manual reset.

## Known limitations

- `d`/`w`/`W` operate on RAM, flash, and peripheral registers, but `w`/`W` cannot write to
  flash — flash writes require an unlock/erase/program sequence not implemented here, so
  writes are effectively RAM-only in practice.
- No single-step or breakpoint support. That would require driving the Cortex-M3's DWT
  and FPB debug units directly — a substantially larger undertaking than what's here, and
  a natural next step.
- No disassembler — `d` shows raw hex, not decoded mnemonics.
- `get_hex` stops parsing at the first non-hex character rather than rejecting the whole
  token — `W 20000100 ACQUIRED` silently parses only `AC` rather than reporting an error.

## Design notes

- No `.data` section: the firmware has no initialized variables, only a single
  zero-initialized buffer (`line_buf`, in `.bss`), so no flash-to-RAM copy step is needed
  at boot.
- UART runs on the default 8 MHz HSI oscillator, no PLL — kept deliberately simple at the
  cost of being limited to lower baud rates (9600 here; HSI's ~1% tolerance makes higher
  rates like 115200 unreliable without a crystal-derived clock).
- `g <addr>` manually loads the link register with a return address before jumping, since
  it uses `bx` rather than `bl` — this is what allows control to return to the monitor's
  main loop if the executed code itself ends in `bx lr`.
