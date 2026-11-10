`timescale 1ns/1ps
// psram_dual -- two APS6404L driven in lock-step as ONE 16-bit-wide memory,
// the layout proposed for BigMig chip RAM on the Chameleon96:
//
//   chip A = high byte lane (D15..D8), chip B = low byte lane (D7..D0)
//   16-bit word address W  ->  byte address W inside BOTH chips
//
// so a 16-bit word costs one byte (2 nibbles) per chip, a 32-bit access two
// bytes and a 64-bit (AGA FMODE 3) access four bytes per chip. A byte write
// (UDS or LDS only) is issued to one chip only: that is how byte enables are
// done, since the PSRAM has no data mask.
//
// Both chips share clk (also the SCLK pads), one capture clock and one
// calibration (teiram's psram_cal3 + psram_dps, unchanged): the calibrator owns
// both host ports while busy, exactly as in ram_bridge.sv.
//
// Host port (clk domain, after cal_done):
//   ready  : a request is accepted in a cycle where ready && req
//   size   : 0 = 1 word, 1 = 2 words (W even), 2 = 4 words (W multiple of 4)
//   be     : byte enables for 1-word writes ({A,B}); ignored otherwise
//   wdata/rdata packing: word0 in [63:48], word1 [47:32], word2 [31:16], word3 [15:0]
//   done   : one-cycle pulse when the operation is complete (rdata valid for reads)
module psram_dual #(
    parameter integer S            = 20,
    parameter [22:0]  CAL_BASE     = 23'h7F0000,
    parameter [4:0]   DPS_CNTL     = 5'd2,
    parameter         DPS_DIRUP    = 1'b1,
    parameter integer PWRUP_CYCLES = 30000,
    parameter integer RST_CYCLES   = 4000,
    parameter integer MID_CYCLES   = 100,
    parameter integer CAL_WORDS    = 16,
    parameter integer CAL_PASSES   = 4,
    // 0: SCLK = clk (teiram's v3: CE#/SIO change on the SCLK rising edge and rely on
    //    the pad delays for the device's input hold). 1: SCLK = ~clk, CE#/SIO change
    //    on the SCLK falling edge (half a period of setup and of hold).
    parameter         SCLK_INV     = 0
) (
    // chip A pads (high byte lane)
    output        PSA_SCLK,
    output        PSA_CE_N,
    output [3:0]  PSA_SIO_OUT,
    output [3:0]  PSA_SIO_OE,
    input  [3:0]  PSA_SIO_IN,
    // chip B pads (low byte lane)
    output        PSB_SCLK,
    output        PSB_CE_N,
    output [3:0]  PSB_SIO_OUT,
    output [3:0]  PSB_SIO_OE,
    input  [3:0]  PSB_SIO_IN,
    // clocks / calibration
    input         init,
    input         clk,
    input         clk_cap,
    input         scanclk,
    input         pll_phase_done,
    output        pll_phase_en,
    output        pll_updn,
    output [4:0]  pll_cntsel,
    output        cal_done,
    output        cal_fail,
    output        cal_busy,
    output [63:0] cal_status,
    // host
    output        ready,
    input         req,
    input         we,
    input  [22:0] waddr,
    input  [1:0]  size,
    input  [1:0]  be,
    input  [63:0] wdata,
    output reg [63:0] rdata,
    output reg    done
);
    assign PSA_SCLK = SCLK_INV ? ~clk : clk;
    assign PSB_SCLK = SCLK_INV ? ~clk : clk;
    wire rst_n = ~init;

    // ------------------------------------------------------------ calibration
    wire [22:0] cal_addr;
    wire [1:0]  cal_wtbt;
    wire [15:0] cal_din;
    wire        cal_rd1, cal_we1, cal_rd2, cal_we2;
    wire [2:0]  cal_c;

    // ------------------------------------------------------------ host issue
    wire        a_ready, b_ready;
    wire [31:0] a_dout, b_dout;
    reg         busy = 1'b0;
    wire        issue = ready & req;
    wire        use_a = we ? (size != 2'd0 || be[1]) : 1'b1;
    wire        use_b = we ? (size != 2'd0 || be[0]) : 1'b1;

    // per-chip request fields (combinational from the request: the controller
    // edge-detects rd/we, so a one-cycle strobe starts the frame on that edge)
    wire        h_dw   = (size == 2'd2);
    wire [1:0]  h_wtbt = (size == 2'd1) ? 2'b11 : 2'b00;
    wire [22:0] h_addr = waddr;
    wire [31:0] a_din  = (size == 2'd2) ? {wdata[63:56], wdata[47:40], wdata[31:24], wdata[15:8]} :
                         (size == 2'd1) ? {16'h0, wdata[47:40], wdata[63:56]} :
                                          {24'h0, wdata[63:56]};
    wire [31:0] b_din  = (size == 2'd2) ? {wdata[55:48], wdata[39:32], wdata[23:16], wdata[7:0]} :
                         (size == 2'd1) ? {16'h0, wdata[39:32], wdata[55:48]} :
                                          {24'h0, wdata[55:48]};

    psram_n #(
        .PWRUP_CYCLES(PWRUP_CYCLES), .RST_CYCLES(RST_CYCLES), .MID_CYCLES(MID_CYCLES), .LEAN(1)
    ) chip_a (
        .clk(clk), .reset(~rst_n), .init(init),
        .ce_n(PSA_CE_N), .sio_out(PSA_SIO_OUT), .sio_oe(PSA_SIO_OE), .sio_in(PSA_SIO_IN),
        .clk_cap(clk_cap), .cap_sel(cal_c),
        .ready(a_ready),
        .addr (cal_busy ? cal_addr : h_addr),
        .wtbt (cal_busy ? cal_wtbt : h_wtbt),
        .dw   (cal_busy ? 1'b0     : h_dw),
        .rd   (cal_busy ? cal_rd1  : (issue & ~we & use_a)),
        .we   (cal_busy ? cal_we1  : (issue &  we & use_a)),
        .din  (cal_busy ? {16'h0, cal_din} : a_din),
        .dout (a_dout)
    );

    psram_n #(
        .PWRUP_CYCLES(PWRUP_CYCLES), .RST_CYCLES(RST_CYCLES), .MID_CYCLES(MID_CYCLES), .LEAN(1)
    ) chip_b (
        .clk(clk), .reset(~rst_n), .init(init),
        .ce_n(PSB_CE_N), .sio_out(PSB_SIO_OUT), .sio_oe(PSB_SIO_OE), .sio_in(PSB_SIO_IN),
        .clk_cap(clk_cap), .cap_sel(cal_c),
        .ready(b_ready),
        .addr (cal_busy ? cal_addr : h_addr),
        .wtbt (cal_busy ? cal_wtbt : h_wtbt),
        .dw   (cal_busy ? 1'b0     : h_dw),
        .rd   (cal_busy ? cal_rd2  : (issue & ~we & use_b)),
        .we   (cal_busy ? cal_we2  : (issue &  we & use_b)),
        .din  (cal_busy ? {16'h0, cal_din} : b_din),
        .dout (b_dout)
    );

    wire        dps_phase_en, dps_updn;
    wire [4:0]  dps_cntsel;
    wire        dps_req_tgl, dps_req_up, dps_done_tgl, dps_err;
    reg clk_det = 1'b0;
    always @(posedge clk_cap) clk_det <= clk;

    psram_cal3 #(
        .BASE_ADDR(CAL_BASE), .N_WORDS(CAL_WORDS), .PASSES(CAL_PASSES), .S(S), .DEF_C(3'd3)
    ) cal (
        .clk(clk), .rst_n(rst_n), .recal(1'b0),
        .ready1(a_ready), .dout1(a_dout[15:0]), .rd1(cal_rd1), .we1(cal_we1),
        .ready2(b_ready), .dout2(b_dout[15:0]), .rd2(cal_rd2), .we2(cal_we2),
        .addr(cal_addr), .wtbt(cal_wtbt), .din(cal_din),
        .cap_c(cal_c),
        .dps_req_tgl(dps_req_tgl), .dps_req_up(dps_req_up),
        .dps_done_tgl(dps_done_tgl), .dps_err(dps_err),
        .clk_det(clk_det),
        .busy(cal_busy), .done(cal_done), .fail(cal_fail), .status(cal_status)
    );

    psram_dps #(.CNTSEL(DPS_CNTL), .DIR_UP(DPS_DIRUP)) dps (
        .scanclk(scanclk), .rst_n(rst_n),
        .req_tgl(dps_req_tgl), .req_up(dps_req_up), .done_tgl(dps_done_tgl), .err(dps_err),
        .phase_en(dps_phase_en), .updn(dps_updn), .cntsel(dps_cntsel), .phase_done(pll_phase_done)
    );
    assign pll_phase_en = dps_phase_en;
    assign pll_updn     = dps_updn;
    assign pll_cntsel   = dps_cntsel;

    // ------------------------------------------------------------ completion
    // per lane: 0 idle, 1 issued (ready not yet low), 2 running (wait ready high)
    reg [1:0] sa = 2'd0, sb = 2'd0;
    reg [1:0] op_size = 2'd0;
    reg       op_we = 1'b0;
    assign ready = cal_done & ~cal_busy & ~busy & a_ready & b_ready;

    function automatic [63:0] pack(input [1:0] sz, input [31:0] a, input [31:0] b);
        case (sz)
            2'd2:    pack = {a[31:24], b[31:24], a[23:16], b[23:16], a[15:8], b[15:8], a[7:0], b[7:0]};
            2'd1:    pack = {a[7:0], b[7:0], a[15:8], b[15:8], 32'h0};
            default: pack = {a[7:0], b[7:0], 48'h0};
        endcase
    endfunction

    always @(posedge clk) begin
        done <= 1'b0;
        if (~rst_n) begin
            busy <= 1'b0; sa <= 2'd0; sb <= 2'd0;
        end else if (issue) begin
            busy    <= 1'b1;
            op_size <= size;
            op_we   <= we;
            sa      <= use_a ? 2'd1 : 2'd0;
            sb      <= use_b ? 2'd1 : 2'd0;
        end else if (busy) begin
            case (sa)
                2'd1: if (~a_ready) sa <= 2'd2;
                2'd2: if ( a_ready) sa <= 2'd0;
                default: ;
            endcase
            case (sb)
                2'd1: if (~b_ready) sb <= 2'd2;
                2'd2: if ( b_ready) sb <= 2'd0;
                default: ;
            endcase
            // finished when every used lane is back to ready (checked on the
            // live ready so the pulse comes on the same edge as the last return)
            if ((sa == 2'd0 || (sa == 2'd2 && a_ready)) &&
                (sb == 2'd0 || (sb == 2'd2 && b_ready))) begin
                busy  <= 1'b0;
                done  <= 1'b1;
                sa    <= 2'd0;
                sb    <= 2'd0;
                if (~op_we) rdata <= pack(op_size, a_dout, b_dout);
            end
        end
    end
endmodule
