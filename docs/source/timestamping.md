# Timestamping

Every captured frame carries a 64-bit nanosecond timestamp from one timebase shared by all
four ports. This page describes how the timestamp is taken, what it means, how it is
calibrated, and how accurate it is.

## Summary

| Property | Value |
|----------|-------|
| Source | the DP83867 PHY's receive start-of-frame-delimiter (SFD) indication, sampled in the fabric |
| Resolution | 1 ns |
| Jitter between two ports (measured) | 0.40 to 0.52 ns rms, 2 to 3 ns peak-to-peak |
| Per-link-up offset uncertainty | about ±2.3 ns between the 1000BASE-T master and slave roles; a further +8 ns step that the PHY reports in register `0x0055` is corrected at every link-up |
| Fallback (no SFD match, flagged) | MAC timestamp: 16 ns quantisation, calibrated to within −4..+7 ns of the SFD scale |
| Timebase | 64-bit ns counter on a 250 MHz clock, disciplined to the system clock (NTP) |
| Absolute time | bounded by the accuracy of the board's NTP-synchronised system clock (measured: 25 ms off 35 min after boot with `systemd-timesyncd`, see below) |

Relative timing, between frames and between ports, does not depend on the system clock:
it stays at the SFD resolution.

## What a timestamp means

The DP83867 can indicate on a GPIO pin when it receives (GPIO_0) or transmits (GPIO_1) the
start-of-frame delimiter on the cable. The pin goes high at the SFD and stays high until the
end of the frame. `pktrec-phy init` configures both indications on all four PHYs
(`GPIO_MUX_CTRL` = `0x0012`).

A record's timestamp is **the time at which the PHY's receive SFD indication reached the
FPGA, on the shared timebase, plus the port's calibration offset**. The offset (see
[Calibration](#calibration)) removes the constant delays of the PHY's SFD detection, the
level translators and the routing, so the timestamp refers to the frame's SFD on the cable.
Everything behind the PHY (the SGMII link, the transceiver, the PCS, the MAC and their
variable latencies) is outside the measurement. This is why the SFD pins are used rather
than a timestamp at the MAC.

If the timebase was set from the system clock (the default), the timestamp is nanoseconds
since the Unix epoch (UTC).

## Sampling

The eight SFD pins (two per PHY) are sampled by ISERDESE3 primitives at four samples per
`dp_clk` cycle (one sample about every 1.0 ns), from an MMCM-generated ~500 MHz clock that is
phase-locked to the timebase clock. The first high sample after a low one marks the edge; its
timestamp is the timebase value of that cycle plus the sample position, minus the fixed
sampler pipeline. In simulation with the real ISERDESE3 and MMCME4 models, the error was
uniformly within (−1, 0] ns.

A glitch filter accepts an edge only if the pin was low for at least 100 ns before and stays
high for at least 32 ns after (a minimum frame keeps it high for 512 ns); rejected edges are
counted (`RX_GLITCH`, `TX_GLITCH`).

## Matching SFD indications to frames

The SFD indication arrives before the frame comes out of the MAC (measured: 171 to 203 ns
earlier). Each port queues its receive SFD timestamps (16 entries) and matches the oldest one
to every frame that starts at the MAC, using the MAC's own coarse timestamp of the frame as a
sanity check: `d = MAC timestamp − SFD timestamp` must fall within a window.

| Condition | Action |
|-----------|--------|
| `d` within the window | match: the record gets the SFD timestamp + the port's `RX_OFFSET` |
| `d` above the window (an indication without a frame) | the entry is discarded and counted (`RX_STALE`); the record gets flag bit 3; the next entry is tried |
| `d` below the window (the entry belongs to a later frame) | kept; this frame falls back to its MAC timestamp |
| no entry | the frame falls back to its MAC timestamp |

A frame that falls back gets its MAC timestamp (+ `MAC_OFFSET`) and **flag bit 2**, and is
counted in `RX_MISMATCH`. A missing indication costs only its own frame, and an extra one is
discarded at the next frame: an error never shifts the timestamps of later frames. The window
must stay narrower than one minimum frame time (672 ns at 1 Gb/s) so that the indications of
neighbouring frames cannot fall inside it. The shipped calibration uses 30 to 350 ns.

Frames that are dropped or not captured consume their queue entry too, so the matching stays
aligned whatever the capture does. The flags are visible in the capture file and, with
`pktrec-export --comments`, as pcapng packet comments.

Measured on 2026-10-13, 64-byte frames at line rate from the P2 generator to P3 for 600 s
(890 000 000 frames): every frame matched its SFD indication; `RX_MISMATCH`, `RX_STALE` and
the glitch counters stayed 0. During a 30-minute soak with traffic on all four ports
(about 1.5 billion frames), the glitch counters stayed 0 on every port.

## Measured accuracy

Method: P2 and P3 connected with a short CAT-5e cable (about 1 m), the generator on one port
sending 64-byte frames at 1000 frames/s to the other; for the same frame, the transmit SFD
timestamp of the sender and the receive SFD timestamp of the receiver are taken from the
ports' SFD log FIFOs. Measured on 2026-10-13 on a ZCU106 with an Ethernet FMC Max Rev-B,
over 19 link-ups (link restarted between runs), about 920 to 1920 frames per link-up.

| Quantity | Result |
|----------|--------|
| Spread of TX SFD (sender) → RX SFD (receiver), per link-up | **2–3 ns peak-to-peak, standard deviation 0.40–0.52 ns** |
| Mean, sender is the 1000BASE-T master | 241.2 ns (P2→P3), 240.9 ns (P3→P2) |
| Mean, sender is the slave | 236.6 ns (P3→P2), 236.9 ns (P2→P3) |
| Mean, sender is the slave and the master's register `0x0055` ≠ 0 (6 of 16 link-ups) | 244.5 ns (+8 ns) |
| Receive SFD to MAC (`RX_HEAD_DELTA`), all ports | 171 to 203 ns |
| MAC transmit to transmit SFD (`TX_LAT`) | 295 to 313 ns |

The spread includes two 1 ns samplers and both PHYs, so the sampler resolution is reached:
**1 ns resolution, less than 0.5 ns rms jitter.**

* **Master/slave.** The pin-to-pin delay depends on which PHY is the 1000BASE-T master of the
  link (a property of each link-up): the two directions differ by about 4.6 ns, i.e. about
  ±2.3 ns around the mean.
* **Register `0x0055`.** On some link-ups the master's DP83867 reports a non-zero value in its
  register `0x0055`; on those link-ups its receive latency is 8 ns longer (the receive SFD to
  MAC delay did not change, so this is a real change of the PHY's receive latency). The
  DP83867 datasheet describes this per-link-up variation of the receive SFD. The link watcher
  (`pktrec-phy-watch.service`) reads the register after every copper link-up and sets that
  port's `RX_OFFSET` to the calibrated value − 8 ns while it is non-zero
  (`--no-0055-correction` turns this off). The correction is derived from the measurement
  above; its effect on the residual offset has not been measured separately. The ±2.3 ns
  master/slave asymmetry is not corrected.
* **Time between consecutive frames.** Frames from the generator, captured with SFD
  timestamps, show inter-frame times in steps of about 8 ns (for example 672 ns ± 1 ns for
  99.5 % of back-to-back 64-byte frames, and a bimodal ±4 ns distribution at other rates): the
  PHY transmits on the 8 ns symbol grid of 1000BASE-T, so this is the real line timing, not
  timestamp noise.

The datasheet latencies of the DP83867 (201 ns transmit, 289 ns receive between MAC interface
and cable) do not add up to the measured pin-to-pin delay of about 239 ns: the SFD indications
are not exactly at the cable. They are, however, constant per link-up, which is what the
calibration needs.

## MAC fallback

A frame without a matching SFD indication is stamped by the MAC at its own SFD detection,
after the transceiver and PCS. That timestamp has a 16 ns quantisation (one 62.5 MHz MAC
clock) and a constant offset that `MAC_OFFSET` removes. Measured on 2026-10-13 (64-byte
frames at 10 000 frames/s): with `MAC_OFFSET` = −418 ns, MAC timestamps landed −4 to +7 ns from
the SFD timestamps of the same frames; the standard deviation of the inter-frame time was
7.4 ns with MAC timestamps and 4.0 ns with SFD timestamps.

## Calibration

The calibration lives in `/etc/pktrec/calibration.conf` and is written into the capture
block's registers at every boot by `pktrec-calibration.service` (`pktrec-tb
apply-calibration`), because the registers reset with every bitstream load. The image ships
the values measured on 2026-10-13 on a ZCU106 with an Ethernet FMC Max Rev-B:

| Key | Value | Meaning |
|-----|-------|---------|
| `[sfd] rx_window_min_ns`, `rx_window_max_ns` | 30, 350 | receive match window (measured 171..203 ns ± 150 ns margin) |
| `[sfd] tx_window_min_ns`, `tx_window_max_ns` | 150, 460 | transmit pairing window (measured 294..313 ns) |
| `[port0..3] rx_offset_ns` | −234 | measured TX→RX pin-to-pin delay 236.6..241.2 ns, minus about 5 ns for the ~1 m cable; P0/P1 use the value measured on P2/P3 |
| `[port0..3] tx_offset_ns` | 0 | the transmit SFD is the reference |
| `[capture] mac_offset_ns` | −418 | MAC fallback onto the SFD scale |
| `[timebase] ppm` | 11.67 | start frequency of the timebase discipline (a property of the individual board's crystal) |

These are good starting values for another ZCU106 with an Ethernet FMC Max Rev-B. They hold
for one bitstream: the phase of the SFD sampler clock can move between builds, so
**re-calibrate after every bitstream change**.

`pktrec-tb show-calibration` lists, for every key, the register value, the file value and the
design default. The file format is described in [Software](software.md#calibration-file).

### Calibration procedure

You need a short cable between P2 and P3 and pair 1 in monitor mode.

1. Clear and enable the SFD logs:
   ```
   sudo pktrec-phy sfd config --log on
   sudo pktrec-phy sfd status --clear
   ```
2. Send from P2 to P3 at a low rate (so that the 16-entry logs can be read before they
   overflow) and read both logs while it runs:
   ```
   sudo pktrec-phy gen 2 start --size 64 --rate 1000 --count 10000
   sudo pktrec-phy sfd log 2 --dir tx
   sudo pktrec-phy sfd log 3 --dir rx
   ```
   For the same frames, `RX_SFD(P3) − TX_SFD(P2)` = cable delay (about 5 ns per metre) +
   the receive indication delay − the transmit indication delay. Note its mean and spread.
   Repeat in the other direction (generator on P3, logs `3 --dir tx` and `2 --dir rx`).
3. Set `TX_OFFSET` = 0 on all ports and `RX_OFFSET` = −(mean − cable delay). A frame's receive
   timestamp then equals its transmit timestamp plus the cable delay. The remaining
   translator and routing delay of the transmit indication is small and constant, and cancels
   in every difference between two ports of the board.
4. Place the windows: `RX_DELTA_MIN/MAX` (in `pktrec-phy sfd status`) give the range of
   `MAC − SFD`. Centre the receive window on it with margin, but keep it narrower than
   672 ns, for example `pktrec-phy sfd config --rx-win <min−150> <max+150>`. Likewise use
   `TX_LAT_MIN/MAX` for `--tx-win`.
5. MAC fallback: set `MAC_OFFSET` = `RX_OFFSET` − median(`RX_DELTA`), so that a frame that
   falls back lands on the same scale within the MAC's 16 ns quantisation.
6. Save: `sudo pktrec-tb save-calibration` writes the file from the registers (the previous
   file is kept as `.bak`); check with `pktrec-tb show-calibration`.

Re-measure after a few link restarts to see the per-link-up variation (read register
`0x0055` of both PHYs with `pktrec-phy mdio`). Calibrate on link-ups where both PHYs report 0
in register `0x0055`, or stop the link watcher during the calibration: the watcher applies the
−8 ns correction on top of the configured offsets.

```{note}
`pktrec-tb save-calibration` also saves the timebase frequency. Run it while the timebase
discipline has been locked for a while (`pktrec-tb status`), otherwise it may store a
transient frequency (for example right after the system clock was stepped by NTP). The
daemon re-learns the frequency at every start anyway.
```

## Timebase and absolute time

The timebase (`pktrec_timebase`) is a 64-bit nanosecond counter with a 32-bit fraction on
`dp_clk` (249.975 MHz, from the PS PLL), advanced every cycle by a programmable increment
(nominally 4.0004 ns). Software can set it, step it and trim its rate. The same timebase
stamps the SFD indications and the MAC timestamps, and the replay scheduler releases frames
against it.

`dp_clk` is derived from the board's crystal, so the free-running timebase is only as
accurate as that crystal: on the measured board it ran 11.7 ppm slow against NTP (about
1 s per day). The **`pktrec-tb`** daemon (`pktrec-tb.service`) therefore disciplines the
timebase to the Linux system clock (`CLOCK_REALTIME`), which the image's NTP client keeps on NTP
through the board's RJ45 port:

* every second it measures the offset between the timebase and the system clock and steers
  the timebase frequency with a PI controller (bounded to ±200 ppm);
* it **never steps the timebase while a capture or a replay runs** (a step would move the
  frames waiting in the FIFOs or shift a replay schedule); it only adjusts the frequency then;
* "locked" means within 10 µs of the system clock for 30 s;
* the state goes into every capture file header (locked or not, offset, frequency) and is
  shown by the web interface.

If the daemon is not locked when a capture starts, `pktrec-cap` sets the timebase from the
system clock once, before the capture.

Measured on 2026-10-13 (board on a LAN, `systemd-timesyncd`, two boots):

| Quantity | Result |
|----------|--------|
| Lock after the first NTP step of the system clock (−19.9 s) | 31 s |
| Timebase − system clock, over 30 min (one-minute summaries) | −188 to +63 ns, rms typically 40 to 60 ns |
| Steps during captures and replays | none |
| Capture timestamp of frames sent by an NTP-synchronised PC, minus the PC's send time, 35 min after boot | −24.9 ms |

The last line is the **absolute accuracy**: the timebase follows the board's system clock
closely, but the system clock itself was still 12 ms off at its last NTP poll and drifting
by about −11.7 ppm, because `systemd-timesyncd` polls rarely (every 17 minutes at that point)
and had only partly learned the crystal's error. Absolute timestamps are therefore only as
good as the board's NTP synchronisation: how close the NTP server is, how often the client
polls, and how well it has learned the crystal's error. Relative timing between frames and
ports is unaffected.

When the daemon stops, the timebase keeps its last frequency and runs free. A Linux PTP
hardware clock (`/dev/ptpN`) is not provided.
