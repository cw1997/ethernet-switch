// ============================================================================
//  File        : es_mac_gmii.sv
//  Description : GMII MAC for one switch port: the physical pins on one side,
//                the switch's beat contract on the other.
//
//                GMII is octet-aligned - one 8-bit octet per octet time - so the
//                pins already carry the octet stream the frame layer wants and
//                no symbol serialiser is needed here.  This module is therefore
//                just the pin wiring into the interface-agnostic `es_mac_core`,
//                which owns the receive framer, the transmit framer and the
//                elastic receive buffer.  See `es_mac_core.sv` for the beat
//                contract, the `tx_fr_ready_o` invariant and the clocking model.
//
//                Clocking
//                --------
//                Single `clk_i`, no PHY clock inputs, exactly like the rest of
//                the design.  Capturing an asynchronous RX_CLK into this domain
//                is the board shell's job; nothing in this module changes when
//                that is added.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MAC_GMII_SV
`define ES_MAC_GMII_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "mac/es_mac_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_mac_gmii #(
  /// `clk_i` cycles per octet time: 1 at 1000 Mbit/s on a 125 MHz core, 10 at
  /// 100 Mbit/s, 100 at 10 Mbit/s.
  parameter int unsigned BYTE_PERIOD = 1,
  /// Depth of the elastic receive beat buffer; see `es_mac_core`.
  parameter int unsigned WF_DEPTH    = 16
) (
  /// Clock and synchronous active-low reset.
  input var logic clk_i,
  input var logic rst_ni,
  /// Administrative port enable.  A down port presents no receive octets, so
  /// nothing is parsed and nothing is learned from it.
  input var logic link_up_i,

  // ---- GMII pins -----------------------------------------------------------
  /// Octet-aligned receive and transmit pins for this port.
  input  var logic       gmii_rx_en_i,
  input  var logic [7:0] gmii_rx_d_i,
  output logic           gmii_tx_en_o,
  output logic [7:0]     gmii_tx_d_o,

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
  // Interface-agnostic frame path.  The GMII pins are octet-aligned, so they
  // connect straight through to the canonical octet stream; `link_up_i` is
  // gated inside the core.
  // --------------------------------------------------------------------------
  es_mac_core #(
    .BYTE_PERIOD (BYTE_PERIOD),
    .WF_DEPTH    (WF_DEPTH)
  ) u_core (
    .clk_i            (clk_i),
    .rst_ni           (rst_ni),
    .link_up_i        (link_up_i),
    .oct_en_i         (gmii_rx_en_i),
    .oct_d_i          (gmii_rx_d_i),
    .oct_en_o         (gmii_tx_en_o),
    .oct_d_o          (gmii_tx_d_o),
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

endmodule : es_mac_gmii

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_MAC_GMII_SV
