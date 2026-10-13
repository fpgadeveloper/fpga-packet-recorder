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
  (Taxi `taxi_axis_async_fifo`; 4 KB for LOOP, 16 KB for FWD since M3). Frames are
  switched only between frames, so they are never cut. TAP mode, the dynamic
  inter-frame gap and the map 1.2 registers are described in
  [TAP mode (M3)](#tap-mode-m3).
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
| `0x008` | PATH_CTRL | [2n+1:2n] TX source of port n: 0 IDLE, 1 LOOP, 2 FWD, 3 GEN (M2) |
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
link is broken, including a TAP pair (see [TAP mode (M3)](#tap-mode-m3)).

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

Since M2 the record timestamp normally comes from the PHYs' SFD pins instead (see
[SFD timestamping](#sfd-timestamping-m2)); the MAC timestamp remains the fallback.

Taxi's PTP clock-domain-crossing module (`taxi_ptp_clock_cdc`, a digital PLL per clock
domain) was tried first. In simulation, with the 125..250 ppm frequency offsets expected
between a recovered clock and `dp_clk`, its output wandered up to ±30 ns (rms about 9 ns)
around the master. The cycle-count scheme has no lock time and only a constant offset.

### Capture register map

`pktrec_capture` (`0x04_2003_0000`, 4 KB, `generic-uio`), register map 1.2 (1.1 plus the
SFD block at `0x400`..`0xBFF`, see [SFD timestamping](#sfd-timestamping-m2)). The full
definitions, including the start and stop protocol with the fdrec driver, are in
`include/pktrec_regs.h`. 64-bit counters are `_LO`/`_HI` pairs: reading `_LO` latches
the matching `_HI`.

| Offset | Name | Description |
|--------|------|-------------|
| `0x000` | ID | `0x504B4350` |
| `0x004` | VERSION | `0x00010002` |
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

## SFD timestamping (M2)

Each DP83867 raises its GPIO_0 when it receives a start-of-frame delimiter on the cable
and keeps it high until the end of the frame; GPIO_1 does the same for transmitted
frames (`pktrec-phy init` sets `GPIO_MUX_CTRL` = `0x0012`). The reference point is the
MDI (cable) side of the PHY, which is what a capture timestamp should describe: the
PHY, SGMII, transceiver and PCS latencies, and their variation, are all behind it.

### Sampling and resolution

The eight pins reach the FPGA through the OP080's SN74AVC4T245 translators (LVCMOS18,
HP banks 67/68) and go straight from their input buffers into ISERDESE3 primitives
(`pktrec_sfd_io`):

* An MMCM takes `dp_clk` (249.975 MHz) and makes, from one VCO (4 x `dp_clk`), a 2x
  clock (~500 MHz, BUFGCE) and a 1x clock (~250 MHz, BUFGCE). The two are phase
  aligned by construction, and to `dp_clk` by the MMCM's feedback compensation.
  (A BUFGCE_DIV for the 1x clock was avoided: its divided edge can come up on either
  2x edge, which would shift the samples by 2 ns from one configuration to the next.)
* ISERDESE3 in component mode, DATA_WIDTH 4, DDR on the 2x clock: four samples per
  `dp_clk` cycle, one every ~1.0 ns. The 4-bit words cross into `dp_clk` as an
  ordinary timed path (same frequency, phase locked).
* `pktrec_sfd_edge` finds the first high sample after a low one: the timestamp is the
  timebase value of that cycle plus the sample index (ns), minus the fixed sampler
  pipeline (`SFD_PIPE_NS` = 16).

**Resolution: 1 ns** (`SFD_RES_PS` = 1000). In simulation with the real ISERDESE3 and
MMCME4 models, 8 pins x 150 edges at random sub-ns phases gave a timestamp error
uniformly within (-1, 0] ns (the timestamp is the first sample at or after the edge).
The IDDR fallback (`SFD_SAMPLER = "IDDR"`, no MMCM, 2 samples per cycle) gives 2 ns.
The DP83867 itself adds a receive SFD variation of up to +-8 ns that changes with every
link-up (it is constant while the link stays up; register `0x0055` reports it in 8 ns
steps) and none on transmit at 1000 Mb/s.

Glitch filter: an edge counts only if the pin was low for at least `SFD_MIN_LOW`
cycles before (reset 25 = 100 ns; real frames are at least 160 ns apart at 1 Gb/s) and
stays high for `SFD_MIN_HIGH` cycles after (reset 8 = 32 ns; a minimum frame keeps it
high for 512 ns). Rejected edges are counted (`RX_GLITCH`, `TX_GLITCH`).

### Matching receive SFDs to frames

Each accepted receive edge goes into a 16-entry queue in the port's capture front end
(`pktrec_cap_port`, dp_clk to rx_clk). From the first beat of every frame - captured,
dropped by the FIFO or not enabled alike, since every frame had an SFD - the oldest
entry is compared with the frame's MAC timestamp (the cycle stamp the Taxi MAC took at
its own SFD detection):

    d = MAC_raw - t_sfd        (ns; MAC_raw = MAC cycle stamp x 4 ns, no MAC_OFFSET)

| Condition | Action |
|-----------|--------|
| `d` > `RX_WIN_MAX` | stale entry (a pulse without a frame): dropped, `RX_STALE`, record flag bit3; try the next |
| `RX_WIN_MIN` <= `d` <= `RX_WIN_MAX` | match: record ts = `t_sfd` + `RX_OFFSET`, flag bit2 (TS_MAC) = 0 |
| `d` < `RX_WIN_MIN` | the entry belongs to a later frame: kept; this frame falls back |
| queue empty | wait until the frame's last beat, then fall back |

A frame without a match gets the MAC timestamp (`+ MAC_OFFSET`, flag bit2 = 1) and
counts `RX_MISMATCH`. A missing pulse costs only its own frame and an extra one is
discarded at the next frame: nothing ever shifts. The window (reset 100..700 ns)
must stay narrower than a minimum frame time (672 ns at 1 Gb/s), so that the SFDs of
neighbouring frames can never fall inside it. `RX_DELTA_LAST/MIN/MAX` record `d` of
the matches, `RX_HEAD_DELTA` the `d` of the last entry evaluated whatever the outcome
(use it to place the window when nothing matches). In simulation, with the pin pulsed
350 ns before the frame entered the MAC model, `d` was 303 ns.

Record flags (`include/pktrec_format.h`): bit2 TS_MAC = 1 when the frame fell back to
the MAC timestamp; bit3 SFD_RESYNC (`PKTREC_REC_FLAG_SFD_MISMATCH`) = 1 when stale
entries were discarded while this frame was matched (independent of bit2).

### Transmit SFDs and latency

Transmit edges are paired, in order, with the MAC's TX completions of the same port
(one per frame sent, with the MAC's cycle stamp): `lat` = `t_sfd` - `cpl_raw` within
`TX_WIN_MIN`..`TX_WIN_MAX` (reset 0..900 ns) pairs, older completions are stale
(`TX_CPL_STALE`), an edge without a completion counts `TX_UNPAIRED`. `TX_LAT_LAST/MIN/MAX`
give the MAC-to-cable transmit latency (raw cycle stamp, no offsets); `TX_EDGES` versus
`TX_CPL` checks the counts. The transmit timestamps are not stored in records; they are
for calibration and for TAP latency measurements.

`RX_LAST_TS` / `TX_LAST_TS` hold the latest timestamps of each port (with the port's
offset). With `SFD_CTRL.LOG_EN`, per-port log FIFOs keep the last 16 receive and 16
transmit timestamps (transmit with its latency) for software (`pktrec-phy sfd log`).

### SFD registers

Capture block offsets (`include/pktrec_regs.h` `PKTREC_SFD_*`):

| Offset | Name | Description |
|--------|------|-------------|
| `0x400` | SFD_CTRL | [0] MATCH_EN (reset 1), [1] LOG_EN, [8] CLEAR (also cleared by CTRL.CLEAR) |
| `0x404` | SFD_STATUS | [0] sampler locked, [1] ISERDES sampler, [11:8] RX levels, [15:12] TX levels |
| `0x408` / `0x40C` | SFD_RES_PS / SFD_PIPE_NS | 1000 / 16 |
| `0x410` / `0x414` | RX_WIN_MIN / MAX | signed ns (100 / 700) |
| `0x418` / `0x41C` | TX_WIN_MIN / MAX | signed ns (0 / 900) |
| `0x420` / `0x424` | MIN_LOW / MIN_HIGH | glitch filter, `dp_clk` cycles (25 / 8) |
| `0x800 + n*0x100` | port n, receive | +0x00 RX_EDGES (64), +0x08 RX_GLITCH, +0x0C RX_FIFO_OVF, +0x10 RX_MATCHED (64), +0x18 RX_STALE, +0x1C RX_MISMATCH, +0x20..0x28 RX_DELTA_LAST/MIN/MAX, +0x2C RX_HEAD_DELTA, +0x30 RX_LAST_TS (64), +0x38 RX_OFFSET (RW), +0x3C RX_LOG_STATUS, +0x40 RX_LOG_TS (64, LO read pops) |
| `0x880 + n*0x100` | port n, transmit | +0x00 TX_EDGES (64), +0x08 TX_GLITCH, +0x0C TX_CPL_OVF, +0x10 TX_CPL (64), +0x18 TX_PAIRED, +0x1C TX_CPL_STALE, +0x20 TX_UNPAIRED, +0x24..0x2C TX_LAT_LAST/MIN/MAX, +0x30 TX_LAST_TS (64), +0x38 TX_OFFSET (RW), +0x3C TX_LOG_STATUS, +0x40 TX_LOG_TS (64, LO read pops), +0x48 TX_LOG_LAT, +0x4C TX_HEAD_LAT |

Deltas and latencies are signed ns; `0x80000000` means "none yet".

### Calibration

What a timestamp means: the time the PHY's SFD indication reached the FPGA sampler, on
the shared timebase. Between the cable and that point are the PHY's SFD detection, the
translator and the routing; they are constant per port (apart from the PHY's per-link
receive variation of up to +-8 ns) and are removed with `RX_OFFSET` / `TX_OFFSET`.
With P2 and P3 connected by a short cable (both run by the same 25 MHz PHY clock tree):

1. `pktrec-phy init --1000-only`, `pktrec-phy sfd config --log on`,
   `pktrec-phy sfd status --clear`.
2. Generate on P2, receive on P3: `pktrec-phy gen 2 start --size 64 --rate 1000
   --count 10000` (and `pktrec-phy chk 3 start`).
3. `pktrec-phy sfd log 2 --dir tx` and `pktrec-phy sfd log 3 --dir rx` (repeat while
   running, 16 entries per read): for the same frames, `RX_SFD(P3) - TX_SFD(P2)` =
   cable delay (about 5 ns/m) + (receive indication delay - transmit indication delay,
   including both translators). Record its mean and spread; the spread is the PHY's
   receive SFD variation plus the 1 ns sampling. Repeat in the other direction (gen 3,
   log tx 3 / rx 2). Setting `TX_OFFSET` of both ports to 0 and `RX_OFFSET(p)` =
   `-(mean - cable delay)` makes a frame's receive timestamp equal its transmit
   timestamp plus the cable delay. TI defines the transmit indication as "symbol
   presented on the line", so the transmit SFD is taken as the cable-side reference;
   only its (small, constant) translator and routing delay remains unknown, and it
   cancels in every difference between two ports of this board.
   Re-measure after a link-up to see the per-link variation (read register `0x0055`).
4. `RX_DELTA_MIN/MAX` (P3) give the spread of `MAC_raw - t_sfd`. Center the receive
   window on it with generous margin but keep it narrower than 672 ns, e.g.
   `sfd config --rx-win <min-150> <max+150>`. Likewise `TX_LAT_MIN/MAX` for
   `--tx-win`.
5. MAC fallback: set `MAC_OFFSET` = `RX_OFFSET` - median(`RX_DELTA`) so that a frame that
   falls back to its MAC timestamp lands on the same scale (within the MAC's 16 ns
   quantisation).
6. TAP latency (M3): with P0/P1 forwarding, the latency of a frame received on P0 and
   sent on P1 is `TX_SFD(P1) - RX_SFD(P0)` from the two log FIFOs (or
   `TX_LAST_TS(P1) - RX_LAST_TS(P0)` at low rates).

Repeat at 100 Mb/s if needed: the PHY latencies differ there, so the windows and
offsets must be re-measured (registers, no rebuild).

## Traffic generator (M2)

Each port's TX path has a fourth source (`PATH_CTRL` mode 3, `gen`): `pktrec_gen`
sends sequence-numbered test frames from the fabric at up to line rate, so P2 and P3
can drive each other (and the bench can load P0/P1) without external equipment. A
receive checker (`pktrec_gen_chk`) on every port counts the sequence numbers it sees.

* Format 0 (PRSQ, default): byte-identical to `test/gen_seq.py` - Ethernet, IPv4
  192.0.2.1 to 192.0.2.2, UDP 50000 to 50001, payload `"PRSQ"`, stream id (u32),
  sequence number (u64), zeros - so `test/check_pcap.py` verifies captures of
  generator traffic unchanged (stream key `prsq:<stream>`).
* Format 1 (raw): destination, source, EtherType (`GEN_ETYPE`, default `0x88B5`), a u32
  sequence number at payload offset 0, zeros.
* Length 60..16383 bytes without the FCS (the MAC appends it); optional random
  lengths `LEN + (LFSR & LEN_MASK)`. Frames above the MAC's `TX_MAX_LEN` (1518 incl.
  FCS by default) need `PKTREC_ETH_P_TX_MAX_LEN` raised.
* Rate: a frame starts at most every `ceil((LEN + 4 + 8 + IFG) / 2)` `tx_clk` cycles
  (IFG in bytes; 12 = line rate: 1.488 Mframes/s at 64 bytes).
* `COUNT` frames (0 = until stopped); `GEN_CTRL.ENABLE` 0 to 1 starts (reloading
  `SEQ_FIRST`, clearing `GEN_FRAMES` / `GEN_BYTES`), 0 stops after the current frame.
  Frames are never cut.
* Checker: `CHK_FRAMES`, `CHK_LOST` (sum of sequence gaps), `CHK_ERRORS` (duplicates or
  reordering), `CHK_BAD` (MAC errors), `CHK_LAST_SEQ`; enabling it clears them.

Registers: `pktrec_m0_path` (`0x04_2002_0000`, map 1.1) at `0x200 + n*0x80`
(`PKTREC_M0_GEN_*`, `PKTREC_M0_CHK_*` in `include/pktrec_regs.h`). Command line:

    pktrec-phy gen 2 start --size 64 --count 0       # line rate, P2 path = gen
    pktrec-phy chk 3 start; pktrec-phy chk 3 status
    pktrec-phy gen 2 stop

### Verification (M2)

* `tb_pktrec_sfd`: the real ISERDESE3/MMCME4 models and timebase; resolution over 8 pins
  x 150 random-phase edges (error within (-1, 0] ns; IDDR within 2 ns), queue overflow,
  glitch filter, TX pairing with missing and extra completions, log FIFOs and offsets.
* `tb_pktrec_sfd_match`: normal matching with exact timestamps, missing pulses, extra
  pulses, entries too young / too old, frames dropped by the FIFO and frames on a
  disabled port consuming their entries, `MATCH_EN` = 0, a 1-beat runt, queue overflow;
  all counters and delta statistics exact.
* `tb_pktrec_capture` test 5: SFD pulses on a pin through the whole capture block and
  recorder: every record SFD-stamped, timestamp differences equal to the pin time
  differences within 1 ns.
* `tb_pktrec_gen`: frame content byte for byte against a `gen_seq.py` model, line-rate
  spacing, IFG spacing, random lengths, count, stop, and the checker (loss, duplicate,
  bad frames).

## TAP mode (M3)

```{warning}
**The Ethernet FMC Max has no bypass relays.** The TAP forwards in the FPGA fabric, so the
link between the two devices on a TAP pair is **broken whenever the board is unpowered,
booting, or the FPGA is being reconfigured** (a new bitstream, a reboot, a crash of the
PL). Insert the TAP only where a short outage at power-up is acceptable, and expect
both devices to see a link-down event whenever the board restarts.
```

A pair (P0/P1 or P2/P3) is either in **TAP** mode, where each port forwards everything
it receives out of its partner so the two devices on either side talk to each other
through the board, or in **monitor** mode, where both ports only receive. Capture is
the same in both modes: each port records what it *receives*, so in TAP mode the two
directions of the link are the two ports' interfaces (`P0` = traffic from the device on
P0 to the device on P1) and nothing is recorded twice.

### Forwarding

* **Store-and-forward.** Every TX port has a 16 KB forward FIFO (`FWD_FIFO_DEPTH`,
  `pktrec_m0_path`) fed by its partner's RX MAC; a frame is sent once it has been
  received completely. The latency therefore grows with the frame size (see
  [Latency](#forwarding-latency)). Cut-through forwarding (start sending after the
  header) is deferred: it would make the latency fixed but adds complexity (underrun
  handling when the partner's clock is slower) without changing what the devices see.
* **Frames are forwarded unmodified** except for the FCS, which the RX MAC checks and
  strips and the TX MAC regenerates (a correct frame comes out bit-identical). TX
  padding is off, so runts stay runts.
* **Errored frames are forwarded as errored frames.** A frame that arrives with a bad
  FCS or a receive error is forwarded with the MAC's bad-frame flag (Taxi TX
  `tuser[0]`); the Taxi PCS then sends `/V/` (error propagation) code groups in place
  of the FCS, the DP83867 turns them into a transmit error on the copper side, and the
  device on the other side counts a receive error and drops the frame, as it would
  with the original errored frame. The original wrong FCS value is not preserved, and
  a receiver that meets `/V/` ends the frame a few bytes early (6 bytes for the Taxi
  receiver in simulation) - so the far device sees *a* receive error, not the same
  bytes. The capture records the frame as received, with the bad-frame flag.
* **Frames never get cut.** The TX side changes source only between frames; frames that
  do not fit are dropped whole and counted (`DROP_FWD`).

### Clock mismatch and the dynamic inter-frame gap

The two devices on a TAP pair each transmit with their own clock, up to +-100 ppm off
nominal, while our TX MAC sends with the board's 125 MHz reference. If the device on P0
sends at 100 % utilisation and its clock is faster than ours, frames arrive faster than
P1 can send them, and any FIFO eventually overflows: at a +200 ppm worst case that is
25 KB per second of traffic.

The standard fix, applied here, is to shorten the inter-frame gap while the FIFO fills
up. Per TX port, `pktrec_m0_path` drives the Taxi MAC's `cfg_tx_ifg`
(`pktrec_eth_ports` parameter `EXT_TX_IFG` = 1):

* normally `IFG_NOM` = 12 bytes (the IEEE 802.3 gap),
* `IFG_MIN` = 8 bytes while the forward FIFO holds more than `IFG_HI` = 3072 bytes, until
  it falls below `IFG_LO` = 2048 bytes (hysteresis; IEEE 802.3 receivers must accept
  gaps down to 64 bit times, i.e. 8 bytes).

Saving 4 bytes per frame catches up 4 / 1538 = 0.26 % (2600 ppm) with 1518-byte frames
and 4.8 % with 64-byte frames, far more than the 200 ppm needed. The FIFO fill counts
the frame that is being received, so while forwarding 1518-byte frames at 100 % it sits
at about one frame (~1.5 KB) even with no backlog; `IFG_LO` must stay above the largest
frame or the reduced gap only ends when the traffic pauses. Below 100 % utilisation the
FIFO never fills and the gap stays at 12 bytes. The worst-case extra latency from the
backlog is `IFG_HI` (3 KB, 25 us); the 13 KB above it absorb bursts.

Counters per TX port (`pktrec-phy ifg`): FWD fill now and its maximum, time spent with
the reduced gap (`IFG_RED_CYC`, 16 ns units) and the number of episodes.

Speed: the forward FIFO cannot bridge two different link speeds. `pktrec-phy init
--1000-only` (what `pktrec-phy-watch.service` runs at boot) advertises only 1000BASE-T
full duplex on all four PHYs, so both devices link at 1 Gb/s or not at all, and `pktrec-phy
mode <pair> tap` warns when the two ports of a pair report different speeds. Tapping a
100 Mb/s link needs both PHYs of the pair restricted to 100 Mb/s instead (Should #10,
not done yet).

### Pair mode and switching

`pktrec-phy mode <pair> tap|monitor` sets the two ports' `PATH_CTRL` fields (tap = FWD
on both, monitor = IDLE on both) and the informational `PAIR_MODE` register, which
`pktrec-cap` copies into the capture file header (`pair_mode`, bit p = pair p in TAP mode)
and `pktrec-export` reports in each pcapng interface description ("TAP pair 0
(P0<->P1), forwarded to P1" or "monitor mode"). `pktrec-phy path` and `gen` keep
`PAIR_MODE` consistent (a pair is "tap" exactly when both its ports forward).
`pktrec-phy mode` refuses to switch while a capture is running (capture `CTRL.ENABLE`),
unless `--force` is given.

Exact behaviour of a switch while traffic flows (verified in `tb_pktrec_tap`):

* **RX side:** the new mode takes effect for frames whose first byte arrives after the
  register write has crossed into the port's receive clock (a few cycles); a frame that
  is being received keeps the decision taken at its first byte.
* **TX side:** the port finishes the frame it is sending, then switches source.
* **Frames already in a FIFO** that the port no longer selects (for example the forward
  FIFO when going from TAP to monitor) are discarded and counted per port in `FLUSH`. At
  most the FIFO contents are lost (in practice the one or two frames in flight); no
  frame is ever truncated, corrupted, duplicated or reordered, and every frame that
  entered a FIFO is either sent or counted in `FLUSH` or `DROP_*`.

In **monitor mode** the PHYs still link up normally (with the advertisement from `pktrec-phy
init`, 1000BASE-T full duplex only by default) so that the devices on each side keep
their link; the ports send nothing but idles.

### Link-state propagation

On a direct cable, when one device's link goes down the other device sees it too. Through
the TAP it would not: the PHY on the other port keeps its link to the other device. The
link watcher (`pktrec-phy watch`, run by `pktrec-phy-watch.service`) therefore propagates
the copper link state for pairs in TAP mode:

* when a port's copper link has been down for 0.5 s (`--debounce`), its partner PHY is
  powered down (DP83867 `BMCR[11]`), so the device on the partner's side sees link down;
* when the port's link has been up again for 0.5 s, the partner PHY is powered up (its
  registers are kept) and the SGMII status word re-triggered once its copper link
  returns;
* a port whose link is down *because we powered it down* never propagates (no
  ping-pong), and a PHY that was just powered up gets 6 s (`--grace`) to auto-negotiate
  before its own link-down counts. If its far device is really gone, the first port is
  powered down after the grace time: the device on that side sees its link come up
  for up to ~6 s, then go down again;
* when the pair leaves TAP mode, when the watcher stops (SIGTERM), or when someone else
  powers the PHY up (`pktrec-phy init`), the watcher releases every PHY it powered down.

Every action is logged with a timestamp (`journalctl -u pktrec-phy-watch`; `--json` gives
one JSON object per line); `--no-propagate` disables propagation.

### Forwarding latency

Simulated (`tb_pktrec_tap`, Taxi MAC/PCS models, no transceiver or PHY), from the
start-of-frame on the incoming 1000BASE-X stream to the start-of-frame of the forwarded
frame:

| Frame (incl. FCS) | 64 B | 256 B | 512 B | 1024 B | 1518 B |
|---|---|---|---|---|---|
| Latency (simulation) | 735 ns | 2271 ns | 4319 ns | 8415 ns | 12367 ns |

That is `8 ns x frame length + 223 ns`: the frame time plus a fixed MAC/FIFO/PCS
pipeline. On the hardware the GTH transceivers and the two DP83867s (RX and TX) add their
fixed latencies. **Hardware latency is measured with the SFD timestamps** (M2): for a
frame received on port A and forwarded out of port B, latency = TX SFD(B) - RX SFD(A),
i.e. from the start-of-frame delimiter on the incoming wire to the one on the outgoing
wire (the PHYs' own SFD indications, 1 ns sampling; with `RX_OFFSET`/`TX_OFFSET`
calibrated, wire to wire). `pktrec-phy latency` pairs the two ports' SFD log FIFOs
(time window 30 us, so the traffic must be paced: at most one frame in flight per
direction) and prints min / median / max per direction:

    # on the board (pair 0 in TAP mode)
    pktrec-phy latency --pair 0 --count 300 --label "64 B"
    # meanwhile on the device behind P1: echo traffic of one size through the TAP
    ping -I <if> -i 0.01 -c 400 -s 18 <host behind P0>     # 64-byte frames

ICMP payload sizes for the standard frame sizes (Ethernet + IPv4 + ICMP = 42 bytes of
headers, plus the 4-byte FCS): 64 B `-s 18`, 256 B `-s 210`, 512 B `-s 466`, 1024 B
`-s 978`, 1518 B `-s 1472`. The echo request gives the P1 to P0 direction and the reply the
P0 to P1 direction. Background frames of other sizes fall outside the "main cluster"
(median +- 500 ns) that the tool also reports.

### Registers (pktrec_m0_path map 1.2)

New in map 1.2 (`VERSION` = `0x00010002`; full list in `include/pktrec_regs.h`):

| Offset | Name | Description |
|--------|------|-------------|
| `0x018` | PAIR_MODE | [2p+1:2p] pair p: 0 monitor, 1 TAP (informational, see above) |
| `0x01C` | EFF_PATH | [2n+1:2n] TX source port n is using now (PATH_CTRL coding) |
| port + `0x20` | IFG_CTRL | [0] dynamic IFG enable (1), [15:8] IFG_NOM (12), [23:16] IFG_MIN (8) |
| port + `0x24` | IFG_THRESH | [15:0] IFG_HI (3072), [31:16] IFG_LO (2048), bytes of FWD FIFO fill |
| port + `0x28` | FWD_FILL | [15:0] FWD FIFO fill now, [31:16] maximum since `CNT_CTRL` clear |
| port + `0x2C` | IFG_STATUS | [0] reduced gap active, [15:8] gap in use |
| port + `0x30/0x34` | IFG_RED_CYC | 48-bit count of 16 ns cycles with the reduced gap (LO read latches HI) |
| port + `0x38` | IFG_RED_ENTRIES | number of reduced-gap episodes |
| port + `0x3C` | FLUSH | frames discarded from a FIFO the port no longer selects |
| GEN + `0x00` | GEN_CTRL[3] | BAD: generator frames sent error-terminated (bad-frame forwarding test) |

(port = `0x100 + n*0x40`, GEN = `0x200 + n*0x80`.) The shell's `TX_IFG` register is not
used any more (`EXT_TX_IFG` = 1). The block keeps its historical name `pktrec_m0_path`.

### Commands

| Command | What it does |
|---------|--------------|
| `pktrec-phy mode <0\|1> tap\|monitor [--force]` | sets the pair's mode (PATH_CTRL + PAIR_MODE) |
| `pktrec-phy mode status [--json]` | mode, path and effective path per pair |
| `pktrec-phy ifg <port\|all> [--enable on\|off] [--nom B] [--min B] [--hi B] [--lo B] [--json]` | dynamic-IFG settings and counters, FWD fill, FLUSH |
| `pktrec-phy latency --pair P \| --in A --out B [--count N] [--json]` | forwarding latency from the SFD logs |
| `pktrec-phy watch [--no-propagate] [--debounce S] [--grace S] [--json]` | SGMII re-trigger and link-state propagation |
| `pktrec-phy gen <port> start --bad ...` | generator frames sent as errored frames |

### Verification (M3)

`tb_pktrec_tap` puts real Taxi 1000BASE-X MAC/PCS cores (`taxi_axis_basex_tx_16` /
`_rx_16`) on both sides of the P0/P1 pair, wired at the 8b/10b level, with sources at
100 % utilisation and sequence-numbered frames checked at the far ends:

* **Bad frames:** frames sent error-terminated and frames hit by a bit error on the line
  leave the partner port error-terminated; the far receiver flags exactly those 130 of
  400 frames bad, the others arrive intact; RX_BAD / TX_GOOD exact.
* **Dynamic IFG:** 1514-byte frames from a source +2000 ppm fast: the reduced gap starts
  only above `IFG_HI` and ends only below `IFG_LO` (4 episodes in 1200 frames), the wire
  carries only 12- and 8-byte gaps, no frame lost.
* **Clock mismatch:** 64-byte frames, source +4 % fast (a scaled stand-in for +200 ppm
  over more than 1 s: 233 us of accumulated excess against 200 us): 9000 of 9000 frames
  delivered with the dynamic IFG; without it the FIFO overflows and 75 frames are dropped
  whole, `DROP_FWD` = 75 = the frames missing at the far end.
* **Mode switching:** both directions at 100 %, PATH_CTRL toggled 12 times between TAP,
  monitor and loopback mid-traffic: 1335 frames entered FIFOs, 1232 delivered + 103 in
  `FLUSH`, none corrupted, truncated or reordered; lossless after the last switch.

The other testbenches (`tb_pktrec_m0_path`, `tb_pktrec_gen`, ...) pass unchanged.
