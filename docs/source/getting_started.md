# Getting started

This page takes you from a written SD card to a capture opened in Wireshark. It assumes the
cards and cables are set up as described in [Hardware setup](hardware_setup) and the SD card
was written as described in [Yocto](yocto.md#boot-from-sd-card).

## Boot

1. Insert the SD card, check that SW6 selects SD boot, and connect the USB-UART to your PC.
2. Open a terminal on the UART at 115200 baud (8N1). The ZCU106 USB-UART bridge provides
   several serial ports; the Linux console is on one of them (usually the first).
3. Power up the board.

During the boot, these lines show that the SSD link, the recorder driver and the capture
hardware are up:

```none
xilinx-xdma-pcie 400000000.axi-pcie: PCIe Link is UP
nvme nvme0: 4/0/0 default/read/poll queues
fdrec 420010000.fdrec_core: /dev/fdrec0: fdrec_core v1.2, src_clk ... Hz, dp_clk ... Hz, ...
```

Once the board's RJ45 port has an address from DHCP, the console prints the address of the
web interface, and the login prompt repeats it:

```none
pktrec web UI: http://192.168.2.110:8080/
zcu106-pktrec-2025-2 login:
```

(The address is the one your DHCP server assigns.) The port uses the board's own MAC address,
read from the ZCU106 EEPROM; U-Boot prints it near the top of the UART output
(`Ethernet mac: 00:0a:35:...`). Reserve that MAC address in your DHCP server to give the board
a fixed IP address. If the line does not appear, see
[Troubleshooting](troubleshooting.md#no-web-interface-url-on-the-console).

## Log in

Log in as **`amd-edf`**; on the first login you must choose a password. The user can run
commands as root with `sudo`. The image has an SSH server, so from now on you can also log in
over the network: `ssh amd-edf@<board-ip>`.

At boot the image has already:

* configured the four PHYs for 1000BASE-T full duplex with SFD indications, and started the
  link watcher (`pktrec-phy-watch.service`),
* applied the timestamp calibration (`pktrec-calibration.service`) and started the timebase
  discipline (`pktrec-tb.service`),
* mounted the SSD at `/mnt/rec` (if it is formatted: see
  [Hardware setup](hardware_setup.md#ssd)),
* started the web server (`pktrec-web.service`).

Both pairs start in monitor mode. Check the ports and the SSD:

```
sudo pktrec-phy status
df -h /mnt/rec
```

`pktrec-phy status` shows, for every port, the copper link, the speed and duplex and the
SGMII state. A port with a cable to a 1000BASE-T device shows its link up at 1000 Mb/s full
duplex. If the SSD is new, format it now (see [Hardware setup](hardware_setup.md#ssd)).

## First capture from the web interface

1. Open the URL from the console (`http://<board-ip>:8080/`) in a browser on a PC on the same
   network. The page shows one card per port with its link state.
2. Choose the mode of each pair: **monitor** for SPAN/mirror inputs, **TAP** for a pair that
   sits inline in a link (see [Port modes](modes)). In TAP mode, the two devices on the pair
   can talk to each other as soon as the mode is set.
3. Tick the ports to capture, optionally set a duration or size limit, and click
   **Start capture**. The port cards show frames/s and bits/s while it runs.
4. Click **Stop** (or wait for the limit). The page reports whether the capture was lossless.
5. In the **Captures** table, click **pcapng** to download the capture.

The [Web interface](web_ui) page describes every element of the page and the JSON API.

## Open it in Wireshark

Open the downloaded file in Wireshark. You will see:

* one **interface per captured port**, named `P0` to `P3`, with a description that gives the
  port's mode (for example "monitor mode", or "TAP pair 0 (P0<->P1), forwarded to P1"),
* **nanosecond timestamps** (wall-clock time, see [Timestamping](timestamping)),
* frames in timestamp order, all marked **inbound** (each port records what it receives),
* for each frame, a length on the wire that is 4 bytes longer than the captured length, for
  example "64 bytes on wire (512 bits), 60 bytes captured (480 bits)". The hardware strips
  the FCS and the pcapng records the original length including it. This is expected and is
  not a truncation.
* frames that arrived with a bad FCS (or another receive error) flagged with the pcapng
  "CRC error" flag,
* in the capture file properties, the per-interface statistics: frames received and frames
  dropped by the hardware.

## The same from the command line

On the board (as root):

```
sudo pktrec-phy mode 0 monitor                 # or: tap
sudo pktrec-cap --ports 0,1 --duration 30 /mnt/rec/captures/first.cap
sudo pktrec-export /mnt/rec/captures/first.cap -o /mnt/rec/captures/first.pcapng
```

`pktrec-cap` prints live statistics every second and a summary at the end; it exits with 0
when no frame was dropped. Copy the pcapng to your PC
(`scp amd-edf@<board-ip>:/mnt/rec/captures/first.pcapng .`), or convert on the PC: the raw
`.cap` file can also be downloaded from the web interface, and `pktrec-export` builds and runs
on a Linux PC. See [Software](software) for all options.

```{note}
The web interface and the command line use the same hardware: only one capture (or replay
from the SSD) runs at a time, whoever started it.
```
