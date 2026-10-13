// SPDX-License-Identifier: MIT
//
// pktrec_gen - per-port hardware traffic generator (path mode 3 "gen" of
// pktrec_m0_path), tx_clk domain (62.5 MHz, 16-bit beats to the Taxi TX MAC).
//
// Frames (length LEN bytes WITHOUT the FCS, which the MAC appends; 60..16383):
//   FORMAT 0 "PRSQ" -- byte-identical to test/gen_seq.py, so test/check_pcap.py
//     verifies generator traffic unchanged:
//       dst MAC | src MAC | 0x0800 | IPv4 (20 B: 0x45, tot_len = LEN - 14,
//       id 0, DF, TTL 64, UDP, header checksum, 192.0.2.1 -> 192.0.2.2) |
//       UDP 50000 -> 50001, len = LEN - 34, checksum 0 |
//       "PRSQ" | stream id (u32 BE) | sequence number (u64 BE) | zero fill
//   FORMAT 1 "raw" -- dst MAC | src MAC | ETYPE (default 0x88B5, IEEE local
//       experimental) | sequence number (u32 BE, payload offset 0) | zero fill
// The sequence number starts at SEQ_FIRST on every start and increments per
// frame. RAND_LEN: LEN + (16-bit LFSR & LEN_MASK) per frame (clamped to 16383).
//
// Rate: a frame may start at most every ceil((LEN + 4 FCS + 8 preamble + IFG)
// / 2) tx_clk cycles after the previous start (IFG in bytes; 12 = line rate,
// where the MAC's own IFG/preamble back-pressure sets the pace anyway).
// COUNT frames (0 = until stopped). ENABLE 0 -> 1 starts (and reloads SEQ_FIRST
// / COUNT), ENABLE = 0 stops after the frame in progress. A frame is never cut
// (tvalid stays high from the first to the last beat). 'allow' = the port's
// path mode is gen; while it is 0 no new frame starts.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_gen (
    input  wire logic         clk,
    input  wire logic         rst,

    input  wire logic         enable,
    input  wire logic         allow,
    input  wire logic         fmt_raw,
    input  wire logic         rand_len,
    input  wire logic [13:0]  len,
    input  wire logic [13:0]  len_mask,
    input  wire logic [15:0]  ifg,
    input  wire logic [31:0]  count,
    input  wire logic [47:0]  dst,
    input  wire logic [47:0]  src,
    input  wire logic [15:0]  etype,
    input  wire logic [31:0]  stream,
    input  wire logic [31:0]  seq_first,

    output logic      [15:0]  m_tdata,
    output logic      [1:0]   m_tkeep,
    output logic              m_tvalid,
    input  wire logic         m_tready,
    output logic              m_tlast,

    output logic              running,
    output logic              done,
    output logic      [63:0]  frames,
    output logic      [63:0]  bytes
);

localparam logic [31:0] IP_SRC = 32'hC000_0201;   // 192.0.2.1
localparam logic [31:0] IP_DST = 32'hC000_0202;   // 192.0.2.2
localparam logic [15:0] SPORT  = 16'd50000;
localparam logic [15:0] DPORT  = 16'd50001;
// IPv4 header checksum: sum of the constant words (tot_len and checksum excluded)
localparam logic [19:0] CSUM_C = 20'h4500 + 20'h0000 + 20'h4000 + 20'h4011 +
                                 20'(IP_SRC[31:16]) + 20'(IP_SRC[15:0]) +
                                 20'(IP_DST[31:16]) + 20'(IP_DST[15:0]);

logic        en_d = 1'b0;
logic [15:0] lfsr = 16'hACE1;
logic [13:0] nlen = 14'd60;          // length of the next frame
logic [15:0] ncsum = '0;             // its IPv4 checksum
logic [1:0]  prep = '0;              // cycles until nlen/ncsum are valid

logic        in_frame = 1'b0;
logic [12:0] beat = '0;
logic [12:0] nbeats = '0;
logic [13:0] clen = '0;
logic [15:0] ccsum = '0;
logic [63:0] seq = '0;
logic [31:0] left = '0;
logic [16:0] wait_cnt = '0;

// next length (clamped)
wire [14:0] len_r   = 15'(len) + (rand_len ? 15'(lfsr[13:0] & len_mask) : 15'd0);
wire [13:0] len_c0  = (len_r > 15'd16383) ? 14'd16383 : len_r[13:0];
wire [13:0] len_c   = (len_c0 < 14'd60) ? 14'd60 : len_c0;
wire [15:0] tot_len = 16'(nlen) - 16'd14;
wire [19:0] cs1     = CSUM_C + 20'(tot_len);
wire [16:0] cs2     = 17'(cs1[15:0]) + 17'(cs1[19:16]);
wire [15:0] cs3     = cs2[15:0] + 16'(cs2[16]);

// ---- frame bytes ----
wire [15:0] c_tot  = 16'(clen) - 16'd14;
wire [15:0] c_udp  = 16'(clen) - 16'd34;
function automatic [15:0] be(input [15:0] v);   // big-endian on the wire: {2nd byte, 1st byte}
    return {v[7:0], v[15:8]};
endfunction
logic [15:0] word;
always_comb begin
    word = 16'h0000;
    case (beat)
        13'd0: word = be(dst[47:32]);
        13'd1: word = be(dst[31:16]);
        13'd2: word = be(dst[15:0]);
        13'd3: word = be(src[47:32]);
        13'd4: word = be(src[31:16]);
        13'd5: word = be(src[15:0]);
        13'd6: word = be(fmt_raw ? etype : 16'h0800);
        default: ;
    endcase
    if (fmt_raw) begin
        case (beat)
            13'd7: word = be(seq[31:16]);
            13'd8: word = be(seq[15:0]);
            default: ;
        endcase
    end else begin
        case (beat)
            13'd7:  word = be(16'h4500);
            13'd8:  word = be(c_tot);
            13'd9:  word = be(16'h0000);
            13'd10: word = be(16'h4000);
            13'd11: word = be(16'h4011);
            13'd12: word = be(ccsum);
            13'd13: word = be(IP_SRC[31:16]);
            13'd14: word = be(IP_SRC[15:0]);
            13'd15: word = be(IP_DST[31:16]);
            13'd16: word = be(IP_DST[15:0]);
            13'd17: word = be(SPORT);
            13'd18: word = be(DPORT);
            13'd19: word = be(c_udp);
            13'd20: word = be(16'h0000);
            13'd21: word = be(16'h5052);          // "PR"
            13'd22: word = be(16'h5351);          // "SQ"
            13'd23: word = be(stream[31:16]);
            13'd24: word = be(stream[15:0]);
            13'd25: word = be(seq[63:48]);
            13'd26: word = be(seq[47:32]);
            13'd27: word = be(seq[31:16]);
            13'd28: word = be(seq[15:0]);
            default: ;
        endcase
    end
end

wire last_beat = (beat == nbeats - 13'd1);
assign m_tdata  = word;
assign m_tvalid = in_frame;
assign m_tlast  = in_frame && last_beat;
assign m_tkeep  = (last_beat && clen[0]) ? 2'b01 : 2'b11;

wire more    = (count == 32'd0) || (left != 32'd0);
wire start   = running && allow && !in_frame && wait_cnt == 17'd0 && prep == 2'd0 && more && enable;

always_ff @(posedge clk) begin
    en_d <= enable;
    if (wait_cnt != 17'd0) wait_cnt <= wait_cnt - 17'd1;
    if (prep != 2'd0) prep <= prep - 2'd1;

    // next-frame length + checksum pipeline
    if (prep == 2'd2) nlen <= len_c;
    if (prep == 2'd1) ncsum <= ~cs3;

    if (enable && !en_d) begin
        running <= 1'b1;
        done    <= 1'b0;
        seq     <= 64'(seq_first);
        left    <= count;
        prep    <= 2'd3;
    end else if (running && !in_frame && (!enable || !more)) begin
        running <= 1'b0;
        done    <= !more;
    end

    if (start) begin
        in_frame <= 1'b1;
        beat     <= '0;
        clen     <= nlen;
        ccsum    <= ncsum;
        nbeats   <= 13'((15'(nlen) + 15'd1) >> 1);
        wait_cnt <= 17'((18'(nlen) + 18'd12 + 18'(ifg) + 18'd1) >> 1) - 17'd1;
        lfsr     <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        prep     <= 2'd2;
    end else if (in_frame && m_tready) begin
        beat <= beat + 13'd1;
        if (last_beat) begin
            in_frame <= 1'b0;
            frames   <= frames + 64'd1;
            bytes    <= bytes + 64'(clen) + 64'd4;
            seq      <= seq + 64'd1;
            if (left != 32'd0) left <= left - 32'd1;
        end
    end

    if (enable && !en_d && !running) begin
        frames <= '0;
        bytes  <= '0;
    end

    if (rst) begin
        in_frame <= 1'b0;
        running  <= 1'b0;
        done     <= 1'b0;
        frames   <= '0;
        bytes    <= '0;
        wait_cnt <= '0;
        prep     <= '0;
        en_d     <= 1'b1;      // no start straight out of reset with ENABLE already 1
    end
end

endmodule

`resetall
