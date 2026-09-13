# Verilator-compatible CV-X-IF VPU and NPC-facing model

本目录保留官方 CV-X-IF 的接口结构，只对官方接口中 Verilator 5.040 不支持的
`x_register_t.rs` 作工具兼容改写：

```systemverilog
logic [X_NUM_RS-1:0][X_RFR_WIDTH-1:0] rs;
```

接口名称、字段名称、字段宽度、握手规则和 modport 均保持与
`../src/core_v_xif.sv` 一致。官方源文件未被修改。

## 文件

- `core_v_xif_compat.sv`：官方 `core_v_xif` 的 Verilator 兼容版本。
- `vpu_basic.sv`：直接使用 `core_v_xif` 的最小协处理器；数据宽度从接口类型自动推导。
- `vpu_compute.sv`：纯组合执行单元，集中实现 VADD、VXOR、VDOT8、VADD8、VMAX8、VRELU8。
- `vpu_vector_regfile.sv`：独立的 32×128-bit 本地向量寄存器堆，双读口、单写口、byte write mask。
- `vpu_npc_model.sv`：模拟 NPC 的指令、GPR 操作数、commit/kill 和写回握手，不修改 NPC。
- `vpu_pkg.sv`：custom-0 指令的编码和解码。
- `tb_vpu_basic.sv`：通过官方接口字段驱动的自检 testbench。
- `tb_vpu_npc_model.sv`：NPC-facing 适配器的独立仿真 demo。
- `tb_vpu_vector_regfile.sv`：向量寄存器堆的复位、双读和掩码写测试。
- `Makefile`：Verilator 仿真和 VCD 波形。

已删除原来的扁平 `vpu_basic_core.sv`，避免维护两套接口实现。

## 配置

testbench 使用：

```text
X_NUM_RS               = 2
X_ID_WIDTH             = 4
X_RFR_WIDTH            = 32
X_RFW_WIDTH            = 32
X_HARTID_WIDTH         = 1
X_DUALREAD             = 0
X_DUALWRITE            = 0
X_ISSUE_REGISTER_SPLIT = 1
X_MEM_WIDTH            = 32
```

VPU 当前只实现 issue、split register、commit/kill 和 result；compressed、
memory、memory-result、中断、GEMM 和 L2 master 均未实现。

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

它们是验证 CV-X-IF 通信的占位指令，不是最终向量 ISA。

## 模块化边界

```text
CV-X-IF issue/register/commit/result
                 |
             vpu_basic
                 |
            vpu_compute

vpu_vector_regfile
  双读、单写、byte mask
  （当前独立验证，待后续向量指令绑定）
```

`vpu_basic` 只负责 CV-X-IF 事务状态机；`vpu_compute` 只负责组合计算；
`vpu_vector_regfile` 只负责本地向量寄存器存储。当前没有擅自定义 VRF 的
load/store 指令，后续确定向量 ISA 后再连接寄存器寻址和控制逻辑。

## 仿真

```sh
cd /home/ccy/Documents/qs/vpu
make clean
make sim
```

模拟 NPC 侧接口，不编译 NPC：

```sh
make npc-sim
```

预期输出：

```text
[1] VADD: rs1=17 rs2=25 -> rd=x3 data=42
[1b] VDOT8: signed four-lane INT8 dot product -> rd=x9 data=368
[1c] VADD8: four independent 8-bit lanes with wraparound -> rd=x10 data=0x02040608
[1d] VMAX8: signed four-lane INT8 maximum -> rd=x11 data=0x05037f00
[1e] VRELU8: signed four-lane INT8 ReLU -> rd=x12 data=0x7f050000
[2] VXOR: result remains stable while result_ready=0
[3] Standard ADD is rejected by the VPU
[4] A killed VADD produces no result
[5] Positive commit may arrive before split register operands
PASS: official-compatible CV-X-IF VPU demo completed
```

生成波形：

```sh
make wave
gtkwave vpu_basic.vcd
```

## 与官方版本的关系

官方版本：

```text
src/core_v_xif.sv
```

兼容版本：

```text
core_v_xif.sv
```

两者不能在同一次编译中同时出现，因为都定义了同名的 `core_v_xif` interface。

当使用 Questa、VCS 等支持官方写法的工具时，可以把
`core_v_xif_compat.sv` 替换为 `../src/core_v_xif.sv`。VPU 侧的字段连接不需要改变：

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

`vpu_npc_model.sv` 只用于在 VPU 工程内复现 NPC 的时序，不会修改
`Mundus/npc`。真实接入时，NPC 需要实现 CPU 一侧的 CV-X-IF 驱动：

1. `IDU` 识别 `custom-0`，驱动 `issue_valid/issue_req`。
2. `ISU` 使用最终旁路后的 rs1/rs2 值驱动 `register_valid/register`。
3. `WBU` 或 retire 控制驱动 `commit_valid/commit`。
4. 接收 `result_valid/result`，并用 `result_ready` 形成 GPR 写回。
5. 维护递增且不重复的 `id`。
6. flush、异常或分支错误时发送 `commit_kill`。

建议先在 NPC 外围加入一个扁平 Chisel Bundle，再由 SV adapter 接入本目录的
`core_v_xif` interface；Chisel 不需要直接解析 SystemVerilog interface。
