# Third-party submodules and their licenses

This reference design is published by Opsero under the **MIT license** (see
`../LICENSE.txt`). It depends on one third-party component, brought in as a git
submodule so that the boundary between Opsero's MIT-licensed sources and the
third-party sources is unambiguous:

| submodule | upstream | license |
|-----------|----------|---------|
| `submodules/taxi` | https://github.com/fpganinja/taxi (FPGA Ninja, LLC) | **CERN-OHL-S-2.0** (dual-licensed: CERN Open Hardware Licence v2 Strongly Reciprocal, or a paid commercial license from FPGA Ninja) — a few files are MIT, as stated by their SPDX headers |

Nothing under `submodules/` is modified. Everything outside `submodules/` is
Opsero's and is MIT-licensed, including the wrapper that instantiates the Taxi
modules (`Vivado/src/hdl/pktrec_eth_ports.v` and `pktrec_eth_ports_core.sv`), the
rest of the packet-recorder RTL, the block design, constraints, the recorder RTL
copied from the FPGA Drive Recorder, software and build scripts.

## What this design uses from Taxi

The four Ethernet FMC Max (OP080) ports are built from the Taxi transport
library: there is no AMD Ethernet IP in the design. Opsero's MIT-licensed
wrapper `../Vivado/src/hdl/pktrec_eth_ports.v` / `pktrec_eth_ports_core.sv`
instantiates the Taxi modules and adds the register block; the M0 path
(`pktrec_m0_path.v`) and the capture ports (`pktrec_cap_port.sv`,
`pktrec_axis_async_fifo.sv`) use Taxi FIFOs and synchronisers. The exact source
files pulled into the Vivado project are enumerated in
`../Vivado/scripts/taxi_sources.tcl` (the MAC/PCS/GT list is Taxi's own
`src/eth/rtl/us/taxi_eth_mac_1g_basex_us.f`); they are, by function:

| function | Taxi module(s) | files | license |
|----------|----------------|-------|---------|
| 1G MAC + 1000BASE-X/SGMII PCS per port (16-bit, 62.5 MHz), SGMII auto-negotiation, PTP timestamps | `taxi_eth_mac_1g_basex_us`, `taxi_eth_mac_1g_basex_us_ch`, `taxi_eth_mac_phy_1g_basex(_rx/_tx)`, `taxi_axis_basex_rx/tx_8/16`, `taxi_eth_phy_1g_basex_rx/tx_if`, `taxi_eth_phy_1g_basex_an`, `taxi_axis_pad`, `taxi_lfsr`, `taxi_ptp_td_leaf` | `src/eth/rtl/`, `src/eth/rtl/us/`, `src/axis/rtl/`, `src/lfsr/rtl/`, `src/ptp/rtl/` | CERN-OHL-S-2.0 |
| GTH transceiver wrapper (one quad, QPLL, reset sequencers, low-latency buffer-bypass variant) and its DRP/APB control space | `taxi_eth_phy_1g_basex_us_gt(_ll)`, `taxi_gt_qpll_reset`, `taxi_gt_rx_reset`, `taxi_gt_tx_reset`, `taxi_eth_phy_25g_us_gt_apb`, `taxi_apb_interconnect_1s`, `taxi_axil_apb_adapter`; the gtwizard_ultrascale IP is created by Taxi's `taxi_eth_phy_1g_basex_us_gth_125.tcl` | `src/eth/rtl/us/`, `src/hip/rtl/us/`, `src/apb/rtl/`, `src/axi/rtl/` | CERN-OHL-S-2.0 |
| MAC control / pause / statistics (compiled in with the MAC, disabled by parameter) | `taxi_mac_ctrl_rx/tx`, `taxi_mac_pause_ctrl_rx/tx`, `taxi_eth_mac_stats`, `taxi_stats_collect`, `taxi_axis_arb_mux`, `taxi_arbiter`, `taxi_penc` | `src/eth/rtl/`, `src/stats/rtl/`, `src/axis/rtl/`, `src/prim/rtl/` | CERN-OHL-S-2.0 |
| MDIO (Clause 22) master for the four DP83867 PHYs | `taxi_mdio_master` | `src/lss/rtl/` | CERN-OHL-S-2.0 |
| Async AXI-Stream frame FIFOs and width adapters (TAP/loop FIFOs of the M0 path, capture port FIFOs) | `taxi_axis_async_fifo`, `taxi_axis_async_fifo_adapter`, `taxi_axis_adapter` | `src/axis/rtl/` | CERN-OHL-S-2.0 |
| Reset / quasi-static signal synchronisers | `taxi_sync_reset`, `taxi_sync_signal` | `src/sync/rtl/` | CERN-OHL-S-2.0 |
| SystemVerilog interface definitions and tie-off helpers | `taxi_axis_if`, `taxi_axil_if`, `taxi_apb_if`, `taxi_axis_null_src`, `taxi_axis_tie` | `src/axis/rtl/`, `src/axi/rtl/`, `src/apb/rtl/` | MIT |
| Vivado timing-constraint scripts for the CDC paths of the modules above (implementation only) | — | `src/sync/syn/vivado/taxi_sync_reset.tcl`, `src/sync/syn/vivado/taxi_sync_signal.tcl`, `src/axis/syn/vivado/taxi_axis_async_fifo.tcl` | CERN-OHL-S-2.0 |

The RTL testbenches (`../Vivado/scripts/sim.tcl`) also compile a few of these
(FIFOs, synchronisers, and `taxi_axis_basex_rx_16` / `_tx_16` as MAC/PCS models).
Every file carries an SPDX header stating its own license; the table above was
compiled from those headers at the pinned commit.

## What the CERN-OHL-S-2.0 means for you

CERN-OHL-S is *strongly reciprocal*: if you distribute a product (including a
bitstream) that contains the Taxi sources or a design derived from them, you
must make the complete source of that design available under the same license
on request, including your modifications. The MIT-licensed parts of this
repository do not change that obligation for the Taxi-derived part of the
design. If that is not acceptable for your product, FPGA Ninja offers a
commercial license for Taxi (info@fpga.ninja) — see the upstream README.

The AMD IP used alongside Taxi in the block design (Zynq UltraScale+ PS,
DMA/Bridge Subsystem for PCIe, AXI DMA, AXI interconnect, SmartConnect,
processor system reset, and the gtwizard_ultrascale transceiver IP generated by
Taxi's script) is provided by AMD under the Vivado tool license and needs no
additional IP license.

## Pinned version

The submodule is pinned to a specific Taxi commit (`cc70b27`, recorded in this
repository's git tree; `git submodule status` prints it). Update it
deliberately — Taxi is under active development and module interfaces change.

```
git submodule update --init --recursive
```
