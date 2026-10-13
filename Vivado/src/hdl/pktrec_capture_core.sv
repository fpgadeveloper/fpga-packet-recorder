// SPDX-License-Identifier: MIT
//
// pktrec_capture_core - monitor-mode capture path (M1), see pktrec_capture.v
//
//   RX n (rx_clk_n) --> pktrec_cap_port n --+
//                                           +--> pktrec_cap_merge --> m_rec (dp_clk)
//   ...                                     |    (round robin over whole records)
//   pktrec_timebase (dp_clk) --> tb_ns/cyc -+    --> fdrec_core packetizer
//        |                                        (s_axis_cap, back-pressure)
//        +--> rx_ts_n / tx_ts_n ({32'b0, cycle count}, Gray-synchronised into
//             the MAC clock domains; converted back to ns in pktrec_cap_port)
//   pktrec_cap_regs (AXI-Lite, dp_clk)
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_capture_core #(
    parameter int     N          = 4,
    parameter longint DP_CLK_HZ  = 250000000,
    parameter int     FIFO_BYTES = 16384
)(
    input  wire logic             dp_clk,
    input  wire logic             dp_rst,

    input  wire logic [N-1:0]     rx_clk,
    input  wire logic [N-1:0]     rx_rst,
    input  wire logic [N*16-1:0]  rx_tdata,
    input  wire logic [N*2-1:0]   rx_tkeep,
    input  wire logic [N-1:0]     rx_tvalid,
    input  wire logic [N-1:0]     rx_tlast,
    input  wire logic [N-1:0]     rx_tbad,
    input  wire logic [N*64-1:0]  rx_tts,       // tuser[64:1] per port ({32'b0, cycle count})
    output wire logic [N*64-1:0]  rx_ptp_ts,
    input  wire logic [N-1:0]     tx_clk,
    input  wire logic [N-1:0]     tx_rst,
    output wire logic [N*64-1:0]  tx_ptp_ts,

    output wire logic [127:0]     m_rec_tdata,
    output wire logic             m_rec_tvalid,
    input  wire logic             m_rec_tready,
    output wire logic             cap_sel,
    input  wire logic             rec_srst,

    input  wire logic [11:0]      s_axi_awaddr,
    input  wire logic             s_axi_awvalid,
    output wire logic             s_axi_awready,
    input  wire logic [31:0]      s_axi_wdata,
    input  wire logic [3:0]       s_axi_wstrb,
    input  wire logic             s_axi_wvalid,
    output wire logic             s_axi_wready,
    output wire logic [1:0]       s_axi_bresp,
    output wire logic             s_axi_bvalid,
    input  wire logic             s_axi_bready,
    input  wire logic [11:0]      s_axi_araddr,
    input  wire logic             s_axi_arvalid,
    output wire logic             s_axi_arready,
    output wire logic [31:0]      s_axi_rdata,
    output wire logic [1:0]       s_axi_rresp,
    output wire logic             s_axi_rvalid,
    input  wire logic             s_axi_rready
);

// ---- control ----
wire          cap_enable, fill_en, clear;
wire [N-1:0]  port_en, hwm_clr;
wire [15:0]   snaplen;
wire          tb_set, tb_adj, tb_inc_load;
wire [63:0]   tb_set_val, tb_adj_val;
wire [7:0]    tb_inc_ns_wr, tb_inc_ns;
wire [31:0]   tb_inc_frac_wr, tb_inc_frac;
wire [63:0]   tb_ns;
wire [31:0]   tb_frac;
wire [31:0]   tb_cyc;
wire [31:0]   mac_offset;
wire [2*N-1:0] tb_valid;
wire [N*32-1:0] rx_cyc, tx_cyc;
genvar g;
for (g = 0; g < N; g = g + 1) begin : g_ts
    assign rx_ptp_ts[64*g +: 64] = {32'd0, rx_cyc[32*g +: 32]};
    assign tx_ptp_ts[64*g +: 64] = {32'd0, tx_cyc[32*g +: 32]};
end

// ---- timebase ----
pktrec_timebase #(.CLK_HZ(DP_CLK_HZ), .N(N)) tb_inst (
    .clk(dp_clk), .rst(dp_rst),
    .inc_load(tb_inc_load), .inc_ns_in(tb_inc_ns_wr), .inc_frac_in(tb_inc_frac_wr),
    .set(tb_set), .set_val(tb_set_val), .adj(tb_adj), .adj_val(tb_adj_val),
    .ns(tb_ns), .frac(tb_frac), .inc_ns(tb_inc_ns), .inc_frac(tb_inc_frac),
    .cyc(tb_cyc), .dom_valid(tb_valid),
    .rx_clk(rx_clk), .rx_rst(rx_rst), .rx_cyc(rx_cyc),
    .tx_clk(tx_clk), .tx_rst(tx_rst), .tx_cyc(tx_cyc)
);

// ---- ports ----
wire [N*128-1:0] p_tdata;
wire [N-1:0]     p_tvalid, p_tready, p_tlast;
wire [N*64-1:0]  s_frames_rx, s_frames_bad, s_frames_drop, s_bytes_rx, s_bytes_drop,
                 s_frames_trunc, s_records;
wire [N*32-1:0]  s_fifo_hwm;
wire [N*16-1:0]  s_seq_next;
wire [N-1:0]     s_rx_active, s_idle, s_len_fixup;

for (g = 0; g < N; g = g + 1) begin : g_port
    pktrec_cap_port #(.PORT(g), .FIFO_BYTES(FIFO_BYTES)) port_inst (
        .rx_clk(rx_clk[g]),
        .rx_rst(rx_rst[g]),
        .rx_tdata(rx_tdata[16*g +: 16]),
        .rx_tkeep(rx_tkeep[2*g +: 2]),
        .rx_tvalid(rx_tvalid[g]),
        .rx_tlast(rx_tlast[g]),
        .rx_tbad(rx_tbad[g]),
        .rx_ts_cyc(rx_tts[64*g +: 32]),
        .dp_clk(dp_clk),
        .dp_rst(dp_rst),
        .cap_en(cap_enable && port_en[g]),
        .snaplen(snaplen),
        .clear(clear),
        .tb_ns(tb_ns),
        .tb_cyc(tb_cyc),
        .tb_inc({tb_inc_ns, tb_inc_frac}),
        .mac_offset(mac_offset),
        .m_tdata(p_tdata[128*g +: 128]),
        .m_tvalid(p_tvalid[g]),
        .m_tready(p_tready[g]),
        .m_tlast(p_tlast[g]),
        .st_frames_rx(s_frames_rx[64*g +: 64]),
        .st_frames_bad(s_frames_bad[64*g +: 64]),
        .st_frames_drop(s_frames_drop[64*g +: 64]),
        .st_bytes_rx(s_bytes_rx[64*g +: 64]),
        .st_bytes_drop(s_bytes_drop[64*g +: 64]),
        .st_frames_trunc(s_frames_trunc[64*g +: 64]),
        .st_seq_next(s_seq_next[16*g +: 16]),
        .st_rx_active(s_rx_active[g]),
        .st_records(s_records[64*g +: 64]),
        .st_fifo_hwm(s_fifo_hwm[32*g +: 32]),
        .hwm_clr(hwm_clr[g]),
        .idle(s_idle[g]),
        .len_fixup(s_len_fixup[g])
    );
end

// ---- merge ----
wire [63:0] bytes_out, records_out, fill_beats, bp_cycles;
wire [31:0] srst_aborts;
wire        merge_busy, merge_idle;

pktrec_cap_merge #(.N(N)) merge_inst (
    .clk(dp_clk), .rst(dp_rst),
    .s_tdata(p_tdata), .s_tvalid(p_tvalid), .s_tready(p_tready), .s_tlast(p_tlast),
    .m_tdata(m_rec_tdata), .m_tvalid(m_rec_tvalid), .m_tready(m_rec_tready),
    .fill_en(fill_en), .rec_srst(rec_srst), .clear(clear),
    .bytes_out(bytes_out), .records_out(records_out), .fill_beats(fill_beats),
    .bp_cycles(bp_cycles), .srst_aborts(srst_aborts),
    .busy(merge_busy), .idle(merge_idle)
);

// ---- length fix-ups (any port) ----
logic [31:0] len_fixups = '0;
always_ff @(posedge dp_clk) begin
    if (|s_len_fixup) len_fixups <= len_fixups + 32'd1;
    if (clear || dp_rst) len_fixups <= '0;
end

logic idle_all = 1'b0;
always_ff @(posedge dp_clk) idle_all <= (&s_idle) && merge_idle;

// ---- registers ----
wire src_sel;
assign cap_sel = src_sel;

pktrec_cap_regs #(.N(N), .DP_CLK_HZ(32'(DP_CLK_HZ)), .FIFO_BYTES(32'(FIFO_BYTES))) regs_inst (
    .clk(dp_clk), .rst(dp_rst),
    .s_axi_awaddr(s_axi_awaddr), .s_axi_awvalid(s_axi_awvalid), .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata), .s_axi_wstrb(s_axi_wstrb), .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready), .s_axi_bresp(s_axi_bresp), .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready), .s_axi_araddr(s_axi_araddr), .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready), .s_axi_rdata(s_axi_rdata), .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid), .s_axi_rready(s_axi_rready),
    .cap_enable(cap_enable), .fill_en(fill_en), .src_sel(src_sel), .clear(clear),
    .port_en(port_en), .snaplen(snaplen), .hwm_clr(hwm_clr),
    .tb_set(tb_set), .tb_set_val(tb_set_val), .tb_adj(tb_adj), .tb_adj_val(tb_adj_val),
    .tb_inc_load(tb_inc_load), .tb_inc_ns_wr(tb_inc_ns_wr), .tb_inc_frac_wr(tb_inc_frac_wr),
    .tb_ns(tb_ns), .tb_inc_ns(tb_inc_ns), .tb_inc_frac(tb_inc_frac), .tb_valid(tb_valid),
    .mac_offset(mac_offset),
    .idle(idle_all), .merge_busy(merge_busy), .port_idle(s_idle), .rx_active(s_rx_active),
    .bytes_out(bytes_out), .records_out(records_out), .fill_beats(fill_beats),
    .bp_cycles(bp_cycles), .srst_aborts(srst_aborts), .len_fixups(len_fixups),
    .p_frames_rx(s_frames_rx), .p_frames_bad(s_frames_bad), .p_frames_drop(s_frames_drop),
    .p_bytes_rx(s_bytes_rx), .p_bytes_drop(s_bytes_drop), .p_frames_trunc(s_frames_trunc),
    .p_records(s_records), .p_fifo_hwm(s_fifo_hwm), .p_seq_next(s_seq_next)
);

endmodule

`resetall
