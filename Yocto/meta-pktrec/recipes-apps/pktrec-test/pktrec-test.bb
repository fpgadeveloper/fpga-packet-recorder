# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "FPGA Packet Recorder test tools (board side)"
DESCRIPTION = "pktrec-pktgen drives the kernel packet generator (pktgen) to \
send sequence-numbered UDP frames (64 to 1518 bytes, given rate and count) \
from a board interface; pktrec-check-pcap verifies a pcapng capture of such \
traffic (every sequence number once and in order, counts, timestamps, drop \
statistics) and pktrec-pcapng-lint validates a pcapng file's structure. \
The same scripts run on the test PC from the repository's test/ directory."
HOMEPAGE = "https://github.com/fpgadeveloper/fpga-packet-recorder"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

FILESEXTRAPATHS:prepend := "${PKTREC_REPO_ROOT}:"
SRC_URI = "file://test/board_pktgen.sh \
           file://test/check_pcap.py \
           file://test/pcapng_lint.py \
           file://test/pcapng_reader.py \
          "
S = "${WORKDIR}/test"

inherit allarch

do_compile[noexec] = "1"

PKTREC_TESTDIR = "${datadir}/pktrec/test"

do_install() {
    install -d ${D}${bindir} ${D}${PKTREC_TESTDIR}
    install -m 0755 ${S}/board_pktgen.sh ${D}${bindir}/pktrec-pktgen
    install -m 0755 ${S}/check_pcap.py ${S}/pcapng_lint.py ${D}${PKTREC_TESTDIR}/
    install -m 0644 ${S}/pcapng_reader.py ${D}${PKTREC_TESTDIR}/
    # the checkers import pcapng_reader from their own directory: link, not copy
    ln -sf ../share/pktrec/test/check_pcap.py ${D}${bindir}/pktrec-check-pcap
    ln -sf ../share/pktrec/test/pcapng_lint.py ${D}${bindir}/pktrec-pcapng-lint
}

FILES:${PN} += "${PKTREC_TESTDIR}"

# pktgen itself is built into the reference kernel (CONFIG_NET_PKTGEN=y)
RDEPENDS:${PN} = "python3-core python3-json python3-math"
