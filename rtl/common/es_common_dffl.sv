// ============================================================================
//  File        : es_common_dffl.sv
//  Description : Load-enable register with NO reset: data is qualified by a companion valid bit.
//
//                Load-enable register primitive ported from the E203
//                `sirv_gnrl_dffs.v` convention: no delays, no SV assertions,
//                synchronous active-low `rst_ni`, `input var logic` / `logic`
//                only under `default_nettype none`.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_COMMON_DFFL_SV
`define ES_COMMON_DFFL_SV

`default_nettype none

module es_common_dffl #(
  parameter int unsigned WIDTH = 1
) (
  input  var logic             clk_i,  ///< core clock
  input  var logic             lden_i,  ///< load enable
  input  var logic [WIDTH-1:0] dnxt_i,  ///< next value
  output     logic [WIDTH-1:0] qout_o  ///< held value
);

  logic [WIDTH-1:0] q;

  always_ff @(posedge clk_i) begin
    if (lden_i) q <= dnxt_i;
  end

  assign qout_o = q;

endmodule : es_common_dffl

`default_nettype wire

`endif  // ES_COMMON_DFFL_SV
