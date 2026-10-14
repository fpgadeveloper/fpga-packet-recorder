# Architecture

This page describes the hardware design and its register maps. The register definitions in C
are in `include/pktrec_regs.h` (this design's blocks) and `include/fdrec_regs.h` (the
recorder datapath); the record and file formats are in `include/pktrec_format.h` (see
[File formats](capture_format)).

## Overview

The block design (`Vivado/src/bd/`) consists of:

| Hierarchy / block | Function |
|-------------------|----------|
| Zynq UltraScale+ PS | Linux, DDR, the board's RJ45 (GEM3), the clocks of the PL |
| `xdma_0` (DMA/Bridge Subsystem for PCIe, AXI Bridge root port) | PCIe Gen3 x1 to the SSD in slot 1 of the FPGA Drive FMC Gen4 on HPC1 |
| `eth_ports` | the four Ethernet ports: `pktrec_eth_ports` (Taxi MAC/PCS/transceivers, MDIO, PHY resets) and `pktrec_m0_path` (per-port transmit source: idle, loopback, forward to the pair partner, generator, replay) |
| `capture` | `pktrec_capture`: timebase, SFD sampling and matching, per-port capture front ends, record merge |
| `replay` | `pktrec_replay`: record parser, frame store and scheduler for replay |
| recorder datapath | `fdrec_core` (packetizer, egress FIFO, registers), the AXI DMA (S2MM for capture, MM2S for replay), and the recorder's test pattern generator and checker (`user_data_source`, `user_data_sink`), from the [FPGA Drive Recorder](https://recorder.fpgadrive.com) |

The datapath is shown in the [Description](description.md#how-it-works).

### Clocks

| Clock | Source | Frequency | Use |
|-------|--------|-----------|-----|
| `pl_clk0` | PS | 100 MHz | AXI-Lite register blocks, `ctrl_clk` of the Ethernet ports (MDIO master, transceiver reset/DRP logic), PCIe data to HP0 |
| `pl_clk1` | PS | 250 MHz (249.975 MHz) | `dp_clk`: timebase, capture merge, SFD matching, replay scheduler, AXI DMA, packetizer, HP2 |
| `pl_clk2` | PS | 200 MHz | `src_clk`: the recorder's test pattern source and playback sink, replay input |
| GT reference clock | Ethernet FMC Max, GBTCLK0 | 125 MHz | QPLL0 of the four Ethernet transceivers; transmit clocks `tx_clk_n` (62.5 MHz) |
| recovered clocks | each Ethernet transceiver | 62.5 MHz | receive clocks `rx_clk_n` |
| SFD sampler clocks | MMCM from `dp_clk` | ~500 / ~250 MHz | ISERDESE3 sampling of the SFD pins |
| PCIe reference clock | FPGA Drive FMC Gen4, HPC1 GBTCLK0 | 100 MHz | PCIe root port |

### Address map

| Slave | Address | Size |
|-------|---------|------|
| PCIe BAR window (`xdma_0` S_AXI_B) | `0x00_A000_0000` | 256 MB |
| PCIe root-port configuration (`xdma_0` S_AXI_LITE) | `0x04_0000_0000` | 512 MB |
| AXI DMA registers | `0x04_2000_0000` | 64 KB |
| Recorder registers (`fdrec_core`) | `0x04_2001_0000` | 4 KB |
| Port paths (`eth_ports/pktrec_m0_path_0`) | `0x04_2002_0000` | 4 KB |
| Capture (`capture/pktrec_capture_0`) | `0x04_2003_0000` | 4 KB |
| Replay (`replay/pktrec_replay_0`) | `0x04_2004_0000` | 4 KB |
| Ethernet ports + GT APB (`eth_ports/pktrec_eth_ports_0`) | `0x04_2008_0000` | 512 KB |

The AXI DMA and `fdrec_core` are bound to the `fdrec` kernel driver; the other four
`pktrec_*` blocks are bound to `generic-uio` and mapped by the tools from user space.

### Interrupts

| Interrupt | `pl_ps_irq0` bit | GIC SPI |
|-----------|------------------|---------|
| XDMA `interrupt_out` / MSI 0-31 / MSI 32-63 | 0 / 1 / 2 | 89 / 90 / 91 |
| reserved (tied low) | 3-5 | 92-94 |
| AXI DMA S2MM | 6 | 95 |
| AXI DMA MM2S | 7 | 96 |

### Implementation

Vivado 2025.2, XCZU7EV-2FFVC1156E, the design as released: all timing constraints met
(worst negative slack +0.404 ns, worst hold slack +0.009 ns), no critical warnings; 26.6 % of
the LUTs, 24.1 % of the flip-flops and 156 block RAM tiles (50 %).

## PCIe and recorder datapath

* One DMA/Bridge Subsystem for PCIe in AXI Bridge root-port mode, Gen3 x1, on PCIE40E4_X0Y0
  with the HPC1 transceiver (GTH quad 223, channel X0Y3) and the HPC1 GBTCLK0 100 MHz
  reference clock. It serves SSD slot 1 of the FPGA Drive FMC Gen4; the 3.3 V supply of slot
  2 is switched off (`disable_ssd2_pwr`).
* The recording datapath is the FPGA Drive Recorder's `fdrec_core` and AXI DMA
  (scatter-gather, S2MM record and MM2S playback, on `S_AXI_HP2_FPD`). Its documentation
  describes the register map, the driver and the ring of hugepage buffers.
* This design adds a second source to the recorder's packetizer: with `CTRL.SRC_SEL` = 1 in
  the capture block, the packetizer takes the capture's record stream (`S_AXIS_CAP`) **with
  back-pressure**, bypassing the recorder's ingest FIFO (which drops 16-byte beats when full
  and would cut records). When the SSD or the DMA stalls, the back-pressure reaches the
  per-port frame FIFOs of the capture, and drops happen there, as whole, counted frames.
  `fdrec_core` register map 1.2 adds `PKT_SRC` (0x050), which reads the selected source back.
  With `SRC_SEL` = 0 (the reset value) the recorder's test pattern generator path works as in
  the FPGA Drive Recorder, so `fdrec --rate` benchmarks run on this design.
* The DMA contract is unchanged: `TLAST` every `PKT_LEN` beats, `TKEEP` all ones. Record
  boundaries and DMA buffer boundaries are unrelated.

## Ethernet ports (`eth_ports`)

### MAC, PCS and transceivers (`pktrec_eth_ports`)

`Vivado/src/hdl/pktrec_eth_ports.v` (a Verilog shell, as required for a block-design module
reference) over `pktrec_eth_ports_core.sv`, built on the Taxi library (`submodules/taxi`,
used unmodified):

* Taxi `taxi_eth_mac_1g_basex_us` drives four 1000BASE-X/SGMII MAC+PCS channels on GTH quad
  226 (`GTHE4_CHANNEL_X0Y12`..`X0Y15`); the package pins place them, port n = FMC DPn.
* The transceivers run at 1.25 Gb/s from QPLL0 with the card's 125 MHz reference clock, in
  Taxi's low-latency (buffer-bypass) variant. The receivers use LPM equalisation
  (`GT_RX_LPM_EN` = 1 on all lanes): with the default DFE mode, received frames were
  intermittently corrupted by bit errors on these short channels.
* Each port has a 16-bit stream at 62.5 MHz: transmit on `tx_clk_n`, receive on `rx_clk_n`
  (the lane's recovered clock). The receive stream has no back-pressure; the MAC checks and
  strips the FCS and flags bad frames on the last beat.
* SGMII auto-negotiation runs in the PCS and reports the PHY's copper link, speed and
  duplex.
* A Taxi MDIO master drives the shared management bus. The PHYs are at MDIO addresses 0x01,
  0x03, 0x0C and 0x0F. Software controls the four PHY reset pins.
* Transmit padding is off, so frames are forwarded and replayed as they were received.
* The 64-bit MAC timestamp inputs are fed by the capture block's timebase (see
  [Timebase](#timebase)).
* The transmit inter-frame gap of each MAC comes from `pktrec_m0_path` (`EXT_TX_IFG` = 1), for
  the dynamic inter-frame gap of TAP mode.

### Port paths (`pktrec_m0_path`)

`Vivado/src/hdl/pktrec_m0_path.v` selects, per port, what the transmit MAC sends
(`PATH_CTRL`, overridden by `PATH_RPL`):

| Path | Code | Transmit source |
|------|------|-----------------|
| IDLE | 0 | nothing (idles only) |
| LOOP | 1 | the port's own received frames (4 KB FIFO) |
| FWD | 2 | the received frames of the pair partner (P0↔P1, P2↔P3), through a 16 KB forward FIFO; FWD on both ports of a pair makes a TAP |
| GEN | 3 | the port's traffic generator |
| REPLAY | 4 (`PATH_RPL`) | the replay block |

* Every FIFO is a store-and-forward asynchronous frame FIFO (Taxi `taxi_axis_async_fifo`):
  a frame is sent only once it has been received completely, and the source is switched only
  between frames, so frames are never cut. A frame that does not fit is dropped whole and
  counted (`DROP_LOOP`, `DROP_FWD`).
* Frames that arrive with an error are forwarded with the MAC's bad-frame flag (Taxi TX
  `tuser[0]`); the Taxi PCS then sends `/V/` code groups in place of the FCS (see
  [Port modes](modes.md#what-the-devices-see)).
* When a port switches source, frames left in a FIFO that it no longer reads are discarded
  and counted (`FLUSH`).
* `pktrec_m0_path` passes a copy of every receive stream (`m_axis_mon_n`) to the capture
  block. The receive streams have no back-pressure, so this fan-out cannot affect forwarding.
* It reads back the PHY GPIO pins (SFD indications) and the card's power-good signals and
  counts the rising edges of the GPIO pins.

**Dynamic inter-frame gap.** Per transmit port, the gap is `IFG_NOM` (12 bytes) normally and
`IFG_MIN` (8 bytes) while the forward FIFO holds more than `IFG_HI` (3072 bytes), until it
falls below `IFG_LO` (2048 bytes). The two devices on a TAP pair transmit with their own
clocks (±100 ppm), the board with its own: if a device sends at 100 % utilisation and its
clock is faster, frames arrive faster than they can be sent (at a +200 ppm worst case, 25 KB
per second). Saving 4 bytes per frame catches up 0.26 % (2600 ppm) with 1518-byte frames and
4.8 % with 64-byte frames. The FIFO fill includes the frame being received, so `IFG_LO` must
stay above the largest frame: 2048 bytes leaves more than 500 bytes over the MACs' 1522-byte
limit, and `pktrec-phy maxlen --set` raises both thresholds when it raises the limit. Below
100 % utilisation the gap stays at 12 bytes.

**Traffic generator and checker.** Each port has a generator (`pktrec_gen`, path GEN) and a
receive checker (`pktrec_gen_chk`):

* Format 0 (default): byte-identical to `test/gen_seq.py`: Ethernet, IPv4 192.0.2.1 to
  192.0.2.2, UDP 50000 to 50001, payload `"PRSQ"`, a stream id (u32) and a sequence number
  (u64), zeros, so `test/check_pcap.py` verifies captures of generator traffic.
* Format 1 (raw): destination, source, EtherType (`GEN_ETYPE`, default `0x88B5`), a u32
  sequence number, zeros.
* Length 60..16383 bytes without the FCS (the MAC appends it), optionally random
  (`LEN + (LFSR & LEN_MASK)`). Frames above the MAC's `TX_MAX_LEN` (1522 bytes including
  the FCS) are cut by the MAC and arrive as bad frames.
* `GEN_VLAN` inserts an 802.1Q tag after the source MAC in either format (as
  `gen_seq.py --vlan`); the length includes the tag, so `pktrec-phy gen <port> start --size
  1522 --vlan 100` sends full-size tagged frames. The checker skips one tag in received
  frames.
* Rate: a frame starts at most every `ceil((LEN + 4 + 8 + IFG) / 2)` transmit clock cycles
  (IFG in bytes; 12 = line rate, 1.488 Mframes/s at 64 bytes).
* `COUNT` frames (0 = until stopped); `GEN_CTRL.BAD` sends every frame error-terminated.
* The checker counts generator frames, lost frames (sum of sequence gaps), duplicates or
  reordering, and frames with a MAC error.

## Capture (`pktrec_capture`)

`Vivado/src/hdl/pktrec_capture.v` (implementation in `pktrec_capture_core.sv` and the
`pktrec_cap_*.sv`, `pktrec_sfd_*.sv` and `pktrec_timebase.sv` modules) records what every
port receives and hands the records to the recorder.

```none
eth_ports RX n (rx_clk_n, 16 bit) ──► pktrec_cap_port n ──┐
   x4          SFD pins ─► pktrec_sfd_io/edge ─► queue ─┘ │  frame FIFO 16 KB + record header
                                                           ▼
pktrec_timebase (dp_clk) ── cycle count ─► MAC timestamps   pktrec_cap_merge (round robin,
                         ── ns ──────────► headers, SFD      whole records) ─► fdrec_core
```

### Per port (`pktrec_cap_port`)

* A frame is captured if capture is enabled (`CTRL.ENABLE` and `PORT_EN[n]`) when its first
  byte arrives; a frame in progress when the enable changes is taken or ignored whole.
* Every frame that starts while the port is enabled gets the port's next 16-bit sequence
  number, including frames that are then dropped, so a sequence gap equals the number of
  frames the hardware dropped.
* `SNAPLEN` (0 = off) limits the bytes stored; truncated records carry the TRUNC flag and the
  original length.
* The frame is stored whole in a 16 KB frame FIFO (Taxi `taxi_axis_async_fifo_adapter`:
  16-to-128-bit conversion and the crossing into `dp_clk`). A frame that does not fit, or is
  larger than the FIFO, is dropped **whole** and counted (`FRAMES_DROP`, `BYTES_DROP`).
  Nothing is ever dropped in the middle of a frame or a record.
* The record reader in `dp_clk` builds the 16-byte header once the FIFO has committed the
  frame, then copies the frame's beats, zeroing the unused bytes of the last one.
* The counters live in the receive clock and are copied to `dp_clk` as one coherent snapshot.

### Merge

`pktrec_cap_merge` grants the four ports round robin, one **whole record** at a time, and
produces one 128-bit stream at up to 4 GB/s (well above the 500 MB/s of four ports at line
rate), which goes into the packetizer with back-pressure.

* **Fill:** with `CTRL.FILL` set, the merge sends all-zero 16-byte units when it has no
  record. At the end of a capture this pushes the last records through the DMA, whose
  buffers only complete when full.
* A recorder soft reset (at every recorder start) while a record is in progress cuts that
  record (`SRST_ABORTS`); the merge discards its remainder, so a recording always starts on a
  record boundary.

### Timebase

`pktrec_timebase` is a PHC-style clock in `dp_clk`: a 64-bit nanosecond counter plus a 32-bit
fraction, advanced every cycle by a 32.32 increment (`INC`, reset 1e9 / `DP_CLK_HZ` =
4.0004 ns). Software can set it (`TB_SET`), step it by a signed offset (`TB_ADJ`) and trim its
rate (`TB_INC_*`). See [Timestamping](timestamping.md#timebase-and-absolute-time) for the
discipline.

The four MAC receive clocks are recovered from the network and unrelated to `dp_clk`. Instead
of copying the time into each of them, the timebase counts `dp_clk` cycles and carries that
count, Gray-coded (`xpm_cdc_gray`), into every MAC clock domain; the MAC latches it at the
start of frame, and the header builder converts it back:

    ts_mac = TB_NOW − (cycles now − cycles at SFD) × INC + MAC_OFFSET

This MAC timestamp is the fallback of the SFD timestamp. (Taxi's PTP clock-domain-crossing
module, a digital PLL per domain, was evaluated first: in simulation, with the 125 to 250 ppm
offsets expected between a recovered clock and `dp_clk`, its output wandered by up to
±30 ns. The cycle-count scheme has no lock time and only a constant offset.)

### SFD sampling and matching

* `pktrec_sfd_io`: the eight SFD pins (GPIO_0 = receive, GPIO_1 = transmit of each PHY) come
  through the Ethernet FMC Max's level translators (LVCMOS18, banks 67/68) straight into
  ISERDESE3 primitives. An MMCM makes a ~500 MHz and a ~250 MHz clock from one VCO, phase
  aligned to each other and to `dp_clk`; the ISERDESE3s sample DDR on the 500 MHz clock, four
  samples per `dp_clk` cycle. (A BUFGCE_DIV for the slow clock was avoided: its edge can come
  up on either fast edge, which would shift the samples by 2 ns between configurations.) The
  build parameter `SFD_SAMPLER = "IDDR"` selects a 2 ns sampler without the MMCM.
* `pktrec_sfd_edge`: edge detection with the glitch filter (`MIN_LOW`, `MIN_HIGH`); timestamp
  = timebase of the cycle + sample index − `SFD_PIPE_NS` (16).
* Receive: a 16-entry queue per port, matched in `pktrec_cap_port` against every frame's MAC
  cycle stamp with the window `RX_WIN_MIN..RX_WIN_MAX`. Frames that are dropped or not enabled
  consume their entry too. The rules are in [Timestamping](timestamping.md#matching-sfd-indications-to-frames).
* Transmit: edges are paired in order with the MAC's transmit completions within
  `TX_WIN_MIN..TX_WIN_MAX`, giving the MAC-to-pin transmit latency. Transmit timestamps are not
  stored in records; they serve the calibration and the TAP latency measurement.
* Per port, `RX_LAST_TS` / `TX_LAST_TS` hold the latest timestamps, and with `SFD_CTRL.LOG_EN`
  16-entry log FIFOs keep the last receive and transmit timestamps for software.

## Replay (`pktrec_replay`)

```none
capture file ─(pktrec-replay: one interface's records)─► hugepage ring ─► AXI DMA MM2S
  ─► fdrec_core egress FIFO (64 KB, src_clk)
  ─► pktrec_replay:  SEL = 0: passed on to the recorder's checker (fdplay works unchanged)
                     SEL = 1: async FIFO ─► dp_clk: record parser ─► frame store
                              (128 KB data + 2048 frames) ─► scheduler (timebase) ─► 128→16 bit
  ─► pktrec_m0_path replay FIFO of the port (cut-through, dp_clk → tx_clk) ─► TX MAC ─► PHY
```

* **Parser.** Reads record format v1, skips fill units, checks every header like
  `pktrec-export` (marker, port, lengths, TRUNC flag). A unit that is neither counts
  `PARSE_ERRORS`, and the parser tests every following unit until a header passes. A port
  filter (set by `pktrec-replay` as a safety net) and the bad-frame policy skip records
  (`SKIPPED`).
* **Frame store.** A frame's metadata is written with its last beat, so the scheduler never
  sees an incomplete frame and no partial frame is ever released. When the store is full, the
  parser stops and the back-pressure stalls the DMA; nothing is lost.
* **Scheduler.** TIMED: `target_i = T0 + ((ts_i − ts_first) × RATE_INV) >> 16` (16.16;
  `0x10000` = original timing). BACK-TO-BACK: as soon as the MAC takes the frame. FIXED:
  `target_i = T0 + i × GAP_NS`. `T0 = TB_NOW + START_DELAY` is latched by GO. The comparison
  runs every `dp_clk` cycle against `timebase + floor(INC)` and the release follows in the
  next cycle, so a frame is never early and at most one timebase step late. The frame is
  written at `dp_clk`, four times faster than the MAC reads it, from a store that holds the
  whole frame, so its output is never interrupted (the MAC would abort a stalled frame).
* **Lateness and underruns** are counted, never corrected: `LATE` (released more than
  `LATE_THRESH` after the target; `MAX_LATE`, `LAST_LATE`, `LATE_SUM`), `UNDERRUNS` (the store
  ran empty and the next frame arrived after its target, or, back to back, before the end of
  the stream; `STATUS.UNDERRUN` is sticky).
* **Bad frames** (`CTRL.BAD_MODE`): 2 = skipped, 1 = sent error-terminated, 0 = sent with a
  valid FCS.
* **Run control.** ARM (clears the counters; the parser fills the store) → GO (T0 latched) →
  DONE when `EXPECT` records were processed, or after STOP once the input has been idle for
  256 cycles and everything is sent. ABORT completes the frame on the wire, drops everything
  buffered and returns to idle. While SEL = 1 and the block is not armed or running, input is
  accepted and discarded (`DISCARD`) so the DMA can always drain.

The recorder's DMA path serves one direction at a time (`/dev/fdrec0` opens once, and
stopping either AXI DMA channel resets the whole AXI DMA), so a streamed replay cannot run
during a capture; `--preload` plays from the frame store instead (see
[Replay](replay.md#replay-and-capture-at-the-same-time)).

## Register maps

All registers are 32 bits. 64-bit values are `_LO`/`_HI` pairs: reading `_LO` latches the
matching `_HI`.

### Ethernet ports: `pktrec_eth_ports` (`0x04_2008_0000`)

| Offset | Name | Description |
|--------|------|-------------|
| `0x000` | ID | `0x504B5245` ("PKRE") |
| `0x004` | VERSION | `0x00010001` (1.1: maximum frame length 1522 bytes at reset) |
| `0x008` | GCTRL | [0] hold the transceivers and QPLL in reset, [11:8] PHY `RESET_N` pins (reset `0xF`, released) |
| `0x00C` | GSTATUS | [0] GT power good, [1] QPLL0 lock, [7:4] link up per port |
| `0x010` | MDIO_CMD | write to start a frame: [31:30] `01`, [29:28] op (`01` write, `10` read), [27:23] PHY, [22:18] register, [15:0] data |
| `0x014` | MDIO_RDATA | data of the last read |
| `0x018` | MDIO_STATUS | [0] busy, [1] read data valid, [2] command dropped |
| `0x01C` | MDIO_DIV | MDC half period − 1 in `ctrl_clk` cycles (49: 1 MHz) |
| `0x100 + n*0x40` | port n | see below |
| `0x40000 + n*0x10000` | GT lane n | Taxi transceiver control registers (16-bit APB) |

Port n (`0x100 + n*0x40`):

| Offset | Name | Description |
|--------|------|-------------|
| `+0x00` | CTRL | [0] TX enable, [1] RX enable, [2] TX padding (0), [3] SGMII AN enable, [4] AN restart, [5] SGMII mode, [6] SGMII speed from AN, [8] GT TX reset, [9] GT RX reset |
| `+0x04` | STATUS | [0] PCS sync, [1] AN complete, [2] AN running, [3] AN timeout, [4] SGMII mode, [5] PHY copper link, [7:6] speed (00 10M, 01 100M, 10 1G), [8] full duplex, [11] link up |
| `+0x08` | LP_ADV | SGMII configuration word from the PHY |
| `+0x0C` | STICKY | write 1 to clear: [0] link down, [1] bad FCS, [2] bad frame, [3] TX underflow, [4] AN interrupt |
| `+0x10` | TX_IFG | not used in this design (the gap comes from `pktrec_m0_path`) |
| `+0x14` | TX_MAX_LEN | maximum transmit frame length including FCS, minus 1 (1521: 1518 + one 802.1Q tag); longer frames are cut and sent error-terminated |
| `+0x18` | RX_MAX_LEN | maximum receive frame length including FCS, minus 1 (1521); longer frames are received whole but flagged bad (oversize) |
| `+0x1C` | TX_MIN_LEN | minimum transmit length without FCS, minus 1 (59) |

### Port paths: `pktrec_m0_path` (`0x04_2002_0000`, map 1.4)

| Offset | Name | Description |
|--------|------|-------------|
| `0x000` | ID | `0x504B4D30` ("PKM0") |
| `0x004` | VERSION | `0x00010004` |
| `0x008` | PATH_CTRL | [2n+1:2n] transmit source of port n: 0 IDLE, 1 LOOP, 2 FWD, 3 GEN |
| `0x00C` | CNT_CTRL | write 1: clear all counters and IO_STICKY |
| `0x010` | IO_STATUS | [3:0] GPIO_0, [7:4] GPIO_1, [8] PG_1V0, [9] PG_2V5, [19:16] link up |
| `0x014` | IO_STICKY | rising edge seen on GPIO_0 [3:0] / GPIO_1 [7:4] (write 1 to clear) |
| `0x018` | PAIR_MODE | [2p+1:2p] pair p: 0 monitor, 1 TAP (informational, written by the tools, copied into the capture file header) |
| `0x01C` | EFF_PATH | [2n+1:2n] transmit source port n uses now; [8+n] port n sends replay frames now |
| `0x020` | PATH_RPL | [n] port n in path REPLAY (overrides PATH_CTRL) |
| `0x100 + n*0x40` | port n | below |
| `0x200 + n*0x80` | generator / checker n | below |

Port n (`0x100 + n*0x40`):

| Offset | Name | Description |
|--------|------|-------------|
| `+0x00` | RX_GOOD | frames received OK |
| `+0x04` | RX_BAD | frames received with an error |
| `+0x08` | TX_GOOD | frames transmitted |
| `+0x0C` | TX_UNDERFLOW | frames aborted by a transmit underflow (expect 0) |
| `+0x10` | DROP_LOOP | frames dropped by the LOOP FIFO |
| `+0x14` | DROP_FWD | frames dropped by the forward FIFO |
| `+0x18` | GPIO0_EDGES | rising edges of GPIO_0 (receive SFD) |
| `+0x1C` | GPIO1_EDGES | rising edges of GPIO_1 (transmit SFD) |
| `+0x20` | IFG_CTRL | [0] dynamic gap enable (1), [15:8] IFG_NOM (12), [23:16] IFG_MIN (8) |
| `+0x24` | IFG_THRESH | [15:0] IFG_HI (3072), [31:16] IFG_LO (2048), bytes of forward FIFO fill |
| `+0x28` | FWD_FILL | [15:0] forward FIFO fill now, [31:16] maximum since the last clear |
| `+0x2C` | IFG_STATUS | [0] reduced gap active, [15:8] gap in use |
| `+0x30` / `+0x34` | IFG_RED_CYC | 48-bit count of 16 ns cycles with the reduced gap |
| `+0x38` | IFG_RED_ENTRIES | number of reduced-gap episodes |
| `+0x3C` | FLUSH | frames discarded from a FIFO the port no longer selects |

Generator and checker n (`0x200 + n*0x80`):

| Offset | Name | Description |
|--------|------|-------------|
| `+0x00` | GEN_CTRL | [0] ENABLE (0→1 starts: reloads SEQ_FIRST, clears the counters; 0 stops after the current frame), [1] raw format, [2] random length, [3] send error-terminated |
| `+0x04` | GEN_STATUS | [0] running, [1] done (COUNT reached) |
| `+0x08` | GEN_LEN | [13:0] bytes without FCS (60) |
| `+0x0C` | GEN_LEN_MASK | [13:0] random length mask (0) |
| `+0x10` | GEN_IFG | [15:0] gap in bytes (12) |
| `+0x14` | GEN_COUNT | frames per start, 0 = until stopped |
| `+0x18` / `+0x1C` | GEN_DST | destination MAC (bytes 2..5 / 0..1; reset broadcast) |
| `+0x20` / `+0x24` | GEN_SRC | source MAC (reset `02:00:00:00:00:0n`) |
| `+0x28` | GEN_ETYPE | raw-format EtherType (`0x88B5`) |
| `+0x2C` | GEN_STREAM | stream id (n) |
| `+0x30` | GEN_SEQ_FIRST | first sequence number |
| `+0x34` / `+0x38` | GEN_FRAMES | frames sent since the start (64) |
| `+0x3C` / `+0x40` | GEN_BYTES | bytes sent including FCS (64) |
| `+0x44` | GEN_VLAN | [15:0] 802.1Q TCI (priority, DEI, VLAN id), [16] insert the tag (0) |
| `+0x48` | CHK_CTRL | [0] ENABLE (0→1 clears), [1] raw format, [31:16] EtherType |
| `+0x4C` | CHK_FRAMES | generator frames received |
| `+0x50` | CHK_LOST | sum of sequence gaps |
| `+0x54` | CHK_ERRORS | duplicate or out-of-order sequence numbers |
| `+0x58` | CHK_BAD | generator frames with a MAC error |
| `+0x5C` / `+0x60` | CHK_LAST_SEQ | highest sequence number seen (64) |

### Capture: `pktrec_capture` (`0x04_2003_0000`, map 1.2)

| Offset | Name | Description |
|--------|------|-------------|
| `0x000` | ID | `0x504B4350` ("PKCP") |
| `0x004` | VERSION | `0x00010002` (register map 1.2, record format v1) |
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
| `0x100 + n*0x40` | port n | below |
| `0x400`..`0xBFF` | SFD | below |

Port n (`0x100 + n*0x40`, 64-bit counters):

| Offset | Name | Description |
|--------|------|-------------|
| `+0x00` | FRAMES_RX | frames seen while enabled (good + bad, including dropped) |
| `+0x08` | FRAMES_BAD | of which flagged bad by the MAC |
| `+0x10` | FRAMES_DROP | dropped whole (FIFO full or oversize) |
| `+0x18` | BYTES_RX | bytes of FRAMES_RX, including FCS |
| `+0x20` | BYTES_DROP | bytes of FRAMES_DROP |
| `+0x28` | FRAMES_TRUNC | frames cut by SNAPLEN |
| `+0x30` | RECORDS | records handed to the merge |
| `+0x38` | FIFO_HWM | frame FIFO high-water mark in bytes (32 bit, write clears) |
| `+0x3C` | SEQ_NEXT | [15:0] sequence number of the next frame |

Once `STATUS.IDLE` = 1, `FRAMES_RX` = `RECORDS` + `FRAMES_DROP` on every port.
`include/pktrec_regs.h` documents the start and stop protocol with the recorder driver.

SFD block:

| Offset | Name | Description |
|--------|------|-------------|
| `0x400` | SFD_CTRL | [0] MATCH_EN (reset 1), [1] LOG_EN, [8] CLEAR (also cleared by CTRL.CLEAR) |
| `0x404` | SFD_STATUS | [0] sampler locked, [1] ISERDES sampler, [11:8] RX levels, [15:12] TX levels |
| `0x408` / `0x40C` | SFD_RES_PS / SFD_PIPE_NS | 1000 / 16 |
| `0x410` / `0x414` | RX_WIN_MIN / MAX | signed ns (reset 100 / 700) |
| `0x418` / `0x41C` | TX_WIN_MIN / MAX | signed ns (reset 0 / 900) |
| `0x420` / `0x424` | MIN_LOW / MIN_HIGH | glitch filter, `dp_clk` cycles (25 / 8) |
| `0x800 + n*0x100` | port n, receive | +0x00 RX_EDGES (64), +0x08 RX_GLITCH, +0x0C RX_FIFO_OVF, +0x10 RX_MATCHED (64), +0x18 RX_STALE, +0x1C RX_MISMATCH, +0x20..0x28 RX_DELTA_LAST/MIN/MAX, +0x2C RX_HEAD_DELTA, +0x30 RX_LAST_TS (64), +0x38 RX_OFFSET (RW), +0x3C RX_LOG_STATUS, +0x40 RX_LOG_TS (64, LO read pops) |
| `0x880 + n*0x100` | port n, transmit | +0x00 TX_EDGES (64), +0x08 TX_GLITCH, +0x0C TX_CPL_OVF, +0x10 TX_CPL (64), +0x18 TX_PAIRED, +0x1C TX_CPL_STALE, +0x20 TX_UNPAIRED, +0x24..0x2C TX_LAT_LAST/MIN/MAX, +0x30 TX_LAST_TS (64), +0x38 TX_OFFSET (RW), +0x3C TX_LOG_STATUS, +0x40 TX_LOG_TS (64, LO read pops), +0x48 TX_LOG_LAT, +0x4C TX_HEAD_LAT |

Deltas and latencies are signed ns; `0x80000000` means "none yet". `RX_DELTA` is
`MAC_raw − t_sfd` of the matched frames; `RX_HEAD_DELTA` is the delta of the last entry
evaluated whatever the outcome (use it to place the window when nothing matches).

### Replay: `pktrec_replay` (`0x04_2004_0000`, map 1.0)

| Offset | Name | Description |
|--------|------|-------------|
| `0x000` | ID | `0x504B5250` ("PKRP") |
| `0x004` | VERSION | `0x00010000` |
| `0x008` | CTRL | [0] SEL, [2:1] MODE (0 timed, 1 back-to-back, 2 fixed), [5:4] BAD_MODE, [6] FILTER_EN, [9:8] FILTER_PORT, [13:12] TX_PORT |
| `0x00C` | CMD | write 1: [0] ARM, [1] GO, [2] STOP, [3] ABORT |
| `0x010` | STATUS | [2:0] state (0 idle, 1 armed, 2 running, 3 done, 4 aborting), [3] STOP requested, [8] UNDERRUN, [9] PARSE_ERROR, [10] LATE (sticky until ARM), [11] TX port in REPLAY, [12] input idle, [13] scheduler busy, [14] frames in the store |
| `0x014` | RATE_INV | 16.16 interval scale (`0x10000`) |
| `0x018` | START_DELAY | ns from GO to T0 (1 ms) |
| `0x01C` | LATE_THRESH | ns (100) |
| `0x020` | GAP_NS | FIXED mode interval (672) |
| `0x024` / `0x028` | EXPECT | records that will be streamed (0 = unknown: end with STOP) |
| `0x02C` | STORE_LEVEL | [15:0] data beats, [31:16] frames |
| `0x030` / `0x034` | STORE_BEATS / MAX_CAP | 8192 (128 KB) / 16384 |
| `0x038` / `0x040` / `0x048` | T0 / TS_FIRST / LAST_TARGET | 64 bit |
| `0x050` / `0x054` | MAX_LATE / LAST_LATE | ns |
| `0x080`..`0x0E4` | counters (64 bit) | RECORDS, FRAMES, BYTES, PARSE_ERRORS, FILL, SKIPPED, UNDERRUNS, LATE, LATE_SUM, BEATS_IN, DISCARD, BAD_SENT, RECORDS_DONE |

The capture block exports its timebase (`tb_now`, `tb_inc_ns`) to the replay block.

### Recorder: `fdrec_core` (`0x04_2001_0000`, map 1.2)

The register map of the FPGA Drive Recorder (`include/fdrec_regs.h`, documented on the
recorder's [register map page](https://recorder.fpgadrive.com/en/latest/register_map.html)),
plus `PKT_SRC` (0x050), which reads back the packetizer source selected by the capture
block's `CTRL.SRC_SEL`.

## Verification

The custom RTL has self-checking testbenches in `Vivado/src/sim/` (run with
`Vivado/scripts/sim.tcl`, see [Testing](testing.md#rtl-testbenches)):

| Testbench | Checks |
|-----------|--------|
| `tb_pktrec_m0_path` | IDLE/LOOP/FWD paths, whole-frame drops and counters |
| `tb_pktrec_gen` | generator frames byte for byte against a `gen_seq.py` model, line-rate and IFG spacing, random lengths, count, stop; 802.1Q-tagged frames (1522 bytes, minimum 62 + FCS, raw); checker loss, duplicate and bad counts, tagged and untagged |
| `tb_pktrec_tap` | real Taxi 1000BASE-X MAC/PCS on both sides of a pair at 100 % utilisation: bad-frame propagation (130 of 400 frames flagged bad exactly), the dynamic gap's hysteresis, clock mismatch (source +4 % fast: 9000 of 9000 frames with the dynamic gap, 75 dropped and counted without it), 12 mode switches mid-traffic with no corrupted, truncated or reordered frame; 1522-byte tagged frames received and forwarded good both ways; 1523- and 1600-byte frames flagged bad and cut at the limit; simulated forwarding latency 8 ns × frame length + 223 ns |
| `tb_pktrec_cap_port` | headers, data and padding of every record, snap length, whole-frame drops under back-pressure with exact counters and sequence gaps, port enable, minimum-size frames at line rate, timestamp conversion across the cycle counter wrap |
| `tb_pktrec_cap_merge` | whole records only, per-port order, round-robin fairness, fill, soft-reset cut |
| `tb_pktrec_timebase` | increment, set, adjust, rate change, the delay window of the cycle-count copies at +125 / −250 ppm |
| `tb_pktrec_sfd` | the real ISERDESE3/MMCME4 models: resolution over 8 pins × 150 random-phase edges (error within (−1, 0] ns; IDDR within 2 ns), queue overflow, glitch filter, transmit pairing with missing and extra completions, logs and offsets |
| `tb_pktrec_sfd_match` | matching with exact timestamps, missing and extra pulses, entries too young or too old, dropped and disabled frames consuming their entries, `MATCH_EN` = 0, a 1-beat runt, queue overflow |
| `tb_pktrec_capture` | the four ports, the merge, the registers and `fdrec_core` in capture mode with a DMA model, following the start and stop protocol; recorded stream checked frame by frame; records cut by a recorder soft reset; SFD pulses through the whole block (timestamp differences equal to the pin time differences within 1 ns) |
| `tb_pktrec_replay` | record stream with random stalls through the replay block, the real `pktrec_m0_path` and Taxi MACs: timed 1x (release − target 0..3 ns, wire within 15 ns of the schedule), 0.5x and 2x, back to back (exactly 672 ns at 64 bytes), fixed gap, underruns, a corrupted unit (resynchronised), ABORT and STOP, pass-through with SEL = 0 |
| `tb_fdrec_*` | the recorder datapath (from the FPGA Drive Recorder) |

## Origin of the sources

* The recorder datapath (`Vivado/src/hdl/fdrec_*.v`), its testbenches, `include/fdrec_*.h`,
  the `fdrec` kernel driver (`sw/fdrec-driver`), the recorder apps (`sw/fdrec-apps`) and the
  `Yocto/meta-fdrec` layer come from the
  [FPGA Drive Recorder](https://github.com/fpgadeveloper/fpga-drive-recorder) and keep their
  `fdrec` names.
* The PCIe root-port configuration for the FPGA Drive FMC Gen4 on the ZCU106 HPC1 connector
  follows [fpga-drive-aximm-pcie](https://github.com/fpgadeveloper/fpga-drive-aximm-pcie)
  (`zcu106_hpc1`).
* The Ethernet MAC, PCS, transceiver wrapper, MDIO master and AXI-Stream FIFOs are from
  [Taxi](https://github.com/fpganinja/taxi) (git submodule, CERN-OHL-S-2.0).
