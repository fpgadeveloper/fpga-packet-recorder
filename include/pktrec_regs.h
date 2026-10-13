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
 *   PKTREC_M0_*   pktrec_m0_path (Vivado/src/hdl/pktrec_m0_regs.v): M0 bring-up
 *                 datapath (per-port idle / loopback / forward), frame counters,
 *                 PHY GPIO_0/1 and power-good inputs
 *                 PS address 0x4_2002_0000, 4 KB
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

#define PKTREC_NUM_PORTS           4
#define PKTREC_PHY_ADDR(n)         ((n) == 0 ? 0x01 : (n) == 1 ? 0x03 : (n) == 2 ? 0x0C : 0x0F)

/* ------------------------------------------------------------------------- */
/* pktrec_eth_ports: global registers                                         */
/* ------------------------------------------------------------------------- */
#define PKTREC_ETH_ID              0x000   /* RO 0x504B5245 "PKRE" */
#define PKTREC_ETH_ID_VALUE        0x504B5245
#define PKTREC_ETH_VERSION         0x004   /* RO 0x00010000 */
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
#define PKTREC_ETH_P_TX_MAX_LEN    0x14    /* RW [15:0] incl. FCS, minus 1 (1517) */
#define PKTREC_ETH_P_RX_MAX_LEN    0x18    /* RW [15:0] incl. FCS, minus 1 (1517) */
#define PKTREC_ETH_P_TX_MIN_LEN    0x1C    /* RW [7:0] excl. FCS, minus 1 (59) */

/* Taxi GT control registers of lane n (16-bit APB, 32-bit accesses) */
#define PKTREC_ETH_GT_APB(n)       (0x40000 + (n) * 0x10000)

/* ------------------------------------------------------------------------- */
/* pktrec_m0_path                                                            */
/* ------------------------------------------------------------------------- */
#define PKTREC_M0_ID               0x000   /* RO 0x504B4D30 "PKM0" */
#define PKTREC_M0_ID_VALUE         0x504B4D30
#define PKTREC_M0_VERSION          0x004   /* RO 0x00010000 */
#define PKTREC_M0_PATH_CTRL        0x008   /* RW [2n+1:2n] TX source of port n (reset 0) */
#define   PKTREC_M0_PATH_IDLE            0u          /* nothing is sent */
#define   PKTREC_M0_PATH_LOOP            1u          /* own RX (RX n -> TX n) */
#define   PKTREC_M0_PATH_FWD             2u          /* pair partner's RX (RX n^1 -> TX n) */
#define   PKTREC_M0_PATH_SHIFT(n)        (2 * (n))
#define PKTREC_M0_CNT_CTRL         0x00C   /* WO [0] 1 = clear all counters and IO_STICKY */
#define PKTREC_M0_IO_STATUS        0x010   /* RO [3:0] GPIO_0 P0..P3, [7:4] GPIO_1 P0..P3,
                                              [8] PG_1V0, [9] PG_2V5, [19:16] link_up */
#define PKTREC_M0_IO_STICKY        0x014   /* W1C [3:0] GPIO_0 rose, [7:4] GPIO_1 rose */

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

#endif /* PKTREC_REGS_H */
