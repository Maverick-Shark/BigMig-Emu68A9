// copy of teiram's aps6404l_model.sv with the >2-byte burst fix (see read path)
`timescale 1ns/1ps

// APS6404L-SQN QSPI PSRAM behavioral model (simulation only).
//
// Protocol convention (matches psram_bridge):
//   - sclk is a free-running 144 MHz clock produced by the PLL and routed
//     straight to the loan pad; the fabric domain drives one QPI nibble per
//     sclk period, sampling reads back on a phase-shifted capture strobe.
//   - Cmd / address / write data latched on the RISING edge of sclk: one bit
//     per period in SPI mode, one nibble per period in QPI mode.
//   - Read data presented after the FALLING edge of sclk, held until the next
//     falling edge.
//   - CE# low defines a session.
//   - SPI: SIO0 = SI (in), SIO1 = SO (out). QPI: SIO[3:0] bidir.
//
// Supported ops:
//   SPI : RSTEN 0x66, RST 0x99, EnterQPI 0x35, ReadID 0x9F
//         (cmd + 24 dummy addr bits + 8 result bytes on SO)
//   QPI : Write 0x02 (cmd, 24b addr, then one byte per 2 nibbles; the frame
//         length picks the exact byte count - 1|2 bytes for byte|word ops)
//         Fast Read 0x0B (cmd, 24b addr, 4 dummy, data nibbles)
//         Fast Quad Read 0xEB (cmd, 24b addr, 6 dummy, data nibbles)
// Byte addressable A[22:0], 1K-byte page wrap. 64 Mbit = 8 MByte.
//
// tSP/tHD monitors (sim only): flag any SIO transition occurring closer than
// ~2 ns to an sclk sampling edge. With the C1 phase placed away from the
// fabric posedges these should never fire; they exist to catch drive/phase
// regressions when the phase knob is retuned.

`ifndef MODEL_WAIT_EB
 // 0xEB dummy clocks before read data. 7 is the value that lines the data
 // launch up with the bridge's capture window (cap_first=15, registered
 // strobe -> first data nibble at period 16). The old default of 9 was tuned
 // against the hardware-broken pre-fix window and produces [z,z,dN-1,dN].
 `define MODEL_WAIT_EB 7      // literal in the "cnt < WAIT_EB" compare below
`endif

module aps6404l_model #(
    parameter integer DEPTH = 8*1024*1024,
    parameter [7:0]  MFID   = 8'h0D,  // AP Memory MFID
    parameter [7:0]  KGD    = 8'h5D,  // PASS (S series)
    // tACLK: clock-to-output from the launch (falling) edge. The real part is
    // 2.0..5.5 ns. The model delays its read outputs by TACLK_NS so the
    // sampling-clock phase must genuinely land inside the valid window;
    // with TACLK_NS=0 you get the old zero-delay behaviour, which cannot
    // distinguish a correct phase from a wrong one.
    parameter real   TACLK_NS = 5.5,
    // tOH: time from CE# going high until the pad is released. Real silicon
    // releases in well under one sclk period; TOH_NS=0 is the pessimistic
    // bound. Any TOH_NS < 2778 ps reproduces a capture-after-release fault,
    // so this is the knob that makes the CE# timing visible in simulation.
    parameter real   TOH_NS   = 0.0,
    // Value presented on the pad while undriven (board pull state).
    parameter [3:0]  IDLE_NS  = 4'h0,
    // Dummy-clock compare limit for 0xEB. Exposed as a parameter so the real
    // device's latency can be SWEPT rather than assumed -- a design that only
    // works at one exact value just agrees with whatever guess is baked into
    // the model. This was previously hardcoded to 9 only because that was the
    // value the (hardware-broken) capture window had been tuned against.
    parameter integer WAIT_EB  = `MODEL_WAIT_EB
) (
    input  wire       sclk,
    input  wire       ce_n,
    inout  wire [3:0] sio
);

    reg [7:0] mem [0:DEPTH-1];
    integer k;
    initial for (k = 0; k < DEPTH; k = k + 1) mem[k] = 8'h00;

    // ---------------- SIO (delayed by tACLK) --------
    // Read data is registered on the negedge and only reaches the pad after
    // TACLK_NS, which is what forces the capture phase into the real eye.
    reg [3:0] sio_drv = 4'h0;
    reg       sio_en  = 1'b0;
    reg [3:0] pad_drv = 4'h0;
    reg       pad_en  = 1'b0;
    assign sio = pad_en ? pad_drv : 4'hz;

    // ---------------- state -----------------------
    reg [7:0]  cmd8 = 8'h00;   // SPI accumulate
    reg [7:0]  cmdq = 8'h00;   // QPI accumulate (holds first nibble in [3:0])
    reg [23:0] a    = 24'h0;   // address field (holds first 6 nibbles)
    reg [4:0]  cnt  = 5'd0;    // generic period count
    reg [2:0]  ph = 3'd0;    // phase within frame
    reg [7:0]  dbyte = 8'h00;  // write byte accumulator (high nibble in [3:0])
    reg [1:0]  dhalf = 3'd0;   // nibbles written so far in current byte
    integer    baddr;          // resolved byte address
    integer    bcnt;           // bytes written in this frame
    integer    idptr;          // read-ID bit pointer
    reg [1:0]  rnib  = 3'd0;   // nibble index of current read byte
    reg        qpi   = 1'b0;

    // ---------------- read-ID ROM -----------------
    reg [7:0] idbuf [0:7];
    integer idn;
    initial begin
        for (idn = 0; idn < 8; idn = idn + 1) idbuf[idn] = 8'h00;
        idbuf[0] = MFID;
        idbuf[1] = KGD;
    end

    // ---------------- posedge (inputs) -------------
    always @(posedge sclk) begin
        if (ce_n) begin
            ph   <= 3'd0;
            cnt  <= 5'd0;
            dhalf<= 3'd0;
            sio_en <= 1'b0;
            idptr  <= 0;
        end else if (!qpi) begin
            // =================== SPI ===================
            if (ph == 3'd0) begin
                if (cnt == 5'd7) begin
                    cnt <= 5'd0;
                    case ({cmd8[6:0], sio[0]})
                        8'h9f: ph <= 3'd1;   // ReadID -> 24 dummy addr bits
                        8'h35: qpi <= 1'b1;  // Enter QPI
                        default: ;
                    endcase
                end else begin
                    cnt  <= cnt + 5'd1;
                    cmd8 <= {cmd8[6:0], sio[0]};
                end
            end else if (ph == 3'd1) begin
                // 25 dummy address bits (24 + 1 added read latency, matching
                // the real APS6404L observed on board)
                if (cnt == 5'd24) begin ph <= 3'd2; cnt <= 5'd0; end
                else cnt <= cnt + 5'd1;
            end
            // ph 3'd2 = read-ID data stream (negedge block)
        end else begin
            // =================== QPI ===================
            case (ph)
                3'd0: begin
                    if (cnt == 5'd1) begin
                        cnt <= 5'd0;
                        cmdq <= {cmdq[3:0], sio[3:0]};    // latch full 2-nibble cmd
                        case ({cmdq[3:0], sio[3:0]})
                            8'h02, 8'h38: begin ph <= 3'd1; bcnt <= 0; end
                            8'h0b:        begin ph <= 3'd1; end
                            8'heb:        begin ph <= 3'd1; end
                            8'hf5:        qpi <= 1'b0;
                            default: ;
                        endcase
                    end else begin
                        cnt  <= cnt + 5'd1;
                        cmdq <= {4'h0, sio[3:0]};
                    end
                end
                3'd1: begin
                    // 6 address nibbles; keep first 5 (+1 incoming) = 24 bits
                    if (cnt == 5'd5) begin
                        cnt <= 5'd0;
                        baddr <= {a[19:0], sio[3:0]};
                        case (cmdq)
                            8'h02, 8'h38: begin ph <= 3'd2; end
                            8'h0b:        begin ph <= 3'd3; end
                            8'heb:        begin ph <= 3'd4; end
                            default: ;
                        endcase
                    end else begin
                        cnt <= cnt + 5'd1;
                        a   <= {a[19:0], sio[3:0]};
                    end
                end
                3'd2: begin // write data: 2 nibbles per byte
                    if (dhalf == 3'd1) begin
                        dhalf <= 3'd0;
                        // 2 nibbles assembled: low 4 of dbyte + incoming
                        mem[baddr[22:0]] <= {dbyte[3:0], sio[3:0]};
                        baddr <= {baddr[22:10], baddr[9:0] + 10'd1};  // 1 KB page wrap
                        bcnt  <= bcnt + 1;
                    end else begin
                        dhalf <= 3'd1;
                        dbyte <= {4'h0, sio[3:0]};
                    end
                end
                3'd3: begin // 0x0B: 5 wait clocks then data (4 + 1 latency)
                    if (cnt < 5'd4) cnt <= cnt + 5'd1;
                    else begin ph <= 3'd5; cnt <= 5'd0; rnib <= 3'd0; end
                end
                3'd4: begin // 0xEB: WAIT_EB dummy clocks then data
                    if (cnt < WAIT_EB[4:0]) cnt <= cnt + 5'd1;
                    else begin ph <= 3'd5; cnt <= 5'd0; rnib <= 3'd0; end
                end
                default: ;
            endcase
        end
    end

    // ---------------- negedge (read data) -----------
    always @(negedge sclk) begin
        if (ce_n) begin
            sio_en <= 1'b0;
            idptr  <= 0;
            rnib   <= 3'd0;
        end else if (!qpi) begin
            if (ph == 3'd2) begin
                // Read-ID: 8 bytes out on SO (SIO1), MSB first, per period
                if (idptr < 64) begin
                    sio_en  <= 1'b1;
                    sio_drv <= {2'b00, idbuf[(idptr >> 3)][7 - (idptr & 7)], 1'b0};
                    idptr   <= idptr + 1;
                end else sio_en <= 1'b0;
            end else begin
                sio_en <= 1'b0;
            end
        end else if (ph == 3'd5) begin
            // QPI read data: MSB nibble first, changes on falling edges
            sio_en  <= 1'b1;
            sio_drv <= rnib[0] ? mem[baddr[22:0]][3:0]
                               : mem[baddr[22:0]][7:4];
            // fixed: next byte after EVERY low nibble (the original only stepped
            // after the first byte, so bursts longer than 2 bytes re-read byte 1);
            // the address wraps inside the 1 KB page like the device's wrapped burst
            if (rnib[0] == 1'b1) baddr <= {baddr[22:10], baddr[9:0] + 10'd1};
            rnib <= rnib + 3'd1;
        end else begin
            sio_en <= 1'b0;
        end
    end

    // ---------------- pad model (tACLK launch, CE# release) -----------------
    // LAUNCH: sio_drv/sio_en are computed at the negedge; the pad sees them
    // TACLK_NS later. Using TACLK_NS=0 degenerates to the previous zero-delay
    // model. A CONSTANT TACLK_NS per run is sufficient and is what the corner
    // matrix relies on: the capture instant C-L is fixed by the phase and the
    // capture window and does NOT depend on tACLK. Passing at TACLK_NS=5.5
    // proves setup (C-L >= 5.5); passing at TACLK_NS=2.0 proves hold
    // (C-L <= T + 2.0). Both together cover every per-cycle value in
    // [2.0, 5.5]. Do NOT randomise tACLK here: concurrent delayed writers
    // spawned by `always @(sio_drv or sio_en)` would complete out of order.
    //
    // RELEASE: real silicon stops driving the pad within tOH of CE# going
    // high. It does NOT wait for the next falling edge, and it does NOT
    // inherit tACLK. This matters: the previous version only cleared sio_en
    // on the negedge, so the pad stayed driven for a further tACLK after CE#
    // rose and a capture landing after CE# release could never be observed.
    //
    // The !ce_n guard stops a launch already in flight from re-asserting
    // pad_en after the release (it would otherwise win the race whenever
    // TOH_NS > TACLK_NS and silently hide the bug again).
    //
    // IDLE_NS models the board's pull state once the device stops driving. On
    // release the pad stays RESOLVED (pad_en high, driving IDLE_NS) rather
    // than going Hi-Z: that is what the board's pull resistors do, and it
    // keeps dout deterministic instead of X. What matters for the fault is
    // that the pad is no longer carrying device data - TOH_NS and this
    // release path are what make CE# timing visible in simulation.
    always @(sio_drv or sio_en or ce_n) begin
        if (ce_n) begin
            #(TOH_NS);
            pad_drv <= IDLE_NS;
            pad_en  <= 1'b1;
        end else if (!sio_en) begin
            // fix 2: not a read-data launch -> the device is not driving at all.
            // The original kept the idle level on the pad for TACLK_NS after CE#
            // fell, fighting the host's first command nibble (it produced the
            // "tSP violation" notes and broke any host that samples earlier than
            // TACLK_NS after CE# falls).
            pad_en  <= 1'b0;
        end else begin
            #(TACLK_NS);
            if (!ce_n) begin
                pad_drv <= sio_drv;
                pad_en  <= sio_en;
            end
        end
    end

    // ---------------- tSP / tHD monitors (sim) -------
    realtime last_chg        = 0.0;   // time of last SIO transition
    realtime last_sclk_pos   = 0.0;   // time of last sclk posedge
    integer  tsp_fails       = 0;

    always @(posedge sclk) last_sclk_pos = $realtime;

    // bus transition tracker (any direction)
    always @(sio) last_chg = $realtime;

    // input setup: the bridge-driven bus must be stable ~2 ns before the
    // sampling posedge of the QPI frames - exactly the tSP guard the C1 phase
    // knob must satisfy. Only checked once we are in QPI (the SPI/RDID init
    // turnaround is not what the phase knob is tuned for).
    //
    // Only meaningful while the HOST is driving the bus (command/address/write
    // phases). Once ph reaches the read-data phase the transitions being seen
    // are the device's own launches, which tSP does not govern -- including
    // them produced false positives at exactly TACLK_NS after each negedge.
    always @(posedge sclk) begin
        if (!ce_n && qpi && (ph < 3'd5)) begin
            if (($realtime - last_chg) < 2.0) begin
                $display("%0t MODEL: tSP violation (moved %0t; sio=%04b sclk_pos=%0t last_chg=%0t)",
                         $time, $realtime - last_chg, sio, last_sclk_pos, last_chg);
                tsp_fails = tsp_fails + 1;
            end
        end
    end

endmodule