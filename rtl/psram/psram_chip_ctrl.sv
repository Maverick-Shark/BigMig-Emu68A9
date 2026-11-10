// psram_chip_ctrl -- BigMig chip RAM on the Chameleon96 dual APS6404L module.
//
// Drop-in replacement for rtl/sdram_ctrl.v: the chip port, the CPU port (with
// cpu_cache_new and the one-entry write buffer) and the status outputs keep
// the names, widths and handshakes of sdram_ctrl, so BigMig.sv only swaps the
// instance and connects the PSRAM pads/clocks.
//
//   sysclk side (clk_114)           |  clk_ram side (PSRAM PLL, 128 MHz)
//   --------------------------------+-----------------------------------
//   7 MHz half-slot counter (c_7m)  |
//   chip port sample at state 0     |  request queue  -> psram_dual
//   write buffer, cpu_cache_new     |  (one op at a time, in order)
//   response handler (chipRD,       |  response queue <- psram_dual
//   chip48, cache fill acks)        |
//
// Memory layout (psram_dual): one 16-bit word per byte address in both chips,
// chip A = D15..D8, chip B = D7..D0, so the 16 MB chip bus space (chipAddr
// [23:1]) maps 1:1 onto the 2 x 8 MB devices.
//
// Ordering: every request goes through one in-order queue, so a later read
// (chipset or cache fill) always sees an earlier write. The cache is snooped
// at the chip write's slot, exactly like sdram_ctrl; a chip write that lands
// in the line of a cache fill still in flight is merged into the fill data
// before the line is handed to the cache.
//
// TIMING (phase 1 of the port): a PSRAM read takes ~22-34 clk_ram cycles plus
// the two clock crossings, longer than the 140 ns 7 MHz slot in which the
// chipset expects the data. Chip reads therefore return late here; the data
// is correct but arrives after the chipset has latched the bus. The cure is
// on the chipset side (phase 2: Agnus presents the DMA address one slot
// early). CPU-port accesses (Via-B, through the cache) are not affected: they
// simply wait. Chip writes are posted and complete in the background.
//
// Copyright 2026 -- GPL-3.0-or-later, same terms as BigMig. The cache and the
// write buffer logic come from sdram_ctrl.v (T. Gubener, A. Melnikov).

module psram_chip_ctrl #(
    parameter integer QAW          = 2,         // queue depth = 2**QAW
    parameter         SYNC_CLK     = 0,         // 1: clk_ram is sysclk (no crossing)
    parameter [1:0]   CHIP_RD_SIZE = 2'd2,      // chip reads: 0 = 16, 1 = 32, 2 = 64 bit
    // psram_dual / calibration (see psram_dual.sv, psram_cal3.sv)
    parameter integer S            = 20,
    parameter [22:0]  CAL_BASE     = 23'h7F0000,
    parameter [4:0]   DPS_CNTL     = 5'd2,
    parameter         DPS_DIRUP    = 1'b1,
    parameter integer PWRUP_CYCLES = 30000,
    parameter integer RST_CYCLES   = 4000,
    parameter integer MID_CYCLES   = 100,
    parameter integer CAL_WORDS    = 16,
    parameter integer CAL_PASSES   = 4,
    parameter         SCLK_INV     = 0          // see psram_dual.sv
) (
    // ---- system (sysclk = clk_114 domain), as sdram_ctrl
    input             sysclk,
    input             c_7m,
    input             reset_n,
    input             cache_rst,
    input             cache_inhibit,
    input       [3:0] cpu_cache_ctrl,
    input             sys_locked,       // main PLL lock: the queues restart when it drops

    // ---- PSRAM clocks and PLL dynamic phase shift
    input             clk_ram,          // controller clock, also both SCLK pads
    input             clk_cap,          // read capture clock (DPS-stepped copy of clk_ram)
    input             scanclk,          // DPS stepping clock (50 MHz reference)
    input             ram_locked,       // PSRAM PLL lock
    input             pll_phase_done,
    output            pll_phase_en,
    output            pll_updn,
    output      [4:0] pll_cntsel,

    // ---- pads: chip A (high byte lane), chip B (low byte lane)
    output            PSA_SCLK,
    output            PSA_CE_N,
    output      [3:0] PSA_SIO_OUT,
    output      [3:0] PSA_SIO_OE,
    input       [3:0] PSA_SIO_IN,
    output            PSB_SCLK,
    output            PSB_CE_N,
    output      [3:0] PSB_SIO_OUT,
    output      [3:0] PSB_SIO_OE,
    input       [3:0] PSB_SIO_IN,

    // ---- status
    output            ready,            // sysclk: calibrated and queues running
    output            cal_done_s,       // sysclk copies of the calibration result
    output            cal_fail_s,
    output      [2:0] cal_c_s,          // coarse capture position c* (latency column)
    output     [63:0] cal_status,       // clk_ram domain, for SignalTap
    output reg        ovr = 1'b0,       // sticky: a chip access found the queue full
    output reg  [7:0] dbg_rd_lat = 8'd0,// sysclk cycles, chip read slot -> chipRD update

    // ---- chip port, as sdram_ctrl
    input      [24:1] chipAddr,
    input             chipL,
    input             chipU,
    input             chipRW,
    input             chipDMA,
    input      [15:0] chipWR,
    output reg [15:0] chipRD = 16'd0,
    output     [47:0] chip48,

    // ---- cpu port, as sdram_ctrl
    input      [24:1] cpuAddr,
    input             cpuCS,
    input       [1:0] cpustate,
    input             cpuL,
    input             cpuU,
    input      [15:0] cpuWR,
    output     [15:0] cpuRD,
    output            ramready,
    output            write_busy
);
    localparam integer N = 1 << QAW;

    // request kinds (info queue)
    localparam [1:0] K_CHIP_RD = 2'd0, K_CHIP_WR = 2'd1, K_CPU_RD = 2'd2, K_CPU_WR = 2'd3;

    // =====================================================================
    // resets
    // =====================================================================
    // Queue reset: either PLL out of lock. Asserted asynchronously in both
    // domains at once (so the two queue pointers restart together), released
    // through a two-flop synchroniser in each domain.
    wire q_rst_a = ~(sys_locked & ram_locked);

    reg [1:0] qr_s = 2'b11;
    always @(posedge sysclk or posedge q_rst_a)
        if (q_rst_a) qr_s <= 2'b11; else qr_s <= {qr_s[0], 1'b0};
    wire q_rst_s = qr_s[1];

    reg [1:0] qr_r = 2'b11;
    always @(posedge clk_ram or posedge q_rst_a)
        if (q_rst_a) qr_r <= 2'b11; else qr_r <= {qr_r[0], 1'b0};
    wire q_rst_r = qr_r[1];

    // PSRAM power-up / QPI entry / calibration: PSRAM PLL lock only. A main PLL
    // relock (PAL/NTSC switch) does not touch the devices or the calibration.
    reg [2:0] ini_r = 3'b111;
    always @(posedge clk_ram or negedge ram_locked)
        if (!ram_locked) ini_r <= 3'b111; else ini_r <= {ini_r[1:0], 1'b0};
    wire ps_init = ini_r[2];

    // =====================================================================
    // clk_ram side: psram_dual and the in-order engine
    // =====================================================================
    wire        ps_ready, ps_done;
    wire [63:0] ps_rdata;
    wire        cal_done, cal_fail, cal_busy;

    // request queue read side
    wire        rq_empty;
    wire [43:0] rq_data;             // {we, size[1:0], be[1:0], waddr[22:0], wdata[15:0]}
    wire        rq_we    = rq_data[43];
    wire [1:0]  rq_size  = rq_data[42:41];
    wire [1:0]  rq_be    = rq_data[40:39];
    wire [22:0] rq_addr  = rq_data[38:16];
    wire [15:0] rq_wdata = rq_data[15:0];

    // response queue write side
    wire        sq_full;

    reg  eng_busy    = 1'b0;
    reg  eng_discard = 1'b0;
    wire eng_free    = ~eng_busy | ps_done;
    wire eng_issue   = ~q_rst_r & ~rq_empty & ~sq_full & ps_ready & eng_free;
    wire eng_push    = eng_busy & ps_done & ~eng_discard & ~q_rst_r;

    always @(posedge clk_ram) begin
        if (eng_issue) begin
            eng_busy    <= 1'b1;
            eng_discard <= 1'b0;
        end else if (ps_done) begin
            eng_busy    <= 1'b0;
            eng_discard <= 1'b0;
        end else if (eng_busy && q_rst_r) begin
            eng_discard <= 1'b1;         // let the frame finish, drop its answer
        end
    end

    psram_dual #(
        .S(S), .CAL_BASE(CAL_BASE), .DPS_CNTL(DPS_CNTL), .DPS_DIRUP(DPS_DIRUP),
        .PWRUP_CYCLES(PWRUP_CYCLES), .RST_CYCLES(RST_CYCLES), .MID_CYCLES(MID_CYCLES),
        .CAL_WORDS(CAL_WORDS), .CAL_PASSES(CAL_PASSES), .SCLK_INV(SCLK_INV)
    ) u_dual (
        .PSA_SCLK(PSA_SCLK), .PSA_CE_N(PSA_CE_N), .PSA_SIO_OUT(PSA_SIO_OUT),
        .PSA_SIO_OE(PSA_SIO_OE), .PSA_SIO_IN(PSA_SIO_IN),
        .PSB_SCLK(PSB_SCLK), .PSB_CE_N(PSB_CE_N), .PSB_SIO_OUT(PSB_SIO_OUT),
        .PSB_SIO_OE(PSB_SIO_OE), .PSB_SIO_IN(PSB_SIO_IN),
        .init(ps_init), .clk(clk_ram), .clk_cap(clk_cap), .scanclk(scanclk),
        .pll_phase_done(pll_phase_done), .pll_phase_en(pll_phase_en),
        .pll_updn(pll_updn), .pll_cntsel(pll_cntsel),
        .cal_done(cal_done), .cal_fail(cal_fail), .cal_busy(cal_busy), .cal_status(cal_status),
        .ready(ps_ready), .req(eng_issue), .we(rq_we), .waddr(rq_addr), .size(rq_size),
        .be(rq_be), .wdata({rq_wdata, 48'h0}), .rdata(ps_rdata), .done(ps_done)
    );

    // =====================================================================
    // the two queues (push and pop strobes are combinational: no extra
    // register stage in front of the clock crossing)
    // =====================================================================
    reg         push_now;
    reg  [43:0] push_data;           // {we, size[1:0], be[1:0], waddr[22:0], wdata[15:0]}
    reg   [4:0] push_info;           // {probe, kind[1:0], word-in-block[1:0]}
    reg         pop_now;
    wire        fq_full;

    psram_afifo #(.W(44), .AW(QAW), .SYNC(SYNC_CLK)) u_req_q (
        .wclk(sysclk),  .wrst(q_rst_s), .wr(push_now), .wdata(push_data), .wfull(fq_full),
        .rclk(clk_ram), .rrst(q_rst_r), .rd(eng_issue), .rdata(rq_data), .rempty(rq_empty)
    );

    wire        sq_empty;
    wire [63:0] sq_data;

    psram_afifo #(.W(64), .AW(QAW), .SYNC(SYNC_CLK)) u_rsp_q (
        .wclk(clk_ram), .wrst(q_rst_r), .wr(eng_push), .wdata(ps_rdata), .wfull(sq_full),
        .rclk(sysclk),  .rrst(q_rst_s), .rd(pop_now), .rdata(sq_data), .rempty(sq_empty)
    );

    // =====================================================================
    // sysclk side
    // =====================================================================

    // ---- calibration status into sysclk (quasi-static after calibration)
    reg [1:0] cd_s = 2'b00, cf_s = 2'b00;
    reg [2:0] cc_s1 = 3'd0, cc_s2 = 3'd0;
    always @(posedge sysclk) begin
        cd_s  <= {cd_s[0], cal_done & ~cal_busy};
        cf_s  <= {cf_s[0], cal_fail};
        cc_s1 <= cal_status[32:30];
        cc_s2 <= cc_s1;
    end
    assign cal_done_s = cd_s[1];
    assign cal_fail_s = cf_s[1];
    assign cal_c_s    = cc_s2;
    assign ready      = cd_s[1] & ~q_rst_s;

    // ---- 7 MHz half-slot counter, identical to sdram_ctrl (state 0 = the
    //      cycle after c_7m rises; the chip port is sampled at its end)
    reg [3:0] st     = 4'd0;
    reg       st_is0 = 1'b0;
    reg       st_is2 = 1'b0;
    reg       old_7m = 1'b0;
    always @(posedge sysclk) begin
        st     <= st + 4'd1;
        st_is0 <= (st == 4'd15);
        st_is2 <= (st == 4'd1);
        old_7m <= c_7m;
        if (~old_7m & c_7m) begin
            st     <= 4'd0;
            st_is0 <= 1'b1;
            st_is2 <= 1'b0;
        end
    end

    // ---- CPU port: cache and write buffer (sdram_ctrl logic)
    wire ramsel = cpuCS & (~&cpustate | ~cpuU | ~cpuL);

    wire        cache_rd_ack;
    wire        cache_wr_ack;
    wire        cache_req;
    reg         fill_ack = 1'b0;
    reg  [15:0] fill_dat = 16'd0;
    reg         chipWE   = 1'b0;

    cpu_cache_new cpu_cache
    (
        .clk              (sysclk),
        .rst              (!ready || !reset_n || !cache_rst),
        .cpu_cache_ctrl   (cpu_cache_ctrl),
        .cache_inhibit    (cache_inhibit),
        .cpu_cs           (ramsel),
        .cpu_adr          ({4'b0000, cpuAddr}),
        .cpu_bs           ({!cpuU, !cpuL}),
        .cpu_we           (cpustate == 2'd3),
        .cpu_ir           (cpustate == 2'd0),
        .cpu_dr           (cpustate == 2'd2),
        .cpu_dat_w        (cpuWR),
        .cpu_dat_r        (cpuRD),
        .cpu_ack          (cache_rd_ack),
        .wb_en            (cache_wr_ack),
        .sdr_dat_r        (fill_dat),
        .sdr_read_req     (cache_req),
        .sdr_read_ack     (fill_ack),
        .snoop_act        (chipWE),
        .snoop_adr        ({4'b0000, chipAddr}),
        .snoop_dat_w      (chipWR),
        .snoop_bs         ({!chipU, !chipL})
    );

    // write buffer: lets the CPU continue while its write waits for a slot
    reg        write_ena = 1'b0;
    reg        write_req = 1'b0;
    reg        write_ack = 1'b0;
    reg  [1:0] write_dqm = 2'b11;
    reg [24:1] writeAddr = 24'd0;
    reg [15:0] writeDat  = 16'd0;
    reg  [1:0] write_state = 2'd0;

    always @(posedge sysclk) begin
        if (~reset_n || q_rst_s) begin
            write_req   <= 1'b0;
            write_ena   <= 1'b0;
            write_state <= 2'd0;
        end else begin
            case (write_state)
                default:
                    if (~write_ena && ramsel && cpustate == 2'd3) begin
                        writeAddr <= cpuAddr;
                        writeDat  <= cpuWR;
                        write_dqm <= {cpuU, cpuL};
                        write_req <= 1'b1;
                        if (cache_wr_ack) begin
                            write_ena   <= 1'b1;
                            write_state <= 2'd1;
                        end
                    end
                2'd1: if (write_ack) begin
                        write_req   <= 1'b0;
                        write_state <= 2'd2;
                    end
                2'd2: if (!write_ack) begin
                        write_state <= 2'd0;
                    end
            endcase
            if (~ramsel) write_ena <= 1'b0;
        end
    end

    assign ramready   = cache_rd_ack || write_ena;
    assign write_busy = write_req;   // high from capture until the write is in the queue

    // ---- info queue (same clock): what each queued request was
    reg  [4:0] iq_mem [0:N-1];
    reg [QAW:0] iq_w = {(QAW+1){1'b0}}, iq_r = {(QAW+1){1'b0}};
    wire [4:0] iq_head  = iq_mem[iq_r[QAW-1:0]];
    wire       iq_probe = iq_head[4];
    wire [1:0] iq_kind  = iq_head[3:2];
    wire [1:0] iq_word  = iq_head[1:0];

    reg [QAW:0] outstanding = {(QAW+1){1'b0}};   // queued, answer not consumed yet

    // ---- issue: at the slot (state 0), chipset first, as sdram_ctrl. Like
    //      sdram_ctrl (which re-initialises while reset_n is low) the chip port
    //      is ignored during reset: the chipset is frozen then and may show a
    //      stale cycle.
    wire chip_acc = ~chipDMA | ~chipRW;
    wire chip_wr  = ~chipRW;

    reg        fill_pend  = 1'b0;   // a cache fill is in flight
    reg        fill_stale = 1'b0;   // ...and its answer must be dropped (reset in between)
    reg [23:3] fill_blk   = 21'd0;
    reg [63:0] patch_d    = 64'd0;  // chip writes into the fill's line, word0 in [63:48]
    reg  [7:0] patch_m    = 8'd0;   // byte valid, bit 7 = word0 high byte

    reg        lat_run = 1'b0;      // chip read latency probe
    reg  [7:0] lat_cnt = 8'd0;

    reg        is_cpu_wr, is_fill, is_drop;

    always @(*) begin
        push_now  = 1'b0;
        push_data = 44'd0;
        push_info = 5'd0;
        is_cpu_wr = 1'b0;
        is_fill   = 1'b0;
        is_drop   = 1'b0;
        if (st_is0 && ready && reset_n) begin
            if (chip_acc) begin
                if (chip_wr) begin
                    if (outstanding < N) begin
                        push_now  = 1'b1;
                        push_data = {1'b1, 2'd0, ~chipU, ~chipL, chipAddr[23:1], chipWR};
                        push_info = {1'b0, K_CHIP_WR, chipAddr[2:1]};
                    end else is_drop = 1'b1;
                end else begin
                    // keep the last entry for writes: a read is useless once late
                    if (outstanding < N - 1) begin
                        push_now = 1'b1;
                        case (CHIP_RD_SIZE)
                            2'd2:    push_data = {1'b0, 2'd2, 2'b11, chipAddr[23:3], 2'b00, 16'h0};
                            2'd1:    push_data = {1'b0, 2'd1, 2'b11, chipAddr[23:2], 1'b0,  16'h0};
                            default: push_data = {1'b0, 2'd0, 2'b11, chipAddr[23:1],        16'h0};
                        endcase
                        push_info = {~lat_run, K_CHIP_RD, chipAddr[2:1]};
                    end else is_drop = 1'b1;
                end
            end else if (outstanding == 0) begin
                // a free slot and nothing in flight: the CPU port
                if (write_req && !write_ack) begin
                    push_now  = 1'b1;
                    is_cpu_wr = 1'b1;
                    push_data = {1'b1, 2'd0, ~write_dqm[1], ~write_dqm[0], writeAddr[23:1], writeDat};
                    push_info = {1'b0, K_CPU_WR, writeAddr[2:1]};
                end else if (cache_req && !fill_pend) begin
                    push_now  = 1'b1;
                    is_fill   = 1'b1;
                    push_data = {1'b0, 2'd2, 2'b11, cpuAddr[23:3], 2'b00, 16'h0};
                    push_info = {1'b0, K_CPU_RD, cpuAddr[2:1]};
                end
            end
        end
    end

    // ---- answers, in order
    localparam [1:0] R_IDLE = 2'd0, R_FWAIT = 2'd1, R_FILL = 2'd2;
    reg  [1:0] rs   = R_IDLE;
    reg  [1:0] fcnt = 2'd0;
    reg  [1:0] fpos = 2'd0;
    reg [63:0] fblk = 64'd0;

    always @(*) begin
        pop_now = 1'b0;
        case (rs)
            R_IDLE:  if (!sq_empty) pop_now = (iq_kind != K_CPU_RD) || fill_stale || !reset_n;
            R_FWAIT: pop_now = !reset_n;
            R_FILL:  pop_now = !reset_n || (st[0] && fcnt == 2'd3);
            default: pop_now = 1'b0;
        endcase
    end

    function automatic [15:0] wsel(input [63:0] b, input [1:0] i);
        case (i)
            2'd0:    wsel = b[63:48];
            2'd1:    wsel = b[47:32];
            2'd2:    wsel = b[31:16];
            default: wsel = b[15:0];
        endcase
    endfunction

    function automatic [63:0] merge(input [63:0] d, input [63:0] p, input [7:0] m);
        integer k;
        begin
            for (k = 0; k < 8; k = k + 1)
                merge[8*k +: 8] = m[k] ? p[8*k +: 8] : d[8*k +: 8];
        end
    endfunction

    reg [47:0] chip48_r = 48'd0;
    assign chip48 = chip48_r;

    always @(posedge sysclk) begin
        chipWE   <= 1'b0;
        fill_ack <= 1'b0;

        if (st_is2) write_ack <= 1'b0;
        if (lat_run && lat_cnt != 8'hFF) lat_cnt <= lat_cnt + 8'd1;

        // ---------------- issue side effects
        if (st_is0 && reset_n && chip_acc && chip_wr) begin
            chipWE <= 1'b1;                              // snoop now, as sdram_ctrl
            if (fill_pend && chipAddr[23:3] == fill_blk) begin
                if (~chipU) begin
                    patch_d[8*(7-2*chipAddr[2:1]) +: 8] <= chipWR[15:8];
                    patch_m[7-2*chipAddr[2:1]]          <= 1'b1;
                end
                if (~chipL) begin
                    patch_d[8*(6-2*chipAddr[2:1]) +: 8] <= chipWR[7:0];
                    patch_m[6-2*chipAddr[2:1]]          <= 1'b1;
                end
            end
        end
        if (is_drop) ovr <= 1'b1;
        if (push_now && push_info[4]) begin              // probe this chip read
            lat_run <= 1'b1;
            lat_cnt <= 8'd1;
        end
        if (is_cpu_wr) write_ack <= 1'b1;
        if (is_fill) begin
            fill_pend <= 1'b1;
            fill_blk  <= cpuAddr[23:3];
            patch_m   <= 8'd0;
        end

        // ---------------- answers
        case (rs)
            R_IDLE:
                if (!sq_empty) begin
                    case (iq_kind)
                        K_CHIP_RD: begin
                            case (CHIP_RD_SIZE)
                                2'd2: begin
                                    chipRD   <= wsel(sq_data, iq_word);
                                    chip48_r <= {wsel(sq_data, iq_word + 2'd1),
                                                 wsel(sq_data, iq_word + 2'd2),
                                                 wsel(sq_data, iq_word + 2'd3)};
                                end
                                2'd1: begin
                                    chipRD   <= wsel(sq_data, {1'b0,  iq_word[0]});
                                    chip48_r <= {wsel(sq_data, {1'b0, ~iq_word[0]}), 32'h0};
                                end
                                default: begin
                                    chipRD   <= sq_data[63:48];
                                    chip48_r <= 48'h0;
                                end
                            endcase
                            if (iq_probe) begin
                                dbg_rd_lat <= lat_cnt;
                                lat_run    <= 1'b0;
                            end
                        end
                        K_CPU_RD: begin
                            if (fill_stale || !reset_n) begin
                                fill_stale <= 1'b0;
                                fill_pend  <= 1'b0;
                            end else begin
                                fblk <= sq_data;
                                fpos <= iq_word;
                                rs   <= R_FWAIT;
                            end
                        end
                        default: ;                       // writes: nothing to hand back
                    endcase
                end

            // hand the line to the cache at the slot states sdram_ctrl uses
            // (acks visible at 8/10/12/14), clear of the chip-write snoop at 0..3
            R_FWAIT:
                if (!reset_n) begin
                    fill_pend <= 1'b0;
                    rs        <= R_IDLE;
                end else if (st == 4'd6) begin
                    fcnt <= 2'd0;
                    rs   <= R_FILL;
                end

            R_FILL:
                if (!reset_n) begin
                    fill_pend <= 1'b0;
                    rs        <= R_IDLE;
                end else if (st[0]) begin                 // states 7, 9, 11, 13
                    fill_ack <= 1'b1;
                    fill_dat <= wsel(merge(fblk, patch_d, patch_m), fpos + fcnt);
                    fcnt     <= fcnt + 2'd1;
                    if (fcnt == 2'd3) begin
                        fill_pend <= 1'b0;
                        rs        <= R_IDLE;
                    end
                end

            default: rs <= R_IDLE;
        endcase

        // an Amiga reset while a fill is queued: its answer is for nobody
        if (!reset_n && fill_pend && rs == R_IDLE && !(pop_now && iq_kind == K_CPU_RD))
            fill_stale <= 1'b1;

        // ---------------- queue bookkeeping
        if (push_now) begin
            iq_mem[iq_w[QAW-1:0]] <= push_info;
            iq_w <= iq_w + 1'b1;
        end
        if (pop_now) iq_r <= iq_r + 1'b1;
        outstanding <= outstanding + (push_now ? 1'b1 : 1'b0) - (pop_now ? 1'b1 : 1'b0);

        if (q_rst_s) begin
            outstanding <= {(QAW+1){1'b0}};
            iq_w        <= {(QAW+1){1'b0}};
            iq_r        <= {(QAW+1){1'b0}};
            fill_pend   <= 1'b0;
            fill_stale  <= 1'b0;
            lat_run     <= 1'b0;
            rs          <= R_IDLE;
        end
    end
endmodule
