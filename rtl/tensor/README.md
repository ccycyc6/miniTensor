# Tensor implementation area

The first implemented tensor operation is a non-pipelined 4x4 signed INT8
GEMM. It uses the existing 128-bit Unified Buffer without changing its 1R1W
interface:

```text
A: one UB row, row-major signed INT8, 16 elements
B: one UB row, row-major signed INT8, 16 elements
C: four UB rows, row-major signed INT32, four elements per row
C = A * B
```

`MT_GEMM` uses `funct7=0000101`, `funct3=000` in `custom-0`:

```text
rs1[7:0]  = A UB row
rs1[15:8] = B UB row
rs2[7:0]  = C UB start row (C..C+3 must fit)
```

All other operand bits are reserved and must be zero. The command is accepted
through the existing CV-X-IF issue/register/commit/result sequence. A killed
or invalid command has no UB write side effect.

The current implementation boundaries are:

```text
MXU/
  INT8_GEMM/
  Systolic_Array/
  INT32_Accumulator/
Epilogue/
  Bias/
  Requant/
  ReLU/
```

`tensor_gemm_core` runs a fixed 4x4 systolic array for ten cycles, holds its
result under backpressure, and `tensor_controller` performs the two synchronous
UB reads followed by four sequential result writes. Larger K tiles, bias,
requantization, ReLU, double buffering, and pipelining remain future work.
