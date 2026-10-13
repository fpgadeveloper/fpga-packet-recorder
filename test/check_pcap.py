#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""check_pcap.py - verify a capture of sequence-numbered test traffic (stdlib only).

Reads a pcapng (as written by pktrec-export) and, per interface and per test
stream, checks that every sequence number is present exactly once and in
order, that the count matches what was sent, and that timestamps never go
backwards. Reports loss, duplicates, reordering, inter-frame interval stats,
FCS-error / truncated frames and the per-interface drop counters from the
Interface Statistics Blocks.

Recognised test payloads (UDP over IPv4, optional 802.1Q/802.1ad tags):
  * gen_seq.py:  "PRSQ" + stream id (u32 BE) + sequence number (u64 BE)
  * Linux pktgen: magic 0xbe9be955 + sequence number (u32 BE) + tv_sec + tv_usec
    (board_pktgen.sh, or gen_seq.py --mode pktgen); stream id = source MAC + UDP
    source port
Every other frame (LLDP, ARP, ...) is counted as "other" and ignored.

Usage:
  check_pcap.py capture.pcapng [--sent sent.json] [--expect N] [--expect-if P1=N]
                [--interface P1] [--allow-drops] [--json]

  --sent      the JSON summary gen_seq.py wrote (streams with first seq + count)
  --expect    every stream must have exactly N frames
  --expect-if the named interface must have exactly N test frames in total
  --interface only check this interface (repeatable)
Exit: 0 = PASS, 1 = FAIL, 2 = usage / file error.
"""

import argparse
import json
import math
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pcapng_reader import Capture, PcapngError  # noqa: E402

PRSQ_MAGIC = b"PRSQ"
PKTGEN_MAGIC = 0xBE9BE955
EPB_FLAG_CRC_ERR = 1 << 24
FCS_LEN = 4


def parse_test_frame(data):
    """Return (kind, stream_key, seq, seq_bits) or None."""
    if len(data) < 14:
        return None
    off = 12
    (etype,) = struct.unpack_from("!H", data, off)
    off += 2
    while etype in (0x8100, 0x88A8, 0x9100) and len(data) >= off + 4:
        (etype,) = struct.unpack_from("!H", data, off + 2)
        off += 4
    if etype != 0x0800 or len(data) < off + 20:
        return None
    ihl = (data[off] & 0x0F) * 4
    if data[off] >> 4 != 4 or ihl < 20 or data[off + 9] != 17:
        return None
    u = off + ihl
    if len(data) < u + 8:
        return None
    sport, dport = struct.unpack_from("!HH", data, u)
    p = u + 8
    if data[p:p + 4] == PRSQ_MAGIC and len(data) >= p + 16:
        stream, seq = struct.unpack_from("!IQ", data, p + 4)
        return "prsq", f"prsq:{stream}", seq, 64
    if len(data) >= p + 8 and struct.unpack_from("!I", data, p)[0] == PKTGEN_MAGIC:
        (seq,) = struct.unpack_from("!I", data, p + 4)
        smac = data[6:12].hex(":")
        return "pktgen", f"pktgen:{smac}:{sport}", seq, 32
    return None


class Stats:
    """Running min/mean/max/stdev (Welford)."""

    def __init__(self):
        self.n = 0
        self.mean = 0.0
        self.m2 = 0.0
        self.min = None
        self.max = None

    def add(self, x):
        self.n += 1
        d = x - self.mean
        self.mean += d / self.n
        self.m2 += d * (x - self.mean)
        self.min = x if self.min is None else min(self.min, x)
        self.max = x if self.max is None else max(self.max, x)

    def __str__(self):
        if not self.n:
            return "n/a"
        sd = math.sqrt(self.m2 / self.n) if self.n > 1 else 0.0
        return f"min {self.min} ns, mean {self.mean:.1f} ns, max {self.max} ns, stdev {sd:.1f} ns"


class SeqSet:
    """Set of sequence numbers as a growable bitmap (1 bit per number), so a
    line-rate capture of 10^8 frames needs ~12 MB, not a Python set."""

    def __init__(self):
        self.base = None
        self.bits = bytearray()
        self.size = 0

    def _ensure(self, seq):
        if self.base is None:
            self.base = seq
        if seq < self.base:                     # grow downwards (rare: reordering)
            shift = ((self.base - seq + 7) // 8) * 8
            self.bits = bytearray(shift // 8) + self.bits
            self.base -= shift
        idx = seq - self.base
        if idx // 8 >= len(self.bits):
            self.bits.extend(bytearray(max(idx // 8 + 1 - len(self.bits), len(self.bits))))
        return idx

    def add(self, seq):
        """Add; return True if it was already present."""
        i = self._ensure(seq)
        m = 1 << (i & 7)
        if self.bits[i >> 3] & m:
            return True
        self.bits[i >> 3] |= m
        self.size += 1
        return False

    def count_range(self, lo, hi):
        """Number of present sequence numbers in [lo, hi]."""
        if self.base is None or hi < lo:
            return 0
        n = 0
        a = max(lo, self.base) - self.base
        b = min(hi - self.base, len(self.bits) * 8 - 1)
        if b < a:
            return 0
        while a <= b and a & 7:
            n += (self.bits[a >> 3] >> (a & 7)) & 1
            a += 1
        while a + 7 <= b:
            n += bin(self.bits[a >> 3]).count("1")
            a += 8
        while a <= b:
            n += (self.bits[a >> 3] >> (a & 7)) & 1
            a += 1
        return n


class Stream:
    def __init__(self, key, ifname, bits):
        self.key, self.ifname, self.bits = key, ifname, bits
        self.count = 0
        self.first = None
        self.maxseq = None
        self.seen = SeqSet()       # unwrapped sequence numbers
        self.dups = 0
        self.reorders = 0
        self.wrap_base = 0
        self.prev_raw = None
        self.gap = Stats()
        self.prev_ts = None
        self.bad_fcs = 0

    def unwrap(self, raw):
        if self.bits >= 64:
            return raw
        mod = 1 << self.bits
        if self.prev_raw is not None and raw < self.prev_raw and self.prev_raw - raw > mod // 2:
            self.wrap_base += mod
        self.prev_raw = raw
        return self.wrap_base + raw

    def add(self, raw_seq, ts, bad_fcs):
        seq = self.unwrap(raw_seq)
        self.count += 1
        if bad_fcs:
            self.bad_fcs += 1
        if self.first is None:
            self.first = seq
        if self.seen.add(seq):
            self.dups += 1
        if self.maxseq is not None and seq < self.maxseq:
            self.reorders += 1
        self.maxseq = seq if self.maxseq is None else max(self.maxseq, seq)
        if self.prev_ts is not None:
            self.gap.add(ts - self.prev_ts)
        self.prev_ts = ts

    def missing(self, first=None, count=None):
        lo = self.first if first is None else first
        hi = self.maxseq if count is None else lo + count - 1
        if lo is None or hi is None:
            return count or 0
        return (hi - lo + 1) - self.seen.count_range(lo, hi)

    def outside(self, first, count):
        """Distinct sequence numbers outside [first, first + count)."""
        return self.seen.size - self.seen.count_range(first, first + count - 1)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("file")
    ap.add_argument("--sent", help="gen_seq.py summary JSON")
    ap.add_argument("--expect", type=int, help="frames expected per stream")
    ap.add_argument("--expect-if", action="append", default=[], metavar="IF=N",
                    help="test frames expected on interface IF")
    ap.add_argument("--interface", action="append", default=[], help="only check these interfaces")
    ap.add_argument("--allow-drops", action="store_true",
                    help="do not fail on non-zero isb_ifdrop")
    ap.add_argument("--json", action="store_true", help="print a JSON result line")
    a = ap.parse_args()

    expect_if = {}
    for item in a.expect_if:
        k, _, v = item.partition("=")
        expect_if[k] = int(v)
    sent = None
    if a.sent:
        with open(a.sent) as f:
            sent = json.load(f)

    cap = Capture(a.file)
    streams = {}
    per_if = {}
    fails = []
    try:
        for pkt in cap.packets():
            itf = cap.interfaces[pkt.ifid]
            if a.interface and itf.name not in a.interface:
                continue
            st = per_if.setdefault(itf.name, {"frames": 0, "test": 0, "other": 0, "bad_fcs": 0,
                                              "truncated": 0, "unreadable": 0,
                                              "ts_backwards": 0, "prev_ts": None,
                                              "first_ts": None, "last_ts": None, "bytes": 0,
                                              "dropcount": 0})
            st["frames"] += 1
            st["dropcount"] += pkt.dropcount
            st["bytes"] += pkt.wirelen
            if st["prev_ts"] is not None and pkt.ts < st["prev_ts"]:
                st["ts_backwards"] += 1
            st["prev_ts"] = pkt.ts
            st["first_ts"] = pkt.ts if st["first_ts"] is None else st["first_ts"]
            st["last_ts"] = pkt.ts
            bad = bool(pkt.flags & EPB_FLAG_CRC_ERR)
            if bad:
                st["bad_fcs"] += 1
            if pkt.caplen < pkt.wirelen - FCS_LEN:
                st["truncated"] += 1
            r = parse_test_frame(pkt.data)
            if r is None:
                if pkt.caplen < pkt.wirelen - FCS_LEN and pkt.caplen < 58:
                    st["unreadable"] += 1
                else:
                    st["other"] += 1
                continue
            kind, key, seq, bits = r
            st["test"] += 1
            s = streams.get((itf.name, key))
            if s is None:
                s = streams[(itf.name, key)] = Stream(key, itf.name, bits)
            s.add(seq, pkt.ts, bad)
    except PcapngError as ex:
        print(f"check_pcap: {a.file}: {ex}")
        sys.exit(2)

    result = {"file": a.file, "interfaces": {}, "streams": []}
    print(f"{a.file}: {len(cap.interfaces)} interfaces, {len(streams)} test streams")
    for itf in cap.interfaces:
        st = per_if.get(itf.name)
        isb = itf.stats
        if a.interface and itf.name not in a.interface:
            continue
        if st is None:
            st = {"frames": 0, "test": 0, "other": 0, "bad_fcs": 0, "truncated": 0,
                  "unreadable": 0, "ts_backwards": 0, "first_ts": None, "last_ts": None,
                  "bytes": 0, "dropcount": 0}
        dur = ((st["last_ts"] - st["first_ts"]) / 1e9) if st["first_ts"] is not None else 0
        print(f"  {itf.name}: {st['frames']} frames ({st['test']} test, {st['other']} other), "
              f"{st['bytes']} bytes on the wire in {dur:.6f} s; bad FCS {st['bad_fcs']}, "
              f"truncated {st['truncated']}, timestamps backwards {st['ts_backwards']}")
        if st["dropcount"]:
            print(f"      epb_dropcount total {st['dropcount']} (frames the hardware dropped "
                  f"between captured frames)")
        result["interfaces"][itf.name] = {"frames": st["frames"], "test": st["test"],
                                          "dropcount": st["dropcount"],
                                          "isb_ifdrop": isb.get("isb_ifdrop"),
                                          "isb_ifrecv": isb.get("isb_ifrecv")}
        if isb:
            print(f"      ISB: ifrecv {isb.get('isb_ifrecv', '-')}, ifdrop {isb.get('isb_ifdrop', '-')}, "
                  f"filteraccept {isb.get('isb_filteraccept', '-')}, osdrop {isb.get('isb_osdrop', '-')}, "
                  f"usrdeliv {isb.get('isb_usrdeliv', '-')}")
            if isb.get("isb_ifdrop") and not a.allow_drops:
                fails.append(f"{itf.name}: isb_ifdrop = {isb['isb_ifdrop']}")
            if isb.get("isb_osdrop") and not a.allow_drops:
                fails.append(f"{itf.name}: isb_osdrop = {isb['isb_osdrop']}")
        if st["ts_backwards"]:
            fails.append(f"{itf.name}: {st['ts_backwards']} timestamps go backwards")
        if st["unreadable"]:
            print(f"      {st['unreadable']} frames truncated before the sequence number "
                  f"(snaplen too small to check them)")
        if itf.name in expect_if and st["test"] != expect_if[itf.name]:
            fails.append(f"{itf.name}: {st['test']} test frames, expected {expect_if[itf.name]}")
    for k in expect_if:
        if k not in [i.name for i in cap.interfaces]:
            fails.append(f"interface {k} not in the capture")

    sent_streams = {}
    if sent:
        for ss in sent.get("streams", []):
            sent_streams[ss["key"]] = ss

    for (ifname, key), s in sorted(streams.items()):
        first = count = None
        if key in sent_streams:
            first, count = sent_streams[key]["first"], sent_streams[key]["count"]
            if first is None:          # pktgen: first sequence number not known exactly
                first = s.first
        elif a.expect is not None:
            first, count = s.first, a.expect
        miss = s.missing(first, count)
        extra = 0
        if count is not None:
            extra = s.outside(first, count)
        print(f"  {ifname} {key}: {s.count} frames, seq {s.first}..{s.maxseq}, "
              f"missing {miss}, duplicates {s.dups}, out of order {s.reorders}, "
              f"unexpected {extra}, bad FCS {s.bad_fcs}")
        print(f"      interval: {s.gap}")
        if miss:
            fails.append(f"{ifname} {key}: {miss} frames missing")
        if s.dups:
            fails.append(f"{ifname} {key}: {s.dups} duplicates")
        if s.reorders:
            fails.append(f"{ifname} {key}: {s.reorders} out of order")
        if extra:
            fails.append(f"{ifname} {key}: {extra} unexpected sequence numbers")
        if count is not None and s.count != count:
            fails.append(f"{ifname} {key}: {s.count} frames captured, {count} sent")
        result["streams"].append({"interface": ifname, "key": key, "frames": s.count,
                                  "first": s.first, "last": s.maxseq, "missing": miss,
                                  "dups": s.dups, "reorders": s.reorders,
                                  "gap_min_ns": s.gap.min, "gap_mean_ns": s.gap.mean,
                                  "gap_max_ns": s.gap.max})
    for key in sent_streams:
        if not any(k == key for (_, k) in streams):
            fails.append(f"stream {key} was sent but not captured")
    if not streams:
        fails.append("no test frames found")

    for f in fails:
        print(f"FAIL: {f}")
    print("PASS" if not fails else f"FAIL ({len(fails)} problems)")
    if a.json:
        result["pass"] = not fails
        result["failures"] = fails
        print(json.dumps(result))
    sys.exit(0 if not fails else 1)


if __name__ == "__main__":
    main()
