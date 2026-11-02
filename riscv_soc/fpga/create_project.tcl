# ZCU106 PL: CVA6 Sv39 plus the blit GPU. Run on the Azure Vivado 2019.1 container.
# Project files stay on /data, not the 29G root disk.
set root /data/zcu106-riscv
set origin /home/azureuser/riscv/cva6
set proj $root/vivado/zcu106_cva6
file mkdir $proj
create_project zcu106_cva6 $proj -part xczu7ev-ffvc1156-2-e -force
set_property board_part [lindex [lsort -dictionary [get_board_parts -quiet xilinx.com:zcu106:part0:*]] end] [current_project]
add_files [glob $root/soc/rtl/*.sv]
set_property include_dirs [list \
    $origin/core/include \
    $origin/vendor/pulp-platform/axi/include \
    $origin/vendor/pulp-platform/common_cells/include \
    $origin/corev_apu/register_interface/include \
] [current_fileset]
set_property top gpu_blit [current_fileset]
puts "CVA6_PROJECT_READY $proj"
puts "NOTE: top is gpu_blit until the CVA6 file list is elaborated. Do not call this the bootable SoC yet."
exit
