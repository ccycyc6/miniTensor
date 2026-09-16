# Verilator-compatible vector VPU

本目录保留官方 CV-X-IF 的接口结构，只对官方接口中 Verilator 5.040 不支持的
`x_register_t.rs` 作工具兼容改写：

```systemverilog
logic [X_NUM_RS-1:0][X_RFR_WIDTH-1:0] rs;
```

接口名称、字段名称、字段宽度、握手规则和 modport 均保持与
`../src/core_v_xif.sv` 一致。官方源文件未被修改。

## 目录

```text
CV-X-IF_Adapter/
  core_v_xif.sv             CV-X-IF 接口定义
  vpu_vector_npc_adapter.sv CV-X-IF/NPC 到真实向量控制器的适配器
  tb_vpu_vector_npc_adapter.sv
Command_Queue/              预留
Controller/
  vpu_pkg.sv                指令编码、解码和公共定义
  vpu_vector_controller.sv  向量指令控制器
  tb_vpu_vector_controller.sv
TensorCore/                 预留
  INT8_GEMM/
  Systolic Array/
  INT32_Accumulator/
  Bias/
    Requant/
      ReLU/
Vector_Processing_Unit/
  vpu_vector_regfile.sv     向量寄存器堆
  Vector_ALU/
    vpu_vector_alu.sv       16-lane INT8 向量 ALU
    tb_vpu_vector_regfile.sv
  Quantization/             预留
  Activation/
    Pooling/                预留
Unified_Buffer/
  unified_buffer.sv         4 KiB 参数化 Local SRAM
  tb_unified_buffer.sv      同步读与 byte mask 写仿真
VPU-Uncached-Master/               预留
  DMA/
    vpu_dma.sv               单 outstanding read 的 Tile DMA
    tb_vpu_dma.sv            DMA 到 Unified Buffer 端到端仿真
```

根目录的 `Makefile` 负责 Verilator 仿真和 VCD 波形。

## 配置

testbench 使用：

```text
X_NUM_RS               = 2
X_ID_WIDTH             = 4
X_RFR_WIDTH            = 128
X_RFW_WIDTH            = 128
X_HARTID_WIDTH         = 1
X_DUALREAD             = 0
X_DUALWRITE            = 0
X_ISSUE_REGISTER_SPLIT = 1
X_MEM_WIDTH            = 32
```

VPU 当前实现 issue、split register、commit/kill、VRF 装载和 result；compressed、
memory、memory-result、中断和 GEMM 尚未实现。

## 演示指令

```text
VADD: custom-0, funct7=0000001, funct3=000, rd = rs1 + rs2
VXOR: custom-0, funct7=0000001, funct3=001, rd = rs1 ^ rs2
VDOT8: custom-0, funct7=0000001, funct3=010,
       rd = signed(rs1[7:0])*signed(rs2[7:0]) + ... +
            signed(rs1[31:24])*signed(rs2[31:24])
VADD8: custom-0, funct7=0000001, funct3=011,
       four independent 8-bit lane additions, wrapping at 8 bits
VMAX8: custom-0, funct7=0000001, funct3=100,
       signed maximum of each independent 8-bit lane
VRELU8: custom-0, funct7=0000001, funct3=101,
        signed INT8 ReLU per lane: max(signed(lane), 0); rs2 is unused
```

这些是当前向量控制器支持的 custom-0 指令编码。

## 模块化边界

```text
CV-X-IF issue/register/commit/result
                 |
       vpu_vector_npc_adapter
                 |
       vpu_vector_controller
                 |
          VRF -> vector ALU

vector instruction controller
  cmd_valid/cmd_ready -> VRF 双读 -> vector ALU
  result_valid/result_ready -> vd 写回 VRF
  load_valid/load_ready -> VRF 初始化（与 command 互斥）
```

`CV-X-IF_Adapter/vpu_vector_npc_adapter.sv` 负责 CV-X-IF/NPC 事务桥接，
并将两个 128-bit 操作数装入真实的向量寄存器堆。
`Controller/vpu_vector_controller.sv` 负责指令字段解析、VRF 双读、ALU 调度和结果写回。
`Vector_Processing_Unit/vpu_vector_regfile.sv` 负责本地向量寄存器存储。

## 向量指令字段与控制协议

向量指令采用 custom-0 R-type 编码（`opcode=7'b0001011`）：

```text
31:25 funct7 = 7'b0000010   向量指令族
24:20 vs2                     源向量寄存器 2
19:15 vs1                     源向量寄存器 1
14:12 funct3                  ADD8/MAX8/RELU8
11:7  vd                      目标向量寄存器
6:0   opcode                  custom-0
```

控制器接口是一条在途命令的 ready/valid 协议：

```text
cmd_valid && cmd_ready       接收 instr、id 和 vs1/vs2/vd
result_valid                 结果保持有效，直到 result_ready
result_valid && result_ready 写回 vd，并释放控制器
cmd_kill                     在执行或结果等待阶段取消当前命令，不写回
load_valid && load_ready     用 byte mask 装载 VRF；与 command 同周期时 load 优先
```

当前 `VLEN=128`（16 个 INT8 lane），`result_data` 是 ALU 结果；结果接口的
`result_id/result_vd` 分别用于上层 scheduler 做事务匹配和提交目的寄存器。
CV-X-IF/NPC 适配器已经连接 issue/register/commit/result 时序；L2 cache、DMA
和中断路径仍属于后续集成层工作。

## 仿真

```sh
cd /home/ccy/Documents/qs/miniTensor
make clean
make sim
```

运行 CV-X-IF/NPC 适配器与真实向量控制器的闭环仿真：

```sh
make npc-sim
```

运行向量指令控制器闭环仿真：

```sh
make OBJ_DIR=/tmp/vpu_obj_vector vector-sim
```

预期最后一行：

```text
PASS: vector instruction fields, controller protocol and VRF integration completed
```

`make sim` 默认运行真实向量控制器，预期最后一行：

```text
PASS: vector instruction fields, controller protocol and VRF integration completed
```

运行独立 Unified Buffer 仿真：

```sh
make ub-sim
```

默认 Unified Buffer 为 `128-bit x 256`（4 KiB），使用单时钟同步读和逐字节
写使能。当前只实现 Local SRAM 存储体，尚未接入 DMA、总线或计算单元。预期最后一行：

```text
PASS: unified buffer synchronous read and byte-mask writes completed
```

运行独立 DMA 到 Unified Buffer 仿真：

```sh
make dma-sim
```

DMA 每次只允许一个未完成的 128-bit memory read，收到响应后写入 Unified Buffer，
源地址按 16 字节递增、目标地址按一行递增。当前使用 ready/valid memory model，
尚未接入 AXI、TileLink 或 OBI。

生成波形：

```sh
make wave
gtkwave vector_controller.vcd
```

## 与官方版本的关系

官方版本：

```text
src/core_v_xif.sv
```

兼容版本：

```text
CV-X-IF_Adapter/core_v_xif.sv
```

两者不能在同一次编译中同时出现，因为都定义了同名的 `core_v_xif` interface。

当使用 Questa、VCS 等支持官方写法的工具时，可以把
`CV-X-IF_Adapter/core_v_xif.sv` 替换为 `../src/core_v_xif.sv`。VPU 侧的字段连接不需要改变：

```systemverilog
xif.issue_req.instr
xif.issue_req.id
xif.issue_resp.accept
xif.register.rs[0]
xif.register.rs[1]
xif.commit.commit_kill
xif.result.data
xif.result.rd
xif.result_valid
xif.result_ready
```

## 与 Mundus/NPC 的关系

`CV-X-IF_Adapter/vpu_vector_npc_adapter.sv` 将 NPC 侧信号接入真实向量控制器，
不会修改 `Mundus/npc`。真实接入时，NPC 需要实现 CPU 一侧的 CV-X-IF 驱动：

1. `IDU` 识别 `custom-0`，驱动 `issue_valid/issue_req`。
2. `ISU` 使用最终旁路后的 rs1/rs2 值驱动 `register_valid/register`。
3. `WBU` 或 retire 控制驱动 `commit_valid/commit`。
4. 接收 `result_valid/result`，并用 `result_ready` 形成 GPR 写回。
5. 维护递增且不重复的 `id`。
6. flush、异常或分支错误时发送 `commit_kill`。

建议先在 NPC 外围加入一个扁平 Chisel Bundle，再由 SV adapter 接入本目录的
`core_v_xif` interface；Chisel 不需要直接解析 SystemVerilog interface。
