// ============================================================================
//  File        : es_common_sync_2ff.sv
//  Description : Two-stage input sampler; no debounce or pulse stretching.
//                Single clk_i domain; synchronous active-low rst_ni where present.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_COMMON_SYNC_2FF_SV
`define ES_COMMON_SYNC_2FF_SV
`default_nettype none
module es_common_sync_2ff #(
  /// Word width in bits (key/sampler width is the number of input bits).
  parameter int unsigned WIDTH = 1,
  /// Synchronous reset/clear contents for each word.
  parameter logic [WIDTH-1:0] RESET_VALUE = '1
) (
  input var logic clk_i, rst_ni,
  input var logic [WIDTH-1:0] async_i,
  output logic [WIDTH-1:0] sync_o
);
  logic [WIDTH-1:0] meta_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      meta_q <= RESET_VALUE;
      sync_o <= RESET_VALUE;
    end else begin
      meta_q <= async_i;
      sync_o <= meta_q;
    end
  end
endmodule : es_common_sync_2ff
`default_nettype wire
`endif // ES_COMMON_SYNC_2FF_SV
