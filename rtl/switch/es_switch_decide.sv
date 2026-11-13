// ============================================================================
//  File        : es_switch_decide.sv
//  Description : S3 - one combinational forwarding decision per CAM lane,
//                followed by the E203-style valid/ready stage register.
//
//                A frame whose resulting mask is zero is NOT dropped here.
//                Its bytes are still sitting in the ingress byte FIFO and MUST
//                be drained by the TX writer, otherwise the next frame on that
//                port would be read from the wrong offset.  The decision is
//                therefore published on every frame; a zero mask simply means "read
//                and discard".
//
//                Switch-domain style (AGENTS.md 3.3.1): no procedural block
//                in this file - the per-lane stage registers are es_mems_reg_bank
//                instances and everything else is a `logic`/`assign` cloud.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_DECIDE_SV
`define ES_SWITCH_DECIDE_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_switch_decide #(
  parameter int unsigned   NUM_PORTS   = 4,
  parameter logic [1:0]    FLOOD_MODE  = 2'd1
) (
  input  var logic                                    clk_i,
  input  var logic                                    rst_ni,

  input  var logic [NUM_PORTS-1:0]                    i_valid,
  output      logic [NUM_PORTS-1:0]                   i_ready,
  input  var logic [NUM_PORTS*sw_pl_cam_w(NUM_PORTS)-1:0] i_pkg,

  output      logic [NUM_PORTS-1:0]                   o_valid,
  input  var logic [NUM_PORTS-1:0]                    o_ready,
  output      logic [NUM_PORTS*(NUM_PORTS+SW_LEN_W)-1:0] o_pkg
);

  localparam int unsigned PW       = sw_port_w(NUM_PORTS);
  localparam int unsigned CAM_W    = sw_pl_cam_w(NUM_PORTS);
  localparam int unsigned LW       = NUM_PORTS + SW_LEN_W;
  localparam int unsigned DST_LSB  = sw_pl_desc_dstm_lsb(NUM_PORTS);
  localparam int unsigned LEN_LSB  = sw_pl_desc_len_lsb(NUM_PORTS);
  localparam int unsigned HIT_LSB  = sw_pl_cam_hit_lsb(NUM_PORTS);
  localparam int unsigned PORT_LSB = sw_pl_cam_port_lsb(NUM_PORTS);

  /// Pure function: the forwarding policy per lane.
  function automatic logic [NUM_PORTS-1:0] decide_mask(
      input logic [47:0]              dst,
      input logic [PW-1:0]            src_port,
      input logic                     hit,
      input logic [NUM_PORTS-1:0]     port_mask);
    logic [NUM_PORTS-1:0] all_but_src;
    logic [NUM_PORTS-1:0] m;
    all_but_src = ~(NUM_PORTS'(1) << src_port);
    m = '0;
    if (dst == SW_MAC_BROADCAST) begin
      m = all_but_src;
    end else if (sw_is_group(dst)) begin
      if (FLOOD_MODE == SW_FLOOD_ALL) m = all_but_src;
    end else if (hit) begin
      m = port_mask & all_but_src;
    end else begin
      if (FLOOD_MODE != SW_FLOOD_BCAST_ONLY) m = all_but_src;
    end
    decide_mask = m;
  endfunction

  genvar gp;

  generate
    for (gp = 0; gp < NUM_PORTS; gp++) begin : g_lane
      logic              vld_q;
      logic [LW-1:0]     dat_q;
      logic              vld_set;
      logic              vld_clr;
      logic [NUM_PORTS-1:0] mask;
      logic [LW-1:0]     dat_d;

      assign mask = decide_mask(
          i_pkg[gp*CAM_W + DST_LSB +: 48],
          i_pkg[gp*CAM_W +: PW],
          i_pkg[gp*CAM_W + HIT_LSB],
          i_pkg[gp*CAM_W + PORT_LSB +: NUM_PORTS]);

      // Only the egress mask and the frame length are needed downstream;
      // carrying the full descriptor would leave its MAC bits unread at the
      // fabric level and -Wall would report UNUSEDSIGNAL.
      assign dat_d = {mask, i_pkg[gp*CAM_W + LEN_LSB +: SW_LEN_W]};

      assign vld_set       = i_valid[gp] && i_ready[gp];
      assign vld_clr       = o_valid[gp] && o_ready[gp];
      assign i_ready[gp]   = (!vld_q || vld_clr);
      assign o_valid[gp]   = vld_q;
      assign o_pkg[gp*LW +: LW] = dat_q;

      // Valid bit: the E203 pipe-stage set/clear template, held in a one-bit
      // es_mems_reg_bank entry (switch-domain style, AGENTS.md).
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
        .WIDTH (LW),
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

endmodule : es_switch_decide

`default_nettype wire

`endif  // ES_SWITCH_DECIDE_SV
