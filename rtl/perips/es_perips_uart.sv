// ============================================================================
//  File        : es_perips_uart.sv
//  Description : Parameterised UART transmitter and receiver.
//
//                All state advances on clk_i; rst_ni is synchronous active low.
//                Asynchronous RX and active-low CTS pass through two sampling
//                stages before any frame control uses them.  Handshakes bound
//                the buffering, and parity, framing and overflow are reported
//                as separate event pulses.
//
//                CLK_FREQ_HZ and BAUD_RATE are in hertz and bits/s.  DATA_BITS,
//                PARITY and STOP_BITS select the framing, FLOW_CONTROL selects
//                whether CTS gates transmission.  The transmitter accepts a
//                character with tx_valid_i / tx_ready_o; a received character
//                raises rx_valid_o only when rx_ready_i is high, and is
//                otherwise discarded with an overflow pulse.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_PERIPS_UART_SV
`define ES_PERIPS_UART_SV

`default_nettype none

`include "es_defs.sv"
`include "console/es_console_defs.sv"
`default_nettype none

module es_perips_uart #(
  /// Core clock frequency in hertz; timing counters use this value.
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  /// UART bit rate in bits per second.
  parameter int unsigned BAUD_RATE = 115200,
  /// Number of data bits per UART character, from five through eight.
  parameter int unsigned DATA_BITS = 8,
  /// UART parity encoding from es_perips_defs.sv.
  parameter int unsigned PARITY = SW_UART_PARITY_NONE,
  /// Number of UART stop bits, one or two.
  parameter int unsigned STOP_BITS = 1,
  /// CTS/RTS policy from es_perips_defs.sv.
  parameter int unsigned FLOW_CONTROL = SW_UART_FLOW_NONE
) (
  /// Clock/reset and asynchronous UART RX plus active-low CTS inputs.
  input var logic clk_i, rst_ni, rx_i, cts_ni,
  /// UART TX pin and active-low RTS back-pressure output.
  output    logic tx_o, rts_no,
  /// Transmit ready/valid interface; characters are sent least-significant bit first.
  input var logic       tx_valid_i,
  input var logic [7:0] tx_data_i,
  output    logic       tx_ready_o,
  /// Receive ready/valid interface; a character is dropped when rx_ready_i is low.
  output    logic       rx_valid_o,
  output    logic [7:0] rx_data_o,
  input var logic       rx_ready_i,
  /// Parity, framing, and receive-overflow event pulses.
  output    logic parity_error_o, frame_error_o, overflow_o
);

  // --------------------------------------------------------------------------
  // Timing
  //
  // PERIOD is the number of clk_i cycles in one bit time, rounded to nearest.
  // BAUD_ERROR compares the resulting line rate with the requested one so that
  // a clock/rate pair which cannot be generated within 2 % is rejected at
  // elaboration time instead of producing a link that silently corrupts data.
  // --------------------------------------------------------------------------
  localparam int unsigned PERIOD = (BAUD_RATE == 0) ? 1 : (CLK_FREQ_HZ + BAUD_RATE / 2) / BAUD_RATE;
  localparam logic [63:0] ACTUAL_PRODUCT = 64'(PERIOD) * 64'(BAUD_RATE);
  localparam logic [63:0] BAUD_ERROR = (ACTUAL_PRODUCT >= 64'(CLK_FREQ_HZ)) ?
      (ACTUAL_PRODUCT - 64'(CLK_FREQ_HZ)) : (64'(CLK_FREQ_HZ) - ACTUAL_PRODUCT);
  localparam int unsigned FRAME_BITS = 1 + DATA_BITS + STOP_BITS +
      ((PARITY == SW_UART_PARITY_NONE) ? 0 : 1);

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
    if ((DATA_BITS < 5) || (DATA_BITS > 8) ||
        (STOP_BITS < 1) || (STOP_BITS > 2) ||
        (PARITY > SW_UART_PARITY_EVEN) ||
        (FLOW_CONTROL > SW_UART_FLOW_RTS_CTS) ||
        (BAUD_RATE == 0) || (PERIOD < 4) ||
        ((BAUD_ERROR * 64'd100) > (ACTUAL_PRODUCT * 64'd2))) begin : g_invalid
      SW_UART_INVALID_PARAMETERS invalid_parameters ();
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Asynchronous input sampling
  //
  // RX and active-low CTS pass through two sampling stages before frame
  // control uses them.  CTS gates acceptance of a new character; it must not
  // truncate a character already in flight.
  // --------------------------------------------------------------------------
  logic rx_sync_q;
  logic cts_sync_q;

  es_common_sync_2ff #(
    .WIDTH (2)
  ) u_sync (
    .clk_i   (clk_i),
    .rst_ni  (rst_ni),
    .async_i ({rx_i, cts_ni}),
    .sync_o  ({rx_sync_q, cts_sync_q})
  );

  // --------------------------------------------------------------------------
  // Transmit frame construction
  //
  // The shift register is preloaded with the whole frame: start bit low, data
  // bits least-significant first, then parity, and the unused high bits stay
  // at the idle level so that the stop bits need no special case.
  // --------------------------------------------------------------------------
  function automatic logic [11:0] frame(input var logic [7:0] data);
    logic [11:0] result;
    logic        parity;
    result    = '1;
    result[0] = 1'b0;
    parity    = 1'b0;
    for (int unsigned b = 0; b < DATA_BITS; b++) begin
      result[b+1] = data[b];
      parity      = parity ^ data[b];
    end
    // Odd parity inverts the even-parity result; no parity leaves the slot idle.
    if (PARITY != SW_UART_PARITY_NONE) begin
      result[1+DATA_BITS] = parity ^ (PARITY == SW_UART_PARITY_ODD);
    end
    frame = result;
  endfunction

  logic [11:0] tx_shift_q;
  logic [ 3:0] tx_left_q;
  logic [31:0] tx_timer_q;

  assign tx_ready_o = (tx_left_q == 4'd0) &&
                      ((FLOW_CONTROL == SW_UART_FLOW_NONE) || !cts_sync_q);
  assign tx_o       = (tx_left_q == 4'd0) ? 1'b1 : tx_shift_q[0];
  assign rts_no     = (FLOW_CONTROL == SW_UART_FLOW_NONE) ? 1'b0 : !rx_ready_i;

  // --------------------------------------------------------------------------
  // Transmit sequencer
  // --------------------------------------------------------------------------
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      tx_shift_q <= '1;
      tx_left_q  <= '0;
      tx_timer_q <= '0;
    end else if (tx_left_q == 4'd0) begin
      if (tx_valid_i && tx_ready_o) begin
        tx_shift_q <= frame(tx_data_i);
        tx_left_q  <= 4'(FRAME_BITS);
        // The frame was shifted in at the start of this bit; the next edge is
        // one full period away.
        tx_timer_q <= 32'(PERIOD - 1);
      end
    end else if (tx_timer_q == 32'd0) begin
      tx_shift_q <= {1'b1, tx_shift_q[11:1]};
      tx_left_q  <= tx_left_q - 4'd1;
      tx_timer_q <= 32'(PERIOD - 1);
    end else tx_timer_q <= tx_timer_q - 32'd1;
  end

  // --------------------------------------------------------------------------
  // Receiver state
  //
  // Validate the start bit at its centre, then sample each data, parity and
  // stop bit one period apart.  A bad frame is discarded instead of being
  // delivered, so a consumer never has to re-check the FCS of a frame the UART
  // already rejected.
  // --------------------------------------------------------------------------
  typedef enum logic [2:0] {
    S_IDLE,
    S_START,
    S_DATA,
    S_PARITY,
    S_STOP
  } state_e;

  state_e state_q;

  logic [31:0] rx_timer_q;
  logic [ 3:0] rx_bit_q;
  logic [ 7:0] rx_shift_q;
  logic        rx_parity_q;  ///< running parity of the data bits received so far
  logic        rx_bad_q;     ///< set by a parity or framing error in this frame
  logic        stop_q;       ///< first stop bit already sampled

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q        <= S_IDLE;
      rx_timer_q     <= '0;
      rx_bit_q       <= '0;
      rx_shift_q     <= '0;
      rx_parity_q    <= 1'b0;
      rx_bad_q       <= 1'b0;
      stop_q         <= 1'b0;
      rx_valid_o     <= 1'b0;
      rx_data_o      <= '0;
      parity_error_o <= 1'b0;
      frame_error_o  <= 1'b0;
      overflow_o     <= 1'b0;
    end else begin
      // All three event outputs are one-clock pulses.
      rx_valid_o     <= 1'b0;
      parity_error_o <= 1'b0;
      frame_error_o  <= 1'b0;
      overflow_o     <= 1'b0;
      if (state_q == S_IDLE) begin
        if (!rx_sync_q) begin
          state_q    <= S_START;
          // Half a bit time puts the first sample in the centre of the start bit.
          rx_timer_q <= 32'(PERIOD / 2 - 1);
        end
      end else if (rx_timer_q != 32'd0) rx_timer_q <= rx_timer_q - 32'd1;
      else begin
        rx_timer_q <= 32'(PERIOD - 1);
        case (state_q)
          S_START: begin
            // A start bit that is already gone was a glitch, not a frame.
            if (!rx_sync_q) begin
              state_q     <= S_DATA;
              rx_bit_q    <= '0;
              rx_shift_q  <= '0;
              rx_parity_q <= 1'b0;
              rx_bad_q    <= 1'b0;
            end else state_q <= S_IDLE;
          end
          S_DATA: begin
            rx_shift_q[rx_bit_q[2:0]] <= rx_sync_q;
            rx_parity_q <= rx_parity_q ^ rx_sync_q;
            if (rx_bit_q == 4'(DATA_BITS - 1)) begin
              state_q <= (PARITY == SW_UART_PARITY_NONE) ? S_STOP : S_PARITY;
              stop_q  <= 1'b0;
            end else rx_bit_q <= rx_bit_q + 4'd1;
          end
          S_PARITY: begin
            if (rx_sync_q != (rx_parity_q ^ (PARITY == SW_UART_PARITY_ODD))) begin
              rx_bad_q       <= 1'b1;
              parity_error_o <= 1'b1;
            end
            stop_q  <= 1'b0;
            state_q <= S_STOP;
          end
          S_STOP: begin
            if (!rx_sync_q) begin
              rx_bad_q      <= 1'b1;
              frame_error_o <= 1'b1;
            end
            // With two stop bits the first is sampled here and the second on
            // the next visit; both must be high for the frame to be accepted.
            if ((STOP_BITS == 1) || stop_q) begin
              if (!rx_bad_q && rx_sync_q) begin
                rx_data_o <= rx_shift_q;
                if (rx_ready_i) rx_valid_o <= 1'b1;
                else overflow_o <= 1'b1;
              end
              state_q <= S_IDLE;
            end else stop_q <= 1'b1;
          end
          default: state_q <= S_IDLE;
        endcase
      end
    end
  end

endmodule : es_perips_uart

`default_nettype wire

`endif  // ES_PERIPS_UART_SV
