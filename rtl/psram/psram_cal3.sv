`timescale 1ns/1ps

// psram_cal3 -- shared calibration of both PSRAM chips with ONE capture clock.
//
// The capture clock clk_cap (PLL outclk_1) starts at a fixed static phase
// (window start, ~0.15 T) and is stepped later, S steps = half a clock period
// (S = 4 * Fvco / Fout, see README). For every phase step s = 0..S-1 and every
// coarse position c = 0..7 (half periods) the pattern is read back from BOTH
// chips. A position is addressed linearly in time:
//
//        n = c * S + s        (n = 0 .. 8*S-1, one step = T / (2*S))
//
// and the result {chip2 ok, chip1 ok} is stored in a small RAM. The sweep then
// scans the RAM for the longest run where BOTH chips read clean, takes its
// centre n*, converts it back to (c*, s*), steps the PLL to s* and holds c*.
// If the two eyes do not overlap, `fail` is set and the per-chip run lengths
// (len1, len2) show why.
//
// While `busy` is 1 this block owns both psram host ports (mux them in the top
// level) and the test controllers should be held in reset.

module psram_cal3 #(
    parameter [22:0]  BASE_ADDR = 23'h000400,  // byte address, word aligned
    parameter integer N_WORDS   = 16,          // 1..16
    parameter integer PASSES    = 4,           // read passes per position
    parameter integer S         = 20,          // phase steps per HALF clock period, 2..64
    parameter [2:0]   DEF_C     = 3'd3,        // fallback coarse position if no overlap
    parameter integer SETTLE    = 64,          // ready must be stable this long
    parameter integer OP_TMO    = 4096,        // clk cycles before a host op is abandoned
    parameter integer STEP_TMO  = 200000       // clk cycles before a PLL step is abandoned
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        recal,                  // rising edge re-runs the sweep when done

    // chip 1 / chip 2 host ports (mux in the top level; addr/wtbt/din are shared)
    input  wire        ready1,
    input  wire [15:0] dout1,
    output reg         rd1,
    output reg         we1,
    input  wire        ready2,
    input  wire [15:0] dout2,
    output reg         rd2,
    output reg         we2,
    output reg  [22:0] addr,
    output reg  [1:0]  wtbt,
    output reg  [15:0] din,

    // coarse capture position for both psram instances
    output wire [2:0]  cap_c,

    // PLL phase stepper (psram_dps)
    output reg         dps_req_tgl,
    output reg         dps_req_up,
    input  wire        dps_done_tgl,
    input  wire        dps_err,
    input  wire        clk_det,                // clk sampled by clk_cap (async, self-test)

    // status
    output reg         busy,
    output reg         done,
    output reg         fail,
    output reg  [9:0]  eye_len,                // overlap run (both chips), in steps
    output reg  [9:0]  len1,                   // longest run chip 1 alone
    output reg  [9:0]  len2,                   // longest run chip 2 alone
    output reg  [2:0]  c_star,
    output reg  [6:0]  s_star,
    output reg  [9:0]  margin,                 // steps from the chosen point to the nearer eye edge
    output reg  [7:0]  det_tog,                // toggles of clk_det seen during the sweep (expect >=1)
    output wire [63:0] status
);

    localparam integer NTOT = 8 * S;

    // --------------------------------------------------------- pattern ROM
    function [15:0] pat_of(input [4:0] i);
        case (i)
            5'd0:  pat_of = 16'h5345;
            5'd1:  pat_of = 16'hE51B;
            5'd2:  pat_of = 16'h95F5;
            5'd3:  pat_of = 16'hBFD4;
            5'd4:  pat_of = 16'h712B;
            5'd5:  pat_of = 16'h13CE;
            5'd6:  pat_of = 16'hB791;
            5'd7:  pat_of = 16'h743F;
            5'd8:  pat_of = 16'h81FD;
            5'd9:  pat_of = 16'h45C7;
            5'd10: pat_of = 16'h45C2;
            5'd11: pat_of = 16'hC804;
            5'd12: pat_of = 16'h1658;
            5'd13: pat_of = 16'h8260;
            5'd14: pat_of = 16'hBA76;
            5'd15: pat_of = 16'h962F;
            default: pat_of = 16'h0000;
        endcase
    endfunction

    // ---------------------------------------------------------- host op engine
    reg        op_req;
    reg        op_rd;
    reg        op_chip;
    reg [22:0] op_addr;
    reg [15:0] op_din;
    reg        op_fin;
    reg        op_to;
    reg [15:0] op_dout;

    localparam [2:0] O_IDLE = 3'd0, O_RDY = 3'd1, O_PULSE = 3'd2,
                     O_LOW  = 3'd3, O_HIGH = 3'd4;
    reg [2:0]  ost;
    reg [15:0] otmo;
    wire       ready_sel = op_chip ? ready2 : ready1;

    always @(posedge clk) begin
        if (!rst_n) begin
            ost <= O_IDLE; otmo <= 16'd0;
            rd1 <= 1'b0; we1 <= 1'b0; rd2 <= 1'b0; we2 <= 1'b0;
            addr <= 23'd0; wtbt <= 2'b11; din <= 16'd0;
            op_fin <= 1'b0; op_to <= 1'b0; op_dout <= 16'd0;
        end else begin
            op_fin <= 1'b0;
            case (ost)
                O_IDLE: if (op_req) begin
                    op_to <= 1'b0;
                    otmo  <= 16'd0;
                    ost   <= O_RDY;
                end
                O_RDY: begin
                    if (ready_sel) begin
                        rd1  <= op_rd  & ~op_chip;
                        we1  <= ~op_rd & ~op_chip;
                        rd2  <= op_rd  &  op_chip;
                        we2  <= ~op_rd &  op_chip;
                        addr <= op_addr;
                        wtbt <= 2'b11;
                        din  <= op_din;
                        otmo <= 16'd0;
                        ost  <= O_PULSE;
                    end else if (otmo == OP_TMO) begin
                        op_to <= 1'b1; op_fin <= 1'b1; ost <= O_IDLE;
                    end else otmo <= otmo + 16'd1;
                end
                O_PULSE: begin
                    rd1 <= 1'b0; we1 <= 1'b0; rd2 <= 1'b0; we2 <= 1'b0;
                    otmo <= 16'd0;
                    ost  <= O_LOW;
                end
                O_LOW: begin
                    if (!ready_sel) begin
                        otmo <= 16'd0;
                        ost  <= O_HIGH;
                    end else if (otmo == 16'd16) begin
                        op_to <= 1'b1; op_fin <= 1'b1; ost <= O_IDLE;
                    end else otmo <= otmo + 16'd1;
                end
                O_HIGH: begin
                    if (ready_sel) begin
                        op_dout <= op_chip ? dout2 : dout1;
                        op_fin  <= 1'b1;
                        ost     <= O_IDLE;
                    end else if (otmo == OP_TMO) begin
                        op_to <= 1'b1; op_fin <= 1'b1; ost <= O_IDLE;
                    end else otmo <= otmo + 16'd1;
                end
                default: ost <= O_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------- PLL step engine
    // st_go (1-cycle pulse) + st_dir (1 = later phase) -> one step; st_fin pulses when done.
    reg        st_go;
    reg        st_dir;
    reg        st_fin;
    reg        st_to;                   // sticky: a step timed out
    reg [6:0]  scur;                    // current step index relative to the window start

    reg [2:0]  dd;
    reg        dd_seen;
    reg [1:0]  pst;
    reg [23:0] ptmo;
    localparam [1:0] P_IDLE = 2'd0, P_SET = 2'd1, P_WAIT = 2'd2;

    always @(posedge clk) begin
        if (!rst_n) begin
            dd <= 3'b000; dd_seen <= 1'b0; pst <= P_IDLE; ptmo <= 24'd0;
            dps_req_tgl <= 1'b0; dps_req_up <= 1'b1;
            st_fin <= 1'b0; st_to <= 1'b0; scur <= 7'd0;
        end else begin
            dd     <= {dd[1:0], dps_done_tgl};
            st_fin <= 1'b0;
            case (pst)
                P_IDLE: if (st_go) begin
                    dps_req_up <= st_dir;          // stable for >= 1 cycle before the toggle
                    ptmo <= 24'd0;
                    pst  <= P_SET;
                end
                P_SET: begin
                    dps_req_tgl <= ~dps_req_tgl;
                    pst <= P_WAIT;
                end
                P_WAIT: begin
                    if (dd[1] != dd_seen) begin
                        dd_seen <= dd[1];
                        scur    <= dps_req_up ? scur + 7'd1 : scur - 7'd1;
                        st_fin  <= 1'b1;
                        pst     <= P_IDLE;
                    end else if (ptmo == STEP_TMO) begin
                        st_to  <= 1'b1;
                        st_fin <= 1'b1;
                        pst    <= P_IDLE;
                    end else ptmo <= ptmo + 24'd1;
                end
                default: pst <= P_IDLE;
            endcase
        end
    end

    // clk_det self-test: clk sampled by clk_cap flips once per half period of sweep
    reg [1:0] det_q = 2'b00;
    reg       det_prev;
    always @(posedge clk) det_q <= {det_q[0], clk_det};

    // ---------------------------------------------------------- result RAM
    reg [1:0] res [0:511];
    reg [1:0] res_q;
    reg [8:0] raddr;
    reg [8:0] nadr;
    reg       p1, p2;

    // ------------------------------------------------------------ main FSM
    localparam [4:0]
        M_WAIT = 5'd0,  M_HOME = 5'd1,  M_HOMEW = 5'd2, M_WR   = 5'd3,  M_WRW  = 5'd4,
        M_CSET = 5'd5,  M_RD   = 5'd6,  M_RDW   = 5'd7, M_NXCH = 5'd8,  M_STORE= 5'd9,
        M_CNXT = 5'd10, M_SNXT = 5'd11, M_STEPW = 5'd12,
        M_SC0  = 5'd13, M_SC1  = 5'd14, M_SC2   = 5'd15,
        M_PICK = 5'd16, M_DIV  = 5'd17, M_GOTO  = 5'd18, M_GOTOW= 5'd19,
        M_FIN  = 5'd20, M_DONE = 5'd21;

    reg [4:0]  mst;
    reg        chip;
    reg [4:0]  widx;
    reg [2:0]  pass_no;
    reg [6:0]  s;
    reg [2:0]  c;
    reg [2:0]  c_sw;
    reg [2:0]  c_best;
    reg [15:0] settle;
    reg        recal_q;

    // scan trackers
    reg [8:0]  scan_n;
    reg [9:0]  cur_a, cur_1, cur_2;
    reg [8:0]  cur_a_st, best_a_st;
    reg [8:0]  nn;

    wire        q1 = res_q[0];
    wire        q2 = res_q[1];
    wire        qa = q1 & q2;
    wire [9:0]  cur_a_next = cur_a + 10'd1;

    always @(posedge clk) begin
        if (!rst_n) begin
            mst <= M_WAIT; busy <= 1'b1; done <= 1'b0; fail <= 1'b0;
            chip <= 1'b0; widx <= 5'd0; pass_no <= 3'd0;
            s <= 7'd0; c <= 3'd0; c_sw <= DEF_C; c_best <= DEF_C;
            settle <= 16'd0; recal_q <= 1'b0;
            op_req <= 1'b0; op_rd <= 1'b0; op_chip <= 1'b0; op_addr <= 23'd0; op_din <= 16'd0;
            st_go <= 1'b0; st_dir <= 1'b1;
            nadr <= 9'd0; raddr <= 9'd0; p1 <= 1'b0; p2 <= 1'b0;
            scan_n <= 9'd0; cur_a <= 10'd0; cur_1 <= 10'd0; cur_2 <= 10'd0;
            cur_a_st <= 9'd0; best_a_st <= 9'd0; nn <= 9'd0;
            eye_len <= 10'd0; len1 <= 10'd0; len2 <= 10'd0;
            c_star <= DEF_C; s_star <= 7'd0; margin <= 10'd0;
            det_tog <= 8'd0; det_prev <= 1'b0;
        end else begin
            recal_q <= recal;
            op_req  <= 1'b0;                       // 1-cycle pulses
            st_go   <= 1'b0;

            case (mst)
                // wait for both controllers to finish power-up / QPI entry
                M_WAIT: begin
                    if (ready1 && ready2) begin
                        if (settle == SETTLE) begin
                            settle <= 16'd0;
                            chip   <= 1'b0;
                            widx   <= 5'd0;
                            mst    <= M_WR;
                        end else settle <= settle + 16'd1;
                    end else settle <= 16'd0;
                end

                // return the PLL to the window start (after a recal)
                M_HOME: begin
                    if (scur == 7'd0) mst <= M_WAIT;
                    else begin
                        st_go  <= 1'b1;
                        st_dir <= 1'b0;
                        mst    <= M_HOMEW;
                    end
                end
                M_HOMEW: if (st_fin) mst <= M_HOME;

                // write the pattern to chip 1, then chip 2 (independent of the capture clock)
                M_WR: begin
                    op_req  <= 1'b1;
                    op_rd   <= 1'b0;
                    op_chip <= chip;
                    op_addr <= BASE_ADDR + {widx, 1'b0};
                    op_din  <= pat_of(widx);
                    mst     <= M_WRW;
                end
                M_WRW: if (op_fin) begin
                    if (widx == N_WORDS - 1) begin
                        widx <= 5'd0;
                        if (!chip) begin
                            chip <= 1'b1;
                            mst  <= M_WR;
                        end else begin
                            chip    <= 1'b0;
                            s       <= 7'd0;
                            c       <= 3'd0;
                            nadr    <= 9'd0;
                            det_tog <= 8'd0;
                            mst     <= M_CSET;
                        end
                    end else begin
                        widx <= widx + 5'd1;
                        mst  <= M_WR;
                    end
                end

                // ---- sweep: position (s, c) ----
                M_CSET: begin
                    c_sw    <= c;
                    p1      <= 1'b1;
                    p2      <= 1'b1;
                    chip    <= 1'b0;
                    widx    <= 5'd0;
                    pass_no <= 3'd0;
                    // clk_det self-test: count changes between phase steps
                    if (c == 3'd0) begin
                        if (s != 7'd0 && det_q[1] != det_prev && det_tog != 8'hFF)
                            det_tog <= det_tog + 8'd1;
                        det_prev <= det_q[1];
                    end
                    mst <= M_RD;
                end
                M_RD: begin
                    op_req  <= 1'b1;
                    op_rd   <= 1'b1;
                    op_chip <= chip;
                    op_addr <= BASE_ADDR + {widx, 1'b0};
                    mst     <= M_RDW;
                end
                M_RDW: if (op_fin) begin
                    if (op_to || (op_dout != pat_of(widx))) begin
                        if (!chip) p1 <= 1'b0; else p2 <= 1'b0;
                        mst <= M_NXCH;                 // early exit: this chip fails here
                    end else if (widx == N_WORDS - 1) begin
                        widx <= 5'd0;
                        if (pass_no == PASSES - 1) mst <= M_NXCH;
                        else begin
                            pass_no <= pass_no + 3'd1;
                            mst     <= M_RD;
                        end
                    end else begin
                        widx <= widx + 5'd1;
                        mst  <= M_RD;
                    end
                end
                M_NXCH: begin
                    if (!chip) begin
                        chip    <= 1'b1;
                        widx    <= 5'd0;
                        pass_no <= 3'd0;
                        mst     <= M_RD;
                    end else mst <= M_STORE;
                end
                M_STORE: begin                          // RAM write below
                    mst <= M_CNXT;
                end
                M_CNXT: begin
                    if (c == 3'd7) mst <= M_SNXT;
                    else begin
                        c    <= c + 3'd1;
                        nadr <= nadr + S;
                        mst  <= M_CSET;
                    end
                end
                M_SNXT: begin
                    if (s == S - 1) begin
                        scan_n     <= 9'd0;
                        cur_a      <= 10'd0; cur_1 <= 10'd0; cur_2 <= 10'd0;
                        eye_len    <= 10'd0; len1  <= 10'd0; len2  <= 10'd0;
                        best_a_st  <= 9'd0;
                        mst        <= M_SC0;
                    end else begin
                        s      <= s + 7'd1;
                        nadr   <= {2'b00, s} + 9'd1;
                        c      <= 3'd0;
                        st_go  <= 1'b1;
                        st_dir <= 1'b1;
                        mst    <= M_STEPW;
                    end
                end
                M_STEPW: if (st_fin) mst <= M_CSET;

                // ---- scan the RAM for the longest runs ----
                M_SC0: begin raddr <= scan_n; mst <= M_SC1; end
                M_SC1: mst <= M_SC2;
                M_SC2: begin
                    // both chips
                    if (qa) begin
                        if (cur_a == 10'd0) cur_a_st <= scan_n;
                        cur_a <= cur_a_next;
                        if (cur_a_next > eye_len) begin
                            eye_len   <= cur_a_next;
                            best_a_st <= (cur_a == 10'd0) ? scan_n : cur_a_st;
                        end
                    end else cur_a <= 10'd0;
                    // chip 1 alone
                    if (q1) begin
                        cur_1 <= cur_1 + 10'd1;
                        if (cur_1 + 10'd1 > len1) len1 <= cur_1 + 10'd1;
                    end else cur_1 <= 10'd0;
                    // chip 2 alone
                    if (q2) begin
                        cur_2 <= cur_2 + 10'd1;
                        if (cur_2 + 10'd1 > len2) len2 <= cur_2 + 10'd1;
                    end else cur_2 <= 10'd0;

                    if (scan_n == NTOT - 1) mst <= M_PICK;
                    else begin
                        scan_n <= scan_n + 9'd1;
                        mst    <= M_SC0;
                    end
                end

                // ---- centre of the overlap, convert back to (c, s) ----
                M_PICK: begin
                    if (eye_len != 10'd0) begin
                        nn     <= best_a_st + ((eye_len - 10'd1) >> 1);
                        margin <= (eye_len - 10'd1) >> 1;
                        fail   <= 1'b0;
                    end else begin
                        nn     <= DEF_C * S + S / 2;   // fallback
                        margin <= 10'd0;
                        fail   <= 1'b1;
                    end
                    c_star <= 3'd0;
                    mst    <= M_DIV;
                end
                M_DIV: begin
                    if (nn >= S) begin
                        nn     <= nn - S;
                        c_star <= c_star + 3'd1;
                    end else begin
                        s_star <= nn[6:0];
                        mst    <= M_GOTO;
                    end
                end
                M_GOTO: begin
                    if (scur == s_star) mst <= M_FIN;
                    else begin
                        st_go  <= 1'b1;
                        st_dir <= (scur < s_star);
                        mst    <= M_GOTOW;
                    end
                end
                M_GOTOW: if (st_fin) mst <= M_GOTO;

                M_FIN: begin
                    c_best <= c_star;
                    busy   <= 1'b0;
                    done   <= 1'b1;
                    mst    <= M_DONE;
                end

                M_DONE: begin
                    if (recal && !recal_q) begin
                        busy   <= 1'b1;
                        done   <= 1'b0;
                        fail   <= 1'b0;
                        settle <= 16'd0;
                        mst    <= M_HOME;
                    end
                end

                default: mst <= M_WAIT;
            endcase
        end
    end

    // result RAM: written in M_STORE, read serially by the scan (1-cycle latency)
    always @(posedge clk) begin
        if (mst == M_STORE) res[nadr] <= {p2, p1};
        res_q <= res[raddr];
    end

    assign cap_c = busy ? c_sw : c_best;

    // status word:
    //   [9:0] eye_len  [19:10] len1  [29:20] len2  [32:30] c_star  [39:33] s_star
    //   [49:40] margin [50] done [51] busy [52] fail [53] dps_err [54] step timeout
    //   [62:55] det_tog (8 bit)  [63] unused
    assign status = {1'b0, det_tog, st_to, dps_err, fail, busy, done,
                     margin, s_star, c_star, len2, len1, eye_len};

endmodule
