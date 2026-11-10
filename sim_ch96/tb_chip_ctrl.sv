`timescale 1ns/1ps
// tb_chip_ctrl -- psram_chip_ctrl (BigMig chip RAM on the Chameleon96 dual
// APS6404L) against two APS6404L models behind delayed pads, driven like the
// real core:
//
//  * clk_114 / clk_sys (exactly 4:1, edges aligned) and amiga_clk -> c1, cck
//  * chip port driver: one access per 7 MHz slot at most, changed on the
//    clk7_en edge -- DMA-style reads/writes in the cck=1 slots, chip-bus
//    style reads/writes in the cck=0 slots
//  * CPU port driver: the Via-B protocol of minimig_m68k_hybrid_bridge
//    (payload, then cpuCS one clk later, wait ramready, capture next clk)
//  * clk_ram asynchronous to both (128 MHz), behavioural PLL DPS model
//
// Checks
//  * every chip read that the controller queued returns the memory content of
//    its slot (all earlier queued writes applied), in the sdram_ctrl word order
//    (chipRD = word, chip48 = next three words, wrapping in the 4-word block)
//  * every CPU read returns the latest value (its own posted write included);
//    a read racing a chip write to the same word by < 16 clk_114 is not judged
//  * at the end both PSRAM arrays hold exactly the reference
// Measures: chip read latency from the start of its 7 MHz slot to chipRD,
// unloaded (queue empty at the slot) and loaded.

`ifndef T_RAM_HALF_PS
  `define T_RAM_HALF_PS 3906       // 128.0 MHz
`endif
`ifndef RAM_PHASE_PS
  `define RAM_PHASE_PS 1234
`endif
`ifndef DFWD_NS
  `define DFWD_NS 1.0
`endif
`ifndef DBACK_NS
  `define DBACK_NS 1.0
`endif
`ifndef TACLK_NS
  `define TACLK_NS 3.5
`endif
`ifndef WAIT_EB
  `define WAIT_EB 5
`endif
`ifndef NSLOTS
  `define NSLOTS 12000
`endif
`ifndef SEED
  `define SEED 1
`endif
`ifndef RDSIZE
  `define RDSIZE 2
`endif
`ifndef SCLKINV
  `define SCLKINV 0
`endif
`ifndef DSKEW_A
  `define DSKEW_A 0.3              // CE#/SIO pad delay minus SCLK pad delay, chip A (ns)
`endif
`ifndef DSKEW_B
  `define DSKEW_B 0.7
`endif
`ifndef P_DMA_RD
  `define P_DMA_RD 35              // % of cck=1 slots with a chip read
`endif
`ifndef P_DMA_WR
  `define P_DMA_WR 10
`endif
`ifndef P_CB_RD
  `define P_CB_RD 5                // % of cck=0 slots with a chip read
`endif
`ifndef P_CB_WR
  `define P_CB_WR 10
`endif

module tb_chip_ctrl;
    // ------------------------------------------------------------ clocks
    reg clk_114 = 1'b0, clk_sys = 1'b0, clk_ram = 1'b0, clk_50 = 1'b0;
    always #4.405  clk_114 = ~clk_114;      // 113.5 MHz
    always #17.620 clk_sys = ~clk_sys;      // 28.375 MHz, edges on clk_114 edges
    initial begin
        #(`RAM_PHASE_PS / 1000.0);
        forever #(`T_RAM_HALF_PS / 1000.0) clk_ram = ~clk_ram;
    end
    always #10.0 clk_50 = ~clk_50;

    localparam real T_SLOT = 4 * 35.240;     // one 7 MHz slot, ns

    reg aclk_rst = 1'b1;
    wire clk7_en, clk7n_en, c1, c3, cck;
    wire [9:0] eclk;
    amiga_clk u_aclk (
        .clk_28(clk_sys), .clk7_en(clk7_en), .clk7n_en(clk7n_en),
        .c1(c1), .c3(c3), .cck(cck), .eclk(eclk), .reset_n(~aclk_rst));

    // ------------------------------------------------------------ DUT
    reg  core_rst  = 1'b1;
    reg  ram_lock  = 1'b0;
    wire clk_cap, pll_pen, pll_upd, pll_phdone;
    wire [4:0] pll_cntsel;

    wire a_sclk, a_ce_n, b_sclk, b_ce_n;
    wire [3:0] a_out, a_oe, a_in, b_out, b_oe, b_in;

    reg  [23:1] ch_addr = 23'd0;
    reg         ch_rw = 1'b1, ch_oe_n = 1'b1, ch_u_n = 1'b1, ch_l_n = 1'b1;
    reg  [15:0] ch_wd = 16'd0;
    wire [15:0] chipRD;
    wire [47:0] chip48;

    reg  [23:1] cp_addr = 23'd0;
    reg   [1:0] cp_state = 2'b01;
    reg         cp_cs = 1'b0, cp_u = 1'b1, cp_l = 1'b1;
    reg  [15:0] cp_wd = 16'd0;
    wire [15:0] cpuRD;
    wire        ramready, write_busy;

    wire        ready, cal_done_s, cal_fail_s, ovr;
    wire  [2:0] cal_c_s;
    wire [63:0] cal_status;
    wire  [7:0] dbg_rd_lat;

    localparam [22:0] CALB = 23'h01F000;

    psram_chip_ctrl #(
        .QAW(2), .CHIP_RD_SIZE(`RDSIZE), .S(20), .CAL_BASE(CALB),
        .PWRUP_CYCLES(2000), .RST_CYCLES(400), .MID_CYCLES(20),
        .CAL_WORDS(4), .CAL_PASSES(1), .SCLK_INV(`SCLKINV)
    ) dut (
        .sysclk(clk_114), .c_7m(c1), .reset_n(~core_rst), .cache_rst(1'b1),
        .cache_inhibit(1'b0), .cpu_cache_ctrl(4'b0001), .sys_locked(1'b1),
        .clk_ram(clk_ram), .clk_cap(clk_cap), .scanclk(clk_50), .ram_locked(ram_lock),
        .pll_phase_done(pll_phdone), .pll_phase_en(pll_pen), .pll_updn(pll_upd),
        .pll_cntsel(pll_cntsel),
        .PSA_SCLK(a_sclk), .PSA_CE_N(a_ce_n), .PSA_SIO_OUT(a_out), .PSA_SIO_OE(a_oe), .PSA_SIO_IN(a_in),
        .PSB_SCLK(b_sclk), .PSB_CE_N(b_ce_n), .PSB_SIO_OUT(b_out), .PSB_SIO_OE(b_oe), .PSB_SIO_IN(b_in),
        .ready(ready), .cal_done_s(cal_done_s), .cal_fail_s(cal_fail_s), .cal_c_s(cal_c_s),
        .cal_status(cal_status), .ovr(ovr), .dbg_rd_lat(dbg_rd_lat),
        .chipAddr({1'b0, ch_addr}), .chipL(ch_l_n), .chipU(ch_u_n), .chipRW(ch_rw),
        .chipDMA(ch_oe_n), .chipWR(ch_wd), .chipRD(chipRD), .chip48(chip48),
        .cpuAddr({1'b0, cp_addr}), .cpuCS(cp_cs), .cpustate(cp_state), .cpuL(cp_l), .cpuU(cp_u),
        .cpuWR(cp_wd), .cpuRD(cpuRD), .ramready(ramready), .write_busy(write_busy)
    );

    pll_dps_model #(.PHI0(6 * `T_RAM_HALF_PS / 20000.0), .STEP(`T_RAM_HALF_PS / 20000.0), .CNT(5'd2)) u_pll (
        .clk(clk_ram), .scanclk(clk_50), .phase_en(pll_pen), .updn(pll_upd), .cntsel(pll_cntsel),
        .phase_done(pll_phdone), .clk_cap(clk_cap));

    ps_pads #(.DFWD(`DFWD_NS), .DBACK(`DBACK_NS), .DSKEW(`DSKEW_A), .TACLK(`TACLK_NS),
              .WAIT(`WAIT_EB), .DEPTH(1 << 17)) ca (
        .sclk_f(a_sclk), .ce_n_f(a_ce_n), .sio_out_f(a_out), .sio_oe_f(a_oe), .sio_in_b(a_in));
    ps_pads #(.DFWD(`DFWD_NS), .DBACK(`DBACK_NS), .DSKEW(`DSKEW_B), .TACLK(`TACLK_NS),
              .WAIT(`WAIT_EB), .DEPTH(1 << 17)) cb (
        .sclk_f(b_sclk), .ce_n_f(b_ce_n), .sio_out_f(b_out), .sio_oe_f(b_oe), .sio_in_b(b_in));

    // ------------------------------------------------------------ reference
    // window: R1 = CPU writes, R2 = chip writes, reads anywhere
    localparam integer WBASE = 23'h001000;
    localparam integer WN    = 4096;
    localparam integer R2    = 2048;           // R2 starts at WBASE + R2
    reg [15:0] refm [0:WN-1];
    integer    lastcw [0:WN-1];                // clk_114 cycle of the last chip write push
    integer    cyc = 0;
    always @(posedge clk_114) cyc <= cyc + 1;

    integer errors = 0, checks = 0, skipped = 0;
    task automatic chk(input ok, input string msg);
        begin
            checks = checks + 1;
            if (ok !== 1'b1) begin
                errors = errors + 1;
                if (errors < 25) $display("%0t FAIL: %0s", $time, msg);
            end
        end
    endtask

    function automatic integer inwin(input [22:0] a);
        inwin = (a >= WBASE) && (a < WBASE + WN);
    endfunction

    // pending (posted, not yet queued) CPU write
    reg        pend_v = 1'b0;
    reg [22:0] pend_a;
    reg  [1:0] pend_be;
    reg [15:0] pend_d;

    // expected chip read answers, in queue order
    reg [22:0] eq_a   [0:255];
    reg [63:0] eq_blk [0:255];
    real       eq_t   [0:255];
    reg        eq_unl [0:255];
    integer    eq_w = 0, eq_r = 0;

    real slot_t = 0.0;                         // start of the current 7 MHz slot
    always @(posedge clk_sys) if (clk7_en) slot_t = $realtime;

    // ---- queue push monitor: apply writes, snapshot reads
    reg        m_we;
    reg  [1:0] m_sz, m_be, m_kind;
    reg [22:0] m_a, m_base;
    reg [15:0] m_d;
    integer    mk, mwi;
    reg [63:0] mblk;
    always @(posedge clk_114) begin
        if (dut.push_now) begin
            m_we   = dut.push_data[43];
            m_sz   = dut.push_data[42:41];
            m_be   = dut.push_data[40:39];
            m_a    = dut.push_data[38:16];
            m_d    = dut.push_data[15:0];
            m_kind = dut.push_info[3:2];
            if (m_we) begin
                if (inwin(m_a)) begin
                    mwi = m_a - WBASE;
                    if (m_be[1]) refm[mwi][15:8] = m_d[15:8];
                    if (m_be[0]) refm[mwi][7:0]  = m_d[7:0];
                    if (m_kind == 2'd1) lastcw[mwi] = cyc;
                end
                if (m_kind == 2'd3) pend_v = 1'b0;     // the posted CPU write is queued now
            end else if (m_kind == 2'd0) begin
                m_base = (`RDSIZE == 2) ? (m_a & ~23'd3) : (`RDSIZE == 1) ? (m_a & ~23'd1) : m_a;
                for (mk = 0; mk < 4; mk = mk + 1)
                    mblk[63 - 16*mk -: 16] = inwin(m_base + mk) ? refm[m_base + mk - WBASE] : 16'h0;
                eq_a[eq_w & 255]   = dut.push_data[38:16];
                eq_blk[eq_w & 255] = mblk;
                eq_t[eq_w & 255]   = slot_t;
                eq_unl[eq_w & 255] = (dut.outstanding == 0);   // nothing else in flight
                eq_w = eq_w + 1;
            end
        end
    end

    // the chip read address of the slot, to know the word inside the block
    reg [22:0] rd_word_q [0:255];
    integer    rq_w = 0;

    // ---- chip read answer monitor
    reg        chk_next = 1'b0;
    real       lat_ns;
    real       lu_min = 1.0e9, lu_max = 0.0, ll_min = 1.0e9, ll_max = 0.0;
    integer    n_unl = 0, n_lod = 0, n_ok1 = 0, n_ok2 = 0, n_rd = 0;
    reg  [1:0] ww;
    reg [63:0] blk;
    reg [15:0] e0, e1, e2, e3;
    always @(posedge clk_114) begin
        if (chk_next) begin
            chk_next = 1'b0;
            ww  = rd_word_q[eq_r & 255][1:0];
            blk = eq_blk[eq_r & 255];
            e0 = blk[63 - 16*ww -: 16];
            e1 = blk[63 - 16*((ww + 2'd1) & 2'd3) -: 16];
            e2 = blk[63 - 16*((ww + 2'd2) & 2'd3) -: 16];
            e3 = blk[63 - 16*((ww + 2'd3) & 2'd3) -: 16];
            if (`RDSIZE == 2) begin
                chk(chipRD === e0 && chip48 === {e1, e2, e3},
                    $sformatf("chip read %h: got %h %h exp %h %h%h%h",
                              rd_word_q[eq_r & 255], chipRD, chip48, e0, e1, e2, e3));
            end else if (`RDSIZE == 1) begin
                e0 = blk[63 - 16*{1'b0, ww[0]} -: 16];
                e1 = blk[63 - 16*{1'b0, ~ww[0]} -: 16];
                chk(chipRD === e0 && chip48[47:32] === e1,
                    $sformatf("chip read32 %h: got %h %h exp %h %h", rd_word_q[eq_r & 255],
                              chipRD, chip48[47:32], e0, e1));
            end else begin
                chk(chipRD === blk[63:48], $sformatf("chip read16 %h: got %h exp %h",
                                                     rd_word_q[eq_r & 255], chipRD, blk[63:48]));
            end
            lat_ns = $realtime - eq_t[eq_r & 255];
            n_rd = n_rd + 1;
            if (lat_ns <= T_SLOT - 3.0)     n_ok1 = n_ok1 + 1;   // same slot (today's chipset)
            if (lat_ns <= 2*T_SLOT - 3.0)   n_ok2 = n_ok2 + 1;   // one slot of advance (phase 2)
            if (eq_unl[eq_r & 255]) begin
                n_unl = n_unl + 1;
                if (lat_ns < lu_min) lu_min = lat_ns;
                if (lat_ns > lu_max) lu_max = lat_ns;
            end else begin
                n_lod = n_lod + 1;
                if (lat_ns < ll_min) ll_min = lat_ns;
                if (lat_ns > ll_max) ll_max = lat_ns;
            end
            eq_r = eq_r + 1;
        end
        if (dut.rs == 2'd0 && !dut.sq_empty && dut.iq_kind == 2'd0)
            chk_next = 1'b1;
    end

    // ------------------------------------------------------------ chip port driver
    integer seed = `SEED;
    reg     run_chip = 1'b0;
    reg        dw_go = 1'b0;           // directed chip write in the next slot
    reg [22:0] dw_a;
    reg [15:0] dw_d;
    reg  [1:0] dw_be;
    integer mode = 0;          // 0: random mix, 1: sparse reads only (unloaded latency)
    integer nslot = 0;
    reg [22:0] ra;
    integer r, kb;
    always @(posedge clk_sys) begin
        if (clk7_en) begin
            // new slot starts at this edge; cck toggles here, so the slot's cck is ~cck
            ch_rw   <= 1'b1;
            ch_oe_n <= 1'b1;
            ch_u_n  <= 1'b1;
            ch_l_n  <= 1'b1;
            if (dw_go) begin
                ch_addr <= dw_a; ch_rw <= 1'b0;
                ch_u_n  <= ~dw_be[1]; ch_l_n <= ~dw_be[0];
                ch_wd   <= dw_d;
                dw_go   <= 1'b0;
            end else if (run_chip) begin
                nslot = nslot + 1;
                r = $unsigned($random(seed)) % 100;
                if (mode == 1) begin
                    if ((nslot % 6) == 0) begin
                        ra = WBASE + ($unsigned($random(seed)) % WN);
                        ch_addr <= ra; ch_oe_n <= 1'b0;
                        rd_word_q[rq_w & 255] = ra; rq_w = rq_w + 1;
                    end
                end else if (!cck) begin             // the coming slot has cck = 1: DMA
                    if (r < `P_DMA_RD) begin
                        ra = WBASE + ($unsigned($random(seed)) % WN);
                        ch_addr <= ra; ch_oe_n <= 1'b0;
                        rd_word_q[rq_w & 255] = ra; rq_w = rq_w + 1;
                    end else if (r < `P_DMA_RD + `P_DMA_WR) begin
                        ra = WBASE + R2 + ($unsigned($random(seed)) % (WN - R2));
                        ch_addr <= ra; ch_rw <= 1'b0;
                        ch_u_n  <= 1'b0; ch_l_n <= 1'b0;
                        ch_wd   <= $random(seed);
                    end
                end else begin                       // cck = 0: chip-bus CPU slot
                    if (r < `P_CB_RD) begin
                        ra = WBASE + ($unsigned($random(seed)) % WN);
                        ch_addr <= ra; ch_oe_n <= 1'b0;
                        rd_word_q[rq_w & 255] = ra; rq_w = rq_w + 1;
                    end else if (r < `P_CB_RD + `P_CB_WR) begin
                        ra = WBASE + R2 + ($unsigned($random(seed)) % (WN - R2));
                        ch_addr <= ra; ch_rw <= 1'b0;
                        kb = $unsigned($random(seed)) % 3;
                        ch_u_n  <= (kb == 2);
                        ch_l_n  <= (kb == 1);
                        ch_wd   <= $random(seed);
                    end
                end
            end
        end
    end

    // a read pushed by the controller always comes from a slot that was a read;
    // reads dropped by the controller (queue full) must leave rd_word_q in step
    integer n_drop = 0, n_patch = 0;
    always @(posedge clk_114) begin
        if (dut.st_is0 && dut.ready && dut.chip_acc && dut.chip_wr && dut.fill_pend &&
            dut.chipAddr[23:3] == dut.fill_blk) n_patch = n_patch + 1;
        if (dut.is_drop && !dut.chip_wr) begin
            n_drop = n_drop + 1;
            // dropped: remove the newest entry (it is this slot's)
            rq_w = rq_w - 1;
        end
    end

    // ------------------------------------------------------------ CPU port driver
    reg        run_cpu = 1'b0;
    integer    n_cpu_rd = 0, n_cpu_wr = 0;
    reg [15:0] q;
    task automatic cpu_op(input w, input [22:0] a, input [1:0] be, input [15:0] d,
                          output [15:0] qq);
        integer to;
        begin
            @(negedge clk_sys);
            cp_addr  = a;
            cp_state = w ? 2'b11 : 2'b10;
            cp_u     = w ? ~be[1] : 1'b0;
            cp_l     = w ? ~be[0] : 1'b0;
            cp_wd    = d;
            @(negedge clk_sys);
            cp_cs    = 1'b1;
            to = 0;
            @(negedge clk_sys);
            while (ramready !== 1'b1) begin
                @(negedge clk_sys);
                to = to + 1;
                if (to > 20000) begin $display("%0t CPU TIMEOUT a=%h w=%0d", $time, a, w); $finish; end
            end
            if (w) begin
                pend_v  = 1'b1; pend_a = a; pend_be = be; pend_d = d;
                cp_cs    = 1'b0;
                cp_state = 2'b01;
            end else begin
                @(negedge clk_sys);
                qq       = cpuRD;
                cp_cs    = 1'b0;
                cp_state = 2'b01;
            end
        end
    endtask

    reg [15:0] expv;
    reg [22:0] cadr;
    reg  [1:0] cbe;
    integer    gap, hot, rc, cwi;
    initial begin : cpu_proc
        wait (run_cpu);
        hot = WBASE + 64;
        while (run_cpu) begin
            rc = $unsigned($random(seed)) % 100;
            if (rc < 70) cadr = hot + ($unsigned($random(seed)) % 96);            // cache hits
            else         cadr = WBASE + ($unsigned($random(seed)) % WN);
            if (($unsigned($random(seed)) % 100) < 30 && (cadr - WBASE) < R2) begin
                cbe = ($unsigned($random(seed)) % 3) + 1;
                cpu_op(1'b1, cadr, cbe, $random(seed), q);
                n_cpu_wr = n_cpu_wr + 1;
            end else begin
                cpu_op(1'b0, cadr, 2'b11, 16'h0, q);
                n_cpu_rd = n_cpu_rd + 1;
                cwi = cadr - WBASE;
                expv = refm[cwi];
                if (pend_v && pend_a == cadr) begin
                    if (pend_be[1]) expv[15:8] = pend_d[15:8];
                    if (pend_be[0]) expv[7:0]  = pend_d[7:0];
                end
                if (cyc - lastcw[cwi] < 16) skipped = skipped + 1;
                else chk(q === expv, $sformatf("cpu read %h: got %h exp %h", cadr, q, expv));
            end
            gap = $unsigned($random(seed)) % 8;
            repeat (gap) @(negedge clk_sys);
            if (($unsigned($random(seed)) % 500) == 0) hot = WBASE + ($unsigned($random(seed)) % (WN - 96));
        end
    end

    // ------------------------------------------------------------ CE# timing at chip A pins
    realtime ce_rise = 0.0, ce_fall = 0.0, ce_hi_min = 1.0e9, ce_lo_max = 0.0;
    reg      mon = 1'b0;
    always @(ca.ce_d) begin
        if (ca.ce_d === 1'b1) begin
            ce_rise = $realtime;
            if (mon && (ce_rise - ce_fall) > ce_lo_max) ce_lo_max = ce_rise - ce_fall;
        end else if (ca.ce_d === 1'b0) begin
            ce_fall = $realtime;
            if (mon && (ce_fall - ce_rise) < ce_hi_min) ce_hi_min = ce_fall - ce_rise;
        end
    end

    // ------------------------------------------------------------ main
    integer j;
    reg [7:0] ma, mb;
    initial begin
        for (j = 0; j < WN; j = j + 1) begin refm[j] = 16'h0; lastcw[j] = -1000; end
        $display("tb_chip_ctrl: clk_ram half=%0d ps  DFWD=%0.2f DBACK=%0.2f TACLK=%0.2f WAIT=%0d RDSIZE=%0d seed=%0d",
                 `T_RAM_HALF_PS, `DFWD_NS, `DBACK_NS, `TACLK_NS, `WAIT_EB, `RDSIZE, `SEED);
        repeat (10) @(posedge clk_sys);
        aclk_rst = 1'b0;
        repeat (20) @(posedge clk_sys);
        ram_lock = 1'b1;
        j = 0;
        while (!(cal_done_s && ready) && j < 4000000) begin @(posedge clk_114); j = j + 1; end
        if (!ready) begin $display("CAL TIMEOUT"); $finish; end
        $display("%0t cal: fail=%0d c*=%0d s*=%0d eye=%0d len1=%0d len2=%0d margin=%0d",
                 $time, cal_fail_s, cal_c_s, dut.u_dual.cal.s_star, dut.u_dual.cal.eye_len,
                 dut.u_dual.cal.len1, dut.u_dual.cal.len2, dut.u_dual.cal.margin);
        mon = 1'b1; ca.mon = 1'b1; cb.mon = 1'b1;
        core_rst = 1'b0;
        repeat (600) @(posedge clk_114);           // cache tag clear

        // 1) unloaded latency: sparse chip reads, no CPU traffic
        mode = 1; run_chip = 1'b1;
        repeat (1200) @(posedge clk_sys);
        $display("  sparse reads: n=%0d unloaded latency %0.1f .. %0.1f ns", n_unl, lu_min, lu_max);

        // 2) full mix
        mode = 0; run_cpu = 1'b1;
        repeat (`NSLOTS * 4) @(posedge clk_sys);
        run_cpu = 1'b0;
        run_chip = 1'b0;
        repeat (400) @(posedge clk_sys);

        // 3) chip writes into the line of a cache fill in flight: the line the
        //    cache gets must carry them (the fill read the old data)
        begin : patch_test
            integer t, n_ok, w0, nw, x;
            for (t = 0; t < 24; t = t + 1) begin
                cadr = WBASE + R2 + 400 + 4 * t;                 // a fresh line each time
                w0 = t % 4;
                @(negedge clk_sys);
                cp_addr = cadr + w0; cp_state = 2'b10; cp_u = 1'b0; cp_l = 1'b0;
                @(negedge clk_sys);
                cp_cs = 1'b1;
                n_ok = 0;
                while (!dut.fill_pend && n_ok < 2000) begin @(negedge clk_sys); n_ok = n_ok + 1; end
                repeat (t % 3) @(posedge clk_sys);
                nw = 1 + (t % 3);                                // 1..3 writes into the line
                for (x = 0; x < nw; x = x + 1) begin
                    @(posedge clk_sys);
                    while (dw_go) @(posedge clk_sys);
                    dw_a  = cadr + ((w0 + x + t) % 4);
                    dw_d  = $random(seed);
                    dw_be = (x == 1) ? 2'b10 : (x == 2) ? 2'b01 : 2'b11;
                    dw_go = 1'b1;
                end
                while (ramready !== 1'b1) @(negedge clk_sys);
                @(negedge clk_sys);
                q = cpuRD;
                cp_cs = 1'b0; cp_state = 2'b01;
                while (dw_go) @(posedge clk_sys);
                repeat (80) @(posedge clk_sys);                  // fill delivered, writes done
                for (j = 0; j < 4; j = j + 1) begin
                    cpu_op(1'b0, cadr + j, 2'b11, 16'h0, q);
                    chk(q === refm[cadr + j - WBASE],
                        $sformatf("patch test %0d: word %h got %h exp %h", t, cadr + j, q,
                                  refm[cadr + j - WBASE]));
                end
            end
        end

        // 4) an Amiga reset while a cache fill is in flight, then normal reads
        //    of that line: the stale answer must not reach the cache
        begin : rst_test
            integer t, n_ok;
            for (t = 0; t < 8; t = t + 1) begin
                cadr = WBASE + R2 + 64 + 40 * t;
                @(negedge clk_sys);
                cp_addr = cadr; cp_state = 2'b10; cp_u = 1'b0; cp_l = 1'b0;
                @(negedge clk_sys);
                cp_cs = 1'b1;
                n_ok = 0;
                while (!dut.fill_pend && n_ok < 2000) begin @(negedge clk_sys); n_ok = n_ok + 1; end
                repeat (t) @(posedge clk_114);           // vary where the reset lands
                core_rst = 1'b1;
                cp_cs = 1'b0; cp_state = 2'b01;
                repeat (2 + t) @(negedge clk_sys);
                core_rst = 1'b0;
                repeat (700) @(posedge clk_114);         // cache tag clear
                chk(dut.fill_pend == 1'b0 && dut.fill_stale == 1'b0 && dut.outstanding == 0,
                    $sformatf("reset test %0d: fill state left behind (pend=%0d stale=%0d out=%0d)",
                              t, dut.fill_pend, dut.fill_stale, dut.outstanding));
                for (j = 0; j < 4; j = j + 1) begin
                    cpu_op(1'b0, (cadr & ~23'd3) + j, 2'b11, 16'h0, q);
                    chk(q === refm[(cadr & ~23'd3) + j - WBASE],
                        $sformatf("reset test %0d: read %h got %h exp %h", t, (cadr & ~23'd3) + j,
                                  q, refm[(cadr & ~23'd3) + j - WBASE]));
                end
            end
        end

        // the arrays must hold exactly the reference
        for (j = 0; j < WN; j = j + 1) begin
            ma = ca.u_mem.mem[WBASE + j];
            mb = cb.u_mem.mem[WBASE + j];
            chk({ma, mb} === refm[j], $sformatf("array word %h: A=%h B=%h exp %h",
                                               WBASE + j, ma, mb, refm[j]));
        end
        chk(eq_r == eq_w, $sformatf("chip read answers %0d of %0d", eq_r, eq_w));

        $display("  chip reads answered: %0d (unloaded %0d, loaded %0d)", n_rd, n_unl, n_lod);
        $display("  latency slot start -> chipRD: unloaded %0.1f .. %0.1f ns, loaded %0.1f .. %0.1f ns",
                 lu_min, lu_max, ll_min, ll_max);
        $display("  within the same slot (<= %0.1f ns): %0d / %0d;  within two slots (<= %0.1f ns): %0d / %0d",
                 T_SLOT - 3.0, n_ok1, n_rd, 2*T_SLOT - 3.0, n_ok2, n_rd);
        $display("  cpu ops: %0d reads, %0d writes; racing reads not judged: %0d",
                 n_cpu_rd, n_cpu_wr, skipped);
        $display("  chip reads dropped (queue full): %0d; chip writes merged into a fill in flight: %0d",
                 n_drop, n_patch);
        $display("  CE# at chip A pins: min high %0.2f ns (tCPH >= 18), max low %0.2f ns (tCEM <= 8000)",
                 ce_hi_min, ce_lo_max);
        $display("  pins (min, A/B): tSP %0.2f/%0.2f (>=2)  tHD %0.2f/%0.2f (>=2)  tCSP %0.2f/%0.2f (>=2.5)  tCHD %0.2f/%0.2f (>=3)",
                 ca.tsp_min, cb.tsp_min, ca.thd_min, cb.thd_min, ca.tcsp_min, cb.tcsp_min, ca.tchd_min, cb.tchd_min);
        $display("PINS inv=%0d skewA=%0.2f skewB=%0.2f tSP=%0.2f tHD=%0.2f tCSP=%0.2f tCHD=%0.2f",
                 `SCLKINV, `DSKEW_A, `DSKEW_B,
                 (ca.tsp_min < cb.tsp_min) ? ca.tsp_min : cb.tsp_min, (ca.thd_min < cb.thd_min) ? ca.thd_min : cb.thd_min,
                 (ca.tcsp_min < cb.tcsp_min) ? ca.tcsp_min : cb.tcsp_min, (ca.tchd_min < cb.tchd_min) ? ca.tchd_min : cb.tchd_min);
        $display("RESULT taclk=%0.2f dfwd=%0.2f c=%0d unl_min=%0.1f unl_max=%0.1f same_slot=%0d/%0d two_slots=%0d/%0d errors=%0d checks=%0d",
                 `TACLK_NS, `DFWD_NS, cal_c_s, lu_min, lu_max, n_ok1, n_rd, n_ok2, n_rd, errors, checks);
        if (errors == 0) $display("TB PASS (%0d checks)", checks);
        else             $display("TB FAIL (%0d errors / %0d checks)", errors, checks);
        $finish;
    end
endmodule
