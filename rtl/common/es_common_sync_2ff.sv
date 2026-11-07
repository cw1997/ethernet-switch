// ============================================================================
//  File        : es_common_sync_2ff.sv
//  Description : Two-stage input sampler; no debounce or pulse stretching.
//                Both stages use clk_i and synchronous active-low rst_ni.
//                Each bit is sampled independently: a multi-bit input is not
//                guaranteed to arrive as one coherent word.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_COMMON_SYNC_2FF_SV
`define ES_COMMON_SYNC_2FF_SV

`default_nettype none

module es_common_sync_2ff #(
  /// Number of independently sampled input bits.
  parameter int unsigned WIDTH = 1,
  /// Synchronous reset value for both sampling stages.
  parameter logic [WIDTH-1:0] RESET_VALUE = '1
) (
  /// Clock and synchronous active-low reset for both sampling stages.
  input var logic clk_i, rst_ni,
  /// Independently sampled asynchronous bits; this is not a coherent bus CDC.
  input var logic [WIDTH-1:0] async_i,
  /// Input vector after two rising edges in the clk_i domain.
  output    logic [WIDTH-1:0] sync_o);

  // --------------------------------------------------------------------------
  // Sampling stages
  //
  // The first stage can sample an input near its transition; downstream logic
  // sees only the second stage and must tolerate the sampling latency.  There
  // is deliberately no third stage and no edge detector here: a caller that
  // needs one builds it on `sync_o`, where the metastability window is closed.
  // --------------------------------------------------------------------------
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

`endif  // ES_COMMON_SYNC_2FF_SV
