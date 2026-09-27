# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

Hardware project, not a software package. VirtualTap is a mod board for the Nintendo Virtual Boy that taps one eye display's pixel bus and outputs VGA or NTSC RGB. The repo holds everything needed to build, program and test the board: Verilog for the CPLD, PCB/Gerber/BOM, AVR firmware for two helper boards, and installation manuals. The original author (furrtek) no longer produces kits; the repo is archival/community-maintained. Recent commits are doc fixes and BOM updates.

There is no CI, linter, or top-level build. Each subproject uses its own vendor toolchain. The only automated check is the Icarus Verilog bench in `logic/sim/` (`run.sh pal`), which is pixel-exact and must pass after any change to `VT_pal2.v`.

## Subprojects and how to build them

### `logic/` — CPLD bitstreams (Altera Max V 5M240ZT100C5, Quartus II 12.0)

- One Quartus project (`VBTVout.qpf`) with two revisions: `VBTVout_VGA2` and `VBTVout_NTSC2`, each with its own `.qsf` and top-level module (`VT_vga2.v` → `VT_VGA2`, `VT_ntsc2.v` → `VT_NTSC2`).
- Prebuilt bitstreams `VT_VGA2.pof` / `VT_NTSC2.pof` are checked in; flashing needs a Quartus version supporting Max V plus a USB Blaster on the 6-pin JTAG header (see `JTAG_pinout.png`).
- **Known inconsistency**: the `.qsf` files reference `VBTVout_vga2.v` / `VBTVout_ntsc2.v` and `TOP_LEVEL_ENTITY VBTVout_*`, but the actual files/modules are `VT_vga2.v` / `VT_VGA2` etc. Opening the project in Quartus will need those assignments fixed (or the files renamed) before it synthesizes.
- `assignments.csv` is a pin-assignment export duplicating the `set_location_assignment` lines in the `.qsf` files. The NTSC `.qsf` lacks the `V_HS` pin (composite sync only).
- `logic/sim/run.sh` runs Icarus Verilog benches (`tb_servo.v` for the PAL design, `tb.v` for NTSC, `tb_dbg.v` for the probe); `initial` blocks in the Verilog exist only for them. Run sims and Quartus compiles one at a time on the user's VM.
- The PAL revision (`VBTVout_PAL2`, `VT_pal2.v`) is the only one that compiles as-is with Quartus Prime Lite; it is a different architecture from VGA/NTSC (rigid raster, single buffer, the CPLD drives the Virtual Boy's servo main sync and phase-steps it so the transfer burst sits in vblank; read the header of `VT_pal2.v` and `logic/README.md`). The `.pof` checked in must always match the committed RTL.

### `servo_emu/firmware/` — servo board emulator (ATtiny25, internal 8 MHz RC, CKDIV8 off)

Only subproject with a Makefile. Build with avr-gcc (`brew install avr-gcc` on macOS; verified to compile with current avr-gcc):

```sh
cd servo_emu/firmware/tl866_programmer
make            # produces servo_emu.elf, servo_emu.hex, servo_emu.eep
make clean
```

Fuses are documented in the header comment of `servo_emu.c`: Ext 0xFF, High 0xDF, Low 0xE2. The `.aps` file (AVR Studio 4) targets `attiny45` while the Makefile and source say `attiny25` — the Makefile is authoritative. `tl866_programmer/readme.txt` explains that the `.hex` there was rebuilt by a contributor because the original hex failed to flash with a TL866 II Plus; both hex files are kept.

### `tester/firmware/` — production test jig (ATmega8 @ 16 MHz, 38400 baud UART)

AVR Studio 4 project (`tester.aps`), no Makefile. Equivalent manual build:

```sh
cd tester/firmware
avr-gcc -mmcu=atmega8 -Os -std=gnu99 -Wall -funsigned-char -funsigned-bitfields -fpack-struct -fshort-enums -o tester.elf *.c
avr-objcopy -O ihex -R .eeprom tester.elf tester.hex
```

**This does not compile on modern avr-gcc**: `data.c` declares non-`const` `PROGMEM` arrays/strings, which newer compilers reject ("variable ... must be const in order to be put into read-only section"). It was built with WinAVR-20100110. To build today, add `const` to the `PROGMEM` declarations in `data.c`/`data.h` and the matching `serial_print` signature in `uart.h`/`uart.c`. The checked-in `tester.hex` is the original build.

### `pcb/`, `servo_emu/pcb/`, `tester/pcb/`

Proteus project (`vt_c.pdsprj`), schematic PNGs, Gerber zips, and the BOM (`pcb/vt_c_BOM.csv`, CSV with Category/Quantity/References/Value/Notes/Stock Code columns). Board revision is "C" (`vt_c_*`). Nothing to build; edits are usually BOM part substitutions.

## Architecture: how the video pipeline works

Understanding this requires reading the Verilog together with the README and the tester firmware.

**Input side (Virtual Boy bus)**: the VB sends each display column as 28 words of 16 bits (`VB_PIXELS`), strobed by `VB_SHIFT` while `VB_CS` is high; a `VB_CS` rising edge marks a new frame. Each 16-bit word packs 8 pixels × 2 bits, but with an interleaved bit order — see the `PAIR_INDEX` case in the Verilog and `lut_order[]` in `tester/firmware/data.c`, which must agree. The frame is 384 columns × 224 rows, stored column-major: `WRITE_ADDR` increments per word, so column *c* lives at addresses `c*28 .. c*28+27`.

**SRAM framebuffer**: a 64K×16 SRAM is time-multiplexed between writes (latched VB words) and reads (output scan). In VGA, `CYCLE = HCOUNT[0]` alternates read/write every 40 MHz clock. In NTSC, a 5-state `HSTRETCH` counter does one write slot then four read slots (also providing 5× horizontal stretch). `SRAM_ADDR` is muxed accordingly; `nSRAM_WE`/`nSRAM_OE` are complementary.

**Double buffering**: the top two address bits select one of four 16K buffers. When `MODE` is high, `BUFFER_WR` advances each VB frame and `BUFFER_RD` is set to `BUFFER_WR - 1` each output frame (tear-free but a frame of latency). When `MODE` is low both are forced to buffer 0 (single buffer, lower latency, possible tearing). `MODE` and `PAL_SW` need pull-ups (enabled in the `.qsf`).

**Output scan / rotation**: the VB frame is stored by column, so the output reads "rotated": `READ_COUNTER` steps by 28 per output pixel (next column), `READ_OFFSET` selects the 8-pixel word within the column, and `PAIR_INDEX` selects the 2-bit pixel inside that word. VGA doubles pixels horizontally (advance only on `~CYCLE`) and vertically (advance `PAIR_INDEX` only on odd `VCOUNT`), giving 768×448 inside 800×600@60. NTSC stretches 5× horizontally with no vertical doubling (1920×224 inside 262 lines, composite sync on `V_VS`).

**Palette**: 8 palettes in a `case` LUT, each a 24-bit constant = 4 colors × (R,G,B) × 2 bits, brightest first. `PAL_SW` falling edge (sampled once per frame) cycles `PALETTE`. Output is 2 bits per channel through R-2R DACs into a THS7373 amp, so only the 64 colors in `logic/colors.png` are reachable. `logic/README.md` documents how to edit palettes; keep both `.v` files in sync since the LUT is duplicated.

**VGA vs NTSC files are near-copies**: `VT_vga2.v` and `VT_ntsc2.v` differ only in sync timing, the read/write slot scheme, stretch factors, and edge-detector widths. Any fix to shared logic (palette, buffer switching, VB bus capture) must be applied to both.

**Servo emulator**: independent of the video path. Replaces the mechanical mirror-servo board so the VB boots without displays. A 50 µs timer ISR generates 50 Hz main sync plus phased eye A/B feedback and bit-bangs an 8-bit "frame duration" value (`TIMING_DATA = 0xA4`) over a clock/data pair twice per cycle. Pin mapping VB↔MCU is in the source header.

**Tester**: drives the VB-side FPC connector through 74-series latches (`latch_out`/`latch_in` in `hw.c`) to inject test patterns (checkerboards, counter, per-palette brightness bars with letters) and loops back the bus for connectivity checks; reports over UART. `p_shift()` emulates one VB word strobe and is the reference for the bus protocol timing.

## Conventions

- Verilog uses tabs, `UPPER_CASE` signal names, non-blocking assigns inside combinational `always @(*)` (legacy style; keep consistent within a file).
- Firmware is C99 for avr-libc, tabs, direct register access, no HAL.
- Manuals in `doc/` are PDFs (EN/FR); the last commit fixed the VGA pinout in them — pinout changes must be mirrored there.
- License in `LICENSE` must be respected for any redistribution (see README).
