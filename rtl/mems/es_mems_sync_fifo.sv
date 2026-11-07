// ============================================================================
//  File        : es_mems_sync_fifo.sv
//  Description : Parameterised synchronous FIFO with a first-word-fall-through
//                (FWFT) read port and a *frame-granular abort* capability.
//
//                Two extra facilities are needed by the switch datapath:
//
//                * `undo_*` - rewind the write pointer by N entries.  The
//                  receive path uses this to discard a frame that was streamed
//                  into the FIFO but turned out to be corrupt (bad FCS, runt,
//                  oversize, ingress filter drop).  Because a frame is always
//                  the newest data in the buffer, a simple pointer rewind is
//                  enough and no data has to be read back.
//
//                * `flush_i` - hard reset of both pointers, used to drop
//                  everything currently buffered.
//
//                Entries already read by the consumer are never touched by the
//                rewind, so the operation is safe while the read side runs.
//
//                The FWFT property is what lets the fabric inspect the head
//                entry without consuming it: `rd_data_o` is valid while
//                `empty_o` is low, and `rd_en_i` advances the pointer.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MEMS_SYNC_FIFO_SV
`define ES_MEMS_SYNC_FIFO_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

module es_mems_sync_fifo #(
  /// Entry width in bits.
  parameter int unsigned WIDTH  = 64,
  /// Number of entries; any value >= 2, not necessarily a power of two.
  parameter int unsigned DEPTH  = 16,
  /// Address width; `$clog2` rounds a non-power-of-two DEPTH up, and the
  /// pointer wrap in `next_slot` skips the unused encodings.
  parameter int unsigned ADDR_W = (DEPTH <= 2) ? 1 : $clog2(DEPTH),
  /// Occupancy / free-space counter width: one extra bit for the DEPTH+1 state.
  parameter int unsigned CNT_W  = ADDR_W + 1
) (
  input var logic clk_i,
  input var logic rst_ni,

  // ---- abort (rewind) ------------------------------------------------------
  input var logic             undo_i,       ///< rewind the write pointer
  input var logic [CNT_W-1:0] undo_cnt_i,   ///< number of entries to discard

  // ---- hard flush ----------------------------------------------------------
  input var logic flush_i,  ///< drop every buffered entry

  // ---- write port ----------------------------------------------------------
  input var logic             wr_en_i,
  input var logic [WIDTH-1:0] wr_data_i,
  output    logic             full_o,
  output    logic [CNT_W-1:0] free_o,  ///< entries that can still be written

  // ---- read port (FWFT) ----------------------------------------------------
  input var logic             rd_en_i,
  output    logic [WIDTH-1:0] rd_data_o,  ///< head entry, valid while !empty_o
  output    logic             empty_o
);

  // --------------------------------------------------------------------------
  // Pointers and occupancy
  // --------------------------------------------------------------------------
  logic [ADDR_W-1:0] wr_ptr;
  logic [ADDR_W-1:0] rd_ptr;
  logic [CNT_W-1:0]  count;

  // --------------------------------------------------------------------------
  // Write and read qualification
  //
  // A rewind or a flush suppresses the write in the same clock, so the two
  // operations can never fight over the write pointer.
  // --------------------------------------------------------------------------
  logic do_write;
  logic do_read;

  assign do_write = wr_en_i && !full_o && !undo_i && !flush_i;
  assign do_read  = rd_en_i && !empty_o;

  // --------------------------------------------------------------------------
  // Pointer increment
  //
  // It wraps at DEPTH, which is not necessarily a power of two, so a plain +1
  // on an `$clog2`-wide pointer would run off the end into an unused encoding.
  // --------------------------------------------------------------------------
  function automatic logic [ADDR_W-1:0] next_slot(input var logic [ADDR_W-1:0] cur);
    next_slot = (cur == (ADDR_W'(DEPTH) - ADDR_W'(1))) ? '0 : (cur + ADDR_W'(1));
  endfunction

  // --------------------------------------------------------------------------
  // Occupancy
  //
  // A clock in which an entry is written *and* an entry is read leaves the
  // occupancy unchanged.  The two are independent operations and must therefore
  // not be chained with `else if`, which would silently collapse the pair into
  // a single write and lose the reader one entry.  The switch depends on this
  // case in several places, e.g. the ingress payload FIFO, which the receive
  // port appends to while the fabric is reading from it.
  //
  // The rewind is applied after the read/write pair and wins over it, so a
  // combined "discard the head frame" action can never underflow.
  // --------------------------------------------------------------------------
  logic [CNT_W-1:0] count_rw;  ///< occupancy after read and write
  logic             undo_fire;
  logic [CNT_W-1:0] count_d;

  always_comb begin
    if (flush_i)                   count_rw = '0;
    else if (do_write && do_read)  count_rw = count;
    else if (do_write)             count_rw = count + CNT_W'(1);
    else if (do_read)              count_rw = count - CNT_W'(1);
    else                           count_rw = count;
  end

  // The rewind only fires when the requested number of entries really is in the
  // buffer, so the occupancy can never be pushed below zero.
  assign undo_fire = undo_i && !flush_i && (undo_cnt_i <= count_rw);
  assign count_d   = undo_fire ? (count_rw - undo_cnt_i) : count_rw;

  // --------------------------------------------------------------------------
  // Status flags
  // --------------------------------------------------------------------------
  assign full_o  = (count == CNT_W'(DEPTH));
  assign free_o  = CNT_W'(DEPTH) - count;
  assign empty_o = (count == '0);

  // --------------------------------------------------------------------------
  // Storage
  //
  // Inferred as a block or distributed RAM by the common FPGA vendors because
  // it is written from a single clocked process.  The instance is placed after
  // every signal it reads so that a frontend that requires declaration before
  // use elaborates it unchanged.
  // --------------------------------------------------------------------------
  es_mems_ram_1r1w #(
    .WIDTH  (WIDTH),
    .DEPTH  (DEPTH),
    .ADDR_W (ADDR_W)
  ) u_ram (
    .clk_i     (clk_i),
    .wr_en_i   (do_write),
    .wr_addr_i (wr_ptr),
    .wr_data_i (wr_data_i),
    .rd_addr_i (rd_ptr),
    .rd_data_o (rd_data_o)
  );

  // --------------------------------------------------------------------------
  // Pointer update
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end else if (flush_i) begin
      wr_ptr <= '0;
      rd_ptr <= '0;
      count  <= '0;
    end else begin
      if (do_write) wr_ptr <= next_slot(wr_ptr);
      if (do_read)  rd_ptr <= next_slot(rd_ptr);
      // The rewind moves the write pointer only.  A frame is always the newest
      // data in the buffer, so nothing the consumer has already read can be
      // affected by it.
      if (undo_fire) wr_ptr <= wr_ptr - ADDR_W'(undo_cnt_i);
      count <= count_d;
    end
  end

endmodule : es_mems_sync_fifo

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_MEMS_SYNC_FIFO_SV
