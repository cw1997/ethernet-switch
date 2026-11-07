// ============================================================================
//  File        : es_console_cmd_mac.sv
//  Description : Live MAC-table traversal for `mac all` and `mac <port>`.
//
//                start_i captures the table capacity and the port filter.  The
//                CSR grant spans each coherent entry or metadata read only, and
//                is released while the line consumer or the UART is stalled.
//                A line is accepted when text_valid_o and text_ready_i are both
//                high.  A synchronous active-low reset returns the engine to
//                idle.
//
//                The traversal brackets the scan with a metadata read on each
//                side, so the response carries the sample clock and the flush
//                count at both ends: a reader can tell whether the table moved
//                underneath the listing.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_CONSOLE_CMD_MAC_SV
`define ES_CONSOLE_CMD_MAC_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_console_cmd_mac (
  /// Clock, synchronous active-low reset, and command start handshake.
  input var logic clk_i, rst_ni, start_i,
  /// `filter_i` is a zero-based port, or all ones for every port; `count_i` is
  /// the table capacity captured with the command, not the number of matches.
  input var logic [31:0] filter_i, count_i,
  /// Shared CSR ownership is taken only at safe cache-idle boundaries.
  input var logic        cache_idle_i,
  output    logic        bus_claim_o, req_o,
  output    logic [31:0] addr_o,
  /// CSR read handshake and returned word.
  input var logic        csr_ready_i, csr_valid_i,
  input var logic [31:0] csr_data_i,
  /// Text sink handshake; a line advances only when it is ready.
  input var logic text_ready_i,
  /// done_o coincides with acceptance of the final metadata line; busy_o stays
  /// high from the cycle after start_i until that handshake completes.
  output    logic         text_valid_o, busy_o, done_o,
  output    logic [511:0] text_o);

  // --------------------------------------------------------------------------
  // Control state
  //
  // A traversal reads an entry's four words, emits the matching lines, then
  // moves to the next entry.  `meta_access_q` selects the metadata read that
  // brackets the scan; `meta_end_q` says which side of the bracket it is.
  // --------------------------------------------------------------------------
  typedef enum logic [3:0] {
    S_IDLE,
    S_MAC_IDLE,   ///< wait for a cache-idle boundary before claiming the bus
    S_MAC_SEND,   ///< request one entry word
    S_MAC_WAIT,   ///< wait for that word
    S_MAC_PRINT,  ///< present the address line, then the port line
    S_MAC_NEXT,   ///< accept the port line and advance to the next entry
    S_META_SEND,  ///< request one metadata word
    S_META_WAIT,  ///< wait for that word
    S_META_PRINT  ///< present both metadata lines
  } state_e;

  state_e state_q;

  logic [31:0]  mac_index_q;  ///< entry being read
  logic [31:0]  filter_q;     ///< port filter captured at start
  logic [31:0]  mac_count_q;  ///< table capacity captured at start
  logic [ 1:0]  mac_word_q;   ///< word within the current entry or metadata
  logic [127:0] mac_entry_q;  ///< the four words of one MAC entry
  logic [ 95:0] meta_q;       ///< clock word plus flush word

  logic meta_end_q;     ///< the metadata read is the closing one
  logic meta_line_q;    ///< second of the two metadata lines
  logic meta_access_q;  ///< next bus access is metadata, not an entry
  logic match_entry;    ///< the latched entry passes the port filter

  // Bits 127:97 of a CAM entry are reserved; reduce them so the slice is
  // accounted for rather than left dangling.
  logic unused_mac_reserved;
  assign unused_mac_reserved = ^mac_entry_q[127:97];

  // A learned entry is valid (bit 96) and either matches the requested port or
  // the filter asks for every port.
  assign match_entry = mac_entry_q[96] &&
                       ((filter_q == 32'hFFFF_FFFF) || (filter_q == mac_entry_q[95:64]));

  // --------------------------------------------------------------------------
  // Line formatting
  // --------------------------------------------------------------------------
  function automatic logic [511:0] value_line(input var logic [191:0] label,
                                              input var logic [63:0] value);
    logic [127:0] hextext;
    for (int unsigned h = 0; h < 16; h++) begin
      hextext[127-h*8 -: 8] = sw_hexchar(value[63-h*4 -: 4]);
    end
    value_line = {label, "=0x", hextext, 16'h0d0a, 152'd0};
  endfunction

  // --------------------------------------------------------------------------
  // Bus ownership and address
  //
  // A grant cannot be held while the UART waits for CTS: the display cache uses
  // the same CSR bus and must keep refreshing between reads.
  // --------------------------------------------------------------------------
  assign bus_claim_o = ((state_q == S_MAC_IDLE) && cache_idle_i && text_ready_i) ||
                       (state_q == S_MAC_SEND) || (state_q == S_MAC_WAIT) ||
                       (state_q == S_META_SEND) || (state_q == S_META_WAIT);

  assign req_o = (state_q == S_MAC_SEND) || (state_q == S_META_SEND);

  // Metadata lives at the live counters; an entry is 16 bytes (four words), and
  // `mac_word_q` selects the word within it.
  assign addr_o = ((state_q == S_META_SEND) || (state_q == S_META_WAIT)) ?
                  (SW_MON_LIVE_CLOCK + {28'd0, mac_word_q, 2'b00}) :
                  (SW_MON_MAC_BASE + (mac_index_q * 32'd16) + {28'd0, mac_word_q, 2'b00});

  assign busy_o = (state_q != S_IDLE);

  // The address line is valid for every match; the port line only follows a
  // match, which is why it is gated on `match_entry`.
  assign text_valid_o = ((state_q == S_MAC_PRINT) && match_entry) ||
                        (state_q == S_MAC_NEXT) || (state_q == S_META_PRINT);

  assign done_o = (state_q == S_META_PRINT) && meta_line_q && meta_end_q && text_ready_i;

  // --------------------------------------------------------------------------
  // Line content
  // --------------------------------------------------------------------------
  always_comb begin
    text_o = '0;
    case (state_q)
      S_MAC_PRINT:  text_o = value_line("mac_address", mac_entry_q[63:0]);
      S_MAC_NEXT:   text_o = value_line("mac_port", {32'd0, mac_entry_q[95:64]});
      S_META_PRINT: text_o = meta_line_q ?
          value_line(meta_end_q ? "mac_end_flushes" : "mac_start_flushes",
                     {32'd0, meta_q[95:64]}) :
          value_line(meta_end_q ? "mac_end_clock" : "mac_start_clock",
                     meta_q[63:0]);
      default: text_o = '0;
    endcase
  end

  // --------------------------------------------------------------------------
  // Traversal sequencer
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q       <= S_IDLE;
      mac_index_q   <= '0;
      mac_word_q    <= '0;
      mac_entry_q   <= '0;
      filter_q      <= '1;
      mac_count_q   <= '0;
      meta_q        <= '0;
      meta_end_q    <= 1'b0;
      meta_line_q   <= 1'b0;
      meta_access_q <= 1'b1;
    end else begin
      case (state_q)
        S_IDLE: if (start_i) begin
          filter_q      <= filter_i;
          mac_index_q   <= '0;
          mac_word_q    <= '0;
          mac_count_q   <= count_i;
          // Start with the opening metadata read.
          meta_end_q    <= 1'b0;
          meta_line_q   <= 1'b0;
          meta_access_q <= 1'b1;
          state_q       <= S_MAC_IDLE;
        end
        S_MAC_IDLE: if (cache_idle_i && text_ready_i) begin
          state_q <= meta_access_q ? S_META_SEND : S_MAC_SEND;
        end
        S_MAC_SEND: if (csr_ready_i) state_q <= S_MAC_WAIT;
        S_MAC_WAIT: if (csr_valid_i) begin
          mac_entry_q[{mac_word_q, 5'd0} +: 32] <= csr_data_i;
          if (mac_word_q == 2'd3) begin
            mac_word_q <= '0;
            state_q    <= S_MAC_PRINT;
          end else begin
            mac_word_q <= mac_word_q + 2'd1;
            state_q    <= S_MAC_SEND;
          end
        end
        S_MAC_PRINT: if (text_ready_i) begin
          if (match_entry) begin
            // The address line was taken; the port line follows.
            state_q <= S_MAC_NEXT;
          end else begin
            mac_index_q <= mac_index_q + 32'd1;
            // The last entry schedules the closing metadata read.
            if ((mac_index_q + 32'd1) >= mac_count_q) begin
              meta_access_q <= 1'b1;
              meta_end_q    <= 1'b1;
            end else meta_access_q <= 1'b0;
            state_q <= S_MAC_IDLE;
          end
        end
        S_MAC_NEXT: if (text_ready_i) begin
          mac_index_q <= mac_index_q + 32'd1;
          if ((mac_index_q + 32'd1) >= mac_count_q) begin
            meta_access_q <= 1'b1;
            meta_end_q    <= 1'b1;
          end else meta_access_q <= 1'b0;
          state_q <= S_MAC_IDLE;
        end
        S_META_SEND: if (csr_ready_i) state_q <= S_META_WAIT;
        S_META_WAIT: if (csr_valid_i) begin
          meta_q[{mac_word_q, 5'd0} +: 32] <= csr_data_i;
          // The metadata read is three words: the 64-bit clock then the flush
          // count.  Both lines are emitted after the last word lands.
          if (mac_word_q == 2'd2) begin
            mac_word_q  <= '0;
            meta_line_q <= 1'b0;
            state_q     <= S_META_PRINT;
          end else begin
            mac_word_q <= mac_word_q + 2'd1;
            state_q    <= S_META_SEND;
          end
        end
        S_META_PRINT: if (text_ready_i) begin
          if (!meta_line_q) meta_line_q <= 1'b1;
          else if (meta_end_q) state_q <= S_IDLE;
          else if (mac_count_q == 32'd0) begin
            // An empty table still gets its opening and closing metadata; with
            // no entries to walk, go straight to the closing read.
            meta_end_q    <= 1'b1;
            meta_access_q <= 1'b1;
            state_q       <= S_MAC_IDLE;
          end else begin
            meta_access_q <= 1'b0;
            state_q       <= S_MAC_IDLE;
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end

endmodule : es_console_cmd_mac

`default_nettype wire

`endif  // ES_CONSOLE_CMD_MAC_SV
