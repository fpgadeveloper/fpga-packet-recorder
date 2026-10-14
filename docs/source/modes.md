# Port modes

The four ports form two pairs: **pair 0 = P0/P1** and **pair 1 = P2/P3**. Each pair is
either in **monitor** mode or in **TAP** mode, chosen at run time without a rebuild, from the
web interface or with `pktrec-phy mode`. The pairs are independent.

```{warning}
**No bypass relays.** A TAP pair forwards in the FPGA fabric: whenever the board is
unpowered, booting or reconfiguring, the link through the TAP is broken. See
[Hardware setup](hardware_setup).
```

Capture is the same in both modes: **each port records what it receives**. In TAP mode the
two directions of the tapped link are therefore the two ports' interfaces (P0 = the frames
sent by the device on P0 towards the device on P1, P1 = the other direction), and nothing is
recorded twice.

## Monitor mode

Both ports of the pair only receive. Use it for traffic from switch SPAN/mirror ports or
from any source that does not expect anything back.

* The PHYs still link up, so the devices connected to the ports see a normal link. They
  advertise 1000BASE-T full duplex only (see [Speed](#speed)).
* The ports transmit only idles, never a frame.
* Monitor mode is the state after boot.

## TAP mode

The two ports of the pair forward everything they receive to each other, so the two devices
on either side communicate through the board as if they were connected by a cable. The
forwarding happens entirely in the fabric, never through Linux.

### What the devices see

* **Frames are forwarded unmodified**, except for the FCS: the receiving MAC checks and
  strips it, and the transmitting MAC generates it again, so a correct frame comes out
  bit-identical. Frames shorter than the minimum are not padded.
* **Errored frames stay errored.** A frame that arrives with a bad FCS or a receive error is
  forwarded and ended with an error code (the 1000BASE-X `/V/` code groups in place of the
  FCS). The PHY turns that into a transmit error on the copper side, so the far device counts
  a receive error and discards the frame, as it would have with the original frame. The
  original wrong FCS value is not reproduced, and the far receiver may see the frame end a few
  bytes early: it sees *a* receive error, not the same bytes. The capture records the frame
  as received, with its bad-frame flag.
* **Latency:** the forwarding is store-and-forward: a frame is sent once it has been received
  completely, so the delay grows with the frame size (8 ns per byte, see the table below).
* **Inter-frame gap:** normally 12 bytes. When a device sends at full utilisation with a
  clock that is faster than the board's, the forward buffer fills up; above 3072 bytes the
  transmitter shortens the gap to 8 bytes until the buffer is below 2048 bytes again
  (dynamic inter-frame gap). IEEE 802.3 receivers must accept gaps down to 8 bytes.
* **Frames are never cut.** Frames that do not fit in the 16 KB forward buffer are dropped
  whole and counted (`DROP_FWD`), which can only happen when the traffic exceeds what the
  dynamic gap can absorb.
* **Link state** is propagated: when one device's link goes down, the board takes the link to
  the other device down too (see [Link-state propagation](#link-state-propagation)).

### Forwarding latency

Measured on 2026-10-13 on pair 0 inline between a router and a PC: one frame in flight per
direction (ping-paced), 300 frames per size and direction, latency from the start-of-frame
on the incoming cable to the start-of-frame on the outgoing cable, taken from the PHYs' SFD
indications with the calibration applied. Both directions agreed within 3 ns.

| Frame size (incl. FCS) | 64 B | 256 B | 512 B | 1024 B | 1518 B |
|------------------------|------|-------|-------|--------|--------|
| Median latency | 1429 ns | 2966 ns | 5012 ns | 9108 ns | 13060 ns |
| Min .. max | 1414 .. 1445 | 2950 .. 2979 | 4997 .. 5028 | 9092 .. 9123 | 13045 .. 13078 |

That is **8 ns × frame length + 917 ns, ± 15 ns**: the frame time (store-and-forward), 223 ns
of MAC/FIFO/PCS pipeline (from simulation) and 694 ns for the two PHYs, the SGMII links and
the transceivers. When the dynamic inter-frame gap is active, a backlog of up to 3 KB
(about 25 µs) can add to it.

You can measure it on your own setup with `pktrec-phy latency` (see
[Software](software.md#pktrec-phy)).

### Throughput

Measured on 2026-10-13, pair 0 inline between a router and a PC: 1518-byte frames at
973 Mb/s from the router side and 848 Mb/s from the PC side at the same time (the most the
traffic sources produced), captured on both ports for 40 s: counters symmetric (every frame
received on one port was transmitted on the other), 0 forwarding drops, 0 capture drops. The
dynamic inter-frame gap did not engage: the router's traffic never arrived faster than the
board sent it. Separately, 8-byte gaps were sent from the board's generator to the router
(20 000 × 1518 B) and between two DP83867s (10 000 000 × 64 B): every frame was received
without error.

## Switching modes

```
sudo pktrec-phy mode 0 tap          # pair 0 (P0/P1) inline TAP
sudo pktrec-phy mode 1 monitor      # pair 1 (P2/P3) receive only
sudo pktrec-phy mode status
```

or the mode buttons of the [web interface](web_ui). A mode change is refused while a
capture runs (the capture file records the mode at the start), unless `--force` is given to
`pktrec-phy`.

What happens to traffic during a switch:

* the links stay up;
* a frame that is being received or sent completes in the old mode;
* frames that are waiting in a buffer the port no longer uses (for example the forward buffer
  when going from TAP to monitor) are discarded and counted (`FLUSH`). No frame is ever
  truncated, corrupted, duplicated or reordered.

Measured on 2026-10-13: 10 switches between monitor and TAP while 1518-byte frames flowed
through pair 0 at 80 000 frames/s: 8 frames flushed in total, no receive errors at the far
devices, no link flaps; traffic through the TAP stopped in monitor mode and resumed in TAP
mode.

Replay and TAP mode exclude each other on a pair: a port cannot replay while its pair
forwards, and a pair cannot be put into TAP mode while one of its ports replays (see
[Replay](replay)).

## Speed

The forward path cannot bridge two different link speeds, so both devices of a TAP pair must
link at the same speed. At boot, `pktrec-phy-watch.service` runs `pktrec-phy init --1000-only`,
which makes all four PHYs advertise **1000BASE-T full duplex only**. Both devices of a pair
therefore link at 1 Gb/s or not at all, and a 10/100 Mb/s device does not link.
`pktrec-phy mode <pair> tap` warns when the two ports report different speeds.

Tapping or monitoring 10/100 Mb/s links is not supported by this release (see
[Known limitations](known_limitations)).

## Link-state propagation

On a direct cable, when one device's link goes down, the other device sees it go down too.
Through a TAP it would not: the PHY on the other port keeps its own link up. The link watcher
(`pktrec-phy watch`, run by `pktrec-phy-watch.service`) therefore propagates the copper link
state for pairs in TAP mode:

* when a port's copper link has been down for 0.5 s (`--debounce`), its partner's PHY is put
  into MII loopback (DP83867 `BMCR[14]`): the partner's copper link drops, so the device on
  the partner's side sees link down, while the PHY itself keeps running;
* when the port's link has been up again for 0.5 s, the loopback is released, the partner
  restarts auto-negotiation, and its link comes back;
* a port held in loopback by the watcher never propagates (no ping-pong). A released port gets
  6 s (`--grace`) to link before its own link-down counts: if its far device is really gone,
  the device on the other side sees its link come up for up to about 6 s, then go down again;
* when the pair leaves TAP mode or the watcher stops, every PHY it holds is released.

The watcher never powers a PHY down: on the Ethernet FMC Max, the DP83867 of P0 supplies the
clock of the other three PHYs, and powering it down takes down P1, P2 and P3 as well. Every
action is logged (`journalctl -u pktrec-phy-watch`). `--no-propagate` turns propagation off:

```
sudo systemctl edit pktrec-phy-watch
# in the editor:
[Service]
ExecStart=
ExecStart=/usr/bin/python3 -u /usr/bin/pktrec-phy watch --no-propagate
```

Status of the measurements (2026-10-13): putting a DP83867 into MII loopback was verified to
take its copper link down, so that the device on the other end sees link down; propagation
from P0 to P1 reacted within 0.9 s and the link and traffic came back after P0's link
returned. The complete propagation cycle in both directions with the loopback method has not
been measured yet.
