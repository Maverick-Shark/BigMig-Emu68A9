// pll_psram -- wrapper with the port names of teiram's Amstrad_MiSTer_ch96 PSRAM PLL
// (see pll_psram/pll_psram_0002.v). Keep all three outputs connected: the capture
// clock must stay on counter C2, which is what the DPS stepper selects (cntsel = 2).
`timescale 1 ps / 1 ps
module pll_psram (
		input  wire       refclk,     //     refclk.clk
		input  wire       rst,        //      reset.reset
		output wire       outclk_0,   //    outclk0.clk  64 MHz
		output wire       outclk_1,   //    outclk1.clk  128 MHz
		output wire       outclk_2,   //    outclk2.clk  128 MHz, DPS
		output wire       locked,     //     locked.export
		input  wire       phase_en,   //   phase_en.phase_en
		input  wire       scanclk,    //    scanclk.scanclk
		input  wire       updn,       //       updn.updn
		input  wire [4:0] cntsel,     //     cntsel.cntsel
		output wire       phase_done  // phase_done.phase_done
	);

	pll_psram_0002 pll_inst (
		.refclk     (refclk),
		.rst        (rst),
		.outclk_0   (outclk_0),
		.outclk_1   (outclk_1),
		.outclk_2   (outclk_2),
		.locked     (locked),
		.phase_en   (phase_en),
		.scanclk    (scanclk),
		.updn       (updn),
		.cntsel     (cntsel),
		.phase_done (phase_done)
	);

endmodule
