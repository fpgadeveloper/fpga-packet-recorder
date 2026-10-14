# Testing

The repository's `test/` folder holds the tools used to verify the design, and they double as
examples. Everything is Python 3 with the standard library only (`scapy` is optional), plus one
shell script. The detailed reference is `test/README.md` in the repository.

| Tool | Runs on | What it does |
|------|---------|--------------|
| `gen_seq.py` | PC | sequence-numbered UDP frames ("PRSQ" payload): sends them through a raw socket or scapy, or writes a pcap for `tcpreplay`; writes a JSON summary of what was sent |
| `board_pktgen.sh` | PC, or board (`pktrec-pktgen`) | drives the Linux kernel packet generator (pktgen) at a given size, rate and count; every frame carries pktgen's sequence number |
| `check_pcap.py` | PC, or board (`pktrec-check-pcap`) | verifies a pcapng per interface and per stream: every sequence number exactly once, in order, the count matches what was sent, timestamps never go backwards; reports loss, duplicates, reordering, intervals, bad and truncated frames and the drop counters |
| `pcapng_lint.py` | PC, or board (`pktrec-pcapng-lint`) | strict structural pcapng validator (for machines without `tshark`) |
| `make_synth_capture.py` | PC | writes a synthetic capture file in the hardware's record format |
| `selftest_export.py` | PC | builds `pktrec-export` and checks it on synthetic captures |
| `compare_replay.py` | PC | replay timing accuracy: pairs original and replayed frames by their bytes, reports lost, extra and reordered frames and the inter-frame interval error |
| `test_pktrec_tb.py` | PC | tests `pktrec-tb` (controller, calibration file, commands) against a simulated timebase |

On the board, the hardware traffic generator and checker of every port (`pktrec-phy gen` /
`chk`) produce and verify sequence-numbered traffic at line rate without external equipment;
their frames have the same format as `gen_seq.py`, so `check_pcap.py` checks them too.

## Tests without hardware

```
test/selftest_export.py
python3 test/test_pktrec_tb.py
```

`selftest_export.py` must end with `PASS`. It exports synthetic captures (four ports,
out-of-order timestamps, a bad frame, a truncated frame, fill units) and checks that a clean
file exports with exit code 0 and every sequence number once and in order; that a damaged
file (a corrupted stretch and a truncated tail) exports with exit code 2, one resync and
exactly the destroyed frames missing; that hardware drops appear as `isb_ifdrop` = the sum of
`epb_dropcount`; and that a too-small reorder window is detected. If `tshark` or `capinfos`
is installed, it also checks that Wireshark reads the export without warnings.

The web interface can be tried and tested on a PC with stand-in tools (see
[Web interface](web_ui.md#how-it-works)): `sw/pktrec-web/test_api.py` exercises every API
endpoint against a server in `--mock` mode or on the board.

## RTL testbenches

```
cd Vivado
vivado -mode batch -notrace -source scripts/sim.tcl -tclargs all
```

`sim.tcl` runs the self-checking testbenches in the Vivado simulator; each prints `PASS` or
`FAIL`. The testbenches and what they check are listed in
[Architecture](design.md#verification).

```
vivado -mode batch -notrace -source scripts/sim_netlist.tcl
```

`sim_netlist.tcl` synthesizes the receive checker (`pktrec_gen_chk`) and runs `tb_pktrec_gen`
on its post-synthesis netlist, which catches logic that simulates correctly as RTL but is
built differently.

## Test traffic

At 1 Gb/s, line rate is 1 488 095 frames/s for 64-byte frames (672 ns apart) and 81 274
frames/s for 1518-byte frames (12 304 ns apart).

| Source | Line rate? |
|--------|------------|
| On-board generator (`pktrec-phy gen`) | yes, any size up to 1518 bytes |
| PC kernel pktgen (`board_pktgen.sh` as root) or `tcpreplay --topspeed` with a `gen_seq.py --mode pcap` file | depends on the PC's NIC; a PC NIC through a 1 Gb/s switch typically reaches 1518-byte line rate but not 64-byte line rate |
| `gen_seq.py --mode raw` | no (roughly 100 to 300 kframes/s), enough for functional tests |

Use a destination MAC address that no switch knows, or a direct cable, so that the test
traffic is not flooded onto your network.

## Monitor-mode capture test

The basic acceptance test: every frame sent is captured exactly once, in order, with zero
drops. The board's ports are initialised at boot; the SSD is mounted at `/mnt/rec`.

1. With P2 and P3 cabled to each other and pair 1 in monitor mode, generate on P2 at line
   rate and capture P3:
   ```
   sudo pktrec-phy chk 3 start
   sudo pktrec-cap --ports 3 --duration 60 /mnt/rec/captures/lr64.cap &
   sudo pktrec-phy gen 2 start --size 64 --count 85000000
   wait
   sudo pktrec-phy chk 3 status
   sudo pktrec-phy path 2 idle
   sudo pktrec-export /mnt/rec/captures/lr64.cap -o /mnt/rec/captures/lr64.pcapng
   pktrec-check-pcap /mnt/rec/captures/lr64.pcapng --interface P3 --expect-if P3=85000000
   ```
2. From a PC on any port (here P1), with `pktrec-cap --ports 1` running on the board:
   ```
   sudo test/board_pktgen.sh -i <pc-if> -d 02:00:00:00:00:99 -s 64 -c 10000000 -o sent64.json
   test/check_pcap.py capture.pcapng --sent sent64.json --interface P1
   test/pcapng_lint.py capture.pcapng
   ```
   Without root on the PC, write a pcap with `gen_seq.py --mode pcap --summary sent.json` and
   send it with `tcpreplay`.

**Pass criteria:** `pktrec-cap` exits with 0 (no frame dropped anywhere), `pktrec-export`
exits with 0, `check_pcap.py` reports PASS (every sequence number once, in order, the counts
match, `isb_ifdrop` = 0), and the pcapng opens in Wireshark without warnings.

For a four-port line-rate test, run generators on all ports. Ports whose far end is a device
that would answer or forward the test traffic need a sink that absorbs it. Connect P2 to P3
with a cable and let their generators load each other. Loading P0 and P1 from their own
generators through PHY loopback (`pktrec-phy mdio p0 0 0x4140`) is only possible with both
ports idle (`pktrec-phy mode 0 monitor`), with nothing but test equipment connected to them,
and with `--i-accept-lan-loop` on `gen`: `pktrec-phy` refuses a generator on a port in
loopback (see [Loop safety](modes.md#loop-safety)). Never do it on a pair that is cabled into a
network. Restore the PHYs with `0x1140` afterwards and check with `pktrec-phy safe`. The
results of these tests are on the [Performance](performance) page.

## Link-state propagation

Run this test on **pair 1 only** (P2 and P3, each cabled to a test device, for example two
ports of a PC), never on the pair that carries your network:

```
sudo pktrec-phy mode 1 tap
sudo pktrec-phy safe                       # SAFE
sudo pktrec-phy test linkdown 3            # P3: PHY power-down (simulated cable pull)
journalctl -u pktrec-phy-watch -n 5        # within ~1 s: P2 held by PHY power-down
sudo pktrec-phy status                     # P2, P3 down (PHY PD); P0, P1 unaffected
sudo pktrec-phy test linkup 3              # P3 back; ~0.5 s after its link: P2 released
sudo pktrec-phy test linkdown 2            # the other direction
sudo pktrec-phy test linkup 2
sudo pktrec-phy mode 1 monitor
```

Pass criteria: the device on the partner port sees its link go down within about 1 s and come
back after the simulated loss ends; the watcher logs one hold and one release per loss; P0 and
P1 keep their links and keep answering MDIO; `pktrec-phy safe` reports SAFE throughout.

`pktrec-phy test linkdown` uses the same method as the watcher: PHY power-down on P1 to P3 and,
on P0, path idle followed by MII loopback. It refuses pair 0 unless `--i-accept-lan-loop` is
given. A test hold is not remembered across `pktrec-phy init`: restarting the
`pktrec-phy-watch` service (whose start runs `pktrec-phy init`) or running `init` by hand
re-configures every PHY and so ends the simulated loss; repeat `test linkdown` afterwards. Do
not simulate a link loss by writing MII loopback into a PHY with `pktrec-phy mdio`:
on a pair in TAP mode this reflects the traffic of the device on the other port back to it (the
tool refuses it; see [Loop safety](modes.md#loop-safety)).

## Timestamp calibration

See [Timestamping](timestamping.md#calibration-procedure).

## TAP forwarding latency

With a pair in TAP mode between two devices, pace one frame size through it (one frame in
flight), for example with `ping` from the device behind P1 to a host behind P0, and read the
latency from the SFD logs:

```
sudo pktrec-phy latency --pair 0 --count 300
# meanwhile, on the device behind P1:
ping -I <if> -i 0.01 -c 400 -s 18 <host behind P0>     # 64-byte frames
```

ICMP payload sizes for the standard frame sizes (Ethernet + IPv4 + ICMP = 42 bytes of headers,
plus the 4-byte FCS): 64 B `-s 18`, 256 B `-s 210`, 512 B `-s 466`, 1024 B `-s 978`,
1518 B `-s 1472`. The echo request gives the P1 to P0 direction and the reply the P0 to P1
direction. Frames of other sizes fall outside the "main cluster" (median ± 500 ns) that the
tool also reports.

## Replay accuracy

See [Replay](replay.md#measuring-the-replay-accuracy).

## Web interface

```
sw/pktrec-web/test_api.py --url http://<board-ip>:8080 --lint
```

checks every API endpoint on the board: status, mode changes, a capture with live statistics,
the capture list, a streamed pcapng download (validated), deletion, and the error paths.
It switches the pair modes; use `--no-mode` when a pair in TAP mode carries live traffic.
