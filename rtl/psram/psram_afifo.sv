// psram_afifo -- small dual-clock FIFO for the BigMig / Chameleon96 chip RAM
// controller (psram_chip_ctrl).
//
// Classic gray-pointer design: binary + gray pointers on each side, the other
// side's gray pointer brought over with a two-flop synchroniser, register
// storage (DEPTH = 2**AW entries, AW >= 1), first-word fall-through read.
//
// wrst / rrst are asynchronous-assert resets in their own domain; the caller
// asserts both together (same source) so the two pointers always restart in
// step.
//
// SYNC = 1 removes the synchronisers, for use when wclk and rclk are the same
// clock (lets the controller run with SCLK = clk_114 later without a rewrite).
//
// Copyright 2026 -- GPL-3.0-or-later, same terms as BigMig.

module psram_afifo #(
    parameter integer W    = 8,
    parameter integer AW   = 2,
    parameter         SYNC = 0
) (
    input  wire          wclk,
    input  wire          wrst,
    input  wire          wr,
    input  wire [W-1:0]  wdata,
    output wire          wfull,

    input  wire          rclk,
    input  wire          rrst,
    input  wire          rd,
    output wire [W-1:0]  rdata,
    output wire          rempty
);
    localparam integer N = 1 << AW;

    // flops, not MLAB: the storage must be plain registers for the SDC net-delay limits
    (* ramstyle = "logic" *) reg [W-1:0] mem [0:N-1];

    reg [AW:0] wbin = {(AW+1){1'b0}}, wgray = {(AW+1){1'b0}};
    reg [AW:0] rbin = {(AW+1){1'b0}}, rgray = {(AW+1){1'b0}};

    wire [AW:0] rgray_w;     // read pointer as seen by the write side
    wire [AW:0] wgray_r;     // write pointer as seen by the read side

    wire        do_wr   = wr & ~wfull;
    wire        do_rd   = rd & ~rempty;
    wire [AW:0] wbin_n  = wbin + {{AW{1'b0}}, do_wr};
    wire [AW:0] wgray_n = (wbin_n >> 1) ^ wbin_n;
    wire [AW:0] rbin_n  = rbin + {{AW{1'b0}}, do_rd};
    wire [AW:0] rgray_n = (rbin_n >> 1) ^ rbin_n;

    always @(posedge wclk or posedge wrst) begin
        if (wrst) begin
            wbin  <= {(AW+1){1'b0}};
            wgray <= {(AW+1){1'b0}};
        end else begin
            wbin  <= wbin_n;
            wgray <= wgray_n;
        end
    end

    always @(posedge wclk) begin
        if (do_wr) mem[wbin[AW-1:0]] <= wdata;
    end

    always @(posedge rclk or posedge rrst) begin
        if (rrst) begin
            rbin  <= {(AW+1){1'b0}};
            rgray <= {(AW+1){1'b0}};
        end else begin
            rbin  <= rbin_n;
            rgray <= rgray_n;
        end
    end

    generate
        if (SYNC) begin : g_sync
            assign rgray_w = rgray;
            assign wgray_r = wgray;
        end else begin : g_async
            reg [AW:0] rg_w1 = {(AW+1){1'b0}}, rg_w2 = {(AW+1){1'b0}};
            reg [AW:0] wg_r1 = {(AW+1){1'b0}}, wg_r2 = {(AW+1){1'b0}};
            always @(posedge wclk or posedge wrst) begin
                if (wrst) begin
                    rg_w1 <= {(AW+1){1'b0}};
                    rg_w2 <= {(AW+1){1'b0}};
                end else begin
                    rg_w1 <= rgray;
                    rg_w2 <= rg_w1;
                end
            end
            always @(posedge rclk or posedge rrst) begin
                if (rrst) begin
                    wg_r1 <= {(AW+1){1'b0}};
                    wg_r2 <= {(AW+1){1'b0}};
                end else begin
                    wg_r1 <= wgray;
                    wg_r2 <= wg_r1;
                end
            end
            assign rgray_w = rg_w2;
            assign wgray_r = wg_r2;
        end
    endgenerate

    // full: the write pointer is one lap ahead (top two gray bits inverted)
    generate
        if (AW >= 2) begin : g_full2
            assign wfull = (wgray == {~rgray_w[AW:AW-1], rgray_w[AW-2:0]});
        end else begin : g_full1
            assign wfull = (wgray == ~rgray_w);
        end
    endgenerate

    assign rempty = (wgray_r == rgray);
    assign rdata  = mem[rbin[AW-1:0]];
endmodule
