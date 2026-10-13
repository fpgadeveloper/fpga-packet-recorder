# Third-party submodules and their licenses

This reference design is published by Opsero under the **MIT license** (see
`../LICENSE.txt`). It depends on one third-party component, brought in as a git
submodule so that the boundary between Opsero's MIT-licensed sources and the
third-party sources is unambiguous:

| submodule | upstream | license |
|-----------|----------|---------|
| `submodules/taxi` | https://github.com/fpganinja/taxi (FPGA Ninja, LLC) | **CERN-OHL-S-2.0** (dual-licensed: CERN Open Hardware Licence v2 Strongly Reciprocal, or a paid commercial license from FPGA Ninja) — a few files are MIT, as stated by their SPDX headers |

Nothing under `submodules/` is modified. Everything outside `submodules/` is
Opsero's and is MIT-licensed, including the block design, constraints, the
recorder RTL copied from the FPGA Drive Recorder, software and build scripts.

## What this design uses from Taxi

Nothing yet. The submodule is in place for the Ethernet FMC Max port subsystem
(Ethernet MACs, AXI-Stream infrastructure), which is added in a later
milestone. When it is, the exact Taxi source files pulled into the Vivado
project will be enumerated in a Tcl script under `../Vivado/scripts/` and
listed here by function and license.

## What the CERN-OHL-S-2.0 means for you

CERN-OHL-S is *strongly reciprocal*: if you distribute a product (including a
bitstream) that contains the Taxi sources or a design derived from them, you
must make the complete source of that design available under the same license
on request, including your modifications. The MIT-licensed parts of this
repository do not change that obligation for the Taxi-derived part of the
design. If that is not acceptable for your product, FPGA Ninja offers a
commercial license for Taxi (info@fpga.ninja) — see the upstream README.

The AMD IP used in the block design (Zynq UltraScale+ PS, DMA/Bridge Subsystem
for PCIe, AXI DMA, AXI interconnect, SmartConnect, processor system reset) is
provided by AMD under the Vivado tool license and needs no additional IP
license.

## Pinned version

The submodule is pinned to a specific Taxi commit (`cc70b27`, recorded in this
repository's git tree; `git submodule status` prints it). Update it
deliberately — Taxi is under active development and module interfaces change.

```
git submodule update --init --recursive
```
