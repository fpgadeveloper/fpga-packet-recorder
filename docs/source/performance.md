# Performance

Unless dated otherwise, the results on this page were measured on 2026-10-13 on one ZCU106 with an Ethernet FMC Max
Rev-B on HPC0 and an FPGA Drive FMC Gen4 on HPC1, with a **Samsung 980 PRO 1TB** NVMe SSD in
slot 1 (PCIe Gen3 x1, XFS), running the Yocto image of this design (capture block register
map 1.2, recorder `fdrec_core` 1.2). Results with other SSDs will differ; the SSD's sustained
write rate is what matters.

## SSD recording budget

Method: the recorder's own test pattern generator (`fdrec --rate`), which models a source
that cannot be stalled, recording to a file on the SSD; `fdverify` checks every byte. This
measures what the SSD path can sustain independently of the Ethernet ports.

| Set rate | Size | Dropped | Result |
|----------|------|---------|--------|
| 400 MB/s | 10 GB | 0 | pass |
| 500 MB/s | 10 GB | 0 | pass |
| 600 MB/s | 10 GB | 0 | pass |
| 700 MB/s | 10 GB | 0 | pass |
| 725 MB/s | 10 GB | 0 | pass |
| 740 MB/s | 10 GB | 0 | pass |
| 800 MB/s | 10 GB | 490 MB | fail (delivered 742.8 MB/s) |
| 900 MB/s | 10 GB | 1.8 GB | fail (delivered 742.8 MB/s) |
| **700 MB/s** | **40 GB** | **0** | **pass, flat 699.8 MB/s, no slow-down when the SSD's cache filled** |

`fio` (direct, sequential, 4 GiB) gave 743 MB/s write and 804 MB/s read. The ceiling of about
743 MB/s is the PCIe Gen3 x1 link (with 128-byte payloads), not the SSD.
**Sustained budget: 700 MB/s.** The CPU load while recording was 2.5 to 4.6 % of the four
cores.

Four ports at line rate produce at most 476 MB/s (64-byte frames) to 499 MB/s (1518-byte
frames) of records (see [Description](description.md#recording-throughput-budget)): about 70 %
of the budget. With this SSD, Ethernet traffic cannot exceed what the SSD sustains. With
another SSD, check its sustained write rate after its SLC cache is full; the FPGA Drive
Recorder documentation describes the method (`fdbench.sh`).

## Lossless envelope

Method: sequence-numbered traffic, captured with `pktrec-cap`; a run passes when
`pktrec-cap` reports 0 drops at every stage (per-port FIFOs and recorder), the number of
records equals the number of frames sent, and the checks find every sequence number once and
in order. Line-rate traffic on P2/P3 comes from the on-board generators over the P2–P3 cable.
For the four-port 64-byte run, the PHYs of P0 and P1 were put into loopback so that their own
generators could load them at line rate.

| Traffic | Ports | Duration / frames | Data to SSD | Result |
|---------|-------|-------------------|-------------|--------|
| 64 B, line rate (1.488 Mframes/s) | 1 | 62 s / 85 000 000 | 119 MB/s | 0 drops |
| 64 B, line rate | 1 | 598 s / 890 000 000 | 119 MB/s | 0 drops; pcapng 92.6 GB, Wireshark tools report no warnings |
| 1518 B, line rate (81 274 frames/s) | 1 | 63 s / 4 800 000 | 117–124 MB/s | 0 drops |
| 64 B, line rate, both directions | 2 | 62 s / 170 000 000 | 238 MB/s | 0 drops |
| random 64..1087 B, line rate, both directions | 2 | 46 s / 16 000 000 | 250 MB/s | 0 drops |
| **64 B, line rate on all four ports** | 4 | 62 s / 340 000 000 (5.95 Mframes/s) | **476 MB/s** | **0 drops**, FIFO high-water ≤ 1.5 KB of 16 KB |
| **1518 B, line rate on all four ports** | 4 | 40 s / 9 600 000 | **500 MB/s** | **0 drops**, FIFO high-water ≤ 3.4 KB |
| TAP pair 0 inline, 973 + 848 Mb/s of 1518 B | 2 | 40 s / 2 846 511 | 109 MB/s | 0 capture drops, 0 forwarding drops |
| 64 B at 635 kframes/s from a PC | 1 | 640 s / 396 000 000 | 50 MB/s | 0 drops |

**Result: with this SSD, all four ports are captured losslessly at line rate at every frame
size.** 64-byte frames are the highest record rate and 1518-byte frames the highest byte rate
that four 1 Gb/s ports can deliver. Snap length and port enables are not needed for this
SSD; they reduce the data rate for slower SSDs (the snap length stores at most N bytes of
each frame: for example a snap length of 128 bytes turns a 1518-byte frame into a 144-byte
record).

**30-minute capture** (2026-10-14, same hardware, image with capture block register map
1.2 and recorder `fdrec_core` 1.2): all four ports enabled, both pairs in monitor mode, the
P2 and P3 generators at line rate with 1518-byte frames (140 000 000 frames each way),
20 000 frames/s from a PC on P1 and the LAN background on P0.

| Duration | Records | Data to SSD | Result |
|----------|---------|-------------|--------|
| 30 min 1 s | 313 462 888 | 481 GB, 280 MB/s steady | **0 drops**, 0 recorder data loss, 0 DMA errors; P2 and P3 records = 140 000 000 = frames sent = MAC receive count; FIFO high-water ≤ 4.9 KB, ring ≤ 1/32 full |

The raw file showed no hardware sequence gaps and no timestamps going backwards on any port,
and no gaps in the generator sequence numbers on P2 and P3.

**802.1Q-tagged frames** (2026-10-14): 100 000 frames of 1522 bytes (1518 bytes + one tag,
VID 100) from the P2 generator were captured on P3 completely: 100 000 records of 1522 bytes,
0 receive errors, 0 drops, every sequence number once and in order, VLAN ID 100 decoded by
`tshark`. A 1523-byte frame is counted as a receive error, as the 1522-byte maximum frame
length requires.

**Overload.** To check that overload is reported and never corrupts a file, a second program
wrote to the same SSD at 452 MB/s (`dd`, direct I/O) during a four-port 1518-byte line-rate
capture. The capture dropped about 407 000 frames per port; every drop was counted per port
in the capture result, the file header, the web interface's capture list and the pcapng
interface statistics (`isb_ifdrop` = sum of `epb_dropcount` = sequence gaps), `pktrec-cap`
exited with code 2 ("not lossless"), and the exported file had no duplicates, reordered or
corrupted frames.

## CPU load

| Situation | Load |
|-----------|------|
| Capture at 50 MB/s (64 B, 635 kframes/s, one port) | `pktrec-cap` 1.3 % of one core, load average 0.05 |
| Capture at 336 to 500 MB/s (four ports) | `pktrec-cap` 8 % of one core; about 24 % I/O wait on one core |

The CPU never touches the frame data during a capture.

## TAP forwarding

**Latency.** See [Port modes](modes.md#forwarding-latency): 8 ns × frame length + 917 ns,
± 15 ns (1.43 µs at 64 bytes, 13.06 µs at 1518 bytes), measured with a router and a PC as the
two devices.

**Bench measurements, 2026-10-14.** ZCU106 + Ethernet FMC Max, one board: pair 0 (P0/P1) in
TAP mode, P2 cabled to P0 and P3 to P1, so the P2 and P3 hardware generators are the two
devices and their checkers count what arrives. Generators at line rate (12-byte gaps) in
both directions at the same time, 802.1Q-tagged sequence frames (VID 100), counters cleared
before each run. The first table is from the bitstream of 2026-10-14 13:32, whose MACs still
used deficit idle count; the second from the release bitstream (2026-10-14 15:06, MACs
without deficit idle count).

| Traffic, both directions | Duration | Frames P2→P3 / P3→P2 | Lost / errors / bad | DROP_FWD | Forward FIFO max |
|--------------------------|----------|----------------------|---------------------|----------|------------------|
| 66 B (smallest tagged) | 60 s | 89 665 573 / 89 405 816 | 0 / 0 / 0 | 0 | 62 B |
| 1518 B | 60 s | 5 002 562 / 5 009 319 | 0 / 0 / 0 | 0 | 1514 B |
| 498 to 1521 B random | 60 s | 7 443 343 / 7 442 525 | 0 / 0 / 0 | 0 | 1518 B |
| 67 B (odd, fixed) | 30 s | 44 483 589 / 44 440 704 | 0 / 0 / 0 | 0 | 64 B |
| **66 B soak** | **10 min** | **874 012 663 / 874 080 371** | **0 / 0 / 0** | **0** | 62 B |

In every run the frames received on one TAP port equalled the frames transmitted on the
other, exactly. With mixed odd and even lengths (66 to 1089 bytes random, or 66/67
alternating) 2.5 × 10⁻⁵ to 3 × 10⁻⁴ of the frames were lost on the cable after the TAP
(the TAP itself forwarded every frame): the MACs' deficit idle count sent 11-byte gaps after
some odd-length frames and the receiving DP83867 dropped frames after them. The release
bitstream builds the MACs without deficit idle count (every gap ≥ 12 bytes, 13 after an
odd-length frame); with it the same mixed-length traffic is lossless:

| Traffic, both directions (release bitstream) | Duration | Frames P2→P3 / P3→P2 | Lost / errors / bad | DROP_FWD | Forward FIFO max |
|----------------------------------------------|----------|----------------------|---------------------|----------|------------------|
| 66/67 B alternating | 60 s | 87 810 592 / 87 819 380 | 0 / 0 / 0 | 0 | 64 B |
| 66 to 1089 B random | 60 s | 12 774 126 / 12 775 128 | 0 / 0 / 0 | 0 | 1086 B |
| 66 to 129 B random | 60 s | 64 740 894 / 64 748 280 | 0 / 0 / 0 | 0 | 126 B |
| 64/65 B alternating, untagged | 60 s | 89 874 885 / 89 882 016 | 0 / 0 / 0 | 0 | 62 B |
| **66/67 B alternating soak** | **10 min** | **863 663 413 / 863 671 822** | **0 / 0 / 0** | **0** | **64 B** |
| 66 B soak (control) | 10 min | 873 710 725 / 873 724 566 | 0 / 0 / 0 | 0 | 62 B |

Receive errors were 0 on all four ports in every run, and the forward FIFO never held more
than the frame being forwarded. Without deficit idle count, back-to-back odd-length frames
cost throughput: 1 extra byte of gap after each odd-length frame, so 66/67-byte traffic
carries about 1 % fewer frames than 66-byte traffic (863.7 against 873.7 million in 10
minutes). Here both devices are the board's own generators, which send with the same spacing
as the TAP; a faster device is described in
[Known limitations](known_limitations.md#ethernet).

* **Forwarding with capture:** 29 000 000 × 66 B each way (1.45 million frames/s per port)
  and 1 600 000 × 1518 B each way, forwarded at line rate while P0 and P1 were captured:
  every frame forwarded and captured, 0 capture drops, the exported pcapng files complete
  and in order (`check_pcap`). With the release bitstream: 87 000 000 × 66 B each way
  (174 000 000 records, 13.92 GB, 232 MB/s): 0 capture drops, 0 forwarding drops, both
  directions complete and in order, frame interval 679 to 698 ns (mean 688.0 ns).
* **Latency** (300 frames per size and direction, one frame in flight): 8 ns × frame length
  + 933 to 936 ns in both directions (64 B: 1446 ns, 1518 B: 13 077 ns median), jitter
  ±13 ns; 16 to 19 ns more than with the router and PC, the same at every size.
* **Link-state propagation:** P2's link taken down → P0 lost its link → P1 held down
  0.505 to 0.515 s later (0.5 s debounce) → P3 saw its link go down 0.255 to 0.258 s after
  that (5 of 5). When P2 came back, all four links were up again 6.9 to 7.4 s later. The
  opposite direction, with the release image (5 of 5): P3's link taken down → P1 lost its
  link (seen 1.11 s after the command) → P0 held by path idle + MII loopback with
  auto-negotiation off → P2 saw its link go down 0.57 to 0.59 s after P1's; all four links up
  again 6.8 s after P3 came back. The first direction, repeated with the release image
  (3 of 3), gave the same result.
* **Errored frames:** 1000 frames of 128 bytes sent error-terminated by the P2 generator → P0 counted 1000 receive
  errors, P3 received 1000 bad frames and 0 good ones; 1 000 000 at line rate (66 bytes):
  P0 and P3 receive errors both +1 000 000 exactly. Captured on P0, all 1000 records carry
  the bad-frame flag, and the exported pcapng marks them as CRC errors.
* **Inter-frame gap below 12 bytes** (P2 to P0, monitor mode, generator at line rate):
  12-byte gap 15 854 447 sent, all received; 11 bytes: 15 995 514 sent, 4 055 good and 37
  bad received; 8 bytes: 16 594 129 sent, 41 good and 258 bad. Hence the TAP never sends a
  gap below 12 bytes (see [Known limitations](known_limitations)).

## Timestamp accuracy

See [Timestamping](timestamping.md#measured-accuracy): 1 ns resolution, 0.40 to 0.52 ns rms
jitter between two ports.

## Replay accuracy

See [Replay](replay.md#measured-accuracy): inter-frame interval error with a standard
deviation of 6.65 to 9.36 ns and a maximum of 21 ns; back to back at 1 488 117 frames/s.

## Export and download

`pktrec-export` runs on one CPU core of the board and converts about **390 000 to 416 000
records per second**, independent of the frame size. Measured: 85 000 000 records in 3 min 38 s;
890 000 000 records (92.56 GB of pcapng) in 36 min 36 s; 396 000 000 records (41.18 GB of
pcapng) in 15 min 52 s.

A pcapng download from the web interface converts while it sends. For a 1 GB capture of
1518-byte frames the download ran at **110.6 MB/s** (1.026 GB in 9.27 s), limited by the
board's Gigabit Ethernet port. For small frames the conversion rate limits the download
instead: a capture of 64-byte frames at line rate takes longer to download than it took to
record. Capture files can also be downloaded raw and converted on a PC.
