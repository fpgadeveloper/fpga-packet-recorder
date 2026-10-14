# Opsero Electronic Design Inc. Copyright 2026
#
# SPDX-License-Identifier: MIT
#
# Post-synthesis functional simulation of the receive checker.
#
# Synthesizes pktrec_gen_chk out of context (synth_design, the same tool and
# part as the real build), writes its funcsim netlist and runs tb_pktrec_gen
# against that netlist (pktrec_gen and the testbench stay RTL). This catches
# RTL that simulates correctly but is synthesized differently: the m0 map 1.4
# checker passed tb_pktrec_gen in RTL simulation but counted 0 untagged PRSQ
# frames on hardware and in this netlist simulation (fixed in m0 map 1.5).
#
# Usage (needs Vivado, not just the simulator):
#
#   vivado -mode batch -notrace -source scripts/sim_netlist.tcl [-tclargs <part>]
#
# <part> defaults to the zcu106 part. Work files go to Vivado/sim/netlist_chk/
# (gitignored). Exit status 0 = PASS, 1 = FAIL.
#
#*****************************************************************************************

set script_dir [file dirname [file normalize [info script]]]
set vivado_dir [file dirname $script_dir]
set hdl_dir    [file join $vivado_dir src hdl]
set tb_file    [file join $vivado_dir src sim tb_pktrec_gen.sv]
set work       [file join $vivado_dir sim netlist_chk]
set part       xczu7ev-ffvc1156-2-e
if {[info exists argv] && [llength $argv] >= 1} { set part [lindex $argv 0] }

file delete -force $work
file mkdir $work

puts "=== netlist_chk: synth_design pktrec_gen_chk ($part, out of context) ==="
read_verilog -sv [file join $hdl_dir pktrec_gen_chk.sv]
synth_design -top pktrec_gen_chk -part $part -mode out_of_context
set net [file join $work pktrec_gen_chk_funcsim.v]
write_verilog -force -mode funcsim $net

set bin  [file join $::env(XILINX_VIVADO) bin]
set glbl [file join $::env(XILINX_VIVADO) data verilog src glbl.v]

proc step {work log args} {
  set cwd [pwd]
  cd $work
  set rc [catch {exec {*}$args 2>@1} out]
  cd $cwd
  set fh [open [file join $work $log] w]; puts $fh $out; close $fh
  return [list $rc $out]
}

puts "=== netlist_chk: compile ==="
lassign [step $work xvlog_net.log [file join $bin xvlog] $net $glbl] rc out
if {$rc} { puts $out; puts "=== netlist_chk: FAIL (compile) ==="; exit 1 }
lassign [step $work xvlog_tb.log [file join $bin xvlog] -sv [file join $hdl_dir pktrec_gen.sv] $tb_file] rc out
if {$rc} { puts $out; puts "=== netlist_chk: FAIL (compile) ==="; exit 1 }
puts "=== netlist_chk: elaborate ==="
lassign [step $work xelab.log [file join $bin xelab] -relax -L unisims_ver -s netlist_snap work.tb_pktrec_gen work.glbl] rc out
if {$rc} { puts $out; puts "=== netlist_chk: FAIL (elaborate) ==="; exit 1 }
puts "=== netlist_chk: run ==="
lassign [step $work xsim.log [file join $bin xsim] netlist_snap -R] rc out
puts $out
if {$rc || [regexp {FAIL} $out] || ![regexp {PASS} $out]} {
  puts "=== netlist_chk: FAIL ==="
  exit 1
}
puts "=== netlist_chk: PASS ==="
exit 0
