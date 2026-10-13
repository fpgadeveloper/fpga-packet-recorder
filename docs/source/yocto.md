# Yocto

The Linux image is built with the AMD Yocto / Embedded Development Framework (EDF) 2025.2
using the `gen-machineconf parse-sdt` flow: the device tree is generated from the Vivado XSA,
and the board-level fixups live in `Yocto/bsp/zcu106`. See `Yocto/README.md` in the
repository for the details of the flow.

## Writing the SD card

The `bootimages/fpga-packet-recorder_zcu106_yocto-2025-2.zip` file contains `BOOT.BIN` and
`rootfs.wic.xz`. Write the wic image to the SD card (for example with `bmaptool copy` or
`xzcat rootfs.wic.xz | sudo dd of=/dev/sdX bs=4M conv=fsync`), then boot the ZCU106 from the
SD card (boot-mode switch SW6 set to SD boot). Log in as `amd-edf`; the password is chosen on first login.
