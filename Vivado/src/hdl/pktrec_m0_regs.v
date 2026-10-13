// SPDX-License-Identifier: MIT
//
// pktrec_m0_regs - AXI4-Lite register block of the M0 Ethernet datapath
// (pktrec_m0_path). Everything here runs on ctrl_clk; event strobes and pin levels
// arrive already synchronised. Register map (byte offsets, 32-bit registers; the
// same map is in include/pktrec_regs.h, keep both in sync):
//
//   0x000 ID         RO  0x504B4D30 ("PKM0")
//   0x004 VERSION    RO  0x00010000 (1.0)
//   0x008 PATH_CTRL  RW  [2n+1:2n] TX source of port n: 0 IDLE, 1 LOOP (own RX),
//                        2 FWD (pair partner's RX: P0<->P1, P2<->P3), 3 = IDLE. Reset 0.
//   0x00C CNT_CTRL   WO  [0] 1 = clear every counter and IO_STICKY (reads 0)
//   0x010 IO_STATUS  RO  [3:0] PHY GPIO_0 level of P0..P3, [7:4] PHY GPIO_1 level,
//                        [8] PG_1V0, [9] PG_2V5, [19:16] link_up[3:0] (eth_ports)
//   0x014 IO_STICKY  W1C [3:0] GPIO_0 rising edge seen, [7:4] GPIO_1 rising edge seen
//   per port n at 0x100 + n * 0x40 (32-bit counters, wrap):
//   +0x00 RX_GOOD    frames received without error (MAC)
//   +0x04 RX_BAD     frames received with an error (bad FCS, framing, oversize)
//   +0x08 TX_GOOD    frames transmitted (MAC)
//   +0x0C TX_UNDERFLOW  frames aborted by a TX underflow (should stay 0)
//   +0x10 DROP_LOOP  frames for TX n dropped by the LOOP FIFO (full / oversize)
//   +0x14 DROP_FWD   frames for TX n dropped by the FWD FIFO (full / oversize)
//   +0x18 GPIO0_EDGES  rising edges on PHY GPIO_0 (RX SFD once configured)
//   +0x1C GPIO1_EDGES  rising edges on PHY GPIO_1 (TX SFD once configured)
//
// evt[6n+i]: one-cycle strobes, i = 0 RX_GOOD, 1 RX_BAD, 2 TX_GOOD, 3 TX_UNDERFLOW,
// 4 DROP_LOOP, 5 DROP_FWD. Unmapped offsets read 0, writes to them are ignored
// (OKAY response).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`timescale 1ns / 1ps

module pktrec_m0_regs #(
    parameter C_S_AXI_ADDR_WIDTH = 12
)(
    input  wire        clk,
    input  wire        resetn,
    input  wire [23:0] evt,
    input  wire [9:0]  io,
    input  wire [3:0]  link_up,
    output wire [7:0]  path_mode,

    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_awaddr,
    input  wire        s_axi_awvalid,
    output reg         s_axi_awready = 1'b0,
    input  wire [31:0] s_axi_wdata,
    input  wire [3:0]  s_axi_wstrb,
    input  wire        s_axi_wvalid,
    output reg         s_axi_wready = 1'b0,
    output wire [1:0]  s_axi_bresp,
    output reg         s_axi_bvalid = 1'b0,
    input  wire        s_axi_bready,
    input  wire [C_S_AXI_ADDR_WIDTH-1:0] s_axi_araddr,
    input  wire        s_axi_arvalid,
    output reg         s_axi_arready = 1'b0,
    output reg  [31:0] s_axi_rdata = 32'd0,
    output wire [1:0]  s_axi_rresp,
    output reg         s_axi_rvalid = 1'b0,
    input  wire        s_axi_rready
);

localparam [31:0] REG_ID      = 32'h504B4D30;
localparam [31:0] REG_VERSION = 32'h00010000;

assign s_axi_bresp = 2'b00;
assign s_axi_rresp = 2'b00;

reg [7:0]  path_mode_reg = 8'd0;
reg [7:0]  sticky_reg = 8'd0;
reg [7:0]  gpio_d = 8'd0;
reg        clr = 1'b0;
reg [31:0] cnt [0:31];          // [8n + i]: i 0..5 = evt, 6 = GPIO0, 7 = GPIO1

assign path_mode = path_mode_reg;

wire [7:0] gpio = io[7:0];
wire [7:0] gpio_rise = gpio & ~gpio_d;

integer i;
initial for (i = 0; i < 32; i = i + 1) cnt[i] = 32'd0;

// counters
always @(posedge clk) begin
    gpio_d <= gpio;
    for (i = 0; i < 32; i = i + 1) begin
        if (clr) begin
            cnt[i] <= 32'd0;
        end else if ((i % 8) < 6) begin
            if (evt[6*(i/8) + (i%8)]) cnt[i] <= cnt[i] + 32'd1;
        end else if ((i % 8) == 6) begin
            if (gpio_rise[i/8]) cnt[i] <= cnt[i] + 32'd1;
        end else begin
            if (gpio_rise[4 + i/8]) cnt[i] <= cnt[i] + 32'd1;
        end
    end
end

// AXI4-Lite: write when AW and W are both valid, one transaction at a time
wire [C_S_AXI_ADDR_WIDTH-1:0] wa = s_axi_awaddr;
wire [C_S_AXI_ADDR_WIDTH-1:0] ra = s_axi_araddr;

always @(posedge clk) begin
    s_axi_awready <= 1'b0;
    s_axi_wready  <= 1'b0;
    s_axi_arready <= 1'b0;
    clr <= 1'b0;
    sticky_reg <= sticky_reg | gpio_rise;

    if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
    if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;

    if (s_axi_awvalid && s_axi_wvalid && !s_axi_awready && !s_axi_bvalid) begin
        s_axi_awready <= 1'b1;
        s_axi_wready  <= 1'b1;
        s_axi_bvalid  <= 1'b1;
        case (wa[11:2])
            10'h002: if (s_axi_wstrb[0]) path_mode_reg <= s_axi_wdata[7:0];
            10'h003: if (s_axi_wstrb[0] && s_axi_wdata[0]) begin
                         clr <= 1'b1;
                         sticky_reg <= 8'd0;
                     end
            10'h005: if (s_axi_wstrb[0]) sticky_reg <= (sticky_reg | gpio_rise) & ~s_axi_wdata[7:0];
            default: ;
        endcase
    end

    if (s_axi_arvalid && !s_axi_arready && !s_axi_rvalid) begin
        s_axi_arready <= 1'b1;
        s_axi_rvalid  <= 1'b1;
        s_axi_rdata   <= 32'd0;
        if (ra[11:8] == 4'h0) begin
            case (ra[7:2])
                6'h00: s_axi_rdata <= REG_ID;
                6'h01: s_axi_rdata <= REG_VERSION;
                6'h02: s_axi_rdata <= {24'd0, path_mode_reg};
                6'h04: s_axi_rdata <= {12'd0, link_up, 6'd0, io[9:8], io[7:0]};
                6'h05: s_axi_rdata <= {24'd0, sticky_reg};
                default: ;
            endcase
        end else if (ra[11:8] == 4'h1 && ra[5] == 1'b0) begin
            s_axi_rdata <= cnt[{ra[7:6], ra[4:2]}];
        end
    end

    if (!resetn) begin
        s_axi_awready <= 1'b0;
        s_axi_wready  <= 1'b0;
        s_axi_bvalid  <= 1'b0;
        s_axi_arready <= 1'b0;
        s_axi_rvalid  <= 1'b0;
        path_mode_reg <= 8'd0;
        sticky_reg    <= 8'd0;
        clr           <= 1'b1;
    end
end

endmodule
