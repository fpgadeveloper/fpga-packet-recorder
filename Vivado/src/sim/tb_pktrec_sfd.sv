// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_pktrec_sfd -- self-checking testbench for the SFD sampler + timestamping
// (pktrec_sfd_io with the real ISERDESE3/MMCME4 models, pktrec_sfd_edge,
// pktrec_sfd) against the real pktrec_timebase.
//
// The timebase runs at 250 MHz with INC = 4.0 ns from reset, so the true
// timebase value at simulation time t is ns(t) = (t - t0) with t0 the time of
// the cycle where ns was 0. The SFD pins are driven with edges at random
// sub-ns times.
//
// Checks:
//   1. resolution: for 8 pins x 150 edges at random phases, the timestamp
//      error e = ev_ns - ns(t_edge) has a spread (max - min) <= 1 ns with the
//      ISERDES sampler (and <= 2 ns for an IDDR sampler on the same pins) and
//      lies in [-1, +1] ns: PIPE_NS compensates the sampler pipeline
//   2. every accepted RX edge is pushed to the port queue ({k, cyc} consistent
//      with ev_ns); rx_full -> RX_FIFO_OVF counts
//   3. glitch filter: a 10 ns spike on an idle line and a re-rise after 40 ns
//      of low level are rejected (GLITCH), a rise after 120 ns of low is
//      accepted; RX_EDGES / RX_GLITCH via the register port
//   4. TX pairing with MAC completions (cycle stamps from the timebase's TX
//      domain copy): TX_LAT_LAST = TX edge time - 4 * cpl_cyc exactly;
//      a missing completion -> TX_UNPAIRED, an extra completion -> stale
//      (TX_CPL_STALE) at the next edge, later pairs unaffected; TX_CPL count
//   5. log FIFOs (LOG_EN): RX/TX entries popped through LOG_TS_LO/_HI/_LAT in
//      order with the right values; overflow counted; RX_LAST_TS/TX_LAST_TS
//      include RX_OFFSET/TX_OFFSET
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

module tb_pktrec_sfd;

  localparam int PIPE = 16;

  int errors = 0;
  task automatic fail(input string msg);
    errors++;
    if (errors < 30) $display("FAIL: %s (t=%0t)", msg, $time);
  endtask

  reg dp_clk = 0;
  always #2.0 dp_clk = ~dp_clk;
  reg [3:0] tx_clk = 0;
  always #8.0012 tx_clk = ~tx_clk;
  reg dp_rst = 1;
  reg [3:0] tx_rst = 4'hF;

  // ---- timebase ----
  wire [63:0] tb_ns;
  wire [31:0] tb_frac, tb_cyc;
  wire [7:0]  inc_ns;
  wire [31:0] inc_frac;
  wire [127:0] rx_cyc_unused, tx_cyc;
  wire [7:0]  dom_valid;
  pktrec_timebase #(.CLK_HZ(250000000), .N(4)) tb_inst (
    .clk(dp_clk), .rst(dp_rst), .inc_load(1'b0), .inc_ns_in(8'd0), .inc_frac_in(32'd0),
    .set(1'b0), .set_val(64'd0), .adj(1'b0), .adj_val(64'd0),
    .ns(tb_ns), .frac(tb_frac), .inc_ns(inc_ns), .inc_frac(inc_frac), .cyc(tb_cyc),
    .dom_valid(dom_valid), .rx_clk(4'b0), .rx_rst(4'hF), .rx_cyc(rx_cyc_unused),
    .tx_clk(tx_clk), .tx_rst(tx_rst), .tx_cyc(tx_cyc)
  );

  // reference: time at which ns was 0
  realtime t0 = -1;
  always @(posedge dp_clk) if (t0 < 0 && !dp_rst && tb_ns == 64'd4) t0 = $realtime - 4.0;
  function automatic real ns_at(input realtime t);
    return t - t0;
  endfunction

  // ---- DUT ----
  reg  [3:0] rx_pin = 0, tx_pin = 0;
  wire [31:0] smp, smp_iddr;
  wire locked, locked_iddr;
  pktrec_sfd_io #(.SAMPLER("ISERDES"), .DP_CLK_PERIOD_NS(4.0), .NPIN(8)) io_inst (
    .dp_clk(dp_clk), .dp_rst(dp_rst), .pin({tx_pin, rx_pin}), .smp(smp), .locked(locked));
  pktrec_sfd_io #(.SAMPLER("IDDR"), .NPIN(8)) io_iddr (
    .dp_clk(dp_clk), .dp_rst(dp_rst), .pin({tx_pin, rx_pin}), .smp(smp_iddr), .locked(locked_iddr));

  wire [3:0]   rx_wr;
  wire [135:0] rx_din;
  reg  [3:0]   rx_full = 0;
  wire match_en, sfd_clear;
  wire [31:0] rx_win_min, rx_win_max;
  wire [127:0] rx_offset;
  reg  [3:0]  cpl_valid = 0;
  reg  [127:0] cpl_cyc = 0;
  wire [3:0]  lvl_rx, lvl_tx;
  reg         reg_wr = 0, reg_rd = 0;
  reg  [11:0] reg_wa = 0, reg_ra = 0;
  reg  [31:0] reg_wd = 0;
  wire        reg_rvalid;
  wire [31:0] reg_rdata;

  pktrec_sfd #(.N(4), .PIPE_NS(PIPE), .RES_PS(1000), .ISERDES(1'b1)) dut (
    .clk(dp_clk), .rst(dp_rst), .smp(smp), .locked(locked),
    .tb_ns(tb_ns), .tb_frac(tb_frac), .tb_cyc(tb_cyc), .clear_in(1'b0),
    .rx_wr(rx_wr), .rx_din(rx_din), .rx_full(rx_full),
    .match_en(match_en), .rx_win_min(rx_win_min), .rx_win_max(rx_win_max),
    .rx_offset(rx_offset), .sfd_clear(sfd_clear),
    .p_matched(256'd0), .p_stale(128'd0), .p_mismatch(128'd0), .p_dlast(128'd0), .p_dmin(128'd0),
    .p_dmax(128'd0), .p_dhead(128'd0),
    .tx_clk(tx_clk), .tx_rst(tx_rst), .tx_cpl_valid(cpl_valid), .tx_cpl_cyc(cpl_cyc),
    .lvl_rx(lvl_rx), .lvl_tx(lvl_tx),
    .reg_wr(reg_wr), .reg_wa(reg_wa), .reg_wd(reg_wd), .reg_rd(reg_rd), .reg_ra(reg_ra),
    .reg_rvalid(reg_rvalid), .reg_rdata(reg_rdata)
  );

  // IDDR comparison: one edge detector on pin 0 of the IDDR sampler
  wire        ie_ev;
  wire [63:0] ie_ns;
  pktrec_sfd_edge #(.PIPE_NS(PIPE)) edge_iddr (
    .clk(dp_clk), .rst(dp_rst), .s(smp_iddr[3:0]), .min_low(8'd25), .min_high(8'd8),
    .tb_ns(tb_ns), .tb_half(tb_frac[31]), .tb_cyc(tb_cyc), .level(), .ev(ie_ev), .ev_ns(ie_ns),
    .ev_cyc(), .ev_k(), .glitch());

  // ---- register access ----
  task automatic wr(input [11:0] a, input [31:0] d);
    @(posedge dp_clk); reg_wr <= 1; reg_wa <= a; reg_wd <= d;
    @(posedge dp_clk); reg_wr <= 0;
  endtask
  task automatic rd(input [11:0] a, output [31:0] d);
    @(posedge dp_clk); reg_rd <= 1; reg_ra <= a;
    @(posedge dp_clk); reg_rd <= 0;
    while (!reg_rvalid) @(posedge dp_clk);
    d = reg_rdata;
  endtask
  function automatic [11:0] pa(input int port, input int off);
    return 12'(12'h800 + port * 12'h100 + off);
  endfunction
  task automatic expect_reg(input [11:0] a, input [31:0] exp, input string what);
    logic [31:0] d;
    rd(a, d);
    if (d !== exp) fail($sformatf("%s (0x%03x) = 0x%08x (%0d), expected 0x%08x (%0d)", what, a, d, $signed(d), exp, $signed(exp)));
  endtask

  // ---- event monitors ----
  real err_min[8], err_max[8];
  int  n_ev[8];
  realtime last_edge[8];
  bit  expect_ev[8];
  longint unsigned ev_ns_q[8][$];
  real ierr_min = 1e9, ierr_max = -1e9;
  realtime iddr_edge;
  int n_push[4];

  initial for (int i = 0; i < 8; i++) begin err_min[i] = 1e9; err_max[i] = -1e9; n_ev[i] = 0; end

  for (genvar i = 0; i < 8; i++) begin : g_mon
    always @(posedge dp_clk) begin
      if (dut.e_ev[i]) begin
        real e;
        e = real'(dut.e_ns[64*i +: 64]) - ns_at(last_edge[i]);
        n_ev[i]++;
        ev_ns_q[i].push_back(dut.e_ns[64*i +: 64]);
        if (!expect_ev[i]) fail($sformatf("pin %0d: unexpected event", i));
        expect_ev[i] = 0;
        if (e < err_min[i]) err_min[i] = e;
        if (e > err_max[i]) err_max[i] = e;
        // {k, cyc} consistent with ns
        if (dut.e_ns[64*i +: 64] != 4 * longint'(dut.e_cyc[32*i +: 32]) + dut.e_k[2*i +: 2] - PIPE)
          fail($sformatf("pin %0d: ev_ns %0d inconsistent with cyc %0d k %0d", i, dut.e_ns[64*i +: 64],
                         dut.e_cyc[32*i +: 32], dut.e_k[2*i +: 2]));
      end
    end
  end
  always @(posedge dp_clk) begin
    if (ie_ev) begin
      real e;
      e = real'(ie_ns) - ns_at(last_edge[0]);
      if (e < ierr_min) ierr_min = e;
      if (e > ierr_max) ierr_max = e;
    end
    for (int p = 0; p < 4; p++) if (rx_wr[p]) n_push[p]++;
  end

  // drive a pulse: rise at absolute time t (relative to now), high for hi ns
  task automatic pulse(input int pin, input real delay, input real hi, input bit expect_it);
    #(delay);
    last_edge[pin] = $realtime;
    expect_ev[pin] = expect_it;
    if (pin < 4) rx_pin[pin] = 1; else tx_pin[pin - 4] = 1;
    #(hi);
    if (pin < 4) rx_pin[pin] = 0; else tx_pin[pin - 4] = 0;
  endtask

  // TX completion on port p (tx_clk p): cycle stamp = the timebase's TX copy
  longint unsigned cpl_sent[4][$];
  // (port 1 only: xsim cannot wait on an edge of a variably indexed bit)
  task automatic send_cpl(input int p);
    @(posedge tx_clk[1]);
    cpl_valid[1] <= 1;
    cpl_cyc[63:32] <= tx_cyc[63:32];
    cpl_sent[1].push_back(tx_cyc[63:32]);
    @(posedge tx_clk[1]);
    cpl_valid[1] <= 0;
  endtask

  // test 1 drivers: one process per pin
  event t1_go;
  int   t1_done = 0;
  for (genvar gi = 0; gi < 8; gi++) begin : g_drv
    initial begin
      @(t1_go);
      for (int j = 0; j < 150; j++) pulse(gi, 400.0 + $urandom_range(0, 9999) / 1000.0, 600.0, 1);
      t1_done++;
    end
  end

  logic [31:0] d, d2, d3;
  int lat_exp;

  initial begin
    $display("tb_pktrec_sfd: start");
    repeat (10) @(posedge dp_clk);
    dp_rst <= 0;
    tx_rst <= 0;
    wait (locked);
    repeat (50) @(posedge dp_clk);
    $display("  sampler locked at %0t", $time);
    expect_reg(12'h400, 32'h0000_0001, "SFD_CTRL reset");
    expect_reg(12'h408, 32'd1000, "SFD_RES_PS");
    expect_reg(12'h40C, PIPE, "SFD_PIPE_NS");
    expect_reg(12'h410, 32'd100, "RX_WIN_MIN");
    expect_reg(12'h414, 32'd700, "RX_WIN_MAX");
    rd(12'h404, d);
    if (d[1:0] != 2'b11) fail($sformatf("SFD_STATUS 0x%08x: locked/ISERDES", d));

    // ---- 1. resolution ----
    $display("test 1: timestamp resolution");
    -> t1_go;
    wait (t1_done == 8);
    repeat (100) @(posedge dp_clk);
    for (int i = 0; i < 8; i++) begin
      $display("  pin %0d: %0d events, error %0.3f .. %0.3f ns", i, n_ev[i], err_min[i], err_max[i]);
      if (n_ev[i] != 150) fail($sformatf("pin %0d: %0d events, expected 150", i, n_ev[i]));
      if (err_max[i] - err_min[i] > 1.0001) fail($sformatf("pin %0d: spread %0.3f ns > 1 ns", i, err_max[i] - err_min[i]));
      if (err_min[i] < -1.0001 || err_max[i] > 1.0001) fail($sformatf("pin %0d: error outside +-1 ns (PIPE_NS)", i));
    end
    $display("  IDDR sampler (pin 0): error %0.3f .. %0.3f ns", ierr_min, ierr_max);
    if (ierr_max - ierr_min > 2.0001) fail("IDDR spread > 2 ns");
    for (int p = 0; p < 4; p++)
      if (n_push[p] != 150) fail($sformatf("port %0d: %0d RX queue pushes, expected 150", p, n_push[p]));
    expect_reg(pa(0, 'h00), 32'd150, "P0 RX_EDGES");
    expect_reg(pa(3, 'h80), 32'd150, "P3 TX_EDGES");

    // ---- 2. queue full ----
    $display("test 2: RX queue full");
    rx_full[1] = 1;
    for (int j = 0; j < 5; j++) pulse(1, 300.0, 600.0, 1);
    rx_full[1] = 0;
    repeat (50) @(posedge dp_clk);
    expect_reg(pa(1, 'h0C), 32'd5, "P1 RX_FIFO_OVF");
    if (n_push[1] != 150) fail("pushes while full");

    // ---- 3. glitch filter ----
    $display("test 3: glitch filter");
    pulse(2, 500.0, 10.0, 0);                    // 10 ns spike
    #500;
    pulse(2, 0.0, 600.0, 1);                     // real frame
    pulse(2, 40.0, 600.0, 0);                    // re-rise after 40 ns low
    pulse(2, 120.0, 600.0, 1);                   // 120 ns low: accepted
    #300;
    repeat (20) @(posedge dp_clk);
    expect_reg(pa(2, 'h08), 32'd2, "P2 RX_GLITCH");
    expect_reg(pa(2, 'h00), 32'd152, "P2 RX_EDGES");

    // ---- 4. TX pairing ----
    $display("test 4: TX completions pairing");
    wr(12'h400, 32'h0000_0103);                  // MATCH_EN, LOG_EN, CLEAR
    wr(pa(1, 'hB8), 32'd5);                      // TX_OFFSET P1 = 5
    wr(pa(1, 'h38), -32'sd3);                    // RX_OFFSET P1 = -3
    for (int j = 0; j < 12; j++) begin
      realtime tc;
      if (j != 4) send_cpl(1);                   // j = 4: missing completion
      if (j == 8) send_cpl(1);                   // j = 8: an extra completion (no SFD)
      tc = $realtime;
      pulse(5, 300.0 + $urandom_range(0, 999) / 1000.0, 600.0, 1);
      #400;
      repeat (10) @(posedge dp_clk);
      rd(pa(1, 'hA4), d);                        // TX_LAT_LAST
      if (j != 4) begin
        // expected: edge time - 4 * cpl_cyc of the paired completion
        longint unsigned ev = ev_ns_q[5][$];
        longint unsigned cc = (j == 8) ? cpl_sent[1][cpl_sent[1].size() - 2] : cpl_sent[1][$];
        lat_exp = int'(longint'(ev) - 4 * longint'(cc));
        if ($signed(d) != lat_exp) fail($sformatf("TX pair %0d: LAT_LAST %0d, expected %0d", j, $signed(d), lat_exp));
        if (j == 0) $display("  TX latency (completion -> SFD edge, raw) = %0d ns (pin delay 300 ns + copy lag)", $signed(d));
      end
    end
    // the extra completion of j = 8 was sent before j = 8's own: its edge
    // pairs with the extra one? No: the extra is younger -> both queued; the
    // edge pairs with the OLDEST in-window completion (the j = 8 own one was
    // sent first), the extra goes stale at j = 9.
    expect_reg(pa(1, 'h98), 32'd11, "TX_PAIRED");
    expect_reg(pa(1, 'hA0), 32'd1,  "TX_UNPAIRED");
    expect_reg(pa(1, 'h9C), 32'd1,  "TX_CPL_STALE");
    expect_reg(pa(1, 'h90), 32'd12, "TX_CPL");
    // log: 12 entries, ts = edge + TX_OFFSET, LAT = 0x80000000 for j = 4
    rd(pa(1, 'hBC), d);
    if (d[4:0] != 5'd12) fail($sformatf("TX_LOG_STATUS count %0d", d[4:0]));
    for (int j = 0; j < 12; j++) begin
      rd(pa(1, 'hC0), d); rd(pa(1, 'hC4), d2); rd(pa(1, 'hC8), d3);
      if ({d2, d} !== ev_ns_q[5][ev_ns_q[5].size() - 12 + j] + 5)
        fail($sformatf("TX log %0d: ts %0d, expected %0d", j, {d2, d}, ev_ns_q[5][ev_ns_q[5].size() - 12 + j] + 5));
      if ((j == 4) != (d3 == 32'h8000_0000)) fail($sformatf("TX log %0d: LAT 0x%08x", j, d3));
    end
    rd(pa(1, 'hBC), d);
    if (d[4:0] != 5'd0) fail("TX log not empty after 12 pops");
    // RX log + offset + overflow
    for (int j = 0; j < 20; j++) pulse(1, 300.0, 600.0, 1);
    repeat (20) @(posedge dp_clk);
    rd(pa(1, 'h3C), d);
    if (d[4:0] != 5'd16 || d[31:16] != 16'd4) fail($sformatf("RX_LOG_STATUS 0x%08x (16 entries, 4 overflows)", d));
    rd(pa(1, 'h40), d); rd(pa(1, 'h44), d2);
    if ({d2, d} !== ev_ns_q[1][ev_ns_q[1].size() - 20] - 3) fail("RX log head ts");
    rd(pa(1, 'h30), d); rd(pa(1, 'h34), d2);
    if ({d2, d} !== ev_ns_q[1][$] - 3) fail("RX_LAST_TS");
    rd(pa(1, 'hB0), d); rd(pa(1, 'hB4), d2);
    if ({d2, d} !== ev_ns_q[5][$] + 5) fail("TX_LAST_TS");

    if (errors == 0) $display("tb_pktrec_sfd: PASS");
    else $display("tb_pktrec_sfd: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #5ms;
    $display("tb_pktrec_sfd: FAIL (timeout)");
    $finish;
  end

endmodule
