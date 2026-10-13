# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""Minimal, strict pcapng reader (Python standard library only).

Used by check_pcap.py (sequence check) and pcapng_lint.py (format validator).
It understands the blocks pktrec-export writes -- SHB, IDB, EPB, SPB, ISB --
and skips (but length-checks) any other block type.

    for blk in read_blocks(path):          # Block objects in file order
        ...
    cap = Capture(path)                     # convenience: interfaces + packets
    for pkt in cap.packets():               # Packet(ifid, ts, caplen, wirelen, data, flags)
        ...

Structural problems raise PcapngError with the byte offset.
"""

import struct
import sys

BT_SHB = 0x0A0D0D0A
BT_IDB = 0x00000001
BT_SPB = 0x00000003
BT_EPB = 0x00000006
BT_ISB = 0x00000005
BT_NAMES = {BT_SHB: "SHB", BT_IDB: "IDB", BT_SPB: "SPB", BT_EPB: "EPB", BT_ISB: "ISB",
            0x00000004: "NRB", 0x0000000A: "DSB", 0x00000BAD: "CB", 0x40000BAD: "CB"}
BOM = 0x1A2B3C4D

# option codes per block type (pcapng spec, draft-ietf-opsawg-pcapng)
OPT_ENDOFOPT, OPT_COMMENT = 0, 1
SHB_OPTS = {2: "shb_hardware", 3: "shb_os", 4: "shb_userappl"}
IDB_OPTS = {2: "if_name", 3: "if_description", 4: "if_IPv4addr", 5: "if_IPv6addr",
            6: "if_MACaddr", 7: "if_EUIaddr", 8: "if_speed", 9: "if_tsresol",
            10: "if_tzone", 11: "if_filter", 12: "if_os", 13: "if_fcslen",
            14: "if_tsoffset", 15: "if_hardware", 16: "if_txspeed", 17: "if_rxspeed"}
EPB_OPTS = {2: "epb_flags", 3: "epb_hash", 4: "epb_dropcount", 5: "epb_packetid",
            6: "epb_queue", 7: "epb_verdict"}
ISB_OPTS = {2: "isb_starttime", 3: "isb_endtime", 4: "isb_ifrecv", 5: "isb_ifdrop",
            6: "isb_filteraccept", 7: "isb_osdrop", 8: "isb_usrdeliv"}
STRING_OPTS = {"shb_hardware", "shb_os", "shb_userappl", "if_name", "if_description",
               "if_os", "if_hardware", "opt_comment"}


class PcapngError(Exception):
    pass


class Block:
    __slots__ = ("offset", "btype", "body", "length", "endian")

    def __init__(self, offset, btype, body, length, endian):
        self.offset, self.btype, self.body, self.length, self.endian = (
            offset, btype, body, length, endian)

    @property
    def name(self):
        return BT_NAMES.get(self.btype, f"0x{self.btype:08x}")


def read_blocks(path_or_file, chunk=1 << 20):
    """Yield Block objects in file order; validates block framing."""
    f = open(path_or_file, "rb") if isinstance(path_or_file, str) else path_or_file
    endian = None
    off = 0
    try:
        while True:
            hdr = f.read(8)
            if not hdr:
                return
            if len(hdr) < 8:
                raise PcapngError(f"offset {off}: truncated block header")
            (btype_le,) = struct.unpack("<I", hdr[:4])
            if btype_le == BT_SHB:
                bom_raw = f.read(4)
                if len(bom_raw) < 4:
                    raise PcapngError(f"offset {off}: truncated SHB")
                if struct.unpack("<I", bom_raw)[0] == BOM:
                    endian = "<"
                elif struct.unpack(">I", bom_raw)[0] == BOM:
                    endian = ">"
                else:
                    raise PcapngError(f"offset {off}: bad byte-order magic")
                (blen,) = struct.unpack(endian + "I", hdr[4:8])
                rest = bom_raw
            else:
                if endian is None:
                    raise PcapngError(f"offset {off}: file does not start with an SHB")
                (blen,) = struct.unpack(endian + "I", hdr[4:8])
                rest = b""
            btype = struct.unpack(endian + "I", hdr[:4])[0]
            if blen < 12 or blen % 4:
                raise PcapngError(f"offset {off}: block length {blen} invalid (must be >= 12, multiple of 4)")
            need = blen - 8 - len(rest)
            data = f.read(need)
            if len(data) < need:
                raise PcapngError(f"offset {off}: truncated {BT_NAMES.get(btype, hex(btype))} "
                                  f"(length {blen}, file ends)")
            data = rest + data
            (trail,) = struct.unpack(endian + "I", data[-4:])
            if trail != blen:
                raise PcapngError(f"offset {off}: trailing block length {trail} != {blen}")
            yield Block(off, btype, data[:-4], blen, endian)
            off += blen
    finally:
        if f is not path_or_file:
            f.close()


def parse_options(body, start, endian, names, where=""):
    """Return a list of (code, name, raw_value). Validates padding and end-of-options."""
    opts = []
    p = start
    n = len(body)
    ended = False
    while p < n:
        if p + 4 > n:
            raise PcapngError(f"{where}: option header runs past the block")
        code, olen = struct.unpack(endian + "HH", body[p:p + 4])
        p += 4
        if code == OPT_ENDOFOPT:
            if olen != 0:
                raise PcapngError(f"{where}: opt_endofopt with length {olen}")
            ended = True
            break
        padded = (olen + 3) & ~3
        if p + padded > n:
            raise PcapngError(f"{where}: option {code} (length {olen}) runs past the block")
        val = body[p:p + olen]
        pad = body[p + olen:p + padded]
        if any(pad):
            raise PcapngError(f"{where}: option {code} padding is not zero")
        p += padded
        name = "opt_comment" if code == OPT_COMMENT else names.get(code, f"opt_{code}")
        opts.append((code, name, val))
    if p != n:
        raise PcapngError(f"{where}: {n - p} bytes after opt_endofopt")
    return opts, ended


class Interface:
    def __init__(self, ifid, linktype, snaplen, opts, endian):
        self.ifid, self.linktype, self.snaplen = ifid, linktype, snaplen
        self.opts = {}
        for _, name, raw in opts:
            self.opts.setdefault(name, []).append(raw)
        self.name = self._s("if_name") or f"if{ifid}"
        self.description = self._s("if_description")
        tsresol = self.opts.get("if_tsresol", [b"\x06"])[0][0]
        if tsresol & 0x80:
            self.ticks_per_s = 2 ** (tsresol & 0x7F)
        else:
            self.ticks_per_s = 10 ** tsresol
        self.tsresol = tsresol
        self.fcslen = self.opts.get("if_fcslen", [None])[0]
        self.stats = {}

    def _s(self, name):
        v = self.opts.get(name)
        return v[0].decode("utf-8", "replace") if v else None

    def ts_ns(self, ticks):
        if self.ticks_per_s == 10 ** 9:
            return ticks
        return ticks * 10 ** 9 // self.ticks_per_s


class Packet:
    __slots__ = ("ifid", "ts", "caplen", "wirelen", "data", "flags", "comments", "index")

    def __init__(self, ifid, ts, caplen, wirelen, data, flags, comments, index):
        self.ifid, self.ts, self.caplen, self.wirelen, self.data = ifid, ts, caplen, wirelen, data
        self.flags, self.comments, self.index = flags, comments, index


class Capture:
    """Iterate packets of a single- or multi-section pcapng file.

    Interfaces and the SHB options are filled in while iterating; after the
    iteration, .interfaces[ifid].stats holds the ISB values (last one wins).
    """

    def __init__(self, path):
        self.path = path
        self.interfaces = []
        self.shb = {}

    def packets(self):
        idx = 0
        for b in read_blocks(self.path):
            e = b.endian
            if b.btype == BT_SHB:
                self.interfaces = []
                opts, _ = parse_options(b.body, 16, e, SHB_OPTS, "SHB")
                self.shb = {name: raw for _, name, raw in opts}
            elif b.btype == BT_IDB:
                linktype, _res, snaplen = struct.unpack(e + "HHI", b.body[:8])
                opts, _ = parse_options(b.body, 8, e, IDB_OPTS, "IDB")
                self.interfaces.append(Interface(len(self.interfaces), linktype, snaplen, opts, e))
            elif b.btype == BT_EPB:
                ifid, tsh, tsl, caplen, wirelen = struct.unpack(e + "IIIII", b.body[:20])
                data = b.body[20:20 + caplen]
                optstart = 20 + ((caplen + 3) & ~3)
                opts, _ = parse_options(b.body, optstart, e, EPB_OPTS, f"EPB@{b.offset}")
                flags = 0
                comments = []
                for code, name, raw in opts:
                    if name == "epb_flags":
                        (flags,) = struct.unpack(e + "I", raw)
                    elif name == "opt_comment":
                        comments.append(raw.decode("utf-8", "replace"))
                if ifid >= len(self.interfaces):
                    raise PcapngError(f"EPB@{b.offset}: interface {ifid} not defined")
                ts = self.interfaces[ifid].ts_ns((tsh << 32) | tsl)
                yield Packet(ifid, ts, caplen, wirelen, data, flags, comments, idx)
                idx += 1
            elif b.btype == BT_ISB:
                ifid, tsh, tsl = struct.unpack(e + "III", b.body[:12])
                opts, _ = parse_options(b.body, 12, e, ISB_OPTS, f"ISB@{b.offset}")
                if ifid < len(self.interfaces):
                    st = self.interfaces[ifid].stats
                    st["isb_timestamp"] = (tsh << 32) | tsl
                    for _, name, raw in opts:
                        if len(raw) != 8:
                            continue
                        if name in ("isb_starttime", "isb_endtime"):
                            # same layout as the EPB timestamp: high word, low word
                            hi, lo = struct.unpack(e + "II", raw)
                            st[name] = (hi << 32) | lo
                        else:
                            st[name] = struct.unpack(e + "Q", raw)[0]


if __name__ == "__main__":
    for blk in read_blocks(sys.argv[1]):
        print(f"{blk.offset:10d} {blk.name:4s} len {blk.length}")
