# Design

## M0 base platform (zcu106)

* Zynq UltraScale+ PS with the ZCU106 board preset. The board's RJ45 is PS GEM3.
* PCIe: one DMA/Bridge Subsystem for PCIe (XDMA) in AXI Bridge root-port mode, Gen3 x1, on
  PCIE40E4_X0Y0 with the HPC1 transceiver (GTH quad 223, channel X0Y3) and the HPC1 GBTCLK0
  100 MHz reference clock. It serves SSD slot 1 of the FPGA Drive FMC Gen4; SSD slot 2's
  3.3 V supply is switched off (`disable_ssd2_pwr`).
* Recording datapath (from the FPGA Drive Recorder): `user_data_source` (test pattern
  generator), `fdrec_core` (ingest FIFO,
  packetizer, egress FIFO, register block), AXI DMA (scatter-gather, S2MM record and MM2S
  playback) on `S_AXI_HP2_FPD`, and `user_data_sink` (playback checker).

| Clock | Source | Frequency | Use |
|-------|--------|-----------|-----|
| `pl_clk0` | PS | 100 MHz | AXI-Lite masters (HPM0), PCIe data to HP0 |
| `pl_clk1` | PS | 250 MHz | `dp_clk`: AXI DMA, packetizer, recorder registers, HP2 |
| `pl_clk2` | PS | 200 MHz | `src_clk`: data source and sink |

| Slave | Address | Size |
|-------|---------|------|
| PCIe BAR window (`xdma_0` S_AXI_B) | `0x00_A000_0000` | 256 MB |
| PCIe root-port config (`xdma_0` S_AXI_LITE) | `0x04_0000_0000` | 512 MB |
| AXI DMA registers | `0x04_2000_0000` | 64 KB |
| Recorder registers (`fdrec_core`) | `0x04_2001_0000` | 4 KB |

| Interrupt | `pl_ps_irq0` bit | GIC SPI |
|-----------|------------------|---------|
| XDMA `interrupt_out` / MSI 0-31 / MSI 32-63 | 0 / 1 / 2 | 89 / 90 / 91 |
| reserved (tied low) | 3-5 | 92-94 |
| AXI DMA S2MM | 6 | 95 |
| AXI DMA MM2S | 7 | 96 |

The Ethernet FMC Max on HPC0 (GTH quads 226/227 and the HPC0 LA pins) is left free for the
port subsystem.
