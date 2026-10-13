// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_pktrec_tap -- self-checking testbench for the M3 TAP mode of pktrec_m0_path
//
// The pair P0/P1 is simulated with real Taxi 1000BASE-X frame transmitters and
// receivers (taxi_axis_basex_tx_16 / _rx_16, the MAC+PCS cores inside
// pktrec_eth_ports) on both sides of the DUT, wired at the 8b/10b-encoded level:
//
//   lane 0:  source (100 % utilisation, IFG 12) -> Taxi TX @ rx_clk_0 (far device's
//            clock) -> [bit-error injector] -> Taxi RX @ rx_clk_0 (our P0 MAC)
//            -> pktrec_m0_path FWD FIFO -> Taxi TX @ tx_clk_1 (our P1 MAC, IFG from
//            the DUT's dynamic IFG output) -> Taxi RX @ tx_clk_1 (device on P1)
//            -> checker
//   lane 1:  the same from P1 to P0
//
// Frames carry {seq[31:0], lane, pattern}; the checker verifies content, length,
// error flag, order (strictly increasing seq per source lane) and counts gaps.
// The far device's clock is varied to model a partner that is faster than our
// local TX clock (QPLL). P2/P3 are not used (clocks stopped).
//
// Tests:
//   1. Registers: VERSION 1.3, IFG_CTRL / IFG_THRESH reset values, PAIR_MODE RW,
//      EFF_PATH follows PATH_CTRL.
//   2. Bad-frame forwarding: frames sent error-terminated (TX tuser -> /V/ over the
//      FCS) and frames with a bit error on the line (bad FCS) arrive at P0/P1, are
//      forwarded with the bad flag, and leave the partner port error-terminated: the
//      far receiver flags exactly those frames bad; RX_BAD and TX_GOOD counters match.
//      Observed (and checked exactly): a Taxi receiver that meets /V/ in place of the
//      FCS ends the frame 6 bytes early (the bytes it held back as FCS candidates), so
//      a frame sent error-terminated arrives at the far end 12 bytes short (two /V/
//      hops), a line-corrupted frame 6 bytes short (one); the bytes that do arrive
//      are intact (except the flipped one).
//   3. Dynamic IFG at 1514-byte frames (the worst case: 4 bytes of catch-up per
//      1538 bytes = 2600 ppm), source +2000 ppm, 1200 frames: the reduced gap starts
//      only when the FWD fill exceeds IFG_HI and ends only when it falls below
//      IFG_LO, and cycles at least twice; between frames the wire carries 12-byte
//      gaps normally and 8-byte gaps while reduced (nothing else); no frame lost.
//   4. Clock mismatch at 100 % utilisation, 64-byte frames, source +4 %: a scaled
//      stand-in for +200 ppm over >= 1 s. What matters is the accumulated excess,
//      ppm x time: 1 s at +200 ppm = 200 us of wire time (25 KB); here 9000 frames x
//      25.9 ns = 233 us, a backlog of ~350 frames, more than the 16 KB FIFO holds
//      (~270 64-byte frames). With the dynamic IFG no frame is lost; with it disabled
//      (DYN_EN = 0) the FWD FIFO overflows, frames are dropped whole and counted
//      (DROP_FWD = frames missing at the far end).
//   5. Mode switching mid-traffic (both directions at 100 %): PATH_CTRL toggles
//      between FWD/FWD, IDLE/IDLE and LOOP/LOOP at random times. Every frame that
//      arrives is complete and intact, per-source order is kept, and every frame
//      committed to a FIFO is either delivered or counted in FLUSH (frames that
//      were in the FIFO when the port left that source) or DROP_*; nothing is lost
//      silently. After the last switch back to FWD, forwarding is lossless.
//   Store-and-forward latency (first /S/ on the far device's wire to first /S/
//   on our TX wire, MAC/PCS only, no GT/PHY) is printed per frame size.
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

package tb_tap_pkg;
  int unsigned len_of  [2][int unsigned];    // [lane][seq] payload length (no FCS)
  bit          bad_of  [2][int unsigned];    // sent error-terminated (TX tuser)
  bit          fcs_of  [2][int unsigned];    // bit error injected on the line
  realtime     sof_of  [2][int unsigned];    // time of the source /S/
endpackage

// -----------------------------------------------------------------------------
// One direction: far device (source) -> our RX MAC; our TX MAC -> far device
// (checker). LANE = source port.
// -----------------------------------------------------------------------------
module tb_tap_lane #(parameter int LANE = 0) (
  input  logic        src_clk,
  input  logic        src_rst,
  input  logic        dst_clk,
  input  logic        dst_rst,
  // to the DUT RX port LANE (src_clk)
  output logic [15:0] rx_tdata,
  output logic [1:0]  rx_tkeep,
  output logic        rx_tvalid,
  output logic        rx_tlast,
  output logic        rx_tbad,
  output logic        rx_stat_good,
  output logic        rx_stat_bad,
  // from the DUT TX port LANE^1 (dst_clk)
  input  logic [15:0] tx_tdata,
  input  logic [1:0]  tx_tkeep,
  input  logic        tx_tvalid,
  output logic        tx_tready,
  input  logic        tx_tlast,
  input  logic        tx_tuser,
  input  logic [7:0]  tx_ifg,
  output logic        tx_stat_good
);
  import tb_tap_pkg::*;

  // ---- configuration (written hierarchically by the test) ----
  int unsigned len = 60;          // payload bytes without FCS (60 = 64-byte frame)
  bit          en = 0;            // source on (100 % utilisation), no limit
  int unsigned quota = 0;         // or: send this many more frames (100 % utilisation)
  int unsigned bad_every = 0, bad_phase = 0;
  int unsigned fcs_every = 0, fcs_phase = 0;

  // ---- results ----
  int unsigned n_src = 0;                      // frames sent by the source
  int unsigned n_rx = 0, n_rx_bad = 0;         // frames at the far receiver
  int unsigned n_lost [2] = '{0, 0};           // seq gaps per source lane
  int unsigned n_err = 0;                      // content / length / flag / order errors
  int unsigned n_foreign = 0;                  // frames of the other lane (LOOP)
  longint      last_seq [2] = '{-1, -1};
  int unsigned n_fcs_inj = 0;
  int unsigned gap_hist [0:31];
  realtime     lat_min = 1e9, lat_max = 0;
  int unsigned n_lat = 0;

  initial for (int i = 0; i < 32; i++) gap_hist[i] = 0;

  function automatic byte unsigned fbyte(input int unsigned sq, input int b);
    if (b < 4) return 8'(sq >> (8 * (3 - b)));
    if (b == 4) return 8'(LANE);
    return 8'(sq + b);
  endfunction

  // ---------------------------------------------------------------------------
  // Source: AXI-Stream frames into the far device's Taxi TX, back to back
  // ---------------------------------------------------------------------------
  logic [15:0] s_tdata = '0;
  logic [1:0]  s_tkeep = '0;
  logic        s_tvalid = 1'b0, s_tlast = 1'b0, s_tbad = 1'b0;
  wire         s_tready;
  int unsigned seq = 0, beat = 0, nb = 0;
  bit          active = 0;

  always @(posedge src_clk) begin
    if (src_rst) begin
      s_tvalid <= 1'b0;
      beat = 0;
      active = 0;
    end else begin
      if (s_tvalid && s_tready) begin
        if (s_tlast) begin
          seq++; n_src++; beat = 0; active = 0;
        end else begin
          beat++;
        end
      end
      if (!active && (en || quota > 0)) begin
        if (!en) quota--;
        active = 1;
        len_of[LANE][seq] = len;
        bad_of[LANE][seq] = (bad_every != 0) && (seq % bad_every == bad_phase);
        fcs_of[LANE][seq] = (fcs_every != 0) && (seq % fcs_every == fcs_phase);
        nb = (len + 1) / 2;
      end
      if (active) begin
        s_tdata  <= {fbyte(seq, 2 * beat + 1), fbyte(seq, 2 * beat)};
        s_tkeep  <= (2 * beat + 1 < len) ? 2'b11 : 2'b01;
        s_tvalid <= 1'b1;
        s_tlast  <= (beat == nb - 1);
        s_tbad   <= (beat == nb - 1) && bad_of[LANE][seq];
      end else begin
        s_tvalid <= 1'b0;
        s_tlast  <= 1'b0;
        s_tbad   <= 1'b0;
      end
    end
  end

  taxi_axis_if #(.DATA_W(16), .KEEP_W(2), .USER_EN(1), .USER_W(2), .ID_EN(1), .ID_W(8)) src_if();
  taxi_axis_if #(.DATA_W(8), .KEEP_W(1)) src_cpl_if();
  assign src_if.tdata  = s_tdata;
  assign src_if.tkeep  = s_tkeep;
  assign src_if.tstrb  = s_tkeep;
  assign src_if.tvalid = s_tvalid;
  assign src_if.tlast  = s_tlast;
  assign src_if.tuser  = {1'b0, s_tbad};
  assign src_if.tid    = '0;
  assign src_if.tdest  = '0;
  assign s_tready      = src_if.tready;
  assign src_cpl_if.tready = 1'b1;

  wire [15:0] se_d;
  wire [1:0]  se_k;
  wire [1:0]  src_sop;

  taxi_axis_basex_tx_16 #(.SGMII_EN(1'b1), .PTP_TS_EN(1'b0), .PTP_TS_W(64)) src_tx (
    .clk(src_clk), .rst(src_rst),
    .s_axis_tx(src_if), .m_axis_tx_cpl(src_cpl_if),
    .encoded_tx_data(se_d), .encoded_tx_data_k(se_k), .encoded_tx_data_dm(), .encoded_tx_data_dv(),
    .encoded_tx_data_valid(), .tx_gbx_req_sync(1'b0), .tx_gbx_req_stall(1'b0), .tx_gbx_sync(),
    .tx_an_cfg(16'd0), .tx_an_cfg_valid(1'b0), .tx_an_cfg_ready(),
    .ptp_ts(64'd0),
    .cfg_tx_max_pkt_len(16'd2047), .cfg_tx_ifg(8'd12), .cfg_tx_enable(1'b1),
    .cfg_tx_sgmii_en(1'b1), .cfg_tx_sgmii_speed(2'b10),
    .tx_start_packet(src_sop), .stat_tx_byte(), .stat_tx_pkt_len(), .stat_tx_pkt_ucast(),
    .stat_tx_pkt_mcast(), .stat_tx_pkt_bcast(), .stat_tx_pkt_vlan(), .stat_tx_pkt_good(),
    .stat_tx_pkt_bad(), .stat_tx_err_oversize(), .stat_tx_err_user(), .stat_tx_err_underflow()
  );

  // time of each source frame start (frames leave in seq order)
  int unsigned src_sof_cnt = 0;
  always @(posedge src_clk) if (|src_sop) begin
    sof_of[LANE][src_sof_cnt] = $realtime;
    src_sof_cnt++;
  end

  // ---------------------------------------------------------------------------
  // Line bit-error injector: flips one data bit in encoded word 20 of the frames
  // marked fcs_of (=> the receiving MAC sees a bad FCS)
  // ---------------------------------------------------------------------------
  logic [15:0] ie_d = '0;
  logic [1:0]  ie_k = '0;
  int unsigned inj_sof = 0, inj_idx = 0, wpos = 0;
  always @(posedge src_clk) begin
    ie_d <= se_d;
    ie_k <= se_k;
    if ((se_k[0] && se_d[7:0] == 8'hFB) || (se_k[1] && se_d[15:8] == 8'hFB)) begin
      inj_idx = inj_sof; inj_sof++; wpos = 0;
    end else begin
      wpos++;
      if (wpos == 20 && se_k == 2'b00 && fcs_of[LANE].exists(inj_idx) && fcs_of[LANE][inj_idx]) begin
        ie_d <= se_d ^ 16'h0100;
        n_fcs_inj++;
      end
    end
  end

  // ---------------------------------------------------------------------------
  // Our RX MAC (port LANE) -> DUT
  // ---------------------------------------------------------------------------
  taxi_axis_if #(.DATA_W(16), .KEEP_W(2), .USER_EN(1), .USER_W(1)) rx_if();
  assign rx_if.tready = 1'b1;
  assign rx_tdata  = rx_if.tdata;
  assign rx_tkeep  = rx_if.tkeep;
  assign rx_tvalid = rx_if.tvalid;
  assign rx_tlast  = rx_if.tlast;
  assign rx_tbad   = rx_if.tuser[0];

  taxi_axis_basex_rx_16 #(.SGMII_EN(1'b1), .PTP_TS_EN(1'b0), .PTP_TS_W(64)) our_rx (
    .clk(src_clk), .rst(src_rst),
    .encoded_rx_data(ie_d), .encoded_rx_data_k(ie_k), .encoded_rx_data_valid(1'b1),
    .m_axis_rx(rx_if),
    .rx_an_cfg(), .rx_an_cfg_valid(), .rx_an_ability_match(), .rx_an_ack_match(), .rx_an_idle_match(),
    .ptp_ts(64'd0),
    .cfg_rx_max_pkt_len(16'd2047), .cfg_rx_enable(1'b1), .cfg_rx_sgmii_en(1'b1), .cfg_rx_sgmii_speed(2'b10),
    .rx_start_packet(), .stat_rx_byte(), .stat_rx_pkt_len(), .stat_rx_pkt_fragment(), .stat_rx_pkt_jabber(),
    .stat_rx_pkt_ucast(), .stat_rx_pkt_mcast(), .stat_rx_pkt_bcast(), .stat_rx_pkt_vlan(),
    .stat_rx_pkt_good(rx_stat_good), .stat_rx_pkt_bad(rx_stat_bad), .stat_rx_err_oversize(),
    .stat_rx_err_bad_fcs(), .stat_rx_err_bad_block(), .stat_rx_err_framing(), .stat_rx_err_preamble()
  );

  // ---------------------------------------------------------------------------
  // DUT -> our TX MAC (port LANE^1, gap from the DUT) -> far device's RX
  // ---------------------------------------------------------------------------
  taxi_axis_if #(.DATA_W(16), .KEEP_W(2), .USER_EN(1), .USER_W(2), .ID_EN(1), .ID_W(8)) tx_if();
  taxi_axis_if #(.DATA_W(8), .KEEP_W(1)) tx_cpl_if();
  assign tx_if.tdata  = tx_tdata;
  assign tx_if.tkeep  = tx_tkeep;
  assign tx_if.tstrb  = tx_tkeep;
  assign tx_if.tvalid = tx_tvalid;
  assign tx_if.tlast  = tx_tlast;
  assign tx_if.tuser  = {1'b0, tx_tuser};
  assign tx_if.tid    = '0;
  assign tx_if.tdest  = '0;
  assign tx_tready    = tx_if.tready;
  assign tx_cpl_if.tready = 1'b1;

  wire [15:0] te_d;
  wire [1:0]  te_k;
  wire [1:0]  dst_sop;

  taxi_axis_basex_tx_16 #(.SGMII_EN(1'b1), .PTP_TS_EN(1'b0), .PTP_TS_W(64)) our_tx (
    .clk(dst_clk), .rst(dst_rst),
    .s_axis_tx(tx_if), .m_axis_tx_cpl(tx_cpl_if),
    .encoded_tx_data(te_d), .encoded_tx_data_k(te_k), .encoded_tx_data_dm(), .encoded_tx_data_dv(),
    .encoded_tx_data_valid(), .tx_gbx_req_sync(1'b0), .tx_gbx_req_stall(1'b0), .tx_gbx_sync(),
    .tx_an_cfg(16'd0), .tx_an_cfg_valid(1'b0), .tx_an_cfg_ready(),
    .ptp_ts(64'd0),
    .cfg_tx_max_pkt_len(16'd2047), .cfg_tx_ifg(tx_ifg), .cfg_tx_enable(1'b1),
    .cfg_tx_sgmii_en(1'b1), .cfg_tx_sgmii_speed(2'b10),
    .tx_start_packet(dst_sop), .stat_tx_byte(), .stat_tx_pkt_len(), .stat_tx_pkt_ucast(),
    .stat_tx_pkt_mcast(), .stat_tx_pkt_bcast(), .stat_tx_pkt_vlan(), .stat_tx_pkt_good(tx_stat_good),
    .stat_tx_pkt_bad(), .stat_tx_err_oversize(), .stat_tx_err_user(), .stat_tx_err_underflow()
  );

  realtime dst_sof_q[$];
  always @(posedge dst_clk) if (|dst_sop) dst_sof_q.push_back($realtime);

  // wire gap (bytes from /T/ to before /S/) histogram
  bit g_in = 0;
  int unsigned g_cnt = 0;
  always @(posedge dst_clk) begin
    for (int l = 0; l < 2; l++) begin
      if (g_in) begin
        if (te_k[l] && te_d[8*l +: 8] == 8'hFD) begin g_in = 0; g_cnt = 1; end
      end else if (te_k[l] && te_d[8*l +: 8] == 8'hFB) begin
        g_in = 1;
        if (g_cnt > 0) gap_hist[(g_cnt > 31) ? 31 : g_cnt]++;
        g_cnt = 0;
      end else if (g_cnt > 0) begin
        g_cnt++;
      end
    end
  end

  taxi_axis_if #(.DATA_W(16), .KEEP_W(2), .USER_EN(1), .USER_W(1)) far_if();
  assign far_if.tready = 1'b1;

  taxi_axis_basex_rx_16 #(.SGMII_EN(1'b1), .PTP_TS_EN(1'b0), .PTP_TS_W(64)) far_rx (
    .clk(dst_clk), .rst(dst_rst),
    .encoded_rx_data(te_d), .encoded_rx_data_k(te_k), .encoded_rx_data_valid(1'b1),
    .m_axis_rx(far_if),
    .rx_an_cfg(), .rx_an_cfg_valid(), .rx_an_ability_match(), .rx_an_ack_match(), .rx_an_idle_match(),
    .ptp_ts(64'd0),
    .cfg_rx_max_pkt_len(16'd2047), .cfg_rx_enable(1'b1), .cfg_rx_sgmii_en(1'b1), .cfg_rx_sgmii_speed(2'b10),
    .rx_start_packet(), .stat_rx_byte(), .stat_rx_pkt_len(), .stat_rx_pkt_fragment(), .stat_rx_pkt_jabber(),
    .stat_rx_pkt_ucast(), .stat_rx_pkt_mcast(), .stat_rx_pkt_bcast(), .stat_rx_pkt_vlan(),
    .stat_rx_pkt_good(), .stat_rx_pkt_bad(), .stat_rx_err_oversize(),
    .stat_rx_err_bad_fcs(), .stat_rx_err_bad_block(), .stat_rx_err_framing(), .stat_rx_err_preamble()
  );

  // ---------------------------------------------------------------------------
  // Checker
  // ---------------------------------------------------------------------------
  byte unsigned got[$];
  always @(posedge dst_clk) begin
    if (far_if.tvalid) begin
      got.push_back(far_if.tdata[7:0]);
      if (far_if.tkeep[1]) got.push_back(far_if.tdata[15:8]);
      if (far_if.tlast) begin
        check(far_if.tuser[0]);
        got.delete();
      end
    end
  end

  function automatic void err(input string m);
    n_err++;
    if (n_err <= 10) $display("FAIL: lane %0d checker: %s (t=%0t)", LANE, m, $time);
  endfunction

  task automatic check(input bit bad);
    int unsigned sq, ln, exp_len;
    bit exp_bad;
    realtime lat;
    n_rx++;
    if (bad) n_rx_bad++;
    if (dst_sof_q.size() == 0) err("frame without TX start");
    lat = dst_sof_q.size() ? dst_sof_q.pop_front() : 0;
    if (got.size() < 5) begin err($sformatf("runt of %0d bytes", got.size())); return; end
    sq = {got[0], got[1], got[2], got[3]};
    ln = got[4];
    if (ln > 1) begin err($sformatf("bad lane id %0d", ln)); return; end
    if (ln != LANE) n_foreign++;
    if (!len_of[ln].exists(sq)) begin err($sformatf("unknown seq %0d of lane %0d", sq, ln)); return; end
    exp_len = len_of[ln][sq];
    exp_bad = bad_of[ln][sq] || fcs_of[ln][sq];
    // each receiver that meets /V/ over the FCS ends the frame 6 bytes early: sent
    // error-terminated = 2 such hops, bit error on the line = 1 (our TX)
    if (bad_of[ln][sq]) exp_len -= 12;
    else if (fcs_of[ln][sq]) exp_len -= 6;
    if (got.size() != exp_len) err($sformatf("seq %0d: %0d bytes, expected %0d", sq, got.size(), exp_len));
    if (bad != exp_bad) err($sformatf("seq %0d: bad flag %0d, expected %0d", sq, bad, exp_bad));
    for (int b = 5; b < got.size(); b++)
      if (got[b] != 8'(sq + b) && !(fcs_of[ln][sq] && b == 33)) begin
        err($sformatf("seq %0d: byte %0d corrupt", sq, b)); break;
      end
    if (longint'(sq) <= last_seq[ln]) err($sformatf("seq %0d after %0d (order)", sq, last_seq[ln]));
    else n_lost[ln] += sq - last_seq[ln] - 1;
    last_seq[ln] = sq;
    lat = lat - sof_of[ln][sq];
    if (lat < lat_min) lat_min = lat;
    if (lat > lat_max) lat_max = lat;
    n_lat++;
  endtask
endmodule

// -----------------------------------------------------------------------------
// Testbench top
// -----------------------------------------------------------------------------
module tb_pktrec_tap;
  import tb_tap_pkg::*;

  localparam [11:0] R_ID = 12'h000, R_VERSION = 12'h004, R_PATH_CTRL = 12'h008,
                    R_CNT_CTRL = 12'h00C, R_PAIR_MODE = 12'h018, R_EFF_PATH = 12'h01C;
  localparam [11:0] P_BASE = 12'h100, P_STRIDE = 12'h040;
  localparam [11:0] P_RX_GOOD = 12'h00, P_RX_BAD = 12'h04, P_TX_GOOD = 12'h08,
                    P_TX_UNF = 12'h0C, P_DROP_LOOP = 12'h10, P_DROP_FWD = 12'h14,
                    P_IFG_CTRL = 12'h20, P_IFG_THRESH = 12'h24, P_FWD_FILL = 12'h28,
                    P_IFG_STATUS = 12'h2C, P_RED_LO = 12'h30, P_RED_HI = 12'h34,
                    P_RED_ENT = 12'h38, P_FLUSH = 12'h3C;

  integer errors = 0;
  task automatic fail(input string msg);
    errors = errors + 1;
    $display("FAIL: %s (t=%0t)", msg, $time);
  endtask

  // ---- clocks ----
  reg ctrl_clk = 1'b0;
  always #5 ctrl_clk = ~ctrl_clk;
  reg ctrl_aresetn = 1'b0;

  realtime half_rx [2] = '{8.0, 8.0};      // far devices' clocks (lane 0 = P0 side)
  reg [3:0] rx_clk = 4'b0, tx_clk = 4'b0;
  initial begin #1.1; forever begin #(half_rx[0]); rx_clk[0] = ~rx_clk[0]; end end
  initial begin #3.7; forever begin #(half_rx[1]); rx_clk[1] = ~rx_clk[1]; end end
  // local TX clock (one QPLL for all lanes)
  initial begin #0.4; forever begin #8.0; tx_clk[0] = ~tx_clk[0]; tx_clk[1] = ~tx_clk[1]; end end
  reg [3:0] rx_aresetn = 4'b0, tx_aresetn = 4'b0;

  // ---- DUT signals ----
  wire [15:0] rx_tdata [0:1];
  wire [1:0]  rx_tkeep [0:1];
  wire [1:0]  rx_tvalid, rx_tlast, rx_tbad, rx_sgood, rx_sbad;
  wire [15:0] tx_tdata [0:3];
  wire [1:0]  tx_tkeep [0:3];
  wire [3:0]  tx_tvalid, tx_tlast;
  wire [0:0]  tx_tuser [0:3];
  wire [1:0]  tx_tready, tx_sgood;
  wire [31:0] tx_ifg;

  reg  [11:0] awaddr = 0, araddr = 0;
  reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
  reg  [31:0] wdata = 0;
  reg  [3:0]  wstrb = 0;
  wire        awready, wready, bvalid, arready, rvalid;
  wire [1:0]  bresp, rresp;
  wire [31:0] rdata;

  pktrec_m0_path dut (
    // replay input (M6) unused here
    .dp_clk(1'b0), .dp_aresetn(1'b0), .s_axis_rpl_tdata(16'd0), .s_axis_rpl_tkeep(2'd0),
    .s_axis_rpl_tvalid(1'b0), .s_axis_rpl_tready(), .s_axis_rpl_tlast(1'b0), .s_axis_rpl_tuser(1'b0),
    .s_axis_rpl_tdest(2'd0), .rpl_eff(),
    .ctrl_clk(ctrl_clk), .ctrl_aresetn(ctrl_aresetn),
    .rx_clk_0(rx_clk[0]), .rx_aresetn_0(rx_aresetn[0]),
    .s_axis_rx_0_tdata(rx_tdata[0]), .s_axis_rx_0_tkeep(rx_tkeep[0]), .s_axis_rx_0_tvalid(rx_tvalid[0]),
    .s_axis_rx_0_tlast(rx_tlast[0]), .s_axis_rx_0_tuser({64'd0, rx_tbad[0]}),
    .tx_clk_0(tx_clk[0]), .tx_aresetn_0(tx_aresetn[0]),
    .m_axis_tx_0_tdata(tx_tdata[0]), .m_axis_tx_0_tkeep(tx_tkeep[0]), .m_axis_tx_0_tvalid(tx_tvalid[0]),
    .m_axis_tx_0_tready(tx_tready[0]), .m_axis_tx_0_tlast(tx_tlast[0]), .m_axis_tx_0_tuser(tx_tuser[0]),
    .m_axis_tx_0_tid(), .m_axis_mon_0_tdata(), .m_axis_mon_0_tkeep(), .m_axis_mon_0_tvalid(),
    .m_axis_mon_0_tlast(), .m_axis_mon_0_tuser(),
    .rx_clk_1(rx_clk[1]), .rx_aresetn_1(rx_aresetn[1]),
    .s_axis_rx_1_tdata(rx_tdata[1]), .s_axis_rx_1_tkeep(rx_tkeep[1]), .s_axis_rx_1_tvalid(rx_tvalid[1]),
    .s_axis_rx_1_tlast(rx_tlast[1]), .s_axis_rx_1_tuser({64'd0, rx_tbad[1]}),
    .tx_clk_1(tx_clk[1]), .tx_aresetn_1(tx_aresetn[1]),
    .m_axis_tx_1_tdata(tx_tdata[1]), .m_axis_tx_1_tkeep(tx_tkeep[1]), .m_axis_tx_1_tvalid(tx_tvalid[1]),
    .m_axis_tx_1_tready(tx_tready[1]), .m_axis_tx_1_tlast(tx_tlast[1]), .m_axis_tx_1_tuser(tx_tuser[1]),
    .m_axis_tx_1_tid(), .m_axis_mon_1_tdata(), .m_axis_mon_1_tkeep(), .m_axis_mon_1_tvalid(),
    .m_axis_mon_1_tlast(), .m_axis_mon_1_tuser(),
    .rx_clk_2(rx_clk[2]), .rx_aresetn_2(rx_aresetn[2]),
    .s_axis_rx_2_tdata(16'd0), .s_axis_rx_2_tkeep(2'd0), .s_axis_rx_2_tvalid(1'b0),
    .s_axis_rx_2_tlast(1'b0), .s_axis_rx_2_tuser(65'd0),
    .tx_clk_2(tx_clk[2]), .tx_aresetn_2(tx_aresetn[2]),
    .m_axis_tx_2_tdata(tx_tdata[2]), .m_axis_tx_2_tkeep(tx_tkeep[2]), .m_axis_tx_2_tvalid(tx_tvalid[2]),
    .m_axis_tx_2_tready(1'b1), .m_axis_tx_2_tlast(tx_tlast[2]), .m_axis_tx_2_tuser(tx_tuser[2]),
    .m_axis_tx_2_tid(), .m_axis_mon_2_tdata(), .m_axis_mon_2_tkeep(), .m_axis_mon_2_tvalid(),
    .m_axis_mon_2_tlast(), .m_axis_mon_2_tuser(),
    .rx_clk_3(rx_clk[3]), .rx_aresetn_3(rx_aresetn[3]),
    .s_axis_rx_3_tdata(16'd0), .s_axis_rx_3_tkeep(2'd0), .s_axis_rx_3_tvalid(1'b0),
    .s_axis_rx_3_tlast(1'b0), .s_axis_rx_3_tuser(65'd0),
    .tx_clk_3(tx_clk[3]), .tx_aresetn_3(tx_aresetn[3]),
    .m_axis_tx_3_tdata(tx_tdata[3]), .m_axis_tx_3_tkeep(tx_tkeep[3]), .m_axis_tx_3_tvalid(tx_tvalid[3]),
    .m_axis_tx_3_tready(1'b1), .m_axis_tx_3_tlast(tx_tlast[3]), .m_axis_tx_3_tuser(tx_tuser[3]),
    .m_axis_tx_3_tid(), .m_axis_mon_3_tdata(), .m_axis_mon_3_tkeep(), .m_axis_mon_3_tvalid(),
    .m_axis_mon_3_tlast(), .m_axis_mon_3_tuser(),
    .rx_stat_pkt_good({2'b00, rx_sgood}), .rx_stat_pkt_bad({2'b00, rx_sbad}),
    .tx_stat_pkt_good({2'b00, tx_sgood}), .tx_stat_err_underflow(4'b0000),
    .link_up(4'b0011), .tx_ifg(tx_ifg),
    .phy_gpio0(4'b0), .phy_gpio1(4'b0), .pg_1v0(1'b1), .pg_2v5(1'b1),
    .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready)
  );

  // lane 0: P0 RX -> P1 TX; lane 1: P1 RX -> P0 TX
  tb_tap_lane #(.LANE(0)) lane0 (
    .src_clk(rx_clk[0]), .src_rst(!rx_aresetn[0]), .dst_clk(tx_clk[1]), .dst_rst(!tx_aresetn[1]),
    .rx_tdata(rx_tdata[0]), .rx_tkeep(rx_tkeep[0]), .rx_tvalid(rx_tvalid[0]), .rx_tlast(rx_tlast[0]),
    .rx_tbad(rx_tbad[0]), .rx_stat_good(rx_sgood[0]), .rx_stat_bad(rx_sbad[0]),
    .tx_tdata(tx_tdata[1]), .tx_tkeep(tx_tkeep[1]), .tx_tvalid(tx_tvalid[1]), .tx_tready(tx_tready[1]),
    .tx_tlast(tx_tlast[1]), .tx_tuser(tx_tuser[1][0]), .tx_ifg(tx_ifg[15:8]), .tx_stat_good(tx_sgood[1]));
  tb_tap_lane #(.LANE(1)) lane1 (
    .src_clk(rx_clk[1]), .src_rst(!rx_aresetn[1]), .dst_clk(tx_clk[0]), .dst_rst(!tx_aresetn[0]),
    .rx_tdata(rx_tdata[1]), .rx_tkeep(rx_tkeep[1]), .rx_tvalid(rx_tvalid[1]), .rx_tlast(rx_tlast[1]),
    .rx_tbad(rx_tbad[1]), .rx_stat_good(rx_sgood[1]), .rx_stat_bad(rx_sbad[1]),
    .tx_tdata(tx_tdata[0]), .tx_tkeep(tx_tkeep[0]), .tx_tvalid(tx_tvalid[0]), .tx_tready(tx_tready[0]),
    .tx_tlast(tx_tlast[0]), .tx_tuser(tx_tuser[0][0]), .tx_ifg(tx_ifg[7:0]), .tx_stat_good(tx_sgood[0]));

  // ---- AXI4-Lite BFM ----
  task automatic axi_write(input [11:0] a, input [31:0] d);
    @(posedge ctrl_clk);
    awaddr <= a; wdata <= d; wstrb <= 4'hF; awvalid <= 1; wvalid <= 1; bready <= 1;
    @(posedge ctrl_clk);
    while (!(awready && wready)) @(posedge ctrl_clk);
    awvalid <= 0; wvalid <= 0;
    while (!bvalid) @(posedge ctrl_clk);
    @(posedge ctrl_clk);
    bready <= 0;
  endtask

  task automatic axi_read(input [11:0] a, output [31:0] d);
    @(posedge ctrl_clk);
    araddr <= a; arvalid <= 1; rready <= 1;
    @(posedge ctrl_clk);
    while (!arready) @(posedge ctrl_clk);
    arvalid <= 0;
    while (!rvalid) @(posedge ctrl_clk);
    d = rdata;
    @(posedge ctrl_clk);
    rready <= 0;
  endtask

  task automatic expect_reg(input [11:0] a, input [31:0] exp, input string what);
    reg [31:0] d;
    axi_read(a, d);
    if (d !== exp) fail($sformatf("%s: reg 0x%03x = 0x%08x, expected 0x%08x", what, a, d, exp));
  endtask

  function automatic [11:0] preg(input integer p, input [11:0] off);
    preg = P_BASE + p * P_STRIDE + off;
  endfunction

  int unsigned rv;
  task automatic rd(input [11:0] a);
    reg [31:0] d;
    axi_read(a, d);
    rv = d;
  endtask

  // ---- probes: frames committed into each FIFO (FIFO f = 2 * TX port + kind) ----
  int unsigned committed [4] = '{0, 0, 0, 0};
  int unsigned fifo_drops [4] = '{0, 0, 0, 0};
  always @(posedge rx_clk[0]) begin
    if (dut.g_fifo[0].fifo_inst.s_good) committed[0]++;
    if (dut.g_fifo[3].fifo_inst.s_good) committed[3]++;
    if (dut.g_fifo[0].fifo_inst.s_drop) fifo_drops[0]++;
    if (dut.g_fifo[3].fifo_inst.s_drop) fifo_drops[3]++;
  end
  always @(posedge rx_clk[1]) begin
    if (dut.g_fifo[1].fifo_inst.s_good) committed[1]++;
    if (dut.g_fifo[2].fifo_inst.s_good) committed[2]++;
    if (dut.g_fifo[1].fifo_inst.s_drop) fifo_drops[1]++;
    if (dut.g_fifo[2].fifo_inst.s_drop) fifo_drops[2]++;
  end

  // ---- dynamic IFG transition monitor (TX port 1 = lane 0's output) ----
  int unsigned ifg_hi = 3072, ifg_lo = 2048;
  int unsigned n_enter = 0, n_exit = 0, fill_max_seen = 0;
  bit          red_d = 0;
  int unsigned fill_d = 0;
  always @(posedge tx_clk[1]) begin
    if (dut.g_port[1].reduced && !red_d) begin
      n_enter++;
      if (!(fill_d > ifg_hi)) fail($sformatf("reduced IFG started at fill %0d (IFG_HI %0d)", fill_d, ifg_hi));
    end
    if (!dut.g_port[1].reduced && red_d) begin
      n_exit++;
      if (!(fill_d < ifg_lo) && dut.g_port[1].i_en)
        fail($sformatf("reduced IFG ended at fill %0d (IFG_LO %0d)", fill_d, ifg_lo));
    end
    red_d  <= dut.g_port[1].reduced;
    fill_d <= dut.g_port[1].fill;
    if (dut.g_port[1].fill > fill_max_seen) fill_max_seen = dut.g_port[1].fill;
  end

  // ---- helpers ----
  task automatic set_ppm(input int lane, input real ppm);
    half_rx[lane] = 8.0 / (1.0 + ppm * 1e-6);
  endtask

  task automatic run_frames(input int lane_mask, input int n);
    if (lane_mask & 1) lane0.quota = n;
    if (lane_mask & 2) lane1.quota = n;
    while (lane0.quota != 0 || lane1.quota != 0 || lane0.active || lane1.active) #1000;
  endtask

  task automatic drain();
    int quiet = 0;
    while (quiet < 3000) begin
      @(posedge tx_clk[0]);
      if (tx_tvalid[1:0] != 0 || rx_tvalid != 0 || lane0.s_tvalid || lane1.s_tvalid) quiet = 0;
      else quiet++;
    end
  endtask

  task automatic clear_counters();
    axi_write(R_CNT_CTRL, 32'd1);
    repeat (20) @(posedge ctrl_clk);
  endtask

  task automatic latency_report(input string what);
    $display("INFO: %s: store-and-forward latency /S/ in -> /S/ out: lane0 %0.1f..%0.1f ns, lane1 %0.1f..%0.1f ns",
             what, lane0.lat_min, lane0.lat_max, lane1.lat_min, lane1.lat_max);
    lane0.lat_min = 1e9; lane0.lat_max = 0; lane1.lat_min = 1e9; lane1.lat_max = 0;
  endtask

  task automatic gap_report(input string what);
    string s = "";
    for (int i = 0; i < 32; i++) if (lane0.gap_hist[i]) s = {s, $sformatf(" %0dB:%0d", i, lane0.gap_hist[i])};
    $display("INFO: %s: P1 TX wire gaps (bytes:count)%s", what, s);
  endtask

  function automatic void reset_lane_stats();
    lane0.n_rx = 0; lane0.n_rx_bad = 0; lane0.n_err = 0; lane0.n_lost = '{0, 0}; lane0.n_foreign = 0;
    lane1.n_rx = 0; lane1.n_rx_bad = 0; lane1.n_err = 0; lane1.n_lost = '{0, 0}; lane1.n_foreign = 0;
    for (int i = 0; i < 32; i++) begin lane0.gap_hist[i] = 0; lane1.gap_hist[i] = 0; end
  endfunction

  // ---------------------------------------------------------------------------
  // frame counts of the long tests: 25 KB of accumulated excess each (see header)
  localparam int N1514 = 1200;
  localparam int N64   = 9000;
  reg [31:0] d;
  int unsigned exp_bad, n0, n1, drops, flushed, delivered, comm, lost0, lost1;

  initial begin
    #400ms;
    $display("FAIL: watchdog timeout");
    $finish;
  end

  initial begin
    repeat (20) @(posedge ctrl_clk);
    ctrl_aresetn = 1'b1;
    #200;
    rx_aresetn = 4'h3;
    tx_aresetn = 4'h3;
    #2000;

    // ---- 1. registers ----
    expect_reg(R_ID, 32'h504B4D30, "ID");
    expect_reg(R_VERSION, 32'h00010003, "VERSION");
    for (int p = 0; p < 4; p++) begin
      expect_reg(preg(p, P_IFG_CTRL), 32'h00080C01, "IFG_CTRL reset");
      expect_reg(preg(p, P_IFG_THRESH), 32'h08000C00, "IFG_THRESH reset");
    end
    expect_reg(R_PAIR_MODE, 32'h0, "PAIR_MODE reset");
    axi_write(R_PAIR_MODE, 32'h5);
    expect_reg(R_PAIR_MODE, 32'h5, "PAIR_MODE");
    axi_write(R_PAIR_MODE, 32'h1);
    expect_reg(R_EFF_PATH, 32'h0, "EFF_PATH idle");
    axi_write(R_PATH_CTRL, 32'h0A);              // P0 FWD, P1 FWD (pair 0 TAP)
    repeat (50) @(posedge ctrl_clk);
    expect_reg(R_EFF_PATH, 32'h0A, "EFF_PATH tap");
    expect_reg(preg(1, P_IFG_STATUS), 32'h00000C00, "IFG_STATUS idle");
    $display("INFO: registers done");

    // ---- 2. bad-frame forwarding (nominal clocks +-50 ppm) ----
    set_ppm(0, 50); set_ppm(1, -50);
    clear_counters(); reset_lane_stats();
    lane0.len = 252; lane0.bad_every = 5; lane0.bad_phase = 2; lane0.fcs_every = 7; lane0.fcs_phase = 3;
    lane1.len = 60;  lane1.bad_every = 4; lane1.bad_phase = 1; lane1.fcs_every = 9; lane1.fcs_phase = 0;
    n0 = lane0.n_src; n1 = lane1.n_src;
    run_frames(3, 200);
    drain();
    begin
      int unsigned eb0 = 0, eb1 = 0;
      for (int unsigned s = n0; s < lane0.n_src; s++) if (bad_of[0][s] || fcs_of[0][s]) eb0++;
      for (int unsigned s = n1; s < lane1.n_src; s++) if (bad_of[1][s] || fcs_of[1][s]) eb1++;
      if (lane0.n_rx != 200 || lane1.n_rx != 200)
        fail($sformatf("bad-frame test: delivered %0d/%0d of 200/200", lane0.n_rx, lane1.n_rx));
      if (lane0.n_rx_bad != eb0 || lane1.n_rx_bad != eb1)
        fail($sformatf("bad-frame test: far end saw %0d/%0d bad, expected %0d/%0d",
                       lane0.n_rx_bad, lane1.n_rx_bad, eb0, eb1));
      if (lane0.n_fcs_inj == 0) fail("no line bit errors injected");
      expect_reg(preg(0, P_RX_BAD), eb0, "P0 RX_BAD");
      expect_reg(preg(1, P_RX_BAD), eb1, "P1 RX_BAD");
      expect_reg(preg(0, P_RX_GOOD), 200 - eb0, "P0 RX_GOOD");
      expect_reg(preg(1, P_TX_GOOD), 200 - eb0, "P1 TX_GOOD (bad frames leave error-terminated)");
      expect_reg(preg(0, P_TX_GOOD), 200 - eb1, "P0 TX_GOOD");
      $display("INFO: bad-frame forwarding done: lane0 %0d bad (%0d tuser, %0d line bit errors) of 200 -> %0d bad at the far end; lane1 %0d -> %0d",
               eb0, eb0 - lane0.n_fcs_inj, lane0.n_fcs_inj, lane0.n_rx_bad, eb1, lane1.n_rx_bad);
    end
    lane0.bad_every = 0; lane0.fcs_every = 0; lane1.bad_every = 0; lane1.fcs_every = 0;
    latency_report("252-byte / 60-byte frames");

    // ---- latency by frame size (paced: one frame in flight) ----
    for (int k = 0; k < 5; k++) begin
      int sz [5] = '{60, 252, 508, 1020, 1514};
      lane0.len = sz[k];
      repeat (5) begin
        run_frames(1, 1);
        drain();
      end
      $display("INFO: latency %0d-byte frames (+FCS = %0d): %0.1f..%0.1f ns", sz[k], sz[k] + 4,
               lane0.lat_min, lane0.lat_max);
      lane0.lat_min = 1e9; lane0.lat_max = 0;
    end

    // ---- 3. 1514-byte frames, source +2000 ppm, dynamic IFG ----
    set_ppm(0, 2000); set_ppm(1, 0);
    #1000;
    clear_counters(); reset_lane_stats();
    n_enter = 0; n_exit = 0; fill_max_seen = 0;
    lane0.len = 1514;
    // The FWD fill counts the frame being received: about 1530 B + backlog while
    // forwarding 1514-byte frames at 100 %. Narrow band for this test (speed):
    // IFG_HI 2048 / IFG_LO 1792. Backlog grows 3.08 B / frame (+2000 ppm) and drains
    // 0.93 B / frame with the 8-byte gap: enter after ~170 frames, a cycle every ~360.
    ifg_hi = 2048; ifg_lo = 1792;
    axi_write(preg(1, P_IFG_THRESH), {16'd1792, 16'd2048});
    run_frames(1, N1514);
    drain();
    gap_report("1514 B +2000 ppm, dyn IFG on");
    axi_read(preg(1, P_FWD_FILL), d);
    rd(preg(1, P_RED_LO));
    $display("INFO: 1514 B +2000 ppm: %0d frames, delivered %0d, lost %0d, reduced-IFG entries %0d/exits %0d, max FWD fill %0d B (reg 0x%08x), RED_CYC %0d",
             N1514, lane0.n_rx, lane0.n_lost[0], n_enter, n_exit, fill_max_seen, d, rv);
    if (lane0.n_rx != N1514 || lane0.n_lost[0] != 0 || lane0.n_err != 0)
      fail($sformatf("1514 B +2000 ppm: delivered %0d of %0d, lost %0d", lane0.n_rx, N1514, lane0.n_lost[0]));
    if (n_enter < 2 || n_exit < 2) fail($sformatf("dynamic IFG did not cycle (%0d entries, %0d exits)", n_enter, n_exit));
    expect_reg(preg(1, P_RED_ENT), n_enter, "IFG_RED_ENTRIES");
    expect_reg(preg(1, P_DROP_FWD), 0, "DROP_FWD (dyn IFG)");
    if (d[31:16] != fill_max_seen) fail($sformatf("FWD_FILL max %0d != %0d", d[31:16], fill_max_seen));
    if (lane0.gap_hist[8] == 0 || lane0.gap_hist[12] == 0) fail("wire gaps of 8 and 12 bytes not both seen");
    for (int i = 0; i < 31; i++)       // 31 = idle (>= 31 bytes)
      if (i != 8 && i != 12 && lane0.gap_hist[i] != 0) fail($sformatf("unexpected wire gap %0d bytes", i));
    if (rv == 0) fail("IFG_RED_CYC = 0");
    ifg_hi = 3072; ifg_lo = 2048;
    axi_write(preg(1, P_IFG_THRESH), {16'd2048, 16'd3072});
    $display("INFO: dynamic IFG 1514 B done");

    // ---- 4. 64-byte frames, source +4 %, with and without the dynamic IFG ----
    set_ppm(0, 40000);
    #1000;
    clear_counters(); reset_lane_stats(); n_enter = 0; n_exit = 0; fill_max_seen = 0;
    lane0.len = 60;
    // excess 25.9 ns of wire time per frame: 233 us over 9000 frames (>= 200 us)
    run_frames(1, N64);
    drain();
    gap_report("60 B +4 %, dyn IFG on");
    rd(preg(1, P_DROP_FWD));
    $display("INFO: 64 B +4 %%, dyn IFG on: delivered %0d of %0d, lost %0d, entries %0d, max fill %0d B, DROP_FWD %0d",
             lane0.n_rx, N64, lane0.n_lost[0], n_enter, fill_max_seen, rv);
    if (lane0.n_rx != N64 || lane0.n_lost[0] != 0 || lane0.n_err != 0)
      fail($sformatf("64 B +4 %% dyn on: delivered %0d of %0d, lost %0d", lane0.n_rx, N64, lane0.n_lost[0]));
    expect_reg(preg(1, P_DROP_FWD), 0, "DROP_FWD (64 B, dyn IFG)");
    if (n_enter == 0) fail("64 B: dynamic IFG never engaged");

    axi_write(preg(1, P_IFG_CTRL), 32'h00080C00);   // DYN_EN = 0
    repeat (20) @(posedge ctrl_clk);
    clear_counters(); reset_lane_stats(); fill_max_seen = 0;
    run_frames(1, N64);
    drain();
    rd(preg(1, P_DROP_FWD)); drops = rv;
    $display("INFO: 64 B +4 %%, dyn IFG off: delivered %0d of %0d, lost %0d, DROP_FWD %0d, max fill %0d B",
             lane0.n_rx, N64, lane0.n_lost[0], drops, fill_max_seen);
    if (drops == 0 || lane0.n_lost[0] == 0) fail("64 B +4 % without dynamic IFG: expected drops");
    if (lane0.n_rx + drops != N64 || lane0.n_lost[0] > drops)
      fail($sformatf("drops not accounted: delivered %0d + DROP_FWD %0d != %0d (lost %0d)", lane0.n_rx, drops, N64, lane0.n_lost[0]));
    if (lane0.n_err != 0) fail("frames corrupted while dropping");
    axi_write(preg(1, P_IFG_CTRL), 32'h00080C01);
    $display("INFO: clock-mismatch tests done");

    // ---- 5. mode switching mid-traffic ----
    set_ppm(0, 80); set_ppm(1, -80);
    #1000;
    axi_write(R_PATH_CTRL, 32'h0A);
    repeat (50) @(posedge ctrl_clk);
    clear_counters(); reset_lane_stats();
    for (int f = 0; f < 4; f++) begin committed[f] = 0; fifo_drops[f] = 0; end
    lane0.len = 1514; lane1.len = 60;
    lane0.en = 1; lane1.en = 1;
    for (int i = 0; i < 12; i++) begin
      bit [7:0] m;
      #($urandom_range(20000, 60000) * 1ns);
      case (i % 4)
        0: m = 8'h00;    // IDLE
        1: m = 8'h0A;    // FWD (TAP)
        2: m = 8'h05;    // LOOP
        default: m = 8'h0A;
      endcase
      axi_write(R_PATH_CTRL, {24'd0, m});
    end
    // final: TAP, steady
    axi_write(R_PATH_CTRL, 32'h0A);
    #100000;
    lost0 = lane0.n_lost[0] + lane1.n_lost[0];
    lost1 = lane0.n_lost[1] + lane1.n_lost[1];
    #400000;
    if (lane0.n_lost[0] + lane1.n_lost[0] != lost0 || lane0.n_lost[1] + lane1.n_lost[1] != lost1)
      fail("frames lost in steady TAP forwarding after the last mode switch");
    lane0.en = 0; lane1.en = 0;
    drain();
    rd(preg(0, P_FLUSH)); flushed = rv;
    rd(preg(1, P_FLUSH)); flushed += rv;
    drops = 0;
    rd(preg(0, P_DROP_FWD)); drops += rv;
    rd(preg(1, P_DROP_FWD)); drops += rv;
    rd(preg(0, P_DROP_LOOP)); drops += rv;
    rd(preg(1, P_DROP_LOOP)); drops += rv;
    delivered = lane0.n_rx + lane1.n_rx;
    comm = committed[0] + committed[1] + committed[2] + committed[3];
    $display("INFO: mode switching: committed %0d, delivered %0d (%0d looped), flushed %0d, FIFO drops %0d (probe %0d), errors %0d/%0d",
             comm, delivered, lane0.n_foreign + lane1.n_foreign, flushed, drops,
             fifo_drops[0] + fifo_drops[1] + fifo_drops[2] + fifo_drops[3], lane0.n_err, lane1.n_err);
    if (lane0.n_err != 0 || lane1.n_err != 0) fail("mode switching: corrupt / truncated / reordered frame");
    if (comm != delivered + flushed) fail($sformatf("mode switching: committed %0d != delivered %0d + flushed %0d", comm, delivered, flushed));
    if (lane0.n_foreign + lane1.n_foreign == 0) fail("mode switching: LOOP phase delivered nothing");
    if (drops != fifo_drops[0] + fifo_drops[1] + fifo_drops[2] + fifo_drops[3]) fail("DROP counters != FIFO drops");
    $display("INFO: mode switching done");

    if (errors == 0) $display("PASS: tb_pktrec_tap");
    else $display("FAIL: tb_pktrec_tap, %0d error(s)", errors);
    $finish;
  end
endmodule
