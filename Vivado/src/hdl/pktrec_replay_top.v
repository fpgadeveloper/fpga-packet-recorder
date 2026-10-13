// SPDX-License-Identifier: MIT
//
// pktrec_replay_top - block-design module reference (hierarchy "replay"): the
// capture replay of the FPGA Packet Recorder (M6). Thin Verilog-2001 shell
// around pktrec_replay.sv (Vivado needs a Verilog top for a module reference).
//
//   s_axis_egr (src_clk): fdrec_core m_axis_snk, the recorder's playback stream
//                         (AXI DMA MM2S -> egress FIFO); back-pressure stalls the DMA
//   m_axis_chk (src_clk): the same stream passed on to user_data_sink (fdrec_check)
//                         while CTRL.SEL = 0 (fdplay keeps working unchanged)
//   tb_now / tb_inc_ns (dp_clk): shared timebase from capture/pktrec_capture
//   m_axis_rpl (dp_clk):  frames, 16 bit, tdest = TX port, to
//                         eth_ports/pktrec_m0_path s_axis_rpl (path mode 4 REPLAY)
//   rpl_eff:              pktrec_m0_path: port n's TX source is the replay FIFO
//   s_axi (dp_clk):       include/pktrec_regs.h PKTREC_RPL_*
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module pktrec_replay_top #(
    parameter STORE_BEATS = 8192,
    parameter META_DEPTH  = 2048,
    parameter MAX_CAP     = 16384
)(
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 src_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axis_egr:m_axis_chk, ASSOCIATED_RESET src_resetn" *)
    input  wire          src_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 src_resetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          src_resetn,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 dp_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:m_axis_rpl, ASSOCIATED_RESET dp_resetn" *)
    input  wire          dp_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 dp_resetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          dp_resetn,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_egr TDATA" *)
    input  wire [127:0]  s_axis_egr_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_egr TLAST" *)
    input  wire          s_axis_egr_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_egr TVALID" *)
    input  wire          s_axis_egr_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_egr TREADY" *)
    output wire          s_axis_egr_tready,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_chk TDATA" *)
    output wire [127:0]  m_axis_chk_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_chk TLAST" *)
    output wire          m_axis_chk_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_chk TVALID" *)
    output wire          m_axis_chk_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_chk TREADY" *)
    input  wire          m_axis_chk_tready,

    input  wire [63:0]   tb_now,
    input  wire [7:0]    tb_inc_ns,

    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rpl TDATA" *)
    output wire [15:0]   m_axis_rpl_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rpl TKEEP" *)
    output wire [1:0]    m_axis_rpl_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rpl TVALID" *)
    output wire          m_axis_rpl_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rpl TREADY" *)
    input  wire          m_axis_rpl_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rpl TLAST" *)
    output wire          m_axis_rpl_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rpl TUSER" *)
    output wire [0:0]    m_axis_rpl_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rpl TDEST" *)
    output wire [1:0]    m_axis_rpl_tdest,
    input  wire [3:0]    rpl_eff,

    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 12" *)
    input  wire [11:0]   s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
    input  wire [2:0]    s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire          s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire          s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0]   s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0]    s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire          s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire          s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0]    s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire          s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire          s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [11:0]   s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
    input  wire [2:0]    s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire          s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire          s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0]   s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0]    s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire          s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire          s_axi_rready
);

pktrec_replay #(
    .STORE_BEATS(STORE_BEATS),
    .META_DEPTH(META_DEPTH),
    .MAX_CAP(MAX_CAP)
) core_inst (
    .src_clk(src_clk),
    .src_rst(!src_resetn),
    .s_egr_tdata(s_axis_egr_tdata),
    .s_egr_tlast(s_axis_egr_tlast),
    .s_egr_tvalid(s_axis_egr_tvalid),
    .s_egr_tready(s_axis_egr_tready),
    .m_chk_tdata(m_axis_chk_tdata),
    .m_chk_tlast(m_axis_chk_tlast),
    .m_chk_tvalid(m_axis_chk_tvalid),
    .m_chk_tready(m_axis_chk_tready),
    .clk(dp_clk),
    .rst(!dp_resetn),
    .tb_now(tb_now),
    .tb_inc_ns(tb_inc_ns),
    .m_rpl_tdata(m_axis_rpl_tdata),
    .m_rpl_tkeep(m_axis_rpl_tkeep),
    .m_rpl_tvalid(m_axis_rpl_tvalid),
    .m_rpl_tready(m_axis_rpl_tready),
    .m_rpl_tlast(m_axis_rpl_tlast),
    .m_rpl_tuser(m_axis_rpl_tuser[0]),
    .m_rpl_tdest(m_axis_rpl_tdest),
    .rpl_eff(rpl_eff),
    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awvalid(s_axi_awvalid),
    .s_axi_awready(s_axi_awready),
    .s_axi_wdata(s_axi_wdata),
    .s_axi_wstrb(s_axi_wstrb),
    .s_axi_wvalid(s_axi_wvalid),
    .s_axi_wready(s_axi_wready),
    .s_axi_bresp(s_axi_bresp),
    .s_axi_bvalid(s_axi_bvalid),
    .s_axi_bready(s_axi_bready),
    .s_axi_araddr(s_axi_araddr),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready)
);

endmodule
