# Bitstreams

* `VT_VGA2.pof`: 800x600@60 VGA, separate H/V sync.
* `VT_NTSC2.pof`: 60 Hz / 262-line progressive RGB, composite sync on `V_VS`.
* `VT_PAL2.pof`: 50 Hz / 314-line progressive RGB, composite sync on `V_VS`, **the Virtual Boy is locked to VirtualTap** instead of the other way round. The output raster is free-running and rigid (every frame exactly 314 lines of 2562 clocks = 64.05 us, 49.72 Hz, 3 lines of vertical sync); nothing in it ever changes, so displays that show the slightest timing kick stay steady. The CPLD generates the mirror servo main sync from its own crystal and steps that servo cycle by one line per frame until the VB's column transfer burst sits inside the output's vertical blanking. The single framebuffer is then never read while written: no tear, no dropped or repeated frames, no jitter, and a fixed 3.6 ms between the end of the burst and the first displayed row. The 8 palettes cycled by `PAL_SW` as in the other builds; `MODE` is unused. The servo sync is placed so that, on the calibrated unit, the first burst after power-up already ends on the target line (`` `define INIT_FALL_LINE `` in `VT_pal2.v`: build once with `` `define CALIBRATE ``, read the 9-bit line number it paints on lines 64..79, MSB left, bright = 1, put it there); on another unit the loop moves the burst into the blanking in 8-line steps (1-line steps once within 8 lines), deciding every other frame, at most ~56 frames (1.1 s); the framebuffer is shown from power-up as in the other builds (SRAM noise before the first burst, possibly a torn frame or two while the loop moves the burst).

  Tested setup: the servo emulator stays on the VB's servo connector running `servo_emu/firmware/servo_emu_vtsync.c` (its PB2 becomes a sync input, everything else unchanged), and one wire goes from VirtualTap J1 pin 8 (the `V_HS` pad, now `SERVO_SYNC`) straight to the emulator's PB2 / VB pin 6 net; both accept the 3.3 V level (a 5 V-powered 74HCT1G125 in the wire if another VB does not). The ATtiny restarts its 20 ms cycle on each rising edge, the VB follows the ATtiny. Commit f24f895 also let the CPLD generate eye A/B and the frame-duration bytes itself for a setup without the emulator (never tested); dropped since to free logic cells. The eyepiece mirrors are not synchronised in either case, same as with the plain emulator.
* `VT_dbg.v` (revision `VBTVout_DBG`, no `.pof` checked in): not a video mode but a probe. Paints the raw `VB_CS` (red) and `VB_SHIFT` (blue) lines on the PAL raster with a reference bar the length of the vertical blanking, plus binary readouts of the `VB_CS` period and high time in 40 MHz clocks. Used to measure the Virtual Boy's transfer timing before designing the PAL lock; build it when you need to see what the CPLD sees.

The Quartus project `VBTVout.qpf` has one revision per bitstream. The NTSC and VGA revisions reference source files under their old names; the PAL revision (`VBTVout_PAL2.qsf`) compiles as-is with Quartus Prime Lite plus the MAX V device support.

# Simulation

`sim/run.sh pal [DLY_ns] [NFRAMES] [CHECK_FROM]` runs an Icarus Verilog bench (`sim/tb_servo.v`) that models the SRAM and a Virtual Boy whose transfer burst starts `DLY` after the servo eye A feedback falls; it checks the rigid raster (line and frame length), sync pulse widths, the servo signal timing and frame duration bytes, that the SRAM is never read during the burst, and every displayed pixel from output frame `CHECK_FROM` on. `sim/run.sh ntsc` runs the older bench (`sim/tb.v`) on the NTSC design; `sim/tb_dbg.v` is the bench of the probe. Icarus Verilog is enough for all of them; `.svf` files for OpenOCD are made from a `.pof` with `quartus_cpf -c -q 10MHz -g 3.3 -n p X.pof X.svf` and are not checked in. Run the PAL one after editing anything in `VT_pal2.v`.

# How to program the CPLD

Download a version of Quartus which supports the Max V series, and buy (or build) a fake $30 Altera USB Blaster cable.
Connect the 6 JTAG pins on the board to the programmer, provide power to the board and write one of the `.pof` files.

# Creating custom palettes

The same `case` block exists in `VT_pal2.v`; keep the three files in sync.

The 8 default palettes can be modified to suit your needs by editing the following section of Verilog code:

```
// Palette LUT
always @(*) begin
				     // 3     2     1     0
	case(PALETTE)		     // RRGGBBRRGGBBRRGGBBRRGGBB
		3'd0: PAL_COLORS <= 24'b110000100000010000000000;	// Red gradient
		3'd1: PAL_COLORS <= 24'b111100101000010100000000;	// Yellow gradient
		3'd2: PAL_COLORS <= 24'b001100001000000100000000;	// Green gradient
		3'd3: PAL_COLORS <= 24'b001111001010000101000000;	// Cyan gradient
		3'd4: PAL_COLORS <= 24'b000011000010000001000000;	// Blue gradient
		3'd5: PAL_COLORS <= 24'b110011100010010001000000;	// Magenta gradient
		3'd6: PAL_COLORS <= 24'b111111101010010101000000;	// White gradient
		3'd7: PAL_COLORS <= 24'b000000010101101010111111;	// White inverted gradient
	endcase
end
```

Each line in the `case` block defines the RGB values for each of the 4 colors of a given palette, top to bottom from 0 to 7.

The 24 bits represent the 2-bit values for each R, G and B component for each color index, left to right from brightest to darkest.

All combinations of colors are possible but the output is limited by the hardware to 2-bit per component, so the available colors can only be taken from the following table (which is coincidentally the Sega Master System palette):

![Virtualtap possible colors](colors.png)
