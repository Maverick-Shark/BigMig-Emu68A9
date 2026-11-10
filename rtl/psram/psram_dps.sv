`timescale 1ns/1ps

// psram_dps -- one-step-at-a-time driver for the altera_pll dynamic phase shift ports.
//
// Runs in the scanclk domain (use the 100 MHz PLL reference clock). The fabric
// side talks to it with a toggle handshake, so no multi-bit signal crosses
// clock domains unprotected:
//
//   fabric: set req_up, wait >= 2 fabric clocks, toggle req_tgl
//   here  : 2-FF synchronise req_tgl, do ONE phase step, toggle done_tgl
//   fabric: 2-FF synchronise done_tgl; a change means "step finished"
//
// One step moves the selected output's phase by 1/8 of the VCO period
// (see the Fitter's "PLL Usage" report for the exact value).
//
// Handshake with the PLL, deliberately conservative (the datasheet allows the
// phase_done low pulse to be shorter than one scanclk cycle, so it is NOT relied
// upon to be observed):
//   * updn / cntsel are set one cycle before phase_en,
//   * phase_en is high for exactly 2 scanclk cycles,
//   * then a fixed GAP wait,
//   * then wait until phase_done has been high for 4 consecutive cycles.
// If phase_done does not return within TMO cycles, `err` is set (sticky) and the
// step is reported as finished anyway so the caller never hangs.

module psram_dps #(
    parameter [4:0]   CNTSEL = 5'd1,      // logical counter of the capture output (C1 = outclk_1)
    parameter         DIR_UP = 1'b1,      // updn value that means "later phase"
    parameter integer GAP    = 24,        // scanclk cycles to wait after phase_en
    parameter integer TMO    = 4096       // scanclk cycles to wait for phase_done
) (
    input  wire       scanclk,
    input  wire       rst_n,              // any domain; synchronised here

    // fabric-side handshake
    input  wire       req_tgl,
    input  wire       req_up,             // 1 = later phase; stable before req_tgl toggles
    output reg        done_tgl,
    output reg        err,

    // PLL ports
    output reg        phase_en,
    output reg        updn,
    output wire [4:0] cntsel,
    input  wire       phase_done
);

    assign cntsel = CNTSEL;

    // reset synchroniser (assert asynchronously, release in scanclk domain)
    reg rs0 = 1'b0, rs1 = 1'b0;
    always @(posedge scanclk or negedge rst_n) begin
        if (!rst_n) begin rs0 <= 1'b0; rs1 <= 1'b0; end
        else        begin rs0 <= 1'b1; rs1 <= rs0; end
    end

    reg [1:0] rq   = 2'b00;    // synchroniser for req_tgl
    reg       seen = 1'b0;     // last request toggle value handled
    reg [3:0] pdq  = 4'b1111;  // phase_done synchroniser / history
    reg [1:0] st   = 2'd0;
    reg [15:0] cnt = 16'd0;
    reg [2:0]  hi  = 3'd0;

    localparam [1:0] S_IDLE = 2'd0, S_EN = 2'd1, S_GAP = 2'd2, S_HIGH = 2'd3;

    always @(posedge scanclk) begin
        if (!rs1) begin
            rq <= 2'b00; seen <= 1'b0; pdq <= 4'b1111;
            st <= S_IDLE; cnt <= 16'd0; hi <= 3'd0;
            phase_en <= 1'b0; updn <= DIR_UP; done_tgl <= 1'b0; err <= 1'b0;
        end else begin
            rq  <= {rq[0], req_tgl};
            pdq <= {pdq[2:0], phase_done};

            case (st)
                S_IDLE: begin
                    phase_en <= 1'b0;
                    if (rq[1] != seen) begin
                        seen <= rq[1];
                        updn <= req_up ? DIR_UP : ~DIR_UP;
                        cnt  <= 16'd0;
                        st   <= S_EN;
                    end
                end
                S_EN: begin                       // updn is stable; pulse phase_en for 2 cycles
                    cnt <= cnt + 16'd1;
                    if (cnt == 16'd0)      phase_en <= 1'b1;
                    else if (cnt == 16'd2) begin
                        phase_en <= 1'b0;
                        cnt      <= 16'd0;
                        st       <= S_GAP;
                    end
                end
                S_GAP: begin
                    cnt <= cnt + 16'd1;
                    if (cnt == GAP) begin
                        cnt <= 16'd0;
                        hi  <= 3'd0;
                        st  <= S_HIGH;
                    end
                end
                S_HIGH: begin
                    cnt <= cnt + 16'd1;
                    if (pdq[1]) hi <= (hi == 3'd7) ? hi : hi + 3'd1;
                    else        hi <= 3'd0;
                    if (hi >= 3'd4) begin          // phase_done high for >= 4 cycles
                        done_tgl <= ~done_tgl;
                        st       <= S_IDLE;
                    end else if (cnt == TMO) begin
                        err      <= 1'b1;
                        done_tgl <= ~done_tgl;
                        st       <= S_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
