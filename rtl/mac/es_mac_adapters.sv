// ============================================================================
//  File        : es_mac_adapters.sv
//  Description : Per-port MAC interface adapters for the staged switch.
//
//                Each adapter owns exactly one physical line interface and
//                presents the SAME 8-bit byte-stream contract to the core:
//                rx_valid/rx_ready/rx_data/rx_sof/rx_eof/rx_err and the
//                matching tx_* signals.  Preamble/SFD/FCS/IFG/padding and the
//                clock-enable rate model are handled entirely inside the MAC
//                adapters (es_mac_byte_if.sv), so `es_switch_fabric` is
//                unchanged no matter which of the three is elaborated.
//
//                MII and RMII reuse the existing symbol serialisers, which
//                turn nibble/dibit pins into the canonical octet stream and
//                back.  Those serialisers already suppress an RX_ER octet, so
//                `oct_er_i` into the receive framer is tied low here.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MAC_ADAPTERS_SV
`define ES_MAC_ADAPTERS_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

// ============================================================================
// GMII: the pins are already octet aligned.
// ============================================================================
module es_mac_gmii_adapt #(
  parameter int unsigned BYTE_PERIOD    = 1,
  parameter int unsigned IFG_OCTETS     = 12,
  parameter int unsigned MIN_CLIENT_LEN = 60
) (
  input  var logic       clk_i,
  input  var logic       rst_ni,

  input  var logic       gmii_rx_en_i,
  input  var logic [7:0] gmii_rx_d_i,
  output      logic      gmii_tx_en_o,
  output      logic [7:0] gmii_tx_d_o,

  output      logic       rx_valid_o,
  input  var logic        rx_ready_i,
  output      logic [7:0] rx_data_o,
  output      logic       rx_sof_o,
  output      logic       rx_eof_o,
  output      logic       rx_err_o,

  input  var logic        tx_valid_i,
  output      logic       tx_ready_o,
  input  var logic [7:0]  tx_data_i,
  input  var logic        tx_sof_i,
  input  var logic        tx_eof_i
);

  es_mac_frame_rx #(.BYTE_PERIOD(BYTE_PERIOD)) u_rx (
    .clk_i    (clk_i),        .rst_ni  (rst_ni),
    .oct_en_i (gmii_rx_en_i), .oct_d_i (gmii_rx_d_i),
    .oct_er_i (1'b0),
    .b_valid_o(rx_valid_o),   .b_ready_i(rx_ready_i),
    .b_data_o (rx_data_o),    .b_sof_o (rx_sof_o),
    .b_eof_o  (rx_eof_o),     .b_err_o (rx_err_o)
  );

  es_mac_frame_tx #(
    .BYTE_PERIOD    (BYTE_PERIOD),
    .IFG_OCTETS     (IFG_OCTETS),
    .MIN_CLIENT_LEN (MIN_CLIENT_LEN)
  ) u_tx (
    .clk_i    (clk_i),        .rst_ni   (rst_ni),
    .b_valid_i(tx_valid_i),   .b_ready_o(tx_ready_o),
    .b_data_i (tx_data_i),    .b_sof_i  (tx_sof_i),
    .b_eof_i  (tx_eof_i),
    .oct_en_o (gmii_tx_en_o), .oct_d_o  (gmii_tx_d_o)
  );

endmodule : es_mac_gmii_adapt

// ============================================================================
// MII: 4-bit nibble pins, two windows per octet time.
// ============================================================================
module es_mac_mii_adapt #(
  parameter int unsigned BYTE_PERIOD    = 2,
  parameter int unsigned IFG_OCTETS     = 12,
  parameter int unsigned MIN_CLIENT_LEN = 60
) (
  input  var logic       clk_i,
  input  var logic       rst_ni,

  input  var logic       mii_rx_dv_i,
  input  var logic       mii_rx_er_i,
  input  var logic [3:0] mii_rxd_i,
  output      logic      mii_tx_en_o,
  output      logic      mii_tx_er_o,
  output      logic [3:0] mii_txd_o,

  output      logic       rx_valid_o,
  input  var logic        rx_ready_i,
  output      logic [7:0] rx_data_o,
  output      logic       rx_sof_o,
  output      logic       rx_eof_o,
  output      logic       rx_err_o,

  input  var logic        tx_valid_i,
  output      logic       tx_ready_o,
  input  var logic [7:0]  tx_data_i,
  input  var logic        tx_sof_i,
  input  var logic        tx_eof_i
);

  logic       oct_rx_en;
  logic [7:0] oct_rx_d;
  logic       oct_tx_en;
  logic [7:0] oct_tx_d;

  es_mac_mii_serdes #(.BYTE_PERIOD(BYTE_PERIOD)) u_serdes (
    .clk_i       (clk_i),      .rst_ni     (rst_ni),
    .mii_rx_dv_i (mii_rx_dv_i), .mii_rx_er_i(mii_rx_er_i),
    .mii_rxd_i   (mii_rxd_i),
    .mii_tx_en_o (mii_tx_en_o), .mii_tx_er_o(mii_tx_er_o),
    .mii_txd_o   (mii_txd_o),
    .oct_en_o    (oct_rx_en),  .oct_d_o    (oct_rx_d),
    .oct_en_i    (oct_tx_en),  .oct_d_i    (oct_tx_d)
  );

  es_mac_frame_rx #(.BYTE_PERIOD(BYTE_PERIOD)) u_rx (
    .clk_i    (clk_i),      .rst_ni  (rst_ni),
    .oct_en_i (oct_rx_en),  .oct_d_i (oct_rx_d),
    .oct_er_i (1'b0),
    .b_valid_o(rx_valid_o), .b_ready_i(rx_ready_i),
    .b_data_o (rx_data_o),  .b_sof_o (rx_sof_o),
    .b_eof_o  (rx_eof_o),   .b_err_o (rx_err_o)
  );

  es_mac_frame_tx #(
    .BYTE_PERIOD    (BYTE_PERIOD),
    .IFG_OCTETS     (IFG_OCTETS),
    .MIN_CLIENT_LEN (MIN_CLIENT_LEN)
  ) u_tx (
    .clk_i    (clk_i),       .rst_ni   (rst_ni),
    .b_valid_i(tx_valid_i),  .b_ready_o(tx_ready_o),
    .b_data_i (tx_data_i),   .b_sof_i  (tx_sof_i),
    .b_eof_i  (tx_eof_i),
    .oct_en_o (oct_tx_en),   .oct_d_o  (oct_tx_d)
  );

endmodule : es_mac_mii_adapt

// ============================================================================
// RMII: 2-bit dibit pins, four windows per octet time.
// ============================================================================
module es_mac_rmii_adapt #(
  parameter int unsigned BYTE_PERIOD    = 4,
  parameter int unsigned IFG_OCTETS     = 12,
  parameter int unsigned MIN_CLIENT_LEN = 60
) (
  input  var logic       clk_i,
  input  var logic       rst_ni,

  input  var logic       rmii_crs_dv_i,
  input  var logic [1:0] rmii_rxd_i,
  output      logic      rmii_tx_en_o,
  output      logic [1:0] rmii_txd_o,

  output      logic       rx_valid_o,
  input  var logic        rx_ready_i,
  output      logic [7:0] rx_data_o,
  output      logic       rx_sof_o,
  output      logic       rx_eof_o,
  output      logic       rx_err_o,

  input  var logic        tx_valid_i,
  output      logic       tx_ready_o,
  input  var logic [7:0]  tx_data_i,
  input  var logic        tx_sof_i,
  input  var logic        tx_eof_i
);

  logic       oct_rx_en;
  logic [7:0] oct_rx_d;
  logic       oct_tx_en;
  logic [7:0] oct_tx_d;

  es_mac_rmii_serdes #(.BYTE_PERIOD(BYTE_PERIOD)) u_serdes (
    .clk_i         (clk_i),         .rst_ni       (rst_ni),
    .rmii_crs_dv_i (rmii_crs_dv_i), .rmii_rxd_i   (rmii_rxd_i),
    .rmii_tx_en_o  (rmii_tx_en_o),  .rmii_txd_o   (rmii_txd_o),
    .oct_en_o      (oct_rx_en),     .oct_d_o      (oct_rx_d),
    .oct_en_i      (oct_tx_en),     .oct_d_i      (oct_tx_d)
  );

  es_mac_frame_rx #(.BYTE_PERIOD(BYTE_PERIOD)) u_rx (
    .clk_i    (clk_i),      .rst_ni  (rst_ni),
    .oct_en_i (oct_rx_en),  .oct_d_i (oct_rx_d),
    .oct_er_i (1'b0),
    .b_valid_o(rx_valid_o), .b_ready_i(rx_ready_i),
    .b_data_o (rx_data_o),  .b_sof_o (rx_sof_o),
    .b_eof_o  (rx_eof_o),   .b_err_o (rx_err_o)
  );

  es_mac_frame_tx #(
    .BYTE_PERIOD    (BYTE_PERIOD),
    .IFG_OCTETS     (IFG_OCTETS),
    .MIN_CLIENT_LEN (MIN_CLIENT_LEN)
  ) u_tx (
    .clk_i    (clk_i),       .rst_ni   (rst_ni),
    .b_valid_i(tx_valid_i),  .b_ready_o(tx_ready_o),
    .b_data_i (tx_data_i),   .b_sof_i  (tx_sof_i),
    .b_eof_i  (tx_eof_i),
    .oct_en_o (oct_tx_en),   .oct_d_o  (oct_tx_d)
  );

endmodule : es_mac_rmii_adapt

`default_nettype wire

`endif  // ES_MAC_ADAPTERS_SV
