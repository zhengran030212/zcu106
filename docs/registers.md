# PL 寄存器 ABI 1.0

AXI 基址 `0xA0000000`，范围 4 KiB。所有寄存器为 32 位。PS 使用小端 MMIO。

| 偏移 | 访问 | 内容 |
|---|---|---|
| 0x00 | R | 签名 `0x42544331`（BTC1） |
| 0x04 | R | ABI `0x00010000` |
| 0x08 | W | bit 0：原子装载新任务；bit 1：停止，优先于装载 |
| 0x0c | R | bit 0：正在发射 nonce；bit 1：范围耗尽且流水线排空；bit 2：FIFO 满而暂停；bit 3：存在候选结果 |
| 0x10 | R | 并行 lane 数 |
| 0x14 | R | 每流水级的 SHA 轮数 |
| 0x18 | RW | 新任务的 32 位 tag |
| 0x1c | RW | 起始 nonce |
| 0x20 | R | 已完成 SHA256d 次数低 32 位；读取时锁存高 32 位 |
| 0x24 | R | 上一次读 0x20 时锁存的计数高 32 位 |
| 0x28 | RW | 当前选择的结果 lane，必须小于 0x10 |
| 0x2c | R | 选中 lane 的 FIFO 数量 |
| 0x30 | R | FIFO 首项 nonce，只有 0x2c 非零时有效 |
| 0x34 | R | FIFO 首项任务 tag |
| 0x38 | W | bit 0 为 1 时弹出选中 lane 的 FIFO 首项 |
| 0x40–0x5c | RW | SHA-256 midstate，依次为 H0…H7 的数值 |
| 0x60–0x68 | RW | 区块头第 64…75 字节，按三个大端 32 位字写入 |
| 0x80–0x9c | RW | 256 位数值 target，最低 32 位在 0x80 |

写任务参数不会更改运行中的任务。写 0x08 的装载位才使参数生效，同时清空流水线和结果 FIFO。
每个 lane 有 8 项结果 FIFO。任一 FIFO 满时，所有流水线、nonce 标签与发射计数同时暂停，直到软件取走结果；候选不会因队列满而静默丢弃。

lane i 搜索 `start_nonce+i, start_nonce+i+LANES, …`，到 `0xffffffff` 为止，避免 nonce 回绕重复。
软件在范围排空、结果取完后更新 extranonce2，重新计算 coinbase、merkle root 和 midstate，再提交新任务。

SHA 模块的 digest 是标准 SHA-256 字节序；PoW 比较把完整 32 字节摘要当作小端整数，与完整 256 位 target 作 `<=` 比较。
每个结果在提交矿池前，都会使用 Python hashlib 独立重算 SHA256d。
