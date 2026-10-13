// SPDX-License-Identifier: MIT
//
// pktrec_sfd_io - oversampling front end for the eight DP83867 SFD pins
// (OP080: GPIO_0 = RX SFD, GPIO_1 = TX SFD of each PHY, through SN74AVC4T245
// translators, LVCMOS18 inputs in HP banks 67/68).
//
// SAMPLER = "ISERDES" (default): one MMCME4_ADV takes dp_clk (~250 MHz) and
//   makes, from the same VCO (4 x dp_clk), a 2x clock (CLKOUT0, ~500 MHz,
//   BUFGCE) and a 1x clock (CLKOUT1, ~250 MHz, BUFGCE) that are phase-aligned
//   to each other by construction and to dp_clk by the MMCM's feedback
//   compensation (CLKFBOUT -> BUFG -> CLKFBIN). Each pin goes straight from its
//   IBUF into an ISERDESE3 (component mode, DATA_WIDTH 4, DDR on the 2x clock,
//   CLKDIV = the 1x clock, FIFO off): 4 samples per dp_clk cycle, i.e. one
//   sample every ~1.0 ns. (A BUFGCE_DIV for CLKDIV was avoided on purpose: its
//   divided edge can come up on either of the two 2x edges, which would shift
//   the samples by half a dp_clk cycle from one configuration to the next.)
//   The 4-bit words are registered once on the 1x clock and then taken into
//   dp_clk (same frequency, phase-locked: an ordinary timed path).
// SAMPLER = "IDDR": no MMCM; an IDDRE1 per pin on dp_clk (both edges): 2
//   samples per cycle (~2 ns), each duplicated into the 4-bit word.
//
// Output smp[4i+3:4i] (dp_clk): the samples of pin i during one dp_clk period,
// bit 0 = oldest ... bit 3 = newest. The fixed latency from the pin to smp
// (ISERDES + registers, a whole number of dp_clk cycles) is compensated in
// pktrec_sfd_edge (parameter PIPE_NS); the residual constant offset (IBUF,
// clock insertion, translator, PHY) is part of the per-port calibration.
//
// The pins are asynchronous: the first sampling flop (inside the ISERDES) can
// go metastable for the one sample that coincides with an edge; the following
// register stages resolve it, and the edge position is then uncertain by that
// one sample (+-1 ns), which is the resolution anyway.
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_sfd_io #(
    parameter string SAMPLER          = "ISERDES",
    parameter real   DP_CLK_PERIOD_NS = 4.0004,
    parameter int    NPIN             = 8
)(
    input  wire logic              dp_clk,
    input  wire logic              dp_rst,
    input  wire logic [NPIN-1:0]   pin,
    output logic      [NPIN*4-1:0] smp,
    output logic                   locked      // dp_clk domain
);

genvar i;

if (SAMPLER == "ISERDES") begin : g_iserdes

    wire clk_fb, clk_fb_bufg, clk2x_mmcm, clk1x_mmcm, mmcm_locked;
    wire clk2x, clk1x;

    MMCME4_ADV #(
        .BANDWIDTH          ("OPTIMIZED"),
        .COMPENSATION       ("AUTO"),
        .CLKIN1_PERIOD      (DP_CLK_PERIOD_NS),
        .DIVCLK_DIVIDE      (1),
        .CLKFBOUT_MULT_F    (4.000),          // VCO = 4 x dp_clk (~1000 MHz)
        .CLKFBOUT_PHASE     (0.000),
        .CLKOUT0_DIVIDE_F   (2.000),          // 2x (~500 MHz): ISERDES CLK
        .CLKOUT0_PHASE      (0.000),
        .CLKOUT0_DUTY_CYCLE (0.500),
        .CLKOUT1_DIVIDE     (4),              // 1x (~250 MHz): ISERDES CLKDIV + first register
        .CLKOUT1_PHASE      (0.000),
        .CLKOUT1_DUTY_CYCLE (0.500),
        .STARTUP_WAIT       ("FALSE")
    ) mmcm_inst (
        .CLKIN1(dp_clk), .CLKIN2(1'b0), .CLKINSEL(1'b1),
        .CLKFBIN(clk_fb_bufg), .CLKFBOUT(clk_fb), .CLKFBOUTB(),
        .CLKOUT0(clk2x_mmcm), .CLKOUT0B(), .CLKOUT1(clk1x_mmcm), .CLKOUT1B(),
        .CLKOUT2(), .CLKOUT2B(), .CLKOUT3(), .CLKOUT3B(), .CLKOUT4(), .CLKOUT5(), .CLKOUT6(),
        .LOCKED(mmcm_locked), .RST(dp_rst), .PWRDWN(1'b0),
        .DADDR(7'd0), .DCLK(1'b0), .DEN(1'b0), .DI(16'd0), .DWE(1'b0), .DO(), .DRDY(),
        .PSCLK(1'b0), .PSEN(1'b0), .PSINCDEC(1'b0), .PSDONE(),
        .CDDCREQ(1'b0), .CDDCDONE(), .CLKFBSTOPPED(), .CLKINSTOPPED()
    );

    BUFG   bufg_fb  (.I(clk_fb), .O(clk_fb_bufg));
    BUFGCE bufg_2x  (.I(clk2x_mmcm), .CE(1'b1), .O(clk2x));
    BUFGCE bufg_1x  (.I(clk1x_mmcm), .CE(1'b1), .O(clk1x));

    // ISERDES reset: asserted asynchronously, released on clk1x
    (* ASYNC_REG = "TRUE" *) logic [2:0] rst_sr = 3'b111;
    always_ff @(posedge clk1x or negedge mmcm_locked) begin
        if (!mmcm_locked) rst_sr <= 3'b111;
        else              rst_sr <= {rst_sr[1:0], 1'b0};
    end
    wire serdes_rst = rst_sr[2];

    logic [NPIN*4-1:0] q1x = '0;     // clk1x
    for (i = 0; i < NPIN; i = i + 1) begin : g_pin
        wire [7:0] q;
        ISERDESE3 #(
            .DATA_WIDTH        (4),
            .DDR_CLK_EDGE      ("OPPOSITE_EDGE"),
            .FIFO_ENABLE       ("FALSE"),
            .FIFO_SYNC_MODE    ("FALSE"),
            .IDDR_MODE         ("FALSE"),
            .IS_CLK_B_INVERTED (1'b1),
            .IS_CLK_INVERTED   (1'b0),
            .IS_RST_INVERTED   (1'b0),
            .SIM_DEVICE        ("ULTRASCALE_PLUS")
        ) iserdes_inst (
            .CLK(clk2x), .CLK_B(clk2x), .CLKDIV(clk1x), .D(pin[i]),
            .FIFO_RD_CLK(1'b0), .FIFO_RD_EN(1'b0), .RST(serdes_rst),
            .Q(q), .FIFO_EMPTY(), .INTERNAL_DIVCLK()
        );
        // ISERDESE3 4:1 (simulation model): Q[0] is the oldest sample, Q[3] the newest
        always_ff @(posedge clk1x) q1x[4*i +: 4] <= q[3:0];
    end

    always_ff @(posedge dp_clk) smp <= q1x;

    xpm_cdc_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(0))
    cdc_locked (.src_clk(1'b0), .src_in(mmcm_locked && !serdes_rst), .dest_clk(dp_clk), .dest_out(locked));

end else begin : g_iddr

    logic [NPIN*4-1:0] q_r = '0;
    for (i = 0; i < NPIN; i = i + 1) begin : g_pin
        wire q1, q2;
        IDDRE1 #(
            .DDR_CLK_EDGE  ("SAME_EDGE_PIPELINED"),
            .IS_CB_INVERTED(1'b1),
            .IS_C_INVERTED (1'b0)
        ) iddr_inst (
            .C(dp_clk), .CB(dp_clk), .D(pin[i]), .R(1'b0), .Q1(q1), .Q2(q2)
        );
        // SAME_EDGE_PIPELINED: Q1 = rising-edge sample (older), Q2 = falling-edge sample
        always_ff @(posedge dp_clk) q_r[4*i +: 4] <= {q2, q2, q1, q1};
    end
    always_ff @(posedge dp_clk) smp <= q_r;
    assign locked = 1'b1;

end

endmodule

`resetall
