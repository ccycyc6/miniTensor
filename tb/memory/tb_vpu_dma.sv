`timescale 1ns/1ps

module tb_vpu_dma;
  localparam int unsigned DATA_WIDTH = 128;
  localparam int unsigned UB_DEPTH = 256;
  localparam int unsigned UB_ADDR_WIDTH = $clog2(UB_DEPTH);
  localparam int unsigned TILE_COUNT = 4;

  logic clk;
  logic rst;
  logic cmd_valid;
  logic cmd_ready;
  logic [31:0] cmd_src_addr;
  logic [UB_ADDR_WIDTH-1:0] cmd_dst_addr;
  logic [7:0] cmd_tile_count;
  logic busy;
  logic done;
  logic mem_rd_valid;
  logic mem_rd_ready;
  logic [31:0] mem_rd_addr;
  logic mem_rsp_valid;
  logic mem_rsp_ready;
  logic [DATA_WIDTH-1:0] mem_rsp_data;
  logic ub_wr_en;
  logic [UB_ADDR_WIDTH-1:0] ub_wr_addr;
  logic [DATA_WIDTH-1:0] ub_wr_data;
  logic [DATA_WIDTH/8-1:0] ub_wr_be;
  logic ub_rd_en;
  logic [UB_ADDR_WIDTH-1:0] ub_rd_addr;
  logic ub_rd_valid;
  logic [DATA_WIDTH-1:0] ub_rd_data;

  logic [DATA_WIDTH-1:0] backing_mem [0:TILE_COUNT-1];
  logic mem_rsp_pending;
  logic [DATA_WIDTH-1:0] mem_pending_data;
  integer request_count;
  integer response_count;

  vpu_dma #(
    .DATA_WIDTH(DATA_WIDTH),
    .UB_ADDR_WIDTH(UB_ADDR_WIDTH),
    .COUNT_WIDTH(8)
  ) dma (
    .clk, .rst,
    .cmd_valid, .cmd_ready,
    .cmd_src_addr, .cmd_dst_addr, .cmd_tile_count,
    .busy, .done,
    .mem_rd_valid, .mem_rd_ready, .mem_rd_addr,
    .mem_rsp_valid, .mem_rsp_ready, .mem_rsp_data,
    .ub_wr_en, .ub_wr_addr, .ub_wr_data, .ub_wr_be
  );

  unified_buffer #(
    .DATA_WIDTH(DATA_WIDTH),
    .DEPTH(UB_DEPTH),
    .ADDR_WIDTH(UB_ADDR_WIDTH)
  ) ub (
    .clk, .rst,
    .wr_en(ub_wr_en), .wr_addr(ub_wr_addr), .wr_data(ub_wr_data), .wr_be(ub_wr_be),
    .rd_en(ub_rd_en), .rd_addr(ub_rd_addr),
    .rd_valid(ub_rd_valid), .rd_data(ub_rd_data)
  );

  always #5 clk = ~clk;

  // The backing-memory model accepts every request; response delivery still
  // has an explicit one-cycle delay through mem_rsp_pending.
  assign mem_rd_ready = 1'b1;

  always_ff @(posedge clk) begin
    if (rst) begin
      mem_rsp_valid <= 1'b0;
      mem_rsp_data <= '0;
      mem_rsp_pending <= 1'b0;
      mem_pending_data <= '0;
      request_count <= 0;
      response_count <= 0;
    end else begin
      mem_rsp_valid <= mem_rsp_pending;
      mem_rsp_data <= mem_pending_data;
      mem_rsp_pending <= 1'b0;
      if (mem_rd_valid && mem_rd_ready) begin
        if (mem_rd_addr >= TILE_COUNT * 16)
          $fatal(1, "DMA issued out-of-range source address %h", mem_rd_addr);
        mem_pending_data <= backing_mem[mem_rd_addr[5:4]];
        mem_rsp_pending <= 1'b1;
        request_count <= request_count + 1;
      end
      if (mem_rsp_valid && mem_rsp_ready)
        response_count <= response_count + 1;
    end
  end

  task automatic read_ub(
    input logic [UB_ADDR_WIDTH-1:0] addr,
    input logic [DATA_WIDTH-1:0] expected
  );
    begin
      @(negedge clk);
      ub_rd_en = 1'b1;
      ub_rd_addr = addr;
      @(posedge clk);
      #1;
      if (!ub_rd_valid || ub_rd_data !== expected)
        $fatal(1, "Unified Buffer mismatch at %0d: got %h expected %h",
               addr, ub_rd_data, expected);
      @(negedge clk);
      ub_rd_en = 1'b0;
      @(posedge clk);
    end
  endtask

  initial begin
    clk = 1'b0;
    rst = 1'b1;
    cmd_valid = 1'b0;
    cmd_src_addr = '0;
    cmd_dst_addr = '0;
    cmd_tile_count = '0;
    ub_rd_en = 1'b0;
    ub_rd_addr = '0;
    backing_mem[0] = 128'h00112233445566778899aabbccddeeff;
    backing_mem[1] = 128'h102132435465768798a9bacbdcedfe0f;
    backing_mem[2] = 128'hfedcba98765432100123456789abcdef;
    backing_mem[3] = 128'hffeeddccbbaa99887766554433221100;

    repeat (2) @(posedge clk);
    @(negedge clk);
    rst = 1'b0;
    cmd_valid = 1'b1;
    cmd_src_addr = 32'h0000_0000;
    cmd_dst_addr = 8'd12;
    cmd_tile_count = 8'(TILE_COUNT);
    #1;
    if (!cmd_ready || busy)
      $fatal(1, "DMA did not advertise idle command readiness");
    @(posedge clk);
    #1;
    if (cmd_ready || !busy)
      $fatal(1, "DMA command was not accepted");
    @(negedge clk);
    cmd_valid = 1'b0;

    while (!done) begin
      @(posedge clk);
      if (cmd_ready && busy)
        $fatal(1, "DMA advertised command ready while busy");
    end
    #1;
    if (request_count != TILE_COUNT || response_count != TILE_COUNT)
      $fatal(1, "DMA transaction count mismatch: requests=%0d responses=%0d",
             request_count, response_count);
    if (busy)
      $fatal(1, "DMA remained busy after done");

    read_ub(8'd12, backing_mem[0]);
    read_ub(8'd13, backing_mem[1]);
    read_ub(8'd14, backing_mem[2]);
    read_ub(8'd15, backing_mem[3]);

    $display("PASS: DMA copied contiguous tiles from memory into Unified Buffer");
    $finish;
  end
endmodule
