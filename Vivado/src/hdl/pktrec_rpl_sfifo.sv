// SPDX-License-Identifier: MIT
//
// pktrec_rpl_sfifo - synchronous first-word-fall-through FIFO for the replay
// block (pktrec_replay, M6): block RAM with a 2-cycle read (address register,
// RAM output register) and a 4-entry prefetch queue, so dout/valid behave like
// a FWFT FIFO at full clock rate.
//
//   wr_en  : write din (ignored while full)
//   full   : the RAM holds DEPTH entries (entries already moved into the
//            prefetch queue no longer count)
//   rd_en  : pop the head (dout) - only while valid
//   level  : entries held in total (RAM + read pipeline + prefetch queue)
//   rst    : synchronous, empties the FIFO
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_rpl_sfifo #(
    parameter int W     = 128,
    parameter int DEPTH = 2048,          // power of 2
    parameter     RAM_STYLE = "block"
)(
    input  wire logic          clk,
    input  wire logic          rst,
    input  wire logic          wr_en,
    input  wire logic [W-1:0]  din,
    output wire logic          full,
    input  wire logic          rd_en,
    output wire logic [W-1:0]  dout,
    output wire logic          valid,
    output logic [$clog2(DEPTH)+2:0] level
);

localparam int AW = $clog2(DEPTH);

(* ram_style = RAM_STYLE *) logic [W-1:0] mem [0:DEPTH-1];

logic [AW:0]   wptr = '0, rptr = '0;
logic [AW-1:0] raddr = '0;
logic          re1 = 1'b0, v1 = 1'b0, v2 = 1'b0;
logic [W-1:0]  d1, d2;

// prefetch queue
logic [W-1:0]  q [0:3];
logic [1:0]    qh = '0, qt = '0;
logic [2:0]    qn = '0;

wire [AW:0] used   = wptr - rptr;
assign full        = used[AW];                    // == DEPTH
wire        ram_ne = (wptr != rptr);
wire [2:0]  infl   = {2'b0, re1} + {2'b0, v1} + {2'b0, v2};
wire        issue  = ram_ne && (qn + infl < 3'd4);
wire        do_wr  = wr_en && !full;
wire        do_rd  = rd_en && (qn != 3'd0);

assign valid = (qn != 3'd0);
assign dout  = q[qh];
assign level = {2'b0, used} + {{(AW){1'b0}}, infl} + {{(AW){1'b0}}, qn};

always_ff @(posedge clk) begin
    if (do_wr) mem[wptr[AW-1:0]] <= din;
    if (re1) d1 <= mem[raddr];
    d2 <= d1;
end

always_ff @(posedge clk) begin
    re1 <= issue;
    if (issue) begin
        raddr <= rptr[AW-1:0];
        rptr  <= rptr + 1'b1;
    end
    v1 <= re1;          // d1 valid
    v2 <= v1;           // d2 valid
    if (do_wr) wptr <= wptr + 1'b1;
    if (v2) begin
        q[qt] <= d2;
        qt    <= qt + 1'b1;
    end
    if (do_rd) qh <= qh + 1'b1;
    qn <= qn + {2'b0, v2} - {2'b0, do_rd};
    if (rst) begin
        wptr <= '0;
        rptr <= '0;
        re1  <= 1'b0;
        v1   <= 1'b0;
        v2   <= 1'b0;
        qh   <= '0;
        qt   <= '0;
        qn   <= '0;
    end
end

endmodule

`resetall
