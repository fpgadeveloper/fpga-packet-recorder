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
Throughout, the model checks the loop-safety invariant on every register write:
no BMCR[14] is set on a port whose PATH_CTRL is not idle, and no PATH_CTRL write
selects a non-idle path into a port whose PHY is in loopback (except the cases
run with --i-accept-lan-loop).

1. P0 guard: BMCR[11] and IO_MUX_CFG 0x0170 writes to P0 are refused (API and
   the 'mdio' command); other PHYs / registers are not affected.
2. watch, link propagation in TAP mode (real time, ~21 s): P1 unplugged -> P0
   held: path 0 idle FIRST, then MII loopback; P2/P3 untouched; P1 back -> P0
   released: loopback cleared + AN restart, SGMII re-trigger, THEN path 0 fwd;
   P0 unplugged -> P1 held by power-down (P2/P3 and MDIO alive); never a
   power-down on P0; both unplugged then one back (one grace-long flap, then
   stable, no ping-pong); pair -> monitor releases; exit releases and restores
   PATH_CTRL 0x0A; state file lists the held ports.
2b. pair 1: 'test linkdown 3' (P3 power-down) -> P2 held by power-down;
   'test linkup 3' -> P2 released.
3. watch restart: holds recorded in phy-watch.json are released (P0 loopback
   -> path 0 fwd restored; P1 power-down cleared), a hand-set loopback and a
   hand-set power-down elsewhere are left alone.
3b. loop safety: mdio BMCR[14] refused on a port that is forwarded into / in a
   TAP pair (--force is no override, --i-accept-lan-loop is, with a warning),
   refused on the LAN pair in every mode (pair 0 monitor + 'mdio p1 0 0x5140'
   -> refused, BMCR unchanged; internal phy_loopback too) and allowed on an
   idle pair-1 port; mode tap / path fwd refused into a looped PHY (also
   with --force); path loop refused in a TAP pair, on a looped PHY and on the
   LAN pair; gen refused on a looped port; test linkdown refused on P0/P1,
   P3 = power-down, P0 with the override = path idle then loopback, linkup
   restores fwd; 'safe' flags the incident state (exit 2) and passes otherwise;
   status --json reports phy_loopback / phy_powered_down.
4. 0x0055 RX correction: master link-up with 0x0055 = 0x0111 -> RX_OFFSET =
   base - 8; apply-calibration writing a new base -> adopted, correction
   re-applied; link-up with 0x0055 = 0 -> base; slave with 0x0055 = 0x0001 ->
   base, logged "on slave, not corrected"; --no-0055-correction leaves
   RX_OFFSET alone.
5. gen: size + rand mask beyond TX_MAX_LEN + 1 (1522) refused, --force sends;
   --vlan writes GEN_VLAN (EN | PCP | VID), a plain start clears it, --size 1522
   --vlan 100 accepted; maxlen --set 2000 writes RX/TX_MAX_LEN 1999 and raises
   IFG_LO/HI (2526/3550), --set 1522 leaves raised thresholds alone.
6. sfd config --mac-offset writes MAC_OFFSET.
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
        self.events = []                     # ("mdio", phy, reg, value) / ("path", PATH_CTRL)
        self.path = 0                        # PATH_CTRL as last written
        self.violations = []                 # loop-safety invariant broken (see docstring)
        self.allow = False                   # --i-accept-lan-loop cases
        self.reg55_next = {}                 # port -> value 0x0055 takes at its next link-up
        self.selfcable = False               # P2<->P3 cabled to each other (the bench)

    def p0_clock(self):
        return not self.phy[m.PHY_ADDR[0]][0] & 0x0800

    def link(self, n):
        bm = self.phy[m.PHY_ADDR[n]][0]
        if bm & 0x4800 or not self.cable[n] or (n and not self.p0_clock()):
            return False
        if self.selfcable and n in (2, 3):  # the peer PHY is the link partner
            if self.phy[m.PHY_ADDR[5 - n]][0] & 0x4800:
                return False
            return time.monotonic() >= max(self.up_at[n], self.up_at[5 - n])
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
                self.r[m.ETH_PORT_BASE + n * m.ETH_PORT_STRIDE + m.P_TX_MAX_LEN] = 1521
                self.r[m.ETH_PORT_BASE + n * m.ETH_PORT_STRIDE + m.P_RX_MAX_LEN] = 1521
        elif base == m.M0_BASE:
            self.r[m.M0_ID] = m.M0_ID_VALUE
            self.r[m.M0_VERSION] = 0x00010004
            for n in range(4):
                self.r[m.M0_PORT_BASE + n * m.M0_PORT_STRIDE + m.P_IFG_THRESH] = 0x08000C00
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
                W.events.append(("mdio", a, reg, d))
                old = W.phy[a].get(reg, 0)
                if reg == 0 and d & 0x4000 and not old & 0x4000 and (W.path >> (2 * n)) & 3 \
                        and not W.allow:
                    W.violations.append(f"BMCR[14] set on P{n} with PATH_CTRL 0x{W.path:02x}")
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
        if self.base == m.M0_BASE and off == m.M0_PATH_CTRL:
            W.path = val & 0xFF
            W.events.append(("path", W.path))
            for n in range(4):
                if (W.path >> (2 * n)) & 3 and W.phy[m.PHY_ADDR[n]][0] & 0x4000 and not W.allow:
                    W.violations.append(f"PATH_CTRL 0x{W.path:02x} sends into looped P{n}")
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
    W.events.clear()
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
    print("watch: link propagation in TAP mode (P0 path idle + loopback, P1 power-down; real time)")
    run(["mode", "0", "tap"])
    S = {}
    script = [
        (1.0, "unplug P1", lambda: W.cable.__setitem__(1, False)),
        (1.8, "snapshot p1_down", lambda: S.__setitem__(
            "p1_down", ([bm(n) for n in range(4)], [W.link(n) for n in range(4)],
                        BOARD.mdio_rd(m.PHY_ADDR[2], m.PHYIDR1), W.path,
                        BOARD.m0.rd(m.M0_PAIR_MODE)))),
        (2.5, "replug P1", lambda: W.replug(1)),
        (4.0, "snapshot p1_up", lambda: S.__setitem__("p1_up", ([bm(n) for n in range(4)],
                                                                [W.link(n) for n in range(4)],
                                                                W.path))),
        (5.0, "unplug P0", lambda: W.cable.__setitem__(0, False)),
        (6.0, "snapshot p0_down", lambda: S.__setitem__(
            "p0_down", ([bm(n) for n in range(4)], [W.link(n) for n in range(4)],
                        BOARD.mdio_rd(m.PHY_ADDR[2], m.PHYIDR1)))),
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
    W.violations.clear()
    ev, out = watch_scenario(script, ["--debounce", "0.2", "--grace", "1.5"], 21.0)
    pd0 = [w for w in W.writes if w[0] == m.PHY_ADDR[0] and w[1] == m.BMCR and w[2] & 0x0800]
    check(not pd0, f"no BMCR[11] power-down ever written to P0 ({len(pd0)})")
    st = json.load(open(os.path.join(RUN, "phy-watch.json")))
    bmcr, links, id2, path, pm = S["p1_down"]
    check(bmcr[0] & 0x4000 and not bmcr[1] & 0x4800, "P1 down -> P0 held in MII loopback, P1 untouched")
    check(path == 0x08 and pm & 3 == 1, f"P0 held: PATH_CTRL 0x{path:02x} (P0 idle, P1 fwd), "
          "PAIR_MODE pair 0 still tap")
    check(links[2] and links[3] and id2 == 0x2000, "P2/P3 links stay up, MDIO alive (P2 PHYIDR1 0x2000)")
    # ordering of the first P0 hold and release
    e = W.events
    i_lb = next(i for i, x in enumerate(e) if x[:3] == ("mdio", 1, 0) and x[3] & 0x4000)
    i_idle = max((i for i, x in enumerate(e[:i_lb]) if x[0] == "path" and not x[1] & 3), default=-1)
    check(i_idle >= 0 and not any(x[0] == "path" and x[1] & 3 for x in e[i_idle:i_lb]),
          "P0 hold ordering: path 0 idle written before BMCR[14]")
    i_clr = next(i for i, x in enumerate(e) if i > i_lb and x[:3] == ("mdio", 1, 0)
                 and not x[3] & 0x4000)
    i_fwd = next((i for i, x in enumerate(e) if i > i_lb and x[0] == "path" and x[1] & 3 == 2), None)
    i_sg = next((i for i, x in enumerate(e) if i > i_clr and x[:3] == ("mdio", 1, m.CFG2)), None)
    check(i_fwd is not None and i_sg is not None and i_clr < i_sg < i_fwd and e[i_clr][3] & 0x0200,
          "P0 release ordering: BMCR[14] cleared + AN restart, SGMII re-trigger, then path 0 fwd")
    check(not e[i_lb][3] & 0x1000 and e[i_clr][3] & 0x1000,
          "P0 hold = loopback WITH AN off (0x4140 drops the copper link, 0x5140 does not: bench D); "
          "release sets AN enable again")
    holds = [e for e in ev if e["event"] == "hold"]
    check(holds and holds[0]["port"] == 0 and "path 0 fwd -> idle" in holds[0]["steps"]
          and holds[0]["steps"][-1] == "BMCR[14] MII loopback P0",
          "hold event logs the steps: " + " -> ".join(holds[0]["steps"] if holds else []))
    bmcr, links, path = S["p1_up"]
    check(not bmcr[0] & 0x4000 and all(links) and path == 0x0A,
          "P1 back -> P0 released, path 0 fwd again (PATH_CTRL 0x0a), all four links up")
    rel = [e for e in ev if e["event"] == "release"]
    check(rel and rel[0]["port"] == 0 and rel[0]["recheck_ok"]
          and rel[0]["steps"][-1] == "path 0 idle -> fwd", "release logged with BMCR re-check ok")
    an = [w for w in W.writes if w[0] == m.PHY_ADDR[0] and w[1] == m.BMCR and w[2] & 0x0200]
    check(an, "release restarts auto-negotiation (BMCR[9])")
    bmcr, links, id2 = S["p0_down"]
    check(bmcr[1] & 0x0800 and not bmcr[1] & 0x4000 and not bmcr[0] & 0x0800,
          f"P0 down -> P1 held by power-down (BMCR 0x{bmcr[1]:04x}), no loopback")
    check(links[2] and links[3] and id2 == 0x2000, "P1 powered down: P2/P3 up, MDIO alive")
    h1 = [e for e in ev if e["event"] == "hold" and e["port"] == 1]
    check(h1 and h1[0]["method"] == "PHY power-down", "P1 hold method logged: PHY power-down")
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
    check(W.path == 0x0A, f"watch exit: PATH_CTRL back to 0x0a (0x{W.path:02x})")
    check(not W.violations, "loop-safety invariant held throughout: " + "; ".join(W.violations[:3]))
    W.replug(1)
    time.sleep(NEG + 0.1)


def test_pair1():
    print("pair 1: test linkdown/linkup P3 (power-down) propagates to P2")
    run(["mode", "1", "tap"])
    S = {}
    script = [
        # what 'test linkdown 3' / 'test linkup 3' write (BMCR[11] set / cleared + AN
        # restart), done in the model: the tool's MDIO lock is per process, not per thread
        (1.0, "P3 power-down (test linkdown 3)", lambda: W.phy[m.PHY_ADDR[3]].__setitem__(0, 0x1940)),
        (2.0, "snapshot down", lambda: S.__setitem__("down", [bm(n) for n in range(4)])),
        (2.2, "P3 power-up (test linkup 3)", lambda: (W.phy[m.PHY_ADDR[3]].__setitem__(0, 0x1140),
                                                     W.renegotiate(3))),
        (3.5, "snapshot up", lambda: S.__setitem__("up", ([bm(n) for n in range(4)],
                                                          [W.link(n) for n in range(4)]))),
    ]
    W.violations.clear()
    ev, out = watch_scenario(script, ["--debounce", "0.2", "--grace", "1.0",
                                      "--no-0055-correction"], 4.0)
    d = S["down"]
    check(d[3] & 0x0800 and d[2] & 0x0800 and not d[2] & 0x4000 and not d[0] & 0x4800,
          f"P3 powered down -> P2 held by power-down (BMCR P2 0x{d[2]:04x}), pair 0 untouched")
    bmcr, links = S["up"]
    check(not any(b & 0x4800 for b in bmcr) and all(links), "P3 back -> P2 released, 4 links up")
    check(W.path == 0x0A | 0xA0 and not W.violations, "PATH_CTRL 0xaa, no invariant violation")
    run(["mode", "1", "monitor"])

def test_pair1_selfcabled():
    print("pair 1 cabled to itself (bench P2<->P3): test linkdown/linkup does not latch")
    run(["mode", "1", "tap"])
    W.selfcable = True
    try:
        for t in (3, 2):
            S = {}
            a = m.PHY_ADDR[t]
            script = [
                (1.0, f"P{t} power-down (test linkdown {t})", lambda: W.phy[a].__setitem__(0, 0x1940)),
                (2.0, "snapshot down", lambda: S.__setitem__("down", [W.link(n) for n in range(4)])),
                (2.2, f"P{t} power-up (test linkup {t})", lambda: (W.phy[a].__setitem__(0, 0x1140),
                                                                   W.renegotiate(t))),
                (3.6, "snapshot up", lambda: S.__setitem__("up", ([bm(n) for n in range(4)],
                                                                  [W.link(n) for n in range(4)]))),
            ]
            ev, out = watch_scenario(script, ["--debounce", "0.2", "--grace", "1.0",
                                              "--no-0055-correction"], 4.0)
            check(S["down"] == [True, True, False, False], f"P{t} powered down -> P2 and P3 down, pair 0 up")
            check(not any(e.get("event") == "hold" for e in ev),
                  "no hold: the partner is already down (holding it would latch the pair)")
            bmcr, links = S["up"]
            check(not any(b & 0x4800 for b in bmcr) and all(links),
                  f"P{t} back -> 4 links up (BMCR {[hex(b) for b in bmcr]})")
    finally:
        W.selfcable = False
    run(["mode", "1", "monitor"])


def test_restart():
    print("watch restart: holds of a previous instance only")
    run(["mode", "0", "tap"])
    BOARD.set_port_path(0, "idle")                      # previous watch: P0 path idle +
    W.phy[m.PHY_ADDR[0]][0] = 0x5140                    # loopback hold
    W.phy[m.PHY_ADDR[1]][0] = 0x1940                    # previous watch: P1 power-down hold
    W.phy[m.PHY_ADDR[2]][0] = 0x5140                    # hand-set loopback (pair 1, monitor)
    W.phy[m.PHY_ADDR[3]][0] = 0x1940                    # hand-set power-down (test linkdown)
    m.write_watch_state({"held": [0, 1], "skew": None})
    ev, out = watch_scenario([], ["--debounce", "0.2", "--grace", "1.0", "--no-0055-correction"], 1.5)
    check(not bm(0) & 0x4000 and W.path == 0x0A, "P0 (recorded hold) released at start, path 0 fwd")
    check(not bm(1) & 0x0800, "P1 (recorded power-down hold) powered up at start")
    check(bm(2) & 0x4000 and bm(3) & 0x0800, "P2 hand-set loopback / P3 hand-set power-down left alone")
    W.phy[m.PHY_ADDR[2]][0] = 0x1140
    W.phy[m.PHY_ADDR[3]][0] = 0x1140
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
    # slave with a non-zero 0x0055 (bench C: P0 0x0001 as slave): logged, never corrected
    W.phy[m.PHY_ADDR[2]][m.SKEW_FIFO_STS] = 0x0001
    W.phy[m.PHY_ADDR[2]][0x0A] = 0x0000
    ev, out = watch_scenario([(0.2, "P2 bounce", lambda: W.renegotiate(2))], ["--no-propagate"], 2.5)
    sk = [e for e in ev if e["event"] == "rx_skew" and e["port"] == 2]
    check(rx_offset(2) == -230 and sk and sk[-1]["reg55"] == 0x0001 and not sk[-1]["master"]
          and sk[-1]["corr"] == 0 and "on slave, not corrected (no measured basis)" in sk[-1]["msg"],
          f"slave, 0x0055 = 0x0001: no correction (RX_OFFSET {rx_offset(2)}), logged")
    st = json.load(open(os.path.join(RUN, "phy-watch.json")))
    check(st["skew"][2]["corr"] == 0 and st["skew"][2]["master"] is False,
          "phy-watch.json: slave P2 corr 0")
    W.phy[m.PHY_ADDR[2]][0x0A] = 0x4000
    # correction off
    W.phy[m.PHY_ADDR[2]][m.SKEW_FIFO_STS] = 0x1011
    ev, out = watch_scenario([], ["--no-propagate", "--no-0055-correction"], 2.0)
    check(rx_offset(2) == -230 and not [e for e in ev if e["event"] == "rx_skew"],
          "--no-0055-correction: RX_OFFSET untouched")


def test_safety():
    print("loop safety: refusals, overrides, safe report")
    W.violations.clear()
    a1 = m.PHY_ADDR[1]
    run(["mode", "0", "tap"])
    out = run(["mdio", "p1", "0", "0x5140"])
    check("EXIT" in out and "refused" in out and "TAP" in out and not bm(1) & 0x4000,
          "pair 0 tap: 'mdio p1 0 0x5140' (the incident) refused")
    out = run(["mdio", "p1", "0", "0x5140", "--force"])
    check("EXIT" in out and not bm(1) & 0x4000, "--force is not an override for mdio")
    out = run(["mdio", "3", "0", "0x4140"])            # P1 by MDIO address, other bits
    check("refused" in out and not bm(1) & 0x4000, "same by MDIO address 3")
    out = run(["safe"])
    check("SAFE: no reflecting" in out and "EXIT" not in out, "safe: pair 0 tap, no loopback -> SAFE")
    W.allow = True
    out = run(["mdio", "p1", "0", "0x5140", "--i-accept-lan-loop"])
    check("WARNING" in out and bm(1) & 0x4000, "--i-accept-lan-loop: warned and written")
    out = run(["safe"])
    check("REFLECTION LOOP" in out and "LAN pair" in out and "EXIT: 2" in out,
          "safe flags the incident state (P1 loopback, pair 0 forwarding), exit 2")
    out = run(["safe", "--json"])
    doc = json.loads(out.split("EXIT")[0])
    check(not doc["safe"] and doc["hazards"][0]["port"] == 1 and doc["hazards"][0]["kind"] == "loop",
          "safe --json: hazard P1 kind loop")
    W.allow = False
    BOARD.mdio_wr(a1, 0, 0x1140)
    run(["mode", "0", "monitor"])
    out = run(["mdio", "p1", "0", "0x5140"])           # bench C, fix round 3: the exact case
    check("EXIT" in out and "refused" in out and "LAN pair" in out and bm(1) == 0x1140,
          "pair 0 monitor (paths idle): 'mdio p1 0 0x5140' refused (LAN pair), BMCR p1 unchanged")
    out = run(["mdio", "p0", "0", "0x5140"])
    check("EXIT" in out and "LAN pair" in out and not bm(0) & 0x4000,
          "pair 0 monitor: 'mdio p0 0 0x5140' refused (LAN pair)")
    try:
        BOARD.phy_loopback(1, True)
        ok = False
    except RuntimeError as e:
        ok = "LAN pair" in str(e)
    check(ok and not bm(1) & 0x4000, "internal phy_loopback(P1) refused on the LAN pair")
    run(["mode", "1", "monitor"])
    out = run(["mdio", "p2", "0", "0x5140"])
    check("EXIT" not in out and bm(2) & 0x4000, "pair 1 monitor (paths idle): P2 MII loopback allowed")
    BOARD.mdio_wr(m.PHY_ADDR[2], 0, 0x1140)
    W.renegotiate(2)
    BOARD.mdio_wr(a1, 0, 0x5140)                        # P1 looped behind the tool's back
    st = json.loads(run(["status", "--json"]))
    check(st["ports"][1]["phy_loopback"] is True and st["ports"][2]["phy_loopback"] is False,
          "status --json: phy_loopback per port")
    out = run(["mode", "0", "tap"])
    check("EXIT" in out and "loopback" in out and W.path & 0x0F == 0, "mode 0 tap refused: P1 looped")
    out = run(["mode", "0", "tap", "--force"])
    check("EXIT" in out and W.path & 0x0F == 0, "mode 0 tap --force still refused")
    out = run(["path", "1", "fwd"])
    check("EXIT" in out and W.path & 0x0C == 0, "path 1 fwd into looped P1 refused")
    out = run(["path", "1", "loop"])
    check("EXIT" in out and W.path & 0x0C == 0, "path 1 loop on looped P1 refused")
    BOARD.mdio_wr(a1, 0, 0x1140)
    W.renegotiate(1)
    out = run(["path", "0", "loop"])
    check("EXIT" in out and "LAN pair" in out and W.path & 3 == 0, "path 0 loop refused (LAN pair)")
    W.allow = True
    out = run(["path", "0", "loop", "--i-accept-lan-loop"])
    check("WARNING" in out and W.path & 3 == 1, "path 0 loop --i-accept-lan-loop: warned, set")
    W.allow = False
    run(["path", "0", "idle"])
    run(["mode", "1", "tap"])
    out = run(["path", "2", "loop"])
    check("EXIT" in out and "TAP" in out and (W.path >> 4) & 3 == 2, "path 2 loop in TAP pair 1 refused")
    run(["mode", "1", "monitor"])
    out = run(["path", "2", "loop"])
    check("EXIT" not in out and (W.path >> 4) & 3 == 1, "path 2 loop, pair 1 monitor: allowed")
    out = run(["mdio", "p2", "0", "0x5140"])
    check("EXIT" in out and not bm(2) & 0x4000, "MII loopback on P2 with path loop refused")
    run(["path", "2", "idle"])
    BOARD.mdio_wr(m.PHY_ADDR[3], 0, 0x5140)
    out = run(["gen", "3", "start", "--size", "64", "--count", "1"])
    g = m.GEN_BASE + 3 * m.GEN_STRIDE
    check("EXIT" in out and not BOARD.m0.rd(g + m.G_CTRL) & 1, "gen on looped P3 refused")
    out = run(["gen", "3", "start", "--size", "64", "--count", "1", "--force"])
    check("EXIT" in out and not BOARD.m0.rd(g + m.G_CTRL) & 1, "gen --force on looped P3 still refused")
    BOARD.mdio_wr(m.PHY_ADDR[3], 0, 0x1140)
    W.renegotiate(3)
    print("test linkdown / linkup")
    out = run(["test", "linkdown", "0"])
    check("EXIT" in out and "LAN pair" in out and not bm(0) & 0x4800, "test linkdown 0 refused (LAN pair)")
    out = run(["test", "linkdown", "1"])
    check("EXIT" in out and not bm(1) & 0x4800, "test linkdown 1 refused (LAN pair)")
    run(["mode", "1", "tap"])
    out = run(["test", "linkdown", "3"])
    check("EXIT" not in out and bm(3) & 0x0800 and not bm(3) & 0x4000 and W.path == 0xA0,
          "test linkdown 3: P3 power-down, paths untouched")
    out = run(["test", "linkup", "3"])
    check("EXIT" not in out and not bm(3) & 0x0800 and "AN restart" in out, "test linkup 3: powered up")
    run(["mode", "1", "monitor"])
    run(["mode", "0", "tap"])
    out = run(["test", "linkdown", "0", "--i-accept-lan-loop"])
    check("WARNING" in out and bm(0) & 0x4000 and not bm(0) & 0x0800 and W.path == 0x08,
          "test linkdown 0 --i-accept-lan-loop: path 0 idle, then MII loopback (no power-down)")
    out = run(["safe"])
    check("SAFE" in out and "UNSAFE" not in out, "P0 held the safe way: safe reports no hazard")
    out = run(["test", "linkup", "0"])
    check(not bm(0) & 0x4000 and W.path == 0x0A and "path 0 idle -> fwd" in out,
          "test linkup 0: loopback cleared, path 0 fwd restored")
    run(["mode", "0", "monitor"])
    for n in range(4):
        W.renegotiate(n)
    check(not W.violations, "loop-safety invariant held: " + "; ".join(W.violations[:3]))
    time.sleep(NEG + 0.1)


def test_gen():
    print("gen: frames beyond TX_MAX_LEN")
    out = run(["gen", "2", "start", "--size", "64", "--rand-mask", "0x5ff", "--count", "10"])
    g = m.GEN_BASE + 2 * m.GEN_STRIDE
    check("EXIT" in out and "1599" in out and "1522" in out and not BOARD.m0.rd(g + m.G_CTRL) & 1,
          "size 64 + mask 0x5ff (up to 1599 B) refused, generator not started")
    out = run(["gen", "2", "start", "--size", "64", "--rand-mask", "0x5ff", "--count", "10", "--force"])
    check("WARNING" in out and BOARD.m0.rd(g + m.G_CTRL) & 1, "--force: warned and started")
    out = run(["gen", "2", "start", "--size", "64", "--rand-mask", "0x3ff", "--count", "10"])
    check("EXIT" not in out and "WARNING" not in out, "64 + 0x3ff (up to 1087 B): no warning")
    out = run(["gen", "2", "start", "--size", "1523", "--count", "10"])
    check("EXIT" in out, "--size 1523 refused")
    out = run(["gen", "2", "start", "--size", "1522", "--vlan", "100", "--count", "10"])
    check("EXIT" not in out and "WARNING" not in out and "vlan=100" in out
          and BOARD.m0.rd(g + m.G_VLAN) == (1 << 16) | 100 and BOARD.m0.rd(g + m.G_LEN) == 1518,
          "--size 1522 --vlan 100: GEN_VLAN 0x10064, LEN 1518")
    run(["gen", "2", "start", "--size", "200", "--vlan", "7", "--pcp", "5", "--count", "1"])
    check(BOARD.m0.rd(g + m.G_VLAN) == (1 << 16) | (5 << 13) | 7, "--vlan 7 --pcp 5: TCI 0xa007")
    out = run(["gen", "2", "start", "--size", "64", "--vlan", "7", "--count", "1"])
    check("EXIT" in out and "66" in out, "tagged PRSQ below 66 B refused")
    run(["gen", "2", "start", "--size", "200", "--count", "1"])
    check(BOARD.m0.rd(g + m.G_VLAN) == 0, "untagged start clears GEN_VLAN")
    run(["gen", "2", "stop"])
    print("maxlen")
    e = m.ETH_PORT_BASE + 1 * m.ETH_PORT_STRIDE
    t = m.M0_PORT_BASE + 1 * m.M0_PORT_STRIDE + m.P_IFG_THRESH
    out = run(["maxlen", "1"])
    check("RX 1522 B, TX 1522 B" in out and "LO 2048" in out, "maxlen shows the 1522 B default")
    out = run(["maxlen", "1", "--set", "2000"])
    check(BOARD.eth.rd(e + m.P_RX_MAX_LEN) == 1999 and BOARD.eth.rd(e + m.P_TX_MAX_LEN) == 1999
          and BOARD.m0.rd(t) == (2526 << 16) | 3550,
          "--set 2000: RX/TX_MAX_LEN 1999, IFG_LO/HI 2526/3550")
    out = run(["maxlen", "1", "--set", "1522"])
    check(BOARD.eth.rd(e + m.P_TX_MAX_LEN) == 1521 and BOARD.m0.rd(t) == (2526 << 16) | 3550,
          "--set 1522: limits back, thresholds not lowered")
    out = run(["maxlen", "1", "--set", "70000"])
    check("EXIT" in out, "--set beyond 16383 refused")



def test_sfd_config():
    print("sfd config --mac-offset")
    out = run(["sfd", "config", "--mac-offset", "-418"])
    check(m.s32(CAP.rd(0x0A8)) == -418 and "MAC_OFFSET -418" in out, "MAC_OFFSET written and shown")


def main():
    global VERBOSE
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("-v", "--verbose", action="store_true")
    VERBOSE = ap.parse_args().verbose
    test_guard()
    test_propagation()
    test_pair1()
    test_pair1_selfcabled()
    test_restart()
    test_safety()
    test_skew()
    test_gen()
    test_sfd_config()
    print(f"\n{'ALL PASSED' if not FAILS else str(len(FAILS)) + ' FAILED'}")
    for f in FAILS:
        print("  FAILED: " + f)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
