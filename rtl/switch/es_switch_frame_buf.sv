// ============================================================================
//  File        : es_switch_frame_buf.sv
//  Description : Per-ingress-port frame buffer for the staged switch.
//
//                Why two FIFOs and a rewind
//                -------------------------
//                A frame is only visible to the CAM/egress levels once it has
//                arrived in full and passed every check.  Until then its bytes
//                are streamed into `u_bytes`; a bad, runt or over-MTU frame is
//                removed with ONE `undo_i` pulse that rewinds the write pointer
//                by the number of bytes written, so no data has to be read
//                back and no frame is ever partially forwarded.  A legal frame
//                instead pushes one descriptor into `u_desc`.  Descriptors and
//                frames are consumed in the same order, so a slot id is not
//                needed and no run-time-indexed unpacked array is involved
//                (Icarus would return stale data for one).
//
//                `SLOTS * SLOT_BYTES` MUST be a power of two.  The rewind in
//                es_mems_sync_fifo is `wr_ptr - undo_cnt` on an ADDR_W-wide
//                pointer, while `next_slot` skips the unused encodings of a
//                non-power-of-two DEPTH; mixing the two lands on an illegal
//                encoding and corrupts the FIFO.  The elaboration check below
//                is what keeps that from being a silent, simulation-only bug.
//
//                Each ingress port has its own instance, which is also what
//                gives the TX writer one independent byte read port per source
//                port: several copy engines really can run in parallel.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_FRAME_BUF_SV
`define ES_SWITCH_FRAME_BUF_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_switch_frame_buf #(
  /// Number of maximum-size frames the buffer can hold.
  parameter int unsigned SLOTS       = 2,
  /// Bytes per frame slot; MUST be a power of two.
  parameter int unsigned SLOT_BYTES  = 2048,
  /// Descriptor FIFO depth (>= 2).
  parameter int unsigned DESC_DEPTH  = 8,
  /// Descriptor payload width, from sw_pl_desc_w().
  parameter int unsigned DESC_W      = 107
) (
  input  var logic                  clk_i,
  input  var logic                  rst_ni,

  // ---- receive byte write -----------------------------------------------
  input  var logic                  wr_en_i,
  input  var logic [7:0]            wr_data_i,
  output      logic                 wfull_o,
  output      logic [sw_pl_fifo_cnt_w(SLOTS*SLOT_BYTES)-1:0] wfree_o,

  // ---- frame-granular abort ---------------------------------------------
  input  var logic                  undo_i,
  input  var logic [sw_pl_fifo_cnt_w(SLOTS*SLOT_BYTES)-1:0] undo_cnt_i,

  // ---- legal-frame descriptor commit ------------------------------------
  input  var logic                  commit_i,
  input  var logic [DESC_W-1:0]     commit_desc_i,
  output      logic                 dfull_o,
  output      logic [sw_pl_fifo_cnt_w(DESC_DEPTH)-1:0] dfree_o,

  // ---- descriptor read (FWFT, consumed by the CAM stage) ----------------
  output      logic                 dvalid_o,
  input  var logic                  drd_i,
  output      logic [DESC_W-1:0]    dout_o,

  // ---- byte read (FWFT, consumed by the TX writer) ----------------------
  input  var logic                  brd_i,
  output      logic [7:0]           bout_o,
  output      logic                 bempty_o
);

  localparam int unsigned BYTE_DEPTH  = SLOTS * SLOT_BYTES;
  localparam int unsigned BYTE_ADDR_W = (BYTE_DEPTH <= 2) ? 1 : $clog2(BYTE_DEPTH);
  localparam int unsigned BYTE_CNT_W  = BYTE_ADDR_W + 1;
  localparam int unsigned DESC_ADDR_W = (DESC_DEPTH <= 2) ? 1 : $clog2(DESC_DEPTH);
  localparam int unsigned DESC_CNT_W  = DESC_ADDR_W + 1;

`ifndef SYNTHESIS
  // yosys has no implementation for $error, so this block is excluded from
  // synthesis exactly like the wrapper parameter checks (AGENTS.md 3.4).
  initial begin
    if (SLOTS < 1 || SLOT_BYTES < 2 || DESC_DEPTH < 2)
      $error("es_switch_frame_buf: SLOTS/SLOT_BYTES/DESC_DEPTH out of range");
    if ((BYTE_DEPTH & (BYTE_DEPTH - 1)) != 0)
      $error("es_switch_frame_buf: SLOTS*SLOT_BYTES must be a power of two for undo to be safe");
    if (SLOT_BYTES < 64)
      $error("es_switch_frame_buf: SLOT_BYTES must cover a whole frame");
  end
`endif

  logic [BYTE_CNT_W-1:0] byte_free;
  logic [DESC_CNT_W-1:0] desc_free;
  logic                  desc_empty;

  es_mems_sync_fifo #(
    .WIDTH (8),
    .DEPTH (BYTE_DEPTH)
  ) u_bytes (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .undo_i     (undo_i),
    .undo_cnt_i (undo_cnt_i),
    .flush_i    (1'b0),
    .wr_en_i    (wr_en_i),
    .wr_data_i  (wr_data_i),
    .full_o     (wfull_o),
    .free_o     (byte_free),
    .rd_en_i    (brd_i),
    .rd_data_o  (bout_o),
    .empty_o    (bempty_o)
  );

  es_mems_sync_fifo #(
    .WIDTH (DESC_W),
    .DEPTH (DESC_DEPTH)
  ) u_desc (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .undo_i     (1'b0),
    .undo_cnt_i (DESC_CNT_W'(0)),
    .flush_i    (1'b0),
    .wr_en_i    (commit_i),
    .wr_data_i  (commit_desc_i),
    .full_o     (dfull_o),
    .free_o     (desc_free),
    .rd_en_i    (drd_i),
    .rd_data_o  (dout_o),
    .empty_o    (desc_empty)
  );

  assign wfree_o  = byte_free;
  assign dfree_o  = desc_free;
  assign dvalid_o = ~desc_empty;

endmodule : es_switch_frame_buf

`default_nettype wire

`endif  // ES_SWITCH_FRAME_BUF_SV
