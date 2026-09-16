# Tensor implementation area

The non-pipelined first version reserves these implementation boundaries:

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

Tensor blocks are intentionally not connected until the uncached load/store
path and Unified Buffer ownership protocol are complete.
