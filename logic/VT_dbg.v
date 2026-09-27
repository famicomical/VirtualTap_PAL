// VIRTUALTAP Rev. C CPLD logic - VB bus timing probe (debug bitstream, not a video mode)
// For Max V 5M240ZT100. Free-running 314-line / 2562-clock PAL-timed raster, same sync
// as VT_pal2.v, but the picture is a live view of the Virtual Boy bus instead of the framebuffer:
//
//   red        = VB_CS sampled at 40 MHz, painted across every line. Band height = burst length,
//                band edge x position = edge time within a line (25 ns per pixel). Frame-to-frame
//                jitter shows as a ragged / wobbling edge, extra pulses as extra bands.
//   blue       = VB_SHIFT sampled at 40 MHz (texture while words are strobed in).
//   dim green  = the 384x224 picture window of VT_pal2.v (lines 56..279), for reference.
//   green bar  = 90 lines tall at the left (lines 120..209), the length of VT_pal2.v's vertical
//                blanking. If the red band is shorter than this bar, the whole VB burst can be
//                parked in vblank and a single-buffered picture can be tear free.
//   green ticks= every 16 lines (1.025 ms) at the left edge.
//   two rows of 20 white/dim-blue blocks, MSB left, nibbles separated:
//     row at lines 64..79  = VB_CS period in 40 MHz clocks, MEAN OF 16 FRAMES (a 24-bit count
//                            over 16 rising edges, shown >> 4), refreshed every 16 VB frames. The
//                            +-1300-clock frame-to-frame jitter is averaged down to +-80.
//     row at lines 96..111 = VB_CS high time in 40 MHz clocks (rising edge to falling edge),
//                            single frame, the first of each group of 16.
//   VB frame rate = 40e6 / period.
//
// SRAM is left idle (nSRAM_WE = nSRAM_OE = 1, data bus tri-stated).

module VT_DBG (
		input CLK_40M,
		input [15:0] VB_PIXELS,				// Unused
		input VB_CS, VB_SHIFT,
		input VB_CLEAR,						// Unused
		input VB_CLKA, VB_CLKB, VB_CLKC,	// Unused
		input PAL_SW,						// Unused, pull-up
		input MODE,							// Unused, pull-up
		inout [15:0] SRAM_DATA,
		output [15:0] SRAM_ADDR,
		output nSRAM_WE, nSRAM_OE,
		output V_VS,						// Composite sync
		output [1:0] V_RED,
		output [1:0] V_GREEN,
		output [1:0] V_BLUE
);

reg [11:0] HCOUNT;		// Sync gen
reg [8:0] VCOUNT;		// Sync gen
reg [2:0] CS_SR;		// VB_CS synchroniser / edge detect
reg [1:0] SH_SR;		// VB_SHIFT synchroniser
reg [23:0] T;			// Clocks since the VB_CS rising edge that started the group of 16
reg [3:0] NCS;			// Rising edges seen in the group
reg [19:0] PERIOD;		// Latched T[23:4] at the 16th rising edge = mean period
reg [19:0] HIGH;		// Latched T at VB_CS falling edge
reg [19:0] DISP;		// Readout shift register, MSB displayed
reg [6:0] SUB;			// Clock within a readout block (0..79)
reg [4:0] BLK;			// Readout block index (0..19 shown)
reg ACTIVE;

wire SYNC_H, SYNC_V;
wire CS_RISE, CS_FALL;
wire ROW_A, ROW_B, IN_BITS, BIT1, BIT0, REFBAR, TICK, PICT;

assign SYNC_H = !(HCOUNT < 188);		// 4.7us sync pulse
assign SYNC_V = (VCOUNT < 3);			// 3 lines
assign V_VS = SYNC_H ^ SYNC_V;

assign nSRAM_WE = 1'b1;
assign nSRAM_OE = 1'b1;
assign SRAM_DATA = 16'bzzzzzzzzzzzzzzzz;
assign SRAM_ADDR = 16'h0000;

assign CS_RISE = (CS_SR[2:1] == 2'b01);
assign CS_FALL = (CS_SR[2:1] == 2'b10);

// Overlay geometry
assign ROW_A = (VCOUNT >= 64) && (VCOUNT < 80);
assign ROW_B = (VCOUNT >= 96) && (VCOUNT < 112);
assign IN_BITS = (ROW_A | ROW_B) && (BLK < 20) && (SUB < ((BLK[1:0] == 2'd3) ? 7'd48 : 7'd64));
assign BIT1 = IN_BITS & DISP[19];
assign BIT0 = IN_BITS & ~DISP[19];
assign REFBAR = (VCOUNT >= 120) && (VCOUNT < 210) && (HCOUNT >= 440) && (HCOUNT < 520);
assign TICK = (VCOUNT[3:0] == 4'd0) && (HCOUNT >= 440) && (HCOUNT < 600);
assign PICT = (VCOUNT >= 56) && (VCOUNT < 280) && (HCOUNT >= 540) && (HCOUNT < 2460);

assign V_RED   = !ACTIVE ? 2'b00 : (CS_SR[1] | BIT1) ? 2'b11 : 2'b00;
assign V_GREEN = !ACTIVE ? 2'b00 : (BIT1 | REFBAR) ? 2'b11 : TICK ? 2'b10 : PICT ? 2'b01 : 2'b00;
assign V_BLUE  = !ACTIVE ? 2'b00 : (SH_SR[1] | BIT1) ? 2'b11 : BIT0 ? 2'b01 : 2'b00;

// Only used for simulation
initial
begin
	HCOUNT <= 0;
	VCOUNT <= 0;
	CS_SR <= 0;
	SH_SR <= 0;
	T <= 0;
	NCS <= 0;
	PERIOD <= 0;
	HIGH <= 0;
	DISP <= 0;
	SUB <= 0;
	BLK <= 0;
	ACTIVE <= 0;
end

always @(posedge CLK_40M)
begin
	CS_SR <= {CS_SR[1:0], VB_CS};
	SH_SR <= {SH_SR[0], VB_SHIFT};

	// VB_CS interval measurement
	if (CS_RISE)
	begin
		NCS <= NCS + 1'b1;
		if (NCS == 4'd15)
		begin
			PERIOD <= T[23:4];
			T <= 24'd0;
		end
		else
			T <= T + 1'b1;
	end
	else
		T <= T + 1'b1;
	if (CS_FALL && (NCS == 4'd0))
		HIGH <= T[19:0];

	// Readout: load at HCOUNT 700, one block every 80 clocks
	if (HCOUNT == 700)
	begin
		DISP <= ROW_A ? PERIOD : HIGH;
		SUB <= 0;
		BLK <= 0;
	end
	else if (SUB == 79)
	begin
		SUB <= 0;
		BLK <= BLK + 1'b1;
		DISP <= {DISP[18:0], 1'b0};
	end
	else
		SUB <= SUB + 1'b1;

	// Video window: everything but sync, back porch and the 3 vsync lines
	ACTIVE <= (HCOUNT >= 420) && (HCOUNT < 2500) && !SYNC_V;

	// PAL sync, 1 line = 2562clk = 64.05us, 314 lines = 49.72Hz
	if (HCOUNT < 2561)
		HCOUNT <= HCOUNT + 1'b1;
	else
	begin
		HCOUNT <= 0;
		if (VCOUNT == 313)
			VCOUNT <= 0;
		else
			VCOUNT <= VCOUNT + 1'b1;
	end
end

endmodule
