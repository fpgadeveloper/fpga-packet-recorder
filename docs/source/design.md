# Design

## M0 base platform (zcu106)

* Zynq UltraScale+ PS with the ZCU106 board preset. The board's RJ45 is PS GEM3.
* PCIe: one DMA/Bridge Subsystem for PCIe (XDMA) in AXI Bridge root-port mode, Gen3 x1, on
  PCIE40E4_X0Y0 with the HPC1 transceiver (GTH quad 223, channel X0Y3) and the HPC1 GBTCLK0
  100 MHz reference clock. It serves SSD slot 1 of the FPGA Drive FMC Gen4; SSD slot 2's
  3.3 V supply is switched off (`disable_ssd2_pwr`).
* Recording datapath (from the FPGA Drive Recorder): `user_data_source` (test pattern
  generator), `fdrec_core` (ingest FIFO,
  packetizer, egress FIFO, register block), AXI DMA (scatter-gather, S2MM record and MM2S
  playback) on `S_AXI_HP2_FPD`, and `user_data_sink` (playback checker).

| Clock | Source | Frequency | Use |
|-------|--------|-----------|-----|
| `pl_clk0` | PS | 100 MHz | AXI-Lite masters (HPM0), PCIe data to HP0 |
| `pl_clk1` | PS | 250 MHz | `dp_clk`: AXI DMA, packetizer, recorder registers, HP2 |
| `pl_clk2` | PS | 200 MHz | `src_clk`: data source and sink |

| Slave | Address | Size |
|-------|---------|------|
| PCIe BAR window (`xdma_0` S_AXI_B) | `0x00_A000_0000` | 256 MB |
| PCIe root-port config (`xdma_0` S_AXI_LITE) | `0x04_0000_0000` | 512 MB |
| AXI DMA registers | `0x04_2000_0000` | 64 KB |
| Recorder registers (`fdrec_core`) | `0x04_2001_0000` | 4 KB |
| M0 path registers (`eth_ports/pktrec_m0_path_0`) | `0x04_2002_0000` | 4 KB |
| Port registers + GT APB (`eth_ports/pktrec_eth_ports_0`) | `0x04_2008_0000` | 512 KB |

| Interrupt | `pl_ps_irq0` bit | GIC SPI |
|-----------|------------------|---------|
| XDMA `interrupt_out` / MSI 0-31 / MSI 32-63 | 0 / 1 / 2 | 89 / 90 / 91 |
| reserved (tied low) | 3-5 | 92-94 |
| AXI DMA S2MM | 6 | 95 |
| AXI DMA MM2S | 7 | 96 |

## Ethernet port subsystem (M0)

The Ethernet FMC Max (OP080) on HPC0 carries four TI DP83867 PHYs, each connected to the
FPGA over SGMII on one GTH transceiver. The block-design hierarchy `eth_ports` holds two
module references.

**`pktrec_eth_ports`** is the MAC/PCS/transceiver shell (`Vivado/src/hdl/pktrec_eth_ports.v`
and `pktrec_eth_ports_core.sv`), built on the open-source Taxi library
(`submodules/taxi`, CERN-OHL-S-2.0, used unmodified).

* Taxi `taxi_eth_mac_1g_basex_us` drives four 1000BASE-X/SGMII MAC+PCS channels on GTH quad
  226 (`GTHE4_CHANNEL_X0Y12`..`X0Y15`). Channel placement follows the package pins: port
  n = FMC DPn.
* The transceivers run from QPLL0 with the card's 125 MHz reference clock (GBTCLK0_M2C).
  They use Taxi's low-latency (buffer-bypass) variant.
* Each port has a 16-bit stream at 62.5 MHz:
  * TX runs on `tx_clk_n` (QPLL).
  * RX runs on `rx_clk_n`, the lane's recovered clock. RX has no back-pressure.
* SGMII auto-negotiation runs in the PCS. It reports the PHY's copper link, speed and
  duplex, and 10/100 rate adaptation is automatic.
* A Taxi MDIO master drives the shared management bus. The PHYs are at MDIO addresses
  0x01, 0x03, 0x0C and 0x0F.
* Software controls the four PHY reset pins.
* TX padding is off, so frames are forwarded as they were received.
* The 64-bit MAC timestamp inputs are fed from placeholder counters for now.

**`pktrec_m0_path`** is the bring-up datapath (`Vivado/src/hdl/pktrec_m0_path.v`).

* For each port, `PATH_CTRL` selects what the TX MAC sends:
  * nothing (IDLE),
  * the port's own received frames (LOOP),
  * or the received frames of its pair partner (FWD), where P0 pairs with P1 and P2 with
    P3. Setting FWD on both ports of a pair makes a two-port TAP.
* Every TX port and source pair has its own store-and-forward asynchronous frame FIFO
  (4 KB, Taxi `taxi_axis_async_fifo`). Frames are switched only between frames, so they
  are never cut.
* A frame that does not fit in its FIFO is dropped whole and counted.
* Frames that arrive with an error (bad FCS, framing error) are forwarded with the error
  flag set. The TX MAC then ends them with an error code, so the far end still sees a bad
  frame.
* Forwarding is store-and-forward, so latency grows with frame size.
* The PHY GPIO_0/GPIO_1 inputs (RX/TX start-of-frame-delimiter pulses once configured) and
  the card's power-good signals can be read back. Their rising edges are counted.

`ctrl_clk` is the PS `pl_clk0` (100 MHz). It clocks both register blocks, the MDIO master
and Taxi's transceiver reset/DRP logic. The GT wizard IP declares 62.5 MHz for this clock.
Taxi's reset sequencers count fixed cycle numbers, so a faster clock only shortens their
waits.

### Register maps

The full definitions are in `include/pktrec_regs.h`.

`pktrec_eth_ports` (`0x04_2008_0000`):

| Offset | Name | Description |
|--------|------|-------------|
| `0x000` | ID | `0x504B5245` |
| `0x008` | GCTRL | [0] hold the transceivers in reset, [11:8] PHY `RESET_N` pins (reset `0xF`, released) |
| `0x00C` | GSTATUS | [0] GT power good, [1] QPLL0 lock, [7:4] link up per port |
| `0x010` | MDIO_CMD | write to start a frame: [31:30] `01`, [29:28] op (`01` write, `10` read), [27:23] PHY, [22:18] register, [15:0] data |
| `0x014` | MDIO_RDATA | data of the last read |
| `0x018` | MDIO_STATUS | [0] busy, [1] read data valid, [2] command dropped |
| `0x01C` | MDIO_DIV | MDC half period - 1 in `ctrl_clk` cycles (49: 1 MHz) |
| `0x100 + n*0x40` | port n | CTRL, STATUS (PCS sync, AN, SGMII link/speed/duplex, link up), LP_ADV, STICKY, IFG and length limits |
| `0x40000 + n*0x10000` | GT lane n | Taxi transceiver control registers |

`pktrec_m0_path` (`0x04_2002_0000`):

| Offset | Name | Description |
|--------|------|-------------|
| `0x000` | ID | `0x504B4D30` |
| `0x008` | PATH_CTRL | [2n+1:2n] TX source of port n: 0 IDLE, 1 LOOP, 2 FWD |
| `0x00C` | CNT_CTRL | write 1 to clear all counters |
| `0x010` | IO_STATUS | [3:0] GPIO_0, [7:4] GPIO_1, [8] PG_1V0, [9] PG_2V5, [19:16] link up |
| `0x014` | IO_STICKY | rising edge seen on GPIO_0 [3:0] / GPIO_1 [7:4] (write 1 to clear) |
| `0x100 + n*0x40` | port n counters | RX_GOOD, RX_BAD, TX_GOOD, TX_UNDERFLOW, DROP_LOOP, DROP_FWD, GPIO0_EDGES, GPIO1_EDGES (32 bit) |

### Software

Both blocks are bound to `generic-uio` in the device tree. The `pktrec-phy` tool
(`sw/pktrec-tools`, installed by `Yocto/meta-pktrec`) maps them and provides these commands:

| Command | What it does |
|---------|--------------|
| `pktrec-phy init [--1000-only] [--reset]` | configures every PHY (see below), then watches the links for a few seconds |
| `pktrec-phy status` | shows per port the copper link, speed and duplex, the SGMII/PCS state and the GPIO levels |
| `pktrec-phy path <port\|all> idle\|loop\|fwd` | selects the M0 datapath |
| `pktrec-phy counters [--clear]` | shows the frame counters |
| `pktrec-phy watch` | resends the SGMII status word on every copper link change |
| `pktrec-phy mdio <phy> <reg> [val]` | raw PHY register access (registers above 0x1F through the extended-register window) |

`pktrec-phy init` configures each PHY as follows:

* mirror mode on,
* SGMII with SGMII auto-negotiation,
* SFD indications on GPIO_0 (RX) and GPIO_1 (TX): GPIO_MUX_CTRL (0x0172) = 0x0012,
  RXFCFG (0x0134) = 0x1080, SYNC_FIFO_CTRL (0x00E9) = 0xDF22. Verified on the bench:
  GPIO_0 edges equal RX_GOOD and GPIO_1 edges equal TX_GOOD on every port,
* a soft restart.

The DP83867 sends its SGMII status word to the MAC only once after a restart. The
image runs `pktrec-phy-watch.service` (systemd, enabled by default): it runs
`pktrec-phy init --1000-only` at boot and then `pktrec-phy watch`, which re-triggers the
status word on every copper link change. All MDIO accesses of `pktrec-phy` hold an
flock on `/run/lock/pktrec-mdio`, so the service and command-line calls never
interleave on the single MDIO master. To use other advertisement settings, stop the
service (`systemctl stop pktrec-phy-watch`) and run `pktrec-phy init` by hand.

The OP080 has no bypass relays. If the board is unpowered or reconfiguring, every port
link is broken, including a TAP pair.
