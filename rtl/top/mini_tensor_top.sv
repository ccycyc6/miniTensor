`timescale 1ns/1ps

// Unified, single-clock miniTensor top.
// One committed command at a time controls DMA load/store or a vector
// operation whose operands and result reside in the Unified Buffer.
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

  output logic mem_wr_valid,
  input  logic mem_wr_ready,
  output logic [31:0] mem_wr_addr,
  output logic [DATA_WIDTH-1:0] mem_wr_data,
  output logic [DATA_WIDTH/8-1:0] mem_wr_be,

  // Read-only debug port. Future compute blocks can replace this external
  // owner without changing the DMA/UB boundary.
  input  logic ub_rd_en,
  input  logic [UB_ADDR_WIDTH-1:0] ub_rd_addr,
  output logic ub_rd_valid,
  output logic [DATA_WIDTH-1:0] ub_rd_data,
  output logic dma_busy
);
  import minitensor_pkg::*;
  import vpu_pkg::*;

  typedef enum logic [1:0] {OP_LOAD, OP_STORE, OP_VECTOR} op_t;
  typedef enum logic [3:0] {
    S_IDLE,
    S_WAIT_COMMIT,
    S_DMA_START,
    S_DMA_WAIT,
    S_VEC_READ_A,
    S_VEC_LOAD_A,
    S_VEC_READ_B,
    S_VEC_LOAD_B,
    S_VEC_COMMAND,
    S_VEC_WAIT,
    S_RESULT
  } state_t;

  state_t state_q;
  op_t op_q;
  logic [X_ID_WIDTH-1:0] id_q;
  logic [X_HARTID_WIDTH-1:0] hartid_q;
  logic [4:0] rd_q;
  logic [31:0] mem_addr_q;
  logic [UB_ADDR_WIDTH-1:0] ub_base_q;
  logic [COUNT_WIDTH-1:0] tile_count_q;
  logic [UB_ADDR_WIDTH-1:0] vec_src_a_q, vec_src_b_q, vec_dst_q;
  logic [2:0] vec_funct3_q;

  logic dma_cmd_valid, dma_cmd_ready, dma_cmd_write, dma_done;
  logic dma_ub_wr_en, dma_ub_rd_en;
  logic [UB_ADDR_WIDTH-1:0] dma_ub_wr_addr, dma_ub_rd_addr;
  logic [DATA_WIDTH-1:0] dma_ub_wr_data;
  logic [DATA_WIDTH/8-1:0] dma_ub_wr_be;

  logic vector_cmd_valid, vector_cmd_ready;
  logic [31:0] vector_cmd_instr;
  logic vector_result_valid, vector_result_ready;
  logic [3:0] vector_result_id;
  logic [DATA_WIDTH-1:0] vector_result_data;
  logic [4:0] vector_result_vd;
  logic vector_load_valid, vector_load_ready;
  logic [4:0] vector_load_addr;

  logic ub_mem_wr_en, ub_mem_rd_en, ub_mem_rd_valid;
  logic [UB_ADDR_WIDTH-1:0] ub_mem_wr_addr, ub_mem_rd_addr;
  logic [DATA_WIDTH-1:0] ub_mem_wr_data, ub_mem_rd_data;
  logic [DATA_WIDTH/8-1:0] ub_mem_wr_be;

  wire load_instr = is_minitensor_load(npc_issue_instr);
  wire store_instr = is_minitensor_store(npc_issue_instr);
  wire vector_instr = is_vector_instruction(npc_issue_instr);
  wire count_valid = (npc_issue_rs2[15:8] != 8'h00);
  wire [8:0] ub_end = {1'b0, npc_issue_rs2[7:0]} +
      {1'b0, npc_issue_rs2[15:8]};
  wire dma_operands_valid = (npc_issue_rs2[31:16] == 16'h0000) &&
      (npc_issue_rs1[3:0] == 4'h0) && count_valid &&
      (ub_end <= 9'(UB_DEPTH));
  wire vector_operands_valid = (npc_issue_rs1[31:16] == 16'h0000) &&
      (npc_issue_rs2[31:8] == 24'h000000) &&
      ({1'b0, npc_issue_rs1[7:0]} < 9'(UB_DEPTH)) &&
      ({1'b0, npc_issue_rs1[15:8]} < 9'(UB_DEPTH)) &&
      ({1'b0, npc_issue_rs2[7:0]} < 9'(UB_DEPTH));
  wire issue_supported = ((load_instr || store_instr) && dma_operands_valid) ||
      (vector_instr && vector_operands_valid);
  wire issue_fire = npc_issue_valid && npc_issue_ready && npc_issue_accept;
  wire commit_match = npc_commit_valid && (npc_commit_id == id_q) &&
      (npc_commit_hartid == hartid_q);
  wire commit_fire = commit_match && !npc_commit_kill;
  wire kill_fire = commit_match && npc_commit_kill;
  wire vector_result_match = (vector_result_id == id_q) &&
      (vector_result_vd == 5'd3);
  wire vector_result_fire = vector_result_valid && vector_result_ready;

  initial begin
    if (DATA_WIDTH != 128)
      $fatal(1, "mini_tensor_top currently requires DATA_WIDTH=128");
    if (X_ID_WIDTH != 4)
      $fatal(1, "mini_tensor_top currently requires X_ID_WIDTH=4");
  end

  assign npc_issue_ready = (state_q == S_IDLE);
  assign npc_issue_accept = issue_supported;

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
  assign dma_cmd_write = (op_q == OP_STORE);

  vpu_dma #(
    .DATA_WIDTH(DATA_WIDTH),
    .UB_ADDR_WIDTH(UB_ADDR_WIDTH),
    .COUNT_WIDTH(COUNT_WIDTH)
  ) u_dma (
    .clk,
    .rst,
    .cmd_valid(dma_cmd_valid),
    .cmd_ready(dma_cmd_ready),
    .cmd_write(dma_cmd_write),
    .cmd_mem_addr(mem_addr_q),
    .cmd_ub_addr(ub_base_q),
    .cmd_tile_count(tile_count_q),
    .busy(dma_busy),
    .done(dma_done),
    .mem_rd_valid,
    .mem_rd_ready,
    .mem_rd_addr,
    .mem_rsp_valid,
    .mem_rsp_ready,
    .mem_rsp_data,
    .mem_wr_valid,
    .mem_wr_ready,
    .mem_wr_addr,
    .mem_wr_data,
    .mem_wr_be,
    .ub_wr_en(dma_ub_wr_en),
    .ub_wr_addr(dma_ub_wr_addr),
    .ub_wr_data(dma_ub_wr_data),
    .ub_wr_be(dma_ub_wr_be),
    .ub_rd_en(dma_ub_rd_en),
    .ub_rd_addr(dma_ub_rd_addr),
    .ub_rd_valid(ub_mem_rd_valid),
    .ub_rd_data(ub_mem_rd_data)
  );

  assign vector_load_valid =
      ((state_q == S_VEC_LOAD_A) || (state_q == S_VEC_LOAD_B)) &&
      ub_mem_rd_valid;
  assign vector_load_addr = (state_q == S_VEC_LOAD_A) ? 5'd1 : 5'd2;
  assign vector_cmd_valid = (state_q == S_VEC_COMMAND);
  assign vector_cmd_instr = make_vector_rtype(vec_funct3_q, 5'd3, 5'd1, 5'd2);
  assign vector_result_ready = (state_q == S_VEC_WAIT) && vector_result_match;

  vpu_vector_controller #(
    .NUM_REGS(32), .VLEN(DATA_WIDTH), .ADDR_WIDTH(5)
  ) u_vector_controller (
    .clk,
    .rst,
    .cmd_valid(vector_cmd_valid),
    .cmd_ready(vector_cmd_ready),
    .cmd_instr(vector_cmd_instr),
    .cmd_id(id_q),
    .cmd_kill(1'b0),
    .result_valid(vector_result_valid),
    .result_ready(vector_result_ready),
    .result_id(vector_result_id),
    .result_data(vector_result_data),
    .result_vd(vector_result_vd),
    .load_valid(vector_load_valid),
    .load_ready(vector_load_ready),
    .load_addr(vector_load_addr),
    .load_data(ub_mem_rd_data),
    .load_be('1)
  );

  // The command FSM guarantees these owners are mutually exclusive.
  always_comb begin
    ub_mem_rd_en = 1'b0;
    ub_mem_rd_addr = '0;
    if (dma_ub_rd_en) begin
      ub_mem_rd_en = 1'b1;
      ub_mem_rd_addr = dma_ub_rd_addr;
    end else if (state_q == S_VEC_READ_A) begin
      ub_mem_rd_en = 1'b1;
      ub_mem_rd_addr = vec_src_a_q;
    end else if (state_q == S_VEC_READ_B) begin
      ub_mem_rd_en = 1'b1;
      ub_mem_rd_addr = vec_src_b_q;
    end else if (ub_rd_en) begin
      ub_mem_rd_en = 1'b1;
      ub_mem_rd_addr = ub_rd_addr;
    end
  end

  always_comb begin
    ub_mem_wr_en = dma_ub_wr_en;
    ub_mem_wr_addr = dma_ub_wr_addr;
    ub_mem_wr_data = dma_ub_wr_data;
    ub_mem_wr_be = dma_ub_wr_be;
    if (vector_result_fire) begin
      ub_mem_wr_en = 1'b1;
      ub_mem_wr_addr = vec_dst_q;
      ub_mem_wr_data = vector_result_data;
      ub_mem_wr_be = '1;
    end
  end

  unified_buffer #(
    .DATA_WIDTH(DATA_WIDTH),
    .DEPTH(UB_DEPTH),
    .ADDR_WIDTH(UB_ADDR_WIDTH)
  ) u_unified_buffer (
    .clk,
    .rst,
    .wr_en(ub_mem_wr_en),
    .wr_addr(ub_mem_wr_addr),
    .wr_data(ub_mem_wr_data),
    .wr_be(ub_mem_wr_be),
    .rd_en(ub_mem_rd_en),
    .rd_addr(ub_mem_rd_addr),
    .rd_valid(ub_mem_rd_valid),
    .rd_data(ub_mem_rd_data)
  );

  assign ub_rd_valid = ub_mem_rd_valid;
  assign ub_rd_data = ub_mem_rd_data;

  always_ff @(posedge clk) begin
    if (rst) begin
      state_q <= S_IDLE;
      op_q <= OP_LOAD;
      id_q <= '0;
      hartid_q <= '0;
      rd_q <= '0;
      mem_addr_q <= '0;
      ub_base_q <= '0;
      tile_count_q <= '0;
      vec_src_a_q <= '0;
      vec_src_b_q <= '0;
      vec_dst_q <= '0;
      vec_funct3_q <= '0;
    end else begin
      case (state_q)
        S_IDLE: begin
          if (issue_fire) begin
            id_q <= npc_issue_id;
            hartid_q <= npc_issue_hartid;
            rd_q <= npc_issue_instr[11:7];
            if (load_instr || store_instr) begin
              op_q <= load_instr ? OP_LOAD : OP_STORE;
              mem_addr_q <= npc_issue_rs1;
              ub_base_q <= npc_issue_rs2[UB_ADDR_WIDTH-1:0];
              tile_count_q <= npc_issue_rs2[15:8];
            end else begin
              op_q <= OP_VECTOR;
              vec_src_a_q <= npc_issue_rs1[UB_ADDR_WIDTH-1:0];
              vec_src_b_q <= npc_issue_rs1[8 +: UB_ADDR_WIDTH];
              vec_dst_q <= npc_issue_rs2[UB_ADDR_WIDTH-1:0];
              vec_funct3_q <= npc_issue_instr[14:12];
            end
            state_q <= S_WAIT_COMMIT;
          end
        end
        S_WAIT_COMMIT: begin
          if (kill_fire)
            state_q <= S_IDLE;
          else if (commit_fire)
            state_q <= (op_q == OP_VECTOR) ? S_VEC_READ_A : S_DMA_START;
        end
        S_DMA_START: begin
          if (dma_cmd_valid && dma_cmd_ready)
            state_q <= S_DMA_WAIT;
        end
        S_DMA_WAIT: begin
          if (dma_done)
            state_q <= S_RESULT;
        end
        S_VEC_READ_A: state_q <= S_VEC_LOAD_A;
        S_VEC_LOAD_A: begin
          if (vector_load_valid && vector_load_ready)
            state_q <= S_VEC_READ_B;
        end
        S_VEC_READ_B: state_q <= S_VEC_LOAD_B;
        S_VEC_LOAD_B: begin
          if (vector_load_valid && vector_load_ready)
            state_q <= S_VEC_COMMAND;
        end
        S_VEC_COMMAND: begin
          if (vector_cmd_valid && vector_cmd_ready)
            state_q <= S_VEC_WAIT;
        end
        S_VEC_WAIT: begin
          if (vector_result_fire)
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
