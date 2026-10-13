#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""gen_seq.py - sequence-numbered UDP test traffic for the FPGA Packet Recorder.

Every frame is Ethernet / [802.1Q] / IPv4 / UDP with the payload

    "PRSQ" | stream id (u32, big-endian) | sequence number (u64, big-endian) | zero fill

which fits the minimum frame (64 bytes on the wire incl. FCS: 14 + 20 + 8 + 18).
check_pcap.py finds these frames in the exported pcapng and checks that every
sequence number arrived exactly once and in order.

Modes:
  raw    send through an AF_PACKET socket (Python standard library). Needs root
         (or CAP_NET_RAW). Python paces to ~100-300 kframes/s at best: use it
         for functional tests, not for line rate.
  scapy  same frames, sent with scapy's sendp() (if scapy is installed). Root.
  pcap   write the frames to a classic pcap file, no root needed; replay it at
         line rate with tcpreplay, e.g.
             sudo tcpreplay -i eth0 --topspeed seq64.pcap
             sudo tcpreplay -i eth0 --pps=1488095 seq64.pcap
For line rate from a Linux host or from the board use the kernel packet
generator instead: board_pktgen.sh (works on the host too); check_pcap.py
understands pktgen's sequence numbers.

Every mode writes a JSON summary (--summary, default <stream>.sent.json next to
the output, or ./sent.json) for check_pcap.py --sent.

Examples:
  sudo ./gen_seq.py --mode raw -i eth0 --size 64 --count 100000 --rate 50000
  ./gen_seq.py --mode pcap -o seq1518.pcap --size 1518 --count 1000000
  ./check_pcap.py capture.pcapng --sent sent.json --interface P1
"""

import argparse
import json
import os
import socket
import struct
import sys
import time

FCS_LEN = 4
MAGIC = b"PRSQ"


def mac_bytes(s):
    b = bytes(int(x, 16) for x in s.split(":"))
    if len(b) != 6:
        raise ValueError(s)
    return b


def iface_mac(ifname):
    try:
        with open(f"/sys/class/net/{ifname}/address") as f:
            return f.read().strip()
    except OSError:
        return "02:00:00:00:00:01"


def ip_checksum(h):
    s = sum(struct.unpack(f"!{len(h) // 2}H", h))
    s = (s >> 16) + (s & 0xFFFF)
    s += s >> 16
    return (~s) & 0xFFFF


class FrameBuilder:
    """Pre-builds the headers; frame(seq) only patches the sequence number."""

    def __init__(self, size, dst, src, src_ip, dst_ip, sport, dport, stream, vlan=None):
        l2 = dst + src
        if vlan is not None:
            l2 += struct.pack("!HH", 0x8100, vlan & 0x0FFF)
        l2 += struct.pack("!H", 0x0800)
        payload_len = size - FCS_LEN - len(l2) - 20 - 8
        if payload_len < 16:
            raise SystemExit(f"gen_seq: --size {size} too small (min {size - payload_len + 16})")
        ip = struct.pack("!BBHHHBBH4s4s", 0x45, 0, 20 + 8 + payload_len, 0, 0x4000, 64, 17, 0,
                         socket.inet_aton(src_ip), socket.inet_aton(dst_ip))
        ip = ip[:10] + struct.pack("!H", ip_checksum(ip)) + ip[12:]
        udp = struct.pack("!HHHH", sport, dport, 8 + payload_len, 0)
        self.prefix = l2 + ip + udp + MAGIC + struct.pack("!I", stream)
        self.suffix = bytes(payload_len - 16)
        self.size = size

    def frame(self, seq):
        return self.prefix + struct.pack("!Q", seq) + self.suffix


def write_pcap(path, fb, first, count, rate):
    gap_ns = int(1e9 / rate) if rate else (fb.size + 20) * 8   # line rate at 1 Gb/s
    with open(path, "wb") as f:
        f.write(struct.pack("<IHHiIII", 0xA1B23C4D, 2, 4, 0, 0, 65535, 1))  # ns pcap
        t = 0
        for i in range(count):
            fr = fb.frame(first + i)
            f.write(struct.pack("<IIII", t // 10 ** 9, t % 10 ** 9, len(fr), len(fr)))
            f.write(fr)
            t += gap_ns


def send_raw(ifname, fb, first, count, rate, batch=64):
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW)
    s.bind((ifname, 0))
    t0 = time.monotonic()
    sent = 0
    for i in range(count):
        s.send(fb.frame(first + i))
        sent += 1
        if rate and sent % batch == 0:
            due = t0 + sent / rate
            d = due - time.monotonic()
            if d > 0:
                time.sleep(d)
    el = time.monotonic() - t0
    return sent, el


def send_scapy(ifname, fb, first, count, rate):
    try:
        from scapy.all import sendp  # type: ignore
    except ImportError:
        raise SystemExit("gen_seq: scapy is not installed (pip install scapy), use --mode raw")
    t0 = time.monotonic()
    frames = (fb.frame(first + i) for i in range(count))
    sendp(list(frames), iface=ifname, inter=(1.0 / rate) if rate else 0, verbose=False)
    return count, time.monotonic() - t0


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter,
                                 epilog=__doc__[__doc__.index("Modes:"):])
    ap.add_argument("--mode", choices=["raw", "scapy", "pcap"], default="raw")
    ap.add_argument("-i", "--interface", help="egress interface (raw, scapy)")
    ap.add_argument("-o", "--output", help="pcap file to write (pcap mode)")
    ap.add_argument("--size", type=int, default=64,
                    help="frame size on the wire incl. FCS, 64..1518 (default 64)")
    ap.add_argument("--count", type=int, default=1000)
    ap.add_argument("--rate", type=float, default=0,
                    help="frames/s (0 = as fast as possible; pcap: timestamps at 1G line rate)")
    ap.add_argument("--first", type=int, default=0, help="first sequence number")
    ap.add_argument("--stream", type=int, default=1, help="stream id (u32)")
    ap.add_argument("--dst-mac", default="ff:ff:ff:ff:ff:ff",
                    help="destination MAC (default broadcast)")
    ap.add_argument("--src-mac", help="source MAC (default: the interface's)")
    ap.add_argument("--src-ip", default="192.0.2.1")
    ap.add_argument("--dst-ip", default="192.0.2.2")
    ap.add_argument("--sport", type=int, default=50000)
    ap.add_argument("--dport", type=int, default=50001)
    ap.add_argument("--vlan", type=int, help="add an 802.1Q tag with this VLAN id")
    ap.add_argument("--summary", help="JSON summary path (default sent.json)")
    a = ap.parse_args()

    if not 64 <= a.size <= (1522 if a.vlan is not None else 1518):
        ap.error("--size must be 64..1518 (1522 with --vlan)")
    if a.mode in ("raw", "scapy") and not a.interface:
        ap.error("--interface is required for raw and scapy modes")
    if a.mode == "pcap" and not a.output:
        ap.error("--output is required for pcap mode")
    src = a.src_mac or (iface_mac(a.interface) if a.interface else "02:00:00:00:00:01")
    fb = FrameBuilder(a.size, mac_bytes(a.dst_mac), mac_bytes(src), a.src_ip, a.dst_ip,
                      a.sport, a.dport, a.stream, a.vlan)

    if a.mode == "pcap":
        write_pcap(a.output, fb, a.first, a.count, a.rate)
        sent, el = a.count, 0.0
        print(f"gen_seq: wrote {a.count} frames of {a.size} B to {a.output}")
    else:
        if os.geteuid() != 0:
            print("gen_seq: warning: not root; sending raw frames needs CAP_NET_RAW",
                  file=sys.stderr)
        if a.mode == "raw":
            sent, el = send_raw(a.interface, fb, a.first, a.count, a.rate)
        else:
            sent, el = send_scapy(a.interface, fb, a.first, a.count, a.rate)
        print(f"gen_seq: sent {sent} frames of {a.size} B on {a.interface} in {el:.3f} s "
              f"({sent / el if el else 0:.0f} frames/s, "
              f"{sent * a.size * 8 / el / 1e6 if el else 0:.1f} Mb/s)")

    summary = {"generator": "gen_seq.py", "mode": a.mode, "interface": a.interface,
               "output": a.output, "size": a.size, "rate_pps": a.rate, "vlan": a.vlan,
               "seconds": round(el, 6), "time": time.time(),
               "streams": [{"key": f"prsq:{a.stream}", "first": a.first, "count": sent}]}
    path = a.summary or "sent.json"
    with open(path, "w") as f:
        json.dump(summary, f, indent=1)
    print(f"gen_seq: summary in {path}")


if __name__ == "__main__":
    main()
