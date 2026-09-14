`timescale 1ns/1ps

// Pure combinational execution block. Protocol and state live in vpu_basic.
module vpu_compute #(
  parameter int unsigned DATA_WIDTH = 32,
  parameter int unsigned RESULT_WIDTH = 32
) (
  input logic [2:0] op,
  input logic [DATA_WIDTH-1:0] a,
  input logic [DATA_WIDTH-1:0] b,
  output logic [RESULT_WIDTH-1:0] result
);
  import vpu_pkg::*;

  function automatic logic [RESULT_WIDTH-1:0] dot8(
      input logic [DATA_WIDTH-1:0] x,
      input logic [DATA_WIDTH-1:0] y);
    logic signed [7:0] x0, x1, x2, x3;
    logic signed [7:0] y0, y1, y2, y3;
    logic signed [15:0] p0, p1, p2, p3;
    logic signed [17:0] e0, e1, e2, e3, sum;
    begin
      x0 = x[7:0]; x1 = x[15:8]; x2 = x[23:16]; x3 = x[31:24];
      y0 = y[7:0]; y1 = y[15:8]; y2 = y[23:16]; y3 = y[31:24];
      p0 = x0 * y0; p1 = x1 * y1; p2 = x2 * y2; p3 = x3 * y3;
      e0 = {{2{p0[15]}}, p0}; e1 = {{2{p1[15]}}, p1};
      e2 = {{2{p2[15]}}, p2}; e3 = {{2{p3[15]}}, p3};
      sum = e0 + e1 + e2 + e3;
      dot8 = {{(RESULT_WIDTH-18){sum[17]}}, sum};
    end
  endfunction

  function automatic logic [RESULT_WIDTH-1:0] add8(
      input logic [DATA_WIDTH-1:0] x,
      input logic [DATA_WIDTH-1:0] y);
    logic [7:0] c0, c1, c2, c3;
    begin
      c0 = x[7:0] + y[7:0]; c1 = x[15:8] + y[15:8];
      c2 = x[23:16] + y[23:16]; c3 = x[31:24] + y[31:24];
      add8 = '0;
      add8[7:0] = c0; add8[15:8] = c1;
      add8[23:16] = c2; add8[31:24] = c3;
    end
  endfunction

  function automatic logic [RESULT_WIDTH-1:0] max8(
      input logic [DATA_WIDTH-1:0] x,
      input logic [DATA_WIDTH-1:0] y);
    logic signed [7:0] x0, x1, x2, x3;
    logic signed [7:0] y0, y1, y2, y3;
    logic signed [7:0] c0, c1, c2, c3;
    begin
      x0 = x[7:0]; x1 = x[15:8]; x2 = x[23:16]; x3 = x[31:24];
      y0 = y[7:0]; y1 = y[15:8]; y2 = y[23:16]; y3 = y[31:24];
      c0 = (x0 > y0) ? x0 : y0; c1 = (x1 > y1) ? x1 : y1;
      c2 = (x2 > y2) ? x2 : y2; c3 = (x3 > y3) ? x3 : y3;
      max8 = '0;
      max8[7:0] = c0; max8[15:8] = c1;
      max8[23:16] = c2; max8[31:24] = c3;
    end
  endfunction

  function automatic logic [RESULT_WIDTH-1:0] relu8(
      input logic [DATA_WIDTH-1:0] x);
    logic signed [7:0] x0, x1, x2, x3;
    logic signed [7:0] c0, c1, c2, c3;
    begin
      x0 = x[7:0]; x1 = x[15:8]; x2 = x[23:16]; x3 = x[31:24];
      c0 = (x0 > 0) ? x0 : 0; c1 = (x1 > 0) ? x1 : 0;
      c2 = (x2 > 0) ? x2 : 0; c3 = (x3 > 0) ? x3 : 0;
      relu8 = '0;
      relu8[7:0] = c0; relu8[15:8] = c1;
      relu8[23:16] = c2; relu8[31:24] = c3;
    end
  endfunction

  always_comb begin
    result = '0;
    case (op)
      VPU_OP_ADD:  result = a + b;
      VPU_OP_XOR:  result = a ^ b;
      VPU_OP_DOT8: result = dot8(a, b);
      VPU_OP_ADD8: result = add8(a, b);
      VPU_OP_MAX8: result = max8(a, b);
      VPU_OP_RELU8: result = relu8(a);
      default:     result = '0;
    endcase
  end
endmodule
