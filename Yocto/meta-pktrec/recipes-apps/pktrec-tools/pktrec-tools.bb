# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "FPGA Packet Recorder Ethernet port tools: pktrec-phy"
DESCRIPTION = "pktrec-phy configures the four DP83867 PHYs of the Ethernet FMC \
Max (OP080) through the fabric MDIO master (mirror mode, SGMII, 1588 SFD on \
GPIO_0/1), shows PHY and SGMII link status, selects the M0 datapath \
(idle/loopback/forward) and reads its counters. It maps the eth_ports register \
blocks through generic-uio (or /dev/mem)."
HOMEPAGE = "https://github.com/fpgadeveloper/fpga-packet-recorder"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Sources come straight from this repository (PKTREC_REPO_ROOT: layer.conf).
FILESEXTRAPATHS:prepend := "${PKTREC_REPO_ROOT}:"
SRC_URI = "file://sw/pktrec-tools"
S = "${WORKDIR}/sw/pktrec-tools"

inherit allarch

do_compile[noexec] = "1"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/pktrec-phy ${D}${bindir}/pktrec-phy
}

RDEPENDS:${PN} = "python3-core python3-mmap"
