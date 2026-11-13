// ============================================================================
//  File        : es_switch_tx_engine.sv
//  Description : S5 per-egress-port transmit queue of the staged switch.
//
//                The queue carries 10-bit words {sof, eof, data[7:0]} so the
//                frame boundaries survive the FIFO and the MAC adapter can
//                rebuild preamble, padding, FCS and IFG from them.  The read
//                side is FWFT: `b_valid_o` is high and `b_data_o` is the head
//                word whenever the queue is non-empty, and the word advances
//                only on `b_valid_o && b_ready_i`.  That is what makes the
//                adapter's valid/ready handshake lossless under backpressure.
//
//                `wr_ready_o` combines the FIFO's full flag and free counter
//                into one signal; both outputs are therefore genuinely read,
//                which avoids a PINCONNECTEMPTY lint waiver.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_TX_ENGINE_SV
`define ES_SWITCH_TX_ENGINE_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_switch_tx_engine #(
  parameter int unsigned TX_QUEUE_DEPTH = 256
) (
  input  var logic       clk_i,
  input  var logic       rst_ni,

  // ---- write side, driven by es_switch_tx_writer ------------------------
  input  var logic       wr_en_i,
  input  var logic [7:0] wr_data_i,
  input  var logic       wr_sof_i,
  input  var logic       wr_eof_i,
  output      logic      wr_ready_o,

  // ---- read side, byte stream toward the MAC adapter ------------------
  output      logic      b_valid_o,
  input  var logic       b_ready_i,
  output      logic [7:0] b_data_o,
  output      logic      b_sof_o,
  output      logic      b_eof_o
);

  localparam int unsigned WORD_W = 10;  // {sof, eof, data}
  localparam int unsigned CNT_W  = sw_pl_fifo_cnt_w(TX_QUEUE_DEPTH);

  logic [WORD_W-1:0] wr_word;
  logic [WORD_W-1:0] rd_word;
  logic              full;
  logic [CNT_W-1:0]  free_cnt;
  logic              empty;
  logic              rd_en;

  assign wr_word    = {wr_sof_i, wr_eof_i, wr_data_i};
  assign wr_ready_o = !full && (free_cnt != '0);
  assign b_valid_o  = !empty;
  assign b_data_o   = rd_word[7:0];
  assign b_sof_o    = rd_word[9];
  assign b_eof_o    = rd_word[8];
  assign rd_en      = b_valid_o && b_ready_i;

  es_mems_sync_fifo #(
    .WIDTH (WORD_W),
    .DEPTH (TX_QUEUE_DEPTH)
  ) u_queue (
    .clk_i      (clk_i),
    .rst_ni     (rst_ni),
    .undo_i     (1'b0),
    .undo_cnt_i (CNT_W'(0)),
    .flush_i    (1'b0),
    .wr_en_i    (wr_en_i && wr_ready_o),
    .wr_data_i  (wr_word),
    .full_o     (full),
    .free_o     (free_cnt),
    .rd_en_i    (rd_en),
    .rd_data_o  (rd_word),
    .empty_o    (empty)
  );

`ifndef SYNTHESIS
  initial begin
    if (TX_QUEUE_DEPTH < 2)
      $error("es_switch_tx_engine: TX_QUEUE_DEPTH must be at least 2");
  end
`endif

endmodule : es_switch_tx_engine

`default_nettype wire

`endif  // ES_SWITCH_TX_ENGINE_SV
