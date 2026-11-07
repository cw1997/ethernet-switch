// ============================================================================
//  File        : es_mac_mii.sv
//  Description : MII MAC for one switch port: 4-bit nibble pins on one side,
//                the switch's beat contract on the other.
//
//                The chain is the same as `es_mac_gmii` with one stage added at
//                each end: the nibble pins are reassembled into the canonical
//                octet stream by `es_mac_mii_serdes`, that stream is framed into
//                beats by `es_mac_rx_frame`, and on transmit the framer's octet
//                stream is split back into nibbles by the same serialiser.
//
//                Only the receive octets are gated by `link_up_i`.  The
//                serialiser is left free-running so that its nibble window
//                counter stays on the grid the PHY is transmitting on; gating it
//                would make the transmit windows start at an arbitrary phase
//                after the link came up.
//
//                Beat contract, `tx_fr_ready_o` and the clocking model are
//                identical to `es_mac_gmii`; see that file for why `ready` may
//                only ever come from the framer's busy register.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MAC_MII_SV
`define ES_MAC_MII_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "mac/es_mac_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_mac_mii #(
  /// `clk_i` cycles per octet time.  Must be even and at least 2, because every
  /// octet time carries exactly two nibble windows; MII is a 10/100 Mbit/s
  /// front-end and the 1000 Mbit/s value of 1 is rejected at elaboration.
  parameter int unsigned BYTE_PERIOD = 2,
  /// Depth of the elastic receive beat buffer; see `es_mac_gmii`.
  parameter int unsigned WF_DEPTH    = 16
) (
  /// Clock and synchronous active-low reset.
  input var logic clk_i,
  input var logic rst_ni,
  /// Administrative port enable; gates received octets only.
  input var logic link_up_i,

  // ---- MII pins ------------------------------------------------------------
  /// Low-nibble-first receive symbols with the PHY's error indication.
  input  var logic       mii_rx_dv_i,
  input  var logic       mii_rx_er_i,
  input  var logic [3:0] mii_rxd_i,
  /// Low-nibble-first transmit symbols; the error pin is never asserted because
  /// this design has no transmit error source.
  output logic       mii_tx_en_o,
  output logic       mii_tx_er_o,
  output logic [3:0] mii_txd_o,

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
  // Symbol serialiser: nibbles <-> canonical octets
  // --------------------------------------------------------------------------
  logic       ser_rx_oct_en;
  logic [7:0] ser_rx_oct_data;
  logic       ser_tx_oct_en;
  logic [7:0] ser_tx_oct_data;
  logic       fr_tx_oct_en;
  logic [7:0] fr_tx_oct_data;

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
    .oct_en_o    (ser_rx_oct_en),
    .oct_d_o     (ser_rx_oct_data),
    .oct_en_i    (ser_tx_oct_en),
    .oct_d_i     (ser_tx_oct_data)
  );

  assign ser_tx_oct_en   = fr_tx_oct_en;
  assign ser_tx_oct_data = fr_tx_oct_data;

  // --------------------------------------------------------------------------
  // Receive framer: octets to beats, FCS checked at the octet rate
  // --------------------------------------------------------------------------
  logic        frame_valid;
  logic [63:0] frame_data;
  logic        frame_sof;
  logic        frame_eof;
  logic        frame_crc_ok;
  logic [3:0]  frame_octets;

  es_mac_rx_frame #(
    .BYTE_PERIOD (BYTE_PERIOD)
  ) u_rx_frame (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    .oct_en_i      (ser_rx_oct_en & link_up_i),
    .oct_d_i       (ser_rx_oct_data),
    .beat_valid_o  (frame_valid),
    .beat_data_o   (frame_data),
    .beat_sof_o    (frame_sof),
    .beat_eof_o    (frame_eof),
    .beat_crc_ok_o (frame_crc_ok),
    .beat_octets_o (frame_octets)
  );

  // --------------------------------------------------------------------------
  // Elastic receive buffer; see `es_mac_gmii` for the shape and the drop rule.
  // --------------------------------------------------------------------------
  logic                   wf_wr_en;
  logic [SW_MAC_WF_W-1:0] wf_wr_data;
  logic                   wf_rd_en;
  logic [SW_MAC_WF_W-1:0] wf_rd_data;
  logic                   wf_empty;

  assign wf_wr_en   = frame_valid;
  assign wf_wr_data = {frame_octets, frame_crc_ok, frame_eof, frame_sof, frame_data};
  assign wf_rd_en   = rx_beat_rd_i;

  assign rx_beat_valid_o  = !wf_empty;
  assign rx_beat_data_o   = wf_rd_data[63:0];
  assign rx_beat_sof_o    = wf_rd_data[64];
  assign rx_beat_eof_o    = wf_rd_data[65];
  assign rx_beat_crc_ok_o = wf_rd_data[66];
  assign rx_beat_octets_o = wf_rd_data[67 +: 4];

  /* verilator lint_off PINCONNECTEMPTY */
  es_mems_sync_fifo #(
    .WIDTH (SW_MAC_WF_W),
    .DEPTH (WF_DEPTH)
  ) u_wf (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .undo_i     (1'b0),
    .undo_cnt_i ('0),
    .flush_i    (1'b0),
    .wr_en_i    (wf_wr_en),
    .wr_data_i  (wf_wr_data),
    .full_o     (),
    .free_o     (),
    .rd_en_i    (wf_rd_en),
    .rd_data_o  (wf_rd_data),
    .empty_o    (wf_empty)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // --------------------------------------------------------------------------
  // Transmit framer: beats to octets, then octets to nibbles above
  // --------------------------------------------------------------------------
  logic tx_busy;
  logic unused_tx_done;
  logic [SW_LEN_W-1:0] unused_tx_len;
  logic unused_tx_status;

  assign tx_fr_ready_o = !tx_busy;
  assign unused_tx_status = unused_tx_done ^ (^unused_tx_len);

  es_mac_tx_frame #(
    .BYTE_PERIOD (BYTE_PERIOD)
  ) u_tx_frame (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .fr_start_i  (tx_fr_valid_i && tx_fr_ready_o),
    .fr_len_i    (tx_fr_len_i),
    .done_o      (unused_tx_done),
    .done_len_o  (unused_tx_len),
    .tx_busy_o   (tx_busy),
    .beat_valid_i(tx_beat_valid_i),
    .beat_data_i (tx_beat_data_i),
    .beat_rd_o   (tx_beat_rd_o),
    .oct_en_o    (fr_tx_oct_en),
    .oct_d_o     (fr_tx_oct_data)
  );

endmodule : es_mac_mii

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_MAC_MII_SV
