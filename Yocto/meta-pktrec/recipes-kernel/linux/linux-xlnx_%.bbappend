# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# Kernel options for the Ethernet FMC Max port subsystem (pktrec.cfg).
FILESEXTRAPATHS:prepend := "${THISDIR}/${PN}:"

SRC_URI:append = " file://pktrec.cfg"
KERNEL_FEATURES:append = " pktrec.cfg"
