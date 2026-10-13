#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""pcapng_lint.py - strict structural validator for pcapng files (stdlib only).

A stand-in for "Wireshark opens it without warnings" on machines without
tshark/capinfos. It checks what Wireshark's pcapng reader checks, and a few
things it does not (padding bytes, timestamp order):

  * block framing: lengths >= 12 and a multiple of 4, trailing length matches
  * SHB first, byte-order magic, version 1.0, section length (-1 or exact)
  * options: known lengths, zero padding, opt_endofopt last, valid UTF-8 strings
  * IDB: link type, if_tsresol / if_fcslen are 1 byte, unique if_name
  * EPB: interface defined, caplen <= len, caplen <= snaplen, epb_flags reserved
    bits clear, Ethernet frames >= 14 bytes
  * ISB: interface defined, counters 8 bytes, start <= end
  * timestamps: non-decreasing over the whole file (--no-order to skip) and
    per interface

Usage: pcapng_lint.py [--no-order] [--quiet] file.pcapng
Exit: 0 = valid (warnings allowed), 1 = errors found.
"""

import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pcapng_reader import (BT_EPB, BT_IDB, BT_ISB, BT_SHB, BT_SPB, EPB_OPTS, IDB_OPTS,  # noqa: E402
                           ISB_OPTS, SHB_OPTS, STRING_OPTS, PcapngError, parse_options,
                           read_blocks)

FIXED_LEN = {"if_tsresol": 1, "if_fcslen": 1, "if_speed": 8, "if_tsoffset": 8,
             "epb_flags": 4, "epb_dropcount": 8, "epb_packetid": 8, "epb_queue": 4,
             "isb_starttime": 8, "isb_endtime": 8, "isb_ifrecv": 8, "isb_ifdrop": 8,
             "isb_filteraccept": 8, "isb_osdrop": 8, "isb_usrdeliv": 8}
LINKTYPE_ETHERNET = 1


class Lint:
    def __init__(self, quiet=False):
        self.errors = []
        self.warnings = []
        self.quiet = quiet

    def err(self, msg):
        self.errors.append(msg)

    def warn(self, msg):
        self.warnings.append(msg)


def check_opts(lint, opts, ended, where):
    if opts and not ended:
        lint.warn(f"{where}: options without opt_endofopt")
    for code, name, raw in opts:
        want = FIXED_LEN.get(name)
        if want is not None and len(raw) != want:
            lint.err(f"{where}: {name} has length {len(raw)}, expected {want}")
        if name in STRING_OPTS:
            try:
                s = raw.decode("utf-8")
            except UnicodeDecodeError:
                lint.err(f"{where}: {name} is not valid UTF-8")
                continue
            if "\x00" in s:
                lint.warn(f"{where}: {name} contains NUL characters")


def lint_file(path, order=True, quiet=False):
    lint = Lint(quiet)
    ifaces = []
    names = set()
    last_ts = None
    last_if_ts = {}
    counts = {"SHB": 0, "IDB": 0, "EPB": 0, "ISB": 0, "SPB": 0, "other": 0}
    order_violations = 0
    first = True
    sect_start = 0
    sect_len = -1
    prev_shb_len = 0
    try:
        for b in read_blocks(path):
            e = b.endian
            where = f"{b.name}@{b.offset}"
            if first and b.btype != BT_SHB:
                lint.err("first block is not an SHB")
            first = False
            if b.btype == BT_SHB:
                if counts["SHB"] and sect_len != -1 and sect_len != b.offset - sect_start - prev_shb_len:
                    lint.err(f"{where}: previous section length {sect_len} does not match")
                counts["SHB"] += 1
                bom, major, minor, slen = struct.unpack(e + "IHHq", b.body[:16])
                if (major, minor) != (1, 0):
                    lint.err(f"{where}: version {major}.{minor}, expected 1.0")
                sect_start, sect_len, prev_shb_len = b.offset, slen, b.length
                opts, ended = parse_options(b.body, 16, e, SHB_OPTS, where)
                check_opts(lint, opts, ended, where)
                ifaces = []
                names = set()
                last_if_ts = {}
            elif b.btype == BT_IDB:
                counts["IDB"] += 1
                linktype, reserved, snaplen = struct.unpack(e + "HHI", b.body[:8])
                if reserved:
                    lint.warn(f"{where}: reserved field = {reserved}")
                if linktype != LINKTYPE_ETHERNET:
                    lint.warn(f"{where}: link type {linktype} (not Ethernet)")
                opts, ended = parse_options(b.body, 8, e, IDB_OPTS, where)
                check_opts(lint, opts, ended, where)
                d = {n: r for _, n, r in opts}
                res = d.get("if_tsresol", b"\x06")[0] if d.get("if_tsresol") else 6
                tps = 2 ** (res & 0x7F) if res & 0x80 else 10 ** res
                nm = d.get("if_name", b"").decode("utf-8", "replace")
                if nm:
                    if nm in names:
                        lint.warn(f"{where}: duplicate if_name '{nm}'")
                    names.add(nm)
                ifaces.append({"snaplen": snaplen, "tps": tps, "name": nm or f"if{len(ifaces)}",
                               "linktype": linktype})
            elif b.btype in (BT_EPB, BT_SPB):
                counts["EPB" if b.btype == BT_EPB else "SPB"] += 1
                if b.btype == BT_SPB:
                    continue
                ifid, tsh, tsl, caplen, wirelen = struct.unpack(e + "IIIII", b.body[:20])
                if ifid >= len(ifaces):
                    lint.err(f"{where}: interface {ifid} not defined")
                    continue
                itf = ifaces[ifid]
                if 20 + ((caplen + 3) & ~3) > len(b.body):
                    lint.err(f"{where}: caplen {caplen} runs past the block")
                    continue
                if caplen > wirelen:
                    lint.err(f"{where}: caplen {caplen} > len {wirelen}")
                if itf["snaplen"] and caplen > itf["snaplen"]:
                    lint.err(f"{where}: caplen {caplen} > snaplen {itf['snaplen']}")
                if itf["linktype"] == LINKTYPE_ETHERNET and caplen < 14:
                    lint.warn(f"{where}: Ethernet frame of {caplen} bytes (< 14)")
                pad = b.body[20 + caplen:20 + ((caplen + 3) & ~3)]
                if any(pad):
                    lint.warn(f"{where}: packet data padding is not zero")
                opts, ended = parse_options(b.body, 20 + ((caplen + 3) & ~3), e, EPB_OPTS, where)
                check_opts(lint, opts, ended, where)
                for _, n, r in opts:
                    if n == "epb_flags" and len(r) == 4:
                        (fl,) = struct.unpack(e + "I", r)
                        if fl & 0x0000FE00:
                            lint.err(f"{where}: epb_flags reserved bits 9-15 set (0x{fl:08x})")
                        if fl & 3 == 3:
                            lint.err(f"{where}: epb_flags direction 3 is invalid")
                ts = ((tsh << 32) | tsl) * 10 ** 9 // itf["tps"] if itf["tps"] != 10 ** 9 \
                    else (tsh << 32) | tsl
                if order and last_ts is not None and ts < last_ts:
                    order_violations += 1
                    if order_violations <= 10:
                        lint.err(f"{where}: timestamp {ts} ns earlier than the previous packet "
                                 f"({last_ts} ns)")
                if ifid in last_if_ts and ts < last_if_ts[ifid]:
                    lint.warn(f"{where}: timestamp goes backwards on interface {itf['name']}")
                last_ts = ts if last_ts is None else max(last_ts, ts)
                last_if_ts[ifid] = ts
            elif b.btype == BT_ISB:
                counts["ISB"] += 1
                ifid = struct.unpack(e + "I", b.body[:4])[0]
                if ifid >= len(ifaces):
                    lint.err(f"{where}: interface {ifid} not defined")
                opts, ended = parse_options(b.body, 12, e, ISB_OPTS, where)
                check_opts(lint, opts, ended, where)
                d = {}
                for _, n, r in opts:
                    if n in ("isb_starttime", "isb_endtime") and len(r) == 8:
                        hi, lo = struct.unpack(e + "II", r)
                        d[n] = (hi << 32) | lo
                if "isb_starttime" in d and "isb_endtime" in d and d["isb_starttime"] > d["isb_endtime"]:
                    lint.err(f"{where}: isb_starttime > isb_endtime")
            else:
                counts["other"] += 1
    except PcapngError as ex:
        lint.err(str(ex))
    if order_violations > 10:
        lint.err(f"... {order_violations} timestamp order violations in total")
    if counts["SHB"] == 0:
        lint.err("no SHB")
    return lint, counts, ifaces


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("file")
    ap.add_argument("--no-order", action="store_true", help="do not require timestamp order")
    ap.add_argument("-q", "--quiet", action="store_true")
    a = ap.parse_args()
    lint, counts, ifaces = lint_file(a.file, order=not a.no_order)
    for w in lint.warnings[:50]:
        print(f"WARNING: {w}")
    if len(lint.warnings) > 50:
        print(f"WARNING: ... {len(lint.warnings)} warnings in total")
    for m in lint.errors:
        print(f"ERROR: {m}")
    if not a.quiet or lint.errors:
        print(f"{a.file}: " + ", ".join(f"{k} {v}" for k, v in counts.items() if v) +
              f"; interfaces: {', '.join(i['name'] for i in ifaces)}")
    print(f"{'PASS' if not lint.errors else 'FAIL'}: {len(lint.errors)} errors, "
          f"{len(lint.warnings)} warnings")
    sys.exit(1 if lint.errors else 0)


if __name__ == "__main__":
    main()
