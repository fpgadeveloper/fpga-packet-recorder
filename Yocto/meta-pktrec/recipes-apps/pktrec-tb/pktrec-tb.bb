# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "FPGA Packet Recorder timebase discipline and calibration: pktrec-tb"
DESCRIPTION = "pktrec-tb keeps the capture timebase (64-bit ns counter on \
dp_clk, shared by all ports) on CLOCK_REALTIME (NTP via systemd-timesyncd) \
with a PI controller on the increment and bounded steps (pktrec-tb.service), \
and applies the persistent calibration /etc/pktrec/calibration.conf (timebase \
frequency, MAC_OFFSET, SFD windows and per-port offsets) at boot \
(pktrec-calibration.service). State in /run/pktrec for pktrec-web and pktrec-cap."
HOMEPAGE = "https://github.com/fpgadeveloper/fpga-packet-recorder"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Sources come straight from this repository (PKTREC_REPO_ROOT: layer.conf).
FILESEXTRAPATHS:prepend := "${PKTREC_REPO_ROOT}:"
SRC_URI = "file://sw/pktrec-tools/pktrec-tb \
           file://calibration.conf \
           file://pktrec-calibration.service \
           file://pktrec-tb.service \
           file://pktrec-tb.default \
          "
S = "${WORKDIR}/sw/pktrec-tools"

inherit allarch systemd

SYSTEMD_SERVICE:${PN} = "pktrec-calibration.service pktrec-tb.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_compile[noexec] = "1"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/pktrec-tb ${D}${bindir}/pktrec-tb
    install -d ${D}${sysconfdir}/pktrec ${D}${sysconfdir}/default
    install -m 0644 ${WORKDIR}/calibration.conf ${D}${sysconfdir}/pktrec/calibration.conf
    install -m 0644 ${WORKDIR}/pktrec-tb.default ${D}${sysconfdir}/default/pktrec-tb
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/pktrec-calibration.service ${WORKDIR}/pktrec-tb.service \
        ${D}${systemd_system_unitdir}/
}

# A tuned calibration (pktrec-tb save-calibration) survives package updates
CONFFILES:${PN} = "${sysconfdir}/pktrec/calibration.conf ${sysconfdir}/default/pktrec-tb"

# pktrec-tb imports pktrec-phy (pktrec-tools) for the UIO register access;
# configparser/argparse are in python3-core, ctypes (adjtimex: NTP state) and
# datetime are separate packages.
RDEPENDS:${PN} = "python3-core python3-mmap python3-json python3-ctypes python3-datetime \
                  pktrec-tools"
