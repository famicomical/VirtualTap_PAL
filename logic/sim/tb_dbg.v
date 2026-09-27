`timescale 1ns/1ps
// Bench for VT_dbg.v: VB_CS 4.84ms high every 20.11ms (+ small jitter), VB_SHIFT strobes during
// the burst. Checks the latched PERIOD/HIGH readouts and dumps one raster frame to dbg.ppm.
module tb_dbg;
reg CLK = 0; always #12.5 CLK = ~CLK;
reg VB_CS = 0, VB_SHIFT = 0;
wire V_VS; wire [1:0] R, G, B;
wire [15:0] SRAM_DATA;
VT_DBG dut(.CLK_40M(CLK), .VB_PIXELS(16'd0), .VB_CS(VB_CS), .VB_SHIFT(VB_SHIFT),
	.VB_CLEAR(1'b0), .VB_CLKA(1'b0), .VB_CLKB(1'b0), .VB_CLKC(1'b0), .PAL_SW(1'b1), .MODE(1'b1),
	.SRAM_DATA(SRAM_DATA), .SRAM_ADDR(), .nSRAM_WE(), .nSRAM_OE(), .V_VS(V_VS),
	.V_RED(R), .V_GREEN(G), .V_BLUE(B));

integer f, w, errs = 0;
real period_ns, high_ns;
initial begin
	#7_000_000;	// start mid-raster so the band lands somewhere in the frame
	for (f = 0; f < 4; f = f + 1) begin
		period_ns = 20_110_000 + (f % 2 ? 1300 : -700);	// +-1us jitter
		high_ns = 4_840_000;
		VB_CS = 1;
		for (w = 0; w < 10752; w = w + 1) begin #250; VB_SHIFT = 1; #200; VB_SHIFT = 0; end
		#(high_ns - 10752*450); VB_CS = 0;
		#(period_ns - high_ns);
	end
	// dut.PERIOD = interval between the 3rd and 4th rising edges = 20_110_000-700 ns = 804372 clk (+-1), HIGH = 4.84ms = 193600 clk (+-1)
	if (dut.PERIOD < 804371 || dut.PERIOD > 804373) begin $display("ERR PERIOD %0d want 804372", dut.PERIOD); errs = errs + 1; end
	if (dut.HIGH < 193599 || dut.HIGH > 193601) begin $display("ERR HIGH %0d want 193600", dut.HIGH); errs = errs + 1; end
	$display("PERIOD=%0d HIGH=%0d", dut.PERIOD, dut.HIGH);
	$display("RESULT DBG: %0d errors", errs);
	$finish;
end

// Dump frame 3 (raster lines 3..313, HCOUNT 420..2499 subsampled by 4) as PPM
integer fd, frames = 0, x, y;
reg [5:0] img [0:520][0:313];
initial for (y = 0; y < 314; y = y + 1) for (x = 0; x < 521; x = x + 1) img[x][y] = 0;
always @(negedge CLK) begin
	if (dut.HCOUNT == 0 && dut.VCOUNT == 0) frames = frames + 1;
	if (frames == 3 && dut.HCOUNT >= 420 && dut.HCOUNT < 2500 && dut.HCOUNT[1:0] == 0)
		img[(dut.HCOUNT-420)/4][dut.VCOUNT] = img[(dut.HCOUNT-420)/4][dut.VCOUNT] | {R, G, B};
	if (frames == 4 && dut.HCOUNT == 0 && dut.VCOUNT == 0) begin
		fd = $fopen("dbg.ppm", "w");
		$fwrite(fd, "P3\n520 314\n3\n");
		for (y = 0; y < 314; y = y + 1) begin
			for (x = 0; x < 520; x = x + 1) $fwrite(fd, "%0d %0d %0d ", img[x][y][5:4], img[x][y][3:2], img[x][y][1:0]);
			$fwrite(fd, "\n");
		end
		$fclose(fd);
	end
end
endmodule
