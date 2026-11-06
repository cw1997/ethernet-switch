// ============================================================================
//  File        : es_console_defs.sv
//  Description : Console constants and compilation-unit helpers.
//
//                Compilation-unit declarations keep port ranges readable by
//                yosys read_verilog -sv. Include guards prevent redefinition;
//                packages, imports and function returns are intentionally absent.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_CONSOLE_DEFS_SV
`define ES_CONSOLE_DEFS_SV
`default_nettype none
// Included by es_defs.sv after common declarations.
localparam int unsigned SW_UART_PARITY_NONE = 0;
localparam int unsigned SW_UART_PARITY_ODD = 1;
localparam int unsigned SW_UART_PARITY_EVEN = 2;
localparam int unsigned SW_UART_FLOW_NONE = 0;
localparam int unsigned SW_UART_FLOW_RTS_CTS = 1;


`default_nettype wire
`endif // ES_CONSOLE_DEFS_SV
