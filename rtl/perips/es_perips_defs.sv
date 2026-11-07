// ============================================================================
//  File        : es_perips_defs.sv
//  Description : Shared UART encodings and active-low seven-segment glyphs.
//                Included at compilation-unit scope through es_defs.sv.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_PERIPS_DEFS_SV
`define ES_PERIPS_DEFS_SV

`default_nettype none

// ============================================================================
// 1.  UART framing and flow-control encodings
// ============================================================================
// Framing parameters are shared by the UART, the console and the board shells,
// so the numeric encodings live here rather than in any one port list.
localparam int unsigned SW_UART_PARITY_NONE  = 0;
localparam int unsigned SW_UART_PARITY_ODD   = 1;
localparam int unsigned SW_UART_PARITY_EVEN  = 2;
localparam int unsigned SW_UART_FLOW_NONE    = 0;
localparam int unsigned SW_UART_FLOW_RTS_CTS = 1;

// ============================================================================
// 2.  Seven-segment glyph table
// ============================================================================
// The segment pattern is active low; non-decimal inputs display a dash.

`default_nettype wire

`endif  // ES_PERIPS_DEFS_SV
