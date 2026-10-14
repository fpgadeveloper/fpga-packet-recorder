// SPDX-License-Identifier: MIT
//
// pktrec_eth_ports_core - 4-port 1G SGMII MAC/PCS for the Ethernet FMC Max (OP080):
// Taxi taxi_eth_mac_1g_basex_us (CNT = 4, GTH, one quad) + Taxi MDIO master + an
// AXI4-Lite register block + the Taxi transceiver-control APB space.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.
//
// Clock domains
//   ctrl_clk     s_axi, register block, MDIO master, Taxi xcvr_ctrl_clk (GT DRP / APB /
//                reset sequencers). Any free-running clock 62.5..125 MHz.
//   tx_clk[n]    TXUSRCLK2 of lane n, 62.5 MHz from the QPLL (125 MHz FMC refclk).
//                s_axis_tx_n, m_axis_tx_cpl_n, tx_ptp_ts_n, AN status, tx_stat_* are here.
//   rx_clk[n]    RXUSRCLK2 of lane n = the lane's recovered clock (62.5 MHz +-100 ppm).
//                m_axis_rx_n, rx_ptp_ts_n, rx_status, rx_stat_* are here.
//
// s_axi map (byte offsets; 0x0_0000..0x3_FFFF local, 0x4_0000..0x7_FFFF transceiver APB)
//   0x000 ID           RO  0x504B5245 ("PKRE")
//   0x004 VERSION      RO  0x00010001 (1.1: TX/RX_MAX_LEN reset from MAX_FRAME_LEN, 1522)
//   0x008 GCTRL        RW  [0] xcvr_rst (1 = hold all GTs/QPLL in reset; reset value
//                          XCVR_RST_DEFAULT)  [11:8] phy_reset_n[3:0] (reset value 4'hF)
//   0x00C GSTATUS      RO  [0] gtpowergood [1] qpll0 lock [2] qpll1 lock
//                          [7:4] link_up[3:0] (rx_status & an_complete & sgmii link)
//   0x010 MDIO_CMD     WO  [31:30]=01 [29:28] op (01 write, 10 read) [27:23] phy addr
//                          [22:18] reg addr [15:0] write data - writing issues the frame
//   0x014 MDIO_RDATA   RO  [15:0] data of the last completed read
//   0x018 MDIO_STATUS  RO  [0] busy [1] read data valid [2] command dropped
//   0x01C MDIO_DIV     RW  [7:0] MDC half-period in ctrl_clk cycles minus 1 (reset 49)
//   per port n at 0x100 + n * 0x40:
//   +0x00 CTRL         RW  [0] tx_enable (1) [1] rx_enable (1) [2] tx_pad_en (DEFAULT_TX_PAD_EN)
//                          [3] an_en (1) [4] an_restart (level; write 1 then 0)
//                          [5] an_sgmii_en (1 = force SGMII) [6] an_sgmii_auto (1)
//                          [8] gt_tx_rst (re-reset TX lane) [9] gt_rx_rst (re-reset RX lane)
//   +0x04 STATUS       RO  [0] rx_status (PCS sync) [1] an_complete [2] an_running
//                          [3] an_timeout [4] an_sgmii_mode [5] lp_sgmii_link
//                          [7:6] lp_sgmii_speed (00 10M, 01 100M, 10 1G) [8] full duplex
//                          [9] tx_rst_out [10] rx_rst_out [11] link_up
//   +0x08 LP_ADV       RO  [15:0] an_lp_adv_ability (SGMII config word from the PHY)
//   +0x0C STICKY       W1C [0] link went down [1] rx bad FCS [2] rx bad frame
//                          [3] tx underflow [4] an interrupt
//   +0x10 TX_IFG       RW  [7:0] (12); not used when EXT_TX_IFG = 1 (the MAC then takes
//                          tx_ifg_ext, the dynamic IFG of pktrec_m0_path, M3)
//   +0x14 TX_MAX_LEN   RW  [15:0] max frame length incl. FCS, minus 1 (MAX_FRAME_LEN - 1 =
//                          1521): longer frames are cut and sent error-terminated
//   +0x18 RX_MAX_LEN   RW  [15:0] max frame length incl. FCS, minus 1 (MAX_FRAME_LEN - 1 =
//                          1521): longer frames are delivered in full but flagged bad
//                          (tuser[0], RX_BAD / STICKY[2]); Taxi has no VLAN allowance of
//                          its own, so the reset value 1522 covers one 802.1Q tag.
//                          Raise both (up to 16383) for jumbo frames; keep the m0 path's
//                          IFG_LO above the largest frame (pktrec-phy maxlen does both)
//   +0x1C TX_MIN_LEN   RW  [7:0] min frame length excl. FCS, minus 1 (59; used when tx_pad_en)
//   0x4_0000 + n * 0x1_0000: Taxi GT control registers of lane n (16-bit APB, 32-bit
//   accesses; see taxi_eth_phy_25g_us_gt_apb). One AXI transaction at a time.
//
// Config registers cross into tx_clk / rx_clk through taxi_sync_signal: they are
// quasi-static; change them while the port is idle (tx/rx disabled).
// The bare MAC has no address filter (always "promiscuous"), strips the FCS on RX,
// appends it on TX, and RX has no back-pressure (no tready).

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_eth_ports_core #(
    parameter logic        SIM               = 1'b0,
    parameter string       FAMILY            = "zynquplus",
    parameter logic        CFG_LOW_LATENCY   = 1'b1,
    parameter logic [3:0]  GT_TX_POLARITY    = 4'b0000,
    parameter logic [3:0]  GT_RX_POLARITY    = 4'b0000,
    parameter logic        PTP_TS_EN         = 1'b1,
    parameter logic        PTP_TS_FMT_TOD    = 1'b0,
    parameter int          PTP_TS_W          = PTP_TS_FMT_TOD ? 96 : 64,
    parameter int          TX_TAG_W          = 8,
    parameter logic        XCVR_RST_DEFAULT  = 1'b0,
    parameter logic        DEFAULT_TX_PAD_EN = 1'b1,
    parameter logic        EXT_TX_IFG        = 1'b0,
    parameter int          MAX_FRAME_LEN     = 1522,   // TX/RX_MAX_LEN reset, bytes incl. FCS
    parameter int          AXIL_ADDR_W       = 19
)(
    // GT reference clock (125 MHz) and serial lanes
    input  wire logic                     gt_ref_clk_p,
    input  wire logic                     gt_ref_clk_n,
    output wire logic [3:0]               gt_txp,
    output wire logic [3:0]               gt_txn,
    input  wire logic [3:0]               gt_rxp,
    input  wire logic [3:0]               gt_rxn,

    // control clock / reset
    input  wire logic                     ctrl_clk,
    input  wire logic                     ctrl_rst,

    // AXI4-Lite slave (ctrl_clk)
    input  wire logic [AXIL_ADDR_W-1:0]   s_axi_awaddr,
    input  wire logic [2:0]               s_axi_awprot,
    input  wire logic                     s_axi_awvalid,
    output wire logic                     s_axi_awready,
    input  wire logic [31:0]              s_axi_wdata,
    input  wire logic [3:0]               s_axi_wstrb,
    input  wire logic                     s_axi_wvalid,
    output wire logic                     s_axi_wready,
    output wire logic [1:0]               s_axi_bresp,
    output wire logic                     s_axi_bvalid,
    input  wire logic                     s_axi_bready,
    input  wire logic [AXIL_ADDR_W-1:0]   s_axi_araddr,
    input  wire logic [2:0]               s_axi_arprot,
    input  wire logic                     s_axi_arvalid,
    output wire logic                     s_axi_arready,
    output wire logic [31:0]              s_axi_rdata,
    output wire logic [1:0]               s_axi_rresp,
    output wire logic                     s_axi_rvalid,
    input  wire logic                     s_axi_rready,

    // MAC clocks / resets (active high, synchronous to their clock)
    output wire logic [3:0]               tx_clk,
    output wire logic [3:0]               tx_rst,
    output wire logic [3:0]               rx_clk,
    output wire logic [3:0]               rx_rst,

    // RX streams (rx_clk[n]); 16-bit, tkeep 2-bit; tuser[0] = bad frame (on tlast),
    // tuser[PTP_TS_W:1] = RX timestamp (PTP_TS_EN). No tready.
    output wire logic [4*16-1:0]          m_axis_rx_tdata,
    output wire logic [4*2-1:0]           m_axis_rx_tkeep,
    output wire logic [3:0]               m_axis_rx_tvalid,
    output wire logic [3:0]               m_axis_rx_tlast,
    output wire logic [4*(1+PTP_TS_W)-1:0] m_axis_rx_tuser,

    // TX streams (tx_clk[n]); tuser[0] = send as bad frame; tid = timestamp tag
    input  wire logic [4*16-1:0]          s_axis_tx_tdata,
    input  wire logic [4*2-1:0]           s_axis_tx_tkeep,
    input  wire logic [3:0]               s_axis_tx_tvalid,
    output wire logic [3:0]               s_axis_tx_tready,
    input  wire logic [3:0]               s_axis_tx_tlast,
    input  wire logic [3:0]               s_axis_tx_tuser,
    input  wire logic [4*TX_TAG_W-1:0]    s_axis_tx_tid,

    // TX completion (tx_clk[n]): TX timestamp + tag, one per frame. No tready.
    output wire logic [4*PTP_TS_W-1:0]    m_axis_tx_cpl_tdata,
    output wire logic [4*TX_TAG_W-1:0]    m_axis_tx_cpl_tid,
    output wire logic [3:0]               m_axis_tx_cpl_tvalid,

    // timestamp inputs (already in tx_clk[n] / rx_clk[n])
    input  wire logic [4*PTP_TS_W-1:0]    tx_ptp_ts,
    input  wire logic [4*PTP_TS_W-1:0]    rx_ptp_ts,

    // TX inter-frame gap per port (EXT_TX_IFG = 1; tx_clk[n], [8n+7:8n] bytes)
    input  wire logic [4*8-1:0]           tx_ifg_ext,

    // status (native domains: rx_status rx_clk[n]; an_* / sgmii_* tx_clk[n]; link_up ctrl_clk)
    output wire logic [3:0]               rx_status,
    output wire logic [3:0]               an_complete,
    output wire logic [3:0]               sgmii_link,
    output wire logic [4*2-1:0]           sgmii_speed,
    output wire logic [3:0]               sgmii_full_duplex,
    output wire logic [3:0]               link_up,

    // per-frame strobes
    output wire logic [3:0]               rx_sop,
    output wire logic [3:0]               rx_stat_pkt_good,
    output wire logic [3:0]               rx_stat_pkt_bad,
    output wire logic [3:0]               rx_stat_bad_fcs,
    output wire logic [3:0]               tx_sop,
    output wire logic [3:0]               tx_stat_pkt_good,
    output wire logic [3:0]               tx_stat_err_underflow,

    // PHY management
    output wire logic                     mdc,
    inout  wire logic                     mdio,
    output wire logic [3:0]               phy_reset_n
);

localparam int CNT = 4;
localparam int APB_ADDR_W = 18;
localparam logic [31:0] REG_ID      = 32'h504B5245;
localparam logic [31:0] REG_VERSION = 32'h00010001;

// ============================================================================
// Registers (ctrl_clk)
// ============================================================================
logic        gctrl_xcvr_rst_reg = XCVR_RST_DEFAULT;
logic [3:0]  gctrl_phy_rstn_reg = 4'hF;
logic [9:0]  pctrl_reg      [CNT];
logic [7:0]  tx_ifg_reg     [CNT];
logic [15:0] tx_max_len_reg [CNT];
logic [15:0] rx_max_len_reg [CNT];
logic [7:0]  tx_min_len_reg [CNT];
logic [4:0]  sticky_reg     [CNT];

localparam logic [15:0] MAX_LEN_DEFAULT = 16'(MAX_FRAME_LEN - 1);
localparam logic [9:0] PCTRL_DEFAULT = {1'b0, 1'b0, 1'b0, 1'b1, 1'b1, 1'b0, 1'b1, DEFAULT_TX_PAD_EN, 1'b1, 1'b1};

initial begin
    for (int i = 0; i < CNT; i++) begin
        pctrl_reg[i] = PCTRL_DEFAULT;
        tx_ifg_reg[i] = 8'd12;
        tx_max_len_reg[i] = MAX_LEN_DEFAULT;
        rx_max_len_reg[i] = MAX_LEN_DEFAULT;
        tx_min_len_reg[i] = 8'd59;
        sticky_reg[i] = '0;
    end
end

logic [7:0]  mdio_div_reg       = 8'd49;
logic [31:0] mdio_cmd_reg       = '0;
logic        mdio_cmd_valid_reg = 1'b0;
logic [15:0] mdio_rdata_reg     = '0;
logic        mdio_rd_valid_reg  = 1'b0;
logic        mdio_cmd_drop_reg  = 1'b0;

wire xcvr_rst_any = gctrl_xcvr_rst_reg || ctrl_rst;

assign phy_reset_n = gctrl_phy_rstn_reg;

// ============================================================================
// GT reference clock
// ============================================================================
wire gt_refclk;

if (SIM) begin : refclk
    assign gt_refclk = gt_ref_clk_p;
end else begin : refclk
    IBUFDS_GTE4 ibufds_gte4_refclk_inst (
        .I     (gt_ref_clk_p),
        .IB    (gt_ref_clk_n),
        .CEB   (1'b0),
        .O     (gt_refclk),
        .ODIV2 ()
    );
end

// ============================================================================
// Taxi quad 1G BASE-X / SGMII MAC + PCS + GTH
// ============================================================================
taxi_apb_if #(.ADDR_W(APB_ADDR_W), .DATA_W(16)) apb_adapter();   // adapter -> filter
taxi_apb_if #(.ADDR_W(APB_ADDR_W), .DATA_W(16)) apb_gt();        // filter -> wrapper

taxi_axis_if #(.DATA_W(16), .ID_EN(1), .ID_W(TX_TAG_W), .USER_EN(1), .USER_W(1)) axis_tx[CNT]();
taxi_axis_if #(.DATA_W(PTP_TS_W), .KEEP_W(1), .ID_EN(1), .ID_W(TX_TAG_W)) axis_tx_cpl[CNT]();
taxi_axis_if #(.DATA_W(16), .USER_EN(1), .USER_W(1+(PTP_TS_EN ? PTP_TS_W : 0))) axis_rx[CNT]();
taxi_axis_if #(.DATA_W(16), .KEEP_W(1), .KEEP_EN(0), .LAST_EN(0), .USER_EN(1), .USER_W(1), .ID_EN(1), .ID_W(10)) axis_stat();

wire        mac_txp[CNT], mac_txn[CNT], mac_rxp[CNT], mac_rxn[CNT];
wire        mac_tx_clk[CNT], mac_tx_rst[CNT], mac_rx_clk[CNT], mac_rx_rst[CNT];
wire        gt_tx_rst_in[CNT], gt_rx_rst_in[CNT];
wire        an_en_s[CNT], an_restart_s[CNT], an_sgmii_en_s[CNT], an_sgmii_auto_s[CNT];
wire        an_intr_w[CNT], an_running_w[CNT], an_complete_w[CNT], an_timeout_w[CNT], an_sgmii_mode_w[CNT];
wire [15:0] an_lp_adv_w[CNT];
wire        an_lp_link_w[CNT], an_res_fd_w[CNT];
wire [1:0]  an_lp_speed_w[CNT];
wire [PTP_TS_W-1:0] tx_ts_in_w[CNT], rx_ts_in_w[CNT];
wire [1:0]  tx_start_packet_w[CNT], rx_start_packet_w[CNT];
wire        rx_status_w[CNT];
wire        stat_rx_good_w[CNT], stat_rx_bad_w[CNT], stat_rx_fcs_w[CNT];
wire        stat_tx_good_w[CNT], stat_tx_unf_w[CNT];
wire        cfg_tx_pad_en_s[CNT], cfg_tx_en_s[CNT], cfg_rx_en_s[CNT];
wire [7:0]  cfg_tx_ifg_s[CNT], cfg_tx_min_s[CNT];
wire [15:0] cfg_tx_max_s[CNT], cfg_rx_max_s[CNT];

wire gtpowergood, qpll0_lock, qpll1_lock;

taxi_eth_mac_1g_basex_us #(
    .SIM(SIM),
    .VENDOR("XILINX"),
    .FAMILY(FAMILY),
    .CNT(CNT),
    .CFG_LOW_LATENCY(CFG_LOW_LATENCY),
    .GT_TYPE("GTH"),
    .QPLL0_PD(1'b0),
    .QPLL1_PD(1'b1),
    .GT_TX_POLARITY(GT_TX_POLARITY),
    .GT_RX_POLARITY(GT_RX_POLARITY),
    // LPM receive equaliser on all lanes (Taxi default is DFE). 1.25 Gb/s SGMII over
    // a few cm of FMC trace is a low-loss channel: the M1 bench (m1_bench.md) saw
    // intermittent 10b code-group bit errors (up to 60 % bad FCS) in DFE mode on all
    // ports and clean lanes for > 1 h with RXLPMEN = 1 set live through the GT APB.
    .GT_RX_LPM_EN(4'b1111),
    .COMBINED_MAC_PCS(1'b1),
    .SGMII_EN(1'b1),
    .AN_EN(1'b1),
    // No deficit idle count: every TX gap is at least cfg_tx_ifg (12 B). With DIC the
    // MAC sends cfg_tx_ifg - 1 = 11 B after an odd-length frame when the next frame is
    // already waiting (the TAP forward FIFO feeds it back-to-back), and the DP83867
    // loses frames on the copper side after gaps < 12 B (bench D, 2026-10-14). Without
    // DIC the gap after an odd-length frame is 13 B (the 16-bit datapath starts a
    // frame in lane 0 only).
    .DIC_EN(1'b0),
    .PTP_TS_EN(PTP_TS_EN),
    .PTP_TD_EN(1'b0),
    .PTP_TS_FMT_TOD(PTP_TS_FMT_TOD),
    .PTP_TS_W(PTP_TS_W),
    .PRBS31_EN(1'b0),
    .TX_SERDES_PIPELINE(1),
    .RX_SERDES_PIPELINE(1),
    .PFC_EN(1'b0),
    .PAUSE_EN(1'b0),
    .STAT_EN(1'b0)
)
mac_inst (
    .xcvr_ctrl_clk(ctrl_clk),
    .xcvr_ctrl_rst(xcvr_rst_any),
    .s_apb_ctrl(apb_gt),

    .xcvr_gtpowergood_out(gtpowergood),
    .xcvr_gtrefclk00_in(gt_refclk),
    .xcvr_qpll0pd_in(1'b0),
    .xcvr_qpll0reset_in(1'b0),
    .xcvr_qpll0pcierate_in(3'd0),
    .xcvr_qpll0lock_out(qpll0_lock),
    .xcvr_qpll0clk_out(),
    .xcvr_qpll0refclk_out(),
    .xcvr_gtrefclk01_in(gt_refclk),
    .xcvr_qpll1pd_in(1'b1),
    .xcvr_qpll1reset_in(1'b0),
    .xcvr_qpll1pcierate_in(3'd0),
    .xcvr_qpll1lock_out(qpll1_lock),
    .xcvr_qpll1clk_out(),
    .xcvr_qpll1refclk_out(),

    .xcvr_txp(mac_txp),
    .xcvr_txn(mac_txn),
    .xcvr_rxp(mac_rxp),
    .xcvr_rxn(mac_rxn),

    .rx_clk(mac_rx_clk),
    .rx_rst_in(gt_rx_rst_in),
    .rx_rst_out(mac_rx_rst),
    .tx_clk(mac_tx_clk),
    .tx_rst_in(gt_tx_rst_in),
    .tx_rst_out(mac_tx_rst),

    .s_axis_tx(axis_tx),
    .m_axis_tx_cpl(axis_tx_cpl),
    .m_axis_rx(axis_rx),

    .an_en(an_en_s),
    .an_restart(an_restart_s),
    .an_speedup('{CNT{1'b0}}),
    .an_timeout_en('{CNT{1'b1}}),
    .an_sgmii_en(an_sgmii_en_s),
    .an_sgmii_auto(an_sgmii_auto_s),
    .an_intr(an_intr_w),
    .an_running(an_running_w),
    .an_complete(an_complete_w),
    .an_timeout(an_timeout_w),
    .an_sgmii_mode(an_sgmii_mode_w),
    .an_adv_ability_basex('{CNT{16'h0020}}),
    .an_adv_ability_sgmii('{CNT{16'h0001}}),
    .an_lp_adv_ability(an_lp_adv_w),
    .an_lp_remote_fault(),
    .an_lp_sgmii_link(an_lp_link_w),
    .an_lp_sgmii_speed(an_lp_speed_w),
    .an_res_full_duplex(an_res_fd_w),
    .an_res_tx_pause(),
    .an_res_rx_pause(),

    .ptp_clk(1'b0),
    .ptp_rst(1'b0),
    .ptp_sample_clk(1'b0),
    .ptp_td_sdi(1'b0),
    .tx_ptp_ts_in(tx_ts_in_w),
    .tx_ptp_ts_out(),
    .tx_ptp_ts_step_out(),
    .tx_ptp_locked(),
    .rx_ptp_ts_in(rx_ts_in_w),
    .rx_ptp_ts_out(),
    .rx_ptp_ts_step_out(),
    .rx_ptp_locked(),

    .tx_lfc_req('{CNT{1'b0}}),
    .tx_lfc_resend('{CNT{1'b0}}),
    .rx_lfc_en('{CNT{1'b0}}),
    .rx_lfc_req(),
    .rx_lfc_ack('{CNT{1'b0}}),
    .tx_pfc_req('{CNT{8'd0}}),
    .tx_pfc_resend('{CNT{1'b0}}),
    .rx_pfc_en('{CNT{8'd0}}),
    .rx_pfc_req(),
    .rx_pfc_ack('{CNT{8'd0}}),
    .tx_lfc_pause_en('{CNT{1'b0}}),
    .tx_pause_req('{CNT{1'b0}}),
    .tx_pause_ack(),

    .stat_clk(ctrl_clk),
    .stat_rst(ctrl_rst),
    .m_axis_stat(axis_stat),

    .tx_start_packet(tx_start_packet_w),
    .stat_tx_byte(),
    .stat_tx_pkt_len(),
    .stat_tx_pkt_ucast(),
    .stat_tx_pkt_mcast(),
    .stat_tx_pkt_bcast(),
    .stat_tx_pkt_vlan(),
    .stat_tx_pkt_good(stat_tx_good_w),
    .stat_tx_pkt_bad(),
    .stat_tx_pad_frame(),
    .stat_tx_err_oversize(),
    .stat_tx_err_user(),
    .stat_tx_err_underflow(stat_tx_unf_w),
    .rx_start_packet(rx_start_packet_w),
    .rx_error_count(),
    .rx_block_lock(),
    .rx_high_ber(),
    .rx_status(rx_status_w),
    .stat_rx_byte(),
    .stat_rx_pkt_len(),
    .stat_rx_pkt_fragment(),
    .stat_rx_pkt_jabber(),
    .stat_rx_pkt_ucast(),
    .stat_rx_pkt_mcast(),
    .stat_rx_pkt_bcast(),
    .stat_rx_pkt_vlan(),
    .stat_rx_pkt_good(stat_rx_good_w),
    .stat_rx_pkt_bad(stat_rx_bad_w),
    .stat_rx_err_oversize(),
    .stat_rx_err_bad_fcs(stat_rx_fcs_w),
    .stat_rx_err_bad_block(),
    .stat_rx_err_framing(),
    .stat_rx_err_preamble(),
    .stat_rx_fifo_drop('{CNT{1'b0}}),
    .stat_tx_mcf(),
    .stat_rx_mcf(),
    .stat_tx_lfc_pkt(),
    .stat_tx_lfc_xon(),
    .stat_tx_lfc_xoff(),
    .stat_tx_lfc_paused(),
    .stat_tx_pfc_pkt(),
    .stat_tx_pfc_xon(),
    .stat_tx_pfc_xoff(),
    .stat_tx_pfc_paused(),
    .stat_rx_lfc_pkt(),
    .stat_rx_lfc_xon(),
    .stat_rx_lfc_xoff(),
    .stat_rx_lfc_paused(),
    .stat_rx_pfc_pkt(),
    .stat_rx_pfc_xon(),
    .stat_rx_pfc_xoff(),
    .stat_rx_pfc_paused(),

    .cfg_tx_pad_en(cfg_tx_pad_en_s),
    .cfg_tx_min_pkt_len(cfg_tx_min_s),
    .cfg_tx_max_pkt_len(cfg_tx_max_s),
    .cfg_tx_ifg(cfg_tx_ifg_s),
    .cfg_tx_enable(cfg_tx_en_s),
    .cfg_rx_max_pkt_len(cfg_rx_max_s),
    .cfg_rx_enable(cfg_rx_en_s),
    .cfg_ifg('{CNT{8'd12}}),
    .cfg_tx_prbs31_enable('{CNT{1'b0}}),
    .cfg_rx_prbs31_enable('{CNT{1'b0}}),
    .cfg_mcf_rx_eth_dst_mcast('{CNT{48'h01_80_C2_00_00_01}}),
    .cfg_mcf_rx_check_eth_dst_mcast('{CNT{1'b1}}),
    .cfg_mcf_rx_eth_dst_ucast('{CNT{48'd0}}),
    .cfg_mcf_rx_check_eth_dst_ucast('{CNT{1'b0}}),
    .cfg_mcf_rx_eth_src('{CNT{48'd0}}),
    .cfg_mcf_rx_check_eth_src('{CNT{1'b0}}),
    .cfg_mcf_rx_eth_type('{CNT{16'h8808}}),
    .cfg_mcf_rx_opcode_lfc('{CNT{16'h0001}}),
    .cfg_mcf_rx_check_opcode_lfc('{CNT{1'b1}}),
    .cfg_mcf_rx_opcode_pfc('{CNT{16'h0101}}),
    .cfg_mcf_rx_check_opcode_pfc('{CNT{1'b1}}),
    .cfg_mcf_rx_forward('{CNT{1'b0}}),
    .cfg_mcf_rx_enable('{CNT{1'b0}}),
    .cfg_tx_lfc_eth_dst('{CNT{48'h01_80_C2_00_00_01}}),
    .cfg_tx_lfc_eth_src('{CNT{48'h80_23_31_43_54_4C}}),
    .cfg_tx_lfc_eth_type('{CNT{16'h8808}}),
    .cfg_tx_lfc_opcode('{CNT{16'h0001}}),
    .cfg_tx_lfc_en('{CNT{1'b0}}),
    .cfg_tx_lfc_quanta('{CNT{16'hffff}}),
    .cfg_tx_lfc_refresh('{CNT{16'h7fff}}),
    .cfg_tx_pfc_eth_dst('{CNT{48'h01_80_C2_00_00_01}}),
    .cfg_tx_pfc_eth_src('{CNT{48'h80_23_31_43_54_4C}}),
    .cfg_tx_pfc_eth_type('{CNT{16'h8808}}),
    .cfg_tx_pfc_opcode('{CNT{16'h0101}}),
    .cfg_tx_pfc_en('{CNT{1'b0}}),
    .cfg_tx_pfc_quanta('{CNT{'{8{16'hffff}}}}),
    .cfg_tx_pfc_refresh('{CNT{'{8{16'h7fff}}}}),
    .cfg_rx_lfc_opcode('{CNT{16'h0001}}),
    .cfg_rx_lfc_en('{CNT{1'b0}}),
    .cfg_rx_pfc_opcode('{CNT{16'h0101}}),
    .cfg_rx_pfc_en('{CNT{1'b0}})
);

assign axis_stat.tready = 1'b1;

// ============================================================================
// Per-port glue: flatten interfaces, CDC of config / status
// ============================================================================
logic [3:0] link_up_ctrl;
wire  [15:0] st_tx_ctrl[CNT];   // tx_clk status, synced to ctrl_clk
wire  [1:0]  st_rx_ctrl[CNT];   // rx_clk status, synced to ctrl_clk
wire  [15:0] lp_adv_ctrl[CNT];
wire  [4:0]  evt_tgl_ctrl[CNT];

for (genvar n = 0; n < CNT; n = n + 1) begin : port

    // serial lanes
    assign gt_txp[n] = mac_txp[n];
    assign gt_txn[n] = mac_txn[n];
    assign mac_rxp[n] = gt_rxp[n];
    assign mac_rxn[n] = gt_rxn[n];

    // clocks / resets
    assign tx_clk[n] = mac_tx_clk[n];
    assign tx_rst[n] = mac_tx_rst[n];
    assign rx_clk[n] = mac_rx_clk[n];
    assign rx_rst[n] = mac_rx_rst[n];

    // GT lane re-reset requests (ctrl_clk; synchronised by the Taxi reset FSMs)
    assign gt_tx_rst_in[n] = pctrl_reg[n][8];
    assign gt_rx_rst_in[n] = pctrl_reg[n][9];

    // TX stream
    assign axis_tx[n].tdata  = s_axis_tx_tdata[16*n +: 16];
    assign axis_tx[n].tkeep  = s_axis_tx_tkeep[2*n +: 2];
    assign axis_tx[n].tstrb  = s_axis_tx_tkeep[2*n +: 2];
    assign axis_tx[n].tvalid = s_axis_tx_tvalid[n];
    assign axis_tx[n].tlast  = s_axis_tx_tlast[n];
    assign axis_tx[n].tuser  = s_axis_tx_tuser[n];
    assign axis_tx[n].tid    = s_axis_tx_tid[TX_TAG_W*n +: TX_TAG_W];
    assign axis_tx[n].tdest  = '0;
    assign s_axis_tx_tready[n] = axis_tx[n].tready;

    // TX completion
    assign m_axis_tx_cpl_tdata[PTP_TS_W*n +: PTP_TS_W] = axis_tx_cpl[n].tdata;
    assign m_axis_tx_cpl_tid[TX_TAG_W*n +: TX_TAG_W]   = axis_tx_cpl[n].tid;
    assign m_axis_tx_cpl_tvalid[n] = axis_tx_cpl[n].tvalid;
    assign axis_tx_cpl[n].tready = 1'b1;

    // RX stream
    assign m_axis_rx_tdata[16*n +: 16] = axis_rx[n].tdata;
    assign m_axis_rx_tkeep[2*n +: 2]   = axis_rx[n].tkeep;
    assign m_axis_rx_tvalid[n]         = axis_rx[n].tvalid;
    assign m_axis_rx_tlast[n]          = axis_rx[n].tlast;
    if (PTP_TS_EN) begin : rx_user_ts
        assign m_axis_rx_tuser[(1+PTP_TS_W)*n +: (1+PTP_TS_W)] = axis_rx[n].tuser;
    end else begin : rx_user_nots
        assign m_axis_rx_tuser[(1+PTP_TS_W)*n +: (1+PTP_TS_W)] = {{PTP_TS_W{1'b0}}, axis_rx[n].tuser[0]};
    end
    assign axis_rx[n].tready = 1'b1;

    // timestamps
    assign tx_ts_in_w[n] = tx_ptp_ts[PTP_TS_W*n +: PTP_TS_W];
    assign rx_ts_in_w[n] = rx_ptp_ts[PTP_TS_W*n +: PTP_TS_W];

    // status out (native domains)
    assign rx_status[n]          = rx_status_w[n];
    assign an_complete[n]        = an_complete_w[n];
    assign sgmii_link[n]         = an_lp_link_w[n];
    assign sgmii_speed[2*n +: 2] = an_lp_speed_w[n];
    assign sgmii_full_duplex[n]  = an_res_fd_w[n];
    assign rx_sop[n]             = |rx_start_packet_w[n];
    assign tx_sop[n]             = |tx_start_packet_w[n];
    assign rx_stat_pkt_good[n]   = stat_rx_good_w[n];
    assign rx_stat_pkt_bad[n]    = stat_rx_bad_w[n];
    assign rx_stat_bad_fcs[n]    = stat_rx_fcs_w[n];
    assign tx_stat_pkt_good[n]   = stat_tx_good_w[n];
    assign tx_stat_err_underflow[n] = stat_tx_unf_w[n];

    // ---- config -> tx_clk ----
    wire [38:0] tx_cfg_s;
    taxi_sync_signal #(.WIDTH(39), .N(2)) tx_cfg_sync_inst (
        .clk(mac_tx_clk[n]),
        .in({pctrl_reg[n][6:0], tx_ifg_reg[n], tx_max_len_reg[n], tx_min_len_reg[n]}),
        .out(tx_cfg_s)
    );
    assign cfg_tx_min_s[n]    = tx_cfg_s[7:0];
    assign cfg_tx_max_s[n]    = tx_cfg_s[23:8];
    assign cfg_tx_ifg_s[n]    = EXT_TX_IFG ? tx_ifg_ext[8*n +: 8] : tx_cfg_s[31:24];
    assign cfg_tx_en_s[n]     = tx_cfg_s[32];
    assign cfg_tx_pad_en_s[n] = tx_cfg_s[34];
    assign an_en_s[n]         = tx_cfg_s[35];
    assign an_restart_s[n]    = tx_cfg_s[36];
    assign an_sgmii_en_s[n]   = tx_cfg_s[37];
    assign an_sgmii_auto_s[n] = tx_cfg_s[38];

    // ---- config -> rx_clk ----
    wire [16:0] rx_cfg_s;
    taxi_sync_signal #(.WIDTH(17), .N(2)) rx_cfg_sync_inst (
        .clk(mac_rx_clk[n]),
        .in({pctrl_reg[n][1], rx_max_len_reg[n]}),
        .out(rx_cfg_s)
    );
    assign cfg_rx_en_s[n]  = rx_cfg_s[16];
    assign cfg_rx_max_s[n] = rx_cfg_s[15:0];

    // ---- event toggles (source domains) ----
    logic rx_fcs_tgl_reg = 1'b0, rx_bad_tgl_reg = 1'b0;
    logic tx_unf_tgl_reg = 1'b0, an_intr_tgl_reg = 1'b0;
    always_ff @(posedge mac_rx_clk[n]) begin
        if (stat_rx_fcs_w[n]) rx_fcs_tgl_reg <= !rx_fcs_tgl_reg;
        if (stat_rx_bad_w[n]) rx_bad_tgl_reg <= !rx_bad_tgl_reg;
    end
    always_ff @(posedge mac_tx_clk[n]) begin
        if (stat_tx_unf_w[n]) tx_unf_tgl_reg <= !tx_unf_tgl_reg;
        if (an_intr_w[n])     an_intr_tgl_reg <= !an_intr_tgl_reg;
    end

    // ---- status -> ctrl_clk ----
    // register the tx_clk-domain status first: Taxi decodes an_lp_sgmii_* combinationally
    // and a synchroniser must be fed from a flop (CDC-10)
    logic [15:0] st_tx_reg = '0;
    always_ff @(posedge mac_tx_clk[n]) begin
        st_tx_reg <= {6'd0, an_res_fd_w[n], an_lp_speed_w[n], an_lp_link_w[n], an_sgmii_mode_w[n],
                      an_timeout_w[n], an_running_w[n], an_complete_w[n], mac_tx_rst[n], 1'b0};
    end
    taxi_sync_signal #(.WIDTH(16), .N(2)) st_tx_sync_inst (
        .clk(ctrl_clk),
        .in(st_tx_reg),
        .out(st_tx_ctrl[n])
    );
    taxi_sync_signal #(.WIDTH(2), .N(2)) st_rx_sync_inst (
        .clk(ctrl_clk),
        .in({mac_rx_rst[n], rx_status_w[n]}),
        .out(st_rx_ctrl[n])
    );
    taxi_sync_signal #(.WIDTH(16), .N(2)) lp_adv_sync_inst (
        .clk(ctrl_clk),
        .in(an_lp_adv_w[n]),
        .out(lp_adv_ctrl[n])
    );
    taxi_sync_signal #(.WIDTH(5), .N(3)) evt_sync_inst (
        .clk(ctrl_clk),
        .in({an_intr_tgl_reg, tx_unf_tgl_reg, rx_bad_tgl_reg, rx_fcs_tgl_reg, 1'b0}),
        .out(evt_tgl_ctrl[n])
    );

    assign link_up_ctrl[n] = st_rx_ctrl[n][0] && st_tx_ctrl[n][2] && st_tx_ctrl[n][6];
end

assign link_up = link_up_ctrl;

// ============================================================================
// MDIO master (Taxi), shared bus to the four DP83867s
// ============================================================================
taxi_axis_if #(.DATA_W(32)) axis_mdio_cmd();
taxi_axis_if #(.DATA_W(16)) axis_mdio_rd();

wire mdio_busy;

assign axis_mdio_cmd.tdata  = mdio_cmd_reg;
assign axis_mdio_cmd.tkeep  = '1;
assign axis_mdio_cmd.tstrb  = '1;
assign axis_mdio_cmd.tvalid = mdio_cmd_valid_reg;
assign axis_mdio_cmd.tlast  = 1'b1;
assign axis_mdio_cmd.tid    = '0;
assign axis_mdio_cmd.tdest  = '0;
assign axis_mdio_cmd.tuser  = '0;
assign axis_mdio_rd.tready  = 1'b1;

wire mdio_i, mdio_o, mdio_t;

if (SIM) begin : mdio_buf
    assign mdio = mdio_t ? 1'bz : mdio_o;
    assign mdio_i = mdio;
end else begin : mdio_buf
    // explicit IOBUF: an inferred tristate on an inout port of an out-of-context
    // module reference loses its input side
    IOBUF mdio_iobuf (
        .IO(mdio),
        .I(mdio_o),
        .O(mdio_i),
        .T(mdio_t)
    );
end

taxi_mdio_master mdio_master_inst (
    .clk(ctrl_clk),
    .rst(ctrl_rst),
    .s_axis_cmd(axis_mdio_cmd),
    .m_axis_rd_data(axis_mdio_rd),
    .mdc_o(mdc),
    .mdio_i(mdio_i),
    .mdio_o(mdio_o),
    .mdio_t(mdio_t),
    .busy(mdio_busy),
    .prescale(mdio_div_reg)
);

// ============================================================================
// APB filter (adapter -> wrapper): see zircon_cmac_us_core. (a) writes with
// pstrb == 0 complete locally (Taxi GT APB regs ignore pstrb); (b) while the
// transceivers are held in reset (and 32 cycles after) every transfer completes
// locally with SLVERR (the wrapper's APB interconnect would never answer).
// ============================================================================
logic [4:0] apb_ok_cnt_reg = '0;
wire  apb_ok = &apb_ok_cnt_reg;

always_ff @(posedge ctrl_clk) begin
    if (!apb_ok) begin
        apb_ok_cnt_reg <= apb_ok_cnt_reg + 1;
    end
    if (xcvr_rst_any) begin
        apb_ok_cnt_reg <= '0;
    end
end

logic apb_blk_reg = 1'b0;
logic apb_err_reg = 1'b0;
wire  apb_setup = apb_adapter.psel && !apb_adapter.penable;
wire  apb_err_now = !apb_ok;
wire  apb_blk_now = apb_err_now || (apb_adapter.pwrite && apb_adapter.pstrb == '0);
wire  apb_blk = apb_setup ? apb_blk_now : apb_blk_reg;
wire  apb_err = apb_setup ? apb_err_now : apb_err_reg;

always_ff @(posedge ctrl_clk) begin
    if (apb_setup) begin
        apb_blk_reg <= apb_blk_now;
        apb_err_reg <= apb_err_now;
    end
end

assign apb_gt.paddr   = apb_adapter.paddr;
assign apb_gt.pprot   = apb_adapter.pprot;
assign apb_gt.psel    = apb_adapter.psel && !apb_blk;
assign apb_gt.penable = apb_adapter.penable && !apb_blk;
assign apb_gt.pwrite  = apb_adapter.pwrite;
assign apb_gt.pwdata  = apb_adapter.pwdata;
assign apb_gt.pstrb   = apb_adapter.pstrb;
assign apb_gt.pauser  = '0;
assign apb_gt.pwuser  = '0;

assign apb_adapter.pready  = apb_blk ? 1'b1 : apb_gt.pready;
assign apb_adapter.prdata  = apb_blk ? '0 : apb_gt.prdata;
assign apb_adapter.pslverr = apb_blk ? apb_err : apb_gt.pslverr;
assign apb_adapter.pruser  = '0;
assign apb_adapter.pbuser  = '0;

// ============================================================================
// AXI4-Lite front end: local registers or the APB adapter, one transaction at a time
// ============================================================================
taxi_axil_if #(.DATA_W(32), .ADDR_W(APB_ADDR_W)) axil_apb();

taxi_axil_apb_adapter apb_adapter_inst (
    .clk(ctrl_clk),
    .rst(ctrl_rst),
    .s_axil_wr(axil_apb),
    .s_axil_rd(axil_apb),
    .m_apb(apb_adapter)
);

typedef enum logic [2:0] {
    AX_IDLE, AX_WR_APB, AX_WR_APB_B, AX_RD_APB, AX_RD_APB_R, AX_RD_LOCAL, AX_WR_RESP, AX_RD_RESP
} ax_state_t;

ax_state_t ax_state_reg = AX_IDLE;

logic [AXIL_ADDR_W-1:0] ax_addr_reg = '0;
logic [31:0] ax_wdata_reg = '0;
logic [3:0]  ax_wstrb_reg = '0;
logic [2:0]  ax_prot_reg = '0;

logic        s_axi_awready_reg = 1'b0;
logic        s_axi_wready_reg = 1'b0;
logic        s_axi_bvalid_reg = 1'b0;
logic [1:0]  s_axi_bresp_reg = 2'b00;
logic        s_axi_arready_reg = 1'b0;
logic        s_axi_rvalid_reg = 1'b0;
logic [1:0]  s_axi_rresp_reg = 2'b00;
logic [31:0] s_axi_rdata_reg = '0;

logic        apb_aw_done_reg = 1'b0;
logic        apb_w_done_reg = 1'b0;

assign s_axi_awready = s_axi_awready_reg;
assign s_axi_wready  = s_axi_wready_reg;
assign s_axi_bresp   = s_axi_bresp_reg;
assign s_axi_bvalid  = s_axi_bvalid_reg;
assign s_axi_arready = s_axi_arready_reg;
assign s_axi_rdata   = s_axi_rdata_reg;
assign s_axi_rresp   = s_axi_rresp_reg;
assign s_axi_rvalid  = s_axi_rvalid_reg;

assign axil_apb.awaddr  = ax_addr_reg[APB_ADDR_W-1:0];
assign axil_apb.awprot  = ax_prot_reg;
assign axil_apb.awuser  = '0;
assign axil_apb.awvalid = ax_state_reg == AX_WR_APB && !apb_aw_done_reg;
assign axil_apb.wdata   = ax_wdata_reg;
assign axil_apb.wstrb   = ax_wstrb_reg;
assign axil_apb.wuser   = '0;
assign axil_apb.wvalid  = ax_state_reg == AX_WR_APB && !apb_w_done_reg;
assign axil_apb.bready  = ax_state_reg == AX_WR_APB_B;
assign axil_apb.araddr  = ax_addr_reg[APB_ADDR_W-1:0];
assign axil_apb.arprot  = ax_prot_reg;
assign axil_apb.aruser  = '0;
assign axil_apb.arvalid = ax_state_reg == AX_RD_APB;
assign axil_apb.rready  = ax_state_reg == AX_RD_APB_R;

// global status into ctrl_clk
wire gtpowergood_s, qpll0_lock_s, qpll1_lock_s;
taxi_sync_signal #(.WIDTH(3), .N(2)) gst_sync_inst (
    .clk(ctrl_clk),
    .in({qpll1_lock, qpll0_lock, gtpowergood}),
    .out({qpll1_lock_s, qpll0_lock_s, gtpowergood_s})
);

// local register read mux (ax_addr_reg[17:0])
wire [1:0] rd_port = ax_addr_reg[7:6];
wire       rd_is_port = ax_addr_reg[17:8] == 10'd1;
logic [31:0] reg_rdata;
always_comb begin
    reg_rdata = '0;
    if (ax_addr_reg[17:8] == '0) begin
        case (ax_addr_reg[7:2])
            6'h00: reg_rdata = REG_ID;
            6'h01: reg_rdata = REG_VERSION;
            6'h02: reg_rdata = {20'd0, gctrl_phy_rstn_reg, 7'd0, gctrl_xcvr_rst_reg};
            6'h03: reg_rdata = {24'd0, link_up_ctrl, 1'b0, qpll1_lock_s, qpll0_lock_s, gtpowergood_s};
            6'h04: reg_rdata = mdio_cmd_reg;
            6'h05: reg_rdata = {16'd0, mdio_rdata_reg};
            6'h06: reg_rdata = {29'd0, mdio_cmd_drop_reg, mdio_rd_valid_reg, mdio_busy | mdio_cmd_valid_reg};
            6'h07: reg_rdata = {24'd0, mdio_div_reg};
            default: reg_rdata = '0;
        endcase
    end else if (rd_is_port) begin
        case (ax_addr_reg[5:2])
            4'h0: reg_rdata = {22'd0, pctrl_reg[rd_port]};
            4'h1: reg_rdata = {20'd0, link_up_ctrl[rd_port], st_rx_ctrl[rd_port][1], st_tx_ctrl[rd_port][1],
                               st_tx_ctrl[rd_port][9], st_tx_ctrl[rd_port][8:7], st_tx_ctrl[rd_port][6],
                               st_tx_ctrl[rd_port][5], st_tx_ctrl[rd_port][4], st_tx_ctrl[rd_port][3],
                               st_tx_ctrl[rd_port][2], st_rx_ctrl[rd_port][0]};
            4'h2: reg_rdata = {16'd0, lp_adv_ctrl[rd_port]};
            4'h3: reg_rdata = {27'd0, sticky_reg[rd_port]};
            4'h4: reg_rdata = {24'd0, tx_ifg_reg[rd_port]};
            4'h5: reg_rdata = {16'd0, tx_max_len_reg[rd_port]};
            4'h6: reg_rdata = {16'd0, rx_max_len_reg[rd_port]};
            4'h7: reg_rdata = {24'd0, tx_min_len_reg[rd_port]};
            default: reg_rdata = '0;
        endcase
    end
end

// event edge detect -> sticky
logic [4:0] evt_last_reg [CNT];
logic [CNT-1:0] link_last_reg = '0;
initial for (int i = 0; i < CNT; i++) evt_last_reg[i] = '0;

wire [1:0] wr_port = s_axi_awaddr[7:6];

always_ff @(posedge ctrl_clk) begin
    s_axi_awready_reg <= 1'b0;
    s_axi_wready_reg <= 1'b0;
    s_axi_arready_reg <= 1'b0;

    if (mdio_cmd_valid_reg && axis_mdio_cmd.tready) begin
        mdio_cmd_valid_reg <= 1'b0;
    end
    if (axis_mdio_rd.tvalid) begin
        mdio_rdata_reg    <= axis_mdio_rd.tdata;
        mdio_rd_valid_reg <= 1'b1;
    end

    for (int i = 0; i < CNT; i++) begin
        evt_last_reg[i] <= evt_tgl_ctrl[i];
        link_last_reg[i] <= link_up_ctrl[i];
        if (link_last_reg[i] && !link_up_ctrl[i]) sticky_reg[i][0] <= 1'b1;
        for (int b = 1; b < 5; b++) begin
            if (evt_tgl_ctrl[i][b] != evt_last_reg[i][b]) sticky_reg[i][b] <= 1'b1;
        end
    end

    case (ax_state_reg)
        AX_IDLE: begin
            if (s_axi_awvalid && s_axi_wvalid && !s_axi_awready_reg) begin
                s_axi_awready_reg <= 1'b1;
                s_axi_wready_reg <= 1'b1;
                ax_addr_reg <= s_axi_awaddr;
                ax_prot_reg <= s_axi_awprot;
                ax_wdata_reg <= s_axi_wdata;
                ax_wstrb_reg <= s_axi_wstrb;
                apb_aw_done_reg <= 1'b0;
                apb_w_done_reg <= 1'b0;
                if (s_axi_awaddr[18]) begin
                    ax_state_reg <= AX_WR_APB;
                end else begin
                    if (s_axi_awaddr[17:8] == '0) begin
                        case (s_axi_awaddr[7:2])
                            6'h02: begin
                                if (s_axi_wstrb[0]) gctrl_xcvr_rst_reg <= s_axi_wdata[0];
                                if (s_axi_wstrb[1]) gctrl_phy_rstn_reg <= s_axi_wdata[11:8];
                            end
                            6'h04: begin
                                if (!mdio_cmd_valid_reg || axis_mdio_cmd.tready) begin
                                    mdio_cmd_reg       <= {s_axi_wdata[31:18], 2'b10, s_axi_wdata[15:0]};
                                    mdio_cmd_valid_reg <= 1'b1;
                                    mdio_rd_valid_reg  <= 1'b0;
                                    mdio_cmd_drop_reg  <= 1'b0;
                                end else begin
                                    mdio_cmd_drop_reg  <= 1'b1;
                                end
                            end
                            6'h07: if (s_axi_wstrb[0]) mdio_div_reg <= s_axi_wdata[7:0];
                            default: ;
                        endcase
                    end else if (s_axi_awaddr[17:8] == 10'd1) begin
                        case (s_axi_awaddr[5:2])
                            4'h0: pctrl_reg[wr_port] <= s_axi_wdata[9:0];
                            4'h3: sticky_reg[wr_port] <= sticky_reg[wr_port] & ~s_axi_wdata[4:0];
                            4'h4: tx_ifg_reg[wr_port] <= s_axi_wdata[7:0];
                            4'h5: tx_max_len_reg[wr_port] <= s_axi_wdata[15:0];
                            4'h6: rx_max_len_reg[wr_port] <= s_axi_wdata[15:0];
                            4'h7: tx_min_len_reg[wr_port] <= s_axi_wdata[7:0];
                            default: ;
                        endcase
                    end
                    s_axi_bresp_reg <= 2'b00;
                    s_axi_bvalid_reg <= 1'b1;
                    ax_state_reg <= AX_WR_RESP;
                end
            end else if (s_axi_arvalid && !s_axi_arready_reg) begin
                s_axi_arready_reg <= 1'b1;
                ax_addr_reg <= s_axi_araddr;
                ax_prot_reg <= s_axi_arprot;
                if (s_axi_araddr[18]) begin
                    ax_state_reg <= AX_RD_APB;
                end else begin
                    ax_state_reg <= AX_RD_LOCAL;
                end
            end
        end
        AX_WR_APB: begin
            if (axil_apb.awready) apb_aw_done_reg <= 1'b1;
            if (axil_apb.wready)  apb_w_done_reg <= 1'b1;
            if ((apb_aw_done_reg || axil_apb.awready) && (apb_w_done_reg || axil_apb.wready)) begin
                ax_state_reg <= AX_WR_APB_B;
            end
        end
        AX_WR_APB_B: begin
            if (axil_apb.bvalid) begin
                s_axi_bresp_reg <= axil_apb.bresp;
                s_axi_bvalid_reg <= 1'b1;
                ax_state_reg <= AX_WR_RESP;
            end
        end
        AX_RD_APB: begin
            if (axil_apb.arready) begin
                ax_state_reg <= AX_RD_APB_R;
            end
        end
        AX_RD_APB_R: begin
            if (axil_apb.rvalid) begin
                s_axi_rdata_reg <= axil_apb.rdata;
                s_axi_rresp_reg <= axil_apb.rresp;
                s_axi_rvalid_reg <= 1'b1;
                ax_state_reg <= AX_RD_RESP;
            end
        end
        AX_RD_LOCAL: begin
            s_axi_rdata_reg <= reg_rdata;
            s_axi_rresp_reg <= 2'b00;
            s_axi_rvalid_reg <= 1'b1;
            ax_state_reg <= AX_RD_RESP;
        end
        AX_WR_RESP: begin
            if (s_axi_bready) begin
                s_axi_bvalid_reg <= 1'b0;
                ax_state_reg <= AX_IDLE;
            end
        end
        AX_RD_RESP: begin
            if (s_axi_rready) begin
                s_axi_rvalid_reg <= 1'b0;
                ax_state_reg <= AX_IDLE;
            end
        end
        default: ax_state_reg <= AX_IDLE;
    endcase

    if (ctrl_rst) begin
        ax_state_reg <= AX_IDLE;
        s_axi_awready_reg <= 1'b0;
        s_axi_wready_reg <= 1'b0;
        s_axi_bvalid_reg <= 1'b0;
        s_axi_arready_reg <= 1'b0;
        s_axi_rvalid_reg <= 1'b0;
        gctrl_xcvr_rst_reg <= XCVR_RST_DEFAULT;
        gctrl_phy_rstn_reg <= 4'hF;
        mdio_div_reg <= 8'd49;
        mdio_cmd_valid_reg <= 1'b0;
        mdio_rd_valid_reg <= 1'b0;
        mdio_cmd_drop_reg <= 1'b0;
        link_last_reg <= '0;
        for (int i = 0; i < CNT; i++) begin
            pctrl_reg[i] <= PCTRL_DEFAULT;
            tx_ifg_reg[i] <= 8'd12;
            tx_max_len_reg[i] <= MAX_LEN_DEFAULT;
            rx_max_len_reg[i] <= MAX_LEN_DEFAULT;
            tx_min_len_reg[i] <= 8'd59;
            sticky_reg[i] <= '0;
            evt_last_reg[i] <= evt_tgl_ctrl[i];
        end
    end
end

endmodule

`resetall
