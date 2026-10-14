// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_pktrec_replay -- self-checking testbench for the capture replay (M6)
//
//   record stream source (src_clk 200 MHz, models fdrec_core's egress output:
//   random stalls, pauses = DMA starvation)
//     -> pktrec_replay_top (parser, frame store, scheduler; timebase model at
//        4.0004 ns per dp_clk like the real pktrec_timebase)
//     -> pktrec_m0_path replay FIFO of the TX port (path mode 4, PATH_RPL)
//     -> Taxi 1000BASE-X TX (taxi_axis_basex_tx_16, the MAC/PCS of the real
//        port, 62.5 MHz) -> Taxi RX (the far device) -> checker
//
// Measured per frame: release time (timebase value when the first 16-bit word
// enters the port's replay FIFO) and the time of the /S/ code group the TX
// puts on the wire.
//
// Tests:
//   1. Registers: ID / VERSION / reset values; m0 VERSION 1.4, PATH_RPL, EFF_PATH.
//   2. SEL = 0: the playback stream passes through to the fdrec_check port
//      untouched (fdplay unchanged); the replay block sees nothing.
//   3. TIMED 1x, 150 frames of 60..1514 bytes, records of another port mixed in
//      (hardware port filter -> SKIPPED), fill units, one corrupted header unit
//      (PARSE_ERRORS = 1, resynchronised on the next header), bad frames sent
//      error-terminated (BAD_MODE 1): every frame arrives complete, in order,
//      bytes exact; release - target in [0, 1 dp_clk + 2 ns] for every frame
//      (never early); wire start-to-start intervals = original intervals within
//      one MAC clock (16 ns); counters exact; DONE by EXPECT.
//   4. Rate scale: 0.5x (RATE_INV 0x20000) and 2x (0x8000): release exactness
//      and scaled wire intervals as in 3; BAD_MODE 2 (skip) and 0 (send good).
//   5. Back-to-back: 600 x 64-byte frames (60 + FCS), prefilled: on the wire
//      every frame start is exactly 42 MAC cycles (672 ns) after the previous
//      one (line rate), UNDERRUNS = 0.
//   6. Fixed gap: 40 frames, GAP 2500 ns: release intervals 2500 ns +- 1 cycle.
//   7. Underrun: TIMED, frames 2 us apart, the source pauses 150 us mid-stream:
//      UNDERRUNS > 0 and STATUS.UNDERRUN, LATE > 0, frames still complete and
//      in order (no partial frame, nothing lost); back-to-back with EXPECT and a
//      pause: UNDERRUNS > 0.
//   8. Abort mid-stream (TIMED, 1514-byte frames, abort while a frame is on the
//      wire): that frame completes intact, nothing after it is sent, state IDLE,
//      the rest of the stream is drained (DISCARD_BEATS); a new run afterwards
//      works. STOP: a run without EXPECT ends (DONE) after STOP once all is sent.
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

module tb_pktrec_replay;

  // replay registers (include/pktrec_regs.h PKTREC_RPL_*)
  localparam [11:0] R_ID = 12'h000, R_VERSION = 12'h004, R_CTRL = 12'h008, R_CMD = 12'h00C,
                    R_STATUS = 12'h010, R_RATE = 12'h014, R_DELAY = 12'h018, R_LATE_TH = 12'h01C,
                    R_GAP = 12'h020, R_EXP_LO = 12'h024, R_EXP_HI = 12'h028, R_LEVEL = 12'h02C,
                    R_STORE = 12'h030, R_MAXCAP = 12'h034, R_T0 = 12'h038, R_TSF = 12'h040,
                    R_MAX_LATE = 12'h050,
                    C_RECORDS = 12'h080, C_FRAMES = 12'h088, C_BYTES = 12'h090, C_PERR = 12'h098,
                    C_FILL = 12'h0A0, C_SKIP = 12'h0A8, C_UNDER = 12'h0B0, C_LATE = 12'h0B8,
                    C_LATE_SUM = 12'h0C0, C_BEATS = 12'h0C8, C_DISCARD = 12'h0D0, C_BAD = 12'h0D8,
                    C_DONE = 12'h0E0;
  localparam [11:0] M_VERSION = 12'h004, M_PATH_CTRL = 12'h008, M_EFF = 12'h01C, M_RPL = 12'h020;
  localparam int CMD_ARM = 1, CMD_GO = 2, CMD_STOP = 4, CMD_ABORT = 8;
  localparam int ST_IDLE = 0, ST_ARMED = 1, ST_RUN = 2, ST_DONE = 3;

  integer errors = 0;
  task automatic fail(input string msg);
    errors = errors + 1;
    if (errors <= 30) $display("FAIL: %s (t=%0t)", msg, $time);
  endtask

  // ---------------------------------------------------------------------------
  // Clocks / resets
  // ---------------------------------------------------------------------------
  reg dp_clk = 0, src_clk = 0, ctrl_clk = 0;
  always #2.0 dp_clk = ~dp_clk;          // 250 MHz (the timebase model adds 4.0004 ns)
  always #2.5 src_clk = ~src_clk;        // 200 MHz
  always #5.0 ctrl_clk = ~ctrl_clk;      // 100 MHz
  reg [3:0] tx_clk = 4'b0;
  initial begin #0.7; forever #8.0 tx_clk[0] = ~tx_clk[0]; end
  initial begin #2.9; forever #8.0 tx_clk[1] = ~tx_clk[1]; end
  initial begin #5.3; forever #8.0 tx_clk[2] = ~tx_clk[2]; end
  initial begin #6.1; forever #8.0 tx_clk[3] = ~tx_clk[3]; end
  reg dp_resetn = 0, src_resetn = 0, ctrl_aresetn = 0;
  reg [3:0] tx_aresetn = 4'b0;

  // timebase model (pktrec_timebase): ns + 32-bit fraction
  // (the simulated dp_clk is exactly 4 ns, so the model counts exactly 4 ns per
  // cycle; on hardware INC = 4.0004 ns and the fraction carries now and then,
  // which the scheduler covers by comparing against timebase + tb_inc_ns)
  localparam [31:0] INC_FRAC = 32'd0;
  reg [63:0] tb_ns = 64'd1_760_000_000_000_000_000;
  reg [31:0] tb_frac = 0;
  always @(posedge dp_clk) {tb_ns, tb_frac} <= {tb_ns, tb_frac} + {64'd4, INC_FRAC};

  // ---------------------------------------------------------------------------
  // DUTs
  // ---------------------------------------------------------------------------
  reg  [127:0] egr_tdata = 0;
  reg          egr_tvalid = 0, egr_tlast = 0;
  wire         egr_tready;
  wire [127:0] chk_tdata;
  wire         chk_tvalid, chk_tlast;
  reg          chk_tready = 1;

  wire [15:0] rpl_tdata;
  wire [1:0]  rpl_tkeep, rpl_tdest;
  wire        rpl_tvalid, rpl_tready, rpl_tlast;
  wire [0:0]  rpl_tuser;
  wire [3:0]  rpl_eff;

  // AXI-Lite: replay (dp_clk) and m0 (ctrl_clk)
  reg  [11:0] r_awaddr = 0, r_araddr = 0, m_awaddr = 0, m_araddr = 0;
  reg         r_awvalid = 0, r_wvalid = 0, r_bready = 0, r_arvalid = 0, r_rready = 0;
  reg         m_awvalid = 0, m_wvalid = 0, m_bready = 0, m_arvalid = 0, m_rready = 0;
  reg  [31:0] r_wdata = 0, m_wdata = 0;
  wire        r_awready, r_wready, r_bvalid, r_arready, r_rvalid;
  wire        m_awready, m_wready, m_bvalid, m_arready, m_rvalid;
  wire [31:0] r_rdata, m_rdata;

  pktrec_replay_top rpl (
    .src_clk(src_clk), .src_resetn(src_resetn), .dp_clk(dp_clk), .dp_resetn(dp_resetn),
    .s_axis_egr_tdata(egr_tdata), .s_axis_egr_tlast(egr_tlast), .s_axis_egr_tvalid(egr_tvalid),
    .s_axis_egr_tready(egr_tready),
    .m_axis_chk_tdata(chk_tdata), .m_axis_chk_tlast(chk_tlast), .m_axis_chk_tvalid(chk_tvalid),
    .m_axis_chk_tready(chk_tready),
    .tb_now(tb_ns), .tb_inc_ns(8'd4),
    .m_axis_rpl_tdata(rpl_tdata), .m_axis_rpl_tkeep(rpl_tkeep), .m_axis_rpl_tvalid(rpl_tvalid),
    .m_axis_rpl_tready(rpl_tready), .m_axis_rpl_tlast(rpl_tlast), .m_axis_rpl_tuser(rpl_tuser),
    .m_axis_rpl_tdest(rpl_tdest), .rpl_eff(rpl_eff),
    .s_axi_awaddr(r_awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(r_awvalid), .s_axi_awready(r_awready),
    .s_axi_wdata(r_wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(r_wvalid), .s_axi_wready(r_wready),
    .s_axi_bresp(), .s_axi_bvalid(r_bvalid), .s_axi_bready(r_bready),
    .s_axi_araddr(r_araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(r_arvalid), .s_axi_arready(r_arready),
    .s_axi_rdata(r_rdata), .s_axi_rresp(), .s_axi_rvalid(r_rvalid), .s_axi_rready(r_rready)
  );

  wire [15:0] tx_tdata [0:3];
  wire [1:0]  tx_tkeep [0:3];
  wire [3:0]  tx_tvalid, tx_tlast, tx_tready;
  wire [0:0]  tx_tuser [0:3];
  wire [31:0] tx_ifg;

  pktrec_m0_path m0 (
    .dp_clk(dp_clk), .dp_aresetn(dp_resetn),
    .s_axis_rpl_tdata(rpl_tdata), .s_axis_rpl_tkeep(rpl_tkeep), .s_axis_rpl_tvalid(rpl_tvalid),
    .s_axis_rpl_tready(rpl_tready), .s_axis_rpl_tlast(rpl_tlast), .s_axis_rpl_tuser(rpl_tuser),
    .s_axis_rpl_tdest(rpl_tdest), .rpl_eff(rpl_eff),
    .ctrl_clk(ctrl_clk), .ctrl_aresetn(ctrl_aresetn),
    .rx_clk_0(tx_clk[0]), .rx_aresetn_0(tx_aresetn[0]), .s_axis_rx_0_tdata(16'd0), .s_axis_rx_0_tkeep(2'd0),
    .s_axis_rx_0_tvalid(1'b0), .s_axis_rx_0_tlast(1'b0), .s_axis_rx_0_tuser(65'd0),
    .tx_clk_0(tx_clk[0]), .tx_aresetn_0(tx_aresetn[0]), .m_axis_tx_0_tdata(tx_tdata[0]),
    .m_axis_tx_0_tkeep(tx_tkeep[0]), .m_axis_tx_0_tvalid(tx_tvalid[0]), .m_axis_tx_0_tready(tx_tready[0]),
    .m_axis_tx_0_tlast(tx_tlast[0]), .m_axis_tx_0_tuser(tx_tuser[0]), .m_axis_tx_0_tid(),
    .m_axis_mon_0_tdata(), .m_axis_mon_0_tkeep(), .m_axis_mon_0_tvalid(), .m_axis_mon_0_tlast(), .m_axis_mon_0_tuser(),
    .rx_clk_1(tx_clk[1]), .rx_aresetn_1(tx_aresetn[1]), .s_axis_rx_1_tdata(16'd0), .s_axis_rx_1_tkeep(2'd0),
    .s_axis_rx_1_tvalid(1'b0), .s_axis_rx_1_tlast(1'b0), .s_axis_rx_1_tuser(65'd0),
    .tx_clk_1(tx_clk[1]), .tx_aresetn_1(tx_aresetn[1]), .m_axis_tx_1_tdata(tx_tdata[1]),
    .m_axis_tx_1_tkeep(tx_tkeep[1]), .m_axis_tx_1_tvalid(tx_tvalid[1]), .m_axis_tx_1_tready(tx_tready[1]),
    .m_axis_tx_1_tlast(tx_tlast[1]), .m_axis_tx_1_tuser(tx_tuser[1]), .m_axis_tx_1_tid(),
    .m_axis_mon_1_tdata(), .m_axis_mon_1_tkeep(), .m_axis_mon_1_tvalid(), .m_axis_mon_1_tlast(), .m_axis_mon_1_tuser(),
    .rx_clk_2(tx_clk[2]), .rx_aresetn_2(tx_aresetn[2]), .s_axis_rx_2_tdata(16'd0), .s_axis_rx_2_tkeep(2'd0),
    .s_axis_rx_2_tvalid(1'b0), .s_axis_rx_2_tlast(1'b0), .s_axis_rx_2_tuser(65'd0),
    .tx_clk_2(tx_clk[2]), .tx_aresetn_2(tx_aresetn[2]), .m_axis_tx_2_tdata(tx_tdata[2]),
    .m_axis_tx_2_tkeep(tx_tkeep[2]), .m_axis_tx_2_tvalid(tx_tvalid[2]), .m_axis_tx_2_tready(tx_tready[2]),
    .m_axis_tx_2_tlast(tx_tlast[2]), .m_axis_tx_2_tuser(tx_tuser[2]), .m_axis_tx_2_tid(),
    .m_axis_mon_2_tdata(), .m_axis_mon_2_tkeep(), .m_axis_mon_2_tvalid(), .m_axis_mon_2_tlast(), .m_axis_mon_2_tuser(),
    .rx_clk_3(tx_clk[3]), .rx_aresetn_3(tx_aresetn[3]), .s_axis_rx_3_tdata(16'd0), .s_axis_rx_3_tkeep(2'd0),
    .s_axis_rx_3_tvalid(1'b0), .s_axis_rx_3_tlast(1'b0), .s_axis_rx_3_tuser(65'd0),
    .tx_clk_3(tx_clk[3]), .tx_aresetn_3(tx_aresetn[3]), .m_axis_tx_3_tdata(tx_tdata[3]),
    .m_axis_tx_3_tkeep(tx_tkeep[3]), .m_axis_tx_3_tvalid(tx_tvalid[3]), .m_axis_tx_3_tready(tx_tready[3]),
    .m_axis_tx_3_tlast(tx_tlast[3]), .m_axis_tx_3_tuser(tx_tuser[3]), .m_axis_tx_3_tid(),
    .m_axis_mon_3_tdata(), .m_axis_mon_3_tkeep(), .m_axis_mon_3_tvalid(), .m_axis_mon_3_tlast(), .m_axis_mon_3_tuser(),
    .rx_stat_pkt_good(4'd0), .rx_stat_pkt_bad(4'd0), .tx_stat_pkt_good(4'd0), .tx_stat_err_underflow(4'd0),
    .link_up(4'hF), .tx_ifg(tx_ifg),
    .phy_gpio0(4'd0), .phy_gpio1(4'd0), .pg_1v0(1'b1), .pg_2v5(1'b1),
    .s_axi_awaddr(m_awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(m_awvalid), .s_axi_awready(m_awready),
    .s_axi_wdata(m_wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(m_wvalid), .s_axi_wready(m_wready),
    .s_axi_bresp(), .s_axi_bvalid(m_bvalid), .s_axi_bready(m_bready),
    .s_axi_araddr(m_araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(m_arvalid), .s_axi_arready(m_arready),
    .s_axi_rdata(m_rdata), .s_axi_rresp(), .s_axi_rvalid(m_rvalid), .s_axi_rready(m_rready)
  );

  // ---------------------------------------------------------------------------
  // Per port: Taxi TX (our MAC) -> Taxi RX (far device) -> received frames
  // ---------------------------------------------------------------------------
  typedef struct {
    byte unsigned data[$];
    bit           bad;
    realtime      sof;
  } rx_frame_t;
  rx_frame_t rxq [4][$];
  int        tx_underflow [4] = '{0, 0, 0, 0};

  genvar gp;
  generate for (gp = 0; gp < 4; gp++) begin : g_port
    taxi_axis_if #(.DATA_W(16), .KEEP_W(2), .USER_EN(1), .USER_W(2), .ID_EN(1), .ID_W(8)) tx_if();
    taxi_axis_if #(.DATA_W(8), .KEEP_W(1)) cpl_if();
    assign tx_if.tdata  = tx_tdata[gp];
    assign tx_if.tkeep  = tx_tkeep[gp];
    assign tx_if.tstrb  = tx_tkeep[gp];
    assign tx_if.tvalid = tx_tvalid[gp];
    assign tx_if.tlast  = tx_tlast[gp];
    assign tx_if.tuser  = {1'b0, tx_tuser[gp]};
    assign tx_if.tid    = '0;
    assign tx_if.tdest  = '0;
    assign tx_tready[gp] = tx_if.tready;
    assign cpl_if.tready = 1'b1;
    wire [15:0] te_d;
    wire [1:0]  te_k, sop;
    wire        unf;
    taxi_axis_basex_tx_16 #(.SGMII_EN(1'b1), .PTP_TS_EN(1'b0), .PTP_TS_W(64)) mac_tx (
      .clk(tx_clk[gp]), .rst(!tx_aresetn[gp]),
      .s_axis_tx(tx_if), .m_axis_tx_cpl(cpl_if),
      .encoded_tx_data(te_d), .encoded_tx_data_k(te_k), .encoded_tx_data_dm(), .encoded_tx_data_dv(),
      .encoded_tx_data_valid(), .tx_gbx_req_sync(1'b0), .tx_gbx_req_stall(1'b0), .tx_gbx_sync(),
      .tx_an_cfg(16'd0), .tx_an_cfg_valid(1'b0), .tx_an_cfg_ready(),
      .ptp_ts(64'd0),
      .cfg_tx_max_pkt_len(16'd2047), .cfg_tx_ifg(tx_ifg[8*gp +: 8]), .cfg_tx_enable(1'b1),
      .cfg_tx_sgmii_en(1'b1), .cfg_tx_sgmii_speed(2'b10),
      .tx_start_packet(sop), .stat_tx_byte(), .stat_tx_pkt_len(), .stat_tx_pkt_ucast(),
      .stat_tx_pkt_mcast(), .stat_tx_pkt_bcast(), .stat_tx_pkt_vlan(), .stat_tx_pkt_good(),
      .stat_tx_pkt_bad(), .stat_tx_err_oversize(), .stat_tx_err_user(), .stat_tx_err_underflow(unf)
    );
    realtime sof_q[$];
    always @(posedge tx_clk[gp]) begin
      if (|sop) sof_q.push_back($realtime + (sop[1] ? 8.0 : 0.0));
      if (unf) tx_underflow[gp]++;
    end

    taxi_axis_if #(.DATA_W(16), .KEEP_W(2), .USER_EN(1), .USER_W(1)) far_if();
    assign far_if.tready = 1'b1;
    taxi_axis_basex_rx_16 #(.SGMII_EN(1'b1), .PTP_TS_EN(1'b0), .PTP_TS_W(64)) far_rx (
      .clk(tx_clk[gp]), .rst(!tx_aresetn[gp]),
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
    byte unsigned got[$];
    always @(posedge tx_clk[gp]) begin
      if (far_if.tvalid) begin
        got.push_back(far_if.tdata[7:0]);
        if (far_if.tkeep[1]) got.push_back(far_if.tdata[15:8]);
        if (far_if.tlast) begin
          rx_frame_t f;
          f.data = got;
          f.bad  = far_if.tuser[0];
          f.sof  = sof_q.size() ? sof_q.pop_front() : -1.0;
          rxq[gp].push_back(f);
          got.delete();
        end
      end
    end
  end endgenerate

  // ---------------------------------------------------------------------------
  // Release monitor (dp_clk): timebase value when a frame's first word is taken
  // ---------------------------------------------------------------------------
  longint unsigned rel_q[$];
  bit rel_in = 0;
  int rpl_gap_err = 0;
  always @(posedge dp_clk) begin
    if (rpl_tvalid && rpl_tready) begin
      if (!rel_in) rel_q.push_back(tb_ns);
      rel_in <= !rpl_tlast;
    end else if (rel_in && !rpl_tvalid) begin
      rpl_gap_err++;               // tvalid dropped inside a frame
    end
  end

  // ---------------------------------------------------------------------------
  // fdrec_check port model (SEL = 0)
  // ---------------------------------------------------------------------------
  int chk_beats = 0;
  always @(posedge src_clk) if (chk_tvalid && chk_tready) chk_beats++;

  // ---------------------------------------------------------------------------
  // Record stream source (src_clk)
  // ---------------------------------------------------------------------------
  logic [127:0] src_q[$];
  bit           src_pause = 0;
  int           src_stall_pct = 20;
  longint       src_beats = 0;
  int           pause_at = -1;           // pause after this many beats (-1 = never)
  realtime      pause_len = 0;

  always @(posedge src_clk) begin
    if (!src_resetn) begin
      egr_tvalid <= 0;
    end else begin
      if (egr_tvalid && egr_tready) src_beats++;
      if (!egr_tvalid || egr_tready) begin
        if (src_q.size() > 0 && !src_pause && $urandom_range(99) >= src_stall_pct) begin
          egr_tdata  <= src_q.pop_front();
          egr_tlast  <= (src_q.size() == 0);
          egr_tvalid <= 1;
        end else begin
          egr_tvalid <= 0;
        end
      end
    end
  end
  always @(posedge src_clk)
    if (pause_at >= 0 && src_beats == pause_at && !src_pause) begin
      src_pause = 1;
      pause_at = -1;
      fork begin #(pause_len); src_pause = 0; end join_none
    end

  // ---------------------------------------------------------------------------
  // Frames, records, expectations
  // ---------------------------------------------------------------------------
  class Frame;
    byte unsigned data[$];
    longint unsigned ts;
    int port;
    bit bad;
    bit sent;              // expected on the wire
  endclass
  Frame frames[$];         // every record of the stream, in order
  Frame sent_f[$];         // those expected on the wire, in order

  function automatic logic [127:0] hdr(input Frame f, input int seq);
    logic [7:0] flags = 8'hA0 | (f.bad ? 8'h01 : 8'h00);
    return {seq[15:0], flags, 8'(f.port), 16'(f.data.size() + 4), 16'(f.data.size()), f.ts};
  endfunction

  task automatic push_record(input Frame f, input int seq);
    logic [127:0] b;
    src_q.push_back(hdr(f, seq));
    for (int i = 0; i < f.data.size(); i += 16) begin
      b = '0;
      for (int k = 0; k < 16 && i + k < f.data.size(); k++) b[8*k +: 8] = f.data[i + k];
      src_q.push_back(b);
    end
  endtask

  function automatic Frame mk(input longint unsigned ts, input int len, input int port, input bit bad);
    Frame f = new();
    f.ts = ts; f.port = port; f.bad = bad;
    for (int i = 0; i < len; i++) f.data.push_back($urandom_range(0, 255));
    return f;
  endfunction

  // wire time of a frame at 1 Gb/s: preamble/SFD 8 + data + FCS 4 + IFG 12 bytes
  function automatic longint unsigned wire_ns(input int len);
    return 8 * (8 + (len < 60 ? 60 : len) + 4 + 12);
  endfunction

  // ---------------------------------------------------------------------------
  // AXI4-Lite BFMs
  // ---------------------------------------------------------------------------
  task automatic rwr(input [11:0] a, input [31:0] d);
    @(posedge dp_clk);
    r_awaddr <= a; r_wdata <= d; r_awvalid <= 1; r_wvalid <= 1; r_bready <= 1;
    @(posedge dp_clk);
    while (!(r_awready && r_wready)) @(posedge dp_clk);
    r_awvalid <= 0; r_wvalid <= 0;
    while (!r_bvalid) @(posedge dp_clk);
    @(posedge dp_clk);
    r_bready <= 0;
  endtask
  task automatic rrd(input [11:0] a, output [31:0] d);
    @(posedge dp_clk);
    r_araddr <= a; r_arvalid <= 1; r_rready <= 1;
    @(posedge dp_clk);
    while (!r_arready) @(posedge dp_clk);
    r_arvalid <= 0;
    while (!r_rvalid) @(posedge dp_clk);
    d = r_rdata;
    @(posedge dp_clk);
    r_rready <= 0;
  endtask
  task automatic rrd64(input [11:0] a, output longint unsigned v);
    logic [31:0] lo, hi;
    rrd(a, lo); rrd(a + 4, hi);
    v = {hi, lo};
  endtask
  task automatic mwr(input [11:0] a, input [31:0] d);
    @(posedge ctrl_clk);
    m_awaddr <= a; m_wdata <= d; m_awvalid <= 1; m_wvalid <= 1; m_bready <= 1;
    @(posedge ctrl_clk);
    while (!(m_awready && m_wready)) @(posedge ctrl_clk);
    m_awvalid <= 0; m_wvalid <= 0;
    while (!m_bvalid) @(posedge ctrl_clk);
    @(posedge ctrl_clk);
    m_bready <= 0;
  endtask
  task automatic mrd(input [11:0] a, output [31:0] d);
    @(posedge ctrl_clk);
    m_araddr <= a; m_arvalid <= 1; m_rready <= 1;
    @(posedge ctrl_clk);
    while (!m_arready) @(posedge ctrl_clk);
    m_arvalid <= 0;
    while (!m_rvalid) @(posedge ctrl_clk);
    d = m_rdata;
    @(posedge ctrl_clk);
    m_rready <= 0;
  endtask
  task automatic rexp(input [11:0] a, input [31:0] e, input string what);
    logic [31:0] d;
    rrd(a, d);
    if (d !== e) fail($sformatf("%s: 0x%03x = 0x%08x, expected 0x%08x", what, a, d, e));
  endtask
  task automatic cexp(input [11:0] a, input longint unsigned e, input string what);
    longint unsigned v;
    rrd64(a, v);
    if (v != e) fail($sformatf("%s: counter 0x%03x = %0d, expected %0d", what, a, v, e));
  endtask

  task automatic wait_state(input int st, input real timeout_us, input string what);
    logic [31:0] s;
    realtime t_end = $realtime + timeout_us * 1000.0;
    rrd(R_STATUS, s);
    while (s[2:0] != st && $realtime < t_end) begin
      repeat (50) @(posedge dp_clk);
      rrd(R_STATUS, s);
    end
    if (s[2:0] != st) fail($sformatf("%s: state %0d, expected %0d (status 0x%08x)", what, s[2:0], st, s));
  endtask

  // ---------------------------------------------------------------------------
  // Run helpers
  // ---------------------------------------------------------------------------
  int       tx_port = 2;
  longint unsigned t0_rd, tsf_rd;

  // CTRL: SEL | MODE | BAD_MODE | FILTER | TX_PORT
  function automatic [31:0] ctrl(input int mode, input int bad_mode, input bit filt, input int fport,
                                 input int txp);
    return 32'd1 | (mode << 1) | (bad_mode << 4) | (filt << 6) | (fport << 8) | (txp << 12);
  endfunction

  // queue the whole stream (frames[]) as records; seq per port
  task automatic build_stream(input int fill_every, input int corrupt_after);
    int seq [4] = '{0, 0, 0, 0};
    for (int i = 0; i < frames.size(); i++) begin
      if (corrupt_after == i) src_q.push_back({64'h0123_4567_89AB_CDEF, 64'h5555_0000_FFFF_1111});
      push_record(frames[i], seq[frames[i].port]++);
      if (fill_every > 0 && i % fill_every == fill_every - 1) begin
        src_q.push_back('0);
        src_q.push_back('0);
      end
    end
  endtask

  task automatic reset_capture_state();
    for (int p = 0; p < 4; p++) rxq[p].delete();
    rel_q.delete();
    sent_f.delete();
  endtask

  // check the frames on the wire against sent_f and the timing against the
  // schedule; rate = RATE_INV (TIMED), or gap (FIXED), b2b = no timing
  task automatic check_run(input string name, input int mode, input longint unsigned rate,
                           input longint unsigned gap, input int bad_mode);
    longint unsigned tgt, tgt0, rel, prev_rel;
    real d, dmax = 0, dsum = 0, lmax = 0, lsum = 0;
    int n = sent_f.size();
    if (rxq[tx_port].size() != n)
      fail($sformatf("%s: %0d frames on the wire, expected %0d", name, rxq[tx_port].size(), n));
    if (rel_q.size() != n)
      fail($sformatf("%s: %0d releases, expected %0d", name, rel_q.size(), n));
    for (int p = 0; p < 4; p++)
      if (p != tx_port && rxq[p].size() != 0) fail($sformatf("%s: %0d frames on P%0d", name, rxq[p].size(), p));
    if (rpl_gap_err) fail($sformatf("%s: tvalid dropped inside a frame %0d times", name, rpl_gap_err));
    for (int p = 0; p < 4; p++)
      if (tx_underflow[p]) fail($sformatf("%s: MAC TX underflow on P%0d", name, p));
    for (int i = 0; i < n && i < rxq[tx_port].size() && i < rel_q.size(); i++) begin
      Frame f = sent_f[i];
      rx_frame_t r = rxq[tx_port][i];
      bit exp_bad = f.bad && bad_mode == 1;
      // /V/ over the FCS: the far receiver ends the frame 6 bytes early (5 for an
      // odd length: the /V/ lands in the second byte lane)
      int exp_len = exp_bad ? f.data.size() - 6 + (f.data.size() % 2) : f.data.size();
      if (r.bad != exp_bad) fail($sformatf("%s: frame %0d bad flag %0d, expected %0d", name, i, r.bad, exp_bad));
      if (r.data.size() != exp_len)
        fail($sformatf("%s: frame %0d: %0d bytes, expected %0d", name, i, r.data.size(), exp_len));
      else
        for (int b = 0; b < exp_len; b++)
          if (r.data[b] != f.data[b]) begin
            fail($sformatf("%s: frame %0d byte %0d differs", name, i, b)); break;
          end
      rel = rel_q[i];
      if (mode == 0) tgt = t0_rd + (((f.ts - tsf_rd) * rate) >> 16);
      else if (mode == 2) tgt = t0_rd + i * gap;
      else tgt = 0;
      if (mode != 1) begin
        // never early, at most one dp_clk step (4 ns + fraction carry) + 1 ns late
        if (rel < tgt || rel > tgt + 6)
          fail($sformatf("%s: frame %0d released at target + (%0d) ns", name, i, longint'(rel) - longint'(tgt)));
        if (i == 0) tgt0 = tgt;
        lsum += real'(rel - tgt);
        if (real'(rel - tgt) > lmax) lmax = real'(rel - tgt);
        // wire: start-to-start relative to frame 0 vs the schedule
        d = (rxq[tx_port][i].sof - rxq[tx_port][0].sof) - real'(tgt - tgt0);
        if (d < 0) d = -d;
        dsum += d;
        if (d > dmax) dmax = d;
      end
      prev_rel = rel;
    end
    if (mode != 1) begin
      $display("INFO: %s: %0d frames, release - target mean %.2f max %.0f ns; wire start vs schedule |d| mean %.2f max %.2f ns",
               name, n, lsum / n, lmax, dsum / n, dmax);
      if (dmax > 16.0 + 6.0) fail($sformatf("%s: wire timing error %.2f ns > 22 ns", name, dmax));
    end
  endtask

  // configure + ARM (before the stream starts, as pktrec-replay does before
  // PLAY_START), then queue the stream, optionally wait for the store to fill, GO
  task automatic start_run(input [31:0] ctl, input int rate, input int gap, input longint unsigned exp_n,
                           input int delay_ns, input bit prefill, input int fill_every = 0,
                           input int corrupt_after = -1);
    rwr(R_CTRL, ctl);
    rwr(R_RATE, rate);
    rwr(R_GAP, gap);
    rwr(R_DELAY, delay_ns);
    rwr(R_EXP_LO, exp_n[31:0]);
    rwr(R_EXP_HI, exp_n[63:32]);
    repeat (20) @(posedge dp_clk);
    rwr(R_CMD, CMD_ARM);
    build_stream(fill_every, corrupt_after);
    if (prefill) begin
      // wait until the store is full or the stream is in
      logic [31:0] lv;
      do begin repeat (200) @(posedge dp_clk); rrd(R_LEVEL, lv); end
      while (src_q.size() > 0 && lv[15:0] < 8192 - 100 && lv[31:16] < 2000);
    end
    rwr(R_CMD, CMD_GO);
    rrd64(R_T0, t0_rd);
  endtask

  // ---------------------------------------------------------------------------
  // Tests
  // ---------------------------------------------------------------------------
  task automatic run_all();
    logic [31:0] d;
    longint unsigned v, ts;
    int n_other, n_bad, n_fill_units;

    #50;
    dp_resetn = 1; src_resetn = 1; ctrl_aresetn = 1; tx_aresetn = 4'hF;
    #500;

    // ---- 1. registers ----
    rexp(R_ID, 32'h504B5250, "ID");
    rexp(R_VERSION, 32'h00010000, "VERSION");
    rexp(R_CTRL, 32'h0, "CTRL reset");
    rexp(R_STATUS, 32'h0, "STATUS reset");
    rexp(R_RATE, 32'h0001_0000, "RATE_INV reset");
    rexp(R_DELAY, 32'd1_000_000, "START_DELAY reset");
    rexp(R_LATE_TH, 32'd100, "LATE_THRESH reset");
    rexp(R_STORE, 32'd8192, "STORE_BEATS");
    rexp(R_MAXCAP, 32'd16384, "MAX_CAP");
    mrd(M_VERSION, d);
    if (d !== 32'h00010004) fail($sformatf("m0 VERSION 0x%08x", d));
    mwr(M_RPL, 32'h4);                       // P2 = replay
    mwr(M_PATH_CTRL, 32'h0);
    repeat (40) @(posedge ctrl_clk);
    mrd(M_RPL, d);
    if (d !== 32'h4) fail($sformatf("PATH_RPL 0x%08x", d));
    mrd(M_EFF, d);
    if (d !== 32'h400) fail($sformatf("EFF_PATH 0x%08x, expected 0x400", d));
    repeat (20) @(posedge dp_clk);
    rwr(R_CTRL, 32'h2001);                   // SEL, TX_PORT 2
    repeat (20) @(posedge dp_clk);
    rrd(R_STATUS, d);
    if (!d[11]) fail("STATUS.TX port in REPLAY not set");
    rwr(R_CTRL, 32'h0);
    repeat (20) @(posedge dp_clk);

    // ---- 2. SEL = 0 pass-through ----
    for (int i = 0; i < 37; i++) src_q.push_back({4{$urandom()}});
    wait (src_q.size() == 0);
    repeat (100) @(posedge src_clk);
    if (chk_beats != 37) fail($sformatf("SEL=0: %0d beats at the checker, expected 37", chk_beats));
    cexp(C_BEATS, 0, "SEL=0 BEATS_IN");
    $display("INFO: 2 pass-through done");

    // ---- 3. TIMED 1x, filter, fill, corrupt header, bad frames sent bad ----
    reset_capture_state();
    frames.delete();
    ts = 64'd1_759_999_000_000_000_000;
    n_other = 0; n_bad = 0;
    for (int i = 0; i < 150; i++) begin
      int len = ($urandom_range(9) == 0) ? 1514 : $urandom_range(60, 600);
      bit bad = ($urandom_range(14) == 0);
      Frame f = mk(ts, len, 1, bad);
      f.sent = 1;
      frames.push_back(f);
      sent_f.push_back(f);
      if (bad) n_bad++;
      if (i % 7 == 3) begin                 // a record of port 3 (filtered)
        Frame o = mk(ts + 100, $urandom_range(60, 200), 3, 0);
        frames.push_back(o);
        n_other++;
      end
      ts += wire_ns(len) + $urandom_range(0, 3000);
    end
    n_fill_units = 2 * (frames.size() / 10);
    tx_port = 2;
    start_run(ctrl(0, 1, 1, 1, 2), 32'h10000, 0, frames.size(), 30000, 1, 10, 40);
    rrd64(R_TSF, tsf_rd);
    if (tsf_rd != frames[0].ts) fail($sformatf("TS_FIRST %0d, expected %0d", tsf_rd, frames[0].ts));
    wait_state(ST_DONE, 3000, "3 TIMED");
    repeat (500) @(posedge tx_clk[2]);
    check_run("3 TIMED 1x", 0, 64'h10000, 0, 1);
    cexp(C_RECORDS, frames.size(), "3 RECORDS");
    cexp(C_DONE, frames.size(), "3 RECORDS_DONE");
    cexp(C_FRAMES, 150, "3 FRAMES");
    cexp(C_SKIP, n_other, "3 SKIPPED");
    cexp(C_PERR, 1, "3 PARSE_ERRORS");
    cexp(C_FILL, n_fill_units, "3 FILL");
    cexp(C_BAD, n_bad, "3 BAD_SENT");
    cexp(C_UNDER, 0, "3 UNDERRUNS");
    cexp(C_LATE, 0, "3 LATE");
    v = 0; foreach (sent_f[i]) v += sent_f[i].data.size();
    cexp(C_BYTES, v, "3 BYTES");
    rrd(R_STATUS, d);
    if (d[10:8] != 3'b010) fail($sformatf("3: sticky flags 0x%0x, expected PARSE_ERROR only", d[10:8]));
    $display("INFO: 3 done (%0d frames, %0d skipped, %0d bad)", sent_f.size(), n_other, n_bad);

    // ---- 4. rate 0.5x (bad frames skipped) and 2x (bad frames sent good) ----
    for (int r = 0; r < 2; r++) begin
      int rate = r ? 32'h8000 : 32'h20000;
      int bm = r ? 0 : 2;
      reset_capture_state();
      frames.delete();
      ts = 64'd5_000_000_000;
      n_bad = 0;
      for (int i = 0; i < 80; i++) begin
        int len = $urandom_range(60, 1514);
        bit bad = ($urandom_range(7) == 0);
        Frame f = mk(ts, len, 0, bad);
        frames.push_back(f);
        if (!(bad && bm == 2)) sent_f.push_back(f);
        if (bad) n_bad++;
        // spacing such that the scaled interval still exceeds the wire time
        ts += (wire_ns(len) * 2 * (r ? 2 : 1)) + $urandom_range(0, 2000);
      end
      start_run(ctrl(0, bm, 0, 0, 2), rate, 0, frames.size(), 20000, 1);
      rrd64(R_TSF, tsf_rd);
      wait_state(ST_DONE, 4000, "4 rate");
      repeat (500) @(posedge tx_clk[2]);
      begin
        string nm;
        if (r) nm = "4 rate 2x"; else nm = "4 rate 0.5x";
        check_run(nm, 0, rate, 0, bm);
      end
      cexp(C_SKIP, bm == 2 ? n_bad : 0, "4 SKIPPED");
      cexp(C_BAD, 0, "4 BAD_SENT");
      cexp(C_LATE, 0, "4 LATE");
    end

    // ---- 5. back-to-back, 600 x 64-byte frames ----
    reset_capture_state();
    frames.delete();
    for (int i = 0; i < 600; i++) begin
      Frame f = mk(64'd1000 * i, 60, 2, 0);
      frames.push_back(f);
      sent_f.push_back(f);
    end
    src_stall_pct = 0;
    start_run(ctrl(1, 0, 0, 0, 2), 32'h10000, 0, frames.size(), 2000, 1);
    wait_state(ST_DONE, 3000, "5 b2b");
    repeat (500) @(posedge tx_clk[2]);
    check_run("5 back-to-back", 1, 0, 0, 0);
    begin
      real sp, smin = 1e9, smax = 0;
      for (int i = 1; i < rxq[2].size(); i++) begin
        sp = rxq[2][i].sof - rxq[2][i - 1].sof;
        if (sp < smin) smin = sp;
        if (sp > smax) smax = sp;
      end
      $display("INFO: 5 back-to-back: start-to-start min %.1f max %.1f ns (line rate 672)", smin, smax);
      if (smin < 671.0 || smax > 673.0) fail("5: not at line rate");
    end
    cexp(C_UNDER, 0, "5 UNDERRUNS");
    src_stall_pct = 20;

    // ---- 6. fixed gap ----
    reset_capture_state();
    frames.delete();
    for (int i = 0; i < 40; i++) begin
      Frame f = mk(64'd7 * i, $urandom_range(60, 200), 2, 0);
      frames.push_back(f);
      sent_f.push_back(f);
    end
    tx_port = 1;
    mwr(M_RPL, 32'h2);
    repeat (40) @(posedge ctrl_clk);
    start_run(ctrl(2, 0, 0, 0, 1), 32'h10000, 2500, frames.size(), 5000, 1);
    wait_state(ST_DONE, 1000, "6 fixed");
    repeat (500) @(posedge tx_clk[1]);
    check_run("6 fixed gap 2500 ns (P1)", 2, 0, 2500, 0);
    tx_port = 2;
    mwr(M_RPL, 32'h4);
    repeat (40) @(posedge ctrl_clk);

    // ---- 7. underrun: TIMED, source pause mid-stream ----
    reset_capture_state();
    frames.delete();
    ts = 64'd9_000_000;
    for (int i = 0; i < 100; i++) begin
      Frame f = mk(ts, 100, 2, 0);
      frames.push_back(f);
      sent_f.push_back(f);
      ts += 2000;
    end
    src_beats = 0;
    pause_at = 45 * 8;                       // ~frame 45 (8 beats per record)
    pause_len = 150000;                      // frame 45 is due ~93 us after GO
    start_run(ctrl(0, 0, 0, 0, 2), 32'h10000, 0, frames.size(), 3000, 0);
    rrd64(R_TSF, tsf_rd);
    wait_state(ST_DONE, 2000, "7 underrun");
    repeat (500) @(posedge tx_clk[2]);
    rrd(R_STATUS, d);
    rrd64(C_UNDER, v);
    $display("INFO: 7 underrun TIMED: UNDERRUNS %0d, STATUS 0x%08x", v, d);
    if (v == 0 || !d[8]) fail("7: no underrun reported");
    rrd64(C_LATE, v);
    if (v == 0 || !d[10]) fail("7: no late frames reported");
    rrd(R_MAX_LATE, d);
    $display("INFO: 7 MAX_LATE %0d ns, LATE %0d frames", d, v);
    if (rxq[2].size() != 100) fail($sformatf("7: %0d frames on the wire", rxq[2].size()));
    for (int i = 0; i < rxq[2].size(); i++)
      if (rxq[2][i].data != sent_f[i].data || rxq[2][i].bad) begin
        fail($sformatf("7: frame %0d differs", i)); break;
      end
    // back-to-back with EXPECT and a pause
    reset_capture_state();
    frames.delete();
    for (int i = 0; i < 200; i++) begin
      Frame f = mk(64'd0, 200, 2, 0);
      frames.push_back(f);
      sent_f.push_back(f);
    end
    src_beats = 0;
    pause_at = 20 * 14;                      // 20 frames = 36 us of line rate
    pause_len = 80000;
    start_run(ctrl(1, 0, 0, 0, 2), 32'h10000, 0, frames.size(), 2000, 0);
    wait_state(ST_DONE, 2000, "7 b2b underrun");
    repeat (500) @(posedge tx_clk[2]);
    rrd64(C_UNDER, v);
    $display("INFO: 7 underrun back-to-back: UNDERRUNS %0d", v);
    if (v == 0) fail("7 b2b: no underrun reported");
    check_run("7 b2b underrun", 1, 0, 0, 0);

    // ---- 8. abort mid-stream, then a new run; STOP ----
    reset_capture_state();
    frames.delete();
    ts = 64'd100;
    for (int i = 0; i < 120; i++) begin       // 11520 beats > the 8192-beat store
      Frame f = mk(ts, 1514, 2, 0);
      frames.push_back(f);
      ts += 20000;
    end
    start_run(ctrl(0, 0, 0, 0, 2), 32'h10000, 0, frames.size(), 3000, 1);
    // abort while frame 6 is being sent
    wait (rel_q.size() == 7);
    repeat (100) @(posedge dp_clk);
    rwr(R_CMD, CMD_ABORT);
    wait_state(ST_IDLE, 200, "8 abort");
    repeat (2000) @(posedge tx_clk[2]);
    if (rxq[2].size() != 7) fail($sformatf("8: %0d frames after abort, expected 7", rxq[2].size()));
    for (int i = 0; i < rxq[2].size(); i++)
      if (rxq[2][i].data != frames[i].data) begin fail($sformatf("8: frame %0d differs", i)); break; end
    rexp(R_LEVEL, 32'h0, "8 store empty after abort");
    wait (src_q.size() == 0);
    repeat (200) @(posedge dp_clk);
    rrd64(C_DISCARD, v);
    $display("INFO: 8 abort: 7 frames sent complete, %0d beats discarded", v);
    if (v == 0) fail("8: stream after abort not drained");
    // STOP-terminated run (EXPECT = 0)
    reset_capture_state();
    frames.delete();
    ts = 64'd100;
    for (int i = 0; i < 20; i++) begin
      Frame f = mk(ts, $urandom_range(60, 300), 2, 0);
      frames.push_back(f);
      sent_f.push_back(f);
      ts += 5000;
    end
    start_run(ctrl(0, 0, 0, 0, 2), 32'h10000, 0, 0, 3000, 1);
    rrd64(R_TSF, tsf_rd);
    wait (src_q.size() == 0);
    rwr(R_CMD, CMD_STOP);
    wait_state(ST_DONE, 500, "8 stop");
    repeat (500) @(posedge tx_clk[2]);
    check_run("8 STOP run", 0, 64'h10000, 0, 0);

    if (errors == 0) $display("PASS: tb_pktrec_replay");
    else $display("FAIL: tb_pktrec_replay, %0d error(s)", errors);
    $finish;
  endtask

  initial run_all();

  initial begin
    #30ms;
    $display("FAIL: tb_pktrec_replay watchdog timeout");
    $finish;
  end

endmodule
