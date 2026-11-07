// ============================================================================
//  File        : es_common_bin_to_bcd.sv
//  Description : Serial binary-to-BCD double-dabble converter.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                Captures a 64-bit value and publishes twenty packed decimal
//                digits after shifting all input bits; requests while busy are
//                not queued.
//  Interface   : start_i captures value_i while idle. valid_o pulses when bcd_o
//                is published. Each least-significant nibble is one decimal digit;
//                output data holds until the next conversion completes.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_COMMON_BIN_TO_BCD_SV
`define ES_COMMON_BIN_TO_BCD_SV
`default_nettype none

// --------------------------------------------------------------------------
// Configuration and public interface
// --------------------------------------------------------------------------
module es_common_bin_to_bcd (
  input var logic clk_i, rst_ni, start_i,
  input var logic [63:0] value_i,
  output logic valid_o,
  output logic [79:0] bcd_o
);
  // --------------------------------------------------------------------------
  // Conversion registers
  //
  // Twenty BCD nibbles hold all 64 input bits. left_q counts remaining
  // shifts; publication includes the final corrected shift rather than the
  // previous bcd_q value.
  // --------------------------------------------------------------------------
  logic busy_q;
  logic [6:0] left_q;
  logic [63:0] value_q;
  logic [79:0] bcd_q, corrected;
  logic unused_correction;
  assign unused_correction = corrected[79];
  /// Add three before shifting each digit of five or more (double dabble).
  function automatic logic [79:0] correct(input var logic [79:0] x);
    logic [79:0] y;
    y = x;
    for (int unsigned d = 0; d < 20; d++) if (x[d*4 +: 4] >= 4'd5) y[d*4 +: 4] = x[d*4 +: 4] + 4'd3;
    correct = y;
  endfunction
  assign corrected = correct(bcd_q);

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
endmodule
`default_nettype wire
`endif
