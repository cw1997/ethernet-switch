// ============================================================================
//  File        : es_monitor_defs.sv
//  Description : Monitor constants and compilation-unit helpers.
//
//                Compilation-unit declarations keep port ranges readable by
//                yosys read_verilog -sv. Include guards prevent redefinition;
//                packages, imports and function returns are intentionally absent.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_MONITOR_DEFS_SV
`define ES_MONITOR_DEFS_SV
`default_nettype none
// Included by es_defs.sv after common declarations.
localparam int unsigned SW_MON_ABI_VERSION = 1;
localparam int unsigned SW_MON_STATUS_WORD = 0;
localparam int unsigned SW_MON_RX_USED_WORD = 1;
localparam int unsigned SW_MON_TX_USED_WORD = 2;
localparam int unsigned SW_MON_RX_PEAK_WORD = 3;
localparam int unsigned SW_MON_TX_PEAK_WORD = 4;
localparam int unsigned SW_MON_RX_LOAD_WORD = 5;
localparam int unsigned SW_MON_TX_LOAD_WORD = 6;
localparam int unsigned SW_MON_UPTIME_WORD = 44;
localparam int unsigned SW_MON_WINDOW_WORD = 46;
localparam int unsigned SW_MON_REFRESH_WORD = 48;
localparam int unsigned SW_MON_SEQUENCE_WORD = 49;
localparam int unsigned SW_MON_VALID_WORD = 50;
localparam int unsigned SW_MON_CAM_ENTRIES_WORD = 51;
localparam int unsigned SW_MON_CAM_CAPACITY_WORD = 52;
localparam int unsigned SW_MON_FLUSH_WORD = 53;
localparam int unsigned SW_MON_BUSY_WORD = 54;
localparam int unsigned SW_MON_AGE_WORD = 55;
localparam int unsigned SW_MON_TIME_WORD = 56;
localparam int unsigned SW_MON_VERSION_WORD = 58;
localparam logic [31:0] SW_MON_LIVE_CLOCK = 32'hf0;
localparam logic [31:0] SW_MON_LIVE_FLUSH = 32'hf8;
// Read-only monitoring ABI, version 1. Byte addresses; little-word-first 64-bit values.
localparam logic [31:0] SW_MON_PORT_BASE = 32'h1000_0000;
localparam logic [31:0] SW_MON_MAC_BASE  = 32'h2000_0000;
localparam int unsigned SW_MON_WORDS = 64;
localparam int unsigned SW_MON_BITS = 32*SW_MON_WORDS;
localparam int unsigned SW_MON_COUNTER = 8; // 14 counter pairs, same IDs as stat_o
localparam int unsigned SW_MON_RATE = 36;   // RX pps, TX pps, RX bit/s, TX bit/s pairs

`default_nettype wire
`endif // ES_MONITOR_DEFS_SV
