#!/usr/bin/env python3
"""Chameleon96 changes to BigMig.sv, all under `ifdef MISTER_CHAMELEON96 (the
`else branches keep the DE10-Nano code untouched):

  * pll_psram (teiram's PSRAM PLL: 128 MHz controller/SCLK + DPS capture clock)
  * psram_chip_ctrl as ram1 instead of sdram_ctrl (same chip and CPU ports)
  * SDRAM outputs parked, core held in reset until the PSRAM is calibrated
  * calibration state and c* on the user LEDs for a few seconds after power-up

Every replacement must match exactly once, so a changed upstream file fails
loudly instead of being patched in the wrong place.
Usage: patch_bigmig_sv.py <in BigMig.sv> <out BigMig.sv>"""
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src, newline='').read()
crlf = '\r\n' in s
s = s.replace('\r\n', '\n')


def rep(old, new):
    global s
    n = s.count(old)
    if n != 1:
        sys.exit(f"patch_bigmig_sv: pattern found {n}x (expected 1):\n{old}")
    s = s.replace(old, new)


# ---- LEDs: the DE10 assignments move into the `else branch
rep("""assign LED_POWER[1] = 1;
assign LED_DISK     = {1'b0, ide_fast ? ide_f_led : ide_c_led};
""", """wire fdd_led;
`ifdef MISTER_CHAMELEON96
// LED_USER / LED_DISK / LED_POWER: see the Chameleon96 status block after the power LED
`else
assign LED_POWER[1] = 1;
assign LED_DISK     = {1'b0, ide_fast ? ide_f_led : ide_c_led};
assign LED_USER     = fdd_led;
`endif
""")

rep("""	.fdd_led      (LED_USER         ),""",
    """	.fdd_led      (fdd_led          ),""")

# ---- PSRAM PLL right after the main PLL
rep("""pll pll
(
	.refclk(CLK_50M),
	.outclk_0(clk_114),
	.outclk_1(clk_sys),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(locked)
);
""", """pll pll
(
	.refclk(CLK_50M),
	.outclk_0(clk_114),
	.outclk_1(clk_sys),
	.reconfig_to_pll(reconfig_to_pll),
	.reconfig_from_pll(reconfig_from_pll),
	.locked(locked)
);

`ifdef MISTER_CHAMELEON96
// Chameleon96: chip RAM is the dual APS6404L module. Its clocks come from their own
// PLL (teiram's Amstrad_MiSTer_ch96 PSRAM PLL), so the PAL/NTSC reconfiguration of
// the main PLL above never disturbs the PSRAM or its calibration.
wire       clk_ram, clk_ram_cap, clk_ram_aux, ram_pll_locked;
wire       ram_pll_phase_en, ram_pll_updn, ram_pll_phase_done;
wire [4:0] ram_pll_cntsel;

pll_psram pll_psram
(
	.refclk(CLK_50M),
	.rst(1'b0),
	.outclk_0(clk_ram_aux),    // 64 MHz: only the LED divider below (keeps the capture clock on C2)
	.outclk_1(clk_ram),        // 128 MHz: controller and both SCLK pads
	.outclk_2(clk_ram_cap),    // 128 MHz, DPS-stepped: read capture
	.locked(ram_pll_locked),
	.phase_en(ram_pll_phase_en),
	.scanclk(CLK_50M),
	.updn(ram_pll_updn),
	.cntsel(ram_pll_cntsel),
	.phase_done(ram_pll_phase_done)
);

reg [23:0] ram_aux_div = 24'd0;
always @(posedge clk_ram_aux) ram_aux_div <= ram_aux_div + 1'd1;
`endif
""")

# ---- hold the core in reset until the chip RAM is calibrated
rep("""wire reset = ~locked | buttons[1] | RESET;
""", """`ifdef MISTER_CHAMELEON96
wire ram1_ready;   // chip RAM calibrated and running: hold the core until then
wire reset = ~locked | buttons[1] | RESET | ~ram1_ready;
`else
wire reset = ~locked | buttons[1] | RESET;
`endif
""")

# ---- ram1: psram_chip_ctrl on the Chameleon96, sdram_ctrl otherwise
rep("""sdram_ctrl ram1
(
	.sysclk       (clk_114         ),
	.reset_n      (~reset_d        ),
	.c_7m         (c1              ),
""", """`ifdef MISTER_CHAMELEON96
wire       ram1_cal_done, ram1_cal_fail;
wire [2:0] ram1_cal_c;

// SCLK polarity at the PSRAM pads. Default: SCLK = clk_ram, CE#/SIO change on its
// rising edge (teiram's v3, proven on this board with the Amstrad fit); the device's
// input hold then comes only from the pad delay difference. PSRAM_SCLK_INV moves
// CE#/SIO to the falling edge (half a period of setup and of hold).
`ifdef PSRAM_SCLK_INV
localparam PSRAM_SCLK_POL = 1;
`else
localparam PSRAM_SCLK_POL = 0;
`endif

// same chip and CPU ports as sdram_ctrl (see rtl/psram/psram_chip_ctrl.sv)
psram_chip_ctrl #(.CHIP_RD_SIZE(2'd2), .SCLK_INV(PSRAM_SCLK_POL)) ram1
(
	.sysclk       (clk_114         ),
	.reset_n      (~reset_d        ),
	.c_7m         (c1              ),
	.sys_locked   (locked          ),

	.cache_rst    (cpu_rst         ),
	.cpu_cache_ctrl(ram1_cacr      ),
	.cache_inhibit(ram1_cache_inh  ),

	.clk_ram      (clk_ram         ),
	.clk_cap      (clk_ram_cap     ),
	.scanclk      (CLK_50M         ),
	.ram_locked   (ram_pll_locked  ),
	.pll_phase_done(ram_pll_phase_done),
	.pll_phase_en (ram_pll_phase_en),
	.pll_updn     (ram_pll_updn    ),
	.pll_cntsel   (ram_pll_cntsel  ),

	.PSA_SCLK     (PSRAM_SCLK      ),   // chip A: D15..D8
	.PSA_CE_N     (PSRAM_CE_N      ),
	.PSA_SIO_OUT  (PSRAM_SIO_OUT   ),
	.PSA_SIO_OE   (PSRAM_SIO_OE    ),
	.PSA_SIO_IN   (PSRAM_SIO_IN    ),
	.PSB_SCLK     (PSRAM2_SCLK     ),   // chip B: D7..D0
	.PSB_CE_N     (PSRAM2_CE_N     ),
	.PSB_SIO_OUT  (PSRAM2_SIO_OUT  ),
	.PSB_SIO_OE   (PSRAM2_SIO_OE   ),
	.PSB_SIO_IN   (PSRAM2_SIO_IN   ),

	.ready        (ram1_ready      ),
	.cal_done_s   (ram1_cal_done   ),
	.cal_fail_s   (ram1_cal_fail   ),
	.cal_c_s      (ram1_cal_c      ),
	.cal_status   (                ),
	.ovr          (                ),
	.dbg_rd_lat   (                ),

	.cpuWR        (ram1_cpu_wr     ),
	.cpuAddr      (ram1_cpu_addr   ),
	.cpuU         (ram1_cpu_u      ),
	.cpuL         (ram1_cpu_l      ),
	.cpustate     (ram1_cpu_state  ),
	.cpuCS        (ram1_cpu_cs     ),
	.cpuRD        (ram_dout1       ),
	.ramready     (ram_ready1      ),
	.write_busy   (ram1_write_busy ),

	.chipWR       (cw_ram_data     ),
	.chipAddr     (cw_ram_address  ),
	.chipU        (cw_ram_bhe      ),
	.chipL        (cw_ram_ble      ),
	.chipRW       (cw_ram_we       ),
	.chipDMA      (cw_ram_oe       ),
	.chipRD       (ramdata_in      ),
	.chip48       (chip48          )
);

// no SDRAM on this board
assign SDRAM_CLK  = 1'b0;
assign SDRAM_CKE  = 1'b0;
assign SDRAM_A    = 13'd0;
assign SDRAM_BA   = 2'd0;
assign SDRAM_DQ   = 16'hZZZZ;
assign SDRAM_DQML = 1'b1;
assign SDRAM_DQMH = 1'b1;
assign SDRAM_nCS  = 1'b1;
assign SDRAM_nWE  = 1'b1;
assign SDRAM_nRAS = 1'b1;
assign SDRAM_nCAS = 1'b1;
`else
sdram_ctrl ram1
(
	.sysclk       (clk_114         ),
	.reset_n      (~reset_d        ),
	.c_7m         (c1              ),
""")

rep("""	.chipRD       (ramdata_in      ),
	.chip48       (chip48          )
);

// ram2 (the fabric Z3 controller) is gone""", """	.chipRD       (ramdata_in      ),
	.chip48       (chip48          )
);
`endif

// ram2 (the fabric Z3 controller) is gone""")

# ---- power LED and the Chameleon96 status block
rep("""assign LED_POWER[0] = pwr_led | ~led_dim;
""", """`ifdef MISTER_CHAMELEON96
// Chameleon96 bring-up: PSRAM calibration on the user LEDs
//   D5 (LED_USER):  ~4 Hz blink = calibrating (the blink is made by the PSRAM PLL:
//                   no blink at all = that PLL does not run), ~1 Hz blink = calibration
//                   failed, steady on = calibrated
//   D6 (LED_DISK) / D7 (LED_POWER): c*[1] / c*[2], the capture column found
//   After ~9 s of a good calibration the LEDs return to floppy / HDD / power.
reg  [1:0] ram_aux_s   = 2'b00;
reg  [1:0] cal_done_ss = 2'b00;
reg  [1:0] cal_fail_ss = 2'b00;
reg [27:0] cal_show    = 28'd0;
reg [24:0] cal_blink   = 25'd0;
always @(posedge clk_sys) begin
	ram_aux_s   <= {ram_aux_s[0], ram_aux_div[23]};
	cal_done_ss <= {cal_done_ss[0], ram1_cal_done};
	cal_fail_ss <= {cal_fail_ss[0], ram1_cal_fail};
	cal_blink   <= cal_blink + 1'd1;
	if (!cal_done_ss[1])  cal_show <= 28'd0;
	else if (~&cal_show)  cal_show <= cal_show + 1'd1;
end
wire cal_ok      = cal_done_ss[1] & ~cal_fail_ss[1];
wire cal_showing = ~cal_ok | ~&cal_show;
wire cal_led     = ~cal_done_ss[1] ? ram_aux_s[1] : cal_fail_ss[1] ? cal_blink[24] : 1'b1;
assign LED_USER  = cal_showing ? cal_led : fdd_led;
assign LED_DISK  = cal_showing ? {1'b1, cal_ok & ram1_cal_c[1]} : {1'b0, ide_fast ? ide_f_led : ide_c_led};
assign LED_POWER = cal_showing ? {1'b1, cal_ok & ram1_cal_c[2]} : {1'b1, pwr_led | ~led_dim};
`else
assign LED_POWER[0] = pwr_led | ~led_dim;
`endif
""")

if crlf:
    s = s.replace('\n', '\r\n')
open(dst, 'w', newline='').write(s)
print("patch_bigmig_sv: ok ->", dst)
