// ============================================================================
//  File        : sw_tx_port.sv
//  Description : Egress datapath of one Layer-2 switch port.
//
//                The fabric queues a frame as a run of 64-bit beats plus a
//                length descriptor.  This module buffers the beats in an egress
//                FIFO, hands them to the GMII transmit adapter one frame at a
//                time and keeps the statistics.
//
//                The length descriptor has its own small FIFO, written once per
//                frame (qualified by `wr_fr_i`) while *all* beats of that frame
//                share one `wr_en_i` pulse each.  The descriptor is popped at
//                the moment the frame is handed over to the serialiser, so the
//                two streams cannot drift apart.
//
//                The fabric guarantees that the complete frame fits into the
//                egress FIFO before it starts writing it, which is what lets
//                the serialiser run without a single stall.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef SW_TX_PORT_SV
`define SW_TX_PORT_SV

`include "sw_switch_pkg.sv"

// ---------------------------------------------------------------------------
//  Package import
//
//  The package is pulled in by the guarded `include` above, which is what makes
//  its declarations visible here.  Under simulation an explicit wildcard import
//  is added as well, because a simulator resolves a package strictly: without it
//  the port list and the body cannot see `sw_switch_pkg` items.
//
//  Under synthesis the import is omitted.  The yosys frontend that OpenLane /
//  LibreLane drive does not accept a wildcard package import at all - neither in
//  a module header, nor inside the body, nor at file scope - and aborts with
//
//      syntax error, unexpected TOK_ID, expecting '(' or ';' or '#'
//
//  right at the module keyword, which points at the module rather than at the
//  import.  It does, however, make the items of an *included* package visible for
//  free, so dropping the import is both necessary and sufficient.  The two forms
//  below therefore differ only in the two tokens between the module name and its
//  port list; everything after the `endif is shared.
// ---------------------------------------------------------------------------
`ifndef SYNTHESIS
module sw_tx_port import sw_switch_pkg::*; #(
`else
module sw_tx_port #(
`endif
  parameter int unsigned BYTE_PERIOD    = 1,     ///< clk_i cycles per GMII octet
  parameter int unsigned TX_FIFO_DEPTH  = 256,   ///< egress beats buffered
  parameter int unsigned LEN_FIFO_DEPTH = 8      ///< frame length descriptors
) (
  input  logic                    clk_i,
  input  logic                    rst_ni,

  // ---- fabric write side ---------------------------------------------------
  input  logic                    wr_en_i,     ///< a payload beat is offered
  input  logic [63:0]             wr_data_i,
  input  logic [SW_LEN_W-1:0]     wr_len_i,    ///< valid together with `wr_fr_i`
  input  logic                    wr_fr_i,     ///< this beat starts a new frame

  // ---- GMII transmit interface ---------------------------------------------
  output logic                    gmii_en_o,
  output logic [7:0]              gmii_d_o,

  // ---- egress buffer occupancy (consumed by the arbiter) ------------------
  output logic [sw_tx_free_width(TX_FIFO_DEPTH):0] free_o,

  // ---- status / statistics -------------------------------------------------
  output logic [32*SW_STAT_COUNT-1:0] stat_o
);

  logic        tx_busy;
  logic        len_empty;
  logic [SW_LEN_W-1:0] len_data;
  logic        data_empty;
  logic [63:0] data_rd_data;   ///< FWFT head of the egress beat FIFO
  logic        beat_rd;

  // A new frame is started as soon as a descriptor is available and the
  // serialiser has finished the inter-frame gap of the previous one.
  logic fr_start;
  assign fr_start = !len_empty && !tx_busy;

  sw_gmii_tx #(
      .BYTE_PERIOD (BYTE_PERIOD)
  ) u_gmii_tx (
      .clk_i      (clk_i),
      .rst_ni     (rst_ni),
      .fr_start_i (fr_start),
      .fr_len_i   (len_data),
      .tx_busy_o  (tx_busy),
      .beat_valid_i(!data_empty),
      .beat_data_i (data_rd_data),
      .beat_rd_o  (beat_rd),
      .gmii_en_o  (gmii_en_o),
      .gmii_d_o   (gmii_d_o)
  );

  // ---- egress beat FIFO -----------------------------------------------------
  /* verilator lint_off PINCONNECTEMPTY */
  sw_sync_fifo #(
      .WIDTH (64),
      .DEPTH (TX_FIFO_DEPTH)
  ) u_data_fifo (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .undo_i    (1'b0),
      .undo_cnt_i('0),
      .flush_i   (1'b0),
      .wr_en_i   (wr_en_i),
      .wr_data_i (wr_data_i),
      .full_o    (),      // the fabric guarantees the whole frame fits
      .free_o    (free_o),
      .rd_en_i   (beat_rd),
      .rd_data_o (data_rd_data),
      .empty_o   (data_empty)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- frame length descriptor FIFO ----------------------------------------
  // Written once per frame: `wr_en_i` pulses for every beat, `wr_fr_i` marks
  // the first one.
  /* verilator lint_off PINCONNECTEMPTY */
  sw_sync_fifo #(
      .WIDTH (SW_LEN_W),
      .DEPTH (LEN_FIFO_DEPTH)
  ) u_len_fifo (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .undo_i    (1'b0),
      .undo_cnt_i('0),
      .flush_i   (1'b0),
      .wr_en_i   (wr_en_i & wr_fr_i),
      .wr_data_i (wr_len_i),
      .full_o    (),      // one descriptor per frame, bounded by the fabric
      .free_o    (),
      .rd_en_i   (fr_start),
      .rd_data_o (len_data),
      .empty_o   (len_empty)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // ---- statistics -----------------------------------------------------------
  logic [31:0] cnt_frames, cnt_octets;
  assign stat_o[32*int'(SW_STAT_TX_FRAMES) +: 32] = cnt_frames;
  assign stat_o[32*int'(SW_STAT_TX_OCTETS) +: 32] = cnt_octets;
  // The remaining counters belong to the receive path, the CAM and the
  // scheduler; they are zeroed here and summed by the top level.
  for (genvar gk = 0; gk < int'(SW_STAT_COUNT); gk++) begin : g_stat_zero
    if ((gk != int'(SW_STAT_TX_FRAMES)) && (gk != int'(SW_STAT_TX_OCTETS))) begin : g_stat_zero_other
      assign stat_o[32*gk +: 32] = 32'd0;
    end
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      cnt_frames <= 32'd0;
      cnt_octets <= 32'd0;
    end else if (fr_start) begin
      cnt_frames <= cnt_frames + 32'd1;
      cnt_octets <= cnt_octets + {21'd0, len_data[10:0]};
    end
  end

endmodule : sw_tx_port

`endif // SW_TX_PORT_SV
