# Design notes: making a PAL (50 Hz) version of the VirtualTap CPLD logic

**Historical.** Written before anything was built, as a plan for the PAL bitstream. What shipped differs: the output-side genlock described in section 3 was tried (commit c5a3582), dropped for a free-running raster (e8ccc0b), and replaced by locking the Virtual Boy to the output through the servo main sync (f24f895 and later). The current design is described in the header of `VT_pal2.v` and in `README.md` next to this file; those win wherever they disagree with this document. The timing analysis and the constants below still apply.

## 0. What "PAL" means here

The board outputs analog RGB plus composite sync through a THS7373. There is no color encoding, so "NTSC" and "PAL" only mean line/frame timing: 60 Hz / 262 lines vs 50 Hz / 312 lines (progressive, the "288p" trick every 50 Hz console uses). Any RGB SCART TV, most OSSC/RetroTINK-type scalers and most capture cards accept 50 Hz progressive RGB.

Why bother: the Virtual Boy refreshes at 50 Hz. The existing NTSC build runs 60 Hz output from a 50 Hz source, so every fifth VB frame is shown twice (judder) and the vsync phase wanders, so latency wanders between 0 and one output frame. A 50 Hz output can be genlocked to the VB frame and shows every frame exactly once, with constant and minimal latency.

## 1. Start from the NTSC file, not the VGA file

`VT_ntsc2.v` is the right base:

- It already outputs composite sync on `V_VS` (no `V_HS` pin).
- It already uses the 5-slot `HSTRETCH` scheme (one SRAM write slot, four read slots) and 5× horizontal stretch, which fits PAL line timing too.
- It advances `BUFFER_WR` on the **falling** edge of `VB_CS` (`VB_CS_SR == 4'b1100`), i.e. when a VB frame finishes. The VGA file uses the rising edge (`2'b01`), which costs a full extra frame of latency. Keep the falling-edge version.
- It gates the pixel latch with `!WRITE_FLAG`, the VGA file does not.

Copy `VT_ntsc2.v` to `VT_pal2.v`, rename the module to `VT_PAL2`, update the header comment.

## 2. Timing constants

Clock is 40 MHz, 25 ns per clock. All numbers below are in 40 MHz clocks unless stated.

| Item | NTSC file today | PAL value | Notes |
|---|---|---|---|
| Line period | 2542 (`HCOUNT < 2541`) | **2560** (`HCOUNT < 2559`) | 64.000 µs exactly |
| HSYNC pulse | `!(HCOUNT < 188)` | same, 188 | 4.7 µs |
| Active start (H) | 500 | **540** | ≥ 12 µs after sync start (sync 4.7 + back porch 5.7 µs = 480 clk), plus centering margin |
| Active end (H) | 2410 | **2460** | must be ≤ 2494 (front porch 1.65 µs = 66 clk before next sync) |
| Active width | 1910 | **1920** | 384 columns × 5 clocks. NTSC has 1910, which is 382 columns; either a deliberate crop or an off-by-10. Use 1920 and check the last two columns show |
| Lines per frame | 262 (`VCOUNT == 261`) | **312** (`VCOUNT == 311`) free-running, or genlocked (see §3) | 312 × 64 µs = 19.968 ms = 50.08 Hz |
| VSYNC lines | `VCOUNT < 6` | same, 6 | XORed with HS, gives inverted-sync "broad pulses". Non-standard but every 50/60 Hz TV accepts it. PAL standard is 2.5 lines; 5 or 6 both work |
| Active lines (V) | 24..247 | **56..279** | 224 rows, no vertical doubling. PAL visible region is roughly lines 23..310 (288 lines); 224 centered in 288 leaves 32 blank lines top and bottom |

Register widths already suffice: `HCOUNT` is 12 bits (max 4095), `VCOUNT` is 9 bits (max 511).

Resulting picture geometry: 48 µs of 52 µs width (92 %), 224 of 288 lines height (78 %). On a 4:3 display that gives an image aspect of about 1.58, closer to the VB's native 384:224 = 1.71 than the NTSC build (about 1.30, noticeably squashed). If a wider image is wanted, 6× stretch (2304 clocks = 57.6 µs) does not fit in the 52 µs active window, so 5× is the practical maximum.

Concrete edits in `VT_pal2.v`:

```verilog
// 50Hz progressive, 312 lines
//   W=384*5=1920px
//   H=224*1=224px
assign ACTIVE_V = (VCOUNT >= 56) && (VCOUNT < 280);
assign ACTIVE = (HCOUNT >= 540) && (HCOUNT < 2460) && ACTIVE_V;
assign NTSC_HS = !((HCOUNT >= 0) && (HCOUNT < 188));   // rename to PAL_HS if you like
assign NTSC_VS = ((VCOUNT >= 0) && (VCOUNT < 6));
assign V_VS = NTSC_HS ^ NTSC_VS;
...
	// 1clk = 25ns, 1 PAL line = 64.000us = 2560clk
	if (HCOUNT < 2559)
...
		if (VCOUNT == 311)	// Whole frame (free-running variant)
```

## 3. Genlock to the Virtual Boy (the actual payoff)

### Why

With a free-running 312-line frame (50.08 Hz) against the VB's ~50 Hz, the phase drifts slowly and a frame is dropped or repeated every few seconds, and latency still cycles between 0 and 20 ms. Resetting the output frame counter from the VB frame pulse removes both effects.

### How

Do not reset `VCOUNT` in the middle of a line, that breaks HSYNC. Latch a request on the `VB_CS` falling edge and act on it at the next line wrap:

```verilog
reg FRAME_REQ;
...
	// Detect VB_CS falling edge (existing block)
	if (VB_CS_SR[3:0] == 4'b1100)
	begin
		WRITE_ADDR <= 14'h0000;
		BUFFER_WR <= BUFFER_WR + 1'b1;
		FRAME_REQ <= 1'b1;			// NEW
	end
...
	else
	begin
		// New raster line
		HCOUNT <= 0;
		READ_COUNTER <= 0;
		HSTRETCH <= 0;
		...
		// New frame when VB says so, or after a timeout so the TV keeps sync with no VB signal
		if (FRAME_REQ || (VCOUNT == 330))
		begin
			FRAME_REQ <= 1'b0;
			VCOUNT <= 0;
			READ_OFFSET <= 0;
			PAIR_INDEX <= 3'd0;
			BUFFER_RD <= BUFFER_WR - 1'b1;
			// PAL_SW handling unchanged
			...
		end
		else
			VCOUNT <= VCOUNT + 1'b1;
	end
```

Notes on this block:

- `FRAME_REQ` is set on the edge clock and consumed at a later line wrap, so `BUFFER_WR` has already advanced when `BUFFER_RD <= BUFFER_WR - 1` runs. `BUFFER_RD` therefore points at the frame that just finished writing. Latency from end of VB burst to first active output line is then 56 lines ≈ 3.6 ms, plus up to one line (64 µs) of quantization, and it is constant.
- The frame will alternate between 312 and 313 lines if the VB period is not an integer number of 64 µs lines (20.000 ms = 312.5 lines). Analog TVs do not care. Some digital TVs, scalers and capture cards do; if the target device loses lock or judders, fall back to free-running 312 (leave `FRAME_REQ` out, keep `VCOUNT == 311`). Consider making this a `` `define GENLOCK `` so both builds come from one file.
- Timeout value 330 is arbitrary, anything above 313 and below 512 works. It only matters when the VB is off or unplugged: the TV still gets a valid 50 Hz-ish signal.
- Put `FRAME_REQ <= 0;` in the `initial` block for simulation.
- If the fitter runs out of LEs (see §6), replace `VCOUNT == 330` with a cheaper decode like `VCOUNT[8] & VCOUNT[6]` (first hit at 320).

### Single vs double buffer with genlock

Keep the `MODE` pin and the 4-buffer scheme as they are. With genlock and `MODE=1` the extra buffer costs nothing in latency any more (read buffer is always the just-completed frame), and it protects against the VB's next burst overwriting the frame while it is still being scanned. Whether `MODE=0` (single buffer) is tear-free depends on where the VB burst sits inside the 20 ms period relative to our 224 active lines (lines 56..279 = 3.6 ms..17.9 ms after the CS falling edge). The VB draws one eye in a burst of roughly 5 ms; if the next burst starts before 17.9 ms after the previous one ends, the bottom of the picture tears in `MODE=0`. Measure before promising anything (§5).

## 4. Quartus project changes

- Add a third revision to `logic/VBTVout.qpf`:
  ```
  PROJECT_REVISION = "VBTVout_PAL2"
  ```
- Copy `VBTVout_NTSC2.qsf` to `VBTVout_PAL2.qsf`. In it set:
  ```
  set_global_assignment -name TOP_LEVEL_ENTITY VT_PAL2
  set_global_assignment -name VERILOG_FILE VT_pal2.v
  ```
  Beware: the existing `.qsf` files say `TOP_LEVEL_ENTITY VBTVout_NTSC2` and `VERILOG_FILE VBTVout_ntsc2.v`, but the real module is `VT_NTSC2` in `VT_ntsc2.v`. The checked-in project does not synthesize as-is; fix the names for the new revision (and ideally for the old two while you are there).
- Pin assignments are identical to NTSC (composite sync on `V_VS`, no `V_HS`). Do not touch the `set_location_assignment` lines.
- Device: MAX V `5M240ZT100C5`. Quartus II 12.0 was used originally; 13.0sp1/13.1 Web Edition and Quartus Prime Lite both list MAX V. Verify the device appears in whichever version you install before committing to it.
- Output `.pof` goes next to the others as `VT_PAL2.pof`. Program over the 6-pin JTAG header with a USB Blaster (`JTAG_pinout.png`).

## 5. Things to measure on real hardware first

No VB timing was measured for these notes. Two numbers decide the tear-free question and the vertical placement, get them with a scope or logic analyser on the FPC tap:

1. `VB_CS` high time per frame (the column burst; expected on the order of 5 ms) and whether `VB_CS` is a single pulse per frame. The whole design assumes one pulse per frame; if it toggles per column the `WRITE_ADDR` reset logic would already be broken today, so it almost certainly is one pulse.
2. `VB_CS` period (expected ≈ 20 ms). This is the output frame period under genlock. If it is far from 312.5 lines, adjust the timeout and check the TV still locks.

## 6. Fitting

The 5M240Z has 240 LEs and no RAM. The NTSC design is presumably near full. The PAL changes add one flip-flop (`FRAME_REQ`) and one 9-bit compare; changed constants cost nothing. Check the Fitter report after compile. If it does not fit: simplify the timeout compare (§3), or drop the `VB_CLEAR`/`VB_CLK*` unused inputs from the port list (they are declared but unused, they should already be optimized away).

## 7. Simulation before flashing

No testbench exists in the repo and Quartus 12 ModelSim is painful. A quick Icarus Verilog (`brew install icarus-verilog`) testbench is worth it:

- Model the SRAM as `reg [15:0] mem [0:65535]` driven from `SRAM_ADDR`/`SRAM_DATA`/`nSRAM_WE`/`nSRAM_OE`.
- Stimulus: 40 MHz clock; a `VB_CS` pulse every 20 ms that is high for 5 ms; inside it, 384 × 28 `VB_SHIFT` pulses with `VB_PIXELS` set to a recognisable pattern (the tester firmware's checkerboard, `x & 8` and `y & 1`, is convenient). Copy the strobe shape from `p_shift()` in `tester/firmware/hw.c`: data set, CS high, SHIFT high, SHIFT low.
- Checks: `V_VS` low-going edges every 2560 clocks outside vsync; 312 or 313 lines between frame starts; ACTIVE asserted for exactly 1920 clocks per active line and 224 lines per frame; `BUFFER_RD` equals the buffer that was just written when the frame starts; dump `V_RED/GREEN/BLUE` per active pixel into a PGM file and eyeball that the checkerboard comes out upright and complete (all 384 columns, all 224 rows).
- Run the same testbench on `VT_ntsc2.v` first to make sure the bench itself is sane.

## 8. Hardware test checklist

1. Flash `VT_PAL2.pof`, connect to a 50 Hz RGB SCART TV or OSSC. Picture should lock immediately.
2. Scope `V_VS`: 64.0 µs line, sync pulse 4.7 µs, frame 20 ms locked to `VB_CS`.
3. Run a game with content at the screen edges; confirm columns 0 and 383 and rows 0 and 223 are visible (checks the 1920/224 windows and the `READ_COUNTER` first-column behaviour).
4. Cycle palettes with `PAL_SW`, confirm all 8 still work (frame-reset block moved, make sure the `PAL_SW_SR` logic stayed inside it).
5. Toggle `MODE` and look for tearing at the bottom of the picture in `MODE=0`.
6. Latency: film the VB eyepiece and the TV together at high frame rate, or use a photodiode on both. Expect about 4 ms plus scan position with genlock.
7. Try a picky digital device (capture card, modern TV HDMI via scaler). If it drops lock on the 312/313 alternation, ship the free-running build as an alternative `.pof`.

## 9. Keep in sync

The palette LUT and the VB bus capture logic are duplicated in every `.v` file. Any later fix to those must be applied to `VT_vga2.v`, `VT_ntsc2.v` and `VT_pal2.v`. Update `README.md` (top-level and `logic/`) to mention the third bitstream. The repository is GPL-2.0 (`LICENSE`), the new file inherits it.
