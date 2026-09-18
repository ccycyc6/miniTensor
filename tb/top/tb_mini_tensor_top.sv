`timescale 1ns/1ps

module tb_mini_tensor_top;
  import minitensor_pkg::*;
  import vpu_pkg::*;

  localparam int unsigned DATA_WIDTH = 128;
  localparam logic [DATA_WIDTH-1:0] INPUT_A =
      128'h7f05ff80_7d03fd80_7c02fc80_7b01fb80;
  localparam logic [DATA_WIDTH-1:0] INPUT_B =
      128'h01010101_01010101_01010101_01010101;
  localparam logic [DATA_WIDTH-1:0] EXPECTED_ADD =
      128'h80060081_7e04fe81_7d03fd81_7c02fc81;

  logic clk, rst;
  always #5 clk = ~clk;

  logic issue_valid, issue_ready, issue_accept;
  logic [31:0] issue_instr, issue_rs1, issue_rs2;
  logic [3:0] issue_id;
  logic commit_valid, commit_kill;
  logic [3:0] commit_id;
  logic result_valid, result_ready;
  logic [3:0] result_id;
  logic result_hartid;
  logic [31:0] result_data;
  logic [4:0] result_rd;
  logic result_we, result_exc, result_dbg, result_err;
  logic [5:0] result_exccode;

  logic mem_rd_valid, mem_rd_ready, mem_rsp_valid, mem_rsp_ready;
  logic [31:0] mem_rd_addr;
  logic [DATA_WIDTH-1:0] mem_rsp_data;
  logic mem_wr_valid, mem_wr_ready;
  logic [31:0] mem_wr_addr;
  logic [DATA_WIDTH-1:0] mem_wr_data;
  logic [DATA_WIDTH/8-1:0] mem_wr_be;

  logic ub_rd_en, ub_rd_valid;
  logic [7:0] ub_rd_addr;
  logic [DATA_WIDTH-1:0] ub_rd_data;
  logic dma_busy;

  logic [DATA_WIDTH-1:0] source_mem [0:1];
  logic [DATA_WIDTH-1:0] stored_result;
  logic mem_pending;
  logic [DATA_WIDTH-1:0] pending_data;
  integer read_count, response_count, write_count;

  mini_tensor_top dut (
    .clk, .rst,
    .npc_issue_valid(issue_valid), .npc_issue_ready(issue_ready),
    .npc_issue_instr(issue_instr), .npc_issue_id(issue_id),
    .npc_issue_hartid(1'b0), .npc_issue_rs1(issue_rs1), .npc_issue_rs2(issue_rs2),
    .npc_issue_accept(issue_accept),
    .npc_commit_valid(commit_valid), .npc_commit_id(commit_id),
    .npc_commit_hartid(1'b0), .npc_commit_kill(commit_kill),
    .npc_result_valid(result_valid), .npc_result_ready(result_ready),
    .npc_result_id(result_id), .npc_result_hartid(result_hartid),
    .npc_result_data(result_data), .npc_result_rd(result_rd),
    .npc_result_we(result_we), .npc_result_exc(result_exc),
    .npc_result_exccode(result_exccode), .npc_result_dbg(result_dbg),
    .npc_result_err(result_err),
    .mem_rd_valid, .mem_rd_ready, .mem_rd_addr,
    .mem_rsp_valid, .mem_rsp_ready, .mem_rsp_data,
    .mem_wr_valid, .mem_wr_ready, .mem_wr_addr, .mem_wr_data, .mem_wr_be,
    .ub_rd_en, .ub_rd_addr, .ub_rd_valid, .ub_rd_data, .dma_busy
  );

  assign mem_rd_ready = 1'b1;
  assign mem_wr_ready = 1'b1;

  always_ff @(posedge clk) begin
    if (rst) begin
      mem_rsp_valid <= 1'b0;
      mem_rsp_data <= '0;
      mem_pending <= 1'b0;
      pending_data <= '0;
      stored_result <= '0;
      read_count <= 0;
      response_count <= 0;
      write_count <= 0;
    end else begin
      mem_rsp_valid <= mem_pending;
      mem_rsp_data <= pending_data;
      mem_pending <= 1'b0;
      if (mem_rd_valid && mem_rd_ready) begin
        if (mem_rd_addr >= 32)
          $fatal(1, "unexpected memory read address %h", mem_rd_addr);
        pending_data <= source_mem[mem_rd_addr[4]];
        mem_pending <= 1'b1;
        read_count <= read_count + 1;
      end
      if (mem_rsp_valid && mem_rsp_ready)
        response_count <= response_count + 1;
      if (mem_wr_valid && mem_wr_ready) begin
        if (mem_wr_addr != 32'h0000_0100 || mem_wr_be !== '1)
          $fatal(1, "unexpected memory write transaction");
        stored_result <= mem_wr_data;
        write_count <= write_count + 1;
      end
    end
  end

  task automatic issue_command(
      input logic [31:0] instr,
      input logic [31:0] rs1,
      input logic [31:0] rs2,
      input logic [3:0] id);
    begin
      @(negedge clk);
      issue_instr = instr;
      issue_rs1 = rs1;
      issue_rs2 = rs2;
      issue_id = id;
      issue_valid = 1'b1;
      while (!issue_ready) @(negedge clk);
      #1;
      if (!issue_accept) $fatal(1, "command was not accepted: %h", instr);
      @(posedge clk);
      @(negedge clk);
      issue_valid = 1'b0;
    end
  endtask

  task automatic commit_command(input logic [3:0] id, input logic kill);
    begin
      @(negedge clk);
      commit_id = id;
      commit_kill = kill;
      commit_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      commit_valid = 1'b0;
      commit_kill = 1'b0;
    end
  endtask

  task automatic accept_result(input logic [3:0] id, input logic [4:0] rd);
    begin
      while (!result_valid) @(negedge clk);
      repeat (2) begin
        #1;
        if (!result_valid || result_id !== id || result_rd !== rd ||
            result_hartid !== 1'b0 || result_data !== 0 || !result_we ||
            result_exc || result_exccode !== 0 || result_dbg || result_err)
          $fatal(1, "result changed under backpressure");
        @(negedge clk);
      end
      result_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      result_ready = 1'b0;
    end
  endtask

  task automatic read_ub(input logic [7:0] addr,
                         input logic [DATA_WIDTH-1:0] expected);
    begin
      @(negedge clk);
      ub_rd_addr = addr;
      ub_rd_en = 1'b1;
      @(posedge clk);
      #1;
      if (!ub_rd_valid || ub_rd_data !== expected)
        $fatal(1, "UB mismatch at %0d: got %h expected %h", addr, ub_rd_data, expected);
      @(negedge clk);
      ub_rd_en = 1'b0;
    end
  endtask

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    issue_valid = 1'b0;
    issue_instr = '0;
    issue_rs1 = '0;
    issue_rs2 = '0;
    issue_id = '0;
    commit_valid = 1'b0;
    commit_kill = 1'b0;
    commit_id = '0;
    result_ready = 1'b0;
    ub_rd_en = 1'b0;
    ub_rd_addr = '0;
    source_mem[0] = INPUT_A;
    source_mem[1] = INPUT_B;

    repeat (2) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;

    // 1. Memory -> UB[12:13]. No read is allowed before commit.
    issue_command(make_minitensor_load(5'd5, 5'd1, 5'd2),
                  32'h0000_0000, {16'h0, 8'd2, 8'd12}, 4'd1);
    repeat (2) @(posedge clk);
    if (read_count != 0 || dma_busy)
      $fatal(1, "MT_LOAD had side effects before commit");
    commit_command(4'd1, 1'b0);
    accept_result(4'd1, 5'd5);
    if (read_count != 2 || response_count != 2)
      $fatal(1, "MT_LOAD transaction count mismatch");
    read_ub(8'd12, INPUT_A);
    read_ub(8'd13, INPUT_B);

    // 2. UB[12] + UB[13] -> VPU -> UB[14].
    issue_command(make_vector_rtype(VPU_VECTOR_FUNCT3_ADD8, 5'd6, 5'd1, 5'd2),
                  {16'h0, 8'd13, 8'd12}, {24'h0, 8'd14}, 4'd2);
    commit_command(4'd2, 1'b0);
    accept_result(4'd2, 5'd6);
    read_ub(8'd14, EXPECTED_ADD);

    // 3. UB[14] -> Memory[0x100].
    issue_command(make_minitensor_store(5'd7, 5'd1, 5'd2),
                  32'h0000_0100, {16'h0, 8'd1, 8'd14}, 4'd3);
    commit_command(4'd3, 1'b0);
    accept_result(4'd3, 5'd7);
    if (write_count != 1 || stored_result !== EXPECTED_ADD)
      $fatal(1, "closed-loop stored result mismatch: %h", stored_result);

    // A killed store must not create another external write.
    issue_command(make_minitensor_store(5'd8, 5'd1, 5'd2),
                  32'h0000_0100, {16'h0, 8'd1, 8'd14}, 4'd4);
    commit_command(4'd4, 1'b1);
    repeat (4) @(posedge clk);
    if (write_count != 1 || result_valid)
      $fatal(1, "commit-kill allowed store side effects");

    $display("PASS: NPC drove Memory -> UB -> VPU -> UB -> Memory closed loop");
    $finish;
  end
endmodule
