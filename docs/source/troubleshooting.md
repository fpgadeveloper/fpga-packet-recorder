# Troubleshooting

## Boot and access

### No web interface URL on the console

The line `pktrec web UI: http://<address>:8080/` appears once the board's RJ45 port (`end0`)
has an address from DHCP (the banner waits up to 3 minutes).

* Check that the ZCU106's own RJ45 port (not an Ethernet FMC Max port) is cabled to a network
  with a DHCP server.
* Log in on the UART and run `ip -br addr show end0`. Without an address, check the cable and
  the DHCP server; with an address, open `http://<address>:8080/`.
* `systemctl status pktrec-web` shows whether the server runs; `journalctl -u pktrec-web` shows
  why not.
* The server listens on `end0` only: `curl localhost:8080` on the board does not reach it.

### The board does not boot

* Check SW6 (SD boot: switches 1 to 4 = ON, OFF, OFF, OFF) and that `BOOT.BIN` was copied to
  the first (FAT) partition of the SD card: the EDF image leaves it empty (see
  [Yocto](yocto.md#boot-from-sd-card)).
* Watch the UART from power-on. If nothing appears, check the boot mode and the SD card.

### No `PCIe Link is UP`, no `/dev/nvme0n1`

* The FPGA Drive FMC Gen4 must be on **HPC1**, with the SSD in **slot 1**. Re-seat the card and
  the SSD.
* `dmesg | grep -i "pcie link"` and `lspci -vv | grep -E "LnkCap|LnkSta"`: the link should be
  8 GT/s x1.
* The FPGA Drive Recorder's
  [troubleshooting guide](https://recorder.fpgadrive.com/en/latest/troubleshooting.html)
  covers the PCIe link and the `fdrec` driver (`/dev/fdrec0`) in more detail.

### The SSD is not mounted (`503`, "the SSD is not mounted at /mnt/rec")

`mnt-rec.mount` mounts `/dev/nvme0n1` as XFS at `/mnt/rec`. A new SSD must be formatted once
with `sudo fdsetup-raid0.sh --single /dev/nvme0n1` (this erases it); see
[Hardware setup](hardware_setup.md#ssd). `systemctl status mnt-rec.mount` shows the reason
for a failed mount.

## Ports and links

### A port does not link

* `sudo pktrec-phy status` shows the copper link, the speed and the SGMII state of each port.
* The ports advertise **1000BASE-T full duplex only**. A device that cannot do 1 Gb/s (or is
  forced to 10/100 Mb/s) does not link. See [Port modes](modes.md#speed).
* Check `systemctl status pktrec-phy-watch`: the service configures the PHYs at boot (`init`)
  and keeps the MAC informed of link changes. If it is not running, the PHYs keep their
  power-on defaults and a link may come up without passing traffic. Restart it with
  `sudo systemctl restart pktrec-phy-watch`.
* A link light alone does not prove the path works; the frame counters do
  (`sudo pktrec-phy counters`).

### Devices on a TAP pair cannot communicate

* Check the mode: `sudo pktrec-phy mode status`; the pair must be `tap`.
* Both devices must have a link at 1 Gb/s (`pktrec-phy status`).
* A port of the pair in replay prevents TAP mode; stop the replay.
* `sudo pktrec-phy counters` shows whether frames are received (RX) on one port and
  transmitted (TX) on the other, and `DROP_FWD` for forwarding drops.
* After a reboot of the board both pairs are in monitor mode again; set TAP mode again.

### Received frames are flagged bad

* A frame larger than 1518 bytes (including the FCS) is flagged bad by the MAC: jumbo frames
  and full-size VLAN-tagged frames are not supported (see
  [Known limitations](known_limitations)).
* Otherwise the frames really arrived with an error: check the cable, and the far device's
  transmit errors.

## Captures

### `pktrec-cap` exits with code 2 / the web interface reports drops

The capture is complete, but frames were dropped. Drops happen when the data arrive faster than
the SSD writes them: the per-port frame FIFOs fill up and frames are dropped whole and
counted.

* Is another program writing to or reading from the SSD at the same time (including a
  download from the web interface of another capture)? Stop it.
* Is the SSD fast enough? Four ports at line rate need up to 500 MB/s sustained. Measure the
  SSD's sustained rate with the FPGA Drive Recorder's `fdbench.sh`, and see
  [Performance](performance).
* Is the SSD nearly full? XFS slows down on an almost full filesystem.
* Reduce the data: capture fewer ports, or set a snap length.

### `pktrec-cap` stops with "recording stalled"

The SSD did not complete a write for `--timeout` seconds (default 10). Check `dmesg` for NVMe
errors. An idle network is not a stall.

### Timestamps are flagged as MAC timestamps

Records with flag bit 2 (with `pktrec-export --comments`: "MAC timestamp") did not match an SFD
indication.

* After a new bitstream the SFD calibration may be off: check `sudo pktrec-phy sfd status`.
  If `RX_MISMATCH` counts and `RX_HEAD_DELTA` lies outside the receive window, adjust the
  window and re-calibrate (see [Timestamping](timestamping.md#calibration)).
* Check that the calibration was applied at boot: `pktrec-tb show-calibration` and
  `systemctl status pktrec-calibration`.
* `pktrec-phy init --no-sfd` (or a PHY reset without `init`) leaves the SFD indications off.

### Timestamps are not wall-clock time / the timebase is not locked

* `pktrec-tb status` shows the discipline. The daemon needs the system clock to be
  NTP-synchronised (`timedatectl`): the board needs a route to an NTP server.
* After boot, locking takes about a minute; after the system clock is stepped by NTP the
  daemon re-locks.
* A capture that starts while the daemon is not locked sets the timebase from the system clock
  once (`pktrec-cap info` shows this as `tb discipline`).

### `pktrec-export` exits with code 2

The file was exported but with anomalies, listed in the summary on stderr:

* "records later than the window": increase `--window-records` / `--window-bytes` (the summary
  gives the largest reorder distance seen); this happens if the timebase was stepped backwards
  during the capture;
* resyncs / skipped bytes: the file is damaged; the frames around the damage are lost, the
  rest is exported;
* truncated tail or no COMPLETE flag: the capture was interrupted (power loss). The frames
  in the file are exported.

### Wireshark shows "60 bytes captured" for a 64-byte frame

This is expected: the FCS is not stored, and the pcapng records the original length including
it. See [File formats](capture_format.md#pcapng-mapping).

## Replay

### `pktrec-replay` refuses the port

* The output port's pair is in TAP mode, or its partner forwards: `sudo pktrec-phy mode <pair>
  monitor` first.
* The port has no link, or the replay block is busy: check `pktrec-phy status`; `--force`
  overrides.
* `/dev/fdrec0` is busy: a capture (or `fdrec`/`fdplay`) is running. Use `--preload` to replay
  during a capture (see [Replay](replay.md#replay-and-capture-at-the-same-time)).

### Underruns or late frames

* Underruns: the stream from the SSD did not keep up; check for other I/O on the SSD.
* Late frames without underruns: the capture holds frames closer together than the output port
  can send them, or `--rate` asks for more than the line carries.

## Build failures

1. **Are you using the correct version of Vivado for this version of the repository?** The
   design needs Vivado, Vitis and EDF 2025.2 (see [Requirements](requirements)).
2. **Did you clone the repository with its submodules?** Clone with `--recursive`, or run
   `git submodule update --init`; the Ethernet ports need the Taxi submodule.
3. **Did you change the RTL?** A module-reference top must be a Verilog (`.v`) or VHDL file;
   Vivado 2025.2 rejects a SystemVerilog top.
4. **Yocto on Windows or WSL** is not supported; build the XSA there and the Yocto image on a
   native Linux machine (see [Build instructions](build_instructions)).
5. **A change in `sw/` does not show up in the image:** delete `Yocto/zcu106/images/linux/`
   and build again (see [Yocto](yocto.md#how-to-build)).
