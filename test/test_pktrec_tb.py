#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""test_pktrec_tb.py - host test of sw/pktrec-tools/pktrec-tb (no hardware).

  test/test_pktrec_tb.py [-v]

1. Controller, in virtual time against a simulated timebase (SimHw): start-up
   from timebase 0 with the M1 bench's -10.4 ppm oscillator and 1 us rms read
   jitter -> locked, frequency estimate, residual drift; no TB_SET/TB_ADJ while
   a capture runs; a 2 s system-clock step (idle) -> one TB_SET and re-lock; a
   5 ms step during a capture -> slewed (<= 200 ppm), never stepped; an INC
   written by someone else is adopted.
   A calibrated INC seeds the controller: no start-up estimate, tracking at once.
2. Calibration file: defaults render/parse round trip, apply -> registers ->
   save round trip, invalid files rejected, wide-window warning; save-calibration
   stores the daemon's frequency only after >= 10 min locked with a stable
   estimate; RX offsets with a live 0x0055 correction are saved as their base.
3. CLI end to end with --sim (real time, a few seconds): status --json, set,
   trim, save/apply/show-calibration, daemon --duration -> /run state file.
Exit 0 when every check passed.
"""

import argparse
import importlib.machinery
import importlib.util
import json
import os
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.realpath(__file__))
TOOL = os.path.normpath(os.path.join(HERE, "..", "sw", "pktrec-tools", "pktrec-tb"))
FAILS = []
VERBOSE = False


def check(cond, what):
    print(f"  {'PASS' if cond else 'FAIL'}  {what}")
    if not cond:
        FAILS.append(what)
    return cond


def load_tool():
    sys.dont_write_bytecode = True
    loader = importlib.machinery.SourceFileLoader("pktrec_tb", TOOL)
    spec = importlib.util.spec_from_loader("pktrec_tb", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class VClock:
    """Virtual time: true_ns advances only by sleep() and by each CLOCK_REALTIME read
    (read_cost); realtime = true + rt_off (a system-clock step changes rt_off)."""

    def __init__(self, t0_ns=1_760_000_000 * 10 ** 9, read_cost=800):
        self.t = float(t0_ns)
        self.rt_off = 0.0
        self.cost = read_cost

    def true_ns(self):
        return self.t

    def realtime_ns(self):
        v = int(self.t + self.rt_off)
        self.t += self.cost
        return v

    def monotonic(self):
        return self.t / 1e9

    def sleep(self, s):
        if s > 0:
            self.t += s * 1e9


def opts(**kw):
    d = dict(interval=1.0, samples=7, kp=0.2, ki=0.02, max_ppm=200.0, estimate=8.0,
             lock_threshold=10000.0, lock_time=30.0, adj_threshold=20000.0, max_adj=1000.0,
             step_threshold=1e9, no_set=False, summary=1e9, verbose=False)
    d.update(kw)
    return argparse.Namespace(**d)


class Quiet:
    def write(self, s):
        if VERBOSE:
            sys.stdout.write("        " + s if s.strip() else s)

    def flush(self):
        pass


def run_for(d, clock, seconds, hook=None):
    t_end = clock.monotonic() + seconds
    while clock.monotonic() < t_end:
        if hook:
            hook(clock.monotonic())
        d.step()
        clock.sleep(d.o.interval)


def test_controller(tb):
    print("controller (virtual time, simulated timebase -10.4 ppm, 1 us rms read jitter)")
    clock = VClock()
    hw = tb.SimHw(-10.4, clock=clock, noise_ns=1000.0, persist=False, seed=7)
    d = tb.Daemon(hw, clock, opts(), out=Quiet(), state_path=None)
    d.startup()
    check([e[1] for e in hw.log if e[1] != "inc"][:1] == ["set"], "start-up: TB_SET from CLOCK_REALTIME")
    t0 = clock.monotonic()
    lock_t = None
    worst_after_lock = 0
    while clock.monotonic() - t0 < 300:
        st = d.step()
        if st["locked"] and lock_t is None:
            lock_t = clock.monotonic() - t0
        if lock_t is not None:
            worst_after_lock = max(worst_after_lock, abs(st["offset_ns"]))
        clock.sleep(1.0)
    st = d.st
    check(lock_t is not None and lock_t < 90, f"locked after {lock_t and round(lock_t)} s (< 90 s)")
    check(st["locked"], "still locked at 300 s")
    check(worst_after_lock < 10000, f"|offset| after lock <= {worst_after_lock} ns (< 10 us)")
    est = st["freq_est_ppb"] / 1e3
    check(abs(est - 10.4) < 0.3, f"frequency estimate {est:+.3f} ppm (oscillator -10.4 -> +10.4 "
          "+- 0.3)")
    # residual drift: true frequency error of the disciplined timebase
    rate = hw.inc_raw() / tb.nominal_inc_raw(hw.dp_clk_hz) * (1 - 10.4e-6)
    check(abs(rate - 1) * 1e6 < 1.0, f"timebase frequency error now {(rate - 1) * 1e6:+.3f} ppm (< 1)")
    sets = [e for e in hw.log if e[1] == "set"]
    check(len(sets) == 2, f"{len(sets)} TB_SET (start-up + after the frequency estimate)")
    check(st["sets"] == 2 and st["steps_detected"] == 0, "no unexpected steps")

    print("capture running: phase corrected through the frequency only")
    n_log = len(hw.log)
    clock.rt_off += 300_000                           # NTP slews the system clock: 300 us
    hw.cap_ctrl = tb.CTRL_ENABLE
    max_ppb = 0
    t1 = clock.monotonic()
    while clock.monotonic() - t1 < 120:
        st = d.step()
        max_ppb = max(max_ppb, abs(st["freq_ppb"]))
        clock.sleep(1.0)
    during = hw.log[n_log:]
    check(not any(e[1] in ("set", "adj") for e in during),
          f"no TB_SET / TB_ADJ during the capture ({len(during)} INC writes only)")
    check(max_ppb <= 200e3 + 1, f"frequency within +-200 ppm (max {max_ppb / 1e3:.1f} ppm)")
    check(abs(st["offset_ns"]) < 10000, f"300 us offset slewed out during the capture "
          f"(now {st['offset_ns']} ns)")
    hw.cap_ctrl = 0

    print("5 ms system-clock step while a capture runs: slewed, never stepped")
    n_log = len(hw.log)
    hw.cap_ctrl = tb.CTRL_ENABLE
    clock.rt_off -= 5_000_000
    t2 = clock.monotonic()
    while clock.monotonic() - t2 < 120:
        st = d.step()
        clock.sleep(1.0)
    during = hw.log[n_log:]
    check(not any(e[1] in ("set", "adj") for e in during), "no TB_SET / TB_ADJ")
    check(st["steps_detected"] == 1, "step detected (integrator frozen for that sample)")
    check(abs(st["offset_ns"]) < 10000, f"recovered by slewing: offset {st['offset_ns']} ns")
    hw.cap_ctrl = 0
    run_for(d, clock, 60)
    check(d.st["locked"], "locked again")

    print("tb-hold file (another timebase user, e.g. replay): no steps while it exists")
    with tempfile.TemporaryDirectory() as td:
        old = tb.RUN_DIR
        tb.RUN_DIR = td
        hold = os.path.join(td, f"tb-hold.{os.getpid()}")
        open(hold, "w").close()
        n_log = len(hw.log)
        clock.rt_off += 3e9
        run_for(d, clock, 5)
        check(not any(e[1] in ("set", "adj") for e in hw.log[n_log:]) and d.st["steps_held"],
              "3 s offset with tb-hold.<own pid>: no TB_SET / TB_ADJ")
        os.unlink(hold)
        open(os.path.join(td, "tb-hold.999999999"), "w").close()   # stale: process gone
        run_for(d, clock, 2)
        check(any(e[1] == "set" for e in hw.log[n_log:]) and not d.st["steps_held"],
              "hold released (stale pid ignored): TB_SET")
        tb.RUN_DIR = old
    run_for(d, clock, 60)
    check(d.st["locked"], "locked again")

    print("2 s system-clock step, idle: TB_SET")
    n_sets = d.st["sets"]
    clock.rt_off += 2e9
    run_for(d, clock, 3)
    check(d.st["sets"] == n_sets + 1 and d.st["last_set_reason"].startswith("offset"),
          f"one TB_SET ({d.st['last_set_reason']})")
    check(not d.st["locked"], "unlocked by the step")
    run_for(d, clock, 60)
    check(d.st["locked"] and abs(d.st["offset_ns"]) < 10000, "re-locked within 60 s")

    print("INC written by someone else (pktrec-tb trim / apply-calibration)")
    hw.set_inc_raw(tb.ppb_to_inc(50e3, hw.dp_clk_hz))
    run_for(d, clock, 1)
    check("adopted" in (d.st["message"] or ""), f"adopted: {d.st['message']}")
    run_for(d, clock, 200)
    check(abs(d.st["freq_est_ppb"] / 1e3 - 10.4) < 0.3 and d.st["locked"],
          f"converged back to {d.st['freq_est_ppb'] / 1e3:+.3f} ppm, locked")

    print("start-up while a capture runs, timebase 0 (> step threshold): waits, then sets")
    clock = VClock()
    hw = tb.SimHw(+30.0, clock=clock, noise_ns=500.0, persist=False, seed=3)
    hw.cap_ctrl = tb.CTRL_ENABLE
    d = tb.Daemon(hw, clock, opts(), out=Quiet(), state_path=None)
    d.startup()
    check(d.st["state"] == "waiting" and not [e for e in hw.log if e[1] != "inc"],
          "no TB_SET / TB_ADJ at start-up, state waiting")
    run_for(d, clock, 10)
    check(not any(e[1] == "set" for e in hw.log), "still no TB_SET while capturing")
    hw.cap_ctrl = 0
    run_for(d, clock, 120)
    check(d.st["locked"] and abs(d.st["freq_est_ppb"] / 1e3 + 30) < 0.3,
          f"after the capture: set, estimated {d.st['freq_est_ppb'] / 1e3:+.3f} ppm, locked")


def test_seeded(tb):
    print("start-up with a calibrated INC (+10.4 ppm for a -10.4 ppm oscillator): seeded")
    clock = VClock()
    hw = tb.SimHw(-10.4, clock=clock, noise_ns=1000.0, persist=False, seed=11)
    hw.set_inc_raw(tb.ppb_to_inc(10.4e3, hw.dp_clk_hz))
    d = tb.Daemon(hw, clock, opts(), out=Quiet(), state_path=None)
    d.startup()
    check(d.st["seeded_from_calibration"] and d.st["state"] == "tracking",
          "seeded_from_calibration, state tracking right after start-up")
    t0 = clock.monotonic()
    lock_t = None
    while clock.monotonic() - t0 < 120:
        st = d.step()
        if st["locked"] and lock_t is None:
            lock_t = clock.monotonic() - t0
        clock.sleep(1.0)
    check(lock_t is not None and lock_t < 45, f"locked after {lock_t and round(lock_t)} s (< 45 s)")
    check(len([e for e in hw.log if e[1] == "set"]) == 1, "one TB_SET (no second one after an estimate)")
    check(abs(d.st["freq_est_ppb"] / 1e3 - 10.4) < 0.3,
          f"estimate stays at the calibration: {d.st['freq_est_ppb'] / 1e3:+.3f} ppm")

    print("save-calibration verdict (>= 10 min locked, estimate stable within 0.5 ppm)")
    o = opts()
    o.stable_window = 600.0
    clock = VClock()
    # 300 ns rms read jitter (the bench measured 40-60 ns rms offsets; 1 us makes the
    # integrator wander +-0.1 ppm; the limit is 0.5 ppm, the default --max-ppm-delta)
    hw = tb.SimHw(-10.4, clock=clock, noise_ns=300.0, persist=False, seed=12)
    hw.set_inc_raw(tb.ppb_to_inc(10.4e3, hw.dp_clk_hz))
    d = tb.Daemon(hw, clock, o, out=Quiet(), state_path=None)
    d.startup()
    run_for(d, clock, 300)
    st = dict(d.st, fresh=True)
    ppb, why = tb.timebase_save_verdict(st, clock.realtime_ns(), 600, 500)
    check(ppb is None and "locked for" in why, f"after 5 min: refused ({why})")
    run_for(d, clock, 420)
    st = dict(d.st, fresh=True)
    ppb, why = tb.timebase_save_verdict(st, clock.realtime_ns(), 600, 500)
    check(ppb is not None and abs(ppb / 1e3 - 10.4) < 0.3, f"after 12 min: {(ppb or 0) / 1e3:+.3f} ppm ({why})")
    check(ppb is not None and "moved" in why and "limit 0.500 ppm" in why, f"movement printed on success ({why})")
    check(st["freq_est_window_s"] >= 590, f"history window {st['freq_est_window_s']} s")
    # bench C (chrony): 0.561 ppm over 600 s -> refused; 0.45 ppm -> accepted
    st2 = dict(st, freq_est_max_ppb=st["freq_est_min_ppb"] + 561)
    ppb, why = tb.timebase_save_verdict(st2, clock.realtime_ns(), 600, 500)
    check(ppb is None and "not stable" in why and "moved 0.561 ppm" in why,
          f"estimate moving 0.561 ppm: refused ({why})")
    st3 = dict(st, freq_est_max_ppb=st["freq_est_min_ppb"] + 450)
    ppb, why = tb.timebase_save_verdict(st3, clock.realtime_ns(), 600, 500)
    check(ppb is not None and "moved 0.450 ppm" in why, f"estimate moving 0.45 ppm: accepted ({why})")
    r = subprocess.run([sys.executable, TOOL, "save-calibration", "--help"], capture_output=True,
                       text=True, timeout=60)
    h = " ".join(r.stdout.split())
    check("ppm (0.5)" in h and "estimate is saved (10)" in h,
          "save-calibration defaults: --max-ppm-delta 0.5, --min-locked 10")
    ppb, why = tb.timebase_save_verdict(dict(st, fresh=False), clock.realtime_ns(), 600, 500)
    check(ppb is None and "not running" in why, "daemon not running: refused")


def test_calibration(tb):
    print("calibration file")
    dflt = tb.cal_defaults()
    text = tb.render_cal(dflt, "test")
    with tempfile.TemporaryDirectory() as td:
        f = os.path.join(td, "calibration.conf")
        with open(f, "w") as fh:
            fh.write(text)
        v, errs = tb.parse_cal(f)
        check(not errs and v == dflt, f"defaults round trip ({len(v)} keys)")
        clock = VClock()
        hw = tb.SimHw(0.0, clock=clock, persist=False)
        mine = dict(dflt)
        mine.update({("timebase", "ppm"): 10.4, ("capture", "mac_offset_ns"): -37,
                     ("sfd", "match"): 0, ("sfd", "rx_window_min_ns"): 250,
                     ("sfd", "rx_window_max_ns"): 550, ("sfd", "min_high_cycles"): 6,
                     ("port3", "rx_offset_ns"): -291, ("port2", "tx_offset_ns"): 4})
        with open(f, "w") as fh:
            fh.write(tb.render_cal(mine, "test"))
        v, errs = tb.parse_cal(f)
        applied, warns, errs2 = tb.apply_cal(hw, v)
        check(not errs and not errs2 and not warns, "custom file applied without errors")
        back = tb.cal_from_regs(hw)
        check(all(back[k] == mine[k] for k in mine if k != ("timebase", "ppm")),
              "registers read back = file (all calibration keys)")
        check(abs(back[("timebase", "ppm")] - 10.4) < 1e-4,
              f"INC -> {back[('timebase', 'ppm')]} ppm")
        check(hw.rd(tb.SFD_CTRL) == 0, "match off -> SFD_CTRL.MATCH_EN = 0")
        with open(f, "w") as fh:
            fh.write("[sfd]\nrx_window_min_ns = 700\nrx_window_max_ns = 100\nbogus = 1\n"
                     "min_low_cycles = 300\n[timebase]\nppm = 1\nppb = 2\n")
        v, errs = tb.parse_cal(f)
        check(len(errs) == 4, f"invalid file: {len(errs)} errors ({'; '.join(errs)})")
        with open(f, "w") as fh:
            fh.write("[sfd]\nrx_window_min_ns = 0\nrx_window_max_ns = 800\n[timebase]\nppm = 500\n")
        v, errs = tb.parse_cal(f)
        applied, warns, errs2 = tb.apply_cal(hw, v)
        check(len(warns) == 1 and "wide" in warns[0], "window >= 672 ns warned")
        check(len(errs2) == 1 and "timebase.ppm" not in applied, "500 ppm refused")
        # 0x0055: pktrec-phy watch corrects port2 by -8 ns: the base is saved
        old = tb.RUN_DIR
        tb.RUN_DIR = td
        hw.wr(tb.SFD_PORT_BASE + 2 * tb.SFD_PORT_STRIDE + tb.SFD_P_RX_OFFSET, -242)
        with open(os.path.join(td, "phy-watch.json"), "w") as fh:
            json.dump({"skew": [{"port": n, "base": -234, "corr": -8 if n == 2 else 0,
                                 "written": -242 if n == 2 else -234} for n in range(4)]}, fh)
        sk = tb.skew_corrections(hw)
        v = tb.cal_from_regs(hw, sk)
        check(sk == {2: (-242, -234, -8)} and v[("port2", "rx_offset_ns")] == -234,
              "RX_OFFSET with a live 0x0055 correction (-242) saved as its base (-234)")
        hw.wr(tb.SFD_PORT_BASE + 2 * tb.SFD_PORT_STRIDE + tb.SFD_P_RX_OFFSET, -250)
        check(tb.skew_corrections(hw) == {}, "register changed since: no correction assumed")
        tb.RUN_DIR = old


def run(args, env, check_rc=0):
    r = subprocess.run([sys.executable, TOOL] + args, capture_output=True, text=True, env=env,
                       timeout=120)
    if VERBOSE or r.returncode != check_rc:
        print("        $ pktrec-tb " + " ".join(args))
        for line in (r.stdout + r.stderr).strip().splitlines()[:40]:
            print("        " + line)
    return r


def test_cli():
    print("CLI with --sim (real time)")
    with tempfile.TemporaryDirectory() as td:
        env = dict(os.environ, PKTREC_RUN_DIR=os.path.join(td, "run"),
                   PKTREC_CAL_FILE=os.path.join(td, "etc", "calibration.conf"))
        sim = ["--sim", "-10.4", "--sim-noise", "200"]
        r = run(sim + ["status", "--json"], env)
        ok = r.returncode == 0
        doc = json.loads(r.stdout) if ok else {}
        check(ok and "offset_ns" in doc and doc["daemon"] is None and
              doc["calibration"]["present"] is False, "status --json (no daemon, no file)")
        r = run(sim + ["set"], env)
        check(r.returncode == 0 and "timebase set" in r.stdout, "set")
        r = run(sim + ["status", "--json"], env)
        check(r.returncode == 0 and abs(json.loads(r.stdout)["offset_ns"]) < 1e6,
              f"offset after set {json.loads(r.stdout)['offset_ns'] if r.returncode == 0 else '?'} ns")
        r = run(sim + ["trim", "--ppm", "10.4"], env)
        check(r.returncode == 0 and "+10.400 ppm" in r.stdout, "trim --ppm 10.4")
        r = run(sim + ["save-calibration"], env)
        cal = env["PKTREC_CAL_FILE"]
        check(r.returncode == 0 and os.path.isfile(cal), "save-calibration writes the file")
        txt = open(cal).read() if os.path.isfile(cal) else ""
        check("NOT updated" in r.stderr and "not running" in r.stderr and "ppm = 0.000000" in txt,
              "no locked daemon: timebase.ppm not taken from the live INC (file had none: 0)")
        r = run(sim + ["trim", "--ppm", "3.3"], env)
        with open(cal) as fh:
            txt0 = fh.read()
        with open(cal, "w") as fh:
            fh.write(txt0.replace("ppm = 0.000000", "ppm = 9.9"))
        r = run(sim + ["save-calibration"], env)
        txt = open(cal).read()
        check("keeping the file's timebase.ppm = +9.900000" in r.stderr and "ppm = 9.900000" in txt,
              "existing file value kept and reported")
        r = run(sim + ["trim", "--ppm", "10.4"], env)
        r = run(sim + ["save-calibration", "--force-timebase"], env)
        txt = open(cal).read()
        check("ppm = 10.4000" in txt and "mac_offset_ns = 52" in txt, "--force-timebase: live INC saved")
        r = run(sim + ["trim", "--ppm", "0"], env)
        r = run(sim + ["apply-calibration"], env)
        st = os.path.join(env["PKTREC_RUN_DIR"], "calibration.json")
        check(r.returncode == 0 and os.path.isfile(st), "apply-calibration + /run record")
        r = run(sim + ["show-calibration", "--json"], env)
        rows = {k["key"]: k for k in json.loads(r.stdout)["keys"]} if r.returncode == 0 else {}
        check(rows and abs(rows["timebase.ppm"]["register"] - 10.4) < 1e-4 and
              all(k["file"] == k["register"] for n, k in rows.items() if n != "timebase.ppm"),
              "show-calibration: registers = file")
        r = run(sim + ["status"], env)
        check(r.returncode == 0 and "present, applied" in r.stdout, "status text shows calibration")
        r = run(sim + ["daemon", "--duration", "12", "--estimate", "4", "--summary", "5"], env)
        stf = os.path.join(env["PKTREC_RUN_DIR"], "tb.json")
        js = json.load(open(stf)) if os.path.isfile(stf) else {}
        check(r.returncode == 0 and js.get("state") == "stopped" and js.get("sets", 0) >= 1 and
              "seeds the controller" in r.stdout and js.get("seeded_from_calibration"),
              "daemon --duration 12: ran seeded from the calibration (no estimate), stopped")
        check("kernel clock correction" in r.stdout, "kernel clock correction logged")
        check(abs(js.get("offset_ns", 1e9)) < 50000, f"daemon final offset {js.get('offset_ns')} ns")
        r = run(["save-calibration", "--defaults", "--stdout"], env)
        check(r.returncode == 0 and "rx_window_max_ns = 700" in r.stdout, "save --defaults --stdout")


def main():
    global VERBOSE
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("-v", "--verbose", action="store_true")
    VERBOSE = ap.parse_args().verbose
    tb = load_tool()
    test_controller(tb)
    test_seeded(tb)
    test_calibration(tb)
    test_cli()
    print(f"\n{'ALL PASSED' if not FAILS else str(len(FAILS)) + ' FAILED'}")
    for f in FAILS:
        print("  FAILED: " + f)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
