// ============================================================================
//  File        : es_switch_fabric.sv
//  Description : Composition root of the staged, pure-switching datapath.
//
//                Level graph (every level carries its own valid/ready register
//                in the E203 pipe-stage style, so about five frames can be in
//                flight at once and all NUM_PORTS receive engines run in
//                parallel - the legacy global single-frame arbiter is gone):
//
//                  N x rx_engine  -> cam_stage -> N x decide -> tx_writer
//                       ^              ^  ^
//                       |              |  +-- es_switch_cam_table
//                  frame_buf       same-clock lookup + learn
//                       |
//                       +--------------------> tx_writer byte read ports
//                                              -> N x tx_engine -> MAC
//
//                There is deliberately no status, statistics, console, panel,
//                LED or DIP port.  FLOOD_MODE and LEARNING_EN are elaboration
//                parameters; link_up_i is a data gate, not an observability
//                surface.
//
//                Inter-level packages are packed vectors with `localparam`
//                widths; no struct, interface or package (yosys would reject
//                a package item in a port range).  The CAM, decide and writer
//                levels each own their register stage, so an extra
//                es_common_pipe_stage between them would only add latency;
//                the primitive stays in the tree (regression-tested by
//                sw_pipe_stage_tb) for timing repair if a level ever needs a
//                deeper ready cut.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_FABRIC_SV
`define ES_SWITCH_FABRIC_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_switch_fabric #(
  parameter int unsigned NUM_PORTS       = 4,
  parameter logic [NUM_PORTS*48-1:0] PORT_MAC = '0,
  parameter int unsigned MIN_FRAME_LEN   = 64,
  parameter int unsigned MAX_FRAME_LEN   = 1518,
  parameter int unsigned SLOTS           = 2,
  parameter int unsigned SLOT_BYTES      = 2048,
  parameter int unsigned DESC_DEPTH      = 8,
  parameter int unsigned TX_QUEUE_DEPTH  = 256,
  parameter int unsigned CAM_SETS        = 128,
  parameter int unsigned CAM_WAYS        = 4,
  parameter int unsigned LEARNING_EN     = 1,
  parameter logic [1:0]  FLOOD_MODE      = 2'd1
) (
  input  var logic                       clk_i,
  input  var logic                       rst_ni,
  input  var logic [NUM_PORTS-1:0]       link_up_i,

  // ---- 8-bit byte streams from the N MAC adapters -----------------------
  input  var logic [NUM_PORTS-1:0]       rx_valid_i,
  output      logic [NUM_PORTS-1:0]      rx_ready_o,
  input  var logic [NUM_PORTS*8-1:0]     rx_data_i,
  input  var logic [NUM_PORTS-1:0]       rx_sof_i,
  input  var logic [NUM_PORTS-1:0]       rx_eof_i,
  input  var logic [NUM_PORTS-1:0]       rx_err_i,

  // ---- 8-bit byte streams toward the N MAC adapters ---------------------
  output      logic [NUM_PORTS-1:0]      tx_valid_o,
  input  var logic [NUM_PORTS-1:0]       tx_ready_i,
  output      logic [NUM_PORTS*8-1:0]    tx_data_o,
  output      logic [NUM_PORTS-1:0]      tx_sof_o,
  output      logic [NUM_PORTS-1:0]      tx_eof_o
);

  localparam int unsigned DESC_W   = sw_pl_desc_w(NUM_PORTS);
  localparam int unsigned CAM_W    = sw_pl_cam_w(NUM_PORTS);
  localparam int unsigned LW       = NUM_PORTS + SW_LEN_W;

  // ---- level-to-level busses --------------------------------------------
  logic [NUM_PORTS-1:0]           rx_desc_valid;
  logic [NUM_PORTS-1:0]           rx_desc_ready;
  logic [NUM_PORTS*DESC_W-1:0]    rx_desc;

  logic [NUM_PORTS-1:0]           cam_valid;
  logic [NUM_PORTS-1:0]           cam_ready;
  logic [NUM_PORTS*CAM_W-1:0]     cam_pkg;

  logic [NUM_PORTS-1:0]           dec_valid;
  logic [NUM_PORTS-1:0]           dec_ready;
  logic [NUM_PORTS*LW-1:0]        dec_pkg;

  logic [NUM_PORTS-1:0]           buf_rd_en;
  logic [NUM_PORTS*8-1:0]         buf_rd_data;
  logic [NUM_PORTS-1:0]           buf_empty;

  logic [NUM_PORTS-1:0]           tx_wr_ready;
  logic [NUM_PORTS-1:0]           tx_wr_en;
  logic [NUM_PORTS*8-1:0]         tx_wr_data;
  logic [NUM_PORTS-1:0]           tx_wr_sof;
  logic [NUM_PORTS-1:0]           tx_wr_eof;

  logic [NUM_PORTS-1:0]           rx_gated_valid;

  genvar g;

  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_port
      // link_up_i is a data gate; a down port cannot inject bytes.
      assign rx_gated_valid[g] = rx_valid_i[g] && link_up_i[g];

      es_switch_rx_engine #(
        .NUM_PORTS     (NUM_PORTS),
        .PORT_ID       (g),
        .PORT_MAC      (PORT_MAC[g*48 +: 48]),
        .MIN_FRAME_LEN (MIN_FRAME_LEN),
        .MAX_FRAME_LEN (MAX_FRAME_LEN),
        .SLOTS         (SLOTS),
        .SLOT_BYTES    (SLOT_BYTES),
        .DESC_DEPTH    (DESC_DEPTH)
      ) u_rx (
        .clk_i    (clk_i),
        .rst_ni   (rst_ni),
        .b_valid_i(rx_gated_valid[g]), .b_ready_o(rx_ready_o[g]),
        .b_data_i (rx_data_i[g*8 +: 8]), .b_sof_i(rx_sof_i[g]),
        .b_eof_i  (rx_eof_i[g]),       .b_err_i (rx_err_i[g]),
        .dvalid_o (rx_desc_valid[g]),  .drd_i   (rx_desc_ready[g]),
        .dout_o   (rx_desc[g*DESC_W +: DESC_W]),
        .brd_i    (buf_rd_en[g]),      .bout_o  (buf_rd_data[g*8 +: 8]),
        .bempty_o (buf_empty[g])
      );

      es_switch_tx_engine #(
        .TX_QUEUE_DEPTH (TX_QUEUE_DEPTH)
      ) u_tx (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .wr_en_i   (tx_wr_en[g]),   .wr_data_i(tx_wr_data[g*8 +: 8]),
        .wr_sof_i  (tx_wr_sof[g]),  .wr_eof_i (tx_wr_eof[g]),
        .wr_ready_o(tx_wr_ready[g]),
        .b_valid_o (tx_valid_o[g]), .b_ready_i(tx_ready_i[g]),
        .b_data_o  (tx_data_o[g*8 +: 8]), .b_sof_o(tx_sof_o[g]),
        .b_eof_o   (tx_eof_o[g])
      );
    end
  endgenerate

  es_switch_cam_stage #(
    .NUM_PORTS   (NUM_PORTS),
    .NUM_SETS    (CAM_SETS),
    .NUM_WAYS    (CAM_WAYS),
    .LEARNING_EN (LEARNING_EN)
  ) u_cam_stage (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .d_i_valid (rx_desc_valid),
    .d_i_ready (rx_desc_ready),
    .d_i_desc  (rx_desc),
    .o_valid   (cam_valid),
    .o_ready   (cam_ready),
    .o_pkg     (cam_pkg)
  );

  es_switch_decide #(
    .NUM_PORTS  (NUM_PORTS),
    .FLOOD_MODE (FLOOD_MODE)
  ) u_decide (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .i_valid (cam_valid),
    .i_ready (cam_ready),
    .i_pkg   (cam_pkg),
    .o_valid (dec_valid),
    .o_ready (dec_ready),
    .o_pkg   (dec_pkg)
  );

  es_switch_tx_writer #(
    .NUM_PORTS (NUM_PORTS)
  ) u_writer (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .i_valid     (dec_valid),
    .i_ready     (dec_ready),
    .i_pkg       (dec_pkg),
    .buf_rd_en   (buf_rd_en),
    .buf_rd_data (buf_rd_data),
    .buf_empty   (buf_empty),
    .tx_ready    (tx_wr_ready),
    .tx_wr_en    (tx_wr_en),
    .tx_wr_data  (tx_wr_data),
    .tx_wr_sof   (tx_wr_sof),
    .tx_wr_eof   (tx_wr_eof)
  );

endmodule : es_switch_fabric

`default_nettype wire

`endif  // ES_SWITCH_FABRIC_SV
