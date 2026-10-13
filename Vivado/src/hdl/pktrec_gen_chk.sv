// SPDX-License-Identifier: MIT
//
// pktrec_gen_chk - per-port receive checker for pktrec_gen traffic, rx_clk
// domain (taps the MAC RX stream, no back-pressure).
//
// A frame is a generator frame when (FORMAT 0) EtherType 0x0800, IP protocol
// 17 and "PRSQ" at UDP payload offset 0 (sequence = u64 BE at byte 50), or
// (FORMAT 1) EtherType = ETYPE (sequence = u32 BE at byte 14). For each good
// generator frame (MAC bad flag clear):
//   first frame after ENABLE: LAST_SEQ := seq
//   seq == LAST_SEQ + 1       : in order
//   seq >  LAST_SEQ + 1       : LOST += seq - LAST_SEQ - 1
//   seq <= LAST_SEQ           : ERRORS++ (duplicate / reordered)
//   LAST_SEQ := max(LAST_SEQ, seq); FRAMES++
// Generator frames flagged bad by the MAC count in BAD only. One stream per
// port (the stream id is not compared). ENABLE 0 -> 1 clears the counters.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_gen_chk (
    input  wire logic         clk,
    input  wire logic         rst,
    input  wire logic         enable,
    input  wire logic         fmt_raw,
    input  wire logic [15:0]  etype,

    input  wire logic [15:0]  s_tdata,
    input  wire logic         s_tvalid,
    input  wire logic         s_tlast,
    input  wire logic         s_tbad,

    output logic      [31:0]  frames,
    output logic      [31:0]  lost,
    output logic      [31:0]  errors,
    output logic      [31:0]  bad,
    output logic      [63:0]  last_seq
);

logic        en_d = 1'b0;
logic [12:0] beat = '0;
logic        ok = 1'b0;          // all checked fields so far match
logic        have = 1'b0;        // LAST_SEQ valid
logic [63:0] seq = '0;
logic        long_enough = 1'b0; // the frame reached the sequence number
logic        eval_q = 1'b0, bad_q = 1'b0;

// bytes of this beat (wire order): b0 = tdata[7:0] = byte 2*beat
wire [15:0] be_word = {s_tdata[7:0], s_tdata[15:8]};   // big-endian value of bytes 2b, 2b+1

always_ff @(posedge clk) begin
    en_d <= enable;
    if (s_tvalid) begin
        beat <= s_tlast ? 13'd0 : beat + 13'd1;
        if (beat == 13'd0) ok <= 1'b1;
        if (beat == 13'd0) long_enough <= 1'b0;
        if (!fmt_raw) begin
            case (beat)
                13'd6:  if (be_word != 16'h0800) ok <= 1'b0;
                13'd11: if (s_tdata[15:8] != 8'd17) ok <= 1'b0;
                13'd21: if (be_word != 16'h5052) ok <= 1'b0;
                13'd22: if (be_word != 16'h5351) ok <= 1'b0;
                13'd25: seq[63:48] <= be_word;
                13'd26: seq[47:32] <= be_word;
                13'd27: seq[31:16] <= be_word;
                13'd28: begin seq[15:0] <= be_word; long_enough <= 1'b1; end
                default: ;
            endcase
        end else begin
            case (beat)
                13'd6: if (be_word != etype) ok <= 1'b0;
                13'd7: begin seq[63:32] <= '0; seq[31:16] <= be_word; end
                13'd8: begin seq[15:0] <= be_word; long_enough <= 1'b1; end
                default: ;
            endcase
        end
    end

    // evaluate one cycle after the last beat (seq/ok/long_enough updated)
    if (enable && eval_q && ok && long_enough) begin
        if (bad_q) begin
            bad <= bad + 32'd1;
        end else begin
            frames <= frames + 32'd1;
            if (!have) begin
                have <= 1'b1;
                last_seq <= seq;
            end else begin
                if (seq == last_seq + 64'd1) ;
                else if (seq > last_seq + 64'd1) lost <= lost + 32'(seq - last_seq - 64'd1);
                else errors <= errors + 32'd1;
                if (seq > last_seq) last_seq <= seq;
            end
        end
    end

    if ((enable && !en_d) || rst) begin
        frames <= '0; lost <= '0; errors <= '0; bad <= '0; last_seq <= '0; have <= 1'b0;
    end
    if (rst) beat <= '0;
end

// the last beat's checks land in ok/seq at the same edge; evaluate next cycle
always_ff @(posedge clk) begin
    eval_q <= 1'b0;
    if (s_tvalid && s_tlast) begin
        eval_q <= 1'b1;
        bad_q  <= s_tbad;
    end
end

endmodule

`resetall
