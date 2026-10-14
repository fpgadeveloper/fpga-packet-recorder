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
  for "baby jumbo" frames) and raises the dynamic inter-frame gap thresholds with it.
  Frames above 1522 bytes have been checked in simulation only.
* **Store-and-forward TAP.** The forwarding latency grows with the frame size: 8 ns per byte
  plus 917 ns (1.43 µs at 64 bytes, 13.06 µs at 1518 bytes). It is fixed for a given frame
  size, but it is not the constant latency of a cut-through or passive TAP. See
  [Port modes](modes.md#forwarding-latency).
* **8-byte inter-frame gaps.** When a device on a TAP pair sends at full utilisation with a
  faster clock than the board's, the TAP shortens the gap of the forwarded frames from 12 to
  8 bytes until its buffer drains. IEEE 802.3 receivers must accept that, and the devices
  tested did, but the far device can see shorter gaps than were sent. The forwarded traffic is
  otherwise retimed by the board's transmit clock.
* **Errored frames are not forwarded bit-exact.** A frame received with a bad FCS is forwarded
  with an error code in place of the FCS: the far device sees a receive error, not the same
  bytes and FCS. The original FCS is never captured (`if_fcslen` = 0).
* **Link-state propagation** takes a few seconds: 0.5 s debounce, then auto-negotiation; a
  partner whose device is gone sees its link come up for up to about 6 s before it is taken
  down again. P1 to P3 are held down by PHY power-down; P0, whose PHY clocks the other three
  and must not be powered down, is held by MII loopback after its path has been set idle.
  This method has not been measured on hardware yet.
* **Loopback and TAP forwarding are mutually exclusive.** A PHY or path loopback on a port that
  is forwarded into reflects the far device's traffic back to it; on the pair that carries the
  network this stops the whole network (it has happened on a test bench). `pktrec-phy` refuses
  every such combination (see [Loop safety](modes.md#loop-safety)); raw extended-register
  writes through `mdio <port> 0x0d/0x0e` are not checked.

## Timestamps

* **Absolute time is bounded by NTP.** The timebase follows the board's system clock closely,
  but the system clock is only as accurate as its NTP synchronisation; a 25 ms error was
  measured 35 minutes after boot with `systemd-timesyncd` as the NTP client. Relative timing between frames
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
