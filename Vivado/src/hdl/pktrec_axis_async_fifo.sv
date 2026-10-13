// SPDX-License-Identifier: MIT
//
// pktrec_axis_async_fifo - plain-port wrapper around Taxi's taxi_axis_async_fifo
// (CERN-OHL-S-2.0, used unmodified from submodules/taxi) so that Verilog-2001
// modules (block-design module references) can instantiate it.
//
// Fixed configuration for the Ethernet MAC streams of the packet recorder:
//   16-bit tdata, 2-bit tkeep, tlast, 1-bit tuser (bad-frame marker at tlast)
//   frame FIFO (store-and-forward: the output never drops tvalid inside a frame,
//   which the Taxi TX MAC requires), frames dropped WHOLE when the FIFO is full
//   (s_tready is always 1, as the MAC RX stream has no back-pressure) and frames
//   longer than the FIFO dropped. Bad frames are NOT dropped: tuser travels with
//   the frame so the TX MAC re-sends it with an error.
//
// DEPTH is in bytes (Taxi counts tkeep units); 4096 = 2048 x 16-bit beats.
//
// Status strobes (one s_clk cycle per frame): s_drop (frame dropped: FIFO full or
// oversize), s_good (frame committed). m_depth (m_clk): current fill in bytes as seen
// by the read side (Taxi m_status_depth: everything written and not yet read,
// including the frame still being received), used by the M3 dynamic inter-frame gap.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_axis_async_fifo #(
    parameter int DEPTH = 4096,
    parameter int RAM_PIPELINE = 2
)(
    input  wire logic        s_clk,
    input  wire logic        s_rst,
    input  wire logic [15:0] s_tdata,
    input  wire logic [1:0]  s_tkeep,
    input  wire logic        s_tvalid,
    output wire logic        s_tready,
    input  wire logic        s_tlast,
    input  wire logic        s_tuser,

    input  wire logic        m_clk,
    input  wire logic        m_rst,
    output wire logic [15:0] m_tdata,
    output wire logic [1:0]  m_tkeep,
    output wire logic        m_tvalid,
    input  wire logic        m_tready,
    output wire logic        m_tlast,
    output wire logic        m_tuser,

    output wire logic        s_drop,
    output wire logic        s_good,
    output wire logic [$clog2(DEPTH):0] m_depth
);

taxi_axis_if #(.DATA_W(16), .KEEP_W(2), .USER_EN(1), .USER_W(1)) s_axis(), m_axis();

assign s_axis.tdata  = s_tdata;
assign s_axis.tkeep  = s_tkeep;
assign s_axis.tstrb  = s_tkeep;
assign s_axis.tvalid = s_tvalid;
assign s_axis.tlast  = s_tlast;
assign s_axis.tuser  = s_tuser;
assign s_axis.tid    = '0;
assign s_axis.tdest  = '0;
assign s_tready      = s_axis.tready;

assign m_tdata  = m_axis.tdata;
assign m_tkeep  = m_axis.tkeep;
assign m_tvalid = m_axis.tvalid;
assign m_tlast  = m_axis.tlast;
assign m_tuser  = m_axis.tuser;
assign m_axis.tready = m_tready;

taxi_axis_async_fifo #(
    .DEPTH(DEPTH),
    .RAM_PIPELINE(RAM_PIPELINE),
    .FRAME_FIFO(1'b1),
    .USER_BAD_FRAME_VALUE(1'b1),
    .USER_BAD_FRAME_MASK(1'b1),
    .DROP_OVERSIZE_FRAME(1'b1),
    .DROP_BAD_FRAME(1'b0),
    .DROP_WHEN_FULL(1'b1)
) fifo_inst (
    .s_clk(s_clk),
    .s_rst(s_rst),
    .s_axis(s_axis),
    .m_clk(m_clk),
    .m_rst(m_rst),
    .m_axis(m_axis),
    .s_pause_req(1'b0),
    .s_pause_ack(),
    .m_pause_req(1'b0),
    .m_pause_ack(),
    .s_status_depth(),
    .s_status_depth_commit(),
    .s_status_overflow(s_drop),
    .s_status_bad_frame(),
    .s_status_good_frame(s_good),
    .m_status_depth(m_depth),
    .m_status_depth_commit(),
    .m_status_overflow(),
    .m_status_bad_frame(),
    .m_status_good_frame()
);

endmodule

`resetall
