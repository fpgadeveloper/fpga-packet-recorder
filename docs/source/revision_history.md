# Revision history

## v1.0 (2025.2, in development)

Initial version of the FPGA Packet Recorder for the ZCU106 (`zcu106`), with the Ethernet FMC
Max on HPC0 and the FPGA Drive FMC Gen4 on HPC1, built with Vivado / Vitis 2025.2 and the
Yocto / EDF 2025.2 flow.

* Platform: Zynq UltraScale+ PS with the board's RJ45 (GEM3); PCIe Gen3 x1 root port on HPC1
  for SSD slot 1; the FPGA Drive Recorder datapath (`fdrec_core` 1.2, AXI DMA) with a second,
  back-pressured source for the capture records.
* Ethernet ports: four SGMII ports with the Taxi 1G MAC/PCS and low-latency transceiver
  wrapper (receivers in LPM mode); per-port transmit paths (idle, loopback, forward,
  generator, replay); hardware traffic generator and checker on every port.
* Capture (register map 1.2): per-port 16 KB frame FIFOs with whole-frame drop counting,
  snap length, port enables, record format v1, 4:1 whole-record merge; 64-bit nanosecond
  timebase; SFD timestamping with 1 ns ISERDES sampling, matching to frames, MAC fallback and
  flags.
* TAP mode: per-pair TAP/monitor modes, store-and-forward forwarding with errored-frame
  propagation, dynamic inter-frame gap, clean mode switching, 1000BASE-T-only advertisement,
  link-state propagation (MII loopback of the partner PHY), per-link-up correction of the PHY's
  receive latency step (register `0x0055`).
* Replay (register map 1.0): record parser, 128 KB frame store, hardware scheduler (original
  timing, scaled, fixed gap, back to back), lateness and underrun counters.
* Software: `pktrec-cap`, `pktrec-export` (streaming pcapng), `pktrec-replay`, `pktrec-phy`,
  `pktrec-tb` (timebase discipline to NTP, persistent calibration), `pktrec-web` (web
  interface and JSON API), the image's services (PHY init and link watcher, SSD mount,
  calibration, timebase, web server, console banner).
* Test tools in `test/` and self-checking RTL testbenches.
* Documentation: this site, with the measured performance, timestamp accuracy, TAP latency
  and replay accuracy.
