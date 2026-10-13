# FPGA Packet Recorder

Reference design that turns an AMD ZCU106 fitted with Opsero's
[Ethernet FMC Max](https://docs.opsero.com/ethernet-fmc-max) and
[FPGA Drive FMC Gen4](https://docs.opsero.com/fpga-drive-fmc-gen4) into a lossless,
hardware-timestamped Gigabit Ethernet packet capture and replay tool.

Capture runs entirely in the FPGA fabric and records straight to an NVMe SSD with the
zero-copy datapath of the
[FPGA Drive Recorder](https://github.com/fpgadeveloper/fpga-drive-recorder). Every frame is
timestamped in hardware from the PHYs' start-of-frame signals against one shared timebase.
The four ports work as two transparent inline TAPs (P0-P1, P2-P3) or as four independent
monitor inputs, selectable at runtime. A web interface on the board's Ethernet port starts
and stops captures and serves them as pcapng files that open directly in Wireshark. Captures
can be replayed out of a port with their original timing.

Development is in progress on the `dev` branch.

## License

Opsero's code is MIT licensed - see LICENSE.txt. Third-party components under `submodules/`
carry their own licenses.
