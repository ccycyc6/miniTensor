`timescale 1ns/1ps

module tb_mini_tensor_top;
  import minitensor_pkg::*;

  localparam int unsigned DATA_WIDTH = 128;
  localparam int unsigned UB_DEPTH = 256;
  localparam int unsigned UB_ADDR_WIDTH = $clog2(UB_DEPTH);
  localparam int unsigned TILE_COUNT = 4;

  logic clk, rst;
  always #5 clk = ~clk;

  logic issue_valid, issue_ready, issue_accept;
  logic [31:0] issue_instr, issue_rs1, issue_rs2;
  logic [3:0] issue_id;
  logic commit_valid, commit_kill;
  logic [3:0] commit_id;
  logic result_valid, result_ready;
  logic [3:0] result_id;
  logic [4:0] result_rd;
  logic [31:0] result_data;
  logic result_we, result_exc, result_dbg, result_err;
  logic result_hartid;
  logic [5:0] result_exccode;
  logic mem_rd_valid, mem_rd_ready, mem_rsp_valid, mem_rsp_ready;
  logic [31:0] mem_rd_addr;
  logic [DATA_WIDTH-1:0] mem_rsp_data;
  logic ub_rd_en, ub_rd_valid;
  logic [UB_ADDR_WIDTH-1:0] ub_rd_addr;
  logic [DATA_WIDTH-1:0] ub_rd_data;
  logic dma_busy;

  logic [DATA_WIDTH-1:0] backing_mem [0:TILE_COUNT-1];
  logic mem_pending;
  logic [DATA_WIDTH-1:0] pending_data;
  integer request_count;
  integer response_count;

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
    .npc_result_data(result_data),
    .npc_result_rd(result_rd), .npc_result_we(result_we), .npc_result_exc(result_exc),
    .npc_result_exccode(result_exccode), .npc_result_dbg(result_dbg),
    .npc_result_err(result_err),
    .mem_rd_valid, .mem_rd_ready, .mem_rd_addr,
    .mem_rsp_valid, .mem_rsp_ready, .mem_rsp_data,
    .ub_rd_en, .ub_rd_addr, .ub_rd_valid, .ub_rd_data, .dma_busy
  );

  assign mem_rd_ready = 1'b1;

  always_ff @(posedge clk) begin
    if (rst) begin
      mem_rsp_valid <= 1'b0;
      mem_rsp_data <= '0;
      mem_pending <= 1'b0;
      pending_data <= '0;
      request_count <= 0;
      response_count <= 0;
    end else begin
      mem_rsp_valid <= mem_pending;
      mem_rsp_data <= pending_data;
      mem_pending <= 1'b0;
      if (mem_rd_valid && mem_rd_ready) begin
        if (mem_rd_addr >= TILE_COUNT * 16)
          $fatal(1, "DMA issued out-of-range address %h", mem_rd_addr);
        pending_data <= backing_mem[mem_rd_addr[5:4]];
        mem_pending <= 1'b1;
        request_count <= request_count + 1;
      end
      if (mem_rsp_valid && mem_rsp_ready)
        response_count <= response_count + 1;
    end
  end

  task automatic drive_issue(input logic [3:0] id, input logic [31:0] src,
                             input logic [7:0] count, input logic [7:0] dst);
    begin
      @(negedge clk);
      issue_id = id;
      issue_rs1 = src;
      issue_rs2 = {16'h0, count, dst};
      issue_instr = make_minitensor_load(5'd7, 5'd1, 5'd2);
      issue_valid = 1'b1;
      while (!issue_ready) @(negedge clk);
      #1;
      if (!issue_accept) $fatal(1, "MT_LOAD was not accepted");
      @(posedge clk);
      @(negedge clk);
      issue_valid = 1'b0;
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
    issue_id = '0;
    issue_rs1 = '0;
    issue_rs2 = '0;
    commit_valid = 1'b0;
    commit_id = '0;
    commit_kill = 1'b0;
    result_ready = 1'b0;
    ub_rd_en = 1'b0;
    ub_rd_addr = '0;
    backing_mem[0] = 128'h00112233445566778899aabbccddeeff;
    backing_mem[1] = 128'h102132435465768798a9bacbdcedfe0f;
    backing_mem[2] = 128'hfedcba98765432100123456789abcdef;
    backing_mem[3] = 128'hffeeddccbbaa99887766554433221100;

    repeat (2) @(posedge clk);
    rst = 1'b0;

    drive_issue(4'd1, 32'h0000_0000, TILE_COUNT[7:0], 8'd12);
    repeat (2) @(posedge clk);
    if (mem_rd_valid || dma_busy)
      $fatal(1, "DMA started before commit");

    @(negedge clk);
    commit_id = 4'd1;
    commit_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    commit_valid = 1'b0;
    while (!dma_busy) @(negedge clk);

    // A second issue must remain blocked while the DMA owns the command slot.
    issue_id = 4'd9;
    issue_rs1 = 32'h0000_0000;
    issue_rs2 = {16'h0, 8'd1, 8'd24};
    issue_instr = make_minitensor_load(5'd8, 5'd1, 5'd2);
    issue_valid = 1'b1;
    repeat (2) begin
      @(negedge clk);
      if (issue_ready) $fatal(1, "new issue was accepted while DMA was busy");
    end
    issue_valid = 1'b0;

    while (!result_valid) @(negedge clk);
    #1;
    if (result_id !== 4'd1 || result_rd !== 5'd7 || result_data !== 0 ||
        result_hartid !== 1'b0 || !result_we || result_exc ||
        result_exccode !== 0 || result_dbg || result_err)
      $fatal(1, "MT_LOAD result mismatch");

    // Backpressure must not change or drop the result.
    repeat (3) begin
      @(negedge clk);
      if (!result_valid || result_id !== 4'd1 || result_rd !== 5'd7 ||
          result_data !== 0)
        $fatal(1, "MT_LOAD result changed under backpressure");
    end
    result_ready = 1'b1;
    @(posedge clk);
    @(negedge clk);
    result_ready = 1'b0;

    if (request_count != TILE_COUNT || response_count != TILE_COUNT)
      $fatal(1, "DMA count mismatch req=%0d rsp=%0d", request_count, response_count);
    read_ub(8'd12, backing_mem[0]);
    read_ub(8'd13, backing_mem[1]);
    read_ub(8'd14, backing_mem[2]);
    read_ub(8'd15, backing_mem[3]);

    drive_issue(4'd2, 32'h0000_0000, 8'd1, 8'd20);
    @(negedge clk);
    commit_id = 4'd2;
    commit_kill = 1'b1;
    commit_valid = 1'b1;
    @(posedge clk);
    @(negedge clk);
    commit_valid = 1'b0;
    commit_kill = 1'b0;
    repeat (3) @(posedge clk);
    if (request_count != TILE_COUNT || result_valid)
      $fatal(1, "commit kill allowed DMA side effects");

    $display("PASS: committed MT_LOAD, commit-kill and UB integration completed");
    $finish;
  end
endmodule
