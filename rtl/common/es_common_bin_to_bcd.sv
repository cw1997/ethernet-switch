// ============================================================================
//  File        : es_common_bin_to_bcd.sv
//  Description : Serial binary-to-BCD double-dabble converter.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                A start_i while idle captures a 64-bit value and publishes
//                twenty packed decimal digits after shifting all input bits;
//                requests while busy are not queued.
//
//                valid_o pulses for exactly one clock when bcd_o is published,
//                and bcd_o holds its value until the next conversion completes.
//                Each nibble is one decimal digit, least-significant in [3:0].
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_COMMON_BIN_TO_BCD_SV
`define ES_COMMON_BIN_TO_BCD_SV

`default_nettype none

module es_common_bin_to_bcd (
  /// Core clock, synchronous active-low reset, and idle-qualified start pulse.
  input var logic clk_i, rst_ni, start_i,
  /// Unsigned binary value sampled on the clock that accepts start_i.
  input var logic [63:0] value_i,
  /// Pulses when the packed twenty-digit BCD result is published.
  output    logic valid_o,
  /// Twenty decimal nibbles, least-significant digit in bits [3:0].
  output    logic [79:0] bcd_o);

  // --------------------------------------------------------------------------
  // Conversion registers
  //
  // Twenty BCD nibbles hold all 64 input bits.  `left_q` counts the shifts
  // still to perform; publication includes the final corrected shift rather
  // than the previous `bcd_q` value, which is why the last step writes both
  // `bcd_q` and `bcd_o` from the same expression.
  // --------------------------------------------------------------------------
  logic        busy_q;
  logic [ 6:0] left_q;
  logic [63:0] value_q;
  logic [79:0] bcd_q;
  logic [79:0] corrected;

  // --------------------------------------------------------------------------
  // Double-dabble correction
  //
  // Add three to every digit whose value is five or more, before the shift
  // that would carry it into the next decade.  A function rather than an
  // accumulating process: the loop writes and reads `y` inside one evaluation,
  // which is safe with no sensitivity list and would re-trigger forever in an
  // `always_comb`.
  // --------------------------------------------------------------------------
  function automatic logic [79:0] correct(input var logic [79:0] x);
    logic [79:0] y;
    y = x;
    for (int unsigned d = 0; d < 20; d++) begin
      if (x[d*4 +: 4] >= 4'd5) y[d*4 +: 4] = x[d*4 +: 4] + 4'd3;
    end
    correct = y;
  endfunction

  assign corrected = correct(bcd_q);

  // The top digit only ever reaches 1 and its most-significant bit is shifted
  // out of the register, so it is never part of the published value.  Reduce it
  // explicitly instead of leaving an unconsumed slice for the linter to find.
  logic unused_correction;
  assign unused_correction = corrected[79];

  // --------------------------------------------------------------------------
  // Synchronous state and datapath
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      busy_q  <= 1'b0;
      valid_o <= 1'b0;
      bcd_o   <= '0;
      left_q  <= '0;
      value_q <= '0;
      bcd_q   <= '0;
    end else begin
      valid_o <= 1'b0;
      if (!busy_q) begin
        if (start_i) begin
          busy_q  <= 1'b1;
          left_q  <= 7'd64;
          value_q <= value_i;
          bcd_q   <= '0;
        end
      end else begin
        bcd_q   <= {corrected[78:0], value_q[63]};
        value_q <= {value_q[62:0], 1'b0};
        left_q  <= left_q - 7'd1;
        if (left_q == 7'd1) begin
          busy_q  <= 1'b0;
          valid_o <= 1'b1;
          bcd_o   <= {corrected[78:0], value_q[63]};
        end
      end
    end
  end

endmodule : es_common_bin_to_bcd

`default_nettype wire

`endif  // ES_COMMON_BIN_TO_BCD_SV
