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

## TAP forwarding latency

See [Port modes](modes.md#forwarding-latency): 8 ns × frame length + 917 ns, ± 15 ns
(1.43 µs at 64 bytes, 13.06 µs at 1518 bytes).

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
