# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# SPDX-License-Identifier: MIT

# FPGA Packet Recorder additions to the EDF disk image.
IMAGE_INSTALL:append = " pktrec-tools pktrec-apps pktrec-test pktrec-web pktrec-tb"

# NTP client: chronyd instead of systemd-timesyncd (meta-pktrec chrony bbappend:
# config + timesyncd masked). The capture timebase follows CLOCK_REALTIME, and
# chronyd trains the kernel frequency in minutes (timesyncd: >30 min, bench).
IMAGE_INSTALL:append = " chrony chronyc"

# SFTP subsystem for sshd, so that plain `scp` (SFTP protocol, the OpenSSH 9
# default) and sftp clients can copy files to and from the board.
IMAGE_INSTALL:append = " openssh-sftp-server"
