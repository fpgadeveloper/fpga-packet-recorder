# SPDX-License-Identifier: MIT
#
# taxi_sources.tcl - add the 4-port 1G SGMII datapath (pktrec_eth_ports) to the
# current Vivado project:
#   * Taxi taxi_eth_mac_1g_basex_us (+ everything its .f lists name), the Taxi
#     AXI-Lite -> APB adapter and MDIO master  (SystemVerilog, used in place)
#   * the Opsero core pktrec_eth_ports_core.sv (SystemVerilog) and the Verilog
#     module-reference shell pktrec_eth_ports.v
#   * the gtwizard_ultrascale IPs, created by Taxi's own (unmodified)
#     taxi_eth_phy_1g_basex_us_gth_125.tcl; the variant not selected by
#     CFG_LOW_LATENCY is removed again (saves two OOC IP runs)
#   * Taxi's implementation-only CDC constraint scripts (PROCESSING_ORDER LATE):
#     taxi_sync_reset / taxi_sync_signal (MAC, M0 path) and taxi_axis_async_fifo
#     (the M0 path's frame FIFOs)
#
# Inputs (set before sourcing):
#   taxi_dir       absolute path of the Taxi checkout (repo: submodules/taxi)
#   pktrec_hdl_dir absolute path of the directory holding pktrec_eth_ports*.{v,sv}
#   pktrec_gt_ll   1 = low-latency (buffer-bypass) GT variant (default), 0 = normal
# Outputs: $pktrec_rtl (RTL files added), $pktrec_xdc (constraint scripts added)
#
# Copyright (c) 2026 Opsero Electronic Design Inc.

if {![info exists taxi_dir] || ![info exists pktrec_hdl_dir]} {
    error "taxi_sources.tcl: set taxi_dir and pktrec_hdl_dir before sourcing"
}
if {![info exists pktrec_gt_ll]} { set pktrec_gt_ll 1 }
set taxi_dir [file normalize $taxi_dir]
if {![file exists "$taxi_dir/src/eth/rtl/us/taxi_eth_mac_1g_basex_us.sv"]} {
    error "taxi_sources.tcl: $taxi_dir is not a Taxi checkout (git submodule update --init)"
}

# Resolve one .f entry (relative to the .f's directory). Taxi's lists reach the rest
# of the library through the symlink src/eth/lib/taxi -> ../../../ (absent in some
# checkouts / zip downloads), so any /lib/taxi/ path is rewritten to the Taxi root.
proc pktrec_resolve_f_entry {fdir entry} {
    set p [string map {\\ /} [file join $fdir $entry]]
    set i [string last "/lib/taxi/" $p]
    if {$i >= 0} {
        set p [file join $::taxi_dir [string range $p [expr {$i + 10}] end]]
    }
    return [file normalize $p]
}

# Expand a Taxi .f file list recursively (duplicates removed, first occurrence kept).
set ::pktrec_f_visiting {}
proc pktrec_read_f {f} {
    set f [file normalize $f]
    if {[lsearch -exact $::pktrec_f_visiting $f] >= 0} { return {} }
    lappend ::pktrec_f_visiting $f
    if {![file exists $f]} { error "taxi_sources.tcl: file list not found: $f" }
    set fh [open $f r]
    set lines [split [read $fh] "\n"]
    close $fh
    set out {}
    set fdir [file dirname $f]
    foreach line $lines {
        set line [string trim $line]
        if {$line eq "" || [string match "#*" $line] || [string match "//*" $line]} { continue }
        set p [pktrec_resolve_f_entry $fdir $line]
        if {[file extension $p] eq ".f"} {
            foreach s [pktrec_read_f $p] {
                if {[lsearch -exact $out $s] < 0} { lappend out $s }
            }
        } else {
            if {![file exists $p]} { error "taxi_sources.tcl: $f lists a missing file: $line ($p)" }
            if {[lsearch -exact $out $p] < 0} { lappend out $p }
        }
    }
    set ::pktrec_f_visiting [lrange $::pktrec_f_visiting 0 end-1]
    return $out
}

# ---- RTL ----
set pktrec_taxi_rtl [pktrec_read_f "$taxi_dir/src/eth/rtl/us/taxi_eth_mac_1g_basex_us.f"]
foreach rel {
    src/axi/rtl/taxi_axil_if.sv
    src/axi/rtl/taxi_axil_apb_adapter.sv
    src/apb/rtl/taxi_apb_if.sv
    src/lss/rtl/taxi_mdio_master.sv
    src/sync/rtl/taxi_sync_signal.sv
    src/sync/rtl/taxi_sync_reset.sv
    src/axis/rtl/taxi_axis_async_fifo.sv
} {
    set p [file normalize "$taxi_dir/$rel"]
    if {[lsearch -exact $pktrec_taxi_rtl $p] < 0} { lappend pktrec_taxi_rtl $p }
}
set pktrec_sv [concat $pktrec_taxi_rtl [list [file normalize "$pktrec_hdl_dir/pktrec_eth_ports_core.sv"]]]
set pktrec_shell [file normalize "$pktrec_hdl_dir/pktrec_eth_ports.v"]

set pktrec_rtl {}
foreach f $pktrec_sv {
    if {[llength [get_files -quiet -of_objects [get_filesets sources_1] $f]] == 0} {
        add_files -norecurse -fileset sources_1 $f
    }
    lappend pktrec_rtl $f
}
set_property file_type SystemVerilog [get_files -of_objects [get_filesets sources_1] $pktrec_sv]
if {[llength [get_files -quiet -of_objects [get_filesets sources_1] $pktrec_shell]] == 0} {
    add_files -norecurse -fileset sources_1 $pktrec_shell
}
set_property file_type Verilog [get_files -of_objects [get_filesets sources_1] $pktrec_shell]
lappend pktrec_rtl $pktrec_shell

# ---- GT IP (gtwizard_ultrascale, fixed names the Taxi RTL instantiates) ----
# The Taxi script needs an open project (it reads the project PART) and creates
# taxi_eth_phy_1g_basex_us_gth_{full,ch,ll_full,ll_ch} in the current IP location.
if {[llength [get_ips -quiet taxi_eth_phy_1g_basex_us_gth_ll_full]] == 0} {
    source "$taxi_dir/src/eth/rtl/us/taxi_eth_phy_1g_basex_us_gth_125.tcl"
}
if {$pktrec_gt_ll} {
    set pktrec_unused_ips {taxi_eth_phy_1g_basex_us_gth_full taxi_eth_phy_1g_basex_us_gth_ch}
} else {
    set pktrec_unused_ips {taxi_eth_phy_1g_basex_us_gth_ll_full taxi_eth_phy_1g_basex_us_gth_ll_ch}
}
foreach ip $pktrec_unused_ips {
    set xci [get_files -quiet -all "$ip.xci"]
    if {[llength $xci]} { remove_files $xci }
}

# ---- implementation-only CDC constraint scripts ----
set pktrec_xdc {}
foreach f [list \
    "$taxi_dir/src/sync/syn/vivado/taxi_sync_reset.tcl" \
    "$taxi_dir/src/sync/syn/vivado/taxi_sync_signal.tcl" \
    "$taxi_dir/src/axis/syn/vivado/taxi_axis_async_fifo.tcl" \
] {
    set f [file normalize $f]
    if {[llength [get_files -quiet -of_objects [get_filesets constrs_1] $f]] == 0} {
        add_files -norecurse -fileset constrs_1 $f
    }
    set xf [get_files -of_objects [get_filesets constrs_1] $f]
    set_property used_in_synthesis false $xf
    set_property used_in_implementation true $xf
    set_property PROCESSING_ORDER LATE $xf
    lappend pktrec_xdc $f
}

puts "INFO: \[taxi_sources\] [llength $pktrec_rtl] RTL file(s), [llength $pktrec_xdc] constraint script(s), GT variant [expr {$pktrec_gt_ll ? {low-latency} : {normal}}]"
