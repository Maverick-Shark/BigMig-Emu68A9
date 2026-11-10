//============================================================================
//  BigMig-Emu68A9 on Chameleon96 - top level
//
//  Board wrapper around the MiSTer hardware abstraction module (sys_top) for
//  the Chameleon96 Cyclone V SoC board (5CSEBA6U19I7). Taken from teiram's
//  Amstrad_MiSTer_ch96 (ch96_top.sv); the board handling is the same:
//
//  - No FPGA-side oscillator: FPGA_CLK1/2/3_50 all come from the HPS
//    h2f_user1_clk, exposed by sys_top as clk_50m.
//  - Video: parallel RGB565 on the LCD connector (to the TDA19988), with DE,
//    HS, VS and the pixel clock, taken from the HDMI_TX_* bus.
//  - Audio: I2S to the TDA19988. HPS I2C2 (FPGA-muxed) programs the TDA19988.
//  - Chip RAM: the dual APS6404L QSPI PSRAM module on the HPS loan I/O bus
//      PSRAM  (chip A, high byte lane): SIO0..3 = 33/19/17/34, SCLK 54, CE# 48
//      PSRAM2 (chip B, low byte lane) : SIO0..3 = 29/27/53/30, SCLK 28, CE# 23
//  - User LEDs D5..D8 are HPS GPIO14/22/25/32, muxed to loan I/O by the
//    hps-ch96 preloader handoff; the RF LEDs are FPGA pins Y19/Y20.
//  - No VGA, SDIO, analog audio, MCP23009, ADC or USER_IO: tied off.
//
//  LED map (sys_top LED vector, active high):
//    D5 = LED[0] user (BigMig: floppy; PSRAM calibration state at power-up)
//    D6 = LED[2] disk (BigMig: HDD;    c*[1] after calibration)
//    D7 = LED[4] power                 (c*[2] after calibration)
//    D8 = LED[6] video low-latency lock (pll_hdmi_adj)
//    yellow = LED[1] video active (HDMI DE), blue = LED[3] always on
//============================================================================

module ch96_top
(
	//////////// LCD/HDMI RGB565 //////////
	output  [4:0] LCD_R,
	output  [5:0] LCD_G,
	output  [4:0] LCD_B,
	output        LCD_DE,
	output        LCD_HSYNC,
	output        LCD_VSYNC,
	output        LCD_PIXEL_CLK,

	//////////// HDMI I2S audio //////////
	output        I2S_MCLK,
	output        I2S_TXC,
	output        I2S_TXD,
	output        I2S_TXFS,

	//////////// HPS I2C2 (EMAC0) -> TDA19988 //////////
	inout         I2C2_SCL,
	inout         I2C2_SDA,

	//////////// LEDs //////////
	output        LED_YELLOW,  // D9, PIN_Y19 (video active)
	output        LED_BLUE     // D10, PIN_Y20 (always on)
);

	wire clk_50m;

	wire        PSRAM_SCLK;
	wire        PSRAM_CE_N;
	wire  [3:0] PSRAM_SIO_OUT;
	wire  [3:0] PSRAM_SIO_OE;
	wire  [3:0] PSRAM_SIO_IN;

	wire        PSRAM2_SCLK;
	wire        PSRAM2_CE_N;
	wire  [3:0] PSRAM2_SIO_OUT;
	wire  [3:0] PSRAM2_SIO_OE;
	wire  [3:0] PSRAM2_SIO_IN;

	wire [23:0] hdmi_d;
	wire  [7:0] led;

	// SD card detect: hold the secondary-SD path "present"; the board's SD card
	// belongs to the HPS SDMMC.
	wire        sdcd_spdif = 1'b1;

	sys_top sys_top
	(
		/////////// CLOCK //////////
		.FPGA_CLK1_50(clk_50m),
		.FPGA_CLK2_50(clk_50m),
		.FPGA_CLK3_50(clk_50m),
		.clk_50m(clk_50m),

		//////////// QSPI PSRAM (loan I/O bus) //////////
		.PSRAM_SCLK(PSRAM_SCLK),
		.PSRAM_CE_N(PSRAM_CE_N),
		.PSRAM_SIO_OUT(PSRAM_SIO_OUT),
		.PSRAM_SIO_OE(PSRAM_SIO_OE),
		.PSRAM_SIO_IN(PSRAM_SIO_IN),

		.PSRAM2_SCLK(PSRAM2_SCLK),
		.PSRAM2_CE_N(PSRAM2_CE_N),
		.PSRAM2_SIO_OUT(PSRAM2_SIO_OUT),
		.PSRAM2_SIO_OE(PSRAM2_SIO_OE),
		.PSRAM2_SIO_IN(PSRAM2_SIO_IN),

		//////////// SDRAM - not present //////////
		.SDRAM_A(),
		.SDRAM_DQ(),
		.SDRAM_DQML(),
		.SDRAM_DQMH(),
		.SDRAM_nWE(),
		.SDRAM_nCAS(),
		.SDRAM_nRAS(),
		.SDRAM_nCS(),
		.SDRAM_BA(),
		.SDRAM_CLK(),
		.SDRAM_CKE(),

		//////////// HDMI I2C (HPS I2C2 -> TDA19988) //////////
		.HDMI_I2C_SCL(I2C2_SCL),
		.HDMI_I2C_SDA(I2C2_SDA),

		//////////// HDMI I2S audio //////////
		.HDMI_MCLK(I2S_MCLK),
		.HDMI_SCLK(I2S_TXC),
		.HDMI_LRCLK(I2S_TXFS),
		.HDMI_I2S(I2S_TXD),

		//////////// HDMI / LCD parallel RGB565 //////////
		.HDMI_TX_CLK(LCD_PIXEL_CLK),
		.HDMI_TX_DE(LCD_DE),
		.HDMI_TX_D(hdmi_d),
		.HDMI_TX_HS(LCD_HSYNC),
		.HDMI_TX_VS(LCD_VSYNC),
		.HDMI_TX_INT(1'b1),

		//////////// VGA - not present //////////
		.VGA_R(),
		.VGA_G(),
		.VGA_B(),
		.VGA_HS(),
		.VGA_VS(),
		.VGA_EN(1'b1),

		//////////// Analog audio - not present //////////
		.AUDIO_L(),
		.AUDIO_R(),
		.AUDIO_SPDIF(),

		//////////// SDIO - not present //////////
		.SDIO_DAT(),
		.SDIO_CMD(),
		.SDIO_CLK(),

		//////////// LEDs/Buttons - not present //////////
		.LED_USER(),
		.LED_HDD(),
		.LED_POWER(),
		.BTN_USER(1'b1),
		.BTN_OSD(1'b1),
		.BTN_RESET(1'b1),

		//////////// Secondary SD SPI - not present //////////
		.SD_SPI_CS(),
		.SD_SPI_MISO(1'b0),
		.SD_SPI_CLK(),
		.SD_SPI_MOSI(),
		.SDCD_SPDIF(sdcd_spdif),
		.IO_SCL(),
		.IO_SDA(),

		//////////// ADC - not present //////////
		.ADC_SCK(),
		.ADC_SDO(1'b0),
		.ADC_SDI(),
		.ADC_CONVST(),

		//////////// MB KEY/SW/LED - not present //////////
		.KEY(2'b11),
		.SW(4'b0000),
		.LED(led),

		//////////// USER IO - not present //////////
		.USER_IO()
	);

	// HDMI_TX_D[23:0] is RGB888 (R[23:16] G[15:8] B[7:0]); the LCD connector
	// takes RGB565.
	assign LCD_R = hdmi_d[23:19];
	assign LCD_G = hdmi_d[15:10];
	assign LCD_B = hdmi_d[7:3];

	// ---- HPS loan I/O: user LEDs and the two PSRAMs
	wire [66:0] loan_io_in;
	wire [66:0] loan_io_out;
	wire [66:0] loan_io_oe;

	cyclonev_hps_interface_loan_io loan_io_inst
	(
		.loanio_in(loan_io_in),
		.loanio_out(loan_io_out),
		.loanio_oe(loan_io_oe)
	);

	// user LEDs D5..D8 (HPS GPIO14/22/25/32)
	assign loan_io_out[14] = led[0];
	assign loan_io_out[22] = led[2];
	assign loan_io_out[25] = led[4];
	assign loan_io_out[32] = led[6];
	assign loan_io_oe[14]  = 1'b1;
	assign loan_io_oe[22]  = 1'b1;
	assign loan_io_oe[25]  = 1'b1;
	assign loan_io_oe[32]  = 1'b1;

	// PSRAM (chip A, high byte lane)
	assign loan_io_out[33] = PSRAM_SIO_OUT[0];
	assign loan_io_out[19] = PSRAM_SIO_OUT[1];
	assign loan_io_out[17] = PSRAM_SIO_OUT[2];
	assign loan_io_out[34] = PSRAM_SIO_OUT[3];
	assign loan_io_oe[33]  = PSRAM_SIO_OE[0];
	assign loan_io_oe[19]  = PSRAM_SIO_OE[1];
	assign loan_io_oe[17]  = PSRAM_SIO_OE[2];
	assign loan_io_oe[34]  = PSRAM_SIO_OE[3];
	assign PSRAM_SIO_IN[0] = loan_io_in[33];
	assign PSRAM_SIO_IN[1] = loan_io_in[19];
	assign PSRAM_SIO_IN[2] = loan_io_in[17];
	assign PSRAM_SIO_IN[3] = loan_io_in[34];
	assign loan_io_out[54] = PSRAM_SCLK;
	assign loan_io_oe[54]  = 1'b1;
	assign loan_io_out[48] = PSRAM_CE_N;
	assign loan_io_oe[48]  = 1'b1;

	// PSRAM2 (chip B, low byte lane)
	assign loan_io_out[29] = PSRAM2_SIO_OUT[0];
	assign loan_io_out[27] = PSRAM2_SIO_OUT[1];
	assign loan_io_out[53] = PSRAM2_SIO_OUT[2];
	assign loan_io_out[30] = PSRAM2_SIO_OUT[3];
	assign loan_io_oe[29]  = PSRAM2_SIO_OE[0];
	assign loan_io_oe[27]  = PSRAM2_SIO_OE[1];
	assign loan_io_oe[53]  = PSRAM2_SIO_OE[2];
	assign loan_io_oe[30]  = PSRAM2_SIO_OE[3];
	assign PSRAM2_SIO_IN[0] = loan_io_in[29];
	assign PSRAM2_SIO_IN[1] = loan_io_in[27];
	assign PSRAM2_SIO_IN[2] = loan_io_in[53];
	assign PSRAM2_SIO_IN[3] = loan_io_in[30];
	assign loan_io_out[28] = PSRAM2_SCLK;
	assign loan_io_oe[28]  = 1'b1;
	assign loan_io_out[23] = PSRAM2_CE_N;
	assign loan_io_oe[23]  = 1'b1;

	// RF LEDs
	assign LED_YELLOW = led[1];
	assign LED_BLUE   = led[3];

endmodule
