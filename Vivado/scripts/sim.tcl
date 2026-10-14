# Opsero Electronic Design Inc. Copyright 2026
#
# SPDX-License-Identifier: MIT
#
# Batch xsim runner for the custom RTL testbenches.
#
# Compiles every RTL source in Vivado/src/hdl (*.v, *.sv) plus one testbench
# Vivado/src/sim/tb_<name>.sv (or tb_<name>.v), elaborates it and runs it to
# completion in the Vivado simulator (xsim), with no Vivado project.
#
# Usage (from the Vivado directory, or any directory -- paths are resolved from
# this script's location):
#
#   vivado -mode batch -notrace -source scripts/sim.tcl -tclargs <name>
#   vivado -mode batch -notrace -source scripts/sim.tcl -tclargs all
#
# <name> is the testbench name without the "tb_" prefix (eg. "fdrec_tpg" runs
# src/sim/tb_fdrec_tpg.sv); "all" runs every src/sim/tb_*.{sv,v} in turn.
# The script also runs under a plain tclsh as long as xvlog/xelab/xsim are on
# the PATH (eg. after sourcing <xilinx-install>/2025.2/Vivado/settings64.sh).
#
# Testbench contract:
#   * the top module is named tb_<name> (same as the file name)
#   * it is self-checking: at the end it prints a line containing PASS, or a
#     line containing FAIL (with a reason) on the first/any error, then calls
#     $finish
#   * it must terminate on its own (add a watchdog that prints FAIL on timeout)
#
# A testbench passes only if its output contains "PASS" and no "FAIL", and
# xsim itself exits cleanly. The script exits with status 1 if any testbench
# fails, 0 if all pass. Work files and logs go to Vivado/sim/<tb>/ (gitignored).
#
# SIM_DEFINES (environment, optional): space-separated Verilog defines passed to
# xvlog as -d, e.g. SIM_DEFINES=PKTREC_TB_DIC_EN (tb_pktrec_tap: model the old
# DIC_EN = 1 TX MAC, test 7 must then fail).
#
# XPM macros (eg. xpm_fifo_async) used by the RTL are taken from the
# precompiled "xpm" library that ships with Vivado (-L xpm).
#
# Taxi (submodules/taxi): the library modules the simulated RTL instantiates
# (taxi_sim_srcs below) are compiled too. The 4-port MAC/PCS/GT shell
# (pktrec_eth_ports*.v/.sv) is skipped: it needs the GT wizard IP and the full
# Taxi MAC, and is verified by implementation and on hardware instead.
#
#*****************************************************************************************

set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_dir]
set hdl_dir    [file join $vivado_dir src hdl]
set sim_dir    [file join $vivado_dir src sim]
set work_root  [file join $vivado_dir sim]
set taxi_dir   [file normalize [file join $vivado_dir .. submodules taxi]]

# Taxi library sources needed by the simulated RTL (pktrec_axis_async_fifo,
# pktrec_m0_path, pktrec_cap_port) and, as MAC/PCS models, by tb_pktrec_tap
# (taxi_axis_basex_tx_16 / _rx_16 + taxi_lfsr)
set taxi_sim_srcs {}
foreach rel {
  src/axis/rtl/taxi_axis_if.sv
  src/axis/rtl/taxi_axis_async_fifo.sv
  src/axis/rtl/taxi_axis_adapter.sv
  src/axis/rtl/taxi_axis_async_fifo_adapter.sv
  src/sync/rtl/taxi_sync_reset.sv
  src/sync/rtl/taxi_sync_signal.sv
  src/lfsr/rtl/taxi_lfsr.sv
  src/eth/rtl/taxi_axis_basex_tx_16.sv
  src/eth/rtl/taxi_axis_basex_rx_16.sv
} {
  lappend taxi_sim_srcs [file join $taxi_dir $rel]
}
# RTL files not simulated here (see above)
set sim_exclude {pktrec_eth_ports.v pktrec_eth_ports_core.sv}

# Locate a Vivado simulator tool: prefer $XILINX_VIVADO/bin, else the PATH
proc find_tool {name} {
  if {[info exists ::env(XILINX_VIVADO)]} {
    foreach ext {"" ".bat"} {
      set p [file join $::env(XILINX_VIVADO) bin "$name$ext"]
      if {[file exists $p]} { return $p }
    }
  }
  set p [auto_execok $name]
  if {$p eq ""} {
    puts "ERROR: $name not found. Run from Vivado, or source Vivado's settings64.sh."
    exit 2
  }
  return [lindex $p 0]
}

# Run a tool in dir, tee its output to a log, return {exit_code output}
proc run_step {dir log args} {
  set cwd [pwd]
  cd $dir
  set rc [catch {exec {*}$args 2>@1} out opts]
  cd $cwd
  set fh [open $log w]
  puts $fh $out
  close $fh
  if {$rc} {
    set ec [lindex [dict get $opts -errorcode] 0]
    if {$ec eq "CHILDSTATUS"} {
      set rc [lindex [dict get $opts -errorcode] 2]
    } elseif {$ec eq "NONE"} {
      # tool wrote to stderr but exited 0 (stderr is merged, so this is rare)
      set rc 0
    }
  }
  return [list $rc $out]
}

proc run_tb {tb_file} {
  global hdl_dir work_root taxi_dir taxi_sim_srcs sim_exclude
  set tb [file rootname [file tail $tb_file]]
  set work [file join $work_root $tb]
  file delete -force $work
  file mkdir $work

  set xvlog [find_tool xvlog]
  set xelab [find_tool xelab]
  set xsim  [find_tool xsim]

  set rtl [lsort [concat [glob -nocomplain -directory $hdl_dir *.v] \
                         [glob -nocomplain -directory $hdl_dir *.sv]]]
  set rtl_sim {}
  foreach f $rtl {
    if {[lsearch -exact $sim_exclude [file tail $f]] < 0} { lappend rtl_sim $f }
  }
  foreach f $taxi_sim_srcs {
    if {![file exists $f]} {
      puts "ERROR: $f not found (git submodule update --init submodules/taxi)"
      return 0
    }
  }
  set srcs [concat $taxi_sim_srcs $rtl_sim [list $tb_file]]
  set glbl [file join [file dirname [file dirname $xvlog]] data verilog src glbl.v]
  if {[file exists $glbl]} { lappend srcs $glbl }

  set defs {}
  if {[info exists ::env(SIM_DEFINES)]} {
    foreach d $::env(SIM_DEFINES) { lappend defs -d $d }
    puts "=== $tb: defines $::env(SIM_DEFINES) ==="
  }
  puts "=== $tb: compile ([llength $srcs] files) ==="
  lassign [run_step $work [file join $work xvlog.log] \
             $xvlog -sv {*}$defs -i $hdl_dir -i [file dirname $tb_file] {*}$srcs] rc out
  if {$rc != 0} {
    puts $out
    puts "=== $tb: FAIL (compile error, see [file join $work xvlog.log]) ==="
    return 0
  }

  puts "=== $tb: elaborate ==="
  set tops [list work.$tb]
  if {[file exists $glbl]} { lappend tops work.glbl }
  lassign [run_step $work [file join $work xelab.log] \
             $xelab -relax -timescale 1ns/1ps -L xpm -L unisims_ver -L unimacro_ver -L secureip \
             -s ${tb}_snap {*}$tops] rc out
  if {$rc != 0} {
    puts $out
    puts "=== $tb: FAIL (elaboration error, see [file join $work xelab.log]) ==="
    return 0
  }

  puts "=== $tb: run ==="
  lassign [run_step $work [file join $work xsim.log] $xsim ${tb}_snap -R] rc out
  puts $out
  set has_fail [regexp {FAIL} $out]
  set has_pass [regexp {PASS} $out]
  if {$rc != 0 || $has_fail || !$has_pass} {
    set why [expr {$rc != 0 ? "xsim exit $rc" : ($has_fail ? "testbench reported FAIL" : "no PASS line")}]
    puts "=== $tb: FAIL ($why) ==="
    return 0
  }
  puts "=== $tb: PASS ==="
  return 1
}

# Parse the argument: testbench name (without tb_) or "all"
if {[info exists argv] && [llength $argv] >= 1} {
  set sel [lindex $argv 0]
} elseif {[info exists tb_name]} {
  set sel $tb_name
} else {
  puts "Usage: vivado -mode batch -notrace -source scripts/sim.tcl -tclargs <name|all>"
  puts "Testbenches found in $sim_dir:"
  foreach f [lsort [concat [glob -nocomplain -directory $sim_dir tb_*.sv] \
                           [glob -nocomplain -directory $sim_dir tb_*.v]]] {
    puts "  [string range [file rootname [file tail $f]] 3 end]"
  }
  exit 2
}

if {$sel eq "all"} {
  set tbs [lsort [concat [glob -nocomplain -directory $sim_dir tb_*.sv] \
                         [glob -nocomplain -directory $sim_dir tb_*.v]]]
  if {[llength $tbs] == 0} {
    puts "ERROR: no testbenches (tb_*.sv / tb_*.v) found in $sim_dir"
    exit 2
  }
} else {
  set tbs {}
  foreach ext {sv v} {
    set f [file join $sim_dir "tb_${sel}.$ext"]
    if {[file exists $f]} { lappend tbs $f; break }
  }
  if {[llength $tbs] == 0} {
    puts "ERROR: testbench not found: $sim_dir/tb_${sel}.sv"
    exit 2
  }
}

set passed {}
set failed {}
foreach tb_file $tbs {
  set tb [file rootname [file tail $tb_file]]
  if {[run_tb $tb_file]} { lappend passed $tb } else { lappend failed $tb }
}

puts ""
puts "=== Simulation summary: [llength $passed] passed, [llength $failed] failed ==="
foreach t $passed { puts "  PASS  $t" }
foreach t $failed { puts "  FAIL  $t" }
exit [expr {[llength $failed] > 0 ? 1 : 0}]
