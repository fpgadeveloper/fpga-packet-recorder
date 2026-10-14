# Software

The software runs on the board's Linux image. All commands that touch the hardware need
root (`sudo`): they use the recorder device, the register maps of the capture blocks and
2 MB hugepages.

| Program | Language, source | What it does |
|---------|------------------|--------------|
| `pktrec-phy` | Python, `sw/pktrec-tools` | PHY configuration, link status, port modes and paths, SFD timestamping, generator and checker, forwarding latency, link watcher |
| `pktrec-cap` | C, `sw/pktrec-apps` | configures the capture, records it to the SSD, statistics |
| `pktrec-export` | C, `sw/pktrec-apps` | converts a capture file to pcapng (streaming) |
| `pktrec-replay` | C, `sw/pktrec-apps` | replays one interface of a capture out of a port |
| `pktrec-tb` | Python, `sw/pktrec-tools` | timebase discipline and calibration |
| `pktrec-web` | Python, `sw/pktrec-web` | web interface and JSON API ([Web interface](web_ui)) |
| `fdrec`, `fdplay`, `fdverify`, `fdsetup-raid0.sh`, `fdbench.sh` | `sw/fdrec-apps` | the FPGA Drive Recorder's tools: raw recording and playback with the test pattern generator, SSD formatting, SSD benchmark |
| `pktrec-pktgen`, `pktrec-check-pcap`, `pktrec-pcapng-lint` | `test/` | test traffic and checkers ([Testing](testing)) |

The C programs reuse the FPGA Drive Recorder's kernel driver (`fdrec.ko`, `/dev/fdrec0`) and
its zero-copy loop: the AXI DMA fills buffers in hugepage memory, io_uring writes the same
buffers to the file with `O_DIRECT` (or reads them, for replay), and the CPU only does the
bookkeeping. Only one program can use the recorder at a time.

## Services

| Unit | Started | What it does |
|------|---------|--------------|
| `pktrec-phy-watch.service` | at boot | `pktrec-phy init --1000-only`, then `pktrec-phy watch` (SGMII re-trigger on link changes, TAP link-state propagation) |
| `mnt-rec.mount` | at boot | mounts `/dev/nvme0n1` (XFS) at `/mnt/rec`; gives up after 20 s without blocking the boot |
| `pktrec-calibration.service` | at boot, once | `pktrec-tb apply-calibration`: writes `/etc/pktrec/calibration.conf` into the registers |
| `pktrec-tb.service` | at boot | `pktrec-tb daemon`: disciplines the timebase to the system clock |
| `pktrec-web.service` | at boot | the web server on `end0` port 8080 |
| `pktrec-banner.service` | at boot, once | prints the web interface URL on the console once the board has an address |

Logs: `journalctl -u <unit>`.

## pktrec-phy

`pktrec-phy` maps the Ethernet port, path and capture register blocks (`generic-uio`) and
drives the PHYs over the fabric MDIO master. Every MDIO access holds a lock
(`/run/lock/pktrec-mdio`), so the watcher service and command-line calls never interleave.
Most commands accept `--json`.

| Command | What it does |
|---------|--------------|
| `pktrec-phy init [--1000-only] [--reset] [--no-sfd]` | configures the four PHYs (below); the boot service runs it with `--1000-only` |
| `pktrec-phy status` | per port: copper link, speed, duplex, SGMII/PCS state, SFD pin levels; pair modes |
| `pktrec-phy mode <0\|1> tap\|monitor [--force]` | sets a pair's mode ([Port modes](modes)); refused during a capture unless `--force` |
| `pktrec-phy mode status` | mode, path and effective path per pair |
| `pktrec-phy path <port\|all> idle\|loop\|fwd\|gen\|replay` | selects what a port transmits: nothing, its own received frames, its partner's (TAP), the generator, or the replay block |
| `pktrec-phy counters [--clear]` | per-port frame counters of the MACs and the forward path (RX good/bad, TX good, underflow, drops, SFD pin edges) |
| `pktrec-phy sfd status [--clear]` | SFD timestamping counters per port: edges, matches, stale entries, mismatches, MAC−SFD deltas, transmit latency |
| `pktrec-phy sfd config [--rx-win MIN MAX] [--tx-win MIN MAX] [--rx-offset P NS] [--tx-offset P NS] [--match on\|off] [--log on\|off] ...` | SFD windows, offsets, matching and logging ([Timestamping](timestamping)) |
| `pktrec-phy sfd log <port> [--dir rx\|tx]` | reads the port's SFD log FIFO (last 16 timestamps) |
| `pktrec-phy gen <port> start [--size B] [--count N] [--ifg B \| --rate PPS] [--rand-mask M] [--vlan VID] [--bad] ...` | starts the port's hardware traffic generator (`--size` includes the FCS and the 802.1Q tag that `--vlan` inserts; sizes that can exceed the MAC's limit, 1522 bytes by default, are refused unless `--force`) |
| `pktrec-phy maxlen <port\|all> [--set B]` | the MACs' maximum frame length including the FCS (1522 by default); `--set` changes it for RX and TX and raises the dynamic inter-frame gap thresholds to stay above it |
| `pktrec-phy gen <port> stop\|status` | stops it / shows its counters |
| `pktrec-phy chk <port> start\|stop\|status` | receive checker for generator traffic: frames, lost, duplicates or reordered, bad |
| `pktrec-phy ifg <port\|all> [...]` | inter-frame gap of the TAP forward path (12 bytes; the experimental dynamic gap is off), forward FIFO fill, `DROP_FWD`, flushed frames; a gap below 12 bytes is refused unless `--i-know-the-phy-drops-frames` (the DP83867 loses frames after it) |
| `pktrec-phy latency --pair P [--count N]` | TAP forwarding latency per direction from the SFD logs (needs paced traffic: one frame in flight) |
| `pktrec-phy watch [--no-propagate] [--debounce S] [--grace S]` | the link watcher (normally run by the service) |
| `pktrec-phy mdio <phy> <reg> [val]` | raw PHY register access (`p0`..`p3` or the MDIO address; registers above 0x1F through the extended-register window) |

`pktrec-phy init` configures each DP83867 (MDIO addresses 0x01, 0x03, 0x0C, 0x0F for P0..P3):

* mirror mode on (needed on Rev-A Ethernet FMC Max cards, harmless on later ones),
* SGMII with SGMII auto-negotiation,
* with `--1000-only`: advertise 1000BASE-T full duplex only,
* SFD indications on GPIO_0 (receive) and GPIO_1 (transmit): `GPIO_MUX_CTRL` (0x0172) =
  0x0012, `RXFCFG` (0x0134) = 0x1080, `SYNC_FIFO_CTRL` (0x00E9) = 0xDF22,
* a soft restart.

The DP83867 sends its SGMII status word to the MAC only once after a restart; the watcher
re-triggers it on every copper link change, otherwise the MAC's view of the link goes stale.
To use other advertisement settings, stop the service (`systemctl stop pktrec-phy-watch`) and
run `pktrec-phy init` by hand.

```{note}
On the Ethernet FMC Max, the DP83867 of P0 supplies the clock of the other three PHYs.
`pktrec-phy` therefore refuses any MDIO write that would power down P0's PHY or change its
clock output, including through `pktrec-phy mdio`.
```

## pktrec-cap

```
pktrec-cap [record] [options] <output-file>
pktrec-cap stats [--watch <sec>] [--clear] [--json]
pktrec-cap info [--records <n>] <capture-file>
```

Run it as root (`sudo`). It needs the recorder device, the register maps and 2 MB hugepages.

| Option | Default | Meaning |
|--------|---------|---------|
| `--ports <list>` | `all` | Ports to capture: `0,1`, `0-3`, `all` |
| `--snaplen <bytes>` | `0` | Store at most this many bytes of each frame, FCS excluded. `0` stores whole frames. |
| `--duration <sec>` | - | Stop after this time. |
| `--size <bytes>` | - | Stop once this much has been written (`K/M/G/T` suffixes). The capture ends at the next buffer boundary. |
| `--stop-file <path>` | - | Stop when this file appears. It is removed. |
| `--no-tb-set` | - | Leave the hardware timebase as it is. By default it is set to `CLOCK_REALTIME` before the start, so timestamps are UTC. When the `pktrec-tb` daemon has the timebase locked, it is never set: the daemon already keeps it on `CLOCK_REALTIME`, and a step would disturb it. |
| `--stats <sec>` | `1` | Live statistics interval. `0` turns them off. |
| `--stats-json[=<fd>]` | - | Also write each statistics interval as one JSON object per line, to stdout or to file descriptor `<fd>`, plus a final result object. Works with `-q`. See below. |
| `--tb-state <path>` | `/run/pktrec/tb.json` | The `pktrec-tb` state file read at the start. |
| `--buffers <n>`, `--buf-size <bytes>`, `--qd <n>` | 32, 8M, 8 | Ring and write queue, as for `fdrec`. |
| `--timeout <sec>` | `10` | Abort when writes are in flight and none completes for this long (SSD stall). An idle network is not a stall. |
| `--target`, `--design` | - | Strings stored in the file header. |
| `--devmem` | - | Map the registers through `/dev/mem` instead of `generic-uio`. |

The capture stops on `--duration`, `--size`, `--stop-file`, Ctrl-C or `SIGTERM`. Every
frame that started before the stop is in the file.

The live statistics line shows:

* elapsed time,
* write rate,
* bytes written,
* ring buffers in use,
* back-pressure from the recorder on the record merge (`bp`, in percent of the time),
* per port: frames/s, bits/s and frames dropped so far (`d`).

At the end, the program prints a per-port summary and one machine-readable line:

```
RESULT bytes=... records=... seconds=... drops=... rec_drop_beats=... len_fixups=... error=0
```

With `--stats-json`, the same information comes as JSON lines (the web UI uses these):

```
{"type":"stats","final":false,"elapsed_s":3.001,"write_mb_s":118.2,"written_bytes":354418688,
 "written_gb":0.354,"ring_used":2,"ring_total":32,"backpressure_pct":0.0,"drops":0,
 "ports":{"1":{"frames_s":81274.0,"bits_s":998000000.0,"drops":0,"frames_rx":243822,
 "bytes_rx":374724544,"fifo_hwm":3072}}}
{"type":"result","exit_code":0,"bytes":...,"records":...,"seconds":...,"drops":0,
 "rec_drop_beats":0,"dma_errors":0,"len_fixups":0,"error":0}
```

(one object per line; wrapped here). The last `stats` object has `"final": true`.

At the start, `pktrec-cap` prints the timebase state, for example
`timebase disciplined by pktrec-tb (locked), offset +1.204 us vs CLOCK_REALTIME, trim +10.412 ppm`,
and records it in the file header (see [File formats](capture_format.md#capture-file-header)).

| Exit code | Meaning |
|-----------|---------|
| 0 | Complete, and no frame was dropped anywhere. |
| 2 | Complete, but frames were dropped (a per-port FIFO overflowed) or the recorder lost data. The capture is not lossless. |
| 1 | Error. |

### Sequence of operations

`pktrec-cap` follows the protocol documented in `include/pktrec_regs.h`.

**Start**

1. Select the capture block as the recorder source.
2. Read the `pktrec-tb` state (`/run/pktrec/tb.json`). If the daemon runs and is locked,
   leave the timebase alone. Otherwise set it to `CLOCK_REALTIME` (unless `--no-tb-set`).
   `TB_SET` applies on the next clock cycle; there is nothing to wait for.
3. Clear the counters and sequence numbers.
4. Set the port enables and the snap length.
5. Start the recorder without its test pattern generator.
6. Enable the capture.

**Stop**

1. Disable the capture. No new frame starts; frames already in progress complete.
2. Keep writing buffers until the capture block reports idle.
3. Read the count of stream bytes handed to the recorder (`BYTES_OUT`) and the counters.
4. Switch on FILL, so zero units push the last partial buffer through the DMA.
5. Collect buffers until `BYTES_OUT` bytes are in hand, then stop the recorder.
6. Set `CTRL` back to 0. This also returns the recorder source to the test pattern
   generator, for `fdrec`.
7. Truncate the file to the header plus `BYTES_OUT`, so the fill units are not stored.

If a previous capture was killed and left the capture enabled, the next run notices it and
resets the block. The recorder device is exclusive, so only one capture (or `fdrec` /
`fdplay`) runs at a time.

### Other commands

`pktrec-cap stats` reads the capture block without capturing:

* control and status,
* the timebase,
* merge counters,
* per-port frames, bad frames, drops, truncated frames, bytes, records, FIFO high-water
  mark and next sequence number.

With `--watch <sec>` it repeats and adds rates. `--clear` clears the counters; it is refused
while a capture runs. `--json` prints the same fields as one JSON object per line
(`ports[]` with `frames_rx`, `frames_bad`, `frames_drop`, `frames_trunc`, `bytes_rx`,
`bytes_drop`, `records`, `fifo_hwm`, `seq`, `link`, `enabled`, and with `--watch`
`frames_s` / `bits_s`; `merge{}`; `timebase_ns`, `tb_inc`, `tb_freq_ppb`, `tb_status`,
`ctrl`, `status`, ...).

`pktrec-cap info <file>` prints the file header. `--records <n>` also lists the first record
headers.

## pktrec-export

```
pktrec-export [options] <capture-file|-> [-o <out.pcapng|->]
```

`pktrec-export` reads the capture sequentially and writes pcapng to a file or to stdout. It
never seeks and needs no temporary file, so a web server can convert during a download:

```
pktrec-export /mnt/rec/cap1.cap | <send to the client>
```

It refuses to write binary to a terminal unless `--force` is given.

| Option | Default | Meaning |
|--------|---------|---------|
| `-o <file>` | stdout | Output file. |
| `--port <n>` | all captured | Export only these ports (repeatable). |
| `--window-records <n>` | 65536 | Reorder window: records held. |
| `--window-bytes <bytes>` | 4M | Reorder window: frame bytes held. |
| `--max-frame <bytes>` | 16388 | Largest frame the hardware stores, including the FCS (per-port FIFO 16384 B + 4). Used by the header checks; snaplen-truncated records may describe longer frames. |
| `--raw-ts` | - | Write the raw timebase values instead of wall-clock time. |
| `--comments` | - | Per-packet comment for records flagged with a MAC timestamp or an SFD mismatch. |
| `--no-isb` | - | No Interface Statistics Blocks. |
| `--check` | - | Check gen_seq.py / PRSQ test traffic while exporting (below). |
| `--expect <n>` | - | With `--check`: every PRSQ stream must have exactly `n` frames. |

At the end it prints a summary to stderr:

* records per port,
* bad and truncated frames,
* drops seen as sequence gaps,
* the largest reorder distance,
* resynchronisations.

| Exit code | Meaning |
|-----------|---------|
| 0 | Clean. |
| 2 | Written, but with anomalies: corrupt stretches skipped, records later than the reorder window, a truncated tail, or recorder data loss recorded in the header. |
| 1 | Error. |
| 3 | The output could not be written: the reader closed the pipe (EPIPE, e.g. `pktrec-export cap.cap - \| head`) or the disk is full; the message names the write error. |
| 4 | Written, but `--check` found a problem (takes precedence over 2). |

`--check` runs the PRSQ part of `test/check_pcap.py` inside the exporter, on the frames in
output (timestamp) order, at export speed. Frames must carry the gen_seq.py payload (UDP over
IPv4, optional 802.1Q/802.1ad tags, `"PRSQ"` + stream id + 64-bit sequence number), as sent
by `gen_seq.py` and by the board's hardware generators (`pktrec-phy gen`). For each port and
stream it reports the frame count, the sequence range, missing numbers (gaps inside the range
seen), duplicates, out-of-order numbers, bad-FCS frames and the inter-frame interval; for each
port, timestamps that go backwards. Other frames are counted and ignored. The verdict
(`pktrec-export --check: PASS` or `FAIL`) goes to stderr, also with `-q`. The pcapng output is
unchanged; for a check without a file, write to `/dev/null`:

```
pktrec-export --check --expect 87000000 /mnt/rec/captures/run1.cap -o /dev/null
```

Missing numbers are counted between the first and the last number seen in each stream; use
`--expect` (or `check_pcap.py --sent` on the PC) to catch frames lost at the start or the end.
Linux pktgen payloads are not recognised by `--check`; use `check_pcap.py` for those.

The reorder window, the header checks and resynchronisation, and the pcapng mapping are
described in [File formats](capture_format.md#pcapng-mapping).

## pktrec-replay

`pktrec-replay` (C, `sw/pktrec-apps`) plays the frames one interface received in a
capture file back out of a port, with the original timing, scaled, at a fixed interval
or back to back. The timing is done by the replay block in the FPGA (see [Replay](replay) and
[Architecture](design)); the program selects the records, streams them through the recorder's
playback path (io_uring `O_DIRECT` reads of the file, hugepage ring, AXI DMA MM2S, the
fdrec driver's `PLAY_*` ioctls like `fdplay`) and reports.

```
pktrec-replay <capture.cap> --iface P<n> --port <m>
              [--rate X | --topspeed | --gap NS] [--loop N] [--start-delay MS]
              [--keep-bad | --bad-as-good] [--late-thresh NS]
              [--preload [--wait-capture S]] [--force] [--keep-path]
              [--buffers N] [--buf-size B] [--device D] [--devmem] [--json] [-q] [--dry-run]
```

| Option | Meaning |
|--------|---------|
| `--iface P<n>` | capture interface to replay: the frames received on port Pn |
| `--port <m>` | output port 0..3; put into path mode 4 REPLAY for the run and restored afterwards (`--keep-path` leaves it) |
| (default) | original timing: frame i leaves `ts_i - ts_first` after the first |
| `--rate X` | intervals divided by X (2 = twice as fast, 0.5 = half speed; 1/65536..65536) |
| `--topspeed` | back to back at line rate, timestamps ignored |
| `--gap NS` | fixed start-to-start interval, timestamps ignored |
| `--loop N` | play the selection N times; the timestamps continue (one mean interval between the last frame and the next loop) |
| `--start-delay MS` | first frame this long after the start (default 10 ms) |
| `--keep-bad` / `--bad-as-good` | frames captured with an error: sent errored (the receiver counts an RX error) / sent with a valid FCS. Default: skipped |
| `--late-thresh NS` | lateness above which a frame counts as LATE (default 100 ns) |
| `--preload` | load the frames into the replay store (128 KB / 2048 frames; the rest is ignored with a note), release the recorder, then play: a capture can run during the replay |
| `--wait-capture S` | with `--preload`: start once `pktrec-cap` has started a capture (at most S seconds) |
| `--force` | replay although the pair is in TAP mode, the port has no link, or the replay block is busy (aborts it) |
| `--dry-run` | only read the file: records selected, bytes, time span |
| `--json` | one JSON summary object on stdout |

Only capture files (`pktrec-cap`) can be replayed, not pcapng: the record headers carry
the hardware timestamps, port and flags, and the exporter direction is one-way.

**Interfaces and TAP captures.** Each record belongs to the port that received it. In
monitor mode Pn is the traffic seen on port n; in a TAP-mode capture P0 is the direction
P0 -> P1 and P1 the direction P1 -> P0. One interface is replayed out of one port per run;
to replay both directions of a TAP capture, run pktrec-replay twice (one direction each);
replaying both at the same time is not implemented.

**Mutual exclusion with TAP mode.** pktrec-replay refuses an output port whose pair is
in TAP mode or whose partner forwards (`pktrec-phy mode <pair> monitor` first, or
`--force`). While a port is in replay, `pktrec-phy mode <pair> tap` and `pktrec-phy path
<partner> fwd` are refused (`mode ... tap --force` takes the port out of replay).
`pktrec-phy path <m> replay` selects the path by hand.

**Sequence.** Checks (replay block present and idle, m0 map >= 1.3, TAP, link) ->
`/run/pktrec/tb-hold.<pid>` (the timebase daemon does not step the timebase while the
file exists; removed on exit) -> output port into REPLAY -> CTRL (SEL, mode, bad-frame
policy, port filter, TX port), RATE_INV, START_DELAY -> ARM -> `PLAY_START` (without the
checker: no recorder soft reset) -> the selected records are copied into the ring and
submitted; once the ring is full the store has primed -> GO -> streaming continues while
the hardware sends -> STOP after the last buffer -> wait for DONE -> counters ->
`PLAY_STOP`, SEL = 0, path restored, hold file removed. Ctrl-C aborts cleanly (ABORT: the
frame on the wire is completed).

**Output.** A progress line (frames sent, frames in the store, underruns, late, max
lateness) and the summary: frames and bytes sent, errored frames sent, skipped, underruns,
lateness (max, mean, count above the threshold), parse errors, duration.
Exit code 0 = every selected frame sent, no underrun, no parse error; 2 = completed with
underruns, parse errors or frames missing; 1 = error.

**Replay and capture at the same time.** The recorder serves one direction at a time,
so a streamed replay cannot run while `pktrec-cap` records. Use `--preload`:

```
pktrec-replay /mnt/rec/captures/p3.cap --iface P3 --port 2 --preload --wait-capture 30 &
pktrec-cap record --ports 3 --duration 5 /mnt/rec/captures/replayed.cap
wait
pktrec-export /mnt/rec/captures/p3.cap -o p3.pcapng
pktrec-export /mnt/rec/captures/replayed.cap -o replayed.pcapng
python3 test/compare_replay.py p3.pcapng --orig-iface P3 replayed.pcapng --replay-iface P3
```

`test/compare_replay.py` pairs the frames by their bytes and reports lost, extra and
reordered frames and the inter-frame interval error (mean, standard deviation, max) of
the replay against the original (`--rate X` for a scaled replay, `--topspeed` for a
back-to-back one). Expected accuracy: within about +-16 ns per interval (MAC clock) plus
the receiving side's timestamp spread.

## pktrec-tb

All timestamps come from one 64-bit nanosecond timebase in the capture block. It runs
on `dp_clk` (249.975 MHz) and adds `INC` (32.32 fixed point, about 4.0004 ns) on every
cycle. `dp_clk` comes from the PS PLL, so the timebase is only as accurate as the board's
crystal (the measured board's ran 10 to 12 ppm slow, about 1 s per day).

`pktrec-tb` (Python, `sw/pktrec-tools`, recipe `Yocto/meta-pktrec/recipes-apps/pktrec-tb`)
keeps the timebase on `CLOCK_REALTIME`. The image's NTP client keeps that on NTP through the
PS Ethernet port, so capture timestamps are absolute wall-clock times. It runs as
`pktrec-tb.service` (enabled), and uses the register access of `pktrec-phy`.

```
pktrec-tb status [--json]
pktrec-tb set [--force]
pktrec-tb trim (--ppm X | --ppb X | --inc 0xNNNNNNNNNN) [--force]
pktrec-tb daemon [--interval 1] [--lock-threshold 10000] [--lock-time 30] [-v] ...
pktrec-tb apply-calibration [--file F] [--dry-run] [--force] [--no-timebase]
pktrec-tb save-calibration [--file F | --stdout] [--defaults] [--min-locked MIN]
                           [--max-ppm-delta PPM] [--force-timebase]
pktrec-tb show-calibration [--file F] [--json]
```

| Command | What it does |
|---------|--------------|
| `status` | Measures the timebase against `CLOCK_REALTIME` now. Shows `INC` and its ppm offset from nominal, whether the system clock is NTP-synchronised, the daemon state and whether the calibration was applied. `--json` gives one document. |
| `set` | One `TB_SET` from `CLOCK_REALTIME`. This is what `pktrec-cap` does at the start when the daemon is not locked. It is refused while a capture runs (unless `--force`), because a step moves the frames waiting in the FIFOs and breaks the file's time scale. |
| `trim` | Writes `INC`. A running daemon adopts the new value and keeps disciplining from it. |
| `daemon` | The controller below; `pktrec-tb.service` runs it. Options are in `/etc/default/pktrec-tb`. |

**Measurement.** Every second the daemon reads `TB_NOW` between two `CLOCK_REALTIME`
reads, 7 times, and keeps the pair with the shortest read latency (about 1.5 µs on the A53):
`offset = TB_NOW - (t1 + t2) / 2`. A positive offset means the timebase is ahead.

**Start-up.**

1. `TB_SET` to `CLOCK_REALTIME`, plus one `TB_ADJ` for the few µs the register writes took.
2. If the calibration set the frequency (`INC` differs from nominal), start the controller
   from it and track at once. Otherwise (or with `--estimate-always`) let the timebase run
   free for 8 s and fit a straight line to the offsets: its slope is the frequency error.
   Correct `INC`, then `TB_SET` again.
3. Track. The kernel's own frequency correction of the system clock is logged next to the
   trim (`status` shows it): the trim follows it by design.

**Tracking.** A PI controller on the frequency:

```
freq_ppb = I - kp * offset / dt        I += -ki * offset / dt        (kp 0.2, ki 0.02)
INC      = nominal * (1 + freq_ppb * 1e-9),   nominal = 2^32 * 1e9 / DP_CLK_HZ
```

* The frequency is bounded to ±200 ppm, and the integrator does not wind up.
* **Phase steps.** `TB_ADJ` is used only when no capture runs and |offset| > 20 µs, and
  never more than 1 µs per second. Normal tracking corrects the phase through the
  frequency only.
* **`TB_SET`** happens only at start-up and when |offset| > 1 s, for example when NTP first
  sets the system clock after boot. It never happens while a capture runs. Then the
  daemon slews and does the `TB_SET` after the capture.
* **External changes.** A jump of more than 1 ms beyond the worst-case slew counts as a
  step: someone set the timebase, or the system clock stepped. It is logged and is not
  integrated. An `INC` written by someone else is adopted.
* **Locked** means |offset| < 10 µs for 30 s. The lock is lost after 3 samples beyond
  50 µs, or after a set or a step.

**Why no steps during a capture.** The record timestamp of a frame is computed when it
leaves its FIFO:

```
ts = TB_NOW - cycles_since_SFD * INC + MAC_OFFSET
```

* A `TB_ADJ` or `TB_SET` while frames wait moves those frames by the full step.
* An `INC` change moves them only by cycles × ΔINC. For example, 1000 cycles at 50 ppm is
  0.2 ns, below the resolution.

So while `CTRL.ENABLE` or `FILL` is set, the daemon only writes `INC`. Another program that
depends on the timebase can hold steps off the same way. Replay, for example, releases
frames against the timebase. It creates `/run/pktrec/tb-hold.<pid>`, which is ignored once
that process has exited, or `/run/pktrec/tb-hold`, which holds until it is removed. A capture may still
see a frequency slew of up to 200 ppm right after the system clock jumps. Inter-frame
intervals are then off by up to that fraction (0.2 ns per µs of interval), and the
timestamps stay monotonic.

**State file.** The daemon writes `/run/pktrec/tb.json` every second:

* `state`, `locked`, `locked_since`,
* `offset_ns`, and the rms and max over the last 30 s,
* `freq_ppb` / `ppm` (applied now) and `freq_est_ppb` (the integrator),
* `inc_raw`, `last_set`, `sets`, `adj_steps`, `steps_detected`,
* `ntp_synced`, `capture_running`, `pid`, `updated_ns`.

`pktrec-web` shows it, and `pktrec-cap` reads it at the start. The daemon logs to the
journal: the start-up, every `TB_SET`, lock changes, and a summary once a minute
(`journalctl -u pktrec-tb`).

**Accuracy.** The measured tracking and absolute accuracy are in
[Timestamping](timestamping.md#timebase-and-absolute-time). In short: the timebase follows
`CLOCK_REALTIME` within a few hundred ns once locked, and absolute time is only as good as
the system clock's NTP synchronisation. Relative timing (between frames and between ports)
does not depend on any of this. When the daemon stops, `INC` keeps its last trim, so the
timebase free-runs at the learned frequency (holdover). A Linux PTP hardware clock
(`/dev/ptpN`) driver is not provided.

## Calibration file

The capture block's calibration registers reset on every bitstream load. Their values are
kept in **`/etc/pktrec/calibration.conf`**, an INI file. `pktrec-calibration.service`
(oneshot, enabled) applies it at every boot with `pktrec-tb apply-calibration`. It runs
after `pktrec-phy-watch.service` (PHY init) and before `pktrec-tb.service` and
`pktrec-web.service`. The result goes to `/run/pktrec/calibration.json`, where
`pktrec-tb status` and the web UI show it.

| Section / key | Register | Design default |
|---------------|----------|----------------|
| `[timebase] ppm` (or `ppb`, or raw `inc`) | `TB_INC_NS/FRAC`: INC = nominal × (1 + ppm/10⁶). The daemon's start frequency, and the holdover frequency. | 0 |
| `[capture] mac_offset_ns` | `MAC_OFFSET` (0x0A8): added to MAC-fallback timestamps | 52 |
| `[sfd] match` | `SFD_CTRL.MATCH_EN`: on = records carry PHY SFD timestamps | on |
| `[sfd] rx_window_min_ns`, `rx_window_max_ns` | `SFD_RX_WIN_MIN/MAX`: RX match window (raw MAC − SFD) | 100, 700 |
| `[sfd] tx_window_min_ns`, `tx_window_max_ns` | `SFD_TX_WIN_MIN/MAX`: TX pairing window | 0, 900 |
| `[sfd] min_low_cycles`, `min_high_cycles` | `SFD_MIN_LOW/HIGH`: glitch filter, dp_clk cycles | 25, 8 |
| `[port0..3] rx_offset_ns`, `tx_offset_ns` | `SFD_P_RX_OFFSET` / `SFD_P_TX_OFFSET` of the port | 0, 0 |

The SFD windows are global: the hardware has one pair for all four ports, not one per
port.

* **Missing keys.** A key that is missing leaves its register at the reset value.
* **Validation.** Unknown keys, values out of range and `min >= max` are errors. An RX
  window of 672 ns or wider (one minimum frame time) gets a warning. More than ±200 ppm is
  refused.
* **Running captures.** `apply-calibration` is refused while a capture runs (unless
  `--force`). `--dry-run` shows what it would write.
* **Package updates.** The file is a `CONFFILE`, so an image or package update never
  overwrites a tuned file.

To persist a calibration that you measured (the procedure is in
[Timestamping](timestamping.md#calibration-procedure)):

1. Set the registers, for example with
   `pktrec-phy sfd config --rx-win … --rx-offset 3 … --tx-offset …`, a write of
   `MAC_OFFSET`, and `pktrec-tb trim`, or let the daemon lock.
2. Check them with `pktrec-tb show-calibration`. It lists register, file and default for
   every key.
3. Run `pktrec-tb save-calibration`. It writes the file from the registers and keeps the
   previous one as `.bak`. The timebase frequency is saved only when the daemon has been
   locked for at least 10 minutes (`--min-locked`) and its frequency estimate moved less than
   0.5 ppm over that time (`--max-ppm-delta`; with chrony the estimate typically wanders
   about 0.5 ppm in 10 minutes); the mean estimate is saved. The command prints the measured
   movement either way. Otherwise the file keeps its previous `ppm` and says why
   (`--force-timebase` saves anyway). The
   SFD receive offsets are saved without the link watcher's per-link-up `0x0055`
   correction.

`save-calibration --defaults --stdout` prints the design defaults (the register reset
values). The shipped file holds the values measured on a ZCU106 with an Ethernet FMC Max
Rev-B instead (see [Timestamping](timestamping.md#calibration)).

Calibrate again after every bitstream change. The SFD sampler's clock phase can move
between builds.

## pktrec-web

The web server and its JSON API are described in [Web interface](web_ui).

