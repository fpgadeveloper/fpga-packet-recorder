# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# FPGA Packet Recorder: chronyd replaces systemd-timesyncd as the NTP client.
#
# pktrec-tb disciplines the capture timebase to CLOCK_REALTIME, so absolute
# capture time is only as good as the kernel clock. On the bench (2026-10-13)
# systemd-timesyncd (SNTP, poll interval growing to 34 min) had trained the
# kernel frequency to -0.63 ppm after 34 min while the PS crystal needed
# +11.7 ppm: CLOCK_REALTIME drifted ~12 ppm between polls (-25 ms vs the host
# after 35 min). chronyd estimates the frequency from all its samples, converges
# within minutes and keeps it in /var/lib/chrony/drift across reboots.
# chrony is in meta-openembedded/meta-networking, already in the EDF layer set.
FILESEXTRAPATHS:prepend := "${THISDIR}/files:"

do_install:append() {
    # mask systemd-timesyncd: one NTP client only (chronyd.service also
    # Conflicts= with it, but the mask makes the boot order irrelevant)
    install -d ${D}${sysconfdir}/systemd/system
    ln -sf /dev/null ${D}${sysconfdir}/systemd/system/systemd-timesyncd.service
}
