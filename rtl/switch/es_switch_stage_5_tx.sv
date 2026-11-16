// ============================================================================
//  File        : es_switch_stage_5_tx.sv
//  Description : One egress lane. Exposes a frame only after EOF has been written.
//                Whole-frame credits let the writer run through EOF.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_SWITCH_STAGE_5_TX_SV
`define ES_SWITCH_STAGE_5_TX_SV
`default_nettype none
`include "es_defs.sv"
`default_nettype none

module es_switch_stage_5_tx #(
  parameter int unsigned MAX_FRAME_LEN  = 1518,
  parameter int unsigned TX_QUEUE_DEPTH = 256
) (
  input var logic clk_i,
  rst_ni,
  input var logic wr_i,
  sof_i,
  eof_i,
  input var logic [7:0] data_i,
  output logic [sw_pl_fifo_cnt_w(sw_pl_tx_depth(TX_QUEUE_DEPTH, MAX_FRAME_LEN))-1:0] free_o,
  output logic b_valid_o,
  b_sof_o,
  b_eof_o,
  input var logic b_ready_i,
  output logic [7:0] b_data_o
);
  localparam int unsigned DEPTH = sw_pl_tx_depth(TX_QUEUE_DEPTH, MAX_FRAME_LEN);
  localparam int unsigned CW = sw_pl_fifo_cnt_w(DEPTH);

  logic full, empty, write_byte, read_byte, commit, finish;
  logic [CW-1:0] frames_q, frames_d;
  assign write_byte = wr_i && !full;
  assign b_valid_o = !empty && (frames_q != '0);
  assign read_byte = b_valid_o && b_ready_i;
  assign commit = write_byte && eof_i;
  assign finish = read_byte && b_eof_o;
  assign frames_d = commit ? frames_q + CW'(1) : frames_q - CW'(1);
  es_mems_reg_bank #(
    .WIDTH (CW),
    .DEPTH (1)
  ) u_frames_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (1'b0),
    .wr_en_i   (commit ^ finish),
    .wr_data_i (frames_d),
    .data_o    (frames_q)
  );

  es_mems_sync_fifo #(
    .WIDTH (10),
    .DEPTH (DEPTH)
  ) u_queue (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .undo_i     (1'b0),
    .undo_cnt_i (CW'(0)),
    .flush_i    (1'b0),
    .wr_en_i    (write_byte),
    .wr_data_i  ({sof_i, eof_i, data_i}),
    .full_o     (full),
    .free_o     (free_o),
    .rd_en_i    (read_byte),
    .rd_data_o  ({b_sof_o, b_eof_o, b_data_o}),
    .empty_o    (empty)
  );
endmodule

`default_nettype wire
`endif
