// SPDX-License-Identifier: MIT
//
// pktrec_sfd_edge - rising-edge timestamping of ONE oversampled SFD level
// (pktrec_sfd_io: 4 samples per dp_clk cycle, bit 0 oldest).
//
// The DP83867 drives its SFD GPIO high from the start of frame delimiter to
// the end of the frame (a level, not a pulse). An edge is the first sample
// that is 1 after a 0. Glitch filter (both limits in dp_clk cycles, from
// registers; 0 disables the check):
//   * MIN_LOW:  the level must have been low for at least MIN_LOW whole cycles
//               before the edge (reset 25 = 100 ns). Real frames are separated
//               by >= IFG + preamble + SFD = 160 ns of low level at 1 Gb/s, so
//               this rejects an edge closer than ~100 ns to the end of the
//               previous frame (and therefore to the previous edge), e.g. a
//               mid-frame dropout of the level.
//   * MIN_HIGH: the level must then stay high for MIN_HIGH further whole cycles
//               (reset 8 = 32 ns; a minimum frame keeps it high for 512 ns);
//               this rejects short spikes on an idle line.
// A rejected edge pulses 'glitch'. An accepted edge is reported (ev, one
// cycle) MIN_HIGH + 1 cycles after the edge cycle, with the time of the edge:
//   ev_cyc = timebase cycle count of the cycle whose sample word held the edge
//   ev_k   = index of the first high sample in that word (0..3)
//   ev_ns  = tb_ns(that cycle) + round(tb_frac) + ev_k - PIPE_NS
// i.e. the edge time in ns of the shared timebase, with the fixed sampler
// pipeline (PIPE_NS) removed. Resolution = the sample spacing (dp_clk/4 =
// ~1.0 ns with the ISERDES sampler; 2 ns with the IDDR fallback, where k is
// 0 or 2). The same instant in "cycle units", used to compare against MAC
// cycle stamps: t = 4 * ev_cyc + ev_k - PIPE_NS (ns, INC ~ 4.0).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_sfd_edge #(
    parameter int PIPE_NS = 16
)(
    input  wire logic         clk,
    input  wire logic         rst,
    input  wire logic [3:0]   s,          // samples of this cycle, bit 0 oldest
    input  wire logic [7:0]   min_low,
    input  wire logic [7:0]   min_high,
    input  wire logic [63:0]  tb_ns,
    input  wire logic         tb_half,    // tb_frac[31]: round to nearest ns
    input  wire logic [31:0]  tb_cyc,

    output logic              level,      // last sample
    output logic              ev,
    output logic      [63:0]  ev_ns,
    output logic      [31:0]  ev_cyc,
    output logic      [1:0]   ev_k,
    output logic              glitch
);

logic       prev = 1'b0;
logic [7:0] low_cnt = '0;     // whole cycles with all samples low (saturating)
logic       pend = 1'b0;
logic [7:0] hi_cnt = '0;
logic [63:0] e_ns = '0;
logic [31:0] e_cyc = '0;
logic [1:0]  e_k = '0;

// first rising sample in this word
wire [3:0] rise = s & ~{s[2:0], prev};
logic [1:0] k;
logic       has_rise;
always_comb begin
    has_rise = |rise;
    k = 2'd0;
    if (rise[0])      k = 2'd0;
    else if (rise[1]) k = 2'd1;
    else if (rise[2]) k = 2'd2;
    else              k = 2'd3;
end
// samples from the edge to the end of the word are all high
wire [3:0] tail_mask = 4'b1111 << k;
wire       tail_ok   = (s & tail_mask) == tail_mask;
wire       low_ok    = (low_cnt >= min_low);

always_ff @(posedge clk) begin
    ev     <= 1'b0;
    glitch <= 1'b0;
    prev   <= s[3];
    level  <= s[3];
    low_cnt <= (|s) ? 8'd0 : ((low_cnt == 8'hFF) ? 8'hFF : low_cnt + 8'd1);

    if (pend) begin
        if (&s) begin
            if (hi_cnt + 8'd1 >= min_high) begin
                pend   <= 1'b0;
                ev     <= 1'b1;
                ev_ns  <= e_ns;
                ev_cyc <= e_cyc;
                ev_k   <= e_k;
            end
            hi_cnt <= hi_cnt + 8'd1;
        end else begin
            pend   <= 1'b0;
            glitch <= 1'b1;
        end
    end else if (has_rise) begin
        if (low_ok && tail_ok) begin
            e_ns  <= tb_ns + 64'(tb_half) + 64'(k) - 64'(PIPE_NS);
            e_cyc <= tb_cyc;
            e_k   <= k;
            if (min_high == 8'd0) begin
                ev     <= 1'b1;
                ev_ns  <= tb_ns + 64'(tb_half) + 64'(k) - 64'(PIPE_NS);
                ev_cyc <= tb_cyc;
                ev_k   <= k;
            end else begin
                pend   <= 1'b1;
                hi_cnt <= 8'd0;
            end
        end else begin
            glitch <= 1'b1;
        end
    end

    if (rst) begin
        pend    <= 1'b0;
        ev      <= 1'b0;
        glitch  <= 1'b0;
        low_cnt <= '0;
        prev    <= 1'b1;
    end
end

endmodule

`resetall
