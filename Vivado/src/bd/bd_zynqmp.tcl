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
#
# Names that software depends on (do not rename without updating
# Yocto/bsp/zcu106/.../system-user.dtsi): fdrec_core/fdrec_core_0 (DT label
# fdrec_core_fdrec_core_0) and axi_dma_0.
#
# Reserved for the Ethernet FMC Max (OP080) port subsystem on HPC0 (added later):
#   - HPC0 LA/HA pins, GTH quads 226/227 and the HPC0 GBTCLKs (nothing here uses them)
#   - PS ports S_AXI_HP1_FPD, S_AXI_HP3_FPD, S_AXI_HPC0/1_FPD (all free)
#   - periph_intercon_0: append master ports after the recorder's (see add_periph_slave)
#   - pl_ps_irq0: append inputs at In8 and up (see add_irq)
#
# Address map (PS view) and interrupts are kept identical to the FPGA Drive
# Recorder's zcu106_hpc0 target so that its driver, DT binding and docs apply:
#   xdma_0 S_AXI_B (BAR window)   0x00_A000_0000  256M
#   xdma_0 S_AXI_LITE (RP config) 0x04_0000_0000  512M
#   axi_dma_0 S_AXI_LITE          0x04_2000_0000   64K
#   fdrec_core_0 s_axi            0x04_2001_0000    4K
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
                   chk_enable chk_reset chk_rate_inc} $chk_counters] {
  connect_bd_net [get_bd_pins fdrec_core/$p] [get_bd_pins fdrec_core/fdrec_core_0/$p]
}
connect_bd_intf_net [get_bd_intf_pins fdrec_core/S_AXIS] [get_bd_intf_pins fdrec_core/fdrec_core_0/s_axis]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/M_AXIS] [get_bd_intf_pins fdrec_core/fdrec_core_0/m_axis]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/S_AXI] [get_bd_intf_pins fdrec_core/fdrec_core_0/s_axi]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/S_AXIS_MM2S] [get_bd_intf_pins fdrec_core/fdrec_core_0/s_axis_mm2s]
connect_bd_intf_net [get_bd_intf_pins fdrec_core/M_AXIS_SNK] [get_bd_intf_pins fdrec_core/fdrec_core_0/m_axis_snk]

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
# Address map
# ------------------------------------------------------------------------------

assign_ps_addr pcie_ssd1/xdma_0/S_AXI_B    0x00A0000000 256M
assign_ps_addr pcie_ssd1/xdma_0/S_AXI_LITE 0x0400000000 512M
assign_ps_addr axi_dma_0/S_AXI_LITE        0x0420000000 64K
assign_ps_addr fdrec_core/fdrec_core_0/s_axi 0x0420010000 4K
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
