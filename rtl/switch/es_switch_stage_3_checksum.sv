// ============================================================================
//  File        : es_switch_stage_3_checksum.sv
//  Description : One ingress lane. Accumulates CRC on the Stage 1 write tap;
//                verdict and queue accounting travel together through stalls.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_SWITCH_STAGE_3_CHECKSUM_SV
`define ES_SWITCH_STAGE_3_CHECKSUM_SV
`default_nettype none
`include "es_defs.sv"
`default_nettype none

module es_switch_stage_3_checksum #(
  parameter int unsigned NUM_PORTS = 4
) (
  input var logic clk_i,
  rst_ni,
  input var logic crc_write_i,
  crc_sof_i,
  input var logic [7:0] crc_data_i,
  output logic [31:0] crc_o,
  input var logic i_valid,
  output logic i_ready,
  input var logic [sw_pl_rx_desc_w(NUM_PORTS)-1:0] i_desc,
  output logic o_valid,
  input var logic o_ready,
  output logic [sw_pl_desc_w(NUM_PORTS)-1:0] o_desc
);
  localparam int unsigned DW = sw_pl_desc_w(NUM_PORTS);
  localparam int unsigned PW = sw_port_w(NUM_PORTS);
  localparam int unsigned ERR = DW + SW_PL_RX_ERR_LSB;
  logic [31:0] crc_q, crc_next;
  logic accept, valid_d, reject;
  logic [DW-1:0] verdict;
  // crc_o includes the current beat so a same-cycle EOF sees the final CRC.
  assign crc_next = sw_crc32_absorb_octet(crc_sof_i ? SW_CRC32_INIT : crc_q, crc_data_i);
  assign crc_o = (crc_write_i ? crc_next : crc_q) ^ SW_CRC32_XOROUT;
  // SOF selects the CRC seed, so the accumulator needs no reset value.
  es_mems_reg_bank #(
    .WIDTH (32),
    .DEPTH (1)
  ) u_crc_q (
    .clk_i     (clk_i),
    .rst_ni    (1'b1),
    .clear_i   (1'b0),
    .wr_en_i   (crc_write_i),
    .wr_data_i (crc_next),
    .data_o    (crc_q)
  );

  // Stage 2 carries its reason-independent drop bit and zero forward length.
  // Header-check metadata has no consumer after this boundary.
  logic [ERR-DW-1:0] unused_validation_metadata;
  assign unused_validation_metadata = i_desc[DW +: ERR-DW];
  assign reject = i_desc[ERR] || i_desc[DW-1] ||
      (i_desc[ERR+1 +: 32] != i_desc[ERR+33 +: 32]);
  assign verdict = {reject, i_desc[DW-2:PW+SW_LEN_W],
                   reject ? SW_LEN_W'(0) : i_desc[PW +: SW_LEN_W], i_desc[PW-1:0]};
  assign i_ready = !o_valid || o_ready;
  assign accept = i_valid && i_ready;
  assign valid_d = accept || (o_valid && !o_ready);
  es_mems_reg_bank #(
    .WIDTH (1),
    .DEPTH (1)
  ) u_valid_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (1'b0),
    .wr_en_i   (1'b1),
    .wr_data_i (valid_d),
    .data_o    (o_valid)
  );
  // The descriptor payload is ignored until its resettable valid bit is set.
  es_mems_reg_bank #(
    .WIDTH (DW),
    .DEPTH (1)
  ) u_desc_q (
    .clk_i     (clk_i),
    .rst_ni    (1'b1),
    .clear_i   (1'b0),
    .wr_en_i   (accept),
    .wr_data_i (verdict),
    .data_o    (o_desc)
  );
endmodule

`default_nettype wire
`endif
