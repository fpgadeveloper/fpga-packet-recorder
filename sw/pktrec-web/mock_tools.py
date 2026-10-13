#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""mock_tools.py - stand-ins for pktrec-cap and pktrec-phy, for testing
pktrec-web on a PC (pktrec-web --mock). Host test only; not installed.

They print exactly the text formats of the real tools (sw/pktrec-apps/pktrec-cap.c
'stats' / live statistics / RESULT line, sw/pktrec-tools/pktrec-phy 'status'),
so the server's parsers are exercised end to end. State lives in
$PKTREC_MOCK_STATE (JSON files).

  mock_tools.py cap record [--ports L] [--snaplen N] [--duration S] [--size B]
                           [--stats S] <file>
      fake capture: live statistics on stderr every --stats seconds; stops on
      SIGTERM/SIGINT, --duration or --size; then writes a real capture file
      with test/make_synth_capture.py (4 ports of sequence-numbered frames,
      whatever --ports says) so pktrec-export can convert it. An output name
      containing 'mockfail' fails at start (exit 1), like a missing /dev/fdrec0.
  mock_tools.py cap stats
  mock_tools.py cap info <file>
  mock_tools.py phy status
  mock_tools.py phy path <port|all> idle|loop|fwd
"""

import argparse
import json
import os
import signal
import struct
import subprocess
import sys
import time

STATE = os.environ.get("PKTREC_MOCK_STATE", "/tmp/pktrec-mock")
HERE = os.path.dirname(os.path.realpath(__file__))
SYNTH = os.path.normpath(os.path.join(HERE, "..", "..", "test", "make_synth_capture.py"))
# per-port fake traffic: frames/s, frame size (wire bytes incl. FCS)
RATE = [(80000.0, 512), (40000.0, 1518), (120000.0, 64), (0.0, 64)]
LINK = ["1G", "1G", "1G", "down"]


def load(name, default):
    try:
        with open(os.path.join(STATE, name)) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def save(name, obj):
    os.makedirs(STATE, exist_ok=True)
    tmp = os.path.join(STATE, name + ".tmp")
    with open(tmp, "w") as f:
        json.dump(obj, f)
    os.replace(tmp, os.path.join(STATE, name))


def counters(now=None):
    """Counters = rate x time the port was enabled for capture (all runs)."""
    now = now or time.time()
    runs = load("runs.json", [])
    out = []
    for p in range(4):
        t = sum((r[1] or now) - r[0] for r in runs if r[2] >> p & 1)
        fr = int(RATE[p][0] * t)
        drops = fr // 50000 if p == 2 else 0       # P2 drops a little, for the UI
        out.append({"frames_rx": fr, "bad": 0, "drop": drops, "trunc": 0,
                    "bytes_rx": fr * RATE[p][1], "records": fr - drops,
                    "hwm": 2048 if fr else 0, "seq": fr & 0xFFFF})
    return out, runs and runs[-1][1] is None, runs[-1][2] if runs else 0


def fmt_rate(v, unit):
    if v >= 1e9:
        return f"{v / 1e9:.2f}G{unit}"
    if v >= 1e6:
        return f"{v / 1e6:.2f}M{unit}"
    if v >= 1e3:
        return f"{v / 1e3:.1f}k{unit}"
    return f"{v:.0f}{unit}"


# ---------------------------------------------------------------- cap
def cap_stats(_a):
    c, running, mask = counters()
    tb = time.time_ns()
    print(f"capture  version 0x00010001  CTRL 0x{3 if running else 0:08x} "
          f"({'ENABLED' if running else 'disabled'}, source = "
          f"{'capture' if running else 'TPG'})  STATUS 0x00000001 (idle)")
    print(f"ports    enabled 0x{mask if running else 0:x}, snaplen 0, FIFO 16384 bytes/port, "
          "dp_clk 250000000 Hz")
    print(f"timebase {tb} ns ({time.strftime('%Y-%m-%d %H:%M:%S', time.gmtime(tb / 1e9))}."
          f"{tb % 1000000000:09d} UTC if set from CLOCK_REALTIME), inc 4 + 0/2^32 ns, "
          "TB_STATUS 0x0f")
    print(f"merge    {sum(x['records'] for x in c)} records, 0 bytes out, 0 fill units, "
          "back-pressure 0 cycles, reset aborts 0, length fixups 0")
    print("port link  %14s %10s %10s %10s %16s %14s %9s %6s" % (
        "frames_rx", "bad", "dropped", "truncated", "bytes_rx", "records", "fifo_hwm", "seq"))
    for p, x in enumerate(c):
        print("P%u   %-5s %14u %10u %10u %10u %16u %14u %9u %6u%s" % (
            p, LINK[p], x["frames_rx"], x["bad"], x["drop"], x["trunc"], x["bytes_rx"],
            x["records"], x["hwm"], x["seq"],
            "" if running and mask >> p & 1 else "  (not enabled)"))
    return 0


def parse_ports(s):
    if s == "all":
        return 0xF
    m = 0
    for part in s.split(","):
        a, _, b = part.partition("-")
        for p in range(int(a), int(b or a) + 1):
            m |= 1 << p
    return m


def cap_record(a):
    if "mockfail" in os.path.basename(a.file):
        print("pktrec-cap: open /dev/fdrec0: No such file or directory (mock failure)",
              file=sys.stderr)
        return 1
    mask = parse_ports(a.ports)
    runs = load("runs.json", [])
    if runs and runs[-1][1] is None:
        runs[-1][1] = time.time()
    t0 = time.time()
    runs.append([t0, None, mask])
    save("runs.json", runs)
    with open(a.file, "wb") as f:                  # header placeholder, like the real app
        f.write(b"\0" * 4096)
    stop = {"why": None}

    def on_sig(signum, frame):
        stop["why"] = "signal"
    signal.signal(signal.SIGTERM, on_sig)
    signal.signal(signal.SIGINT, on_sig)
    print(f"pktrec-cap: capturing ports {' '.join(f'P{p}' for p in range(4) if mask >> p & 1)}"
          f" to {a.file} (snaplen {a.snaplen}, 32 x 8 MB buffers, qd 8) [MOCK]",
          file=sys.stderr, flush=True)
    last_t, last_c = t0, counters(t0)[0]
    written = 0.0
    while stop["why"] is None:
        time.sleep(min(a.stats or 1.0, 0.2) if a.stats else 0.2)
        now = time.time()
        el = now - t0
        if a.duration and el >= a.duration:
            stop["why"] = "time"
        if a.stats and now - last_t >= a.stats:
            c = counters(now)[0]
            dt = now - last_t
            bw = sum((c[p]["bytes_rx"] - last_c[p]["bytes_rx"]) + 16 * (c[p]["frames_rx"] -
                     last_c[p]["frames_rx"]) for p in range(4) if mask >> p & 1)
            written += bw
            line = (f"{el:7.1f}s {bw / dt / 1e6:7.1f} MB/s {written / 1e9:9.3f} GB ring "
                    f"{int(el * 7) % 9:2d}/32 bp {0.0:4.1f}%")
            for p in range(4):
                if mask >> p & 1:
                    line += (f" | P{p} {fmt_rate((c[p]['frames_rx'] - last_c[p]['frames_rx']) / dt, '')}/s"
                             f" {fmt_rate((c[p]['bytes_rx'] - last_c[p]['bytes_rx']) * 8 / dt, 'b')}/s"
                             f" d{c[p]['drop']}")
            print(line, file=sys.stderr, flush=True)
            last_t, last_c = now, c
            if a.size and written >= a.size:
                stop["why"] = "size"
    t1 = time.time()
    runs = load("runs.json", runs)
    runs[-1][1] = t1
    save("runs.json", runs)
    frames = max(200, min(3000, int(400 * (t1 - t0))))
    if os.path.isfile(SYNTH):
        cmd = [sys.executable, SYNTH, a.file, "--frames", str(frames), "--seed",
               str(int(t0) & 0xFFFF)]
        if a.snaplen:
            cmd += ["--snaplen", str(a.snaplen)]
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL)
        with open(a.file, "r+b") as f:             # real start/stop times, limit flag
            raw = bytearray(f.read(4096))
            flags = struct.unpack_from("<I", raw, 20)[0]
            flags |= {"time": 8, "size": 4}.get(stop["why"], 0)
            struct.pack_into("<I", raw, 20, flags)
            struct.pack_into("<QQ", raw, 48, int(t0 * 1e9), int(t1 * 1e9))
            f.seek(0)
            f.write(raw)
    data = os.path.getsize(a.file) - 4096
    print(f"pktrec-cap: {a.file}: {frames * 4} records, {data} bytes in {t1 - t0:.2f} s "
          f"({data / max(t1 - t0, 1e-3) / 1e6:.1f} MB/s) [MOCK]")
    print(f"RESULT bytes={data} records={frames * 4} seconds={t1 - t0:.3f} drops=0 "
          "rec_drop_beats=0 len_fixups=0 error=0")
    return 0


def cap_info(a):
    with open(a.file, "rb") as f:
        raw = f.read(4096)
    if raw[:8] != b"PKTRCAP\x00":
        print(f"pktrec-cap info: {a.file}: not a capture file", file=sys.stderr)
        return 1
    v = struct.unpack_from("<8s10I9Q", raw, 0)
    print(f"header version   {v[1]}, record format {v[3]}{'' if v[4] & 1 else '  ** NOT COMPLETE **'}")
    print(f"ports            mask 0x{v[8]:x}")
    print(f"snaplen          {v[10] or 'none (whole frames)'}")
    print(f"start / stop     {v[11]} / {v[12]} ns, {(v[12] - v[11]) / 1e9:.3f} s")
    print(f"data             {v[16]} bytes, {v[17]} records   [MOCK info]")
    return 0


# ---------------------------------------------------------------- phy
PHY_ADDR = [0x01, 0x03, 0x0C, 0x0F]


def phy_status(_a):
    paths = load("phy.json", ["idle"] * 4)
    print("eth_ports: gtpowergood=1 qpll0_lock=1 phy_reset_n=0xf PG_1V0=1 PG_2V5=1")
    print("port phy  copper            sgmii/pcs                         lp_adv  link_up "
          "gpio0 gpio1 path")
    for n in range(4):
        up = LINK[n] != "down"
        copper = f"up {LINK[n]:>4} FD" if up else "down"
        pcs = f"sync={int(up)} an={'done' if up else 'idle'} lp_link={int(up)} 1G FD"
        print(f"P{n}   0x{PHY_ADDR[n]:02x} {copper:<17} {pcs:<33} 0x{0xd801 if up else 0:04x}  "
              f"{int(up)}       0     0     {paths[n]}")
    return 0


def phy_path(a):
    paths = load("phy.json", ["idle"] * 4)
    ports = range(4) if a.port == "all" else [int(a.port.lstrip("pP"))]
    for n in ports:
        if not 0 <= n <= 3:
            print("port must be 0..3 or all", file=sys.stderr)
            return 1
        paths[n] = a.mode
    save("phy.json", paths)
    print("PATH_CTRL (mock) " + ", ".join(f"P{n}={paths[n]}" for n in range(4)))
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    tool = ap.add_subparsers(dest="tool", required=True)
    cap = tool.add_parser("cap").add_subparsers(dest="cmd", required=True)
    p = cap.add_parser("record")
    p.add_argument("--ports", default="all")
    p.add_argument("--snaplen", type=int, default=0)
    p.add_argument("--duration", type=float)
    p.add_argument("--size", type=int)
    p.add_argument("--stats", type=float, default=1.0)
    p.add_argument("file")
    p.set_defaults(fn=cap_record)
    cap.add_parser("stats").set_defaults(fn=cap_stats)
    p = cap.add_parser("info")
    p.add_argument("file")
    p.set_defaults(fn=cap_info)
    phy = tool.add_parser("phy").add_subparsers(dest="cmd", required=True)
    phy.add_parser("status").set_defaults(fn=phy_status)
    p = phy.add_parser("path")
    p.add_argument("port")
    p.add_argument("mode", choices=["idle", "loop", "fwd"])
    p.set_defaults(fn=phy_path)
    a = ap.parse_args()
    return a.fn(a)


if __name__ == "__main__":
    sys.exit(main())
