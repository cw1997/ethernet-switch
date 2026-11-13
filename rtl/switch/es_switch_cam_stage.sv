// ============================================================================
//  File        : es_switch_cam_stage.sv
//  Description : S2 - NUM_PORTS independent pipeline lanes, each issuing a
//                destination lookup and a source learn in the SAME clock.
//
//                The lookup is combinational over the current CAM contents
//                (read-first); the learn is written on that clock edge.  The
//                descriptor is captured into the stage register on the same
//                edge, so the output package carries the verdict that
//                belonged to its own frame.
//
//                The valid/ready register is the E203 pipe-stage template
//                (vld_set / vld_clr / vld_ena / vld_nxt) written out per lane
//                in a generate loop, with the two lane registers held in
//                es_mems_reg_bank instances.  Switch-domain style (AGENTS.md
//                3.3.1): no procedural block in this file, and local registers
//                per lane
//                avoid both a multi-driven packed vector and a loop-indexed
//                store into an unpacked array.
//
//                Backpressure: a lane whose learn was refused by the CAM
//                (same bucket, no free way) keeps its input valid asserted and
//                simply lowers ready for that clock.  No learn is ever
//                silently dropped.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_CAM_STAGE_SV
`define ES_SWITCH_CAM_STAGE_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_switch_cam_stage #(
  parameter int unsigned NUM_PORTS   = 4,
  parameter int unsigned NUM_SETS    = 128,
  parameter int unsigned NUM_WAYS    = 4,
  parameter int unsigned LEARNING_EN = 1
) (
  input  var logic                                    clk_i,
  input  var logic                                    rst_ni,

  // ---- descriptors from the N receive engines ---------------------------
  input  var logic [NUM_PORTS-1:0]                    d_i_valid,
  output      logic [NUM_PORTS-1:0]                   d_i_ready,
  input  var logic [NUM_PORTS*sw_pl_desc_w(NUM_PORTS)-1:0] d_i_desc,

  // ---- packages toward the decide level ---------------------------------
  output      logic [NUM_PORTS-1:0]                   o_valid,
  input  var logic [NUM_PORTS-1:0]                    o_ready,
  output      logic [NUM_PORTS*sw_pl_cam_w(NUM_PORTS)-1:0] o_pkg
);

  localparam int unsigned PW        = sw_port_w(NUM_PORTS);
  localparam int unsigned DESC_W    = sw_pl_desc_w(NUM_PORTS);
  localparam int unsigned CAM_W     = sw_pl_cam_w(NUM_PORTS);
  localparam int unsigned DST_LSB   = sw_pl_desc_dstm_lsb(NUM_PORTS);
  localparam int unsigned SRC_LSB   = sw_pl_desc_srcm_lsb(NUM_PORTS);

  logic [NUM_PORTS-1:0]                 req;
  logic [NUM_PORTS*48-1:0]              lookup_mac;
  logic [NUM_PORTS-1:0]                 hit;
  logic [NUM_PORTS*PW-1:0]              hit_port;
  logic [NUM_PORTS-1:0]                 learn;
  logic [NUM_PORTS*48-1:0]              learn_mac;
  logic [NUM_PORTS*PW-1:0]              learn_port;
  logic [NUM_PORTS-1:0]                 learn_ready;
  logic [NUM_PORTS-1:0]                 grant_ok;

  genvar gp;

  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_lane
      logic              vld_q;
      logic [CAM_W-1:0]  dat_q;
      logic              vld_set;
      logic              vld_clr;
      logic [NUM_PORTS-1:0] port_mask;
      logic [CAM_W-1:0]  dat_d;

      assign req[gp]        = d_i_valid[gp];
      assign lookup_mac[gp*48 +: 48] =
          d_i_desc[gp*DESC_W + DST_LSB +: 48];
      assign learn[gp]      = d_i_valid[gp] && (LEARNING_EN != 0);
      assign learn_mac[gp*48 +: 48] =
          d_i_desc[gp*DESC_W + SRC_LSB +: 48];
      // src_port is the descriptor's low field; using it rather than the lane
      // index keeps the CAM independent of how the core wires its lanes.
      assign learn_port[gp*PW +: PW] = d_i_desc[gp*DESC_W +: PW];

      // Binary port index from the CAM -> one-hot egress mask.  Both operands
      // are NUM_PORTS bits wide, so no implicit 32-bit extension occurs.
      assign port_mask = hit[gp] ? (NUM_PORTS'(1) << hit_port[gp*PW +: PW])
                                 : '0;
      assign dat_d = {port_mask, hit[gp], d_i_desc[gp*DESC_W +: DESC_W]};

      assign grant_ok[gp]   = (LEARNING_EN != 0) ? learn_ready[gp] : 1'b1;
      assign vld_set        = d_i_valid[gp] && d_i_ready[gp];
      assign vld_clr        = o_valid[gp] && o_ready[gp];
      assign d_i_ready[gp]  = grant_ok[gp] && (!vld_q || vld_clr);
      assign o_valid[gp]    = vld_q;
      assign o_pkg[gp*CAM_W +: CAM_W] = dat_q;

      // Valid bit: the E203 pipe-stage set/clear template, held in a one-bit
      // es_mems_reg_bank entry (switch-domain style, AGENTS.md 3.3.1).
      es_mems_reg_bank #(
        .WIDTH       (1),
        .DEPTH       (1),
        .RESET_VALUE ('0)
      ) u_vld_q (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .clear_i   (1'b0),
        .wr_en_i   (vld_set || vld_clr),
        .wr_data_i (vld_set | (~vld_clr)),
        .data_o    (vld_q)
      );

      // Data payload is not reset: it is meaningless while vld_q is low,
      // which is exactly the E203 dffl convention.  The bank's rst_ni is
      // therefore deliberately tied high and its clear low.
      es_mems_reg_bank #(
        .WIDTH (CAM_W),
        .DEPTH (1)
      ) u_dat_q (
        .clk_i     (clk_i),
        .rst_ni    (1'b1),
        .clear_i   (1'b0),
        .wr_en_i   (vld_set),
        .wr_data_i (dat_d),
        .data_o    (dat_q)
      );
    end
  endgenerate

  es_switch_cam_table #(
    .NUM_PORTS (NUM_PORTS),
    .NUM_SETS  (NUM_SETS),
    .NUM_WAYS  (NUM_WAYS)
  ) u_cam (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .req_i          (req),
    .mac_i          (lookup_mac),
    .hit_o          (hit),
    .port_o         (hit_port),
    .learn_i        (learn),
    .learn_mac_i    (learn_mac),
    .learn_port_i   (learn_port),
    .learn_ready_o  (learn_ready)
  );

endmodule : es_switch_cam_stage

`default_nettype wire

`endif  // ES_SWITCH_CAM_STAGE_SV
