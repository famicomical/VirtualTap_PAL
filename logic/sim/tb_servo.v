`timescale 1ns/1ps
// Bench for the servo-master VT_pal2.v: SRAM model, a Virtual Boy model whose transfer burst
// starts DLY ns after the servo main sync rises,
// pixel-exact output check, rigid raster check (every line LINE clocks, every frame 314 lines),
// no SRAM read while VB_CS is high (checked once the loop is in band), lock within MAXLOCK VB
// frames, servo sync timing.
module tb;
parameter H0 = 540;			// first displayed HCOUNT
parameter V0 = 56;			// first displayed VCOUNT
parameter NCOL = 384;		// displayed columns (ACTIVE width / 5)
parameter LINE = 2562;		// clocks per line
parameter NFRAMES = 40;		// VB frames to send
parameter DUMP = 0;			// write last checked frame as PGM
parameter WORDNS = 245;		// VB_SHIFT low time per word, ns (word = 50 + 200 + WORDNS). 245 = 5.32ms burst (measured)
parameter DLY = 1024000;	// main sync rising edge -> VB_CS rising edge, ns (measured: burst ends on line 240 with the sync on 141)
parameter MAXLOCK = 60;		// VB frames within which the loop must be in band (157 lines = 20 coarse + 8 fine decisions, one per 2 frames)
parameter JITNS = 0;		// +-jitter added to DLY, alternating, ns
parameter CHECK_FROM = 10;	// first output frame whose pixels are checked (lets the loop settle)
parameter TARGET = 52;		// line on which the loop should park the VB_CS falling edge

reg CLK = 0; always #12.5 CLK = ~CLK;
reg [15:0] VB_PIXELS = 0; reg VB_CS = 0, VB_SHIFT = 0;
wire [15:0] SRAM_DATA, SRAM_ADDR; wire nWE, nOE, V_VS; wire [1:0] R, G, B;
wire SV_SYNC;				// SERVO_SYNC pin, main sync

VT_PAL2 dut(.CLK_40M(CLK), .VB_PIXELS(VB_PIXELS), .VB_CS(VB_CS), .VB_SHIFT(VB_SHIFT),
	.VB_CLEAR(1'b0), .VB_CLKA(1'b0), .VB_CLKB(1'b0), .VB_CLKC(1'b0), .PAL_SW(1'b1),
	.SRAM_DATA(SRAM_DATA), .SRAM_ADDR(SRAM_ADDR), .nSRAM_WE(nWE), .nSRAM_OE(nOE),
	.V_VS(V_VS), .V_RED(R), .V_GREEN(G), .V_BLUE(B),
	.SERVO_SYNC(SV_SYNC));

// Async SRAM, unwritten cells stay X
reg [15:0] mem [0:65535];
assign SRAM_DATA = nOE ? 16'bz : mem[SRAM_ADDR];
always @(negedge CLK) if (!nWE) mem[SRAM_ADDR] <= SRAM_DATA;

// Test pattern, depends on frame so stale buffers are caught
function [1:0] pix; input integer c, r, f; pix = (c + r + (r >> 3) + f) & 3; endfunction
// Bit placement per PAIR_INDEX case in the DUT: pair p -> {bit for v[1], bit for v[0]}
function [15:0] pk; input integer p; input [1:0] v; reg [15:0] w;
begin
	w = 0;
	case (p)
		0: begin w[1]  = v[1]; w[0]  = v[0]; end
		1: begin w[14] = v[1]; w[15] = v[0]; end
		2: begin w[3]  = v[1]; w[2]  = v[0]; end
		3: begin w[12] = v[1]; w[13] = v[0]; end
		4: begin w[5]  = v[1]; w[4]  = v[0]; end
		5: begin w[10] = v[1]; w[11] = v[0]; end
		6: begin w[7]  = v[1]; w[6]  = v[0]; end
		7: begin w[8]  = v[1]; w[9]  = v[0]; end
	endcase
	pk = w;
end endfunction

integer vb_done = 0; realtime cs_fall_t = 0; integer fall_line = -1, locked_frames = 0, first_lock = -1;
task vb_frame(input integer f); integer c, o, r; reg [15:0] w;
begin
	VB_CS = 1; #200;
	for (c = 0; c < 384; c = c + 1) for (o = 0; o < 28; o = o + 1) begin
		w = 0; for (r = 0; r < 8; r = r + 1) w = w | pk(r, pix(c, o*8 + r, f));
		VB_PIXELS = w; #50; VB_SHIFT = 1; #200; VB_SHIFT = 0; #(WORDNS);
	end
	#200; VB_CS = 0; cs_fall_t = $realtime; vb_done = vb_done + 1;
	fall_line = dut.VCOUNT;
	if (fall_line >= TARGET - 1 && fall_line <= TARGET + 1) begin locked_frames = locked_frames + 1; if (first_lock < 0) first_lock = f; end else locked_frames = 0;
	$display("VB frame %0d: burst end on output line %0d (HCOUNT %0d), servo line %0d", f, fall_line, dut.HCOUNT, dut.SCOUNT);
end endtask

// Virtual Boy model: the column transfer starts DLY after the servo main sync rises
initial begin : stim
	integer f; real jit;
	for (f = 0; f < NFRAMES; f = f + 1) begin
		@(posedge SV_SYNC);
		jit = (JITNS == 0) ? 0.0 : ((f & 1) ? JITNS : -JITNS);
		#(DLY + jit);
		vb_frame(f);
	end
	#25_000_000; $finish;
end

// ---- checks ----
integer errs = 0, checked = 0, act_clk = 0, act_lines = 0, line_clk = 0, fexp = -1, overlap = 0;
integer bad_col [0:511]; integer i;
integer frames = 0, flines = 0;
realtime fstart_t = 0, first_act_t = 0; integer first_act_seen = 0;
reg [1:0] img [0:383][0:223];
initial for (i = 0; i < 512; i = i + 1) bad_col[i] = 0;

always @(negedge CLK) begin
	// Line / frame bookkeeping via DUT counters
	if (dut.HCOUNT == 0) begin
		if (line_clk != 0 && frames > 0 && line_clk != LINE) begin $display("ERR line length %0d", line_clk); errs = errs + 1; end
		if (act_clk != 0) begin
			if (act_clk != NCOL*5) begin $display("ERR active clocks/line %0d at V=%0d", act_clk, dut.VCOUNT-1); errs = errs + 1; end
			act_lines = act_lines + 1;
		end
		line_clk = 0; act_clk = 0;
		if (dut.VCOUNT == 0) begin
			if (frames > 0)
				$display("frame %0d: %0d lines, %0d active, shows VB frame %0d, start %0.1fus after VB_CS fall, first active line +%0.2fms",
					frames, flines, act_lines, fexp, (fstart_t - cs_fall_t)/1000.0, (first_act_t - fstart_t)/1e6);
			if (frames > 1 && flines != 314) begin $display("ERR frame length %0d lines", flines); errs = errs + 1; end
			if (act_lines != 0 && frames > 1 && act_lines != 224) begin $display("ERR active lines %0d", act_lines); errs = errs + 1; end
			frames = frames + 1; flines = 0; act_lines = 0; fstart_t = $realtime; first_act_seen = 0;
			fexp = -1;
		end
		flines = flines + 1;
	end
	line_clk = line_clk + 1;
	if (dut.SCAN && VB_CS && frames >= CHECK_FROM && locked_frames > 0) overlap = overlap + 1;
	if (dut.ACTIVE) begin : chk
		integer c, r;
		act_clk = act_clk + 1;
		if (!first_act_seen) begin
			first_act_seen = 1; first_act_t = $realtime;
			if (frames >= CHECK_FROM && locked_frames > 0) fexp = vb_done - 1;
			if (frames >= CHECK_FROM && locked_frames > 0 && VB_CS) begin $display("ERR VB burst still running at first active line of output frame %0d", frames); errs = errs + 1; end
		end
		c = (dut.HCOUNT - H0) / 5; r = dut.VCOUNT - V0;
		if (fexp >= 0) begin
			checked = checked + 1;
			if (R !== pix(c, r, fexp)) begin
				errs = errs + 1; bad_col[c] = bad_col[c] + 1;
				if (errs <= 5) $display("ERR pixel col %0d row %0d: got %b want %b (frame %0d)", c, r, R, pix(c, r, fexp), fexp);
			end
			if (G !== 2'b00 || B !== 2'b00) begin errs = errs + 1; if (errs <= 5) $display("ERR G/B not 0"); end
			if (DUMP && c < 384 && r < 224) img[c][r] = R;
		end
	end
end

// Sync pulse widths (V_VS low time), distinct values
realtime vs_fall = 0; integer nlow = 0; realtime lows [0:7]; integer j, seen;
always @(negedge V_VS) vs_fall = $realtime;
always @(posedge V_VS) if (vs_fall != 0) begin : sw
	realtime w; w = $realtime - vs_fall; seen = 0;
	for (j = 0; j < nlow; j = j + 1) if (lows[j] == w) seen = 1;
	if (!seen && nlow < 8) begin lows[nlow] = w; nlow = nlow + 1; end
end

// Servo main sync timing, in lines
realtime sy_rise = 0, sy_fall = 0; integer nservo = 0;
always @(posedge SV_SYNC) begin
	if (sy_rise != 0 && nservo < 3) $display("servo: sync period %0.2f lines, high %0.2f lines", ($realtime - sy_rise)/(LINE*25.0), (sy_fall - sy_rise)/(LINE*25.0));
	sy_rise = $realtime; nservo = nservo + 1;
end
always @(negedge SV_SYNC) sy_fall = $realtime;

always @(posedge CLK) if (vb_done == NFRAMES && $realtime > cs_fall_t + 24_000_000.0 && !reported) begin : fin
	integer fd, c, r;
	reported = 1;
	$display("V_VS low widths seen (ns):"); for (j = 0; j < nlow; j = j + 1) $display("  %0.1f", lows[j]);
	$display("bad columns:"); for (c = 0; c < 512; c = c + 1) if (bad_col[c]) $display("  col %0d: %0d bad pixels", c, bad_col[c]);
	if (overlap) begin $display("ERR SRAM read while VB_CS high: %0d clocks", overlap); errs = errs + 1; end
	if (fall_line < TARGET - 1 || fall_line > TARGET + 1) begin $display("ERR not locked: last burst ended on line %0d", fall_line); errs = errs + 1; end
	if (first_lock < 0 || first_lock > MAXLOCK) begin $display("ERR lock took too long: first in-band VB frame %0d", first_lock); errs = errs + 1; end
	$display("RESULT PAL-servo: %0d pixels checked, %0d errors, last burst end line %0d, %0d frames in band, first in band at VB frame %0d", checked, errs, fall_line, locked_frames, first_lock);
	if (DUMP) begin
		fd = $fopen("frame.pgm", "w"); $fwrite(fd, "P2\n384 224\n3\n");
		for (r = 0; r < 224; r = r + 1) begin for (c = 0; c < 384; c = c + 1) $fwrite(fd, "%0d ", img[c][r]); $fwrite(fd, "\n"); end
		$fclose(fd);
	end
end
reg reported = 0;
endmodule
