# Software

The capture software runs on the board's Linux image and has two parts:

* **`pktrec-cap`** controls the capture hardware and records its record stream to the NVMe
  SSD.
* **`pktrec-export`** converts a capture file to pcapng for Wireshark.

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
pktrec-cap stats [--watch <sec>] [--clear]
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
| `--no-tb-set` | - | Leave the hardware timebase as it is. By default it is set to `CLOCK_REALTIME` before the start, so timestamps are UTC. |
| `--stats <sec>` | `1` | Live statistics interval. `0` turns them off. |
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

| Exit code | Meaning |
|-----------|---------|
| 0 | Complete, and no frame was dropped anywhere. |
| 2 | Complete, but frames were dropped (a per-port FIFO overflowed) or the recorder lost data. The capture is not lossless. |
| 1 | Error. |

### Sequence of operations

`pktrec-cap` follows the protocol documented in `include/pktrec_regs.h`.

**Start**

1. Select the capture block as the recorder source.
2. Set the timebase to `CLOCK_REALTIME`, and wait for its per-port copies to re-lock.
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
while a capture runs.

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
    start, and the interface name.
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

`test/check_pcap.py` compares what was sent with what was captured. It reports loss,
duplicates, reordering, intervals and the ISB drop counters. The procedure, including the
zero-drop criterion, is in `test/README.md`.
