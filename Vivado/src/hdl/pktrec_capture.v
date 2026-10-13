// SPDX-License-Identifier: MIT
//
// pktrec_capture - block-design module reference (hierarchy "capture"): the
// monitor-mode capture path of the FPGA Packet Recorder (M1).
//
// Thin Verilog-2001 shell (Vivado needs a Verilog top for a module reference);
// the implementation is pktrec_capture_core.sv and its submodules:
//   pktrec_cap_port  (x4)  RX tap -> frame FIFO (whole-frame drop) -> record
//   pktrec_cap_merge       4:1 round robin over whole records -> m_axis_rec
//   pktrec_timebase        64-bit ns PHC (dp_clk) + a cycle counter distributed
//                          Gray-coded into the 4 RX and 4 TX MAC clocks
//                          (rx/tx_ptp_ts_n = {32'b0, cycle count})
//   pktrec_cap_regs        AXI-Lite registers (include/pktrec_regs.h PKTREC_CAP_*)
//   pktrec_sfd_io/_sfd     (M2) PHY SFD pins (phy_gpio0 = RX SFD, phy_gpio1 = TX
//                          SFD) oversampled by ISERDESE3 (~1 ns), timestamped,
//                          matched to the frames (RX) and to the MAC TX
//                          completions s_axis_tx_cpl_n (TX); the sampled levels
//                          go back out (phy_gpio0/1_lvl) to pktrec_m0_path
// Record format: include/pktrec_format.h.
//
// s_axis_rx_n: the MAC RX stream of port n (rx_clk_n, no tready) -- a parallel
// tap of the stream that also feeds the forward path (pktrec_m0_path).
// m_axis_rec (dp_clk): the merged record stream to fdrec_core s_axis_cap;
// cap_sel: CTRL.SRC_SEL (dp_clk level) selects it in fdrec_core; rec_srst: the
// recorder's soft reset (dp_clk level) from fdrec_core.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module pktrec_capture #(
    parameter DP_CLK_HZ  = 250000000,
    parameter FIFO_BYTES = 16384,
    parameter SFD_SAMPLER = "ISERDES",
    parameter SFD_PIPE_NS = 16
)(
    // ---- datapath / register clock ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 dp_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi:m_axis_rec, ASSOCIATED_RESET dp_resetn" *)
    input  wire          dp_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 dp_resetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          dp_resetn,
    // ---- port 0: MAC RX stream tap (rx_clk_0, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk_0 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_rx_0, ASSOCIATED_RESET rx_aresetn_0" *)
    input  wire          rx_clk_0,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_aresetn_0 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          rx_aresetn_0,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_0 TDATA" *)
    input  wire [15:0]   s_axis_rx_0_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_0 TKEEP" *)
    input  wire [1:0]    s_axis_rx_0_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_0 TVALID" *)
    input  wire          s_axis_rx_0_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_0 TLAST" *)
    input  wire          s_axis_rx_0_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_0 TUSER" *)
    input  wire [64:0]   s_axis_rx_0_tuser,
    // ---- port 0: timestamps to the MAC ({32'b0, timebase cycle count}, in rx_clk_0 / tx_clk_0) ----
    output wire [63:0]   rx_ptp_ts_0,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk_0 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_tx_cpl_0, ASSOCIATED_RESET tx_aresetn_0" *)
    input  wire          tx_clk_0,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 tx_aresetn_0 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          tx_aresetn_0,
    output wire [63:0]   tx_ptp_ts_0,
    // ---- port 0: MAC TX completions (tx_clk_0, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_cpl_0 TDATA" *)
    input  wire [63:0]   s_axis_tx_cpl_0_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_cpl_0 TID" *)
    input  wire [7:0]    s_axis_tx_cpl_0_tid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_cpl_0 TVALID" *)
    input  wire          s_axis_tx_cpl_0_tvalid,
    // ---- port 1: MAC RX stream tap (rx_clk_1, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk_1 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_rx_1, ASSOCIATED_RESET rx_aresetn_1" *)
    input  wire          rx_clk_1,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_aresetn_1 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          rx_aresetn_1,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_1 TDATA" *)
    input  wire [15:0]   s_axis_rx_1_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_1 TKEEP" *)
    input  wire [1:0]    s_axis_rx_1_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_1 TVALID" *)
    input  wire          s_axis_rx_1_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_1 TLAST" *)
    input  wire          s_axis_rx_1_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_1 TUSER" *)
    input  wire [64:0]   s_axis_rx_1_tuser,
    // ---- port 1: timestamps to the MAC ({32'b0, timebase cycle count}, in rx_clk_1 / tx_clk_1) ----
    output wire [63:0]   rx_ptp_ts_1,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk_1 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_tx_cpl_1, ASSOCIATED_RESET tx_aresetn_1" *)
    input  wire          tx_clk_1,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 tx_aresetn_1 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          tx_aresetn_1,
    output wire [63:0]   tx_ptp_ts_1,
    // ---- port 1: MAC TX completions (tx_clk_1, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_cpl_1 TDATA" *)
    input  wire [63:0]   s_axis_tx_cpl_1_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_cpl_1 TID" *)
    input  wire [7:0]    s_axis_tx_cpl_1_tid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_cpl_1 TVALID" *)
    input  wire          s_axis_tx_cpl_1_tvalid,
    // ---- port 2: MAC RX stream tap (rx_clk_2, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk_2 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_rx_2, ASSOCIATED_RESET rx_aresetn_2" *)
    input  wire          rx_clk_2,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_aresetn_2 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          rx_aresetn_2,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_2 TDATA" *)
    input  wire [15:0]   s_axis_rx_2_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_2 TKEEP" *)
    input  wire [1:0]    s_axis_rx_2_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_2 TVALID" *)
    input  wire          s_axis_rx_2_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_2 TLAST" *)
    input  wire          s_axis_rx_2_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_2 TUSER" *)
    input  wire [64:0]   s_axis_rx_2_tuser,
    // ---- port 2: timestamps to the MAC ({32'b0, timebase cycle count}, in rx_clk_2 / tx_clk_2) ----
    output wire [63:0]   rx_ptp_ts_2,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk_2 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_tx_cpl_2, ASSOCIATED_RESET tx_aresetn_2" *)
    input  wire          tx_clk_2,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 tx_aresetn_2 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          tx_aresetn_2,
    output wire [63:0]   tx_ptp_ts_2,
    // ---- port 2: MAC TX completions (tx_clk_2, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_cpl_2 TDATA" *)
    input  wire [63:0]   s_axis_tx_cpl_2_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_cpl_2 TID" *)
    input  wire [7:0]    s_axis_tx_cpl_2_tid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_cpl_2 TVALID" *)
    input  wire          s_axis_tx_cpl_2_tvalid,
    // ---- port 3: MAC RX stream tap (rx_clk_3, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk_3 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_rx_3, ASSOCIATED_RESET rx_aresetn_3" *)
    input  wire          rx_clk_3,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_aresetn_3 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          rx_aresetn_3,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_3 TDATA" *)
    input  wire [15:0]   s_axis_rx_3_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_3 TKEEP" *)
    input  wire [1:0]    s_axis_rx_3_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_3 TVALID" *)
    input  wire          s_axis_rx_3_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_3 TLAST" *)
    input  wire          s_axis_rx_3_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_3 TUSER" *)
    input  wire [64:0]   s_axis_rx_3_tuser,
    // ---- port 3: timestamps to the MAC ({32'b0, timebase cycle count}, in rx_clk_3 / tx_clk_3) ----
    output wire [63:0]   rx_ptp_ts_3,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk_3 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_tx_cpl_3, ASSOCIATED_RESET tx_aresetn_3" *)
    input  wire          tx_clk_3,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 tx_aresetn_3 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire          tx_aresetn_3,
    output wire [63:0]   tx_ptp_ts_3,
    // ---- port 3: MAC TX completions (tx_clk_3, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_cpl_3 TDATA" *)
    input  wire [63:0]   s_axis_tx_cpl_3_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_cpl_3 TID" *)
    input  wire [7:0]    s_axis_tx_cpl_3_tid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_cpl_3 TVALID" *)
    input  wire          s_axis_tx_cpl_3_tvalid,
    // ---- merged record stream to fdrec_core s_axis_cap (dp_clk) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rec TDATA" *)
    output wire [127:0]  m_axis_rec_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rec TVALID" *)
    output wire          m_axis_rec_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rec TREADY" *)
    input  wire          m_axis_rec_tready,
    output wire          cap_sel,
    input  wire          rec_srst,
    // ---- PHY SFD pins (OP080 GPIO_0 = RX SFD, GPIO_1 = TX SFD; asynchronous) ----
    input  wire [3:0]    phy_gpio0,
    input  wire [3:0]    phy_gpio1,
    // sampled levels (dp_clk) for pktrec_m0_path's IO_STATUS / edge counters
    output wire [3:0]    phy_gpio0_lvl,
    output wire [3:0]    phy_gpio1_lvl,
    // ---- s_axi (AXI4-Lite slave, dp_clk), include/pktrec_regs.h PKTREC_CAP_* ----
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

wire [255:0] rx_ts_all, tx_ts_all;
assign {rx_ptp_ts_3, rx_ptp_ts_2, rx_ptp_ts_1, rx_ptp_ts_0} = rx_ts_all;
assign {tx_ptp_ts_3, tx_ptp_ts_2, tx_ptp_ts_1, tx_ptp_ts_0} = tx_ts_all;

pktrec_capture_core #(
    .N(4),
    .DP_CLK_HZ(DP_CLK_HZ),
    .FIFO_BYTES(FIFO_BYTES),
    .SFD_SAMPLER(SFD_SAMPLER),
    .SFD_PIPE_NS(SFD_PIPE_NS)
) core_inst (
    .dp_clk(dp_clk),
    .dp_rst(!dp_resetn),
    .rx_clk({rx_clk_3, rx_clk_2, rx_clk_1, rx_clk_0}),
    .rx_rst(~{rx_aresetn_3, rx_aresetn_2, rx_aresetn_1, rx_aresetn_0}),
    .rx_tdata({s_axis_rx_3_tdata, s_axis_rx_2_tdata, s_axis_rx_1_tdata, s_axis_rx_0_tdata}),
    .rx_tkeep({s_axis_rx_3_tkeep, s_axis_rx_2_tkeep, s_axis_rx_1_tkeep, s_axis_rx_0_tkeep}),
    .rx_tvalid({s_axis_rx_3_tvalid, s_axis_rx_2_tvalid, s_axis_rx_1_tvalid, s_axis_rx_0_tvalid}),
    .rx_tlast({s_axis_rx_3_tlast, s_axis_rx_2_tlast, s_axis_rx_1_tlast, s_axis_rx_0_tlast}),
    .rx_tbad({s_axis_rx_3_tuser[0], s_axis_rx_2_tuser[0], s_axis_rx_1_tuser[0], s_axis_rx_0_tuser[0]}),
    .rx_tts({s_axis_rx_3_tuser[64:1], s_axis_rx_2_tuser[64:1], s_axis_rx_1_tuser[64:1], s_axis_rx_0_tuser[64:1]}),
    .rx_ptp_ts(rx_ts_all),
    .tx_clk({tx_clk_3, tx_clk_2, tx_clk_1, tx_clk_0}),
    .tx_rst(~{tx_aresetn_3, tx_aresetn_2, tx_aresetn_1, tx_aresetn_0}),
    .tx_ptp_ts(tx_ts_all),
    .tx_cpl_valid({s_axis_tx_cpl_3_tvalid, s_axis_tx_cpl_2_tvalid, s_axis_tx_cpl_1_tvalid, s_axis_tx_cpl_0_tvalid}),
    .tx_cpl_ts({s_axis_tx_cpl_3_tdata, s_axis_tx_cpl_2_tdata, s_axis_tx_cpl_1_tdata, s_axis_tx_cpl_0_tdata}),
    .sfd_rx_pin(phy_gpio0),
    .sfd_tx_pin(phy_gpio1),
    .sfd_rx_lvl(phy_gpio0_lvl),
    .sfd_tx_lvl(phy_gpio1_lvl),
    .m_rec_tdata(m_axis_rec_tdata),
    .m_rec_tvalid(m_axis_rec_tvalid),
    .m_rec_tready(m_axis_rec_tready),
    .cap_sel(cap_sel),
    .rec_srst(rec_srst),
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
