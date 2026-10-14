# Yocto

The Linux image of this design is built with the AMD Yocto / Embedded Development Framework
(EDF) 2025.2 flow, the announced successor to PetaLinux. There is no PetaLinux flow. The build
is driven by the `build.py` runner at the root of the repository.

## Requirements

To build the Yocto image you need a physical or virtual machine running one of the
[supported Linux distributions], with Vivado and Vitis 2025.2 installed: the flow uses
`xsct`/`sdtgen` (which ship with Vitis) to generate a System Device Tree from the Vivado XSA.
You also need [Google's repo tool](https://gerrit.googlesource.com/git-repo/) on your `PATH`.
The host packages are listed in `Yocto/README.md` in the repository.

Plan for the disk space and time of a full Yocto build: the first build downloads several GB
of sources and runs bitbake from scratch, and the workspace occupies 40 to 60 GB.

```{attention}
You cannot build the Yocto image in the Windows operating system. Windows users are advised
to use a Linux virtual machine. On Windows the build runner can still build the Vivado
project and XSA, and prints the command to run on the Linux machine.
```

## How to build

```
git clone --recursive https://github.com/fpgadeveloper/fpga-packet-recorder.git
cd fpga-packet-recorder
./build.sh yocto --target zcu106
```

This builds the Vivado project and XSA first if they do not exist yet. The output products
are gathered into `Yocto/zcu106/images/linux/`:

| File | Description |
| --- | --- |
| `rootfs.wic.xz` + `rootfs.wic.bmap` | Full SD-card disk image: this is what you flash |
| `BOOT.BIN` | Boot image (FSBL, PMU firmware, bitstream, ATF, U-Boot) |
| `boot.scr` | U-Boot boot script |
| `Image` | Linux kernel |
| `system.dtb` | Linux device tree |
| `rootfs.tar.gz` | Root filesystem tarball |

`./build.sh all --target zcu106` (or `./build.sh package --target zcu106` after the Yocto
stage) also packs `rootfs.wic.xz`, `rootfs.wic.bmap` and `BOOT.BIN` into
`bootimages/fpga-packet-recorder_zcu106_yocto-2025-2.zip`.

```{note}
The Yocto stage is skipped when the gathered images are newer than their sources. If a
change in `sw/` does not show up in the image, delete `Yocto/zcu106/images/linux/` and
build again (incrementally: the workspace is kept).
```

## How the image is put together

The flow generates a custom Yocto MACHINE (`pktrec-zcu106`) directly from the Vivado XSA
(`sdtgen` → System Device Tree → `gen-machineconf parse-sdt`), so the PL hardware in the
device tree (the PCIe root port, the AXI DMA, the recorder and the capture register blocks)
comes from the design itself. The bitstream is embedded in `BOOT.BIN` and programmed by the
FSBL at boot. On top of the EDF defaults, three layers are added:

* **`Yocto/bsp/zcu106`**: board fixups in `system-user.dtsi` (UART numbering; the TI DP83867
  PHY of the board's RJ45 port with its RGMII delays and a fixed MAC address; the `fdrec`
  driver node), the kernel command line and the hostname `zcu106-pktrec-2025-2`.
* **`Yocto/meta-fdrec`**: the recorder layer of the FPGA Drive Recorder: the `fdrec.ko`
  kernel module, `fdrec` / `fdplay` / `fdverify` / `fdsetup-raid0.sh`, the kernel options
  (AXI DMA, hugepages, io_uring, XFS) and tools (`nvme-cli`, `fio`, `xfsprogs`, `ethtool`,
  `iperf3`, an SSH server and others).
* **`Yocto/meta-pktrec`**: this design's layer:

  | Recipe | What it adds |
  |--------|--------------|
  | `pktrec-apps` | `pktrec-cap`, `pktrec-export`, `pktrec-replay` (from `sw/pktrec-apps`) |
  | `pktrec-tools` | `pktrec-phy`, `pktrec-phy-watch.service` (PHY init at boot + link watcher), `mnt-rec.mount` (the SSD at `/mnt/rec`) |
  | `pktrec-tb` | `pktrec-tb`, `pktrec-tb.service` (timebase discipline), `pktrec-calibration.service` and `/etc/pktrec/calibration.conf` |
  | `pktrec-web` | `pktrec-web`, `pktrec-web.service`, `pktrec-banner.service` (the URL on the console) |
  | `pktrec-test` | `pktrec-pktgen`, `pktrec-check-pcap`, `pktrec-pcapng-lint` |
  | `linux-xlnx` bbappend | generic UIO driver for the capture register blocks |

The register blocks of the Ethernet ports, the capture block and the replay block are bound
to `generic-uio`; the tools map them from user space.

### Kernel command line

The board-specific arguments come from `BSP_EXTRA_BOOTARGS` in
`Yocto/bsp/zcu106/conf/local.conf.append`:

```
cma=1536M hugepagesz=2M hugepages=256
```

The 2 MB hugepages (`FDREC_HUGEPAGES`, default 256 = 512 MB) hold the recording and playback
ring buffers.

```{note}
The board's RJ45 port uses the board's own **MAC address from the ZCU106 EEPROM**; no MAC
address is built into the image, so the same image works on any number of boards. U-Boot
reads the EEPROM (described for it in
`Yocto/bsp/zcu106/meta-user/recipes-bsp/device-tree/files/system-user.dtsi`), prints the
address on the UART at power-up (`Ethernet mac:` in the `Xilinx I2C Legacy format` block) and
passes it to Linux. To keep the board at the same IP address, reserve that MAC address in
your DHCP server.
```

## Boot from SD card

The image is a **full SD-card disk image** (`rootfs.wic.xz`) with four partitions: `esp`
(FAT), `boot` (ext4), `root` (ext4) and `storage` (FAT). The EDF image leaves `esp` empty,
but the ZynqMP BootROM loads `BOOT.BIN` from the first FAT partition, so `BOOT.BIN` must be
copied there after flashing.

```{warning}
Flashing writes directly to a raw block device and cannot be undone. Be absolutely certain
you have identified the SD card's device node before running the commands below.
```

1. Identify the SD card device: run `lsblk -o NAME,SIZE,RM,TYPE,MOUNTPOINT` with the card
   unplugged and again with it plugged in; the new entry (`/dev/sdX`, `RM=1`) is the card.
2. Unmount anything the desktop auto-mounted:
   ```
   for p in /dev/sdX?*; do sudo umount "$p" 2>/dev/null; done
   ```
3. Flash the image:
   ```
   sudo bmaptool copy --bmap rootfs.wic.bmap rootfs.wic.xz /dev/sdX
   ```
   or, slower: `xzcat rootfs.wic.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync`
4. Copy `BOOT.BIN` onto the `esp` partition:
   ```
   sudo partprobe /dev/sdX
   sudo mkdir -p /mnt/sd_esp && sudo mount /dev/sdX1 /mnt/sd_esp
   sudo cp BOOT.BIN /mnt/sd_esp/ && sync
   sudo umount /mnt/sd_esp && sudo rmdir /mnt/sd_esp
   ```
5. Eject the card: `sudo eject /dev/sdX`.

The files are in `Yocto/zcu106/images/linux/` after a build, or in the zip in `bootimages/`.
Then continue with [Getting started](getting_started).

[supported Linux distributions]: https://docs.amd.com/r/en-US/ug1144-petalinux-tools-reference-guide/Setting-Up-Your-Environment
