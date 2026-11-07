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
  /// Console parity encoding from es_perips_defs.sv.
  parameter int unsigned UART_PARITY = SW_UART_PARITY_NONE,
  /// Number of console stop bits per character.
  parameter int unsigned UART_STOP_BITS = 1,
  /// Console CTS/RTS policy from es_perips_defs.sv.
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
  typedef enum logic [2:0] {S_RX, S_PARSE, S_STATUS, S_PORT, S_MAC, S_END} state_e;
  state_e state_q;
  logic rx_valid, tx_ready, parity_error, frame_error, overflow;
  logic [  7:0] rx_data;
  // Command bytes accumulate at increasing low-byte offsets until a line ending.
  logic [255:0] command_q;
  logic [  5:0] length_q;
  logic long_q, deferred_error_q;
  logic [511:0] text_q;
  logic [6:0] text_left_q;
  logic [35:0] parsed;
  logic [31:0] parity_errors_q, frame_errors_q, overflow_errors_q, busy_errors_q, long_errors_q;
  logic text_empty, unused_rts;
  logic help_valid, help_done;
  logic [511:0] help_text;
  // Each command owns the shared text buffer until its last line is
  // accepted. The status and port policies share one snapshot formatter.
  logic status_start, status_busy, status_done, port_start, port_busy, port_done;
  logic snapshot_busy, snapshot_done, snapshot_valid;
  logic [31:0] status_first, status_last, port_first, port_last;
  logic [511:0] snapshot_text, mac_text;
  logic mac_start, mac_busy, mac_done, mac_valid;
  logic parse_ready;
  assign parse_ready = (state_q == S_PARSE) && text_empty && !long_q;
  es_console_cmd_status #(.NUM_PORTS(NUM_PORTS)) u_cmd_status (
    .start_i(parse_ready && (parsed[35:32] == 4'd1)), .selected_i(state_q == S_STATUS),
    .engine_busy_i(snapshot_busy), .engine_done_i(snapshot_done),
    .start_o(status_start), .busy_o(status_busy), .done_o(status_done),
    .first_page_o(status_first), .last_page_o(status_last)
  );
  es_console_cmd_port u_cmd_port (
    .start_i(parse_ready && (parsed[35:32] == 4'd2)), .selected_i(state_q == S_PORT),
    .engine_busy_i(snapshot_busy), .engine_done_i(snapshot_done), .port_i(parsed[31:0]),
    .start_o(port_start), .busy_o(port_busy), .done_o(port_done),
    .first_page_o(port_first), .last_page_o(port_last)
  );
  es_console_snapshot #(.NUM_PORTS(NUM_PORTS)) u_snapshot (
    .clk_i(clk_i), .rst_ni(rst_ni), .start_i(status_start || port_start),
    .first_page_i(port_start ? port_first : status_first),
    .last_page_i(port_start ? port_last : status_last), .image_i(image_i),
    .parity_errors_i(parity_errors_q), .frame_errors_i(frame_errors_q),
    .overflow_errors_i(overflow_errors_q), .busy_errors_i(busy_errors_q),
    .long_errors_i(long_errors_q), .ready_i(text_empty), .valid_o(snapshot_valid),
    .busy_o(snapshot_busy), .done_o(snapshot_done), .text_o(snapshot_text)
  );
  assign mac_start = parse_ready && ((parsed[35:32] == 4'd3) || (parsed[35:32] == 4'd4)) &&
      image_i[SW_MON_VALID_WORD*32];
  es_console_cmd_mac u_cmd_mac (
    .clk_i(clk_i), .rst_ni(rst_ni), .start_i(mac_start),
    .filter_i((parsed[35:32] == 4'd3) ? 32'hffff_ffff : parsed[31:0]),
    .count_i(image_i[52*32 +: 32]), .cache_idle_i(cache_idle_i),
    .bus_claim_o(bus_claim_o), .req_o(req_o), .addr_o(addr_o),
    .csr_ready_i(ready_i), .csr_valid_i(valid_i), .csr_data_i(data_i),
    .text_ready_i(text_empty), .text_valid_o(mac_valid), .busy_o(mac_busy),
    .done_o(mac_done), .text_o(mac_text)
  );
  assign rts_no = (UART_FLOW_CONTROL == SW_UART_FLOW_NONE) ? 1'b0 : (state_q != S_RX);
  assign text_empty = text_left_q == 7'd0;
  es_console_cmd_help u_cmd_help (
    .start_i((state_q == S_PARSE) && !long_q && (parsed[35:32] == 4'd0)),
    .ready_i(text_empty),
    .valid_o(help_valid),
    .done_o(help_done),
    .text_o(help_text)
  );
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
  // Command parsing
  //
  // The parser returns a command kind and bounded decimal port index. The
  // selected command owns the response generator until its final line.
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
          state_q <= S_END;
          if (long_q || (parsed[35:32] == 4'd5)) begin
            text_q <= {"ERR command_or_port_or_length\015\n", 264'd0};
            text_left_q <= 7'd64;
          end else begin
            case (parsed[35:32])
              4'd0: if (help_valid && help_done) begin
                text_q <= help_text;
                text_left_q <= 7'd64;
              end
              4'd1: state_q <= S_STATUS;
              4'd2: state_q <= S_PORT;
              4'd3, 4'd4: begin
                if (!image_i[SW_MON_VALID_WORD*32]) begin
                  text_q <= {"ERR sample_not_ready", 16'h0d0a, 336'd0};
                  text_left_q <= 7'd64;
                end else state_q <= S_MAC;
              end
              default: state_q <= S_END;
            endcase
          end
          command_q <= '0;
          length_q <= '0;
          long_q <= 1'b0;
        end
        S_STATUS, S_PORT: begin
          if ((status_busy || port_busy) && snapshot_valid && text_empty) begin
            text_q <= snapshot_text;
            text_left_q <= 7'd64;
          end
          if (status_done || port_done) state_q <= S_END;
        end
        S_MAC: begin
          if (mac_busy && mac_valid && text_empty) begin
            text_q <= mac_text;
            text_left_q <= 7'd64;
          end
          if (mac_done) state_q <= S_END;
        end
        S_END: if (text_empty) state_q <= S_RX;
        default: state_q <= S_RX;
      endcase
    end
  end
endmodule
`default_nettype wire
`endif
