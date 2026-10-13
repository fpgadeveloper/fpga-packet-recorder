// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_pktrec_cap_port -- self-checking testbench for one capture port
//
// A MAC RX model (rx_clk 62.5 MHz - 150 ppm, 16-bit beats, no tready, odd
// lengths end with tkeep = 01, bad flag at tlast, the timebase cycle count of
// its SFD held for the frame) feeds pktrec_cap_port (PORT = 2, 16 KB FIFO); the record
// stream (dp_clk 250 MHz) goes to a sink with programmable tready and a parser
// that checks every record against a scoreboard. The timebase is modelled as
// a cycle counter cyc (starting 200000 cycles below its 32-bit wrap) and
// tb_ns = BASE + 4 * cyc (INC = 4.0 ns); the expected header timestamp is
// BASE + 4 * cyc_sfd + MAC_OFFSET, so the cycle -> ns conversion is checked
// exactly, across the counter wrap.
//
// Checks:
//   1. random lengths 1..1514 (+ bad frames), random tready: every frame is a
//      record, in order, seq 0,1,2,..; header ts/cap_len/orig_len/port/flags
//      exact; data exact; padding zero; tlast on the last beat only
//   2. SNAPLEN 64 and 61: cap_len = min(len, snaplen), TRUNC flag, data prefix,
//      FRAMES_TRUNC counter
//   3. back-pressure overflow: tready = 0, 40 x 1514-byte frames -> records are
//      an in-order subset, the missing seq numbers are exactly the drops,
//      FRAMES_DROP / BYTES_DROP exact, FRAMES_RX = RECORDS + FRAMES_DROP
//   4. cap_en = 0: frames are ignored (no record, no count, seq unchanged);
//      a frame already in progress when cap_en rises is not captured
//   5. 64-byte frames at line rate (IFG 6 cycles), tready = 1: zero drops
//   6. clear: counters and seq restart at 0; idle = 1 at the end of each test
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

module tb_pktrec_cap_port;

  localparam int PORT = 2;
  localparam int FIFO_BYTES = 16384;
  localparam longint unsigned BASE = 64'h1876_5432_1000_0000;
  localparam longint unsigned CYC0 = 64'h1_0000_0000 - 64'd200_000;
  localparam int MAC_OFFSET = -37;

  int errors = 0;
  task automatic fail(input string msg);
    errors++;
    if (errors < 30) $display("FAIL: %s (t=%0t)", msg, $time);
  endtask

  // ---------------------------------------------------------------------------
  // Clocks / resets
  // ---------------------------------------------------------------------------
  reg rx_clk = 0, dp_clk = 0;
  always #8.0012 rx_clk = ~rx_clk;     // 62.49 MHz
  always #2.0 dp_clk = ~dp_clk;        // 250 MHz
  reg rx_rst = 1, dp_rst = 1;

  // timebase model: cycle counter + ns = BASE + 4 * cycles
  longint unsigned cyc_ctr = CYC0;
  reg [63:0] tb_ns = 0;
  reg [31:0] tb_cyc = 0;
  always @(posedge dp_clk) begin
    cyc_ctr <= cyc_ctr + 1;
    tb_cyc  <= cyc_ctr[31:0];
    tb_ns   <= BASE + 4 * cyc_ctr;
  end

  // ---------------------------------------------------------------------------
  // DUT
  // ---------------------------------------------------------------------------
  reg  [15:0] rx_tdata = 0;
  reg  [1:0]  rx_tkeep = 0;
  reg         rx_tvalid = 0, rx_tlast = 0, rx_tbad = 0;
  reg  [31:0] rx_ts = 0;
  reg         cap_en = 0;
  reg  [15:0] snaplen = 0;
  reg         clear = 0, hwm_clr = 0;
  wire [127:0] m_tdata;
  wire        m_tvalid, m_tlast;
  reg         m_tready = 0;
  wire [63:0] st_frames_rx, st_frames_bad, st_frames_drop, st_bytes_rx, st_bytes_drop,
              st_frames_trunc, st_records;
  wire [15:0] st_seq_next;
  wire        st_rx_active, idle, len_fixup;
  wire [31:0] st_fifo_hwm;

  pktrec_cap_port #(.PORT(PORT), .FIFO_BYTES(FIFO_BYTES)) dut (
    .rx_clk(rx_clk), .rx_rst(rx_rst),
    .rx_tdata(rx_tdata), .rx_tkeep(rx_tkeep), .rx_tvalid(rx_tvalid), .rx_tlast(rx_tlast),
    .rx_tbad(rx_tbad), .rx_ts_cyc(rx_ts),
    .dp_clk(dp_clk), .dp_rst(dp_rst),
    .cap_en(cap_en), .snaplen(snaplen), .clear(clear), .tb_ns(tb_ns),
    .tb_cyc(tb_cyc), .tb_inc(40'h4_0000_0000), .mac_offset(MAC_OFFSET),
    .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tlast(m_tlast),
    .st_frames_rx(st_frames_rx), .st_frames_bad(st_frames_bad), .st_frames_drop(st_frames_drop),
    .st_bytes_rx(st_bytes_rx), .st_bytes_drop(st_bytes_drop), .st_frames_trunc(st_frames_trunc),
    .st_seq_next(st_seq_next), .st_rx_active(st_rx_active), .st_records(st_records),
    .st_fifo_hwm(st_fifo_hwm), .hwm_clr(hwm_clr), .idle(idle), .len_fixup(len_fixup)
  );

  // ---------------------------------------------------------------------------
  // Scoreboard
  // ---------------------------------------------------------------------------
  class Frame;
    byte unsigned data[$];
    bit bad;
    longint unsigned cyc;  // timebase cycle at SFD
    longint unsigned ts;   // expected header timestamp
    int seq;               // -1: not captured (port disabled)
  endclass

  Frame tx_q[$];           // frames to send
  Frame exp_q[$];          // frames expected as records (in seq order), incl. droppable
  int   seq_ctr = 0;
  bit   allow_drop = 0;
  int   n_records = 0, n_skipped = 0;
  longint unsigned skipped_bytes = 0;
  int   cur_snap = 0;
  int   ifg = 8;
  bit   rx_busy = 0;

  function automatic Frame make_frame(input int len, input bit bad);
    Frame f = new();
    for (int i = 0; i < len; i++) f.data.push_back($urandom_range(0, 255));
    f.bad = bad;
    return f;
  endfunction

  // queue a frame; it is expected as a record if captured (cap_en at send time
  // is decided by the caller through 'captured')
  task automatic send(input int len, input bit bad, input bit captured);
    Frame f = make_frame(len, bad);
    f.seq = captured ? seq_ctr : -1;
    if (captured) begin
      seq_ctr = (seq_ctr + 1) & 16'hFFFF;
      exp_q.push_back(f);
    end
    tx_q.push_back(f);
  endtask

  // RX MAC model
  initial begin
    Frame f;
    int nb;
    forever begin
      @(posedge rx_clk);
      if (tx_q.size() == 0 || rx_rst) begin rx_busy = 0; continue; end
      rx_busy = 1;
      f = tx_q.pop_front();
      nb = (f.data.size() + 1) / 2;
      f.cyc = cyc_ctr - $urandom_range(0, 60);         // SFD "a bit earlier"
      f.ts  = BASE + 4 * f.cyc;
      f.ts  = f.ts - 64'd37;                            // MAC_OFFSET = -37
      for (int b = 0; b < nb; b++) begin
        rx_tdata  <= {(2*b+1 < f.data.size()) ? f.data[2*b+1] : 8'hXX, f.data[2*b]};
        rx_tkeep  <= (2*b+1 < f.data.size()) ? 2'b11 : 2'b01;
        rx_tvalid <= 1'b1;
        rx_tlast  <= (b == nb - 1);
        rx_tbad   <= (b == nb - 1) ? f.bad : 1'bx;
        rx_ts     <= f.cyc[31:0];
        @(posedge rx_clk);
      end
      rx_tvalid <= 1'b0;
      rx_tlast  <= 1'b0;
      rx_tdata  <= 16'hXXXX;
      repeat (ifg - 1) @(posedge rx_clk);
    end
  end

  // record parser
  initial begin
    bit in_rec = 0;
    Frame f;
    int beat_i, nbeats, cap, orig, seq, flags, port;
    longint unsigned ts;
    byte unsigned b;
    forever begin
      @(posedge dp_clk);
      if (!(m_tvalid && m_tready)) continue;
      if (!in_rec) begin
        ts    = m_tdata[63:0];
        cap   = m_tdata[79:64];
        orig  = m_tdata[95:80];
        port  = m_tdata[103:96];
        flags = m_tdata[111:104];
        seq   = m_tdata[127:112];
        n_records++;
        // find the expected frame; skip dropped ones when allowed
        f = null;
        while (exp_q.size() > 0) begin
          f = exp_q.pop_front();
          if (f.seq == seq) break;
          if (!allow_drop) fail($sformatf("record seq %0d, expected seq %0d (frame lost)", seq, f.seq));
          n_skipped++;
          skipped_bytes += f.data.size() + 4;
          f = null;
        end
        if (f == null) begin
          fail($sformatf("record seq %0d not in the scoreboard", seq));
          in_rec = !m_tlast;
          continue;
        end
        begin
          int len = f.data.size();
          int exp_cap = (cur_snap != 0 && len > cur_snap) ? cur_snap : len;
          int exp_flags = 8'hA4 | (f.bad ? 1 : 0) | ((exp_cap < len) ? 2 : 0);
          if (ts !== f.ts) fail($sformatf("seq %0d: ts 0x%016x, expected 0x%016x", seq, ts, f.ts));
          if (cap != exp_cap) fail($sformatf("seq %0d: cap_len %0d, expected %0d", seq, cap, exp_cap));
          if (orig != len + 4) fail($sformatf("seq %0d: orig_len %0d, expected %0d", seq, orig, len + 4));
          if (port != PORT) fail($sformatf("seq %0d: port %0d", seq, port));
          if (flags != exp_flags) fail($sformatf("seq %0d: flags 0x%02x, expected 0x%02x", seq, flags, exp_flags));
          nbeats = (exp_cap + 15) / 16;
          if (m_tlast) fail($sformatf("seq %0d: tlast on the header", seq));
        end
        beat_i = 0;
        in_rec = 1;
      end else begin
        for (int k = 0; k < 16; k++) begin
          b = m_tdata[8*k +: 8];
          if (16*beat_i + k < cap) begin
            if (b !== f.data[16*beat_i + k])
              fail($sformatf("seq %0d: byte %0d = %02x, expected %02x", seq, 16*beat_i + k, b, f.data[16*beat_i + k]));
          end else if (b !== 8'h00) begin
            fail($sformatf("seq %0d: padding byte %0d = %02x", seq, 16*beat_i + k, b));
          end
        end
        beat_i++;
        if (m_tlast != (beat_i == nbeats))
          fail($sformatf("seq %0d: tlast %0d at data beat %0d of %0d", seq, m_tlast, beat_i, nbeats));
        if (m_tlast) in_rec = 0;
      end
    end
  end

  // tready pattern
  int ready_pct = 100;
  always @(posedge dp_clk) m_tready <= ($urandom_range(1, 100) <= ready_pct);

  always @(posedge dp_clk) if (len_fixup) fail("len_fixup pulse");

  // ---------------------------------------------------------------------------
  // helpers
  // ---------------------------------------------------------------------------
  task automatic wait_rx_done();
    while (tx_q.size() > 0 || rx_busy) @(posedge rx_clk);
    repeat (20) @(posedge rx_clk);
  endtask

  task automatic wait_idle(input string what);
    int t = 0;
    repeat (200) @(posedge dp_clk);
    while (!idle && t < 200000) begin @(posedge dp_clk); t++; end
    if (!idle) fail({what, ": idle never rose"});
    if (exp_q.size() != 0 && !allow_drop) fail($sformatf("%s: %0d frames never arrived", what, exp_q.size()));
  endtask

  task automatic do_clear();
    @(posedge dp_clk); clear <= 1; @(posedge dp_clk); clear <= 0;
    repeat (400) @(posedge dp_clk);
    seq_ctr = 0;
  endtask

  task automatic expect64(input [63:0] got, input longint unsigned exp, input string what);
    if (got !== exp) fail($sformatf("%s = %0d, expected %0d", what, got, exp));
  endtask

  longint unsigned sum_bytes;
  int n_bad, n_trunc, n_sent;

  // ---------------------------------------------------------------------------
  // Test sequence
  // ---------------------------------------------------------------------------
  initial begin
    $display("tb_pktrec_cap_port: start");
    repeat (20) @(posedge dp_clk);
    dp_rst <= 0;
    repeat (10) @(posedge rx_clk);
    rx_rst <= 0;
    repeat (200) @(posedge dp_clk);
    cap_en <= 1;
    repeat (50) @(posedge rx_clk);

    // ---- 1. random frames, random tready ----
    $display("test 1: random lengths, random tready");
    ready_pct = 60;
    sum_bytes = 0; n_bad = 0;
    for (int i = 0; i < 300; i++) begin
      int len = (i < 4) ? (i + 1) : (i % 7 == 0) ? 60 : $urandom_range(1, 1514);
      bit bad = ($urandom_range(0, 9) == 0);
      send(len, bad, 1);
      sum_bytes += len + 4;
      n_bad += bad;
    end
    wait_rx_done();
    wait_idle("test 1");
    expect64(st_frames_rx, 300, "test 1 FRAMES_RX");
    expect64(st_frames_bad, n_bad, "test 1 FRAMES_BAD");
    expect64(st_frames_drop, 0, "test 1 FRAMES_DROP");
    expect64(st_bytes_rx, sum_bytes, "test 1 BYTES_RX");
    expect64(st_records, 300, "test 1 RECORDS");
    expect64(st_seq_next, 300, "test 1 SEQ_NEXT");
    if (st_fifo_hwm == 0) fail("test 1: FIFO_HWM = 0");

    // ---- 2. snaplen ----
    for (int s = 0; s < 2; s++) begin
      int sl;
      sl = (s == 0) ? 64 : 61;
      $display("test 2: SNAPLEN %0d", sl);
      cap_en <= 0;
      repeat (50) @(posedge rx_clk);
      snaplen <= sl;
      cur_snap = sl;
      do_clear();
      cap_en <= 1;
      repeat (50) @(posedge rx_clk);
      n_trunc = 0;
      for (int i = 0; i < 80; i++) begin
        int len = $urandom_range(30, 1514);
        send(len, 0, 1);
        n_trunc += (len > sl);
      end
      wait_rx_done();
      wait_idle("test 2");
      expect64(st_frames_trunc, n_trunc, "test 2 FRAMES_TRUNC");
      expect64(st_records, 80, "test 2 RECORDS");
    end
    cap_en <= 0;
    repeat (50) @(posedge rx_clk);
    snaplen <= 0;
    cur_snap = 0;

    // ---- 3. overflow: whole-frame drops ----
    $display("test 3: back-pressure overflow");
    do_clear();
    cap_en <= 1;
    repeat (50) @(posedge rx_clk);
    ready_pct = 0;
    allow_drop = 1;
    n_skipped = 0; skipped_bytes = 0; n_records = 0;
    for (int i = 0; i < 40; i++) send(1514, 0, 1);
    wait_rx_done();
    repeat (100) @(posedge dp_clk);
    ready_pct = 100;
    wait_idle("test 3");
    // trailing drops: frames after the last surviving record
    foreach (exp_q[i]) begin
      n_skipped++;
      skipped_bytes += exp_q[i].data.size() + 4;
    end
    exp_q.delete();
    $display("  records %0d, dropped %0d", n_records, n_skipped);
    if (n_records < 9 || n_records > 12) fail($sformatf("test 3: %0d records survived (expected ~10)", n_records));
    expect64(st_frames_drop, n_skipped, "test 3 FRAMES_DROP");
    expect64(st_bytes_drop, skipped_bytes, "test 3 BYTES_DROP");
    expect64(st_frames_rx, 40, "test 3 FRAMES_RX");
    expect64(st_records + st_frames_drop, 40, "test 3 RECORDS + FRAMES_DROP");

    // 3b: slow sink -> drops in the middle of the stream (seq gaps)
    do_clear();
    ready_pct = 1;
    n_skipped = 0; skipped_bytes = 0; n_records = 0;
    for (int i = 0; i < 150; i++) send($urandom_range(600, 1514), 0, 1);
    wait_rx_done();
    ready_pct = 100;
    wait_idle("test 3b");
    foreach (exp_q[i]) begin
      n_skipped++;
      skipped_bytes += exp_q[i].data.size() + 4;
    end
    exp_q.delete();
    $display("  3b: records %0d, dropped %0d", n_records, n_skipped);
    if (n_skipped == 0 || n_records < 20) fail("test 3b: expected both drops and records");
    expect64(st_frames_drop, n_skipped, "test 3b FRAMES_DROP");
    expect64(st_bytes_drop, skipped_bytes, "test 3b BYTES_DROP");
    expect64(st_records, n_records, "test 3b RECORDS");
    allow_drop = 0;

    // ---- 4. cap_en gating ----
    $display("test 4: enable gating");
    ready_pct = 80;
    do_clear();
    cap_en <= 0;
    repeat (50) @(posedge rx_clk);
    for (int i = 0; i < 10; i++) send(200, 0, 0);
    wait_rx_done();
    repeat (500) @(posedge dp_clk);
    expect64(st_frames_rx, 0, "test 4 FRAMES_RX while disabled");
    expect64(st_seq_next, 0, "test 4 SEQ_NEXT while disabled");
    // a long frame starts while disabled; cap_en rises in the middle of it
    send(1500, 0, 0);
    @(posedge rx_clk); while (!rx_tvalid) @(posedge rx_clk);
    repeat (100) @(posedge rx_clk);
    cap_en <= 1;
    wait_rx_done();
    for (int i = 0; i < 5; i++) send(100, 0, 1);
    wait_rx_done();
    wait_idle("test 4");
    expect64(st_frames_rx, 5, "test 4 FRAMES_RX");
    expect64(st_records, 5, "test 4 RECORDS");

    // ---- 5. line rate, minimum frames ----
    $display("test 5: 64-byte frames at line rate");
    do_clear();
    ready_pct = 100;
    ifg = 6;
    for (int i = 0; i < 1000; i++) send(60, 0, 1);
    wait_rx_done();
    wait_idle("test 5");
    expect64(st_frames_drop, 0, "test 5 FRAMES_DROP");
    expect64(st_records, 1000, "test 5 RECORDS");
    ifg = 8;

    // ---- 6. clear ----
    do_clear();
    expect64(st_frames_rx, 0, "test 6 FRAMES_RX after clear");
    expect64(st_records, 0, "test 6 RECORDS after clear");
    expect64(st_seq_next, 0, "test 6 SEQ_NEXT after clear");

    if (cyc_ctr < 64'h1_0000_0000) fail("cycle counter never wrapped (test setup)");

    if (errors == 0) $display("tb_pktrec_cap_port: PASS");
    else $display("tb_pktrec_cap_port: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #50ms;
    $display("tb_pktrec_cap_port: FAIL (timeout)");
    $finish;
  end

endmodule
