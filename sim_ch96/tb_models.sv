`timescale 1ns/1ps
// Behavioural board models for the PSRAM testbenches:
//   pll_dps_model : capture clock = clk delayed by a phase that the DPS port
//                   steps by STEP ns (one VCO/8 tap) per phase_en pulse.
//   ps_pads       : one APS6404L behind the loan-I/O pads, with forward and
//                   return delays and the device's clock-to-output time.

module pll_dps_model #(
    parameter real  PHI0 = 1.1719,     // static phase of the capture output (ns)
    parameter real  STEP = 0.1953125,  // one DPS step (ns)
    parameter [4:0] CNT  = 5'd2
) (
    input  wire       clk,
    input  wire       scanclk,
    input  wire       phase_en,
    input  wire       updn,
    input  wire [4:0] cntsel,
    output reg        phase_done,
    output wire       clk_cap
);
    real phi;
    reg  cap_r;
    initial begin phi = PHI0; phase_done = 1'b1; cap_r = 1'b0; end
    always @(clk) cap_r <= #(phi) clk;
    assign clk_cap = cap_r;
    always @(posedge phase_en) begin
        @(posedge scanclk);
        phase_done = 1'b0;
        if (cntsel == CNT) phi = phi + (updn ? STEP : -STEP);
        #25.0;
        phase_done = 1'b1;
    end
endmodule

module ps_pads #(
    parameter real    DFWD  = 1.0,     // fabric -> pad -> device (ns)
    parameter real    DBACK = 1.0,     // device -> pad -> fabric (ns)
    parameter real    DSKEW = 0.3,     // extra on CE#/SIO vs SCLK (ns)
    parameter real    TACLK = 3.5,     // device clock-to-output (ns)
    parameter integer WAIT  = 5,       // model's EBh wait count (5 = datasheet)
    parameter integer DEPTH = 1 << 23
) (
    input  wire       sclk_f,
    input  wire       ce_n_f,
    input  wire [3:0] sio_out_f,
    input  wire [3:0] sio_oe_f,
    output wire [3:0] sio_in_b
);
    reg        sclk_d   = 1'b0;
    reg        ce_d     = 1'b1;
    reg [3:0]  sio_fwd  = 4'bzzzz;
    tri  [3:0] sio_dev;
    reg [3:0]  sio_back = 4'h0;
    always @(sclk_f)                sclk_d  <= #(DFWD)         sclk_f;
    always @(ce_n_f)                ce_d    <= #(DFWD + DSKEW) ce_n_f;
    always @(sio_out_f or sio_oe_f) sio_fwd <= #(DFWD + DSKEW) ((sio_oe_f != 4'h0) ? sio_out_f : 4'bzzzz);
    assign sio_dev = sio_fwd;
    always @(sio_dev)               sio_back <= #(DBACK) sio_dev;
    assign sio_in_b = sio_back;
    // ---- datasheet input timing at the device pins (host-driven phases only)
    reg      mon = 1'b0;
    realtime t_pos = 0.0, t_sio = 0.0, t_cef = 0.0;
    realtime tsp_min = 1.0e9, thd_min = 1.0e9, tcsp_min = 1.0e9, tchd_min = 1.0e9;
    reg      first = 1'b0;
    always @(posedge sclk_d) begin
        if (mon && !ce_d) begin
            if (first && ($realtime - t_cef) < tcsp_min) tcsp_min = $realtime - t_cef;
            if (sio_fwd !== 4'bzzzz && ($realtime - t_sio) < tsp_min) tsp_min = $realtime - t_sio;
        end
        first = 1'b0;
        t_pos = $realtime;
    end
    always @(sio_fwd) begin
        if (mon && !ce_d && ($realtime - t_pos) < thd_min) thd_min = $realtime - t_pos;
        t_sio = $realtime;
    end
    always @(ce_d) begin
        if (ce_d === 1'b0) begin t_cef = $realtime; first = 1'b1; end
        else if (mon && ce_d === 1'b1 && ($realtime - t_pos) < tchd_min) tchd_min = $realtime - t_pos;
    end

    aps6404l_model #(.DEPTH(DEPTH), .TACLK_NS(TACLK), .TOH_NS(0.0), .WAIT_EB(WAIT))
        u_mem (.sclk(sclk_d), .ce_n(ce_d), .sio(sio_dev));
endmodule
