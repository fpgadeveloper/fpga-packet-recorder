// SPDX-License-Identifier: MIT
//
// pktrec_cap_regs - AXI4-Lite register block of the capture path (dp_clk).
// Register map: include/pktrec_regs.h (PKTREC_CAP_*), docs/source/design.md.
//
// One transaction at a time (AW and W together, then B; AR then R), OKAY
// responses only; unmapped offsets read 0 and ignore writes. 64-bit counters
// are _LO/_HI pairs: a _LO read latches the matching _HI half (one latch per
// pair), so software reads _LO then _HI.
// Offsets 0x400..0xFFF are forwarded to the SFD block (pktrec_sfd: sfd_reg_*;
// reads complete when it answers with sfd_reg_rvalid).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_cap_regs #(
    parameter int          N          = 4,
    parameter logic [31:0] DP_CLK_HZ  = 32'd250000000,
    parameter logic [31:0] FIFO_BYTES = 32'd16384
)(
    input  wire logic          clk,
    input  wire logic          rst,

    // AXI4-Lite slave
    input  wire logic [11:0]   s_axi_awaddr,
    input  wire logic          s_axi_awvalid,
    output logic               s_axi_awready,
    input  wire logic [31:0]   s_axi_wdata,
    input  wire logic [3:0]    s_axi_wstrb,
    input  wire logic          s_axi_wvalid,
    output logic               s_axi_wready,
    output wire logic [1:0]    s_axi_bresp,
    output logic               s_axi_bvalid,
    input  wire logic          s_axi_bready,
    input  wire logic [11:0]   s_axi_araddr,
    input  wire logic          s_axi_arvalid,
    output logic               s_axi_arready,
    output logic      [31:0]   s_axi_rdata,
    output wire logic [1:0]    s_axi_rresp,
    output logic               s_axi_rvalid,
    input  wire logic          s_axi_rready,

    // control
    output logic               cap_enable,
    output logic               fill_en,
    output logic               src_sel,
    output logic               clear,           // 1-cycle pulse
    output logic      [N-1:0]  port_en,
    output logic      [15:0]   snaplen,
    output logic      [N-1:0]  hwm_clr,         // 1-cycle pulses

    // timebase control / status
    output logic               tb_set,
    output logic      [63:0]   tb_set_val,
    output logic               tb_adj,
    output logic      [63:0]   tb_adj_val,
    output logic               tb_inc_load,
    output logic      [7:0]    tb_inc_ns_wr,
    output logic      [31:0]   tb_inc_frac_wr,
    input  wire logic [63:0]   tb_ns,
    input  wire logic [7:0]    tb_inc_ns,
    input  wire logic [31:0]   tb_inc_frac,
    input  wire logic [2*N-1:0] tb_valid,
    output logic      [31:0]   mac_offset,

    // status
    input  wire logic          idle,
    input  wire logic          merge_busy,
    input  wire logic [N-1:0]  port_idle,
    input  wire logic [N-1:0]  rx_active,

    // merge statistics
    input  wire logic [63:0]   bytes_out,
    input  wire logic [63:0]   records_out,
    input  wire logic [63:0]   fill_beats,
    input  wire logic [63:0]   bp_cycles,
    input  wire logic [31:0]   srst_aborts,
    input  wire logic [31:0]   len_fixups,

    // per-port counters (port n at [64n +: 64] / [32n +: 32] / [16n +: 16])
    input  wire logic [N*64-1:0] p_frames_rx,
    input  wire logic [N*64-1:0] p_frames_bad,
    input  wire logic [N*64-1:0] p_frames_drop,
    input  wire logic [N*64-1:0] p_bytes_rx,
    input  wire logic [N*64-1:0] p_bytes_drop,
    input  wire logic [N*64-1:0] p_frames_trunc,
    input  wire logic [N*64-1:0] p_records,
    input  wire logic [N*32-1:0] p_fifo_hwm,
    input  wire logic [N*16-1:0] p_seq_next,

    // SFD block register port (offsets 0x400..0xFFF)
    output logic               sfd_reg_wr,
    output logic      [11:0]   sfd_reg_wa,
    output logic      [31:0]   sfd_reg_wd,
    output logic               sfd_reg_rd,
    output logic      [11:0]   sfd_reg_ra,
    input  wire logic          sfd_reg_rvalid,
    input  wire logic [31:0]   sfd_reg_rdata
);

localparam logic [31:0] ID      = 32'h504B4350;   // "PKCP"
localparam logic [31:0] VERSION = 32'h0001_0002;   // 1.2: SFD timestamping block at 0x400..0xBFF

assign s_axi_bresp = 2'b00;
assign s_axi_rresp = 2'b00;

// ---------------------------------------------------------------------------
// Write channel
// ---------------------------------------------------------------------------
wire        wr_fire = s_axi_awvalid && s_axi_wvalid && !s_axi_awready && !s_axi_bvalid;
wire [11:0] wa      = {s_axi_awaddr[11:2], 2'b00};
wire [31:0] wd      = s_axi_wdata;
logic [31:0] inc_frac_stage;

always_ff @(posedge clk) begin
    s_axi_awready <= 1'b0;
    s_axi_wready  <= 1'b0;
    clear       <= 1'b0;
    hwm_clr     <= '0;
    tb_set      <= 1'b0;
    tb_adj      <= 1'b0;
    tb_inc_load <= 1'b0;
    sfd_reg_wr  <= 1'b0;

    if (wr_fire && wa[11:10] != 2'b00) begin
        s_axi_awready <= 1'b1;
        s_axi_wready  <= 1'b1;
        s_axi_bvalid  <= 1'b1;
        sfd_reg_wr    <= 1'b1;
        sfd_reg_wa    <= wa;
        sfd_reg_wd    <= wd;
    end else if (wr_fire) begin
        s_axi_awready <= 1'b1;
        s_axi_wready  <= 1'b1;
        s_axi_bvalid  <= 1'b1;
        case (wa)
            12'h008: begin
                cap_enable <= wd[0];
                fill_en    <= wd[1];
                src_sel    <= wd[2];
                clear      <= wd[8];
            end
            12'h010: port_en <= wd[N-1:0];
            12'h014: snaplen <= wd[15:0];
            12'h080: begin
                tb_set <= wd[0];
                tb_adj <= wd[1] && !wd[0];
            end
            12'h084: inc_frac_stage <= wd;
            12'h088: begin
                tb_inc_ns_wr   <= wd[7:0];
                tb_inc_frac_wr <= inc_frac_stage;
                tb_inc_load    <= 1'b1;
            end
            12'h098: tb_set_val[31:0]  <= wd;
            12'h09C: tb_set_val[63:32] <= wd;
            12'h0A0: tb_adj_val[31:0]  <= wd;
            12'h0A4: tb_adj_val[63:32] <= wd;
            12'h0A8: mac_offset <= wd;
            default: begin
                for (int n = 0; n < N; n++)
                    if (wa == 12'(12'h100 + n * 12'h040 + 12'h038)) hwm_clr[n] <= 1'b1;
            end
        endcase
    end
    if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;

    if (rst) begin
        s_axi_awready <= 1'b0;
        s_axi_wready  <= 1'b0;
        s_axi_bvalid  <= 1'b0;
        cap_enable    <= 1'b0;
        fill_en       <= 1'b0;
        src_sel       <= 1'b0;
        clear         <= 1'b0;
        port_en       <= '1;
        snaplen       <= '0;
        tb_set_val    <= '0;
        tb_adj_val    <= '0;
        mac_offset    <= 32'd52;
        inc_frac_stage <= '0;
        tb_inc_ns_wr  <= '0;
        tb_inc_frac_wr <= '0;
        sfd_reg_wr     <= 1'b0;
    end
end

// ---------------------------------------------------------------------------
// Read channel: 64-bit values by pair index (offset >> 3), with per-pair HI latch
// ---------------------------------------------------------------------------
wire [11:0] ra = {s_axi_araddr[11:2], 2'b00};

// 64-bit value of pair k = offset[8:3] (0x000..0x1F8); 0 where no pair
logic [63:0] pair_val;
logic        pair_is64;
always_comb begin
    pair_val  = '0;
    pair_is64 = 1'b0;
    case (ra[8:3])
        6'h04: begin pair_val = bytes_out;   pair_is64 = 1'b1; end    // 0x020
        6'h05: begin pair_val = records_out; pair_is64 = 1'b1; end    // 0x028
        6'h06: begin pair_val = fill_beats;  pair_is64 = 1'b1; end    // 0x030
        6'h07: begin pair_val = bp_cycles;   pair_is64 = 1'b1; end    // 0x038
        6'h12: begin pair_val = tb_ns;       pair_is64 = 1'b1; end    // 0x090
        6'h13: begin pair_val = tb_set_val;  pair_is64 = 1'b1; end    // 0x098
        6'h14: begin pair_val = tb_adj_val;  pair_is64 = 1'b1; end    // 0x0A0
        default: ;
    endcase
    for (int n = 0; n < N; n++) begin
        if (ra[8:6] == 3'(4 + n)) begin       // 0x100 + n * 0x40
            pair_is64 = (ra[5:3] != 3'd7);
            case (ra[5:3])
                3'd0: pair_val = p_frames_rx[64*n +: 64];
                3'd1: pair_val = p_frames_bad[64*n +: 64];
                3'd2: pair_val = p_frames_drop[64*n +: 64];
                3'd3: pair_val = p_bytes_rx[64*n +: 64];
                3'd4: pair_val = p_bytes_drop[64*n +: 64];
                3'd5: pair_val = p_frames_trunc[64*n +: 64];
                3'd6: pair_val = p_records[64*n +: 64];
                default: pair_val = {16'd0, p_seq_next[16*n +: 16], p_fifo_hwm[32*n +: 32]};
            endcase
        end
    end
    if (ra[11:9] != 3'd0) begin
        pair_val  = '0;
        pair_is64 = 1'b0;
    end
end

logic [31:0] hi_l [64];
logic        sfd_pend = 1'b0;

always_ff @(posedge clk) begin
    s_axi_arready <= 1'b0;
    sfd_reg_rd    <= 1'b0;
    if (sfd_pend) begin
        if (sfd_reg_rvalid) begin
            s_axi_rvalid <= 1'b1;
            s_axi_rdata  <= sfd_reg_rdata;
            sfd_pend     <= 1'b0;
        end
    end else if (s_axi_arvalid && !s_axi_arready && !s_axi_rvalid && ra[11:10] != 2'b00) begin
        s_axi_arready <= 1'b1;
        sfd_reg_rd    <= 1'b1;
        sfd_reg_ra    <= ra;
        sfd_pend      <= 1'b1;
    end else if (s_axi_arvalid && !s_axi_arready && !s_axi_rvalid) begin
        s_axi_arready <= 1'b1;
        s_axi_rvalid  <= 1'b1;
        if (pair_is64 && !ra[2]) begin
            s_axi_rdata   <= pair_val[31:0];
            hi_l[ra[8:3]] <= pair_val[63:32];
        end else if (pair_is64) begin
            s_axi_rdata <= hi_l[ra[8:3]];
        end else if (ra[11:9] == 3'd0 && ra[8:6] >= 3'd4 && ra[5:3] == 3'd7) begin
            // per-port FIFO_HWM (0x38) / SEQ_NEXT (0x3C)
            s_axi_rdata <= ra[2] ? pair_val[63:32] : pair_val[31:0];
        end else begin
            case (ra)
                12'h000: s_axi_rdata <= ID;
                12'h004: s_axi_rdata <= VERSION;
                12'h008: s_axi_rdata <= {29'd0, src_sel, fill_en, cap_enable};
                12'h00C: s_axi_rdata <= {8'd0, 8'(tb_valid), 4'(rx_active), 4'(port_idle),
                                         6'd0, merge_busy, idle};
                12'h010: s_axi_rdata <= 32'(port_en);
                12'h014: s_axi_rdata <= {16'd0, snaplen};
                12'h018: s_axi_rdata <= DP_CLK_HZ;
                12'h01C: s_axi_rdata <= FIFO_BYTES;
                12'h040: s_axi_rdata <= srst_aborts;
                12'h044: s_axi_rdata <= len_fixups;
                12'h084: s_axi_rdata <= tb_inc_frac;
                12'h088: s_axi_rdata <= {24'd0, tb_inc_ns};
                12'h08C: s_axi_rdata <= 32'(tb_valid);
                12'h0A8: s_axi_rdata <= mac_offset;
                default: s_axi_rdata <= 32'd0;
            endcase
        end
    end else if (s_axi_rvalid && s_axi_rready) begin
        s_axi_rvalid <= 1'b0;
    end
    if (rst) begin
        s_axi_arready <= 1'b0;
        s_axi_rvalid  <= 1'b0;
        s_axi_rdata   <= '0;
        sfd_pend      <= 1'b0;
        sfd_reg_rd    <= 1'b0;
    end
end

endmodule

`resetall
