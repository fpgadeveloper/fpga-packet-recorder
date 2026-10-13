// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_pktrec_m0_path -- self-checking testbench for the M0 Ethernet datapath
//
// Four MAC RX stream models (rx_clk_n, 62.5 MHz +- a few hundred ppm, no tready,
// 16-bit beats, odd lengths end with tkeep = 01, some frames marked bad on tlast)
// feed pktrec_m0_path; four TX MAC sink models (tx_clk_n, random tready stalls)
// collect what it sends. A scoreboard per TX port holds the frames it must see, in
// order. Registers are driven through an AXI4-Lite BFM.
//
// Checks:
//   1. ID / VERSION / PATH_CTRL reset value
//   2. LOOP on all ports (PATH_CTRL = 0x55): every frame comes back on its own
//      port, bytes / length / bad flag intact, tvalid never drops inside a frame
//   3. FWD on all ports (0xAA): RX0->TX1, RX1->TX0, RX2->TX3, RX3->TX2
//   4. Mixed (P0 LOOP, P1 IDLE, P2 FWD, P3 IDLE): P1/P3 send nothing
//   5. IDLE (0x00): nothing is sent
//   6. Overflow: TX0 stalled, 40 frames looped on P0 -> the FIFO keeps what fits,
//      the rest is dropped WHOLE: received frames are an in-order subset of the
//      sent ones (no partial frame), DROP_LOOP = dropped count, received + dropped
//      = sent, and a frame larger than the FIFO is dropped too
//   7. Counters: RX_GOOD / RX_BAD / TX_GOOD exact per port; CNT_CTRL clears them
//   8. PHY GPIO / PG inputs: IO_STATUS levels, GPIO edge counters, IO_STICKY W1C
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

module tb_pktrec_m0_path;

  // Register offsets (include/pktrec_regs.h)
  localparam [11:0] R_ID = 12'h000, R_VERSION = 12'h004, R_PATH_CTRL = 12'h008,
                    R_CNT_CTRL = 12'h00C, R_IO_STATUS = 12'h010, R_IO_STICKY = 12'h014;
  localparam [11:0] P_BASE = 12'h100, P_STRIDE = 12'h040;
  localparam [11:0] P_RX_GOOD = 12'h00, P_RX_BAD = 12'h04, P_TX_GOOD = 12'h08,
                    P_TX_UNF = 12'h0C, P_DROP_LOOP = 12'h10, P_DROP_FWD = 12'h14,
                    P_GPIO0 = 12'h18, P_GPIO1 = 12'h1C;
  localparam integer FIFO_DEPTH = 4096;

  integer errors = 0;
  task automatic fail(input string msg);
    begin
      errors = errors + 1;
      $display("FAIL: %s (t=%0t)", msg, $time);
    end
  endtask

  // ---------------------------------------------------------------------------
  // Clocks / resets
  // ---------------------------------------------------------------------------
  reg ctrl_clk = 1'b0;
  always #5 ctrl_clk = ~ctrl_clk;                     // 100 MHz
  reg ctrl_aresetn = 1'b0;

  reg [3:0] rx_clk = 4'b0, tx_clk = 4'b0;
  // recovered RX clocks: +-100..300 ppm around 62.5 MHz; TX clocks: one QPLL
  initial begin #1.1;  forever #8.0016 rx_clk[0] = ~rx_clk[0]; end
  initial begin #3.7;  forever #7.9984 rx_clk[1] = ~rx_clk[1]; end
  initial begin #5.3;  forever #8.0024 rx_clk[2] = ~rx_clk[2]; end
  initial begin #6.9;  forever #7.9976 rx_clk[3] = ~rx_clk[3]; end
  initial begin #0.4;  forever #8.0 tx_clk[0] = ~tx_clk[0]; end
  initial begin #2.2;  forever #8.0 tx_clk[1] = ~tx_clk[1]; end
  initial begin #4.6;  forever #8.0 tx_clk[2] = ~tx_clk[2]; end
  initial begin #7.1;  forever #8.0 tx_clk[3] = ~tx_clk[3]; end
  reg [3:0] rx_aresetn = 4'b0, tx_aresetn = 4'b0;

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  reg  [15:0] rx_tdata [0:3];
  reg  [1:0]  rx_tkeep [0:3];
  reg  [3:0]  rx_tvalid = 4'b0, rx_tlast = 4'b0, rx_tbad = 4'b0;
  wire [15:0] tx_tdata [0:3];
  wire [1:0]  tx_tkeep [0:3];
  wire [3:0]  tx_tvalid, tx_tlast;
  wire [0:0]  tx_tuser [0:3];
  wire [7:0]  tx_tid [0:3];
  reg  [3:0]  tx_tready = 4'b0;
  wire [15:0] mon_tdata [0:3];
  wire [3:0]  mon_tvalid;

  reg  [3:0]  rx_stat_good = 4'b0, rx_stat_bad = 4'b0, tx_stat_good = 4'b0;
  reg  [3:0]  phy_gpio0 = 4'b0, phy_gpio1 = 4'b0;
  reg         pg_1v0 = 1'b1, pg_2v5 = 1'b0;
  reg  [3:0]  link_up = 4'b1010;

  reg  [11:0] awaddr = 0, araddr = 0;
  reg         awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
  reg  [31:0] wdata = 0;
  reg  [3:0]  wstrb = 0;
  wire        awready, wready, bvalid, arready, rvalid;
  wire [1:0]  bresp, rresp;
  wire [31:0] rdata;

  integer k;
  initial for (k = 0; k < 4; k = k + 1) begin rx_tdata[k] = 0; rx_tkeep[k] = 0; end

  pktrec_m0_path #(.FIFO_DEPTH(FIFO_DEPTH)) dut (
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
    .m_axis_tx_0_tid(tx_tid[0]), .m_axis_mon_0_tdata(mon_tdata[0]), .m_axis_mon_0_tkeep(), .m_axis_mon_0_tvalid(mon_tvalid[0]),
    .m_axis_mon_0_tlast(), .m_axis_mon_0_tuser(),
    .rx_clk_1(rx_clk[1]), .rx_aresetn_1(rx_aresetn[1]),
    .s_axis_rx_1_tdata(rx_tdata[1]), .s_axis_rx_1_tkeep(rx_tkeep[1]), .s_axis_rx_1_tvalid(rx_tvalid[1]),
    .s_axis_rx_1_tlast(rx_tlast[1]), .s_axis_rx_1_tuser({64'd0, rx_tbad[1]}),
    .tx_clk_1(tx_clk[1]), .tx_aresetn_1(tx_aresetn[1]),
    .m_axis_tx_1_tdata(tx_tdata[1]), .m_axis_tx_1_tkeep(tx_tkeep[1]), .m_axis_tx_1_tvalid(tx_tvalid[1]),
    .m_axis_tx_1_tready(tx_tready[1]), .m_axis_tx_1_tlast(tx_tlast[1]), .m_axis_tx_1_tuser(tx_tuser[1]),
    .m_axis_tx_1_tid(tx_tid[1]), .m_axis_mon_1_tdata(mon_tdata[1]), .m_axis_mon_1_tkeep(), .m_axis_mon_1_tvalid(mon_tvalid[1]),
    .m_axis_mon_1_tlast(), .m_axis_mon_1_tuser(),
    .rx_clk_2(rx_clk[2]), .rx_aresetn_2(rx_aresetn[2]),
    .s_axis_rx_2_tdata(rx_tdata[2]), .s_axis_rx_2_tkeep(rx_tkeep[2]), .s_axis_rx_2_tvalid(rx_tvalid[2]),
    .s_axis_rx_2_tlast(rx_tlast[2]), .s_axis_rx_2_tuser({64'd0, rx_tbad[2]}),
    .tx_clk_2(tx_clk[2]), .tx_aresetn_2(tx_aresetn[2]),
    .m_axis_tx_2_tdata(tx_tdata[2]), .m_axis_tx_2_tkeep(tx_tkeep[2]), .m_axis_tx_2_tvalid(tx_tvalid[2]),
    .m_axis_tx_2_tready(tx_tready[2]), .m_axis_tx_2_tlast(tx_tlast[2]), .m_axis_tx_2_tuser(tx_tuser[2]),
    .m_axis_tx_2_tid(tx_tid[2]), .m_axis_mon_2_tdata(mon_tdata[2]), .m_axis_mon_2_tkeep(), .m_axis_mon_2_tvalid(mon_tvalid[2]),
    .m_axis_mon_2_tlast(), .m_axis_mon_2_tuser(),
    .rx_clk_3(rx_clk[3]), .rx_aresetn_3(rx_aresetn[3]),
    .s_axis_rx_3_tdata(rx_tdata[3]), .s_axis_rx_3_tkeep(rx_tkeep[3]), .s_axis_rx_3_tvalid(rx_tvalid[3]),
    .s_axis_rx_3_tlast(rx_tlast[3]), .s_axis_rx_3_tuser({64'd0, rx_tbad[3]}),
    .tx_clk_3(tx_clk[3]), .tx_aresetn_3(tx_aresetn[3]),
    .m_axis_tx_3_tdata(tx_tdata[3]), .m_axis_tx_3_tkeep(tx_tkeep[3]), .m_axis_tx_3_tvalid(tx_tvalid[3]),
    .m_axis_tx_3_tready(tx_tready[3]), .m_axis_tx_3_tlast(tx_tlast[3]), .m_axis_tx_3_tuser(tx_tuser[3]),
    .m_axis_tx_3_tid(tx_tid[3]), .m_axis_mon_3_tdata(mon_tdata[3]), .m_axis_mon_3_tkeep(), .m_axis_mon_3_tvalid(mon_tvalid[3]),
    .m_axis_mon_3_tlast(), .m_axis_mon_3_tuser(),
    .rx_stat_pkt_good(rx_stat_good), .rx_stat_pkt_bad(rx_stat_bad),
    .tx_stat_pkt_good(tx_stat_good), .tx_stat_err_underflow(4'b0000),
    .link_up(link_up),
    .phy_gpio0(phy_gpio0), .phy_gpio1(phy_gpio1), .pg_1v0(pg_1v0), .pg_2v5(pg_2v5),
    .s_axi_awaddr(awaddr), .s_axi_awprot(3'b000), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
    .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
    .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
    .s_axi_araddr(araddr), .s_axi_arprot(3'b000), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
    .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready)
  );

  // ---------------------------------------------------------------------------
  // AXI4-Lite BFM
  // ---------------------------------------------------------------------------
  task automatic axi_write(input [11:0] a, input [31:0] d);
    begin
      @(posedge ctrl_clk);
      awaddr <= a; wdata <= d; wstrb <= 4'hF; awvalid <= 1; wvalid <= 1; bready <= 1;
      @(posedge ctrl_clk);
      while (!(awready && wready)) @(posedge ctrl_clk);
      awvalid <= 0; wvalid <= 0;
      while (!bvalid) @(posedge ctrl_clk);
      @(posedge ctrl_clk);
      bready <= 0;
    end
  endtask

  task automatic axi_read(input [11:0] a, output [31:0] d);
    begin
      @(posedge ctrl_clk);
      araddr <= a; arvalid <= 1; rready <= 1;
      @(posedge ctrl_clk);
      while (!arready) @(posedge ctrl_clk);
      arvalid <= 0;
      while (!rvalid) @(posedge ctrl_clk);
      d = rdata;
      @(posedge ctrl_clk);
      rready <= 0;
    end
  endtask

  task automatic expect_reg(input [11:0] a, input [31:0] exp, input string what);
    reg [31:0] d;
    begin
      axi_read(a, d);
      if (d !== exp) fail($sformatf("%s: reg 0x%03x = 0x%08x, expected 0x%08x", what, a, d, exp));
    end
  endtask

  function automatic [11:0] preg(input integer p, input [11:0] off);
    preg = P_BASE + p * P_STRIDE + off;
  endfunction

  // ---------------------------------------------------------------------------
  // Frames, RX drivers and TX scoreboards
  // ---------------------------------------------------------------------------
  class Frame;
    byte unsigned data[$];
    bit bad;
    int id;
  endclass

  Frame send_q [4][$];      // frames to inject on RX port p
  Frame exp_q  [4][$];      // frames TX port p must emit, in order
  int   n_sent [4];
  int   n_rx_good [4], n_rx_bad [4], n_tx [4];
  int   skipped [4];        // expected frames that never appeared (dropped)
  bit   allow_skip [4];     // test 6 only
  int   frame_id = 0;

  // route of RX p under PATH_CTRL m: list of TX ports whose source is RX p
  reg [7:0] cur_mode = 8'h00;

  function automatic Frame make_frame(input int len, input bit bad);
    Frame f = new();
    for (int i = 0; i < len; i++) f.data.push_back($urandom_range(0, 255));
    f.bad = bad;
    f.id = frame_id++;
    return f;
  endfunction

  // queue a frame on RX p and add it to the scoreboard of every TX port routed to it
  task automatic send(input int p, input int len, input bit bad);
    Frame f;
    begin
      f = make_frame(len, bad);
      send_q[p].push_back(f);
      for (int d = 0; d < 4; d++) begin
        if ((cur_mode[2*d +: 2] == 2'd1 && d == p) || (cur_mode[2*d +: 2] == 2'd2 && (d ^ 1) == p))
          exp_q[d].push_back(f);
      end
    end
  endtask

  genvar gp;
  generate
    for (gp = 0; gp < 4; gp = gp + 1) begin : g_bfm
      // RX MAC model: one beat per cycle, IFG of 6..12 cycles between frames
      initial begin
        Frame f;
        int nb;
        forever begin
          @(posedge rx_clk[gp]);
          if (send_q[gp].size() == 0 || !rx_aresetn[gp]) continue;
          f = send_q[gp].pop_front();
          nb = (f.data.size() + 1) / 2;
          for (int b = 0; b < nb; b++) begin
            rx_tdata[gp]  <= {(2*b+1 < f.data.size()) ? f.data[2*b+1] : 8'h00, f.data[2*b]};
            rx_tkeep[gp]  <= (2*b+1 < f.data.size()) ? 2'b11 : 2'b01;
            rx_tvalid[gp] <= 1'b1;
            rx_tlast[gp]  <= (b == nb - 1);
            rx_tbad[gp]   <= (b == nb - 1) ? f.bad : 1'b0;
            rx_stat_good[gp] <= (b == nb - 1) && !f.bad;
            rx_stat_bad[gp]  <= (b == nb - 1) && f.bad;
            @(posedge rx_clk[gp]);
          end
          rx_tvalid[gp] <= 1'b0; rx_tlast[gp] <= 1'b0; rx_tbad[gp] <= 1'b0;
          rx_stat_good[gp] <= 1'b0; rx_stat_bad[gp] <= 1'b0;
          if (f.bad) n_rx_bad[gp]++; else n_rx_good[gp]++;
          n_sent[gp]++;
          repeat ($urandom_range(6, 12)) @(posedge rx_clk[gp]);
        end
      end

      // TX MAC model: random tready (stall_tx forces 0), collects frames
      reg stall_tx = 1'b0;
      byte unsigned got[$];
      bit in_frame = 0;
      always @(posedge tx_clk[gp]) begin
        tx_tready[gp] <= !stall_tx && ($urandom_range(0, 99) < 80);
        tx_stat_good[gp] <= 1'b0;
        if (tx_tvalid[gp] && tx_tready[gp]) begin
          in_frame = !tx_tlast[gp];
          if (tx_tid[gp] !== 8'd0) fail($sformatf("TX%0d tid not 0", gp));
          if (tx_tkeep[gp] == 2'b11) begin
            got.push_back(tx_tdata[gp][7:0]); got.push_back(tx_tdata[gp][15:8]);
          end else if (tx_tkeep[gp] == 2'b01 && tx_tlast[gp]) begin
            got.push_back(tx_tdata[gp][7:0]);
          end else begin
            fail($sformatf("TX%0d bad tkeep %b (tlast %b)", gp, tx_tkeep[gp], tx_tlast[gp]));
          end
          if (tx_tlast[gp]) begin
            check_frame(gp, got, tx_tuser[gp][0]);
            got.delete();
            tx_stat_good[gp] <= 1'b1;
          end
        end else if (in_frame && !tx_tvalid[gp]) begin
          fail($sformatf("TX%0d tvalid dropped inside a frame (underrun)", gp));
        end
      end
    end
  endgenerate

  task automatic check_frame(input int p, ref byte unsigned got[$], input bit bad);
    Frame e;
    bit match;
    begin
      n_tx[p]++;
      forever begin
        if (exp_q[p].size() == 0) begin
          fail($sformatf("TX%0d: unexpected frame (%0d bytes)", p, got.size()));
          return;
        end
        e = exp_q[p].pop_front();
        match = (e.data.size() == got.size()) && (e.bad == bad);
        if (match) for (int i = 0; i < got.size(); i++) if (got[i] != e.data[i]) match = 0;
        if (match) return;
        if (!allow_skip[p]) begin
          fail($sformatf("TX%0d: frame mismatch (expected id %0d, %0d bytes, bad %0d; got %0d bytes, bad %0d)",
                         p, e.id, e.data.size(), e.bad, got.size(), bad));
          return;
        end
        skipped[p]++;
      end
    end
  endtask

  task automatic wait_idle();
    int quiet;
    begin
      quiet = 0;
      while (quiet < 2000) begin
        @(posedge ctrl_clk);
        if (send_q[0].size() || send_q[1].size() || send_q[2].size() || send_q[3].size() ||
            rx_tvalid != 0 || tx_tvalid != 0) quiet = 0;
        else quiet++;
      end
    end
  endtask

  task automatic set_mode(input [7:0] m);
    begin
      axi_write(R_PATH_CTRL, {24'd0, m});
      cur_mode = m;
      repeat (50) @(posedge ctrl_clk);     // let the synchronisers settle
    end
  endtask

  task automatic check_scoreboards_empty(input string what);
    begin
      for (int p = 0; p < 4; p++)
        if (exp_q[p].size() != 0) fail($sformatf("%s: TX%0d missed %0d frame(s)", what, p, exp_q[p].size()));
    end
  endtask

  task automatic burst(input int nframes);
    begin
      for (int i = 0; i < nframes; i++)
        for (int p = 0; p < 4; p++)
          send(p, (i % 7 == 3) ? 1514 : $urandom_range(14, 300), (i % 5 == 2));
    end
  endtask

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  reg [31:0] d;
  int sent_before, drops;

  initial begin
    #20000000;
    $display("FAIL: watchdog timeout");
    $finish;
  end

  initial begin
    for (int p = 0; p < 4; p++) begin
      n_sent[p] = 0; n_rx_good[p] = 0; n_rx_bad[p] = 0; n_tx[p] = 0; skipped[p] = 0; allow_skip[p] = 0;
    end
    repeat (20) @(posedge ctrl_clk);
    ctrl_aresetn = 1'b1;
    #200;
    rx_aresetn = 4'hF;
    tx_aresetn = 4'hF;
    #500;

    // 1. identification and reset values
    expect_reg(R_ID, 32'h504B4D30, "ID");
    expect_reg(R_VERSION, 32'h00010003, "VERSION");
    expect_reg(R_PATH_CTRL, 32'h0, "PATH_CTRL reset");
    expect_reg(12'h0FC, 32'h0, "unmapped");

    // 2. loopback on all ports
    set_mode(8'h55);
    burst(12);
    wait_idle();
    check_scoreboards_empty("LOOP");
    for (int p = 0; p < 4; p++) if (n_tx[p] != 12) fail($sformatf("LOOP: TX%0d sent %0d frames, expected 12", p, n_tx[p]));
    $display("INFO: LOOP done (%0d/%0d/%0d/%0d frames)", n_tx[0], n_tx[1], n_tx[2], n_tx[3]);

    // 3. forwarding on all ports (TAP)
    set_mode(8'hAA);
    burst(12);
    wait_idle();
    check_scoreboards_empty("FWD");
    for (int p = 0; p < 4; p++) if (n_tx[p] != 24) fail($sformatf("FWD: TX%0d total %0d frames, expected 24", p, n_tx[p]));
    $display("INFO: FWD done");

    // 4. mixed: P0 LOOP, P1 IDLE, P2 FWD (RX3 -> TX2), P3 IDLE
    set_mode(8'b00_10_00_01);
    burst(8);
    wait_idle();
    check_scoreboards_empty("MIXED");
    if (n_tx[0] != 32 || n_tx[1] != 24 || n_tx[2] != 32 || n_tx[3] != 24)
      fail($sformatf("MIXED: TX frame totals %0d/%0d/%0d/%0d, expected 32/24/32/24", n_tx[0], n_tx[1], n_tx[2], n_tx[3]));
    $display("INFO: MIXED done");

    // 5. idle: nothing goes out
    set_mode(8'h00);
    burst(5);
    wait_idle();
    if (n_tx[0] != 32 || n_tx[1] != 24 || n_tx[2] != 32 || n_tx[3] != 24) fail("IDLE: frames were sent");
    $display("INFO: IDLE done");

    // 7a. counters so far (all frames sent so far, counted by the MAC models)
    repeat (100) @(posedge ctrl_clk);
    for (int p = 0; p < 4; p++) begin
      expect_reg(preg(p, P_RX_GOOD), n_rx_good[p], $sformatf("RX_GOOD P%0d", p));
      expect_reg(preg(p, P_RX_BAD), n_rx_bad[p], $sformatf("RX_BAD P%0d", p));
      expect_reg(preg(p, P_TX_GOOD), n_tx[p], $sformatf("TX_GOOD P%0d", p));
      expect_reg(preg(p, P_TX_UNF), 0, $sformatf("TX_UNDERFLOW P%0d", p));
      expect_reg(preg(p, P_DROP_LOOP), 0, $sformatf("DROP_LOOP P%0d", p));
      expect_reg(preg(p, P_DROP_FWD), 0, $sformatf("DROP_FWD P%0d", p));
    end
    // 7b. clear
    axi_write(R_CNT_CTRL, 32'h1);
    for (int p = 0; p < 4; p++) begin
      expect_reg(preg(p, P_RX_GOOD), 0, "RX_GOOD after clear");
      expect_reg(preg(p, P_TX_GOOD), 0, "TX_GOOD after clear");
      n_rx_good[p] = 0; n_rx_bad[p] = 0; n_tx[p] = 0;
    end
    $display("INFO: counters done");

    // 6. overflow on P0 LOOP with TX0 stalled
    set_mode(8'h01);
    allow_skip[0] = 1;
    g_bfm[0].stall_tx = 1'b1;
    for (int i = 0; i < 40; i++) send(0, (i == 20) ? 1514 : $urandom_range(200, 400), 1'b0);
    wait (send_q[0].size() == 0);
    repeat (200) @(posedge rx_clk[0]);
    g_bfm[0].stall_tx = 1'b0;
    wait_idle();
    axi_read(preg(0, P_DROP_LOOP), d);
    drops = d;
    if (drops == 0) fail("OVERFLOW: no drops counted");
    // trailing frames that were dropped are still in exp_q: count them as skipped
    skipped[0] += exp_q[0].size();
    exp_q[0].delete();
    if (skipped[0] != drops) fail($sformatf("OVERFLOW: %0d frames missing, DROP_LOOP = %0d", skipped[0], drops));
    if (n_tx[0] + drops != 40) fail($sformatf("OVERFLOW: received %0d + dropped %0d != 40", n_tx[0], drops));
    if (n_tx[0] * 300 > FIFO_DEPTH + 1600) fail($sformatf("OVERFLOW: %0d frames got through a 4 KB FIFO", n_tx[0]));
    expect_reg(preg(0, P_TX_GOOD), n_tx[0], "OVERFLOW TX_GOOD");
    expect_reg(preg(0, P_RX_GOOD), 40, "OVERFLOW RX_GOOD");
    $display("INFO: OVERFLOW done: %0d received, %0d dropped whole", n_tx[0], drops);
    allow_skip[0] = 0; skipped[0] = 0;

    // 6b. oversize frame (> FIFO) is dropped, the next one passes
    axi_write(R_CNT_CTRL, 32'h1);
    n_tx[0] = 0;
    send(0, FIFO_DEPTH + 100, 1'b0);
    allow_skip[0] = 1;
    send(0, 64, 1'b0);
    wait_idle();
    expect_reg(preg(0, P_DROP_LOOP), 1, "OVERSIZE DROP_LOOP");
    if (n_tx[0] != 1 || skipped[0] != 1) fail($sformatf("OVERSIZE: %0d sent, %0d skipped", n_tx[0], skipped[0]));
    check_scoreboards_empty("OVERSIZE");
    allow_skip[0] = 0;
    $display("INFO: OVERSIZE done");

    // 8. PHY GPIO / power good
    expect_reg(R_IO_STATUS, {12'd0, 4'b1010, 6'd0, 2'b01, 8'h00}, "IO_STATUS idle");
    repeat (3) begin
      phy_gpio0[2] = 1'b1; #200; phy_gpio0[2] = 1'b0; #200;
    end
    phy_gpio1[1] = 1'b1; #200;
    expect_reg(R_IO_STATUS, {12'd0, 4'b1010, 6'd0, 2'b01, 8'b0010_0000}, "IO_STATUS gpio1[1]");
    phy_gpio1[1] = 1'b0; #200;
    expect_reg(preg(2, P_GPIO0), 3, "GPIO0_EDGES P2");
    expect_reg(preg(1, P_GPIO1), 1, "GPIO1_EDGES P1");
    expect_reg(preg(0, P_GPIO0), 0, "GPIO0_EDGES P0");
    expect_reg(R_IO_STICKY, 32'h24, "IO_STICKY");
    axi_write(R_IO_STICKY, 32'h04);
    expect_reg(R_IO_STICKY, 32'h20, "IO_STICKY after W1C");
    $display("INFO: GPIO done");

    if (errors == 0) $display("PASS: tb_pktrec_m0_path");
    else $display("FAIL: tb_pktrec_m0_path, %0d error(s)", errors);
    $finish;
  end

endmodule
