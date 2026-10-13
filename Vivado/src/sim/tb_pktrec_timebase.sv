// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_pktrec_timebase -- self-checking testbench for pktrec_timebase
//
// Master on clk = 250 MHz (CLK_HZ = 250e6 -> reset INC = 4.0 ns); the cycle
// counter is distributed into an "RX" domain at 62.5 MHz + 125 ppm and a "TX"
// domain at 62.5 MHz - 250 ppm (half periods 7.999 / 8.002 ns).
//
// Checks:
//   1. reset increment = 4.0 ns; the master advances exactly INC per cycle
//   2. distribution: in both MAC domains the copy is monotonic and its age
//      (master cycle count minus copy, sampled at the MAC clock edge) stays in
//      a narrow constant window (~3 MAC cycles of sync latency, <= 2 clk wide);
//      dom_valid follows the domain resets
//   3. set (settime): ns jumps to the value on the next cycle
//   4. adj (adjtime, negative offset): ns jumps by exactly the offset
//   5. inc_load (adjfine): INC = 4.0004 ns -> 400040 ns per 100000 cycles
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

module tb_pktrec_timebase;

  int errors = 0;
  task automatic fail(input string msg);
    errors++;
    if (errors < 30) $display("FAIL: %s (t=%0t)", msg, $time);
  endtask

  reg clk = 0;
  reg [0:0] rx_clk = 0, tx_clk = 0;
  always #2.0 clk = ~clk;
  always #7.999 rx_clk = ~rx_clk;      // +125 ppm
  always #8.002 tx_clk = ~tx_clk;      // -250 ppm
  reg rst = 1;
  reg [0:0] rx_rst = 1, tx_rst = 1;

  reg        inc_load = 0, set = 0, adj = 0;
  reg [7:0]  inc_ns_in = 0;
  reg [31:0] inc_frac_in = 0;
  reg [63:0] set_val = 0, adj_val = 0;
  wire [63:0] ns;
  wire [31:0] frac, cyc;
  wire [7:0]  inc_ns;
  wire [31:0] inc_frac;
  wire [1:0]  dom_valid;
  wire [31:0] rx_cyc, tx_cyc;

  pktrec_timebase #(.CLK_HZ(250000000), .N(1)) dut (
    .clk(clk), .rst(rst),
    .inc_load(inc_load), .inc_ns_in(inc_ns_in), .inc_frac_in(inc_frac_in),
    .set(set), .set_val(set_val), .adj(adj), .adj_val(adj_val),
    .ns(ns), .frac(frac), .inc_ns(inc_ns), .inc_frac(inc_frac), .cyc(cyc),
    .dom_valid(dom_valid),
    .rx_clk(rx_clk), .rx_rst(rx_rst), .rx_cyc(rx_cyc),
    .tx_clk(tx_clk), .tx_rst(tx_rst), .tx_cyc(tx_cyc)
  );

  // age of the copies, sampled at the MAC clock edge
  bit check = 0;
  int amin [2], amax [2];
  longint nsamp [2];
  reg [31:0] last [2];
  task automatic sample(input int d, input [31:0] c);
    int age;
    age = int'(cyc - c);
    if (age < amin[d]) amin[d] = age;
    if (age > amax[d]) amax[d] = age;
    if (nsamp[d] > 0 && c < last[d]) fail($sformatf("domain %0d copy went backwards", d));
    last[d] = c;
    nsamp[d]++;
  endtask
  always @(posedge rx_clk) if (check) sample(0, rx_cyc);
  always @(posedge tx_clk) if (check) sample(1, tx_cyc);

  longint unsigned a, b;

  initial begin
    $display("tb_pktrec_timebase: start");
    repeat (10) @(posedge clk);
    rst <= 0;
    repeat (5) @(posedge rx_clk); rx_rst <= 0;
    repeat (20) @(posedge clk);
    if (dom_valid !== 2'b01) fail($sformatf("dom_valid = %b with only RX out of reset", dom_valid));
    repeat (5) @(posedge tx_clk); tx_rst <= 0;
    repeat (20) @(posedge clk);
    if (dom_valid !== 2'b11) fail($sformatf("dom_valid = %b", dom_valid));

    // ---- 1. reset increment ----
    @(posedge clk);
    if (inc_ns !== 8'd4 || inc_frac !== 32'd0) fail($sformatf("reset INC %0d.%08x", inc_ns, inc_frac));
    a = ns; repeat (1000) @(posedge clk); b = ns;
    if (b - a != 4000) fail($sformatf("master advanced %0d ns in 1000 cycles", b - a));

    // ---- 2. distribution ----
    $display("test 2: distribution");
    for (int d = 0; d < 2; d++) begin amin[d] = 1 << 30; amax[d] = -(1 << 30); nsamp[d] = 0; end
    check = 1;
    repeat (500000) @(posedge clk);       // 2 ms: the TX copy slips 0.5 us vs RX
    check = 0;
    for (int d = 0; d < 2; d++) begin
      $display("  domain %0d: age %0d..%0d clk cycles over %0d samples", d, amin[d], amax[d], nsamp[d]);
      // source Gray register + 2 sync stages + output register: ~3 MAC cycles
      // (measured 12..14 clk = 48..56 ns); the window width is the jitter
      if (amin[d] < 11 || amax[d] > 15 || amax[d] - amin[d] > 2)
        fail($sformatf("domain %0d: age window %0d..%0d", d, amin[d], amax[d]));
    end

    // ---- 3. set ----
    $display("test 3: set");
    @(posedge clk); set_val <= 64'h0000_0123_4567_8000; set <= 1;
    @(posedge clk); set <= 0;
    #0.5;
    if (ns !== 64'h0000_0123_4567_8000 || frac !== 0) fail($sformatf("after set: ns = 0x%016x", ns));
    @(posedge clk); #0.5;
    if (ns !== 64'h0000_0123_4567_8004) fail($sformatf("after set + 1: ns = 0x%016x", ns));

    // ---- 4. adj (negative) ----
    $display("test 4: adj");
    @(posedge clk); adj_val <= -64'sd1_000_000;
    repeat (4) @(posedge clk);
    #0.5 a = ns;
    @(posedge clk); adj <= 1;
    @(posedge clk); adj <= 0;
    #0.5 b = ns;
    // two cycles: one normal (+4), one with adj (+4 - 1e6)
    if (b != a + 8 - 1_000_000) fail($sformatf("adj: delta %0d", longint'(b - a)));

    // ---- 5. adjfine: +100 ppm ----
    $display("test 5: inc_load");
    @(posedge clk);
    inc_ns_in <= 8'd4; inc_frac_in <= 32'd1717987;      // 0.0004 ns = 4e-4 * 2^32
    inc_load <= 1;
    @(posedge clk); inc_load <= 0;
    @(posedge clk);
    if (inc_frac !== 32'd1717987) fail("inc_load: INC_FRAC not applied");
    a = ns; repeat (100000) @(posedge clk); b = ns;
    if (b - a < 400039 || b - a > 400041) fail($sformatf("rate after inc_load: %0d ns / 100000 cycles", b - a));

    if (errors == 0) $display("tb_pktrec_timebase: PASS");
    else $display("tb_pktrec_timebase: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #20ms;
    $display("tb_pktrec_timebase: FAIL (timeout)");
    $finish;
  end

endmodule
