// ============================================================================
//  File        : es_monitor_defs.sv
//  Description : Monitor constants and compilation-unit helpers.
//
//                Compilation-unit declarations keep port ranges readable by
//                yosys read_verilog -sv.  Include guards prevent redefinition;
//                packages, imports and function returns are intentionally
//                absent.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MONITOR_DEFS_SV
`define ES_MONITOR_DEFS_SV

`default_nettype none

// ============================================================================
// 1.  Snapshot word layout
// ============================================================================
// Offsets are 32-bit word indices unless declared as byte-address constants;
// 64-bit fields store the low word first and therefore occupy two consecutive
// words, which is what leaves the odd gaps in the numbering below.
//
// A snapshot image is `SW_MON_WORDS` words wide.  Words 0..43 are
// *record-shaped*: the aggregate image and every per-port record use the same
// layout there, so the same reader code decodes either.  Words 44..63 exist
// only in the aggregate image and are never read from a port record.
//
//   aggregate 0..6    status, used/peak/load summaries
//   record    8..35   the 14 counter pairs, indexed by `sw_stat_id_e`
//   record   36..43   the four rate pairs (RX pps, TX pps, RX bit/s, TX bit/s)
//   aggregate 44..63  uptime, window, refresh, sequence, CAM state, time, version
// ----------------------------------------------------------------------------
localparam int unsigned SW_MON_ABI_VERSION       = 1;
localparam int unsigned SW_MON_STATUS_WORD       = 0;
localparam int unsigned SW_MON_RX_USED_WORD      = 1;
localparam int unsigned SW_MON_TX_USED_WORD      = 2;
localparam int unsigned SW_MON_RX_PEAK_WORD      = 3;
localparam int unsigned SW_MON_TX_PEAK_WORD      = 4;
localparam int unsigned SW_MON_RX_LOAD_WORD      = 5;
localparam int unsigned SW_MON_TX_LOAD_WORD      = 6;
localparam int unsigned SW_MON_UPTIME_WORD       = 44;
localparam int unsigned SW_MON_WINDOW_WORD       = 46;
localparam int unsigned SW_MON_REFRESH_WORD      = 48;
localparam int unsigned SW_MON_SEQUENCE_WORD     = 49;
localparam int unsigned SW_MON_VALID_WORD        = 50;
localparam int unsigned SW_MON_CAM_ENTRIES_WORD  = 51;
localparam int unsigned SW_MON_CAM_CAPACITY_WORD = 52;
localparam int unsigned SW_MON_FLUSH_WORD        = 53;
localparam int unsigned SW_MON_BUSY_WORD         = 54;
localparam int unsigned SW_MON_AGE_WORD          = 55;
localparam int unsigned SW_MON_TIME_WORD         = 56;
localparam int unsigned SW_MON_VERSION_WORD      = 58;

// ============================================================================
// 2.  Live-register commands
// ============================================================================
// Two addresses in the aggregate page are not snapshot words but write strobes
// into the monitor itself; they are byte addresses in the same space as the
// word offsets above, and are decoded by es_monitor_core.
localparam logic [31:0] SW_MON_LIVE_CLOCK = 32'hf0;
localparam logic [31:0] SW_MON_LIVE_FLUSH = 32'hf8;

// ============================================================================
// 3.  Read-only monitoring ABI, version 1
// ============================================================================
// Byte addresses; little-word-first 64-bit values.  The two base addresses keep
// the aggregate image and the per-port records in separate decodes, so a port
// index can never alias an aggregate field.
localparam logic [31:0] SW_MON_PORT_BASE = 32'h1000_0000;
localparam logic [31:0] SW_MON_MAC_BASE  = 32'h2000_0000;

// ============================================================================
// 4.  Image geometry and per-record field offsets
// ============================================================================
localparam int unsigned SW_MON_WORDS = 64;
localparam int unsigned SW_MON_BITS  = 32 * SW_MON_WORDS;

/// First word of the counter block: 14 counter pairs, same IDs as `stat_o`.
localparam int unsigned SW_MON_COUNTER = 8;

/// First word of the rate block: RX pps, TX pps, RX bit/s, TX bit/s pairs.
localparam int unsigned SW_MON_RATE = 36;

`default_nettype wire

`endif  // ES_MONITOR_DEFS_SV
