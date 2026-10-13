# Test tools

Host-side (and board-side) tools for testing the FPGA Packet Recorder with
sequence-numbered traffic. Everything is Python 3 with the standard library only
(scapy is optional), plus one POSIX shell script.

| Tool | Runs on | Root | What it does |
|------|---------|------|--------------|
| `gen_seq.py` | PC | raw/scapy: yes; pcap: no | Sequence-numbered UDP frames ("PRSQ" payload): sends them through an AF_PACKET socket, through scapy, or writes a pcap for `tcpreplay`. Writes a JSON summary of what was sent. |
| `board_pktgen.sh` | board (`pktrec-pktgen`) or PC | yes | Drives the kernel packet generator (pktgen) for 64..1518-byte frames at a given rate and count. Every frame carries pktgen's sequence number. |
| `check_pcap.py` | PC or board (`pktrec-check-pcap`) | no | Verifies a pcapng per interface and per stream: every sequence number exactly once, in order, the count matches what was sent, timestamps never go backwards. Reports loss, duplicates, reordering, intervals, bad-FCS/truncated frames and the ISB drop counters. |
| `pcapng_lint.py` | PC or board (`pktrec-pcapng-lint`) | no | Strict structural pcapng validator (stand-in for Wireshark where `tshark` is not installed). |
| `make_synth_capture.py` | PC | no | Writes a synthetic capture file (the hardware's record format) for testing the exporter without hardware. |
| `selftest_export.py` | PC | no | Builds `pktrec-export` and runs it with the validators on synthetic captures (clean, damaged, with drops, with too small a reorder window). |
| `pcapng_reader.py` | - | - | The pcapng parser used by the checkers. |

## Self-test on a PC (no hardware)

```
test/selftest_export.py
```

It must end with `PASS`. If `tshark` or `capinfos` is installed, it also checks that
Wireshark reads the export without warnings.

## Test traffic

### Sequence numbers

* `gen_seq.py` puts `"PRSQ"`, a stream id (u32) and a 64-bit sequence number at the start
  of the UDP payload. That fits a minimum-size frame: 64 bytes on the wire, including the
  FCS.
* pktgen puts its own header there: magic `0xbe9be955` and a 32-bit sequence number.
  `check_pcap.py` identifies a pktgen stream by its source MAC and UDP source port.
* `board_pktgen.sh` forces `clone_skb 0` and `burst 1`. pktgen sends a cloned or burst skb
  unchanged, with the same sequence number, so with those settings the frames would look
  like duplicates.

### Rates

At 1 Gb/s, line rate is:

* 64-byte frames: 1 488 095 frames/s (672 ns apart).
* 1518-byte frames: 81 274 frames/s (12 304 ns apart).

| Source | Line rate? |
|--------|------------|
| Python (`gen_seq.py --mode raw`) | No. It reaches roughly 100-300 kframes/s, which is enough for functional tests. |
| PC kernel pktgen (`board_pktgen.sh` run on the PC, as root) | Yes, both sizes. |
| `tcpreplay --topspeed` with a `gen_seq.py --mode pcap` file | Yes, both sizes. |
| Board GEM (`pktrec-pktgen`) | Expected to reach line rate for 1518-byte frames but not for 64-byte frames: without `clone_skb`, one A53 core builds every skb. The script prints the rate it achieved. |

## M1 acceptance procedure (monitor-mode capture to SSD)

### Setup

* The board runs the M1 image. The SSD is mounted at `/mnt/rec`, for example with
  `fdsetup-raid0.sh`.
* The ports are initialised with `pktrec-phy init`.
* The test PC's 1G port is cabled to OP080 **P1**. P0 is cabled to the router. P2 and P3
  are cabled to each other.
* Criterion for every run: `pktrec-cap` exits with 0 (no frame dropped anywhere).
  `pktrec-export` exits with 0. `check_pcap.py` reports PASS, meaning every sequence
  number arrived exactly once, in order, with the counts matching what was sent, and
  `isb_ifdrop` is 0. The pcapng opens in Wireshark without warnings.

### 1. Single port, P1, from the test PC

Board:

```
pktrec-cap --ports 1 --duration 30 /mnt/rec/m1_p1_64.cap      # start first
```

PC, during the 30 s. Use a destination MAC that no switch knows, and the PC interface
cabled to P1:

```
sudo test/board_pktgen.sh -i <pc-if> -d 02:00:00:00:00:99 -s 64 -c 10000000 -o sent64.json
```

Board, after `pktrec-cap` has finished:

```
pktrec-export /mnt/rec/m1_p1_64.cap -o /mnt/rec/m1_p1_64.pcapng
```

PC:

```
scp amd-edf@<board>:/mnt/rec/m1_p1_64.pcapng .
test/check_pcap.py m1_p1_64.pcapng --sent sent64.json --interface P1
test/pcapng_lint.py m1_p1_64.pcapng
```

Repeat with `-s 1518 -c 1000000`. Without root on the PC, use `tcpreplay`:

```
test/gen_seq.py --mode pcap -o seq64.pcap --size 64 --count 10000000 --summary sent64.json
sudo tcpreplay -i <pc-if> --topspeed seq64.pcap
```

### 2. Four ports

* P1 gets line-rate traffic from the PC, as in step 1.
* P0 gets traffic from the board itself: `pktrec-pktgen` on `end0` with an unknown
  destination MAC. The router floods it to P0.
* P2 and P3 are cabled to each other. With nothing transmitting on them, they carry no
  test traffic: they are captured (idle) but not checked. A sequence-numbered load on
  P2/P3 needs a transmit source on one of them, such as the M6 replay path or a second
  PC NIC.

```
pktrec-cap --duration 60 /mnt/rec/m1_4p.cap
sudo pktrec-pktgen -i end0 -d 02:00:00:00:00:98 -s 1518 -c 2000000 -o /tmp/sent_p0.json
```

Check each interface against its own sender summary:

```
test/check_pcap.py m1_4p.pcapng --sent sent64.json --interface P1
test/check_pcap.py m1_4p.pcapng --sent sent_p0.json --interface P0
```

On P0, frames from the router itself (ARP, LLDP, ...) are counted as "other" and are not
checked.

### 3. Lossless envelope (M1 extract)

Run the 4-port test at 64 B and 1518 B for at least 60 s each. Record the following from
the `RESULT` line of `pktrec-cap`, the per-port FIFO high-water marks, and the `bp`
(merge back-pressure) column of the live statistics:

* frames
* drops
* MB/s

Any drop fails the run. `pktrec-cap` then exits with 2, `check_pcap.py` reports the
missing sequence numbers, and `isb_ifdrop` equals the sum of the `epb_dropcount` values.

## Root and permissions

* Sending raw frames needs root on the PC (`CAP_NET_RAW`). This applies to
  `gen_seq.py --mode raw/scapy`, `board_pktgen.sh` and `tcpreplay`.
* Writing a pcap (`gen_seq.py --mode pcap`) and every checker run as a normal user.
* On the board, `pktrec-cap` and `pktrec-pktgen` need root (`sudo`) for the recorder
  device, the UIO register maps and pktgen.
