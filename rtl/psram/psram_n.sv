// psram_n -- derived for the BigMig/Chameleon96 study from teiram's psram.sv
// (Amstrad_MiSTer_ch96, rtl/psram.sv, v3 lean). Only change: an extra 4-byte
// ('dw') read/write frame and 32-bit din/dout. Capture logic is untouched.
`timescale 1ns/1ps

// psram -- APS6404L QPI controller, dynamic-phase read capture (2 clocks).
//
// Clocks: `clk` (fabric, also the SCLK source) and `clk_cap` (same frequency,
// phase-shifted by the PLL; its phase is stepped at run time by psram_dps).
//
// Read capture: the pad is sampled on BOTH edges of clk_cap
//     pp: rising  edge  -> instant E(k) + phi          ("P(k)")
//     pn: falling edge  -> instant E(k) + phi + T/2    ("N(k)")
// where phi is the current capture phase relative to clk. `cap_sel` (= coarse
// index c, 0..7) picks which sample is used for read nibble i:
//     c even: P(15+i+c/2)      c odd: N(15+i+(c-1)/2)
//     sample instant = E(15+i) + c*T/2 + phi
// phi is restricted (by the PLL start phase and the sweep length) to a window
// of one half period inside the "safe zone" of the transfers into clk:
//     pp -> clk rising edge,  pn -> clk falling edge -> clk rising edge.
// Within that window the transfers have >= ~0.3 T of setup and ~0.15 T of hold
// margin, so they never go metastable, whatever the sweep position.
//
// cap_sel is latched when a frame is issued; change it only while idle.
//
// Costs: read results arrive DRAIN(=5) cycles later, and for cap_sel >= 2 CE#
// is held low 1..3 cycles longer so the device is still driving when the late
// sample is taken. CE# high time between frames only gets longer.
module psram_n #(
    parameter integer PWRUP_CYCLES = 30000,   // ~234 us @128 MHz
    parameter integer RST_CYCLES   = 4000,    // tRST guard
    parameter integer MID_CYCLES   = 100,     // inter-op gap
    //
    // cycles between CE# release and result assembly (sample-history drain).
    // 5 is the verified v3 value (sized for the worst-case cap_sel=7 pipeline);
    // LEAN=1 (stage 2) ignores it and uses 2 + cap_sel/2 per frame instead.
    parameter integer DRAIN        = 5,
    //
    // Stage 2 ("lean drain", board-booted variant):
    //   * write always from `pick` (the 3-stage tap; content X(n-3) == what the
    //     v3 per-c tap chain delivered, arrived earlier: identical sample
    //     because the pad capture instants are untouched),
    //   * write-enabling fire depth 2 + cap_sel/2,
    //   * frame drain 2 + cap_sel/2 (same as the fire depth, so the result is
    //     always on the tap >= 1 cycle before fread)
    // The pad capture, rd_ext (device CE hold) and the calibration window are
    // NOT touched: still the v3 rig silicon behaviour, just less fabric-side
    // wait. LEAN=0 keeps the 100 % v3-verbatim behaviour.
    parameter integer LEAN         = 0
) (
    input clk,
    input reset,
    input init,

    output reg ce_n,
    output reg [3:0] sio_out,
    output reg [3:0] sio_oe,
    input [3:0] sio_in,
    input clk_cap,            // capture clock: clk shifted by phi (PLL outclk_1)
    input [2:0] cap_sel,      // coarse capture point c (half periods), 0..7

    input [22:0] addr,
    input [1:0]  wtbt,
    input        dw,          // 4-byte transfer (8 nibbles), addr[1:0] ignored
    input rd,
    input we,
    input [31:0] din,
    output reg [31:0] dout,
    output ready
);

    localparam [1:0]
        SPI_BYTE = 2'd0,
        WR2 = 2'd2,
        RD2 = 2'd3;

    // ---- lean stage-2 drainer: write-enable depths and result tap ----
    //
    // Information:
    //   cap_en_s registers 1 cycle after the frame counter reaches the first
    //   capture period (we count from the pp warehouse, not the device). So a
    //   write fired at cap_en_dn happens n cycles after pp held the sample of
    //   period (15+i): content period = 15+i + (n - 2 - (tap chain steps - 1)).
    //   v3 always writes at n=5 with tap chain 3-c/2 -> content 15+i+c/2 for
    //   every c. The LEAN path writes from `pick` (1 chain step, content
    //   n-3-(1-1) = n-3 from pp+3) at depth 2+c/2 -> 15+i+c/2 + ... identical
    //   content, 1..3 cycles earlier.
    reg [1:0] dsel = 2'd3;    // fire depth offset: depth = 2 + dsel (2..5)

    reg cap_en_fire;
    always @* begin
        case (dsel)
            2'd0:    cap_en_fire = cap_en_d2;
            2'd1:    cap_en_fire = cap_en_d3;
            2'd2:    cap_en_fire = cap_en_d4;
            default: cap_en_fire = cap_en_d5;   // v3: always the 5th stage
        endcase
    end

    localparam [2:0]
        ST_PWRUP = 3'd0,
        ST_RSTEN = 3'd1,
        ST_RST_WAIT = 3'd2,
        ST_RST = 3'd3,
        ST_QPIEN = 3'd4,
        ST_RDY = 3'd5;

    reg [2:0] st = ST_PWRUP;
    reg [31:0] waitc = 0;

    reg pwrup_ok = 1'b0;
    reg mid_ok = 1'b0;
    
    always @(posedge clk) begin
        pwrup_ok <= (waitc == PWRUP_CYCLES);
        mid_ok   <= (waitc == MID_CYCLES);
    end

    reg [1:0] fop = SPI_BYTE;
    reg [6:0] fpcnt = 7'd0;
    integer flen_m1;          // last fpcnt of the frame (incl. drain)
    integer ce_m1 = 0;        // fpcnt at which CE# is released
    reg [2:0] sel_q = 3'd3;   // cap_sel latched at frame issue
    reg framer = 1'b0;
    reg fend = 1'b0;
    reg fword = 1'b0;
    reg fdw = 1'b0;

    reg [7:0] s_cmd = 8'h00;
    reg [23:0] raddr = 24'h0;
    reg [7:0] wd0 = 8'h00;
    reg [7:0] wd1 = 8'h00;
    reg [7:0] wd2 = 8'h00;
    reg [7:0] wd3 = 8'h00;

    reg old_rd = 1'b0;
    reg old_we = 1'b0;
    reg old_init = 1'b0;

    function automatic [3:0] addr_nib(input [23:0] v, input integer n);
        addr_nib = v[(23 - 4*n) -: 4];
    endfunction

    // nibble presented for period p+1 (one period ahead of the latch)
    function automatic [3:0] drive_val(input [1:0] op, input [6:0] p);
        begin
            case (op)
                SPI_BYTE: drive_val = {3'b000, s_cmd[7 - p[2:0]]};
                WR2: begin
                    case (p[3:0])
                        4'h0:    drive_val = 4'h0;
                        4'h1:    drive_val = 4'h2;
                        4'h2,4'h3,4'h4,4'h5,4'h6,4'h7:
                                 drive_val = addr_nib(raddr, p-2);
                        4'h8:    drive_val = wd0[7:4];
                        4'h9:    drive_val = wd0[3:0];
                        4'ha:    drive_val = wd1[7:4];
                        4'hb:    drive_val = wd1[3:0];
                        4'hc:    drive_val = wd2[7:4];
                        4'hd:    drive_val = wd2[3:0];
                        4'he:    drive_val = wd3[7:4];
                        default: drive_val = wd3[3:0];
                    endcase
                end
                RD2: begin
                    if (p >= 7'd8) drive_val = 4'h0;   // data/drain periods: bus is released
                    else case (p[3:0])
                        4'h0:    drive_val = 4'he;
                        4'h1:    drive_val = 4'hb;
                        4'h2,4'h3,4'h4,4'h5,4'h6,4'h7:
                                 drive_val = addr_nib(raddr, p-2);
                        default: drive_val = 4'h0;
                    endcase
                end
                default: drive_val = 4'h0;
            endcase
        end
    endfunction

    // First period whose returned data we capture.
    function automatic [6:0] cap_first(input [1:0] op);
        case (op)
            RD2: cap_first = 7'd15;
            default: cap_first = 7'd0;
        endcase
    endfunction

    // How many nibbles the frame returns.
    function automatic [6:0] cap_count(input [1:0] op);
        case (op)
            RD2:  cap_count = fdw ? 7'd8 : fword ? 7'd4 : 7'd2;
            default: cap_count = 7'd0;
        endcase
    endfunction

    function automatic bit is_rd(input [1:0] op);
        is_rd = (op == RD2);
    endfunction

    // release the bus one period before the first read nibble is returned
    function automatic bit pre_capture(input [1:0] op, input [6:0] p);
        begin
            pre_capture = 1'b0;
            case (op)
                RD2:  if (p == 7'd14) pre_capture = 1'b1;  // for cap_first==15
                default: ;
            endcase
        end
    endfunction

    // Extra CE#-low cycles so the device is still driving when a late sample is
    // taken. Last nibble sampled at E(18) + c*T/2 + phi, phi <= ~0.7 T; keep
    // CE# low until half a period after that: ext = ceil(c/2 - 0.8), >= 0.
    function automatic integer rd_ext(input [2:0] cv);
        case (cv)
            3'd0, 3'd1: rd_ext = 0;
            3'd2, 3'd3: rd_ext = 1;
            3'd4, 3'd5: rd_ext = 2;
            default:    rd_ext = 3;
        endcase
    endfunction

    reg cap_en_s  = 1'b0;
    reg cap_en_d1 = 1'b0;
    reg cap_en_d2 = 1'b0;
    reg cap_en_d3 = 1'b0;
    reg cap_en_d4 = 1'b0;
    reg cap_en_d5 = 1'b0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            cap_en_s  <= 1'b0;
            cap_en_d1 <= 1'b0;
            cap_en_d2 <= 1'b0;
            cap_en_d3 <= 1'b0;
            cap_en_d4 <= 1'b0;
            cap_en_d5 <= 1'b0;
        end else begin
            cap_en_s <= framer && is_rd(fop) &&
                (fpcnt >= cap_first(fop)) &&
                (fpcnt < cap_first(fop) + cap_count(fop));
            // five more stages: the multi-phase sample pipeline needs v3's 5
            // cycles after the original capture edge before its newest entry
            // is usable (the lean path fires earlier: see the drainer notes).
            cap_en_d1 <= cap_en_s;
            cap_en_d2 <= cap_en_d1;
            cap_en_d3 <= cap_en_d2;
            cap_en_d4 <= cap_en_d3;
            cap_en_d5 <= cap_en_d4;
        end
    end

    // ---------------------------------------- dynamic-phase pad sampling
    // clk_cap domain: one flop per edge (the pad path is untimed).
    reg [3:0] pp = 4'h0;                 // E(k) + phi
    reg [3:0] pn = 4'h0;                 // E(k) + phi + T/2
    always @(posedge clk_cap) pp <= sio_in;
    always @(negedge clk_cap) pn <= sio_in;

    // pn is re-timed on the falling edge of clk (>= 0.35 T available), then
    // both streams are in the clk posedge domain. After edge E(m):
    //   sp2 = P(m-2)   sn1 = N(m-2)      (same period k = m-2)
    reg [3:0] mn  = 4'h0;
    reg [3:0] sp1 = 4'h0, sp2 = 4'h0, sn1 = 4'h0;
    always @(negedge clk) mn <= pn;
    always @(posedge clk) begin
        sp1 <= pp;
        sp2 <= sp1;
        sn1 <= mn;
    end

    // Choose P or N (parity of c), then a 4-deep period history. After E(n):
    //   pick = X(n-3), pk0 = X(n-4), pk1 = X(n-5), pk2 = X(n-6)
    reg [3:0] pick = 4'h0, pk0 = 4'h0, pk1 = 4'h0, pk2 = 4'h0;
    always @(posedge clk) begin
        pick <= sel_q[0] ? sn1 : sp2;
        pk0  <= pick;
        pk1  <= pk0;
        pk2  <= pk1;
    end

    // Nibble i is written at W = 22+i; period k = 15+i+c/2 is then in
    // tap (3 - c/2): pick, pk0, pk1, pk2.
    // Lean (stage 2): always `pick` -- at fire depth 2+c/2 its content is the
    // same nibble the v3 chain delivered at depth 5 (see the drainer notes).
    reg [3:0] cap_tap;
    always @* begin
        if (LEAN != 0) begin
            cap_tap = pick;
        end else begin
            case (sel_q[2:1])
                2'd3:    cap_tap = pick;
                2'd2:    cap_tap = pk0;
                2'd1:    cap_tap = pk1;
                default: cap_tap = pk2;
            endcase
        end
    end

    // ------------------------------------------------------- TX / engine core
    always @(posedge clk or posedge reset) begin
        if (reset) begin
            ce_n <= 1'b1;
            sio_oe <= 4'h0;
            framer <= 1'b0;
            fend <= 1'b0;
            old_rd <= 1'b0;
            old_we <= 1'b0;
            old_init <= 1'b0;
            fword <= 1'b0;
            fdw <= 1'b0;
            fpcnt <= 7'd0;
            sio_out <= 4'h0;
        end else begin
            old_rd <= rd;
            old_we <= we;
            old_init <= init;

            if (framer) begin
                // ---- present the NEXT period's nibble (one period ahead) ----
                sio_out <= drive_val(fop, fpcnt + 7'd1);
                sio_oe  <= (pre_capture(fop, fpcnt + 7'd1) ||
                            (is_rd(fop) && (fpcnt + 7'd1) >= cap_first(fop)))
                           ? 4'h0 : 4'hf;
                // ---- advance ----
                if (fpcnt == ce_m1) begin          // CE# release
                    ce_n   <= 1'b1;
                    sio_oe <= 4'h0;
                end
                if (fpcnt == flen_m1) begin        // frame (incl. drain) done
                    framer <= 1'b0;
                    ce_n   <= 1'b1;
                    sio_oe <= 4'h0;
                    fend   <= 1'b1;
                end else begin
                    fpcnt <= fpcnt + 7'd1;
                end
            end

            // ---- frame completion: one period after framer drops ----
            // fend is the init FSM's "frame done" pulse and the read-result
            // assembly edge. The capture window closes well before frame end,
            // so rnib is already final and a single drain cycle is enough.
            if (fend) begin
                fend <= 1'b0;
                if (is_rd(fop)) begin
                    // device sends MSB nibble first: n0=b0hi n1=b0lo n2=b1hi n3=b1lo
                    if (fdw)        dout <= {rnib[0], rnib[1], rnib[2], rnib[3],
                                             rnib[4], rnib[5], rnib[6], rnib[7]};
                    else if (fword) dout <= {16'h0, rnib[2], rnib[3], rnib[0], rnib[1]};
                    else            dout <= {24'h0, rnib[0], rnib[1]};
                end
            end

            // ---- master state machine ----
            case (st)
                ST_PWRUP: begin
                    if (pwrup_ok) begin
                        waitc <= 0; st <= ST_RSTEN;
                        frame_go(SPI_BYTE, 8, 8'h66, 24'h0, 8'h0, 8'h0, 8'h0, 8'h0);
                    end else waitc <= waitc + 32'd1;
                end
                ST_RSTEN: if (fend) begin waitc <= 0; st <= ST_RST_WAIT; end
                ST_RST_WAIT: begin
                    if (mid_ok) begin
                        waitc <= 0; st <= ST_RST;
                        frame_go(SPI_BYTE, 8, 8'h99, 24'h0, 8'h0, 8'h0, 8'h0, 8'h0);
                    end else waitc <= waitc + 32'd1;
                end
                ST_RST: if (fend) begin waitc <= 0; st <= ST_QPIEN; end
                ST_QPIEN: begin
                    if (mid_ok) begin
                        waitc <= 0; st <= ST_RDY;
                        frame_go(SPI_BYTE, 8, 8'h35, 24'h0, 8'h0, 8'h0, 8'h0, 8'h0);
                    end else waitc <= waitc + 32'd1;
                end
                ST_RDY: begin
                    // ready must not rise until the result is assembled: fend
                    // is still set for the assembly period, so gating on
                    // framer/fend alone lets a host sample dout too early.
                    if (~framer && ~fend) begin
                        if (rd && ~old_rd) begin
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
                        end
                    end
                end
                default:;
            endcase

            if (old_init && ~init && ~framer && st == ST_RDY) begin
                st <= ST_PWRUP; waitc <= 0; ce_n <= 1'b1;
            end
        end
    end
    assign ready = st == ST_RDY && framer == 1'b0 && fend == 1'b0;
    
    task automatic frame_go(input [1:0] op, input integer len,
                            input [7:0] cmd, input [23:0] ba,
                            input [7:0] d0, input [7:0] d1,
                            input [7:0] d2, input [7:0] d3);
        integer drain;
        begin
            fop <= op;
            ce_m1   = len - 1 + (is_rd(op) ? rd_ext(cap_sel) : 0);
            if (is_rd(op)) begin
                if (LEAN != 0)
                    drain = 2 + cap_sel[2:1];          // stage 2: per-c drain
                else
                    drain = DRAIN;                     // v3: fixed 5
            end
            else drain = 0;
            flen_m1 = ce_m1 + (is_rd(op) ? drain : 0);
            sel_q   <= cap_sel;
            // fire depth = 2 + dsel; v3 keeps the fixed 5th stage, lean tracks c
            dsel    <= (LEAN != 0) ? cap_sel[2:1] : 2'd3;
            s_cmd = cmd;
            raddr = ba;
            wd0 = d0;
            wd1 = d1;
            wd2 = d2;
            wd3 = d3;
            framer  <= 1'b1;
            ce_n    <= 1'b0;
            fpcnt   <= 7'd0;
            sio_out <= drive_val(op, 7'd0);
            sio_oe  <= (is_rd(op) && 7'd0 >= cap_first(op)) ? 4'h0 : 4'hf;
        end
    endtask

    reg [3:0]  rnib [0:7];
    reg [2:0]  nidx = 3'd0;

    always @(posedge clk or posedge reset) begin
        if (reset) begin
            rnib[0] <= 4'h0;
            rnib[1] <= 4'h0;
            rnib[2] <= 4'h0;
            rnib[3] <= 4'h0;
            rnib[4] <= 4'h0;
            rnib[5] <= 4'h0;
            rnib[6] <= 4'h0;
            rnib[7] <= 4'h0;
            nidx    <= 3'd0;
        end else begin
            if (cap_en_fire) begin
                rnib[nidx] <= cap_tap;
                nidx <= nidx + 3'd1;
            end else begin
                nidx <= 3'd0;   // idle -> ready for the next read frame
            end
        end
    end

endmodule