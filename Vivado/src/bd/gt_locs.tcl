# Opsero Electronic Design Inc. Copyright 2026

# GT LOC constraints are required in the configuration of the PCIe IPs.
# The following code constructs a nested dictionary that contains the GT assignments for
# each target board for the FPGA Drive FMC Gen4 (OP063).

# To use the dictionary:
#   * Get the GT quad:    dict get $gt_loc_dict <target> <ssd index> quad
#   * Get the PCIe LOC:   dict get $gt_loc_dict <target> <ssd index> pcie
#
# zcu106: OP063 on HPC1, which routes a single transceiver (DP0 = GTHE4_CHANNEL_X0Y3,
# quad 223) and GBTCLK0 -> SSD1 at Gen3 x1 on PCIE40E4_X0Y0 (as fpga-drive-aximm-pcie
# zcu106_hpc1). HPC0 (quads 226/227, PCIE40E4_X0Y1) stays free for the Ethernet FMC Max.
dict set gt_loc_dict zcu106 0 quad GTH_Quad_223
dict set gt_loc_dict zcu106 0 pcie X0Y0
