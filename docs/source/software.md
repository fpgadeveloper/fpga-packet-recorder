# Software

The capture software runs on the board's Linux image. Its main parts are:

* **`pktrec-cap`** controls the capture hardware and records its record stream to the NVMe
  SSD.
* **`pktrec-export`** converts a capture file to pcapng for Wireshark.
* **`pktrec-tb`** keeps the hardware timebase on the system clock (NTP) and applies the
  persistent calibration at boot. See [Timebase discipline](#timebase-discipline-pktrec-tb)
  and [Calibration](#calibration).

Both are C programs in `sw/pktrec-apps`. The recipe `Yocto/meta-pktrec/recipes-apps/pktrec-apps`
installs them in the image. They reuse the FPGA Drive Recorder's kernel driver (`fdrec.ko`,
`/dev/fdrec0`) and its zero-copy recording loop:

* the AXI DMA fills buffers in hugepage memory,
* io_uring writes the same buffers to the file with `O_DIRECT`,
* the CPU only does the bookkeeping.

The test tools are described in [Testing](#testing) below and in `test/README.md`.

## Capturing: pktrec-cap

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
and records it in the file header (see [Capture file format](#capture-file-format)).

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

## Converting: pktrec-export

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

### Timestamp order and the reorder window

The hardware merges the records of the four ports round robin, as whole records, in the
order the frames complete. The stream is therefore not in timestamp order. For example,
a 64-byte frame on P0 that started after a 1518-byte frame on P1 is recorded first.

The exporter restores the order with a min-heap on the timestamp. A record is written once
the window holds more than `--window-records` records or `--window-bytes` bytes. At the
end of the file, the window is flushed in order.

**How far out of order the stream can be.** A record leaves its port at most one per-port
FIFO's worth of data (16 KB at 1 Gb/s, about 131 µs) after its frame ended, plus the
recorder's back-pressure time. With four ports, at most 4 × 16 KB = 64 KB of records can
overtake a frame. For minimum-size frames that is about 820 records (80 bytes each).

**Defaults.** The defaults, 65536 records and 4 MB, are 64 times that bound. A deeper FIFO
in a later design does not need a new option. The memory cost is the bytes held plus about
48 bytes per held record.

**If the window is too small.** A record older than the last one written can no longer be
put in order. It is still written, the summary counts it, and the exit code is 2. The
summary also reports the largest reorder distance seen; use it to size the window.

### Corruption and resynchronisation

Every record header is checked against the rules in `include/pktrec_format.h`:

* the marker nibble is `0xA`,
* the port is captured,
* `cap_len` ≥ 1,
* `cap_len + 4` ≤ `orig_len`, `cap_len + 4` ≤ `--max-frame` (and `orig_len` ≤ `--max-frame` unless truncated),
* the truncated flag is set exactly when `cap_len + 4 < orig_len`,
* `cap_len` ≤ snaplen.

If a header fails these checks, the exporter scans forward in 16-byte steps. It accepts a
header that passes the checks, whose timestamp is not more than 1 s older than the newest
timestamp seen, and which either continues its port's sequence number or is followed by
another valid header (or by fill, or by the end of the data).

The skipped bytes and resyncs are counted and reported. Sequence gaps across a resync are
reported as lost in a corrupt stretch, not as hardware drops.

All-zero 16-byte units are fill and are skipped silently.

### pcapng mapping

| pcapng | Content |
|--------|---------|
| SHB | `shb_hardware`: design, target, capture block and recorder versions. `shb_os`: the exporter's OS. `shb_userappl`: `pktrec-export <version>`. `opt_comment`: host, pair modes, ports, snaplen, start time, and how timestamps were produced. |
| IDB, one per captured port | `LINKTYPE_ETHERNET`. `snaplen`: the capture's snaplen, or 65535. `if_name`: `P0`..`P3`. `if_description`: port, mode and direction (inbound). `if_tsresol` = 9 (nanoseconds). `if_fcslen` = 0. `if_speed`: link speed at start. |
| EPB, one per frame, in timestamp order | 64-bit nanosecond timestamp split high/low. `caplen` = the stored bytes. `len` = `orig_len`. `epb_flags`: see below. `epb_dropcount`: frames the port dropped since the previous captured frame. |
| ISB, one per interface, at the end | `isb_starttime` / `isb_endtime` (capture start and stop). `isb_ifrecv` = frames that started on the port while it was enabled (`FRAMES_RX`, including bad and dropped frames). `isb_ifdrop` = frames the hardware dropped (`FRAMES_DROP`). `isb_filteraccept` = records written for the port. `isb_usrdeliv` = packets in this file. |

**`len` includes the FCS.** pcapng defines `len` as the original packet length on the
wire, and the record's `orig_len` includes the 4-byte FCS. The FCS itself is never stored
(`if_fcslen` = 0), so an untruncated frame has `caplen` = `len` − 4. Wireshark shows, for
example, "64 bytes on wire, 60 bytes captured" for a minimum-size frame. This is expected
and is not a truncation.

**`epb_flags`** has these fields:

* **Direction:** always inbound. A frame is always "received on port n". In TAP mode the
  partner port's TX carries the same frame, so one interface per port is enough.
* **Reception type:** broadcast or multicast from the destination MAC; otherwise
  promiscuous (the capture ports have no address).
* **Bit 24, CRC error:** set for records with the bad-frame flag. The MAC flags FCS
  errors, framing or symbol errors, and oversize frames this way; they are all reported
  through this bit.

**Timestamps.**

* When `pktrec-cap` set the timebase from `CLOCK_REALTIME` (the default), the timestamps
  are UTC.
* Otherwise, the exporter adds (start wall-clock time − timebase at start) to each
  timestamp.
* `--raw-ts` writes the timebase values unchanged.

In M1, timestamps are taken by the MAC at the start of frame delimiter. They have a 16 ns
quantisation plus a fixed, uncalibrated PHY/PCS latency. M2 adds PHY SFD timestamps.

## Timebase discipline: pktrec-tb

All timestamps come from one 64-bit nanosecond timebase in the capture block. It runs
on `dp_clk` (249.975 MHz) and adds `INC` (32.32 fixed point, about 4.0004 ns) on every
cycle. `dp_clk` comes from the PS PLL, so the timebase is only as accurate as the board's
crystal. The M1 bench board ran about 10.4 ppm slow: 0.9 s per day.

`pktrec-tb` (Python, `sw/pktrec-tools`, recipe `Yocto/meta-pktrec/recipes-apps/pktrec-tb`)
keeps the timebase on `CLOCK_REALTIME`. `systemd-timesyncd` keeps that on NTP through the
PS Ethernet port, so capture timestamps are absolute wall-clock times. It runs as
`pktrec-tb.service` (enabled), and uses the register access of `pktrec-phy`.

```
pktrec-tb status [--json]
pktrec-tb set [--force]
pktrec-tb trim (--ppm X | --ppb X | --inc 0xNNNNNNNNNN) [--force]
pktrec-tb daemon [--interval 1] [--lock-threshold 10000] [--lock-time 30] [-v] ...
pktrec-tb apply-calibration [--file F] [--dry-run] [--force] [--no-timebase]
pktrec-tb save-calibration [--file F | --stdout] [--defaults]
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

1. Load `INC` from the calibration (the start frequency).
2. `TB_SET` to `CLOCK_REALTIME`, plus one `TB_ADJ` for the few µs the register writes took.
3. Let the timebase run free for 8 s and fit a straight line to the offsets. Its slope is
   the frequency error. Correct `INC`, then `TB_SET` again.
4. Track.

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

**Accuracy.**

* **Timebase vs `CLOCK_REALTIME`.** A few µs, set by the userspace measurement jitter.
  The lock criterion is 10 µs.
* **Frequency after lock.** The averaged frequency (the integrator) settles within about
  0.1 ppm of the system clock's. The applied `INC` moves around it by kp × the read jitter
  per second: 0.2 ppm for 1 µs of jitter. In the simulation with 1 µs rms jitter it stays
  within ±0.3 ppm. The bench criterion is < 1 ppm of drift.
* **Absolute time.** Bounded by NTP. `systemd-timesyncd` (SNTP) on a LAN keeps
  `CLOCK_REALTIME` within roughly 1 ms of UTC; through the internet it is a few ms. The
  disciplined timestamps are absolute to that accuracy.
* **Relative timing** (between frames and between ports) does not depend on any of this.
  It stays at the SFD timestamping resolution (about 1 ns).
* **Holdover.** When the daemon stops, `INC` keeps its last trim, so the timebase
  free-runs at the learned frequency.

A Linux PTP hardware clock (`/dev/ptpN`) driver is not provided (Should #12 "plus",
deferred).

## Calibration

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

To persist a calibration that the bench measured (the procedure in `design.md`, "SFD
timestamping (M2)"):

1. Set the registers, for example with
   `pktrec-phy sfd config --rx-win … --rx-offset 3 … --tx-offset …`, a write of
   `MAC_OFFSET`, and `pktrec-tb trim`, or let the daemon lock.
2. Check them with `pktrec-tb show-calibration`. It lists register, file and default for
   every key.
3. Run `pktrec-tb save-calibration`. It writes the file from the registers and keeps the
   previous one as `.bak`. When the daemon is locked, it saves the daemon's frequency
   estimate rather than the momentary `INC`.

`save-calibration --defaults --stdout` prints the design defaults. The shipped file is
exactly that.

Calibrate again after every bitstream change. The SFD sampler's clock phase can move
between builds.

## Capture file format

A capture file is a 4096-byte header followed by the record stream:

* **Header** (`struct pktrec_file_header`, little-endian, in `include/pktrec_format.h`):
  * magic `PKTRCAP`, header and record-format versions,
  * pair modes, port mask, snaplen,
  * start and stop time, both as `CLOCK_REALTIME` and as timebase values, and the timebase
    increment,
  * stream bytes and record count,
  * recorder drop and DMA-error counts,
  * target, host name and design string,
  * per port: frames, bad frames, drops, bytes, truncated frames, records, link speed at
    start, and the interface name,
  * the timebase discipline at the start (`tb_disc_*`, taken from bytes that were reserved,
    so the layout of the other fields is unchanged and older files read as "not
    recorded"): flags (daemon running, locked, system clock NTP-synchronised, `TB_SET` done
    by `pktrec-cap`), the timebase - `CLOCK_REALTIME` offset measured right before the
    capture was enabled, the `INC` trim in ppb, and how long the daemon had been locked.
    `pktrec-cap info` prints them as `tb discipline`.
* **Header writes:** `pktrec-cap` writes the header at the start without the COMPLETE flag
  and rewrites it at the stop.
* **Interrupted captures:** a file without COMPLETE (power loss, crash) can still be
  exported. The exporter reads to the end of the file and leaves the counters out of the
  ISBs.

Each **record** is:

* a 16-byte header (`ts_ns`, `cap_len`, `orig_len`, `port`, `flags`, `seq`),
* the frame bytes (FCS excluded),
* padding to a multiple of 16 bytes.

**Records and buffers.** Records follow each other with no regard to the recorder's
buffer boundaries.

**Sequence numbers.** Every frame that starts on an enabled port gets the next per-port
sequence number, including frames the hardware then drops. A sequence gap is therefore
exactly the number of frames the hardware dropped.

## Testing

**On a PC, without hardware**, `test/selftest_export.py` builds `pktrec-export` and runs it
on synthetic capture files that `test/make_synth_capture.py` writes in the hardware's
format. The capture files contain:

* four ports,
* out-of-order timestamps,
* a bad-FCS frame,
* a snaplen-truncated frame,
* fill units.

It checks the results with the stdlib validators:

* the clean file exports with exit code 0, passes `pcapng_lint.py`, and `check_pcap.py`
  finds every sequence number exactly once and in order;
* a damaged file (a corrupted stretch plus a truncated tail) exports with exit code 2 and
  one resync, and exactly the destroyed frames are missing;
* hardware drops show up as `isb_ifdrop` = the sum of `epb_dropcount` = the missing frames;
* a reorder window that is too small is detected.

**On the board**, the M1 acceptance tests use sequence-numbered traffic:

* `test/gen_seq.py` (Python, raw socket or a pcap for `tcpreplay`),
* `test/board_pktgen.sh` (kernel pktgen; installed on the board as `pktrec-pktgen`).

**`test/test_pktrec_tb.py`** (PC, no hardware) tests `pktrec-tb`: the controller in
virtual time against a simulated timebase (start-up, lock, frequency estimate, no step
during a capture, system-clock steps, an INC changed by someone else), the calibration file
round trip and its validation, and every command end to end with `--sim`.

`test/check_pcap.py` compares what was sent with what was captured. It reports loss,
duplicates, reordering, intervals and the ISB drop counters. The procedure, including the
zero-drop criterion, is in `test/README.md`.
