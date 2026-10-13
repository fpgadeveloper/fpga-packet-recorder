// SPDX-License-Identifier: MIT
//
// pktrec_cap_merge - 4:1 round-robin merge of whole capture records (dp_clk)
//
//   * N record streams (128-bit, tlast = last beat of a record) from the
//     pktrec_cap_port readers -> ONE 128-bit stream with back-pressure into the
//     fdrec packetizer (no tlast: the packetizer frames DMA packets itself)
//   * arbitration on record boundaries only: once a port is granted, its record
//     is passed beat by beat until its tlast; the next grant goes to the next
//     port (round robin) that has a record waiting
//   * fill: with fill_en = 1, every cycle in which no record is in progress and
//     none is waiting emits an all-zero 16-byte fill unit (see pktrec_format.h);
//     the capture app uses it to push the last records through the DMA at stop
//   * rec_srst (the recorder's soft reset, level): the packetizer empties its
//     register slice while it is high, so nothing is sent then; a record that
//     was in progress when it rose is discarded to its end (srst_aborts), so the
//     stream the recorder sees after a soft reset starts on a record boundary
//   * registered output (tvalid/tdata from flip-flops); throughput 1 beat/cycle
//     inside a record, 1 idle cycle between records at most
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_cap_merge #(
    parameter int N = 4
)(
    input  wire logic             clk,
    input  wire logic             rst,

    input  wire logic [N*128-1:0] s_tdata,
    input  wire logic [N-1:0]     s_tvalid,
    output logic      [N-1:0]     s_tready,
    input  wire logic [N-1:0]     s_tlast,

    output logic      [127:0]     m_tdata,
    output logic                  m_tvalid,
    input  wire logic             m_tready,

    input  wire logic             fill_en,
    input  wire logic             rec_srst,
    input  wire logic             clear,        // clear the counters

    output logic      [63:0]      bytes_out,    // record bytes delivered
    output logic      [63:0]      records_out,  // records delivered
    output logic      [63:0]      fill_beats,   // fill units delivered
    output logic      [63:0]      bp_cycles,    // cycles a beat waited for m_tready
    output logic      [31:0]      srst_aborts,  // records cut by rec_srst
    output logic                  busy,         // inside a record
    output logic                  idle          // no record beat in flight
);

localparam int CL_N = (N > 1) ? $clog2(N) : 1;

logic [CL_N-1:0] cur = '0;          // granted port while busy
logic [CL_N-1:0] last_gnt = '0;     // round-robin pointer
logic            discard = 1'b0;    // dropping the rest of the current record
logic            o_fill = 1'b0, o_last = 1'b0;
logic            srst_q = 1'b0;

// round robin: first valid port after last_gnt
logic            gnt_valid;
logic [CL_N-1:0] gnt;
always_comb begin
    gnt_valid = 1'b0;
    gnt       = '0;
    for (int i = N; i >= 1; i--) begin
        int idx;
        idx = (int'(last_gnt) + i) % N;
        if (s_tvalid[idx]) begin
            gnt_valid = 1'b1;
            gnt       = CL_N'(idx);
        end
    end
end

wire slot = !m_tvalid || m_tready;          // output register can take a beat
wire take = slot && !rec_srst;

wire [127:0] cur_data = s_tdata[128*cur +: 128];
wire [127:0] gnt_data = s_tdata[128*gnt +: 128];

always_comb begin
    s_tready = '0;
    if (busy) begin
        if (discard || take) s_tready[cur] = 1'b1;
    end else if (gnt_valid && take) begin
        s_tready[gnt] = 1'b1;
    end
end

always_ff @(posedge clk) begin
    srst_q <= rec_srst;
    if (slot) m_tvalid <= 1'b0;

    if (busy) begin
        if (discard) begin
            if (s_tvalid[cur] && s_tlast[cur]) begin
                busy    <= 1'b0;
                discard <= 1'b0;
            end
        end else if (take && s_tvalid[cur]) begin
            m_tdata  <= cur_data;
            m_tvalid <= 1'b1;
            o_fill   <= 1'b0;
            o_last   <= s_tlast[cur];
            if (s_tlast[cur]) busy <= 1'b0;
        end
    end else if (take) begin
        if (gnt_valid) begin
            cur      <= gnt;
            last_gnt <= gnt;
            m_tdata  <= gnt_data;
            m_tvalid <= 1'b1;
            o_fill   <= 1'b0;
            o_last   <= s_tlast[gnt];
            busy     <= !s_tlast[gnt];
        end else if (fill_en) begin
            m_tdata  <= '0;
            m_tvalid <= 1'b1;
            o_fill   <= 1'b1;
            o_last   <= 1'b0;
        end
    end

    // recorder soft reset: the packetizer drops whatever it holds, so drop the
    // output beat and the rest of a record in progress
    // (armed once, on the rising edge: the record may end -- in discard mode --
    // while rec_srst is still high, and the next record must not inherit it)
    if (rec_srst) begin
        m_tvalid <= 1'b0;
        if (!srst_q) begin
            if ((m_tvalid && !o_fill) || busy) srst_aborts <= srst_aborts + 32'd1;
            if (busy && !discard) discard <= 1'b1;
        end
    end

    // counters
    if (m_tvalid && m_tready && !rec_srst) begin
        if (o_fill) fill_beats <= fill_beats + 64'd1;
        else begin
            bytes_out <= bytes_out + 64'd16;
            if (o_last) records_out <= records_out + 64'd1;
        end
    end
    if (m_tvalid && !m_tready) bp_cycles <= bp_cycles + 64'd1;

    if (clear) begin
        bytes_out <= '0; records_out <= '0; fill_beats <= '0; bp_cycles <= '0; srst_aborts <= '0;
    end

    if (rst) begin
        m_tvalid <= 1'b0;
        busy     <= 1'b0;
        discard  <= 1'b0;
        cur      <= '0;
        last_gnt <= '0;
        bytes_out <= '0; records_out <= '0; fill_beats <= '0; bp_cycles <= '0; srst_aborts <= '0;
    end
end

always_ff @(posedge clk) idle <= !busy && !(m_tvalid && !o_fill);

endmodule

`resetall
