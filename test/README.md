# Test tools

Host-side (and board-side) tools for testing the FPGA Packet Recorder with
sequence-numbered traffic. Everything is Python 3 with the standard library only
(scapy is optional), plus one POSIX shell script.

| Tool | Runs on | Root | What it does |
|------|---------|------|--------------|
| `gen_seq.py` | PC | raw/scapy: yes; pcap: no | Sequence-numbered UDP frames ("PRSQ" payload): sends them through an AF_PACKET socket, through scapy, or writes a pcap for `tcpreplay`. Writes a JSON summary of what was sent. |
| `board_pktgen.sh` | board (`pktrec-pktgen`) or PC | yes | Drives the kernel packet generator (pktgen) for 64..1518-byte frames at a given rate and count. Every frame carries pktgen's sequence number. |
| `check_pcap.py` | PC (or board: `pktrec-check-pcap`, slow) | no | Verifies a pcapng per interface and per stream: every sequence number exactly once, in order, the count matches what was sent, timestamps never go backwards. Reports loss, duplicates, reordering, intervals, bad-FCS/truncated frames and the ISB drop counters. |
| `pcapng_lint.py` | PC or board (`pktrec-pcapng-lint`) | no | Strict structural pcapng validator (stand-in for Wireshark where `tshark` is not installed). |
| `make_synth_capture.py` | PC | no | Writes a synthetic capture file (the hardware's record format) for testing the exporter without hardware. |
| `selftest_export.py` | PC | no | Builds `pktrec-export` and runs it with the validators on synthetic captures (clean, damaged, with drops, with too small a reorder window), and compares `pktrec-export --check` with `check_pcap.py`. |
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
| On-board generator (`pktrec-phy gen`) | Yes, any size up to 1518 bytes, on every port. |
| Python (`gen_seq.py --mode raw`) | No. It reaches roughly 100-300 kframes/s, which is enough for functional tests. |
| PC kernel pktgen (`board_pktgen.sh` run on the PC, as root) | Yes, both sizes. |
| `tcpreplay --topspeed` with a `gen_seq.py --mode pcap` file | Yes, both sizes. |
| Board GEM (`pktrec-pktgen`) | Expected to reach line rate for 1518-byte frames but not for 64-byte frames: without `clone_skb`, one A53 core builds every skb. The script prints the rate it achieved. |

## Acceptance procedure (monitor-mode capture to SSD)

The user guide's [Testing](../docs/source/testing.md) page has the full procedure; this is
the short form.

### Setup

* The SSD is mounted at `/mnt/rec` (the image mounts it at boot once it is formatted with
  `fdsetup-raid0.sh --single`). The ports are initialised at boot (`pktrec-phy init`).
* P2 and P3 are cabled to each other; the test PC's port is cabled to a free port (here P1).
* Criterion for every run: `pktrec-cap` exits with 0 (no frame dropped anywhere),
  `pktrec-export` exits with 0, and the sequence check (`pktrec-export --check` or
  `check_pcap.py`) reports PASS: every sequence number arrived exactly once, in order, with
  the counts matching what was sent, and `isb_ifdrop` is 0. The pcapng opens in Wireshark
  without warnings.

### 1. Line rate from the on-board generators (no external equipment)

```
sudo pktrec-phy chk 3 start
sudo pktrec-cap --ports 3 --duration 60 /mnt/rec/captures/lr64.cap &
sudo pktrec-phy gen 2 start --size 64 --count 85000000
wait
sudo pktrec-phy chk 3 status
sudo pktrec-phy path 2 idle
sudo pktrec-export --check --expect 85000000 /mnt/rec/captures/lr64.cap -o /dev/null
```

The generator frames carry the `gen_seq.py` payload, so `--check` and `check_pcap.py`
both verify them.

### 2. From the test PC

Board:

```
sudo pktrec-cap --ports 1 --duration 30 /mnt/rec/captures/p1_64.cap      # start first
```

PC, during the 30 s. Use a destination MAC that no switch knows:

```
sudo test/board_pktgen.sh -i <pc-if> -d 02:00:00:00:00:99 -s 64 -c 10000000 -o sent64.json
```

PC, after `pktrec-cap` has finished (the export streams over SSH; no copy needed):

```
ssh amd-edf@<board> pktrec-export --port 1 -o - /mnt/rec/captures/p1_64.cap > p1_64.pcapng
test/check_pcap.py p1_64.pcapng --sent sent64.json --interface P1
test/pcapng_lint.py p1_64.pcapng
```

Repeat with `-s 1518 -c 1000000`. Without root on the PC, use `tcpreplay`:

```
test/gen_seq.py --mode pcap -o seq64.pcap --size 64 --count 10000000 --summary sent64.json
sudo tcpreplay -i <pc-if> --topspeed seq64.pcap
```

### 3. Checking large captures

`check_pcap.py` checks about 6 500 records/s on the board's CPU (`pktrec-check-pcap`), which
is hours for a line-rate capture. Use `pktrec-export --check` on the board (export speed), or
stream the export to the PC and check there:

```
ssh amd-edf@<board> pktrec-export --port 0 -o - /mnt/rec/captures/run1.cap \
    | test/check_pcap.py /dev/stdin --expect 87000000
```

Any drop fails a run: `pktrec-cap` then exits with 2, the checkers report the missing
sequence numbers, and `isb_ifdrop` equals the sum of the `epb_dropcount` values.

## Root and permissions

* Sending raw frames needs root on the PC (`CAP_NET_RAW`). This applies to
  `gen_seq.py --mode raw/scapy`, `board_pktgen.sh` and `tcpreplay`.
* Writing a pcap (`gen_seq.py --mode pcap`) and every checker run as a normal user.
* On the board, `pktrec-cap` and `pktrec-pktgen` need root (`sudo`) for the recorder
  device, the UIO register maps and pktgen.
