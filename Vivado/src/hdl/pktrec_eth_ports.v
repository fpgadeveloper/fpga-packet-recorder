// SPDX-License-Identifier: MIT
//
// pktrec_eth_ports - block-design module reference: 4-port 1G SGMII MAC/PCS for the
// Opsero Ethernet FMC Max (OP080) on one UltraScale+ GTH quad, through Taxi's
// taxi_eth_mac_1g_basex_us wrapper (CNT = 4).
//
// Thin Verilog-2001 shell (Vivado requires a Verilog top for a module reference);
// the implementation is pktrec_eth_ports_core.sv (MIT), which instantiates the Taxi
// library (CERN-OHL-S-2.0). Register map: see pktrec_eth_ports_core.sv header.
//
// Per port n (0..3): s_axis_tx_n / m_axis_tx_cpl_n / tx_ptp_ts_n on tx_clk_n,
// m_axis_rx_n / rx_ptp_ts_n on rx_clk_n (recovered clock). All MAC clocks 62.5 MHz,
// 16-bit data. RX has no tready (no back-pressure); TX underrun aborts the frame.
// EXT_TX_IFG = 1 (M3): the MAC TX inter-frame gap of port n comes from tx_ifg[8n+7:8n]
// (tx_clk_n; driven by pktrec_m0_path's dynamic IFG) instead of the TX_IFG register.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module pktrec_eth_ports #(
    parameter FAMILY             = "zynquplus",
    parameter CFG_LOW_LATENCY    = 1,
    parameter [3:0] GT_TX_POLARITY = 4'b0000,
    parameter [3:0] GT_RX_POLARITY = 4'b0000,
    parameter PTP_TS_EN          = 1,
    parameter PTP_TS_W           = 64,      // 64: relative ns.fns (48.16); 96 needs PTP_TS_FMT_TOD
    parameter PTP_TS_FMT_TOD     = 0,
    parameter TX_TAG_W           = 8,
    parameter XCVR_RST_DEFAULT   = 0,
    parameter DEFAULT_TX_PAD_EN  = 1,
    parameter EXT_TX_IFG         = 0,       // 1: MAC TX IFG from tx_ifg (M3 dynamic IFG), 0: TX_IFG register
    parameter MAX_FRAME_LEN      = 1522,    // TX/RX_MAX_LEN reset (bytes incl. FCS): 1518 + one 802.1Q tag
    parameter C_S_AXI_ADDR_WIDTH = 19,
    parameter SIM                = 0
)(
    // ---- GT reference clock (125 MHz, GBTCLK0_M2C; IBUFDS_GTE4 inside) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 gt_ref_clk CLK_P" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 125000000" *)
    input  wire         gt_ref_clk_clk_p,
    (* X_INTERFACE_INFO = "xilinx.com:interface:diff_clock:1.0 gt_ref_clk CLK_N" *)
    input  wire         gt_ref_clk_clk_n,
    // ---- GT serial lanes (index n = FMC DPn = Ethernet FMC Max port Pn) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:gt:1.0 gt GTX_P" *)
    output wire [3:0]   gt_gtx_p,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gt:1.0 gt GTX_N" *)
    output wire [3:0]   gt_gtx_n,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gt:1.0 gt GRX_P" *)
    input  wire [3:0]   gt_grx_p,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gt:1.0 gt GRX_N" *)
    input  wire [3:0]   gt_grx_n,
    // ---- control clock (62.5..125 MHz free-running): s_axi, MDIO, GT DRP/reset FSMs ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ctrl_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET ctrl_aresetn" *)
    input  wire         ctrl_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ctrl_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire         ctrl_aresetn,
    // ---- port 0 clocks / resets ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk_0 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_tx_0:m_axis_tx_cpl_0, ASSOCIATED_RESET tx_aresetn_0" *)
    output wire         tx_clk_0,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 tx_aresetn_0 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output wire         tx_aresetn_0,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk_0 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF m_axis_rx_0, ASSOCIATED_RESET rx_aresetn_0" *)
    output wire         rx_clk_0,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_aresetn_0 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output wire         rx_aresetn_0,
    // ---- m_axis_rx_0 (rx_clk_0): tuser[0] bad frame @tlast, tuser[PTP_TS_W:1] RX ts; no tready ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_0 TDATA" *)
    output wire [15:0]  m_axis_rx_0_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_0 TKEEP" *)
    output wire [1:0]   m_axis_rx_0_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_0 TVALID" *)
    output wire         m_axis_rx_0_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_0 TLAST" *)
    output wire         m_axis_rx_0_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_0 TUSER" *)
    output wire [PTP_TS_W:0] m_axis_rx_0_tuser,
    // ---- s_axis_tx_0 (tx_clk_0): tuser[0] = send as bad frame; tid = ts tag ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_0 TDATA" *)
    input  wire [15:0]  s_axis_tx_0_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_0 TKEEP" *)
    input  wire [1:0]   s_axis_tx_0_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_0 TVALID" *)
    input  wire         s_axis_tx_0_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_0 TREADY" *)
    output wire         s_axis_tx_0_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_0 TLAST" *)
    input  wire         s_axis_tx_0_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_0 TUSER" *)
    input  wire [0:0]   s_axis_tx_0_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_0 TID" *)
    input  wire [TX_TAG_W-1:0] s_axis_tx_0_tid,
    // ---- m_axis_tx_cpl_0 (tx_clk_0): TX timestamp (tdata) + tag (tid) per frame; no tready ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_cpl_0 TDATA" *)
    output wire [PTP_TS_W-1:0] m_axis_tx_cpl_0_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_cpl_0 TID" *)
    output wire [TX_TAG_W-1:0] m_axis_tx_cpl_0_tid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_cpl_0 TVALID" *)
    output wire         m_axis_tx_cpl_0_tvalid,
    // ---- port 0 timestamp inputs (PTP_TS_EN; already in tx_clk_0 / rx_clk_0) ----
    input  wire [PTP_TS_W-1:0] tx_ptp_ts_0,
    input  wire [PTP_TS_W-1:0] rx_ptp_ts_0,
    // ---- TX inter-frame gap per port (EXT_TX_IFG = 1): [8n+7:8n] in tx_clk_n, bytes ----
    input  wire [31:0]  tx_ifg,
    // ---- port 1 clocks / resets ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk_1 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_tx_1:m_axis_tx_cpl_1, ASSOCIATED_RESET tx_aresetn_1" *)
    output wire         tx_clk_1,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 tx_aresetn_1 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output wire         tx_aresetn_1,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk_1 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF m_axis_rx_1, ASSOCIATED_RESET rx_aresetn_1" *)
    output wire         rx_clk_1,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_aresetn_1 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output wire         rx_aresetn_1,
    // ---- m_axis_rx_1 (rx_clk_1): tuser[0] bad frame @tlast, tuser[PTP_TS_W:1] RX ts; no tready ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_1 TDATA" *)
    output wire [15:0]  m_axis_rx_1_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_1 TKEEP" *)
    output wire [1:0]   m_axis_rx_1_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_1 TVALID" *)
    output wire         m_axis_rx_1_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_1 TLAST" *)
    output wire         m_axis_rx_1_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_1 TUSER" *)
    output wire [PTP_TS_W:0] m_axis_rx_1_tuser,
    // ---- s_axis_tx_1 (tx_clk_1): tuser[0] = send as bad frame; tid = ts tag ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_1 TDATA" *)
    input  wire [15:0]  s_axis_tx_1_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_1 TKEEP" *)
    input  wire [1:0]   s_axis_tx_1_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_1 TVALID" *)
    input  wire         s_axis_tx_1_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_1 TREADY" *)
    output wire         s_axis_tx_1_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_1 TLAST" *)
    input  wire         s_axis_tx_1_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_1 TUSER" *)
    input  wire [0:0]   s_axis_tx_1_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_1 TID" *)
    input  wire [TX_TAG_W-1:0] s_axis_tx_1_tid,
    // ---- m_axis_tx_cpl_1 (tx_clk_1): TX timestamp (tdata) + tag (tid) per frame; no tready ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_cpl_1 TDATA" *)
    output wire [PTP_TS_W-1:0] m_axis_tx_cpl_1_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_cpl_1 TID" *)
    output wire [TX_TAG_W-1:0] m_axis_tx_cpl_1_tid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_cpl_1 TVALID" *)
    output wire         m_axis_tx_cpl_1_tvalid,
    // ---- port 1 timestamp inputs (PTP_TS_EN; already in tx_clk_1 / rx_clk_1) ----
    input  wire [PTP_TS_W-1:0] tx_ptp_ts_1,
    input  wire [PTP_TS_W-1:0] rx_ptp_ts_1,
    // ---- port 2 clocks / resets ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk_2 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_tx_2:m_axis_tx_cpl_2, ASSOCIATED_RESET tx_aresetn_2" *)
    output wire         tx_clk_2,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 tx_aresetn_2 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output wire         tx_aresetn_2,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk_2 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF m_axis_rx_2, ASSOCIATED_RESET rx_aresetn_2" *)
    output wire         rx_clk_2,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_aresetn_2 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output wire         rx_aresetn_2,
    // ---- m_axis_rx_2 (rx_clk_2): tuser[0] bad frame @tlast, tuser[PTP_TS_W:1] RX ts; no tready ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_2 TDATA" *)
    output wire [15:0]  m_axis_rx_2_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_2 TKEEP" *)
    output wire [1:0]   m_axis_rx_2_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_2 TVALID" *)
    output wire         m_axis_rx_2_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_2 TLAST" *)
    output wire         m_axis_rx_2_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_2 TUSER" *)
    output wire [PTP_TS_W:0] m_axis_rx_2_tuser,
    // ---- s_axis_tx_2 (tx_clk_2): tuser[0] = send as bad frame; tid = ts tag ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_2 TDATA" *)
    input  wire [15:0]  s_axis_tx_2_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_2 TKEEP" *)
    input  wire [1:0]   s_axis_tx_2_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_2 TVALID" *)
    input  wire         s_axis_tx_2_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_2 TREADY" *)
    output wire         s_axis_tx_2_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_2 TLAST" *)
    input  wire         s_axis_tx_2_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_2 TUSER" *)
    input  wire [0:0]   s_axis_tx_2_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_2 TID" *)
    input  wire [TX_TAG_W-1:0] s_axis_tx_2_tid,
    // ---- m_axis_tx_cpl_2 (tx_clk_2): TX timestamp (tdata) + tag (tid) per frame; no tready ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_cpl_2 TDATA" *)
    output wire [PTP_TS_W-1:0] m_axis_tx_cpl_2_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_cpl_2 TID" *)
    output wire [TX_TAG_W-1:0] m_axis_tx_cpl_2_tid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_cpl_2 TVALID" *)
    output wire         m_axis_tx_cpl_2_tvalid,
    // ---- port 2 timestamp inputs (PTP_TS_EN; already in tx_clk_2 / rx_clk_2) ----
    input  wire [PTP_TS_W-1:0] tx_ptp_ts_2,
    input  wire [PTP_TS_W-1:0] rx_ptp_ts_2,
    // ---- port 3 clocks / resets ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk_3 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_tx_3:m_axis_tx_cpl_3, ASSOCIATED_RESET tx_aresetn_3" *)
    output wire         tx_clk_3,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 tx_aresetn_3 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output wire         tx_aresetn_3,
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk_3 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF m_axis_rx_3, ASSOCIATED_RESET rx_aresetn_3" *)
    output wire         rx_clk_3,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_aresetn_3 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    output wire         rx_aresetn_3,
    // ---- m_axis_rx_3 (rx_clk_3): tuser[0] bad frame @tlast, tuser[PTP_TS_W:1] RX ts; no tready ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_3 TDATA" *)
    output wire [15:0]  m_axis_rx_3_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_3 TKEEP" *)
    output wire [1:0]   m_axis_rx_3_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_3 TVALID" *)
    output wire         m_axis_rx_3_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_3 TLAST" *)
    output wire         m_axis_rx_3_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_rx_3 TUSER" *)
    output wire [PTP_TS_W:0] m_axis_rx_3_tuser,
    // ---- s_axis_tx_3 (tx_clk_3): tuser[0] = send as bad frame; tid = ts tag ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_3 TDATA" *)
    input  wire [15:0]  s_axis_tx_3_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_3 TKEEP" *)
    input  wire [1:0]   s_axis_tx_3_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_3 TVALID" *)
    input  wire         s_axis_tx_3_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_3 TREADY" *)
    output wire         s_axis_tx_3_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_3 TLAST" *)
    input  wire         s_axis_tx_3_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_3 TUSER" *)
    input  wire [0:0]   s_axis_tx_3_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_tx_3 TID" *)
    input  wire [TX_TAG_W-1:0] s_axis_tx_3_tid,
    // ---- m_axis_tx_cpl_3 (tx_clk_3): TX timestamp (tdata) + tag (tid) per frame; no tready ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_cpl_3 TDATA" *)
    output wire [PTP_TS_W-1:0] m_axis_tx_cpl_3_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_cpl_3 TID" *)
    output wire [TX_TAG_W-1:0] m_axis_tx_cpl_3_tid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_cpl_3 TVALID" *)
    output wire         m_axis_tx_cpl_3_tvalid,
    // ---- port 3 timestamp inputs (PTP_TS_EN; already in tx_clk_3 / rx_clk_3) ----
    input  wire [PTP_TS_W-1:0] tx_ptp_ts_3,
    input  wire [PTP_TS_W-1:0] rx_ptp_ts_3,
    // ---- status (bit n = port n). rx_status / rx_* strobes: rx_clk_n; an_complete /
    //      sgmii_* / tx_* strobes: tx_clk_n; link_up: ctrl_clk ----
    output wire [3:0]   rx_status,
    output wire [3:0]   an_complete,
    output wire [3:0]   sgmii_link,
    output wire [7:0]   sgmii_speed,          // [2n+1:2n]: 00 10M, 01 100M, 10 1G
    output wire [3:0]   sgmii_full_duplex,
    output wire [3:0]   link_up,
    output wire [3:0]   rx_sop,
    output wire [3:0]   rx_stat_pkt_good,
    output wire [3:0]   rx_stat_pkt_bad,
    output wire [3:0]   rx_stat_bad_fcs,
    output wire [3:0]   tx_sop,
    output wire [3:0]   tx_stat_pkt_good,
    output wire [3:0]   tx_stat_err_underflow,
    // ---- PHY management: shared MDIO (plain pins; IOBUF inside), per-PHY reset ----
    output wire         mdc,
    inout  wire         mdio,
    output wire [3:0]   phy_reset_n,
    // ---- s_axi (AXI4-Lite slave, ctrl_clk): regs at +0x0_0000, GT APB at +0x4_0000 ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 19" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
    input  wire [2:0]                    s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire                          s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire                          s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0]                   s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0]                    s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire                          s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire                          s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0]                    s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire                          s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire                          s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
    input  wire [2:0]                    s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire                          s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire                          s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0]                   s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0]                    s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire                          s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire                          s_axi_rready
);

wire [3:0] tx_clk_w, tx_rst_w, rx_clk_w, rx_rst_w;

assign tx_clk_0 = tx_clk_w[0];  assign tx_aresetn_0 = !tx_rst_w[0];
assign tx_clk_1 = tx_clk_w[1];  assign tx_aresetn_1 = !tx_rst_w[1];
assign tx_clk_2 = tx_clk_w[2];  assign tx_aresetn_2 = !tx_rst_w[2];
assign tx_clk_3 = tx_clk_w[3];  assign tx_aresetn_3 = !tx_rst_w[3];
assign rx_clk_0 = rx_clk_w[0];  assign rx_aresetn_0 = !rx_rst_w[0];
assign rx_clk_1 = rx_clk_w[1];  assign rx_aresetn_1 = !rx_rst_w[1];
assign rx_clk_2 = rx_clk_w[2];  assign rx_aresetn_2 = !rx_rst_w[2];
assign rx_clk_3 = rx_clk_w[3];  assign rx_aresetn_3 = !rx_rst_w[3];

pktrec_eth_ports_core #(
    .SIM(SIM),
    .FAMILY(FAMILY),
    .CFG_LOW_LATENCY(CFG_LOW_LATENCY),
    .GT_TX_POLARITY(GT_TX_POLARITY),
    .GT_RX_POLARITY(GT_RX_POLARITY),
    .PTP_TS_EN(PTP_TS_EN),
    .PTP_TS_FMT_TOD(PTP_TS_FMT_TOD),
    .PTP_TS_W(PTP_TS_W),
    .TX_TAG_W(TX_TAG_W),
    .XCVR_RST_DEFAULT(XCVR_RST_DEFAULT),
    .DEFAULT_TX_PAD_EN(DEFAULT_TX_PAD_EN),
    .EXT_TX_IFG(EXT_TX_IFG),
    .MAX_FRAME_LEN(MAX_FRAME_LEN),
    .AXIL_ADDR_W(C_S_AXI_ADDR_WIDTH)
) core_inst (
    .gt_ref_clk_p(gt_ref_clk_clk_p),
    .gt_ref_clk_n(gt_ref_clk_clk_n),
    .gt_txp(gt_gtx_p),
    .gt_txn(gt_gtx_n),
    .gt_rxp(gt_grx_p),
    .gt_rxn(gt_grx_n),
    .ctrl_clk(ctrl_clk),
    .ctrl_rst(!ctrl_aresetn),
    .s_axi_awaddr(s_axi_awaddr),
    .s_axi_awprot(s_axi_awprot),
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
    .s_axi_arprot(s_axi_arprot),
    .s_axi_arvalid(s_axi_arvalid),
    .s_axi_arready(s_axi_arready),
    .s_axi_rdata(s_axi_rdata),
    .s_axi_rresp(s_axi_rresp),
    .s_axi_rvalid(s_axi_rvalid),
    .s_axi_rready(s_axi_rready),
    .tx_clk(tx_clk_w),
    .tx_rst(tx_rst_w),
    .rx_clk(rx_clk_w),
    .rx_rst(rx_rst_w),
    .m_axis_rx_tdata({m_axis_rx_3_tdata, m_axis_rx_2_tdata, m_axis_rx_1_tdata, m_axis_rx_0_tdata}),
    .m_axis_rx_tkeep({m_axis_rx_3_tkeep, m_axis_rx_2_tkeep, m_axis_rx_1_tkeep, m_axis_rx_0_tkeep}),
    .m_axis_rx_tvalid({m_axis_rx_3_tvalid, m_axis_rx_2_tvalid, m_axis_rx_1_tvalid, m_axis_rx_0_tvalid}),
    .m_axis_rx_tlast({m_axis_rx_3_tlast, m_axis_rx_2_tlast, m_axis_rx_1_tlast, m_axis_rx_0_tlast}),
    .m_axis_rx_tuser({m_axis_rx_3_tuser, m_axis_rx_2_tuser, m_axis_rx_1_tuser, m_axis_rx_0_tuser}),
    .s_axis_tx_tdata({s_axis_tx_3_tdata, s_axis_tx_2_tdata, s_axis_tx_1_tdata, s_axis_tx_0_tdata}),
    .s_axis_tx_tkeep({s_axis_tx_3_tkeep, s_axis_tx_2_tkeep, s_axis_tx_1_tkeep, s_axis_tx_0_tkeep}),
    .s_axis_tx_tvalid({s_axis_tx_3_tvalid, s_axis_tx_2_tvalid, s_axis_tx_1_tvalid, s_axis_tx_0_tvalid}),
    .s_axis_tx_tready({s_axis_tx_3_tready, s_axis_tx_2_tready, s_axis_tx_1_tready, s_axis_tx_0_tready}),
    .s_axis_tx_tlast({s_axis_tx_3_tlast, s_axis_tx_2_tlast, s_axis_tx_1_tlast, s_axis_tx_0_tlast}),
    .s_axis_tx_tuser({s_axis_tx_3_tuser, s_axis_tx_2_tuser, s_axis_tx_1_tuser, s_axis_tx_0_tuser}),
    .s_axis_tx_tid({s_axis_tx_3_tid, s_axis_tx_2_tid, s_axis_tx_1_tid, s_axis_tx_0_tid}),
    .m_axis_tx_cpl_tdata({m_axis_tx_cpl_3_tdata, m_axis_tx_cpl_2_tdata, m_axis_tx_cpl_1_tdata, m_axis_tx_cpl_0_tdata}),
    .m_axis_tx_cpl_tid({m_axis_tx_cpl_3_tid, m_axis_tx_cpl_2_tid, m_axis_tx_cpl_1_tid, m_axis_tx_cpl_0_tid}),
    .m_axis_tx_cpl_tvalid({m_axis_tx_cpl_3_tvalid, m_axis_tx_cpl_2_tvalid, m_axis_tx_cpl_1_tvalid, m_axis_tx_cpl_0_tvalid}),
    .tx_ptp_ts({tx_ptp_ts_3, tx_ptp_ts_2, tx_ptp_ts_1, tx_ptp_ts_0}),
    .rx_ptp_ts({rx_ptp_ts_3, rx_ptp_ts_2, rx_ptp_ts_1, rx_ptp_ts_0}),
    .tx_ifg_ext(tx_ifg),
    .rx_status(rx_status),
    .an_complete(an_complete),
    .sgmii_link(sgmii_link),
    .sgmii_speed(sgmii_speed),
    .sgmii_full_duplex(sgmii_full_duplex),
    .link_up(link_up),
    .rx_sop(rx_sop),
    .rx_stat_pkt_good(rx_stat_pkt_good),
    .rx_stat_pkt_bad(rx_stat_pkt_bad),
    .rx_stat_bad_fcs(rx_stat_bad_fcs),
    .tx_sop(tx_sop),
    .tx_stat_pkt_good(tx_stat_pkt_good),
    .tx_stat_err_underflow(tx_stat_err_underflow),
    .mdc(mdc),
    .mdio(mdio),
    .phy_reset_n(phy_reset_n)
);

endmodule
