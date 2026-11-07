// ============================================================================
//  File        : es_console_core.sv
//  Description : Bounded ASCII command console with coherent telemetry responses.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                The cache image is copied before printing, so a UART or CTS
//                stall can neither mix two snapshots nor block forwarding.
//                Malformed input and commands arriving while a response is in
//                flight are both diagnosed rather than dropped silently.
//
//                NUM_PORTS defaults to four.  CLK_FREQ_HZ and UART_BAUD_RATE are
//                in hertz and bits/s; UART_DATA_BITS, UART_PARITY, UART_STOP_BITS
//                and UART_FLOW_CONTROL select the framing.  CTS/RTS are active
//                low.  image_i holds aggregate record zero followed by the port
//                records.  CSR ownership is released during UART waits, and
//                fault_o reports rejected input as a sticky flag.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_CONSOLE_CORE_SV
`define ES_CONSOLE_CORE_SV

`default_nettype none

`include "es_defs.sv"
`include "console/es_console_defs.sv"
`default_nettype none

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
  /// Clock/reset and asynchronous UART RX/CTS inputs; reset is active low.
  input var logic clk_i, rst_ni, rx_i, cts_ni,
  /// UART transmit data and active-low RTS back-pressure output.
  output    logic tx_o, rts_no,
  /// Coherent telemetry image: aggregate record zero, then one record per port.
  input var logic [(NUM_PORTS+1)*SW_MON_BITS-1:0] image_i,
  /// Safe CSR handoff boundary from the background telemetry cache.
  input var logic cache_idle_i,
  /// Console ownership and request to the shared byte-addressed CSR bus.
  output    logic bus_claim_o, req_o,
  output    logic [31:0] addr_o,
  /// CSR response handshake and returned data word.
  input var logic ready_i, valid_i,
  input var logic [31:0] data_i,
  /// Sticky diagnostic that input was rejected or a UART error occurred.
  output    logic fault_o
);

  // --------------------------------------------------------------------------
  // Parameter check
  //
  // The body instantiates a module that does not exist.  A false generate
  // branch is never elaborated, so a legal configuration costs nothing; an
  // illegal one fails with an unknown-module error that names this block.  The
  // alternative, `$error` in the datapath, is unavailable because yosys has no
  // implementation for it (AGENTS.md 3.4).
  // --------------------------------------------------------------------------
  generate
    if (UART_DATA_BITS < 7) begin : g_ascii_invalid
      SW_CONSOLE_REQUIRES_7_OR_8_DATA_BITS invalid_parameters ();
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Control state
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_RX,      ///< accumulate characters until a line ending
    S_PARSE,   ///< decode the line and hand it to its command engine
    S_STATUS,  ///< stream the status response
    S_PORT,    ///< stream the per-port response
    S_MAC,     ///< stream the MAC-table listing
    S_END      ///< drain the text buffer before returning to S_RX
  } state_e;

  state_e state_q;

  // --------------------------------------------------------------------------
  // UART interconnect
  // --------------------------------------------------------------------------
  logic       rx_valid;
  logic [7:0] rx_data;
  logic       tx_ready;
  logic       parity_error;
  logic       frame_error;
  logic       overflow;
  logic       unused_rts;  ///< the module derives its own RTS below

  // --------------------------------------------------------------------------
  // Command buffer and response text
  //
  // Command bytes accumulate at increasing low-byte offsets until a line
  // ending, and `length_q` saturates at 32 so an over-long line can be
  // rejected instead of overwriting the start of the command.
  // --------------------------------------------------------------------------
  logic [255:0] command_q;
  logic [  5:0] length_q;
  logic         long_q;
  logic         deferred_error_q;

  logic [511:0] text_q;
  logic [  6:0] text_left_q;

  /// Decoded command: 4-bit kind in [35:32] and a bounded decimal argument.
  logic [35:0] parsed;

  // Sticky console diagnostics, reported by `status` and `port`.
  logic [31:0] parity_errors_q;
  logic [31:0] frame_errors_q;
  logic [31:0] overflow_errors_q;
  logic [31:0] busy_errors_q;
  logic [31:0] long_errors_q;

  // --------------------------------------------------------------------------
  // Command engine handshakes
  //
  // Each command owns the shared text buffer until its last line is accepted.
  // The status and port policies share one snapshot formatter and differ only
  // in the page range they ask for.
  // --------------------------------------------------------------------------
  logic        status_start;
  logic        status_busy;
  logic        status_done;
  logic        port_start;
  logic        port_busy;
  logic        port_done;
  logic        snapshot_busy;
  logic        snapshot_done;
  logic        snapshot_valid;
  logic [31:0] status_first;
  logic [31:0] status_last;
  logic [31:0] port_first;
  logic [31:0] port_last;
  logic [511:0] snapshot_text;

  logic         mac_start;
  logic         mac_busy;
  logic         mac_done;
  logic         mac_valid;
  logic [511:0] mac_text;

  logic         help_valid;
  logic         help_done;
  logic [511:0] help_text;

  logic text_empty;
  logic parse_ready;

  // `text_q[511:504]` is the octet being sent; a zero octet is the terminator
  // that the UART is never asked to transmit.
  assign text_empty  = (text_left_q == 7'd0);
  assign parse_ready = (state_q == S_PARSE) && text_empty && !long_q;

  // --------------------------------------------------------------------------
  // Command parsing
  //
  // The parser returns a command kind and a bounded decimal port index.  The
  // selected command then owns the response generator until its final line.
  // --------------------------------------------------------------------------
  function automatic logic [35:0] parse(input var logic [255:0] cmd,
                                        input var logic [5:0] len);
    logic [3:0]  kind;
    logic [31:0] number;
    logic [7:0]  ch;
    int unsigned first;
    logic        bad;
    kind   = 4'd5;  // 5 is the "unrecognised" kind
    first  = 32;    // no argument bytes unless a command sets a start offset
    number = '0;
    bad    = 1'b0;
    ch     = '0;
    // The comparisons are against the ASCII bytes of each command, most
    // significant octet first, which is how the receive path packs them.
    if ((len == 6'd4) && (cmd[31:0] == 32'h706c6568)) kind = 4'd0;  // "help"
    if ((len == 6'd6) && (cmd[47:0] == 48'h737574617473)) kind = 4'd1;  // "status"
    if ((len > 6'd5) && (cmd[39:0] == 40'h2074726f70)) begin
      kind  = 4'd2;  // "port <n>"
      first = 5;
    end
    if ((len == 6'd7) && (cmd[55:0] == 56'h6c6c612063616d)) kind = 4'd3;  // "mac all"
    else if ((len > 6'd4) && (cmd[31:0] == 32'h2063616d)) begin
      kind  = 4'd4;  // "mac <n>"
      first = 4;
    end
    for (int unsigned b = 0; b < 32; b++) begin
      if ((b >= first) && (b < 32'(len))) begin
        ch = cmd[b*8 +: 8];
        if ((ch < "0") || (ch > "9") || (number > 32'(NUM_PORTS))) bad = 1'b1;
        // Decimal port IDs are bounded before every multiply, so malformed
        // input cannot wrap around and select an unintended valid port.
        if (!bad) number = (number * 32'd10) + {24'd0, ch} - 32'd48;
      end
    end
    // A port argument that names a nonexistent port is a parse error, not a
    // clamp: silently listing port 0 for "port 9" would be worse than failing.
    if (bad || (((kind == 4'd2) || (kind == 4'd4)) && (number >= 32'(NUM_PORTS)))) begin
      kind = 4'd5;
    end
    parse = {kind, number};
  endfunction

  assign parsed = parse(command_q, length_q);

  // --------------------------------------------------------------------------
  // Command engines
  // --------------------------------------------------------------------------
  es_console_cmd_status #(
    .NUM_PORTS (NUM_PORTS)
  ) u_cmd_status (
    .start_i       (parse_ready && (parsed[35:32] == 4'd1)),
    .selected_i    (state_q == S_STATUS),
    .engine_busy_i (snapshot_busy),
    .engine_done_i (snapshot_done),
    .start_o       (status_start),
    .busy_o        (status_busy),
    .done_o        (status_done),
    .first_page_o  (status_first),
    .last_page_o   (status_last)
  );

  es_console_cmd_port u_cmd_port (
    .start_i       (parse_ready && (parsed[35:32] == 4'd2)),
    .selected_i    (state_q == S_PORT),
    .engine_busy_i (snapshot_busy),
    .engine_done_i (snapshot_done),
    .port_i        (parsed[31:0]),
    .start_o       (port_start),
    .busy_o        (port_busy),
    .done_o        (port_done),
    .first_page_o  (port_first),
    .last_page_o   (port_last)
  );

  es_console_snapshot #(
    .NUM_PORTS (NUM_PORTS)
  ) u_snapshot (
    .clk_i             (clk_i),
    .rst_ni            (rst_ni),
    .start_i           (status_start || port_start),
    .first_page_i      (port_start ? port_first : status_first),
    .last_page_i       (port_start ? port_last : status_last),
    .image_i           (image_i),
    .parity_errors_i   (parity_errors_q),
    .frame_errors_i    (frame_errors_q),
    .overflow_errors_i (overflow_errors_q),
    .busy_errors_i     (busy_errors_q),
    .long_errors_i     (long_errors_q),
    .ready_i           (text_empty),
    .valid_o           (snapshot_valid),
    .busy_o            (snapshot_busy),
    .done_o            (snapshot_done),
    .text_o            (snapshot_text)
  );

  // A MAC listing is only meaningful once a sample has been published, so the
  // command is not even started while `sample_valid` is clear.
  assign mac_start = parse_ready &&
                     ((parsed[35:32] == 4'd3) || (parsed[35:32] == 4'd4)) &&
                     image_i[SW_MON_VALID_WORD*32];

  es_console_cmd_mac u_cmd_mac (
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .start_i      (mac_start),
    .filter_i     ((parsed[35:32] == 4'd3) ? 32'hFFFF_FFFF : parsed[31:0]),
    .count_i      (image_i[SW_MON_CAM_CAPACITY_WORD*32 +: 32]),
    .cache_idle_i (cache_idle_i),
    .bus_claim_o  (bus_claim_o),
    .req_o        (req_o),
    .addr_o       (addr_o),
    .csr_ready_i  (ready_i),
    .csr_valid_i  (valid_i),
    .csr_data_i   (data_i),
    .text_ready_i (text_empty),
    .text_valid_o (mac_valid),
    .busy_o       (mac_busy),
    .done_o       (mac_done),
    .text_o       (mac_text)
  );

  es_console_cmd_help u_cmd_help (
    .start_i ((state_q == S_PARSE) && !long_q && (parsed[35:32] == 4'd0)),
    .ready_i (text_empty),
    .valid_o (help_valid),
    .done_o  (help_done),
    .text_o  (help_text)
  );

  // --------------------------------------------------------------------------
  // Console UART
  //
  // The transmit side is fed straight from the head of `text_q`; a zero octet
  // marks the end of the response and is never transmitted.
  // --------------------------------------------------------------------------
  es_perips_uart #(
    .CLK_FREQ_HZ  (CLK_FREQ_HZ),
    .BAUD_RATE    (UART_BAUD_RATE),
    .DATA_BITS    (UART_DATA_BITS),
    .PARITY       (UART_PARITY),
    .STOP_BITS    (UART_STOP_BITS),
    .FLOW_CONTROL (UART_FLOW_CONTROL)
  ) u_uart (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .rx_i           (rx_i),
    .cts_ni         (cts_ni),
    .tx_o           (tx_o),
    .rts_no         (unused_rts),
    .tx_valid_i     (!text_empty && (text_q[511:504] != 8'd0)),
    .tx_data_i      (text_q[511:504]),
    .tx_ready_o     (tx_ready),
    .rx_valid_o     (rx_valid),
    .rx_data_o      (rx_data),
    .rx_ready_i     (1'b1),
    .parity_error_o (parity_error),
    .frame_error_o  (frame_error),
    .overflow_o     (overflow)
  );

  // RTS asserts whenever the console is not listening, which is the whole time
  // a response is being streamed: the host must stop before the input buffer,
  // not after it.
  assign rts_no = (UART_FLOW_CONTROL == SW_UART_FLOW_NONE) ? 1'b0 : (state_q != S_RX);

  // --------------------------------------------------------------------------
  // Dispatcher
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q          <= S_RX;
      command_q        <= '0;
      length_q         <= '0;
      long_q           <= 1'b0;
      deferred_error_q <= 1'b0;
      fault_o          <= 1'b0;
      parity_errors_q  <= '0;
      frame_errors_q   <= '0;
      overflow_errors_q <= '0;
      busy_errors_q    <= '0;
      long_errors_q    <= '0;
      text_q           <= '0;
      text_left_q      <= '0;
    end else begin
      // One octet leaves the buffer per accepted UART character.  A zero octet
      // is the terminator and costs a clock without being transmitted.
      if (!text_empty && ((text_q[511:504] == 8'd0) || tx_ready)) begin
        text_q      <= {text_q[503:0], 8'd0};
        text_left_q <= text_left_q - 7'd1;
      end
      if (parity_error) parity_errors_q <= parity_errors_q + 32'd1;
      if (frame_error)  frame_errors_q  <= frame_errors_q + 32'd1;
      if (overflow)     overflow_errors_q <= overflow_errors_q + 32'd1;
      // Input that arrives while a response is streaming is rejected, not
      // buffered: line endings are exempt so the host can still terminate.
      if (rx_valid && (state_q != S_RX) && (rx_data != 8'd10) && (rx_data != 8'd13)) begin
        busy_errors_q <= busy_errors_q + 32'd1;
      end
      if (parity_error || frame_error || overflow ||
          (rx_valid && (state_q != S_RX) && (rx_data != 8'd10) && (rx_data != 8'd13))) begin
        fault_o          <= 1'b1;
        deferred_error_q <= 1'b1;
      end
      case (state_q)
        S_RX: begin
          // The error line is only queued once the buffer is free, so it cannot
          // overwrite a response that is still being transmitted.
          if (deferred_error_q && text_empty) begin
            text_q           <= {"ERR busy_or_uart_frame_or_overflow\015\n", 224'd0};
            text_left_q      <= 7'd64;
            deferred_error_q <= 1'b0;
          end
          if (rx_valid) begin
            if ((rx_data == 8'd13) || (rx_data == 8'd10)) begin
              if ((length_q != 6'd0) || long_q) state_q <= S_PARSE;
            end else if ((rx_data == 8'd8) || (rx_data == 8'd127)) begin
              // Backspace and delete both drop the last character.
              if (length_q != 6'd0) begin
                length_q <= length_q - 6'd1;
                command_q[(32'(length_q)-32'd1)*32'd8 +: 8] <= '0;
              end
            end else if (length_q < 6'd32) begin
              command_q[32'(length_q)*32'd8 +: 8] <= rx_data;
              length_q <= length_q + 6'd1;
            end else begin
              // 33rd character: mark the line over-long and count it once.
              long_q  <= 1'b1;
              fault_o <= 1'b1;
              if (!long_q) long_errors_q <= long_errors_q + 32'd1;
            end
          end
        end
        S_PARSE: if (text_empty) begin
          state_q <= S_END;
          if (long_q || (parsed[35:32] == 4'd5)) begin
            text_q      <= {"ERR command_or_port_or_length\015\n", 264'd0};
            text_left_q <= 7'd64;
          end else begin
            case (parsed[35:32])
              4'd0: if (help_valid && help_done) begin
                text_q      <= help_text;
                text_left_q <= 7'd64;
              end
              4'd1: state_q <= S_STATUS;
              4'd2: state_q <= S_PORT;
              4'd3, 4'd4: begin
                if (!image_i[SW_MON_VALID_WORD*32]) begin
                  text_q      <= {"ERR sample_not_ready", 16'h0d0a, 336'd0};
                  text_left_q <= 7'd64;
                end else state_q <= S_MAC;
              end
              default: state_q <= S_END;
            endcase
          end
          command_q <= '0;
          length_q  <= '0;
          long_q    <= 1'b0;
        end
        S_STATUS, S_PORT: begin
          if ((status_busy || port_busy) && snapshot_valid && text_empty) begin
            text_q      <= snapshot_text;
            text_left_q <= 7'd64;
          end
          if (status_done || port_done) state_q <= S_END;
        end
        S_MAC: begin
          if (mac_busy && mac_valid && text_empty) begin
            text_q      <= mac_text;
            text_left_q <= 7'd64;
          end
          if (mac_done) state_q <= S_END;
        end
        S_END: if (text_empty) state_q <= S_RX;
        default: state_q <= S_RX;
      endcase
    end
  end

endmodule : es_console_core

`default_nettype wire

`endif  // ES_CONSOLE_CORE_SV
