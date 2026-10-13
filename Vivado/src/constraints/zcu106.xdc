#----------------------------------------------------------------------------------------
# Constraints for the FPGA Packet Recorder on ZCU106
#   HPC1: FPGA Drive FMC Gen4 (OP063), SSD1 only, PCIe Gen3 x1
#   HPC0: Ethernet FMC Max (OP080) - not used yet (pins/GT quads 226-227 left free)
#----------------------------------------------------------------------------------------

# SSD1 PCI Express reset (perst_0)
set_property PACKAGE_PIN B18 [get_ports {perst_0[0]}]; # LA00_CC_P
set_property IOSTANDARD LVCMOS18 [get_ports {perst_0[0]}]

# SSD1 PE Detect (pedet_0, not connected in the design)
# set_property PACKAGE_PIN B19 [get_ports {pedet_0[0]}]; # LA00_CC_N
# set_property IOSTANDARD LVCMOS18 [get_ports {pedet_0[0]}]

# Disable signal for 3.3V power supply for SSD2 (disable_ssd2_pwr)
set_property PACKAGE_PIN D22 [get_ports disable_ssd2_pwr]; # LA07_P
set_property IOSTANDARD LVCMOS18 [get_ports disable_ssd2_pwr]

##############################
# PCIe reference clock 100MHz
##############################

# SSD1 ref clock
set_property PACKAGE_PIN Y8 [get_ports {ref_clk_0_clk_p[0]}]; # GBTCLK0_M2C_P
set_property PACKAGE_PIN Y7 [get_ports {ref_clk_0_clk_n[0]}]; # GBTCLK0_M2C_N
create_clock -period 10.000 -name ref_clk_0_clk_p -waveform {0.000 5.000} [get_ports ref_clk_0_clk_p]

############################
# SSD1 Gigabit transceivers
############################

set_property LOC GTHE4_CHANNEL_X0Y3 [get_cells -hierarchical -regexp -filter { PRIMITIVE_TYPE =~ ADVANCED.GT.GTHE4_CHANNEL && PARENT =~  ".*xdma_0.*" && NAME =~ ".*channel_inst\[0\].*" }]

############################
# SSD1 PCIe block
############################

set_property LOC PCIE40E4_X0Y0 [get_cells -hierarchical -filter { PRIMITIVE_TYPE =~ ADVANCED.PCIE.* && NAME =~ "*xdma_0*" }]

