#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""make_synth_capture.py - synthetic FPGA Packet Recorder capture file (stdlib only).

Writes a capture file exactly as pktrec-cap would (4 KB header + record
stream, record format v1) with sequence-numbered gen_seq.py frames on four
ports, for testing pktrec-export and the pcapng tooling without hardware:

  P0  64-byte frames at 1 Gb/s line rate          (stream 0)
  P1  1518-byte frames at line rate               (stream 1)
  P2  random sizes 64..1518, random gaps          (stream 2)
  P3  802.1Q-tagged 128-byte frames               (stream 3)

Record order models the hardware: each frame is complete in its port FIFO at
ts + wire time, then waits a random arbiter delay (per port in order), so the
stream is NOT in timestamp order across ports. Also included: one frame
truncated by snaplen (flag bit1), one bad-FCS frame (bit0), zero padding
blocks between records and at the end (as a flush would leave).

--damage adds a corrupted stretch (random bytes over whole records) and ends
the file in the middle of a record; the frames destroyed are listed in the
--expect JSON so the self-test can check that exactly those are missing.

Usage: make_synth_capture.py out.cap [--frames N] [--damage] [--seed S]
                             [--expect out.expect.json] [--sent sent.json]
"""

import argparse
import json
import random
import struct
import sys
import os

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from gen_seq import FrameBuilder, mac_bytes  # noqa: E402

HDR_SIZE = 4096
MAGIC = b"PKTREC\x00\x00"
FLAG_COMPLETE = 1 << 1
REC_BAD, REC_TRUNC, REC_TS_MAC = 1, 2, 4
MARKER = 0xA0
# pktrec_format_draft.h: struct pktrec_file_header
HDR_FMT = "<8s10I6Q32s64s"
PORT_FMT = "<8Q"


def rec_len(cap):
    return (16 + cap + 15) & ~15


def make_header(port_mask, snaplen, start_ns, tb0, tb1, data_bytes, ports, stop_ns):
    h = struct.pack(HDR_FMT, MAGIC, 1, HDR_SIZE, 1, FLAG_COMPLETE,
                    0x504B4350, 0x00010000, 0x00010001, 0, port_mask, snaplen,
                    start_ns, tb0, stop_ns, tb1, data_bytes, 0,
                    b"zcu106", b"synthetic")
    for p in range(4):
        st = ports.get(p, {})
        h += struct.pack(PORT_FMT, st.get("rx_good", 0), st.get("rx_bad", 0),
                         st.get("dropped", 0), st.get("bytes", 0), st.get("records", 0), 0, 0, 0)
    assert len(h) <= HDR_SIZE
    return h + bytes(HDR_SIZE - len(h))


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("output")
    ap.add_argument("--frames", type=int, default=5000, help="frames per port")
    ap.add_argument("--damage", action="store_true")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--snaplen", type=int, default=1514)
    ap.add_argument("--expect", help="write the expected per-stream result here")
    ap.add_argument("--sent", help="write a gen_seq.py-style summary here")
    a = ap.parse_args()
    rnd = random.Random(a.seed)

    tb0 = 5_000_000_000                     # timebase at start (5 s after reset)
    start_ns = 1_791_000_000_000_000_000    # 2026-10 wall clock
    dst = mac_bytes("02:00:00:00:00:99")
    frames = []                             # (deliver_time, port, ts, wirelen, data, flags)
    for port in range(4):
        src = mac_bytes(f"02:00:00:00:00:1{port}")
        t = tb0 + 1000 + port * 37
        avail = 0                           # time the port FIFO can deliver next
        for i in range(a.frames):
            if port == 0:
                size, gap, vlan = 64, 0, None
            elif port == 1:
                size, gap, vlan = 1518, 0, None
            elif port == 2:
                size, gap, vlan = rnd.randint(64, 1518), rnd.randint(0, 20000), None
            else:
                size, gap, vlan = 128, rnd.randint(0, 2000), 100
            fb = FrameBuilder(size, dst, src, "192.0.2.1", "192.0.2.2", 50000 + port, 50001,
                              port, vlan)
            data = fb.frame(i)
            wire = (size + 20) * 8          # incl. preamble + SFD + IFG at 1 Gb/s
            done = t + size * 8             # last FCS bit received (ts = SFD)
            deliver = max(done + rnd.randint(0, 20000), avail)
            avail = deliver
            flags = REC_TS_MAC
            if port == 2 and i == a.frames // 3:
                flags |= REC_BAD
            frames.append([deliver, port, t, size, data, flags])
            t += wire + gap
    frames.sort(key=lambda f: (f[0], f[1]))

    # one frame truncated by snaplen (P1 middle), on top of snaplen 1514
    seqs = [0] * 4
    out = bytearray()
    starts = []                             # (offset, length, port)
    stats = {p: {"rx_good": 0, "rx_bad": 0, "dropped": 0, "bytes": 0, "records": 0}
             for p in range(4)}
    trunc_done = False
    for n, (deliver, port, ts, size, data, flags) in enumerate(frames):
        cap = size - 4
        if a.snaplen and cap > a.snaplen:
            cap = a.snaplen
            flags |= REC_TRUNC
        if port == 1 and not trunc_done and seqs[1] == a.frames // 2:
            cap = 128
            flags |= REC_TRUNC
            trunc_done = True
        body = data[:cap]
        hdr = struct.pack("<QHHBBH", ts, cap, size, port, MARKER | flags, seqs[port])
        rec = hdr + body + bytes(rec_len(cap) - 16 - cap)
        starts.append((len(out), len(rec), port))
        out += rec
        seqs[port] = (seqs[port] + 1) & 0xFFFF
        st = stats[port]
        st["records"] += 1
        st["bytes"] += size
        st["rx_bad" if flags & REC_BAD else "rx_good"] += 1
        if n % 997 == 500:
            out += bytes(16 * rnd.randint(1, 3))    # padding between records
    out += bytes(4096 - len(out) % 4096) if len(out) % 4096 else b""

    lost = {p: 0 for p in range(4)}
    tail = 0
    if a.damage:
        # corrupt whole records 40 % into the stream: from one record's start
        # to the end of a record 25 records later
        i0 = len(starts) * 2 // 5
        i1 = i0 + 25
        o0 = starts[i0][0]
        o1 = starts[i1][0] + starts[i1][1]
        out[o0:o1] = bytes(rnd.getrandbits(8) for _ in range(o1 - o0))
        for k in range(i0, i1 + 1):
            lost[starts[k][2]] += 1
        # end the data inside the last record (drop the padding, cut 40 bytes)
        last_off, last_len, last_port = starts[-1]
        out = out[:last_off + last_len - 40]
        lost[last_port] += 1
        tail = last_len - 40

    tb1 = frames[-1][0] + 1000
    hdr = make_header(0xF, a.snaplen, start_ns, tb0, tb1, len(out), stats,
                      start_ns + (tb1 - tb0))
    with open(a.output, "wb") as f:
        f.write(hdr)
        f.write(out)

    ooo = sum(1 for x, y in zip(frames, frames[1:]) if y[2] < x[2])
    print(f"make_synth_capture: {a.output}: {len(frames)} records, {len(out)} data bytes, "
          f"{ooo} timestamp inversions in record order"
          + (f", damaged: {sum(lost.values())} records destroyed, tail {tail} bytes"
             if a.damage else ""))
    if a.sent:
        with open(a.sent, "w") as f:
            json.dump({"generator": "make_synth_capture.py",
                       "streams": [{"key": f"prsq:{p}", "first": 0, "count": a.frames}
                                   for p in range(4)]}, f, indent=1)
    if a.expect:
        with open(a.expect, "w") as f:
            json.dump({"frames_per_port": a.frames, "lost": lost,
                       "records": len(frames) - sum(lost.values()),
                       "bad_fcs_port": 2, "trunc_port": 1}, f, indent=1)


if __name__ == "__main__":
    main()
