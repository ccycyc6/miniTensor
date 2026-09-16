# miniTensor

miniTensor 是挂接在 RV32 CPU 外部的 AI 协处理器。目前所有模块与 CPU 共用
`clk/rst`，采用单命令在途、顺序 FSM 调度，暂不设计流水线。

当前已经形成第一条集成数据通路：CPU 通过 CV-X-IF 风格接口发出 `MT_LOAD`，
指令正常提交后，DMA 从 Uncached Memory 搬运连续的 128-bit 数据行到 4 KiB
Unified Buffer，完成后向 CPU 返回状态。commit-kill 不会产生内存请求或 UB 写入。

## 架构边界

```text
RV32 CPU
   | CV-X-IF control/result (32-bit rs1/rs2/result)
   v
mini_tensor_top
   |-- sequential command FSM
   |-- uncached DMA (128-bit, one outstanding read)
   `-- Unified Buffer (256 x 128-bit, synchronous 1R1W)
              |
              +-- Vector Unit       implemented separately
              `-- Tensor Unit       reserved

DMA <------ uncached memory port ------> SRAM / DDR
```

CV-X-IF 只承担指令、控制参数和标量完成结果。向量和矩阵数据通过 DMA 与
Unified Buffer 搬运，不经过 CPU GPR。DMA 不支持硬件缓存一致性，软件必须使用
Uncached 地址区，并避免通过 cacheable alias 同时访问同一缓冲区。

## 目录

```text
rtl/
  common/
    minitensor_pkg.sv              miniTensor 指令编码
  interface/
    core_v_xif.sv                  Verilator 兼容 CV-X-IF 定义
  frontend/
    vpu_vector_npc_adapter.sv      现有 128-bit 向量演示适配器
  control/
    vpu_vector_controller.sv       顺序向量控制器
  memory/
    vpu_dma.sv                     单 outstanding Uncached Load DMA
    unified_buffer.sv              4 KiB Local SRAM
  vector/
    vpu_pkg.sv                     向量指令编码
    vpu_vector_regfile.sv          32 x 128-bit VRF
    vpu_vector_alu.sv              16-lane INT8 ALU
  top/
    mini_tensor_top.sv             MT_LOAD 集成顶层
  tensor/                          后续 MXU 与 Epilogue
tb/
  frontend/ control/ memory/ vector/ top/
for_ai/                             赛题和项目背景
```

`rtl/` 只放可综合模块，`tb/` 只放仿真代码。不会修改外部 NPC 模块；真实接入时，
由 NPC/Chisel wrapper 将扁平信号连接到 `mini_tensor_top`。

## MT_LOAD

`MT_LOAD` 使用 R-type custom-0 编码：

```text
31:25  funct7 = 0000011
24:20  rs2
19:15  rs1
14:12  funct3 = 000
11:7   rd
6:0    opcode = 0001011
```

CPU 已读取的寄存器值含义：

```text
rs1[31:0]  Uncached Memory 源字节地址
rs2[7:0]   Unified Buffer 起始行号
rs2[15:8]  搬运的 128-bit 行数，必须非零
rd          状态返回寄存器；成功返回 0
```

源地址必须按 16 byte 对齐，`rs2[31:16]` 必须为零，目标范围不能越过 UB；
不满足约束的指令不会被接受。

执行状态依次为 `IDLE -> WAIT_COMMIT -> DMA_START -> DMA_WAIT -> RESULT`。
只有匹配 `id/hartid` 的正常 commit 才会启动 DMA。

## 仿真

运行完整的 `MT_LOAD` 集成测试：

```sh
make top-sim
```

测试覆盖 commit 前无副作用、正常 DMA 搬运、busy 时阻止新指令、result
backpressure 保持以及 commit-kill。预期最后一行：

```text
PASS: committed MT_LOAD, commit-kill and UB integration completed
```

其他独立测试：

```sh
make npc-sim
make vector-sim
make vrf-sim
make ub-sim
make dma-sim
```

现有 `vpu_vector_npc_adapter` 使用 128-bit `X_RFR_WIDTH`，仅用于向量功能验证。
真实 RV32 miniTensor 顶层的 `rs1/rs2/result` 均为 32-bit。

## 下一步

在保持单时钟、单命令和非流水架构的前提下，为 DMA 增加 UB 到 Uncached Memory
的 `MT_STORE`，形成 Memory -> UB -> Memory 的闭环。TensorCore、多 Bank、双缓冲、
多 outstanding 和命令队列继续保持预留。
