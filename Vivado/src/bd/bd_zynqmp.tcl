################################################################
# Block design build script for the FPGA Packet Recorder (Zynq UltraScale+)
################################################################
#
# Opsero Electronic Design Inc. Copyright 2026
#
# Sourced by scripts/build.tcl, which provides: $target, $block_name, $num_lanes,
# $dual_design and $gt_loc_dict (src/bd/gt_locs.tcl).
#
# Top level of the block design (M0 base platform):
#
#   zynq_ultra_ps_e_0          PS (board preset: DDR, MIO, GEM3 = board RJ45, UART, SD)
#   rst_pl_clk0 / rst_dp_clk / rst_src_clk     resets of the three PL clock domains
#   periph_intercon_0          M_AXI_HPM0_FPD -> AXI-Lite/AXI slaves (one MI per slave)
#   pcie_ssd1                  PCIe Gen3 x1 root port for SSD slot 1 of the FPGA Drive
#                              FMC Gen4 on HPC1 (XDMA in AXI Bridge mode, refclk buffer,
#                              PERST, SSD2 power disable)
#   pcie_mem_intercon          pcie_ssd1/M_AXI_B (PCIe bus mastering) -> S_AXI_HP0_FPD
#   user_data_source           data source of the recorder (test pattern generator)
#   fdrec_core                 recorder core (ingest FIFO, packetizer, egress FIFO, regs)
#   user_data_sink             playback sink (checker)
#   axi_dma_0 / axi_smc_dma    recorder AXI DMA (SG, S2MM + MM2S) -> S_AXI_HP2_FPD
#   concat_interrupts          pl_ps_irq0
#   eth_ports                  Ethernet FMC Max (OP080) on HPC0: 4-port 1G SGMII
#                              MAC/PCS/GTH (pktrec_eth_ports, Taxi) + the M0 bring-up
#                              datapath (pktrec_m0_path: per-port idle/loopback/forward,
#                              and a plain copy of each RX stream for the capture path)
#   capture                    M1 monitor-mode capture path (pktrec_capture): RX taps ->
#                              per-port frame FIFOs -> records -> round-robin merge ->
#                              fdrec_core/S_AXIS_CAP; shared timebase (PHC) feeding the
#                              MACs' timestamp inputs
#
# Names that software depends on (do not rename without updating
# Yocto/bsp/zcu106/.../system-user.dtsi): fdrec_core/fdrec_core_0 (DT label
# fdrec_core_fdrec_core_0), axi_dma_0, eth_ports/pktrec_eth_ports_0 and
# eth_ports/pktrec_m0_path_0 (DT labels eth_ports_pktrec_eth_ports_0 and
# eth_ports_pktrec_m0_path_0, bound to generic-uio for sw/pktrec-tools),
# capture/pktrec_capture_0 (DT label capture_pktrec_capture_0, generic-uio for
# sw/pktrec-apps pktrec-cap).
#
# Ethernet FMC Max (OP080) on HPC0 (hierarchy eth_ports): GTH quad 226
# (GTHE4_CHANNEL_X0Y12..X0Y15, refclk GBTCLK0_M2C V8/V7), MDIO, PHY resets, PHY
# GPIO_0/1 and PG pins (src/constraints/zcu106.xdc). Still free for later
# milestones: PS ports S_AXI_HP1_FPD, S_AXI_HP3_FPD, S_AXI_HPC0/1_FPD;
# pl_ps_irq0 inputs In8 and up (see add_irq).
#
# Address map (PS view) and interrupts are kept identical to the FPGA Drive
# Recorder's zcu106_hpc0 target so that its driver, DT binding and docs apply:
#   xdma_0 S_AXI_B (BAR window)   0x00_A000_0000  256M
#   xdma_0 S_AXI_LITE (RP config) 0x04_0000_0000  512M
#   axi_dma_0 S_AXI_LITE          0x04_2000_0000   64K
#   fdrec_core_0 s_axi            0x04_2001_0000    4K
#   eth_ports/pktrec_m0_path_0    0x04_2002_0000    4K   (M0 path registers)
#   capture/pktrec_capture_0      0x04_2003_0000    4K   (capture + timebase registers)
#   eth_ports/pktrec_eth_ports_0  0x04_2008_0000  512K   (MAC/PCS/MDIO regs + GT APB)
#   pl_ps_irq0[0..2]  xdma_0 interrupt_out, MSI 0-31, MSI 32-63  (GIC SPI 89..91)
#   pl_ps_irq0[3..5]  reserved, tied low                         (GIC SPI 92..94)
#   pl_ps_irq0[6]     axi_dma_0 s2mm_introut                     (GIC SPI 95)
#   pl_ps_irq0[7]     axi_dma_0 mm2s_introut                     (GIC SPI 96)

# CHECKING IF PROJECT EXISTS
if { [get_projects -quiet] eq "" } {
   puts "ERROR: Please open or create a project!"
   return 1
}

create_bd_design $block_name
current_bd_design $block_name
set oldCurInst [current_bd_instance .]
current_bd_instance [get_bd_cells /]

# ------------------------------------------------------------------------------
# Helpers
# ------------------------------------------------------------------------------

# Connect an AXI slave interface to the next free master port of
# periph_intercon_0, clocked by clk_pin and reset by rstn_pin (both pin paths).
proc add_periph_slave {slave_intf clk_pin rstn_pin} {
  set ic [get_bd_cells periph_intercon_0]
  set n [get_property CONFIG.NUM_MI $ic]
  # NUM_MI starts at 1 with M00 unconnected; use M00 first
  if {[llength [get_bd_intf_nets -quiet -of_objects [get_bd_intf_pins periph_intercon_0/M00_AXI]]] == 0} {
    set mi 0
  } else {
    set mi $n
    set_property CONFIG.NUM_MI [expr {$n + 1}] $ic
  }
  set m [format "M%02d" $mi]
  connect_bd_intf_net [get_bd_intf_pins periph_intercon_0/${m}_AXI] [get_bd_intf_pins $slave_intf]
  connect_bd_net [get_bd_pins $clk_pin] [get_bd_pins periph_intercon_0/${m}_ACLK]
  connect_bd_net [get_bd_pins $rstn_pin] [get_bd_pins periph_intercon_0/${m}_ARESETN]
  puts "INFO: periph_intercon_0/${m}_AXI -> $slave_intf"
  return $m
}

# Connect an interrupt source to input <index> of concat_interrupts.
proc add_irq {src_pin index} {
  connect_bd_net [get_bd_pins $src_pin] [get_bd_pins concat_interrupts/In${index}]
  puts "INFO: $src_pin -> pl_ps_irq0\[$index\] (GIC SPI [expr {89 + $index}])"
}

# Assign one address segment of a slave interface in the PS address space.
proc assign_ps_addr {slave_intf offset range} {
  set seg [get_bd_addr_segs -of_objects [get_bd_intf_pins $slave_intf]]
  assign_bd_address -offset $offset -range $range \
    -target_address_space [get_bd_addr_spaces zynq_ultra_ps_e_0/Data] $seg -force
}

# ------------------------------------------------------------------------------
# Processor system
# ------------------------------------------------------------------------------

# Board preset (ZCU106): DDR4, MIO peripherals incl. GEM3 (the board RJ45, TI DP83867
# RGMII PHY at MDIO address 0xc), UART0/1, SD1, I2C, USB.
create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e zynq_ultra_ps_e_0
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1" } [get_bd_cells zynq_ultra_ps_e_0]

# PS-PL interfaces and clocks
#   M_AXI_HPM0_FPD          : AXI-Lite/AXI masters to the PL slaves
#   S_AXI_HP0_FPD           : PCIe root port bus mastering (SSD DMA) -> DDR
#   S_AXI_HP2_FPD (128-bit) : recorder AXI DMA S2MM + MM2S + SG -> DDR (non-coherent)
#   pl_clk0 = 100 MHz       : HPM0, HP0, AXI interconnect
#   pl_clk1 = 250 MHz       : dp_clk  (AXI DMA, packetizer, ingest read side, HP2, fdrec registers)
#   pl_clk2 = 200 MHz       : src_clk (data source / sink, ingest write side, egress read side)
#   High address enabled    : the 0x4_xxxx_xxxx PL window used by the slaves above
set_property -dict [list CONFIG.PSU__USE__M_AXI_GP0 {1} \
  CONFIG.PSU__USE__M_AXI_GP1 {0} \
  CONFIG.PSU__USE__S_AXI_GP2 {1} \
  CONFIG.PSU__USE__S_AXI_GP3 {0} \
  CONFIG.PSU__USE__S_AXI_GP4 {1} \
  CONFIG.PSU__SAXIGP4__DATA_WIDTH {128} \
  CONFIG.PSU__USE__IRQ0 {1} \
  CONFIG.PSU__HIGH_ADDRESS__ENABLE {1} \
  CONFIG.PSU__FPGA_PL1_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL1_REF_CTRL__FREQMHZ {250} \
  CONFIG.PSU__FPGA_PL2_ENABLE {1} \
  CONFIG.PSU__CRL_APB__PL2_REF_CTRL__FREQMHZ {200}] [get_bd_cells zynq_ultra_ps_e_0]

set ps zynq_ultra_ps_e_0

# Actual PL clock frequencies (the PS PLLs may not hit the requested values exactly)
set dp_clk_hz  [expr {int(round([get_property CONFIG.FREQ_HZ [get_bd_pins $ps/pl_clk1]]))}]
set src_clk_hz [expr {int(round([get_property CONFIG.FREQ_HZ [get_bd_pins $ps/pl_clk2]]))}]
puts "INFO: dp_clk (pl_clk1) = $dp_clk_hz Hz, src_clk (pl_clk2) = $src_clk_hz Hz"

# Resets, one per PL clock domain
foreach {rst clk} {rst_pl_clk0 pl_clk0 rst_dp_clk pl_clk1 rst_src_clk pl_clk2} {
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset $rst
  connect_bd_net [get_bd_pins $ps/$clk] [get_bd_pins $rst/slowest_sync_clk]
  connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins $rst/ext_reset_in]
}

connect_bd_net [get_bd_pins $ps/pl_clk0] [get_bd_pins $ps/maxihpm0_fpd_aclk] [get_bd_pins $ps/saxihp0_fpd_aclk]
connect_bd_net [get_bd_pins $ps/pl_clk1] [get_bd_pins $ps/saxihp2_fpd_aclk]

# Interrupt concat: 8 inputs (see the map in the header); later subsystems append
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconcat:1.0 concat_interrupts
set_property CONFIG.NUM_PORTS {8} [get_bd_cells concat_interrupts]
connect_bd_net [get_bd_pins concat_interrupts/dout] [get_bd_pins $ps/pl_ps_irq0]
create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 const_irq_low
set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL {0}] [get_bd_cells const_irq_low]
foreach i {3 4 5} {
  connect_bd_net [get_bd_pins const_irq_low/dout] [get_bd_pins concat_interrupts/In$i]
}

# AXI interconnect for the PS master port. Its crossbar runs on pl_clk0, so register
# access to the recorder does not depend on the PCIe reference clock being present.
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect periph_intercon_0
set_property CONFIG.NUM_MI {1} [get_bd_cells periph_intercon_0]
connect_bd_intf_net [get_bd_intf_pins $ps/M_AXI_HPM0_FPD] [get_bd_intf_pins periph_intercon_0/S00_AXI]
connect_bd_net [get_bd_pins $ps/pl_clk0] [get_bd_pins periph_intercon_0/ACLK] [get_bd_pins periph_intercon_0/S00_ACLK]
connect_bd_net [get_bd_pins rst_pl_clk0/interconnect_aresetn] [get_bd_pins periph_intercon_0/ARESETN]
connect_bd_net [get_bd_pins rst_pl_clk0/peripheral_aresetn] [get_bd_pins periph_intercon_0/S00_ARESETN]

# ------------------------------------------------------------------------------
# PCIe root port for SSD slot 1 of the FPGA Drive FMC Gen4 (hierarchy pcie_ssd1)
# ------------------------------------------------------------------------------

set select_quad_0 [dict get $gt_loc_dict $target 0 quad]
set pcie_loc_0 [dict get $gt_loc_dict $target 0 pcie]

if {[lindex $num_lanes 0] == "X4"} {
  set max_link_width X4
  set axi_data_width 128_bit
  set axisten_freq 250
  set pf_device_id 9134
} else {
  # ZCU106 HPC1 routes a single transceiver: Gen3 x1
  set max_link_width X1
  set axi_data_width 64_bit
  set axisten_freq 125
  set pf_device_id 9131
}

# Creates hierarchy <name> holding the XDMA root port <xdma> with its refclk buffer,
# PERST generator and the SSD2 power-disable constant. Interface of the hierarchy:
#   pcie_mgt, ref_clk (to ports), perst (O), disable_ssd2_pwr (O), sys_rst_n (I),
#   S_AXI_B, S_AXI_LITE, M_AXI_B, axi_aclk, axi_aresetn, axi_ctl_aresetn,
#   interrupt_out, interrupt_out_msi_vec0to31, interrupt_out_msi_vec32to63
proc create_hier_pcie_rp {name xdma quad loc width data_width stream_freq dev_id disable_ssd2} {
  create_bd_cell -type hier $name
  set x $name/$xdma
  create_bd_cell -type ip -vlnv xilinx.com:ip:xdma $x

  # The PCIe block LOC must be given in the IP's own name format (eg. X0Y0 -> <prefix>_X0Y0)
  set pcie_blk [get_property CONFIG.pcie_blk_locn [get_bd_cells $x]]
  set us [string last "_" $pcie_blk]
  if {$us >= 0} {
    set loc "[string range $pcie_blk 0 [expr {$us - 1}]]_$loc"
  }

  # Configuration as in fpga-drive-aximm-pcie (zcu106_hpc1) and fpga-drive-recorder:
  # (1) "Chip-to-Chip" loss profile: the FMC traces to the SSD are short, and this
  #     profile disables the DFE.
  # (2) AR 70854 for the root-port settings; on ZynqMP BAR0 must be in the 32-bit
  #     address space (0xA000_0000) or the NVMe driver crashes on boot.
  # (3) AR 71106: msi_rx_pin_en (MSI handling in the PL root port).
  set_property -dict [list CONFIG.functional_mode {AXI_Bridge} \
    CONFIG.mode_selection {Advanced} \
    CONFIG.device_port_type {Root_Port_of_PCI_Express_Root_Complex} \
    CONFIG.pl_link_cap_max_link_width $width \
    CONFIG.pl_link_cap_max_link_speed {8.0_GT/s} \
    CONFIG.axi_addr_width {49} \
    CONFIG.axi_data_width $data_width \
    CONFIG.axisten_freq $stream_freq \
    CONFIG.dedicate_perst {false} \
    CONFIG.sys_reset_polarity {ACTIVE_LOW} \
    CONFIG.pf0_device_id $dev_id \
    CONFIG.pf0_base_class_menu {Bridge_device} \
    CONFIG.pf0_class_code_base {06} \
    CONFIG.pf0_sub_class_interface_menu {PCI_to_PCI_bridge} \
    CONFIG.pf0_class_code_sub {04} \
    CONFIG.pf0_class_code_interface {00} \
    CONFIG.pf0_class_code {060400} \
    CONFIG.xdma_axilite_slave {true} \
    CONFIG.pcie_blk_locn $loc \
    CONFIG.en_gt_selection {true} \
    CONFIG.select_quad $quad \
    CONFIG.INS_LOSS_NYQ {5} \
    CONFIG.plltype {QPLL1} \
    CONFIG.ins_loss_profile {Chip-to-Chip} \
    CONFIG.type1_membase_memlimit_enable {Enabled} \
    CONFIG.type1_prefetchable_membase_memlimit {64bit_Enabled} \
    CONFIG.axibar_num {1} \
    CONFIG.axibar2pciebar_0 {0x00000000A0000000} \
    CONFIG.BASEADDR {0x00000000} \
    CONFIG.HIGHADDR {0x001FFFFF} \
    CONFIG.pf0_bar0_enabled {false} \
    CONFIG.pf1_class_code {060700} \
    CONFIG.pf1_base_class_menu {Bridge_device} \
    CONFIG.pf1_class_code_base {06} \
    CONFIG.pf1_class_code_sub {07} \
    CONFIG.pf1_sub_class_interface_menu {CardBus_bridge} \
    CONFIG.pf1_class_code_interface {00} \
    CONFIG.pf1_bar2_enabled {false} \
    CONFIG.pf1_bar2_64bit {false} \
    CONFIG.pf1_bar4_enabled {false} \
    CONFIG.pf1_bar4_64bit {false} \
    CONFIG.dma_reset_source_sel {Phy_Ready} \
    CONFIG.pf0_bar0_type_mqdma {Memory} \
    CONFIG.pf1_bar0_type_mqdma {Memory} \
    CONFIG.pf2_bar0_type_mqdma {Memory} \
    CONFIG.pf3_bar0_type_mqdma {Memory} \
    CONFIG.pf0_sriov_bar0_type {Memory} \
    CONFIG.pf1_sriov_bar0_type {Memory} \
    CONFIG.pf2_sriov_bar0_type {Memory} \
    CONFIG.pf3_sriov_bar0_type {Memory} \
    CONFIG.PF0_DEVICE_ID_mqdma $dev_id \
    CONFIG.PF2_DEVICE_ID_mqdma $dev_id \
    CONFIG.PF3_DEVICE_ID_mqdma $dev_id \
    CONFIG.pf0_base_class_menu_mqdma {Bridge_device} \
    CONFIG.pf0_class_code_base_mqdma {06} \
    CONFIG.pf0_class_code_mqdma {068000} \
    CONFIG.pf1_base_class_menu_mqdma {Bridge_device} \
    CONFIG.pf1_class_code_base_mqdma {06} \
    CONFIG.pf1_class_code_mqdma {068000} \
    CONFIG.pf2_base_class_menu_mqdma {Bridge_device} \
    CONFIG.pf2_class_code_base_mqdma {06} \
    CONFIG.pf2_class_code_mqdma {068000} \
    CONFIG.pf3_base_class_menu_mqdma {Bridge_device} \
    CONFIG.pf3_class_code_base_mqdma {06} \
    CONFIG.pf3_class_code_mqdma {068000}] [get_bd_cells $x]
  set_property -dict [list CONFIG.msi_rx_pin_en {true}] [get_bd_cells $x]

  # Hierarchy pins
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 $name/pcie_mgt
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 $name/ref_clk
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 $name/S_AXI_B
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 $name/S_AXI_LITE
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:aximm_rtl:1.0 $name/M_AXI_B
  create_bd_pin -dir I -type rst $name/sys_rst_n
  create_bd_pin -dir O -type clk $name/axi_aclk
  create_bd_pin -dir O -type rst $name/axi_aresetn
  create_bd_pin -dir O -type rst $name/axi_ctl_aresetn
  create_bd_pin -dir O -from 0 -to 0 -type rst $name/perst
  create_bd_pin -dir O $name/disable_ssd2_pwr
  create_bd_pin -dir O -type intr $name/interrupt_out
  create_bd_pin -dir O -type intr $name/interrupt_out_msi_vec0to31
  create_bd_pin -dir O -type intr $name/interrupt_out_msi_vec32to63

  connect_bd_intf_net [get_bd_intf_pins $x/pcie_mgt] [get_bd_intf_pins $name/pcie_mgt]
  connect_bd_intf_net [get_bd_intf_pins $x/S_AXI_B] [get_bd_intf_pins $name/S_AXI_B]
  connect_bd_intf_net [get_bd_intf_pins $x/S_AXI_LITE] [get_bd_intf_pins $name/S_AXI_LITE]
  connect_bd_intf_net [get_bd_intf_pins $x/M_AXI_B] [get_bd_intf_pins $name/M_AXI_B]
  connect_bd_net [get_bd_pins $name/sys_rst_n] [get_bd_pins $x/sys_rst_n]
  connect_bd_net [get_bd_pins $x/axi_aresetn] [get_bd_pins $name/axi_aresetn]
  foreach p {interrupt_out interrupt_out_msi_vec0to31 interrupt_out_msi_vec32to63} {
    connect_bd_net [get_bd_pins $x/$p] [get_bd_pins $name/$p]
  }

  # 100 MHz PCIe reference clock from the FMC (sys_clk / sys_clk_gt as in PG195)
  create_bd_cell -type ip -vlnv xilinx.com:ip:util_ds_buf $name/ref_clk_buf
  set_property -dict [list CONFIG.C_BUF_TYPE {IBUFDSGTE}] [get_bd_cells $name/ref_clk_buf]
  connect_bd_intf_net [get_bd_intf_pins $name/ref_clk] [get_bd_intf_pins $name/ref_clk_buf/CLK_IN_D]
  connect_bd_net [get_bd_pins $name/ref_clk_buf/IBUF_DS_ODIV2] [get_bd_pins $x/sys_clk]
  connect_bd_net [get_bd_pins $name/ref_clk_buf/IBUF_OUT] [get_bd_pins $x/sys_clk_gt]

  # PERST to the SSD, generated from axi_ctl_aresetn in the axi_aclk domain
  create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset $name/rst_axi_aclk
  connect_bd_net [get_bd_pins $x/axi_aclk] [get_bd_pins $name/rst_axi_aclk/slowest_sync_clk] [get_bd_pins $name/axi_aclk]
  connect_bd_net [get_bd_pins $x/axi_ctl_aresetn] [get_bd_pins $name/rst_axi_aclk/ext_reset_in] [get_bd_pins $name/axi_ctl_aresetn]
  connect_bd_net [get_bd_pins $name/rst_axi_aclk/peripheral_reset] [get_bd_pins $name/perst]

  # 3.3 V supply of SSD slot 2: HIGH disables it (no transceiver for slot 2 on HPC1)
  create_bd_cell -type inline_hdl -vlnv xilinx.com:inline_hdl:ilconstant:1.0 $name/const_dis_ssd2_pwr
  set_property -dict [list CONFIG.CONST_WIDTH {1} CONFIG.CONST_VAL $disable_ssd2] [get_bd_cells $name/const_dis_ssd2_pwr]
  connect_bd_net [get_bd_pins $name/const_dis_ssd2_pwr/dout] [get_bd_pins $name/disable_ssd2_pwr]
}

create_hier_pcie_rp pcie_ssd1 xdma_0 $select_quad_0 $pcie_loc_0 $max_link_width \
  $axi_data_width $axisten_freq $pf_device_id [expr {$dual_design ? 0 : 1}]

# External ports (names match src/constraints/<target>.xdc)
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:pcie_7x_mgt_rtl:1.0 pci_exp_0
connect_bd_intf_net [get_bd_intf_pins pcie_ssd1/pcie_mgt] [get_bd_intf_ports pci_exp_0]
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 ref_clk_0
set_property CONFIG.FREQ_HZ {100000000} [get_bd_intf_ports ref_clk_0]
connect_bd_intf_net [get_bd_intf_pins pcie_ssd1/ref_clk] [get_bd_intf_ports ref_clk_0]
create_bd_port -dir O -from 0 -to 0 -type rst perst_0
connect_bd_net [get_bd_pins pcie_ssd1/perst] [get_bd_ports perst_0]
create_bd_port -dir O disable_ssd2_pwr
connect_bd_net [get_bd_pins pcie_ssd1/disable_ssd2_pwr] [get_bd_ports disable_ssd2_pwr]
connect_bd_net [get_bd_pins $ps/pl_resetn0] [get_bd_pins pcie_ssd1/sys_rst_n]

# Root port bus mastering (SSD DMA to DDR): M_AXI_B (axi_aclk) -> S_AXI_HP0_FPD (pl_clk0)
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect pcie_mem_intercon
set_property CONFIG.NUM_MI {1} [get_bd_cells pcie_mem_intercon]
connect_bd_intf_net [get_bd_intf_pins pcie_ssd1/M_AXI_B] [get_bd_intf_pins pcie_mem_intercon/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins pcie_mem_intercon/M00_AXI] [get_bd_intf_pins $ps/S_AXI_HP0_FPD]
connect_bd_net [get_bd_pins pcie_ssd1/axi_aclk] [get_bd_pins pcie_mem_intercon/ACLK] [get_bd_pins pcie_mem_intercon/S00_ACLK]
connect_bd_net [get_bd_pins pcie_ssd1/axi_aresetn] [get_bd_pins pcie_mem_intercon/ARESETN] [get_bd_pins pcie_mem_intercon/S00_ARESETN]
connect_bd_net [get_bd_pins $ps/pl_clk0] [get_bd_pins pcie_mem_intercon/M00_ACLK]
connect_bd_net [get_bd_pins rst_pl_clk0/peripheral_aresetn] [get_bd_pins pcie_mem_intercon/M00_ARESETN]

# Root port slaves: BAR window (axi_aresetn) and the bridge's config/control space
# (axi_ctl_aresetn), both in the axi_aclk domain
add_periph_slave pcie_ssd1/S_AXI_B pcie_ssd1/axi_aclk pcie_ssd1/axi_aresetn
add_periph_slave pcie_ssd1/S_AXI_LITE pcie_ssd1/axi_aclk pcie_ssd1/axi_ctl_aresetn

add_irq pcie_ssd1/interrupt_out 0
add_irq pcie_ssd1/interrupt_out_msi_vec0to31 1
add_irq pcie_ssd1/interrupt_out_msi_vec32to63 2

# ------------------------------------------------------------------------------
# FPGA Drive Recorder datapath (from fpga-drive-recorder, register map 1.1)
# ------------------------------------------------------------------------------
#
#  user_data_source (src_clk)          fdrec_core                    dp_clk
#  [fdrec_tpg] --AXIS 128b--> [ingest FIFO -> packetizer] --AXIS--> axi_dma_0 S2MM
#                                  ^ AXI-Lite regs                    | M_AXI_S2MM + M_AXI_SG
#                                  |                                  v
#  M_AXI_HPM0_FPD -> periph_intercon_0 -+-> fdrec_core/S_AXI     axi_smc_dma -> S_AXI_HP2_FPD
#                                       +-> axi_dma_0/S_AXI_LITE
#
#  Playback: axi_dma_0 MM2S --AXIS 128b (dp_clk)--> fdrec_core [egress FIFO]
#            --AXIS (src_clk)--> user_data_sink [fdrec_check]
#
# user_data_source / user_data_sink are the insertion points for other data
# sources and sinks (the Ethernet capture path replaces user_data_source later).

# user_data_source hierarchy: the test pattern generator
create_bd_cell -type hier user_data_source
create_bd_pin -dir I -type clk user_data_source/src_clk
create_bd_pin -dir I -type rst user_data_source/src_resetn
create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 user_data_source/M_AXIS
create_bd_pin -dir I user_data_source/tpg_enable
create_bd_pin -dir I user_data_source/tpg_seq_rst
create_bd_pin -dir I -from 31 -to 0 user_data_source/tpg_rate_inc
create_bd_pin -dir O -from 63 -to 0 user_data_source/tpg_seq_next
create_bd_cell -type module -reference fdrec_tpg user_data_source/fdrec_tpg_0
foreach p {src_clk src_resetn tpg_enable tpg_seq_rst tpg_rate_inc tpg_seq_next} {
  connect_bd_net [get_bd_pins user_data_source/$p] [get_bd_pins user_data_source/fdrec_tpg_0/$p]
}
connect_bd_intf_net [get_bd_intf_pins user_data_source/M_AXIS] [get_bd_intf_pins user_data_source/fdrec_tpg_0/m_axis]

# user_data_sink hierarchy: the playback checker
create_bd_cell -type hier user_data_sink
create_bd_pin -dir I -type clk user_data_sink/snk_clk
create_bd_pin -dir I -type rst user_data_sink/snk_resetn
create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 user_data_sink/S_AXIS
create_bd_pin -dir I user_data_sink/chk_enable
create_bd_pin -dir I user_data_sink/chk_reset
create_bd_pin -dir I -from 31 -to 0 user_data_sink/chk_rate_inc
set chk_counters {chk_beats chk_errors chk_gaps chk_gap_beats chk_underflows chk_last_seq}
foreach p $chk_counters {
  create_bd_pin -dir O -from 63 -to 0 user_data_sink/$p
}
create_bd_cell -type module -reference fdrec_check user_data_sink/fdrec_check_0
foreach p [concat {snk_clk snk_resetn chk_enable chk_reset chk_rate_inc} $chk_counters] {
  connect_bd_net [get_bd_pins user_data_sink/$p] [get_bd_pins user_data_sink/fdrec_check_0/$p]
}
connect_bd_intf_net [get_bd_intf_pins user_data_sink/S_AXIS] [get_bd_intf_pins user_data_sink/fdrec_check_0/s_axis]

# fdrec_core hierarchy: ingest FIFO + packetizer + egress FIFO + AXI-Lite register block
create_bd_cell -type hier fdrec_core
create_bd_pin -dir I -type clk fdrec_core/src_clk
create_bd_pin -dir I -type rst fdrec_core/src_resetn
create_bd_pin -dir I -type clk fdrec_core/dp_clk
create_bd_pin -dir I -type rst fdrec_core/dp_resetn
create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 fdrec_core/S_AXIS
create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 fdrec_core/M_AXIS
create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 fdrec_core/S_AXI
create_bd_pin -dir O fdrec_core/tpg_enable
create_bd_pin -dir O fdrec_core/tpg_seq_rst
create_bd_pin -dir O -from 31 -to 0 fdrec_core/tpg_rate_inc
create_bd_pin -dir I -from 63 -to 0 fdrec_core/tpg_seq_next
create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 fdrec_core/S_AXIS_MM2S
create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 fdrec_core/S_AXIS_CAP
create_bd_pin -dir I fdrec_core/cap_sel
create_bd_pin -dir O fdrec_core/rec_srst
create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 fdrec_core/M_AXIS_SNK
create_bd_pin -dir O fdrec_core/chk_enable
create_bd_pin -dir O fdrec_core/chk_reset
create_bd_pin -dir O -from 31 -to 0 fdrec_core/chk_rate_inc
foreach p $chk_counters {
  create_bd_pin -dir I -from 63 -to 0 fdrec_core/$p
}
create_bd_cell -type module -reference fdrec_core fdrec_core/fdrec_core_0
set_property -dict [list CONFIG.SRC_CLK_HZ $src_clk_hz \
  CONFIG.DP_CLK_HZ $dp_clk_hz \
  CONFIG.FIFO_DEPTH {4096} \
  CONFIG.EGR_FIFO_DEPTH {4096}] [get_bd_cells fdrec_core/fdrec_core_0]
foreach p [concat {src_clk src_resetn dp_clk dp_resetn tpg_enable tpg_seq_rst tpg_rate_inc tpg_seq_next \
                   chk_enable chk_reset chk_rate_inc cap_sel rec_srst} $chk_counters] {
  connect_bd_net [get_bd_pins fdrec_core/$p] [get_bd_pins fdrec_core/fdrec_core_0/$p]
}
connect_bd_intf_net [get_bd_intf_pins fdrec_core/S_AXIS] [get_bd_intf_pins fdrec_core/fdrec_core_0/s_axis]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/M_AXIS] [get_bd_intf_pins fdrec_core/fdrec_core_0/m_axis]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/S_AXI] [get_bd_intf_pins fdrec_core/fdrec_core_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/S_AXIS_MM2S] [get_bd_intf_pins fdrec_core/fdrec_core_0/s_axis_mm2s]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/M_AXIS_SNK] [get_bd_intf_pins fdrec_core/fdrec_core_0/m_axis_snk]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/S_AXIS_CAP] [get_bd_intf_pins fdrec_core/fdrec_core_0/s_axis_cap]

# Source -> core, core -> sink, and their control/status signals
connect_bd_intf_net [get_bd_intf_pins user_data_source/M_AXIS] [get_bd_intf_pins fdrec_core/S_AXIS]
foreach p {tpg_enable tpg_seq_rst tpg_rate_inc tpg_seq_next} {
  connect_bd_net [get_bd_pins fdrec_core/$p] [get_bd_pins user_data_source/$p]
}
connect_bd_intf_net [get_bd_intf_pins fdrec_core/M_AXIS_SNK] [get_bd_intf_pins user_data_sink/S_AXIS]
foreach p [concat {chk_enable chk_reset chk_rate_inc} $chk_counters] {
  connect_bd_net [get_bd_pins fdrec_core/$p] [get_bd_pins user_data_sink/$p]
}

# AXI DMA: scatter-gather, S2MM (record) + MM2S (playback), 128-bit stream and
# memory map, burst 256, 26-bit buffer length register, 64-bit addressing (PS
# DDR above 4 GB is at 0x8_0000_0000), no DRE
create_bd_cell -type ip -vlnv xilinx.com:ip:axi_dma axi_dma_0
set_property -dict [list CONFIG.c_include_sg {1} \
  CONFIG.c_include_mm2s {1} \
  CONFIG.c_m_axi_mm2s_data_width {128} \
  CONFIG.c_m_axis_mm2s_tdata_width {128} \
  CONFIG.c_mm2s_burst_size {256} \
  CONFIG.c_include_mm2s_dre {0} \
  CONFIG.c_include_s2mm {1} \
  CONFIG.c_micro_dma {0} \
  CONFIG.c_sg_length_width {26} \
  CONFIG.c_sg_include_stscntrl_strm {0} \
  CONFIG.c_addr_width {64} \
  CONFIG.c_s_axis_s2mm_tdata_width {128} \
  CONFIG.c_m_axi_s2mm_data_width {128} \
  CONFIG.c_s2mm_burst_size {256} \
  CONFIG.c_include_s2mm_dre {0}] [get_bd_cells axi_dma_0]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/M_AXIS] [get_bd_intf_pins axi_dma_0/S_AXIS_S2MM]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXIS_MM2S] [get_bd_intf_pins fdrec_core/S_AXIS_MM2S]

# DMA masters -> SmartConnect -> S_AXI_HP2_FPD
create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect axi_smc_dma
set_property -dict [list CONFIG.NUM_SI {3} CONFIG.NUM_MI {1}] [get_bd_cells axi_smc_dma]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_SG] [get_bd_intf_pins axi_smc_dma/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_S2MM] [get_bd_intf_pins axi_smc_dma/S01_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_dma_0/M_AXI_MM2S] [get_bd_intf_pins axi_smc_dma/S02_AXI]
connect_bd_intf_net [get_bd_intf_pins axi_smc_dma/M00_AXI] [get_bd_intf_pins $ps/S_AXI_HP2_FPD]

# dp_clk domain
connect_bd_net [get_bd_pins $ps/pl_clk1] \
  [get_bd_pins axi_smc_dma/aclk] \
  [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
  [get_bd_pins axi_dma_0/m_axi_sg_aclk] \
  [get_bd_pins axi_dma_0/m_axi_s2mm_aclk] \
  [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] \
  [get_bd_pins fdrec_core/dp_clk]
connect_bd_net [get_bd_pins rst_dp_clk/peripheral_aresetn] \
  [get_bd_pins axi_dma_0/axi_resetn] \
  [get_bd_pins fdrec_core/dp_resetn]
connect_bd_net [get_bd_pins rst_dp_clk/interconnect_aresetn] [get_bd_pins axi_smc_dma/aresetn]

# src_clk domain
connect_bd_net [get_bd_pins $ps/pl_clk2] \
  [get_bd_pins user_data_source/src_clk] \
  [get_bd_pins user_data_sink/snk_clk] \
  [get_bd_pins fdrec_core/src_clk]
connect_bd_net [get_bd_pins rst_src_clk/peripheral_aresetn] \
  [get_bd_pins user_data_source/src_resetn] \
  [get_bd_pins user_data_sink/snk_resetn] \
  [get_bd_pins fdrec_core/src_resetn]

# AXI-Lite: recorder registers and DMA control
add_periph_slave fdrec_core/S_AXI $ps/pl_clk1 rst_dp_clk/peripheral_aresetn
add_periph_slave axi_dma_0/S_AXI_LITE $ps/pl_clk1 rst_dp_clk/peripheral_aresetn

# DMA interrupts
add_irq axi_dma_0/s2mm_introut 6
add_irq axi_dma_0/mm2s_introut 7

# ------------------------------------------------------------------------------
# Ethernet FMC Max (OP080) on HPC0: hierarchy eth_ports
# ------------------------------------------------------------------------------
#
#  GBTCLK0 125 MHz --> pktrec_eth_ports_0 (Taxi taxi_eth_mac_1g_basex_us, CNT 4,
#  DP0..DP3 <-->       GTH quad 226, SGMII to the four DP83867s, MDIO master,
#                      PHY resets, AXI-Lite regs + GT APB)
#                        | m_axis_rx_n (rx_clk_n)      ^ s_axis_tx_n (tx_clk_n)
#                        v                             |
#                      pktrec_m0_path_0 (8 async frame FIFOs: per TX port n a LOOP
#                      FIFO from RX n (4 KB) and a FWD FIFO from RX n^1 (16 KB, TAP);
#                      PATH_CTRL selects; dynamic IFG -> tx_ifg (M3); pair mode;
#                      counters; PHY GPIO_0/1 + PG levels and edge counters;
#                      copies of the RX streams for the capture path; the MAC
#                      timestamp inputs come from capture/pktrec_timebase)
#
# ctrl_clk = pl_clk0 (100 MHz) for both s_axi ports, the MDIO master and the Taxi
# transceiver reset/DRP logic. The GT wizard IP declares a 62.5 MHz free-running
# clock; Taxi's sequencers count fixed cycles, so 100 MHz only shortens their waits
# (Taxi's own ZCU106 example runs them at 125 MHz). The only consequence is the
# OOC Timing 38-316 period-mismatch warning. No extra MMCM is used.
#
# pktrec_eth_ports parameters: low-latency (buffer-bypass) GT variant, 64-bit MAC
# timestamps (48.16 ns), TX padding OFF (frames are forwarded unmodified, runts
# included), GTs run from reset (GCTRL.xcvr_rst = 0), TX inter-frame gap per port
# from pktrec_m0_path's dynamic IFG (EXT_TX_IFG = 1, M3 TAP mode: 12 bytes, 8 while
# the FWD FIFO fills up because the far device's clock is faster than ours).
#
# The module-reference RX streams have no TREADY: pktrec_m0_path always accepts
# (its frame FIFOs drop whole frames when full).

create_bd_cell -type hier eth_ports
create_bd_cell -type module -reference pktrec_eth_ports eth_ports/pktrec_eth_ports_0
set_property -dict [list CONFIG.CFG_LOW_LATENCY {1} \
  CONFIG.PTP_TS_EN {1} \
  CONFIG.PTP_TS_W {64} \
  CONFIG.PTP_TS_FMT_TOD {0} \
  CONFIG.DEFAULT_TX_PAD_EN {0} \
  CONFIG.EXT_TX_IFG {1} \
  CONFIG.XCVR_RST_DEFAULT {0}] [get_bd_cells eth_ports/pktrec_eth_ports_0]
create_bd_cell -type module -reference pktrec_m0_path eth_ports/pktrec_m0_path_0
set_property -dict [list CONFIG.PTP_TS_W {64} CONFIG.FIFO_DEPTH {4096} \
  CONFIG.FWD_FIFO_DEPTH {16384}] [get_bd_cells eth_ports/pktrec_m0_path_0]

set ep eth_ports/pktrec_eth_ports_0
set mp eth_ports/pktrec_m0_path_0

# Hierarchy pins
create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 eth_ports/gt_ref_clk
create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 eth_ports/gt
create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 eth_ports/S_AXI_ETH
create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 eth_ports/S_AXI_M0
create_bd_pin -dir I -type clk eth_ports/ctrl_clk
create_bd_pin -dir I -type rst eth_ports/ctrl_aresetn
create_bd_pin -dir O eth_ports/mdc
create_bd_pin -dir IO eth_ports/mdio
create_bd_pin -dir O -from 3 -to 0 eth_ports/phy_reset_n
create_bd_pin -dir I -from 3 -to 0 eth_ports/phy_gpio0
create_bd_pin -dir I -from 3 -to 0 eth_ports/phy_gpio1
create_bd_pin -dir I eth_ports/pg_1v0
create_bd_pin -dir I eth_ports/pg_2v5

connect_bd_intf_net [get_bd_intf_pins eth_ports/gt_ref_clk] [get_bd_intf_pins $ep/gt_ref_clk]
connect_bd_intf_net [get_bd_intf_pins $ep/gt] [get_bd_intf_pins eth_ports/gt]
connect_bd_intf_net [get_bd_intf_pins eth_ports/S_AXI_ETH] [get_bd_intf_pins $ep/s_axi]
connect_bd_intf_net [get_bd_intf_pins eth_ports/S_AXI_M0] [get_bd_intf_pins $mp/s_axi]
connect_bd_net [get_bd_pins eth_ports/ctrl_clk] [get_bd_pins $ep/ctrl_clk] [get_bd_pins $mp/ctrl_clk]
connect_bd_net [get_bd_pins eth_ports/ctrl_aresetn] [get_bd_pins $ep/ctrl_aresetn] [get_bd_pins $mp/ctrl_aresetn]
connect_bd_net [get_bd_pins $ep/mdc] [get_bd_pins eth_ports/mdc]
connect_bd_net [get_bd_pins $ep/mdio] [get_bd_pins eth_ports/mdio]
connect_bd_net [get_bd_pins $ep/phy_reset_n] [get_bd_pins eth_ports/phy_reset_n]
foreach p {phy_gpio0 phy_gpio1 pg_1v0 pg_2v5} {
  connect_bd_net [get_bd_pins eth_ports/$p] [get_bd_pins $mp/$p]
}

# MAC <-> M0 path, per port
for {set n 0} {$n < 4} {incr n} {
  foreach p [list rx_clk_$n rx_aresetn_$n tx_clk_$n tx_aresetn_$n] {
    connect_bd_net [get_bd_pins $ep/$p] [get_bd_pins $mp/$p]
  }
  connect_bd_intf_net [get_bd_intf_pins $ep/m_axis_rx_$n] [get_bd_intf_pins $mp/s_axis_rx_$n]
  connect_bd_intf_net [get_bd_intf_pins $mp/m_axis_tx_$n] [get_bd_intf_pins $ep/s_axis_tx_$n]
  # capture tap, MAC clocks/resets and the MAC timestamp inputs (from capture)
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 eth_ports/M_AXIS_MON_$n
  connect_bd_intf_net [get_bd_intf_pins $mp/m_axis_mon_$n] [get_bd_intf_pins eth_ports/M_AXIS_MON_$n]
  foreach p [list rx_clk_$n tx_clk_$n] {
    create_bd_pin -dir O -type clk eth_ports/$p
    connect_bd_net [get_bd_pins $ep/$p] [get_bd_pins eth_ports/$p]
  }
  foreach p [list rx_aresetn_$n tx_aresetn_$n] {
    create_bd_pin -dir O -type rst eth_ports/$p
    connect_bd_net [get_bd_pins $ep/$p] [get_bd_pins eth_ports/$p]
  }
  foreach p [list rx_ptp_ts_$n tx_ptp_ts_$n] {
    create_bd_pin -dir I -from 63 -to 0 eth_ports/$p
    connect_bd_net [get_bd_pins eth_ports/$p] [get_bd_pins $ep/$p]
  }
  # MAC TX completions (TX timestamp per frame) for the SFD TX pairing (M2)
  create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 eth_ports/M_AXIS_TX_CPL_$n
  connect_bd_intf_net [get_bd_intf_pins $ep/m_axis_tx_cpl_$n] [get_bd_intf_pins eth_ports/M_AXIS_TX_CPL_$n]
}
foreach p {rx_stat_pkt_good rx_stat_pkt_bad tx_stat_pkt_good tx_stat_err_underflow link_up} {
  connect_bd_net [get_bd_pins $ep/$p] [get_bd_pins $mp/$p]
}
# dynamic inter-frame gap (M3): [8n+7:8n] in tx_clk_n
connect_bd_net [get_bd_pins $mp/tx_ifg] [get_bd_pins $ep/tx_ifg]

# External ports (names match src/constraints/zcu106.xdc)
create_bd_intf_port -mode Slave -vlnv xilinx.com:interface:diff_clock_rtl:1.0 gt_ref_clk
set_property CONFIG.FREQ_HZ {125000000} [get_bd_intf_ports gt_ref_clk]
connect_bd_intf_net [get_bd_intf_ports gt_ref_clk] [get_bd_intf_pins eth_ports/gt_ref_clk]
create_bd_intf_port -mode Master -vlnv xilinx.com:interface:gt_rtl:1.0 gt
connect_bd_intf_net [get_bd_intf_pins eth_ports/gt] [get_bd_intf_ports gt]
create_bd_port -dir O mdc
connect_bd_net [get_bd_pins eth_ports/mdc] [get_bd_ports mdc]
create_bd_port -dir IO mdio
connect_bd_net [get_bd_pins eth_ports/mdio] [get_bd_ports mdio]
create_bd_port -dir O -from 3 -to 0 phy_reset_n
connect_bd_net [get_bd_pins eth_ports/phy_reset_n] [get_bd_ports phy_reset_n]
# PHY GPIO_0/1 (RX/TX SFD): the pins go to the capture hierarchy's ISERDES
# sampler (pktrec_sfd_io, M2); eth_ports/pktrec_m0_path gets the sampled
# levels (phy_gpio*_lvl, dp_clk) for IO_STATUS and its edge counters
foreach p {phy_gpio0 phy_gpio1} {
  create_bd_port -dir I -from 3 -to 0 $p
}
foreach p {pg_1v0 pg_2v5} {
  create_bd_port -dir I $p
  connect_bd_net [get_bd_ports $p] [get_bd_pins eth_ports/$p]
}

# Control clock / reset and the two AXI-Lite slaves (pl_clk0, same as the crossbar)
connect_bd_net [get_bd_pins $ps/pl_clk0] [get_bd_pins eth_ports/ctrl_clk]
connect_bd_net [get_bd_pins rst_pl_clk0/peripheral_aresetn] [get_bd_pins eth_ports/ctrl_aresetn]
add_periph_slave eth_ports/S_AXI_ETH $ps/pl_clk0 rst_pl_clk0/peripheral_aresetn
add_periph_slave eth_ports/S_AXI_M0 $ps/pl_clk0 rst_pl_clk0/peripheral_aresetn

# ------------------------------------------------------------------------------
# Capture path (M1, monitor mode): hierarchy capture
# ------------------------------------------------------------------------------
#
#  eth_ports/M_AXIS_MON_n (rx_clk_n, copy of MAC RX stream n, no tready)
#        |  x4
#        v
#  pktrec_capture_0: per port frame FIFO (16 KB, whole-frame drop + counters)
#        -> 16-byte record header (include/pktrec_format.h) -> 4:1 round robin
#        merge over whole records -> M_AXIS_REC (dp_clk, back-pressure)
#        -> fdrec_core/S_AXIS_CAP (packetizer source while CTRL.SRC_SEL = 1)
#  pktrec_timebase: 64-bit ns PHC on dp_clk; its cycle counter goes Gray-coded
#        into every MAC clock -> eth_ports rx_ptp_ts_n / tx_ptp_ts_n
#  s_axi on dp_clk: include/pktrec_regs.h PKTREC_CAP_*
#
# The forward path (pktrec_m0_path) is unchanged: the RX streams have no
# back-pressure, so the tap is a plain fan-out.

create_bd_cell -type hier capture
create_bd_cell -type module -reference pktrec_capture capture/pktrec_capture_0
set_property -dict [list CONFIG.DP_CLK_HZ $dp_clk_hz CONFIG.FIFO_BYTES {16384}] \
  [get_bd_cells capture/pktrec_capture_0]
set cp capture/pktrec_capture_0

create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:aximm_rtl:1.0 capture/S_AXI
create_bd_intf_pin -mode Master -vlnv xilinx.com:interface:axis_rtl:1.0 capture/M_AXIS_REC
create_bd_pin -dir I -type clk capture/dp_clk
create_bd_pin -dir I -type rst capture/dp_resetn
create_bd_pin -dir O capture/cap_sel
create_bd_pin -dir I capture/rec_srst
foreach p {phy_gpio0 phy_gpio1} {
  create_bd_pin -dir I -from 3 -to 0 capture/$p
  create_bd_pin -dir O -from 3 -to 0 capture/${p}_lvl
  connect_bd_net [get_bd_pins capture/$p] [get_bd_pins $cp/$p]
  connect_bd_net [get_bd_pins $cp/${p}_lvl] [get_bd_pins capture/${p}_lvl]
  connect_bd_net [get_bd_ports $p] [get_bd_pins capture/$p]
  connect_bd_net [get_bd_pins capture/${p}_lvl] [get_bd_pins eth_ports/$p]
}
connect_bd_intf_net [get_bd_intf_pins capture/S_AXI] [get_bd_intf_pins $cp/s_axi]
connect_bd_intf_net [get_bd_intf_pins $cp/m_axis_rec] [get_bd_intf_pins capture/M_AXIS_REC]
foreach p {dp_clk dp_resetn rec_srst} {
  connect_bd_net [get_bd_pins capture/$p] [get_bd_pins $cp/$p]
}
connect_bd_net [get_bd_pins $cp/cap_sel] [get_bd_pins capture/cap_sel]
for {set n 0} {$n < 4} {incr n} {
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 capture/S_AXIS_RX_$n
  connect_bd_intf_net [get_bd_intf_pins capture/S_AXIS_RX_$n] [get_bd_intf_pins $cp/s_axis_rx_$n]
  foreach p [list rx_clk_$n tx_clk_$n] {
    create_bd_pin -dir I -type clk capture/$p
    connect_bd_net [get_bd_pins capture/$p] [get_bd_pins $cp/$p]
  }
  foreach p [list rx_aresetn_$n tx_aresetn_$n] {
    create_bd_pin -dir I -type rst capture/$p
    connect_bd_net [get_bd_pins capture/$p] [get_bd_pins $cp/$p]
  }
  foreach p [list rx_ptp_ts_$n tx_ptp_ts_$n] {
    create_bd_pin -dir O -from 63 -to 0 capture/$p
    connect_bd_net [get_bd_pins $cp/$p] [get_bd_pins capture/$p]
  }
  create_bd_intf_pin -mode Slave -vlnv xilinx.com:interface:axis_rtl:1.0 capture/S_AXIS_TX_CPL_$n
  connect_bd_intf_net [get_bd_intf_pins capture/S_AXIS_TX_CPL_$n] [get_bd_intf_pins $cp/s_axis_tx_cpl_$n]
  # eth_ports <-> capture
  connect_bd_intf_net [get_bd_intf_pins eth_ports/M_AXIS_MON_$n] [get_bd_intf_pins capture/S_AXIS_RX_$n]
  connect_bd_intf_net [get_bd_intf_pins eth_ports/M_AXIS_TX_CPL_$n] [get_bd_intf_pins capture/S_AXIS_TX_CPL_$n]
  foreach p [list rx_clk_$n tx_clk_$n rx_aresetn_$n tx_aresetn_$n] {
    connect_bd_net [get_bd_pins eth_ports/$p] [get_bd_pins capture/$p]
  }
  foreach p [list rx_ptp_ts_$n tx_ptp_ts_$n] {
    connect_bd_net [get_bd_pins capture/$p] [get_bd_pins eth_ports/$p]
  }
}
connect_bd_intf_net [get_bd_intf_pins capture/M_AXIS_REC] [get_bd_intf_pins fdrec_core/S_AXIS_CAP]
connect_bd_net [get_bd_pins capture/cap_sel] [get_bd_pins fdrec_core/cap_sel]
connect_bd_net [get_bd_pins fdrec_core/rec_srst] [get_bd_pins capture/rec_srst]
connect_bd_net [get_bd_pins $ps/pl_clk1] [get_bd_pins capture/dp_clk]
connect_bd_net [get_bd_pins rst_dp_clk/peripheral_aresetn] [get_bd_pins capture/dp_resetn]
add_periph_slave capture/S_AXI $ps/pl_clk1 rst_dp_clk/peripheral_aresetn

# ------------------------------------------------------------------------------
# Address map
# ------------------------------------------------------------------------------

assign_ps_addr pcie_ssd1/xdma_0/S_AXI_B    0x00A0000000 256M
assign_ps_addr pcie_ssd1/xdma_0/S_AXI_LITE 0x0400000000 512M
assign_ps_addr axi_dma_0/S_AXI_LITE        0x0420000000 64K
assign_ps_addr fdrec_core/fdrec_core_0/s_axi 0x0420010000 4K
assign_ps_addr eth_ports/pktrec_m0_path_0/s_axi   0x0420020000 4K
assign_ps_addr capture/pktrec_capture_0/s_axi     0x0420030000 4K
assign_ps_addr eth_ports/pktrec_eth_ports_0/s_axi 0x0420080000 512K
# Everything else: the masters' (PCIe M_AXI_B, DMA SG/S2MM/MM2S) view of PS DDR
assign_bd_address

foreach seg [get_bd_addr_segs -of_objects [get_bd_addr_spaces zynq_ultra_ps_e_0/Data]] {
  puts "INFO: addr [get_property NAME $seg] offset [get_property OFFSET $seg] range [get_property RANGE $seg]"
}
foreach as [concat [get_bd_addr_spaces pcie_ssd1/xdma_0/M_AXI_B] \
                   [get_bd_addr_spaces axi_dma_0/Data_SG] \
                   [get_bd_addr_spaces axi_dma_0/Data_S2MM] \
                   [get_bd_addr_spaces axi_dma_0/Data_MM2S]] {
  foreach seg [get_bd_addr_segs -of_objects $as] {
    puts "INFO: addr $as [get_property NAME $seg] offset [get_property OFFSET $seg] range [get_property RANGE $seg]"
  }
}

validate_bd_design

# Restore current instance
current_bd_instance $oldCurInst

save_bd_design
