#!/usr/bin/env python3
"""BIGMIG_NO_RTG_ANALOG for sys/sys_top.v (Chameleon96: no VGA / analog output).

With the macro defined, the RTG native-rate analog scanout (rtg_ddr_reader,
rtg_scanout, its OSD, csync and vga_out) is left out, its DDR read port on the
ram2 arbiter (or ram1 without the GPU) is parked and the analog mux inputs are
tied to zero. The HDMI mouse pointer (rtg_hdmi_osd_sprite) stays.
Without the macro the file is the merged BigMig + Chameleon96 framework.

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

open(dst, 'w', newline='').write(s)
print("patch_sys_top: ok ->", dst)
