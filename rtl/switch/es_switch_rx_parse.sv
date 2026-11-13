// ============================================================================
//  File        : es_switch_rx_parse.sv
//  Description : Header slice of the S0/S1 receive level - one instance per
//                ingress port, instantiated by es_switch_rx_engine.
//
//                Latches the destination MAC (octets 0-5), the source MAC
//                (octets 6-11) and the length/type field (octets 12-13) off
//                the byte stream in wire order, and derives the VLAN flag
//                from the completed EtherType.  The first octet on the wire
//                is mac[47:40], so a left shift assembles each address.
//
//                Both the held values (dst/src - what the commit descriptor
//                carries) and the next values (dst_d/src_d/l2type_d/vlan_d -
//                what the eof checks examine) are exported; es_switch_rx_ctrl
//                drives byte_fire_i, the octet count this module compares
//                against, and clear_i (S_COMMIT clears every header register,
//                matching the commit branch of the single-process form this
//                was split from).
//
//                Switch-domain style (AGENTS.md): `logic`/`assign` clouds
//                only; every sequential element is an es_mems_reg_bank
//                instance.  The destination and source MAC share one
//                two-entry bank because they have the same width and reset
//                value and are cleared together.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_RX_PARSE_SV
`define ES_SWITCH_RX_PARSE_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_switch_rx_parse (
  input  var logic              clk_i,
  input  var logic              rst_ni,

  // ---- per-byte work strobes from es_switch_rx_ctrl ----------------------
  input  var logic              byte_fire_i,  ///< a byte is consumed this clock
  input  var logic [SW_LEN_W:0] oct_cnt_i,    ///< octets buffered so far (held count)
  input  var logic [7:0]        b_data_i,
  input  var logic              clear_i,      ///< S_COMMIT: clear all header regs

  // ---- held header fields (the commit descriptor carries these) ----------
  output      logic [47:0]      dst_q_o,
  output      logic [47:0]      src_q_o,

  // ---- next header fields (the eof checks examine these) -----------------
  output      logic [47:0]      dst_d_o,
  output      logic [47:0]      src_d_o,
  output      logic [15:0]      l2type_d_o,
  output      logic             vlan_d_o
);

  // --------------------------------------------------------------------------
  // Configuration
  // --------------------------------------------------------------------------
  localparam int unsigned OCTW = SW_LEN_W + 1;

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
                      ? sw_is_vlan_type(l2type_d) : vlan_q;

  assign dst_q_o    = dst_q;
  assign src_q_o    = src_q;
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
    .WIDTH (16),
    .DEPTH (1),
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
    .WIDTH (1),
    .DEPTH (1),
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

endmodule : es_switch_rx_parse

`default_nettype wire

`endif  // ES_SWITCH_RX_PARSE_SV
