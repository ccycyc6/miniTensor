# miniTensor

miniTensor 是 RV32 CPU 的外接 AI 协处理器。当前版本与 CPU 共用 `clk/rst`，采用
单命令在途的顺序 FSM，暂不使用流水线。统一顶层已经打通：

```text
Uncached Memory
      | MT_LOAD / 128-bit DMA read
      v
Unified Buffer
      | two synchronous reads
      v
16-lane INT8 Vector Unit
      | ADD8 / MAX8 / RELU8 result
      v
Unified Buffer
      | MT_STORE / 128-bit DMA write
      v
Uncached Memory
```

CPU 只通过 CV-X-IF 风格的 32-bit 指令、`rs1/rs2` 参数和标量完成结果控制协处理器。
向量数据不经过 CPU GPR。DMA 不提供硬件缓存一致性，软件必须使用 Uncached 地址，
且不能通过 cacheable alias 同时访问同一缓冲区。

## 目录

```text
rtl/
  common/minitensor_pkg.sv          MT_LOAD / MT_STORE 编码
  interface/core_v_xif.sv           NPC 接入使用的 CV-X-IF 协议定义
  control/vpu_vector_controller.sv  单命令向量控制器
  memory/vpu_dma.sv                 双向、单 outstanding DMA
  memory/unified_buffer.sv          256 x 128-bit Local SRAM
  vector/vpu_pkg.sv                 ADD8 / MAX8 / RELU8 编码
  vector/vpu_vector_regfile.sv      32 x 128-bit VRF
  vector/vpu_vector_alu.sv          16-lane INT8 ALU
  top/mini_tensor_top.sv            唯一的 NPC-facing 集成顶层
  tensor/                            后续 MXU 与 Epilogue
tb/
  top/tb_mini_tensor_top.sv         NPC + Uncached Memory 功能模型
  control/ memory/ vector/           独立单元测试
for_ai/                              赛题和项目背景
```

旧的 `vpu_vector_npc_adapter` 已被统一顶层取代。NPC 模型仍使用 issue、commit/kill、
result ready/valid 事务，不修改外部 NPC 工程。`core_v_xif.sv` 保留为后续 Chisel
扁平 Bundle 到标准 CV-X-IF 的连接依据。

## 指令与参数

三类指令都使用 `custom-0`，完成后向 `rd` 返回标量状态 `0`。只有收到匹配
`id/hartid` 的正常 commit 后才产生 UB 或外部内存副作用。

### MT_LOAD

```text
funct7 = 0000011, funct3 = 000
rs1 value       = Uncached Memory 源字节地址，16-byte 对齐
rs2 value[7:0]  = UB 起始行号
rs2 value[15:8] = 128-bit 数据行数，必须非零
```

### Vector

沿用 `funct7=0000010`：

```text
funct3 = 000  ADD8
funct3 = 001  MAX8
funct3 = 010  RELU8

rs1 value[7:0]  = UB 源操作数 A 行号
rs1 value[15:8] = UB 源操作数 B 行号
rs2 value[7:0]  = UB 结果行号
```

顶层顺序读取两行 UB，将数据装入内部 VRF 的 `v1/v2`，执行结果写入 `v3` 和指定
UB 行。RELU8 只使用操作数 A；当前控制器仍读取 B，以保持统一的非流水控制流程。

### MT_STORE

```text
funct7 = 0000100, funct3 = 000
rs1 value       = Uncached Memory 目标字节地址，16-byte 对齐
rs2 value[7:0]  = UB 起始行号
rs2 value[15:8] = 128-bit 数据行数，必须非零
```

所有命令都会检查保留位、地址对齐和 UB 范围；非法参数不会被接受。

## 控制与存储

统一顶层一次只接受一条指令。DMA、VPU 和外部 debug 读端口按命令阶段独占 UB，
所以当前 1R1W SRAM 不需要多 Bank 仲裁。DMA Load 使用显式 read request/response，
DMA Store 使用 write ready/valid；两个方向都只允许一个 outstanding 事务。

commit-kill 只在命令开始产生副作用前处理。一旦收到正常 commit，当前命令运行到
完成，并保持 result valid，直到 NPC 拉高 result ready。

## 仿真

完整 NPC 闭环：

```sh
make sim
# 等价：make top-sim 或 make npc-sim
```

预期结果：

```text
PASS: NPC drove Memory -> UB -> VPU -> UB -> Memory closed loop
```

该测试依次提交 `MT_LOAD`、`VADD8`、`MT_STORE`，检查 commit 前无副作用、结果
backpressure、UB 中间结果、外部内存最终结果和 killed store 无写入。

独立回归：

```sh
make vector-sim
make vrf-sim
make ub-sim
make dma-sim
```

`dma-sim` 同时验证 Memory -> UB 和 UB -> Memory。

## 下一步

下一步应先把 `mini_tensor_top` 的扁平 NPC 端口接到实际 Chisel Bundle，并在 NPC
侧执行上述三条指令序列；TensorCore、双缓冲、多 Bank、多 outstanding 和命令队列
继续保持预留。
