// VIRTUALTAP Rev. C CPLD logic
// Version 2-PAL "servo master", for Max V 5M240ZT100
// (C) 2018 Sean "furrtek" Gonsalves
// 50Hz / 314-line progressive RGB, derived from VT_ntsc2.v / VT_pal2_freerun314.v
//
// Output raster: free-running, rigid. Every frame is exactly 314 lines of exactly 2562 clocks
// (64.05us): 20.11ms = 49.72Hz. No line or frame is ever trimmed, so nothing in the sync stream
// changes from frame to frame (the user's ISL59885 + Sharp CZ-604D chain shows any timing kick,
// even 25ns on one line; this raster was verified rigid on it as VT_pal2_freerun314.v).
//
// Tear-free single buffer without touching the raster: instead of locking the output to the
// Virtual Boy, the Virtual Boy is locked to the output. The CPLD generates the mirror servo main
// sync (10 ms high per 20.11 ms cycle, the shape of servo_emu/firmware/servo_emu.c) from the 40 MHz
// crystal on a line counter SCOUNT that runs at the output frame rate; the servo emulator on the
// VB (servo_emu_vtsync.c) restarts its cycle on every rising edge and produces the rest (eye A/B
// feedback, frame duration bytes) from there, and the VIP starts its column transfer at a fixed
// delay after those edges. The transfer burst (5.32 ms = 83 lines, measured) therefore sits at a
// fixed place in the output frame, and a phase loop puts it in the vertical blanking: at every
// VB_CS falling edge (burst end) the output line VCOUNT is compared with the target line 52; if
// the burst ended late (lines 54..223) the next servo cycle is shortened, if early (224..313,
// 0..50) it is lengthened, lines 51..53 do nothing. Steps are 8 lines while the burst end is
// more than 8 lines off (lines 60..223 / 224..44) and 1 line inside; a request is applied at the
// next servo wrap and shows on the burst after the next, so the loop decides only every other
// burst. Power-up acquisition takes at most ~56 cycles (1.1 s), typically far less. The burst then covers lines 283..52, inside the blanking 280..55
// (reads happen on lines 56..279 only), so the single framebuffer is never read while it is
// written: no tear, no repeated or dropped frames, latency = time from the end of the burst to
// the scan of each row. Steps only ever move the Virtual Boy; the output never moves.
// The framebuffer is shown from power-up like in every other VirtualTap build (unwritten SRAM
// noise until the first burst, a torn frame or two if the loop still has to move the burst).
//
// Wiring, as tested on hardware (2026-09-26): one wire plus the servo emulator.
//   The ATtiny servo emulator (servo_emu/firmware/servo_emu_vtsync.c) stays on the VB's servo
//   connector and keeps generating eye A/B and the frame duration bytes at 5 V; its PB2 becomes an
//   input. SERVO_SYNC (CPLD pin 77 = J1 pin 8, the "V_HS" pad) goes straight to the emulator PB2 /
//   VB pin 6 net: the VB and the ATtiny accept the 3.3 V level. The ATtiny restarts its cycle on
//   every rising edge, the VB follows the ATtiny, and the loop below moves that edge. Should another
//   VB not take 3.3 V on pin 6, a 5 V-powered non-inverting buffer (74HCT1G125) in the wire is the
//   fix. Commit f24f895 also had the CPLD generate eye A/B and the frame duration bytes itself (for
//   a setup without the emulator, never tested); dropped for LEs.
//
// VB bus capture, SRAM addressing and the 8 palettes are those of VT_pal2_freerun314.v; the
// 4-buffer mode is gone (single buffer, SRAM_ADDR[15:14] = 0), MODE unused.

//`define CALIBRATE			// Calibration bitstream: loop frozen, picture always on, the output line on which the
							// VB burst ends is painted on lines 64..79 as 9 bits, MSB left, bright = 1. Read it,
							// put it in INIT_FALL_LINE below, rebuild without CALIBRATE.
`define INIT_FALL_LINE 240	// Burst end line measured with CALIBRATE and SYNC_RISE_LINE = 141 on this setup. The
							// servo sync is placed so the first burst after power-up already ends on line 52;
							// another VB/emulator/board may differ, the loop then just takes a few more frames.

module VT_PAL2 (
		input CLK_40M,
		input [15:0] VB_PIXELS,
		input VB_CS, VB_SHIFT,
		input VB_CLEAR,						// Unused
		input VB_CLKA, VB_CLKB, VB_CLKC,	// Unused, smooth fading
		input PAL_SW,						// Pull-up required ! Falling edge = next palette
		inout [15:0] SRAM_DATA,
		output [15:0] SRAM_ADDR,
		output nSRAM_WE, nSRAM_OE,
		output V_VS,						// Composite sync
		output [1:0] V_RED,
		output [1:0] V_GREEN,
		output [1:0] V_BLUE,
		output SERVO_SYNC					// VB servo pin 6, main 50Hz sync (see header)
);

reg [11:0] HCOUNT;		// Sync gen, 0..2561
reg [8:0] VCOUNT;		// Sync gen, 0..313
reg [1:0] PIXEL_OUT;
reg [3:0] VB_CS_SR;		// Shift registers for edge detection (as VT_pal2_freerun314.v)
reg [3:0] VB_SHIFT_SR;
reg WRITE_FLAG;
reg [13:0] WRITE_ADDR;
reg [15:0] PIXELS_IN;
reg [2:0] PAIR_INDEX;	// 0~7
reg [4:0] READ_OFFSET;	// 0~27
reg [13:0] READ_COUNTER;
reg ACTIVE, SCAN;		// Registered H windows, see below
reg [2:0] HSTRETCH;
reg [8:0] SCOUNT;		// Servo cycle line counter, 0..313, phase-stepped by the loop
reg SV_SYNC;
reg REQ_SKIP;			// Loop: shorten the next servo cycle (burst ended late)
reg REQ_HOLD;			// Loop: lengthen the next servo cycle (burst ended early)
reg COARSE;				// Loop: the pending step is 8 lines instead of 1 (burst end more than 8 lines off)
reg [2:0] HOLDN;		// Loop: extra lines still to hold beyond the first
reg SETTLE;				// A step was requested: ignore the next burst end, it predates the step
reg CS_LATE, CS_EARLY, CS_FAR;	// Classification of VCOUNT, registered (updated every clock)
reg LINE_END;			// HCOUNT == 2561, registered one clock early so the counters see a short path
reg [1:0] PAL_SW_SR;
reg [2:0] PALETTE;
reg [23:0] PAL_COLORS;
`ifdef CALIBRATE
reg [8:0] CAL_LINE;		// VCOUNT at the last VB burst end
`endif

// Servo sync placement: rises on SYNC_RISE_LINE, falls 156 lines (10 ms) later. With the sync on
// line 141 the burst ended on INIT_FALL_LINE; move the sync so it ends on 52 from the first frame.
// The decodes act one line early (outputs change on the next line), hence the *_M1 values.
localparam INIT_OFF = (`INIT_FALL_LINE >= 52) ? (`INIT_FALL_LINE - 52) : (`INIT_FALL_LINE + 314 - 52);
localparam SYNC_RISE_LINE = (141 >= INIT_OFF) ? (141 - INIT_OFF) : (141 + 314 - INIT_OFF);
localparam SYNC_FALL_LINE = (SYNC_RISE_LINE + 156 < 314) ? (SYNC_RISE_LINE + 156) : (SYNC_RISE_LINE + 156 - 314);
localparam SYNC_RISE_M1 = (SYNC_RISE_LINE == 0) ? 313 : (SYNC_RISE_LINE - 1);
localparam SYNC_FALL_M1 = (SYNC_FALL_LINE == 0) ? 313 : (SYNC_FALL_LINE - 1);

wire ACTIVE_V;
wire SYNC_H, SYNC_V;
wire CS_FALL;
wire [13:0] READ_ADDR;
wire [1:0] PAL_RED, PAL_GREEN, PAL_BLUE;

// Palette LUT (same as VT_vga2.v / VT_ntsc2.v)
always @(*)
begin						 // 11    10    01    00
	case(PALETTE)			 // RRGGBBRRGGBBRRGGBBRRGGBB
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

// Decompose PAL_COLORS to RGB depending on pixel value
assign PAL_RED = (PIXEL_OUT == 2'b11) ? PAL_COLORS[23:22] :
						(PIXEL_OUT == 2'b10) ? PAL_COLORS[17:16] :
						(PIXEL_OUT == 2'b01) ? PAL_COLORS[11:10] :
						PAL_COLORS[5:4];
assign PAL_GREEN = (PIXEL_OUT == 2'b11) ? PAL_COLORS[21:20] :
						(PIXEL_OUT == 2'b10) ? PAL_COLORS[15:14] :
						(PIXEL_OUT == 2'b01) ? PAL_COLORS[9:8] :
						PAL_COLORS[3:2];
assign PAL_BLUE = (PIXEL_OUT == 2'b11) ? PAL_COLORS[19:18] :
						(PIXEL_OUT == 2'b10) ? PAL_COLORS[13:12] :
						(PIXEL_OUT == 2'b01) ? PAL_COLORS[7:6] :
						PAL_COLORS[1:0];

// Blank video output when needed (also while the loop has not parked the VB burst yet)
`ifdef CALIBRATE
// Readout of CAL_LINE: 9 blocks of 128 clocks from HCOUNT 640 (HCOUNT[10:7] = 5..13), a dark gap
// in the last eighth of each block, on lines 64..79
wire CAL_ROW = (VCOUNT[8:4] == 5'd4);
wire CAL_COL = (HCOUNT[10:7] >= 4'd5) && (HCOUNT[10:7] <= 4'd13);
wire CAL_BIT = CAL_LINE[4'd13 - HCOUNT[10:7]];
wire CAL_GAP = (HCOUNT[6:4] == 3'd7);
assign V_RED = !ACTIVE ? 2'b00 : (CAL_ROW && CAL_COL) ? (CAL_GAP ? 2'b00 : (CAL_BIT ? 2'b11 : 2'b01)) : PAL_RED;
assign V_GREEN = !ACTIVE ? 2'b00 : (CAL_ROW && CAL_COL) ? 2'b00 : PAL_GREEN;
assign V_BLUE = !ACTIVE ? 2'b00 : (CAL_ROW && CAL_COL) ? 2'b00 : PAL_BLUE;
`else
assign V_RED = ACTIVE ? PAL_RED : 2'b00;
assign V_GREEN = ACTIVE ? PAL_GREEN : 2'b00;
assign V_BLUE = ACTIVE ? PAL_BLUE : 2'b00;
`endif

// Perform writes only when HSTRETCH=0
assign nSRAM_WE = ~(WRITE_FLAG & (HSTRETCH == 0));
assign nSRAM_OE = ~nSRAM_WE;
assign SRAM_DATA = nSRAM_OE ? PIXELS_IN : 16'bzzzzzzzzzzzzzzzz;

// Active:
//   W=384*5=1920px (48us of the 52us active line)
//   H=224*1=224px (224 lines centered in the 288 visible ones)
assign ACTIVE_V = (VCOUNT >= 56) && (VCOUNT < 280);
// ACTIVE (video on) = HCOUNT 540..2459, SCAN (SRAM read machine) = HCOUNT 535..2459, both only while ACTIVE_V.
// SRAM data latched at the end of a 5-clock group is displayed during the next one, so SCAN
// starts one group early to preload column 0. Both are registers set/cleared on HCOUNT equality
// decodes rather than magnitude compares, which keeps the HCOUNT->HSTRETCH path inside 25ns.
assign SYNC_H = !((HCOUNT >= 0) && (HCOUNT < 188));	// 4.7us sync pulse
assign SYNC_V = ((VCOUNT >= 0) && (VCOUNT < 3));	// 3 lines, same as the NES PPU
assign V_VS = SYNC_H ^ SYNC_V;


// READ_COUNTER is the column number * 28
// READ_OFFSET is the index for a 8-pixel block in the column
assign READ_ADDR = READ_OFFSET + READ_COUNTER;

// Single buffer: bits 15:14 always 0. Select read or write address depending on access slot
assign SRAM_ADDR = {2'b00, (HSTRETCH != 0) ? READ_ADDR : WRITE_ADDR};

// VB burst end: falling edge of VB_CS, two low samples after two high ones (50ns filter)
assign CS_FALL = (VB_CS_SR == 4'b1100);
// Where it ended (CS_* registered below): target line 52, dead band 51..53, the rest split so
// the shorter way is taken. More than 8 lines off: 8-line steps. Outside 49..55 the frame in
// memory may be torn: blank.

// Servo output
assign SERVO_SYNC = SV_SYNC;		// Straight 3.3 V wire to the emulator PB2 / VB pin 6 net

// Only used for simulation (hardware registers power up low)
initial
begin
	PAIR_INDEX <= 0;
	HCOUNT <= 0;
	VCOUNT <= 0;
	HSTRETCH <= 0;
	WRITE_FLAG <= 0;
	READ_OFFSET <= 0;
	READ_COUNTER <= 14'h3FE4;
	WRITE_ADDR <= 0;
	ACTIVE <= 0;
	SCAN <= 0;
	VB_CS_SR <= 0;
	VB_SHIFT_SR <= 0;
	SCOUNT <= 0;
	SV_SYNC <= 0;
	REQ_SKIP <= 0;
	REQ_HOLD <= 0;
	COARSE <= 0;
	HOLDN <= 0;
	SETTLE <= 0;
	CS_LATE <= 0;
	CS_EARLY <= 0;
	CS_FAR <= 0;
	PAL_SW_SR <= 2'b11;
	PALETTE <= 0;
	LINE_END <= 0;
end

always @(posedge CLK_40M)
begin

	// Shift VB_CS and VB_SHIFT in
	VB_CS_SR <= {VB_CS_SR[2:0], VB_CS};
	VB_SHIFT_SR = {VB_SHIFT_SR[2:0], VB_SHIFT};

	// Line position flags for the next clock
	LINE_END <= (HCOUNT == 2560);
	CS_LATE <= (VCOUNT >= 54) && (VCOUNT < 224);
	CS_EARLY <= (VCOUNT >= 224) || (VCOUNT <= 50);
	CS_FAR <= (VCOUNT >= 60) || (VCOUNT <= 44);

	// Detect VB_SHIFT rising edge
	if (VB_CS && (VB_SHIFT_SR == 4'b0011) && (!WRITE_FLAG))
	begin
		// Latch pixel data and set WRITE_FLAG
		WRITE_FLAG <= 1'b1;
		PIXELS_IN <= VB_PIXELS;
	end

	// SRAM access cycle control
	if (HSTRETCH == 4)
	begin
		// HSTRETCH was 4 (read)
		// Latch SRAM data and select appropriate pixel (bit pair) for output
		if (PAIR_INDEX == 3'd0) PIXEL_OUT <= {SRAM_DATA[1], SRAM_DATA[0]};
		if (PAIR_INDEX == 3'd1) PIXEL_OUT <= {SRAM_DATA[14], SRAM_DATA[15]};
		if (PAIR_INDEX == 3'd2) PIXEL_OUT <= {SRAM_DATA[3], SRAM_DATA[2]};
		if (PAIR_INDEX == 3'd3) PIXEL_OUT <= {SRAM_DATA[12], SRAM_DATA[13]};
		if (PAIR_INDEX == 3'd4) PIXEL_OUT <= {SRAM_DATA[5], SRAM_DATA[4]};
		if (PAIR_INDEX == 3'd5) PIXEL_OUT <= {SRAM_DATA[10], SRAM_DATA[11]};
		if (PAIR_INDEX == 3'd6) PIXEL_OUT <= {SRAM_DATA[7], SRAM_DATA[6]};
		if (PAIR_INDEX == 3'd7) PIXEL_OUT <= {SRAM_DATA[8], SRAM_DATA[9]};
	end
	else if (HSTRETCH == 0)
	begin
		// HSTRETCH was 0 (write)
		if (WRITE_FLAG)
		begin
			// Write done, reset flag and increment write address
			WRITE_FLAG <= 1'b0;
			WRITE_ADDR <= WRITE_ADDR + 1'b1;
		end
	end

	// Active windows (see ACTIVE_V above)
	if (HCOUNT == 534) SCAN <= ACTIVE_V;
	if (HCOUNT == 539) ACTIVE <= ACTIVE_V;
	if (HCOUNT == 2459)
	begin
		SCAN <= 1'b0;
		ACTIVE <= 1'b0;
	end

	// PAL sync
	// 1clk = 1/40M = 25ns
	// 1 line = 64.05us = 2562clk (PAL nominal is 64.00us)
	if (!LINE_END)	// Whole line
	begin
		// In active frame, next column
		// Horizontal pixel stretching is done here
		if (SCAN)
		begin
			if (HSTRETCH == 3'd0)
				READ_COUNTER <= READ_COUNTER + 14'd28;

			if (HSTRETCH == 3'd4)
				HSTRETCH <= 0;
			else
				HSTRETCH <= HSTRETCH + 1'b1;
		end
		else
			HSTRETCH <= 0;
		HCOUNT <= HCOUNT + 1'b1;
	end
	else
	begin
		// New raster line
		HCOUNT <= 0;
		HSTRETCH <= 0;

		// Restart one column before the first one, the preload group brings it back to 0
		READ_COUNTER <= 14'h3FE4;	// -28

		if (ACTIVE_V)
		begin
			// Move to next 8-pixel column if needed
			if (PAIR_INDEX == 3'd7)
				READ_OFFSET <= READ_OFFSET + 1'b1;
			PAIR_INDEX <= PAIR_INDEX + 1'b1;
		end

		if (VCOUNT == 313)		// Whole frame, always 314 lines
		begin
			VCOUNT <= 0;
			READ_OFFSET <= 0;
			PAIR_INDEX <= 3'd0;

			// Read color switch
			PAL_SW_SR <= {PAL_SW_SR[0], PAL_SW};
			// Detect PAL_SW falling edge
			if (PAL_SW_SR[1:0] == 2'b10)
				PALETTE <= PALETTE + 1'b1;
		end
		else
			VCOUNT <= VCOUNT + 1'b1;

		// Servo cycle: 314 lines, minus 1 or 8 (skip) or plus 1 or 8 (hold) when the loop asks
		if (SCOUNT == 313)
		begin
			if (REQ_HOLD)
			begin
				// Stay on line 313 for HOLDN + 1 lines
				if (HOLDN == 0)
					REQ_HOLD <= 1'b0;
				else
					HOLDN <= HOLDN - 1'b1;
			end
			else
			begin
				SCOUNT <= REQ_SKIP ? (COARSE ? 9'd8 : 9'd1) : 9'd0;
				REQ_SKIP <= 1'b0;
			end
		end
		else
			SCOUNT <= SCOUNT + 1'b1;

		// Servo main sync: high for 156 lines (10 ms) from SYNC_RISE_LINE, takes effect on the next line
		if (SCOUNT == SYNC_RISE_M1) SV_SYNC <= 1'b1;
		if (SCOUNT == SYNC_FALL_M1) SV_SYNC <= 1'b0;
	end

	// Detect VB_CS falling edge (after the wrap so a request set now survives it)
	if (CS_FALL)
	begin
		// VB frame done, reset write address; ask the servo cycle to move if the burst is off target
		WRITE_ADDR <= 14'h0000;
`ifdef CALIBRATE
		CAL_LINE <= VCOUNT;
`else
		// A step requested here is applied at the next servo wrap and first shows on the burst
		// after the next: skip one measurement after each request (SETTLE) or the loop overshoots
		if (SETTLE)
			SETTLE <= 1'b0;
		else if (CS_LATE || CS_EARLY)
		begin
			SETTLE <= 1'b1;
			if (CS_LATE) REQ_SKIP <= 1'b1;
			if (CS_EARLY)
			begin
				REQ_HOLD <= 1'b1;
				HOLDN <= CS_FAR ? 3'd7 : 3'd0;
			end
			COARSE <= CS_FAR;
		end
`endif
	end
end

endmodule
