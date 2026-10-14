/* SPDX-License-Identifier: MIT */
/*
 * Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
 *
 * pktrec_regs.h -- register maps of the Ethernet FMC Max (OP080) port subsystem
 * of the FPGA Packet Recorder (block-design hierarchy eth_ports):
 *
 *   PKTREC_ETH_*  pktrec_eth_ports (Vivado/src/hdl/pktrec_eth_ports_core.sv):
 *                 4-port 1G SGMII MAC/PCS (Taxi), MDIO master, PHY resets, GT APB
 *                 PS address 0x4_2008_0000, 512 KB
 *   PKTREC_M0_*   pktrec_m0_path (Vivado/src/hdl/pktrec_m0_regs.v): port datapath
 *                 (per-port idle / loopback / forward = TAP / generator), frame
 *                 counters, TAP pair mode and dynamic IFG (map 1.2), PHY
 *                 GPIO_0/1 and power-good inputs. ("m0" is historical: the block
 *                 started as the bring-up datapath.)
 *                 PS address 0x4_2002_0000, 4 KB
 *   PKTREC_CAP_*  pktrec_capture (Vivado/src/hdl/pktrec_cap_regs.sv; hierarchy
 *                 capture): capture control, per-port capture counters, record
 *                 merge statistics and the shared timebase (PHC)
 *                 PS address 0x4_2003_0000, 4 KB
 *   PKTREC_RPL_*  pktrec_replay (Vivado/src/hdl/pktrec_replay.sv; hierarchy
 *                 replay): capture replay - record parser, frame store,
 *                 scheduler against the timebase, output into one port's TX
 *                 PS address 0x4_2004_0000, 4 KB
 *
 * Both blocks are bound to generic-uio in the device tree (user space maps them
 * through /dev/uioN; sw/pktrec-tools/pktrec-phy). All registers are 32 bits wide;
 * offsets are byte offsets from the block's base address. Plain C (macros only)
 * so it can be shared by the docs, C tools and drivers; keep it in sync with the
 * RTL headers and docs/source/design.md.
 *
 * Access types: RO = read-only, RW = read/write, WO = write-only, W1C = write 1
 * to clear.
 *
 * Port n (0..3) = FMC DPn = OP080 port Pn = DP83867 at MDIO address
 * PKTREC_PHY_ADDR(n) (0x01, 0x03, 0x0C, 0x0F).
 */

#ifndef PKTREC_REGS_H
#define PKTREC_REGS_H

#define PKTREC_ETH_BASE            0x420080000ULL
#define PKTREC_ETH_SIZE            0x80000
#define PKTREC_M0_BASE             0x420020000ULL
#define PKTREC_M0_SIZE             0x1000
#define PKTREC_CAP_BASE            0x420030000ULL
#define PKTREC_CAP_SIZE            0x1000
#define PKTREC_RPL_BASE            0x420040000ULL
#define PKTREC_RPL_SIZE            0x1000

#define PKTREC_NUM_PORTS           4
#define PKTREC_PHY_ADDR(n)         ((n) == 0 ? 0x01 : (n) == 1 ? 0x03 : (n) == 2 ? 0x0C : 0x0F)

/* ------------------------------------------------------------------------- */
/* pktrec_eth_ports: global registers                                         */
/* ------------------------------------------------------------------------- */
#define PKTREC_ETH_ID              0x000   /* RO 0x504B5245 "PKRE" */
#define PKTREC_ETH_ID_VALUE        0x504B5245
#define PKTREC_ETH_VERSION         0x004   /* RO 0x00010001 (1.1: TX/RX_MAX_LEN reset 1521) */
#define PKTREC_ETH_VERSION_1_1     0x00010001
#define PKTREC_ETH_GCTRL           0x008   /* RW */
#define   PKTREC_ETH_GCTRL_XCVR_RST      (1u << 0)   /* hold all GTs + QPLL in reset (reset 0) */
#define   PKTREC_ETH_GCTRL_PHY_RSTN_SHIFT 8          /* [11:8] PHY RESET_N pins (reset 0xF = released) */
#define   PKTREC_ETH_GCTRL_PHY_RSTN_MASK (0xFu << 8)
#define PKTREC_ETH_GSTATUS         0x00C   /* RO */
#define   PKTREC_ETH_GSTATUS_GTPOWERGOOD (1u << 0)
#define   PKTREC_ETH_GSTATUS_QPLL0_LOCK  (1u << 1)
#define   PKTREC_ETH_GSTATUS_QPLL1_LOCK  (1u << 2)   /* QPLL1 is powered down: 0 */
#define   PKTREC_ETH_GSTATUS_LINK_UP_SHIFT 4         /* [7:4] link_up per port */
/*
 * MDIO master (Taxi taxi_mdio_master, Clause 22 frames on the shared OP080 bus).
 * Write MDIO_CMD to issue one frame:
 *   [31:30] = 01 (start), [29:28] op: 01 write, 10 read, [27:23] PHY address,
 *   [22:18] register, [15:0] write data ([17:16], the turnaround, is forced).
 * Then poll MDIO_STATUS until BUSY = 0 (and, for a read, RD_VALID = 1) and read
 * MDIO_RDATA. A command written while BUSY is dropped (DROPPED = 1).
 * DP83867 extended registers (> 0x1F): REGCR(0x0D) = 0x001F, ADDAR(0x0E) = reg,
 * REGCR = 0x401F, then read / write ADDAR.
 */
#define PKTREC_ETH_MDIO_CMD        0x010   /* WO (reads back the last command) */
#define   PKTREC_ETH_MDIO_CMD_START      (1u << 30)
#define   PKTREC_ETH_MDIO_CMD_OP_WRITE   (1u << 28)
#define   PKTREC_ETH_MDIO_CMD_OP_READ    (2u << 28)
#define   PKTREC_ETH_MDIO_CMD_PHY(a)     (((a) & 0x1Fu) << 23)
#define   PKTREC_ETH_MDIO_CMD_REG(r)     (((r) & 0x1Fu) << 18)
#define PKTREC_ETH_MDIO_RDATA      0x014   /* RO [15:0] last read data */
#define PKTREC_ETH_MDIO_STATUS     0x018   /* RO */
#define   PKTREC_ETH_MDIO_STATUS_BUSY     (1u << 0)
#define   PKTREC_ETH_MDIO_STATUS_RD_VALID (1u << 1)
#define   PKTREC_ETH_MDIO_STATUS_DROPPED  (1u << 2)
#define PKTREC_ETH_MDIO_DIV        0x01C   /* RW [7:0] MDC half period - 1 in ctrl_clk cycles
                                              (reset 49: 1 MHz MDC at 100 MHz) */

/* pktrec_eth_ports: per-port registers at PKTREC_ETH_PORT(n) + offset */
#define PKTREC_ETH_PORT(n)         (0x100 + (n) * 0x40)
#define PKTREC_ETH_P_CTRL          0x00    /* RW (change only with the port idle) */
#define   PKTREC_ETH_CTRL_TX_EN          (1u << 0)   /* reset 1 */
#define   PKTREC_ETH_CTRL_RX_EN          (1u << 1)   /* reset 1 */
#define   PKTREC_ETH_CTRL_TX_PAD_EN      (1u << 2)   /* reset 0 in this design (TAP fidelity) */
#define   PKTREC_ETH_CTRL_AN_EN          (1u << 3)   /* reset 1 */
#define   PKTREC_ETH_CTRL_AN_RESTART     (1u << 4)   /* level: write 1, then 0 */
#define   PKTREC_ETH_CTRL_AN_SGMII_EN    (1u << 5)   /* reset 1: SGMII mode */
#define   PKTREC_ETH_CTRL_AN_SGMII_AUTO  (1u << 6)   /* reset 1 */
#define   PKTREC_ETH_CTRL_GT_TX_RST      (1u << 8)
#define   PKTREC_ETH_CTRL_GT_RX_RST      (1u << 9)
#define PKTREC_ETH_P_STATUS        0x04    /* RO */
#define   PKTREC_ETH_STATUS_RX_STATUS    (1u << 0)   /* PCS sync */
#define   PKTREC_ETH_STATUS_AN_COMPLETE  (1u << 1)
#define   PKTREC_ETH_STATUS_AN_RUNNING   (1u << 2)
#define   PKTREC_ETH_STATUS_AN_TIMEOUT   (1u << 3)
#define   PKTREC_ETH_STATUS_SGMII_MODE   (1u << 4)
#define   PKTREC_ETH_STATUS_LP_LINK      (1u << 5)   /* PHY copper link (SGMII word bit 15) */
#define   PKTREC_ETH_STATUS_SPEED_SHIFT  6           /* [7:6] 00 10M, 01 100M, 10 1G */
#define   PKTREC_ETH_STATUS_FULL_DUPLEX  (1u << 8)
#define   PKTREC_ETH_STATUS_TX_RST       (1u << 9)
#define   PKTREC_ETH_STATUS_RX_RST       (1u << 10)
#define   PKTREC_ETH_STATUS_LINK_UP      (1u << 11)  /* RX_STATUS & AN_COMPLETE & LP_LINK */
#define PKTREC_ETH_P_LP_ADV        0x08    /* RO [15:0] SGMII config word from the PHY */
#define PKTREC_ETH_P_STICKY        0x0C    /* W1C [0] link down [1] bad FCS [2] bad frame
                                              [3] TX underflow [4] AN interrupt */
#define PKTREC_ETH_P_TX_IFG        0x10    /* RW [7:0] (12) */
#define PKTREC_ETH_P_TX_MAX_LEN    0x14    /* RW [15:0] incl. FCS, minus 1 (1521); longer
                                              frames are cut, sent error-terminated */
#define PKTREC_ETH_P_RX_MAX_LEN    0x18    /* RW [15:0] incl. FCS, minus 1 (1521); longer
                                              frames arrive whole with the BAD flag */
#define PKTREC_ETH_MAX_FRAME_DEFAULT 1522  /* 1518 + one 802.1Q tag (1.0 bitstreams: 1518) */
#define PKTREC_ETH_P_TX_MIN_LEN    0x1C    /* RW [7:0] excl. FCS, minus 1 (59) */

/* Taxi GT control registers of lane n (16-bit APB, 32-bit accesses) */
#define PKTREC_ETH_GT_APB(n)       (0x40000 + (n) * 0x10000)

/* ------------------------------------------------------------------------- */
/* pktrec_m0_path                                                            */
/* ------------------------------------------------------------------------- */
#define PKTREC_M0_ID               0x000   /* RO 0x504B4D30 "PKM0" */
#define PKTREC_M0_ID_VALUE         0x504B4D30
#define PKTREC_M0_VERSION          0x004   /* RO 0x00010006 (1.1: traffic generator + checker;
                                              1.2: TAP mode - PAIR_MODE, EFF_PATH, dynamic
                                              IFG, FWD FIFO 16 KB + fill, FLUSH, GEN BAD) */
#define PKTREC_M0_VERSION_1_1      0x00010001
#define PKTREC_M0_VERSION_1_2      0x00010002
#define PKTREC_M0_VERSION_1_3      0x00010003   /* 1.3: PATH_RPL, EFF_PATH[11:8] */
#define PKTREC_M0_VERSION_1_4      0x00010004   /* 1.4: GEN_VLAN, checker skips a tag */
#define PKTREC_M0_VERSION_1_5      0x00010005   /* 1.5: checker fix (untagged PRSQ counted) */
#define PKTREC_M0_VERSION_1_6      0x00010006   /* 1.6: IFG_CTRL reset 0x000C0C00 (shrink off) */
#define PKTREC_M0_PATH_CTRL        0x008   /* RW [2n+1:2n] TX source of port n (reset 0) */
#define   PKTREC_M0_PATH_IDLE            0u          /* nothing is sent */
#define   PKTREC_M0_PATH_LOOP            1u          /* own RX (RX n -> TX n) */
#define   PKTREC_M0_PATH_FWD             2u          /* pair partner's RX (RX n^1 -> TX n) */
#define   PKTREC_M0_PATH_GEN             3u          /* the port's traffic generator (1.1) */
#define   PKTREC_M0_PATH_SHIFT(n)        (2 * (n))
#define PKTREC_M0_CNT_CTRL         0x00C   /* WO [0] 1 = clear all counters and IO_STICKY */
#define PKTREC_M0_IO_STATUS        0x010   /* RO [3:0] GPIO_0 P0..P3, [7:4] GPIO_1 P0..P3,
                                              [8] PG_1V0, [9] PG_2V5, [19:16] link_up */
#define PKTREC_M0_IO_STICKY        0x014   /* W1C [3:0] GPIO_0 rose, [7:4] GPIO_1 rose */
#define PKTREC_M0_PAIR_MODE        0x018   /* RW (1.2) [2p+1:2p] mode of pair p (P0/P1 = 0,
                                              P2/P3 = 1). Informational: written by
                                              pktrec-phy together with PATH_CTRL, read
                                              by pktrec-cap into the file header. Reset 0 */
#define   PKTREC_M0_PAIR_MONITOR         0u          /* both ports IDLE (receive only) */
#define   PKTREC_M0_PAIR_TAP             1u          /* both ports FWD (inline TAP) */
#define   PKTREC_M0_PAIR_SHIFT(p)        (2 * (p))
#define PKTREC_M0_EFF_PATH         0x01C   /* RO (1.2) [2n+1:2n] TX source port n uses now
                                              (PATH_CTRL coding; follows PATH_CTRL at the
                                              next frame boundary). (1.3) [8+n] = port n
                                              sends replay frames now ([2n+1:2n] read 0) */
#define   PKTREC_M0_EFF_RPL(n)           (1u << (8 + (n)))
#define PKTREC_M0_PATH_RPL         0x020   /* RW (1.3) [n] = TX port n in path mode 4 REPLAY:
                                              its TX source is the replay scheduler
                                              (PKTREC_RPL_*), overriding PATH_CTRL
                                              [2n+1:2n] (keep those at IDLE). A port's
                                              replay FIFO is drained while the bit is 0.
                                              Replay and TAP forwarding on the same pair
                                              are mutually exclusive (software rule:
                                              pktrec-phy / pktrec-replay refuse). Reset 0 */
#define   PKTREC_M0_PATH_REPLAY          4u          /* path mode 4 (software name) */

/* pktrec_m0_path: per-port 32-bit counters (wrap) at PKTREC_M0_PORT(n) + offset */
#define PKTREC_M0_PORT(n)          (0x100 + (n) * 0x40)
#define PKTREC_M0_P_RX_GOOD        0x00    /* frames received OK (MAC) */
#define PKTREC_M0_P_RX_BAD         0x04    /* frames received with an error */
#define PKTREC_M0_P_TX_GOOD        0x08    /* frames transmitted (MAC) */
#define PKTREC_M0_P_TX_UNDERFLOW   0x0C    /* frames aborted by TX underflow (expect 0) */
#define PKTREC_M0_P_DROP_LOOP      0x10    /* frames for TX n dropped by the LOOP FIFO */
#define PKTREC_M0_P_DROP_FWD       0x14    /* frames for TX n dropped by the FWD FIFO */
#define PKTREC_M0_P_GPIO0_EDGES    0x18    /* rising edges of GPIO_0 (RX SFD) */
#define PKTREC_M0_P_GPIO1_EDGES    0x1C    /* rising edges of GPIO_1 (TX SFD) */
/* TAP forwarding / dynamic inter-frame gap of TX port n (map 1.2). The TX
 * MAC's inter-frame gap is IFG_NOM, or IFG_MIN while the reduced gap is active:
 * it starts when the FWD FIFO fill (bytes, counting the frame being received)
 * exceeds IFG_HI and ends when it falls below IFG_LO. Keep IFG_LO above the
 * largest frame: the reset 2048 leaves >= 500 B of margin over the 1522-byte
 * MAC limit; raise IFG_LO / IFG_HI together with PKTREC_ETH_P_RX/TX_MAX_LEN for
 * longer frames (pktrec-phy maxlen does this). The shell's TX_IFG register is
 * not used (EXT_TX_IFG = 1).
 * Map 1.6: reset DYN_EN 0, IFG_MIN 12 - the reduced gap is retired (the DP83867
 * loses frames after SGMII gaps < 12 B, measured 2026-10-14) and kept only for
 * experiments; a partner faster than the board at sustained 100 % utilisation
 * fills the FWD FIFO and its excess is dropped and counted (DROP_FWD). */
#define PKTREC_M0_P_IFG_CTRL       0x20    /* RW [0] DYN_EN (0), [15:8] IFG_NOM (12),
                                              [23:16] IFG_MIN (12), bytes */
#define   PKTREC_M0_IFG_DYN_EN           (1u << 0)
#define   PKTREC_M0_IFG_NOM_SHIFT        8
#define   PKTREC_M0_IFG_MIN_SHIFT        16
#define PKTREC_M0_P_IFG_THRESH     0x24    /* RW [15:0] IFG_HI (3072), [31:16] IFG_LO (2048) */
#define PKTREC_M0_P_FWD_FILL       0x28    /* RO [15:0] FWD FIFO fill now, [31:16] max since
                                              CNT_CTRL clear (bytes; FIFO = 16384) */
#define PKTREC_M0_P_IFG_STATUS     0x2C    /* RO [0] reduced gap active, [15:8] gap in use */
#define PKTREC_M0_P_IFG_RED_CYC_LO 0x30    /* RO 48-bit: tx_clk cycles (16 ns) with the */
#define PKTREC_M0_P_IFG_RED_CYC_HI 0x34    /*    reduced gap (LO read latches HI) */
#define PKTREC_M0_P_IFG_RED_ENTRIES 0x38   /* RO times the reduced gap started */
#define PKTREC_M0_P_FLUSH          0x3C    /* RO frames discarded from a FIFO the port no
                                              longer selects (PATH_CTRL change) */
#define PKTREC_M0_FWD_FIFO_BYTES   16384   /* FWD FIFO per TX port (LOOP: 4096) */
/* (since capture map 1.2 the GPIO levels and edges come from the SFD sampler in the capture
 * block -- pktrec_sfd_io, sampled at ~1 ns -- re-synchronised into ctrl_clk;
 * IO_STATUS / IO_STICKY / GPIOn_EDGES behave as before) */

/*
 * pktrec_m0_path: per-port traffic generator (pktrec_gen) and receive checker
 * (pktrec_gen_chk), register map 1.1, at PKTREC_M0_GEN(n) + offset.
 * The generator sends when PATH_CTRL selects PKTREC_M0_PATH_GEN for the port
 * and GEN_CTRL.ENABLE goes 0 -> 1 (which reloads SEQ_FIRST / COUNT and clears
 * GEN_FRAMES / GEN_BYTES). Change the other GEN_* registers only while stopped.
 * Frame formats (LEN = bytes without FCS, 60..16383; the MAC appends the FCS):
 *   FORMAT 0 (PRSQ): the exact layout of test/gen_seq.py (Ethernet / IPv4
 *     192.0.2.1 -> 192.0.2.2 / UDP 50000 -> 50001 / "PRSQ" / stream u32 BE /
 *     sequence u64 BE / zeros), so test/check_pcap.py verifies it unchanged
 *     (stream key "prsq:<GEN_STREAM>")
 *   FORMAT 1 (raw):  dst / src / GEN_ETYPE / sequence u32 BE / zeros
 * Rate: one frame start at most every ceil((LEN + 4 + 8 + GEN_IFG) / 2) tx_clk
 * cycles (16 ns); GEN_IFG = 12 is line rate. Frames longer than the MAC's
 * TX_MAX_LEN (1522 incl. FCS by default; 1518 in eth map 1.0) are cut by the
 * MAC: raise PKTREC_ETH_P_TX_MAX_LEN for jumbo frames.
 * GEN_VLAN.EN (1.4) inserts an 802.1Q tag after the source MAC in either format
 * (as gen_seq.py --vlan); the checker recognises one tag in received frames.
 * The checker counts in-order / lost / duplicate sequence numbers of received
 * generator frames (CHK_CTRL.FORMAT / ETYPE select the format; one stream per
 * port); CHK_CTRL.ENABLE 0 -> 1 clears its counters.
 * 64-bit values: reading _LO latches _HI (one latch per port).
 */
#define PKTREC_M0_GEN(n)           (0x200 + (n) * 0x80)
#define PKTREC_M0_GEN_CTRL         0x00    /* RW */
#define   PKTREC_M0_GEN_CTRL_ENABLE      (1u << 0)
#define   PKTREC_M0_GEN_CTRL_RAW         (1u << 1)   /* FORMAT 1 */
#define   PKTREC_M0_GEN_CTRL_RAND_LEN    (1u << 2)   /* LEN + (LFSR & LEN_MASK) per frame */
#define   PKTREC_M0_GEN_CTRL_BAD         (1u << 3)   /* (1.2) send every frame error-
                                                        terminated (TX tuser; /V/ over FCS) */
#define PKTREC_M0_GEN_STATUS       0x04    /* RO [0] running, [1] done (COUNT reached) */
#define PKTREC_M0_GEN_LEN          0x08    /* RW [13:0] bytes without FCS (reset 60) */
#define PKTREC_M0_GEN_LEN_MASK     0x0C    /* RW [13:0] random length mask (reset 0) */
#define PKTREC_M0_GEN_IFG          0x10    /* RW [15:0] inter-frame gap, bytes (reset 12) */
#define PKTREC_M0_GEN_COUNT        0x14    /* RW frames per start, 0 = until stopped */
#define PKTREC_M0_GEN_DST_LO       0x18    /* RW dst MAC bytes 2..5 (byte 5 = [7:0]) */
#define PKTREC_M0_GEN_DST_HI       0x1C    /* RW [15:0] dst MAC bytes 0..1 (reset ff:ff:..) */
#define PKTREC_M0_GEN_SRC_LO       0x20    /* RW src MAC (reset 02:00:00:00:00:0n) */
#define PKTREC_M0_GEN_SRC_HI       0x24
#define PKTREC_M0_GEN_ETYPE        0x28    /* RW [15:0] raw format EtherType (0x88B5) */
#define PKTREC_M0_GEN_STREAM       0x2C    /* RW PRSQ stream id (reset n) */
#define PKTREC_M0_GEN_SEQ_FIRST    0x30    /* RW first sequence number */
#define PKTREC_M0_GEN_FRAMES_LO    0x34    /* RO 64: frames sent since the last start */
#define PKTREC_M0_GEN_FRAMES_HI    0x38
#define PKTREC_M0_GEN_BYTES_LO     0x3C    /* RO 64: wire bytes incl. FCS (no preamble/IFG) */
#define PKTREC_M0_GEN_BYTES_HI     0x40
#define PKTREC_M0_GEN_VLAN         0x44    /* RW (1.4) [15:0] TCI, [16] EN (reset 0) */
#define   PKTREC_M0_GEN_VLAN_EN          (1u << 16)
#define PKTREC_M0_CHK_CTRL         0x48    /* RW [0] ENABLE, [1] FORMAT raw, [31:16] ETYPE */
#define PKTREC_M0_CHK_FRAMES       0x4C    /* RO good generator frames received */
#define PKTREC_M0_CHK_LOST         0x50    /* RO sum of sequence gaps */
#define PKTREC_M0_CHK_ERRORS       0x54    /* RO duplicate / out-of-order sequence numbers */
#define PKTREC_M0_CHK_BAD          0x58    /* RO generator frames with a MAC error */
#define PKTREC_M0_CHK_LAST_SEQ_LO  0x5C    /* RO 64: highest sequence number seen */
#define PKTREC_M0_CHK_LAST_SEQ_HI  0x60

/* ------------------------------------------------------------------------- */
/* pktrec_capture: capture control, counters and timebase (dp_clk domain)    */
/* ------------------------------------------------------------------------- */
/*
 * There is no port-mode register in the capture block: monitor/TAP forwarding
 * is PKTREC_M0_PATH_CTRL + PKTREC_M0_PAIR_MODE (pktrec_m0_path); capture always
 * records what each port RECEIVES.
 *
 * Datapath (see docs/source/design.md "Capture path"): per port n the MAC RX
 * stream is tapped (in parallel with the TAP forward path), each frame is
 * stored whole in a 16 KB per-port frame FIFO (dropped whole and counted when
 * it does not fit), turned into a record (include/pktrec_format.h) and the
 * records of the four ports are merged round robin into ONE 128-bit stream
 * that goes straight into the fdrec packetizer with back-pressure (bypassing
 * fdrec_ingest's beat-dropping FIFO) when CTRL.SRC_SEL = 1.
 *
 * 64-bit counters are _LO/_HI pairs: reading _LO latches the matching _HI
 * (one latch per counter), so read _LO then _HI. Counters that originate in a
 * port's RX clock arrive as one coherent per-port snapshot, at most ~0.5 us old.
 *
 * Capture start (with the fdrec driver; the capture app does this):
 *   1. CTRL = SRC_SEL (ENABLE = 0, FILL = 0); optionally TB_SET to CLOCK_REALTIME
 *   2. CTRL |= CLEAR (counters and seq := 0; self-clearing)
 *   3. PORT_EN / SNAPLEN (only while ENABLE = 0)
 *   4. FDREC_IOC_START without the TPG flag (SOFT_RST + packetizer enable)
 *   5. CTRL = SRC_SEL | ENABLE  -- ports accept frames that START from now on
 * There is no lock to wait for after TB_SET/TB_ADJ: they apply on the next
 * dp_clk cycle (see the timebase notes below).
 * Capture stop:
 *   1. CTRL = SRC_SEL           -- frames in progress complete, no new ones
 *   2. poll STATUS.IDLE = 1     -- every accepted frame is now a record that
 *                                  the merge has handed to the recorder
 *   3. read BYTES_OUT (= valid stream bytes) and the counters
 *   4. CTRL = SRC_SEL | FILL    -- zero fill units push the tail through the
 *                                  DMA at up to 4 GB/s
 *   5. keep collecting filled buffers until the total >= BYTES_OUT (the rest of
 *      the last buffer is fill), then FDREC_IOC_STOP (its drain completes at
 *      once because FILL keeps the DMA fed), then CTRL = 0 (or SRC_SEL)
 * The fdrec driver discards buffers that are still queued or uncollected at
 * STOP, so collect up to BYTES_OUT BEFORE calling STOP. Writing CTRL = 0 after
 * FDREC_IOC_STOP is harmless: the packetizer is already disabled and the merge
 * is idle (IDLE was 1 and ENABLE is 0), so switching the recorder source back
 * to the TPG loses no record data (at most fill units still sitting in the
 * packetizer's 2-beat slice; the next FDREC_IOC_START soft-resets it and the
 * merge restarts on a record boundary anyway). Do NOT change SRC_SEL while a
 * recording runs.
 * Frame size limits: the MAC delivers every frame whole (frames longer than
 * the MAC's RX_MAX_LEN, 1522 incl. FCS by default, arrive with the BAD flag);
 * the capture stores up to PORT_FIFO_BYTES (16384) bytes per frame -- a frame
 * longer than the per-port FIFO is dropped whole and counted in FRAMES_DROP.
 * So cap_len <= PORT_FIFO_BYTES, orig_len <= cap_len + 4 when not truncated
 * (orig_len saturates at 65535).
 * A recorder SOFT_RST (every FDREC_IOC_START) while the merge is mid-record
 * discards the rest of that record (SRST_ABORTS), so the recorded stream always
 * starts on a record boundary.
 */
#define PKTREC_CAP_ID              0x000   /* RO 0x504B4350 "PKCP" */
#define PKTREC_CAP_ID_VALUE        0x504B4350
#define PKTREC_CAP_VERSION         0x004   /* RO 0x00010002: register map 1.2, record format v1
                                              1.1 vs 1.0: TB_STATUS / STATUS[23:16] = MAC clock
                                              domain valid (no "locked" anymore), new MAC_OFFSET
                                              1.2: PHY SFD timestamping (PKTREC_SFD_*, 0x400..),
                                              records carry SFD timestamps (flags bit2/bit3) */
#define PKTREC_CAP_VERSION_1_1     0x00010001
#define PKTREC_CAP_VERSION_1_2     0x00010002
#define PKTREC_CAP_CTRL            0x008   /* RW */
#define   PKTREC_CAP_CTRL_ENABLE         (1u << 0)   /* global capture enable (reset 0);
                                                        sampled at each frame's start */
#define   PKTREC_CAP_CTRL_FILL           (1u << 1)   /* merge sends all-zero fill units
                                                        whenever it has no record */
#define   PKTREC_CAP_CTRL_SRC_SEL        (1u << 2)   /* recorder source: 0 = fdrec TPG via
                                                        fdrec_ingest (reset; fdrec --rate
                                                        tests), 1 = capture records */
#define   PKTREC_CAP_CTRL_CLEAR          (1u << 8)   /* self-clearing: clear every counter,
                                                        HWM and seq (reads 0) */
#define PKTREC_CAP_STATUS          0x00C   /* RO */
#define   PKTREC_CAP_STATUS_IDLE         (1u << 0)   /* no frame in progress or queued on any
                                                        port, merge empty */
#define   PKTREC_CAP_STATUS_MERGE_BUSY   (1u << 1)   /* merge inside a record */
#define   PKTREC_CAP_STATUS_PORT_IDLE_SHIFT 8        /* [11:8] per-port idle */
#define   PKTREC_CAP_STATUS_RX_ACTIVE_SHIFT 12       /* [15:12] port receiving a captured frame */
#define   PKTREC_CAP_STATUS_TB_VALID_SHIFT 16        /* [23:16] = TB_STATUS[7:0] */
#define PKTREC_CAP_PORT_EN         0x010   /* RW [3:0] per-port capture enable (reset 0xF);
                                              change only while CTRL.ENABLE = 0 */
#define PKTREC_CAP_SNAPLEN         0x014   /* RW [15:0] max bytes stored per frame (FCS
                                              excluded); 0 = whole frames (reset 0);
                                              change only while CTRL.ENABLE = 0 */
#define PKTREC_CAP_DP_CLK_HZ       0x018   /* RO dp_clk frequency (timebase clock) */
#define PKTREC_CAP_PORT_FIFO_BYTES 0x01C   /* RO per-port frame FIFO size (16384) */
#define PKTREC_CAP_BYTES_OUT_LO    0x020   /* RO 64: record bytes handed to the recorder */
#define PKTREC_CAP_BYTES_OUT_HI    0x024
#define PKTREC_CAP_RECORDS_OUT_LO  0x028   /* RO 64: records handed to the recorder */
#define PKTREC_CAP_RECORDS_OUT_HI  0x02C
#define PKTREC_CAP_FILL_BEATS_LO   0x030   /* RO 64: 16-byte fill units sent */
#define PKTREC_CAP_FILL_BEATS_HI   0x034
#define PKTREC_CAP_BP_CYCLES_LO    0x038   /* RO 64: dp_clk cycles a beat waited for the
                                              recorder (back-pressure) */
#define PKTREC_CAP_BP_CYCLES_HI    0x03C
#define PKTREC_CAP_SRST_ABORTS     0x040   /* RO records cut by a recorder SOFT_RST */
#define PKTREC_CAP_LEN_FIXUPS      0x044   /* RO records whose FIFO data length disagreed
                                              with cap_len, or that lost their data to a
                                              port reset (link drop); data zero-filled /
                                              cut to keep the stream framed; expect 0 */

/*
 * Timebase (pktrec_timebase): 64-bit ns counter in dp_clk with a 32.32 ns
 * increment per dp_clk cycle (PHC-style; reset INC = 1e9 / DP_CLK_HZ, i.e.
 * 4.0004 ns at 249.975 MHz). A dp_clk cycle counter is carried Gray-coded into
 * the 4 RX and 4 TX MAC clocks; the MAC latches it at SFD and the record
 * header converts it back:  ts = TB_NOW - (cycles since SFD) * INC + MAC_OFFSET.
 *   settime:  TB_SET_LO/HI = t, then TB_CTRL = SET
 *   adjtime:  TB_ADJ_LO/HI = signed delta ns, then TB_CTRL = ADJ
 *   adjfine:  TB_INC_FRAC = f, then TB_INC_NS = n (the NS write applies both)
 *   gettime:  read TB_NOW_LO, then TB_NOW_HI (coherent)
 * SET / ADJ / INC take effect on the next dp_clk cycle: nothing to wait for.
 * Change them before a capture starts (frames that wait in the capture FIFOs
 * across a SET/ADJ would get timestamps on the wrong side of the step).
 * Accuracy of a MAC timestamp: 16 ns MAC clock quantisation + <= 8 ns
 * sampling jitter + a constant PHY/PCS/GT latency;
 * MAC_OFFSET removes the constant latency of the cycle-counter copy (52 ns,
 * from simulation).
 */
#define PKTREC_CAP_TB_CTRL         0x080   /* WO [0] SET, [1] ADJ (reads 0) */
#define   PKTREC_CAP_TB_CTRL_SET         (1u << 0)
#define   PKTREC_CAP_TB_CTRL_ADJ         (1u << 1)
#define PKTREC_CAP_TB_INC_FRAC     0x084   /* RW fractional ns of the increment (2^-32) */
#define PKTREC_CAP_TB_INC_NS       0x088   /* RW [7:0] integer ns; a write applies
                                              {INC_NS, INC_FRAC} atomically */
#define PKTREC_CAP_TB_STATUS       0x08C   /* RO [3:0] RX n MAC clock domain out of reset (link
                                              up / GT RX ready), [7:4] TX n; informational only */
#define PKTREC_CAP_TB_NOW_LO       0x090   /* RO 64: current time, ns */
#define PKTREC_CAP_TB_NOW_HI       0x094
#define PKTREC_CAP_TB_SET_LO       0x098   /* RW 64: value loaded by TB_CTRL.SET */
#define PKTREC_CAP_TB_SET_HI       0x09C
#define PKTREC_CAP_TB_ADJ_LO       0x0A0   /* RW 64 (signed): added by TB_CTRL.ADJ */
#define PKTREC_CAP_TB_ADJ_HI       0x0A4
#define PKTREC_CAP_MAC_OFFSET      0x0A8   /* RW signed ns added to every MAC timestamp
                                              (reset 52 = sync latency of the copy) */

/* pktrec_capture: per-port counters at PKTREC_CAP_PORT(n) + offset (64-bit
 * unless noted). Only frames that START while the port is enabled count.
 * FRAMES_RX = RECORDS + FRAMES_DROP once STATUS.IDLE = 1. */
#define PKTREC_CAP_PORT(n)         (0x100 + (n) * 0x40)
#define PKTREC_CAP_P_FRAMES_RX_LO    0x00  /* frames seen (good + bad, incl. dropped) */
#define PKTREC_CAP_P_FRAMES_RX_HI    0x04
#define PKTREC_CAP_P_FRAMES_BAD_LO   0x08  /* of which flagged bad by the MAC */
#define PKTREC_CAP_P_FRAMES_BAD_HI   0x0C
#define PKTREC_CAP_P_FRAMES_DROP_LO  0x10  /* dropped whole: FIFO full / oversize */
#define PKTREC_CAP_P_FRAMES_DROP_HI  0x14
#define PKTREC_CAP_P_BYTES_RX_LO     0x18  /* wire bytes (incl. FCS) of FRAMES_RX */
#define PKTREC_CAP_P_BYTES_RX_HI     0x1C
#define PKTREC_CAP_P_BYTES_DROP_LO   0x20  /* wire bytes of FRAMES_DROP */
#define PKTREC_CAP_P_BYTES_DROP_HI   0x24
#define PKTREC_CAP_P_FRAMES_TRUNC_LO 0x28  /* frames cut by SNAPLEN */
#define PKTREC_CAP_P_FRAMES_TRUNC_HI 0x2C
#define PKTREC_CAP_P_RECORDS_LO      0x30  /* records handed to the merge */
#define PKTREC_CAP_P_RECORDS_HI      0x34
#define PKTREC_CAP_P_FIFO_HWM        0x38  /* RW 32: frame FIFO high-water mark in bytes;
                                              any write clears it; CTRL.CLEAR clears it too */
#define PKTREC_CAP_P_SEQ_NEXT        0x3C  /* RO [15:0] seq of the next frame */

/* ------------------------------------------------------------------------- */
/* pktrec_capture: PHY SFD timestamping (map 1.2, pktrec_sfd), capture block */
/* offsets 0x400..0xBFF (dp_clk)                                             */
/* ------------------------------------------------------------------------- */
/*
 * Each DP83867 drives GPIO_0 high from the RX start-of-frame delimiter to the
 * end of the frame and GPIO_1 likewise for TX (pktrec-phy init: GPIO_MUX_CTRL
 * 0x0012). The eight pins are oversampled by ISERDESE3 at 4 samples per dp_clk
 * cycle (~1.0 ns, SFD_RES_PS) and every rising edge that passes the glitch
 * filter (low for >= SFD_MIN_LOW cycles before, high for >= SFD_MIN_HIGH after)
 * gets a timestamp of the shared timebase: t_sfd = time of the first high
 * sample, sampler pipeline removed (SFD_PIPE_NS). Quantisation: the timestamp
 * is up to 1 sample (1 ns) earlier than the true pin edge (uniform in (-1, 0]
 * ns in simulation); plus the constant pin/translator/PHY offset, calibrated
 * per port with RX_OFFSET / TX_OFFSET.
 *
 * RX: each edge is queued (16 entries) for port n's capture front end, which
 * matches it to the received frame (oldest entry whose raw delta d =
 * MAC_raw - t_sfd lies in [RX_WIN_MIN, RX_WIN_MAX]; MAC_raw = the MAC's cycle
 * stamp x ~4 ns, MAC_OFFSET NOT applied): match -> record ts = t_sfd +
 * RX_OFFSET, flags bit2 (TS_MAC) = 0; older entries are dropped as stale
 * (RX_STALE, flags bit3 SFD_RESYNC on that frame); no entry -> MAC timestamp
 * (bit2 = 1) and RX_MISMATCH. Every frame consumes its entry, also frames that
 * are dropped or not captured. The window must stay narrower than one minimum
 * frame time (672 ns at 1 Gb/s) so that neighbouring frames' SFDs can never
 * fall inside it.
 * TX: each edge is paired in order with the MAC's TX completions of port n
 * (lat = t_sfd - cpl_raw in [TX_WIN_MIN, TX_WIN_MAX]; older completions are
 * stale): TX_LAT_LAST/MIN/MAX = MAC SFD (cycle stamp, no MAC_OFFSET) -> PHY
 * TX SFD pin.
 * All deltas (RX_DELTA_*, RX_HEAD_DELTA, TX_LAT_*) are raw: no RX/TX_OFFSET, no
 * MAC_OFFSET; signed ns; 0x80000000 = none yet. *_HEAD_* = the delta of the
 * last entry evaluated, whatever the outcome (use it to place the window).
 * Log FIFOs (SFD_CTRL.LOG_EN): the last 16 RX / TX SFD timestamps per port
 * (+ the TX latency of each TX edge) for software, e.g. TAP latency =
 * TX SFD (P1) - RX SFD (P0) of the same frame. Reading *_LOG_TS_LO pops the
 * oldest entry and latches _HI (and TX_LOG_LAT); read _LO, _HI, (_LAT).
 * 64-bit counters: reading _LO latches _HI (per value). CTRL.CLEAR (capture)
 * and SFD_CTRL.CLEAR clear all SFD counters, min/max and logs.
 */
#define PKTREC_SFD_CTRL            0x400   /* RW */
#define   PKTREC_SFD_CTRL_MATCH_EN       (1u << 0)   /* reset 1; 0 = all records MAC-stamped */
#define   PKTREC_SFD_CTRL_LOG_EN         (1u << 1)   /* reset 0 */
#define   PKTREC_SFD_CTRL_CLEAR          (1u << 8)   /* self-clearing */
#define PKTREC_SFD_STATUS          0x404   /* RO [0] sampler MMCM locked, [1] ISERDES sampler
                                              (0 = IDDR, 2 ns), [11:8] RX SFD levels P0..P3,
                                              [15:12] TX SFD levels */
#define PKTREC_SFD_RES_PS          0x408   /* RO sample spacing, ps (1000) */
#define PKTREC_SFD_PIPE_NS         0x40C   /* RO sampler pipeline removed from t_sfd (16) */
#define PKTREC_SFD_RX_WIN_MIN      0x410   /* RW signed ns (reset 100) */
#define PKTREC_SFD_RX_WIN_MAX      0x414   /* RW signed ns (reset 700) */
#define PKTREC_SFD_TX_WIN_MIN      0x418   /* RW signed ns (reset 0) */
#define PKTREC_SFD_TX_WIN_MAX      0x41C   /* RW signed ns (reset 900) */
#define PKTREC_SFD_MIN_LOW         0x420   /* RW [7:0] dp_clk cycles low before an edge (25) */
#define PKTREC_SFD_MIN_HIGH        0x424   /* RW [7:0] dp_clk cycles high after an edge (8) */

#define PKTREC_SFD_PORT(n)         (0x800 + (n) * 0x100)
#define PKTREC_SFD_P_RX_EDGES_LO     0x00  /* RO 64: accepted RX SFD edges */
#define PKTREC_SFD_P_RX_EDGES_HI     0x04
#define PKTREC_SFD_P_RX_GLITCH       0x08  /* RO edges rejected by the glitch filter */
#define PKTREC_SFD_P_RX_FIFO_OVF     0x0C  /* RO edges lost: match queue full */
#define PKTREC_SFD_P_RX_MATCHED_LO   0x10  /* RO 64: frames with an SFD timestamp */
#define PKTREC_SFD_P_RX_MATCHED_HI   0x14
#define PKTREC_SFD_P_RX_STALE        0x18  /* RO SFD entries discarded (no frame) */
#define PKTREC_SFD_P_RX_MISMATCH     0x1C  /* RO frames that fell back to the MAC ts */
#define PKTREC_SFD_P_RX_DELTA_LAST   0x20  /* RO signed ns MAC_raw - t_sfd of the last match */
#define PKTREC_SFD_P_RX_DELTA_MIN    0x24
#define PKTREC_SFD_P_RX_DELTA_MAX    0x28
#define PKTREC_SFD_P_RX_HEAD_DELTA   0x2C  /* RO delta of the last evaluated entry */
#define PKTREC_SFD_P_RX_LAST_TS_LO   0x30  /* RO 64: latest RX SFD time (+ RX_OFFSET) */
#define PKTREC_SFD_P_RX_LAST_TS_HI   0x34
#define PKTREC_SFD_P_RX_OFFSET       0x38  /* RW signed ns added to RX SFD times (0) */
#define PKTREC_SFD_P_RX_LOG_STATUS   0x3C  /* RO [4:0] entries, [31:16] overflows */
#define PKTREC_SFD_P_RX_LOG_TS_LO    0x40  /* RO pop */
#define PKTREC_SFD_P_RX_LOG_TS_HI    0x44
#define PKTREC_SFD_P_TX_EDGES_LO     0x80  /* RO 64: accepted TX SFD edges */
#define PKTREC_SFD_P_TX_EDGES_HI     0x84
#define PKTREC_SFD_P_TX_GLITCH       0x88
#define PKTREC_SFD_P_TX_CPL_OVF      0x8C  /* RO completions lost: pairing queue full */
#define PKTREC_SFD_P_TX_CPL_LO       0x90  /* RO 64: MAC TX completions (frames sent) */
#define PKTREC_SFD_P_TX_CPL_HI       0x94
#define PKTREC_SFD_P_TX_PAIRED       0x98  /* RO TX edges paired with a completion */
#define PKTREC_SFD_P_TX_CPL_STALE    0x9C  /* RO completions without an SFD edge */
#define PKTREC_SFD_P_TX_UNPAIRED     0xA0  /* RO TX edges without a completion */
#define PKTREC_SFD_P_TX_LAT_LAST     0xA4  /* RO signed ns t_sfd - cpl_raw */
#define PKTREC_SFD_P_TX_LAT_MIN      0xA8
#define PKTREC_SFD_P_TX_LAT_MAX      0xAC
#define PKTREC_SFD_P_TX_LAST_TS_LO   0xB0  /* RO 64: latest TX SFD time (+ TX_OFFSET) */
#define PKTREC_SFD_P_TX_LAST_TS_HI   0xB4
#define PKTREC_SFD_P_TX_OFFSET       0xB8  /* RW signed ns added to TX SFD times (0) */
#define PKTREC_SFD_P_TX_LOG_STATUS   0xBC  /* RO [4:0] entries, [31:16] overflows */
#define PKTREC_SFD_P_TX_LOG_TS_LO    0xC0  /* RO pop */
#define PKTREC_SFD_P_TX_LOG_TS_HI    0xC4
#define PKTREC_SFD_P_TX_LOG_LAT      0xC8  /* RO latency of the popped entry (0x80000000 = none) */
#define PKTREC_SFD_P_TX_HEAD_LAT     0xCC  /* RO latency of the last evaluated completion */
#define PKTREC_SFD_NONE            0x80000000u

/* ------------------------------------------------------------------------- */
/* pktrec_replay: capture replay (dp_clk), PS 0x4_2004_0000                   */
/* ------------------------------------------------------------------------- */
/*
 * The recorder plays a capture's record stream (include/pktrec_format.h) back
 * through the AXI DMA MM2S and the fdrec_core egress FIFO (fdrec driver PLAY_*
 * ioctls, like fdplay); with CTRL.SEL = 1 that stream goes to this block
 * instead of the fdrec_check sink. The block parses the records, keeps whole
 * frames in a 128 KB store (a frame is released only when complete) and releases
 * each frame into the TX MAC of CTRL.TX_PORT (which must be in path mode 4
 * REPLAY: PKTREC_M0_PATH_RPL) when the shared timebase reaches its target:
 *   TIMED:  target_i = T0 + ((ts_i - TS_FIRST) * RATE_INV) >> 16
 *   B2B:    as soon as the MAC takes it (line rate)
 *   FIXED:  target_i = T0 + i * GAP_NS
 * T0 = TB_NOW + START_DELAY at CMD.GO. The frame bytes are the captured bytes
 * (cap_len, FCS excluded); the MAC appends a new FCS. Frames shorter than 60
 * bytes go out as runts (the MAC's padding is off), truncated records (snaplen)
 * go out truncated.
 *
 * Sequence (pktrec-replay):
 *   1. PATH_RPL bit of the port set (pair not in TAP mode), STATUS.TX_REPLAY = 1
 *   2. CTRL (SEL = 1, mode, BAD_MODE, TX_PORT), RATE_INV / GAP_NS / START_DELAY,
 *      EXPECT = number of records that will be streamed
 *   3. CMD.ARM (clears counters; the parser now fills the store)
 *   4. FDREC PLAY_START (without FDREC_PLAY_CHECK: no recorder soft reset, so a
 *      capture may run at the same time) + PLAY_SUBMIT; when the store is full
 *      (STORE_LEVEL) or all is submitted: CMD.GO
 *   5. wait for STATUS.STATE = DONE (EXPECT records processed; or CMD.STOP once
 *      everything is submitted: DONE when the input has been idle and all is sent)
 *   6. CMD.ABORT at any time: the frame on the wire is completed, everything
 *      buffered is dropped, the input is drained (DISCARD_BEATS) -> IDLE.
 * While SEL = 1 and the block is IDLE / DONE / ABORTING, input beats are taken
 * and discarded so the DMA can always drain.
 * Timebase: TB_SET / TB_ADJ steps during a run move every later release
 * (pktrec-replay holds the pktrec-tb daemon's steps off); INC trims are fine.
 */
#define PKTREC_RPL_ID              0x000   /* RO 0x504B5250 "PKRP" */
#define PKTREC_RPL_ID_VALUE        0x504B5250
#define PKTREC_RPL_VERSION         0x004   /* RO 0x00010000 */
#define PKTREC_RPL_CTRL            0x008   /* RW */
#define   PKTREC_RPL_CTRL_SEL            (1u << 0)   /* playback stream -> replay (0: -> fdrec_check) */
#define   PKTREC_RPL_CTRL_MODE_SHIFT     1           /* [2:1] */
#define   PKTREC_RPL_MODE_TIMED          0u
#define   PKTREC_RPL_MODE_B2B            1u
#define   PKTREC_RPL_MODE_FIXED          2u
#define   PKTREC_RPL_CTRL_BAD_SHIFT      4           /* [5:4] records with the BAD flag: */
#define   PKTREC_RPL_BAD_GOOD            0u          /*   sent as good frames (new valid FCS) */
#define   PKTREC_RPL_BAD_ERROR           1u          /*   sent error-terminated (TX tuser: /V/) */
#define   PKTREC_RPL_BAD_SKIP            2u          /*   not sent (SKIPPED) */
#define   PKTREC_RPL_CTRL_FILTER_EN      (1u << 6)   /* replay only records of FILTER_PORT */
#define   PKTREC_RPL_CTRL_FILTER_SHIFT   8           /* [9:8] */
#define   PKTREC_RPL_CTRL_TXPORT_SHIFT   12          /* [13:12] output port (latched at GO) */
#define PKTREC_RPL_CMD             0x00C   /* WO (write 1) */
#define   PKTREC_RPL_CMD_ARM             (1u << 0)   /* IDLE/DONE -> ARMED, clears counters */
#define   PKTREC_RPL_CMD_GO              (1u << 1)   /* ARMED -> RUNNING, latches T0 */
#define   PKTREC_RPL_CMD_STOP            (1u << 2)   /* no more input: DONE when all is sent */
#define   PKTREC_RPL_CMD_ABORT           (1u << 3)   /* -> IDLE (frame on the wire completed) */
#define PKTREC_RPL_STATUS          0x010   /* RO */
#define   PKTREC_RPL_ST_STATE_MASK       0x7u        /* [2:0] */
#define   PKTREC_RPL_STATE_IDLE          0u
#define   PKTREC_RPL_STATE_ARMED         1u
#define   PKTREC_RPL_STATE_RUNNING       2u
#define   PKTREC_RPL_STATE_DONE          3u
#define   PKTREC_RPL_STATE_ABORTING      4u
#define   PKTREC_RPL_ST_STOP_REQ         (1u << 3)
#define   PKTREC_RPL_ST_UNDERRUN         (1u << 8)   /* sticky until ARM */
#define   PKTREC_RPL_ST_PARSE_ERROR      (1u << 9)   /* sticky until ARM */
#define   PKTREC_RPL_ST_LATE             (1u << 10)  /* sticky until ARM */
#define   PKTREC_RPL_ST_TX_REPLAY        (1u << 11)  /* CTRL.TX_PORT is in REPLAY (m0 EFF_PATH) */
#define   PKTREC_RPL_ST_INPUT_IDLE       (1u << 12)  /* no input beat for 256 dp_clk cycles */
#define   PKTREC_RPL_ST_SCHED_BUSY       (1u << 13)  /* a frame is being scheduled / sent */
#define   PKTREC_RPL_ST_STORE_FRAMES     (1u << 14)  /* complete frames wait in the store */
#define PKTREC_RPL_RATE_INV        0x014   /* RW 16.16 interval scale, TIMED (0x00010000 = 1x;
                                              0x8000 = twice as fast; 0x20000 = half speed) */
#define PKTREC_RPL_START_DELAY     0x018   /* RW ns from GO to T0 (1000000) */
#define PKTREC_RPL_LATE_THRESH     0x01C   /* RW ns: release later than target + this = LATE (100) */
#define PKTREC_RPL_GAP_NS          0x020   /* RW FIXED mode start-to-start interval, ns (672) */
#define PKTREC_RPL_EXPECT_LO       0x024   /* RW 64: records that will be streamed (0 = unknown, */
#define PKTREC_RPL_EXPECT_HI       0x028   /*    end the run with CMD.STOP) */
#define PKTREC_RPL_STORE_LEVEL     0x02C   /* RO [15:0] data beats in the store, [31:16] frames
                                              (metadata FIFO: 2048 frames) */
#define PKTREC_RPL_STORE_BEATS     0x030   /* RO store size in 16-byte beats (8192 = 128 KB) */
#define PKTREC_RPL_MAX_CAP         0x034   /* RO largest cap_len accepted (16384) */
#define PKTREC_RPL_T0_LO           0x038   /* RO 64: T0 (timebase ns) */
#define PKTREC_RPL_T0_HI           0x03C
#define PKTREC_RPL_TS_FIRST_LO     0x040   /* RO 64: ts of the first frame of the run */
#define PKTREC_RPL_TS_FIRST_HI     0x044
#define PKTREC_RPL_LAST_TARGET_LO  0x048   /* RO 64: target of the last scheduled frame */
#define PKTREC_RPL_LAST_TARGET_HI  0x04C
#define PKTREC_RPL_MAX_LATE        0x050   /* RO ns, release - target, max (saturates) */
#define PKTREC_RPL_LAST_LATE       0x054   /* RO ns, of the last frame */
/* 64-bit counters (read LO first: it latches HI), cleared by CMD.ARM */
#define PKTREC_RPL_RECORDS         0x080   /* valid record headers parsed */
#define PKTREC_RPL_FRAMES          0x088   /* frames sent */
#define PKTREC_RPL_BYTES           0x090   /* frame bytes sent (FCS excluded) */
#define PKTREC_RPL_PARSE_ERRORS    0x098   /* framing lost (re-synchronised) */
#define PKTREC_RPL_FILL            0x0A0   /* fill units skipped */
#define PKTREC_RPL_SKIPPED         0x0A8   /* records not sent (filter / BAD_SKIP) */
#define PKTREC_RPL_UNDERRUNS       0x0B0   /* the store ran empty and a frame was late for it */
#define PKTREC_RPL_LATE            0x0B8   /* frames released > LATE_THRESH after target */
#define PKTREC_RPL_LATE_SUM        0x0C0   /* sum of (release - target), ns: mean = / FRAMES */
#define PKTREC_RPL_BEATS_IN        0x0C8   /* 16-byte beats parsed */
#define PKTREC_RPL_DISCARD         0x0D0   /* beats discarded (not ARMED/RUNNING) */
#define PKTREC_RPL_BAD_SENT        0x0D8   /* frames sent error-terminated */
#define PKTREC_RPL_RECORDS_DONE    0x0E0   /* records fully processed (sent or skipped) */

#endif /* PKTREC_REGS_H */
