// ============================================================================
//  File        : es_common_pipe_stage.sv
//  Description : Parameterised valid/ready pipeline register, the structural
//                primitive every stage of the switch datapath is built from.
//
//                Why this shape (E203 `sirv_gnrl_pipe_stage` convention)
//                -------------------------------------------------------
//                A single registered stage must be able to accept a new item
//                in the very same clock that its current item leaves, or a
//                fully pipelined stream would insert a bubble every other
//                beat.  The valid bit therefore follows the E203 template
//
//                    vld_set = i_valid & i_ready
//                    vld_clr = o_valid & o_ready
//                    vld_ena = vld_set | vld_clr
//                    vld_nxt = vld_set | (~vld_clr)
//                    i_ready = (~vld_r) | vld_clr
//
//                and the data register is loaded only on `vld_set` and is not
//                reset.  `CUT_READY` drops the `| vld_clr` term to cut a long
//                ready combinational chain at the cost of one bubble per item.
//
//                `DP` instances the stage `DP` times (DP == 0 is a pure
//                combinational bypass, which is what makes the depth a
//                configuration surface rather than a rewrite).  The inter-
//                stage buses are PACKED vectors with constant part-selects in
//                a generate loop: Icarus silently returns stale data for a
//                run-time-indexed unpacked array (AGENTS.md 3.1), and a
//                loop-indexed store into one is dropped outright (3.3).
//
//                Flush
//                -----
//                `flush_req_i` clears every stage's valid bit.  `i_ready` is
//                gated low on a flush clock as well, otherwise the upstream
//                would see a handshake on a beat whose data is thrown away -
//                a lost packet that no testbench at the pins can distinguish
//                from a bad frame.  `flush_ack_o` is a single-cycle pulse.
//
//                No delays, no assertions, no initial blocks, no latches:
//                see es_common_dffs.sv and AGENTS.md 2.1 / 3.4.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_COMMON_PIPE_STAGE_SV
`define ES_COMMON_PIPE_STAGE_SV

`default_nettype none

module es_common_pipe_stage #(
  /// 1 cuts the ready chain (one bubble per item, better timing on a long
  /// fabric); 0 allows back-to-back items with no bubble.
  parameter int unsigned CUT_READY = 0,
  /// Number of register stages; 0 is a combinational bypass.
  parameter int unsigned DP        = 1,
  /// Width of the packed payload.  Pack sideband fields into `i_dat` at the
  /// caller; there is deliberately no struct here (yosys rejects package
  /// items in port ranges, AGENTS.md 2.1).
  parameter int unsigned DW        = 32,
  /// 0 disables the flush port explicitly rather than by an unreachable
  /// threshold (AGENTS.md 3.2).
  parameter int unsigned FLUSH_EN  = 0
) (
  input  var logic             clk_i,
  input  var logic             rst_ni,

  input  var logic             i_valid,
  output      logic            i_ready,
  input  var logic [DW-1:0]    i_dat,

  output      logic            o_valid,
  input  var logic             o_ready,
  output      logic [DW-1:0]   o_dat,

  input  var logic             flush_req_i,
  output      logic            flush_ack_o
);

  logic flush_now;
  assign flush_now    = (FLUSH_EN != 0) && flush_req_i;
  assign flush_ack_o  = (FLUSH_EN != 0) ? flush_req_i : 1'b0;

  genvar g;

  generate
    if (DP == 0) begin : g_bypass
      assign o_valid = i_valid;
      assign i_ready = o_ready;
      assign o_dat   = i_dat;
    end else begin : g_pipe

      // v[k]  : valid presented to stage k (v[0] is the module input,
      //         v[DP] is the module output).
      // r[k]  : ready presented by stage k to its producer (r[DP] is the
      //         module's downstream ready).
      // d[k]  : DW-bit payload at the same boundary.
      logic [DP:0]                  v;
      logic [DP:0]                  r;
      logic [(DP+1)*DW-1:0]         d;

      assign v[0]        = i_valid;
      assign d[DW-1:0]   = i_dat;
      assign r[DP]       = o_ready;
      assign i_ready     = r[0];
      assign o_valid     = v[DP];
      assign o_dat       = d[DP*DW +: DW];

      for (g = 0; g < DP; g++) begin : g_stage
        logic             vld_r;
        logic [DW-1:0]    dat_r;
        logic             vld_set;
        logic             vld_clr;
        logic             vld_ena;
        logic             vld_nxt;

        assign vld_set = v[g] & r[g];
        assign vld_clr = v[g+1] & r[g+1];
        // Flush is expressed through the same load-enable/next-value pair as
        // a normal handshake, so the valid register (es_common_dfflr) is
        // genuinely cleared.  Gating ready alone is NOT enough: without this
        // the in-flight items simply drain out over the next DP clocks and a
        // discarded frame would still be transmitted.
        assign vld_ena = vld_set | vld_clr | flush_now;
        assign vld_nxt = flush_now ? 1'b0 : (vld_set | (~vld_clr));

        es_common_dfflr #(.WIDTH(1)) u_vld (
          .clk_i  (clk_i),
          .rst_ni (rst_ni),
          .lden_i (vld_ena),
          .dnxt_i (vld_nxt),
          .qout_o (vld_r)
        );

        es_common_dffl #(.WIDTH(DW)) u_dat (
          .clk_i  (clk_i),
          .lden_i (vld_set),
          .dnxt_i (d[g*DW +: DW]),
          .qout_o (dat_r)
        );

        assign v[g+1]                  = vld_r;
        assign d[(g+1)*DW +: DW]       = dat_r;
        // A flush clock must not accept anything: gating ready here is what
        // keeps the upstream's valid alive for the next clock.
        assign r[g] = (~flush_now) &
                      ((CUT_READY != 0) ? (~vld_r) : ((~vld_r) | vld_clr));
      end
    end
  endgenerate

endmodule : es_common_pipe_stage

// Hand the nettype default back.
`default_nettype wire

`endif  // ES_COMMON_PIPE_STAGE_SV
