# FPGA Packet Recorder

## Description

This reference design turns an AMD [ZCU106] fitted with Opsero's [Ethernet FMC Max] (OP080)
and [FPGA Drive FMC Gen4] (OP063) into a lossless, hardware-timestamped Gigabit Ethernet
packet capture and replay tool.

Capture runs entirely in the FPGA fabric and records straight to an NVMe SSD with the
zero-copy datapath of the [FPGA Drive Recorder](https://github.com/fpgadeveloper/fpga-drive-recorder).
Every frame is timestamped in hardware from the PHYs' start-of-frame signals against one
shared timebase. The four ports work as two transparent inline TAPs (P0-P1, P2-P3) or as four
independent monitor inputs, selectable at runtime. A web interface on the board's Ethernet
port starts and stops captures and serves them as pcapng files that open directly in
Wireshark. Captures can be replayed out of a port with their original timing.

> **Status:** development is in progress on the `dev` branch. The current milestone (M0) is
> the base platform: the Zynq UltraScale+ PS with the board's RJ45 (GEM3), one PCIe Gen3 x1
> root port on HPC1 for SSD slot 1 of the FPGA Drive FMC Gen4, and the FPGA Drive Recorder
> datapath (`fdrec_core` + AXI DMA) fed by its test pattern generator. The Ethernet FMC Max
> port subsystem on HPC0 is not in the design yet.

Important links:

* Datasheet for the [Ethernet FMC Max]
* Datasheet for the [FPGA Drive FMC Gen4]
* The user guide sources are in [`docs/`](docs/source)
* To report a bug: [Report an issue](https://github.com/fpgadeveloper/fpga-packet-recorder/issues "Report an issue").
* For technical support: [Contact Opsero](https://opsero.com/contact-us "Contact Opsero").

## Requirements

This project is designed for version 2025.2 of the AMD tools (Vivado / Vitis) and the
AMD Yocto / Embedded Development Framework (EDF) 2025.2. There is no PetaLinux flow and no
standalone (baremetal) flow.

* Vivado 2025.2 (Standard Edition, no license needed)
* Vitis 2025.2 (provides `sdtgen`/`xsct` for the Yocto flow)
* A Linux build machine for the Yocto flow (see [Yocto/README.md](Yocto/README.md))
* [ZCU106] with the [Ethernet FMC Max] on HPC0 and the [FPGA Drive FMC Gen4] on HPC1
* One M.2 NVMe PCIe SSD in slot 1 of the FPGA Drive FMC Gen4 (HPC1 has a single
  transceiver, so the SSD links at Gen3 x1 and slot 2 is powered off)

## Target designs

<!-- updater start -->
### Zynq UltraScale+ designs

| Target board          | Target design   | SSD<br> PCIe Lanes | FPGA Drive FMC<br> Slot | Ethernet FMC Max<br> Slot | Standalone | PetaLinux | Yocto | Vivado<br> Edition | IP<br>License |
|-----------------------|-----------------|--------------------|-------------|-------------|-------|-------|-------|-------|-------|
| [ZCU106]              | `zcu106`        | 1     | HPC1        | HPC0        | :x:         | :x:         | :white_check_mark: | Standard :free: | -     |

[ZCU106]: https://www.xilinx.com/zcu106
<!-- updater end -->

## Build instructions

Clone the repo and change into its directory:
```
git clone --recursive https://github.com/fpgadeveloper/fpga-packet-recorder.git
cd fpga-packet-recorder
```

To build everything for the `zcu106` target (Vivado XSA, then the Yocto image, then the
boot image zip in `bootimages/`), on a Linux machine:
```
./build.sh all --target zcu106
```

Single stages: `./build.sh xsa --target zcu106`, `./build.sh yocto --target zcu106`,
`./build.sh package --target zcu106`; artifact state: `./build.sh status --target zcu106`.
The build runner (`build.py`, with the `build.sh` / `build.bat` shims) finds Vivado and
Vitis in their standard install locations; see `./build.sh --help`.

This repository uses git submodules. Clone it with `--recursive`, or run
`git submodule update --init` in an existing clone, before building.

### Simulating the custom RTL

The recorder RTL in `Vivado/src/hdl` has self-checking testbenches in `Vivado/src/sim`, run in
the Vivado simulator by `Vivado/scripts/sim.tcl`:
```
cd Vivado
vivado -mode batch -notrace -source scripts/sim.tcl -tclargs all
```

## Origin of the recorder sources

The recording datapath RTL (`Vivado/src/hdl/fdrec_*.v`), its testbenches, the register
header (`include/fdrec_*.h`), the `fdrec` kernel driver (`sw/fdrec-driver`), the recorder
apps (`sw/fdrec-apps`) and the Yocto layer `Yocto/meta-fdrec` were copied from
[fpga-drive-recorder](https://github.com/fpgadeveloper/fpga-drive-recorder) @ `92817d3`.
They keep their `fdrec` names so that the driver, device tree and recipes work unchanged.

## License

Opsero's code is MIT licensed - see [LICENSE.txt](LICENSE.txt). Third-party components under
`submodules/` carry their own licenses - see [submodules/README.md](submodules/README.md).

## About us

[Opsero Inc.](https://opsero.com "Opsero Inc.") is a team of FPGA developers delivering FPGA products and 
design services to start-ups and tech companies. Follow our blog, 
[FPGA Developer](https://www.fpgadeveloper.com "FPGA Developer"), for news, tutorials and
updates on the awesome projects we work on.

[ZCU106]: https://www.xilinx.com/zcu106
[Ethernet FMC Max]: https://docs.opsero.com/op080/datasheet/overview/
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
