// SPDX-License-Identifier: MIT
//
// pktrec_replay - capture replay (M6): turns a capture record stream played
// back by the recorder (file -> hugepage ring -> AXI DMA MM2S -> fdrec_core
// egress FIFO) into frames and releases each frame into one port's TX MAC
// against the shared timebase. Verilog shell: pktrec_replay_top.v.
//
//   fdrec_core m_axis_snk (src_clk, 128 bit) --+-- SEL = 0 --> m_chk (fdrec_check, unchanged)
//                                              +-- SEL = 1 --> async FIFO (32 beats) --> dp_clk
//   dp_clk: parser -> frame store (data 8192 x 128 bit = 128 KB + metadata 2048 frames)
//           -> scheduler -> 128 -> 16 bit -> m_rpl (tdest = TX port) -> pktrec_m0_path
//              replay FIFO of that port (path mode 4 REPLAY, PATH_RPL) -> MAC TX
//
// Record format: include/pktrec_format.h (16-byte header + frame bytes, padded
// to 16; all-zero 16-byte units are fill). The parser checks every header
// (marker nibble 0xA, port < 4, 1 <= cap_len <= MAX_CAP, cap_len + 4 <= orig_len,
// TRUNC flag consistent); a unit that is neither a header nor fill counts one
// PARSE_ERROR and the parser re-synchronises by testing every following unit
// (like pktrec-export). Optional port filter (CTRL.FILTER_EN/FILTER_PORT) and
// bad-frame policy (CTRL.BAD_MODE: 0 send as a good frame (the MAC appends a
// new, valid FCS), 1 send error-terminated (tuser[0] -> /V/ instead of the
// FCS, the receiver counts an RX error), 2 skip). Skipped records are counted.
//
// Frame store: a frame's bytes go into the data FIFO; its metadata {ts,
// cap_len, bad} is written only with its LAST beat, so the scheduler never sees
// an incomplete frame (no partial frame is ever released). The store holds
// 128 KB / 2048 frames (>= 8 maximum-size frames; ~1600 64-byte frames, so a
// short capture can be preloaded completely: pktrec-replay --preload, which
// lets the recorder DMA be used by a capture during the replay). When it is full the parser
// stops reading and the back-pressure reaches the DMA (no loss).
//
// Scheduler (CTRL.MODE):
//   0 TIMED: target_i = t0 + ((ts_i - ts_first) * RATE_INV) >> 16, RATE_INV in
//            16.16 (0x10000 = original timing, 0x8000 = twice as fast,
//            0x20000 = half speed); ts_first = timestamp of the first frame.
//   1 BACK-TO-BACK: every frame as soon as the TX path takes it (line rate).
//   2 FIXED GAP: target_0 = t0, target_i = target_{i-1} + GAP_NS (start to start).
//   t0 = TB_NOW + START_DELAY, latched by CMD.GO. A frame is released (its first
//   16-bit word handed to the port's replay FIFO) in the first cycle with
//   timebase >= target and room in that FIFO: never early, at most ~1 dp_clk
//   (+ the timebase step) late when the TX path is free.
//   The output word stream of a frame is never interrupted (dp_clk writes 4x
//   faster than the MAC reads), as the Taxi TX MAC requires.
// Statistics per released frame: lateness = timebase at release - target
// (LATE counts lateness > LATE_THRESH; MAX_LATE, LAST_LATE, LATE_SUM).
// UNDERRUN: the scheduler waited for data (store empty) and the next frame
// then arrived after its target (TIMED/FIXED), or, BACK-TO-BACK, the store ran
// empty between frames before the end of the stream (EXPECT reached / mid-
// record). Never hidden: counted, STATUS.UNDERRUN is sticky, the frame is sent
// late (and counted LATE if beyond the threshold) - frames are never re-timed.
//
// Control (CMD, write 1): ARM (from IDLE/DONE: clear counters, parse and fill
// the store, nothing is sent) -> GO (latch t0, start releasing) -> the run ends
// (DONE) when EXPECT records have been processed, or after STOP once the input
// has been idle for 256 cycles and everything is sent. ABORT: finish the frame
// on the wire, drop everything buffered -> IDLE. While SEL = 1 and the block is
// IDLE/DONE/ABORTING, input beats are accepted and discarded (counted), so the
// DMA can always drain.
//
// Register map: include/pktrec_regs.h PKTREC_RPL_* (and the table below).
//
//   0x000 ID 0x504B5250 "PKRP"      0x004 VERSION 0x00010000
//   0x008 CTRL RW  [0] SEL [2:1] MODE [5:4] BAD_MODE [6] FILTER_EN [9:8] FILTER_PORT
//                  [13:12] TX_PORT
//   0x00C CMD  WO  [0] ARM [1] GO [2] STOP [3] ABORT
//   0x010 STATUS RO [2:0] state (0 IDLE 1 ARMED 2 RUNNING 3 DONE 4 ABORTING)
//                  [3] STOP requested [8] UNDERRUN [9] PARSE_ERROR [10] LATE (sticky,
//                  cleared by ARM) [11] TX port is in REPLAY (m0 EFF_PATH) [12] input idle
//                  [13] scheduler busy [14] store has frames
//   0x014 RATE_INV (0x00010000)   0x018 START_DELAY ns (1000000)
//   0x01C LATE_THRESH ns (100)    0x020 GAP_NS (672)
//   0x024/0x028 EXPECT_LO/HI records (0 = unknown, end with STOP)
//   0x02C STORE_LEVEL [15:0] data beats [31:16] frames   0x030 STORE_BEATS (8192)
//   0x034 MAX_CAP (16384)
//   0x038/0x03C T0   0x040/0x044 TS_FIRST   0x048/0x04C LAST_TARGET
//   0x050 MAX_LATE ns (sat.)  0x054 LAST_LATE ns (sat.)
//   64-bit counters (LO read latches HI): 0x080 RECORDS 0x088 FRAMES 0x090 BYTES
//   0x098 PARSE_ERRORS 0x0A0 FILL 0x0A8 SKIPPED 0x0B0 UNDERRUNS 0x0B8 LATE
//   0x0C0 LATE_SUM_NS 0x0C8 BEATS_IN 0x0D0 DISCARD_BEATS 0x0D8 BAD_SENT
//   0x0E0 RECORDS_DONE
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_replay #(
    parameter int STORE_BEATS = 8192,     // 128-bit beats (128 KB)
    parameter int META_DEPTH  = 2048,
    parameter int MAX_CAP     = 16384
)(
    // ---- egress stream (src_clk) ----
    input  wire logic          src_clk,
    input  wire logic          src_rst,
    input  wire logic [127:0]  s_egr_tdata,
    input  wire logic          s_egr_tlast,
    input  wire logic          s_egr_tvalid,
    output wire logic          s_egr_tready,
    output wire logic [127:0]  m_chk_tdata,
    output wire logic          m_chk_tlast,
    output wire logic          m_chk_tvalid,
    input  wire logic          m_chk_tready,

    // ---- dp_clk ----
    input  wire logic          clk,
    input  wire logic          rst,
    input  wire logic [63:0]   tb_now,
    input  wire logic [7:0]    tb_inc_ns,
    output wire logic [15:0]   m_rpl_tdata,
    output wire logic [1:0]    m_rpl_tkeep,
    output wire logic          m_rpl_tvalid,
    input  wire logic          m_rpl_tready,
    output wire logic          m_rpl_tlast,
    output wire logic          m_rpl_tuser,
    output wire logic [1:0]    m_rpl_tdest,
    input  wire logic [3:0]    rpl_eff,          // asynchronous (ctrl_clk)

    input  wire logic [11:0]   s_axi_awaddr,
    input  wire logic          s_axi_awvalid,
    output logic               s_axi_awready,
    input  wire logic [31:0]   s_axi_wdata,
    input  wire logic [3:0]    s_axi_wstrb,
    input  wire logic          s_axi_wvalid,
    output logic               s_axi_wready,
    output wire logic [1:0]    s_axi_bresp,
    output logic               s_axi_bvalid,
    input  wire logic          s_axi_bready,
    input  wire logic [11:0]   s_axi_araddr,
    input  wire logic          s_axi_arvalid,
    output logic               s_axi_arready,
    output logic [31:0]        s_axi_rdata,
    output wire logic [1:0]    s_axi_rresp,
    output logic               s_axi_rvalid,
    input  wire logic          s_axi_rready
);

localparam [31:0] REG_ID      = 32'h504B5250;
localparam [31:0] REG_VERSION = 32'h00010000;

localparam [2:0] G_IDLE = 3'd0, G_ARMED = 3'd1, G_RUN = 3'd2, G_DONE = 3'd3, G_ABORT = 3'd4;
localparam [1:0] M_TIMED = 2'd0, M_B2B = 2'd1, M_FIXED = 2'd2;

// ===========================================================================
// Registers (dp_clk)
// ===========================================================================
logic        r_sel = 1'b0;
logic [1:0]  r_mode = M_TIMED;
logic [1:0]  r_bad_mode = 2'd0;
logic        r_filt_en = 1'b0;
logic [1:0]  r_filt_port = 2'd0;
logic [1:0]  r_tx_port = 2'd0;
logic [31:0] r_rate_inv = 32'h0001_0000;
logic [31:0] r_start_delay = 32'd1_000_000;
logic [31:0] r_late_thresh = 32'd100;
logic [31:0] r_gap = 32'd672;
logic [63:0] r_expect = 64'd0;
logic        cmd_arm, cmd_go, cmd_stop, cmd_abort;

// ===========================================================================
// src_clk: stream switch + clock-domain crossing
// ===========================================================================
logic sel_src;
xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(1))
sel_cdc (.src_clk(clk), .src_in(r_sel), .dest_clk(src_clk), .dest_out(sel_src));

logic cdc_full, cdc_wr_busy, cdc_empty, cdc_rd_busy;
wire  cdc_can_wr = !cdc_full && !cdc_wr_busy;
assign m_chk_tdata  = s_egr_tdata;
assign m_chk_tlast  = s_egr_tlast;
assign m_chk_tvalid = s_egr_tvalid && !sel_src;
assign s_egr_tready = sel_src ? cdc_can_wr : m_chk_tready;
wire  cdc_wr = s_egr_tvalid && sel_src && cdc_can_wr;

wire [127:0] in_data;
wire         in_valid = !cdc_empty && !cdc_rd_busy;
logic        in_pop;

xpm_fifo_async #(
    .FIFO_MEMORY_TYPE    ("distributed"),
    .FIFO_WRITE_DEPTH    (32),
    .WRITE_DATA_WIDTH    (128),
    .READ_DATA_WIDTH     (128),
    .READ_MODE           ("fwft"),
    .FIFO_READ_LATENCY   (0),
    .CDC_SYNC_STAGES     (3),
    .RELATED_CLOCKS      (0),
    .ECC_MODE            ("no_ecc"),
    .FULL_RESET_VALUE    (1),
    .USE_ADV_FEATURES    ("0000"),
    .DOUT_RESET_VALUE    ("0"),
    .WAKEUP_TIME         (0),
    .SIM_ASSERT_CHK      (0)
) cdc_fifo (
    .rst           (src_rst),
    .wr_clk        (src_clk),
    .wr_en         (cdc_wr),
    .din           (s_egr_tdata),
    .full          (cdc_full),
    .wr_rst_busy   (cdc_wr_busy),
    .rd_clk        (clk),
    .rd_en         (in_pop),
    .dout          (in_data),
    .empty         (cdc_empty),
    .rd_rst_busy   (cdc_rd_busy),
    .sleep         (1'b0),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .overflow (), .prog_full (), .rd_data_count (), .wr_data_count (), .almost_full (),
    .wr_ack (), .underflow (), .prog_empty (), .almost_empty (), .data_valid (),
    .sbiterr (), .dbiterr ()
);

logic [3:0] eff_s;
xpm_cdc_array_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(0),
                       .WIDTH(4))
eff_cdc (.src_clk(1'b0), .src_in(rpl_eff), .dest_clk(clk), .dest_out(eff_s));

// ===========================================================================
// dp_clk: global state
// ===========================================================================
logic [2:0]  gstate = G_IDLE;
logic        stop_req = 1'b0;
logic        st_underrun = 1'b0, st_perr = 1'b0, st_late = 1'b0;
logic [8:0]  idle_cnt = '0;
wire         in_idle = idle_cnt[8];
wire         parse_en = (gstate == G_ARMED) || (gstate == G_RUN);
logic [1:0]  tx_port_q = 2'd0;                 // latched at GO
logic [63:0] t0 = '0, ts_first = '0;
logic        first = 1'b1;

// counters
logic [63:0] c_records, c_frames, c_bytes, c_perr, c_fill, c_skip, c_under, c_late, c_late_sum,
             c_beats, c_discard, c_bad, c_rec_done;
logic [31:0] max_late = '0, last_late = '0;

// ===========================================================================
// Frame store
// ===========================================================================
localparam int MW = 64 + 15 + 1;               // {bad, cap_len[14:0], ts}
logic          d_wr, m_wr, d_rd, m_rd, store_rst;
logic [127:0]  d_dout;
logic [MW-1:0] m_din, m_dout;
logic          d_full, m_full, d_valid, m_valid;
logic [$clog2(STORE_BEATS)+2:0] d_level;
logic [$clog2(META_DEPTH)+2:0]  m_level;

pktrec_rpl_sfifo #(.W(128), .DEPTH(STORE_BEATS)) data_fifo (
    .clk(clk), .rst(rst || store_rst), .wr_en(d_wr), .din(in_data), .full(d_full),
    .rd_en(d_rd), .dout(d_dout), .valid(d_valid), .level(d_level));
pktrec_rpl_sfifo #(.W(MW), .DEPTH(META_DEPTH)) meta_fifo (
    .clk(clk), .rst(rst || store_rst), .wr_en(m_wr), .din(m_din), .full(m_full),
    .rd_en(m_rd), .dout(m_dout), .valid(m_valid), .level(m_level));

// ===========================================================================
// Parser
// ===========================================================================
logic        p_data = 1'b0;          // 0 = expecting a header, 1 = frame data
logic        p_skip = 1'b0;
logic        p_resync = 1'b0;
logic [10:0] p_beats = '0;           // data beats left (incl. the current one)
logic [63:0] p_ts = '0;
logic [14:0] p_len = '0;
logic        p_bad = 1'b0;

wire [63:0] h_ts    = in_data[63:0];
wire [15:0] h_cap   = in_data[79:64];
wire [15:0] h_orig  = in_data[95:80];
wire [7:0]  h_port  = in_data[103:96];
wire [7:0]  h_flags = in_data[111:104];
wire [16:0] h_cap4  = {1'b0, h_cap} + 17'd4;
wire        h_fill  = (in_data == 128'd0);
wire        h_ok    = (h_flags[7:4] == 4'hA) && (h_port < 8'd4) && (h_cap != 16'd0) &&
                      (h_cap <= MAX_CAP) && (h_cap4 <= {1'b0, h_orig}) &&
                      (h_flags[1] == (h_cap4 < {1'b0, h_orig}));
wire        h_skip  = (r_filt_en && h_port[1:0] != r_filt_port) ||
                      (h_flags[0] && r_bad_mode == 2'd2);
wire        p_last  = (p_beats == 11'd1);
// a data beat can be taken: skipped, or room in the store (and for the last
// beat also in the metadata FIFO)
wire        p_room  = p_skip || (!d_full && (!p_last || !m_full));

always_comb begin
    in_pop = 1'b0;
    d_wr   = 1'b0;
    m_wr   = 1'b0;
    if (in_valid) begin
        if (!parse_en)
            in_pop = 1'b1;                                       // discard
        else if (!p_data)
            in_pop = 1'b1;
        else if (p_room) begin
            in_pop = 1'b1;
            d_wr   = !p_skip;
            m_wr   = !p_skip && p_last;
        end
    end
end
assign m_din = {p_bad, p_len, p_ts};

// ===========================================================================
// Scheduler
// ===========================================================================
typedef enum logic [2:0] {S_IDLE, S_CALC, S_LOAD, S_WAIT, S_SEND} sstate_t;
sstate_t     s_state = S_IDLE;
logic [63:0] cur_ts = '0;
logic [14:0] cur_len = '0;
logic        cur_bad = 1'b0;
logic [63:0] target = '0, target_m = '0;
logic [79:0] mul_a = '0, mul_acc = '0;
logic [31:0] mul_b = '0;
logic        starved = 1'b0, starve_mid = 1'b0;
logic        due = 1'b0;
logic [127:0] word = '0;
logic [2:0]  widx = '0;
logic [14:0] left = '0;               // bytes not yet handed out (incl. current word)
logic        lat_v = 1'b0;
logic [63:0] lat_raw = '0;

// (S_SEND: the next 128-bit beat of a committed frame is always in the store's
// prefetch queue; the d_valid term only guards against sending a stale word)
wire out_valid = (s_state == S_WAIT && due) ||
                 (s_state == S_SEND && (widx != 3'd7 || left <= 15'd2 || d_valid));
wire out_last  = (left <= 15'd2);
wire out_hs    = out_valid && m_rpl_tready;
assign m_rpl_tdata  = word[16*widx +: 16];
assign m_rpl_tkeep  = (left == 15'd1) ? 2'b01 : 2'b11;
assign m_rpl_tvalid = out_valid;
assign m_rpl_tlast  = out_last;
assign m_rpl_tuser  = out_last && cur_bad && (r_bad_mode == 2'd1);
assign m_rpl_tdest  = tx_port_q;

// next 128-bit beat needed after this word
wire need_beat = out_hs && !out_last && (widx == 3'd7);
assign d_rd = (s_state == S_LOAD && d_valid) || (need_beat && d_valid) ||
              (gstate == G_ABORT && s_state == S_IDLE && d_valid);
assign m_rd = (s_state == S_IDLE && gstate == G_RUN && m_valid) ||
              (gstate == G_ABORT && s_state == S_IDLE && m_valid);
wire sched_idle = (s_state == S_IDLE);

always_ff @(posedge clk) begin
    store_rst <= 1'b0;
    lat_v     <= 1'b0;

    // ---- input idle detector (STOP) ----
    if (in_valid) idle_cnt <= '0;
    else if (!in_idle) idle_cnt <= idle_cnt + 1'b1;

    // ---- parser ----
    if (in_pop) begin
        if (!parse_en) begin
            c_discard <= c_discard + 1'b1;
        end else begin
            c_beats <= c_beats + 1'b1;
            if (!p_data) begin
                if (h_fill) begin
                    c_fill <= c_fill + 1'b1;
                end else if (h_ok) begin
                    c_records <= c_records + 1'b1;
                    p_resync  <= 1'b0;
                    p_data    <= 1'b1;
                    p_skip    <= h_skip;
                    p_ts      <= h_ts;
                    p_len     <= h_cap[14:0];
                    p_bad     <= h_flags[0];
                    p_beats   <= (h_cap + 16'd15) >> 4;
                end else if (!p_resync) begin
                    p_resync <= 1'b1;
                    st_perr  <= 1'b1;
                    c_perr   <= c_perr + 1'b1;
                end
            end else begin
                p_beats <= p_beats - 1'b1;
                if (p_last) begin
                    p_data     <= 1'b0;
                    c_rec_done <= c_rec_done + 1'b1;
                    if (p_skip) c_skip <= c_skip + 1'b1;
                end
            end
        end
    end

    // ---- scheduler ----
    due <= (s_state == S_WAIT) && (r_mode == M_B2B || tb_now >= target_m);
    case (s_state)
    S_IDLE: begin
        if (gstate == G_RUN) begin
            if (m_valid) begin
                cur_ts  <= m_dout[63:0];
                cur_len <= m_dout[78:64];
                cur_bad <= m_dout[79];
                mul_a   <= (first || m_dout[63:0] < ts_first) ? 80'd0 :
                           {16'd0, m_dout[63:0] - ts_first};
                mul_b   <= r_rate_inv;
                mul_acc <= '0;
                if (first) ts_first <= m_dout[63:0];
                s_state <= S_CALC;
            end else begin
                starved <= 1'b1;
                if (p_data && !p_skip) starve_mid <= 1'b1;
            end
        end
    end
    S_CALC: begin
        // TIMED: shift-add multiply (delta * RATE_INV), one bit of RATE_INV per cycle
        if (r_mode == M_TIMED && mul_b != 32'd0) begin
            if (mul_b[0]) mul_acc <= mul_acc + mul_a;
            mul_a <= mul_a << 1;
            mul_b <= mul_b >> 1;
        end else begin
            case (r_mode)
                M_TIMED: target <= t0 + mul_acc[79:16];
                M_FIXED: target <= first ? t0 : target + {32'd0, r_gap};
                default: target <= '0;
            endcase
            s_state <= S_LOAD;
        end
    end
    S_LOAD: begin
        target_m <= target - {56'd0, tb_inc_ns};
        if (d_valid) begin
            word    <= d_dout;
            widx    <= '0;
            left    <= cur_len;
            // underrun: the store was empty while waiting for this frame
            if (starved && ((r_mode != M_B2B && tb_now >= target) ||
                            (r_mode == M_B2B && !first && (r_expect != 64'd0 || starve_mid)))) begin
                c_under     <= c_under + 1'b1;
                st_underrun <= 1'b1;
            end
            starved    <= 1'b0;
            starve_mid <= 1'b0;
            first      <= 1'b0;
            s_state    <= S_WAIT;
        end
    end
    S_WAIT: begin
        if (out_hs) begin
            lat_v   <= (r_mode != M_B2B);
            lat_raw <= tb_now - target;
            s_state <= S_SEND;
        end
    end
    default: ;     // S_SEND below
    endcase

    if (out_hs) begin
        left <= left - 15'd2;
        widx <= widx + 1'b1;
        if (need_beat) word <= d_dout;
        if (out_last) begin
            c_frames <= c_frames + 1'b1;
            c_bytes  <= c_bytes + cur_len;
            if (m_rpl_tuser) c_bad <= c_bad + 1'b1;
            s_state  <= S_IDLE;
        end else if (s_state == S_WAIT) begin
            s_state  <= S_SEND;
        end
    end

    // ---- lateness statistics (one cycle after the release) ----
    if (lat_v) begin
        logic [31:0] l32;
        l32 = (lat_raw[63:32] != 32'd0) ? 32'hFFFF_FFFF : lat_raw[31:0];
        last_late  <= l32;
        if (l32 > max_late) max_late <= l32;
        c_late_sum <= c_late_sum + lat_raw;
        if (l32 > r_late_thresh) begin
            c_late  <= c_late + 1'b1;
            st_late <= 1'b1;
        end
    end

    // ---- global state ----
    case (gstate)
    G_IDLE, G_DONE: begin
        if (cmd_arm) begin
            gstate      <= G_ARMED;
            stop_req    <= 1'b0;
            first       <= 1'b1;
            starved     <= 1'b0;
            starve_mid  <= 1'b0;
            p_data      <= 1'b0;
            p_resync    <= 1'b0;
            st_underrun <= 1'b0;
            st_perr     <= 1'b0;
            st_late     <= 1'b0;
            max_late    <= '0;
            last_late   <= '0;
            {c_records, c_frames, c_bytes, c_perr, c_fill, c_skip, c_under, c_late, c_late_sum,
             c_beats, c_discard, c_bad, c_rec_done} <= '0;
            store_rst   <= 1'b1;
        end
    end
    G_ARMED: begin
        if (cmd_go) begin
            t0        <= tb_now + {32'd0, r_start_delay};
            tx_port_q <= r_tx_port;
            gstate    <= G_RUN;
        end
    end
    G_RUN: begin
        if ((r_expect != 64'd0 && c_rec_done == r_expect && !m_valid && sched_idle && m_level == 0) ||
            (stop_req && in_idle && !p_data && !m_valid && m_level == 0 && d_level == 0 && sched_idle))
            gstate <= G_DONE;
    end
    G_ABORT: begin
        if (sched_idle && m_level == 0 && d_level == 0) begin
            gstate <= G_IDLE;
            p_data <= 1'b0;
        end
    end
    default: gstate <= G_IDLE;
    endcase
    if (cmd_stop && (gstate == G_ARMED || gstate == G_RUN))
        stop_req <= 1'b1;
    if (cmd_abort && gstate != G_IDLE) begin
        gstate <= G_ABORT;
        p_data <= 1'b0;
        if (s_state != S_SEND && !(s_state == S_WAIT && out_hs))
            s_state <= S_IDLE;                      // a frame on the wire is completed
    end

    if (rst) begin
        gstate     <= G_IDLE;
        s_state    <= S_IDLE;
        p_data     <= 1'b0;
        p_resync   <= 1'b0;
        stop_req   <= 1'b0;
        first      <= 1'b1;
        starved    <= 1'b0;
        starve_mid <= 1'b0;
        idle_cnt   <= '0;
        {c_records, c_frames, c_bytes, c_perr, c_fill, c_skip, c_under, c_late, c_late_sum,
         c_beats, c_discard, c_bad, c_rec_done} <= '0;
        max_late   <= '0;
        last_late  <= '0;
        st_underrun <= 1'b0;
        st_perr    <= 1'b0;
        st_late    <= 1'b0;
    end
end

// ===========================================================================
// AXI4-Lite (dp_clk)
// ===========================================================================
assign s_axi_bresp = 2'b00;
assign s_axi_rresp = 2'b00;
logic [31:0] hi_lat = '0;

wire [31:0] status = {17'd0, m_valid, !sched_idle, in_idle, eff_s[r_tx_port], st_late, st_perr,
                      st_underrun, 4'd0, stop_req, gstate};

function automatic [63:0] cnt64(input [3:0] idx);
    case (idx)
        4'd0:  cnt64 = c_records;
        4'd1:  cnt64 = c_frames;
        4'd2:  cnt64 = c_bytes;
        4'd3:  cnt64 = c_perr;
        4'd4:  cnt64 = c_fill;
        4'd5:  cnt64 = c_skip;
        4'd6:  cnt64 = c_under;
        4'd7:  cnt64 = c_late;
        4'd8:  cnt64 = c_late_sum;
        4'd9:  cnt64 = c_beats;
        4'd10: cnt64 = c_discard;
        4'd11: cnt64 = c_bad;
        4'd12: cnt64 = c_rec_done;
        default: cnt64 = 64'd0;
    endcase
endfunction

always_ff @(posedge clk) begin
    s_axi_awready <= 1'b0;
    s_axi_wready  <= 1'b0;
    s_axi_arready <= 1'b0;
    cmd_arm   <= 1'b0;
    cmd_go    <= 1'b0;
    cmd_stop  <= 1'b0;
    cmd_abort <= 1'b0;
    if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
    if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;

    if (s_axi_awvalid && s_axi_wvalid && !s_axi_awready && !s_axi_bvalid) begin
        s_axi_awready <= 1'b1;
        s_axi_wready  <= 1'b1;
        s_axi_bvalid  <= 1'b1;
        case (s_axi_awaddr[11:2])
            10'h002: begin
                r_sel       <= s_axi_wdata[0];
                r_mode      <= s_axi_wdata[2:1];
                r_bad_mode  <= s_axi_wdata[5:4];
                r_filt_en   <= s_axi_wdata[6];
                r_filt_port <= s_axi_wdata[9:8];
                r_tx_port   <= s_axi_wdata[13:12];
            end
            10'h003: begin
                cmd_arm   <= s_axi_wdata[0];
                cmd_go    <= s_axi_wdata[1];
                cmd_stop  <= s_axi_wdata[2];
                cmd_abort <= s_axi_wdata[3];
            end
            10'h005: r_rate_inv    <= s_axi_wdata;
            10'h006: r_start_delay <= s_axi_wdata;
            10'h007: r_late_thresh <= s_axi_wdata;
            10'h008: r_gap         <= s_axi_wdata;
            10'h009: r_expect[31:0]  <= s_axi_wdata;
            10'h00A: r_expect[63:32] <= s_axi_wdata;
            default: ;
        endcase
    end

    if (s_axi_arvalid && !s_axi_arready && !s_axi_rvalid) begin
        s_axi_arready <= 1'b1;
        s_axi_rvalid  <= 1'b1;
        s_axi_rdata   <= 32'd0;
        if (s_axi_araddr[11:8] == 4'h0 && s_axi_araddr[7] && s_axi_araddr[6:3] <= 4'd12) begin
            // 0x080 + 8 * k: 64-bit counters, LO latches HI
            logic [63:0] v;
            v = cnt64(s_axi_araddr[6:3]);
            if (!s_axi_araddr[2]) begin
                s_axi_rdata <= v[31:0];
                hi_lat      <= v[63:32];
            end else begin
                s_axi_rdata <= hi_lat;
            end
        end else begin
            case (s_axi_araddr[11:2])
                10'h000: s_axi_rdata <= REG_ID;
                10'h001: s_axi_rdata <= REG_VERSION;
                10'h002: s_axi_rdata <= {18'd0, r_tx_port, 2'd0, r_filt_port, 1'b0, r_filt_en,
                                         r_bad_mode, 1'b0, r_mode, r_sel};
                10'h004: s_axi_rdata <= status;
                10'h005: s_axi_rdata <= r_rate_inv;
                10'h006: s_axi_rdata <= r_start_delay;
                10'h007: s_axi_rdata <= r_late_thresh;
                10'h008: s_axi_rdata <= r_gap;
                10'h009: s_axi_rdata <= r_expect[31:0];
                10'h00A: s_axi_rdata <= r_expect[63:32];
                10'h00B: s_axi_rdata <= {16'(m_level), 16'(d_level)};
                10'h00C: s_axi_rdata <= STORE_BEATS;
                10'h00D: s_axi_rdata <= MAX_CAP;
                10'h00E: s_axi_rdata <= t0[31:0];
                10'h00F: s_axi_rdata <= t0[63:32];
                10'h010: s_axi_rdata <= ts_first[31:0];
                10'h011: s_axi_rdata <= ts_first[63:32];
                10'h012: s_axi_rdata <= target[31:0];
                10'h013: s_axi_rdata <= target[63:32];
                10'h014: s_axi_rdata <= max_late;
                10'h015: s_axi_rdata <= last_late;
                default: ;
            endcase
        end
    end

    if (rst) begin
        s_axi_awready <= 1'b0;
        s_axi_wready  <= 1'b0;
        s_axi_bvalid  <= 1'b0;
        s_axi_arready <= 1'b0;
        s_axi_rvalid  <= 1'b0;
        r_sel         <= 1'b0;
        r_mode        <= M_TIMED;
        r_bad_mode    <= 2'd0;
        r_filt_en     <= 1'b0;
        r_filt_port   <= 2'd0;
        r_tx_port     <= 2'd0;
        r_rate_inv    <= 32'h0001_0000;
        r_start_delay <= 32'd1_000_000;
        r_late_thresh <= 32'd100;
        r_gap         <= 32'd672;
        r_expect      <= 64'd0;
    end
end

endmodule

`resetall
