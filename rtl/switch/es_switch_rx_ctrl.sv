// ============================================================================
//  File        : es_switch_rx_ctrl.sv
//  Description : Control slice of the S0/S1 receive level - one instance per
//                ingress port, instantiated by es_switch_rx_engine.
//
//                Switch-domain style (AGENTS.md 3.3.1): everything here is a
//                `logic`/`assign` combinational cloud and every sequential
//                element is an es_mems_reg_bank instance; there is no
//                procedural block in this file.
//
//                Owns the frame-reception FSM (S_IDLE / S_FRAME / S_DRAIN /
//                S_COMMIT), the admission decision, the octet counter and the
//                sticky error / bad verdict accumulators.  The header latch
//                lives in es_switch_rx_parse and the eight malformed-frame
//                checks are the purely combinational es_switch_rx_check.
//
//                Frame-level atomicity
//                ---------------------
//                A frame is admitted only when the byte FIFO can hold a whole
//                maximum-length frame and the descriptor FIFO has a slot
//                (`admit_i`, assembled by the engine from the buffer status).
//                Once admitted, `b_ready_o` never drops mid-frame, so a
//                valid/ready handshake can never lose a byte.  A malformed
//                frame is removed with a single rewind of the byte FIFO write
//                pointer (`undo_o`) and produces NO descriptor; the CAM and
//                egress levels therefore cannot see a frame that should have
//                been dropped.
//
//                Next-value exports
//                ------------------
//                The eof checks in es_switch_rx_check run on the NEXT octet
//                count and error accumulator (`oct_cnt_d_o`, `err_d_o`),
//                mirroring the single-process form this was split from, where
//                the checks consumed `oct_cnt_n` / `err_n` on the eof clock.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_RX_CTRL_SV
`define ES_SWITCH_RX_CTRL_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_switch_rx_ctrl #(
  /// Largest accepted MAC client frame in octets; drives the over-MTU drain.
  parameter int unsigned MAX_FRAME_LEN = 1518
) (
  input  var logic clk_i,
  input  var logic rst_ni,

  // ---- byte stream from the MAC adapter (b_data_i flows to the parser and
  //      the byte FIFO directly, never through here) -----------------------
  input  var logic       b_valid_i,
  input  var logic       b_sof_i,
  input  var logic       b_eof_i,
  input  var logic       b_err_i,
  output      logic      b_ready_o,

  // ---- frame-buffer status, assembled by the engine ----------------------
  input  var logic       admit_i,  ///< whole frame fits byte FIFO + descriptor FIFO
  input  var logic       wfull_i,  ///< byte FIFO full (mid-frame readiness)

  // ---- combinational verdict from es_switch_rx_check, consulted at eof ---
  input  var logic       eof_bad_i,

  // ---- per-byte work strobes for the parser ------------------------------
  output      logic      byte_fire_o,  ///< a byte is consumed this clock
  output      logic      hdr_clr_o,    ///< S_COMMIT: parser clears its header regs

  // ---- held / next octet count and error accumulator for the checker -----
  output      logic [SW_LEN_W:0] oct_cnt_o,    ///< bytes buffered for this frame
  output      logic [SW_LEN_W:0] oct_cnt_d_o,  ///< next count (the eof checks run on it)
  output      logic              err_d_o,      ///< next error accumulator

  // ---- frame-buffer control ----------------------------------------------
  output      logic              wr_en_o,
  output      logic              undo_o,       ///< rewind the byte FIFO write pointer
  output      logic [SW_LEN_W:0] undo_cnt_o,   ///< octets to rewind (the held count)
  output      logic              commit_o      ///< publish the descriptor
);

  // --------------------------------------------------------------------------
  // Configuration
  // --------------------------------------------------------------------------
  localparam int unsigned OCTW  = SW_LEN_W + 1;
  localparam int unsigned FSM_W = 2;

  // Binary-encoded FSM states.  S_IDLE is the reset encoding, so the state
  // bank can take its all-zero RESET_VALUE.
  localparam logic [FSM_W-1:0] S_IDLE   = FSM_W'(0);
  localparam logic [FSM_W-1:0] S_FRAME  = FSM_W'(1);
  localparam logic [FSM_W-1:0] S_DRAIN  = FSM_W'(2);
  localparam logic [FSM_W-1:0] S_COMMIT = FSM_W'(3);

  // --------------------------------------------------------------------------
  // State
  // --------------------------------------------------------------------------
  logic [FSM_W-1:0] state_q;
  logic [OCTW-1:0]  oct_cnt_q;
  logic             err_q;
  logic             bad_q;

  // --------------------------------------------------------------------------
  // Combinational control and next-state cloud
  // --------------------------------------------------------------------------
  logic [FSM_W-1:0] state_d;
  logic             state_idle_go;
  logic             state_commit;
  logic             state_legal;
  logic             over_mtu;
  logic             bad_set;
  logic             bad_clr;
  logic             oct_ena;
  logic             err_ena;
  logic [OCTW-1:0]  oct_cnt_d;
  logic             err_d;

  // Per-state readiness.  S_IDLE takes the admission decision, S_FRAME stays
  // ready while the byte FIFO has room, S_DRAIN drains unconditionally, S_COMMIT never
  // accepts; the fallback (S_IDLE and any stray encoding) admits.
  assign b_ready_o = (state_q == S_FRAME)  ? !wfull_i :
                     (state_q == S_DRAIN)  ? 1'b1     :
                     (state_q == S_COMMIT) ? 1'b0     :
                     admit_i;

  // A byte is consumed in S_IDLE only when the whole frame fits (admission),
  // in S_FRAME while the byte FIFO has room, and in S_DRAIN unconditionally.
  // S_COMMIT and stray encodings consume nothing.
  assign byte_fire_o = ((state_q == S_IDLE)  && b_valid_i && b_sof_i && admit_i) ||
                       ((state_q == S_FRAME)  && b_valid_i && !wfull_i)         ||
                       ((state_q == S_DRAIN)  && b_valid_i);

  assign state_idle_go = (state_q == S_IDLE) && b_valid_i && b_sof_i && admit_i;
  assign state_commit  = (state_q == S_COMMIT);
  // An encoding the RTL never writes must still return to S_IDLE, matching the
  // `default` branch of the single-process form this was split from.
  assign state_legal   = (state_q == S_IDLE)  || (state_q == S_FRAME) ||
                         (state_q == S_DRAIN) || (state_q == S_COMMIT);

  // Over MTU: the NEXT count has passed MAX_FRAME_LEN, so a frame ending
  // exactly at MAX_FRAME_LEN is not over.
  assign over_mtu = (state_q == S_FRAME) && byte_fire_o &&
                    (oct_cnt_d > OCTW'(MAX_FRAME_LEN));

  // Next state.  The per-byte overrides are evaluated first because in the
  // single-process form they were written AFTER the case and so won: a frame
  // going over MTU on its last byte still commits (with bad set, so it is
  // rewound), and an sof+eof single byte goes straight from S_IDLE to
  // S_COMMIT.  S_COMMIT exits unconditionally.
  assign state_d = (byte_fire_o && b_eof_i) ? S_COMMIT :
                   over_mtu                 ? S_DRAIN :
                   state_idle_go            ? S_FRAME :
                   state_commit             ? S_IDLE  :
                   state_legal              ? state_q : S_IDLE;

  // Octet count: cleared on the commit clock (the frame leaves), advanced by
  // every consumed byte except in S_DRAIN - there the frame is discarded and
  // the count must keep holding exactly the number of buffered bytes, which is
  // the rewind count.
  assign oct_cnt_d = (state_q == S_COMMIT) ? '0 :
                     (byte_fire_o && (state_q != S_DRAIN))
                         ? (oct_cnt_q + OCTW'(1)) : oct_cnt_q;
  assign oct_ena   = state_commit || (byte_fire_o && (state_q != S_DRAIN));

  // Sticky wire-error accumulator: OR of every RX_ER seen on this frame's
  // bytes, cleared on the commit clock with everything else.
  assign err_d   = byte_fire_o ? (err_q | b_err_i) : '0;
  assign err_ena = byte_fire_o || state_commit;

  // The verdict latches at eof (the checker's bad_o) or on the over-MTU
  // transition, and clears on the commit clock.  bad_set is low whenever
  // bad_clr is high, so the value written while clearing can simply be
  // bad_set.
  assign bad_set = over_mtu || (byte_fire_o && b_eof_i && eof_bad_i);
  assign bad_clr = state_commit;

  // --------------------------------------------------------------------------
  // Frame-buffer control and checker exports
  // --------------------------------------------------------------------------
  assign oct_cnt_o   = oct_cnt_q;
  assign oct_cnt_d_o = oct_cnt_d;
  assign err_d_o     = err_d;
  assign wr_en_o     = byte_fire_o && (state_q != S_DRAIN);
  assign hdr_clr_o  = state_commit;
  assign undo_o     = state_commit && bad_q;
  assign commit_o   = state_commit && !bad_q;
  assign undo_cnt_o = oct_cnt_q;

  // --------------------------------------------------------------------------
  // Registers
  //
  // Every sequential element is an es_mems_reg_bank instance (DEPTH=1: entry
  // zero is the whole register).  Synchronous active-low reset comes from the
  // bank's rst_ni.
  // --------------------------------------------------------------------------
  es_mems_reg_bank #(
    .WIDTH       (FSM_W),
    .DEPTH       (1),
    .RESET_VALUE ('0)   // S_IDLE
  ) u_state_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (1'b0),
    .wr_en_i   (1'b1),        // the FSM reloads its next state every clock
    .wr_data_i (state_d),
    .data_o    (state_q)
  );

  es_mems_reg_bank #(
    .WIDTH (OCTW),
    .DEPTH (1)
  ) u_oct_cnt_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (1'b0),
    .wr_en_i   (oct_ena),
    .wr_data_i (oct_cnt_d),
    .data_o    (oct_cnt_q)
  );

  es_mems_reg_bank #(
    .WIDTH (1),
    .DEPTH (1)
  ) u_err_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (1'b0),
    .wr_en_i   (err_ena),
    .wr_data_i (err_d),
    .data_o    (err_q)
  );

  es_mems_reg_bank #(
    .WIDTH (1),
    .DEPTH (1)
  ) u_bad_q (
    .clk_i     (clk_i),
    .rst_ni    (rst_ni),
    .clear_i   (1'b0),
    .wr_en_i   (bad_set | bad_clr),
    .wr_data_i (bad_set),
    .data_o    (bad_q)
  );

endmodule : es_switch_rx_ctrl

`default_nettype wire

`endif  // ES_SWITCH_RX_CTRL_SV
