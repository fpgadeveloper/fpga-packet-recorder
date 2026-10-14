# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "FPGA Packet Recorder apps: pktrec-cap, pktrec-export, pktrec-replay"
DESCRIPTION = "pktrec-cap configures the capture block (ports, snaplen, \
timebase) and records the hardware record stream to a file on NVMe through \
the fdrec driver (zero-copy, io_uring + O_DIRECT), with live per-port \
statistics and the capture metadata in a 4 KB file header; it also reads the \
capture counters (stats) and prints file headers (info). pktrec-export \
converts a capture file to pcapng, streaming (file or stdout), in timestamp \
order with one interface per port and per-port drop statistics. \
pktrec-replay plays the frames of one capture interface back out of a port \
(original timing, scaled, fixed gap or back to back), scheduled by the \
replay block in the FPGA; the Makefile installs all three to ${bindir}. \
Also installs /etc/pktrec-release (the design version for capture headers)."
HOMEPAGE = "https://github.com/fpgadeveloper/fpga-packet-recorder"
LICENSE = "MIT"
LIC_FILES_CHKSUM = "file://${COMMON_LICENSE_DIR}/MIT;md5=0835ade698e0bcf8506ecda2f7b4f302"

DEPENDS = "liburing"

# Sources come straight from this repository (PKTREC_REPO_ROOT: layer.conf):
# sw/pktrec-apps, fdrec_common.h from sw/fdrec-apps and the shared headers in
# include/. They unpack under ${WORKDIR} with their repo-relative paths, so
# the Makefile's defaults (../../include, ../fdrec-apps) resolve.
FILESEXTRAPATHS:prepend := "${PKTREC_REPO_ROOT}:"
SRC_URI = "file://sw/pktrec-apps \
           file://sw/fdrec-apps/fdrec_common.h \
           file://include \
          "
S = "${WORKDIR}/sw/pktrec-apps"

inherit pkgconfig

# Default target name written into capture headers: MACHINE is "pktrec-<target>"
PKTREC_TARGET ?= "${@d.getVar('MACHINE').replace('pktrec-', '', 1)}"

EXTRA_OEMAKE = "PKTREC_TARGET='${PKTREC_TARGET}'"

# /etc/pktrec-release: "fpga-packet-recorder <git describe of this repository>".
# pktrec-cap writes it (or only the version, if the line is too long) into the
# capture header's "design" field unless --design is given. Evaluated at every
# parse (BB_DONT_CACHE), so a new commit changes the file and rebuilds this
# small package.
def pktrec_describe(d):
    import subprocess
    try:
        out = subprocess.check_output(
            ["git", "-C", d.getVar("PKTREC_REPO_ROOT"), "describe", "--tags", "--always", "--dirty"],
            stderr=subprocess.DEVNULL, universal_newlines=True).strip()
        return out or "unknown"
    except Exception:
        return "unknown"

PKTREC_RELEASE = "fpga-packet-recorder ${@pktrec_describe(d)}"
BB_DONT_CACHE = "1"

do_compile() {
    # -B: never reuse binaries left in the source tree by a host build
    # (test/selftest_export.py builds pktrec-export for the PC in place)
    oe_runmake -B
}

do_install() {
    oe_runmake install DESTDIR=${D} PREFIX=${prefix} BINDIR=${bindir}
    install -d ${D}${sysconfdir}
    echo "${PKTREC_RELEASE}" > ${D}${sysconfdir}/pktrec-release
    chmod 0644 ${D}${sysconfdir}/pktrec-release
}
do_install[vardeps] += "PKTREC_RELEASE"

# The machine name is compiled in, so the package is machine specific.
PACKAGE_ARCH = "${MACHINE_ARCH}"

RDEPENDS:${PN} = "liburing"
