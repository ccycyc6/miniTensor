`timescale 1ns/1ps

// NPC-facing CV-X-IF adapter for the real vector controller.
// The NPC-facing register ports carry one packed vector value per operand.
module vpu_vector_npc_adapter #(
  parameter int unsigned X_ID_WIDTH = 4,
  parameter int unsigned X_RFR_WIDTH = 128,
  parameter int unsigned X_RFW_WIDTH = 128,
  parameter int unsigned X_HARTID_WIDTH = 1
) (
  input logic clk, input logic rst,
  input logic npc_issue_valid, output logic npc_issue_ready,
  input logic [31:0] npc_issue_instr,
  input logic [X_ID_WIDTH-1:0] npc_issue_id,
  input logic [X_HARTID_WIDTH-1:0] npc_issue_hartid,
  input logic [X_RFR_WIDTH-1:0] npc_issue_rs1,
  input logic [X_RFR_WIDTH-1:0] npc_issue_rs2,
  output logic npc_issue_accept,
  input logic npc_commit_valid,
  input logic [X_ID_WIDTH-1:0] npc_commit_id,
  input logic [X_HARTID_WIDTH-1:0] npc_commit_hartid,
  input logic npc_commit_kill,
  output logic npc_result_valid, input logic npc_result_ready,
  output logic [X_ID_WIDTH-1:0] npc_result_id,
  output logic [X_HARTID_WIDTH-1:0] npc_result_hartid,
  output logic [X_RFW_WIDTH-1:0] npc_result_data,
  output logic [4:0] npc_result_rd,
  output logic npc_result_we, output logic npc_result_exc,
  output logic [5:0] npc_result_exccode,
  output logic npc_result_dbg, output logic npc_result_err
);
  import vpu_pkg::*;
  core_v_xif #(
    .X_NUM_RS(2), .X_ID_WIDTH(X_ID_WIDTH), .X_RFR_WIDTH(X_RFR_WIDTH),
    .X_RFW_WIDTH(X_RFW_WIDTH), .X_HARTID_WIDTH(X_HARTID_WIDTH),
    .X_ISSUE_REGISTER_SPLIT(1)
  ) xif();

  logic reg_pending_q;
  logic [X_ID_WIDTH-1:0] reg_id_q;
  logic [X_HARTID_WIDTH-1:0] reg_hartid_q;
  logic [X_RFR_WIDTH-1:0] reg_rs1_q, reg_rs2_q;
  logic [31:0] instr_q;
  logic [X_ID_WIDTH-1:0] id_q;
  logic [X_HARTID_WIDTH-1:0] hartid_q;
  logic [4:0] vs1_q, vs2_q;
  logic committed_q, register_seen_q;
  logic [X_RFR_WIDTH-1:0] rs1_q, rs2_q;

  typedef enum logic [2:0] { S_IDLE, S_WAIT_INPUT, S_LOAD_RS1,
                             S_LOAD_RS2, S_SEND_VECTOR, S_WAIT_VECTOR,
                             S_RESULT } state_t;
  state_t state_q;
  logic vector_cmd_valid, vector_cmd_ready, vector_cmd_kill;
  logic [31:0] vector_cmd_instr;
  logic vector_result_valid, vector_result_ready;
  logic [X_ID_WIDTH-1:0] vector_result_id;
  logic [X_RFR_WIDTH-1:0] vector_result_data;
  logic [4:0] vector_result_vd;
  logic vector_load_valid, vector_load_ready;
  logic [4:0] vector_load_addr;
  logic [X_RFR_WIDTH-1:0] vector_load_data;
  logic [X_RFR_WIDTH/8-1:0] vector_load_be;

  assign xif.issue_valid = npc_issue_valid;
  assign xif.issue_req.instr = npc_issue_instr;
  assign xif.issue_req.id = npc_issue_id;
  assign xif.issue_req.hartid = npc_issue_hartid;
  assign xif.issue_req.mode = 2'b00;
  assign npc_issue_ready = xif.issue_ready;
  assign npc_issue_accept = xif.issue_resp.accept;

  assign xif.register_valid = reg_pending_q;
  assign xif.register.id = reg_id_q;
  assign xif.register.hartid = reg_hartid_q;
  assign xif.register.rs[0] = reg_rs1_q;
  assign xif.register.rs[1] = reg_rs2_q;
  assign xif.register.rs_valid = 2'b11;

  assign xif.commit_valid = npc_commit_valid;
  assign xif.commit.id = npc_commit_id;
  assign xif.commit.hartid = npc_commit_hartid;
  assign xif.commit.commit_kill = npc_commit_kill;

  assign xif.result_ready = npc_result_ready;
  assign npc_result_valid = xif.result_valid;
  assign npc_result_id = xif.result.id;
  assign npc_result_hartid = xif.result.hartid;
  assign npc_result_data = xif.result.data;
  assign npc_result_rd = xif.result.rd;
  assign npc_result_we = xif.result.we[0];
  assign npc_result_exc = xif.result.exc;
  assign npc_result_exccode = xif.result.exccode;
  assign npc_result_dbg = xif.result.dbg;
  assign npc_result_err = xif.result.err;

  assign xif.compressed_valid = 1'b0;
  assign xif.mem_ready = 1'b1;
  assign xif.mem_result_valid = 1'b0;

  assign xif.issue_ready = (state_q == S_IDLE);
  assign xif.issue_resp = '0;
  assign xif.issue_resp.accept = is_vector_instruction(npc_issue_instr);
  assign xif.issue_resp.writeback[0] = is_vector_instruction(npc_issue_instr);
  assign xif.issue_resp.register_read = is_vector_instruction(npc_issue_instr) ?
      ((npc_issue_instr[14:12] == VPU_VECTOR_FUNCT3_RELU8) ? 2'b01 : 2'b11) : 2'b00;
  assign xif.register_ready = (state_q == S_WAIT_INPUT) && !register_seen_q;
  assign xif.result_valid = (state_q == S_RESULT);
  always_comb begin
    xif.result = '0;
    xif.result.hartid = hartid_q;
    xif.result.id = vector_result_id;
    xif.result.data = vector_result_data;
    xif.result.rd = vector_result_vd;
    xif.result.we[0] = 1'b1;
  end
  assign xif.compressed_ready = 1'b1;
  assign xif.compressed_resp = '0;
  assign xif.mem_valid = 1'b0;
  assign xif.mem_req = '0;

  assign vector_cmd_valid = (state_q == S_SEND_VECTOR);
  assign vector_cmd_instr = instr_q;
  assign vector_result_ready = (state_q == S_WAIT_VECTOR) && !vector_cmd_kill;
  assign vector_load_valid = (state_q == S_LOAD_RS1) || (state_q == S_LOAD_RS2);
  assign vector_load_addr = (state_q == S_LOAD_RS1) ? vs1_q : vs2_q;
  assign vector_load_data = (state_q == S_LOAD_RS1) ? rs1_q : rs2_q;
  assign vector_load_be = '1;

  vpu_vector_controller #(
    .NUM_REGS(32), .VLEN(X_RFR_WIDTH), .ADDR_WIDTH(5)
  ) u_vector_controller (
    .clk, .rst,
    .cmd_valid(vector_cmd_valid), .cmd_ready(vector_cmd_ready),
    .cmd_instr(vector_cmd_instr), .cmd_id(id_q), .cmd_kill(vector_cmd_kill),
    .result_valid(vector_result_valid), .result_ready(vector_result_ready),
    .result_id(vector_result_id), .result_data(vector_result_data),
    .result_vd(vector_result_vd),
    .load_valid(vector_load_valid), .load_ready(vector_load_ready),
    .load_addr(vector_load_addr[4:0]), .load_data(vector_load_data),
    .load_be(vector_load_be)
  );

  wire issue_fire = npc_issue_valid && npc_issue_ready && npc_issue_accept;
  wire register_fire = xif.register_valid && xif.register_ready;

  wire commit_match = npc_commit_valid && (npc_commit_id == id_q) &&
                       (npc_commit_hartid == hartid_q);
  assign vector_cmd_kill = commit_match && npc_commit_kill;

  always_ff @(posedge clk) begin
    if (rst) begin
      reg_pending_q <= 1'b0;
      reg_id_q <= '0;
      reg_hartid_q <= '0;
      reg_rs1_q <= '0;
      reg_rs2_q <= '0;
      state_q <= S_IDLE;
      instr_q <= '0;
      id_q <= '0;
      hartid_q <= '0;
      vs1_q <= '0;
      vs2_q <= '0;
      committed_q <= 1'b0;
      register_seen_q <= 1'b0;
      rs1_q <= '0;
      rs2_q <= '0;
    end else begin
      if (issue_fire) begin
        reg_pending_q <= 1'b1;
        reg_id_q <= npc_issue_id;
        reg_hartid_q <= npc_issue_hartid;
        reg_rs1_q <= npc_issue_rs1;
        reg_rs2_q <= npc_issue_rs2;
        instr_q <= npc_issue_instr;
        id_q <= npc_issue_id;
        hartid_q <= npc_issue_hartid;
        vs1_q <= npc_issue_instr[19:15];
        vs2_q <= npc_issue_instr[24:20];
        committed_q <= 1'b0;
        register_seen_q <= 1'b0;
        state_q <= S_WAIT_INPUT;
      end else if (register_fire) begin
        reg_pending_q <= 1'b0;
        rs1_q <= xif.register.rs[0];
        rs2_q <= xif.register.rs[1];
        register_seen_q <= 1'b1;
      end

      if (commit_match && !npc_commit_kill)
        committed_q <= 1'b1;

      if ((state_q == S_WAIT_INPUT) && register_seen_q && committed_q)
        state_q <= S_LOAD_RS1;
      else if ((state_q == S_LOAD_RS1) && vector_load_ready)
        state_q <= S_LOAD_RS2;
      else if ((state_q == S_LOAD_RS2) && vector_load_ready)
        state_q <= S_SEND_VECTOR;
      else if ((state_q == S_SEND_VECTOR) && vector_cmd_kill)
        state_q <= S_IDLE;
      else if ((state_q == S_SEND_VECTOR) && vector_cmd_ready)
        state_q <= S_WAIT_VECTOR;
      else if ((state_q == S_WAIT_VECTOR) && vector_cmd_kill)
        state_q <= S_IDLE;
      else if ((state_q == S_WAIT_VECTOR) && vector_result_valid)
        state_q <= S_RESULT;
      else if ((state_q == S_RESULT) && npc_result_ready)
        state_q <= S_IDLE;
      else if (commit_match && npc_commit_kill)
        state_q <= S_IDLE;

      if (commit_match && npc_commit_kill)
        reg_pending_q <= 1'b0;
    end
  end
endmodule
