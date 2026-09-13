`timescale 1ns/1ps

module tb_vpu_basic;
  import vpu_pkg::*;

  localparam int ID_W = 4;

  logic clk;
  logic rst = 1'b1;
  initial begin
    clk = 1'b0;
    forever #5 clk = ~clk;
  end

  core_v_xif #(
    .X_NUM_RS               (2),
    .X_ID_WIDTH             (ID_W),
    .X_RFR_WIDTH            (32),
    .X_RFW_WIDTH            (32),
    .X_NUM_HARTS            (1),
    .X_HARTID_WIDTH         (1),
    .X_DUALREAD             (0),
    .X_DUALWRITE            (0),
    .X_ISSUE_REGISTER_SPLIT (1),
    .X_MEM_WIDTH            (32)
  ) xif ();

  vpu_basic dut (.clk, .rst, .xif);

`ifdef TRACE
  initial begin
    $dumpfile("vpu_basic.vcd");
    $dumpvars(0, tb_vpu_basic);
  end
`endif

  task automatic clear_cpu_inputs;
    begin
      xif.compressed_valid = 1'b0;
      xif.compressed_req = '0;
      xif.issue_valid = 1'b0;
      xif.issue_req = '0;
      xif.register_valid = 1'b0;
      xif.register = '0;
      xif.commit_valid = 1'b0;
      xif.commit = '0;
      xif.mem_ready = 1'b0;
      xif.mem_resp = '0;
      xif.mem_result_valid = 1'b0;
      xif.mem_result = '0;
      xif.result_ready = 1'b0;
    end
  endtask

  task automatic issue_only(
      input logic [31:0] instr,
      input logic [ID_W-1:0] id);
    begin
      @(negedge clk);
      xif.issue_valid = 1'b1;
      xif.issue_req = '0;
      xif.issue_req.instr = instr;
      xif.issue_req.id = id;
      xif.issue_req.hartid = 1'b0;
      while (!xif.issue_ready) @(negedge clk);
      #1;
      if (!xif.issue_resp.accept || !xif.issue_resp.writeback[0] ||
          xif.issue_resp.register_read[1:0] != 2'b11 ||
          xif.issue_resp.loadstore)
        $fatal(1, "issue response mismatch");
      @(posedge clk);
      @(negedge clk);
      xif.issue_valid = 1'b0;
    end
  endtask

  task automatic send_register(
      input logic [ID_W-1:0] id,
      input logic [31:0] a,
      input logic [31:0] b);
    begin
      xif.register_valid = 1'b1;
      xif.register = '0;
      xif.register.id = id;
      xif.register.hartid = 1'b0;
      xif.register.rs[0] = a;
      xif.register.rs[1] = b;
      xif.register.rs_valid[1:0] = 2'b11;
      #1;
      if (!xif.register_ready)
        $fatal(1, "split register channel was not ready");
      @(posedge clk);
      @(negedge clk);
      xif.register_valid = 1'b0;
    end
  endtask

  task automatic issue_and_register(
      input logic [31:0] instr,
      input logic [ID_W-1:0] id,
      input logic [31:0] a,
      input logic [31:0] b);
    begin
      issue_only(instr, id);
      send_register(id, a, b);
    end
  endtask

  task automatic accept_result(
      input logic [ID_W-1:0] id,
      input logic [31:0] expected,
      input logic [4:0] expected_rd);
    begin
      xif.result_ready = 1'b1;
      while (!xif.result_valid) @(negedge clk);
      if (xif.result.data !== expected || xif.result.id !== id ||
          xif.result.hartid !== 1'b0 || xif.result.rd !== expected_rd ||
          !xif.result.we[0] || xif.result.exc || xif.result.exccode !== '0 ||
          xif.result.dbg || xif.result.err)
        $fatal(1, "result mismatch: data=%h id=%0d rd=%0d",
               xif.result.data, xif.result.id, xif.result.rd);
      @(posedge clk);
      @(negedge clk);
      xif.result_ready = 1'b0;
    end
  endtask

  task automatic commit_and_check(
      input logic [ID_W-1:0] id,
      input logic [31:0] expected,
      input logic [4:0] expected_rd);
    begin
      @(negedge clk);
      xif.commit_valid = 1'b1;
      xif.commit = '0;
      xif.commit.id = id;
      xif.commit.commit_kill = 1'b0;
      @(posedge clk);
      @(negedge clk);
      xif.commit_valid = 1'b0;
      accept_result(id, expected, expected_rd);
    end
  endtask

  initial begin
    clear_cpu_inputs();
    repeat (2) @(negedge clk);
    rst = 1'b0;

    $display("[1] VADD: rs1=17 rs2=25 -> rd=x3 data=42");
    issue_and_register(make_vpu_rtype(VPU_FUNCT3_ADD, 5'd3, 5'd1, 5'd2),
                       4'd1, 32'd17, 32'd25);
    commit_and_check(4'd1, 32'd42, 5'd3);

    $display("[2] VXOR: result remains stable while result_ready=0");
    issue_and_register(make_vpu_rtype(VPU_FUNCT3_XOR, 5'd5, 5'd6, 5'd7),
                       4'd2, 32'h55aa00ff, 32'h0f0f3333);
    @(negedge clk);
    xif.commit_valid = 1'b1;
    xif.commit = '0;
    xif.commit.id = 4'd2;
    @(posedge clk);
    @(negedge clk);
    xif.commit_valid = 1'b0;
    repeat (2) begin
      @(negedge clk);
      if (!xif.result_valid || xif.result.data !== 32'h5aa533cc)
        $fatal(1, "result was not held under backpressure");
    end
    xif.result_ready = 1'b1;
    #1;
    if (!xif.result_valid || xif.result.data !== 32'h5aa533cc ||
        xif.result.rd !== 5'd5)
      $fatal(1, "VXOR result mismatch before handshake");
    @(posedge clk);
    @(negedge clk);
    xif.result_ready = 1'b0;

    $display("[3] Standard ADD is rejected by the VPU");
    @(negedge clk);
    xif.issue_valid = 1'b1;
    xif.issue_req = '0;
    xif.issue_req.instr = 32'h00000033;
    xif.issue_req.id = 4'd3;
    #1;
    if (!xif.issue_ready || xif.issue_resp.accept ||
        xif.issue_resp.writeback[0] ||
        xif.issue_resp.register_read[1:0] !== 2'b00)
      $fatal(1, "unsupported instruction was not rejected");
    @(posedge clk);
    @(negedge clk);
    xif.issue_valid = 1'b0;
    xif.commit_valid = 1'b1;
    xif.commit = '0;
    xif.commit.id = 4'd3;
    @(posedge clk);
    @(negedge clk);
    xif.commit_valid = 1'b0;

    $display("[4] A killed VADD produces no result");
    issue_and_register(make_vpu_rtype(VPU_FUNCT3_ADD, 5'd4, 5'd1, 5'd2),
                       4'd4, 32'd10, 32'd20);
    xif.commit_valid = 1'b1;
    xif.commit = '0;
    xif.commit.id = 4'd4;
    xif.commit.commit_kill = 1'b1;
    @(posedge clk);
    @(negedge clk);
    xif.commit_valid = 1'b0;
    @(negedge clk);
    if (xif.result_valid)
      $fatal(1, "killed operation did not return to idle");

    $display("[5] Positive commit may arrive before split register operands");
    issue_only(make_vpu_rtype(VPU_FUNCT3_ADD, 5'd8, 5'd1, 5'd2), 4'd5);
    xif.commit_valid = 1'b1;
    xif.commit = '0;
    xif.commit.id = 4'd5;
    @(posedge clk);
    @(negedge clk);
    xif.commit_valid = 1'b0;
    send_register(4'd5, 32'd100, 32'd23);
    accept_result(4'd5, 32'd123, 5'd8);

    $display("PASS: official-compatible CV-X-IF VPU demo completed");
    $finish;
  end

  initial begin
    #5000;
    $fatal(1, "simulation timeout");
  end
endmodule
