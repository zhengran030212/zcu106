# Full synthesis of the same ZCU106 top that elaborated.
# One thread, so a rootfs build can keep the other cores.
# Stops after synth. Implementation is a later step.
set cva6 /home/azureuser/riscv/cva6
set proj_dir /data/zcu106-riscv/vivado/synth
file mkdir $proj_dir
cd $proj_dir

create_project zcu106_cva6_synth $proj_dir -part xczu7ev-ffvc1156-2-e -force
set_param general.maxThreads 1

set_property include_dirs [list \
    $cva6/corev_apu/fpga/src/axi_sd_bridge/include \
    $cva6/vendor/pulp-platform/common_cells/include \
    $cva6/vendor/pulp-platform/axi/include \
    $cva6/core/cache_subsystem/hpdcache/rtl/include \
    $cva6/core/cache_subsystem/hpdcache/rtl/src/utils/ecc \
    $cva6/corev_apu/register_interface/include \
    $cva6/corev_apu/instr_tracing/ITI/include \
    $cva6/core/include \
] [current_fileset]

add_files -norecurse $cva6/corev_apu/fpga/src/zcu106.svh
set hdr [get_files *zcu106.svh]
set_property file_type {Verilog Header} $hdr
set_property is_global_include true $hdr

source $cva6/corev_apu/fpga/scripts/add_sources.tcl
set_property top ariane_xilinx [current_fileset]
update_compile_order -fileset sources_1

synth_design -top ariane_xilinx -part xczu7ev-ffvc1156-2-e

set ariane [get_cells -quiet -hierarchical -filter {REF_NAME == ariane}]
set disp [get_cells -quiet -hierarchical -filter {REF_NAME == zcu106_display}]
set gpu [get_cells -quiet -hierarchical -filter {REF_NAME == gpu_blit}]
set scan [get_cells -quiet -hierarchical -filter {REF_NAME == fb_scanout}]
puts "SYNTH_ARIANE_COUNT [llength $ariane]"
puts "SYNTH_DISPLAY_COUNT [llength $disp]"
puts "SYNTH_GPU_COUNT [llength $gpu]"
puts "SYNTH_SCANOUT_COUNT [llength $scan]"
if {[llength $ariane] < 1 || [llength $disp] < 1 || [llength $gpu] < 1} {
    puts "SYNTH_FAIL"
    exit 1
}
report_utilization -hierarchical -file $proj_dir/utilization.rpt
write_checkpoint -force $proj_dir/synth.dcp
puts "SYNTH_OK"
exit 0
