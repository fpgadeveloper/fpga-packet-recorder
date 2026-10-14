#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""compare_replay.py - replay timing accuracy, standard library only.

Compares the frames of one interface of an ORIGINAL capture (pcapng from
pktrec-export) with the frames captured on the receiving port while that
interface was replayed (pktrec-replay), e.g. replay P3's frames out of P2 and
capture them on P3 (P2 <-> P3 cable):

    compare_replay.py orig.pcapng --orig-iface P3 replay.pcapng --replay-iface P3
                      [--rate X | --topspeed] [--include-bad] [--tolerance NS] [--json]

Pairing: frames are matched by their bytes (a hash of the frame; the replay
sends the captured bytes and the MAC appends a new FCS, so the receiver sees
the same bytes), in order: each replayed frame is paired with the earliest
not yet paired original frame with the same bytes that comes after the
previous pair. Original frames that are never paired are LOST, replayed frames
without a partner are EXTRA (duplicates or foreign traffic); pairs whose
original order is reversed are REORDERED.

Timing, over consecutive pairs (i, j):
    interval error = (t_rep[j] - t_rep[i]) - (t_orig[j] - t_orig[i]) / rate
reported as mean / stdev / max |error| (and percentiles), plus the schedule
error (t_rep[j] - t_rep[first]) - (t_orig[j] - t_orig[first]) / rate, which
shows drift (timebase vs the capture's clock). --topspeed: no timing
comparison (back-to-back replay), only lost / extra / order, and the achieved
frame rate.

By default original frames flagged as errored (epb_flags FCS/symbol error bits,
as pktrec-export writes them) are excluded, because pktrec-replay skips them
unless --keep-bad; --include-bad keeps them.

Exit: 0 = nothing lost / extra / reordered and max |interval error| <= tolerance
(default 64 ns), 1 = otherwise, 2 = usage / file error.

--selftest: builds synthetic captures (jitter, a lost and a duplicated frame,
rate 2) in a temporary directory and checks the script's own results.
"""

import argparse
import hashlib
import json
import math
import os
import struct
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from pcapng_reader import Capture, PcapngError  # noqa: E402

ERR_FLAGS = 0xFF000000   # epb_flags link-layer dependent errors (CRC, symbol, ...)


def iface_index(cap_path, name):
    """Packets of interface `name` ("P3" or an index) as [(ts_ns, bytes, flags)]."""
    cap = Capture(cap_path)
    out = []
    want = None
    for pkt in cap.packets():
        if want is None:
            for itf in cap.interfaces:
                if itf.name == name or str(itf.ifid) == name:
                    want = itf.ifid
            if want is None and not cap.interfaces:
                continue
            if want is None:
                raise PcapngError(f"{cap_path}: no interface {name} "
                                  f"(have {', '.join(i.name for i in cap.interfaces)})")
        if pkt.ifid == want:
            out.append((pkt.ts, bytes(pkt.data), pkt.flags))
    if want is None:
        raise PcapngError(f"{cap_path}: no packets")
    return out


def pair_frames(orig, rep):
    """Return (pairs [(oi, ri)], lost, extra, reordered)."""
    pos = {}
    for i, (_, data, _) in enumerate(orig):
        pos.setdefault(hashlib.blake2b(data, digest_size=16).digest(), []).append(i)
    nxt = {h: 0 for h in pos}
    used = [False] * len(orig)
    pairs, extra, reordered = [], 0, 0
    last_oi = -1
    for ri, (_, data, _) in enumerate(rep):
        h = hashlib.blake2b(data, digest_size=16).digest()
        lst = pos.get(h)
        if not lst:
            extra += 1
            continue
        k = nxt[h]
        while k < len(lst) and used[lst[k]]:
            k += 1
        if k >= len(lst):
            extra += 1          # more copies than in the original: duplicate
            continue
        oi = lst[k]
        used[oi] = True
        nxt[h] = k + 1
        if oi < last_oi:
            reordered += 1
        last_oi = max(last_oi, oi)
        pairs.append((oi, ri))
    lost = used.count(False)
    return pairs, lost, extra, reordered


def stats(vals):
    if not vals:
        return None
    n = len(vals)
    mean = sum(vals) / n
    var = sum((v - mean) ** 2 for v in vals) / n
    s = sorted(abs(v) for v in vals)
    pct = lambda q: s[min(n - 1, int(math.ceil(q * n)) - 1)]
    return {"n": n, "mean": mean, "stdev": math.sqrt(var), "min": min(vals), "max": max(vals),
            "max_abs": s[-1], "p50_abs": pct(0.50), "p99_abs": pct(0.99)}


def compare(orig_path, orig_if, rep_path, rep_if, rate=1.0, topspeed=False,
            include_bad=False, tolerance=64.0):
    orig = iface_index(orig_path, orig_if)
    excluded = 0
    if not include_bad:
        n0 = len(orig)
        orig = [o for o in orig if not (o[2] & ERR_FLAGS)]
        excluded = n0 - len(orig)
    rep = iface_index(rep_path, rep_if)
    pairs, lost, extra, reordered = pair_frames(orig, rep)
    res = {"original": {"file": orig_path, "iface": orig_if, "frames": len(orig),
                        "bad_excluded": excluded},
           "replayed": {"file": rep_path, "iface": rep_if, "frames": len(rep)},
           "rate": None if topspeed else rate, "paired": len(pairs), "lost": lost,
           "extra": extra, "reordered": reordered}
    ivl, sched = [], []
    if len(pairs) >= 2:
        o0, r0 = orig[pairs[0][0]][0], rep[pairs[0][1]][0]
        for (oi, ri), (oj, rj) in zip(pairs, pairs[1:]):
            d_rep = rep[rj][0] - rep[ri][0]
            d_org = (orig[oj][0] - orig[oi][0]) / rate
            ivl.append(d_rep - d_org)
        for oi, ri in pairs:
            sched.append((rep[ri][0] - r0) - (orig[oi][0] - o0) / rate)
        span = rep[pairs[-1][1]][0] - r0
        res["replay_span_ns"] = span
        res["replay_fps"] = (len(pairs) - 1) * 1e9 / span if span > 0 else None
    if topspeed:
        res["interval_error_ns"] = None
        ok = True
    else:
        res["interval_error_ns"] = stats(ivl)
        res["schedule_error_ns"] = stats(sched)
        ok = bool(ivl) and res["interval_error_ns"]["max_abs"] <= tolerance
    res["tolerance_ns"] = tolerance
    res["pass"] = ok and lost == 0 and extra == 0 and reordered == 0 and len(pairs) > 0
    return res


def print_human(r):
    o, p = r["original"], r["replayed"]
    print(f"original  {o['file']} {o['iface']}: {o['frames']} frames"
          + (f" ({o['bad_excluded']} errored frames excluded)" if o["bad_excluded"] else ""))
    print(f"replayed  {p['file']} {p['iface']}: {p['frames']} frames")
    print(f"paired    {r['paired']}, lost {r['lost']}, extra {r['extra']}, "
          f"reordered {r['reordered']}")
    if r.get("replay_fps"):
        print(f"replay    {r['replay_span_ns'] / 1e9:.6f} s, {r['replay_fps']:.0f} frames/s")
    e = r.get("interval_error_ns")
    if e:
        print(f"interval error (replayed - original/{r['rate']:g}) over {e['n']} intervals: "
              f"mean {e['mean']:+.2f} ns, stdev {e['stdev']:.2f} ns, max |e| {e['max_abs']:.1f} ns "
              f"(p50 {e['p50_abs']:.1f}, p99 {e['p99_abs']:.1f}), range [{e['min']:+.1f}, "
              f"{e['max']:+.1f}]")
        s = r["schedule_error_ns"]
        print(f"schedule error vs the first frame: range [{s['min']:+.1f}, {s['max']:+.1f}] ns "
              f"(drift / accumulated offset)")
    print("PASS" if r["pass"] else
          f"FAIL (tolerance {r['tolerance_ns']:g} ns; lost/extra/reordered must be 0)")


# ---------------------------------------------------------------------------
# self-test
# ---------------------------------------------------------------------------
def _write_pcapng(path, ifname, frames):
    """Minimal pcapng: SHB, one IDB (if_name, if_tsresol 9), EPBs (ts ns, flags)."""
    def blk(btype, body):
        body += b"\0" * ((4 - len(body) % 4) % 4)
        ln = len(body) + 12
        return struct.pack("<II", btype, ln) + body + struct.pack("<I", ln)

    def opt(code, val):
        return struct.pack("<HH", code, len(val)) + val + b"\0" * ((4 - len(val) % 4) % 4)
    with open(path, "wb") as f:
        f.write(blk(0x0A0D0D0A, struct.pack("<IHHq", 0x1A2B3C4D, 1, 0, -1) + opt(0, b"")))
        f.write(blk(1, struct.pack("<HHI", 1, 0, 65535) + opt(2, ifname.encode())
                    + opt(9, b"\x09") + opt(0, b"")))
        for ts, data, flags in frames:
            body = struct.pack("<IIIII", 0, ts >> 32, ts & 0xFFFFFFFF, len(data), len(data) + 4)
            body += data + b"\0" * ((4 - len(data) % 4) % 4)
            if flags:
                body += opt(2, struct.pack("<I", flags)) + opt(0, b"")
            f.write(blk(6, body))


def selftest():
    import random
    rnd = random.Random(7)
    with tempfile.TemporaryDirectory() as d:
        orig, t = [], 1_700_000_000_000_000_000
        for i in range(500):
            data = struct.pack(">I", i) + bytes(rnd.randrange(256) for _ in range(rnd.randrange(56, 300)))
            flags = 0x01000000 if i == 100 else 0
            orig.append((t, data, flags))
            t += rnd.randrange(800, 20000)
        rate = 2.0
        rep, t0 = [], 5_000_000
        jit = []
        for i, (ts, data, flags) in enumerate(orig):
            if i in (100, 250):          # 100: errored (skipped by replay), 250: lost
                continue
            j = rnd.randrange(-8, 9)
            jit.append(j)
            rep.append((t0 + int((ts - orig[0][0]) / rate) + j, data, 0))
            if i == 300:                 # a duplicate
                rep.append((t0 + int((ts - orig[0][0]) / rate) + 700, data, 0))
        _write_pcapng(os.path.join(d, "o.pcapng"), "P3", orig)
        _write_pcapng(os.path.join(d, "r.pcapng"), "P3", rep)
        r = compare(os.path.join(d, "o.pcapng"), "P3", os.path.join(d, "r.pcapng"), "P3",
                    rate=rate, tolerance=64)
        print_human(r)
        errs = []
        if r["original"]["bad_excluded"] != 1:
            errs.append("bad_excluded")
        if (r["lost"], r["extra"], r["reordered"]) != (1, 1, 0):
            errs.append(f"lost/extra/reordered {r['lost']}/{r['extra']}/{r['reordered']}")
        if r["paired"] != 498 or r["interval_error_ns"]["max_abs"] > 17:
            errs.append("pairing / interval error")
        if r["pass"]:
            errs.append("must FAIL (lost + extra)")
        # identical files: perfect
        r2 = compare(os.path.join(d, "o.pcapng"), "P3", os.path.join(d, "o.pcapng"), "P3",
                     include_bad=True)
        if not r2["pass"] or r2["interval_error_ns"]["max_abs"] != 0:
            errs.append("self-compare")
    print("selftest:", "PASS" if not errs else "FAIL " + ", ".join(errs))
    return 0 if not errs else 1


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("original", nargs="?")
    ap.add_argument("replayed", nargs="?")
    ap.add_argument("--orig-iface", default="P3", help="interface replayed (default P3)")
    ap.add_argument("--replay-iface", default="P3", help="interface that received the replay")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--rate", type=float, default=1.0, help="pktrec-replay --rate (default 1)")
    g.add_argument("--topspeed", action="store_true", help="pktrec-replay --topspeed")
    ap.add_argument("--include-bad", action="store_true",
                    help="keep errored original frames (pktrec-replay --keep-bad/--bad-as-good)")
    ap.add_argument("--tolerance", type=float, default=64.0,
                    help="max |interval error| in ns for PASS (default 64)")
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        return selftest()
    if not a.original or not a.replayed:
        ap.error("original and replayed pcapng files are required")
    try:
        r = compare(a.original, a.orig_iface, a.replayed, a.replay_iface, a.rate, a.topspeed,
                    a.include_bad, a.tolerance)
    except (OSError, PcapngError) as e:
        print(f"compare_replay: {e}", file=sys.stderr)
        return 2
    if a.json:
        print(json.dumps(r, indent=1))
    else:
        print_human(r)
    return 0 if r["pass"] else 1


if __name__ == "__main__":
    sys.exit(main())
