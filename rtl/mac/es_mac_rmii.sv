// ============================================================================
//  File        : es_mac_rmii.sv
//  Description : RMII MAC for one switch port: 2-bit dibit pins on one side,
//                the switch's beat contract on the other.
//
//                The dibit pins are reassembled into the canonical octet stream
//                by `es_mac_rmii_serdes`, and that stream is framed into beats
//                (and back) by the interface-agnostic `es_mac_core`.  RMII
//                carries no separate receive error pin, so an errored frame is
//                only ever visible through its FCS - which the receive framer
//                already reports in the beat's `crc_ok` marker.
//
//                See `es_mac_core.sv` for the beat contract, the
//                `tx_fr_ready_o` invariant and the clocking model.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MAC_RMII_SV
`define ES_MAC_RMII_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "mac/es_mac_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_mac_rmii #(
  /// `clk_i` cycles per octet time.  Must be a multiple of 4, because every octet
  /// time carries exactly four dibit windows; RMII is a 10/100 Mbit/s front-end
  /// and the 1000 Mbit/s value of 1 is rejected at elaboration.
  parameter int unsigned BYTE_PERIOD = 4,
  /// Depth of the elastic receive beat buffer; see `es_mac_core`.
  parameter int unsigned WF_DEPTH    = 16
) (
  /// Clock and synchronous active-low reset.
  input var logic clk_i,
  input var logic rst_ni,
  /// Administrative port enable; gates received octets only.
  input var logic link_up_i,

  // ---- RMII pins -----------------------------------------------------------
  /// Carrier sense / data valid and low-chunk-first receive dibits.
  input  var logic       rmii_crs_dv_i,
  input  var logic [1:0] rmii_rxd_i,
  /// Transmit enable and low-chunk-first dibits.
  output logic       rmii_tx_en_o,
  output logic [1:0] rmii_txd_o,

  // ---- receive beats to the switch -----------------------------------------
  /// Head beat, its frame markers and the FCS verdict.
  output logic        rx_beat_valid_o,
  output logic [63:0] rx_beat_data_o,
  output logic        rx_beat_sof_o,
  output logic        rx_beat_eof_o,
  output logic        rx_beat_crc_ok_o,
  output logic [3:0]  rx_beat_octets_o,
  /// Pop the head beat.
  input  var logic    rx_beat_rd_i,

  // ---- frame and beats from the switch -------------------------------------
  /// Head frame offered by the egress buffer, its length, and its acceptance.
  input  var logic                tx_fr_valid_i,
  input  var logic [SW_LEN_W-1:0] tx_fr_len_i,
  output logic                    tx_fr_ready_o,
  /// Head payload beat of the frame in progress, and its pop.
  input  var logic        tx_beat_valid_i,
  input  var logic [63:0] tx_beat_data_i,
  output logic            tx_beat_rd_o
);

  // --------------------------------------------------------------------------
  // Symbol serialiser: dibits <-> canonical octets
  // --------------------------------------------------------------------------
  logic       ser_rx_oct_en;
  logic [7:0] ser_rx_oct_data;
  logic       ser_tx_oct_en;
  logic [7:0] ser_tx_oct_data;

  es_mac_rmii_serdes #(
    .BYTE_PERIOD (BYTE_PERIOD)
  ) u_serdes (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .rmii_crs_dv_i(rmii_crs_dv_i),
    .rmii_rxd_i   (rmii_rxd_i),
    .rmii_tx_en_o (rmii_tx_en_o),
    .rmii_txd_o   (rmii_txd_o),
    .oct_en_o     (ser_rx_oct_en),
    .oct_d_o      (ser_rx_oct_data),
    .oct_en_i     (ser_tx_oct_en),
    .oct_d_i      (ser_tx_oct_data)
  );

  // --------------------------------------------------------------------------
  // Interface-agnostic frame path.  The serialiser's canonical octet stream is
  // the core's line side; `link_up_i` is gated inside the core.
  // --------------------------------------------------------------------------
  es_mac_core #(
    .BYTE_PERIOD (BYTE_PERIOD),
    .WF_DEPTH    (WF_DEPTH)
  ) u_core (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .link_up_i        (link_up_i),
    .oct_en_i         (ser_rx_oct_en),
    .oct_d_i          (ser_rx_oct_data),
    .oct_en_o         (ser_tx_oct_en),
    .oct_d_o          (ser_tx_oct_data),
    .rx_beat_valid_o  (rx_beat_valid_o),
    .rx_beat_data_o   (rx_beat_data_o),
    .rx_beat_sof_o    (rx_beat_sof_o),
    .rx_beat_eof_o    (rx_beat_eof_o),
    .rx_beat_crc_ok_o (rx_beat_crc_ok_o),
    .rx_beat_octets_o (rx_beat_octets_o),
    .rx_beat_rd_i     (rx_beat_rd_i),
    .tx_fr_valid_i    (tx_fr_valid_i),
    .tx_fr_len_i      (tx_fr_len_i),
    .tx_fr_ready_o    (tx_fr_ready_o),
    .tx_beat_valid_i  (tx_beat_valid_i),
    .tx_beat_data_i   (tx_beat_data_i),
    .tx_beat_rd_o     (tx_beat_rd_o)
  );

endmodule : es_mac_rmii

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_MAC_RMII_SV
