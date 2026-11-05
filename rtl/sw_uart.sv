// Parameterised UART. Active-low RTS/CTS are permissions to receive/transmit.
// CTS is sampled only between characters; a stopped peer cannot truncate a frame.
`timescale 1ns/1ps
`ifndef SW_UART_SV
`define SW_UART_SV
`default_nettype none
`include "sw_defs.sv"
module sw_uart #(
  parameter int unsigned CLK_FREQ_HZ = 50_000_000,
  parameter int unsigned BAUD_RATE = 115200,
  parameter int unsigned DATA_BITS = 8,
  parameter int unsigned PARITY = SW_UART_PARITY_NONE,
  parameter int unsigned STOP_BITS = 1,
  parameter int unsigned FLOW_CONTROL = SW_UART_FLOW_NONE
) (
  input logic clk_i, rst_ni, rx_i, cts_ni,
  output logic tx_o, rts_no,
  input logic tx_valid_i,
  input logic [7:0] tx_data_i,
  output logic tx_ready_o,
  output logic rx_valid_o,
  output logic [7:0] rx_data_o,
  input logic rx_ready_i,
  output logic parity_error_o, frame_error_o, overflow_o
);
  localparam int unsigned PERIOD = (BAUD_RATE == 0) ? 1 : (CLK_FREQ_HZ + BAUD_RATE/2)/BAUD_RATE;
  localparam logic [63:0] ACTUAL_PRODUCT = 64'(PERIOD)*64'(BAUD_RATE);
  localparam logic [63:0] BAUD_ERROR = (ACTUAL_PRODUCT >= 64'(CLK_FREQ_HZ)) ? ACTUAL_PRODUCT-64'(CLK_FREQ_HZ) : 64'(CLK_FREQ_HZ)-ACTUAL_PRODUCT;
  localparam int unsigned FRAME_BITS = 1+DATA_BITS+STOP_BITS+(PARITY == SW_UART_PARITY_NONE ? 0 : 1);
  generate
    if ((DATA_BITS < 5) || (DATA_BITS > 8) || (STOP_BITS < 1) || (STOP_BITS > 2) ||
        (PARITY > SW_UART_PARITY_EVEN) || (FLOW_CONTROL > SW_UART_FLOW_RTS_CTS) ||
        (BAUD_RATE == 0) || (PERIOD < 4) || (BAUD_ERROR*64'd100 > ACTUAL_PRODUCT*64'd2)) begin : g_invalid
      SW_UART_INVALID_PARAMETERS invalid_parameters();
    end
  endgenerate
  logic rx_meta_q, rx_sync_q, cts_meta_q, cts_sync_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      rx_meta_q <= 1'b1; rx_sync_q <= 1'b1;
      cts_meta_q <= 1'b1; cts_sync_q <= 1'b1;
    end else begin
      rx_meta_q <= rx_i; rx_sync_q <= rx_meta_q;
      cts_meta_q <= cts_ni; cts_sync_q <= cts_meta_q;
    end
  end
  function automatic logic [11:0] frame(input logic [7:0] data);
    logic [11:0] result;
    logic parity;
    result = '1; result[0] = 1'b0; parity = 1'b0;
    for (int unsigned b = 0; b < DATA_BITS; b++) begin
      result[b+1] = data[b]; parity = parity ^ data[b];
    end
    if (PARITY != SW_UART_PARITY_NONE) result[1+DATA_BITS] = parity ^ (PARITY == SW_UART_PARITY_ODD);
    frame = result;
  endfunction
  logic [11:0] tx_shift_q;
  logic [3:0] tx_left_q;
  logic [31:0] tx_timer_q;
  assign tx_ready_o = (tx_left_q == 4'd0) && ((FLOW_CONTROL == SW_UART_FLOW_NONE) || !cts_sync_q);
  assign tx_o = (tx_left_q == 4'd0) ? 1'b1 : tx_shift_q[0];
  assign rts_no = (FLOW_CONTROL == SW_UART_FLOW_NONE) ? 1'b0 : !rx_ready_i;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin tx_shift_q <= '1; tx_left_q <= '0; tx_timer_q <= '0; end
    else if (tx_left_q == 4'd0) begin
      if (tx_valid_i && tx_ready_o) begin
        tx_shift_q <= frame(tx_data_i); tx_left_q <= 4'(FRAME_BITS); tx_timer_q <= 32'(PERIOD-1);
      end
    end else if (tx_timer_q == 32'd0) begin
      tx_shift_q <= {1'b1, tx_shift_q[11:1]}; tx_left_q <= tx_left_q - 4'd1;
      tx_timer_q <= 32'(PERIOD-1);
    end else tx_timer_q <= tx_timer_q - 32'd1;
  end
  typedef enum logic [2:0] {S_IDLE, S_START, S_DATA, S_PARITY, S_STOP} state_e;
  state_e state_q;
  logic [31:0] rx_timer_q;
  logic [3:0] rx_bit_q;
  logic [7:0] rx_shift_q;
  logic rx_parity_q, rx_bad_q, stop_q;
  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      state_q <= S_IDLE; rx_timer_q <= '0; rx_bit_q <= '0; rx_shift_q <= '0;
      rx_parity_q <= 1'b0; rx_bad_q <= 1'b0; stop_q <= 1'b0;
      rx_valid_o <= 1'b0; rx_data_o <= '0;
      parity_error_o <= 1'b0; frame_error_o <= 1'b0; overflow_o <= 1'b0;
    end else begin
      rx_valid_o <= 1'b0; parity_error_o <= 1'b0; frame_error_o <= 1'b0; overflow_o <= 1'b0;
      if (state_q == S_IDLE) begin
        if (!rx_sync_q) begin state_q <= S_START; rx_timer_q <= 32'(PERIOD/2-1); end
      end else if (rx_timer_q != 32'd0) rx_timer_q <= rx_timer_q - 32'd1;
      else begin
        rx_timer_q <= 32'(PERIOD-1);
        case (state_q)
          S_START: begin
            if (!rx_sync_q) begin
              state_q <= S_DATA; rx_bit_q <= '0; rx_shift_q <= '0;
              rx_parity_q <= 1'b0; rx_bad_q <= 1'b0;
            end else state_q <= S_IDLE;
          end
          S_DATA: begin
            rx_shift_q[rx_bit_q[2:0]] <= rx_sync_q;
            rx_parity_q <= rx_parity_q ^ rx_sync_q;
            if (rx_bit_q == 4'(DATA_BITS-1)) begin
              state_q <= (PARITY == SW_UART_PARITY_NONE) ? S_STOP : S_PARITY;
              stop_q <= 1'b0;
            end else rx_bit_q <= rx_bit_q + 4'd1;
          end
          S_PARITY: begin
            if (rx_sync_q != (rx_parity_q ^ (PARITY == SW_UART_PARITY_ODD))) begin
              rx_bad_q <= 1'b1; parity_error_o <= 1'b1;
            end
            stop_q <= 1'b0; state_q <= S_STOP;
          end
          S_STOP: begin
            if (!rx_sync_q) begin rx_bad_q <= 1'b1; frame_error_o <= 1'b1; end
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
endmodule
`default_nettype wire
`endif
