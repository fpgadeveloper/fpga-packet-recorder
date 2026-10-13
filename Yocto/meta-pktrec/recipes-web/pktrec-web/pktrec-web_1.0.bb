# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "FPGA Packet Recorder web interface: pktrec-web"
DESCRIPTION = "A small HTTP server (Python 3 standard library only) with a \
single-page UI and a JSON API, served on the PS Ethernet port: port link \
status, per-pair TAP/monitor mode, capture start/stop with size and duration \
limits, live statistics, and the list of captures with pcapng download \
(converted on the fly by pktrec-export) and delete. It drives pktrec-phy and \
pktrec-cap as subprocesses. pktrec-banner.service prints the UI address on \
the UART console once the port has an address."
HOMEPAGE = "https://github.com/fpgadeveloper/fpga-packet-recorder"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

# Sources come straight from this repository (PKTREC_REPO_ROOT: layer.conf).
# mock_tools.py and test_api.py in sw/pktrec-web are host-side test tools and
# are not installed.
FILESEXTRAPATHS:prepend := "${PKTREC_REPO_ROOT}:"
SRC_URI = "file://sw/pktrec-web \
           file://pktrec-web.service \
           file://pktrec-banner.service \
           file://pktrec-web.default \
           file://pktrec-web.issue \
          "
S = "${WORKDIR}/sw/pktrec-web"

inherit allarch systemd

SYSTEMD_SERVICE:${PN} = "pktrec-web.service pktrec-banner.service"
SYSTEMD_AUTO_ENABLE:${PN} = "enable"

do_compile[noexec] = "1"

do_install() {
    install -d ${D}${bindir}
    install -m 0755 ${S}/pktrec-web ${D}${bindir}/pktrec-web
    install -d ${D}${datadir}/pktrec-web/static
    install -m 0644 ${S}/static/index.html ${S}/static/app.js ${S}/static/style.css \
        ${D}${datadir}/pktrec-web/static/
    install -d ${D}${systemd_system_unitdir}
    install -m 0644 ${WORKDIR}/pktrec-web.service ${WORKDIR}/pktrec-banner.service \
        ${D}${systemd_system_unitdir}/
    install -d ${D}${sysconfdir}/default ${D}${sysconfdir}/issue.d
    install -m 0644 ${WORKDIR}/pktrec-web.default ${D}${sysconfdir}/default/pktrec-web
    # agetty prints /etc/issue.d/*.issue after /etc/issue; \4{end0} is the
    # port's current IPv4 address (re-printed when it changes)
    install -m 0644 ${WORKDIR}/pktrec-web.issue ${D}${sysconfdir}/issue.d/pktrec-web.issue
}

FILES:${PN} += "${datadir}/pktrec-web ${sysconfdir}/issue.d"
CONFFILES:${PN} = "${sysconfdir}/default/pktrec-web"

# Python packages per poky's python3-manifest.json: http.server (netclient),
# socketserver (netserver), socket (io), json, datetime, fcntl; threading,
# subprocess, shutil, struct (core). Plus the tools it drives.
RDEPENDS:${PN} = "python3-core python3-io python3-json python3-netclient python3-netserver \
                  python3-datetime python3-fcntl pktrec-tools pktrec-apps"
