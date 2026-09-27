`timescale 1ns/1ps
// Bench for VT_ntsc2.v / VT_pal2.v: SRAM model, VB column bursts, pixel-exact output check.
module tb;
parameter H0 = 540;			// first displayed HCOUNT
parameter V0 = 56;			// first displayed VCOUNT
parameter NCOL = 384;		// displayed columns (ACTIVE width / 5)
parameter LINE = 2560;		// clocks per line
parameter NFRAMES = 4;		// VB frames to send
parameter DUMP = 0;			// write last checked frame as PGM
parameter MODE = 1;			// MODE pin level that selects double buffering (1 on VGA/NTSC, 0 on PAL)
parameter SINGLE = 0;		// 1: DUT is single buffered, displayed frame = last VB frame done before the first active line
parameter VBPER = 20_000_000;	// VB frame period, ns
parameter WORDNS = 200;		// VB_SHIFT low time per word, ns (word = 50 + 200 + WORDNS). 200 = 4.84ms burst, 245 = 5.32ms (measured)
parameter JIT = 0;			// 1: alternate -32/+19/+5us VB period jitter (measured on hardware)
parameter START = 1000;		// time of the first VB burst, ns (sets the initial VB/output phase)
parameter LINETOL = 0;		// accepted line length deviation, clocks (lock loop trims lines)
parameter CHECK_FROM = 1;	// first output frame whose pixels are checked (lets a lock loop settle)
parameter TRIMLINE = -1;	// line whose length is not checked (carries the frame trim)

reg CLK = 0; always #12.5 CLK = ~CLK;
reg [15:0] VB_PIXELS = 0; reg VB_CS = 0, VB_SHIFT = 0;
wire [15:0] SRAM_DATA, SRAM_ADDR; wire nWE, nOE, V_VS; wire [1:0] R, G, B;

`DUT dut(.CLK_40M(CLK), .VB_PIXELS(VB_PIXELS), .VB_CS(VB_CS), .VB_SHIFT(VB_SHIFT),
	.VB_CLEAR(1'b0), .VB_CLKA(1'b0), .VB_CLKB(1'b0), .VB_CLKC(1'b0), .PAL_SW(1'b1), .MODE(MODE[0]),
	.SRAM_DATA(SRAM_DATA), .SRAM_ADDR(SRAM_ADDR), .nSRAM_WE(nWE), .nSRAM_OE(nOE),
	.V_VS(V_VS), .V_RED(R), .V_GREEN(G), .V_BLUE(B));

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

integer vb_done = 0; realtime cs_fall_t = 0;
task vb_frame(input integer f); integer c, o, r; reg [15:0] w;
begin
	VB_CS = 1; #200;
	for (c = 0; c < 384; c = c + 1) for (o = 0; o < 28; o = o + 1) begin
		w = 0; for (r = 0; r < 8; r = r + 1) w = w | pk(r, pix(c, o*8 + r, f));
		VB_PIXELS = w; #50; VB_SHIFT = 1; #200; VB_SHIFT = 0; #(WORDNS);	// 450ns/word = 4.84ms burst, 495ns = 5.32ms
	end
	#200; VB_CS = 0; cs_fall_t = $realtime; vb_done = vb_done + 1;
end endtask

// Icarus never runs the DUT's always @(*) palette LUT at t=0 (PALETTE has a declaration
// initialiser, so no event). Toggle it once so PAL_COLORS gets evaluated; ends at palette 0.
initial begin #1 dut.PALETTE = 3'd1; #1 dut.PALETTE = 3'd0; end

real jit;
initial begin : stim
	integer f;
	#(START);
	for (f = 0; f < NFRAMES; f = f + 1) begin
		vb_frame(f);
		jit = JIT ? ((f % 3 == 0) ? -32000.0 : (f % 3 == 1) ? 19000.0 : 5000.0) : 0.0;
		#(VBPER + jit - ($realtime - START - f*(VBPER*1.0)));	// VB period, jitter does not accumulate
	end
	#25_000_000; $finish;
end

// ---- checks ----
integer errs = 0, checked = 0, act_clk = 0, act_lines = 0, line_clk = 0, fexp = -1;
integer bad_col [0:511]; integer i;
integer frames = 0, flines = 0;
realtime fstart_t = 0, first_act_t = 0; integer first_act_seen = 0;
reg [1:0] img [0:383][0:223];
initial for (i = 0; i < 512; i = i + 1) bad_col[i] = 0;

always @(negedge CLK) begin
	// Line / frame bookkeeping via DUT counters
	if (dut.HCOUNT == 0) begin
		if (line_clk != 0 && frames > 0 && (line_clk < LINE - LINETOL || line_clk > LINE + LINETOL) && (dut.VCOUNT - 1 != TRIMLINE)) begin $display("ERR line length %0d", line_clk); errs = errs + 1; end
		if (act_clk != 0) begin
			if (act_clk != NCOL*5) begin $display("ERR active clocks/line %0d at V=%0d", act_clk, dut.VCOUNT-1); errs = errs + 1; end
			act_lines = act_lines + 1;
		end
		line_clk = 0; act_clk = 0;
		if (dut.VCOUNT == 0) begin
			if (frames > 0)
				$display("frame %0d: %0d lines, %0d active, shows VB frame %0d, start %0.1fus after VB_CS fall, first active line +%0.2fms, BUFFER_RD=%0d",
					frames, flines, act_lines, fexp, (fstart_t - cs_fall_t)/1000.0, (first_act_t - fstart_t)/1e6, dut.BUFFER_RD);
			if (act_lines != 0 && frames > 1 && act_lines != 224) begin $display("ERR active lines %0d", act_lines); errs = errs + 1; end
			frames = frames + 1; flines = 0; act_lines = 0; fstart_t = $realtime; first_act_seen = 0;
			fexp = (frames >= CHECK_FROM && !SINGLE) ? vb_done - 1 : -1;
		end
		flines = flines + 1;
	end
	line_clk = line_clk + 1;
	if (dut.ACTIVE) begin : chk
		integer c, r;
		act_clk = act_clk + 1;
		if (!first_act_seen) begin
			first_act_seen = 1; first_act_t = $realtime;
			if (SINGLE && frames >= CHECK_FROM) fexp = vb_done - 1;
			if (SINGLE && VB_CS) begin $display("ERR VB burst still running at first active line of output frame %0d", frames); errs = errs + 1; end
		end
		c = (dut.HCOUNT - H0) / 5; r = dut.VCOUNT - V0;
		if (fexp >= 0) begin
			checked = checked + 1;
			if (R !== pix(c, r, fexp)) begin
				errs = errs + 1; bad_col[c] = bad_col[c] + 1;
				if (errs <= 5) $display("ERR pixel col %0d row %0d: got %b want %b (frame %0d)", c, r, R, pix(c, r, fexp), fexp);
			end
			if (G !== 2'b00 || B !== 2'b00) begin errs = errs + 1; if (errs <= 5) $display("ERR G/B not 0 in palette 0"); end
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

always @(posedge CLK) if ($realtime > (START + NFRAMES*(VBPER*1.0) + 24_000_000.0) && !reported) begin : fin
	integer fd, c, r;
	reported = 1;
	$display("V_VS low widths seen (ns):"); for (j = 0; j < nlow; j = j + 1) $display("  %0.1f", lows[j]);
	$display("bad columns:"); for (c = 0; c < 512; c = c + 1) if (bad_col[c]) $display("  col %0d: %0d bad pixels", c, bad_col[c]);
	$display("RESULT %s: %0d pixels checked, %0d errors", `DUTNAME, checked, errs);
	if (DUMP) begin
		fd = $fopen("frame.pgm", "w"); $fwrite(fd, "P2\n384 224\n3\n");
		for (r = 0; r < 224; r = r + 1) begin for (c = 0; c < 384; c = c + 1) $fwrite(fd, "%0d ", img[c][r]); $fwrite(fd, "\n"); end
		$fclose(fd);
	end
end
reg reported = 0;
endmodule
