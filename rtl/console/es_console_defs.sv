// ============================================================================
//  File        : es_console_defs.sv
//  Description : Reserved compilation-unit declarations for the console.
//
//                Compilation-unit declarations keep port ranges readable by
//                yosys read_verilog -sv.  Include guards prevent redefinition;
//                packages, imports and function returns are intentionally
//                absent.
//
//                The console owns no shared constants of its own: its line
//                width, buffer geometry and command encoding are private to
//                es_console_core and its command modules.  This file exists so
//                that the umbrella header's include list stays complete, and so
//                that a future cross-module constant has an owner rather than
//                being pushed into es_defs.sv.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_CONSOLE_DEFS_SV
`define ES_CONSOLE_DEFS_SV

`default_nettype none

// UART framing and flow-control encodings used by the console port are shared
// with the UART itself and are declared by perips/es_perips_defs.sv.

`default_nettype wire

`endif  // ES_CONSOLE_DEFS_SV
