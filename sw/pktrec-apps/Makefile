# SPDX-License-Identifier: MIT
# Copyright (C) 2026, Opsero Electronic Design Inc.  All rights reserved.
#
# FPGA Packet Recorder apps: pktrec-cap (capture control + recording),
# pktrec-export (capture file -> pcapng), pktrec-replay (capture -> port, M6).
#
#   make                         build with the system compiler (+ liburing)
#   make pktrec-export           only the exporter (no liburing needed: it
#                                also builds on a PC to convert captures there)
#   make CC=aarch64-linux-gnu-gcc LIBURING_CFLAGS=... LIBURING_LIBS=...
#   make install DESTDIR=<root> [PREFIX=/usr]
#
# Shares fdrec_common.h with the recorder apps (../fdrec-apps) and the
# register / format headers in ../../include.

CC ?= gcc
PKG_CONFIG ?= pkg-config
PREFIX ?= /usr
BINDIR ?= $(PREFIX)/bin
PKTREC_INCLUDE ?= ../../include
FDREC_APPS ?= ../fdrec-apps
PKTREC_TARGET ?= unknown

CFLAGS ?= -O2 -g
# Kept apart from CFLAGS so a CFLAGS from the command line or Yocto keeps them
PKTREC_CFLAGS = -Wall -Wextra -std=gnu11 -I. -I$(PKTREC_INCLUDE) -I$(FDREC_APPS) \
		-DPKTREC_TARGET='"$(PKTREC_TARGET)"'
LIBURING_CFLAGS ?= $(shell $(PKG_CONFIG) --cflags liburing 2>/dev/null)
LIBURING_LIBS ?= $(shell $(PKG_CONFIG) --libs liburing 2>/dev/null || echo -luring)

PROGS = pktrec-cap pktrec-export pktrec-replay
HEADERS = pktrec_common.h $(FDREC_APPS)/fdrec_common.h \
	  $(PKTREC_INCLUDE)/fdrec_uapi.h $(PKTREC_INCLUDE)/pktrec_regs.h $(PKTREC_INCLUDE)/pktrec_format.h

all: $(PROGS)

pktrec-cap: pktrec-cap.c $(HEADERS)
	$(CC) $(CPPFLAGS) $(PKTREC_CFLAGS) $(CFLAGS) $(LIBURING_CFLAGS) -o $@ $< $(LDFLAGS) $(LIBURING_LIBS)

pktrec-replay: pktrec-replay.c $(HEADERS)
	$(CC) $(CPPFLAGS) $(PKTREC_CFLAGS) $(CFLAGS) $(LIBURING_CFLAGS) -o $@ $< $(LDFLAGS) $(LIBURING_LIBS) -lm

pktrec-export: pktrec-export.c $(HEADERS)
	$(CC) $(CPPFLAGS) $(PKTREC_CFLAGS) $(CFLAGS) -o $@ $< $(LDFLAGS)

install: all
	install -d $(DESTDIR)$(BINDIR)
	install -m 0755 $(PROGS) $(DESTDIR)$(BINDIR)/

clean:
	rm -f $(PROGS)

.PHONY: all install clean
