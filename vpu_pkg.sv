`timescale 1ns/1ps

// Minimal instruction definitions for the standalone CV-X-IF VPU example.
//
// The encoding uses RISC-V custom-0 (opcode 0001011).  The module is
// intentionally small: it demonstrates the CV-X-IF transaction protocol,
// not a complete vector ISA.
package vpu_pkg;

  localparam logic [6:0] VPU_CUSTOM0_OPCODE = 7'b0001011;
  localparam logic [6:0] VPU_FUNCT7         = 7'b0000001;

  localparam logic [2:0] VPU_FUNCT3_ADD     = 3'b000;
  localparam logic [2:0] VPU_FUNCT3_XOR     = 3'b001;
  localparam logic [2:0] VPU_FUNCT3_DOT8    = 3'b010;
  localparam logic [2:0] VPU_FUNCT3_ADD8    = 3'b011;
  localparam logic [2:0] VPU_FUNCT3_MAX8    = 3'b100;
  localparam logic [2:0] VPU_FUNCT3_RELU8   = 3'b101;

  localparam logic [2:0] VPU_OP_ADD         = 3'd0;
  localparam logic [2:0] VPU_OP_XOR         = 3'd1;
  localparam logic [2:0] VPU_OP_DOT8        = 3'd2;
  localparam logic [2:0] VPU_OP_ADD8        = 3'd3;
  localparam logic [2:0] VPU_OP_MAX8        = 3'd4;
  localparam logic [2:0] VPU_OP_RELU8       = 3'd5;
  localparam logic [2:0] VPU_OP_INVALID     = 3'd7;

  // Operand and destination fields are intentionally don't-care for decode.
  /* verilator lint_off UNUSEDSIGNAL */
  function automatic logic is_vpu_instruction(input logic [31:0] instr);
    is_vpu_instruction =
        (instr[6:0]   == VPU_CUSTOM0_OPCODE) &&
        (instr[31:25] == VPU_FUNCT7) &&
        ((instr[14:12] == VPU_FUNCT3_ADD) ||
         (instr[14:12] == VPU_FUNCT3_XOR) ||
         (instr[14:12] == VPU_FUNCT3_DOT8) ||
         (instr[14:12] == VPU_FUNCT3_ADD8) ||
         (instr[14:12] == VPU_FUNCT3_MAX8) ||
         (instr[14:12] == VPU_FUNCT3_RELU8));
  endfunction
  /* verilator lint_on UNUSEDSIGNAL */

  function automatic logic [2:0] decode_vpu_op(input logic [31:0] instr);
    if (!is_vpu_instruction(instr)) begin
      decode_vpu_op = VPU_OP_INVALID;
    end else if (instr[14:12] == VPU_FUNCT3_ADD) begin
      decode_vpu_op = VPU_OP_ADD;
    end else if (instr[14:12] == VPU_FUNCT3_XOR) begin
      decode_vpu_op = VPU_OP_XOR;
    end else if (instr[14:12] == VPU_FUNCT3_DOT8) begin
      decode_vpu_op = VPU_OP_DOT8;
    end else if (instr[14:12] == VPU_FUNCT3_ADD8) begin
      decode_vpu_op = VPU_OP_ADD8;
    end else if (instr[14:12] == VPU_FUNCT3_MAX8) begin
      decode_vpu_op = VPU_OP_MAX8;
    end else begin
      decode_vpu_op = VPU_OP_RELU8;
    end
  endfunction

  function automatic logic [31:0] make_vpu_rtype(
      input logic [2:0] funct3,
      input logic [4:0] rd,
      input logic [4:0] rs1,
      input logic [4:0] rs2);
    make_vpu_rtype = {
      VPU_FUNCT7,
      rs2,
      rs1,
      funct3,
      rd,
      VPU_CUSTOM0_OPCODE
    };
  endfunction

endpackage
