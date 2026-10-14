#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""test_api.py - exercise the pktrec-web API of a running server (stdlib only).

  test_api.py --url http://<board>:8080 [--ports 0,1] [--seconds 5] [--keep]
              [--outdir DIR] [--no-mode] [--lint]

Steps: UI files; /api/status and /api/stats; per-pair mode (both pairs set
to each mode and read back, then restored); bad requests (400/404/405/409);
a manual capture (start, live stats, second start refused, stop), a
duration-limited capture that stops by itself; the capture list and info;
pcapng download (chunked, Content-Disposition; checked for a pcapng SHB
and, with --lint, by test/pcapng_lint.py and capinfos if installed); raw
download; delete (and 404 after). Exits 0 when every check passed.

Against the board, run traffic into the captured ports while it runs.
Against 'pktrec-web --mock', it also checks the start-failure path and the
loop-safety refusal of mode tap for a pair with a PHY in loopback (409).
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request

FAILS = []


def check(cond, what):
    print(f"  {'PASS' if cond else 'FAIL'}  {what}")
    if not cond:
        FAILS.append(what)
    return cond


def call(base, method, path, body=None, raw=False, timeout=60):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(base + path, data=data, method=method)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            payload = r.read()
            return r.status, (payload if raw else json.loads(payload or b"null")), r.headers
    except urllib.error.HTTPError as e:
        payload = e.read()
        try:
            return e.code, json.loads(payload), e.headers
        except ValueError:
            return e.code, payload, e.headers


def wait_idle(base, timeout):
    t_end = time.time() + timeout
    while time.time() < t_end:
        _, st, _ = call(base, "GET", "/api/stats")
        if st["capture"]["state"] == "idle":
            return st
        time.sleep(0.5)
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--url", default="http://127.0.0.1:8080")
    ap.add_argument("--ports", default="0,1", help="ports to capture (default 0,1)")
    ap.add_argument("--seconds", type=float, default=4, help="manual capture length")
    ap.add_argument("--keep", action="store_true", help="keep the test captures")
    ap.add_argument("--outdir", default=".", help="where downloads are saved")
    ap.add_argument("--no-mode", action="store_true",
                    help="do not touch the TAP/monitor modes (e.g. a TAP carries live traffic)")
    ap.add_argument("--lint", action="store_true",
                    help="validate downloads with test/pcapng_lint.py and capinfos")
    a = ap.parse_args()
    base = a.url.rstrip("/")
    ports = [int(p) for p in a.ports.split(",")]
    tag = time.strftime("apitest-%H%M%S")
    os.makedirs(a.outdir, exist_ok=True)

    print("UI")
    s, body, h = call(base, "GET", "/", raw=True)
    check(s == 200 and b"<html" in body and "text/html" in h["Content-Type"], "GET / serves the page")
    for f in ("app.js", "style.css"):
        s, body, _ = call(base, "GET", "/" + f, raw=True)
        check(s == 200 and len(body) > 100, f"GET /{f}")
    s, _, _ = call(base, "GET", "/../../etc/passwd", raw=True)
    check(s == 404, "path traversal refused (404)")

    print("status / stats")
    s, st, _ = call(base, "GET", "/api/status")
    check(s == 200 and len(st["ports"]) == 4 and len(st["pairs"]) == 2, "GET /api/status: 4 ports, 2 pairs")
    for p in st["ports"]:
        print(f"        P{p['port']}: link={p.get('link')} {p.get('speed')} {p.get('duplex')} "
              f"path={p.get('path')}")
    print(f"        pairs: {[q['mode'] for q in st['pairs']]}, disk: {st['disk']}")
    print(f"        version: {st['version']}, errors: {st['errors']}")
    check(st["errors"]["pktrec-phy"] is None and st["errors"]["pktrec-cap"] is None,
          "pktrec-phy status and pktrec-cap stats ran")
    check(st.get("sources") == {"pktrec-phy": "json", "pktrec-cap": "json"},
          f"tools read through --json ({st.get('sources')})")
    tb = st["time"].get("discipline") or {}
    print(f"        timebase: {json.dumps(tb)[:300]}")
    check(tb.get("fresh") is True and "locked" in tb and "offset_ns" in tb and "ppm" in tb,
          f"timebase discipline: pktrec-tb running, {'locked' if tb.get('locked') else 'NOT locked'}"
          f", offset {tb.get('offset_ns')} ns, {tb.get('ppm')} ppm")
    cal = st.get("calibration") or {}
    print(f"        calibration: {json.dumps(cal)[:300]}")
    check(cal.get("present") is True and (cal.get("applied") or {}).get("ok") is True,
          "calibration file present and applied at boot")
    if not check(st["disk"]["mounted"], "SSD mounted"):
        print("cannot test captures without the SSD")
    if st["capture"]["state"] != "idle":
        print("  a capture is running: stopping it first")
        call(base, "POST", "/api/capture/stop")
    s, sx, _ = call(base, "GET", "/api/stats")
    check(s == 200 and "counters" in sx and "capture" in sx, "GET /api/stats")
    time.sleep(1.1)
    s, sx, _ = call(base, "GET", "/api/stats")
    check(all("frames_s" in c for c in sx["counters"]["ports"].values()),
          "per-port rates present on the second poll")

    print("mode")
    if a.no_mode:
        print("  (skipped)")
    else:
        orig = [q["mode"] for q in st["pairs"]]
        for mode in ("tap", "monitor"):
            for pair in (0, 1):
                s, r, _ = call(base, "POST", "/api/mode", {"pair": pair, "mode": mode})
                check(s == 200 and r["pairs"][pair]["mode"] == mode, f"pair {pair} -> {mode}")
        s, st2, _ = call(base, "GET", "/api/status")
        check([q["mode"] for q in st2["pairs"]] == ["monitor", "monitor"], "modes read back")
        for pair, mode in enumerate(orig):
            if mode in ("tap", "monitor"):
                call(base, "POST", "/api/mode", {"pair": pair, "mode": mode})
        print(f"        restored {orig}")

    print("bad requests")
    for method, path, body, code in [
            ("POST", "/api/mode", {"pair": 2, "mode": "tap"}, 400),
            ("POST", "/api/mode", {"pair": 0, "mode": "fwd"}, 400),
            ("GET", "/api/mode", None, 405),
            ("POST", "/api/capture/start", {"ports": [4]}, 400),
            ("POST", "/api/capture/start", {"ports": [0], "snaplen": 70000}, 400),
            ("POST", "/api/capture/start", {"ports": [0], "name": "../x"}, 400),
            ("POST", "/api/capture/start", {"ports": [0], "duration_s": -1}, 400),
            ("POST", "/api/capture/stop", None, 409),
            ("GET", "/api/captures/does-not-exist/info", None, 404),
            ("GET", "/api/captures/does-not-exist.pcapng", None, 404),
            ("DELETE", "/api/captures/does-not-exist", None, 404),
            ("GET", "/api/nothing", None, 404)]:
        s, r, _ = call(base, method, path, body)
        check(s == code and isinstance(r, dict) and "error" in r,
              f"{method} {path} {json.dumps(body) if body else ''} -> {code} ({r.get('error') if isinstance(r, dict) else r!r})")
    if "mock" in (st["version"].get("image") or ""):
        s, r, _ = call(base, "POST", "/api/capture/start", {"ports": [0], "name": tag + "-mockfail"})
        check(s == 500 and "fdrec0" in r.get("error", ""), f"start failure reported ({r.get('error')})")
        s, r, _ = call(base, "GET", f"/api/captures/{tag}-mockfail/info")
        check(s == 404, "failed capture file removed")
        ms = st["version"].get("mock_state")
        if ms:                                  # loop safety: no tap into a looped PHY
            lp = os.path.join(ms, "phy_loop.json")
            with open(lp, "w") as f:
                json.dump([False, False, False, True], f)
            try:
                s, r, _ = call(base, "POST", "/api/mode", {"pair": 1, "mode": "tap"})
                check(s == 409 and "loopback" in r.get("error", ""),
                      f"mode tap refused for a pair with a PHY in loopback ({r.get('error')})")
            finally:
                os.unlink(lp)

    if not st["disk"]["mounted"]:
        return finish()

    print("manual capture")
    name = tag + "-manual"
    s, r, _ = call(base, "POST", "/api/capture/start", {"ports": ports, "snaplen": 0, "name": name})
    check(s == 202 and r["state"] == "running" and r["name"] == name, f"start {name} -> 202 running")
    s, r, _ = call(base, "POST", "/api/capture/start", {"ports": ports, "name": name + "-2"})
    check(s == 409, "second start refused (409)")
    if not a.no_mode:
        s, r, _ = call(base, "POST", "/api/mode", {"pair": 0, "mode": "monitor"})
        check(s == 409, "mode change refused while capturing (409)")
    s, r, _ = call(base, "DELETE", f"/api/captures/{name}")
    check(s == 409, "delete of the active capture refused (409)")
    s, r, _ = call(base, "GET", f"/api/captures/{name}.pcapng")
    check(s == 409, "download of the active capture refused (409)")
    live = None
    t_end = time.time() + a.seconds
    while time.time() < t_end:
        time.sleep(1)
        _, sx, _ = call(base, "GET", "/api/stats")
        live = sx["capture"].get("live") or live
        c = sx["capture"]
        print(f"        {c['state']} {c.get('elapsed_s', 0):.1f}s file {c.get('file_bytes')} B "
              f"live {json.dumps(live)[:160] if live else None}")
    check(live is not None and "ring_total" in live, "live statistics parsed from pktrec-cap")
    check(live is not None and live.get("source") == "json" and "written_bytes" in live,
          "live statistics from pktrec-cap --stats-json")
    s, r, _ = call(base, "GET", "/api/captures")
    check(any(c["name"] == name and c["recording"] for c in r["captures"]),
          "listed as recording")
    s, r, _ = call(base, "POST", "/api/capture/stop")
    check(s == 200, f"stop -> {r['state']}")
    st3 = wait_idle(base, 30)
    check(st3 is not None, "idle after stop")
    last = st3["capture"]["last"] if st3 else None
    check(last and last["name"] == name and last["exit_code"] in (0, 2),
          f"result: exit {last and last['exit_code']} {last and last['result']}")
    check(last and "bytes" in last["result"] and "records" in last["result"],
          "result fields (bytes, records)")

    print("duration-limited capture")
    name2 = tag + "-dur"
    s, r, _ = call(base, "POST", "/api/capture/start",
                   {"ports": ports, "snaplen": 128, "duration_s": 2, "name": name2})
    check(s == 202, f"start {name2} with duration_s 2")
    st4 = wait_idle(base, 30)
    check(st4 is not None and st4["capture"]["last"]["name"] == name2,
          "stopped by itself after the duration")

    print("captures")
    s, r, _ = call(base, "GET", "/api/captures")
    names = {c["name"]: c for c in r["captures"]}
    check(name in names and name2 in names, "both captures listed")
    for n in (name, name2):
        c = names.get(n, {})
        print(f"        {n}: {c.get('file_bytes')} B, start {c.get('start_time')}, "
              f"{c.get('duration_s')} s, ports {c.get('ports_captured')}, drops {c.get('drops')}")
        check(c.get("complete") is True, f"{n}: header complete")
    s, r, _ = call(base, "GET", f"/api/captures/{name2}/info")
    check(s == 200 and bool(r.get("info_text")) and r.get("snaplen") == 128,
          "info: header fields + pktrec-cap info text")
    tbd = r.get("tb_discipline")
    check(isinstance(tbd, dict) and "offset_ns" in tbd and "locked" in tbd,
          f"info: timebase discipline at start recorded ({json.dumps(tbd)})")
    print("        " + (r.get("info_text") or "").strip().replace("\n", "\n        ")[:900])

    print("downloads")
    for n in (name, name2):
        out = os.path.join(a.outdir, n + ".pcapng")
        t0 = time.time()
        s, body, h = call(base, "GET", f"/api/captures/{n}.pcapng", raw=True, timeout=600)
        dt = time.time() - t0
        ok = check(s == 200 and h.get("Transfer-Encoding") == "chunked" and
                   "attachment" in (h.get("Content-Disposition") or ""),
                   f"{n}.pcapng: 200, chunked, attachment ({len(body)} B in {dt:.1f} s)")
        if ok:
            with open(out, "wb") as f:
                f.write(body)
            check(body[:4] == b"\x0a\x0d\x0d\x0a", "starts with a pcapng section header block")
            if a.lint:
                lint(out)
    s, body, h = call(base, "GET", f"/api/captures/{name2}.cap", raw=True)
    check(s == 200 and body[:8] == b"PKTRCAP\x00" and int(h["Content-Length"]) == len(body),
          f"{name2}.cap raw download ({len(body)} B)")

    if not a.keep:
        print("delete")
        for n in (name, name2):
            s, r, _ = call(base, "DELETE", f"/api/captures/{n}")
            check(s == 200, f"delete {n}")
            s, r, _ = call(base, "GET", f"/api/captures/{n}/info")
            check(s == 404, f"{n} gone (404)")
    return finish()


def lint(path):
    here = os.path.dirname(os.path.realpath(__file__))
    linter = os.path.normpath(os.path.join(here, "..", "..", "test", "pcapng_lint.py"))
    if os.path.isfile(linter):
        r = subprocess.run([sys.executable, linter, path], capture_output=True, text=True)
        check(r.returncode == 0, f"pcapng_lint: {(r.stdout + r.stderr).strip().splitlines()[-1:]}")
    if shutil.which("capinfos"):
        r = subprocess.run(["capinfos", "-c", "-I", path], capture_output=True, text=True)
        check(r.returncode == 0 and not r.stderr.strip(),
              "capinfos: " + " ".join((r.stdout + r.stderr).split())[:200])


def finish():
    print(f"\n{'ALL PASSED' if not FAILS else str(len(FAILS)) + ' FAILED'}")
    for f in FAILS:
        print("  FAILED: " + f)
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
