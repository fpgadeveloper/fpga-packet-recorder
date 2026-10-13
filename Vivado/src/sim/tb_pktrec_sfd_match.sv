// Opsero Electronic Design Inc. Copyright 2026
//
// SPDX-License-Identifier: MIT
//
// tb_pktrec_sfd_match -- self-checking testbench for the RX SFD-to-frame
// matching in pktrec_cap_port (M2).
//
// Same MAC RX model / record parser as tb_pktrec_cap_port (timebase model:
// tb_ns = BASE + 4 * cyc, INC = 4.0), plus an SFD source that pushes {k, cyc}
// entries into the port's SFD queue (dp_clk) shortly before each frame, as
// pktrec_sfd does. For an entry with cycle c and sample k the matcher's delta
// is d = 4 * (cyc_mac - c) - k + PIPE; a matched record's timestamp must be
// exactly BASE + 4 * c + k - PIPE + RX_OFFSET with flags TS_MAC = 0; a
// fallback record BASE + 4 * cyc_mac + MAC_OFFSET with TS_MAC = 1; bit3
// (SFD_RESYNC) set iff stale entries were discarded for that frame.
//
// Tests:
//   1. normal: every frame has its SFD (random d in the window, random k,
//      random lead time incl. 0 = the entry arrives after the first beat)
//   2. missing pulses: no entry for some frames -> those fall back (TS_MAC,
//      MISMATCH), the following frames still match (no shift)
//   3. extra pulses: 1..3 stale entries before a frame's own -> discarded
//      (STALE, bit3 on that frame), the frame still matches
//   4. entry too young (d < WIN_MIN) -> kept, frame falls back; the next frame
//      discards it as stale (bit3) and matches its own entry
//   5. entry too old (d > WIN_MAX) -> stale, frame falls back with bit3
//   6. FIFO drops (sink stalled): dropped frames consume their entries, every
//      surviving record has its own SFD timestamp
//   7. frames received while the port is disabled consume their entries
//   8. MATCH_EN = 0: every record TS_MAC = 1, nothing counted, queue flushed
//   9. queue overflow (sfd_full) is reported; 1-beat runt never matches
// Counters MATCHED / STALE / MISMATCH and DELTA min / max / last checked exactly.
//
// Prints PASS / FAIL and calls $finish (sim.tcl contract).

`timescale 1ns / 1ps

module tb_pktrec_sfd_match;

  localparam int PORT = 1;
  localparam int FIFO_BYTES = 16384;
  localparam int PIPE = 16;
  localparam longint unsigned BASE = 64'h1876_5432_1000_0000;
  localparam longint unsigned CYC0 = 64'h1_0000_0000 - 64'd300_000;
  localparam int MAC_OFFSET = 52;
  localparam int RX_OFFSET = -7;
  localparam int WIN_MIN = 100, WIN_MAX = 700;

  int errors = 0;
  task automatic fail(input string msg);
    errors++;
    if (errors < 30) $display("FAIL: %s (t=%0t)", msg, $time);
  endtask

  reg rx_clk = 0, dp_clk = 0;
  always #8.0012 rx_clk = ~rx_clk;
  always #2.0 dp_clk = ~dp_clk;
  reg rx_rst = 1, dp_rst = 1;

  longint unsigned cyc_ctr = CYC0;
  reg [63:0] tb_ns = 0;
  reg [31:0] tb_cyc = 0;
  always @(posedge dp_clk) begin
    cyc_ctr <= cyc_ctr + 1;
    tb_cyc  <= cyc_ctr[31:0];
    tb_ns   <= BASE + 4 * cyc_ctr;
  end

  reg  [15:0] rx_tdata = 0;
  reg  [1:0]  rx_tkeep = 0;
  reg         rx_tvalid = 0, rx_tlast = 0, rx_tbad = 0;
  reg  [31:0] rx_ts = 0;
  reg         cap_en = 0;
  reg         clear = 0;
  wire [127:0] m_tdata;
  wire        m_tvalid, m_tlast;
  reg         m_tready = 0;
  wire [63:0] st_frames_rx, st_frames_bad, st_frames_drop, st_bytes_rx, st_bytes_drop,
              st_frames_trunc, st_records;
  wire [15:0] st_seq_next;
  wire        st_rx_active, idle, len_fixup;
  wire [31:0] st_fifo_hwm;
  reg         sfd_wr = 0;
  reg  [33:0] sfd_din = 0;
  wire        sfd_full;
  reg         sfd_match_en = 1;
  reg         sfd_clear = 0;
  wire [63:0] st_matched;
  wire [31:0] st_stale, st_mismatch, st_dlast, st_dmin, st_dmax, st_dhead;

  pktrec_cap_port #(.PORT(PORT), .FIFO_BYTES(FIFO_BYTES), .SFD_PIPE_NS(PIPE)) dut (
    .rx_clk(rx_clk), .rx_rst(rx_rst),
    .rx_tdata(rx_tdata), .rx_tkeep(rx_tkeep), .rx_tvalid(rx_tvalid), .rx_tlast(rx_tlast),
    .rx_tbad(rx_tbad), .rx_ts_cyc(rx_ts),
    .dp_clk(dp_clk), .dp_rst(dp_rst),
    .cap_en(cap_en), .snaplen(16'd0), .clear(clear), .tb_ns(tb_ns),
    .tb_cyc(tb_cyc), .tb_inc(40'h4_0000_0000), .mac_offset(MAC_OFFSET),
    .m_tdata(m_tdata), .m_tvalid(m_tvalid), .m_tready(m_tready), .m_tlast(m_tlast),
    .st_frames_rx(st_frames_rx), .st_frames_bad(st_frames_bad), .st_frames_drop(st_frames_drop),
    .st_bytes_rx(st_bytes_rx), .st_bytes_drop(st_bytes_drop), .st_frames_trunc(st_frames_trunc),
    .st_seq_next(st_seq_next), .st_rx_active(st_rx_active), .st_records(st_records),
    .st_fifo_hwm(st_fifo_hwm), .hwm_clr(1'b0), .idle(idle), .len_fixup(len_fixup),
    .sfd_wr(sfd_wr), .sfd_din(sfd_din), .sfd_full(sfd_full), .sfd_match_en(sfd_match_en),
    .sfd_win_min(WIN_MIN), .sfd_win_max(WIN_MAX), .sfd_offset(RX_OFFSET), .sfd_clear(sfd_clear),
    .st_sfd_matched(st_matched), .st_sfd_stale(st_stale), .st_sfd_mismatch(st_mismatch),
    .st_sfd_dlast(st_dlast), .st_sfd_dmin(st_dmin), .st_sfd_dmax(st_dmax), .st_sfd_dhead(st_dhead)
  );

  // ---------------------------------------------------------------------------
  // scoreboard
  // ---------------------------------------------------------------------------
  // SFD plan of a frame
  typedef enum { S_NORMAL, S_NONE, S_YOUNG, S_OLD } sfd_kind_t;

  class Frame;
    byte unsigned data[$];
    longint unsigned cyc;      // MAC cycle stamp
    sfd_kind_t kind;
    int n_extra;               // stale entries injected before the frame's own
    int lead;                  // rx cycles between the entry push and the first beat
    bit captured;
    int seq;
    // filled by the MAC model
    bit exp_match, exp_resync;
    longint unsigned exp_ts;
    int d;
  endclass

  Frame tx_q[$];
  Frame exp_q[$];
  int   seq_ctr = 0;
  bit   allow_drop = 0;
  int   n_records = 0, n_skipped = 0, n_sfd_records = 0;
  int   ifg = 8;
  bit   rx_busy = 0;
  bit   resync_pending = 0;   // a stale entry is queued: the next frame that is evaluated discards it
  // expected counters (model)
  longint unsigned m_matched = 0;
  int m_stale = 0, m_mismatch = 0;
  int m_dmin = 32'h7FFF_FFFF, m_dmax = 32'h8000_0000, m_dlast = 32'h8000_0000;
  int pending_stale = 0;      // entries that will be found stale by the next evaluated frame

  // entries to push (dp_clk process)
  logic [33:0] push_q[$];
  always @(posedge dp_clk) begin
    sfd_wr <= 1'b0;
    if (push_q.size() > 0 && !sfd_full) begin
      sfd_wr  <= 1'b1;
      sfd_din <= push_q.pop_front();
    end
  end

  task automatic send(input int len, input sfd_kind_t kind, input int n_extra, input bit captured);
    Frame f = new();
    for (int i = 0; i < len; i++) f.data.push_back($urandom_range(0, 255));
    f.kind = kind;
    f.n_extra = n_extra;
    f.lead = ($urandom_range(0, 4) == 0) ? 0 : $urandom_range(3, 12);
    f.captured = captured;
    f.seq = captured ? seq_ctr : -1;
    if (captured) begin
      seq_ctr = (seq_ctr + 1) & 16'hFFFF;
      exp_q.push_back(f);
    end
    tx_q.push_back(f);
  endtask

  // RX MAC model + SFD source
  initial begin
    Frame f;
    int nb, q, k;
    longint unsigned c;
    forever begin
      @(posedge rx_clk);
      if (tx_q.size() == 0 || rx_rst) begin rx_busy = 0; continue; end
      rx_busy = 1;
      f = tx_q.pop_front();
      nb = (f.data.size() + 1) / 2;
      f.cyc = cyc_ctr - $urandom_range(0, 20);
      // stale extras (d >= 2000 ns)
      for (int j = 0; j < f.n_extra; j++)
        push_q.push_back({2'($urandom_range(0, 3)), 32'(f.cyc - 500 - 100 * j)});
      f.exp_resync = (f.n_extra > 0) || (pending_stale > 0) || (f.kind == S_OLD);
      if (sfd_match_en) begin
        m_stale += f.n_extra + pending_stale;
        pending_stale = 0;
      end
      k = $urandom_range(0, 3);
      case (f.kind)
        S_NORMAL: q = $urandom_range((WIN_MIN + 3 - PIPE) / 4 + 1, (WIN_MAX - PIPE) / 4 - 1);
        S_YOUNG:  q = -10;                       // d = -40 - k + PIPE < WIN_MIN
        S_OLD:    q = (WIN_MAX - PIPE) / 4 + 5;  // d > WIN_MAX
        default:  q = 0;
      endcase
      c = f.cyc - q;
      f.d = 4 * q - k + PIPE;
      if (f.kind != S_NONE) push_q.push_back({2'(k), 32'(c)});
      f.exp_match = sfd_match_en && (f.kind == S_NORMAL) && (nb > 1);
      if (!sfd_match_en) f.exp_resync = 0;
      if (f.kind == S_OLD && sfd_match_en) m_stale++;
      if (f.kind == S_YOUNG && sfd_match_en) pending_stale++;   // the next frame finds it stale
      if (f.kind == S_NORMAL && sfd_match_en && nb <= 1) pending_stale++;   // runt: never evaluated
      if (f.exp_match) begin
        m_matched++;
        m_dlast = f.d;
        if (f.d < m_dmin) m_dmin = f.d;
        if (f.d > m_dmax) m_dmax = f.d;
        begin
          longint e;
          e = longint'(BASE) + longint'(c << 2);
          e = e + k;
          e = e - PIPE;
          e = e + RX_OFFSET;
          f.exp_ts = e;
        end
      end else begin
        if (sfd_match_en) m_mismatch++;
        f.exp_ts = BASE + 4 * f.cyc + MAC_OFFSET;
      end
      repeat (f.lead) @(posedge rx_clk);
      for (int b = 0; b < nb; b++) begin
        rx_tdata  <= {(2*b+1 < f.data.size()) ? f.data[2*b+1] : 8'hXX, f.data[2*b]};
        rx_tkeep  <= (2*b+1 < f.data.size()) ? 2'b11 : 2'b01;
        rx_tvalid <= 1'b1;
        rx_tlast  <= (b == nb - 1);
        rx_tbad   <= 1'b0;
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
    int beat_i, nbeats, cap, seq, flags;
    longint unsigned ts;
    forever begin
      @(posedge dp_clk);
      if (!(m_tvalid && m_tready)) continue;
      if (!in_rec) begin
        ts    = m_tdata[63:0];
        cap   = m_tdata[79:64];
        flags = m_tdata[111:104];
        seq   = m_tdata[127:112];
        n_records++;
        f = null;
        while (exp_q.size() > 0) begin
          f = exp_q.pop_front();
          if (f.seq == seq) break;
          if (!allow_drop) fail($sformatf("record seq %0d, expected seq %0d (frame lost)", seq, f.seq));
          n_skipped++;
          f = null;
        end
        if (f == null) begin
          fail($sformatf("record seq %0d not in the scoreboard", seq));
        end else begin
          int exp_flags = 8'hA0 | (f.exp_match ? 0 : 4) | (f.exp_resync ? 8 : 0);
          if (flags != exp_flags)
            fail($sformatf("seq %0d (%s, d %0d): flags 0x%02x, expected 0x%02x", seq, f.kind.name(), f.d, flags, exp_flags));
          if (ts !== f.exp_ts)
            fail($sformatf("seq %0d (%s): ts 0x%016x, expected 0x%016x (diff %0d)", seq, f.kind.name(), ts, f.exp_ts,
                           longint'(ts - f.exp_ts)));
          if (f.exp_match) n_sfd_records++;
          if (cap != f.data.size()) fail($sformatf("seq %0d: cap_len %0d", seq, cap));
        end
        nbeats = (cap + 15) / 16;
        beat_i = 0;
        in_rec = (nbeats > 0);
      end else begin
        beat_i++;
        if (m_tlast) in_rec = 0;
      end
    end
  end

  int ready_pct = 100;
  always @(posedge dp_clk) m_tready <= ($urandom_range(1, 100) <= ready_pct);
  always @(posedge dp_clk) if (len_fixup) fail("len_fixup pulse");

  task automatic wait_rx_done();
    while (tx_q.size() > 0 || rx_busy) @(posedge rx_clk);
    repeat (20) @(posedge rx_clk);
  endtask

  task automatic wait_idle(input string what);
    int t = 0;
    repeat (400) @(posedge dp_clk);
    while (!idle && t < 200000) begin @(posedge dp_clk); t++; end
    if (!idle) fail({what, ": idle never rose"});
    if (exp_q.size() != 0 && !allow_drop) fail($sformatf("%s: %0d frames never arrived", what, exp_q.size()));
    repeat (400) @(posedge dp_clk);     // snapshot refresh
  endtask

  task automatic check_counters(input string what);
    if (st_matched !== m_matched) fail($sformatf("%s: MATCHED %0d, expected %0d", what, st_matched, m_matched));
    if (st_stale !== m_stale) fail($sformatf("%s: STALE %0d, expected %0d", what, st_stale, m_stale));
    if (st_mismatch !== m_mismatch) fail($sformatf("%s: MISMATCH %0d, expected %0d", what, st_mismatch, m_mismatch));
    if (st_dmin !== m_dmin) fail($sformatf("%s: DELTA_MIN %0d, expected %0d", what, $signed(st_dmin), m_dmin));
    if (st_dmax !== m_dmax) fail($sformatf("%s: DELTA_MAX %0d, expected %0d", what, $signed(st_dmax), m_dmax));
    if (st_dlast !== m_dlast) fail($sformatf("%s: DELTA_LAST %0d, expected %0d", what, $signed(st_dlast), m_dlast));
    $display("  %s: matched %0d stale %0d mismatch %0d delta %0d..%0d last %0d head %0d", what,
             st_matched, st_stale, st_mismatch, $signed(st_dmin), $signed(st_dmax), $signed(st_dlast),
             $signed(st_dhead));
  endtask

  initial begin
    $display("tb_pktrec_sfd_match: start");
    repeat (20) @(posedge dp_clk);
    dp_rst <= 0;
    repeat (10) @(posedge rx_clk);
    rx_rst <= 0;
    repeat (300) @(posedge dp_clk);
    cap_en <= 1;
    repeat (50) @(posedge rx_clk);
    ready_pct = 70;

    $display("test 1: normal");
    for (int i = 0; i < 200; i++) send($urandom_range(60, 600), S_NORMAL, 0, 1);
    wait_rx_done(); wait_idle("test 1"); check_counters("test 1");
    if (n_sfd_records != 200) fail($sformatf("test 1: %0d SFD records", n_sfd_records));

    $display("test 2: missing pulses");
    for (int i = 0; i < 100; i++) send($urandom_range(60, 300), (i % 7 == 3 || i % 11 == 5) ? S_NONE : S_NORMAL, 0, 1);
    wait_rx_done(); wait_idle("test 2"); check_counters("test 2");

    $display("test 3: extra pulses");
    for (int i = 0; i < 100; i++) send($urandom_range(60, 300), S_NORMAL, (i % 5 == 2) ? $urandom_range(1, 3) : 0, 1);
    wait_rx_done(); wait_idle("test 3"); check_counters("test 3");

    $display("test 4/5: entry too young / too old");
    ifg = 200;    // the young entry must be > WIN_MAX old for the next frame
    for (int i = 0; i < 60; i++) send(100, (i % 6 == 1) ? S_YOUNG : (i % 6 == 4) ? S_OLD : S_NORMAL, 0, 1);
    wait_rx_done(); wait_idle("test 4/5"); check_counters("test 4/5");
    ifg = 8;

    $display("test 6: FIFO drops consume their entries");
    ready_pct = 1;
    allow_drop = 1;
    n_skipped = 0;
    for (int i = 0; i < 120; i++) send($urandom_range(800, 1514), S_NORMAL, 0, 1);
    wait_rx_done();
    ready_pct = 100;
    wait_idle("test 6");
    n_skipped += exp_q.size();
    exp_q.delete();
    allow_drop = 0;
    $display("  test 6: %0d frames dropped", n_skipped);
    if (n_skipped == 0) fail("test 6: no drops");
    check_counters("test 6");

    $display("test 7: disabled port consumes entries");
    cap_en <= 0;
    repeat (50) @(posedge rx_clk);
    for (int i = 0; i < 20; i++) send(200, S_NORMAL, 0, 0);
    wait_rx_done();
    cap_en <= 1;
    repeat (50) @(posedge rx_clk);
    for (int i = 0; i < 20; i++) send(200, S_NORMAL, 0, 1);
    wait_rx_done(); wait_idle("test 7"); check_counters("test 7");

    $display("test 8: MATCH_EN = 0");
    sfd_match_en <= 0;
    repeat (50) @(posedge rx_clk);
    for (int i = 0; i < 30; i++) send(100, S_NORMAL, (i == 3) ? 2 : 0, 1);
    wait_rx_done(); wait_idle("test 8"); check_counters("test 8");
    sfd_match_en <= 1;
    repeat (50) @(posedge rx_clk);
    for (int i = 0; i < 10; i++) send(100, S_NORMAL, 0, 1);
    wait_rx_done(); wait_idle("test 8b"); check_counters("test 8b");

    $display("test 9: 1-beat runt, SFD queue overflow");
    ifg = 200;
    send(2, S_NORMAL, 0, 1);       // single beat: never matched; its entry goes stale
    send(100, S_NORMAL, 0, 1);
    wait_rx_done(); wait_idle("test 9a"); check_counters("test 9a");
    ifg = 8;
    // overflow: 40 entries without frames
    begin
      for (int j = 0; j < 40; j++) push_q.push_back({2'd0, 32'(cyc_ctr - 10000)});
      repeat (200) @(posedge dp_clk);
      if (!sfd_full) fail("test 9: sfd_full never seen with 40 queued entries");
      push_q.delete();
    end
    // the next frame flushes all 16 (+1 in flight) stale entries; count via STALE delta
    begin
      longint unsigned st0 = st_stale;
      pending_stale = 1;            // the frame discards the queued entries (bit3)
      send(400, S_NORMAL, 0, 1);
      wait_rx_done(); wait_idle("test 9b");
      $display("  test 9b: %0d stale entries flushed by one frame", st_stale - st0);
      if (st_stale - st0 < 16) fail("test 9b: fewer than 16 stale entries flushed");
      m_stale = st_stale;
    end

    if (errors == 0) $display("tb_pktrec_sfd_match: PASS");
    else $display("tb_pktrec_sfd_match: FAIL (%0d errors)", errors);
    $finish;
  end

  initial begin
    #80ms;
    $display("tb_pktrec_sfd_match: FAIL (timeout)");
    $finish;
  end

endmodule
