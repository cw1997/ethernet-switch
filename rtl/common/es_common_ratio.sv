// ============================================================================
//  File        : es_common_ratio.sv
//  Description : Serial multiply/divide engine for telemetry rates.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                A start request captures the operands and the consumer waits
//                for `valid_o` before reading `result_o`.  The serial
//                arithmetic stays outside the forwarding path on purpose: it
//                is eight times slower than a single-cycle unit and eight times
//                smaller, and nothing in the datapath depends on its latency.
//
//                `result_o` = value_i * scale_i / divisor_i, computed as a
//                64x64 multiply followed by a 128/64 divide.  Overflow
//                saturates to 64'hFFFF_FFFF_FFFF_FFFF; a zero divisor yields
//                zero, because that is unavailable data rather than a number.
//                `busy_o` spans the whole computation and requests arriving
//                while it is high are not queued.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_COMMON_RATIO_SV
`define ES_COMMON_RATIO_SV

`default_nettype none

module es_common_ratio (
  /// Core clock, synchronous active-low reset, and idle-qualified start pulse.
  input var logic        clk_i, rst_ni, start_i,
  /// Operands captured on the clock that accepts start_i.
  input var logic [63:0] value_i, scale_i, divisor_i,
  /// `busy_o` spans the computation; `valid_o` qualifies `result_o` for one clock.
  output    logic        busy_o, valid_o,
  /// Quotient, saturated on overflow and zero for a zero divisor.
  output    logic [63:0] result_o);

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
  // The multiply consumes 64 scale bits, then the divide consumes 128 product
  // bits.  Operands are captured only in S_IDLE; start requests during
  // computation are not queued.
  // --------------------------------------------------------------------------
  logic [127:0] product_q;
  logic [127:0] factor_q;
  logic [127:0] quotient_q;
  logic [ 63:0] multiplier_q;
  logic [ 63:0] divisor_q;
  logic [ 63:0] remainder_q;
  logic [ 64:0] trial;
  logic [  7:0] count_q;
  logic [127:0] product_next;

  // Only the low multiplier bit contributes on each serial multiply step.
  assign product_next = multiplier_q[0] ? (product_q + factor_q) : product_q;

  // One divide step: the shifted remainder is compared against the divisor.
  assign trial = {remainder_q[63:0], quotient_q[127]};

  assign busy_o = (state_q != S_IDLE);

  // --------------------------------------------------------------------------
  // Synchronous state and datapath
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q      <= S_IDLE;
      product_q    <= '0;
      factor_q     <= '0;
      quotient_q   <= '0;
      multiplier_q <= '0;
      divisor_q    <= '0;
      remainder_q  <= '0;
      count_q      <= '0;
      valid_o      <= 1'b0;
      result_o     <= '0;
    end else begin
      valid_o <= 1'b0;
      case (state_q)
        S_IDLE: if (start_i) begin
          product_q    <= '0;
          factor_q     <= {64'd0, value_i};
          multiplier_q <= scale_i;
          divisor_q    <= divisor_i;
          count_q      <= '0;
          state_q      <= S_MUL;
        end
        S_MUL: begin
          product_q <= product_next;
          // Rotate for exactly 64 steps.  The wrapped bits are never consumed;
          // this avoids Yosys propagating one constant shift bit per opt pass.
          factor_q     <= {factor_q[126:0], factor_q[127]};
          multiplier_q <= {multiplier_q[0], multiplier_q[63:1]};
          if (count_q == 8'd63) begin
            quotient_q  <= product_next;
            remainder_q <= '0;
            count_q     <= '0;
            state_q     <= S_DIV;
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
            if (divisor_q == 64'd0) begin
              // Divide-by-zero is unavailable data rather than a number.
              result_o <= 64'd0;
            end else if (|quotient_q[126:63]) begin
              // The quotient does not fit in 64 bits: saturate.
              result_o <= 64'hFFFF_FFFF_FFFF_FFFF;
            end else begin
              // The final quotient bit is the comparison just evaluated, since
              // `quotient_q` is updated on the next clock.
              result_o <= {quotient_q[62:0], (trial >= {1'b0, divisor_q})};
            end
            valid_o <= 1'b1;
            state_q <= S_IDLE;
          end else count_q <= count_q + 8'd1;
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule : es_common_ratio

`default_nettype wire

`endif  // ES_COMMON_RATIO_SV
