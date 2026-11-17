// ============================================================================
//  File        : es_switch_stage_2_validate.sv
//  Description : One ingress descriptor lane. Parallel header and length checks
//                fold the receive-error bit and the verdict into the single
//                drop bit while preserving queue accounting.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_SWITCH_STAGE_2_VALIDATE_SV
`define ES_SWITCH_STAGE_2_VALIDATE_SV
`default_nettype none
`include "es_defs.sv"
`default_nettype none

module es_switch_stage_2_validate #(
  parameter int unsigned NUM_PORTS     = 4,
  parameter int unsigned PORT_ID       = 0,
  parameter logic [47:0] PORT_MAC      = '0,
  parameter int unsigned MIN_FRAME_LEN = 60,
  parameter int unsigned MAX_FRAME_LEN = 1518
) (
  input  var logic                                   clk_i,  ///< core clock
  input  var logic                                   rst_ni,  ///< active-low synchronous reset
  input  var logic                                   i_valid,  ///< input valid; stable while i_ready is low
  output     logic                                   i_ready,  ///< input ready; asserted when a beat is accepted
  input  var logic [es_pl_rx_desc_w(NUM_PORTS)-1:0]  i_desc,  ///< input descriptor
  output     logic                                   o_valid,  ///< output valid; stable while o_ready is low
  input  var logic                                   o_ready,  ///< output ready; asserted when a beat is accepted
  output     logic [es_pl_chk_desc_w(NUM_PORTS)-1:0] o_desc  ///< output descriptor
);
  localparam int unsigned CKW = es_pl_chk_desc_w(NUM_PORTS);
  localparam int unsigned PW = es_port_w(NUM_PORTS);
  localparam int unsigned FW = ES_LEN_W + 1;
  localparam int unsigned BASE = es_pl_desc_w(NUM_PORTS);
  localparam int unsigned ERR = BASE + ES_PL_RX_ERR_LSB;
  localparam int unsigned FCS_LSB = BASE + ES_PL_RX_FCS_LSB;
  localparam int unsigned CRC_LSB = BASE + ES_PL_RX_CRC_LSB;
  localparam int unsigned STORED_LSB = es_pl_desc_stored_lsb(NUM_PORTS);
  localparam logic [47:0] OWN_MAC = (PORT_MAC == '0) ? es_default_mac(PORT_ID) : PORT_MAC;
  logic [47:0] src, dst;
  logic [15:0] length_type, declared_len, padded_len;
  logic [FW-1:0] measured;
  logic vlan, reject, rx_reject;
  logic [8:0] checks;
  logic [CKW-1:0] verdict;
  logic accept, valid_d;

  assign src = i_desc[es_pl_desc_srcm_lsb(NUM_PORTS) +: 48];
  assign dst = i_desc[es_pl_desc_dstm_lsb(NUM_PORTS) +: 48];
  assign measured = i_desc[BASE +: FW];
  assign length_type = i_desc[BASE+ES_PL_RX_TYPE_LSB +: 16];
  assign vlan = i_desc[BASE+ES_PL_RX_VLAN_LSB];
  assign declared_len = length_type + 16'(ES_HDR_LEN);
  assign padded_len = (declared_len < 16'(ES_PL_MIN_WIRE_CLIENT)) ?
                      16'(ES_PL_MIN_WIRE_CLIENT) : declared_len;

  assign checks[0] = i_desc[ERR];
  assign checks[1] = (measured < FW'(MIN_FRAME_LEN)) || (measured > FW'(MAX_FRAME_LEN));
  assign checks[2] = vlan && (measured < FW'(ES_HDR_LEN_VLAN));
  assign checks[3] = !es_is_unicast(src);
  assign checks[4] = (src == OWN_MAC) || (dst == OWN_MAC);
  assign checks[5] = (src == dst);
  assign checks[6] = (src == '0) || (dst == '0);
  assign checks[7] = (length_type > 16'd1500) && (length_type < 16'd1536);
  assign checks[8] = !vlan && es_is_8023_length(length_type) && (16'(measured) != padded_len);
  assign reject = |checks;
  // The receive-error bit and the header/length verdict fold into the single
  // drop bit that Stage 3 re-writes with the FCS verdict.  The measured
  // length, Length/Type and VLAN metadata have no consumer past this boundary
  // and stop here; only the FCS and CRC travel on for the comparison.
  assign rx_reject = i_desc[ERR] || reject;
  assign verdict = {i_desc[CRC_LSB +: 32], i_desc[FCS_LSB +: 32],
                    rx_reject, i_desc[STORED_LSB +: ES_LEN_W],
                    dst, src, i_desc[PW-1:0]};

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
    .WIDTH (CKW),
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
