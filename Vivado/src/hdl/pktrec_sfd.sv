// SPDX-License-Identifier: MIT
//
// pktrec_sfd - PHY SFD timestamping (M2), dp_clk domain.
//
// Inputs: the oversampled SFD levels of the four DP83867s (pktrec_sfd_io,
// smp[4i+3:4i]: i = 0..3 RX SFD (GPIO_0) of port i, i = 4..7 TX SFD (GPIO_1)
// of port i-4), the shared timebase (pktrec_timebase) and the Taxi TX
// completions (tx_clk_n: one per transmitted frame with the MAC's TX
// timestamp = timebase cycle count at the MAC's SFD).
//
// Per pin: pktrec_sfd_edge (glitch filter + rising-edge timestamp, ~1 ns).
//
// RX SFD of port n: every accepted edge {cyc, k} is pushed into port n's SFD
//   queue inside pktrec_cap_port (async FIFO, 16 entries; full -> the entry is
//   lost and RX_FIFO_OVF counts it), where it is matched to the frame (see
//   pktrec_cap_port). Also: RX_EDGES, RX_GLITCH, RX_LAST_TS (+ RX_OFFSET) and,
//   with SFD_CTRL.LOG_EN, the software log FIFO (16 x ts).
// TX SFD of port n: paired in order with the MAC TX completions of port n
//   (async FIFO tx_clk -> dp_clk, 16 entries). For an edge at time t_sfd and
//   the oldest waiting completion with raw MAC time t_cpl (cycle count x ~4 ns,
//   no MAC_OFFSET): lat = t_sfd - t_cpl
//     lat > TX_WIN_MAX         -> the completion is stale (its SFD was never
//                                 seen): dropped, TX_CPL_STALE++, try the next
//     TX_WIN_MIN <= lat        -> paired: TX_PAIRED++, TX_LAT_LAST/MIN/MAX
//     else / no completion     -> TX_UNPAIRED++ (completion kept)
//   so a missing or extra pulse costs one pairing and never shifts later ones.
//   Also TX_EDGES, TX_CPL (completions seen), TX_CPL_OVF, TX_LAST_TS
//   (+ TX_OFFSET) and the TX log FIFO (16 x {ts, lat}).
//
// Registers: capture block offsets 0x400..0xBFF (include/pktrec_regs.h
// PKTREC_SFD_*), forwarded by pktrec_cap_regs (reg_rd -> reg_rvalid after 3
// cycles). 64-bit values: reading _LO latches _HI (per value). Reading a
// LOG_TS_LO pops the oldest log entry and latches its _HI (and LAT).
//
// Copyright (c) 2026 Opsero Electronic Design Inc.

`resetall
`timescale 1ns / 1ps
`default_nettype none

module pktrec_sfd #(
    parameter int          N        = 4,
    parameter int          PIPE_NS  = 16,
    parameter logic [31:0] RES_PS   = 32'd1000,
    parameter bit          ISERDES  = 1'b1
)(
    input  wire logic           clk,           // dp_clk
    input  wire logic           rst,

    input  wire logic [8*N-1:0] smp,           // [4i +: 4], i < N: RX port i, i >= N: TX port i-N
    input  wire logic           locked,

    input  wire logic [63:0]    tb_ns,
    input  wire logic [31:0]    tb_frac,
    input  wire logic [31:0]    tb_cyc,
    input  wire logic           clear_in,      // capture CTRL.CLEAR

    // RX SFD entries -> pktrec_cap_port n
    output wire logic [N-1:0]   rx_wr,
    output wire logic [N*34-1:0] rx_din,       // {k[1:0], cyc[31:0]}
    input  wire logic [N-1:0]   rx_full,
    output logic                match_en,
    output logic      [31:0]    rx_win_min,
    output logic      [31:0]    rx_win_max,
    output logic      [N*32-1:0] rx_offset,
    output logic                sfd_clear,     // 1-cycle pulse to the ports

    // RX match statistics from the ports (dp_clk snapshots)
    input  wire logic [N*64-1:0] p_matched,
    input  wire logic [N*32-1:0] p_stale,
    input  wire logic [N*32-1:0] p_mismatch,
    input  wire logic [N*32-1:0] p_dlast,
    input  wire logic [N*32-1:0] p_dmin,
    input  wire logic [N*32-1:0] p_dmax,
    input  wire logic [N*32-1:0] p_dhead,

    // TX completions (tx_clk n)
    input  wire logic [N-1:0]   tx_clk,
    input  wire logic [N-1:0]   tx_rst,
    input  wire logic [N-1:0]   tx_cpl_valid,
    input  wire logic [N*32-1:0] tx_cpl_cyc,

    output logic      [N-1:0]   lvl_rx,
    output logic      [N-1:0]   lvl_tx,

    // register port (offsets 0x400..0xBFF of the capture block)
    input  wire logic           reg_wr,
    input  wire logic [11:0]    reg_wa,
    input  wire logic [31:0]    reg_wd,
    input  wire logic           reg_rd,
    input  wire logic [11:0]    reg_ra,
    output logic                reg_rvalid,
    output logic      [31:0]    reg_rdata
);

localparam logic [31:0] LAT_INVALID = 32'h8000_0000;

// ---------------------------------------------------------------------------
// global registers
// ---------------------------------------------------------------------------
logic        log_en = 1'b0;
logic [31:0] tx_win_min = 32'd0, tx_win_max = 32'd900;
logic [7:0]  min_low = 8'd25, min_high = 8'd8;
logic        clr_sfd = 1'b0;
logic [N*32-1:0] tx_offset = '0;

wire clr = clr_sfd || clear_in;
assign sfd_clear = clr;

// ---------------------------------------------------------------------------
// edge detectors
// ---------------------------------------------------------------------------
wire [2*N-1:0]    e_ev, e_glitch, e_lvl;
wire [2*N*64-1:0] e_ns;
wire [2*N*32-1:0] e_cyc;
wire [2*N*2-1:0]  e_k;

genvar g;
for (g = 0; g < 2*N; g = g + 1) begin : g_edge
    pktrec_sfd_edge #(.PIPE_NS(PIPE_NS)) edge_inst (
        .clk(clk), .rst(rst || !locked),
        .s(smp[4*g +: 4]), .min_low(min_low), .min_high(min_high),
        .tb_ns(tb_ns), .tb_half(tb_frac[31]), .tb_cyc(tb_cyc),
        .level(e_lvl[g]), .ev(e_ev[g]), .ev_ns(e_ns[64*g +: 64]), .ev_cyc(e_cyc[32*g +: 32]),
        .ev_k(e_k[2*g +: 2]), .glitch(e_glitch[g])
    );
end
assign lvl_rx = e_lvl[N-1:0];
assign lvl_tx = e_lvl[2*N-1:N];

// ---------------------------------------------------------------------------
// per port
// ---------------------------------------------------------------------------
// register read values per port: 64 words (offset 0x800 + n * 0x100), flat
wire  [N*64*32-1:0] pw_flat;
// log FIFO pop strobes (from the read logic)
logic [N-1:0] rx_log_pop, tx_log_pop;
// RX log head / TX log head
wire  [N*64-1:0] rx_log_head, tx_log_head_ts;
wire  [N*32-1:0] tx_log_head_lat;
wire  [N*5-1:0]  rx_log_cnt, tx_log_cnt;

for (g = 0; g < N; g = g + 1) begin : g_port
    localparam int RI = g, TI = N + g;

    // ================= RX =================
    logic [63:0] rx_edges = '0;
    logic [31:0] rx_glitch = '0, rx_ovf = '0;
    logic [63:0] rx_last = '0;
    wire  [31:0] rx_off = rx_offset[32*g +: 32];

    logic        q_wr = 1'b0;
    logic [33:0] q_din = '0;
    assign rx_wr[g] = q_wr;
    assign rx_din[34*g +: 34] = q_din;

    always_ff @(posedge clk) begin
        q_wr <= 1'b0;
        if (e_ev[RI]) begin
            rx_edges <= rx_edges + 64'd1;
            rx_last  <= e_ns[64*RI +: 64] + {{32{rx_off[31]}}, rx_off};
            if (rx_full[g]) rx_ovf <= rx_ovf + 32'd1;
            else begin
                q_wr  <= 1'b1;
                q_din <= {e_k[2*RI +: 2], e_cyc[32*RI +: 32]};
            end
        end
        if (e_glitch[RI]) rx_glitch <= rx_glitch + 32'd1;
        if (clr || rst) begin
            rx_edges <= '0; rx_glitch <= '0; rx_ovf <= '0; rx_last <= '0;
        end
        if (rst) q_wr <= 1'b0;
    end

    // RX log FIFO (16 x 64)
    logic [63:0] rl_mem [16];
    logic [3:0]  rl_wp = '0, rl_rp = '0;
    logic [4:0]  rl_cnt = '0;
    logic [15:0] rl_ovf = '0;
    wire rl_push = e_ev[RI] && log_en && rl_cnt != 5'd16;
    wire rl_pop  = rx_log_pop[g] && rl_cnt != 5'd0;
    always_ff @(posedge clk) begin
        if (rl_push) begin
            rl_mem[rl_wp] <= e_ns[64*RI +: 64] + {{32{rx_off[31]}}, rx_off};
            rl_wp <= rl_wp + 4'd1;
        end
        if (e_ev[RI] && log_en && rl_cnt == 5'd16) rl_ovf <= rl_ovf + 16'd1;
        if (rl_pop) rl_rp <= rl_rp + 4'd1;
        rl_cnt <= rl_cnt + 5'(rl_push) - 5'(rl_pop);
        if (clr || rst) begin
            rl_wp <= '0; rl_rp <= '0; rl_cnt <= '0; rl_ovf <= '0;
        end
    end
    assign rx_log_head[64*g +: 64] = rl_mem[rl_rp];
    assign rx_log_cnt[5*g +: 5] = rl_cnt;

    // ================= TX =================
    // completions tx_clk -> clk
    wire [31:0] cpl_dout;
    wire        cpl_empty, cpl_full, cpl_wr_busy, cpl_rd_busy;
    logic       cpl_rd;
    logic       cpl_tgl = 1'b0, cplovf_tgl = 1'b0;
    always_ff @(posedge tx_clk[g]) begin
        if (tx_cpl_valid[g]) cpl_tgl <= !cpl_tgl;
        if (tx_cpl_valid[g] && (cpl_full || cpl_wr_busy)) cplovf_tgl <= !cplovf_tgl;
    end

    xpm_fifo_async #(
        .FIFO_MEMORY_TYPE("distributed"), .FIFO_WRITE_DEPTH(16), .WRITE_DATA_WIDTH(32),
        .READ_DATA_WIDTH(32), .READ_MODE("fwft"), .FIFO_READ_LATENCY(0), .CDC_SYNC_STAGES(2),
        .RELATED_CLOCKS(0), .ECC_MODE("no_ecc"), .FULL_RESET_VALUE(1), .USE_ADV_FEATURES("0000"),
        .PROG_FULL_THRESH(10), .PROG_EMPTY_THRESH(5), .RD_DATA_COUNT_WIDTH(1),
        .WR_DATA_COUNT_WIDTH(1), .DOUT_RESET_VALUE("0"), .WAKEUP_TIME(0), .SIM_ASSERT_CHK(0)
    ) cpl_fifo (
        .rst(tx_rst[g]), .wr_clk(tx_clk[g]),
        .wr_en(tx_cpl_valid[g] && !cpl_full && !cpl_wr_busy), .din(tx_cpl_cyc[32*g +: 32]),
        .full(cpl_full), .prog_full(), .wr_rst_busy(cpl_wr_busy),
        .rd_clk(clk), .rd_en(cpl_rd), .dout(cpl_dout), .empty(cpl_empty), .rd_rst_busy(cpl_rd_busy),
        .sleep(1'b0), .injectsbiterr(1'b0), .injectdbiterr(1'b0), .overflow(), .wr_data_count(),
        .almost_full(), .wr_ack(), .underflow(), .prog_empty(), .rd_data_count(),
        .almost_empty(), .data_valid(), .sbiterr(), .dbiterr()
    );

    wire [1:0] cpl_tgl_s;
    xpm_cdc_array_single #(.DEST_SYNC_FF(3), .INIT_SYNC_FF(1), .SIM_ASSERT_CHK(0), .SRC_INPUT_REG(0), .WIDTH(2))
    cdc_cpl (.src_clk(1'b0), .src_in({cplovf_tgl, cpl_tgl}), .dest_clk(clk), .dest_out(cpl_tgl_s));
    logic [1:0] cpl_tgl_d = '0;
    always_ff @(posedge clk) cpl_tgl_d <= cpl_tgl_s;
    wire cpl_evt    = cpl_tgl_s[0] ^ cpl_tgl_d[0];
    wire cplovf_evt = cpl_tgl_s[1] ^ cpl_tgl_d[1];

    logic [63:0] tx_edges = '0, tx_cpl = '0, tx_last = '0;
    logic [31:0] tx_glitch = '0, tx_cpl_ovf = '0, tx_paired = '0, tx_stale = '0, tx_unpaired = '0;
    logic [31:0] lat_last = LAT_INVALID, lat_min = 32'h7FFF_FFFF, lat_max = 32'h8000_0000;
    logic [31:0] lat_head = LAT_INVALID;
    wire  [31:0] tx_off = tx_offset[32*g +: 32];

    // pairing FSM: P_IDLE -> (edge) P_CALC -> P_DEC -> (stale: P_CALC | done: P_IDLE)
    typedef enum logic [1:0] { P_IDLE, P_CALC, P_DEC } pst_t;
    pst_t        pst = P_IDLE;
    logic [31:0] pe_cyc = '0;
    logic [1:0]  pe_k = '0;
    logic [63:0] pe_ts = '0;
    logic [31:0] lat_q = '0;
    logic        lat_vld = 1'b0;      // a completion was available for lat_q
    logic        tl_push = 1'b0;
    logic [95:0] tl_din = '0;

    wire  [31:0] dcyc   = pe_cyc - cpl_dout;
    wire         d_big  = !dcyc[31] && (dcyc[30:28] != 3'd0);
    wire         d_neg  = dcyc[31] && (dcyc[30:28] != 3'b111);
    wire  [31:0] lat_c  = d_big ? 32'h7FFF_FFFF : d_neg ? 32'h8000_0001 :
                          ({dcyc[29:0], 2'b00} + 32'(pe_k) - 32'(PIPE_NS));

    always_comb begin
        cpl_rd = 1'b0;
        if (pst == P_DEC && lat_vld && !cpl_empty && !cpl_rd_busy &&
            ($signed(lat_q) >= $signed(tx_win_min)))
            cpl_rd = 1'b1;    // stale or paired: consume the completion
    end

    always_ff @(posedge clk) begin
        tl_push <= 1'b0;
        case (pst)
            P_IDLE: ;
            P_CALC: begin
                lat_vld <= !cpl_empty && !cpl_rd_busy;
                lat_q   <= lat_c;
                pst     <= P_DEC;
            end
            P_DEC: begin
                if (lat_vld) lat_head <= lat_q;
                if (lat_vld && $signed(lat_q) > $signed(tx_win_max)) begin
                    tx_stale <= tx_stale + 32'd1;
                    pst <= P_CALC;                       // next completion
                end else if (lat_vld && $signed(lat_q) >= $signed(tx_win_min)) begin
                    tx_paired <= tx_paired + 32'd1;
                    lat_last  <= lat_q;
                    if ($signed(lat_q) < $signed(lat_min)) lat_min <= lat_q;
                    if ($signed(lat_q) > $signed(lat_max)) lat_max <= lat_q;
                    tl_push <= 1'b1;
                    tl_din  <= {lat_q, pe_ts};
                    pst <= P_IDLE;
                end else begin
                    tx_unpaired <= tx_unpaired + 32'd1;
                    tl_push <= 1'b1;
                    tl_din  <= {LAT_INVALID, pe_ts};
                    pst <= P_IDLE;
                end
            end
            default: pst <= P_IDLE;
        endcase

        if (e_ev[TI]) begin
            tx_edges <= tx_edges + 64'd1;
            tx_last  <= e_ns[64*TI +: 64] + {{32{tx_off[31]}}, tx_off};
            // a new edge while the previous one is still being paired (only
            // possible with absurd filter settings): the old one is unpaired
            if (pst != P_IDLE) tx_unpaired <= tx_unpaired + 32'd1;
            pe_cyc <= e_cyc[32*TI +: 32];
            pe_k   <= e_k[2*TI +: 2];
            pe_ts  <= e_ns[64*TI +: 64] + {{32{tx_off[31]}}, tx_off};
            pst    <= P_CALC;
        end
        if (e_glitch[TI]) tx_glitch <= tx_glitch + 32'd1;
        if (cpl_evt)    tx_cpl <= tx_cpl + 64'd1;
        if (cplovf_evt) tx_cpl_ovf <= tx_cpl_ovf + 32'd1;

        if (clr || rst) begin
            tx_edges <= '0; tx_cpl <= '0; tx_last <= '0; tx_glitch <= '0; tx_cpl_ovf <= '0;
            tx_paired <= '0; tx_stale <= '0; tx_unpaired <= '0;
            lat_last <= LAT_INVALID; lat_min <= 32'h7FFF_FFFF; lat_max <= 32'h8000_0000;
            lat_head <= LAT_INVALID;
        end
        if (rst) pst <= P_IDLE;
    end

    // TX log FIFO (16 x {lat, ts})
    logic [95:0] tl_mem [16];
    logic [3:0]  tl_wp = '0, tl_rp = '0;
    logic [4:0]  tl_cnt = '0;
    logic [15:0] tl_ovf = '0;
    wire tl_do_push = tl_push && log_en && tl_cnt != 5'd16;
    wire tl_pop     = tx_log_pop[g] && tl_cnt != 5'd0;
    always_ff @(posedge clk) begin
        if (tl_do_push) begin
            tl_mem[tl_wp] <= tl_din;
            tl_wp <= tl_wp + 4'd1;
        end
        if (tl_push && log_en && tl_cnt == 5'd16) tl_ovf <= tl_ovf + 16'd1;
        if (tl_pop) tl_rp <= tl_rp + 4'd1;
        tl_cnt <= tl_cnt + 5'(tl_do_push) - 5'(tl_pop);
        if (clr || rst) begin
            tl_wp <= '0; tl_rp <= '0; tl_cnt <= '0; tl_ovf <= '0;
        end
    end
    assign tx_log_head_ts[64*g +: 64]  = tl_mem[tl_rp][63:0];
    assign tx_log_head_lat[32*g +: 32] = tl_mem[tl_rp][95:64];
    assign tx_log_cnt[5*g +: 5] = tl_cnt;

    // ================= register words =================
    logic [31:0] pw [64];
    always_comb begin
        for (int w = 0; w < 64; w++) pw[w] = 32'd0;
        pw[0]  = rx_edges[31:0];
        pw[1]  = rx_edges[63:32];
        pw[2]  = rx_glitch;
        pw[3]  = rx_ovf;
        pw[4]  = p_matched[64*g +: 32];
        pw[5]  = p_matched[64*g + 32 +: 32];
        pw[6]  = p_stale[32*g +: 32];
        pw[7]  = p_mismatch[32*g +: 32];
        pw[8]  = p_dlast[32*g +: 32];
        pw[9]  = p_dmin[32*g +: 32];
        pw[10] = p_dmax[32*g +: 32];
        pw[11] = p_dhead[32*g +: 32];
        pw[12] = rx_last[31:0];
        pw[13] = rx_last[63:32];
        pw[14] = rx_off;
        pw[15] = {rl_ovf, 11'd0, rl_cnt};
        pw[32] = tx_edges[31:0];
        pw[33] = tx_edges[63:32];
        pw[34] = tx_glitch;
        pw[35] = tx_cpl_ovf;
        pw[36] = tx_cpl[31:0];
        pw[37] = tx_cpl[63:32];
        pw[38] = tx_paired;
        pw[39] = tx_stale;
        pw[40] = tx_unpaired;
        pw[41] = lat_last;
        pw[42] = lat_min;
        pw[43] = lat_max;
        pw[44] = tx_last[31:0];
        pw[45] = tx_last[63:32];
        pw[46] = tx_off;
        pw[47] = {tl_ovf, 11'd0, tl_cnt};
        pw[51] = lat_head;
    end
    for (genvar w = 0; w < 64; w = w + 1) begin : g_w
        assign pw_flat[(g*64 + w)*32 +: 32] = pw[w];
    end
end

// ---------------------------------------------------------------------------
// register writes
// ---------------------------------------------------------------------------
always_ff @(posedge clk) begin
    clr_sfd <= 1'b0;
    if (reg_wr) begin
        if (reg_wa[11:8] == 4'h4) begin
            case (reg_wa[7:2])
                6'd0: begin
                    match_en <= reg_wd[0];
                    log_en   <= reg_wd[1];
                    clr_sfd  <= reg_wd[8];
                end
                6'd4: rx_win_min <= reg_wd;
                6'd5: rx_win_max <= reg_wd;
                6'd6: tx_win_min <= reg_wd;
                6'd7: tx_win_max <= reg_wd;
                6'd8: min_low    <= reg_wd[7:0];
                6'd9: min_high   <= reg_wd[7:0];
                default: ;
            endcase
        end else if (reg_wa[11:10] == 2'b10) begin
            for (int n = 0; n < N; n++) begin
                if (reg_wa[9:8] == 2'(n)) begin
                    if (reg_wa[7:2] == 6'd14) rx_offset[32*n +: 32] <= reg_wd;
                    if (reg_wa[7:2] == 6'd46) tx_offset[32*n +: 32] <= reg_wd;
                end
            end
        end
    end
    if (rst) begin
        match_en   <= 1'b1;
        log_en     <= 1'b0;
        rx_win_min <= 32'd100;
        rx_win_max <= 32'd700;
        tx_win_min <= 32'd0;
        tx_win_max <= 32'd900;
        min_low    <= 8'd25;
        min_high   <= 8'd8;
        rx_offset  <= '0;
        tx_offset  <= '0;
        clr_sfd    <= 1'b0;
    end
end

// ---------------------------------------------------------------------------
// register reads: 3-stage pipeline (address, per-port word, output)
// ---------------------------------------------------------------------------
logic        r1 = 1'b0, r2 = 1'b0;
logic [11:0] ra1 = '0, ra2 = '0;
logic [31:0] gw2 = '0;                 // global word (stage 2)
logic [31:0] pword2 [N];               // per-port word (stage 2)
logic [31:0] hi_l [N][8];              // HI latches: pairs 0,2(4),6(12),8(16:log),16(32),18(36),22(44),24(48:log)
logic [31:0] lat_l [N];                // TX log LAT latch

// latch slot of a LO word index (or -1)
function automatic int lo_slot(input logic [5:0] w);
    case (w)
        6'd0:  return 0;
        6'd4:  return 1;
        6'd12: return 2;
        6'd16: return 3;
        6'd32: return 4;
        6'd36: return 5;
        6'd44: return 6;
        6'd48: return 7;
        default: return -1;
    endcase
endfunction

always_ff @(posedge clk) begin
    rx_log_pop <= '0;
    tx_log_pop <= '0;
    r1  <= reg_rd;
    ra1 <= reg_ra;
    r2  <= r1;
    ra2 <= ra1;
    reg_rvalid <= r2;

    // stage 2: words
    gw2 <= 32'd0;
    case (ra1[7:2])
        6'd0: gw2 <= {23'd0, 1'b0, 6'd0, log_en, match_en};
        6'd1: gw2 <= {16'd0, 4'(lvl_tx), 4'(lvl_rx), 6'd0, ISERDES, locked};
        6'd2: gw2 <= RES_PS;
        6'd3: gw2 <= 32'(PIPE_NS);
        6'd4: gw2 <= rx_win_min;
        6'd5: gw2 <= rx_win_max;
        6'd6: gw2 <= tx_win_min;
        6'd7: gw2 <= tx_win_max;
        6'd8: gw2 <= {24'd0, min_low};
        6'd9: gw2 <= {24'd0, min_high};
        default: ;
    endcase
    for (int n = 0; n < N; n++) begin
        pword2[n] <= pw_flat[(n*64 + int'(ra1[7:2]))*32 +: 32];
        if (r1 && ra1[11:10] == 2'b10 && ra1[9:8] == 2'(n)) begin
            // LO reads latch HI; log reads pop
            case (ra1[7:2])
                6'd16: begin
                    pword2[n] <= rx_log_cnt[5*n +: 5] != 0 ? rx_log_head[64*n +: 32] : 32'd0;
                    hi_l[n][3] <= rx_log_cnt[5*n +: 5] != 0 ? rx_log_head[64*n + 32 +: 32] : 32'd0;
                    rx_log_pop[n] <= 1'b1;
                end
                6'd48: begin
                    pword2[n] <= tx_log_cnt[5*n +: 5] != 0 ? tx_log_head_ts[64*n +: 32] : 32'd0;
                    hi_l[n][7] <= tx_log_cnt[5*n +: 5] != 0 ? tx_log_head_ts[64*n + 32 +: 32] : 32'd0;
                    lat_l[n]   <= tx_log_cnt[5*n +: 5] != 0 ? tx_log_head_lat[32*n +: 32] : LAT_INVALID;
                    tx_log_pop[n] <= 1'b1;
                end
                6'd17: pword2[n] <= hi_l[n][3];
                6'd49: pword2[n] <= hi_l[n][7];
                6'd50: pword2[n] <= lat_l[n];
                default: begin
                    if (lo_slot(ra1[7:2]) >= 0)
                        hi_l[n][lo_slot(ra1[7:2])] <= pw_flat[(n*64 + int'(ra1[7:2]) + 1)*32 +: 32];
                    if (ra1[2] && lo_slot(ra1[7:2] - 6'd1) >= 0)
                        pword2[n] <= hi_l[n][lo_slot(ra1[7:2] - 6'd1)];
                end
            endcase
        end
    end

    // stage 3: output
    if (ra2[11:8] == 4'h4)        reg_rdata <= gw2;
    else if (ra2[11:10] == 2'b10) reg_rdata <= pword2[ra2[9:8]];
    else                          reg_rdata <= 32'd0;

    if (rst) begin
        r1 <= 1'b0;
        r2 <= 1'b0;
        reg_rvalid <= 1'b0;
    end
end

endmodule

`resetall
