#!/usr/bin/env python3
"""Chameleon96 additions to the merged sys/sys_top.v.

* BIGMIG_NO_RTG_ANALOG (no VGA / analog output on the board): the RTG
  native-rate analog scanout (rtg_ddr_reader, rtg_scanout, its OSD, csync and
  vga_out) is left out, its DDR read port on the ram2 arbiter (or ram1 without
  the GPU) is parked and the analog mux inputs are tied to zero. The HDMI mouse
  pointer (rtg_hdmi_osd_sprite) stays.
* FAN_PWM output, as in teiram's Template_MiSTer_ch96 (loan I/O 49).
* MISTER_CHAMELEON96: the GPU's DDR accesses are pinned into
  0x10000000-0x1FFFFFFF, the half of the 512 MB that Linux does not own.

Every replacement must match exactly once.
Usage: patch_sys_top.py <in sys_top.v> <out sys_top.v>"""
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src, newline='').read().replace('\r\n', '\n')


def rep(old, new):
    global s
    n = s.count(old)
    if n != 1:
        sys.exit(f"patch_sys_top: pattern found {n}x (expected 1):\n{old}")
    s = s.replace(old, new)


rep("""// native-rate RTG analog scanout (instantiated at the end of the module), for RTG modes up to 640x480
wire        rtg_native_en = 1'b1;

wire        rtg_scanout_active = RTG_EN & rtg_native_en &
                                 (RTG_HEIGHT != 12'd0) & (RTG_HEIGHT <= 12'd480) &
                                 (RTG_WIDTH  != 12'd0) & (RTG_WIDTH  <= 12'd640) &
                                 rtg_fmt_ok;
""", """// native-rate RTG analog scanout (instantiated at the end of the module), for RTG modes up to 640x480
`ifdef BIGMIG_NO_RTG_ANALOG
// no analog output on this board: RTG is shown through the scaler (HDMI) only
wire        rtg_scanout_active = 1'b0;
`else
wire        rtg_native_en = 1'b1;

wire        rtg_scanout_active = RTG_EN & rtg_native_en &
                                 (RTG_HEIGHT != 12'd0) & (RTG_HEIGHT <= 12'd480) &
                                 (RTG_WIDTH  != 12'd0) & (RTG_WIDTH  <= 12'd640) &
                                 rtg_fmt_ok;
`endif
""")

rep("""`else
assign ram_clk = clk_100m;
`endif

wire [1:0] rtg_cmode  = (RTG_FMT[2:0]==3'b011) ? 2'd0 :   // 8bpp CLUT
""", """`else
assign ram_clk = clk_100m;
`endif

`ifdef BIGMIG_NO_RTG_ANALOG
// RTG analog scanout left out: park its DDR read port and the analog mux inputs
`ifdef BIGMIG_GPU
assign rtgr_address    = 29'd0;
assign rtgr_burstcount = 8'd0;
assign rtgr_read       = 1'b0;
`else
assign ram_address     = 29'd0;
assign ram_burstcount  = 8'd0;
assign ram_read        = 1'b0;
assign ram_writedata   = 64'd0;
assign ram_byteenable  = 8'd0;
assign ram_write       = 1'b0;
`endif
assign rtgs_o  = 24'd0;
assign rtgs_hs = 1'b0;
assign rtgs_vs = 1'b0;
assign rtgs_cs = 1'b0;
assign rtgs_de = 1'b0;
`else
wire [1:0] rtg_cmode  = (RTG_FMT[2:0]==3'b011) ? 2'd0 :   // 8bpp CLUT
""")

rep("""	.csync_o  (rtgs_cs),
	.de_o     (rtgs_de)
);


endmodule
""", """	.csync_o  (rtgs_cs),
	.de_o     (rtgs_de)
);
`endif // BIGMIG_NO_RTG_ANALOG


endmodule
""")

# ---- fan PWM, as teiram's Template_MiSTer_ch96 (ae1702f): HPS TRACE_D0 lent to the
#      FPGA as loan I/O 49 by the hps-ch96 handoff from 97e5fe4 (2026-11-11) on
rep("""	input   [3:0] PSRAM2_SIO_IN,

`ifdef MISTER_DUAL_SDRAM""", """	input   [3:0] PSRAM2_SIO_IN,

	//////////// FAN (loan I/O 49) ///////////
	output        FAN_PWM,

`ifdef MISTER_DUAL_SDRAM""")

rep("""assign LED = (led_overtake & led_state) | (~led_overtake & {1'b0, led_locked, 1'b0, ~led_p, 1'b1, ~led_d, HDMI_TX_DE, ~led_u});
""", """assign LED = (led_overtake & led_state) | (~led_overtake & {1'b0, led_locked, 1'b0, ~led_p, 1'b1, ~led_d, HDMI_TX_DE, ~led_u});

///////////////////////////  FAN PWM  ///////////////////////////////////
// Same as teiram's Template_MiSTer_ch96: ~50 % duty at 50 MHz / 2^20 (~48 Hz).
// It reaches the fan only with an hps-ch96 preloader that lends TRACE_D0 (loan I/O 49).
reg [19:0] fan_cnt = 20'd0;
reg        fan_pwm = 1'b0;
localparam [19:0] FAN_DUTY = 20'd524288;
always @(posedge FPGA_CLK2_50) begin
	fan_cnt <= fan_cnt + 1'b1;
	fan_pwm <= (fan_cnt > FAN_DUTY);
end
assign FAN_PWM = fan_pwm;
""")

# ---- GPU DDR window: on the Chameleon96 Linux owns 0x00000000-0x0FFFFFFF and the
#      512 MB controller drops the upper address bits, so a stray GPU address
#      (a DE10 firmware base such as 0x27000000) would write Linux memory.
rep("""	.avl_address(ram_address), .avl_burstcount(ram_burstcount), .avl_waitrequest(ram_waitrequest),""",
    """	.avl_address(gpu_avl_address), .avl_burstcount(ram_burstcount), .avl_waitrequest(ram_waitrequest),""")
rep("""bm_gpu_top #(.N(2), .UC_FILE("rtl/gpu/bigmig/bm_setup_ucode.hex"), .LUT_FILE("rtl/gpu/bigmig/bm_setup_lut.hex"),""",
    """wire [28:0] gpu_avl_address;
`ifdef MISTER_CHAMELEON96
// Chameleon96: pin every GPU access into the half Linux does not use,
// 0x10000000-0x1FFFFFFF (ram1 is 64-bit, word address bits [28:25] = 4'b0001).
// The 512 MB controller would otherwise fold 0x2xxxxxxx/0x3xxxxxxx onto Linux memory.
assign ram_address = {4'b0001, gpu_avl_address[24:0]};
`else
assign ram_address = gpu_avl_address;
`endif

bm_gpu_top #(.N(2), .UC_FILE("rtl/gpu/bigmig/bm_setup_ucode.hex"), .LUT_FILE("rtl/gpu/bigmig/bm_setup_lut.hex"),""")

open(dst, 'w', newline='').write(s)
print("patch_sys_top: ok ->", dst)
