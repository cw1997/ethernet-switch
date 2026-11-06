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
// --------------------------------------------------------------------------
// UART framing encodings
//
// Parity and flow-control values are shared by the UART, console and board
// parameters.
// --------------------------------------------------------------------------
// UART framing encodings are owned by perips/es_perips_defs.sv.
`default_nettype wire
`endif  // ES_CONSOLE_DEFS_SV
