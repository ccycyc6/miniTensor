`timescale 1ns/1ps

// Minimal CV-X-IF coprocessor using the official interface shape.
module vpu_basic #(
  parameter int unsigned X_ID_WIDTH     = 4,
  parameter int unsigned X_RFR_WIDTH    = 32,
  parameter int unsigned X_RFW_WIDTH    = 32,
  parameter int unsigned X_HARTID_WIDTH = 1
) (
  input logic clk,
  input logic rst,
  core_v_xif xif
);
  import vpu_pkg::*;


  typedef enum logic [1:0] {
    S_IDLE        = 2'd0,
    S_WAIT_REG    = 2'd1,
    S_WAIT_COMMIT = 2'd2,
    S_RESULT      = 2'd3
  } state_t;

  state_t state_q;
  logic [2:0] op_q;
  logic [X_ID_WIDTH-1:0] id_q;
  logic [X_HARTID_WIDTH-1:0] hartid_q;
  logic [4:0] rd_q;
  logic [X_RFR_WIDTH-1:0] rs1_q;
  logic [X_RFR_WIDTH-1:0] rs2_q;
  logic [X_RFW_WIDTH-1:0] result_q;
  logic committed_q;
  logic issue_supported;

  always_comb begin
    issue_supported = is_vpu_instruction(xif.issue_req.instr);

    xif.issue_ready = (state_q == S_IDLE);
    xif.issue_resp = '0;
    xif.issue_resp.accept = issue_supported;
    xif.issue_resp.writeback[0] = issue_supported;
    xif.issue_resp.register_read[1:0] = issue_supported ?
      ((xif.issue_req.instr[14:12] == VPU_FUNCT3_RELU8) ? 2'b01 : 2'b11) : 2'b00;
    xif.issue_resp.loadstore = 1'b0;

    // X_ISSUE_REGISTER_SPLIT=1: register_valid is a one-cycle CPU pulse.
    xif.register_ready = 1'b1;

    xif.result_valid = (state_q == S_RESULT);
    xif.result = '0;
    xif.result.hartid = hartid_q;
    xif.result.id = id_q;
    xif.result.data = result_q;
    xif.result.rd = rd_q;
    xif.result.we[0] = 1'b1;

    // This bring-up VPU has no compressed or memory operations.
    xif.compressed_ready = 1'b1;
    xif.compressed_resp = '0;
    xif.mem_valid = 1'b0;
    xif.mem_req = '0;

  end

  wire issue_fire = xif.issue_valid && xif.issue_ready && issue_supported;
  wire register_fire = xif.register_valid &&
                       (state_q == S_WAIT_REG) &&
                       (xif.register.id == id_q) &&
                       (xif.register.hartid == hartid_q) &&
                       xif.register.rs_valid[0] &&
                       ((op_q == VPU_OP_RELU8) || xif.register.rs_valid[1]);

  logic [X_RFR_WIDTH-1:0] compute_a, compute_b;
  logic [X_RFW_WIDTH-1:0] compute_result;
  assign compute_a = register_fire ? xif.register.rs[0] : rs1_q;
  assign compute_b = register_fire ? xif.register.rs[1] : rs2_q;

  vpu_compute #(
    .DATA_WIDTH(X_RFR_WIDTH),
    .RESULT_WIDTH(X_RFW_WIDTH)
  ) u_compute (
    .op(op_q), .a(compute_a), .b(compute_b), .result(compute_result)
  );
  wire commit_fire = xif.commit_valid &&
                     (xif.commit.id == id_q) &&
                     (xif.commit.hartid == hartid_q);
  wire result_fire = xif.result_valid && xif.result_ready;

  always_ff @(posedge clk) begin  
    if (rst) begin
      state_q <= S_IDLE;
      op_q <= VPU_OP_INVALID;
      id_q <= '0;
      hartid_q <= '0;
      rd_q <= '0;
      rs1_q <= '0;
      rs2_q <= '0;
      result_q <= '0;
      committed_q <= 1'b0;
      // No architectural state is changed until result handshake.
    end else begin
      case (state_q)
        S_IDLE: begin
          if (issue_fire) begin
            id_q <= xif.issue_req.id;
            hartid_q <= xif.issue_req.hartid;
            rd_q <= xif.issue_req.instr[11:7];
            op_q <= decode_vpu_op(xif.issue_req.instr);
            committed_q <= 1'b0;

            if (xif.commit_valid &&
                (xif.commit.id == xif.issue_req.id) &&
                (xif.commit.hartid == xif.issue_req.hartid)) begin
              if (xif.commit.commit_kill) begin
                state_q <= S_IDLE;
              end else begin
                committed_q <= 1'b1;
                state_q <= S_WAIT_REG;
              end
            end else begin
              state_q <= S_WAIT_REG;
            end
          end
        end

        S_WAIT_REG: begin
          if (commit_fire && xif.commit.commit_kill) begin
            state_q <= S_IDLE;
          end else if (register_fire) begin
            rs1_q <= xif.register.rs[0];
            rs2_q <= xif.register.rs[1];
            if (committed_q || (commit_fire && !xif.commit.commit_kill)) begin
              result_q <= compute_result;
              state_q <= S_RESULT;
            end else begin
              state_q <= S_WAIT_COMMIT;
            end
          end else if (commit_fire) begin
            committed_q <= 1'b1;
          end
        end

        S_WAIT_COMMIT: begin
          if (commit_fire) begin
            if (xif.commit.commit_kill) begin
              state_q <= S_IDLE;
            end else begin
              committed_q <= 1'b1;
              result_q <= compute_result;
              state_q <= S_RESULT;
            end
          end
        end

        S_RESULT: begin
          if (result_fire) begin
            state_q <= S_IDLE;
            committed_q <= 1'b0;
          end
        end

        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
