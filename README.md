# FPGA Packet Recorder

## Description

This reference design turns an AMD [ZCU106] fitted with Opsero's [Ethernet FMC Max] (OP080)
and [FPGA Drive FMC Gen4] (OP063) into a lossless, hardware-timestamped Gigabit Ethernet
packet capture and replay tool.

* **Capture in the FPGA fabric, straight to NVMe.** The four ports of the Ethernet FMC Max are
  captured in the fabric and recorded to an NVMe SSD with the zero-copy datapath of the
  [FPGA Drive Recorder](https://github.com/fpgadeveloper/fpga-drive-recorder): the CPU never
  touches the frame data. Four ports at line rate were recorded without a single drop at
  every frame size. Any drop is counted per port and reported, never silent.
* **Hardware timestamps with 1 ns resolution**, from the PHYs' start-of-frame-delimiter
  signals, on one 64-bit nanosecond timebase shared by all ports and disciplined to NTP.
* **TAP or monitor mode per port pair, at run time.** In TAP mode a pair (P0/P1, P2/P3) sits
  inline in a link and forwards both directions in the fabric while capturing them; in
  monitor mode every port is a receive-only input, for example from a switch SPAN port.
* **Web interface** on the board's own Ethernet port: port status, mode, start/stop, live
  statistics, and downloads as **pcapng** that open directly in Wireshark (one interface per
  port, nanosecond timestamps, timestamp order, drop statistics).
* **Replay** of a capture out of a port with its original timing, scaled, or back to back at
  line rate, scheduled in hardware against the same timebase.

This is a reference design, not a product. Read the
[known limitations](docs/source/known_limitations.md) before you use it: in particular, the
Ethernet FMC Max has **no bypass relays**, so a TAP breaks the tapped link whenever the board
is off, booting or reconfiguring.

Important links:

* Datasheet for the [Ethernet FMC Max]
* Datasheet for the [FPGA Drive FMC Gen4]
* The user guide for this reference design is in [`docs/`](docs/source) (Sphinx sources for
  Read the Docs): start with the [description](docs/source/description.md) and
  [getting started](docs/source/getting_started.md)
* To report a bug: [Report an issue](https://github.com/fpgadeveloper/fpga-packet-recorder/issues "Report an issue").
* For technical support: [Contact Opsero](https://opsero.com/contact-us "Contact Opsero").

## Architecture

```
P0..P3 ─ DP83867 ─ SGMII/GTH ─► Taxi 1G MAC/PCS ─┬─► TAP forwarding to the pair partner (fabric only)
          │ SFD pins (1 ns ISERDES sampling)      └─► capture: SFD timestamp + 16-byte record header,
          └──────────────────────────────────────►    16 KB frame FIFO per port, 4:1 record merge
                                                          ▼
              FPGA Drive Recorder datapath ─► AXI DMA ─► DDR hugepage ring ─► NVMe SSD (PCIe Gen3 x1)
Replay:   SSD ─► DDR ring ─► AXI DMA ─► record parser ─► hardware scheduler ─► TX MAC of one port
```

* The Ethernet MAC/PCS and transceiver wrapper come from the open-source
  [Taxi](https://github.com/fpganinja/taxi) library (git submodule).
* The register maps are in [`include/pktrec_regs.h`](include/pktrec_regs.h) and the
  [architecture page](docs/source/design.md); the record and capture file formats are in
  [`include/pktrec_format.h`](include/pktrec_format.h) and
  [file formats](docs/source/capture_format.md).

## Requirements

This project is designed for version 2025.2 of the AMD tools (Vivado / Vitis) and the
AMD Yocto / Embedded Development Framework (EDF) 2025.2. There is no PetaLinux flow and no
standalone (baremetal) flow.

* Vivado 2025.2 (Standard Edition, no license needed)
* Vitis 2025.2 (provides `sdtgen`/`xsct` for the Yocto flow)
* A Linux build machine for the Yocto flow (see [Yocto/README.md](Yocto/README.md))
* [ZCU106] with the [Ethernet FMC Max] on **HPC0** and the [FPGA Drive FMC Gen4] on **HPC1**
* One M.2 NVMe PCIe SSD in slot 1 of the FPGA Drive FMC Gen4 (HPC1 has a single
  transceiver, so the SSD links at Gen3 x1 and slot 2 is powered off). Its sustained write
  rate should be at least 500 MB/s to record four ports at line rate.

## Target designs

<!-- updater start -->
### Zynq UltraScale+ designs

| Target board          | Target design   | SSD<br> PCIe Lanes | FPGA Drive FMC<br> Slot | Ethernet FMC Max<br> Slot | Standalone | PetaLinux | Yocto | Vivado<br> Edition | IP<br>License |
|-----------------------|-----------------|--------------------|-------------|-------------|-------|-------|-------|-------|-------|
| [ZCU106]              | `zcu106`        | 1     | HPC1        | HPC0        | :x:         | :x:         | :white_check_mark: | Standard :free: | -     |

[ZCU106]: https://www.xilinx.com/zcu106
<!-- updater end -->

## Build instructions

Clone the repo **with its submodules**:
```
git clone --recursive https://github.com/fpgadeveloper/fpga-packet-recorder.git
cd fpga-packet-recorder
```

To build everything for the `zcu106` target (the Vivado XSA, then the Yocto image, then the
boot image zip in `bootimages/`), on a Linux machine:
```
./build.sh all --target zcu106
```

Single stages: `./build.sh xsa --target zcu106`, `./build.sh yocto --target zcu106`,
`./build.sh package --target zcu106`; artifact state: `./build.sh status --target zcu106`.
The build runner (`build.py`, with the `build.sh` / `build.bat` shims) finds Vivado and
Vitis in their standard install locations. On Windows, the Vivado XSA builds, but the Yocto
image needs a native Linux machine. See the [build instructions](docs/source/build_instructions.md).

## Quick start

1. Write `rootfs.wic.xz` to a micro SD card and copy `BOOT.BIN` to its first (FAT) partition
   (see [Yocto](docs/source/yocto.md#boot-from-sd-card)); set SW6 to SD boot.
2. Connect the ZCU106's own RJ45 port to a network with DHCP, and the USB-UART to a PC
   (115200 baud). Power up.
3. Format the SSD once: log in as `amd-edf` and run `sudo fdsetup-raid0.sh --single /dev/nvme0n1`
   (erases the SSD).
4. Open the URL printed on the console (`pktrec web UI: http://<board-ip>:8080/`), choose the
   mode of each pair, start a capture, and download it as pcapng.

See [getting started](docs/source/getting_started.md).

## License

Opsero's code is MIT licensed: see [LICENSE.txt](LICENSE.txt). This includes everything
outside `submodules/`: the block design, constraints, the capture, timestamping,
forwarding and replay RTL, the recorder RTL copied from the FPGA Drive Recorder, the
software and the build scripts.

The design uses the [Taxi](https://github.com/fpganinja/taxi) library by FPGA Ninja as a git
submodule (`submodules/taxi`, used unmodified) for the Ethernet MAC/PCS, the transceiver
wrapper, the MDIO master and AXI-Stream FIFOs. Taxi is licensed under the
**CERN-OHL-S-2.0** (strongly reciprocal), or commercially by FPGA Ninja. A bitstream built
from this design contains Taxi sources; see [submodules/README.md](submodules/README.md) for
what that means for your product.

## Origin of the recorder sources

The recording datapath RTL (`Vivado/src/hdl/fdrec_*.v`), its testbenches, the register
header (`include/fdrec_*.h`), the `fdrec` kernel driver (`sw/fdrec-driver`), the recorder
apps (`sw/fdrec-apps`) and the Yocto layer `Yocto/meta-fdrec` were copied from
[fpga-drive-recorder](https://github.com/fpgadeveloper/fpga-drive-recorder) @ `92817d3`
(see [NOTICE](NOTICE)). They keep their `fdrec` names so that the driver, device tree and
recipes work unchanged.

## About us

[Opsero Inc.](https://opsero.com "Opsero Inc.") is a team of FPGA developers delivering FPGA products and 
design services to start-ups and tech companies. Follow our blog, 
[FPGA Developer](https://www.fpgadeveloper.com "FPGA Developer"), for news, tutorials and
updates on the awesome projects we work on.

[ZCU106]: https://www.xilinx.com/zcu106
[Ethernet FMC Max]: https://docs.opsero.com/op080/datasheet/overview/
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
