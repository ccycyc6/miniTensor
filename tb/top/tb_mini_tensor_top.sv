`timescale 1ns/1ps

module tb_mini_tensor_top;
  import minitensor_pkg::*;
  import tensor_pkg::*;
  import vpu_pkg::*;

  localparam int unsigned DATA_WIDTH = 128;
  localparam logic [DATA_WIDTH-1:0] INPUT_A =
      128'h7f05ff80_7d03fd80_7c02fc80_7b01fb80;
  localparam logic [DATA_WIDTH-1:0] INPUT_B =
      128'h01010101_01010101_01010101_01010101;
  localparam logic [DATA_WIDTH-1:0] EXPECTED_ADD =
      128'h80060081_7e04fe81_7d03fd81_7c02fc81;
  localparam logic [DATA_WIDTH-1:0] TENSOR_A =
      128'hff017f80_0100fe05_020100ff_04030201;
  localparam logic [DATA_WIDTH-1:0] TENSOR_B =
      128'h0102ff00_000103ff_fe000102_02ff0001;
  localparam logic [DATA_WIDTH-1:0] TENSOR_C0 =
      128'h00000002_0000000a_00000007_00000002;
  localparam logic [DATA_WIDTH-1:0] TENSOR_C1 =
      128'h00000000_00000006_00000001_fffffffe;
  localparam logic [DATA_WIDTH-1:0] TENSOR_C2 =
      128'h0000000f_fffffffd_fffffffd_00000001;
  localparam logic [DATA_WIDTH-1:0] TENSOR_C3 =
      128'hfffffe01_0000007f_00000083_0000007d;

  logic clk, rst;
  always #5 clk = ~clk;

  core_v_xif #(
    .X_NUM_RS(2),
    .X_ID_WIDTH(4),
    .X_RFR_WIDTH(32),
    .X_RFW_WIDTH(32),
    .X_HARTID_WIDTH(1),
    .X_ISSUE_REGISTER_SPLIT(1)
  ) xif();

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

  logic [DATA_WIDTH-1:0] source_mem [0:3];
  logic [DATA_WIDTH-1:0] tensor_stored [0:3];
  logic [DATA_WIDTH-1:0] stored_result;
  logic mem_pending;
  logic [DATA_WIDTH-1:0] pending_data;
  integer read_count, response_count, write_count;
  integer tensor_write_count;

  mini_tensor_top dut (
    .clk, .rst,
    .xif,
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
      tensor_write_count <= 0;
    end else begin
      mem_rsp_valid <= mem_pending;
      mem_rsp_data <= pending_data;
      mem_pending <= 1'b0;
      if (mem_rd_valid && mem_rd_ready) begin
        if (mem_rd_addr >= 64)
          $fatal(1, "unexpected memory read address %h", mem_rd_addr);
        pending_data <= source_mem[mem_rd_addr[5:4]];
        mem_pending <= 1'b1;
        read_count <= read_count + 1;
      end
      if (mem_rsp_valid && mem_rsp_ready)
        response_count <= response_count + 1;
      if (mem_wr_valid && mem_wr_ready) begin
        if (mem_wr_be !== '1)
          $fatal(1, "unexpected memory write transaction");
        if (mem_wr_addr == 32'h0000_0100) begin
          stored_result <= mem_wr_data;
        end else if ((mem_wr_addr >= 32'h0000_0200) &&
                     (mem_wr_addr < 32'h0000_0240)) begin
          tensor_stored[(mem_wr_addr - 32'h0000_0200) >> 4] <= mem_wr_data;
        end else begin
          $fatal(1, "unexpected memory write address %h", mem_wr_addr);
        end
        write_count <= write_count + 1;
      end
      if (dut.tensor_ub_wr_en)
        tensor_write_count <= tensor_write_count + 1;
    end
  end

  task automatic issue_command(
      input logic [31:0] instr,
      input logic [31:0] rs1,
      input logic [31:0] rs2,
      input logic [3:0] id);
    begin
      @(negedge clk);
      xif.issue_req.instr = instr;
      xif.issue_req.id = id;
      xif.issue_req.hartid = 1'b0;
      xif.issue_req.mode = 2'b00;
      xif.issue_valid = 1'b1;
      while (!xif.issue_ready) @(negedge clk);
      #1;
      if (!xif.issue_resp.accept)
        $fatal(1, "command was not accepted: %h", instr);
      @(posedge clk);
      @(negedge clk);
      xif.issue_valid = 1'b0;

      xif.register.id = id;
      xif.register.hartid = 1'b0;
      xif.register.rs[0] = rs1;
      xif.register.rs[1] = rs2;
      xif.register.rs_valid = 2'b11;
      xif.register_valid = 1'b1;
      while (!xif.register_ready) @(negedge clk);
      @(posedge clk);
      @(negedge clk);
      xif.register_valid = 1'b0;
    end
  endtask

  task automatic commit_command(input logic [3:0] id, input logic kill);
    begin
      @(negedge clk);
      xif.commit.id = id;
      xif.commit.hartid = 1'b0;
      xif.commit.commit_kill = kill;
      xif.commit_valid = 1'b1;
      @(posedge clk);
      @(negedge clk);
      xif.commit_valid = 1'b0;
      xif.commit.commit_kill = 1'b0;
    end
  endtask

  task automatic accept_result(input logic [3:0] id, input logic [4:0] rd);
    begin
      while (!xif.result_valid) @(negedge clk);
      repeat (2) begin
        #1;
        if (!xif.result_valid || xif.result.id !== id || xif.result.rd !== rd ||
            xif.result.hartid !== 1'b0 || xif.result.data !== 0 ||
            !xif.result.we[0] || xif.result.exc ||
            xif.result.exccode !== 0 || xif.result.dbg || xif.result.err)
          $fatal(1, "result changed under backpressure");
        @(negedge clk);
      end
      xif.result_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      xif.result_ready = 1'b0;
    end
  endtask

  task automatic accept_error_result(input logic [3:0] id, input logic [4:0] rd);
    begin
      while (!xif.result_valid) @(negedge clk);
      #1;
      if (xif.result.id !== id || xif.result.rd !== rd ||
          !xif.result.we[0] || !xif.result.err)
        $fatal(1, "invalid command did not return the expected error result");
      xif.result_ready = 1'b1;
      @(posedge clk);
      @(negedge clk);
      xif.result_ready = 1'b0;
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
    xif.compressed_valid = 1'b0;
    xif.compressed_req = '0;
    xif.issue_valid = 1'b0;
    xif.issue_req = '0;
    xif.register_valid = 1'b0;
    xif.register = '0;
    xif.commit_valid = 1'b0;
    xif.commit = '0;
    xif.mem_ready = 1'b1;
    xif.mem_resp = '0;
    xif.mem_result_valid = 1'b0;
    xif.mem_result = '0;
    xif.result_ready = 1'b0;
    ub_rd_en = 1'b0;
    ub_rd_addr = '0;
    source_mem[0] = INPUT_A;
    source_mem[1] = INPUT_B;
    source_mem[2] = TENSOR_A;
    source_mem[3] = TENSOR_B;
    for (int i = 0; i < 4; i++) tensor_stored[i] = '0;

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
    if (write_count != 1 || xif.result_valid)
      $fatal(1, "commit-kill allowed store side effects");

    // 4. Load two packed 4x4 INT8 tiles into UB[20:21].
    issue_command(make_minitensor_load(5'd9, 5'd1, 5'd2),
                  32'h0000_0020, {16'h0, 8'd2, 8'd20}, 4'd5);
    commit_command(4'd5, 1'b0);
    accept_result(4'd5, 5'd9);

    // 5. Signed INT8 A*B -> four packed INT32 rows in UB[30:33].
    issue_command(make_tensor_gemm(5'd10, 5'd1, 5'd2),
                  {16'h0, 8'd21, 8'd20}, {24'h0, 8'd30}, 4'd6);
    repeat (3) @(posedge clk);
    if (tensor_write_count != 0)
      $fatal(1, "MT_GEMM wrote UB before commit");
    commit_command(4'd6, 1'b0);
    accept_result(4'd6, 5'd10);
    if (tensor_write_count != 4)
      $fatal(1, "MT_GEMM write count mismatch: %0d", tensor_write_count);
    read_ub(8'd30, TENSOR_C0);
    read_ub(8'd31, TENSOR_C1);
    read_ub(8'd32, TENSOR_C2);
    read_ub(8'd33, TENSOR_C3);

    // 6. Store all four INT32 rows and verify the external memory image.
    issue_command(make_minitensor_store(5'd11, 5'd1, 5'd2),
                  32'h0000_0200, {16'h0, 8'd4, 8'd30}, 4'd7);
    commit_command(4'd7, 1'b0);
    accept_result(4'd7, 5'd11);
    if (write_count != 5 || tensor_stored[0] !== TENSOR_C0 ||
        tensor_stored[1] !== TENSOR_C1 || tensor_stored[2] !== TENSOR_C2 ||
        tensor_stored[3] !== TENSOR_C3)
      $fatal(1, "tensor closed-loop stored result mismatch");

    // A killed tensor command must not modify its previous result.
    issue_command(make_tensor_gemm(5'd12, 5'd1, 5'd2),
                  {16'h0, 8'd21, 8'd20}, {24'h0, 8'd30}, 4'd8);
    commit_command(4'd8, 1'b1);
    repeat (4) @(posedge clk);
    if (tensor_write_count != 4 || xif.result_valid)
      $fatal(1, "commit-kill allowed tensor side effects");

    // Four result rows starting at UB[254] exceed the 256-row buffer.
    issue_command(make_tensor_gemm(5'd13, 5'd1, 5'd2),
                  {16'h0, 8'd21, 8'd20}, {24'h0, 8'd254}, 4'd9);
    commit_command(4'd9, 1'b0);
    accept_error_result(4'd9, 5'd13);
    if (tensor_write_count != 4)
      $fatal(1, "out-of-range MT_GEMM modified the Unified Buffer");

    $display("PASS: NPC drove vector and tensor closed loops through UB and memory");
    $finish;
  end
endmodule
