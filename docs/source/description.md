# Description

The FPGA Packet Recorder is a reference design that turns an AMD [ZCU106] fitted with
Opsero's [Ethernet FMC Max] (OP080) and [FPGA Drive FMC Gen4] (OP063) into a Gigabit
Ethernet packet capture and replay tool. The four Ethernet ports of the Ethernet FMC Max are
captured in the FPGA fabric, every frame is timestamped in hardware, and the frames are
recorded to an NVMe SSD with the zero-copy datapath of the
[FPGA Drive Recorder](https://recorder.fpgadrive.com). A web interface on the board's own
Ethernet port starts and stops captures and serves them as pcapng files that open directly
in Wireshark. A capture can be played back out of a port with its original timing.

It is a reference design, not a product: it shows how to build such a tool from open-source
parts, and this documentation reports what was measured, including the limitations.

## Features

* **Four Gigabit Ethernet ports** (1000BASE-T, the four TI DP83867 PHYs of the Ethernet FMC
  Max), connected to the FPGA over SGMII.
* **Two port modes, selectable per port pair at run time:**
  * **TAP mode:** the ports of a pair (P0/P1, P2/P3) sit inline in a link and forward
    everything they receive to each other in the fabric, so the two devices on either side
    keep communicating. Both directions of the link are captured. Up to two links tapped.
  * **Monitor mode:** each port receives only, for example from a switch's SPAN/mirror port.
    Up to four capture inputs.
* **Lossless capture.** Frames are recorded in the fabric and written to the SSD without the
  CPU touching the data. The SSD sustains more than four ports can receive at line rate,
  at any frame size (see [Performance](performance)). If frames are ever dropped (for example
  because another program loads the SSD), they are dropped whole and counted per port, in the
  capture file and in the pcapng interface statistics, never silently.
* **Hardware timestamps** with **1 ns resolution**, taken from the PHYs' start-of-frame
  delimiter (SFD) indications against one 64-bit nanosecond timebase shared by all four
  ports. The timebase is disciplined to the board's system clock (NTP), so timestamps are
  wall-clock times. See [Timestamping](timestamping).
* **Per-frame metadata:** timestamp, port, captured and original length, bad-frame (FCS)
  flag, truncation flag, timestamp source and a per-port sequence number.
* **Snap length and per-port enables** to reduce the recorded data.
* **pcapng export** with one interface per port, nanosecond timestamps, frames in timestamp
  order and per-port drop counters. The export streams, so a download needs no second copy
  on the SSD.
* **Web interface:** port status, mode selection, start/stop (by hand, or after a duration
  or size limit), live statistics, list, download and delete captures, and a JSON API for
  scripting.
* **Replay** of one port's frames out of any port in monitor mode, with the original timing,
  scaled, at a fixed interval or back to back at line rate. The release time of every frame
  is decided in hardware against the same timebase.
* **Built-in test equipment:** a sequence-numbered traffic generator and checker on every
  port, used for the line-rate tests and the timestamp calibration.

## How it works

```none
                 Ethernet FMC Max (HPC0)                   ZCU106 programmable logic
                 ┌──────────────────────┐
 RJ45 P0..P3 ────┤ 4 x DP83867 PHY      ├─ SGMII (GTH) ─► Taxi 1000BASE-X/SGMII MAC+PCS (x4)
                 │                      │                   │ RX                      ▲ TX
                 │ SFD pins (GPIO_0 RX, ├─ LVCMOS18 ─┐      │                         │
                 │          GPIO_1 TX)  │            │      ├──────────► per-port TX source:
                 └──────────────────────┘            │      │            idle / FWD to the pair
                                                     ▼      │            partner (TAP) / generator
                                  1 ns SFD sampler (ISERDES)│            / replay
                                                     │      ▼
                       64-bit ns timebase ──────►  capture: SFD match, record header,
                       (disciplined to NTP)          16 KB frame FIFO per port (whole-frame drops
                                                     counted), snap length, port enable
                                                            │ 4:1 merge of whole records
                                                            ▼
                     FPGA Drive Recorder datapath: packetizer ─► AXI DMA (S2MM)
                                                            │
  Zynq UltraScale+ PS ─────────────────────────────────────▼──────────────────────────────
     DDR: ring of 2 MB hugepage buffers ─► io_uring O_DIRECT writes ─► NVMe SSD
                                                (FPGA Drive FMC Gen4 on HPC1, PCIe Gen3 x1)
     Linux: pktrec-cap / pktrec-export / pktrec-replay / pktrec-web, on the board's RJ45 (GEM3)

  Replay: SSD ─► DDR ring ─► AXI DMA (MM2S) ─► record parser ─► frame store ─► scheduler
          (releases each frame at its timestamp against the timebase) ─► TX MAC of one port
```

* The Ethernet ports use the open-source [Taxi](https://github.com/fpganinja/taxi) 1G MAC/PCS
  and transceiver wrapper in its low-latency (buffer-bypass) mode.
* **TAP forwarding** happens entirely in the fabric, store-and-forward, never through Linux.
* **Capture:** each port turns every frame it receives into a record (a 16-byte header and the
  frame bytes). The records of the four ports are merged and written to the SSD by the
  recorder datapath: the AXI DMA fills buffers in the processor's DDR memory and the NVMe
  controller reads the same buffers when the file is written. The processor only does the
  bookkeeping.
* **Timestamps** come from the PHYs' SFD pins, sampled at 1 ns, and are matched to their
  frames in hardware. A frame without a matching SFD indication falls back to a MAC-level
  timestamp and is flagged as such.
* **Export:** `pktrec-export` converts a capture file to pcapng in timestamp order. The web
  server runs it during a download.

The [Architecture](design) page describes the hardware in detail.

## Recording throughput budget

The ZCU106 HPC1 connector routes a single gigabit transceiver to the FPGA Drive FMC Gen4, so
the SSD runs at **PCIe Gen3 x1**. What the capture can produce is bounded by what four
1 Gb/s ports receive:

| Traffic (all four ports at line rate) | Frames/s per port | Record size | Capture data rate |
|---------------------------------------|-------------------|-------------|-------------------|
| 64-byte frames | 1 488 095 | 80 bytes | 476 MB/s |
| 1518-byte frames | 81 274 | 1536 bytes | 499 MB/s |

(A record is the 16-byte header plus the frame without its FCS, padded to 16 bytes. In TAP
mode the four receive streams are the two directions of the two tapped links, so the
numbers are the same.)

Measured on 2026-10-13 with a Samsung 980 PRO 1TB on this x1 link (XFS), the recorder
sustained **700 MB/s for 40 GB without drops**, with a ceiling of about 743 MB/s. The
worst case of the table fits with a margin of about 30 %, and full line rate on all four
ports was recorded without drops at both frame sizes. An SSD whose sustained (post-cache)
write rate is below 500 MB/s may not keep up with four ports at line rate; the snap length
and the port enables reduce the rate. See [Performance](performance).

## Hardware platforms

{% for group in data.groups %}
{% set designs = data.designs | selectattr("group", "equalto", group.label) | selectattr("publish") | list %}
{% if designs %}
### {{ group.name }} platforms

| Target board | Target design | Ethernet FMC Max slot | FPGA Drive FMC Gen4 slot | SSD PCIe lanes | Yocto |
|--------------|---------------|-----------------------|--------------------------|----------------|-------|
{% for d in designs %}| [{{ d.board }}]({{ d.link }}) | `{{ d.label }}` | {{ d.eth_connector }} | {{ d.ssd_connector }} | {{ d.lanes[0][1:] }} | {{ "Yes" if d.yocto else "No" }} |
{% endfor %}
{% endif %}
{% endfor %}

## IP cores and licensing

| Component | Source | License |
|-----------|--------|---------|
| Ethernet MAC/PCS, transceiver wrapper, MDIO master, AXI-Stream FIFOs | [Taxi](https://github.com/fpganinja/taxi) (FPGA Ninja), git submodule `submodules/taxi`, used unmodified | CERN-OHL-S-2.0 (or a commercial license from FPGA Ninja) |
| Capture, timestamping, forwarding, generator and replay logic (`pktrec_*`), recorder datapath (`fdrec_*`), software | this repository | MIT |
| Zynq UltraScale+ PS, DMA/Bridge Subsystem for PCIe (root port), AXI DMA, interconnect | AMD, Vivado IP | no separate license needed |

CERN-OHL-S-2.0 is strongly reciprocal: a product or bitstream that contains the Taxi sources
comes with obligations to share the source of the design. See `submodules/README.md` in the
repository.

## Software

The design runs embedded Linux built with the AMD Yocto / Embedded Development Framework
(EDF) flow. There is no PetaLinux flow and no standalone (baremetal) application. The image
contains:

| Component | What it does |
|-----------|--------------|
| `pktrec-web` | Web interface and JSON API on the board's RJ45 port ([Web interface](web_ui)) |
| `pktrec-cap` | Configures the capture and records it to the SSD |
| `pktrec-export` | Converts a capture file to pcapng (streaming) |
| `pktrec-replay` | Plays one port's frames of a capture out of a port |
| `pktrec-phy` | PHY configuration, link status, port modes, SFD timestamping, generator and checker, forwarding latency |
| `pktrec-tb` | Disciplines the hardware timebase to the system clock and applies the calibration at boot |
| `fdrec.ko`, `fdrec`, `fdplay`, `fdverify`, `fdsetup-raid0.sh` | Kernel driver and tools of the FPGA Drive Recorder |
| `pktrec-pktgen`, `pktrec-check-pcap`, `pktrec-pcapng-lint` | Test traffic and capture checkers ([Testing](testing)) |

The command reference is on the [Software](software) page.

[ZCU106]: https://www.xilinx.com/zcu106
[Ethernet FMC Max]: https://docs.opsero.com/op080/datasheet/overview/
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
