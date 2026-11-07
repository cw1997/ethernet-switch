// ============================================================================
//  File        : es_console_snapshot.sv
//  Description : Shared snapshot response generator for status and port.
//
//                The packed cache image is captured on start_i, so a UART stall
//                can never mix two cache generations.  Aggregate page zero comes
//                first, then the port pages; the console error counters stay
//                live, matching the console ABI.
//
//                Response line map (one line per accepted handshake):
//                  63        page header
//                  0..8      aggregate or per-port summary words
//                  9..22     the 14 counter pairs
//                  23..30    uptime, window, refresh, CAM state, fabric load
//                  31        sample clock
//                  33..37    live console error counters
//                  38..42    PHY status of the selected port
//                Line 32 is never emitted: the cursor steps from 31 straight to
//                33, which keeps that slot free for a future field.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_CONSOLE_SNAPSHOT_SV
`define ES_CONSOLE_SNAPSHOT_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_console_snapshot #(
  /// Number of switch ports included after aggregate record zero.
  parameter int unsigned NUM_PORTS = SW_DEFAULT_NUM_PORTS
) (
  /// Clock, synchronous active-low reset, and command start pulse.
  input var logic clk_i, rst_ni, start_i,
  /// Page range to emit: page zero is aggregate, page p+1 holds port p.  The
  /// caller guarantees 0 <= first_page_i <= last_page_i <= NUM_PORTS.
  input var logic [31:0] first_page_i, last_page_i,
  /// Packed image captured at start; records contain SW_MON_BITS each.
  input var logic [(NUM_PORTS+1)*SW_MON_BITS-1:0] image_i,
  /// Live console error counters appended to each response.
  input var logic [31:0] parity_errors_i, frame_errors_i, overflow_errors_i,
  input var logic [31:0] busy_errors_i, long_errors_i,
  /// Ready/valid line handshake; state advances only when ready_i is high.
  input var logic ready_i,
  /// done_o accompanies acceptance of the last line, not UART transmission.
  output    logic valid_o, busy_o, done_o,
  /// One left-aligned 64-byte ASCII response line.
  output    logic [511:0] text_o);

  // --------------------------------------------------------------------------
  // Held image and cursor
  //
  // A page is held until all of its lines have been accepted.  The cache copy
  // is frozen at command start, even if transmission is stopped by CTS.
  // --------------------------------------------------------------------------
  logic [(NUM_PORTS+1)*SW_MON_BITS-1:0] held_q;
  logic [31:0] page_q;
  logic [31:0] last_page_q;
  logic [31:0] word_index;  ///< word being printed, combinational per line
  logic [ 5:0] line_q;      ///< line within the current page
  logic        active_q;
  logic        last_line;

  logic [63:0]  print_value;
  logic [191:0] print_label;
  logic [SW_MON_BITS-1:0] record;

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

  function automatic logic [191:0] label_for(input var logic [5:0] line);
    case (line)
      6'd0:  label_for = "snapshot_seq";
      6'd1:  label_for = "sample_valid";
      6'd2:  label_for = "phy_status";
      6'd3:  label_for = "rx_used_beats";
      6'd4:  label_for = "tx_used_beats";
      6'd5:  label_for = "rx_peak_beats";
      6'd6:  label_for = "tx_peak_beats";
      6'd7:  label_for = "rx_load_permille";
      6'd8:  label_for = "tx_load_permille";
      6'd9:  label_for = "rx_frames";
      6'd10: label_for = "rx_octets";
      6'd11: label_for = "rx_filtered";
      6'd12: label_for = "rx_crc_error";
      6'd13: label_for = "rx_runt";
      6'd14: label_for = "rx_oversize";
      6'd15: label_for = "rx_overflow";
      6'd16: label_for = "tx_completed_frames";
      6'd17: label_for = "tx_completed_octets";
      6'd18: label_for = "ingress_stall_drops";
      6'd19: label_for = "rx_pps";
      6'd20: label_for = "tx_pps";
      6'd21: label_for = "rx_bit_per_second";
      6'd22: label_for = "tx_bit_per_second";
      6'd23: label_for = "uptime_seconds";
      6'd24: label_for = "window_clocks";
      6'd25: label_for = "refresh_ms";
      6'd26: label_for = "cam_entries";
      6'd27: label_for = "cam_capacity";
      6'd28: label_for = "cam_flushes";
      6'd29: label_for = "fabric_busy_permille";
      6'd30: label_for = "cam_age_enabled";
      6'd31: label_for = "sample_clock";
      6'd33: label_for = "uart_parity_errors";
      6'd34: label_for = "uart_frame_errors";
      6'd35: label_for = "uart_rx_overflows";
      6'd36: label_for = "console_busy_input";
      6'd37: label_for = "console_long_lines";
      6'd38: label_for = "phy_valid";
      6'd39: label_for = "link_up";
      6'd40: label_for = "speed_mbit";
      6'd41: label_for = "full_duplex";
      6'd42: label_for = "phy_management_error";
      default: label_for = "page_0_all_else_port+1";
    endcase
  endfunction

  // --------------------------------------------------------------------------
  // Line decode
  //
  // Aggregate-only fields come from the held image; the per-port fields come
  // from the record the current page selects.  Everything is a decode of
  // `line_q` and `page_q`, so no state is written here.
  // --------------------------------------------------------------------------
  assign record = held_q[page_q*32'(SW_MON_BITS) +: SW_MON_BITS];

  always_comb begin
    word_index  = 32'd0;
    print_value = '0;
    print_label = label_for(line_q);
    case (line_q)
      6'd0:  print_value = {32'd0, held_q[SW_MON_SEQUENCE_WORD*32 +: 32]};
      6'd1:  print_value = {32'd0, held_q[SW_MON_VALID_WORD*32 +: 32]};
      6'd23: print_value = held_q[SW_MON_UPTIME_WORD*32 +: 64];
      6'd24: print_value = held_q[SW_MON_WINDOW_WORD*32 +: 64];
      6'd25: print_value = {32'd0, held_q[SW_MON_REFRESH_WORD*32 +: 32]};
      6'd26: print_value = {32'd0, held_q[SW_MON_CAM_ENTRIES_WORD*32 +: 32]};
      6'd27: print_value = {32'd0, held_q[SW_MON_CAM_CAPACITY_WORD*32 +: 32]};
      6'd28: print_value = {32'd0, held_q[SW_MON_FLUSH_WORD*32 +: 32]};
      6'd29: print_value = {32'd0, held_q[SW_MON_BUSY_WORD*32 +: 32]};
      6'd30: print_value = {32'd0, held_q[SW_MON_AGE_WORD*32 +: 32]};
      6'd31: print_value = held_q[SW_MON_TIME_WORD*32 +: 64];
      6'd33: print_value = {32'd0, parity_errors_i};
      6'd34: print_value = {32'd0, frame_errors_i};
      6'd35: print_value = {32'd0, overflow_errors_i};
      6'd36: print_value = {32'd0, busy_errors_i};
      6'd37: print_value = {32'd0, long_errors_i};
      6'd38: print_value = {63'd0, record[0]};
      6'd39: print_value = {63'd0, record[1]};
      // A port without a valid link has no negotiated speed, so it reports
      // 0 Mbit/s rather than a speed code that was never latched.
      6'd40: print_value = (!record[0] || !record[1]) ? 64'd0 :
                           (record[4:3] == 2'd0) ? 64'd10 :
                           (record[4:3] == 2'd1) ? 64'd100 :
                           (record[4:3] == 2'd2) ? 64'd1000 : 64'd0;
      6'd41: print_value = {63'd0, record[0] && record[1] && record[2]};
      6'd42: print_value = {63'd0, record[5]};
      6'd63: print_value = {32'd0, page_q};
      default: begin
        if (line_q < 6'd9) begin
          // Summary words 1..6 sit immediately after the status word.
          word_index  = 32'(line_q) - 32'd2;
          print_value = {32'd0, record[word_index*32'd32 +: 32]};
        end else begin
          // Counter pairs then rate pairs, both 64 bits per entry.
          word_index = (line_q < 6'd19) ?
              (32'(SW_MON_COUNTER) + (32'(line_q) - 32'd9) * 32'd2) :
              (32'(SW_MON_RATE) + (32'(line_q) - 32'd19) * 32'd2);
          print_value = record[word_index*32'd32 +: 64];
        end
      end
    endcase
    // Lines 2 and 3 carry different information on the aggregate page.
    if ((page_q == 32'd0) && (line_q == 6'd2)) print_label = "system_ready";
    if ((page_q == 32'd0) && (line_q == 6'd3)) print_label = "num_ports";
  end

  // --------------------------------------------------------------------------
  // Handshake
  //
  // A live error counter can change during a UART stall, so a line is presented
  // only once the consumer is ready: valid data never changes while stalled.
  // --------------------------------------------------------------------------
  assign valid_o   = active_q && ready_i;
  assign busy_o    = active_q;
  assign last_line = (line_q == 6'd42) || ((page_q == 32'd0) && (line_q == 6'd37));
  assign done_o    = active_q && ready_i && last_line && (page_q == last_page_q);
  assign text_o    = value_line(print_label, print_value);

  // --------------------------------------------------------------------------
  // Cursor
  //
  // Advances only when the dispatcher accepts a line.  The aggregate record
  // skips the per-port occupancy and PHY fields, and line 63 (the page header)
  // comes first, which is why the cursor starts there and then wraps to zero.
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      active_q    <= 1'b0;
      held_q      <= '0;
      page_q      <= '0;
      last_page_q <= '0;
      line_q      <= '0;
    end else if (start_i) begin
      held_q      <= image_i;
      page_q      <= first_page_i;
      last_page_q <= last_page_i;
      line_q      <= 6'd63;
      active_q    <= 1'b1;
    end else if (active_q && ready_i) begin
      if (line_q == 6'd63) line_q <= '0;
      else if ((page_q == 32'd0) && (line_q == 6'd3)) line_q <= 6'd9;
      else if (last_line) begin
        if (page_q == last_page_q) active_q <= 1'b0;
        else begin
          page_q <= page_q + 32'd1;
          line_q <= 6'd63;
        end
      end else if (line_q == 6'd31) line_q <= 6'd33;
      else line_q <= line_q + 6'd1;
    end
  end

endmodule : es_console_snapshot

`default_nettype wire

`endif  // ES_CONSOLE_SNAPSHOT_SV
