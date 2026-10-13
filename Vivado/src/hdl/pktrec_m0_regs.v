// SPDX-License-Identifier: MIT
//
// pktrec_m0_regs - AXI4-Lite register block of the M0 Ethernet datapath
// (pktrec_m0_path). Everything here runs on ctrl_clk; event strobes and pin levels
// arrive already synchronised. Register map (byte offsets, 32-bit registers; the
// same map is in include/pktrec_regs.h, keep both in sync):
//
//   0x000 ID         RO  0x504B4D30 ("PKM0")
//   0x004 VERSION    RO  0x00010003 (1.1: generator + checker; 1.2: TAP mode - pair
//                        mode, effective path, dynamic IFG, FIFO fill, FLUSH;
//                        1.3: REPLAY path - PATH_RPL, EFF_PATH[11:8])
//   0x008 PATH_CTRL  RW  [2n+1:2n] TX source of port n: 0 IDLE, 1 LOOP (own RX),
//                        2 FWD (pair partner's RX: P0<->P1, P2<->P3), 3 GEN. Reset 0.
//   0x00C CNT_CTRL   WO  [0] 1 = clear every counter and IO_STICKY (reads 0)
//   0x010 IO_STATUS  RO  [3:0] PHY GPIO_0 level of P0..P3, [7:4] PHY GPIO_1 level,
//                        [8] PG_1V0, [9] PG_2V5, [19:16] link_up[3:0] (eth_ports)
//   0x014 IO_STICKY  W1C [3:0] GPIO_0 rising edge seen, [7:4] GPIO_1 rising edge seen
//   0x018 PAIR_MODE  RW  [1:0] pair 0 (P0/P1), [3:2] pair 1 (P2/P3): 0 monitor, 1 tap
//                        (2/3 reserved). Informational: software writes it together with
//                        PATH_CTRL (tap = FWD on both ports, monitor = IDLE); pktrec-cap
//                        stores it in the capture file header. Reset 0.
//   0x01C EFF_PATH   RO  [2n+1:2n] TX source port n actually uses now (PATH_CTRL
//                        coding); differs from PATH_CTRL only until the TX side reaches
//                        a frame boundary. (1.3) [8+n] = port n sends replay frames
//                        now (then [2n+1:2n] reads 0)
//   0x020 PATH_RPL   RW  (1.3) [n] = TX port n is in path mode 4 REPLAY: its TX source
//                        is the replay scheduler (pktrec_replay, M6), overriding
//                        PATH_CTRL [2n+1:2n]. Reset 0
//   per port n at 0x100 + n * 0x40 (32-bit counters, wrap):
//   +0x00 RX_GOOD    frames received without error (MAC)
//   +0x04 RX_BAD     frames received with an error (bad FCS, framing, oversize)
//   +0x08 TX_GOOD    frames transmitted (MAC)
//   +0x0C TX_UNDERFLOW  frames aborted by a TX underflow (should stay 0)
//   +0x10 DROP_LOOP  frames for TX n dropped by the LOOP FIFO (full / oversize)
//   +0x14 DROP_FWD   frames for TX n dropped by the FWD FIFO (full / oversize)
//   +0x18 GPIO0_EDGES  rising edges on PHY GPIO_0 (RX SFD once configured)
//   +0x1C GPIO1_EDGES  rising edges on PHY GPIO_1 (TX SFD once configured)
//   +0x20 IFG_CTRL   RW  [0] DYN_EN (1) [15:8] IFG_NOM (12) [23:16] IFG_MIN (8):
//                        MAC TX inter-frame gap in bytes, normal / reduced
//   +0x24 IFG_THRESH RW  [15:0] IFG_HI (3072) [31:16] IFG_LO (2048): FWD FIFO fill
//                        (bytes) above which the reduced gap starts / below which it ends.
//                        The fill counts the frame being received too (about one frame
//                        while forwarding at 100 %), so IFG_LO must exceed the largest
//                        frame, else the reduced gap lasts until the traffic pauses
//   +0x28 FWD_FILL   RO  [15:0] FWD FIFO fill now (bytes) [31:16] max since clear
//   +0x2C IFG_STATUS RO  [0] reduced gap active [15:8] gap in use (bytes)
//   +0x30 IFG_RED_CYC_LO / +0x34 _HI  RO  tx_clk cycles (16 ns) spent with the reduced
//                        gap (48 bit; LO read latches HI)
//   +0x38 IFG_RED_ENTRIES RO  times the reduced gap was entered
//   +0x3C FLUSH      RO  frames discarded from an unselected FIFO (after a PATH_CTRL
//                        change: frames already in the FIFO when the port left LOOP/FWD)
//
//   per port n at 0x200 + n * 0x80: traffic generator (pktrec_gen) and receive
//   checker (pktrec_gen_chk); see include/pktrec_regs.h PKTREC_M0_GEN_* / _CHK_*
//   +0x00 GEN_CTRL RW [0] ENABLE (0->1 starts), [1] FORMAT (0 PRSQ/UDP, 1 raw), [2] RAND_LEN
//                     [3] BAD (1.2): every generated frame is sent error-terminated (TX
//                     tuser[0]; the PCS replaces its FCS with /V/) - bad-frame forwarding test
//   +0x04 GEN_STATUS RO [0] running [1] done (COUNT reached)
//   +0x08 GEN_LEN [13:0] (60)  +0x0C GEN_LEN_MASK [13:0]  +0x10 GEN_IFG [15:0] (12)
//   +0x14 GEN_COUNT (0 = endless)  +0x18/1C GEN_DST_LO/HI  +0x20/24 GEN_SRC_LO/HI
//   +0x28 GEN_ETYPE (0x88B5)  +0x2C GEN_STREAM (n)  +0x30 GEN_SEQ_FIRST
//   +0x34/38 GEN_FRAMES_LO/HI  +0x3C/40 GEN_BYTES_LO/HI (LO read latches HI)
//   +0x48 CHK_CTRL [0] ENABLE (0->1 clears) [1] FORMAT [31:16] ETYPE (0x88B5)
//   +0x4C CHK_FRAMES +0x50 CHK_LOST +0x54 CHK_ERRORS +0x58 CHK_BAD
//   +0x5C/60 CHK_LAST_SEQ_LO/HI
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
    output wire [3:0]  path_rpl,
    output wire [4*255-1:0] gen_cfg,     // per port, see pktrec_m0_path GCFG_W
    output wire [4*18-1:0]  chk_cfg,
    input  wire [4*130-1:0] gen_st,      // {bytes, frames, done, running}
    input  wire [4*192-1:0] chk_st,      // {last_seq, bad, errors, lost, frames}
    input  wire [7:0]       flush_evt,   // [2n+k] frame flushed from TX n's FIFO k
    input  wire [11:0]      eff_path,    // [3n+2:3n] TX source of port n (4 = replay)
    output wire [4*50-1:0]  ifg_cfg,     // per port {gen_bad, lo, hi, min, nom, en}
    input  wire [4*121-1:0] ifg_st,      // {red_cyc 48, entries 32, fill_max, fill, ifg, reduced}
    output reg              ifg_clr_tgl = 1'b0,

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
localparam [31:0] REG_VERSION = 32'h00010003;

assign s_axi_bresp = 2'b00;
assign s_axi_rresp = 2'b00;

reg [7:0]  path_mode_reg = 8'd0;
reg [3:0]  path_rpl_reg = 4'd0;
reg [7:0]  sticky_reg = 8'd0;
reg [7:0]  gpio_d = 8'd0;
reg        clr = 1'b0;
reg [31:0] cnt [0:31];          // [8n + i]: i 0..5 = evt, 6 = GPIO0, 7 = GPIO1

assign path_mode = path_mode_reg;
assign path_rpl  = path_rpl_reg;

// EFF_PATH read value: PATH_CTRL coding in [2n+1:2n], replay flags in [11:8]
wire [7:0] eff_code;
wire [3:0] eff_rpl;
genvar ge;
generate for (ge = 0; ge < 4; ge = ge + 1) begin : g_eff
    assign eff_rpl[ge] = (eff_path[3*ge +: 3] == 3'd4);
    assign eff_code[2*ge +: 2] = eff_rpl[ge] ? 2'd0 : eff_path[3*ge +: 2];
end endgenerate

// generator / checker configuration, port n
reg [2:0]  g_ctrl  [0:3];
reg [13:0] g_len   [0:3];
reg [13:0] g_mask  [0:3];
reg [15:0] g_ifg   [0:3];
reg [31:0] g_count [0:3];
reg [47:0] g_dst   [0:3];
reg [47:0] g_src   [0:3];
reg [15:0] g_etype [0:3];
reg [31:0] g_strm  [0:3];
reg [31:0] g_seq0  [0:3];
reg [17:0] c_ctrl  [0:3];
reg [31:0] hi_lat  [0:3];       // HI latch of the last 64-bit LO read, per port
reg [3:0]  pair_mode_reg = 4'd0;
reg [23:0] i_ctrl  [0:3];       // {min, nom, 7'd0, en}
reg [31:0] i_thr   [0:3];       // {lo, hi}
reg [15:0] i_hi_lat [0:3];      // IFG_RED_CYC_HI latch
reg [31:0] flush_cnt [0:3];
reg [3:0]  g_bad = 4'd0;        // GEN_CTRL[3]: generator frames sent as bad (TX tuser)
genvar gp;
generate for (gp = 0; gp < 4; gp = gp + 1) begin : g_cfg
    assign gen_cfg[255*gp +: 255] = {g_seq0[gp], g_strm[gp], g_etype[gp], g_src[gp], g_dst[gp],
                                     g_count[gp], g_ifg[gp], g_mask[gp], g_len[gp], g_ctrl[gp]};
    assign chk_cfg[18*gp +: 18] = c_ctrl[gp];
    assign ifg_cfg[50*gp +: 50] = {g_bad[gp], i_thr[gp][31:16], i_thr[gp][15:0], i_ctrl[gp][23:16],
                                   i_ctrl[gp][15:8], i_ctrl[gp][0]};
end endgenerate
integer p;
initial begin
    for (p = 0; p < 4; p = p + 1) begin
        g_ctrl[p] = 3'd0; g_len[p] = 14'd60; g_mask[p] = 14'd0; g_ifg[p] = 16'd12;
        g_count[p] = 32'd0; g_dst[p] = 48'hFFFF_FFFF_FFFF; g_src[p] = 48'h0200_0000_0000 + p;
        g_etype[p] = 16'h88B5; g_strm[p] = p; g_seq0[p] = 32'd0; c_ctrl[p] = {16'h88B5, 2'b00};
        hi_lat[p] = 32'd0;
        i_ctrl[p] = {8'd8, 8'd12, 7'd0, 1'b1}; i_thr[p] = {16'd2048, 16'd3072};
        i_hi_lat[p] = 16'd0; flush_cnt[p] = 32'd0;
    end
end

// generator / checker read word of port rp, word index rw (0x200 + rp * 0x80 + 4 * rw)
function [31:0] gword;
    input [1:0] rp;
    input [4:0] rw;
    begin
        case (rw)
            5'd0:  gword = {28'd0, g_bad[rp], g_ctrl[rp]};
            5'd1:  gword = {30'd0, gen_st[130*rp +: 2]};
            5'd2:  gword = {18'd0, g_len[rp]};
            5'd3:  gword = {18'd0, g_mask[rp]};
            5'd4:  gword = {16'd0, g_ifg[rp]};
            5'd5:  gword = g_count[rp];
            5'd6:  gword = g_dst[rp][31:0];
            5'd7:  gword = {16'd0, g_dst[rp][47:32]};
            5'd8:  gword = g_src[rp][31:0];
            5'd9:  gword = {16'd0, g_src[rp][47:32]};
            5'd10: gword = {16'd0, g_etype[rp]};
            5'd11: gword = g_strm[rp];
            5'd12: gword = g_seq0[rp];
            5'd13: gword = gen_st[130*rp + 2 +: 32];      // FRAMES_LO
            5'd15: gword = gen_st[130*rp + 66 +: 32];     // BYTES_LO
            5'd18: gword = {c_ctrl[rp][17:2], 14'd0, c_ctrl[rp][1:0]};
            5'd19: gword = chk_st[192*rp +: 32];
            5'd20: gword = chk_st[192*rp + 32 +: 32];
            5'd21: gword = chk_st[192*rp + 64 +: 32];
            5'd22: gword = chk_st[192*rp + 96 +: 32];
            5'd23: gword = chk_st[192*rp + 128 +: 32];    // LAST_SEQ_LO
            default: gword = 32'd0;
        endcase
    end
endfunction

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

integer j;
always @(posedge clk) begin
    for (j = 0; j < 4; j = j + 1) begin
        if (clr)
            flush_cnt[j] <= 32'd0;
        else
            flush_cnt[j] <= flush_cnt[j] + flush_evt[2*j] + flush_evt[2*j+1];
    end
end

// per-port TAP word rw (8..15) of port rp (0x100 + rp * 0x40 + 4 * rw)
function [31:0] iword;
    input [1:0] rp;
    input [2:0] rw;
    begin
        case (rw)
            3'd0: iword = {8'd0, i_ctrl[rp]};
            3'd1: iword = i_thr[rp];
            3'd2: iword = {ifg_st[121*rp + 25 +: 16], ifg_st[121*rp + 9 +: 16]};
            3'd3: iword = {16'd0, ifg_st[121*rp + 1 +: 8], 7'd0, ifg_st[121*rp]};
            3'd4: iword = ifg_st[121*rp + 73 +: 32];
            3'd5: iword = {16'd0, i_hi_lat[rp]};
            3'd6: iword = ifg_st[121*rp + 41 +: 32];
            3'd7: iword = flush_cnt[rp];
        endcase
    end
endfunction

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
                         ifg_clr_tgl <= !ifg_clr_tgl;
                     end
            10'h006: if (s_axi_wstrb[0]) pair_mode_reg <= s_axi_wdata[3:0];
            10'h008: if (s_axi_wstrb[0]) path_rpl_reg <= s_axi_wdata[3:0];
            10'h005: if (s_axi_wstrb[0]) sticky_reg <= (sticky_reg | gpio_rise) & ~s_axi_wdata[7:0];
            default: if (wa[11:8] == 4'h1 && wa[5]) begin
                // 0x100 + n * 0x40 + 0x20: dynamic IFG configuration
                case (wa[4:2])
                    3'd0: i_ctrl[wa[7:6]] <= {s_axi_wdata[23:8], 7'd0, s_axi_wdata[0]};
                    3'd1: i_thr[wa[7:6]]  <= s_axi_wdata;
                    default: ;
                endcase
            end else if (wa[11:9] == 3'b001) begin
                // 0x200 + n * 0x80
                case (wa[6:2])
                    5'd0:  begin
                               g_ctrl[wa[8:7]]  <= s_axi_wdata[2:0];
                               g_bad[wa[8:7]]   <= s_axi_wdata[3];
                           end
                    5'd2:  g_len[wa[8:7]]   <= s_axi_wdata[13:0];
                    5'd3:  g_mask[wa[8:7]]  <= s_axi_wdata[13:0];
                    5'd4:  g_ifg[wa[8:7]]   <= s_axi_wdata[15:0];
                    5'd5:  g_count[wa[8:7]] <= s_axi_wdata;
                    5'd6:  g_dst[wa[8:7]][31:0]  <= s_axi_wdata;
                    5'd7:  g_dst[wa[8:7]][47:32] <= s_axi_wdata[15:0];
                    5'd8:  g_src[wa[8:7]][31:0]  <= s_axi_wdata;
                    5'd9:  g_src[wa[8:7]][47:32] <= s_axi_wdata[15:0];
                    5'd10: g_etype[wa[8:7]] <= s_axi_wdata[15:0];
                    5'd11: g_strm[wa[8:7]]  <= s_axi_wdata;
                    5'd12: g_seq0[wa[8:7]]  <= s_axi_wdata;
                    5'd18: c_ctrl[wa[8:7]]  <= {s_axi_wdata[31:16], s_axi_wdata[1:0]};
                    default: ;
                endcase
            end
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
                6'h06: s_axi_rdata <= {28'd0, pair_mode_reg};
                6'h07: s_axi_rdata <= {20'd0, eff_rpl, eff_code};
                6'h08: s_axi_rdata <= {28'd0, path_rpl_reg};
                default: ;
            endcase
        end else if (ra[11:8] == 4'h1 && ra[5] == 1'b0) begin
            s_axi_rdata <= cnt[{ra[7:6], ra[4:2]}];
        end else if (ra[11:8] == 4'h1) begin
            if (ra[4:2] == 3'd4) i_hi_lat[ra[7:6]] <= ifg_st[121*ra[7:6] + 105 +: 16];
            s_axi_rdata <= iword(ra[7:6], ra[4:2]);
        end else if (ra[11:9] == 3'b001) begin
            // generator / checker; 64-bit pairs: LO latches HI
            case (ra[6:2])
                5'd13: hi_lat[ra[8:7]] <= gen_st[130*ra[8:7] + 34 +: 32];
                5'd15: hi_lat[ra[8:7]] <= gen_st[130*ra[8:7] + 98 +: 32];
                5'd23: hi_lat[ra[8:7]] <= chk_st[192*ra[8:7] + 160 +: 32];
                default: ;
            endcase
            if (ra[6:2] == 5'd14 || ra[6:2] == 5'd16 || ra[6:2] == 5'd24)
                s_axi_rdata <= hi_lat[ra[8:7]];
            else
                s_axi_rdata <= gword(ra[8:7], ra[6:2]);
        end
    end

    if (!resetn) begin
        s_axi_awready <= 1'b0;
        s_axi_wready  <= 1'b0;
        s_axi_bvalid  <= 1'b0;
        s_axi_arready <= 1'b0;
        s_axi_rvalid  <= 1'b0;
        path_mode_reg <= 8'd0;
        path_rpl_reg  <= 4'd0;
        pair_mode_reg <= 4'd0;
        sticky_reg    <= 8'd0;
        clr           <= 1'b1;
    end
end

endmodule
