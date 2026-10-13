// SPDX-License-Identifier: MIT
//
// pktrec_m0_path - M0 bring-up datapath for the 4-port Ethernet subsystem
// (block-design module reference, next to pktrec_eth_ports in hierarchy eth_ports).
//
// Per port n the TX MAC input is selected by PATH_CTRL (pktrec_m0_regs):
//   0 IDLE  nothing is sent
//   1 LOOP  port n's own RX frames             (RX n -> TX n)
//   2 FWD   the pair partner's RX frames        (RX n^1 -> TX n; P0<->P1, P2<->P3 = TAP)
//   3       reserved (= IDLE)
// Each (TX port, source) pair has its own store-and-forward async frame FIFO
// (pktrec_axis_async_fifo, rx_clk[src] -> tx_clk[n], 4 KB): 8 FIFOs in total. A FIFO
// is written only while its source is selected (decided at the first beat of every
// frame, so frames are never cut); frames that do not fit are dropped whole and
// counted. Frames marked bad by the RX MAC (tuser[0] at tlast) are forwarded with
// tuser set, so the TX MAC sends them with an error (TAP fidelity). The TX side
// switches source only between frames; a FIFO that is not selected is drained.
// The MAC strips the FCS on RX and the TX MAC regenerates it; the MAC's own TX
// padding must be off (pktrec_eth_ports DEFAULT_TX_PAD_EN = 0) for faithful runts.
//
// Capture tap (M1): m_axis_mon_n is a plain copy (wires) of RX stream n for the
// capture path (pktrec_capture); the RX stream has no back-pressure, so the
// fan-out costs nothing and the forward path is unaffected.
//
// Timestamps: the MAC's tx_ptp_ts_n / rx_ptp_ts_n come from the shared timebase
// in pktrec_capture (M1); the M0 placeholder counters are gone.
//
// Counters and PHY GPIO / power-good levels: see pktrec_m0_regs.v and
// include/pktrec_regs.h.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module pktrec_m0_path #(
    parameter PTP_TS_W   = 64,
    parameter TX_TAG_W   = 8,
    parameter FIFO_DEPTH = 4096,     // bytes per FIFO
    parameter C_S_AXI_ADDR_WIDTH = 12
)(
    // ---- control clock / reset (s_axi, counters) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 ctrl_clk CLK" *)
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF s_axi, ASSOCIATED_RESET ctrl_aresetn" *)
    input  wire                ctrl_clk,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 ctrl_aresetn RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                ctrl_aresetn,
    // ---- port 0: RX stream from the MAC (rx_clk_0, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk_0 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_rx_0:m_axis_mon_0, ASSOCIATED_RESET rx_aresetn_0" *)
    input  wire                rx_clk_0,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_aresetn_0 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                rx_aresetn_0,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_0 TDATA" *)
    input  wire [15:0]         s_axis_rx_0_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_0 TKEEP" *)
    input  wire [1:0]          s_axis_rx_0_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_0 TVALID" *)
    input  wire                s_axis_rx_0_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_0 TLAST" *)
    input  wire                s_axis_rx_0_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_0 TUSER" *)
    input  wire [PTP_TS_W:0]   s_axis_rx_0_tuser,
    // ---- port 0: TX stream to the MAC (tx_clk_0) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk_0 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF m_axis_tx_0, ASSOCIATED_RESET tx_aresetn_0" *)
    input  wire                tx_clk_0,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 tx_aresetn_0 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                tx_aresetn_0,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_0 TDATA" *)
    output wire [15:0]         m_axis_tx_0_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_0 TKEEP" *)
    output wire [1:0]          m_axis_tx_0_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_0 TVALID" *)
    output wire                m_axis_tx_0_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_0 TREADY" *)
    input  wire                m_axis_tx_0_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_0 TLAST" *)
    output wire                m_axis_tx_0_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_0 TUSER" *)
    output wire [0:0]          m_axis_tx_0_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_0 TID" *)
    output wire [TX_TAG_W-1:0] m_axis_tx_0_tid,
    // ---- port 0: copy of the RX stream for the capture path (rx_clk_0, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_0 TDATA" *)
    output wire [15:0]         m_axis_mon_0_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_0 TKEEP" *)
    output wire [1:0]          m_axis_mon_0_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_0 TVALID" *)
    output wire                m_axis_mon_0_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_0 TLAST" *)
    output wire                m_axis_mon_0_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_0 TUSER" *)
    output wire [PTP_TS_W:0]   m_axis_mon_0_tuser,
    // ---- port 1: RX stream from the MAC (rx_clk_1, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk_1 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_rx_1:m_axis_mon_1, ASSOCIATED_RESET rx_aresetn_1" *)
    input  wire                rx_clk_1,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_aresetn_1 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                rx_aresetn_1,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_1 TDATA" *)
    input  wire [15:0]         s_axis_rx_1_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_1 TKEEP" *)
    input  wire [1:0]          s_axis_rx_1_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_1 TVALID" *)
    input  wire                s_axis_rx_1_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_1 TLAST" *)
    input  wire                s_axis_rx_1_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_1 TUSER" *)
    input  wire [PTP_TS_W:0]   s_axis_rx_1_tuser,
    // ---- port 1: TX stream to the MAC (tx_clk_1) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk_1 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF m_axis_tx_1, ASSOCIATED_RESET tx_aresetn_1" *)
    input  wire                tx_clk_1,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 tx_aresetn_1 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                tx_aresetn_1,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_1 TDATA" *)
    output wire [15:0]         m_axis_tx_1_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_1 TKEEP" *)
    output wire [1:0]          m_axis_tx_1_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_1 TVALID" *)
    output wire                m_axis_tx_1_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_1 TREADY" *)
    input  wire                m_axis_tx_1_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_1 TLAST" *)
    output wire                m_axis_tx_1_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_1 TUSER" *)
    output wire [0:0]          m_axis_tx_1_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_1 TID" *)
    output wire [TX_TAG_W-1:0] m_axis_tx_1_tid,
    // ---- port 1: copy of the RX stream for the capture path (rx_clk_1, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_1 TDATA" *)
    output wire [15:0]         m_axis_mon_1_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_1 TKEEP" *)
    output wire [1:0]          m_axis_mon_1_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_1 TVALID" *)
    output wire                m_axis_mon_1_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_1 TLAST" *)
    output wire                m_axis_mon_1_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_1 TUSER" *)
    output wire [PTP_TS_W:0]   m_axis_mon_1_tuser,
    // ---- port 2: RX stream from the MAC (rx_clk_2, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk_2 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_rx_2:m_axis_mon_2, ASSOCIATED_RESET rx_aresetn_2" *)
    input  wire                rx_clk_2,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_aresetn_2 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                rx_aresetn_2,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_2 TDATA" *)
    input  wire [15:0]         s_axis_rx_2_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_2 TKEEP" *)
    input  wire [1:0]          s_axis_rx_2_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_2 TVALID" *)
    input  wire                s_axis_rx_2_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_2 TLAST" *)
    input  wire                s_axis_rx_2_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_2 TUSER" *)
    input  wire [PTP_TS_W:0]   s_axis_rx_2_tuser,
    // ---- port 2: TX stream to the MAC (tx_clk_2) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk_2 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF m_axis_tx_2, ASSOCIATED_RESET tx_aresetn_2" *)
    input  wire                tx_clk_2,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 tx_aresetn_2 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                tx_aresetn_2,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_2 TDATA" *)
    output wire [15:0]         m_axis_tx_2_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_2 TKEEP" *)
    output wire [1:0]          m_axis_tx_2_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_2 TVALID" *)
    output wire                m_axis_tx_2_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_2 TREADY" *)
    input  wire                m_axis_tx_2_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_2 TLAST" *)
    output wire                m_axis_tx_2_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_2 TUSER" *)
    output wire [0:0]          m_axis_tx_2_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_2 TID" *)
    output wire [TX_TAG_W-1:0] m_axis_tx_2_tid,
    // ---- port 2: copy of the RX stream for the capture path (rx_clk_2, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_2 TDATA" *)
    output wire [15:0]         m_axis_mon_2_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_2 TKEEP" *)
    output wire [1:0]          m_axis_mon_2_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_2 TVALID" *)
    output wire                m_axis_mon_2_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_2 TLAST" *)
    output wire                m_axis_mon_2_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_2 TUSER" *)
    output wire [PTP_TS_W:0]   m_axis_mon_2_tuser,
    // ---- port 3: RX stream from the MAC (rx_clk_3, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 rx_clk_3 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF s_axis_rx_3:m_axis_mon_3, ASSOCIATED_RESET rx_aresetn_3" *)
    input  wire                rx_clk_3,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 rx_aresetn_3 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                rx_aresetn_3,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_3 TDATA" *)
    input  wire [15:0]         s_axis_rx_3_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_3 TKEEP" *)
    input  wire [1:0]          s_axis_rx_3_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_3 TVALID" *)
    input  wire                s_axis_rx_3_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_3 TLAST" *)
    input  wire                s_axis_rx_3_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 s_axis_rx_3 TUSER" *)
    input  wire [PTP_TS_W:0]   s_axis_rx_3_tuser,
    // ---- port 3: TX stream to the MAC (tx_clk_3) ----
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 tx_clk_3 CLK" *)
    (* X_INTERFACE_PARAMETER = "FREQ_HZ 62500000, ASSOCIATED_BUSIF m_axis_tx_3, ASSOCIATED_RESET tx_aresetn_3" *)
    input  wire                tx_clk_3,
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 tx_aresetn_3 RST" *)
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    input  wire                tx_aresetn_3,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_3 TDATA" *)
    output wire [15:0]         m_axis_tx_3_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_3 TKEEP" *)
    output wire [1:0]          m_axis_tx_3_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_3 TVALID" *)
    output wire                m_axis_tx_3_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_3 TREADY" *)
    input  wire                m_axis_tx_3_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_3 TLAST" *)
    output wire                m_axis_tx_3_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_3 TUSER" *)
    output wire [0:0]          m_axis_tx_3_tuser,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_tx_3 TID" *)
    output wire [TX_TAG_W-1:0] m_axis_tx_3_tid,
    // ---- port 3: copy of the RX stream for the capture path (rx_clk_3, no tready) ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_3 TDATA" *)
    output wire [15:0]         m_axis_mon_3_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_3 TKEEP" *)
    output wire [1:0]          m_axis_mon_3_tkeep,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_3 TVALID" *)
    output wire                m_axis_mon_3_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_3 TLAST" *)
    output wire                m_axis_mon_3_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 m_axis_mon_3 TUSER" *)
    output wire [PTP_TS_W:0]   m_axis_mon_3_tuser,
    // ---- MAC status strobes (bit n = port n; rx_* in rx_clk_n, tx_* in tx_clk_n) ----
    input  wire [3:0]          rx_stat_pkt_good,
    input  wire [3:0]          rx_stat_pkt_bad,
    input  wire [3:0]          tx_stat_pkt_good,
    input  wire [3:0]          tx_stat_err_underflow,
    input  wire [3:0]          link_up,               // ctrl_clk
    // ---- OP080 pins (asynchronous inputs): PHY GPIO_0 / GPIO_1 per port, power good ----
    input  wire [3:0]          phy_gpio0,
    input  wire [3:0]          phy_gpio1,
    input  wire                pg_1v0,
    input  wire                pg_2v5,
    // ---- s_axi (AXI4-Lite slave, ctrl_clk), register map include/pktrec_regs.h ----
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    (* X_INTERFACE_PARAMETER = "PROTOCOL AXI4LITE, DATA_WIDTH 32, ADDR_WIDTH 12" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWPROT" *)
    input  wire [2:0]          s_axi_awprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire                s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire                s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0]         s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0]          s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire                s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire                s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0]          s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire                s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire                s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARPROT" *)
    input  wire [2:0]          s_axi_arprot,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire                s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire                s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0]         s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0]          s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire                s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire                s_axi_rready
);

// ---------------------------------------------------------------------------
// Flatten the per-port ports (index n = port n)
// ---------------------------------------------------------------------------
wire [3:0]  rx_clk    = {rx_clk_3, rx_clk_2, rx_clk_1, rx_clk_0};
wire [3:0]  rx_rst    = ~{rx_aresetn_3, rx_aresetn_2, rx_aresetn_1, rx_aresetn_0};
wire [63:0] rx_tdata  = {s_axis_rx_3_tdata, s_axis_rx_2_tdata, s_axis_rx_1_tdata, s_axis_rx_0_tdata};
wire [7:0]  rx_tkeep  = {s_axis_rx_3_tkeep, s_axis_rx_2_tkeep, s_axis_rx_1_tkeep, s_axis_rx_0_tkeep};
wire [3:0]  rx_tvalid = {s_axis_rx_3_tvalid, s_axis_rx_2_tvalid, s_axis_rx_1_tvalid, s_axis_rx_0_tvalid};
wire [3:0]  rx_tlast  = {s_axis_rx_3_tlast, s_axis_rx_2_tlast, s_axis_rx_1_tlast, s_axis_rx_0_tlast};
wire [3:0]  rx_tbad   = {s_axis_rx_3_tuser[0], s_axis_rx_2_tuser[0], s_axis_rx_1_tuser[0], s_axis_rx_0_tuser[0]};

wire [3:0]  tx_clk    = {tx_clk_3, tx_clk_2, tx_clk_1, tx_clk_0};
wire [3:0]  tx_rst    = ~{tx_aresetn_3, tx_aresetn_2, tx_aresetn_1, tx_aresetn_0};
wire [3:0]  tx_tready = {m_axis_tx_3_tready, m_axis_tx_2_tready, m_axis_tx_1_tready, m_axis_tx_0_tready};
wire [63:0] tx_tdata;
wire [7:0]  tx_tkeep;
wire [3:0]  tx_tvalid, tx_tlast, tx_tuser;

assign {m_axis_tx_3_tdata, m_axis_tx_2_tdata, m_axis_tx_1_tdata, m_axis_tx_0_tdata} = tx_tdata;
assign {m_axis_tx_3_tkeep, m_axis_tx_2_tkeep, m_axis_tx_1_tkeep, m_axis_tx_0_tkeep} = tx_tkeep;
assign {m_axis_tx_3_tvalid, m_axis_tx_2_tvalid, m_axis_tx_1_tvalid, m_axis_tx_0_tvalid} = tx_tvalid;
assign {m_axis_tx_3_tlast, m_axis_tx_2_tlast, m_axis_tx_1_tlast, m_axis_tx_0_tlast} = tx_tlast;
assign {m_axis_tx_3_tuser, m_axis_tx_2_tuser, m_axis_tx_1_tuser, m_axis_tx_0_tuser} = tx_tuser;
assign m_axis_tx_0_tid = {TX_TAG_W{1'b0}};
assign m_axis_tx_1_tid = {TX_TAG_W{1'b0}};
assign m_axis_tx_2_tid = {TX_TAG_W{1'b0}};
assign m_axis_tx_3_tid = {TX_TAG_W{1'b0}};

// capture tap: plain copies of the RX streams
assign {m_axis_mon_3_tdata, m_axis_mon_2_tdata, m_axis_mon_1_tdata, m_axis_mon_0_tdata} =
       {s_axis_rx_3_tdata, s_axis_rx_2_tdata, s_axis_rx_1_tdata, s_axis_rx_0_tdata};
assign {m_axis_mon_3_tkeep, m_axis_mon_2_tkeep, m_axis_mon_1_tkeep, m_axis_mon_0_tkeep} =
       {s_axis_rx_3_tkeep, s_axis_rx_2_tkeep, s_axis_rx_1_tkeep, s_axis_rx_0_tkeep};
assign {m_axis_mon_3_tvalid, m_axis_mon_2_tvalid, m_axis_mon_1_tvalid, m_axis_mon_0_tvalid} =
       {s_axis_rx_3_tvalid, s_axis_rx_2_tvalid, s_axis_rx_1_tvalid, s_axis_rx_0_tvalid};
assign {m_axis_mon_3_tlast, m_axis_mon_2_tlast, m_axis_mon_1_tlast, m_axis_mon_0_tlast} =
       {s_axis_rx_3_tlast, s_axis_rx_2_tlast, s_axis_rx_1_tlast, s_axis_rx_0_tlast};
assign {m_axis_mon_3_tuser, m_axis_mon_2_tuser, m_axis_mon_1_tuser, m_axis_mon_0_tuser} =
       {s_axis_rx_3_tuser, s_axis_rx_2_tuser, s_axis_rx_1_tuser, s_axis_rx_0_tuser};

// ---------------------------------------------------------------------------
// Control / status
// ---------------------------------------------------------------------------
wire [7:0]  path_mode;          // ctrl_clk, [2n+1:2n] = mode of TX port n
wire [31:0] mode_rx_all;        // path_mode synchronised into rx_clk[n]: [8n+7:8n]
wire [31:0] mode_tx_all;        // path_mode synchronised into tx_clk[n]: [8n+7:8n]
wire [23:0] evt_tgl;            // event toggles, [6n+i] (i: see pktrec_m0_regs)
wire [7:0]  fifo_drop;          // FIFO f drop strobe (rx_clk of its source)

// FIFO f = 2*n + k: TX port n = f/2, k = 0 LOOP (source n), k = 1 FWD (source n^1)
wire [8*16-1:0] f_tdata;
wire [8*2-1:0]  f_tkeep;
wire [7:0]      f_tvalid, f_tready, f_tlast, f_tuser;

genvar n, f;

generate
for (f = 0; f < 8; f = f + 1) begin : g_fifo
    localparam integer DST  = f / 2;
    localparam integer KIND = f % 2;
    localparam integer SRC  = KIND ? (DST ^ 1) : DST;

    // write gate (rx_clk[SRC]): the source is sampled at the first beat of each frame
    wire want = (mode_rx_all[8*SRC + 2*DST +: 2] == (KIND ? 2'd2 : 2'd1));
    reg  in_frame = 1'b0;
    reg  en_frame = 1'b0;
    wire gate = in_frame ? en_frame : want;
    reg  drop_tgl = 1'b0;

    always @(posedge rx_clk[SRC]) begin
        if (rx_tvalid[SRC]) begin
            if (!in_frame) en_frame <= want;
            in_frame <= !rx_tlast[SRC];
        end
        if (fifo_drop[f]) drop_tgl <= !drop_tgl;
        if (rx_rst[SRC]) begin
            in_frame <= 1'b0;
            en_frame <= 1'b0;
        end
    end

    pktrec_axis_async_fifo #(
        .DEPTH(FIFO_DEPTH),
        .RAM_PIPELINE(2)
    ) fifo_inst (
        .s_clk(rx_clk[SRC]),
        .s_rst(rx_rst[SRC]),
        .s_tdata(rx_tdata[16*SRC +: 16]),
        .s_tkeep(rx_tkeep[2*SRC +: 2]),
        .s_tvalid(rx_tvalid[SRC] && gate),
        .s_tready(),
        .s_tlast(rx_tlast[SRC]),
        .s_tuser(rx_tbad[SRC]),
        .m_clk(tx_clk[DST]),
        .m_rst(tx_rst[DST]),
        .m_tdata(f_tdata[16*f +: 16]),
        .m_tkeep(f_tkeep[2*f +: 2]),
        .m_tvalid(f_tvalid[f]),
        .m_tready(f_tready[f]),
        .m_tlast(f_tlast[f]),
        .m_tuser(f_tuser[f]),
        .s_drop(fifo_drop[f]),
        .s_good()
    );

    // drop events: DROP_LOOP of port DST (k = 0) / DROP_FWD of port DST (k = 1)
    assign evt_tgl[6*DST + 4 + KIND] = drop_tgl;
end

for (n = 0; n < 4; n = n + 1) begin : g_port
    // path_mode into this port's clocks (quasi-static; Taxi sync constraints)
    taxi_sync_signal #(.WIDTH(8), .N(2)) mode_rx_sync_inst (
        .clk(rx_clk[n]), .in(path_mode), .out(mode_rx_all[8*n +: 8]));
    taxi_sync_signal #(.WIDTH(8), .N(2)) mode_tx_sync_inst (
        .clk(tx_clk[n]), .in(path_mode), .out(mode_tx_all[8*n +: 8]));

    // ---- TX source select (tx_clk[n]) ----
    wire [1:0] tmode  = mode_tx_all[8*n + 2*n +: 2];
    wire [1:0] target = (tmode == 2'd3) ? 2'd0 : tmode;
    reg  [1:0] sel = 2'd0;          // 0 none, 1 LOOP FIFO (2n), 2 FWD FIFO (2n+1)
    reg  [1:0] fin = 2'b00;         // FIFO output is inside a frame
    wire [1:0] hs = {f_tvalid[2*n+1] && f_tready[2*n+1], f_tvalid[2*n] && f_tready[2*n]};

    assign f_tready[2*n]   = (sel == 2'd1) ? tx_tready[n] : 1'b1;   // unselected: drain
    assign f_tready[2*n+1] = (sel == 2'd2) ? tx_tready[n] : 1'b1;
    assign tx_tvalid[n] = (sel == 2'd1) ? f_tvalid[2*n] : (sel == 2'd2) ? f_tvalid[2*n+1] : 1'b0;
    assign tx_tdata[16*n +: 16] = (sel == 2'd2) ? f_tdata[16*(2*n+1) +: 16] : f_tdata[16*(2*n) +: 16];
    assign tx_tkeep[2*n +: 2]   = (sel == 2'd2) ? f_tkeep[2*(2*n+1) +: 2]  : f_tkeep[2*(2*n) +: 2];
    assign tx_tlast[n]          = (sel == 2'd2) ? f_tlast[2*n+1] : f_tlast[2*n];
    assign tx_tuser[n]          = (sel == 2'd2) ? f_tuser[2*n+1] : f_tuser[2*n];

    always @(posedge tx_clk[n]) begin
        if (hs[0]) fin[0] <= !f_tlast[2*n];
        if (hs[1]) fin[1] <= !f_tlast[2*n+1];
        // change source only when neither FIFO output is inside a frame
        if (hs == 2'b00 && fin == 2'b00) sel <= target;
        if (tx_rst[n]) begin
            sel <= 2'd0;
            fin <= 2'b00;
        end
    end

    // ---- event toggles (source domains) ----
    reg rx_good_tgl = 1'b0, rx_bad_tgl = 1'b0, tx_good_tgl = 1'b0, tx_unf_tgl = 1'b0;
    always @(posedge rx_clk[n]) begin
        if (rx_stat_pkt_good[n]) rx_good_tgl <= !rx_good_tgl;
        if (rx_stat_pkt_bad[n])  rx_bad_tgl  <= !rx_bad_tgl;
    end
    always @(posedge tx_clk[n]) begin
        if (tx_stat_pkt_good[n])      tx_good_tgl <= !tx_good_tgl;
        if (tx_stat_err_underflow[n]) tx_unf_tgl  <= !tx_unf_tgl;
    end
    assign evt_tgl[6*n + 0] = rx_good_tgl;
    assign evt_tgl[6*n + 1] = rx_bad_tgl;
    assign evt_tgl[6*n + 2] = tx_good_tgl;
    assign evt_tgl[6*n + 3] = tx_unf_tgl;

end
endgenerate

// ---------------------------------------------------------------------------
// Events and pins into ctrl_clk
// ---------------------------------------------------------------------------
wire [23:0] evt_tgl_s;
reg  [23:0] evt_tgl_d = 24'd0;
taxi_sync_signal #(.WIDTH(24), .N(3)) evt_sync_inst (
    .clk(ctrl_clk), .in(evt_tgl), .out(evt_tgl_s));
always @(posedge ctrl_clk) evt_tgl_d <= evt_tgl_s;
wire [23:0] evt = evt_tgl_s ^ evt_tgl_d;

wire [9:0] io_s;
taxi_sync_signal #(.WIDTH(10), .N(3)) io_sync_inst (
    .clk(ctrl_clk), .in({pg_2v5, pg_1v0, phy_gpio1, phy_gpio0}), .out(io_s));

pktrec_m0_regs #(
    .C_S_AXI_ADDR_WIDTH(C_S_AXI_ADDR_WIDTH)
) regs_inst (
    .clk(ctrl_clk),
    .resetn(ctrl_aresetn),
    .evt(evt),
    .io(io_s),
    .link_up(link_up),
    .path_mode(path_mode),
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
