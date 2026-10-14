# Replay

A capture can be played back out of a port with its original inter-frame timing, with the
timing scaled, at a fixed interval, or back to back at line rate. The frames are read from
the capture file on the SSD through the recorder's playback path, and the moment each frame
is released to the transmitting MAC is decided in hardware, against the same timebase that
stamped the frames.

## Usage

```
sudo pktrec-replay <capture.cap> --iface P<n> --port <m> [--rate X | --topspeed | --gap NS]
```

* `--iface P<n>` selects the frames to replay: the frames that port n received in the
  capture.
* `--port <m>` is the port they are sent out of (0 to 3). It must be in a pair in monitor
  mode.
* Timing (one of):
  * default: the original timing; frame i leaves `ts_i − ts_first` after the first frame;
  * `--rate X`: the intervals divided by X (2 = twice as fast, 0.5 = half speed);
  * `--topspeed`: back to back at line rate, timestamps ignored;
  * `--gap NS`: a fixed start-to-start interval, timestamps ignored.
* `--loop N` plays the selection N times.

Only capture files (`.cap`, from `pktrec-cap` or the web interface's **raw** download) can be
replayed, not pcapng: the record headers carry the hardware timestamps, the port and the
flags. The full option list is in [Software](software.md#pktrec-replay).

Example: replay the frames received on P0 out of P3, twice as fast:

```
sudo pktrec-phy mode 1 monitor
sudo pktrec-replay /mnt/rec/captures/run1.cap --iface P0 --port 3 --rate 2
```

`pktrec-replay` prints the progress and a summary (frames and bytes sent, frames skipped,
underruns, lateness). Exit code 0 means every selected frame was sent on time (no underrun,
no parse error); 2 means it completed with underruns, parse errors or missing frames; 1 is an
error. Ctrl-C aborts cleanly: the frame on the wire is completed, and the port is returned to
its previous state.

## What is sent

* The frame sent is the captured bytes; the MAC appends a new FCS. Frames shorter than the
  Ethernet minimum go out as they were captured (no padding). Frames truncated by a snap
  length go out truncated.
* Frames captured with an error (bad FCS, receive error): skipped by default; `--keep-bad`
  sends them error-terminated (the receiver counts a receive error, as described for TAP
  forwarding in [Port modes](modes.md#what-the-devices-see)); `--bad-as-good` sends them with
  a valid FCS. The original FCS value cannot be reproduced.
* Frames longer than the port's maximum frame length (1522 bytes by default, one 802.1Q
  tag; `pktrec-phy maxlen` raises it) are cut by the transmitting MAC (see
  [Known limitations](known_limitations)).

## Timing

The replay block compares the release time of the next frame with the timebase on every
clock cycle:

```
release time of frame i = T0 + (ts_i − ts_first) / rate
```

`T0` is latched when the replay starts. A frame is **never released early, and at most one
timebase step (about 4 ns) late** when the transmitter is free. From the release to the
cable the delay is constant except for the MAC's 62.5 MHz clock, so the expected timing error
of a frame on the wire is within about ±16 ns. It does not accumulate: every release time is
absolute.

Timing is never corrected silently. A frame that cannot be sent on time is sent late and
counted: `LATE` counts frames released more than 100 ns (`--late-thresh`) after their target,
and `UNDERRUNS` counts the times the frame store ran empty before the next frame was due. A
frame is late when the stream from the SSD could not keep up, or when the capture holds
frames closer together than the output port can send them (for example traffic captured at
line rate from a device whose clock was faster than the board's, or a `--rate` above what the
line can carry).

The timebase discipline does not step the timebase while a replay runs.

## Ports, directions and TAP captures

One capture interface is replayed out of one port per run. A monitor-mode capture has one
interface per port. A TAP-mode capture has two interfaces per tapped link, one per direction
(P0 = the frames the device on P0 sent, P1 = the frames the device on P1 sent): replay one
direction per run. Replaying both directions of a pair at the same time is not implemented.

**Replay and TAP forwarding exclude each other on a pair.** `pktrec-replay` refuses an output
port whose pair is in TAP mode (switch it to monitor first), and while a port replays,
`pktrec-phy mode <pair> tap` is refused. The other pair is not affected: it may forward or
capture.

## Replay and capture at the same time

The recorder datapath moves data in one direction at a time, so a replay streamed from the
SSD cannot run while a capture records. For the case where both are needed, such as
replaying out of one port and capturing the result on another, `pktrec-replay --preload`
loads the frames into the replay block's own store (up to 128 KB of frame data or 2048
frames), releases the recorder, and then plays from the store while `pktrec-cap` records.
`--wait-capture S` starts the replay once a capture has started. Start the replay first,
in the background, and the capture after it:

```
sudo pktrec-replay /mnt/rec/captures/ref.cap --iface P3 --port 2 --preload --wait-capture 30 &
sleep 2
sudo pktrec-cap --ports 3 --duration 5 /mnt/rec/captures/replayed.cap
wait
```

The recorder device serves one program at a time, and the replay needs it for a moment to
load its frames (it then prints `waiting for a capture to start`). `pktrec-cap` waits for
a `pktrec-replay --preload` that is still loading, and both programs retry a busy recorder
for up to 5 s, so the commands also work without the `sleep`; the `sleep 2` only keeps
the two programs' messages apart. A replay without `--preload` holds the recorder for the
whole replay: a capture started meanwhile stops with "still busy after 5 s".

## Measured accuracy

Measured on 2026-10-13: reference captures made on P3 from the P2 generator (1200 × 64-byte
and 60 × 1518-byte frames), replayed out of P2 with `--preload` while P3 captured
(P2 and P3 connected by a short cable), compared with `test/compare_replay.py` (pairs the
frames by their bytes and compares the inter-frame intervals with the original). Every run:
0 frames lost, extra or reordered; 0 underruns; 0 late frames; release lateness at most 4 ns.

| Run | Interval error: mean / standard deviation / max | Median / 99th percentile of the error |
|-----|----------------------------------------------|----------------------------------------|
| 64 B, original timing | 0.00 / 6.65 / 16 ns | 7 / 10 ns |
| 1518 B, original timing | −0.02 / 7.05 / 10 ns | 8 / 10 ns |
| 64 B, `--rate 0.5` | 0.00 / 8.43 / 19 ns | 8 / 17 ns |
| 64 B, `--rate 2` | 0.00 / 9.36 / 21 ns | 4.5 / 20.5 ns |
| 64 B, `--topspeed` | 1 488 117 frames/s, mean spacing 671.99 ns (line rate: 672 ns) | |

The interval error includes the timestamp jitter of both captures.

Streamed from the SSD (no preload): 3 000 000 64-byte frames of a line-rate capture,
replayed both with `--topspeed` and with the original timing: all sent in 2.04 s, 0 underruns,
0 late frames (the timed run's largest lateness 4 ns), and the checker on the receiving port
counted 0 lost frames.

Bad-frame policies, measured with 50 bad and 50 good 128-byte frames: default 50 sent and 50
skipped; `--keep-bad` 100 sent, of which the receiving port counted 50 as errored;
`--bad-as-good` 100 good frames.

## Measuring the replay accuracy

With P2 and P3 connected by a short cable and pair 1 in monitor mode:

```
# 1. a reference capture on P3, from the generator on P2
sudo pktrec-cap --ports 3 --duration 5 /mnt/rec/captures/ref.cap &
sudo pktrec-phy gen 2 start --size 64 --rate 10000 --count 1200
wait
sudo pktrec-phy path 2 idle
# 2. replay it out of P2 and capture it again on P3
sudo pktrec-replay /mnt/rec/captures/ref.cap --iface P3 --port 2 --preload --wait-capture 30 &
sleep 2
sudo pktrec-cap --ports 3 --duration 5 /mnt/rec/captures/rep.cap
wait
# 3. convert both to pcapng
pktrec-export /mnt/rec/captures/ref.cap -o ref.pcapng
pktrec-export /mnt/rec/captures/rep.cap -o rep.pcapng
```

Copy the two pcapng files to a PC and compare them with the script from the repository's
`test/` folder:

```
python3 test/compare_replay.py ref.pcapng rep.pcapng
```

The replayed interface is P3 in both files by default; `--orig-iface` and `--replay-iface`
select others.

Add `--rate X` to both `pktrec-replay` and `compare_replay.py` for a scaled replay, or
`--topspeed` for a back-to-back one.
