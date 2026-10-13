#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Opsero Electronic Design Inc.
"""selftest_export.py - host-side self-test of pktrec-export (no hardware).

Builds pktrec-export (make, host compiler), then:
  1. clean synthetic capture (4 ports, out-of-order timestamps, a bad-FCS
     frame, a snaplen-truncated frame, padding) -> exit 0, pcapng_lint PASS,
     check_pcap PASS (every sequence number once, in order).
  2. damaged capture (corrupted stretch + file ending inside a record) ->
     exit 2, one resync, pcapng_lint PASS, exactly the destroyed frames are
     missing, nothing else.
  3. reorder window too small -> exit 2 and the order violation is detected.
  4. streaming: stdin -> stdout gives the same bytes as file -> file.
  5. tshark / capinfos, if installed: no warnings or errors.

Usage: selftest_export.py [--keep DIR]
"""

import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
APPS = os.path.join(HERE, "..", "sw", "pktrec-apps")
EXPORT = os.path.join(APPS, "pktrec-export")
PY = [sys.executable, "-I"]
fails = []


def run(cmd, **kw):
    return subprocess.run(cmd, capture_output=True, text=True, **kw)


def expect(cond, what):
    print(f"  {'ok  ' if cond else 'FAIL'} {what}")
    if not cond:
        fails.append(what)


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--keep", help="work directory to keep (default: temporary)")
    a = ap.parse_args()
    work = a.keep or tempfile.mkdtemp(prefix="pktrec-selftest-")
    os.makedirs(work, exist_ok=True)

    r = run(["make", "-B", "-C", APPS, "pktrec-export"])
    if r.returncode:
        print(r.stdout, r.stderr)
        sys.exit("selftest: build failed")
    warn = [ln for ln in r.stderr.splitlines() if "warning" in ln]
    expect(not warn, "pktrec-export builds without warnings")

    def synth(name, *extra):
        cap = os.path.join(work, name + ".cap")
        r = run(PY + [os.path.join(HERE, "make_synth_capture.py"), cap,
                      "--sent", cap + ".sent.json", "--expect", cap + ".expect.json", *extra])
        if r.returncode:
            sys.exit(r.stderr)
        print(r.stdout.strip())
        return cap

    def export(cap, out, *extra):
        r = run([EXPORT, cap, "-o", out, *extra])
        print("    " + r.stderr.strip().replace("\n", "\n    "))
        return r

    def lint(pc):
        return run(PY + [os.path.join(HERE, "pcapng_lint.py"), "-q", pc])

    def check(pc, sent):
        r = run(PY + [os.path.join(HERE, "check_pcap.py"), pc, "--sent", sent, "--json"])
        return r, json.loads(r.stdout.strip().splitlines()[-1])

    print("1. clean capture")
    cap = synth("clean")
    pc = cap + ".pcapng"
    r = export(cap, pc)
    expect(r.returncode == 0, "export exit code 0")
    expect(lint(pc).returncode == 0, "pcapng_lint PASS")
    r, res = check(pc, cap + ".sent.json")
    expect(res["pass"], "check_pcap PASS: all frames once, in order, counts match")

    print("2. damaged capture")
    cap = synth("damaged", "--damage")
    pc = cap + ".pcapng"
    r = export(cap, pc)
    expect(r.returncode == 2, "export exit code 2 (anomalies)")
    expect("resyncs 1 " in r.stderr, "exactly one resynchronisation")
    expect(lint(pc).returncode == 0, "pcapng_lint PASS")
    with open(cap + ".expect.json") as f:
        exp = json.load(f)
    r, res = check(pc, cap + ".sent.json")
    got = {s["key"].split(":")[1]: s["missing"] for s in res["streams"]}
    want = {k: v for k, v in exp["lost"].items()}
    expect(got == want, f"missing frames per port = destroyed records {want} (got {got})")
    expect(all(s["dups"] == 0 and s["reorders"] == 0 for s in res["streams"]),
           "no duplicates, no reordering")

    print("2b. hardware drops (P0, 5 frames)")
    cap = synth("drops", "--drops", "5")
    pc = cap + ".pcapng"
    r = export(cap, pc)
    expect(r.returncode == 0, "export exit code 0 (drops are data, not corruption)")
    expect(lint(pc).returncode == 0, "pcapng_lint PASS")
    r, res = check(pc, cap + ".sent.json")
    p0 = res["interfaces"]["P0"]
    miss0 = [s["missing"] for s in res["streams"] if s["interface"] == "P0"][0]
    expect(not res["pass"] and miss0 == 5, "check_pcap FAILs with exactly 5 frames missing on P0")
    expect(p0["isb_ifdrop"] == 5 and p0["dropcount"] == 5,
           f"isb_ifdrop = sum(epb_dropcount) = 5 (got {p0['isb_ifdrop']}, {p0['dropcount']})")

    print("3. window too small")
    cap = os.path.join(work, "clean.cap")
    pc = os.path.join(work, "small-window.pcapng")
    r = export(cap, pc, "--window-records", "8")
    expect(r.returncode == 2, "export exit code 2")
    expect("records later than the window: 0" not in r.stderr, "late records reported")
    expect(lint(pc).returncode == 1, "pcapng_lint flags the order violation")

    print("4. streaming stdin -> stdout")
    with open(cap, "rb") as fi, open(os.path.join(work, "stream.pcapng"), "wb") as fo:
        r = subprocess.run([EXPORT, "-", "-q"], stdin=fi, stdout=fo)
    with open(os.path.join(work, "stream.pcapng"), "rb") as f1, \
            open(os.path.join(work, "clean.cap.pcapng"), "rb") as f2:
        a1, a2 = f1.read(), f2.read()
    # the SHB comment and ISBs are identical; only the input name differs nowhere
    expect(r.returncode == 0 and a1 == a2, "stdin/stdout output identical to file output")

    print("5. Wireshark tools")
    tshark, capinfos = shutil.which("tshark"), shutil.which("capinfos")
    if not tshark and not capinfos:
        print("  skip tshark/capinfos not installed: Wireshark verification pending "
              "(pcapng_lint.py stands in)")
    for tool, args in ((capinfos, []), (tshark, ["-r"])):
        if tool:
            pc = os.path.join(work, "clean.cap.pcapng")
            r = run([tool, *args, pc])
            bad = [ln for ln in (r.stderr + r.stdout).splitlines()
                   if "warn" in ln.lower() or "error" in ln.lower() or "appears to" in ln]
            expect(r.returncode == 0 and not bad, f"{os.path.basename(tool)} reads it cleanly")

    if not a.keep:
        shutil.rmtree(work)
    print("PASS" if not fails else f"FAIL ({len(fails)})")
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
