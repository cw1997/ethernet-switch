// ============================================================================
//  File        : es_switch_fabric.sv
//  Description : Connects the five switch stages over per-ingress packed
//                descriptors and the per-egress byte queues. The fabric uses
//                one core clock and synchronous active-low reset.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_FABRIC_SV
`define ES_SWITCH_FABRIC_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_switch_fabric #(
  parameter int unsigned NUM_PORTS            = 4,
  parameter logic [NUM_PORTS*48-1:0] PORT_MAC = '0,
  parameter int unsigned MIN_FRAME_LEN        = SW_PL_MIN_WIRE_CLIENT,
  parameter int unsigned MAX_FRAME_LEN        = 1518,
  parameter int unsigned SLOTS                = 2,
  parameter int unsigned SLOT_BYTES           = 2048,
  parameter int unsigned DESC_DEPTH           = 8,
  parameter int unsigned TX_QUEUE_DEPTH       = 256,
  parameter int unsigned CAM_SETS             = 128,
  parameter int unsigned CAM_WAYS             = 4,
  parameter int unsigned LEARNING_EN          = 1,
  parameter logic [1:0] FLOOD_MODE            = 2'd1
) (
  input  var logic                    clk_i,
  input  var logic                    rst_ni,
  input  var logic [NUM_PORTS-1:0]    link_up_i,

  // ---- 8-bit byte streams from the N MAC adapters -----------------------
  input  var logic [NUM_PORTS-1:0]    rx_valid_i,
  output logic     [NUM_PORTS-1:0]    rx_ready_o,
  input  var logic [NUM_PORTS*8-1:0]  rx_data_i,
  input  var logic [NUM_PORTS-1:0]    rx_sof_i,
  input  var logic [NUM_PORTS-1:0]    rx_eof_i,
  input  var logic [NUM_PORTS-1:0]    rx_err_i,
  input  var logic [NUM_PORTS*32-1:0] rx_fcs_i,

  // ---- 8-bit byte streams toward the N MAC adapters ---------------------
  output logic     [NUM_PORTS-1:0]    tx_valid_o,
  input  var logic [NUM_PORTS-1:0]    tx_ready_i,
  output logic     [NUM_PORTS*8-1:0]  tx_data_o,
  output logic     [NUM_PORTS-1:0]    tx_sof_o,
  output logic     [NUM_PORTS-1:0]    tx_eof_o
);

  localparam int unsigned RAW_W = sw_pl_rx_desc_w(NUM_PORTS);
  localparam int unsigned DESC_W = sw_pl_desc_w(NUM_PORTS);
  localparam int unsigned CW = sw_pl_fifo_cnt_w(sw_pl_tx_depth(TX_QUEUE_DEPTH, MAX_FRAME_LEN));

  logic [NUM_PORTS-1:0] rx_valid, rx_ready, val_valid, val_ready;
  logic [NUM_PORTS-1:0] crc_valid, crc_ready;
  logic [NUM_PORTS*RAW_W-1:0] rx_desc, val_desc;
  logic [NUM_PORTS*DESC_W-1:0] crc_desc;
  logic [NUM_PORTS-1:0] buf_read, buf_empty;
  logic [NUM_PORTS*8-1:0] buf_data, tx_write_data;
  logic [NUM_PORTS-1:0] tx_write, tx_write_sof, tx_write_eof;
  logic [NUM_PORTS*CW-1:0] tx_free;

  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_port
      logic crc_write;
      logic [31:0] crc;
      es_switch_stage_1_rx #(
        .NUM_PORTS     (NUM_PORTS),
        .PORT_ID       (g),
        .MAX_FRAME_LEN (MAX_FRAME_LEN),
        .SLOTS         (SLOTS),
        .SLOT_BYTES    (SLOT_BYTES),
        .DESC_DEPTH    (DESC_DEPTH)
      ) u_rx (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .link_up_i   (link_up_i[g]),
        .b_valid_i   (rx_valid_i[g]),
        .b_ready_o   (rx_ready_o[g]),
        .b_data_i    (rx_data_i[g*8 +: 8]),
        .b_sof_i     (rx_sof_i[g]),
        .b_eof_i     (rx_eof_i[g]),
        .b_err_i     (rx_err_i[g]),
        .b_fcs_i     (rx_fcs_i[g*32 +: 32]),
        .crc_write_o (crc_write),
        .crc_i       (crc),
        .d_valid_o   (rx_valid[g]),
        .d_ready_i   (rx_ready[g]),
        .desc_o      (rx_desc[g*RAW_W +: RAW_W]),
        .rd_i        (buf_read[g]),
        .data_o      (buf_data[g*8 +: 8]),
        .empty_o     (buf_empty[g])
      );

      es_switch_stage_2_validate #(
        .NUM_PORTS     (NUM_PORTS),
        .PORT_ID       (g),
        .PORT_MAC      (PORT_MAC[g*48 +: 48]),
        .MIN_FRAME_LEN (MIN_FRAME_LEN),
        .MAX_FRAME_LEN (MAX_FRAME_LEN)
      ) u_validate (
        .clk_i   (clk_i),
        .rst_ni  (rst_ni),
        .i_valid (rx_valid[g]),
        .i_ready (rx_ready[g]),
        .i_desc  (rx_desc[g*RAW_W +: RAW_W]),
        .o_valid (val_valid[g]),
        .o_ready (val_ready[g]),
        .o_desc  (val_desc[g*RAW_W +: RAW_W])
      );

      es_switch_stage_3_checksum #(
        .NUM_PORTS (NUM_PORTS)
      ) u_checksum (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .crc_write_i (crc_write),
        .crc_sof_i   (rx_sof_i[g]),
        .crc_data_i  (rx_data_i[g*8 +: 8]),
        .crc_o       (crc),
        .i_valid     (val_valid[g]),
        .i_ready     (val_ready[g]),
        .i_desc      (val_desc[g*RAW_W +: RAW_W]),
        .o_valid     (crc_valid[g]),
        .o_ready     (crc_ready[g]),
        .o_desc      (crc_desc[g*DESC_W +: DESC_W])
      );

      es_switch_stage_5_tx #(
        .MAX_FRAME_LEN  (MAX_FRAME_LEN),
        .TX_QUEUE_DEPTH (TX_QUEUE_DEPTH)
      ) u_tx (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .wr_i      (tx_write[g]),
        .sof_i     (tx_write_sof[g]),
        .eof_i     (tx_write_eof[g]),
        .data_i    (tx_write_data[g*8 +: 8]),
        .free_o    (tx_free[g*CW +: CW]),
        .b_valid_o (tx_valid_o[g]),
        .b_ready_i (tx_ready_i[g]),
        .b_data_o  (tx_data_o[g*8 +: 8]),
        .b_sof_o   (tx_sof_o[g]),
        .b_eof_o   (tx_eof_o[g])
      );
    end
  endgenerate

  es_switch_stage_4_lookup #(
    .NUM_PORTS      (NUM_PORTS),
    .CAM_SETS       (CAM_SETS),
    .CAM_WAYS       (CAM_WAYS),
    .LEARNING_EN    (LEARNING_EN),
    .FLOOD_MODE     (FLOOD_MODE),
    .MAX_FRAME_LEN  (MAX_FRAME_LEN),
    .TX_QUEUE_DEPTH (TX_QUEUE_DEPTH)
  ) u_lookup (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .i_valid     (crc_valid),
    .i_ready     (crc_ready),
    .i_desc      (crc_desc),
    .buf_read_o  (buf_read),
    .buf_data_i  (buf_data),
    .buf_empty_i (buf_empty),
    .tx_free_i   (tx_free),
    .tx_write_o  (tx_write),
    .tx_data_o   (tx_write_data),
    .tx_sof_o    (tx_write_sof),
    .tx_eof_o    (tx_write_eof)
  );

endmodule : es_switch_fabric

`default_nettype wire

`endif  // ES_SWITCH_FABRIC_SV
