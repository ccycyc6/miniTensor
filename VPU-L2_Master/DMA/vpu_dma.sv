`timescale 1ns/1ps

// Minimal single-outstanding-read DMA for contiguous 128-bit tiles.
// Source addresses are byte addresses; destination addresses are UB line
// indices. The external memory response is written directly into the UB.
module vpu_dma #(
  parameter int unsigned DATA_WIDTH = 128,
  parameter int unsigned UB_ADDR_WIDTH = 8,
  parameter int unsigned COUNT_WIDTH = 8
) (
  input  logic                         clk,
  input  logic                         rst,
  input  logic                         cmd_valid,
  output logic                         cmd_ready,
  input  logic [31:0]                  cmd_src_addr,
  input  logic [UB_ADDR_WIDTH-1:0]     cmd_dst_addr,
  input  logic [COUNT_WIDTH-1:0]       cmd_tile_count,
  output logic                         busy,
  output logic                         done,
  output logic                         mem_rd_valid,
  input  logic                         mem_rd_ready,
  output logic [31:0]                  mem_rd_addr,
  input  logic                         mem_rsp_valid,
  output logic                         mem_rsp_ready,
  input  logic [DATA_WIDTH-1:0]        mem_rsp_data,
  output logic                         ub_wr_en,
  output logic [UB_ADDR_WIDTH-1:0]     ub_wr_addr,
  output logic [DATA_WIDTH-1:0]        ub_wr_data,
  output logic [DATA_WIDTH/8-1:0]       ub_wr_be
);
  localparam int unsigned BYTE_COUNT = DATA_WIDTH / 8;

  typedef enum logic [1:0] {S_IDLE, S_REQUEST, S_RESPONSE} state_t;
  state_t state_q;
  logic [31:0] src_addr_q;
  logic [UB_ADDR_WIDTH-1:0] dst_addr_q;
  logic [COUNT_WIDTH-1:0] remaining_q;
  logic done_q;

  wire cmd_fire = cmd_valid && cmd_ready;
  wire mem_req_fire = mem_rd_valid && mem_rd_ready;
  wire mem_rsp_fire = mem_rsp_valid && mem_rsp_ready;

  initial begin
    if (DATA_WIDTH == 0 || DATA_WIDTH % 8 != 0)
      $fatal(1, "vpu_dma DATA_WIDTH must be a positive multiple of 8");
    if (COUNT_WIDTH == 0)
      $fatal(1, "vpu_dma COUNT_WIDTH must be positive");
  end

  assign cmd_ready = (state_q == S_IDLE) && (cmd_tile_count != '0);
  assign busy = (state_q != S_IDLE);
  assign done = done_q;

  assign mem_rd_valid = (state_q == S_REQUEST);
  assign mem_rd_addr = src_addr_q;
  assign mem_rsp_ready = (state_q == S_RESPONSE);

  assign ub_wr_en = mem_rsp_fire;
  assign ub_wr_addr = dst_addr_q;
  assign ub_wr_data = mem_rsp_data;
  assign ub_wr_be = {DATA_WIDTH/8{1'b1}};

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
      src_addr_q <= '0;
      dst_addr_q <= '0;
      remaining_q <= '0;
      done_q <= 1'b0;
    end else begin
      done_q <= 1'b0;
      case (state_q)
        S_IDLE: begin
          if (cmd_fire) begin
            src_addr_q <= cmd_src_addr;
            dst_addr_q <= cmd_dst_addr;
            remaining_q <= cmd_tile_count;
            state_q <= S_REQUEST;
          end
        end
        S_REQUEST: begin
          if (mem_req_fire)
            state_q <= S_RESPONSE;
        end
        S_RESPONSE: begin
          if (mem_rsp_fire) begin
            if (remaining_q == {{(COUNT_WIDTH-1){1'b0}}, 1'b1}) begin
              remaining_q <= '0;
              state_q <= S_IDLE;
              done_q <= 1'b1;
            end else begin
              src_addr_q <= src_addr_q + BYTE_COUNT;
              dst_addr_q <= dst_addr_q + 1'b1;
              remaining_q <= remaining_q - 1'b1;
              state_q <= S_REQUEST;
            end
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
