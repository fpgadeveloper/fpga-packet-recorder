# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "FPGA Packet Recorder Ethernet port tools: pktrec-phy"
DESCRIPTION = "pktrec-phy configures the four DP83867 PHYs of the Ethernet FMC \
Max (OP080) through the fabric MDIO master (mirror mode, SGMII, 1588 SFD on \
GPIO_0/1), shows PHY and SGMII link status, selects the port datapath \
(idle/loopback/forward/generator) and reads its counters, drives the per-port \
hardware traffic generator and checker, and reports the PHY SFD timestamping \
(capture block). It maps the register blocks through generic-uio (or /dev/mem). \
Also installs mnt-rec.mount (capture SSD at /mnt/rec)."
HOMEPAGE = "https://github.com/fpgadeveloper/fpga-packet-recorder"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Sources come straight from this repository (PKTREC_REPO_ROOT: layer.conf).
FILESEXTRAPATHS:prepend := "${PKTREC_REPO_ROOT}:"
SRC_URI = "file://sw/pktrec-tools \
           file://pktrec-phy-watch.service \
           file://mnt-rec.mount"
S = "${WORKDIR}/sw/pktrec-tools"

inherit allarch systemd

# PHY init (--1000-only) + SGMII link watcher at boot
# Capture SSD at /mnt/rec (nofail, never blocks the boot)
SYSTEMD_SERVICE:${PN} = "pktrec-phy-watch.service mnt-rec.mount"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_compile[noexec] = "1"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/pktrec-phy ${D}${bindir}/pktrec-phy
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/pktrec-phy-watch.service ${D}${systemd_system_unitdir}/
    install -m 0644 ${WORKDIR}/mnt-rec.mount ${D}${systemd_system_unitdir}/
    install -d ${D}/mnt/rec
}

FILES:${PN} += "/mnt/rec"

RDEPENDS:${PN} = "python3-core python3-mmap python3-json"
