# ZCU106 BTC solo 彩票机

面向 Xilinx ZCU106（ZU7EV、加密禁用版也适用）的 FPGA Bitcoin SHA-256d 挖矿工程。
输出普通未加密 bitstream。默认 1 条流水线、每级 2 轮 SHA、目标时钟 100 MHz；只有布线后时序通过才生成 bitstream。
理论上流水线填满后，每 lane 每周期完成一个 nonce；实际算力以硬件完成计数器测量为准。

目前工程支持两种运行方式：

- USB JTAG：Mac 上的 Python 连接 solo 矿池，通过 OpenOCD 的 AXI MEM-AP 管理 PL。无需 SD 卡、PS Linux 或 DDR 初始化。
- PS Linux：同一客户端在板载 ARM 上运行，通过 `/dev/mem` 访问 PL。需要已有可启动的 Linux 和与工程匹配的 PL 时钟/复位配置。

当前收款地址在 `config/miner.json`，来自用户明确提供的公开 BTC 地址。工程不需要钱包私钥或助记词。
默认使用 [Solo CKPool](https://solo.ckpool.org/) 的 Stratum V1 接口；该服务收取 2% 费用。普通 share 用于反馈算力，只有找到满足 Bitcoin 网络目标的有效区块才有出块收益。

## 验证

本机需要 Python 3.10+、Icarus Verilog、Verilator。运行：

```sh
make check
make probe
```

测试覆盖 SHA 与 hashlib 对照、Bitcoin 创世区块、Stratum 字节序、目标难度、Taproot 地址校验、授权前禁止计算、clean_jobs、新 extranonce、每次提交的独立验算，以及 RTL 多 lane nonce 分配、FIFO 反压、新任务清空、32 位回绕和 AXI 独立 AW/W、WSTRB、读写反压。

`probe` 只检查联网、授权和任务编码，不计算、不提交 share。

## 服务器构建

Vivado 2019.1 位于服务器已有容器镜像 `aperloff/vivado-docker:sl7_vivado2019.1_x11` 中，包含 ZU7EV 器件和 ZCU106 板级文件。

```sh
python3 scripts/build_remote.py
```

SSH 私钥从工程外部读取，只供 SSH 认证，不会装入源码归档。服务器工作目录为 `/home/azureuser/btc-lottery`。
本地结果放在 `build/zcu106_l1_r2_100/`；包括 `.bit`、`.bin`、`.hwh`、时序/资源/DRC 报告和匹配的 `psu_init.tcl`。

已完成的构建可单独取回：

```sh
python3 scripts/build_remote.py --fetch-only
```

## USB JTAG 上板

本机依赖 `openfpgaloader`、`openocd`。macOS 上访问板载 FTDI JTAG 可能需要 sudo。
以下操作面向空闲 ZCU106，初始化本工程的 PS PLL、PL 时钟和 fabric 复位；不写 QSPI 或 SD 卡。

完成构建后可以一键装载、自检并开始挖矿：

```sh
python3 scripts/run_usb.py
```

脚本会在终端请求 sudo 认证，不保存密码。若只做上板验证，使用 `--selftest-only`。
需要留在后台运行时使用 `python3 scripts/run_usb.py --detach`，日志在 `build/miner.log`。
停止后台矿机使用 `python3 scripts/stop_usb.py`。
以下是等价的分步操作，适合排查连接问题。

先启动本机 OpenOCD：

```sh
sudo openocd -f config/zcu106-openocd.cfg
```

在另一个终端初始化时钟：

```sh
python3 scripts/ps_init_openocd.py build/zcu106_l1_r2_100/psu_init.tcl --phase clocks
```

停止 OpenOCD，释放 JTAG 后加载 PL SRAM：

```sh
sudo openFPGALoader -b zcu106 --freq 6000000 build/zcu106_l1_r2_100/btc_lottery.bit
```

重新启动 OpenOCD，再运行 fabric 初始化与真实硬件自检：

```sh
python3 scripts/ps_init_openocd.py build/zcu106_l1_r2_100/psu_init.tcl --phase fabric
python3 scripts/selftest_hardware.py
make mine
```

自检会让 PL 找到创世区块的已知 nonce，并重算出块哈希，再测量实际完成计数器。结果保存在 `build/hardware-selftest.json`。
运行日志中的 `openocd … MH/s` 来自 PL 完成计数器。`--backend cpu` 是明确标识的诊断模式，不代表 FPGA 算力。

中断客户端会停止 PL；失去矿池连接也会停止 PL，随后自动重连。正常 nonce 范围耗尽会自动换 extranonce2，不重复搜索相同头部。
当前 USB 版需要电脑保持运行；断电后需要重新装载。独立开机运行需要进一步制作 PS 启动镜像。

## 源码

- `rtl/sha256_pipeline.sv`：可配置轮数的 SHA 压缩流水线。
- `rtl/btc_miner.sv`：双 SHA、并行 nonce、完整目标比较和结果队列。
- `rtl/btc_axi.v`：AXI-Lite 控制与统计。
- `host/btc_lottery/`：Stratum V1、任务构造、独立验算和 JTAG/MMIO 后端。
- `scripts/build_zcu106.tcl`：ZCU106 PS、AXI 和 PL 的完整 Vivado 构建。
- [寄存器定义](docs/registers.md)。

该工程是低算力 solo 实验设备；可正常计算和提交 share，并不意味着容易挖出区块。
