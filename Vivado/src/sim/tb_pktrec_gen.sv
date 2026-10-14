// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_pktrec_gen -- self-checking testbench for the traffic generator
// (pktrec_gen) and the receive checker (pktrec_gen_chk).
//
// The generator drives a TX MAC model (tx_clk 62.5 MHz: tready low for 10
// cycles after every frame = 12 B IFG + 8 B preamble, as the Taxi MAC at
// 1 Gb/s); every frame is compared byte for byte with a reference built like
// test/gen_seq.py's FrameBuilder (FORMAT 0) or the raw layout (FORMAT 1). The
// same frames are looped into the checker (as an RX stream), optionally with
// frames removed / duplicated.
//
// Checks:
//   1. PRSQ format, 60 B, COUNT 100, IFG 12: 100 frames exactly, seq
//      SEQ_FIRST.., IPv4 checksum / lengths / magic / stream as gen_seq.py,
//      start-to-start spacing = 42 cycles (line rate), done = 1, FRAMES/BYTES
//   2. PRSQ 1514 B, IFG 1000: spacing = ceil((1514 + 12 + 1000) / 2)
//   3. raw format (EtherType 0x88B5, u32 seq at offset 14), random lengths
//      LEN 60 + (LFSR & 1023): every length in range, frame content exact
//   4. COUNT 0 (endless) + stop: ENABLE = 0 ends after the current frame,
//      never cuts a frame (tvalid continuous within a frame)
//   5. checker: in-order stream -> LOST 0 / ERRORS 0 / FRAMES = sent; frames
//      removed -> LOST = removed; a duplicate -> ERRORS 1; bad frames -> BAD
//   6. 802.1Q tag (GEN_VLAN, m0 map 1.4): PRSQ 1518 B + tag = 1522 B on the wire
//      (VID 100, as gen_seq.py --vlan 100 --size 1522) and PRSQ 62 B (the minimum
//      with a tag), raw format with a tag; the checker counts tagged frames like
//      untagged ones (LOST / ERRORS 0), also mixed with untagged frames
//   7. checker on a MAC-like RX stream: random tvalid gaps inside frames (16-bit
//      MAC / SGMII rate adaptation / shell FIFO), frames back to back (beat 0
//      in the cycle after tlast) or after random idle; untagged PRSQ at 64 B
//      and 1518 B on the wire (gen_seq.py layout: EtherType @12, IPv4 @14,
//      UDP @34, "PRSQ" @42, seq @50) mixed with tagged PRSQ -> FRAMES = sent,
//      LOST / ERRORS 0. Bench C (m0 1.4 bitstream) counted 0 untagged PRSQ
//      frames: the RTL passed 1-6 but the synthesized netlist did not -- run
//      this testbench on the post-synthesis netlist with scripts/sim_netlist.tcl
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

module tb_pktrec_gen;

  int errors = 0;
  task automatic fail(input string msg);
    errors++;
    if (errors < 30) $display("FAIL: %s (t=%0t)", msg, $time);
  endtask

  reg clk = 0;
  always #8 clk = ~clk;
  reg rst = 1;

  reg        enable = 0, fmt_raw = 0, rand_len = 0;
  reg [13:0] len = 60, len_mask = 0;
  reg [15:0] ifg = 12;
  reg [31:0] count = 0;
  reg [47:0] dst = 48'h0011_2233_4455, src = 48'h0200_0000_0002;
  reg [15:0] etype = 16'h88B5;
  reg [31:0] stream = 32'd7, seq_first = 32'd1000;
  reg        vlan_en = 0;
  reg [15:0] vlan_tci = 16'd100;
  wire [15:0] tdata;
  wire [1:0]  tkeep;
  wire        tvalid, tlast, running, done;
  reg         tready = 0;
  wire [63:0] frames, bytes;

  pktrec_gen dut (
    .clk(clk), .rst(rst), .enable(enable), .allow(1'b1), .fmt_raw(fmt_raw), .rand_len(rand_len),
    .len(len), .len_mask(len_mask), .ifg(ifg), .count(count), .dst(dst), .src(src),
    .etype(etype), .stream(stream), .seq_first(seq_first), .vlan_en(vlan_en), .vlan_tci(vlan_tci),
    .m_tdata(tdata), .m_tkeep(tkeep), .m_tvalid(tvalid), .m_tready(tready), .m_tlast(tlast),
    .running(running), .done(done), .frames(frames), .bytes(bytes)
  );

  // checker fed by the TB
  reg         c_en = 0, c_raw = 0;
  reg  [15:0] c_tdata = 0;
  reg         c_tvalid = 0, c_tlast = 0, c_tbad = 0;
  wire [31:0] c_frames, c_lost, c_errors, c_bad;
  wire [63:0] c_last;
  pktrec_gen_chk chk (
    .clk(clk), .rst(rst), .enable(c_en), .fmt_raw(c_raw), .etype(16'h88B5),
    .s_tdata(c_tdata), .s_tvalid(c_tvalid), .s_tlast(c_tlast), .s_tbad(c_tbad),
    .frames(c_frames), .lost(c_lost), .errors(c_errors), .bad(c_bad), .last_seq(c_last)
  );

  // ---- MAC model: tready, frame capture ----
  int gap = 0;
  byte unsigned cur[$];
  typedef byte unsigned frame_t[$];
  frame_t got_q[$];
  longint unsigned start_cyc[$];
  longint unsigned cyc = 0;
  bit in_fr = 0;
  always @(posedge clk) begin
    cyc <= cyc + 1;
    if (tvalid && tready) begin
      if (!in_fr) start_cyc.push_back(cyc);
      in_fr = !tlast;
      cur.push_back(tdata[7:0]);
      if (tkeep[1]) cur.push_back(tdata[15:8]);
      if (tlast) begin
        got_q.push_back(cur);
        cur.delete();
      end
    end else if (in_fr && !tvalid) begin
      fail("tvalid dropped inside a frame");
    end
    if (tvalid && tready && tlast) gap = 10;
    else if (gap > 0) gap = gap - 1;
    tready <= (gap == 0) && !(tvalid && tready && tlast);
  end

  // ---- reference frames ----
  function automatic frame_t ref_frame(input bit raw, input int l, input longint unsigned seq);
    frame_t f;
    for (int i = 5; i >= 0; i--) f.push_back(dst[8*i +: 8]);
    for (int i = 5; i >= 0; i--) f.push_back(src[8*i +: 8]);
    if (vlan_en) begin
      f.push_back(8'h81); f.push_back(8'h00); f.push_back(vlan_tci[15:8]); f.push_back(vlan_tci[7:0]);
    end
    if (raw) begin
      f.push_back(etype[15:8]); f.push_back(etype[7:0]);
      for (int i = 3; i >= 0; i--) f.push_back(seq[8*i +: 8]);
    end else begin
      int tot = l - (vlan_en ? 18 : 14), ulen = tot - 20;
      int s = 0;
      byte unsigned ip[20];
      ip = '{8'h45, 8'h00, tot[15:8], tot[7:0], 0, 0, 8'h40, 8'h00, 64, 17, 0, 0,
             192, 0, 2, 1, 192, 0, 2, 2};
      for (int i = 0; i < 20; i += 2) s += {ip[i], ip[i+1]};
      s = (s >> 16) + (s & 16'hFFFF);
      s = s + (s >> 16);
      s = ~s & 16'hFFFF;
      ip[10] = s[15:8]; ip[11] = s[7:0];
      f.push_back(8'h08); f.push_back(8'h00);
      foreach (ip[i]) f.push_back(ip[i]);
      f.push_back(8'hC3); f.push_back(8'h50); f.push_back(8'hC3); f.push_back(8'h51);
      f.push_back(ulen[15:8]); f.push_back(ulen[7:0]); f.push_back(0); f.push_back(0);
      f.push_back("P"); f.push_back("R"); f.push_back("S"); f.push_back("Q");
      for (int i = 3; i >= 0; i--) f.push_back(stream[8*i +: 8]);
      for (int i = 7; i >= 0; i--) f.push_back(seq[8*i +: 8]);
    end
    while (f.size() < l) f.push_back(0);
    return f;
  endfunction

  task automatic check_frames(input bit raw, input int n, input longint unsigned seq0, input int lmin,
                              input int lmax, input int spacing, input string what);
    longint unsigned sum = 0;
    if (got_q.size() != n) fail($sformatf("%s: %0d frames, expected %0d", what, got_q.size(), n));
    for (int i = 0; i < got_q.size(); i++) begin
      frame_t g = got_q[i];
      frame_t r;
      int l = g.size();
      if (l < lmin || l > lmax) fail($sformatf("%s frame %0d: length %0d not in %0d..%0d", what, i, l, lmin, lmax));
      r = ref_frame(raw, l, seq0 + i);
      for (int b = 0; b < l; b++)
        if (g[b] !== r[b]) begin
          fail($sformatf("%s frame %0d: byte %0d = %02x, expected %02x", what, i, b, g[b], r[b]));
          break;
        end
      sum += l + 4;
      if (spacing > 0 && i > 0 && start_cyc[i] - start_cyc[i-1] != spacing)
        fail($sformatf("%s frame %0d: start spacing %0d, expected %0d", what, i, start_cyc[i] - start_cyc[i-1], spacing));
    end
    if (frames != n) fail($sformatf("%s: FRAMES %0d", what, frames));
    if (bytes != sum) fail($sformatf("%s: BYTES %0d, expected %0d", what, bytes, sum));
  endtask

  task automatic run(input int n);
    got_q.delete(); start_cyc.delete();
    @(posedge clk); enable <= 1;
    while (got_q.size() < n) @(posedge clk);
    repeat (200) @(posedge clk);
    enable <= 0;
    repeat (5) @(posedge clk);
  endtask

  // loop frames into the checker
  task automatic feed(input frame_t f, input bit bad);
    int nb = (f.size() + 1) / 2;
    for (int b = 0; b < nb; b++) begin
      @(posedge clk);
      c_tdata  <= {(2*b+1 < f.size()) ? f[2*b+1] : 8'h00, f[2*b]};
      c_tvalid <= 1; c_tlast <= (b == nb - 1); c_tbad <= bad;
    end
    @(posedge clk); c_tvalid <= 0; c_tlast <= 0;
    repeat (12) @(posedge clk);
  endtask

  // MAC-like feed: random tvalid gaps inside the frame (gap_pct % of cycles),
  // idle after tlast = 0 (back to back) .. max_idle cycles
  task automatic feed_gapped(input frame_t f, input bit bad, input int gap_pct, input int max_idle);
    int nb = (f.size() + 1) / 2;
    int b = 0;
    while (b < nb) begin
      @(posedge clk);
      if ($urandom_range(99) < gap_pct) begin
        c_tvalid <= 0; c_tlast <= 0; c_tdata <= $urandom;
      end else begin
        c_tdata  <= {(2*b+1 < f.size()) ? f[2*b+1] : 8'h00, f[2*b]};
        c_tvalid <= 1; c_tlast <= (b == nb - 1); c_tbad <= bad;
        b++;
      end
    end
    begin
      int idle = $urandom_range(max_idle);
      for (int i = 0; i < idle; i++) begin
        @(posedge clk); c_tvalid <= 0; c_tlast <= 0; c_tdata <= $urandom;
      end
    end
  endtask

  initial begin
    frame_t saved[$];
    $display("tb_pktrec_gen: start");
    repeat (5) @(posedge clk);
    rst <= 0;
    repeat (5) @(posedge clk);

    $display("test 1: PRSQ 60 B, COUNT 100, line rate");
    count = 100;
    run(100);
    if (!done) fail("test 1: done not set");
    if (running) fail("test 1: still running");
    check_frames(0, 100, 1000, 60, 60, 42, "test 1");
    saved = got_q;

    $display("test 2: PRSQ 1514 B, IFG 1000");
    len = 1514; ifg = 1000; count = 6;
    run(6);
    check_frames(0, 6, 1000, 1514, 1514, (1514 + 12 + 1000 + 1) / 2, "test 2");

    $display("test 3: raw, random lengths");
    fmt_raw = 1; rand_len = 1; len = 60; len_mask = 1023; ifg = 12; count = 200; seq_first = 5;
    run(200);
    check_frames(1, 200, 5, 60, 60 + 1023, 0, "test 3");
    begin
      int lmin = 9999, lmax = 0;
      foreach (got_q[i]) begin
        if (got_q[i].size() < lmin) lmin = got_q[i].size();
        if (got_q[i].size() > lmax) lmax = got_q[i].size();
      end
      $display("  lengths %0d..%0d", lmin, lmax);
      if (lmax - lmin < 500) fail("test 3: lengths hardly random");
    end

    $display("test 4: endless + stop");
    fmt_raw = 0; rand_len = 0; len = 200; count = 0; seq_first = 0;
    got_q.delete(); start_cyc.delete();
    @(posedge clk); enable <= 1;
    repeat (2000) @(posedge clk);
    enable <= 0;
    repeat (300) @(posedge clk);
    if (running) fail("test 4: still running after stop");
    if (done) fail("test 4: done set on a manual stop");
    $display("  %0d frames before stop", got_q.size());
    check_frames(0, got_q.size(), 0, 200, 200, (200 + 24 + 1) / 2, "test 4");

    $display("test 5: checker");
    c_en <= 1; c_raw <= 0;
    repeat (5) @(posedge clk);
    for (int i = 0; i < 100; i++) if (i != 10 && !(i >= 50 && i < 53)) feed(saved[i], 0);
    feed(saved[60], 0);                       // duplicate / out of order
    feed(saved[99], 1);                       // bad frame
    repeat (10) @(posedge clk);
    if (c_frames != 97) fail($sformatf("CHK_FRAMES %0d, expected 97", c_frames));
    if (c_lost != 4) fail($sformatf("CHK_LOST %0d, expected 4", c_lost));
    if (c_errors != 1) fail($sformatf("CHK_ERRORS %0d, expected 1", c_errors));
    if (c_bad != 1) fail($sformatf("CHK_BAD %0d, expected 1", c_bad));
    if (c_last != 1099) fail($sformatf("CHK_LAST_SEQ %0d, expected 1099", c_last));
    // re-enable clears
    c_en <= 0; repeat (3) @(posedge clk); c_en <= 1; repeat (3) @(posedge clk);
    if (c_frames != 0 || c_lost != 0) fail("checker not cleared by ENABLE 0->1");

    $display("test 6: 802.1Q tag");
    c_en <= 0;
    vlan_en = 1; vlan_tci = 16'd100;
    fmt_raw = 0; rand_len = 0; len = 1518; ifg = 12; count = 8; seq_first = 77;
    run(8);
    check_frames(0, 8, 77, 1518, 1518, (1518 + 24 + 1) / 2, "test 6 PRSQ 1522 B tagged");
    if (got_q.size() > 0) begin
      // gen_seq.py offsets: tag at 12, IPv4 at 18, UDP at 38, "PRSQ" at 46, seq at 54
      frame_t g = got_q[0];
      if (g[12] != 8'h81 || g[13] != 8'h00 || g[14] != 8'h00 || g[15] != 8'd100 ||
          g[16] != 8'h08 || g[17] != 8'h00 || g[46] != "P" || g[49] != "Q" || g[61] != 8'd77)
        fail("test 6: tagged PRSQ layout");
      $display("  %0d B + FCS = %0d B on the wire", g.size(), g.size() + 4);
    end
    saved = got_q;
    len = 62; count = 4; seq_first = 85;
    run(4);
    check_frames(0, 4, 85, 62, 62, 0, "test 6 PRSQ 62 B tagged");
    foreach (got_q[i]) saved.push_back(got_q[i]);
    fmt_raw = 1; len = 100; count = 4; seq_first = 9;
    run(4);
    check_frames(1, 4, 9, 100, 100, 0, "test 6 raw tagged");
    // checker: tagged PRSQ seq 77..88 with seq 80 replaced by an untagged frame
    vlan_en = 0;
    c_raw <= 0; c_en <= 0; repeat (3) @(posedge clk); c_en <= 1; repeat (3) @(posedge clk);
    for (int i = 0; i < 12; i++) begin
      if (i == 3) feed(ref_frame(0, 200, 80), 0);
      else feed(saved[i], 0);
    end
    repeat (10) @(posedge clk);
    if (c_frames != 12 || c_lost != 0 || c_errors != 0 || c_last != 88)
      fail($sformatf("test 6 checker PRSQ: frames %0d lost %0d errors %0d last %0d (12/0/0/88)",
                     c_frames, c_lost, c_errors, c_last));
    // raw checker on tagged frames
    c_raw <= 1; c_en <= 0; repeat (3) @(posedge clk); c_en <= 1; repeat (3) @(posedge clk);
    foreach (got_q[i]) if (i != 1) feed(got_q[i], 0);
    repeat (10) @(posedge clk);
    if (c_frames != 3 || c_lost != 1 || c_errors != 0 || c_last != 12)
      fail($sformatf("test 6 checker raw: frames %0d lost %0d errors %0d last %0d (3/1/0/12)",
                     c_frames, c_lost, c_errors, c_last));

    $display("test 7: checker, gapped MAC-like RX stream, untagged + tagged PRSQ");
    process::self().srandom(32'h5052_5351);
    c_raw <= 0; c_en <= 0; repeat (3) @(posedge clk); c_en <= 1; repeat (3) @(posedge clk);
    for (int i = 0; i < 60; i++) begin
      int l = (i % 3 == 2) ? 1514 : 60;          // 64 B / 1518 B on the wire (+ FCS)
      vlan_en = (i % 5 == 4);                    // every 5th frame tagged (VID 100)
      feed_gapped(ref_frame(0, vlan_en ? l + 4 : l, 64'd5000 + i), 0, 30, (i % 4 == 0) ? 0 : 6);
    end
    vlan_en = 0;
    @(posedge clk); c_tvalid <= 0; c_tlast <= 0;
    repeat (10) @(posedge clk);
    if (c_frames != 60 || c_lost != 0 || c_errors != 0 || c_bad != 0 || c_last != 5059)
      fail($sformatf("test 7 gapped: frames %0d lost %0d errors %0d bad %0d last %0d (60/0/0/0/5059)",
                     c_frames, c_lost, c_errors, c_bad, c_last));
    // untagged only, no gaps, back to back (the M5 / bench C stream)
    c_en <= 0; repeat (3) @(posedge clk); c_en <= 1; repeat (3) @(posedge clk);
    for (int i = 0; i < 20; i++) feed_gapped(ref_frame(0, 1514, 64'd100 + i), 0, 0, 0);
    @(posedge clk); c_tvalid <= 0; c_tlast <= 0;
    repeat (10) @(posedge clk);
    if (c_frames != 20 || c_lost != 0 || c_errors != 0 || c_last != 119)
      fail($sformatf("test 7 untagged b2b: frames %0d lost %0d errors %0d last %0d (20/0/0/119)",
                     c_frames, c_lost, c_errors, c_last));

    if (errors == 0) $display("tb_pktrec_gen: PASS");
    else $display("tb_pktrec_gen: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #40ms;
    $display("tb_pktrec_gen: FAIL (timeout)");
    $finish;
  end

endmodule
