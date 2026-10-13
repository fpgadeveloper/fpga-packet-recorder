// SPDX-License-Identifier: MIT
//
// pktrec_cap_port - capture front end of ONE Ethernet port (record format v1,
// include/pktrec_format.h). Instantiated four times by pktrec_capture_core.
//
// rx_clk domain (MAC RX stream: 16-bit beats, tkeep 11 or 01 on the last beat,
// tuser bad flag at tlast, NO back-pressure):
//   * a frame is captured if the port is enabled (cap_en) when its FIRST beat
//     arrives; frames already in progress when cap_en changes are completed or
//     ignored whole, never cut
//   * every frame that starts while enabled gets the next 16-bit seq number --
//     also frames that are then dropped, so a seq gap = hardware drops
//   * snaplen truncation (0 = off): beats beyond SNAPLEN bytes are not stored
//   * one-beat hold-back register, so the last STORED beat can carry tlast even
//     when the frame was truncated
//   * frame data -> Taxi taxi_axis_async_fifo_adapter: 16 -> 128-bit upsizer +
//     async FRAME FIFO (FIFO_BYTES, block RAM) in DROP_WHEN_FULL mode: a frame
//     that does not fit is dropped WHOLE (and frames larger than the FIFO)
//   * the frame's metadata (MAC timestamp = timebase cycle count, cap_len, orig_len = wire
//     length incl. the FCS the MAC stripped, flags, seq) waits in a small
//     pending queue until the FIFO reports the frame committed (status strobe
//     good_frame) or dropped (overflow); committed metadata goes into an async
//     metadata FIFO (xpm_fifo_async), so header and data stay paired. A frame
//     is also dropped (whole, counted) if the metadata FIFO has no room when it
//     starts.
//   * counters (FRAMES_RX/BAD/DROP, BYTES_RX/DROP, FRAMES_TRUNC), seq and the
//     "receiving a captured frame" flag go to dp_clk as ONE coherent snapshot
//     (xpm_cdc_handshake, continuously refreshed)
//
// dp_clk domain (record reader):
//   * pops one metadata entry, builds the 16-byte header (64-bit timestamp =
//     tb_ns - (tb_cyc - cyc_frame) * tb_inc + mac_offset, see pktrec_timebase;
//     the product is computed by a shift-add loop, 1 cycle per significant bit
//     of the cycle difference), then passes ceil(cap_len / 16) data beats from the frame
//     FIFO (unused bytes of the last beat zeroed). m_tlast marks the record end.
//   * the record framing never depends on the FIFO alone: if the FIFO frame is
//     shorter than cap_len (or its data was lost to a port reset) the record is
//     zero-filled to its announced length, if longer the excess is discarded;
//     either case counts a LEN_FIXUP (expected never to happen).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_cap_port #(
    parameter int        PORT       = 0,
    parameter int        FIFO_BYTES = 16384,   // frame FIFO, bytes (power of 2)
    parameter int        META_DEPTH = 512      // metadata FIFO entries
)(
    // ---- rx_clk domain ----
    input  wire logic         rx_clk,
    input  wire logic         rx_rst,          // active high, synchronous to rx_clk
    input  wire logic [15:0]  rx_tdata,
    input  wire logic [1:0]   rx_tkeep,
    input  wire logic         rx_tvalid,
    input  wire logic         rx_tlast,
    input  wire logic         rx_tbad,         // tuser[0], valid with tlast
    input  wire logic [31:0]  rx_ts_cyc,       // tuser[32:1]: timebase cycle count latched by the MAC at SFD

    // ---- dp_clk domain ----
    input  wire logic         dp_clk,
    input  wire logic         dp_rst,          // active high, synchronous to dp_clk
    input  wire logic         cap_en,          // CTRL.ENABLE & PORT_EN[n]
    input  wire logic [15:0]  snaplen,         // quasi-static (change while disabled)
    input  wire logic         clear,           // 1-cycle pulse: clear counters, seq, HWM
    input  wire logic [63:0]  tb_ns,           // shared timebase, now
    input  wire logic [31:0]  tb_cyc,          // timebase cycle counter, now
    input  wire logic [39:0]  tb_inc,          // ns per cycle, 8.32
    input  wire logic [31:0]  mac_offset,      // signed ns added to MAC timestamps

    output wire logic [127:0] m_tdata,         // record stream (header, data)
    output wire logic         m_tvalid,
    input  wire logic         m_tready,
    output wire logic         m_tlast,         // last beat of a record

    output logic      [63:0]  st_frames_rx,
    output logic      [63:0]  st_frames_bad,
    output logic      [63:0]  st_frames_drop,
    output logic      [63:0]  st_bytes_rx,
    output logic      [63:0]  st_bytes_drop,
    output logic      [63:0]  st_frames_trunc,
    output logic      [15:0]  st_seq_next,
    output logic              st_rx_active,
    output logic      [63:0]  st_records,
    output logic      [31:0]  st_fifo_hwm,     // bytes
    input  wire logic         hwm_clr,
    output logic              idle,
    output logic              len_fixup        // 1-cycle pulse
);

localparam int CL_FIFO = $clog2(FIFO_BYTES);
localparam int META_W  = 32 + 16 + 16 + 1 + 1 + 16;   // ts cycle, cap_len, orig_len, bad, trunc, seq
localparam [7:0] PORT_ID = 8'(PORT);

// ===========================================================================
// CDC: control into rx_clk, resets between the domains
// ===========================================================================
wire       rx_en;
wire [15:0] rx_snaplen;
wire       rx_clear;
wire       dp_rst_rx;      // dp_rst, synchronised into rx_clk
wire       rx_rst_dp;      // rx_rst, synchronised into dp_clk

xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(1))
cdc_en (.src_clk(dp_clk), .src_in(cap_en), .dest_clk(rx_clk), .dest_out(rx_en));

xpm_cdc_array_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(1), .WIDTH(16))
cdc_snap (.src_clk(dp_clk), .src_in(snaplen), .dest_clk(rx_clk), .dest_out(rx_snaplen));

xpm_cdc_pulse #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .REG_OUTPUT(1), .RST_USED(0), .SIM_ASSERT_CHK(0))
cdc_clr (.src_clk(dp_clk), .src_pulse(clear), .src_rst(1'b0), .dest_clk(rx_clk), .dest_rst(1'b0),
         .dest_pulse(rx_clear));

xpm_cdc_sync_rst #(.DEST_SYNC_FF(3), .INIT(1), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0))
cdc_dprst (.src_rst(dp_rst), .dest_clk(rx_clk), .dest_rst(dp_rst_rx));

xpm_cdc_sync_rst #(.DEST_SYNC_FF(3), .INIT(1), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0))
cdc_rxrst (.src_rst(rx_rst), .dest_clk(dp_clk), .dest_rst(rx_rst_dp));

wire rx_srst = rx_rst | dp_rst_rx;     // front end, FIFOs (write side)

// ===========================================================================
// rx_clk domain: frame assembler
// ===========================================================================
logic        in_frame = 1'b0;   // a frame is in progress (any)
logic        counted  = 1'b0;   // ... and it started while enabled
logic        storing  = 1'b0;   // ... and it is being written to the FIFO
logic [16:0] nbytes   = '0;     // bytes of the frame so far (saturating)
logic [15:0] ncap     = '0;     // bytes stored so far
logic [31:0] ts_q     = '0;
logic [15:0] seq_q    = '0;     // seq of the current frame
logic [15:0] seq_next = '0;
logic [15:0] snap_q   = '0;     // snaplen latched at frame start (0 = off)

// hold-back register and FIFO write port
logic [15:0] h_data  = '0;
logic [1:0]  h_keep  = '0;
logic        h_valid = 1'b0;
logic        flush   = 1'b0;    // write the held beat as the last beat next cycle
logic        bad_q   = 1'b0;
logic [15:0] w_data  = '0;
logic [1:0]  w_keep  = '0;
logic        w_valid = 1'b0, w_last = 1'b0, w_user = 1'b0;

// pending metadata queue (written at the frame end, popped by the FIFO status)
localparam int PQ = 4;
logic [META_W-1:0] pq_data [PQ];
logic [16:0]       pq_orig [PQ];   // orig_len (17 bits) for the drop byte counter
logic [1:0]        pq_wp  = '0, pq_rp = '0;
logic [2:0]        pq_cnt = '0;

// counters
logic [63:0] c_frames_rx = '0, c_frames_bad = '0, c_frames_drop = '0;
logic [63:0] c_bytes_rx = '0, c_bytes_drop = '0, c_frames_trunc = '0;

// metadata FIFO write side
logic              meta_wr  = 1'b0;
logic [META_W-1:0] meta_din = '0;
wire               meta_prog_full;
wire               meta_wr_busy;

// data FIFO status (rx_clk)
wire fifo_good, fifo_drop;

// room for one more frame's metadata: checked when a frame starts
wire meta_room = !meta_prog_full && !meta_wr_busy && (pq_cnt < 3'(PQ - 1));

// ---- per-beat next-state values ----
wire        first     = !in_frame;
wire        cnt_now   = first ? rx_en : counted;
wire        store_now = first ? (rx_en && meta_room) : storing;
wire [15:0] snap_cur  = first ? rx_snaplen : snap_q;
wire [1:0]  kb        = (rx_tkeep == 2'b11) ? 2'd2 : (rx_tkeep == 2'b00) ? 2'd0 : 2'd1;
wire [16:0] nb_base   = first ? 17'd0 : nbytes;
wire [16:0] nb_new    = (nb_base > 17'h1FFFD) ? 17'h1FFFF : nb_base + 17'(kb);
wire [15:0] ncap_base = first ? 16'd0 : ncap;
wire [16:0] limit     = (snap_cur == 16'd0) ? 17'h1FFFF : 17'(snap_cur);
wire [16:0] room      = limit - 17'(ncap_base);
wire [1:0]  take      = (17'(kb) <= room) ? kb : 2'(room);
wire [15:0] ncap_new  = ncap_base + 16'(take);
wire [16:0] orig      = (nb_new > 17'h1FFFB) ? 17'h1FFFF : nb_new + 17'd4;
wire        trunc     = (17'(ncap_new) < nb_new);
wire        fr_end    = rx_tvalid && rx_tlast;
wire        push      = fr_end && store_now;
wire        pop_good  = fifo_good && pq_cnt != 0;
wire        pop_drop  = fifo_drop && pq_cnt != 0;

always_ff @(posedge rx_clk) begin
    w_valid <= 1'b0;
    meta_wr <= 1'b0;

    // ---- flush the held beat as the frame's last beat ----
    if (flush) begin
        w_valid <= 1'b1;
        w_data  <= h_data;
        w_keep  <= h_keep;
        w_last  <= 1'b1;
        w_user  <= bad_q;
        h_valid <= 1'b0;
        flush   <= 1'b0;
    end

    // ---- incoming beat ----
    if (rx_tvalid) begin
        if (first) begin
            counted <= rx_en;
            storing <= rx_en && meta_room;
            ts_q    <= rx_ts_cyc;
            seq_q   <= seq_next;
            snap_q  <= rx_snaplen;
        end
        in_frame <= !rx_tlast;
        nbytes   <= nb_new;
        ncap     <= ncap_new;

        if (store_now && take != 2'd0) begin
            // the new beat goes into the hold register; the previous one is
            // written (unless it is being flushed this cycle)
            if (h_valid && !flush) begin
                w_valid <= 1'b1;
                w_data  <= h_data;
                w_keep  <= h_keep;
                w_last  <= 1'b0;
                w_user  <= 1'b0;
            end
            h_data  <= (take == 2'd2) ? rx_tdata : {8'h00, rx_tdata[7:0]};
            h_keep  <= (take == 2'd2) ? 2'b11 : 2'b01;
            h_valid <= 1'b1;
        end

        if (rx_tlast && store_now) begin
            flush <= 1'b1;
            bad_q <= rx_tbad;
        end
    end

    // ---- seq: every frame that starts while enabled ----
    if (rx_tvalid && first && rx_en)
        seq_next <= seq_next + 16'd1;

    // ---- counters ----
    if (fr_end && cnt_now) begin
        c_frames_rx <= c_frames_rx + 64'd1;
        c_bytes_rx  <= c_bytes_rx + 64'(orig);
        if (rx_tbad) c_frames_bad <= c_frames_bad + 64'd1;
    end
    if (push && trunc)
        c_frames_trunc <= c_frames_trunc + 64'd1;
    // drops: at the frame end (no metadata room at its start) and/or a FIFO
    // drop strobe (at most one of each per cycle)
    case ({fr_end && cnt_now && !store_now, pop_drop})
        2'b10: begin
            c_frames_drop <= c_frames_drop + 64'd1;
            c_bytes_drop  <= c_bytes_drop + 64'(orig);
        end
        2'b01: begin
            c_frames_drop <= c_frames_drop + 64'd1;
            c_bytes_drop  <= c_bytes_drop + 64'(pq_orig[pq_rp]);
        end
        2'b11: begin
            c_frames_drop <= c_frames_drop + 64'd2;
            c_bytes_drop  <= c_bytes_drop + 64'(orig) + 64'(pq_orig[pq_rp]);
        end
        default: ;
    endcase

    // ---- pending metadata: push at the frame end, pop on the FIFO status ----
    if (pop_good) begin
        meta_wr  <= 1'b1;
        meta_din <= pq_data[pq_rp];
    end
    if (push) begin
        pq_data[pq_wp] <= {(first ? rx_ts_cyc : ts_q),
                           ncap_new,
                           (orig > 17'hFFFF) ? 16'hFFFF : 16'(orig),
                           rx_tbad, trunc,
                           (first ? seq_next : seq_q)};
        pq_orig[pq_wp] <= orig;
        pq_wp <= pq_wp + 2'd1;
    end
    if (pop_good || pop_drop) pq_rp <= pq_rp + 2'd1;
    pq_cnt <= pq_cnt + 3'(push) - 3'(pop_good || pop_drop);

    if (rx_clear) begin
        c_frames_rx <= '0; c_frames_bad <= '0; c_frames_drop <= '0;
        c_bytes_rx <= '0; c_bytes_drop <= '0; c_frames_trunc <= '0;
        seq_next <= '0;
    end

    if (rx_srst) begin
        in_frame <= 1'b0;
        counted  <= 1'b0;
        storing  <= 1'b0;
        h_valid  <= 1'b0;
        flush    <= 1'b0;
        w_valid  <= 1'b0;
        meta_wr  <= 1'b0;
        pq_wp    <= '0;
        pq_rp    <= '0;
        pq_cnt   <= '0;
    end
end

wire rx_active = in_frame & counted;

// ===========================================================================
// Data FIFO: 16 -> 128-bit upsizer + async frame FIFO (Taxi)
// ===========================================================================
taxi_axis_if #(.DATA_W(16),  .KEEP_W(2),  .USER_EN(1), .USER_W(1)) fifo_s();
taxi_axis_if #(.DATA_W(128), .KEEP_W(16), .USER_EN(1), .USER_W(1)) fifo_m();

assign fifo_s.tdata  = w_data;
assign fifo_s.tkeep  = w_keep;
assign fifo_s.tstrb  = w_keep;
assign fifo_s.tvalid = w_valid;
assign fifo_s.tlast  = w_last;
assign fifo_s.tuser  = w_user;
assign fifo_s.tid    = '0;
assign fifo_s.tdest  = '0;

wire [CL_FIFO:0] fifo_depth_m;
logic            d_ready;

assign fifo_m.tready = d_ready;

wire dp_fifo_rst = dp_rst | rx_rst_dp;

taxi_axis_async_fifo_adapter #(
    .DEPTH(FIFO_BYTES),
    .RAM_PIPELINE(2),
    .FRAME_FIFO(1'b1),
    .USER_BAD_FRAME_VALUE(1'b1),
    .USER_BAD_FRAME_MASK(1'b1),
    .DROP_OVERSIZE_FRAME(1'b1),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b1)
) data_fifo (
    .s_clk(rx_clk),
    .s_rst(rx_srst),
    .s_axis(fifo_s),
    .m_clk(dp_clk),
    .m_rst(dp_fifo_rst),
    .m_axis(fifo_m),
    .s_pause_req(1'b0),
    .s_pause_ack(),
    .m_pause_req(1'b0),
    .m_pause_ack(),
    .s_status_depth(),
    .s_status_depth_commit(),
    .s_status_overflow(fifo_drop),
    .s_status_bad_frame(),
    .s_status_good_frame(fifo_good),
    .m_status_depth(fifo_depth_m),
    .m_status_depth_commit(),
    .m_status_overflow(),
    .m_status_bad_frame(),
    .m_status_good_frame()
);

// ===========================================================================
// Metadata FIFO (rx_clk -> dp_clk, FWFT)
// ===========================================================================
wire [META_W-1:0] meta_dout;
wire              meta_empty;
wire              meta_rd_busy;
logic             meta_rd;

xpm_fifo_async #(
    .FIFO_MEMORY_TYPE    ("block"),
    .FIFO_WRITE_DEPTH    (META_DEPTH),
    .WRITE_DATA_WIDTH    (META_W),
    .READ_DATA_WIDTH     (META_W),
    .READ_MODE           ("fwft"),
    .FIFO_READ_LATENCY   (0),
    .CDC_SYNC_STAGES     (3),
    .RELATED_CLOCKS      (0),
    .ECC_MODE            ("no_ecc"),
    .FULL_RESET_VALUE    (1),
    .USE_ADV_FEATURES    ("0002"),          // prog_full
    .PROG_FULL_THRESH    (META_DEPTH - 16),
    .PROG_EMPTY_THRESH   (10),
    .RD_DATA_COUNT_WIDTH (1),
    .WR_DATA_COUNT_WIDTH (1),
    .DOUT_RESET_VALUE    ("0"),
    .WAKEUP_TIME         (0),
    .SIM_ASSERT_CHK      (0)
) meta_fifo (
    .rst           (rx_srst),
    .wr_clk        (rx_clk),
    .wr_en         (meta_wr && !meta_wr_busy),
    .din           (meta_din),
    .full          (),
    .prog_full     (meta_prog_full),
    .wr_rst_busy   (meta_wr_busy),
    .rd_clk        (dp_clk),
    .rd_en         (meta_rd),
    .dout          (meta_dout),
    .empty         (meta_empty),
    .rd_rst_busy   (meta_rd_busy),
    .sleep         (1'b0),
    .injectsbiterr (1'b0),
    .injectdbiterr (1'b0),
    .overflow      (),
    .wr_data_count (),
    .almost_full   (),
    .wr_ack        (),
    .underflow     (),
    .prog_empty    (),
    .rd_data_count (),
    .almost_empty  (),
    .data_valid    (),
    .sbiterr       (),
    .dbiterr       ()
);

// ===========================================================================
// Counter snapshot rx_clk -> dp_clk (coherent, continuously refreshed)
// ===========================================================================
localparam int SNAP_W = 6 * 64 + 16 + 1;
logic              snap_send = 1'b0;
logic [SNAP_W-1:0] snap_hold = '0;
wire               snap_rcv;
wire               snap_req;
wire  [SNAP_W-1:0] snap_out;

always_ff @(posedge rx_clk) begin
    if (!snap_send && !snap_rcv) begin
        snap_hold <= {rx_active, seq_next, c_frames_trunc, c_bytes_drop, c_bytes_rx,
                      c_frames_drop, c_frames_bad, c_frames_rx};
        snap_send <= 1'b1;
    end else if (snap_send && snap_rcv) begin
        snap_send <= 1'b0;
    end
end

xpm_cdc_handshake #(.DEST_EXT_HSK(0), .DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0),
                    .SRC_SYNC_FF(3), .WIDTH(SNAP_W))
cdc_snapshot (.src_clk(rx_clk), .src_in(snap_hold), .src_send(snap_send), .src_rcv(snap_rcv),
              .dest_clk(dp_clk), .dest_req(snap_req), .dest_ack(1'b0), .dest_out(snap_out));

always_ff @(posedge dp_clk) begin
    if (snap_req)
        {st_rx_active, st_seq_next, st_frames_trunc, st_bytes_drop, st_bytes_rx,
         st_frames_drop, st_frames_bad, st_frames_rx} <= snap_out;
    if (dp_rst) begin
        {st_rx_active, st_seq_next, st_frames_trunc, st_bytes_drop, st_bytes_rx,
         st_frames_drop, st_frames_bad, st_frames_rx} <= '0;
    end
end

// ===========================================================================
// dp_clk domain: record reader
// ===========================================================================
typedef enum logic [3:0] { S_IDLE, S_EXT, S_MUL, S_MK, S_HDR, S_DATA, S_PAD, S_DISC } state_t;
state_t       st = S_IDLE;
logic [12:0]  beats_left = '0;   // data beats still to send for this record
logic [127:0] hdr = '0;
logic [META_W-1:0] md_q = '0;    // metadata of the record being built
logic [31:0]  dcyc = '0;         // cycles since the frame's SFD (shifted by the multiplier)
logic [71:0]  mcand = '0;        // tb_inc << k
logic [71:0]  prod = '0;         // dcyc * tb_inc (32.32 ns)
logic [63:0]  now_q = '0;

// output skid buffer (2 entries; registered ready towards the reader)
logic [128:0] sk_d0 = '0, sk_d1 = '0;     // {last, data}
logic         sk_v0 = 1'b0, sk_v1 = 1'b0;
wire          sk_in_ready = !sk_v1;
logic         sk_in_valid;
logic [128:0] sk_in;
wire          sk_in_fire = sk_in_valid && sk_in_ready;

assign m_tdata  = sk_d0[127:0];
assign m_tlast  = sk_d0[128];
assign m_tvalid = sk_v0;

always_ff @(posedge dp_clk) begin
    if (!sk_v0 || m_tready) begin
        // output register free (or freed this cycle)
        if (sk_v1) begin
            sk_d0 <= sk_d1;
            sk_v0 <= 1'b1;
            sk_v1 <= 1'b0;      // sk_in_ready was 0: nothing new this cycle
        end else begin
            sk_d0 <= sk_in;
            sk_v0 <= sk_in_fire;
        end
    end else if (sk_in_fire) begin
        sk_d1 <= sk_in;
        sk_v1 <= 1'b1;
    end
    if (dp_rst) begin
        sk_v0 <= 1'b0;
        sk_v1 <= 1'b0;
    end
end

// metadata fields (FIFO output / latched copy)
wire        md_valid = !meta_empty && !meta_rd_busy;
wire [31:0] mq_cyc   = md_q[META_W-1 -: 32];
// layout {cyc[81:50], cap_len[49:34], orig_len[33:18], bad[17], trunc[16], seq[15:0]}
wire [15:0] mq_cap   = md_q[34 +: 16];
wire [15:0] mq_orig  = md_q[18 +: 16];
wire        mq_bad   = md_q[17];
wire        mq_trunc = md_q[16];
wire [15:0] mq_seq   = md_q[15:0];

// byte mask of the data beat from tkeep
wire [127:0] keep_mask;
genvar gk;
for (gk = 0; gk < 16; gk = gk + 1) begin : g_keep
    assign keep_mask[8*gk +: 8] = {8{fifo_m.tkeep[gk]}};
end
wire [127:0] d_masked = fifo_m.tdata & keep_mask;

always_comb begin
    meta_rd     = 1'b0;
    d_ready     = 1'b0;
    sk_in_valid = 1'b0;
    sk_in       = {1'b0, hdr};
    case (st)
        S_IDLE: meta_rd = md_valid;                    // pop -> S_EXT
        S_HDR: begin
            sk_in_valid = 1'b1;
            sk_in       = {1'b0, hdr};
        end
        S_DATA: if (!rx_rst_dp) begin
            d_ready     = sk_in_ready;
            sk_in_valid = fifo_m.tvalid;
            sk_in       = {beats_left == 13'd1, d_masked};
        end
        S_PAD: begin
            sk_in_valid = 1'b1;
            sk_in       = {beats_left == 13'd1, 128'd0};
        end
        S_DISC: d_ready = 1'b1;
        default: ;
    endcase
end

always_ff @(posedge dp_clk) begin
    len_fixup <= 1'b0;
    case (st)
        S_IDLE: if (md_valid) begin
            md_q <= meta_dout;
            st   <= S_EXT;
        end
        S_EXT: begin
            // ts = now - (cyc_now - cyc_frame) * INC + mac_offset
            dcyc  <= tb_cyc - mq_cyc;
            now_q <= tb_ns;
            mcand <= 72'(tb_inc);
            prod  <= 72'h0_8000_0000;            // + 0.5 ns: round to nearest
            st    <= S_MUL;
        end
        S_MUL: begin
            if (dcyc[0]) prod <= prod + mcand;
            mcand <= mcand << 1;
            dcyc  <= dcyc >> 1;
            if (dcyc[31:1] == 31'd0) st <= S_MK;
        end
        S_MK: begin
            hdr <= {mq_seq,
                    {4'hA, 1'b0, 1'b1, mq_trunc, mq_bad},     // marker, SFD_MISMATCH=0, TS_MAC=1
                    PORT_ID, mq_orig, mq_cap,
                    now_q - prod[71:32] + {{32{mac_offset[31]}}, mac_offset}};
            beats_left <= 13'((17'(mq_cap) + 17'd15) >> 4);
            st <= S_HDR;
        end
        S_HDR: if (sk_in_ready) begin
            // cap_len >= 1 always; 0 would leave a FIFO frame behind: discard it
            st <= (beats_left == 13'd0) ? S_DISC : S_DATA;
        end
        S_DATA: begin
            if (rx_rst_dp) begin
                // the frame's data is gone with the FIFO reset: keep the
                // record framed with zero bytes
                st <= S_PAD;
                len_fixup <= 1'b1;
            end else if (sk_in_ready && fifo_m.tvalid) begin
                beats_left <= beats_left - 13'd1;
                if (beats_left == 13'd1) begin
                    if (fifo_m.tlast) st <= S_IDLE;
                    else begin st <= S_DISC; len_fixup <= 1'b1; end
                end else if (fifo_m.tlast) begin
                    st <= S_PAD; len_fixup <= 1'b1;
                end
            end
        end
        S_PAD: if (sk_in_ready) begin
            beats_left <= beats_left - 13'd1;
            if (beats_left == 13'd1) st <= S_IDLE;
        end
        S_DISC: if (rx_rst_dp || (fifo_m.tvalid && fifo_m.tlast)) st <= S_IDLE;
        default: st <= S_IDLE;
    endcase
    if (dp_rst) begin
        st <= S_IDLE;
        len_fixup <= 1'b0;
    end
end

// ===========================================================================
// dp_clk domain: records, FIFO high-water mark, idle
// ===========================================================================
always_ff @(posedge dp_clk) begin
    if (sk_v0 && m_tready && m_tlast) st_records <= st_records + 64'd1;
    if (hwm_clr || clear) st_fifo_hwm <= '0;
    else if (32'(fifo_depth_m) > st_fifo_hwm) st_fifo_hwm <= 32'(fifo_depth_m);
    if (clear) st_records <= '0;
    if (dp_rst) begin
        st_records  <= '0;
        st_fifo_hwm <= '0;
    end
end


always_ff @(posedge dp_clk) begin
    idle <= !st_rx_active && (st_frames_rx == st_records + st_frames_drop) &&
            st == S_IDLE && !md_valid && !sk_v0;
end

endmodule

`resetall
