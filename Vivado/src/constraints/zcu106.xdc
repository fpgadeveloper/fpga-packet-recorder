#----------------------------------------------------------------------------------------
# Constraints for the FPGA Packet Recorder on ZCU106
#   HPC1: FPGA Drive FMC Gen4 (OP063), SSD1 only, PCIe Gen3 x1
#   HPC0: Ethernet FMC Max (OP080), 4 x 1G SGMII on GTH quad 226 (eth_ports)
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


#----------------------------------------------------------------------------------------
# Ethernet FMC Max (OP080) on HPC0 (eth_ports); pins as in ethernet-fmc-max-axi-eth
# zcu106_hpc0.xdc. VADJ = 1.8 V (one rail for HPC0 + HPC1): LVCMOS18 on all LA pins.
#----------------------------------------------------------------------------------------

# GT reference clock: Si511 125 MHz on GBTCLK0_M2C = MGTREFCLK0 of quad 226 (X0Y3)
set_property PACKAGE_PIN V8 [get_ports gt_ref_clk_clk_p]; # GBTCLK0_M2C_P
set_property PACKAGE_PIN V7 [get_ports gt_ref_clk_clk_n]; # GBTCLK0_M2C_N
create_clock -period 8.000 -name gt_ref_clk [get_ports gt_ref_clk_clk_p]

# SGMII lanes: port n = DPn. The pins place the channels (GT IP has no LOC XDC):
# DP0 = GTHE4_CHANNEL_X0Y14, DP1 = X0Y13, DP2 = X0Y15, DP3 = X0Y12
set_property PACKAGE_PIN R6 [get_ports {gt_gtx_p[0]}]; # DP0_C2M_P
set_property PACKAGE_PIN R5 [get_ports {gt_gtx_n[0]}]; # DP0_C2M_N
set_property PACKAGE_PIN R2 [get_ports {gt_grx_p[0]}]; # DP0_M2C_P
set_property PACKAGE_PIN R1 [get_ports {gt_grx_n[0]}]; # DP0_M2C_N
set_property PACKAGE_PIN T4 [get_ports {gt_gtx_p[1]}]; # DP1_C2M_P
set_property PACKAGE_PIN T3 [get_ports {gt_gtx_n[1]}]; # DP1_C2M_N
set_property PACKAGE_PIN U2 [get_ports {gt_grx_p[1]}]; # DP1_M2C_P
set_property PACKAGE_PIN U1 [get_ports {gt_grx_n[1]}]; # DP1_M2C_N
set_property PACKAGE_PIN N6 [get_ports {gt_gtx_p[2]}]; # DP2_C2M_P
set_property PACKAGE_PIN N5 [get_ports {gt_gtx_n[2]}]; # DP2_C2M_N
set_property PACKAGE_PIN P4 [get_ports {gt_grx_p[2]}]; # DP2_M2C_P
set_property PACKAGE_PIN P3 [get_ports {gt_grx_n[2]}]; # DP2_M2C_N
set_property PACKAGE_PIN U6 [get_ports {gt_gtx_p[3]}]; # DP3_C2M_P
set_property PACKAGE_PIN U5 [get_ports {gt_gtx_n[3]}]; # DP3_C2M_N
set_property PACKAGE_PIN V4 [get_ports {gt_grx_p[3]}]; # DP3_M2C_P
set_property PACKAGE_PIN V3 [get_ports {gt_grx_n[3]}]; # DP3_M2C_N

# Shared MDIO bus of the four DP83867s (PHY addresses 0x01, 0x03, 0x0C, 0x0F)
set_property -dict {PACKAGE_PIN F11 IOSTANDARD LVCMOS18} [get_ports mdc];  # LA17_CC_P
set_property -dict {PACKAGE_PIN E10 IOSTANDARD LVCMOS18} [get_ports mdio]; # LA17_CC_N

# PHY resets (active low)
set_property -dict {PACKAGE_PIN G18 IOSTANDARD LVCMOS18} [get_ports {phy_reset_n[0]}]; # LA12_P
set_property -dict {PACKAGE_PIN F18 IOSTANDARD LVCMOS18} [get_ports {phy_reset_n[1]}]; # LA12_N
set_property -dict {PACKAGE_PIN A13 IOSTANDARD LVCMOS18} [get_ports {phy_reset_n[2]}]; # LA11_P
set_property -dict {PACKAGE_PIN A12 IOSTANDARD LVCMOS18} [get_ports {phy_reset_n[3]}]; # LA11_N

# PHY GPIO_0 / GPIO_1 (PHY -> FPGA through SN74AVC4T245; RX SFD / TX SFD once the
# PHYs are configured by pktrec-phy init)
set_property -dict {PACKAGE_PIN E18 IOSTANDARD LVCMOS18} [get_ports {phy_gpio0[0]}]; # LA08_P
set_property -dict {PACKAGE_PIN E17 IOSTANDARD LVCMOS18} [get_ports {phy_gpio1[0]}]; # LA08_N
set_property -dict {PACKAGE_PIN J16 IOSTANDARD LVCMOS18} [get_ports {phy_gpio0[1]}]; # LA07_P
set_property -dict {PACKAGE_PIN J15 IOSTANDARD LVCMOS18} [get_ports {phy_gpio1[1]}]; # LA07_N
set_property -dict {PACKAGE_PIN D17 IOSTANDARD LVCMOS18} [get_ports {phy_gpio0[2]}]; # LA16_P
set_property -dict {PACKAGE_PIN C17 IOSTANDARD LVCMOS18} [get_ports {phy_gpio1[2]}]; # LA16_N
set_property -dict {PACKAGE_PIN D16 IOSTANDARD LVCMOS18} [get_ports {phy_gpio0[3]}]; # LA15_P
set_property -dict {PACKAGE_PIN C16 IOSTANDARD LVCMOS18} [get_ports {phy_gpio1[3]}]; # LA15_N

# Power-good outputs of the card's 1.0 V / 2.5 V regulators
set_property -dict {PACKAGE_PIN G15 IOSTANDARD LVCMOS18} [get_ports pg_1v0]; # LA13_P
set_property -dict {PACKAGE_PIN F15 IOSTANDARD LVCMOS18} [get_ports pg_2v5]; # LA13_N

# Slow / asynchronous pins (synchronisers inside; MDIO is far slower than any clock)
set_false_path -to [get_ports {mdc mdio phy_reset_n[*]}]
set_false_path -from [get_ports {mdio phy_gpio0[*] phy_gpio1[*] pg_1v0 pg_2v5}]

# Taxi's CDC scripts (taxi_sync_reset/_signal.tcl, taxi_axis_async_fifo.tcl) are added
# implementation-only with PROCESSING_ORDER LATE by scripts/taxi_sources.tcl.
