// ============================================================================
//  File        : es_switch_tx_port.sv
//  Description : Egress datapath of one Layer-2 switch port.
//
//                The fabric queues a frame as a run of 64-bit beats plus a
//                length descriptor.  This module buffers the beats in an egress
//                FIFO, offers each complete frame to the port's MAC one at a
//                time and keeps the statistics.
//
//                The length descriptor has its own small FIFO, written once per
//                frame (qualified by `wr_fr_i`) while *all* beats of that frame
//                share one `wr_en_i` pulse each.  The descriptor is popped at
//                the moment the frame is handed over to the MAC, so the two
//                streams cannot drift apart.
//
//                The fabric guarantees that the complete frame fits into the
//                egress FIFO before it starts writing it, which is what lets
//                the MAC serialiser run without a single stall.
//
//                The frame handshake (`tx_fr_valid_o` / `tx_fr_ready_i`) plus
//                the beat stream (`tx_beat_valid_o` / `tx_beat_data_o` /
//                `tx_beat_rd_i`) carry everything the MAC needs: how long the
//                frame is and which beats belong to it.  Preamble, SFD,
//                padding, FCS and the inter-frame gap are the MAC's business.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef ES_SWITCH_TX_PORT_SV
`define ES_SWITCH_TX_PORT_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

// The shared declarations (`SW_LEN_W`, `sw_tx_free_width`) arrive through the
// include above and are visible at compilation-unit scope, which is what lets
// them appear in a port range.  See es_defs.sv for why a package cannot be used
// here.
module es_switch_tx_port #(
  /// Egress payload capacity in 64-bit beats.
  parameter int unsigned TX_FIFO_DEPTH  = 256,
  /// Number of queued frame-length descriptors.
  parameter int unsigned LEN_FIFO_DEPTH = 8
) (
  /// Clock/reset and frame-beat writes from the switching fabric.
  input var logic clk_i,
  input var logic rst_ni,

  // ---- fabric write side ---------------------------------------------------
  input var logic                wr_en_i,   ///< a payload beat is offered
  input var logic [63:0]         wr_data_i,
  input var logic [SW_LEN_W-1:0] wr_len_i,  ///< valid together with `wr_fr_i`
  input var logic                wr_fr_i,   ///< this beat starts a new frame

  // ---- frame and beat handshake to the MAC ---------------------------------
  //
  // One frame is offered at a time: `tx_fr_valid_o` stays asserted with the
  // frame's length until the MAC answers with `tx_fr_ready_i` in the same
  // clock, and that single coincident cycle is the start of the frame.  The
  // MAC then pulls the frame's beats with `tx_beat_rd_i` at whatever the line
  // rate allows.
  //
  // `tx_fr_ready_i` may only ever be a registered "not busy" flag inside the
  // MAC.  If it were derived combinationally from the beat stream - from
  // `tx_beat_valid_o`, say - then valid/ready/descriptor-empty would form a
  // loop through two modules, which Verilator reports as UNOPTFLAT and which
  // yosys turns into a latch.
  /// Head frame offered to the MAC, and its length in octets (FCS excluded).
  output    logic                     tx_fr_valid_o,
  output    logic [SW_LEN_W-1:0]      tx_fr_len_o,
  input  var logic                    tx_fr_ready_i,
  /// Head payload beat of the frame in progress, and its pop.
  output    logic                     tx_beat_valid_o,
  output    logic [63:0]              tx_beat_data_o,
  input  var logic                    tx_beat_rd_i,

  // ---- egress capacity (consumed by the arbiter) ---------------------------
  // Two separate limits, because there are two separate buffers, and reporting
  // only one of them is what lets a frame end up buffered with nothing to
  // launch it.
  //
  // `free_o` is the payload headroom in beats.  `slot_o` says whether one more
  // *complete frame* can be started at all, which is the length-descriptor
  // FIFO's state.  A frame with no descriptor can never be serialised, so a beat
  // slot without a descriptor is not usable capacity.
  //
  // Reporting only `free_o` lets the fabric queue more frames than there are
  // descriptors - the beat FIFO holds TX_FIFO_DEPTH/8 = 32 minimum-length frames
  // while only LEN_FIFO_DEPTH = 8 descriptors exist.  The ninth frame is then
  // written into the payload buffer and its descriptor write is dropped, because
  // `u_len_fifo` ignores a write while it is full.  That frame can never be
  // transmitted: it sits in the buffer forever, the port serialises the eight
  // frames it does have descriptors for and then goes idle with dead payload
  // behind it, and once the beat FIFO fills up *every* frame that lists this
  // port as a destination fails the admission check.  On a switch whose ports
  // flood to one another, that is a single frame wedging the whole fabric.
  /// Payload headroom and descriptor availability; both are required to admit.
  output    logic [sw_tx_free_width(TX_FIFO_DEPTH):0] free_o,
  output    logic                                     slot_o,  ///< a whole frame still fits

  // ---- status / statistics -------------------------------------------------
  /// Per-port counters indexed by sw_stat_id_e.
  output    logic [32*SW_STAT_COUNT-1:0] stat_o);

  // --------------------------------------------------------------------------
  // Queues and handshakes
  // --------------------------------------------------------------------------
  logic                len_empty; ///< no frame descriptor queued
  logic [SW_LEN_W-1:0] len_data;  ///< FWFT head of the descriptor FIFO
  logic                data_empty;  ///< no payload beat queued
  logic [63:0]         data_rd_data;  ///< FWFT head of the egress beat FIFO
  /// Free space in the length-descriptor FIFO.  Its width is whatever that FIFO
  /// needs; only "is it non-zero" is used, so it is reduced to one bit here.
  logic [sw_tx_free_width(LEN_FIFO_DEPTH):0] len_free;

  assign slot_o = (len_free != '0);

  // A frame starts on the single clock where a descriptor is available and the
  // MAC accepts it.  Before the MAC layer was extracted this read
  // `!len_empty && !tx_busy`, with `tx_busy` the serialiser's own register
  // inside this module; `tx_fr_ready_i` is the same register seen through a
  // port, so the two forms are equivalent cycle for cycle.  What must not
  // happen is `tx_fr_ready_i` being derived from the beat stream: that would
  // close a loop through the MAC (see the port comment).
  logic fr_start;
  assign fr_start = tx_fr_valid_o && tx_fr_ready_i;

  assign tx_fr_valid_o   = !len_empty;
  assign tx_fr_len_o     = len_data;
  assign tx_beat_valid_o = !data_empty;
  assign tx_beat_data_o  = data_rd_data;

  // --------------------------------------------------------------------------
  // Egress beat FIFO
  // --------------------------------------------------------------------------
  /* verilator lint_off PINCONNECTEMPTY */
  es_mems_sync_fifo #(
    .WIDTH (64),
    .DEPTH (TX_FIFO_DEPTH)
  ) u_data_fifo (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .undo_i     (1'b0),
    .undo_cnt_i ('0),
    .flush_i    (1'b0),
    .wr_en_i    (wr_en_i),
    .wr_data_i  (wr_data_i),
    .full_o     (),  // the fabric guarantees the whole frame fits
    .free_o     (free_o),
    .rd_en_i    (tx_beat_rd_i),
    .rd_data_o  (data_rd_data),
    .empty_o    (data_empty)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // --------------------------------------------------------------------------
  // Frame length descriptor FIFO
  //
  // Written once per frame: `wr_en_i` pulses for every beat, `wr_fr_i` marks
  // the first one.
  // --------------------------------------------------------------------------
  /* verilator lint_off PINCONNECTEMPTY */
  es_mems_sync_fifo #(
    .WIDTH (SW_LEN_W),
    .DEPTH (LEN_FIFO_DEPTH)
  ) u_len_fifo (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .undo_i     (1'b0),
    .undo_cnt_i ('0),
    .flush_i    (1'b0),
    .wr_en_i    (wr_en_i & wr_fr_i),
    .wr_data_i  (wr_len_i),
    .full_o     (),  // one descriptor per frame; `slot_o` gates the fabric
    .free_o     (len_free),
    .rd_en_i    (fr_start),
    .rd_data_o  (len_data),
    .empty_o    (len_empty)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // --------------------------------------------------------------------------
  // Statistics
  //
  // Counted on `fr_start`, i.e. when the descriptor is handed to the serialiser,
  // so a frame that is queued but never reaches the wire is not counted.
  // --------------------------------------------------------------------------
  logic [31:0] cnt_frames;
  logic [31:0] cnt_octets;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      cnt_frames <= 32'd0;
      cnt_octets <= 32'd0;
    end else if (fr_start) begin
      cnt_frames <= cnt_frames + 32'd1;
      cnt_octets <= cnt_octets + {21'd0, len_data[10:0]};
    end
  end

  assign stat_o[32*int'(SW_STAT_TX_FRAMES) +: 32] = cnt_frames;
  assign stat_o[32*int'(SW_STAT_TX_OCTETS) +: 32] = cnt_octets;

  // The remaining counters belong to the receive path, the CAM and the
  // scheduler; they are zeroed here and summed by the top level.
  // Quartus's parser rejects the SV inline form `for (genvar gk = 0; ...)` and
  // also rejects a bare module-level `for` - every loop carries an explicit
  // `generate`/`endgenerate` wrapper; yosys, Verilator and Icarus accept
  // all forms (see es_switch_arbiter.sv for the full note).
  genvar gk;

  generate
    for (gk = 0; gk < int'(SW_STAT_COUNT); gk++) begin : g_stat_zero
      if ((gk != int'(SW_STAT_TX_FRAMES)) &&
          (gk != int'(SW_STAT_TX_OCTETS))) begin : g_stat_zero_other
        assign stat_o[32*gk +: 32] = 32'd0;
      end
    end
  endgenerate

endmodule : es_switch_tx_port

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_SWITCH_TX_PORT_SV
