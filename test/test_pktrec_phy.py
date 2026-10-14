#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""test_pktrec_phy.py - host test of sw/pktrec-tools/pktrec-phy (no hardware).

  test/test_pktrec_phy.py [-v]

The registers, the MDIO master and four DP83867s are replaced by a model: a PHY
has copper link when its cable is plugged, it is neither powered down (BMCR[11])
nor in MII loopback (BMCR[14]), and auto-negotiation (0.4 s) has finished after
a power-up / loopback release / AN restart. Like the OP080, P0's PHY clocks
P1-P3: if P0 is ever powered down, P1-P3 lose link and MDIO reads return 0xffff.

1. P0 guard: BMCR[11] and IO_MUX_CFG 0x0170 writes to P0 are refused (API and
   the 'mdio' command); other PHYs / registers are not affected.
2. watch, link propagation in TAP mode via MII loopback (real time, ~20 s):
   P1 unplugged -> P0 held in loopback within the debounce, P2/P3 untouched,
   no BMCR[11] write anywhere; P1 back -> P0 released (loopback cleared, AN
   restart, SGMII re-trigger); P0 unplugged -> P1 held; both unplugged then one
   back (one grace-long flap, then stable, no ping-pong); pair -> monitor
   releases; exit releases; state file lists the held ports.
3. watch restart: a hold recorded in phy-watch.json is released, a hand-set
   loopback on another port is left alone, a power-down left by an older watch
   is cleared.
4. 0x0055 RX correction: link-up with 0x0055 = 0x0111 -> RX_OFFSET = base - 8;
   apply-calibration writing a new base -> adopted, correction re-applied;
   link-up with 0x0055 = 0 -> base; --no-0055-correction leaves RX_OFFSET alone.
5. gen: size + rand mask beyond TX_MAX_LEN + 1 (1518) refused, --force sends.
Exit 0 when every check passed.
"""

import argparse
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import time
import _thread

HERE = os.path.dirname(os.path.realpath(__file__))
TOOL = os.path.normpath(os.path.join(HERE, "..", "sw", "pktrec-tools", "pktrec-phy"))
FAILS = []
VERBOSE = False
RUN = tempfile.mkdtemp(prefix="pktrec-phy-test-")
os.environ["PKTREC_RUN_DIR"] = RUN


def check(cond, what):
    print(f"  {'PASS' if cond else 'FAIL'}  {what}")
    if not cond:
        FAILS.append(what)
    return cond


def load_tool():
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("pktrec_phy", TOOL)
    spec = importlib.util.spec_from_loader("pktrec_phy", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


m = load_tool()
m.Board.MDIO_LOCK = os.path.join(RUN, "pktrec-mdio.lock")
NEG = 0.4


class World:
    def __init__(self):
        self.cable = [True] * 4
        self.phy = {a: {0x00: 0x1140, 0x01: 0x796d, 0x02: 0x2000, 0x03: 0xA231, 0x14: 0x29c7,
                        0x0A: 0x0000, m.SKEW_FIFO_STS: 0} for a in m.PHY_ADDR}
        self.up_at = [0.0] * 4
        self.writes = []                     # (phy, reg, value) of every MDIO write
        self.reg55_next = {}                 # port -> value 0x0055 takes at its next link-up

    def p0_clock(self):
        return not self.phy[m.PHY_ADDR[0]][0] & 0x0800

    def link(self, n):
        bm = self.phy[m.PHY_ADDR[n]][0]
        if bm & 0x4800 or not self.cable[n] or (n and not self.p0_clock()):
            return False
        return time.monotonic() >= self.up_at[n]

    def replug(self, n):
        self.cable[n] = True
        self.renegotiate(n)

    def renegotiate(self, n):
        self.up_at[n] = time.monotonic() + NEG
        if n in self.reg55_next:
            self.phy[m.PHY_ADDR[n]][m.SKEW_FIFO_STS] = self.reg55_next.pop(n)


W = World()


class FakeRegs:
    def __init__(self, base, size, devmem=False):
        self.base, self.r, self.src = base, {}, "mock"
        self.ext = None                      # extended register address (REGCR/ADDAR)
        if base == m.ETH_BASE:
            self.r[m.ETH_ID] = m.ETH_ID_VALUE
            for n in range(4):
                self.r[m.ETH_PORT_BASE + n * m.ETH_PORT_STRIDE + m.P_TX_MAX_LEN] = 1517
        elif base == m.M0_BASE:
            self.r[m.M0_ID] = m.M0_ID_VALUE
            self.r[m.M0_VERSION] = 0x00010003
        elif base == m.CAP_BASE:
            self.r[0] = m.CAP_ID_VALUE
            self.r[4] = 0x00010002
            for n in range(4):
                self.r[m.SFD_PORT_BASE + n * m.SFD_PORT_STRIDE + 0x38] = (-234) & 0xFFFFFFFF
        self.rdata = 0

    def rd(self, off):
        if self.base == m.ETH_BASE:
            if off == m.ETH_MDIO_STATUS:
                return 0x2
            if off == m.ETH_MDIO_RDATA:
                return self.rdata
            if off >= 0x100 and (off - 0x100) % 0x40 == m.P_STATUS:
                n = (off - 0x100) // 0x40
                return (0x800 | 0x20 | (2 << 6) | 0x100) if W.link(n) else 0
        if self.base == m.M0_BASE and off == m.M0_EFF_PATH:
            return self.r.get(m.M0_PATH_CTRL, 0)
        return self.r.get(off, 0)

    def wr(self, off, val):
        if self.base == m.ETH_BASE and off == m.ETH_MDIO_CMD:
            op, a, reg, d = (val >> 28) & 3, (val >> 23) & 0x1F, (val >> 18) & 0x1F, val & 0xFFFF
            n = m.PHY_ADDR.index(a)
            dead = n and not W.p0_clock()
            if op == 1:
                if dead:
                    return
                if reg == m.REGCR:
                    self.ext_mode = d
                    return
                if reg == m.ADDAR and getattr(self, "ext_mode", 0) == 0x001F:
                    self.ext = d
                    return
                if reg == m.ADDAR and getattr(self, "ext_mode", 0) == 0x401F:
                    reg = self.ext
                W.writes.append((a, reg, d))
                old = W.phy[a].get(reg, 0)
                W.phy[a][reg] = d & ~0x0200 if reg == 0 else d        # AN restart self-clears
                if reg == 0 and ((old & 0x4800) and not (d & 0x4800) or d & 0x0200):
                    W.renegotiate(n)
            else:
                if dead:
                    self.rdata = 0xFFFF
                    return
                if reg == m.ADDAR and getattr(self, "ext_mode", 0) == 0x401F:
                    reg = self.ext
                v = W.phy[a].get(reg, 0)
                if reg == m.PHYSTS:
                    v = (0x0400 | 0x8000 | 0x2000) if W.link(n) else 0
                if reg == m.BMSR:
                    v = 0x796d | (4 if W.link(n) else 0)
                self.rdata = v
            return
        self.r[off] = val & 0xFFFFFFFF


m.Regs = FakeRegs
BOARD = m.Board()
CAP = BOARD.cap


class B2(m.Board):
    def __new__(cls, devmem=False):
        return BOARD

    def __init__(self, devmem=False):
        pass


m.Board = B2


def run(argv):
    sys.argv = ["pktrec-phy"] + argv
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        try:
            m.main()
        except SystemExit as e:
            print("EXIT:", e)
    if VERBOSE:
        print("        $ pktrec-phy " + " ".join(argv))
        for line in out.getvalue().splitlines():
            print("        " + line)
    return out.getvalue()


def rx_offset(n):
    return m.s32(CAP.rd(m.SFD_PORT_BASE + n * m.SFD_PORT_STRIDE + 0x38))


def bm(n):
    return W.phy[m.PHY_ADDR[n]][0]


def test_guard():
    print("P0 guard")
    for reg, val in ((m.BMCR, 0x1940), (m.BMCR, 0x0800), (m.IO_MUX_CFG, 0x0000)):
        try:
            BOARD.mdio_wr(m.PHY_ADDR[0], reg, val)
            ok = False
        except RuntimeError as e:
            ok = "refused" in str(e)
        check(ok, f"mdio_wr(P0, 0x{reg:04x}, 0x{val:04x}) refused")
    out = run(["mdio", "p0", "0", "0x1940"])
    check("refused" in out and not W.phy[1][0] & 0x0800, "'mdio p0 0 0x1940' refused, P0 still powered")
    out = run(["mdio", "1", "0x170", "0x0"])
    check("refused" in out, "'mdio 1 0x170 0' (P0 by address, IO_MUX_CFG) refused")
    BOARD.mdio_wr(m.PHY_ADDR[0], m.BMCR, 0x5140)        # loopback on P0 is fine
    check(bm(0) == 0x5140, "P0 MII loopback write allowed")
    BOARD.mdio_wr(m.PHY_ADDR[0], m.BMCR, 0x1140)
    BOARD.mdio_wr(m.PHY_ADDR[2], m.BMCR, 0x1940)        # other PHYs: not guarded
    check(bm(2) & 0x0800, "BMCR[11] on P2 is not blocked by the P0 guard")
    BOARD.mdio_wr(m.PHY_ADDR[2], m.BMCR, 0x1140)
    W.renegotiate(2)


def watch_scenario(script, argv, total):
    """Run 'pktrec-phy watch' in the main thread while `script` drives the world."""
    log = []

    def world():
        t0 = time.monotonic()
        for t, what, fn in script:
            time.sleep(max(0, t - (time.monotonic() - t0)))
            log.append((round(time.monotonic() - t0, 2), "##", what))
            fn()
        time.sleep(max(0, total - (time.monotonic() - t0)))
        _thread.interrupt_main()
    W.writes.clear()
    th = threading.Thread(target=world, daemon=True)
    th.start()
    out = run(["watch", "--interval", "0.05", "--json"] + argv)
    th.join()
    ev = []
    for line in out.splitlines():
        try:
            ev.append(json.loads(line))
        except ValueError:
            pass
    if VERBOSE:
        for x in log:
            print("        ", *x)
    return ev, out


def test_propagation():
    print("watch: link propagation in TAP mode via MII loopback (real time)")
    run(["mode", "0", "tap"])
    S = {}
    script = [
        (1.0, "unplug P1", lambda: W.cable.__setitem__(1, False)),
        (1.8, "snapshot p1_down", lambda: S.__setitem__(
            "p1_down", ([bm(n) for n in range(4)], [W.link(n) for n in range(4)],
                        BOARD.mdio_rd(m.PHY_ADDR[2], m.PHYIDR1)))),
        (2.5, "replug P1", lambda: W.replug(1)),
        (4.0, "snapshot p1_up", lambda: S.__setitem__("p1_up", ([bm(n) for n in range(4)],
                                                                [W.link(n) for n in range(4)]))),
        (5.0, "unplug P0", lambda: W.cable.__setitem__(0, False)),
        (6.0, "snapshot p0_down", lambda: S.__setitem__("p0_down", [bm(n) for n in range(4)])),
        (6.5, "unplug P1 too", lambda: W.cable.__setitem__(1, False)),
        (8.0, "replug P0 only", lambda: W.replug(0)),
        (12.0, "snapshot both", lambda: S.__setitem__("both", [bm(n) for n in range(4)])),
        (12.5, "replug P1", lambda: W.replug(1)),
        (15.0, "snapshot healed", lambda: S.__setitem__("healed", ([bm(n) for n in range(4)],
                                                                  [W.link(n) for n in range(4)]))),
        (15.5, "unplug P1, then pair 0 -> monitor", lambda: W.cable.__setitem__(1, False)),
        (16.5, "pair 0 monitor", lambda: BOARD.write_path(0)),
        (17.5, "snapshot monitor", lambda: S.__setitem__("monitor", [bm(n) for n in range(4)])),
        (18.0, "pair 0 tap, P1 still unplugged", lambda: BOARD.write_path(0x0A)),
        (20.0, "snapshot before exit", lambda: S.__setitem__("pre_exit", [bm(n) for n in range(4)])),
    ]
    ev, out = watch_scenario(script, ["--debounce", "0.2", "--grace", "1.5"], 21.0)
    pd = [w for w in W.writes if w[1] == m.BMCR and w[2] & 0x0800]
    check(not pd, f"no BMCR[11] power-down written to any PHY ({len(pd)})")
    st = json.load(open(os.path.join(RUN, "phy-watch.json")))
    bmcr, links, id2 = S["p1_down"]
    check(bmcr[0] & 0x4000 and not bmcr[1] & 0x4800, "P1 down -> P0 held in MII loopback, P1 untouched")
    check(links[2] and links[3] and id2 == 0x2000, "P2/P3 links stay up, MDIO alive (P2 PHYIDR1 0x2000)")
    holds = [e for e in ev if e["event"] == "hold"]
    check(holds and holds[0]["port"] == 0, "first hold event is P0 (reason P1 link down)")
    bmcr, links = S["p1_up"]
    check(not bmcr[0] & 0x4000 and all(links), "P1 back -> P0 released, all four links up")
    rel = [e for e in ev if e["event"] == "release"]
    check(rel and rel[0]["port"] == 0 and rel[0]["recheck_ok"], "release logged with BMCR re-check ok")
    an = [w for w in W.writes if w[0] == m.PHY_ADDR[0] and w[1] == m.BMCR and w[2] & 0x0200]
    check(an, "release restarts auto-negotiation (BMCR[9])")
    check(S["p0_down"][1] & 0x4000, "P0 down -> P1 held")
    both = S["both"]
    check(both[0] & 0x4000 and not both[1] & 0x4800,
          "both unplugged, P0 replugged: P1 released, found down after its grace, P0 held "
          f"(BMCR P0 0x{both[0]:04x} P1 0x{both[1]:04x}) -- the documented one flap")
    seq = [f"{e['event']} P{e['port']}" for e in ev if e["event"] in ("hold", "release")]
    want = ["hold P0", "release P0", "hold P1", "release P1", "hold P0", "release P0",
            "hold P0", "release P0", "hold P0", "release P0"]
    check(seq == want, "exactly the expected hold/release sequence, no ping-pong: " + ", ".join(seq))
    bmcr, links = S["healed"]
    check(not any(b & 0x4800 for b in bmcr) and all(links), "P1 replugged: everything released, 4 links up")
    check(not any(b & 0x4800 for b in S["monitor"]), "pair -> monitor: hold released")
    check(S["pre_exit"][0] & 0x4000, "back to tap with P1 unplugged: P0 held again")
    check(not any(bm(n) & 0x4800 for n in range(4)) and st["held"] == [],
          "watch exit: every hold released, state file held = []")
    W.replug(1)
    time.sleep(NEG + 0.1)


def test_restart():
    print("watch restart: holds of a previous instance only")
    run(["mode", "0", "tap"])
    W.phy[m.PHY_ADDR[0]][0] = 0x5140                    # left held by the previous watch
    W.phy[m.PHY_ADDR[2]][0] = 0x5140                    # hand-set loopback (pair 1, monitor)
    W.phy[m.PHY_ADDR[1]][0] = 0x1940                    # power-down left by an older watch
    m.write_watch_state({"held": [0], "skew": None})
    ev, out = watch_scenario([], ["--debounce", "0.2", "--grace", "1.0", "--no-0055-correction"], 1.5)
    check(not bm(0) & 0x4000, "P0 (recorded hold) released at start")
    check(bm(2) & 0x4000, "P2 hand-set loopback left alone")
    check(not bm(1) & 0x0800, "P1 power-down from an older watch cleared")
    W.phy[m.PHY_ADDR[2]][0] = 0x1140
    for n in range(4):
        W.renegotiate(n)
    time.sleep(NEG + 0.1)
    run(["mode", "0", "monitor"])


def test_skew():
    print("0x0055 RX correction after each link-up")
    for n in range(4):
        CAP.wr(m.SFD_PORT_BASE + n * m.SFD_PORT_STRIDE + 0x38, -234)
    try:
        os.unlink(os.path.join(RUN, "phy-watch.json"))
    except OSError:
        pass
    S = {}
    W.phy[m.PHY_ADDR[2]][m.SKEW_FIFO_STS] = 0x0111       # this link-up: master, +8 ns
    W.phy[m.PHY_ADDR[2]][0x0A] = 0x4000

    def apply_cal():
        for n in range(4):
            CAP.wr(m.SFD_PORT_BASE + n * m.SFD_PORT_STRIDE + 0x38, -230)

    def bounce2():
        W.reg55_next[2] = 0x0000
        W.cable[2] = False
    script = [
        (2.0, "snapshot", lambda: S.__setitem__("start", [rx_offset(n) for n in range(4)])),
        (2.2, "apply-calibration writes -230", apply_cal),
        (2.6, "snapshot", lambda: S.__setitem__("cal", [rx_offset(n) for n in range(4)])),
        (2.8, "P2 bounce (next 0x0055 = 0)", bounce2),
        (3.3, "P2 replug", lambda: W.replug(2)),
        (5.5, "snapshot", lambda: S.__setitem__("bounce", [rx_offset(n) for n in range(4)])),
    ]
    ev, out = watch_scenario(script, ["--no-propagate"], 6.0)
    check(S["start"] == [-234, -234, -242, -234], f"P2 0x0055 = 0x0111 -> RX_OFFSET {S['start']}")
    sk = [e for e in ev if e["event"] == "rx_skew" and e["port"] == 2]
    check(sk and sk[0]["reg55"] == 0x0111 and sk[0]["master"] and sk[0]["corr"] == -8,
          "logged: reg55 0x0111, master, corr -8")
    check(S["cal"] == [-230, -230, -238, -230], f"new base adopted, correction re-applied {S['cal']}")
    check(S["bounce"][2] == -230, f"P2 link-up with 0x0055 = 0 -> base {S['bounce'][2]}")
    st = json.load(open(os.path.join(RUN, "phy-watch.json")))
    check(st["skew"][2]["base"] == -230 and st["skew"][2]["corr"] == 0, "state file: base / corr")
    # correction off
    W.phy[m.PHY_ADDR[2]][m.SKEW_FIFO_STS] = 0x1011
    ev, out = watch_scenario([], ["--no-propagate", "--no-0055-correction"], 2.0)
    check(rx_offset(2) == -230 and not [e for e in ev if e["event"] == "rx_skew"],
          "--no-0055-correction: RX_OFFSET untouched")


def test_gen():
    print("gen: frames beyond TX_MAX_LEN")
    out = run(["gen", "2", "start", "--size", "64", "--rand-mask", "0x5ff", "--count", "10"])
    g = m.GEN_BASE + 2 * m.GEN_STRIDE
    check("EXIT" in out and "1599" in out and not BOARD.m0.rd(g + m.G_CTRL) & 1,
          "size 64 + mask 0x5ff (up to 1599 B) refused, generator not started")
    out = run(["gen", "2", "start", "--size", "64", "--rand-mask", "0x5ff", "--count", "10", "--force"])
    check("WARNING" in out and BOARD.m0.rd(g + m.G_CTRL) & 1, "--force: warned and started")
    out = run(["gen", "2", "start", "--size", "64", "--rand-mask", "0x3ff", "--count", "10"])
    check("EXIT" not in out and "WARNING" not in out, "64 + 0x3ff (up to 1087 B): no warning")
    out = run(["gen", "2", "start", "--size", "1519", "--count", "10"])
    check("EXIT" in out, "--size 1519 refused")
    run(["gen", "2", "stop"])


def main():
    global VERBOSE
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("-v", "--verbose", action="store_true")
    VERBOSE = ap.parse_args().verbose
    test_guard()
    test_propagation()
    test_restart()
    test_skew()
    test_gen()
    print(f"\n{'ALL PASSED' if not FAILS else str(len(FAILS)) + ' FAILED'}")
    for f in FAILS:
        print("  FAILED: " + f)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
