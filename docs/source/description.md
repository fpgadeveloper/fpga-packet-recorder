# Description

The FPGA Packet Recorder captures Gigabit Ethernet traffic from the four ports of an
[Ethernet FMC Max] in the FPGA fabric, timestamps every frame in hardware against one shared
timebase, and records the frames to an NVMe SSD on an [FPGA Drive FMC Gen4] with the
zero-copy datapath of the [FPGA Drive Recorder](https://recorder.fpgadrive.com). The ports
work as two transparent inline TAPs (P0-P1, P2-P3) or as four independent monitor inputs.
Captures are served as pcapng files by a web interface on the board's own Ethernet port, and
can be replayed out of a port with their original timing.

## Development status

| Milestone | Content | Status |
|-----------|---------|--------|
| M0 | Base platform: ZynqMP PS + board RJ45 (GEM3), PCIe Gen3 x1 root port on HPC1 (SSD slot 1), recorder datapath with the test pattern generator as source, Yocto image | in progress |
| M1+ | Ethernet FMC Max port subsystem, timestamping, capture format, web interface, replay | planned |

[Ethernet FMC Max]: https://docs.opsero.com/op080/datasheet/overview/
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
