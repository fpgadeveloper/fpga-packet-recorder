# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

SUMMARY = "FPGA Packet Recorder apps: pktrec-cap, pktrec-export"
DESCRIPTION = "pktrec-cap configures the capture block (ports, snaplen, \
timebase) and records the hardware record stream to a file on NVMe through \
the fdrec driver (zero-copy, io_uring + O_DIRECT), with live per-port \
statistics and the capture metadata in a 4 KB file header; it also reads the \
capture counters (stats) and prints file headers (info). pktrec-export \
converts a capture file to pcapng, streaming (file or stdout), in timestamp \
order with one interface per port and per-port drop statistics."
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

do_compile() {
    oe_runmake
}

do_install() {
    oe_runmake install DESTDIR=${D} PREFIX=${prefix} BINDIR=${bindir}
}

# The machine name is compiled in, so the package is machine specific.
PACKAGE_ARCH = "${MACHINE_ARCH}"

RDEPENDS:${PN} = "liburing"
