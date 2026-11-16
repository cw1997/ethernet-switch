// ============================================================================
//  File        : es_switch_stage_1_rx_parse.sv
//  Description : Accumulates MAC addresses and the outer Length/Type field
//                on each buffered RX byte. The next values include the current
//                byte so Stage 1 can publish on the same edge as EOF.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_STAGE_1_RX_PARSE_SV
`define ES_SWITCH_STAGE_1_RX_PARSE_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_switch_stage_1_rx_parse (
  input  var logic              clk_i,
  input  var logic              rst_ni,

  // ---- per-byte work strobes from Stage 1 ----------------------
  input  var logic              byte_fire_i,  ///< a byte is consumed this clock
  input  var logic [ES_LEN_W:0] oct_cnt_i,  ///< octets buffered so far (held count)
  input  var logic [7:0]        b_data_i,
  input  var logic              clear_i,  ///< descriptor publication clears header state

  output logic     [47:0]       dst_d_o,
  output logic     [47:0]       src_d_o,
  output logic     [15:0]       l2type_d_o,
  output logic                  vlan_d_o
);

  // --------------------------------------------------------------------------
  // Configuration
  // --------------------------------------------------------------------------
  localparam int unsigned OCTW = ES_LEN_W + 1;

  // --------------------------------------------------------------------------
  // State and combinational next values
  // --------------------------------------------------------------------------
  logic [47:0] dst_q, src_q;
  logic [47:0] dst_d, src_d;
  logic [15:0] l2type_q, l2type_d;
  logic        vlan_q, vlan_d;
  logic [95:0] mac_flat;   ///< packed bank view: entry 0 dst, entry 1 src

  logic dst_we, src_we, type_we, vlan_we;

  assign dst_we  = byte_fire_i && (oct_cnt_i < OCTW'(6));
  assign src_we  = byte_fire_i && (oct_cnt_i >= OCTW'(6)) &&
                                       (oct_cnt_i < OCTW'(12));
  assign type_we = byte_fire_i && ((oct_cnt_i == OCTW'(12)) ||
                                   (oct_cnt_i == OCTW'(13)));
  assign vlan_we = byte_fire_i && (oct_cnt_i == OCTW'(13));

  // Header latch.  The first octet on the wire is mac[47:40], so a left shift
  // assembles each address in wire order.
  assign dst_d = (byte_fire_i && (oct_cnt_i < OCTW'(6)))
                     ? {dst_q[39:0], b_data_i} : dst_q;
  assign src_d = (byte_fire_i && (oct_cnt_i >= OCTW'(6)) &&
                                  (oct_cnt_i < OCTW'(12)))
                     ? {src_q[39:0], b_data_i} : src_q;

  // The EtherType arrives high byte first (octet 12, then 13).
  assign l2type_d = (byte_fire_i && (oct_cnt_i == OCTW'(12)))
                        ? {b_data_i, l2type_q[7:0]} :
                    (byte_fire_i && (oct_cnt_i == OCTW'(13)))
                        ? {l2type_q[15:8], b_data_i} : l2type_q;

  // The VLAN flag is derived from the completed EtherType on the octet that
  // completes it.
  assign vlan_d = (byte_fire_i && (oct_cnt_i == OCTW'(13)))
                      ? es_is_vlan_type(l2type_d) : vlan_q;

  assign dst_d_o    = dst_d;
  assign src_d_o    = src_d;
  assign l2type_d_o = l2type_d;
  assign vlan_d_o   = vlan_d;

  // --------------------------------------------------------------------------
  // Registers
  //
  // Destination (entry 0) and source (entry 1) MAC share one bank: same width,
  // same reset value, and both are cleared together on the commit clock.
  // clear_i takes priority over the per-entry write enables inside the bank,
  // which is exactly the commit behaviour wanted here.
  // --------------------------------------------------------------------------
  es_mems_reg_bank #(
    .WIDTH       (48),
    .DEPTH       (2),
    .RESET_VALUE ('0)
  ) u_mac_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (clear_i),
    .wr_en_i   ({src_we, dst_we}),
    .wr_data_i ({src_d, dst_d}),
    .data_o    (mac_flat)
  );

  es_mems_reg_bank #(
    .WIDTH       (16),
    .DEPTH       (1),
    .RESET_VALUE ('0)
  ) u_l2type_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (clear_i),
    .wr_en_i   (type_we),
    .wr_data_i (l2type_d),
    .data_o    (l2type_q)
  );

  es_mems_reg_bank #(
    .WIDTH       (1),
    .DEPTH       (1),
    .RESET_VALUE ('0)
  ) u_vlan_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (clear_i),
    .wr_en_i   (vlan_we),
    .wr_data_i (vlan_d),
    .data_o    (vlan_q)
  );

  assign dst_q = mac_flat[47:0];
  assign src_q = mac_flat[95:48];

endmodule : es_switch_stage_1_rx_parse

`default_nettype wire

`endif  // ES_SWITCH_STAGE_1_RX_PARSE_SV
