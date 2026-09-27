# VirtualTap_PAL

A fork of [furrtek/VirtualTap](https://github.com/furrtek/VirtualTap) that replaces the CPLD logic with a PAL (50 Hz) bitstream and adds the VirtualTap-synchronised servo emulator firmware it needs.

* **The servo emulator is required for this build**, not optional as upstream: the mechanical mirror servo board must be replaced by it (see the last two sections).
* The original VGA and NTSC bitstreams are not carried here; get them from upstream.
* The board, the servo emulator and the tester are furrtek's work and are unchanged. furrtek no longer makes or sells these boards; questions about the PAL build belong in this repository's issues, not with furrtek.
* Everything stays under the GPLv2 in `LICENSE`.

![Virtualtap pcb picture](photo.jpg)

* `doc`: Installation manuals.
* `logic`: Verilog sources, pin assignments and bitstream file for the PAL (50 Hz) version.
* `pcb`: Schematics, BOM and GERBER files.
* `servo_emu`: AVR firmware and hookup guide for the servo emulator, plus the VirtualTap-synchronised variant that the PAL bitstream requires.

## What it is
A small mod board made to be plugged inside a Nintendo Virtualboy unit to make it output standard RGB video (PAL 50 Hz in this fork; VGA and NTSC upstream).

## What this is
All the necessary files to make, assemble, and program the board yourself.
Please respect the LICENSE :3

## How it works
The signals sent to one of the Virtualboy's displays are tapped and level-translated to 3.3V for processing by a CPLD clocked at 40MHz. It interleaves the writes to a parallel SRAM chip (framebuffer) with reads to output the rotated frame one pixel at a time to three 2-bit R-2R DACs according to the selected palette. The voltages and the generated sync signal are fed to a 4-channel THS7373 video amp for final output to whatever socket the user wishes to use.

## Servo emulator

**Required for the PAL bitstream in this fork.** Upstream, the emulator is only for consolizing a Virtual Boy and removing the mechanical parts; here the CPLD generates the mirror servo's main sync itself and the emulator is what turns that into the signals the Virtual Boy expects, so the original servo board cannot stay. The PAL build does not work with the mechanical servo board.

The servo emulator makes the VirtualBoy think the eye displays are still there and working properly. Without it, the games won't start.

You only need to program a cheap microcontroler with this code and wire it up to your VirtualBoy's main board.

Porting the code to the Arduino Nano or other small AVR boards should be pretty straightforward.

## PAL bitstream: the Virtual Boy locked to VirtualTap

furrtek's VGA and NTSC bitstreams run their output free of the Virtual Boy's frame timing, so a frame is dropped or repeated now and then and the single-buffer mode can tear. The PAL bitstream (`logic/VT_PAL2.pof`, 50 Hz, 314-line progressive RGB) keeps its raster rigid too, but turns the relationship around: VirtualTap generates the mirror servo's 50 Hz main sync from its own crystal and nudges it until the Virtual Boy's column transfer lands inside the output's vertical blanking. The single framebuffer is then never read while it is written: no tear, no dropped or repeated frames, no jitter, and a constant 3.6 ms from the end of the transfer to the first displayed row.

This requires the servo emulator in place of the Virtual Boy's mechanical servo board, running `servo_emu/firmware/servo_emu_vtsync.c` instead of `servo_emu.c` (its main sync pin becomes an input), and one extra wire from VirtualTap's `V_HS` pad (J1 pin 8) to the emulator's PB2 / Virtual Boy servo connector pin 6. Everything else is unchanged. Details, calibration for another unit and the simulation bench are in `logic/README.md`.
