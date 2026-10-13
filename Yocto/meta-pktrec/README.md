# meta-pktrec

Yocto layer for the FPGA Packet Recorder's Ethernet port subsystem (Ethernet FMC Max,
OP080). It sits next to `meta-fdrec` (the recorder datapath) and is enabled for a board
by listing `Yocto/meta-pktrec` in `bsp/<board>/bblayers-extra.txt`.

Contents:

* `conf/layer.conf` -- the layer definition (scarthgap); sets `PKTREC_REPO_ROOT`, the
  repository root, from which the recipes take their sources.
* `recipes-apps/pktrec-tools/` -- `pktrec-phy` (Python 3, sources `sw/pktrec-tools/`):
  DP83867 configuration over the fabric MDIO master, link status, M0 path selection
  and counters.
* `recipes-kernel/linux/` -- `pktrec.cfg`: `CONFIG_UIO_PDRV_GENIRQ=y`, so the
  `generic-uio` nodes of the eth_ports register blocks bind at boot.
* `recipes-core/images/` -- adds `pktrec-tools` to the image.

The `generic-uio` binding itself is board-specific (it names the block-design cells) and
lives in `bsp/<board>/meta-user/recipes-bsp/device-tree/files/system-user.dtsi`.
