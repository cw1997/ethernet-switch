// ============================================================================
//  File        : es_mems_reg_bank.sv
//  Description : Parallel register bank; entry zero is the least-significant word.
//                All entries share clk_i and a synchronous active-low reset.
//                Reset and clear take priority over independent word writes.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_MEMS_REG_BANK_SV
`define ES_MEMS_REG_BANK_SV
`default_nettype none
module es_mems_reg_bank #(
  /// Word width in bits.
  parameter int unsigned WIDTH = 32,
  /// Number of independently writable entries.
  parameter int unsigned DEPTH = 16,
  /// Synchronous reset/clear contents for each word.
  parameter logic [WIDTH-1:0] RESET_VALUE = '0
) (
  /// Clock, synchronous active-low reset, and synchronous bank-wide clear.
  input var logic clk_i, rst_ni, clear_i,
  /// Per-entry write enables and packed words; entry zero occupies the low slice.
  input var logic [DEPTH-1:0] wr_en_i,
  input var logic [DEPTH*WIDTH-1:0] wr_data_i,
  /// Packed register contents, with entry zero in the least-significant slice.
  output    logic [DEPTH*WIDTH-1:0] data_o);
  genvar g;
  generate
    for (g = 0; g < DEPTH; g++) begin : g_entry
      logic [WIDTH-1:0] value_q, write_word;
      // Icarus needs a plain word at each per-entry nonblocking store; the
      // generated constant slice supplies it before the clocked process.
      assign write_word = wr_data_i[g*WIDTH +: WIDTH];
      always_ff @(posedge clk_i) begin
        if (!rst_ni) value_q <= RESET_VALUE;
        else if (clear_i) value_q <= RESET_VALUE;
        else if (wr_en_i[g]) value_q <= write_word;
      end
      assign data_o[g*WIDTH +: WIDTH] = value_q;
    end
  endgenerate
endmodule : es_mems_reg_bank
`default_nettype wire
`endif // ES_MEMS_REG_BANK_SV
