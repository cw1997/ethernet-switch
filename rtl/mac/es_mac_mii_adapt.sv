// ============================================================================
//  File        : es_mac_mii_adapt.sv
//  Description : Per-port MAC interface adapter for the staged switch.
//
//                Each adapter owns exactly one physical line interface and
//                presents the SAME 8-bit byte-stream contract to the core:
//                rx_valid/rx_ready/rx_data/rx_sof/rx_eof/rx_err/rx_fcs and the
//                matching tx_* signals.  Preamble/SFD, RX FCS extraction, TX
//                framing and the rate model live in the adapters, so
//                `es_switch_fabric` is unchanged no matter which is elaborated.
//
//                MII: 4-bit nibble pins, two windows per octet time. MII/RMII reuse the symbol serialisers.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MAC_MII_ADAPT_SV
`define ES_MAC_MII_ADAPT_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_mac_mii_adapt #(
  parameter int unsigned BYTE_PERIOD    = 2,
  parameter int unsigned IFG_OCTETS     = 12,
  parameter int unsigned MIN_CLIENT_LEN = 60
) (
  input  var logic        clk_i,  ///< core clock
  input  var logic        rst_ni,  ///< active-low synchronous reset

  input  var logic        mii_rx_dv_i,  ///< MII receive data valid
  input  var logic        mii_rx_er_i,  ///< MII receive error
  input  var logic [3:0]  mii_rxd_i,  ///< MII receive nibble, low nibble first
  output     logic        mii_tx_en_o,  ///< MII transmit enable
  output     logic        mii_tx_er_o,  ///< MII transmit error; always low
  output     logic [3:0]  mii_txd_o,  ///< MII transmit nibbles, port p in [p*4 +: 4]

  output     logic        rx_valid_o,  ///< byte-stream valid toward the switch core
  input  var logic        rx_ready_i,  ///< byte-stream ready from the switch core
  output     logic [7:0]  rx_data_o,  ///< canonical octet toward the switch core
  output     logic        rx_sof_o,  ///< start of frame of the current octet
  output     logic        rx_eof_o,  ///< end of frame of the current octet
  output     logic        rx_err_o,  ///< current frame carried an error
  output     logic [31:0] rx_fcs_o,  ///< extracted FCS, first octet in bits 7:0

  input  var logic        tx_valid_i,  ///< canonical octet valid from the switch core
  output     logic        tx_ready_o,  ///< canonical octet ready toward the switch core
  input  var logic [7:0]  tx_data_i,  ///< canonical octet from the switch core
  input  var logic        tx_sof_i,  ///< start of frame from the switch core
  input  var logic        tx_eof_i  ///< end of frame from the switch core
);

  logic       oct_rx_en;
  logic [7:0] oct_rx_d;
  logic       oct_tx_en;
  logic [7:0] oct_tx_d;

  es_mac_mii_serdes #(
    .BYTE_PERIOD (BYTE_PERIOD)
  ) u_serdes (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .mii_rx_dv_i (mii_rx_dv_i),
    .mii_rx_er_i (mii_rx_er_i),
    .mii_rxd_i   (mii_rxd_i),
    .mii_tx_en_o (mii_tx_en_o),
    .mii_tx_er_o (mii_tx_er_o),
    .mii_txd_o   (mii_txd_o),
    .oct_en_o    (oct_rx_en),
    .oct_d_o     (oct_rx_d),
    .oct_en_i    (oct_tx_en),
    .oct_d_i     (oct_tx_d)
  );

  es_mac_frame_rx #(
    .BYTE_PERIOD (BYTE_PERIOD)
  ) u_rx (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .oct_en_i  (oct_rx_en),
    .oct_d_i   (oct_rx_d),
    .oct_er_i  (mii_rx_er_i),
    .b_valid_o (rx_valid_o),
    .b_ready_i (rx_ready_i),
    .b_data_o  (rx_data_o),
    .b_sof_o   (rx_sof_o),
    .b_eof_o   (rx_eof_o),
    .b_err_o   (rx_err_o),
    .b_fcs_o   (rx_fcs_o)
  );

  es_mac_frame_tx #(
    .BYTE_PERIOD    (BYTE_PERIOD),
    .IFG_OCTETS     (IFG_OCTETS),
    .MIN_CLIENT_LEN (MIN_CLIENT_LEN)
  ) u_tx (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .b_valid_i (tx_valid_i),
    .b_ready_o (tx_ready_o),
    .b_data_i  (tx_data_i),
    .b_sof_i   (tx_sof_i),
    .b_eof_i   (tx_eof_i),
    .oct_en_o  (oct_tx_en),
    .oct_d_o   (oct_tx_d)
  );

endmodule : es_mac_mii_adapt

`default_nettype wire

`endif  // ES_MAC_MII_ADAPT_SV
