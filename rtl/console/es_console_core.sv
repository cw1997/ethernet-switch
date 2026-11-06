// ============================================================================
//  File        : es_console_core.sv
//  Description : Bounded ASCII command console with coherent telemetry responses.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                Copies the cache before printing. UART or CTS stalls cannot mix snapshots
//                or block forwarding; malformed and busy input is diagnosed.
//  Interface   : NUM_PORTS defaults to four. CLK_FREQ_HZ and UART_BAUD_RATE
//                are in hertz and bits/s; UART_DATA_BITS, PARITY, STOP_BITS and
//                FLOW_CONTROL select framing. CTS/RTS are active low. image_i
//                contains aggregate record zero then port records. CSR ownership
//                is released during UART waits; fault_o reports rejected input.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_CONSOLE_CORE_SV
`define ES_CONSOLE_CORE_SV
`default_nettype none
`include "es_defs.sv"
`include "console/es_console_defs.sv"
`default_nettype none

// --------------------------------------------------------------------------
// Configuration and public interface
// --------------------------------------------------------------------------
module es_console_core #(
  /// Number of switch ports; packed port 0 uses the least-significant slice.
  parameter int unsigned NUM_PORTS = SW_DEFAULT_NUM_PORTS,
  /// Core clock frequency in hertz; timing counters use this value.
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  /// Console UART bit rate in bits per second.
  parameter int unsigned UART_BAUD_RATE = 115200,
  /// Console character width; ASCII commands require seven or eight data bits.
  parameter int unsigned UART_DATA_BITS = 8,
  /// Console parity encoding from es_console_defs.sv.
  parameter int unsigned UART_PARITY = SW_UART_PARITY_NONE,
  /// Number of console stop bits per character.
  parameter int unsigned UART_STOP_BITS = 1,
  /// Console CTS/RTS policy from es_console_defs.sv.
  parameter int unsigned UART_FLOW_CONTROL = SW_UART_FLOW_NONE
) (
  input var logic clk_i, rst_ni, rx_i, cts_ni,
  output logic tx_o, rts_no,
  input var logic [(NUM_PORTS+1)*SW_MON_BITS-1:0] image_i,
  input var logic cache_idle_i,
  output logic bus_claim_o, req_o,
  output logic [31:0] addr_o,
  input var logic ready_i, valid_i,
  input var logic [31:0] data_i,
  output logic fault_o
);
  generate
    if (UART_DATA_BITS < 7) begin : g_ascii_invalid
      SW_CONSOLE_REQUIRES_7_OR_8_DATA_BITS invalid_parameters ();
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Control state
  // --------------------------------------------------------------------------
  typedef enum logic [3:0] {
    S_RX,
    S_PARSE,
    S_PRINT,
    S_END,
    S_MAC_IDLE,
    S_MAC_SEND,
    S_MAC_WAIT,
    S_MAC_PRINT,
    S_MAC_NEXT,
    S_META_SEND,
    S_META_WAIT,
    S_META_PRINT
  } state_e;
  state_e state_q;
  logic rx_valid, tx_ready, parity_error, frame_error, overflow;
  logic [  7:0] rx_data;
  // Command bytes accumulate at increasing low-byte offsets until a line ending.
  logic [255:0] command_q;
  logic [  5:0] length_q;
  logic long_q, deferred_error_q;
  logic [511:0] text_q;
  logic [6:0] text_left_q;
  // Freeze the cache for the entire response so UART backpressure cannot mix samples.
  logic [(NUM_PORTS+1)*SW_MON_BITS-1:0] held_q;
  logic [31:0] page_q, last_page_q, mac_index_q, filter_q;
  logic [5:0] line_q;
  logic [1:0] mac_word_q;
  logic [127:0] mac_entry_q;
  logic unused_mac_reserved;
  assign unused_mac_reserved = ^mac_entry_q[127:97];
  logic [31:0] mac_count_q;
  logic [95:0] meta_q;
  logic meta_end_q, meta_line_q, meta_access_q;
  logic [35:0] parsed;
  logic [31:0] word_index;
  logic [63:0] print_value;
  logic [191:0] print_label;
  logic [SW_MON_BITS-1:0] record;
  logic [31:0] parity_errors_q, frame_errors_q, overflow_errors_q, busy_errors_q, long_errors_q;
  logic text_empty, unused_rts;
  assign rts_no = (UART_FLOW_CONTROL == SW_UART_FLOW_NONE) ? 1'b0 : (state_q != S_RX);
  assign text_empty = text_left_q == 7'd0;
  es_perips_uart #(
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .BAUD_RATE(UART_BAUD_RATE),
    .DATA_BITS(UART_DATA_BITS),
    .PARITY(UART_PARITY),
    .STOP_BITS(UART_STOP_BITS),
    .FLOW_CONTROL(UART_FLOW_CONTROL)
  ) u_uart (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .rx_i(rx_i),
    .cts_ni(cts_ni),
    .tx_o(tx_o),
    .rts_no(unused_rts),
    .tx_valid_i(!text_empty && (text_q[511:504] != 8'd0)),
    .tx_data_i(text_q[511:504]),
    .tx_ready_o(tx_ready),
    .rx_valid_o(rx_valid),
    .rx_data_o(rx_data),
    .rx_ready_i(1'b1),
    .parity_error_o(parity_error),
    .frame_error_o(frame_error),
    .overflow_o(overflow)
  );

  // --------------------------------------------------------------------------
  // Command parsing and text formatting
  //
  // The parser returns a command kind and bounded decimal port index.
  // Formatting consumes the held snapshot while live CSR accesses use
  // explicit bus ownership.
  // --------------------------------------------------------------------------
  function automatic logic [35:0] parse(input var logic [255:0] cmd,
                                        input var logic [5:0] len);
    logic [3:0] kind;
    logic [31:0] number;
    logic [7:0] ch;
    int unsigned first;
    logic bad;
    kind = 4'd5;
    first = 32;
    number = '0;
    bad = 1'b0;
    ch = '0;
    if ((len == 6'd4) && (cmd[31:0] == 32'h706c6568)) kind = 4'd0;  // help
    if ((len == 6'd6) && (cmd[47:0] == 48'h737574617473)) kind = 4'd1;  // status
    if ((len > 6'd5) && (cmd[39:0] == 40'h2074726f70)) begin
      kind  = 4'd2;
      first = 5;
    end
    if ((len == 6'd7) && (cmd[55:0] == 56'h6c6c612063616d)) kind = 4'd3;
    else if ((len > 6'd4) && (cmd[31:0] == 32'h2063616d)) begin
      kind  = 4'd4;
      first = 4;
    end
    for (int unsigned b = 0; b < 32; b++) begin
      if ((b >= first) && (b < 32'(len))) begin
        ch = cmd[b*8 +: 8];
        if ((ch < "0") || (ch > "9") || (number > 32'(NUM_PORTS))) bad = 1'b1;
        // Decimal port IDs are bounded before every multiply, so malformed
        // input cannot wrap around and select an unintended valid port.
        if (!bad) number = number * 32'd10 + {24'd0, ch} - 32'd48;
      end
    end
    if (bad || (((kind == 4'd2) || (kind == 4'd4)) && (number >= 32'(NUM_PORTS)))) kind = 4'd5;
    parse = {kind, number};
  endfunction
  assign parsed = parse(command_q, length_q);

  function automatic logic [511:0] value_line(input var logic [191:0] label,
                                              input var logic [63:0] value);
    logic [127:0] hextext;
    for (int unsigned h = 0; h < 16; h++) hextext[127-h*8 -: 8] = sw_hexchar(value[63-h*4 -: 4]);
    value_line = {label, "=0x", hextext, 16'h0d0a, 152'd0};
  endfunction
  function automatic logic [191:0] label_for(input var logic [5:0] line);
    case (line)
      6'd0: label_for = "snapshot_seq";
      6'd1: label_for = "sample_valid";
      6'd2: label_for = "phy_status";
      6'd3: label_for = "rx_used_beats";
      6'd4: label_for = "tx_used_beats";
      6'd5: label_for = "rx_peak_beats";
      6'd6: label_for = "tx_peak_beats";
      6'd7: label_for = "rx_load_permille";
      6'd8: label_for = "tx_load_permille";
      6'd9: label_for = "rx_frames";
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
  assign record = held_q[page_q*32'(SW_MON_BITS) +: SW_MON_BITS];
  always_comb begin
    word_index  = 32'd0;
    print_value = '0;
    print_label = label_for(line_q);
    case (line_q)
      6'd0: print_value = {32'd0, held_q[49*32 +: 32]};
      6'd1: print_value = {32'd0, held_q[50*32 +: 32]};
      6'd23: print_value = held_q[44*32 +: 64];
      6'd24: print_value = held_q[46*32 +: 64];
      6'd25: print_value = {32'd0, held_q[48*32 +: 32]};
      6'd26: print_value = {32'd0, held_q[51*32 +: 32]};
      6'd27: print_value = {32'd0, held_q[52*32 +: 32]};
      6'd28: print_value = {32'd0, held_q[53*32 +: 32]};
      6'd29: print_value = {32'd0, held_q[54*32 +: 32]};
      6'd30: print_value = {32'd0, held_q[55*32 +: 32]};
      6'd31: print_value = held_q[56*32 +: 64];
      6'd33: print_value = {32'd0, parity_errors_q};
      6'd34: print_value = {32'd0, frame_errors_q};
      6'd35: print_value = {32'd0, overflow_errors_q};
      6'd36: print_value = {32'd0, busy_errors_q};
      6'd37: print_value = {32'd0, long_errors_q};
      6'd38: print_value = {63'd0, record[0]};
      6'd39: print_value = {63'd0, record[1]};
      6'd40:
      print_value = (!record[0] || !record[1]) ? 64'd0 : (record[4:3] == 2'd0) ?
          64'd10 : (record[4:3] == 2'd1) ? 64'd100 : (record[4:3] == 2'd2) ? 64'd1000 : 64'd0;
      6'd41: print_value = {63'd0, record[0] && record[1] && record[2]};
      6'd42: print_value = {63'd0, record[5]};
      6'd63: print_value = {32'd0, page_q};
      default: begin
        if (line_q < 6'd9) begin
          word_index  = 32'(line_q) - 32'd2;
          print_value = {32'd0, record[word_index*32'd32 +: 32]};
        end else begin
          word_index = (line_q < 6'd19) ? 32'(SW_MON_COUNTER) + (32'(line_q) - 32'd9) * 32'd2 :
              32'(SW_MON_RATE) + (32'(line_q) - 32'd19) * 32'd2;
          print_value = record[word_index*32'd32 +: 64];
        end
      end
    endcase
    if ((page_q == 32'd0) && (line_q == 6'd2)) print_label = "system_ready";
    if ((page_q == 32'd0) && (line_q == 6'd3)) print_label = "num_ports";
  end
  // Hold the bus only across a coherent entry or timestamp read. UART output
  // can wait on CTS indefinitely; holding the grant there freezes the display.
  assign bus_claim_o = ((state_q == S_MAC_IDLE) && cache_idle_i && text_empty) ||
      (state_q == S_MAC_SEND) || (state_q == S_MAC_WAIT) || (state_q == S_META_SEND) ||
      (state_q == S_META_WAIT);
  assign req_o = (state_q == S_MAC_SEND) || (state_q == S_META_SEND);
  assign addr_o = ((state_q == S_META_SEND) || (state_q == S_META_WAIT)) ?
      32'hf0 + {28'd0, mac_word_q, 2'b00} :
      SW_MON_MAC_BASE + mac_index_q * 32'd16 + {28'd0, mac_word_q, 2'b00};

  // --------------------------------------------------------------------------
  // Synchronous state and datapath
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= S_RX;
      command_q <= '0;
      length_q <= '0;
      long_q <= 1'b0;
      deferred_error_q <= 1'b0;
      fault_o <= 1'b0;
      parity_errors_q <= '0;
      frame_errors_q <= '0;
      overflow_errors_q <= '0;
      busy_errors_q <= '0;
      long_errors_q <= '0;
      text_q <= '0;
      text_left_q <= '0;
      page_q <= '0;
      last_page_q <= '0;
      line_q <= '0;
      mac_index_q <= '0;
      mac_word_q <= '0;
      mac_entry_q <= '0;
      filter_q <= '1;
      mac_count_q <= '0;
      meta_q <= '0;
      meta_end_q <= 1'b0;
      meta_line_q <= 1'b0;
      meta_access_q <= 1'b1;
      for (int unsigned p = 0; p <= NUM_PORTS; p++) held_q[p*SW_MON_BITS +: SW_MON_BITS] <= '0;
    end else begin
      if (!text_empty && ((text_q[511:504] == 8'd0) || tx_ready)) begin
        text_q <= {text_q[503:0], 8'd0};
        text_left_q <= text_left_q - 7'd1;
      end
      if (parity_error) parity_errors_q <= parity_errors_q + 32'd1;
      if (frame_error) frame_errors_q <= frame_errors_q + 32'd1;
      if (overflow) overflow_errors_q <= overflow_errors_q + 32'd1;
      if (rx_valid && (state_q != S_RX) && (rx_data != 8'd10) && (rx_data != 8'd13))
        busy_errors_q <= busy_errors_q + 32'd1;
      if (parity_error || frame_error || overflow ||
          (rx_valid && (state_q != S_RX) && (rx_data != 8'd10) && (rx_data != 8'd13))) begin
        fault_o <= 1'b1;
        deferred_error_q <= 1'b1;
      end
      case (state_q)
        S_RX: begin
          if (deferred_error_q && text_empty) begin
            text_q <= {"ERR busy_or_uart_frame_or_overflow\015\n", 224'd0};
            text_left_q <= 7'd64;
            deferred_error_q <= 1'b0;
          end
          if (rx_valid) begin
            if ((rx_data == 8'd13) || (rx_data == 8'd10)) begin
              if ((length_q != 6'd0) || long_q) state_q <= S_PARSE;
            end else if ((rx_data == 8'd8) || (rx_data == 8'd127)) begin
              if (length_q != 6'd0) begin
                length_q <= length_q - 6'd1;
                command_q[(32'(length_q)-32'd1)*32'd8 +: 8] <= '0;
              end
            end else if (length_q < 6'd32) begin
              command_q[32'(length_q)*32'd8 +: 8] <= rx_data;
              length_q <= length_q + 6'd1;
            end else begin
              long_q  <= 1'b1;
              fault_o <= 1'b1;
              if (!long_q) long_errors_q <= long_errors_q + 32'd1;
            end
          end
        end
        S_PARSE: if (text_empty) begin
          held_q <= image_i;
          line_q <= 6'd63;
          page_q <= '0;
          last_page_q <= '0;
          state_q <= S_PRINT;
          if (long_q || (parsed[35:32] == 4'd5)) begin
            text_q <= {"ERR command_or_port_or_length\015\n", 264'd0};
            text_left_q <= 7'd64;
            state_q <= S_END;
          end else
            case (parsed[35:32])
              4'd0: begin
                text_q <= {"help | status | port <n> | mac all | mac <n>\015\n", 144'd0};
                text_left_q <= 7'd64;
                state_q <= S_END;
              end
              4'd1: last_page_q <= 32'(NUM_PORTS);
              4'd2: begin
                page_q <= parsed[31:0] + 32'd1;
                last_page_q <= parsed[31:0] + 32'd1;
              end
              4'd3, 4'd4: begin
                if (!image_i[SW_MON_VALID_WORD*32]) begin
                  text_q <= {"ERR sample_not_ready", 16'h0d0a, 336'd0};
                  text_left_q <= 7'd64;
                  state_q <= S_END;
                end else begin
                  filter_q <= (parsed[35:32] == 4'd3) ? 32'hffff_ffff : parsed[31:0];
                  mac_index_q <= '0;
                  mac_word_q <= '0;
                  mac_count_q <= image_i[52*32 +: 32];
                  meta_end_q <= 1'b0;
                  meta_line_q <= 1'b0;
                  meta_access_q <= 1'b1;
                  state_q <= S_MAC_IDLE;
                end
              end
              default: state_q <= S_END;
            endcase
          command_q <= '0;
          length_q <= '0;
          long_q <= 1'b0;
        end
        S_PRINT: if (text_empty) begin
          text_q <= value_line(print_label, print_value);
          text_left_q <= 7'd64;
          if (line_q == 6'd63) line_q <= '0;
          else if ((page_q == 32'd0) && (line_q == 6'd3)) line_q <= 6'd9;
          else if ((line_q == 6'd42) || ((page_q == 32'd0) && (line_q == 6'd37))) begin
            if (page_q == last_page_q) state_q <= S_END;
            else begin
              page_q <= page_q + 32'd1;
              line_q <= 6'd63;
            end
          end else if (line_q == 6'd31) line_q <= 6'd33;
          else line_q <= line_q + 6'd1;
        end
        S_END: if (text_empty) state_q <= S_RX;
        S_MAC_IDLE: if (cache_idle_i && text_empty) begin
          state_q <= meta_access_q ? S_META_SEND : S_MAC_SEND;
        end
        S_MAC_SEND: if (ready_i) state_q <= S_MAC_WAIT;
        S_MAC_WAIT: if (valid_i) begin
          mac_entry_q[{mac_word_q, 5'd0} +: 32] <= data_i;
          if (mac_word_q == 2'd3) begin
            mac_word_q <= '0;
            state_q <= S_MAC_PRINT;
          end else begin
            mac_word_q <= mac_word_q + 2'd1;
            state_q <= S_MAC_SEND;
          end
        end
        S_MAC_PRINT: if (text_empty) begin
          if (mac_entry_q[96] &&
              ((filter_q == 32'hffff_ffff) || (filter_q == mac_entry_q[95:64]))) begin
            text_q <= value_line("mac_address", mac_entry_q[63:0]);
            text_left_q <= 7'd64;
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
        S_MAC_NEXT: if (text_empty) begin
          text_q <= value_line("mac_port", {32'd0, mac_entry_q[95:64]});
          text_left_q <= 7'd64;
          mac_index_q <= mac_index_q + 32'd1;
          if (mac_index_q + 32'd1 >= mac_count_q) begin
            meta_access_q <= 1'b1;
            meta_end_q <= 1'b1;
          end else meta_access_q <= 1'b0;
          state_q <= S_MAC_IDLE;
        end
        S_META_SEND: if (ready_i) state_q <= S_META_WAIT;
        S_META_WAIT: if (valid_i) begin
          meta_q[{mac_word_q, 5'd0} +: 32] <= data_i;
          if (mac_word_q == 2'd2) begin
            mac_word_q <= '0;
            meta_line_q <= 1'b0;
            state_q <= S_META_PRINT;
          end else begin
            mac_word_q <= mac_word_q + 2'd1;
            state_q <= S_META_SEND;
          end
        end
        S_META_PRINT: if (text_empty) begin
          text_q <= meta_line_q ? value_line(
              meta_end_q ? "mac_end_flushes" : "mac_start_flushes", {32'd0, meta_q[95:64]}
          ) : value_line(
              meta_end_q ? "mac_end_clock" : "mac_start_clock", meta_q[63:0]
          );
          text_left_q <= 7'd64;
          if (!meta_line_q) meta_line_q <= 1'b1;
          else if (meta_end_q) state_q <= S_END;
          else if (mac_count_q == 32'd0) begin
            meta_end_q <= 1'b1;
            meta_access_q <= 1'b1;
            state_q <= S_MAC_IDLE;
          end else begin
            meta_access_q <= 1'b0;
            state_q <= S_MAC_IDLE;
          end
        end
        default: state_q <= S_RX;
      endcase
    end
  end
endmodule
`default_nettype wire
`endif
