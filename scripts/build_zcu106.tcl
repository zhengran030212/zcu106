# Usage: vivado -mode batch -source scripts/build_zcu106.tcl -tclargs LANES ROUNDS_PER_STAGE MHZ
set root [file normalize [file join [file dirname [info script]] ..]]
set lanes [expr {[llength $argv]>0 ? [lindex $argv 0] : 1}]
set rounds [expr {[llength $argv]>1 ? [lindex $argv 1] : 2}]
set mhz [expr {[llength $argv]>2 ? [lindex $argv 2] : 100}]
if {$lanes<1 || $lanes>4 || $rounds ni {1 2 4} || $mhz<10 || $mhz>250} {error "invalid build parameters"}
set out [file join $root build zcu106_l${lanes}_r${rounds}_${mhz}]
file mkdir $out
set_param general.maxThreads 4
create_project btc_lottery $out -part xczu7ev-ffvc1156-2-e -force
set boards [get_board_parts -quiet xilinx.com:zcu106:part0:*]
if {[llength $boards]==0} {error "ZCU106 board files are not installed"}
set_property board_part [lindex [lsort -dictionary $boards] end] [current_project]
add_files [glob [file join $root rtl *.sv] [file join $root rtl *.v]]
update_compile_order -fileset sources_1
create_bd_design system
set ps [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:* ps]
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e -config {apply_board_preset "1"} $ps
# The running Canonical FSBL leaves M_AXI_HPM0_FPD at the ZCU106 board-preset
# width, 128 bits. A 32-bit PL port only completes the low 4 bytes of each
# 16-byte beat; accesses at +4/+8/+12 return zeros or stall the PS master.
# Keep the miner RTL 32-bit. SmartConnect narrows 128 to 32.
set_property -dict [list CONFIG.PSU__USE__M_AXI_GP0 {1} CONFIG.PSU__USE__M_AXI_GP1 {0} CONFIG.PSU__MAXIGP0__DATA_WIDTH {128} CONFIG.PSU__FPGA_PL0_ENABLE {1} CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ $mhz] $ps
set miner [create_bd_cell -type module -reference btc_axi miner]
set_property -dict [list CONFIG.LANES $lanes CONFIG.ROUNDS_PER_STAGE $rounds] $miner
set axi [create_bd_cell -type ip -vlnv xilinx.com:ip:smartconnect:1.0 axi]
set_property -dict [list CONFIG.NUM_SI {1} CONFIG.NUM_MI {1}] $axi
connect_bd_intf_net [get_bd_intf_pins ps/M_AXI_HPM0_FPD] [get_bd_intf_pins axi/S00_AXI]
connect_bd_intf_net [get_bd_intf_pins axi/M00_AXI] [get_bd_intf_pins miner/s_axi]
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:* rst]
set one [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* one]
set_property CONFIG.CONST_VAL {1} $one
set zero [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconstant:* zero]
set_property CONFIG.CONST_VAL {0} $zero
connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins ps/maxihpm0_fpd_aclk] [get_bd_pins axi/aclk] [get_bd_pins rst/slowest_sync_clk] [get_bd_pins miner/s_axi_aclk]
# pl_resetn0 is intentionally not the reset source. After fpgautil it can stay
# low while pl_clk0 runs; a slave held in reset never answers AXI and the PS
# master has no timeout. Tie proc_sys_reset's ext_reset_in and dcm_locked high
# so that controller would itself release, then let a fabric counter force the
# interconnect and miner out of reset even if proc_sys_reset stays asserted.
# The EMIO GPIO toggle in psu_init (0xFF0A0054) is not wired to this reset.
connect_bd_net [get_bd_pins one/dout] [get_bd_pins rst/ext_reset_in] [get_bd_pins rst/dcm_locked]
connect_bd_net [get_bd_pins zero/dout] [get_bd_pins rst/aux_reset_in] [get_bd_pins rst/mb_debug_sys_rst]
set rel [create_bd_cell -type module -reference pl_reset_release rel]
connect_bd_net [get_bd_pins ps/pl_clk0] [get_bd_pins rel/clk]
connect_bd_net [get_bd_pins rst/peripheral_aresetn] [get_bd_pins rel/proc_peripheral_aresetn]
connect_bd_net [get_bd_pins rst/interconnect_aresetn] [get_bd_pins rel/proc_interconnect_aresetn]
connect_bd_net [get_bd_pins rel/aresetn] [get_bd_pins axi/aresetn] [get_bd_pins miner/s_axi_aresetn]
assign_bd_address
set segments [get_bd_addr_segs -of_objects [get_bd_addr_spaces ps/Data] -filter {NAME =~ *miner*}]
if {[llength $segments]!=1} {error "cannot uniquely identify miner AXI address segment: $segments"}
set_property offset 0xA0000000 $segments
set_property range 4K $segments
validate_bd_design
save_bd_design
generate_target all [get_files system.bd]
make_wrapper -files [get_files system.bd] -top
add_files [file join $out btc_lottery.srcs sources_1 bd system hdl system_wrapper.v]
set_property top system_wrapper [current_fileset]
update_compile_order -fileset sources_1
launch_runs synth_1 -jobs 4
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] ne "100%"} {error "synthesis failed"}
launch_runs impl_1 -to_step route_design -jobs 4
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {error "implementation failed"}
open_run impl_1
report_utilization -file [file join $out utilization.rpt]
report_timing_summary -file [file join $out timing.rpt]
report_drc -file [file join $out drc.rpt]
set path [get_timing_paths -delay_type max -max_paths 1]
if {[llength $path]==0 || [get_property SLACK $path]<0} {error "timing did not pass; no bitstream will be produced"}
set holdpath [get_timing_paths -delay_type min -max_paths 1]
if {[llength $holdpath]==0 || [get_property SLACK $holdpath]<0} {error "hold timing did not pass; no bitstream will be produced"}
write_bitstream -force -bin_file [file join $out btc_lottery.bit]
write_hwdef -force -file [file join $out btc_lottery.hdf]
write_sysdef -force -hwdef [file join $out btc_lottery.hdf] -bitfile [file join $out btc_lottery.bit] -file [file join $out btc_lottery.sysdef]
file copy -force [file join $out btc_lottery.srcs sources_1 bd system hw_handoff system.hwh] [file join $out btc_lottery.hwh]
write_bd_tcl -force [file join $out system.tcl]
puts "BTC_BUILD_OK=$out"
exit
