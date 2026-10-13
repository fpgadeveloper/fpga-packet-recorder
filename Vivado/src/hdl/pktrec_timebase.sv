// SPDX-License-Identifier: MIT
//
// pktrec_timebase - the packet recorder's shared timebase (PHC-style) and its
// distribution into the Ethernet MAC clock domains.
//
// Master counter (clk = dp_clk):
//   {ns[63:0], frac[31:0]} += {inc_ns, inc_frac} every cycle: a 64-bit
//   nanosecond counter with a 32.32 ns increment. Reset increment =
//   round(1e9 / CLK_HZ) in 32.32 (4.0004 ns at 249.975 MHz); software trims it
//   to discipline the rate (adjfine), steps the time with set (settime) or adds
//   a signed offset with adj (adjtime). Both take effect on the next clk cycle.
//   Resolution: one clk period (~4 ns); the 32-bit fraction keeps the
//   long-term rate exact to 2^-32 ns per cycle.
//
// Distribution: a 32-bit CYCLE counter (cyc, +1 per clk) is carried into each
//   MAC clock domain (4 RX recovered clocks + 4 TX clocks, 62.5 MHz) Gray-coded
//   through xpm_cdc_gray (2 synchroniser stages + output register). The MAC
//   latches that count at the start of frame (rx_ptp_ts / tx_ptp_ts = {32'b0,
//   cyc}); the capture port converts it back to the timebase when it builds the
//   record header, in the clk domain where both counters are known exactly:
//       ts_ns = ns_now - (cyc_now - cyc_frame) * INC + MAC_OFFSET
//   (pktrec_cap_port). The copy in a MAC domain is (sync latency) older than
//   the master; that latency is constant (source Gray register + 2 sync stages
//   + output register: 12..14 clk cycles = 48..56 ns in simulation) and is
//   compensated by MAC_OFFSET (register, reset 52 ns). So a MAC timestamp has a
//   FIXED offset plus <= 2 clk periods (8 ns) of sampling jitter,
//   on top of the MAC's own 16 ns (one 62.5 MHz cycle) quantisation.
//   Valid as long as INC is not changed and SET/ADJ are not used while a
//   frame waits in the capture FIFOs (configure the timebase before a capture),
//   and for frames younger than 2^32 cycles (17 s).
//
//   Why not Taxi's taxi_ptp_clock_cdc (a digital PLL per domain, 48.16 time in
//   the destination clock)? It was tried first: with realistic frequency
//   offsets between the recovered RX clocks and dp_clk (125..250 ppm) its
//   output wandered by up to +-30 ns (rms ~9 ns) around the master in
//   simulation (only identical clocks tracked within 3 ns). The cycle-count
//   scheme is exact up to the constant latency and needs no lock time.
//
// dom_valid[2N-1:0] (clk domain): MAC domain out of reset ([N-1:0] RX, [2N-1:N] TX).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_timebase #(
    parameter longint CLK_HZ = 250000000,
    parameter int     N      = 4
)(
    input  wire logic          clk,
    input  wire logic          rst,

    input  wire logic          inc_load,
    input  wire logic [7:0]    inc_ns_in,
    input  wire logic [31:0]   inc_frac_in,
    input  wire logic          set,
    input  wire logic [63:0]   set_val,
    input  wire logic          adj,
    input  wire logic [63:0]   adj_val,

    output logic      [63:0]   ns,
    output logic      [31:0]   frac,
    output logic      [7:0]    inc_ns,
    output logic      [31:0]   inc_frac,
    output logic      [31:0]   cyc,
    output wire logic [2*N-1:0] dom_valid,

    input  wire logic [N-1:0]  rx_clk,
    input  wire logic [N-1:0]  rx_rst,
    output wire logic [N*32-1:0] rx_cyc,
    input  wire logic [N-1:0]  tx_clk,
    input  wire logic [N-1:0]  tx_rst,
    output wire logic [N*32-1:0] tx_cyc
);

localparam logic [63:0] INC_DEF = ((64'd1000000000 << 32) + 64'(CLK_HZ / 2)) / 64'(CLK_HZ);

logic [95:0] adj_plus_inc;
wire  [95:0] inc96 = {56'd0, inc_ns, inc_frac};

// adj uses adj_plus_inc from the PREVIOUS cycle's adj_val; the register block
// holds adj_val stable for many cycles before it pulses adj
always_ff @(posedge clk) begin
    adj_plus_inc <= {adj_val, 32'd0} + inc96;
    cyc <= cyc + 32'd1;
    if (set)
        {ns, frac} <= {set_val, 32'd0};
    else if (adj)
        {ns, frac} <= {ns, frac} + adj_plus_inc;
    else
        {ns, frac} <= {ns, frac} + inc96;
    if (inc_load) begin
        inc_ns   <= inc_ns_in;
        inc_frac <= inc_frac_in;
    end
    if (rst) begin
        ns       <= '0;
        frac     <= '0;
        cyc      <= '0;
        inc_ns   <= INC_DEF[39:32];
        inc_frac <= INC_DEF[31:0];
    end
end

wire [2*N-1:0]    dst_clk = {tx_clk, rx_clk};
wire [2*N-1:0]    dst_rst = {tx_rst, rx_rst};
wire [2*N*32-1:0] dst_cyc;

assign rx_cyc = dst_cyc[0 +: N*32];
assign tx_cyc = dst_cyc[N*32 +: N*32];

genvar g;
for (g = 0; g < 2*N; g = g + 1) begin : g_dist
    xpm_cdc_gray #(
        .DEST_SYNC_FF(2),
        .INIT_SYNC_FF(1),
        .REG_OUTPUT(1),
        .SIM_ASSERT_CHK(0),
        .SIM_LOSSLESS_GRAY_CHK(0),
        .WIDTH(32)
    ) cdc_cyc (
        .src_clk(clk),
        .src_in_bin(cyc),
        .dest_clk(dst_clk[g]),
        .dest_out_bin(dst_cyc[32*g +: 32])
    );
end

xpm_cdc_array_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(0),
                       .WIDTH(2*N))
cdc_valid (.src_clk(1'b0), .src_in(~dst_rst), .dest_clk(clk), .dest_out(dom_valid));

endmodule

`resetall
