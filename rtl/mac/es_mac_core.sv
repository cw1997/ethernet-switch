// ============================================================================
//  File        : es_mac_core.sv
//  Description : Interface-agnostic MAC frame path for one switch port: the
//                canonical octet stream on one side, the switch's beat contract
//                on the other.
//
//                This is the part every `es_mac_*` front-end shares.  A line
//                interface - GMII pins, or an MII/RMII serdes - only ever
//                produces or consumes the canonical clock-enable-qualified
//                octet stream (`oct_en_i` / `oct_d_i`, `oct_en_o` / `oct_d_o`),
//                so this module owns everything between that stream and the
//                64-bit beat contract: receive framing and FCS check, the
//                elastic receive buffer, transmit framing and FCS generation,
//                and the per-frame transmit handshake.
//
//                Beat contract
//                -------------
//                Receive is first-word-fall-through: `rx_beat_valid_o` and the
//                payload describe the head beat in the same clock and
//                `rx_beat_rd_i` pops it.  Transmit is a per-frame handshake
//                (`tx_fr_valid_i` / `tx_fr_ready_o`) followed by a beat stream
//                this module pulls with `tx_beat_rd_o`.
//
//                `tx_fr_ready_o` is derived from `tx_busy` inside
//                `es_mac_tx_frame` and from nothing else.  It must never be
//                derived from the beat stream: `tx_fr_valid_i` comes from the
//                egress descriptor FIFO, so a ready that depended on
//                `tx_beat_valid_i` would close a combinational loop through two
//                modules.  Verilator reports that as UNOPTFLAT and yosys turns
//                it into a latch.
//
//                Clocking
//                --------
//                Single `clk_i`, no PHY clock inputs, exactly like the rest of
//                the design.  Capturing an asynchronous line clock into this
//                domain is the board shell's job; nothing in this module
//                changes when that is added.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MAC_CORE_SV
`define ES_MAC_CORE_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "mac/es_mac_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_mac_core #(
  /// `clk_i` cycles per octet time of the canonical octet stream: 1 at
  /// 1000 Mbit/s on a 125 MHz core, 10 at 100 Mbit/s, 100 at 10 Mbit/s.
  parameter int unsigned BYTE_PERIOD = 1,
  /// Depth of the elastic receive beat buffer.  A frame is never admitted to
  /// the switch unless the whole frame fits its ingress FIFO, so this only has
  /// to absorb the parser's short stalls.
  parameter int unsigned WF_DEPTH    = 16
) (
  /// Clock and synchronous active-low reset.
  input var logic clk_i,
  input var logic rst_ni,
  /// Administrative port enable.  A down port presents no receive octets, so
  /// nothing is parsed and nothing is learned from it.
  input var logic link_up_i,

  // ---- canonical octet stream (towards the line interface / serdes) --------
  /// Receive octet stream, already on the canonical octet grid; only the
  /// enable is gated by `link_up_i` here.
  input  var logic       oct_en_i,
  input  var logic [7:0] oct_d_i,
  /// Transmit octet stream produced on the canonical octet grid.
  output logic           oct_en_o,
  output logic [7:0]     oct_d_o,

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
    .oct_en_i      (oct_en_i & link_up_i),
    .oct_d_i       (oct_d_i),
    .beat_valid_o  (frame_valid),
    .beat_data_o   (frame_data),
    .beat_sof_o    (frame_sof),
    .beat_eof_o    (frame_eof),
    .beat_crc_ok_o (frame_crc_ok),
    .beat_octets_o (frame_octets)
  );

  // --------------------------------------------------------------------------
  // Elastic receive buffer
  //
  // A PHY cannot be paused mid-frame, so the framer is free-running and this
  // FIFO is what absorbs the parser's stalls.  Its read side is exported
  // directly - no register in between - so that a beat is visible to the switch
  // in the same clock the FIFO head changes, which is the shape the parser's
  // `pop` expression assumes.
  //
  // A write while full is dropped.  That is safe only because the switch admits
  // a frame into its ingress FIFO before it starts draining, and drains
  // unconditionally otherwise, so the FIFO cannot stay full for the length of a
  // frame.  If that ever changes, this FIFO must grow rather than the drop rule
  // staying silent.
  // --------------------------------------------------------------------------
  logic              wf_wr_en;
  logic [SW_MAC_WF_W-1:0] wf_wr_data;
  logic              wf_rd_en;
  logic [SW_MAC_WF_W-1:0] wf_rd_data;
  logic              wf_empty;

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
    .full_o     (),  // see the drop rule above
    .free_o     (),
    .rd_en_i    (wf_rd_en),
    .rd_data_o  (wf_rd_data),
    .empty_o    (wf_empty)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // --------------------------------------------------------------------------
  // Transmit framer: beats to a wire-legal frame
  // --------------------------------------------------------------------------
  logic tx_busy;
  logic unused_tx_done;
  logic [SW_LEN_W-1:0] unused_tx_len;
  logic unused_tx_status;

  assign tx_fr_ready_o = !tx_busy;

  // Completion is a statistic the switch no longer consumes: a frame is counted
  // when its descriptor is accepted, and the egress port derives its counters
  // from that same event.  Reducing the outputs keeps "nothing reads this" an
  // explicit decision rather than a dangling port.
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
    .oct_en_o    (oct_en_o),
    .oct_d_o     (oct_d_o)
  );

endmodule : es_mac_core

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_MAC_CORE_SV
