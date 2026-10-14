# Known limitations

## Hardware

* **No bypass relays.** The Ethernet FMC Max has no relays that connect a TAP pair's two
  ports when the board is off. A TAP breaks the tapped link whenever the board is unpowered,
  booting or reconfiguring the FPGA. See [Hardware setup](hardware_setup).
* **SSD on a PCIe Gen3 x1 link.** On the ZCU106, the FPGA Drive FMC Gen4 sits on HPC1, which
  routes one transceiver: one SSD (slot 1) at Gen3 x1, with a measured ceiling of about
  743 MB/s and a sustained budget of 700 MB/s. Slot 2 is not used. This is enough for four
  ports at line rate (at most about 500 MB/s) with a fast SSD, but there is no RAID0 option and
  little headroom for a slower SSD. See [Performance](performance).
* **One target.** The design is built for the ZCU106 with the Ethernet FMC Max on HPC0 and the
  FPGA Drive FMC Gen4 on HPC1 only.

## Ethernet

* **1000BASE-T only.** At boot the PHYs advertise 1000 Mb/s full duplex only, so 10/100 Mb/s
  devices do not link. Tapping a 100 Mb/s link is not supported: the forward path cannot bridge
  two different speeds, and the SFD windows and offsets are calibrated for 1 Gb/s only. The
  MAC/PCS supports SGMII rate adaptation, so monitoring at 10/100 Mb/s (by running
  `pktrec-phy init` without `--1000-only`) may work, but it has not been tested.
* **Frames longer than 1522 bytes are flagged oversize.** The MACs accept frames up to
  1522 bytes including the FCS by default (`RX_MAX_LEN` / `TX_MAX_LEN`): a full-size
  802.1Q-tagged frame passes as a good frame, captured and forwarded intact. A longer frame
  is captured whole but with the bad-frame flag (counted in `RX_BAD`), and in TAP mode it
  leaves the other port cut at 1522 bytes and error-terminated. The limit is a per-port
  register: `pktrec-phy maxlen <port|all> --set <bytes>` raises it (up to 16383, e.g. 2000
  for "baby jumbo" frames) and raises the (experimental) dynamic inter-frame gap thresholds
  with it.
  Frames above 1522 bytes have been checked in simulation only.
* **Store-and-forward TAP.** The forwarding latency grows with the frame size: 8 ns per byte
  plus 917 ns (1.43 µs at 64 bytes, 13.06 µs at 1518 bytes). It is fixed for a given frame
  size, but it is not the constant latency of a cut-through or passive TAP. See
  [Port modes](modes.md#forwarding-latency).
* **A device faster than the board at sustained 100 % utilisation loses frames (counted).**
  The TAP sends every frame with a gap of at least 12 bytes (13 after an odd-length frame) on
  the board's own clock. A device whose clock is faster than the board's (up to +200 ppm),
  or that sends odd-length frames back-to-back with exactly 12-byte gaps, can deliver more
  than the board sends. The 16 KB forward buffer absorbs bursts of that; if it lasts, the
  frames that no longer fit are dropped whole and counted in `DROP_FWD`, never lost
  silently. Below 100 % utilisation nothing is dropped. The traffic is retimed by the board's
  transmit clock, so the far device can see gaps different from those that were sent.
* **No catch-up with shorter gaps.** The design can shorten the transmit gap while the
  forward buffer is full (dynamic inter-frame gap, registers `IFG_CTRL` / `IFG_THRESH`), but
  this is off by default and the reduced gap is 12 bytes: the DP83867 PHYs lose frames after
  gaps below 12 bytes. Measured on 2026-10-14 (P2 to P0 of one board, line rate, 64-to-67-byte
  frames): with a 12-byte gap all 15 854 447 frames arrived; with 11 bytes 4 055 good and 37
  bad of 15 995 514; with 8 bytes 41 good and 258 bad of 16 594 129 (the PHY's FIFO depth
  settings did not help). In a TAP, reduced-gap episodes (8 to 11 bytes) wiped out traffic far
  beyond the episodes (6 403 to 23 815 of 15.5 million frames arrived). `pktrec-phy ifg`
  refuses a gap below 12 bytes unless `--i-know-the-phy-drops-frames` is given (experiments
  with other PHYs only).
* **Errored frames are not forwarded bit-exact.** A frame received with a bad FCS is forwarded
  with an error code in place of the FCS: the far device sees a receive error, not the same
  bytes and FCS. The original FCS is never captured (`if_fcslen` = 0).
* **Link-state propagation is not instant.** The far device sees its link go down about
  0.8 s after the other device's link went (0.5 s debounce plus the PHY), and the links come
  back about 7 s after the loss ends (auto-negotiation on both sides). A partner whose device
  is gone sees its link come up for up to about 6 s before it is taken down again. P1 to P3
  are held down by PHY power-down; P0, whose PHY clocks the other three and must not be
  powered down, is held by MII loopback (with auto-negotiation off) after its path has been
  set idle. See [Port modes](modes.md#link-state-propagation) for the measured times.
* **Back-to-back odd-length frames are forwarded about 1 % slower.** The gap after an
  odd-length frame is 13 bytes instead of 12 (see above), so 66/67-byte traffic at line rate
  carries about 1 % fewer frames than 66-byte traffic.
* **Loopback and TAP forwarding are mutually exclusive.** A PHY or path loopback on a port that
  is forwarded into reflects the far device's traffic back to it; on the pair that carries the
  network this stops the whole network. `pktrec-phy` refuses every such combination, and on
  the pair that carries the network (pair 0 by default) it refuses every loopback, in any
  mode, unless `--i-accept-lan-loop` is given (see [Loop safety](modes.md#loop-safety)); raw
  extended-register writes through `mdio <port> 0x0d/0x0e` are not checked.

## Timestamps

* **Absolute time is bounded by NTP.** The timebase follows the board's system clock closely,
  but the system clock is only as accurate as its NTP synchronisation: with the image's
  `chrony`, 1.1 to 1.4 ms against an NTP-synchronised PC was measured (the PC's own error
  limited that measurement); with `systemd-timesyncd`, 25 ms. Relative timing between frames
  and ports is not affected. See [Timestamping](timestamping.md#timebase-and-absolute-time).
* **No PTP hardware clock.** The timebase is not exposed as a Linux PTP clock (`/dev/ptpN`)
  and cannot be synchronised by PTP.
* **Per-link-up uncertainty.** The PHYs' receive latency depends on the 1000BASE-T
  master/slave role of each link-up (about ±2.3 ns, not corrected).
* **Calibration per bitstream.** The SFD sampler's clock phase can change with every build;
  re-calibrate after rebuilding the bitstream. The shipped calibration was measured on one
  ZCU106 with an Ethernet FMC Max Rev-B; the offsets of P0 and P1 were taken from P2/P3.

## Capture and export

* **Frames are not stored in timestamp order.** The exporter reorders them within a bounded
  window (the hardware bound is 64 KB of records); the defaults have a large margin.
* **Never step the timebase backwards during a capture.** The tools never do; a manual
  `TB_SET`/`TB_ADJ` backwards during a capture makes the export report out-of-order records.
* **Export speed.** `pktrec-export` converts about 400 000 records per second on one CPU core
  of the board, so a long capture of small frames takes longer to convert or download than it
  took to record.
* **The Python checker is slow on the board.** `pktrec-check-pcap` (`check_pcap.py`) checks
  about 6 500 records/s on the board's CPU: hours for a line-rate capture. Use
  `pktrec-export --check` on the board or `check_pcap.py` on a PC instead (see
  [Testing](testing.md#checking-large-captures)).
* **No capture filters or triggers.** Every frame of an enabled port is captured; snap length
  and port enables are the only ways to reduce the data. There is no hardware filtering by
  EtherType, VLAN or address, and no trigger-based or ring-buffer capture.
* **One capture at a time**, for all ports together.

## Replay

* **One DMA direction at a time.** The recorder datapath has one AXI DMA used in one direction
  at a time: a replay streamed from the SSD cannot run while a capture records. A replay can
  run during a capture only from the replay block's store (`--preload`: up to 128 KB of frame
  data or 2048 frames).
* **One interface, one port per run.** Both directions of a TAP capture cannot be replayed at
  the same time.
* **Replay and TAP mode exclude each other on a pair.**
* **Timing granularity.** Frames leave within about ±16 ns of their target (the MAC's
  62.5 MHz clock), not at the 1 ns resolution of the timestamps. Traffic captured at line rate
  from a device with a faster clock than the board's cannot be replayed at the original
  timing without late frames.
* **Only capture files** (`.cap`) can be replayed, not pcapng files.

## Software

* **No authentication.** The web interface has no login and no encryption; anyone who can
  reach the board's address can start, download and delete captures. Keep the board on a
  trusted network.
* **Linux only, Yocto only.** There is no standalone (baremetal) application and no PetaLinux
  flow; the image is built with the Yocto / EDF flow, which needs a native Linux build machine.
* **Tool version.** The repository is for Vivado / Vitis / EDF 2025.2.
