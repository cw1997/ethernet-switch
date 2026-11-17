// ============================================================================
//  File        : es_switch_stage_3_checksum.sv
//  Description : One ingress lane. Accumulates CRC on the Stage 1 write tap,
//                compares it with the wire FCS and folds every reject source
//                into the descriptor's drop bit.
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
  input  var logic                                   clk_i,  ///< core clock
  input  var logic                                   rst_ni,  ///< active-low synchronous reset
  input  var logic                                   crc_write_i,  ///< CRC write strobe
  input  var logic                                   crc_sof_i,  ///< start of frame for CRC
  input  var logic [7:0]                             crc_data_i,  ///< CRC input octet
  output     logic [31:0]                            crc_o,  ///< running CRC
  input  var logic                                   i_valid,  ///< input valid; stable while i_ready is low
  output     logic                                   i_ready,  ///< input ready; asserted when a beat is accepted
  input  var logic [es_pl_chk_desc_w(NUM_PORTS)-1:0] i_desc,  ///< input descriptor
  output     logic                                   o_valid,  ///< output valid; stable while o_ready is low
  input  var logic                                   o_ready,  ///< output ready; asserted when a beat is accepted
  output     logic [es_pl_desc_w(NUM_PORTS)-1:0]     o_desc  ///< output descriptor
);
  localparam int unsigned DW = es_pl_desc_w(NUM_PORTS);
  localparam int unsigned PW = es_port_w(NUM_PORTS);
  localparam int unsigned FCS_LSB = DW + ES_PL_CHK_FCS_LSB;
  localparam int unsigned CRC_LSB = DW + ES_PL_CHK_CRC_LSB;
  logic [31:0] crc_q, crc_next;
  logic accept, valid_d, reject;
  logic [DW-1:0] verdict;
  // crc_o includes the current beat so a same-cycle EOF sees the final CRC.
  assign crc_next = es_crc32_absorb_octet(crc_sof_i ? ES_CRC32_INIT : crc_q, crc_data_i);
  assign crc_o = (crc_write_i ? crc_next : crc_q) ^ ES_CRC32_XOROUT;
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

  // Stage 2 folded the receive-error and header/length verdicts into the
  // drop bit; the FCS comparison adds the last reject source and the folded
  // verdict lands back in that bit.  A rejected frame carries no forward
  // length implicitly: the copy engine drains stored_len and writes nothing.
  assign reject = i_desc[DW-1] ||
      (i_desc[FCS_LSB +: 32] != i_desc[CRC_LSB +: 32]);
  assign verdict = {reject, i_desc[DW-2:PW], i_desc[PW-1:0]};
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
