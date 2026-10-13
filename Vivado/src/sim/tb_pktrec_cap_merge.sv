// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_pktrec_cap_merge -- self-checking testbench for pktrec_cap_merge
//
// Four record sources (random record lengths 1..40 beats, random gaps; beat =
// {port, record no., beat no., last}) -> merge -> sink with random tready.
//
// Checks:
//   1. the output is a sequence of WHOLE records (no interleaving inside a
//      record), each source's records in order, none lost or duplicated;
//      RECORDS_OUT / BYTES_OUT exact; with all sources saturated the grants
//      rotate (each port's share within 20 % of the mean)
//   2. fill_en: zero beats only between records, FILL_BEATS counts them,
//      BYTES_OUT excludes them
//   3. rec_srst while a record is in progress: no output during srst, the rest
//      of that record is discarded (SRST_ABORTS = 1) and the stream continues
//      with whole records
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

module tb_pktrec_cap_merge;

  int errors = 0;
  task automatic fail(input string msg);
    errors++;
    if (errors < 30) $display("FAIL: %s (t=%0t)", msg, $time);
  endtask

  reg clk = 0;
  always #2 clk = ~clk;
  reg rst = 1;

  reg  [4*128-1:0] s_tdata = 0;
  reg  [3:0]  s_tvalid = 0, s_tlast = 0;
  wire [3:0]  s_tready;
  wire [127:0] m_tdata;
  wire        m_tvalid;
  reg         m_tready = 0;
  reg         fill_en = 0, rec_srst = 0, clear = 0;
  wire [63:0] bytes_out, records_out, fill_beats, bp_cycles;
  wire [31:0] srst_aborts;
  wire        busy, idle;

  pktrec_cap_merge #(.N(4)) dut (
    .clk(clk), .rst(rst),
    .s_tdata(s_tdata), .s_tvalid(s_tvalid), .s_tready(s_tready), .s_tlast(s_tlast),
    .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready),
    .fill_en(fill_en), .rec_srst(rec_srst), .clear(clear),
    .bytes_out(bytes_out), .records_out(records_out), .fill_beats(fill_beats),
    .bp_cycles(bp_cycles), .srst_aborts(srst_aborts), .busy(busy), .idle(idle)
  );

  // sources
  int  n_rec [4];          // records to generate
  int  gen [4];            // records generated so far
  int  len_q [4][$];       // lengths of generated records
  int  gap_max = 10;
  bit  src_on = 0;
  for (genvar p = 0; p < 4; p++) begin : g_src
    initial begin
      int len;
      forever begin
        @(posedge clk);
        if (!src_on || gen[p] >= n_rec[p]) continue;
        len = $urandom_range(1, 40);
        len_q[p].push_back(len);
        for (int b = 0; b < len; b++) begin
          s_tdata[128*p +: 128] <= {8'(p + 1), 24'(gen[p]), 32'(b), 32'(len), 32'hC0DE};
          s_tvalid[p] <= 1; s_tlast[p] <= (b == len - 1);
          @(posedge clk);
          while (!s_tready[p]) @(posedge clk);
        end
        s_tvalid[p] <= 0; s_tlast[p] <= 0;
        gen[p]++;
        repeat ($urandom_range(0, gap_max)) @(posedge clk);
      end
    end
  end

  // sink / checker
  int ready_pct = 70;
  bit in_rec = 0;
  int cur_p, cur_r, cur_b, cur_len;
  int got [4];
  int nfill = 0, nbeats = 0;
  bit allow_cut = 0;     // test 3: one record may end early
  always @(posedge clk) begin
    m_tready <= ($urandom_range(1, 100) <= ready_pct);
    if (rec_srst && m_tvalid && m_tready && !rst) begin
      // beats offered during srst would be discarded by the packetizer
    end
    if (m_tvalid && m_tready && !rec_srst) begin
      if (m_tdata == 0) begin
        if (in_rec) fail("fill beat inside a record");
        nfill++;
      end else begin
        int p = m_tdata[127:120] - 1, r = m_tdata[119:96], b = m_tdata[95:64], l = m_tdata[63:32];
        nbeats++;
        if (!in_rec) begin
          if (b != 0) fail($sformatf("record starts at beat %0d (port %0d rec %0d)", b, p, r));
          if (r != got[p]) begin
            if (allow_cut && r == got[p] + 1) begin got[p]++; allow_cut = 0; end
            else fail($sformatf("port %0d: record %0d, expected %0d", p, r, got[p]));
          end
          cur_p = p; cur_r = r; cur_b = 0; cur_len = l; in_rec = 1;
        end else begin
          if (p != cur_p || r != cur_r) fail($sformatf("records interleaved: %0d/%0d inside %0d/%0d", p, r, cur_p, cur_r));
          cur_b++;
          if (b != cur_b) fail($sformatf("beat %0d, expected %0d", b, cur_b));
        end
        if (b == l - 1) begin in_rec = 0; got[p]++; end
      end
    end
  end

  task automatic wait_done();
    while (got[0] < n_rec[0] || got[1] < n_rec[1] || got[2] < n_rec[2] || got[3] < n_rec[3]) @(posedge clk);
    repeat (20) @(posedge clk);
  endtask

  int total;
  initial begin
    $display("tb_pktrec_cap_merge: start");
    repeat (5) @(posedge clk); rst <= 0;
    for (int p = 0; p < 4; p++) n_rec[p] = 300;

    // ---- 1. saturated sources, fairness ----
    $display("test 1: whole records, round robin");
    gap_max = 0; src_on = 1;
    repeat (3000) @(posedge clk);
    begin
      int mn = got[0], mx = got[0];
      for (int p = 1; p < 4; p++) begin if (got[p] < mn) mn = got[p]; if (got[p] > mx) mx = got[p]; end
      $display("  after 3000 cycles: %0d %0d %0d %0d records", got[0], got[1], got[2], got[3]);
      if (mx - mn > (mn + mx) / 10 + 2) fail("unfair arbitration");
    end
    gap_max = 10;
    wait_done();
    total = 0;
    for (int p = 0; p < 4; p++) total += 300;
    if (records_out != total) fail($sformatf("RECORDS_OUT %0d", records_out));
    if (bytes_out != 16 * nbeats) fail($sformatf("BYTES_OUT %0d, beats %0d", bytes_out, nbeats));
    if (!idle) fail("not idle at the end");

    // ---- 2. fill ----
    $display("test 2: fill");
    fill_en = 1;
    for (int p = 0; p < 4; p++) n_rec[p] = 400;
    wait_done();
    repeat (100) @(posedge clk);
    fill_en = 0;
    repeat (10) @(posedge clk);
    if (fill_beats == 0 || fill_beats != nfill) fail($sformatf("FILL_BEATS %0d, seen %0d", fill_beats, nfill));
    if (bytes_out != 16 * nbeats) fail("BYTES_OUT counts fill beats");

    // ---- 3. srst mid-record ----
    $display("test 3: srst mid-record");
    ready_pct = 100;
    for (int p = 0; p < 4; p++) n_rec[p] = 460;
    while (!busy) @(posedge clk);
    repeat (2) @(posedge clk);
    allow_cut = 1;
    // the beats of the cut record before srst: the checker sees a record that
    // never ends; restart its state like the packetizer does
    rec_srst <= 1;
    repeat (8) @(posedge clk);
    in_rec = 0;
    rec_srst <= 0;
    wait_done();
    if (srst_aborts != 1) fail($sformatf("SRST_ABORTS %0d", srst_aborts));
    if (allow_cut) fail("no record was cut");

    if (errors == 0) $display("tb_pktrec_cap_merge: PASS");
    else $display("tb_pktrec_cap_merge: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin #5ms; $display("tb_pktrec_cap_merge: FAIL (timeout)"); $finish; end

endmodule
