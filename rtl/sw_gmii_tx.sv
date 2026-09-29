// ============================================================================
//  File        : sw_gmii_tx.sv
//  Description : GMII octet transmit adapter.
//
//                Consumes the 64-bit beat stream produced by the switching
//                fabric and generates a complete, wire-legal Ethernet frame:
//
//                  preamble (7 x 0x55) | SFD (0xD5) | MAC client data | FCS
//
//                ------------------------------------------------------------------------
//                Clock-enable contract (identical to sw_gmii_rx)
//                ------------------------------------------------------------------------
//                `gmii_en_o` is asserted for a whole GMII octet time and
//                `gmii_d_o` is only updated on the last clock of that window,
//                so the octet on the wire is stable for exactly BYTE_PERIOD
//                clocks.  BYTE_PERIOD = 1 gives full line rate on 1000BASE-T.
//
//                ------------------------------------------------------------------------
//                FCS pipeline
//                ------------------------------------------------------------------------
//                The FCS generator is deliberately run *one octet ahead* of
//                the wire: the CRC absorbs exactly the octet that is being
//                registered onto `gmii_d_o` at the same clock edge.  Therefore,
//                when the last client octet has left the MAC, the LFSR already
//                holds the final result and the first FCS octet can be driven
//                on the very next octet time.  No bubble and no extra
//                pipeline register on the critical path.
//
//                ------------------------------------------------------------------------
//                Frame data source contract
//                ------------------------------------------------------------------------
//                The beat source is expected to be first-word-fall-through and
//                to have the complete frame queued before the descriptor that
//                triggers `fr_start_i` is presented.  The fabric guarantees
//                this (it only starts a frame once the whole frame fits into
//                the egress FIFO), so the S_LOAD escape exists purely as a
//                safety net.
//
//                Frames shorter than the 802.3 minimum are zero padded, and the
//                padding is covered by the FCS, so the module is safe to use
//                stand-alone.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef SW_GMII_TX_SV
`define SW_GMII_TX_SV

`include "sw_defs.sv"

// The shared declarations (`SW_LEN_W`, `SW_MIN_PAYLOAD`, `SW_IFG_OCTETS`) arrive
// through the include above and are visible at compilation-unit scope, which is
// what lets them appear in a parameter default and in a port range.  See
// sw_defs.sv for why a package cannot be used here.
module sw_gmii_tx #(
  /// `clk_i` cycles per GMII octet time (see the module header).
  parameter int unsigned BYTE_PERIOD = 1,
  /// Inter-frame gap in octet times; 802.3 requires at least 12.
  parameter int unsigned IFG_OCTETS  = SW_IFG_OCTETS
) (
  input  logic        clk_i,
  input  logic        rst_ni,

  // ---- frame request -------------------------------------------------------
  input  logic        fr_start_i,   ///< pulse: begin transmitting a new frame
  input  logic [SW_LEN_W-1:0] fr_len_i, ///< MAC client data length, FCS excluded
  output logic        tx_busy_o,    ///< high from fr_start_i until the IFG ends

  // ---- frame data source (first-word-fall-through) -------------------------
  input  logic        beat_valid_i, ///< a beat is available
  input  logic [63:0] beat_data_i,
  output logic        beat_rd_o,    ///< the current beat was consumed

  // ---- GMII transmit interface --------------------------------------------
  output logic        gmii_en_o,    ///< TX_EN towards the PHY
  output logic [7:0]  gmii_d_o      ///< octet towards the PHY
);

  // --------------------------------------------------------------------------
  // Octet-rate clock-enable generator.  `tick` marks the last clock of every
  // GMII octet time; it is the only place at which the output octet changes.
  // --------------------------------------------------------------------------
  localparam int unsigned BPW = (BYTE_PERIOD <= 1) ? 1 : $clog2(BYTE_PERIOD);
  localparam logic [BPW-1:0] PHASE_LAST = BYTE_PERIOD[BPW-1:0] - BPW'(1);

  logic [BPW-1:0] phase;
  always_ff @(posedge clk_i) begin
    if (!rst_ni)                  phase <= '0;
    else if (phase == PHASE_LAST) phase <= '0;
    else                          phase <= phase + BPW'(1);
  end

  logic tick;
  assign tick = (phase == PHASE_LAST);

  // --------------------------------------------------------------------------
  // Transmit sequencer state
  // --------------------------------------------------------------------------
  // The states form a strict cycle: IDLE -> PRE -> FRAME -> FCS -> IFG -> IDLE.
  // S_LOAD is a safety net that the store-and-forward fabric never needs, see
  // the module header.
  typedef enum logic [2:0] {
    S_IDLE  = 3'd0,  ///< between frames, waiting for a new descriptor
    S_PRE   = 3'd1,  ///< emitting the 8 preamble octets (7 x 0x55 + SFD)
    S_LOAD  = 3'd2,  ///< safety net: waiting for the first frame beat
    S_FRAME = 3'd3,  ///< streaming the MAC client data octets
    S_FCS   = 3'd4,  ///< appending the 4 FCS octets
    S_IFG   = 3'd5   ///< enforcing the inter-frame gap
  } state_e;

  state_e                state;
  logic [63:0]           cur_beat;   ///< beat currently being serialised
  logic [3:0]            beat_left;  ///< octets of `cur_beat` still to drive
  logic [3:0]            pre_cnt;    ///< preamble octets still to emit (8..1)
  logic [SW_LEN_W-1:0]   sent;       ///< client octets driven so far
  logic [SW_LEN_W-1:0]   len_q;      ///< declared MAC client data length
  logic [SW_LEN_W-1:0]   total;      ///< `len_q` raised to the 802.3 minimum
  /// Index of the next FCS octet to drive.  Counts 1..4: octet 0 is delivered by
  /// the S_FRAME -> S_FCS hand-over, and the counter reaching 4 is the signal to
  /// start the inter-frame gap.  It is deliberately one bit wider than the four
  /// octets so that "all delivered" is a distinct, representable value.
  logic [2:0]            fcs_idx;

  /// A frame request arrived while the current octet window was still open.
  /// The MAC does not start the preamble until the next octet boundary, so that
  /// every octet window of a frame is exactly BYTE_PERIOD long - see the note on
  /// `S_IDLE` below.
  logic                  fr_pending;

  logic [7:0]            ifg_cnt;    ///< inter-frame gap countdown
  logic [7:0]            octet;      ///< octet currently on the wire

  // Busy from the moment a request is *accepted*, not from the moment the
  // sequencer actually starts: the fabric must not be offered a second frame while
  // the first is still waiting for an octet boundary.  `fr_pending` is a
  // register, so this does not close the combinational loop through
  // `fr_start = !len_empty && !tx_busy` in the transmit port.
  assign tx_busy_o = (state != S_IDLE) || fr_pending;
  assign gmii_d_o  = octet;
  // The enable follows the state combinationally, so it is asserted for exactly
  // the octet windows in which `octet` holds data.  Registering it instead would
  // delay it by one clock relative to the octet register and cost the first
  // preamble octet - the enable would still be low in the window where the first
  // 0x55 is already on the pins.
  //
  // The one hazard that this creates is leaving a state in the same clock that
  // loads an octet: the enable would drop before that octet was ever presented.
  // The sequencer below is written to avoid it - in particular the last FCS octet
  // is loaded one full octet time before the inter-frame gap starts.
  assign gmii_en_o = (state == S_PRE)  || (state == S_LOAD) ||
                     (state == S_FRAME) || (state == S_FCS);

  // --------------------------------------------------------------------------
  // Octet selection inside the current beat.
  //
  // `beat_left` counts down from 7 to 0 while a beat is serialised, so the
  // index of the next octet to drive is (8 - beat_left), i.e. 1 .. 7.  Octet 0
  // is driven directly from `beat_data_i` at the clock that loads the beat.
  // `beat_left == 0` therefore means "this beat is exhausted".
  // --------------------------------------------------------------------------
  logic [2:0] cur_idx;
  logic [7:0] cur_octet;
  assign cur_idx   = 3'(8 - beat_left);
  assign cur_octet = cur_beat[63 - {cur_idx, 3'b000} -: 8];

  // Octet 0 of the beat offered by the source.  Selected outside the sequencer
  // process for the same reason as `cur_octet` / `fcs_octet`.
  logic [7:0] beat_next_first;
  assign beat_next_first = beat_data_i[63:56];

  // Octets at or beyond `len_q` are 802.3 padding.  They are still covered by
  // the FCS, so they take the normal data path with a zero octet value.
  logic pad;
  assign pad = (sent >= len_q);

  // --------------------------------------------------------------------------
  // "What goes on the wire next" - evaluated for every state, consumed by the
  // sequencer below only on `tick`.  These are the *next value* signals of the
  // transmit path: they describe the octet that the next tick will place on
  // the wire and the octet that the FCS generator absorbs at that same tick.
  //
  //   oct_next   - octet value to register onto `octet` at the next tick
  //   crc_en_n   - absorb `oct_next` into the FCS generator at that tick
  //   crc_din_n  - the octet absorbed by the FCS generator
  //   load_first - the first (or next) frame beat is taken at that tick
  //   done_fcs   - the last client octet leaves the MAC at that tick
  // --------------------------------------------------------------------------
  logic [7:0] oct_next;
  logic       crc_en_n;
  logic [7:0] crc_din_n;
  logic [7:0] crc_din;
  logic       crc_en;
  logic       load_first;
  logic       done_fcs;
  logic [31:0] crc_fin;
  logic       crc_resid_ok;
  logic       crc_clr;

  // --------------------------------------------------------------------------
  // FCS generation.
  //
  // The generator is run one octet *ahead* of the wire: `crc_din_n` is the
  // octet that the next tick places on the wire, and it is absorbed into the
  // LFSR at that very tick.  When the last client octet has left the MAC the
  // LFSR therefore already holds the final result and the first FCS octet can
  // follow without a bubble (see the module header).
  //
  // The enable is qualified with `tick`, and that qualification is essential at
  // every line rate below 1000 Mbit/s.  `crc_en_n` and `crc_din_n` are
  // combinational functions of the sequencer state, so they stay asserted for the
  // entire octet window - ten clocks at 100 Mbit/s, a hundred at 10 Mbit/s.  An
  // unqualified enable would absorb the same octet once per clock instead of once
  // per octet, and every transmitted frame would carry a wrong FCS.  The clear
  // strobe needs no such treatment, because a repeated clear is idempotent.
  // --------------------------------------------------------------------------
  assign crc_en   = crc_en_n && tick;
  assign crc_din  = crc_din_n;
  // Re-seed the LFSR once, at the frame request, well before the first client
  // octet is absorbed.
  assign crc_clr  = fr_start_i;

  sw_crc32 u_crc (
      .clk_i     (clk_i),
      .rst_ni    (rst_ni),
      .en_i      (crc_en),
      .din_i     (crc_din),
      .clr_i     (crc_clr),
      .crc_fin_o (crc_fin),
      .resid_ok_o(crc_resid_ok)  // unused: the receive path performs the check
  );

  logic unused_crc_ok;
  assign unused_crc_ok = crc_resid_ok;

  // The four FCS octets are transmitted least significant octet first.
  //
  // The octet is selected by a mux rather than by a variable-offset part select.
  // A variable-offset part select inside an always_* block makes a simulator
  // over-approximate the sensitivity list, and a *constant* one inside an
  // always_comb makes Icarus widen the sensitivity to every bit of `crc_fin`
  // ("constant selects in always_* processes are not currently supported").
  // Continuous assignments avoid both, and they also make the selection a static
  // per-input mux rather than a procedural one.
  //
  // `fcs_idx` is a three bit counter that only ever reaches 0..4, so a `unique`
  // case would be a false assertion for the three unused encodings; the final
  // term is the default instead, which is what those encodings resolve to.
  logic [7:0] fcs_octet;
  logic [7:0] fcs_first;

  assign fcs_octet = (fcs_idx == 3'd0) ? crc_fin[ 7: 0] :
                     (fcs_idx == 3'd1) ? crc_fin[15: 8] :
                     (fcs_idx == 3'd2) ? crc_fin[23:16] :
                                         crc_fin[31:24];

  // The first FCS octet on the wire is always the low octet of the generator.
  assign fcs_first = crc_fin[7:0];

  always_comb begin
    // Defaults: hold whatever is on the wire and do not touch the FCS.
    oct_next   = octet;
    crc_en_n   = 1'b0;
    crc_din_n  = 8'h00;
    load_first = 1'b0;
    done_fcs   = 1'b0;

    case (state)
      // -------------------------------------------------------------------
      S_PRE: begin
        if (pre_cnt == 4'd1) begin
          // The octet on the wire right now is the SFD.  The next octet time
          // must carry client octet 0, so the first beat is taken right here -
          // no idle octet is inserted between the SFD and the destination MAC.
          load_first = beat_valid_i;
          if (beat_valid_i) begin
            oct_next  = beat_next_first;
            crc_en_n  = 1'b1;
            crc_din_n = beat_next_first;
          end
        end else if (pre_cnt == 4'd2) begin
          oct_next = 8'hD5;  // start-of-frame delimiter
        end else begin
          oct_next = 8'h55;  // preamble octet
        end
      end

      // -------------------------------------------------------------------
      S_FRAME: begin
        if (sent == total) begin
          // The last client octet is on the wire.  The LFSR settled at the
          // clock that drove it, so the FCS is already final and can be
          // appended on the next octet time without a bubble.
          oct_next = fcs_first;
          done_fcs = 1'b1;
        end else if (beat_left == 4'd0) begin
          // The current beat is exhausted; take the next one.  If the source
          // has not produced it yet the current octet is held for one more
          // octet time - unreachable in the store-and-forward fabric, and a
          // safe, self-recovering degradation if it ever happened.
          load_first = beat_valid_i;
          if (beat_valid_i) begin
            oct_next  = beat_next_first;
            crc_en_n  = 1'b1;
            crc_din_n = beat_next_first;
          end
        end else begin
          oct_next  = pad ? 8'h00 : cur_octet;
          crc_en_n  = 1'b1;
          crc_din_n = oct_next;
        end
      end

      // -------------------------------------------------------------------
      S_FCS: begin
        oct_next = fcs_octet;
      end

      // -------------------------------------------------------------------
      default: ;  // S_IDLE / S_LOAD / S_IFG: nothing is on the wire
    endcase
  end

  // --------------------------------------------------------------------------
  // Main sequencer
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state      <= S_IDLE;
      fr_pending <= 1'b0;
      cur_beat   <= 64'd0;
      beat_left <= 4'd0;
      pre_cnt   <= 4'd0;
      sent      <= '0;
      len_q     <= '0;
      total     <= '0;
      fcs_idx   <= 3'd0;
      ifg_cnt   <= 8'd0;
      octet     <= 8'h00;
      beat_rd_o <= 1'b0;
    end else begin
      beat_rd_o <= 1'b0;

      case (state)
        // ---------------------------------------------------------------
        // Idle.  A request is *latched* but not acted on immediately: the
        // preamble starts on the next octet boundary (`tick`).
        //
        // Starting immediately would make the first octet window shorter than
        // BYTE_PERIOD, because a request can arrive at any point inside a window.
        // A MAC that starts a frame on a partial octet time is not GMII-legal, and
        // it also forces the receiver to guess where the octet boundaries are.
        // Waiting for `tick` makes every window of the frame exactly BYTE_PERIOD
        // long and keeps the octet cadence well defined at every line rate.
        S_IDLE: begin
          if (fr_start_i && !fr_pending) begin
            fr_pending <= 1'b1;
            len_q      <= fr_len_i;
            total      <= (fr_len_i < SW_LEN_W'(SW_MIN_PAYLOAD))
                            ? SW_LEN_W'(SW_MIN_PAYLOAD) : fr_len_i;
          end else if (fr_pending && tick) begin
            fr_pending <= 1'b0;
            pre_cnt    <= 4'd8;
            // The first preamble octet starts driving in this same octet time.
            octet      <= 8'h55;
            state      <= S_PRE;
          end
        end

        // ---------------------------------------------------------------
        S_PRE: begin
          if (tick) begin
            octet <= oct_next;
            if (pre_cnt == 4'd1) begin
              if (load_first) begin
                cur_beat  <= beat_data_i;
                beat_rd_o <= 1'b1;
                beat_left <= 4'd7;   // octets 1..7 are still to be driven
                sent      <= SW_LEN_W'(1);
                state     <= S_FRAME;
              end else begin
                state <= S_LOAD;    // safety net, see the module header
              end
            end else begin
              pre_cnt <= pre_cnt - 4'd1;
            end
          end
        end

        // ---------------------------------------------------------------
        S_LOAD: begin
          if (load_first) begin
            cur_beat  <= beat_data_i;
            beat_rd_o <= 1'b1;
            beat_left <= 4'd7;
            sent      <= SW_LEN_W'(1);
            state     <= S_FRAME;
          end
        end

        // ---------------------------------------------------------------
        S_FRAME: begin
          if (tick) begin
            octet <= oct_next;
            if (done_fcs) begin
              state   <= S_FCS;
              fcs_idx <= 3'd1;      // FCS octet 0 was delivered with `oct_next`
            end else if (load_first) begin
              cur_beat  <= beat_data_i;
              beat_rd_o <= 1'b1;
              beat_left <= 4'd7;
              sent      <= sent + SW_LEN_W'(1);
            end else if (beat_left != 4'd0) begin
              beat_left <= beat_left - 4'd1;
              sent      <= sent + SW_LEN_W'(1);
            end
            // Remaining case: `beat_left == 0` and the next beat has not
            // arrived - hold for one more octet time (unreachable, see above).
          end
        end

        // ---------------------------------------------------------------
        // Frame Check Sequence, least significant octet first.
        //
        // The clock that registers the *last* FCS octet must not also leave
        // S_FCS.  `gmii_en_o` follows `state`, so leaving S_FCS in the same clock
        // would take the enable low before that octet was ever presented, and the
        // frame would be transmitted one octet short.  The sequencer therefore
        // counts to 4 and only then starts the inter-frame gap, one full octet
        // time after the final FCS octet has been driven.
        S_FCS: begin
          if (tick) begin
            octet <= oct_next;
            if (fcs_idx == 3'd4) begin
              state   <= S_IFG;
              ifg_cnt <= 8'(IFG_OCTETS);
            end else begin
              fcs_idx <= fcs_idx + 3'd1;
            end
          end
        end

        // ---------------------------------------------------------------
        // Inter-frame gap: `gmii_en_o` is low, which is how GMII encodes idle.
        S_IFG: begin
          if (tick) begin
            if (ifg_cnt == 8'd1) state   <= S_IDLE;
            else                ifg_cnt <= ifg_cnt - 8'd1;
          end
        end

        // ---------------------------------------------------------------
        default: state <= S_IDLE;
      endcase
    end
  end

endmodule : sw_gmii_tx

`endif // SW_GMII_TX_SV
