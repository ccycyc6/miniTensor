`timescale 1ns/1ps

// First integrated miniTensor command: MT_LOAD.
//
// The flattened CPU-facing ports are the signals that an NPC/Chisel wrapper
// connects to the CV-X-IF adapter.  This top deliberately keeps one command
// in flight and starts DMA only after a matching, non-kill commit.
module mini_tensor_top #(
  parameter int unsigned X_ID_WIDTH = 4,
  parameter int unsigned X_HARTID_WIDTH = 1,
  parameter int unsigned DATA_WIDTH = 128,
  parameter int unsigned UB_DEPTH = 256,
  parameter int unsigned UB_ADDR_WIDTH = $clog2(UB_DEPTH),
  parameter int unsigned COUNT_WIDTH = 8
) (
  input  logic clk,
  input  logic rst,

  input  logic npc_issue_valid,
  output logic npc_issue_ready,
  input  logic [31:0] npc_issue_instr,
  input  logic [X_ID_WIDTH-1:0] npc_issue_id,
  input  logic [X_HARTID_WIDTH-1:0] npc_issue_hartid,
  input  logic [31:0] npc_issue_rs1,
  input  logic [31:0] npc_issue_rs2,
  output logic npc_issue_accept,

  input  logic npc_commit_valid,
  input  logic [X_ID_WIDTH-1:0] npc_commit_id,
  input  logic [X_HARTID_WIDTH-1:0] npc_commit_hartid,
  input  logic npc_commit_kill,

  output logic npc_result_valid,
  input  logic npc_result_ready,
  output logic [X_ID_WIDTH-1:0] npc_result_id,
  output logic [X_HARTID_WIDTH-1:0] npc_result_hartid,
  output logic [31:0] npc_result_data,
  output logic [4:0] npc_result_rd,
  output logic npc_result_we,
  output logic npc_result_exc,
  output logic [5:0] npc_result_exccode,
  output logic npc_result_dbg,
  output logic npc_result_err,

  output logic mem_rd_valid,
  input  logic mem_rd_ready,
  output logic [31:0] mem_rd_addr,
  input  logic mem_rsp_valid,
  output logic mem_rsp_ready,
  input  logic [DATA_WIDTH-1:0] mem_rsp_data,

  // Temporary integration read port used by the testbench and future
  // compute-unit owner.  It does not bypass the DMA write path.
  input  logic ub_rd_en,
  input  logic [UB_ADDR_WIDTH-1:0] ub_rd_addr,
  output logic ub_rd_valid,
  output logic [DATA_WIDTH-1:0] ub_rd_data,
  output logic dma_busy
);
  import minitensor_pkg::*;

  typedef enum logic [2:0] {
    S_IDLE,
    S_WAIT_COMMIT,
    S_DMA_START,
    S_DMA_WAIT,
    S_RESULT
  } state_t;

  state_t state_q;
  logic [X_ID_WIDTH-1:0] id_q;
  logic [X_HARTID_WIDTH-1:0] hartid_q;
  logic [4:0] rd_q;
  logic [31:0] src_addr_q;
  logic [UB_ADDR_WIDTH-1:0] dst_addr_q;
  logic [COUNT_WIDTH-1:0] tile_count_q;

  logic dma_cmd_valid, dma_cmd_ready, dma_done;
  logic dma_ub_wr_en;
  logic [UB_ADDR_WIDTH-1:0] dma_ub_wr_addr;
  logic [DATA_WIDTH-1:0] dma_ub_wr_data;
  logic [DATA_WIDTH/8-1:0] dma_ub_wr_be;

  wire supported = is_minitensor_load(npc_issue_instr);
  wire count_valid = (npc_issue_rs2[15:8] != 8'h00);
  wire [8:0] ub_end = {1'b0, npc_issue_rs2[7:0]} +
      {1'b0, npc_issue_rs2[15:8]};
  wire ub_range_valid = (ub_end <= 9'(UB_DEPTH));
  wire operands_valid = (npc_issue_rs2[31:16] == 16'h0000) &&
      (npc_issue_rs1[3:0] == 4'h0) && ub_range_valid;
  wire issue_fire = npc_issue_valid && npc_issue_ready && npc_issue_accept;
  wire commit_match = npc_commit_valid &&
      (npc_commit_id == id_q) && (npc_commit_hartid == hartid_q);
  wire commit_fire = commit_match && !npc_commit_kill;
  wire kill_fire = commit_match && npc_commit_kill;

  assign npc_issue_ready = (state_q == S_IDLE);
  assign npc_issue_accept = supported && count_valid && operands_valid;

  assign npc_result_valid = (state_q == S_RESULT);
  assign npc_result_id = id_q;
  assign npc_result_hartid = hartid_q;
  assign npc_result_data = 32'h0000_0000;
  assign npc_result_rd = rd_q;
  assign npc_result_we = 1'b1;
  assign npc_result_exc = 1'b0;
  assign npc_result_exccode = 6'h00;
  assign npc_result_dbg = 1'b0;
  assign npc_result_err = 1'b0;

  assign dma_cmd_valid = (state_q == S_DMA_START);

  vpu_dma #(
    .DATA_WIDTH(DATA_WIDTH),
    .UB_ADDR_WIDTH(UB_ADDR_WIDTH),
    .COUNT_WIDTH(COUNT_WIDTH)
  ) u_dma (
    .clk,
    .rst,
    .cmd_valid(dma_cmd_valid),
    .cmd_ready(dma_cmd_ready),
    .cmd_src_addr(src_addr_q),
    .cmd_dst_addr(dst_addr_q),
    .cmd_tile_count(tile_count_q),
    .busy(dma_busy),
    .done(dma_done),
    .mem_rd_valid,
    .mem_rd_ready,
    .mem_rd_addr,
    .mem_rsp_valid,
    .mem_rsp_ready,
    .mem_rsp_data,
    .ub_wr_en(dma_ub_wr_en),
    .ub_wr_addr(dma_ub_wr_addr),
    .ub_wr_data(dma_ub_wr_data),
    .ub_wr_be(dma_ub_wr_be)
  );

  unified_buffer #(
    .DATA_WIDTH(DATA_WIDTH),
    .DEPTH(UB_DEPTH),
    .ADDR_WIDTH(UB_ADDR_WIDTH)
  ) u_unified_buffer (
    .clk,
    .rst,
    .wr_en(dma_ub_wr_en),
    .wr_addr(dma_ub_wr_addr),
    .wr_data(dma_ub_wr_data),
    .wr_be(dma_ub_wr_be),
    .rd_en(ub_rd_en),
    .rd_addr(ub_rd_addr),
    .rd_valid(ub_rd_valid),
    .rd_data(ub_rd_data)
  );

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
      id_q <= '0;
      hartid_q <= '0;
      rd_q <= '0;
      src_addr_q <= '0;
      dst_addr_q <= '0;
      tile_count_q <= '0;
    end else begin
      case (state_q)
        S_IDLE: begin
          if (issue_fire) begin
            id_q <= npc_issue_id;
            hartid_q <= npc_issue_hartid;
            rd_q <= npc_issue_instr[11:7];
            src_addr_q <= npc_issue_rs1;
            dst_addr_q <= npc_issue_rs2[UB_ADDR_WIDTH-1:0];
            tile_count_q <= npc_issue_rs2[15:8];
            state_q <= S_WAIT_COMMIT;
          end
        end
        S_WAIT_COMMIT: begin
          if (kill_fire)
            state_q <= S_IDLE;
          else if (commit_fire)
            state_q <= S_DMA_START;
        end
        S_DMA_START: begin
          if (dma_cmd_valid && dma_cmd_ready)
            state_q <= S_DMA_WAIT;
        end
        S_DMA_WAIT: begin
          if (dma_done)
            state_q <= S_RESULT;
        end
        S_RESULT: begin
          if (npc_result_valid && npc_result_ready)
            state_q <= S_IDLE;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
