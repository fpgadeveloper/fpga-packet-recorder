# Hardware setup

```{warning}
**The Ethernet FMC Max has no bypass relays.** In TAP mode the board forwards the traffic
of a link in the FPGA fabric. The link between the two devices on a TAP pair is therefore
**broken whenever the board is unpowered, booting, or the FPGA is being reconfigured** (a
power cycle, a reboot, a new bitstream). Both devices see a link-down event whenever the
board restarts. Only insert the TAP where such an outage is acceptable.
```

## Mezzanine cards

| Card | Connector | Why |
|------|-----------|-----|
| [Ethernet FMC Max] (OP080) | **HPC0** | All four ports need four gigabit transceivers and the PHY control pins, which only HPC0 provides on the ZCU106. On HPC1 only one port would work. |
| [FPGA Drive FMC Gen4] (OP063) | **HPC1** | HPC1 routes one gigabit transceiver: the SSD in slot 1 links at PCIe Gen3 x1. |

1. With the board powered off, plug the Ethernet FMC Max into HPC0 and the FPGA Drive FMC
   Gen4 into HPC1.
2. Fit the NVMe SSD into **slot 1** of the FPGA Drive FMC Gen4 and tighten its screw. Slot 2
   is not connected on HPC1; the design switches its 3.3 V supply off.
3. Set the boot mode to SD card: DIP switch **SW6** switches 1 to 4 = ON, OFF, OFF, OFF (see
   the ZCU106 user guide).

**VADJ.** On the ZCU106, one VADJ_FMC regulator powers both HPC0 and HPC1. The board's system
controller reads the EEPROMs of both mezzanine cards and sets a voltage that both accept.
With these two cards that is 1.8 V (measured: 1.800 V with both cards fitted). The design's FMC I/O standard is LVCMOS18;
there is nothing to configure.

## Network connections

| Connection | Purpose |
|------------|---------|
| ZCU106 RJ45 (the board's own Ethernet port, PS GEM3) | Management network with a DHCP server. The web interface and SSH are served here only. |
| ZCU106 USB-UART | Console at 115200 baud (8N1); prints the web interface URL at boot |
| Ethernet FMC Max P0..P3 | The ports being captured, cabled by mode (below) |

The ports are numbered P0 to P3 as in the Ethernet FMC Max datasheet. The pairs are
**P0/P1** (pair 0) and **P2/P3** (pair 1).

### Monitor mode

Connect each port that you want to capture to a traffic source that does not need anything
back, typically the SPAN/mirror port of a switch. Each port is an independent receive-only
input. The PHYs still link up (at 1000BASE-T full duplex), so the switch port sees a normal
link.

```none
  switch SPAN port A ──── P0          switch SPAN port C ──── P2
  switch SPAN port B ──── P1          switch SPAN port D ──── P3
```

### TAP mode

Break the link you want to tap and connect its two ends to the two ports of one pair.
Both devices must support 1000BASE-T: the ports advertise 1000 Mb/s full duplex only, so both
sides of a TAP pair link at the same speed (see [Port modes](modes)).

```none
  device A ──── P0 ┐ pair 0 (TAP)   ┌ P2 ──── device C
  device B ──── P1 ┘                └ P3 ──── device D   pair 1 (TAP or monitor)
```

The mode is chosen per pair, so one pair can be a TAP while the other monitors.

### Loopback cable for self-tests

A short Ethernet cable between **P2 and P3** turns pair 1 into a test fixture: the hardware
traffic generator on one port sends to the checker on the other at line rate. The timestamp
calibration ([Timestamping](timestamping.md#calibration)) and the replay accuracy test
([Replay](replay.md#measuring-the-replay-accuracy)) use it. Leave pair 1 in monitor mode while
the cable is fitted: a pair in TAP mode whose two ports are cabled to each other forwards
every frame back to where it came from.

## SSD

The image mounts the SSD at boot (`mnt-rec.mount`: `/dev/nvme0n1`, XFS, at `/mnt/rec`).
A new SSD must be formatted once. **This destroys everything on the SSD.** Log in on the
board (see [Getting started](getting_started)) and run:

```
sudo fdsetup-raid0.sh --single /dev/nvme0n1
```

`fdsetup-raid0.sh` (from the FPGA Drive Recorder) formats the drive with XFS and mounts it at
`/mnt/rec`; it asks for confirmation (`-y` skips the question). From the next boot on, the
mount unit mounts it automatically. Check it with:

```
df -h /mnt/rec
```

A missing or unformatted SSD does not stop the boot: the mount gives up after 20 s and the web
interface then refuses to start captures ("the SSD is not mounted at /mnt/rec"). The web
interface stores its captures in `/mnt/rec/captures/`.

```{note}
`fdsetup-raid0.sh` can also build a RAID0 array of two SSDs on boards that have two M.2 links.
With the FPGA Drive FMC Gen4 on the ZCU106 HPC1 connector there is only one SSD, so always
use `--single`.
```

[Ethernet FMC Max]: https://docs.opsero.com/op080/datasheet/overview/
[FPGA Drive FMC Gen4]: https://docs.opsero.com/op063/datasheet/overview/
