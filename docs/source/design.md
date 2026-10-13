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
* The 64-bit MAC timestamp inputs are fed by the capture block's timebase (see
  [Capture path](#capture-path-m1)).

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
* It also passes a plain copy of every RX stream (`m_axis_mon_n`) to the capture path.
  The RX streams have no back-pressure, so this fan-out does not affect forwarding.

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

## Capture path (M1)

The block-design hierarchy `capture` holds one module reference, **`pktrec_capture`**
(`Vivado/src/hdl/pktrec_capture.v`, implementation in `pktrec_capture_core.sv` and the
`pktrec_cap_*.sv` / `pktrec_timebase.sv` modules). It records what every port receives, in
monitor mode, and hands the records to the recorder datapath (`fdrec_core`), which writes
them to the SSD exactly like the recorder's test data.

```
eth_ports RX n (rx_clk_n, 16 bit) ──> pktrec_cap_port n ─┐
   x4                                  frame FIFO 16 KB   ├─> pktrec_cap_merge ─> fdrec_core
                                       + record header    ┘   (round robin,       S_AXIS_CAP
pktrec_timebase (dp_clk) ─ cycle count ─> MAC timestamp inputs   whole records)   -> packetizer
                         ─ ns, cycles ──> record headers                          -> AXI DMA
```

### Per port (`pktrec_cap_port`)

* A frame is captured if capture is enabled (`CTRL.ENABLE` and `PORT_EN[n]`) when its
  first byte arrives. A frame already in progress when the enable changes is taken or
  ignored whole.
* Every frame that starts while the port is enabled gets the port's next 16-bit sequence
  number, including frames that are then dropped. A gap in a port's sequence numbers in
  a capture file is therefore exactly the number of frames the hardware dropped there.
* `SNAPLEN` (0 = off) limits the bytes stored per frame. Truncated records carry the
  TRUNC flag and the original length.
* The frame is stored whole in a 16 KB per-port frame FIFO (Taxi
  `taxi_axis_async_fifo_adapter`: 16-to-128-bit conversion and the clock crossing into
  `dp_clk`). When a frame does not fit, the FIFO drops it **whole**, and the port counts
  it in `FRAMES_DROP` / `BYTES_DROP`. A frame larger than the FIFO is dropped the same
  way. Nothing is ever dropped in the middle of a frame or a record.
* The frame's metadata waits until the FIFO has committed the frame, then goes into a
  small metadata FIFO. The record reader in `dp_clk` builds the 16-byte header, then
  copies the frame's data beats, zeroing the unused bytes of the last one.
* Counters (frames received, bad, dropped, truncated, bytes received and dropped) are
  kept in the port's receive clock and copied to `dp_clk` as one coherent snapshot.

### Merge and recorder

* `pktrec_cap_merge` grants the four ports round robin, one **whole record** at a time,
  and produces one 128-bit stream at up to 4 GB/s, well above the 500 MB/s of four ports
  at line rate.
* The stream goes straight into the `fdrec_core` packetizer, with back-pressure, while
  `CTRL.SRC_SEL` = 1. The recorder's ingest FIFO, which drops 16-byte beats when it is
  full, is bypassed. When the SSD or the DMA stalls, the back-pressure reaches the
  per-port frame FIFOs, and drops happen there as whole, counted frames.
* The DMA contract is unchanged: `TLAST` every `PKT_LEN` beats, `TKEEP` all ones. Record
  boundaries and DMA buffer boundaries are unrelated: records span buffers.
* `fdrec_core` register map 1.2 adds `PKT_SRC` (0x050), which reads the source back.
  With `SRC_SEL` = 0 (the reset value) the test pattern generator path works as before,
  so `fdrec --rate` benchmarks still run on this design.
* **Fill:** with `CTRL.FILL` set, the merge sends all-zero 16-byte fill units whenever it
  has no record. At the end of a capture, fill pushes the last records through the DMA
  (whose buffers only complete when full), so the fdrec driver's STOP drain completes at
  once.
* A recorder soft reset (every `FDREC_IOC_START`) while a record is in progress cuts that
  record (`SRST_ABORTS`); the merge then discards its remainder, so a recording always
  starts on a record boundary.

### Record format v1

Defined in `include/pktrec_format.h`. Each record is a 16-byte header, the frame bytes
(FCS excluded; the MAC strips it), and zero padding to a multiple of 16 bytes.

| Bytes | Field | Description |
|-------|-------|-------------|
| 0-7 | `ts_ns` | timebase value at the start of frame, ns |
| 8-9 | `cap_len` | bytes stored (FCS excluded, at most `SNAPLEN` and 16384) |
| 10-11 | `orig_len` | length on the wire including the FCS |
| 12 | `port` | 0..3 (OP080 P0..P3) |
| 13 | `flags` | [0] bad frame (FCS/framing error or too long), [1] truncated, [2] timestamp from the MAC (always 1 in M1), [3] SFD mismatch (M2), [7:4] marker `0xA` |
| 14-15 | `seq` | per-port frame sequence number |

All fields are little-endian. A capture file is a 4 KB header (`struct
pktrec_file_header`) followed by the record stream.

### Timebase

`pktrec_timebase` is a PHC-style clock in `dp_clk` (249.975 MHz): a 64-bit nanosecond
counter plus a 32-bit fraction, advanced every cycle by a 32.32 increment (`INC`,
reset 1e9 / `DP_CLK_HZ` = 4.0004 ns). Software can set it (`TB_SET`), step it by a
signed offset (`TB_ADJ`) and trim its rate (`TB_INC_*`), so it can be slaved to system
time. `pktrec-cap` sets it from `CLOCK_REALTIME` before every capture.

The four MAC receive clocks are recovered from the network and are not related to
`dp_clk`. Instead of copying the time into each of them, the timebase counts `dp_clk`
cycles and carries that count, Gray-coded (`xpm_cdc_gray`), into every MAC clock
domain. The MAC latches the count at the start of frame. When the header is built, in
`dp_clk`, the count is turned back into time:

    ts_ns = TB_NOW - (cycles now - cycles at SFD) * INC + MAC_OFFSET

`MAC_OFFSET` (reset 52 ns) removes the constant synchronisation delay of the copy.

| Contribution | Size |
|--------------|------|
| timebase resolution | 4 ns (one `dp_clk` cycle) |
| MAC timestamp quantisation | 16 ns (one 62.5 MHz MAC clock) |
| sampling jitter of the cycle-count copy | at most 8 ns (simulation: 12..14 cycles of delay) |
| PHY, PCS and transceiver latency | constant, not calibrated in M1 |

M2 replaces the MAC timestamps with the PHYs' SFD pulses, sampled in `dp_clk`.

Taxi's PTP clock-domain-crossing module (`taxi_ptp_clock_cdc`, a digital PLL per clock
domain) was tried first. In simulation, with the 125..250 ppm frequency offsets expected
between a recovered clock and `dp_clk`, its output wandered up to ±30 ns (rms about 9 ns)
around the master. The cycle-count scheme has no lock time and only a constant offset.

### Capture register map

`pktrec_capture` (`0x04_2003_0000`, 4 KB, `generic-uio`), register map 1.1. The full
definitions, including the start and stop protocol with the fdrec driver, are in
`include/pktrec_regs.h`. 64-bit counters are `_LO`/`_HI` pairs: reading `_LO` latches
the matching `_HI`.

| Offset | Name | Description |
|--------|------|-------------|
| `0x000` | ID | `0x504B4350` |
| `0x004` | VERSION | `0x00010001` |
| `0x008` | CTRL | [0] ENABLE, [1] FILL, [2] SRC_SEL (recorder source: 1 = capture), [8] CLEAR (self-clearing) |
| `0x00C` | STATUS | [0] IDLE, [1] merge busy, [11:8] port idle, [15:12] port receiving a captured frame, [23:16] MAC clock domains out of reset |
| `0x010` | PORT_EN | [3:0] per-port enable (reset `0xF`) |
| `0x014` | SNAPLEN | [15:0] bytes stored per frame, 0 = whole frames |
| `0x018` | DP_CLK_HZ | timebase clock frequency |
| `0x01C` | PORT_FIFO_BYTES | 16384 |
| `0x020` | BYTES_OUT (64) | record bytes handed to the recorder |
| `0x028` | RECORDS_OUT (64) | records handed to the recorder |
| `0x030` | FILL_BEATS (64) | fill units sent |
| `0x038` | BP_CYCLES (64) | `dp_clk` cycles a beat waited for the recorder |
| `0x040` | SRST_ABORTS | records cut by a recorder soft reset |
| `0x044` | LEN_FIXUPS | records whose data did not match their header length (expect 0) |
| `0x080` | TB_CTRL | [0] SET, [1] ADJ |
| `0x084` / `0x088` | TB_INC_FRAC / TB_INC_NS | increment per cycle; writing `INC_NS` applies both |
| `0x08C` | TB_STATUS | [3:0] RX, [7:4] TX MAC clock domains out of reset |
| `0x090` | TB_NOW (64) | current time, ns |
| `0x098` | TB_SET (64) | value loaded by SET |
| `0x0A0` | TB_ADJ (64) | signed offset added by ADJ |
| `0x0A8` | MAC_OFFSET | signed ns added to MAC timestamps (reset 52) |
| `0x100 + n*0x40` | port n | FRAMES_RX, FRAMES_BAD, FRAMES_DROP, BYTES_RX, BYTES_DROP, FRAMES_TRUNC, RECORDS (64 bit each), FIFO_HWM (0x38, bytes, write clears), SEQ_NEXT (0x3C) |

Once `STATUS.IDLE` = 1, `FRAMES_RX` = `RECORDS` + `FRAMES_DROP` on every port.

### Verification

Self-checking testbenches (`Vivado/scripts/sim.tcl`):

* `tb_pktrec_cap_port`: headers, data and padding of every record, snaplen, whole-frame
  drops under back-pressure with exact counters and sequence gaps, the port enable,
  minimum-size frames at line rate with no drops, the timestamp conversion across the
  32-bit wrap of the cycle counter.
* `tb_pktrec_cap_merge`: whole records only, per-port order, round-robin fairness, fill,
  soft-reset cut.
* `tb_pktrec_timebase`: increment, set, adjust, rate change, and the delay window of the
  cycle-count copies at +125 / -250 ppm.
* `tb_pktrec_capture`: the four ports, the merge, the registers and `fdrec_core` in
  capture mode with a DMA model. It follows the start and stop protocol and checks the
  recorded stream frame by frame, then cuts records in flight with a recorder soft reset.
