// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_pktrec_capture -- integration testbench: capture path -> recorder
//
//   4 MAC RX models (rx_clk_n ~62.5 MHz, different ppm; tuser timestamp =
//   the DUT's own rx_ptp_ts_n sampled at the first beat, like the Taxi MAC)
//     -> pktrec_capture (module-reference top: 4 x pktrec_cap_port,
//        pktrec_cap_merge, pktrec_timebase, pktrec_cap_regs)
//     -> fdrec_core in capture mode (cap_sel, s_axis_cap, rec_srst)
//     -> AXI DMA S2MM model (random tready; checks TLAST every PKT_LEN beats
//        and TKEEP all ones) collecting the byte stream
// Both register blocks are driven through AXI4-Lite BFMs, following the
// start/stop protocol documented in include/pktrec_regs.h.
//
// Checks:
//   1. ID / VERSION / reset values; fdrec VERSION 1.2 and PKT_SRC follows SRC_SEL
//   2. timebase: TB_SET then TB_NOW reads back set value + elapsed time;
//      TB_STATUS shows all MAC domains valid
//   3. capture of random traffic on all 4 ports (random sizes, bad frames,
//      DMA back-pressure): stop protocol (ENABLE=0, IDLE, BYTES_OUT, FILL,
//      collect >= BYTES_OUT, packetizer off). The first BYTES_OUT bytes of the
//      DMA stream parse as records only; every frame of every port is there,
//      in per-port order, bytes exact; per-port timestamps increase; after
//      BYTES_OUT only fill (zeros); RECORDS_OUT, per-port FRAMES_RX / RECORDS /
//      BYTES_RX registers exact; fdrec ING_DROP_COUNT = 0
//   4. recorder soft reset while records are in flight (capture enabled while
//      the packetizer is off, then FDREC START = SOFT_RST): the recorded stream
//      still starts on a record boundary and parses cleanly; FRAMES_RX =
//      RECORDS + FRAMES_DROP per port at the end (no silent loss)
//   5. end to end SFD timestamping (M2, real ISERDES/MMCM models): RX SFD
//      level pulses on PHY GPIO_0 of port 2 shortly before each frame ->
//      records with TS_MAC = 0 whose timestamp differences equal the pulse
//      time differences within +-1 ns; SFD registers through the AXI-Lite
//      forwarding (SFD_STATUS locked, RX_EDGES, RX_MATCHED, MISMATCH 0)
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

module tb_pktrec_capture;

  localparam int PKT_LEN = 64;      // beats per DMA packet

  int errors = 0;
  task automatic fail(input string msg);
    errors++;
    if (errors < 40) $display("FAIL: %s (t=%0t)", msg, $time);
  endtask

  // ---------------------------------------------------------------------------
  // clocks
  // ---------------------------------------------------------------------------
  reg dp_clk = 0, src_clk = 0;
  always #2.0 dp_clk = ~dp_clk;
  always #2.5 src_clk = ~src_clk;
  reg [3:0] rx_clk = 0, tx_clk = 0;
  initial begin #1.1; forever #7.999 rx_clk[0] = ~rx_clk[0]; end
  initial begin #3.7; forever #8.001 rx_clk[1] = ~rx_clk[1]; end
  initial begin #5.3; forever #8.002 rx_clk[2] = ~rx_clk[2]; end
  initial begin #6.9; forever #7.998 rx_clk[3] = ~rx_clk[3]; end
  always #8.0 tx_clk = ~tx_clk;
  reg dp_resetn = 0, src_resetn = 0;
  reg [3:0] rx_aresetn = 0;

  // ---------------------------------------------------------------------------
  // DUTs
  // ---------------------------------------------------------------------------
  reg  [15:0] rx_tdata [4];
  reg  [1:0]  rx_tkeep [4];
  reg  [3:0]  rx_tvalid = 0, rx_tlast = 0;
  reg  [64:0] rx_tuser [4];
  wire [63:0] rx_ts [4];
  wire [63:0] tx_ts [4];
  initial for (int k = 0; k < 4; k++) begin rx_tdata[k] = 0; rx_tkeep[k] = 0; rx_tuser[k] = 0; end

  reg  [3:0]  phy_gpio0 = 0;
  wire [127:0] rec_tdata;
  wire         rec_tvalid, rec_tready, cap_sel, rec_srst;

  // two AXI-Lite buses (c = capture, f = fdrec)
  reg  [11:0] c_awaddr = 0, c_araddr = 0, f_awaddr = 0, f_araddr = 0;
  reg         c_awvalid = 0, c_wvalid = 0, c_bready = 0, c_arvalid = 0, c_rready = 0;
  reg         f_awvalid = 0, f_wvalid = 0, f_bready = 0, f_arvalid = 0, f_rready = 0;
  reg  [31:0] c_wdata = 0, f_wdata = 0;
  wire        c_awready, c_wready, c_bvalid, c_arready, c_rvalid;
  wire        f_awready, f_wready, f_bvalid, f_arready, f_rvalid;
  wire [1:0]  c_bresp, c_rresp, f_bresp, f_rresp;
  wire [31:0] c_rdata, f_rdata;

  pktrec_capture #(.DP_CLK_HZ(250000000), .FIFO_BYTES(16384)) cap (
    .dp_clk(dp_clk), .dp_resetn(dp_resetn),
    .rx_clk_0(rx_clk[0]), .rx_aresetn_0(rx_aresetn[0]),
    .s_axis_rx_0_tdata(rx_tdata[0]), .s_axis_rx_0_tkeep(rx_tkeep[0]), .s_axis_rx_0_tvalid(rx_tvalid[0]),
    .s_axis_rx_0_tlast(rx_tlast[0]), .s_axis_rx_0_tuser(rx_tuser[0]),
    .rx_ptp_ts_0(rx_ts[0]), .tx_clk_0(tx_clk), .tx_aresetn_0(1'b1), .tx_ptp_ts_0(tx_ts[0]),
    .s_axis_tx_cpl_0_tdata(64'd0), .s_axis_tx_cpl_0_tid(8'd0), .s_axis_tx_cpl_0_tvalid(1'b0),
    .rx_clk_1(rx_clk[1]), .rx_aresetn_1(rx_aresetn[1]),
    .s_axis_rx_1_tdata(rx_tdata[1]), .s_axis_rx_1_tkeep(rx_tkeep[1]), .s_axis_rx_1_tvalid(rx_tvalid[1]),
    .s_axis_rx_1_tlast(rx_tlast[1]), .s_axis_rx_1_tuser(rx_tuser[1]),
    .rx_ptp_ts_1(rx_ts[1]), .tx_clk_1(tx_clk), .tx_aresetn_1(1'b1), .tx_ptp_ts_1(tx_ts[1]),
    .s_axis_tx_cpl_1_tdata(64'd0), .s_axis_tx_cpl_1_tid(8'd0), .s_axis_tx_cpl_1_tvalid(1'b0),
    .rx_clk_2(rx_clk[2]), .rx_aresetn_2(rx_aresetn[2]),
    .s_axis_rx_2_tdata(rx_tdata[2]), .s_axis_rx_2_tkeep(rx_tkeep[2]), .s_axis_rx_2_tvalid(rx_tvalid[2]),
    .s_axis_rx_2_tlast(rx_tlast[2]), .s_axis_rx_2_tuser(rx_tuser[2]),
    .rx_ptp_ts_2(rx_ts[2]), .tx_clk_2(tx_clk), .tx_aresetn_2(1'b1), .tx_ptp_ts_2(tx_ts[2]),
    .s_axis_tx_cpl_2_tdata(64'd0), .s_axis_tx_cpl_2_tid(8'd0), .s_axis_tx_cpl_2_tvalid(1'b0),
    .rx_clk_3(rx_clk[3]), .rx_aresetn_3(rx_aresetn[3]),
    .s_axis_rx_3_tdata(rx_tdata[3]), .s_axis_rx_3_tkeep(rx_tkeep[3]), .s_axis_rx_3_tvalid(rx_tvalid[3]),
    .s_axis_rx_3_tlast(rx_tlast[3]), .s_axis_rx_3_tuser(rx_tuser[3]),
    .rx_ptp_ts_3(rx_ts[3]), .tx_clk_3(tx_clk), .tx_aresetn_3(1'b1), .tx_ptp_ts_3(tx_ts[3]),
    .s_axis_tx_cpl_3_tdata(64'd0), .s_axis_tx_cpl_3_tid(8'd0), .s_axis_tx_cpl_3_tvalid(1'b0),
    .m_axis_rec_tdata(rec_tdata), .m_axis_rec_tvalid(rec_tvalid), .m_axis_rec_tready(rec_tready),
    .cap_sel(cap_sel), .rec_srst(rec_srst),
    .phy_gpio0(phy_gpio0), .phy_gpio1(4'd0), .phy_gpio0_lvl(), .phy_gpio1_lvl(),
    .s_axi_awaddr(c_awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(c_awvalid), .s_axi_awready(c_awready),
    .s_axi_wdata(c_wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(c_wvalid), .s_axi_wready(c_wready),
    .s_axi_bresp(c_bresp), .s_axi_bvalid(c_bvalid), .s_axi_bready(c_bready),
    .s_axi_araddr(c_araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(c_arvalid), .s_axi_arready(c_arready),
    .s_axi_rdata(c_rdata), .s_axi_rresp(c_rresp), .s_axi_rvalid(c_rvalid), .s_axi_rready(c_rready)
  );

  wire [127:0] m_tdata;
  wire [15:0]  m_tkeep;
  wire         m_tlast, m_tvalid;
  reg          m_tready = 0;

  fdrec_core #(.SRC_CLK_HZ(200000000), .DP_CLK_HZ(250000000), .FIFO_DEPTH(1024)) rec (
    .src_clk(src_clk), .src_resetn(src_resetn), .dp_clk(dp_clk), .dp_resetn(dp_resetn),
    .s_axis_tdata(128'd0), .s_axis_tvalid(1'b0), .s_axis_tready(),
    .s_axis_cap_tdata(rec_tdata), .s_axis_cap_tvalid(rec_tvalid), .s_axis_cap_tready(rec_tready),
    .cap_sel(cap_sel), .rec_srst(rec_srst),
    .m_axis_tdata(m_tdata), .m_axis_tkeep(m_tkeep), .m_axis_tlast(m_tlast),
    .m_axis_tvalid(m_tvalid), .m_axis_tready(m_tready),
    .s_axi_awaddr(f_awaddr), .s_axi_awprot(3'b0), .s_axi_awvalid(f_awvalid), .s_axi_awready(f_awready),
    .s_axi_wdata(f_wdata), .s_axi_wstrb(4'hF), .s_axi_wvalid(f_wvalid), .s_axi_wready(f_wready),
    .s_axi_bresp(f_bresp), .s_axi_bvalid(f_bvalid), .s_axi_bready(f_bready),
    .s_axi_araddr(f_araddr), .s_axi_arprot(3'b0), .s_axi_arvalid(f_arvalid), .s_axi_arready(f_arready),
    .s_axi_rdata(f_rdata), .s_axi_rresp(f_rresp), .s_axi_rvalid(f_rvalid), .s_axi_rready(f_rready),
    .tpg_enable(), .tpg_seq_rst(), .tpg_rate_inc(), .tpg_seq_next(64'd0),
    .s_axis_mm2s_tdata(128'd0), .s_axis_mm2s_tkeep(16'hFFFF), .s_axis_mm2s_tlast(1'b0),
    .s_axis_mm2s_tvalid(1'b0), .s_axis_mm2s_tready(),
    .m_axis_snk_tdata(), .m_axis_snk_tlast(), .m_axis_snk_tvalid(), .m_axis_snk_tready(1'b0),
    .chk_enable(), .chk_reset(), .chk_rate_inc(),
    .chk_beats(64'd0), .chk_errors(64'd0), .chk_gaps(64'd0), .chk_gap_beats(64'd0),
    .chk_underflows(64'd0), .chk_last_seq(64'd0)
  );

  // ---------------------------------------------------------------------------
  // AXI-Lite BFMs (both buses on dp_clk)
  // ---------------------------------------------------------------------------
  task automatic cw(input [11:0] a, input [31:0] d);
    @(posedge dp_clk);
    c_awaddr <= a; c_wdata <= d; c_awvalid <= 1; c_wvalid <= 1; c_bready <= 1;
    @(posedge dp_clk);
    while (!(c_awready && c_wready)) @(posedge dp_clk);
    c_awvalid <= 0; c_wvalid <= 0;
    while (!c_bvalid) @(posedge dp_clk);
    @(posedge dp_clk); c_bready <= 0;
  endtask
  task automatic cr(input [11:0] a, output [31:0] d);
    @(posedge dp_clk);
    c_araddr <= a; c_arvalid <= 1; c_rready <= 1;
    @(posedge dp_clk);
    while (!c_arready) @(posedge dp_clk);
    c_arvalid <= 0;
    while (!c_rvalid) @(posedge dp_clk);
    d = c_rdata;
    @(posedge dp_clk); c_rready <= 0;
  endtask
  task automatic cr64(input [11:0] a, output [63:0] d);
    reg [31:0] lo, hi;
    cr(a, lo); cr(a + 12'h4, hi);
    d = {hi, lo};
  endtask
  task automatic fw(input [11:0] a, input [31:0] d);
    @(posedge dp_clk);
    f_awaddr <= a; f_wdata <= d; f_awvalid <= 1; f_wvalid <= 1; f_bready <= 1;
    @(posedge dp_clk);
    while (!(f_awready && f_wready)) @(posedge dp_clk);
    f_awvalid <= 0; f_wvalid <= 0;
    while (!f_bvalid) @(posedge dp_clk);
    @(posedge dp_clk); f_bready <= 0;
  endtask
  task automatic fr(input [11:0] a, output [31:0] d);
    @(posedge dp_clk);
    f_araddr <= a; f_arvalid <= 1; f_rready <= 1;
    @(posedge dp_clk);
    while (!f_arready) @(posedge dp_clk);
    f_arvalid <= 0;
    while (!f_rvalid) @(posedge dp_clk);
    d = f_rdata;
    @(posedge dp_clk); f_rready <= 0;
  endtask

  // register offsets (pktrec_regs.h / fdrec_regs.h)
  localparam [11:0] C_ID = 12'h000, C_VERSION = 12'h004, C_CTRL = 12'h008, C_STATUS = 12'h00C,
                    C_PORT_EN = 12'h010, C_SNAPLEN = 12'h014, C_FIFO_BYTES = 12'h01C,
                    C_BYTES_OUT = 12'h020, C_RECORDS_OUT = 12'h028, C_FILL = 12'h030,
                    C_SRST_ABORTS = 12'h040, C_LEN_FIXUPS = 12'h044,
                    C_TB_CTRL = 12'h080, C_TB_INC_NS = 12'h088, C_TB_STATUS = 12'h08C,
                    C_TB_NOW = 12'h090, C_TB_SET = 12'h098, C_MAC_OFFSET = 12'h0A8;
  localparam [11:0] P_FRAMES_RX = 12'h00, P_FRAMES_DROP = 12'h10, P_BYTES_RX = 12'h18,
                    P_RECORDS = 12'h30, P_SEQ = 12'h3C;
  localparam [31:0] CTRL_EN = 1, CTRL_FILL = 2, CTRL_SRC = 4, CTRL_CLEAR = 256;
  localparam [11:0] F_VERSION = 12'h000, F_GLOBAL = 12'h00C, F_ING_DROP = 12'h028,
                    F_PKT_CTRL = 12'h040, F_PKT_LEN = 12'h044, F_PKT_SRC = 12'h050;
  function automatic [11:0] preg(input int p, input [11:0] off);
    return 12'h100 + 12'(p * 64) + off;
  endfunction

  // ---------------------------------------------------------------------------
  // MAC RX models + scoreboards
  // ---------------------------------------------------------------------------
  class Frame;
    byte unsigned data[$];
    bit bad;
  endclass
  Frame tx_q [4][$];
  Frame exp_q [4][$];
  int   n_sent [4];
  longint unsigned bytes_sent [4];
  bit   busy [4];

  task automatic send(input int p, input int len, input bit bad);
    Frame f = new();
    for (int i = 0; i < len; i++) f.data.push_back($urandom_range(0, 255));
    f.bad = bad;
    tx_q[p].push_back(f);
    exp_q[p].push_back(f);
    n_sent[p]++;
    bytes_sent[p] += len + 4;
  endtask

  for (genvar gp = 0; gp < 4; gp++) begin : g_mac
    initial begin
      Frame f;
      int nb;
      forever begin
        @(posedge rx_clk[gp]);
        if (tx_q[gp].size() == 0) begin busy[gp] = 0; continue; end
        busy[gp] = 1;
        f = tx_q[gp].pop_front();
        nb = (f.data.size() + 1) / 2;
        for (int b = 0; b < nb; b++) begin
          rx_tdata[gp]  <= {(2*b+1 < f.data.size()) ? f.data[2*b+1] : 8'h00, f.data[2*b]};
          rx_tkeep[gp]  <= (2*b+1 < f.data.size()) ? 2'b11 : 2'b01;
          rx_tvalid[gp] <= 1'b1;
          rx_tlast[gp]  <= (b == nb - 1);
          // the MAC latches rx_ptp_ts at SFD and holds it in tuser for the frame
          if (b == 0) rx_tuser[gp][64:1] <= rx_ts[gp];
          rx_tuser[gp][0] <= (b == nb - 1) ? f.bad : 1'b0;
          @(posedge rx_clk[gp]);
        end
        rx_tvalid[gp] <= 1'b0;
        rx_tlast[gp]  <= 1'b0;
        repeat ($urandom_range(6, 40)) @(posedge rx_clk[gp]);
      end
    end
  end

  // ---------------------------------------------------------------------------
  // DMA S2MM model
  // ---------------------------------------------------------------------------
  byte unsigned stream[$];
  int  beat_in_pkt = 0;
  int  ready_pct = 50;
  always @(posedge dp_clk) begin
    m_tready <= ($urandom_range(1, 100) <= ready_pct);
    if (m_tvalid && m_tready) begin
      beat_in_pkt++;
      if (m_tkeep !== 16'hFFFF) fail("TKEEP not all ones");
      if (m_tlast !== (beat_in_pkt == PKT_LEN)) fail($sformatf("TLAST %0d at beat %0d of the packet", m_tlast, beat_in_pkt));
      if (m_tlast) beat_in_pkt = 0;
      for (int k = 0; k < 16; k++) stream.push_back(m_tdata[8*k +: 8]);
    end
  end

  // ---------------------------------------------------------------------------
  // stream parser: nbytes of records (fill units allowed), checks the scoreboard
  // ---------------------------------------------------------------------------
  int n_rec [4];
  bit expect_sfd = 0;
  longint unsigned ts_list [4][$];
  task automatic parse(input longint unsigned nbytes, input bit allow_drop);
    longint unsigned pos = 0;
    longint unsigned last_ts [4];
    int last_seq [4];
    for (int p = 0; p < 4; p++) begin last_ts[p] = 0; last_seq[p] = -1; n_rec[p] = 0; end
    while (pos < nbytes) begin
      longint unsigned ts;
      int cap, orig, port, flags, seq, nb;
      bit all_zero = 1;
      Frame f;
      for (int k = 0; k < 16; k++) if (stream[pos + k] != 0) all_zero = 0;
      if (all_zero) begin pos += 16; continue; end
      ts = 0;
      for (int k = 7; k >= 0; k--) ts = (ts << 8) | stream[pos + k];
      cap   = stream[pos + 8]  | (stream[pos + 9] << 8);
      orig  = stream[pos + 10] | (stream[pos + 11] << 8);
      port  = stream[pos + 12];
      flags = stream[pos + 13];
      seq   = stream[pos + 14] | (stream[pos + 15] << 8);
      if ((flags & 8'hF0) != 8'hA0 || port > 3 || cap < 1 || cap + 4 > orig) begin
        fail($sformatf("bad header at stream offset %0d (flags %02x port %0d cap %0d orig %0d)",
                       pos, flags, port, cap, orig));
        return;
      end
      nb = 16 + ((cap + 15) / 16) * 16;
      if (pos + nb > nbytes) begin fail($sformatf("record at %0d runs past BYTES_OUT", pos)); return; end
      // match against the scoreboard
      f = null;
      while (exp_q[port].size() > 0) begin
        f = exp_q[port].pop_front();
        if (f.data.size() == cap) begin
          bit same = 1;
          for (int i = 0; i < cap; i++) if (stream[pos + 16 + i] != f.data[i]) same = 0;
          if (same) break;
        end
        if (!allow_drop) fail($sformatf("port %0d: record seq %0d does not match the next expected frame", port, seq));
        f = null;
      end
      if (f == null) begin fail($sformatf("port %0d: record seq %0d not found", port, seq)); return; end
      if (((flags & 1) != 0) != f.bad) fail($sformatf("port %0d seq %0d: BAD flag %0d", port, seq, flags & 1));
      if (!expect_sfd && (flags & 4) == 0) fail("TS_MAC flag not set");
      if (expect_sfd && (flags & 12) != 0) fail($sformatf("port %0d seq %0d: flags %02x, expected an SFD timestamp", port, seq, flags));
      ts_list[port].push_back(ts);
      if (orig != cap + 4) fail($sformatf("port %0d seq %0d: orig_len %0d cap_len %0d", port, seq, orig, cap));
      if (last_seq[port] >= 0 && !allow_drop && seq != ((last_seq[port] + 1) & 16'hFFFF))
        fail($sformatf("port %0d: seq %0d after %0d", port, seq, last_seq[port]));
      if (ts < last_ts[port]) fail($sformatf("port %0d: timestamp went backwards", port));
      for (int i = cap; i < nb - 16; i++)
        if (stream[pos + 16 + i] != 0) fail("non-zero record padding");
      last_ts[port] = ts;
      last_seq[port] = seq;
      n_rec[port]++;
      pos += nb;
    end
  endtask

  task automatic wait_idle();
    reg [31:0] st;
    int t = 0;
    do begin cr(C_STATUS, st); t++; end while (!st[0] && t < 20000);
    if (!st[0]) fail("STATUS.IDLE never set");
  endtask

  task automatic wait_macs();
    while (tx_q[0].size() || tx_q[1].size() || tx_q[2].size() || tx_q[3].size() ||
           busy[0] || busy[1] || busy[2] || busy[3]) @(posedge dp_clk);
    repeat (500) @(posedge dp_clk);
  endtask

  // stop protocol, returns BYTES_OUT
  task automatic stop_capture(output longint unsigned bytes_out);
    reg [63:0] v;
    wait_macs();                       // all test frames are on the wire
    cw(C_CTRL, CTRL_SRC);
    wait_idle();
    cr64(C_BYTES_OUT, v); bytes_out = v;
    cw(C_CTRL, CTRL_SRC | CTRL_FILL);
    while (stream.size() < bytes_out || beat_in_pkt != 0) @(posedge dp_clk);
    fw(F_PKT_CTRL, 0);
    repeat (50) @(posedge dp_clk);
    cw(C_CTRL, CTRL_SRC);
  endtask

  task automatic fdrec_start();
    reg [31:0] v;
    fw(F_GLOBAL, 1);
    do fr(F_GLOBAL, v); while (v[0]);
    fw(F_PKT_LEN, PKT_LEN);
    beat_in_pkt = 0;                   // like the driver: a new DMA chain
    fw(F_PKT_CTRL, 1);
  endtask

  // ---------------------------------------------------------------------------
  // test sequence
  // ---------------------------------------------------------------------------
  reg [31:0] v;
  reg [63:0] v64, a64;
  longint unsigned bytes_out;
  int total;

  initial begin
    $display("tb_pktrec_capture: start");
    repeat (20) @(posedge dp_clk);
    dp_resetn <= 1; src_resetn <= 1;
    repeat (10) @(posedge dp_clk);
    rx_aresetn <= 4'hF;
    repeat (300) @(posedge dp_clk);

    // ---- 1. identity / reset values ----
    cr(C_ID, v);      if (v !== 32'h504B4350) fail($sformatf("ID %08x", v));
    cr(C_VERSION, v); if (v !== 32'h0001_0002) fail($sformatf("VERSION %08x", v));
    cr(C_CTRL, v);    if (v !== 0) fail($sformatf("CTRL reset %08x", v));
    cr(C_PORT_EN, v); if (v !== 32'hF) fail($sformatf("PORT_EN reset %08x", v));
    cr(C_FIFO_BYTES, v); if (v !== 16384) fail($sformatf("PORT_FIFO_BYTES %0d", v));
    cr(C_MAC_OFFSET, v); if (v !== 52) fail($sformatf("MAC_OFFSET reset %0d", v));
    cr(C_TB_INC_NS, v); if (v !== 4) fail($sformatf("TB_INC_NS %0d", v));
    fr(F_VERSION, v); if (v !== 32'h0001_0002) fail($sformatf("fdrec VERSION %08x", v));
    fr(F_PKT_SRC, v); if (v !== 0) fail("PKT_SRC not 0 after reset");
    cw(C_CTRL, CTRL_SRC);
    fr(F_PKT_SRC, v); if (v !== 1) fail("PKT_SRC does not follow SRC_SEL");
    cr(C_STATUS, v);  if (!v[0]) fail("not IDLE after reset");

    // ---- 2. timebase ----
    cr(C_TB_STATUS, v); if (v[7:0] !== 8'hFF) fail($sformatf("TB_STATUS %02x", v[7:0]));
    cw(C_TB_SET, 32'h8000_0000); cw(C_TB_SET + 4, 32'h1876_5432);
    cw(C_TB_CTRL, 1);
    cr64(C_TB_NOW, v64);
    if (v64 < 64'h1876_5432_8000_0000 || v64 > 64'h1876_5432_8000_0000 + 200)
      fail($sformatf("TB_NOW after SET = %016x", v64));

    // ---- 3. 4-port capture with back-pressure ----
    $display("test 3: 4-port capture");
    cw(C_CTRL, CTRL_SRC | CTRL_CLEAR);
    fdrec_start();
    cw(C_CTRL, CTRL_SRC | CTRL_EN);
    repeat (50) @(posedge dp_clk);             // ENABLE reaches the MAC clocks
    ready_pct = 50;
    for (int i = 0; i < 120; i++)
      for (int p = 0; p < 4; p++)
        send(p, (i % 9 == 0) ? 60 : $urandom_range(1, 1514), $urandom_range(0, 15) == 0);
    stop_capture(bytes_out);
    $display("  BYTES_OUT %0d, stream %0d bytes", bytes_out, stream.size());
    parse(bytes_out, 0);
    for (int i = bytes_out; i < stream.size(); i++)
      if (stream[i] != 0) begin fail($sformatf("non-fill byte after BYTES_OUT at %0d", i)); break; end
    total = 0;
    for (int p = 0; p < 4; p++) begin
      if (n_rec[p] != n_sent[p]) fail($sformatf("port %0d: %0d records, %0d frames sent", p, n_rec[p], n_sent[p]));
      if (exp_q[p].size() != 0) fail($sformatf("port %0d: %0d frames missing", p, exp_q[p].size()));
      cr64(preg(p, P_FRAMES_RX), v64);  if (v64 != n_sent[p]) fail($sformatf("port %0d FRAMES_RX %0d", p, v64));
      cr64(preg(p, P_RECORDS), v64);    if (v64 != n_sent[p]) fail($sformatf("port %0d RECORDS %0d", p, v64));
      cr64(preg(p, P_BYTES_RX), v64);   if (v64 != bytes_sent[p]) fail($sformatf("port %0d BYTES_RX %0d", p, v64));
      cr64(preg(p, P_FRAMES_DROP), v64); if (v64 != 0) fail($sformatf("port %0d FRAMES_DROP %0d", p, v64));
      total += n_sent[p];
    end
    cr64(C_RECORDS_OUT, v64); if (v64 != total) fail($sformatf("RECORDS_OUT %0d, expected %0d", v64, total));
    cr64(C_FILL, v64);        if (v64 == 0) fail("FILL_BEATS = 0 after a FILL stop");
    cr(C_LEN_FIXUPS, v);      if (v != 0) fail($sformatf("LEN_FIXUPS %0d", v));
    fr(F_ING_DROP, v);        if (v != 0) fail("fdrec ING_DROP_COUNT != 0");

    // ---- 4. soft reset with records in flight ----
    $display("test 4: recorder soft reset with records in flight");
    stream.delete();
    for (int p = 0; p < 4; p++) begin n_sent[p] = 0; bytes_sent[p] = 0; exp_q[p].delete(); end
    cw(C_CTRL, CTRL_SRC | CTRL_CLEAR);
    fw(F_GLOBAL, 1);                            // empty the packetizer (fill beats of test 3)
    do fr(F_GLOBAL, v); while (v[0]);
    cw(C_CTRL, CTRL_SRC | CTRL_EN);             // packetizer still off: records back up
    repeat (50) @(posedge dp_clk);
    for (int i = 0; i < 40; i++)
      for (int p = 0; p < 4; p++) send(p, $urandom_range(60, 1514), 0);
    repeat (3000) @(posedge dp_clk);
    fdrec_start();                              // SOFT_RST cuts whatever is in flight
    stop_capture(bytes_out);
    cr(C_SRST_ABORTS, v);
    $display("  BYTES_OUT %0d, SRST_ABORTS %0d", bytes_out, v);
    if (v == 0) fail("test 4: the soft reset did not cut a record (test did not exercise the abort path)");
    parse(bytes_out, 1);
    for (int p = 0; p < 4; p++) begin
      reg [63:0] rx, rc, dr;
      cr64(preg(p, P_FRAMES_RX), rx); cr64(preg(p, P_RECORDS), rc); cr64(preg(p, P_FRAMES_DROP), dr);
      if (rx != n_sent[p]) fail($sformatf("port %0d FRAMES_RX %0d, sent %0d", p, rx, n_sent[p]));
      if (rx != rc + dr) fail($sformatf("port %0d FRAMES_RX %0d != RECORDS %0d + DROP %0d", p, rx, rc, dr));
      if (n_rec[p] == 0) fail($sformatf("port %0d: nothing recorded after the soft reset", p));
    end

    // ---- 5. SFD timestamps end to end ----
    $display("test 5: SFD timestamps end to end (port 2)");
    cr(12'h404, v); if (v[1:0] !== 2'b11) fail($sformatf("SFD_STATUS %08x (locked, ISERDES)", v));
    stream.delete();
    for (int p = 0; p < 4; p++) begin n_sent[p] = 0; bytes_sent[p] = 0; exp_q[p].delete(); ts_list[p].delete(); end
    cw(C_CTRL, CTRL_SRC | CTRL_CLEAR);
    fdrec_start();
    cw(C_CTRL, CTRL_SRC | CTRL_EN);
    repeat (50) @(posedge dp_clk);
    begin
      realtime t_pin [$];
      for (int i = 0; i < 30; i++) begin
        #($urandom_range(0, 15999) / 1000.0);
        phy_gpio0[2] = 1;
        t_pin.push_back($realtime);
        #350;
        send(2, 200, 0);
        #1700;
        phy_gpio0[2] = 0;
        #1000;
      end
      expect_sfd = 1;
      stop_capture(bytes_out);
      parse(bytes_out, 0);
      expect_sfd = 0;
      if (n_rec[2] != 30) fail($sformatf("test 5: %0d records on port 2", n_rec[2]));
      for (int i = 1; i < ts_list[2].size() && i < t_pin.size(); i++) begin
        real dt_ts = real'(ts_list[2][i] - ts_list[2][0]);
        real dt_pin = t_pin[i] - t_pin[0];
        if (dt_ts - dt_pin > 1.001 || dt_ts - dt_pin < -1.001)
          fail($sformatf("test 5 frame %0d: ts delta %0.1f ns vs pin delta %0.3f ns", i, dt_ts, dt_pin));
      end
    end
    cr(12'h800 + 12'h200 + 12'h00, v); if (v != 30) fail($sformatf("P2 RX_EDGES %0d", v));
    cr(12'h800 + 12'h200 + 12'h10, v); if (v != 30) fail($sformatf("P2 RX_MATCHED %0d", v));
    cr(12'h800 + 12'h200 + 12'h1C, v); if (v != 0) fail($sformatf("P2 RX_MISMATCH %0d", v));
    cr(12'h800 + 12'h200 + 12'h20, v); $display("  P2 MATCH_DELTA last %0d ns (SFD -> MAC stamp, raw)", $signed(v));

    if (errors == 0) $display("tb_pktrec_capture: PASS");
    else $display("tb_pktrec_capture: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #30ms;
    $display("tb_pktrec_capture: FAIL (timeout)");
    $finish;
  end

endmodule
