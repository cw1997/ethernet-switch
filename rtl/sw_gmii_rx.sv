// ============================================================================
//  File        : sw_gmii_rx.sv
//  Description : GMII octet receive adapter.
//
//                Converts the octet-serial, clock-enable qualified GMII receive
//                interface of a PHY into the 64-bit "beat" stream consumed by
//                the switching datapath, and performs the FCS check in the same
//                module so that the CRC always advances at the octet rate.
//
//                ------------------------------------------------------------------------
//                Clock-enable (single clock domain) contract
//                ------------------------------------------------------------------------
//                `gmii_en_i` / `gmii_d_i` are synchronous to `clk_i`:
//                  * one octet is transferred every BYTE_PERIOD clock cycles,
//                  * `gmii_en_i` is asserted for the whole octet time and
//                    `gmii_d_i` is stable for the same window,
//                  * `gmii_en_i` is de-asserted for at least one clock during
//                    the inter-frame gap,
//                  * BYTE_PERIOD = 1 for 1000BASE-T (full line rate, one octet
//                    per clock), 10 for 100BASE-TX and 100 for 10BASE-T on a
//                    125 MHz core clock.
//
//                The adapter re-synchronises the octet stream onto a free
//                running phase counter and samples on the last cycle of each
//                octet time, which gives a full clock of data hold margin
//                without any FIFO or clock-domain-crossing logic.  If a PHY
//                drives its GMII from a genuinely asynchronous clock, wrap this
//                module in an asynchronous FIFO - nothing above it changes.
//
//                Preamble (7 x 0x55) and the start-of-frame delimiter (0xD5)
//                are removed by the PHY, as a real GMII MAC does, so the octet
//                stream presented here starts with the first octet of the
//                destination MAC address and ends with the four FCS octets.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef SW_GMII_RX_SV
`define SW_GMII_RX_SV

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
module sw_gmii_rx import sw_switch_pkg::*; #(
`else
module sw_gmii_rx #(
`endif
  /// `clk_i` cycles per GMII octet time (see the module header).
  parameter int unsigned BYTE_PERIOD = 1
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // ---- GMII receive interface (clock-enable qualified) --------------------
  input  logic        gmii_en_i,   ///< TX_EN from the PHY
  input  logic [7:0]  gmii_d_i,    ///< octet from the PHY

  // ---- core beat interface -------------------------------------------------
  output logic        beat_valid_o,   ///< a 64-bit beat is available
  output logic [63:0] beat_data_o,    ///< octet 0 in [63:56] ... octet 7 in [7:0]
  output logic        beat_sof_o,     ///< beat carries the first octet of a frame
  output logic        beat_eof_o,     ///< beat carries the last octet of a frame
  output logic        beat_crc_ok_o,  ///< FCS verdict, valid together with eof
  output logic [3:0]  beat_octets_o   ///< valid octets in this beat (1..8)
);

  // --------------------------------------------------------------------------
  // Octet-rate clock-enable generator.
  //
  // The counter runs free so that it stays phase-aligned with the PHY even
  // while the link is idle; `sample` marks the last cycle of every octet time.
  // --------------------------------------------------------------------------
  localparam int unsigned BPW = (BYTE_PERIOD <= 1) ? 1 : $clog2(BYTE_PERIOD);
  localparam logic [BPW-1:0] PHASE_LAST = BYTE_PERIOD[BPW-1:0] - BPW'(1);

  logic [BPW-1:0] phase;
  always_ff @(posedge clk_i) begin
    if (!rst_ni)                  phase <= '0;
    else if (phase == PHASE_LAST) phase <= '0;
    else                          phase <= phase + BPW'(1);
  end

  // Sample on the final cycle of the octet time for maximum hold margin.
  logic sample;
  assign sample = gmii_en_i && (phase == PHASE_LAST);

  // --------------------------------------------------------------------------
  // Octet assembler.
  //
  //   `acc`      - shift register holding the octets of the beat under
  //                construction; the octet under construction at index 0 lives
  //                in [63:56].
  //   `bcnt`     - number of octets already shifted into `acc` (0..8).  The
  //                value 8 means "a full beat is held in `acc`".
  //   `acc_sof`  - the beat currently held in `acc` is the first of the frame.
  //
  // A full beat is deliberately *held* rather than pushed into the pipeline the
  // moment the eighth octet arrives.  Whether a frame has ended is only
  // observable from `gmii_en_i`, and the PHY is free to hold that signal high
  // for the remainder of the final octet time - which, for a port slower than
  // 1000 Mbit/s, is several clocks *after* the octet was sampled.  Emitting the
  // beat eagerly would therefore push it out of the two stage pipeline as an
  // ordinary beat and the end-of-frame marker would arrive with nothing left to
  // attach it to.  Holding the beat until the following octet (frame continues)
  // or `fend` (frame ends) proves the answer at the cost of one octet time of
  // latency, and it costs no throughput: the beat is released on the very clock
  // the next octet is sampled, so one beat still leaves every eight clocks.
  //
  // IMPORTANT: the assembler state may only be cleared when the link is really
  // idle (`!gmii_en_i`).  Between two octet samples of the same frame the link
  // is still enabled, so the state has to be held for up to BYTE_PERIOD-1
  // clocks.  Clearing it on `!sample` instead would destroy the beat
  // accumulation for every port slower than 1000 Mbit/s.
  // --------------------------------------------------------------------------
  logic       in_frame;   ///< an octet has been seen since the last idle gap
  logic [3:0] bcnt;
  logic [63:0] acc;
  logic       acc_sof;

  // The PHY de-asserts `gmii_en_i` for at least one clock between frames; the
  // first such clock after an octet is the end-of-frame indication.
  logic       fend;
  assign fend = !gmii_en_i && in_frame;

  // --------------------------------------------------------------------------
  // FCS check over the complete received octet sequence, FCS included.
  //
  // The LFSR is re-seeded on every idle cycle, so the very first octet of a
  // frame is absorbed correctly without a separate start-of-frame handshake.
  // `resid_ok_o` is combinational off the LFSR, so during the `fend` cycle it
  // still carries the value produced by the last octet of the frame, which is
  // exactly what the closing beat needs.
  // --------------------------------------------------------------------------
  logic        crc_en, crc_clr, crc_resid_ok;

  assign crc_en  = sample;
  assign crc_clr = !gmii_en_i;

  /* verilator lint_off PINCONNECTEMPTY */
  sw_crc32 u_crc (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .en_i      (crc_en),
      .din_i     (gmii_d_i),
      .clr_i     (crc_clr),
      .crc_fin_o (),      // unused: the receive side checks instead of generating
      .resid_ok_o(crc_resid_ok)
  );
  /* verilator lint_on PINCONNECTEMPTY */

  // --------------------------------------------------------------------------
  // Beat release.
  //
  // `emit` is the single condition under which a beat leaves the assembler; the
  // accompanying signals describe that beat.  It is a combinational decision
  // because it has to be taken in the very clock that the evidence - a ninth
  // octet, or `fend` - becomes visible.
  // --------------------------------------------------------------------------
  logic        emit;
  logic        emit_sof;
  logic        emit_eof;
  logic        emit_crc_ok;
  logic [3:0]  emit_octets;
  logic [63:0] emit_data;

  // The beat in `acc` is full (bcnt == 8) and a ninth octet has been sampled, so
  // it is provably *not* the closing beat of the frame.
  logic full_and_more;
  assign full_and_more = sample && (bcnt == 4'd8);

  // The frame has ended with either a full (bcnt == 8) or a partial
  // (0 < bcnt < 8) beat still sitting in `acc`; that beat is the closing one.
  logic close_full, close_part;
  assign close_full = fend && (bcnt == 4'd8);
  assign close_part = fend && (bcnt != 4'd0) && (bcnt != 4'd8);

  assign emit        = full_and_more || close_full || close_part;
  assign emit_sof    = acc_sof;
  assign emit_eof    = close_full || close_part;
  assign emit_crc_ok = emit_eof && crc_resid_ok;
  assign emit_octets = close_part ? {1'b0, bcnt[2:0]} : 4'd8;
  // A partial beat is already left aligned in `acc`; its unused low order lanes
  // are zero because the assembler shifts in zeros.  A full beat needs no
  // masking.
  assign emit_data   = acc;

  // --------------------------------------------------------------------------
  // Two stage beat pipeline.
  //
  // The end-of-frame marker and the FCS verdict are resolved in the assembler
  // (see above) and simply travel with the beat, so this is a plain two deep
  // shift register and the steady-state throughput is one beat per clock, i.e.
  // a full 1 Gbit/s on a 125 MHz core.
  //
  // The beat stream is unconditional (no ready/valid handshake).  The receive
  // port in front of it always drains its beat FIFO, so a beat can never be
  // dropped, which is what allows the adapter to sustain full line rate.
  // --------------------------------------------------------------------------
  logic        s0_valid, s0_sof, s0_eof, s0_crc_ok;
  logic [63:0] s0_data;
  logic [3:0]  s0_octets;

  logic        s1_valid, s1_sof, s1_eof, s1_crc_ok;
  logic [63:0] s1_data;
  logic [3:0]  s1_octets;

  assign beat_valid_o  = s1_valid;
  assign beat_data_o   = s1_data;
  assign beat_sof_o    = s1_sof;
  assign beat_eof_o    = s1_eof;
  assign beat_crc_ok_o = s1_crc_ok;
  assign beat_octets_o = s1_octets;

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      in_frame  <= 1'b0;
      bcnt      <= 4'd0;
      acc       <= 64'd0;
      acc_sof   <= 1'b0;
      s0_valid  <= 1'b0;
      s0_data   <= 64'd0;
      s0_sof    <= 1'b0;
      s0_eof    <= 1'b0;
      s0_crc_ok <= 1'b0;
      s0_octets <= 4'd0;
      s1_valid  <= 1'b0;
      s1_data   <= 64'd0;
      s1_sof    <= 1'b0;
      s1_eof    <= 1'b0;
      s1_crc_ok <= 1'b0;
      s1_octets <= 4'd0;
    end else begin
      // ---- octet assembler -------------------------------------------------
      if (full_and_more) begin
        // A ninth octet: the held beat leaves (captured into stage 0 by the
        // assignment below) and the assembler restarts on the new octet.
        in_frame <= 1'b1;
        bcnt     <= 4'd1;
        acc      <= {56'd0, gmii_d_i};
        acc_sof  <= 1'b0;
      end else if (close_full || close_part) begin
        // The closing beat leaves; nothing is left in the assembler.
        in_frame <= 1'b0;
        bcnt     <= 4'd0;
        acc      <= 64'd0;
        acc_sof  <= 1'b0;
      end else if (sample) begin
        if (bcnt == 4'd8) begin
          // Impossible in a well-formed stream: the beat was already released
          // by `full_and_more` above.  Held for simulation robustness.
          acc     <= {acc[55:0], gmii_d_i};
          acc_sof <= 1'b0;
        end else if (bcnt == 4'd0) begin
          // First octet of a new frame.
          in_frame <= 1'b1;
          bcnt     <= 4'd1;
          acc      <= {56'd0, gmii_d_i};
          acc_sof  <= 1'b1;
        end else begin
          bcnt <= bcnt + 4'd1;
          acc  <= {acc[55:0], gmii_d_i};
        end
      end else if (!gmii_en_i) begin
        // The link is genuinely idle (inter-frame gap): restart the assembler.
        // Note that this is *not* entered between two octet samples of the
        // same frame, where `gmii_en_i` is still high.
        in_frame <= 1'b0;
        bcnt     <= 4'd0;
        acc_sof  <= 1'b0;
      end

      // ---- stage 0 : released beats ----------------------------------------
      s0_valid  <= emit;
      s0_data   <= emit_data;
      s0_sof    <= emit_sof;
      s0_eof    <= emit_eof;
      s0_crc_ok <= emit_crc_ok;
      s0_octets <= emit_octets;

      // ---- stage 1 : output stage ------------------------------------------
      s1_valid  <= s0_valid;
      s1_data   <= s0_data;
      s1_sof    <= s0_sof;
      s1_eof    <= s0_eof;
      s1_crc_ok <= s0_crc_ok;
      s1_octets <= s0_octets;
    end
  end

endmodule : sw_gmii_rx

`endif // SW_GMII_RX_SV
