# File formats

A capture is stored on the SSD as a **capture file** (`.cap`): a 4 KB header followed by the
stream of records exactly as the hardware produced it. `pktrec-export` converts it to
**pcapng**. The C definitions of both formats are in `include/pktrec_format.h`; all
multi-byte fields are little-endian.

```none
offset 0      file header (struct pktrec_file_header, 4096 bytes)
offset 4096   record stream: record, record, ..., (all-zero fill units allowed)
```

The 4 KB header keeps the record stream aligned for `O_DIRECT` writes. `pktrec-cap` writes the
header when the capture starts (without the COMPLETE flag) and rewrites it at the stop with
the final counts.

## Record format v1

Every frame that a port captures becomes one record:

```none
record = 16-byte header + cap_len frame bytes (FCS not included) + 0..15 zero bytes
record size = 16 + ((cap_len + 15) & ~15)
```

| Bytes | Field | Type | Description |
|-------|-------|------|-------------|
| 0–7 | `ts_ns` | u64 | timestamp in ns on the shared timebase, at the frame's SFD (see [Timestamping](timestamping)) |
| 8–9 | `cap_len` | u16 | frame bytes stored (FCS excluded; at most the snap length and 16384) |
| 10–11 | `orig_len` | u16 | frame length on the wire, **including** the 4-byte FCS |
| 12 | `port` | u8 | receiving port, 0..3 (P0..P3) |
| 13 | `flags` | u8 | see below |
| 14–15 | `seq` | u16 | per-port frame sequence number (wraps) |

`flags`:

| Bit | Name | Meaning |
|-----|------|---------|
| 0 | BAD | the MAC flagged the frame: FCS error, framing or symbol error, or longer than the MAC's maximum length |
| 1 | TRUNC | truncated by the snap length (`cap_len + 4 < orig_len`) |
| 2 | TS_MAC | the timestamp is the MAC fallback (no matching SFD indication); 0 = PHY SFD timestamp |
| 3 | SFD_RESYNC | while this frame was matched, one or more stale SFD indications (without a frame) were discarded; the frame itself may still carry its SFD timestamp |
| 7:4 | marker | always `0xA` in a header |

Example, the first record of a capture of 200-byte frames on P1 (MAC timestamps):

```none
5f 1e 26 c5 fc 2a de 18 | c4 00 | c8 00 | 01 | a4 | 00 00 | 02 50 4b 54 52 43 ...
ts_ns                     cap_len orig_len port flags seq    frame bytes (196), then 12 zero bytes
                          = 196   = 200         0xA, TS_MAC
```

**Record order.** Records of one port are in arrival order. The hardware merges the four
ports round robin, one whole record at a time, in the order the frames complete, so records
of different ports are **not** in strict timestamp order: a 64-byte frame on P0 that started
after a 1518-byte frame on P1 is recorded first. Readers that need timestamp order (the pcapng
exporter) reorder within a bounded window: a record leaves its port at most one per-port
FIFO's worth of data (16 KB, about 131 µs at 1 Gb/s) after its frame ended, plus the time the
recorder held off the merge.

**Records and buffers.** The stream has no relation to the recorder's DMA buffer boundaries:
a record may span buffers. Read the stream as one continuous byte stream.

**Fill.** At a record boundary the stream may contain 16-byte units that are all zero (used to
push the last data through the DMA when a capture stops). A fill unit has a zero marker, so it
is never mistaken for a header. Skip it.

**Sequence numbers and drops.** Every frame that starts while its port is enabled for capture
gets the port's next sequence number, including frames that the hardware then drops. A gap in
a port's sequence numbers (modulo 2¹⁶) is therefore exactly the number of frames the hardware
dropped there.

**Validity checks.** A reader can verify every header:

* `(flags & 0xF0) == 0xA0`,
* `port < 4`,
* `cap_len >= 1` and `cap_len + 4 <= orig_len`,
* the TRUNC flag is set exactly when `cap_len + 4 < orig_len`.

If a header fails, the reader has lost framing: it can scan forward 16 bytes at a time for the
next unit that passes the checks, preferably one whose `seq` continues its port's sequence.

A minimal Python reader:

```python
import struct

def records(path):
    with open(path, "rb") as f:
        f.seek(4096)                      # skip the file header
        data = f.read()                   # (stream it for large files)
    off = 0
    while off + 16 <= len(data):
        if data[off:off + 16] == bytes(16):
            off += 16                     # fill unit
            continue
        ts, cap_len, orig_len, port, flags, seq = struct.unpack_from("<QHHBBH", data, off)
        assert flags & 0xF0 == 0xA0, "lost framing at %d" % off
        yield ts, port, seq, flags, orig_len, data[off + 16: off + 16 + cap_len]
        off += 16 + ((cap_len + 15) & ~15)
```

## Capture file header

`struct pktrec_file_header`, 4096 bytes, zero-padded. The `tb_disc_*` fields were added in
bytes that were reserved before, without a version change: older files have zeros there
("not recorded").

| Offset | Field | Type | Description |
|--------|-------|------|-------------|
| 0 | `magic` | char[8] | `"PKTRCAP\0"` |
| 8 | `header_version` | u32 | 1 |
| 12 | `header_size` | u32 | 4096 |
| 16 | `record_format` | u32 | 1 |
| 20 | `flags` | u32 | [0] COMPLETE (rewritten at the stop), [1] the timebase was set from `CLOCK_REALTIME` before the start, [2] stopped by the size limit, [3] stopped by the duration limit, [4] a DMA or I/O error ended the capture |
| 24 | `cap_version` | u32 | capture block VERSION register |
| 28 | `fdrec_version` | u32 | recorder (`fdrec_core`) version |
| 32 | `num_ports` | u32 | 4 |
| 36 | `port_mask` | u32 | ports enabled for capture |
| 40 | `pair_mode` | u32 | bit p = pair p in TAP mode (0 = monitor) |
| 44 | `snaplen` | u32 | snap length, 0 = whole frames |
| 48 | `start_time_ns` | u64 | `CLOCK_REALTIME` at the start |
| 56 | `stop_time_ns` | u64 | `CLOCK_REALTIME` at the stop |
| 64 | `tb_start_ns` | u64 | timebase right after the start |
| 72 | `tb_stop_ns` | u64 | timebase at the stop |
| 80 | `tb_inc` | u64 | timebase increment per clock, ns in 32.32 fixed point |
| 88 | `data_bytes` | u64 | valid record-stream bytes after the header |
| 96 | `records` | u64 | records in the stream |
| 104 | `rec_drop_beats` | u64 | data lost in the recorder (0 by design in capture mode) |
| 112 | `dma_errors` | u64 | DMA errors reported by the driver |
| 120 | `target` | char[32] | for example `zcu106` |
| 152 | `hostname` | char[64] | |
| 216 | `design` | char[32] | design version string |
| 248 | `port[4]` | 4 × 80 bytes | per-port statistics, below |
| 568 | `tb_disc_flags` | u32 | timebase discipline at the start: [0] fields valid, [1] daemon running, [2] locked, [3] system clock NTP-synchronised, [4] `pktrec-cap` set the timebase at the start |
| 572 | `tb_disc_locked_s` | u32 | seconds the daemon had been locked |
| 576 | `tb_disc_offset_ns` | s64 | timebase − `CLOCK_REALTIME`, measured right before the capture was enabled |
| 584 | `tb_disc_freq_ppb` | s64 | timebase frequency trim at the start, ppb |
| 592 | `tb_disc_time_ns` | u64 | `CLOCK_REALTIME` of that measurement |
| 600 | reserved | | zero |

Per-port statistics (`struct pktrec_file_port`, 80 bytes, copied from the capture block's
counters at the stop):

| Offset | Field | Type | Description |
|--------|-------|------|-------------|
| 0 | `frames_rx` | u64 | frames that started on the port while it was enabled (including bad and dropped frames) |
| 8 | `frames_bad` | u64 | frames flagged bad by the MAC |
| 16 | `frames_drop` | u64 | frames dropped by the hardware |
| 24 | `bytes_rx` | u64 | bytes received, including the FCS |
| 32 | `bytes_drop` | u64 | bytes dropped |
| 40 | `frames_trunc` | u64 | frames truncated by the snap length |
| 48 | `records` | u64 | records written for the port |
| 56 | `speed_mbps` | u32 | link speed at the start (0 = link down) |
| 60 | `flags` | u32 | [0] enabled for capture, [1] link up at the start |
| 64 | `if_name` | char[16] | `"P0"`..`"P3"` |

When the capture has stopped, `frames_rx = records + frames_drop` on every port.
`pktrec-cap info <file>` prints the header.

**Interrupted captures.** A file without the COMPLETE flag (power loss, crash) can still be
exported: the exporter reads to the end of the file and leaves the counters out of the
interface statistics.

## pcapng mapping

`pktrec-export` writes one Section Header Block, one Interface Description Block per captured
port, the frames as Enhanced Packet Blocks in timestamp order, and one Interface Statistics
Block per interface at the end.

| pcapng block | Content |
|--------------|---------|
| SHB | `shb_hardware`: design, target, capture block and recorder versions. `shb_os`: the exporter's OS. `shb_userappl`: `pktrec-export <version>`. `opt_comment`: host, pair modes, ports, snap length, start time, and how the timestamps were produced. |
| IDB, one per captured port | link type Ethernet. `snaplen`: the capture's snap length, or 65535. `if_name`: `P0`..`P3`. `if_description`: port, mode and direction, for example "Ethernet FMC Max port P0, TAP pair 0 (P0<->P1), forwarded to P1". `if_tsresol` = 9 (nanoseconds). `if_fcslen` = 0. `if_speed`: link speed at the start. |
| EPB, one per frame | 64-bit nanosecond timestamp. `caplen` = `cap_len`. `len` = `orig_len`. `epb_flags`: below. `epb_dropcount`: frames the port dropped since its previous captured frame (from the sequence gap). With `--comments`, a packet comment on frames with a MAC timestamp or an SFD resync. |
| ISB, one per interface | `isb_starttime` / `isb_endtime`: capture start and stop. `isb_ifrecv` = `frames_rx`. `isb_ifdrop` = `frames_drop`. `isb_filteraccept` = records written for the port. `isb_usrdeliv` = packets in this file. |

**`len` includes the FCS.** The original length on the wire includes the 4-byte FCS, but the
FCS itself is never stored (`if_fcslen` = 0), so an untruncated frame has `caplen` = `len` − 4.
Wireshark shows, for example, "64 bytes on wire, 60 bytes captured" for a minimum-size frame.
This is expected and is not a truncation.

**`epb_flags`:**

* direction: always **inbound**. A frame is always "received on port n"; in TAP mode the
  partner port transmits the same frame, so one interface per port describes the link
  completely;
* reception type: broadcast or multicast from the destination address, otherwise
  promiscuous;
* bit 24, **CRC error**: set for records with the BAD flag (FCS errors, framing or symbol
  errors and oversize frames are all reported through this bit).

**Timestamps.** When the timebase was set from, or disciplined to, the system clock (the
default), the timestamps are UTC. Otherwise the exporter adds the difference between the
start wall-clock time and the timebase at the start. `--raw-ts` writes the timebase values
unchanged.

## Exporter: reorder window and resynchronisation

The exporter restores timestamp order with a min-heap. A record is written once the window
holds more than `--window-records` records (default 65536) or `--window-bytes` bytes of
frames (default 4 MB). With four ports, at most 4 × 16 KB of records can overtake a frame
(about 820 records of minimum-size frames), so the defaults are about 64 times that bound.
A record that arrives later than the window allows is still written (out of order), counted,
and the exit code is 2; the summary reports the largest reorder distance seen.

The exporter checks every record header (the checks above, plus `cap_len` against the snap
length and the largest frame the hardware stores). If a header fails, it scans forward in
16-byte steps and accepts a header that passes the checks, whose timestamp is not more than
1 s older than the newest timestamp seen, and which either continues its port's sequence or is
followed by another valid header, fill, or the end of the data. Skipped bytes and resyncs are
counted; sequence gaps across a resync are reported as lost in a corrupt stretch, not as
hardware drops.

Exit codes: 0 clean; 2 written but with anomalies (corrupt stretches skipped, records later
than the window, a truncated tail, or recorder data loss recorded in the header); 1 error.
