`timescale 1ns/1ps

module tb_vpu_npc_model;
  import vpu_pkg::*;
  logic clk = 0, rst = 1;
  always #5 clk = ~clk;
  logic issue_valid, issue_ready, issue_accept;
  logic [31:0] issue_instr, issue_rs1, issue_rs2;
  logic [3:0] issue_id, commit_id, result_id;
  logic commit_valid, commit_kill, result_valid, result_ready;
  logic [31:0] result_data;
  logic [4:0] result_rd;
  logic result_we, result_exc, result_dbg, result_err, result_hartid;
  logic [5:0] result_exccode;

  vpu_npc_model dut (
    .clk, .rst,
    .npc_issue_valid(issue_valid), .npc_issue_ready(issue_ready),
    .npc_issue_instr(issue_instr), .npc_issue_id(issue_id),
    .npc_issue_hartid(1'b0), .npc_issue_rs1(issue_rs1), .npc_issue_rs2(issue_rs2),
    .npc_issue_accept(issue_accept), .npc_commit_valid(commit_valid),
    .npc_commit_id(commit_id), .npc_commit_hartid(1'b0), .npc_commit_kill(commit_kill),
    .npc_result_valid(result_valid), .npc_result_ready(result_ready),
    .npc_result_id(result_id), .npc_result_hartid(result_hartid),
    .npc_result_data(result_data), .npc_result_rd(result_rd), .npc_result_we(result_we),
    .npc_result_exc(result_exc), .npc_result_exccode(result_exccode),
    .npc_result_dbg(result_dbg), .npc_result_err(result_err)
  );

  initial begin
    issue_valid = 0; issue_instr = 0; issue_id = 0; issue_rs1 = 17; issue_rs2 = 25;
    commit_valid = 0; commit_id = 0; commit_kill = 0; result_ready = 0;
    repeat (2) @(posedge clk); rst = 0;
    @(negedge clk);
    issue_instr = make_vpu_rtype(VPU_FUNCT3_ADD, 5'd3, 5'd1, 5'd2);
    issue_id = 0; issue_valid = 1;
    while (!issue_ready) @(negedge clk);
    #1;
    if (!issue_accept) $fatal(1, "VADD was not accepted");
    @(posedge clk); @(negedge clk); issue_valid = 0;
    repeat (4) @(negedge clk);
    commit_valid = 1; commit_id = 0;
    @(posedge clk); @(negedge clk); commit_valid = 0; result_ready = 1;
    while (!result_valid) @(negedge clk);
    #1;
    if (result_data !== 42 || result_rd !== 3 || result_id !== 0 || !result_we ||
        result_exc || result_exccode !== 0 || result_dbg || result_err)
      $fatal(1, "NPC model result mismatch");
    @(posedge clk);
    $display("PASS: NPC-facing VPU model completed VADD 17 + 25 = 42");
    $finish;
  end
endmodule
