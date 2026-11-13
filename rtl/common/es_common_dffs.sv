// ============================================================================
//  File        : es_common_dffs.sv
//  Description : Load-enable register primitives for the staged switch
//                pipeline, ported from the E203 `sirv_gnrl_dffs.v` convention.
//
//                Why these exist
//                ---------------
//                A pipeline stage needs two different kinds of register: the
//                valid bit must be reset (otherwise an unknown after power-up
//                looks like a live packet and injects a phantom frame), while
//                the data register must NOT be reset (resetting it would waste
//                reset routing on a wide bus whose contents are meaningless
//                whenever valid is low).  `es_common_pipe_stage` pairs one of
//                each.  This is exactly the dfflr / dffl split in E203.
//
//                Ported differences from E203 (do not reintroduce them):
//                  * no `<= #1` delays - they are simulation-only and ignored
//                    by every synthesis frontend, so they only mask races;
//                  * no `sirv_gnrl_xchecker` SV assertions - `rtl/` forbids
//                    assert/assume/cover;
//                  * synchronous active-low `rst_ni` instead of E203's
//                    asynchronous reset, because this design is single-clock
//                    domain by construction (AGENTS.md 3.3);
//                  * `input var logic` / `logic` only, under
//                    `default_nettype none`.
//
//                `es_common_dffl` deliberately has NO reset.  A data register
//                with no valid bit driving it is never read, so leaving it out
//                of reset is safe and is stated here rather than left implicit.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_COMMON_DFFS_SV
`define ES_COMMON_DFFS_SV

`default_nettype none

// ----------------------------------------------------------------------------
// Load-enable register, synchronous active-low reset to zero.
// ----------------------------------------------------------------------------
module es_common_dfflr #(
  parameter int unsigned WIDTH = 1
) (
  input var logic             clk_i,
  input var logic             rst_ni,
  input var logic             lden_i,
  input var logic [WIDTH-1:0] dnxt_i,
  output    logic [WIDTH-1:0] qout_o
);

  logic [WIDTH-1:0] q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni)   q <= '0;
    else if (lden_i) q <= dnxt_i;
  end

  assign qout_o = q;

endmodule : es_common_dfflr

// ----------------------------------------------------------------------------
// Load-enable register with no reset.  Data is qualified by the companion
// valid bit in `es_common_pipe_stage`, so its value while invalid is a
// don't-care; not resetting it is a deliberate area/routing decision.
// ----------------------------------------------------------------------------
module es_common_dffl #(
  parameter int unsigned WIDTH = 1
) (
  input var logic             clk_i,
  input var logic             lden_i,
  input var logic [WIDTH-1:0] dnxt_i,
  output    logic [WIDTH-1:0] qout_o
);

  logic [WIDTH-1:0] q;

  always_ff @(posedge clk_i) begin
    if (lden_i) q <= dnxt_i;
  end

  assign qout_o = q;

endmodule : es_common_dffl

// ----------------------------------------------------------------------------
// Load-enable register, synchronous active-low reset to all ones.  Used when
// a stage needs a "not yet initialised" sentinel rather than zero.
// ----------------------------------------------------------------------------
module es_common_dfflrs #(
  parameter int unsigned WIDTH = 1
) (
  input var logic             clk_i,
  input var logic             rst_ni,
  input var logic             lden_i,
  input var logic [WIDTH-1:0] dnxt_i,
  output    logic [WIDTH-1:0] qout_o
);

  logic [WIDTH-1:0] q;

  always_ff @(posedge clk_i) begin
    if (!rst_ni)   q <= '1;
    else if (lden_i) q <= dnxt_i;
  end

  assign qout_o = q;

endmodule : es_common_dfflrs

// Hand the nettype default back.
`default_nettype wire

`endif  // ES_COMMON_DFFS_SV
