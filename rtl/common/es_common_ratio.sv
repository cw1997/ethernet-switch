// ============================================================================
//  File        : es_common_ratio.sv
//  Description : Serial multiply/divide engine for telemetry rates.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                A start request captures operands; consumers wait for valid before reading
//                the result. Serial arithmetic stays outside the forwarding path.
//  Interface   : start_i captures value_i, scale_i and divisor_i while idle.
//                busy_o spans serial computation; valid_o qualifies result_o.
//                Overflow saturates to 64'hffff_ffff_ffff_ffff; a zero divisor
//                yields zero. The result is intended for telemetry, not packet flow.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_COMMON_RATIO_SV
`define ES_COMMON_RATIO_SV
`default_nettype none

// --------------------------------------------------------------------------
// Configuration and public interface
// --------------------------------------------------------------------------
module es_common_ratio (
  input var logic clk_i, rst_ni, start_i,
  input var logic [63:0] value_i, scale_i, divisor_i,
  output logic busy_o, valid_o,
  output logic [63:0] result_o
);

  // --------------------------------------------------------------------------
  // Control state
  // --------------------------------------------------------------------------
  typedef enum logic [1:0] {
    S_IDLE,
    S_MUL,
    S_DIV
  } state_e;
  state_e state_q;
  // --------------------------------------------------------------------------
  // Serial arithmetic registers
  //
  // The multiply consumes 64 scale bits, then the divide consumes 128
  // product bits. Operands are captured only in S_IDLE; start requests
  // during computation are not queued.
  // --------------------------------------------------------------------------
  logic [127:0] product_q, factor_q, quotient_q;
  logic [63:0] multiplier_q, divisor_q;
  logic [ 63:0] remainder_q;
  logic [ 64:0] trial;
  logic [  7:0] count_q;
  logic [127:0] product_next;
  // Only the low multiplier bit contributes on each serial multiply step.
  assign product_next = multiplier_q[0] ? product_q + factor_q : product_q;
  assign busy_o = state_q != S_IDLE;
  assign trial = {remainder_q[63:0], quotient_q[127]};

  // --------------------------------------------------------------------------
  // Synchronous state and datapath
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      product_q <= '0;
      factor_q <= '0;
      quotient_q <= '0;
      multiplier_q <= '0;
      divisor_q <= '0;
      remainder_q <= '0;
      count_q <= '0;
      valid_o <= 1'b0;
      result_o <= '0;
    end else begin
      valid_o <= 1'b0;
      case (state_q)
        S_IDLE: if (start_i) begin
          product_q <= '0;
          factor_q <= {64'd0, value_i};
          multiplier_q <= scale_i;
          divisor_q <= divisor_i;
          count_q <= '0;
          state_q <= S_MUL;
        end
        S_MUL: begin
          product_q <= product_next;
          // Rotate for exactly 64 steps. The wrapped bits are never consumed;
          // this avoids Yosys propagating one constant shift bit per opt pass.
          factor_q <= {factor_q[126:0], factor_q[127]};
          multiplier_q <= {multiplier_q[0], multiplier_q[63:1]};
          if (count_q == 8'd63) begin
            quotient_q <= product_next;
            remainder_q <= '0;
            count_q <= '0;
            state_q <= S_DIV;
          end else count_q <= count_q + 8'd1;
        end
        S_DIV: begin
          if (trial >= {1'b0, divisor_q}) begin
            remainder_q <= 64'(trial - {1'b0, divisor_q});
            quotient_q  <= {quotient_q[126:0], 1'b1};
          end else begin
            remainder_q <= trial[63:0];
            quotient_q  <= {quotient_q[126:0], 1'b0};
          end
          if (count_q == 8'd127) begin
            // Saturate an unrepresentable result; divide-by-zero is unavailable data.
            result_o <= (divisor_q == 64'd0) ?
                64'd0 : ((|quotient_q[126:63]) ?
                         64'hffff_ffff_ffff_ffff : {quotient_q[62:0], trial >= {1'b0, divisor_q}});
            valid_o <= 1'b1;
            state_q <= S_IDLE;
          end else count_q <= count_q + 8'd1;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
`default_nettype wire
`endif
