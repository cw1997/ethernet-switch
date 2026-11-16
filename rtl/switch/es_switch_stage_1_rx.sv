// ============================================================================
//  File        : es_switch_stage_1_rx.sv
//  Description : One ingress lane. Reserves queue space at SOF and publishes one
//                descriptor per admitted frame. Bytes remain ordered until lookup
//                copies or discards them. All transfers use the core clock.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_SWITCH_STAGE_1_RX_SV
`define ES_SWITCH_STAGE_1_RX_SV
`default_nettype none
`include "es_defs.sv"
`default_nettype none

module es_switch_stage_1_rx #(
  parameter int unsigned NUM_PORTS     = 4,
  parameter int unsigned PORT_ID       = 0,
  parameter int unsigned MAX_FRAME_LEN = 1518,
  // octets excluding FCS
  parameter int unsigned SLOTS         = 2,
  parameter int unsigned SLOT_BYTES    = 2048,
  parameter int unsigned DESC_DEPTH    = 8
) (
  input var logic clk_i,
  rst_ni,
  input var logic link_up_i,
  input var logic b_valid_i,
  b_sof_i,
  b_eof_i,
  b_err_i,
  input var logic [7:0] b_data_i,
  input var logic [31:0] b_fcs_i,
  // wire FCS, first octet in bits 7:0
  output logic b_ready_o,
  // The CRC tap qualifies only bytes actually written to the FIFO.
  output logic crc_write_o,
  input var logic [31:0] crc_i,
  output logic d_valid_o,
  input var logic d_ready_i,
  output logic [sw_pl_rx_desc_w(NUM_PORTS)-1:0] desc_o,
  input var logic rd_i,
  output logic [7:0] data_o,
  output logic empty_o
);
  localparam int unsigned PW = sw_port_w(NUM_PORTS);
  localparam int unsigned BYTE_DEPTH = SLOTS * SLOT_BYTES;
  localparam int unsigned BCW = sw_pl_fifo_cnt_w(BYTE_DEPTH);
  localparam int unsigned DCW = sw_pl_fifo_cnt_w(DESC_DEPTH);
  localparam int unsigned DW = sw_pl_rx_desc_w(NUM_PORTS);
  localparam logic [1:0] S_IDLE = 2'd0, S_FRAME = 2'd1, S_DRAIN = 2'd2;

  logic [1:0] state_q, state_d;
  logic [SW_LEN_W-1:0] count_q, count_next, stored_len;
  logic [SW_LEN_W:0] measured_len;
  logic [DCW-1:0] desc_free;
  logic [BCW-1:0] byte_free;
  logic desc_full, desc_empty, byte_full;
  logic start, fire, active, abort_frame, publish, write_byte;
  logic [47:0] dst, src;
  logic [15:0] length_type;
  logic vlan;
  logic [DW-1:0] descriptor;

  assign b_ready_o = (state_q != S_IDLE) ||
      (link_up_i && !desc_full && (desc_free != '0) &&
       !byte_full && (byte_free >= BCW'(MAX_FRAME_LEN)));
  assign start = (state_q == S_IDLE) && b_sof_i && b_valid_i && b_ready_o;
  assign active = (state_q == S_FRAME) || start;
  assign fire = active && b_valid_i;
  assign abort_frame = active && (!link_up_i ||
      (fire && (b_err_i || (count_q == SW_LEN_W'(MAX_FRAME_LEN)))));
  assign publish = abort_frame || (fire && b_eof_i);
  assign write_byte = fire && !abort_frame;
  assign crc_write_o = write_byte;
  assign count_next = count_q + SW_LEN_W'(1);
  assign stored_len = write_byte ? count_next : count_q;
  // On early abort this is the number observed through the failing beat.
  // Only stored_len participates in queue reclamation.
  assign measured_len = {1'b0, count_q} + (SW_LEN_W+1)'(fire);
  assign descriptor = {crc_i, (fire && b_eof_i) ? b_fcs_i : 32'b0,
                       abort_frame, vlan, length_type, measured_len,
                       abort_frame, stored_len, dst, src, stored_len, PW'(PORT_ID)};

  assign state_d = (state_q == S_DRAIN) ?
                       ((b_valid_i && b_eof_i) ? S_IDLE : S_DRAIN) :
                   publish ? ((fire && b_eof_i) ? S_IDLE : S_DRAIN) :
                   start   ? S_FRAME : state_q;
  es_mems_reg_bank #(
    .WIDTH (2),
    .DEPTH (1)
  ) u_state_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (1'b0),
    .wr_en_i   (1'b1),
    .wr_data_i (state_d),
    .data_o    (state_q)
  );
  es_mems_reg_bank #(
    .WIDTH (SW_LEN_W),
    .DEPTH (1)
  ) u_count_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (1'b0),
    .wr_en_i   (publish || write_byte),
    .wr_data_i (publish ? '0 : count_next),
    .data_o    (count_q)
  );

  es_switch_stage_1_rx_parse u_parse (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .byte_fire_i (write_byte),
    .oct_cnt_i   ({1'b0, count_q}),
    .b_data_i    (b_data_i),
    .clear_i     (publish),
    .dst_d_o     (dst),
    .src_d_o     (src),
    .l2type_d_o  (length_type),
    .vlan_d_o    (vlan)
  );

  es_mems_sync_fifo #(
    .WIDTH (8),
    .DEPTH (BYTE_DEPTH)
  ) u_bytes (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .undo_i     (1'b0),
    .undo_cnt_i (BCW'(0)),
    .flush_i    (1'b0),
    .wr_en_i    (write_byte),
    .wr_data_i  (b_data_i),
    .full_o     (byte_full),
    .free_o     (byte_free),
    .rd_en_i    (rd_i),
    .rd_data_o  (data_o),
    .empty_o    (empty_o)
  );

  // Admission reserves the descriptor slot until EOF or early abort.
  // There is at most one incomplete frame on any ingress lane.
  es_mems_sync_fifo #(
    .WIDTH (DW),
    .DEPTH (DESC_DEPTH)
  ) u_desc (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .undo_i     (1'b0),
    .undo_cnt_i (DCW'(0)),
    .flush_i    (1'b0),
    .wr_en_i    (publish),
    .wr_data_i  (descriptor),
    .full_o     (desc_full),
    .free_o     (desc_free),
    .rd_en_i    (d_valid_o && d_ready_i),
    .rd_data_o  (desc_o),
    .empty_o    (desc_empty)
  );
  assign d_valid_o = !desc_empty;
endmodule

`default_nettype wire
`endif
