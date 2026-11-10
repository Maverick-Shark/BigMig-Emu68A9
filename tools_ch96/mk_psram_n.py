#!/usr/bin/env python3
"""Derive psram_n.sv from teiram's psram.sv (Amstrad_MiSTer_ch96):
adds a 4-byte ('dw') transfer for reads and writes, widens din/dout to 32 bits.
Every replacement must match exactly once, so a changed upstream file fails loudly."""
import sys

src, dst = sys.argv[1], sys.argv[2]
s = open(src).read()

def rep(old, new, count=1):
    global s
    n = s.count(old)
    if n != count:
        sys.exit(f"pattern found {n}x (expected {count}):\n{old}")
    s = s.replace(old, new)

rep("module psram #(", "module psram_n #(")
rep("    input [1:0]  wtbt,\n", "    input [1:0]  wtbt,\n    input        dw,          // 4-byte transfer (8 nibbles), addr[1:0] ignored\n")
rep("    input [15:0] din,\n", "    input [31:0] din,\n")
rep("    output reg [15:0] dout,\n", "    output reg [31:0] dout,\n")
rep("    reg fword = 1'b0;\n", "    reg fword = 1'b0;\n    reg fdw = 1'b0;\n")
rep("    reg [7:0] wd1 = 8'h00;\n", "    reg [7:0] wd1 = 8'h00;\n    reg [7:0] wd2 = 8'h00;\n    reg [7:0] wd3 = 8'h00;\n")
rep("""                        4'ha:    drive_val = wd1[7:4];
                        default: drive_val = wd1[3:0];""",
    """                        4'ha:    drive_val = wd1[7:4];
                        4'hb:    drive_val = wd1[3:0];
                        4'hc:    drive_val = wd2[7:4];
                        4'hd:    drive_val = wd2[3:0];
                        4'he:    drive_val = wd3[7:4];
                        default: drive_val = wd3[3:0];""")
rep("RD2:  cap_count = fword ? 7'd4 : 7'd2;", "RD2:  cap_count = fdw ? 7'd8 : fword ? 7'd4 : 7'd2;")
rep("""                    if (fword) dout <= {rnib[2], rnib[3], rnib[0], rnib[1]};
                    else       dout <= {8'h0, rnib[0], rnib[1]};""",
    """                    if (fdw)        dout <= {rnib[0], rnib[1], rnib[2], rnib[3],
                                             rnib[4], rnib[5], rnib[6], rnib[7]};
                    else if (fword) dout <= {16'h0, rnib[2], rnib[3], rnib[0], rnib[1]};
                    else            dout <= {24'h0, rnib[0], rnib[1]};""")
# init frames: two extra data bytes in the frame_go signature
rep("8'h66, 24'h0, 8'h0, 8'h0);", "8'h66, 24'h0, 8'h0, 8'h0, 8'h0, 8'h0);")
rep("8'h99, 24'h0, 8'h0, 8'h0);", "8'h99, 24'h0, 8'h0, 8'h0, 8'h0, 8'h0);")
rep("8'h35, 24'h0, 8'h0, 8'h0);", "8'h35, 24'h0, 8'h0, 8'h0, 8'h0, 8'h0);")
rep("""                        if (rd && ~old_rd) begin
                            fword <= (wtbt == 2'b11);
                            if (wtbt == 2'b11)
                                frame_go(RD2, 20, 8'heb,
                                         {1'b0,addr[22:1],1'b0}, 8'h0, 8'h0);
                            else
                                frame_go(RD2, 18, 8'heb,
                                         {1'b0,addr[22:1],
                                          (wtbt==2'b00)?addr[0]:
                                          (wtbt==2'b10)?1'b1:1'b0}, 8'h0,8'h0);
                        end else if (we && ~old_we) begin
                            if (wtbt == 2'b11)
                                frame_go(WR2, 12, 8'h02, {1'b0,addr[22:1],1'b0},
                                         din[7:0], din[15:8]);
                            else
                                frame_go(WR2, 10, 8'h02,
                                         {1'b0,addr[22:1],
                                          (wtbt==2'b00)?addr[0]:
                                          (wtbt==2'b10)?1'b1:1'b0},
                                         din[7:0], din[7:0]);
                        end""",
    """                        if (rd && ~old_rd) begin
                            fword <= ~dw && (wtbt == 2'b11);
                            fdw   <= dw;
                            if (dw)
                                frame_go(RD2, 24, 8'heb,
                                         {1'b0,addr[22:2],2'b00}, 8'h0,8'h0,8'h0,8'h0);
                            else if (wtbt == 2'b11)
                                frame_go(RD2, 20, 8'heb,
                                         {1'b0,addr[22:1],1'b0}, 8'h0,8'h0,8'h0,8'h0);
                            else
                                frame_go(RD2, 18, 8'heb,
                                         {1'b0,addr[22:1],
                                          (wtbt==2'b00)?addr[0]:
                                          (wtbt==2'b10)?1'b1:1'b0}, 8'h0,8'h0,8'h0,8'h0);
                        end else if (we && ~old_we) begin
                            if (dw)
                                frame_go(WR2, 16, 8'h02, {1'b0,addr[22:2],2'b00},
                                         din[31:24], din[23:16], din[15:8], din[7:0]);
                            else if (wtbt == 2'b11)
                                frame_go(WR2, 12, 8'h02, {1'b0,addr[22:1],1'b0},
                                         din[7:0], din[15:8], 8'h0, 8'h0);
                            else
                                frame_go(WR2, 10, 8'h02,
                                         {1'b0,addr[22:1],
                                          (wtbt==2'b00)?addr[0]:
                                          (wtbt==2'b10)?1'b1:1'b0},
                                         din[7:0], din[7:0], 8'h0, 8'h0);
                        end""")
rep("""                            input [7:0] d0, input [7:0] d1);""",
    """                            input [7:0] d0, input [7:0] d1,
                            input [7:0] d2, input [7:0] d3);""")
rep("""            wd1 = d1;
""", """            wd1 = d1;
            wd2 = d2;
            wd3 = d3;
""")
rep("""    reg [3:0]  rnib [0:3];
    reg [1:0]  nidx = 2'd0;""", """    reg [3:0]  rnib [0:7];
    reg [2:0]  nidx = 3'd0;""")
rep("""            rnib[3] <= 4'h0;
            nidx    <= 2'd0;""", """            rnib[3] <= 4'h0;
            rnib[4] <= 4'h0;
            rnib[5] <= 4'h0;
            rnib[6] <= 4'h0;
            rnib[7] <= 4'h0;
            nidx    <= 3'd0;""")
rep("nidx <= nidx + 2'd1;", "nidx <= nidx + 3'd1;")
rep("nidx <= 2'd0;   // idle", "nidx <= 3'd0;   // idle")
rep("            fword <= 1'b0;\n", "            fword <= 1'b0;\n            fdw <= 1'b0;\n")

hdr = ("// psram_n -- derived for the BigMig/Chameleon96 study from teiram's psram.sv\n"
       "// (Amstrad_MiSTer_ch96, rtl/psram.sv, v3 lean). Only change: an extra 4-byte\n"
       "// ('dw') read/write frame and 32-bit din/dout. Capture logic is untouched.\n")
open(dst, "w").write(hdr + s)
print("ok:", dst)
