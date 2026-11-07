// ============================================================================
//  File        : es_perips_defs.sv
//  Description : Shared UART encodings and active-low seven-segment glyphs.
//                Included at compilation-unit scope through es_defs.sv.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_PERIPS_DEFS_SV
`define ES_PERIPS_DEFS_SV
`default_nettype none
// Framing parameters are shared by the UART, console and board shells.
localparam int unsigned SW_UART_PARITY_NONE = 0;
localparam int unsigned SW_UART_PARITY_ODD = 1;
localparam int unsigned SW_UART_PARITY_EVEN = 2;
localparam int unsigned SW_UART_FLOW_NONE = 0;
localparam int unsigned SW_UART_FLOW_RTS_CTS = 1;

// The segment pattern is active low; non-decimal inputs display a dash.
function automatic logic [6:0] sw_sevenseg_digit(input var logic [3:0] d);
  case (d)
    4'd0: sw_sevenseg_digit = 7'b1000000;
    4'd1: sw_sevenseg_digit = 7'b1111001;
    4'd2: sw_sevenseg_digit = 7'b0100100;
    4'd3: sw_sevenseg_digit = 7'b0110000;
    4'd4: sw_sevenseg_digit = 7'b0011001;
    4'd5: sw_sevenseg_digit = 7'b0010010;
    4'd6: sw_sevenseg_digit = 7'b0000010;
    4'd7: sw_sevenseg_digit = 7'b1111000;
    4'd8: sw_sevenseg_digit = 7'b0000000;
    4'd9: sw_sevenseg_digit = 7'b0010000;
    default: sw_sevenseg_digit = 7'b0111111;
  endcase
endfunction

`default_nettype wire
`endif
