`timescale 1ns/1ps

// Standalone NPC-facing adapter. It models the timing of an in-order core
// with synchronous GPR reads, while keeping the VPU implementation on CV-X-IF.
module vpu_npc_model #(
  parameter int unsigned X_ID_WIDTH = 4,
  parameter int unsigned X_RFR_WIDTH = 32,
  parameter int unsigned X_RFW_WIDTH = 32,
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
  core_v_xif #(
    .X_NUM_RS(2), .X_ID_WIDTH(X_ID_WIDTH), .X_RFR_WIDTH(X_RFR_WIDTH),
    .X_RFW_WIDTH(X_RFW_WIDTH), .X_HARTID_WIDTH(X_HARTID_WIDTH),
    .X_ISSUE_REGISTER_SPLIT(1)
  ) xif();

  logic reg_pending_q;
  logic [X_ID_WIDTH-1:0] reg_id_q;
  logic [X_HARTID_WIDTH-1:0] reg_hartid_q;
  logic [X_RFR_WIDTH-1:0] reg_rs1_q, reg_rs2_q;

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

  vpu_basic #(
    .X_ID_WIDTH(X_ID_WIDTH), .X_RFR_WIDTH(X_RFR_WIDTH),
    .X_RFW_WIDTH(X_RFW_WIDTH), .X_HARTID_WIDTH(X_HARTID_WIDTH)
  ) u_vpu (.clk(clk), .rst(rst), .xif(xif));

  wire issue_fire = npc_issue_valid && npc_issue_ready && npc_issue_accept;
  wire register_fire = xif.register_valid && xif.register_ready;

  always_ff @(posedge clk) begin
    if (rst) begin
      reg_pending_q <= 1'b0;
      reg_id_q <= '0;
      reg_hartid_q <= '0;
      reg_rs1_q <= '0;
      reg_rs2_q <= '0;
    end else if (issue_fire) begin
      reg_pending_q <= 1'b1;
      reg_id_q <= npc_issue_id;
      reg_hartid_q <= npc_issue_hartid;
      reg_rs1_q <= npc_issue_rs1;
      reg_rs2_q <= npc_issue_rs2;
    end else if (register_fire) begin
      reg_pending_q <= 1'b0;
    end
  end
endmodule
