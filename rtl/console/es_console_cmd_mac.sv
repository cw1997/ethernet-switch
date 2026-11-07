// ============================================================================
//  File        : es_console_cmd_mac.sv
//  Description : Live MAC-table traversal for mac all and mac <port>.
//
//                start_i captures the table capacity and port filter. The CSR
//                grant spans each coherent entry or metadata read only; it is
//                released while the line consumer or UART is stalled. Lines
//                are accepted when text_valid_o and text_ready_i are both high.
//                A synchronous active-low reset returns the engine to idle.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_CONSOLE_CMD_MAC_SV
`define ES_CONSOLE_CMD_MAC_SV
`default_nettype none
`include "es_defs.sv"
`default_nettype none
module es_console_cmd_mac (
  input var logic clk_i, rst_ni, start_i,
  // filter_i is a zero-based port, or all ones for every port; count_i is
  // the table capacity captured with the command, not the number of matches.
  input var logic [31:0] filter_i, count_i,
  input var logic cache_idle_i,
  output logic bus_claim_o, req_o,
  output logic [31:0] addr_o,
  input var logic csr_ready_i, csr_valid_i,
  input var logic [31:0] csr_data_i,
  input var logic text_ready_i,
  // done_o coincides with acceptance of the final metadata line; busy_o stays
  // high from the cycle after start_i until that handshake completes.
  output logic text_valid_o, busy_o, done_o,
  output logic [511:0] text_o
);
  typedef enum logic [3:0] {
    S_IDLE, S_MAC_IDLE, S_MAC_SEND, S_MAC_WAIT, S_MAC_PRINT, S_MAC_NEXT,
    S_META_SEND, S_META_WAIT, S_META_PRINT
  } state_e;
  state_e state_q;
  logic [31:0] mac_index_q, filter_q, mac_count_q;
  logic [1:0] mac_word_q;
  logic [127:0] mac_entry_q;
  logic [95:0] meta_q;
  logic meta_end_q, meta_line_q, meta_access_q;
  logic unused_mac_reserved, match_entry;
  assign unused_mac_reserved = ^mac_entry_q[127:97];
  assign match_entry = mac_entry_q[96] &&
      ((filter_q == 32'hffff_ffff) || (filter_q == mac_entry_q[95:64]));
  function automatic logic [511:0] value_line(input var logic [191:0] label,
                                              input var logic [63:0] value);
    logic [127:0] hextext;
    for (int unsigned h = 0; h < 16; h++) hextext[127-h*8 -: 8] = sw_hexchar(value[63-h*4 -: 4]);
    value_line = {label, "=0x", hextext, 16'h0d0a, 152'd0};
  endfunction

  // A grant cannot be held while the UART waits for CTS: the display cache
  // uses the same CSR bus and must continue refreshing between reads.
  assign bus_claim_o = ((state_q == S_MAC_IDLE) && cache_idle_i && text_ready_i) ||
      (state_q == S_MAC_SEND) || (state_q == S_MAC_WAIT) || (state_q == S_META_SEND) ||
      (state_q == S_META_WAIT);
  assign req_o = (state_q == S_MAC_SEND) || (state_q == S_META_SEND);
  assign addr_o = ((state_q == S_META_SEND) || (state_q == S_META_WAIT)) ?
      32'hf0 + {28'd0, mac_word_q, 2'b00} :
      SW_MON_MAC_BASE + mac_index_q * 32'd16 + {28'd0, mac_word_q, 2'b00};
  assign busy_o = state_q != S_IDLE;
  assign text_valid_o = ((state_q == S_MAC_PRINT) && match_entry) ||
      (state_q == S_MAC_NEXT) || (state_q == S_META_PRINT);
  assign done_o = (state_q == S_META_PRINT) && meta_line_q && meta_end_q && text_ready_i;
  always_comb begin
    text_o = '0;
    case (state_q)
      S_MAC_PRINT: text_o = value_line("mac_address", mac_entry_q[63:0]);
      S_MAC_NEXT: text_o = value_line("mac_port", {32'd0, mac_entry_q[95:64]});
      S_META_PRINT: text_o = meta_line_q ? value_line(
          meta_end_q ? "mac_end_flushes" : "mac_start_flushes", {32'd0, meta_q[95:64]}
      ) : value_line(meta_end_q ? "mac_end_clock" : "mac_start_clock", meta_q[63:0]);
      default: text_o = '0;
    endcase
  end

  // Four words form a MAC entry and three words form the timestamp/flush
  // metadata. The response brackets the live traversal with both samples.
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= S_IDLE;
      mac_index_q <= '0;
      mac_word_q <= '0;
      mac_entry_q <= '0;
      filter_q <= '1;
      mac_count_q <= '0;
      meta_q <= '0;
      meta_end_q <= 1'b0;
      meta_line_q <= 1'b0;
      meta_access_q <= 1'b1;
    end else begin
      case (state_q)
        S_IDLE: if (start_i) begin
          filter_q <= filter_i;
          mac_index_q <= '0;
          mac_word_q <= '0;
          mac_count_q <= count_i;
          meta_end_q <= 1'b0;
          meta_line_q <= 1'b0;
          meta_access_q <= 1'b1;
          state_q <= S_MAC_IDLE;
        end
        S_MAC_IDLE: if (cache_idle_i && text_ready_i) begin
          state_q <= meta_access_q ? S_META_SEND : S_MAC_SEND;
        end
        S_MAC_SEND: if (csr_ready_i) state_q <= S_MAC_WAIT;
        S_MAC_WAIT: if (csr_valid_i) begin
          mac_entry_q[{mac_word_q, 5'd0} +: 32] <= csr_data_i;
          if (mac_word_q == 2'd3) begin
            mac_word_q <= '0;
            state_q <= S_MAC_PRINT;
          end else begin
            mac_word_q <= mac_word_q + 2'd1;
            state_q <= S_MAC_SEND;
          end
        end
        S_MAC_PRINT: if (text_ready_i) begin
          if (match_entry) begin
            state_q <= S_MAC_NEXT;
          end else begin
            mac_index_q <= mac_index_q + 32'd1;
            if (mac_index_q + 32'd1 >= mac_count_q) begin
              meta_access_q <= 1'b1;
              meta_end_q <= 1'b1;
            end else meta_access_q <= 1'b0;
            state_q <= S_MAC_IDLE;
          end
        end
        S_MAC_NEXT: if (text_ready_i) begin
          mac_index_q <= mac_index_q + 32'd1;
          if (mac_index_q + 32'd1 >= mac_count_q) begin
            meta_access_q <= 1'b1;
            meta_end_q <= 1'b1;
          end else meta_access_q <= 1'b0;
          state_q <= S_MAC_IDLE;
        end
        S_META_SEND: if (csr_ready_i) state_q <= S_META_WAIT;
        S_META_WAIT: if (csr_valid_i) begin
          meta_q[{mac_word_q, 5'd0} +: 32] <= csr_data_i;
          if (mac_word_q == 2'd2) begin
            mac_word_q <= '0;
            meta_line_q <= 1'b0;
            state_q <= S_META_PRINT;
          end else begin
            mac_word_q <= mac_word_q + 2'd1;
            state_q <= S_META_SEND;
          end
        end
        S_META_PRINT: if (text_ready_i) begin
          if (!meta_line_q) meta_line_q <= 1'b1;
          else if (meta_end_q) state_q <= S_IDLE;
          else if (mac_count_q == 32'd0) begin
            meta_end_q <= 1'b1;
            meta_access_q <= 1'b1;
            state_q <= S_MAC_IDLE;
          end else begin
            meta_access_q <= 1'b0;
            state_q <= S_MAC_IDLE;
          end
        end
        default: state_q <= S_IDLE;
      endcase
    end
  end
endmodule
`default_nettype wire
`endif  // ES_CONSOLE_CMD_MAC_SV
