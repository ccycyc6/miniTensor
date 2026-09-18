`timescale 1ns/1ps

package tensor_pkg;
  localparam logic [6:0] TENSOR_CUSTOM0_OPCODE = 7'b0001011;
  localparam logic [6:0] TENSOR_GEMM_FUNCT7   = 7'b0000101;
  localparam logic [2:0] TENSOR_GEMM_FUNCT3   = 3'b000;

  localparam int unsigned TENSOR_DIM = 4;
  localparam int unsigned TENSOR_ELEM_WIDTH = 8;
  localparam int unsigned TENSOR_ACC_WIDTH = 32;
  localparam int unsigned TENSOR_TILE_WIDTH =
      TENSOR_DIM * TENSOR_DIM * TENSOR_ELEM_WIDTH;
  localparam int unsigned TENSOR_RESULT_WIDTH =
      TENSOR_DIM * TENSOR_DIM * TENSOR_ACC_WIDTH;
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic is_tensor_gemm(input logic [31:0] instr);
    is_tensor_gemm =
        (instr[6:0] == TENSOR_CUSTOM0_OPCODE) &&
        (instr[31:25] == TENSOR_GEMM_FUNCT7) &&
        (instr[14:12] == TENSOR_GEMM_FUNCT3);
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic [31:0] make_tensor_gemm(
      input logic [4:0] rd,
      input logic [4:0] src_reg_1,
      input logic [4:0] src_reg_2);
    make_tensor_gemm = {
      TENSOR_GEMM_FUNCT7,
      src_reg_2,
      src_reg_1,
      TENSOR_GEMM_FUNCT3,
      rd,
      TENSOR_CUSTOM0_OPCODE
    };
  endfunction
endpackage
