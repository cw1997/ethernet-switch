// ============================================================================
//  File        : es_switch_stage_4_lookup.sv
//  Description : CAM lookup and frame copy for N ingress lanes. All target queues
//                are reserved atomically before any byte is copied.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_SWITCH_STAGE_4_LOOKUP_SV
`define ES_SWITCH_STAGE_4_LOOKUP_SV
`default_nettype none
`include "es_defs.sv"
`default_nettype none

module es_switch_stage_4_lookup #(
  parameter int unsigned NUM_PORTS      = 4,
  parameter int unsigned CAM_SETS       = 128,
  parameter int unsigned CAM_WAYS       = 4,
  parameter int unsigned LEARNING_EN    = 1,
  parameter logic [1:0] FLOOD_MODE      = 2'd1,
  parameter int unsigned MAX_FRAME_LEN  = 1518,
  parameter int unsigned TX_QUEUE_DEPTH = 256
) (
  input var logic clk_i,
  rst_ni,
  input var logic [NUM_PORTS-1:0] i_valid,
  output logic [NUM_PORTS-1:0] i_ready,
  input var logic [NUM_PORTS*es_pl_desc_w(NUM_PORTS)-1:0] i_desc,
  input var logic [NUM_PORTS*8-1:0] buf_data_i,
  input var logic [NUM_PORTS-1:0] buf_empty_i,
  output logic [NUM_PORTS-1:0] buf_read_o,
  input var logic [NUM_PORTS*es_pl_fifo_cnt_w(es_pl_tx_depth(TX_QUEUE_DEPTH, MAX_FRAME_LEN))-1:0] tx_free_i,
  output logic [NUM_PORTS-1:0] tx_write_o,
  tx_sof_o,
  tx_eof_o,
  output logic [NUM_PORTS*8-1:0] tx_data_o
);
  localparam int unsigned PW = es_port_w(NUM_PORTS);
  localparam int unsigned CW = es_pl_fifo_cnt_w(es_pl_tx_depth(TX_QUEUE_DEPTH, MAX_FRAME_LEN));
  localparam int unsigned LW = NUM_PORTS + ES_LEN_W;
  localparam int unsigned CAM_W = es_pl_cam_w(NUM_PORTS);

  logic [NUM_PORTS-1:0] cam_valid, cam_ready, dec_valid, dec_ready;
  logic [NUM_PORTS*CAM_W-1:0] cam_desc;
  logic [NUM_PORTS*LW-1:0] dec_desc;
  logic [NUM_PORTS*NUM_PORTS-1:0] wait_masks, active_masks;
  logic [NUM_PORTS-1:0] pending, eligible, start_copy, first_byte, last_byte;
  logic [NUM_PORTS-1:0] busy_dest;
  logic [PW-1:0] rr_q, rr_d;

  es_switch_stage_4_lookup_cam_stage #(
    .NUM_PORTS   (NUM_PORTS),
    .NUM_SETS    (CAM_SETS),
    .NUM_WAYS    (CAM_WAYS),
    .LEARNING_EN (LEARNING_EN)
  ) u_cam (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .d_i_valid (i_valid),
    .d_i_ready (i_ready),
    .d_i_desc  (i_desc),
    .o_valid   (cam_valid),
    .o_ready   (cam_ready),
    .o_pkg     (cam_desc)
  );

  es_switch_stage_4_lookup_decide #(
    .NUM_PORTS  (NUM_PORTS),
    .FLOOD_MODE (FLOOD_MODE)
  ) u_decide (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .i_valid (cam_valid),
    .i_ready (cam_ready),
    .i_pkg   (cam_desc),
    .o_valid (dec_valid),
    .o_ready (dec_ready),
    .o_pkg   (dec_desc)
  );

  function automatic logic [PW-1:0] next_port(input logic [PW-1:0] port_id);
    next_port = (port_id == PW'(NUM_PORTS - 1)) ? '0 : port_id + PW'(1);
  endfunction

  // The first pending request claims scheduling priority even if it must
  // wait for credit. Younger requests can still use disjoint destinations.
  function automatic logic [PW+NUM_PORTS-1:0] schedule(
    input logic [PW-1:0] base,
    input logic [NUM_PORTS-1:0] waiting, ready_to_copy, owned,
    input logic [NUM_PORTS*NUM_PORTS-1:0] masks
  );
    logic [PW-1:0] lane, next_base;
    logic [NUM_PORTS-1:0] claimed, grant, targets;
    logic first_pending, fits;
    lane = base;
    next_base = base;
    claimed = owned;
    grant = '0;
    first_pending = 1'b1;
    for (int unsigned i = 0; i < NUM_PORTS; i++) begin
      targets = masks[32'(lane)*NUM_PORTS +: NUM_PORTS];
      fits = ready_to_copy[lane] && ((targets & claimed) == '0);
      if (waiting[lane]) begin
        grant[lane] = fits;
        if (first_pending) next_base = fits ? next_port(lane) : lane;
        if (first_pending || fits) claimed = claimed | targets;
        first_pending = 1'b0;
      end
      lane = next_port(lane);
    end
    schedule = {next_base, grant};
  endfunction

  assign {rr_d, start_copy} = schedule(rr_q, pending, eligible, busy_dest, wait_masks);
  es_mems_reg_bank #(
    .WIDTH (PW),
    .DEPTH (1)
  ) u_rr_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (1'b0),
    .wr_en_i   (1'b1),
    .wr_data_i (rr_d),
    .data_o    (rr_q)
  );

  genvar p, q;
  generate
    for (p = 0; p < NUM_PORTS; p++) begin : g_src
      logic [NUM_PORTS-1:0] mask, mask_q, credit_ok;
      logic [ES_LEN_W-1:0] len, remaining_q;
      logic take, busy;

      assign {mask, len} = dec_desc[p*LW +: LW];
      assign wait_masks[p*NUM_PORTS +: NUM_PORTS] = mask;
      assign active_masks[p*NUM_PORTS +: NUM_PORTS] = busy ? mask_q : '0;
      assign busy = (remaining_q != '0);
      assign pending[p] = dec_valid[p] && !busy && (mask != '0);
      assign eligible[p] = &credit_ok;
      assign dec_ready[p] = !busy && ((mask == '0) || start_copy[p]);
      assign take = dec_valid[p] && dec_ready[p];

      for (q = 0; q < NUM_PORTS; q++) begin : g_credit
        localparam int unsigned CMP_W = (CW > ES_LEN_W) ? CW : ES_LEN_W;
        assign credit_ok[q] = !mask[q] ||
            (CMP_W'(tx_free_i[q*CW +: CW]) >= CMP_W'(len));
      end

      assign buf_read_o[p] = busy && !buf_empty_i[p];
      assign last_byte[p] = (remaining_q == ES_LEN_W'(1));
      es_mems_reg_bank #(
        .WIDTH (ES_LEN_W),
        .DEPTH (1)
      ) u_remaining_q (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .clear_i   (1'b0),
        .wr_en_i   (take || buf_read_o[p]),
        .wr_data_i (take ? len : remaining_q - ES_LEN_W'(1)),
        .data_o    (remaining_q)
      );
      // Only a nonzero remaining count exposes this unreset ownership mask.
      es_mems_reg_bank #(
        .WIDTH (NUM_PORTS),
        .DEPTH (1)
      ) u_mask_q (
        .clk_i     (clk_i),
        .rst_ni    (1'b1),
        .clear_i   (1'b0),
        .wr_en_i   (take),
        .wr_data_i (mask),
        .data_o    (mask_q)
      );
      es_mems_reg_bank #(
        .WIDTH (1),
        .DEPTH (1)
      ) u_first_q (
        .clk_i     (clk_i),
        .rst_ni    (rst_ni),
        .clear_i   (1'b0),
        .wr_en_i   (take || buf_read_o[p]),
        .wr_data_i (take),
        .data_o    (first_byte[p])
      );
    end

    for (q = 0; q < NUM_PORTS; q++) begin : g_dest
      logic [NUM_PORTS-1:0] owners;
      logic [NUM_PORTS-1:0] write_lanes;
      for (p = 0; p < NUM_PORTS; p++) begin : g_owner
        assign owners[p] = active_masks[p*NUM_PORTS + q];
        assign write_lanes[p] = owners[p] && buf_read_o[p];
      end
      assign busy_dest[q] = |owners;
      assign tx_write_o[q] = |write_lanes;
      assign tx_sof_o[q] = |(write_lanes & first_byte);
      assign tx_eof_o[q] = |(write_lanes & last_byte);
      assign tx_data_o[q*8 +: 8] = select_octet(write_lanes, buf_data_i);
    end
  endgenerate

  // Ownership is one-hot, so constant-index masking suffices for the mux.
  function automatic logic [7:0] select_octet(
    input logic [NUM_PORTS-1:0] selected,
    input logic [NUM_PORTS*8-1:0] bytes_flat
  );
    logic [7:0] value;
    value = '0;
    for (int unsigned lane = 0; lane < NUM_PORTS; lane++)
      value = value | (bytes_flat[lane*8 +: 8] & {8{selected[lane]}});
    select_octet = value;
  endfunction
endmodule

`default_nettype wire
`endif
