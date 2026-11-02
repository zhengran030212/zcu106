set hdf /home/azureuser/btc-lottery/build/zcu106_l1_r2_100/btc_lottery.hdf
set out /home/azureuser/btc-lottery/boot
file mkdir $out
cd $out
set hw [open_hw_design $hdf]
generate_app -hw $hw -os standalone -proc psu_cortexa53_0 -app zynqmp_fsbl -dir $out/fsbl -compile
generate_app -hw $hw -os standalone -proc psu_pmu_0 -app zynqmp_pmufw -dir $out/pmufw -compile
puts "=== ELF files ==="
puts [exec find $out -name "*.elf"]
