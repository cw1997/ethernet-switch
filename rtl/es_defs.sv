// ============================================================================
//  File        : es_defs.sv
//  Description : Common switch/telemetry interface widths and statistics.
//
//                Compilation-unit declarations keep port ranges readable by
//                yosys read_verilog -sv. Include guards prevent redefinition;
//                packages, imports and function returns are intentionally absent.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_DEFS_SV
`define ES_DEFS_SV
`default_nettype none

// A declaration library is intentionally broader than any single consumer.
// Keep the original two declaration-only waivers scoped across its includes;
// datapath diagnostics are enabled again at the end of the switch library.
`ifdef VERILATOR
/* verilator lint_off UNUSEDPARAM */
/* verilator lint_off UNUSEDSIGNAL */
`endif
// Board shells override this default to match their physical PHY count.
localparam int unsigned SW_DEFAULT_NUM_PORTS = 4;
// Frame length in octets, excluding FCS, shared by forwarding and telemetry.
localparam int unsigned SW_LEN_W = 11;
// ============================================================================
// 1.  Link speed model
// ============================================================================
// The switch core is fully synchronous to a single `clk_i`.  The three
// Ethernet line rates are therefore handled with *clock enables* (octet
// strobes) instead of with multiple clock domains, which keeps the whole
// design free of clock-domain crossings.
//
// A port only needs one elaboration-time constant: BYTE_PERIOD, the number of
// `clk_i` cycles that make up one octet time of the canonical octet stream.
//
//                  octet rate   BYTE_PERIOD @125 MHz
//     10 Mbit/s      2.5 MHz          100
//    100 Mbit/s     25   MHz           10
//   1000 Mbit/s    125   MHz            1
typedef enum logic [1:0] {
  SW_SPEED_10M   = 2'd0,  ///< 10 Mbit/s    (10BASE-T)
  SW_SPEED_100M  = 2'd1,  ///< 100 Mbit/s   (100BASE-TX)
  SW_SPEED_1000M = 2'd2,  ///< 1000 Mbit/s  (1000BASE-T / GMII)
  SW_SPEED_NONE  = 2'd3   ///< port administratively down
} sw_speed_e;

/// Nominal line rate in bit/s for a link speed.  Used by the byte-period
/// helper below; a down port reports 1 so that the division never degenerates.
function automatic int unsigned sw_speed_baud(input sw_speed_e speed);
  int unsigned baud;
  begin
    baud = 1;
    case (speed)
      SW_SPEED_10M  : baud = 10000000;
      SW_SPEED_100M : baud = 100000000;
      SW_SPEED_1000M: baud = 1000000000;
      default       : baud = 1;
    endcase
    sw_speed_baud = baud;
  end
endfunction

/// Number of `clk_i` cycles that make up one octet time of the canonical stream.
///
///   period = clk_freq_hz * 8 / baud        (rounded to nearest, min 1)
///
/// For the canonical 125 MHz core clock this yields 1 (1000BASE-T, full line
/// rate), 10 (100BASE-TX) and 100 (10BASE-T).  A slower core clock simply
/// stretches the period - the datapath itself never changes, because it is
/// driven exclusively by the resulting clock enable.
function automatic int unsigned sw_byte_period(
    input int unsigned clk_freq_hz,
    input sw_speed_e  speed);
  int unsigned baud;
  int unsigned period;
  begin
    baud    = sw_speed_baud(speed);
    period  = (clk_freq_hz * 8 + (baud / 2)) / baud;
    // A down port (baud == 1) and a very slow clock both have to yield a
    // usable, non-zero period; the octet enable is then simply very slow.
    sw_byte_period = (period == 0) ? 1 : period;
  end
endfunction

/// Bits needed to encode a port index in [0, NUM_PORTS).
function automatic int sw_port_w(input int unsigned n);
  sw_port_w = (n > 2) ? $clog2(n) : 1;
endfunction
// ============================================================================
// 8.  Statistics register map exported on the read-only `stat_o` bus
// ============================================================================
typedef enum int unsigned {
  SW_STAT_RX_FRAMES   = 0,  ///< frames accepted by the receive filter
  SW_STAT_RX_OCTETS   = 1,  ///< octets forwarded into the switching fabric
  SW_STAT_RX_FILTERED = 2,  ///< frames dropped by the ingress filter
  SW_STAT_RX_CRC_ERR  = 3,  ///< frames failing the FCS check
  SW_STAT_RX_RUNT     = 4,  ///< frames shorter than 64 octets
  SW_STAT_RX_OVERSIZE = 5,  ///< frames longer than the configured maximum
  SW_STAT_RX_OVERFLOW = 6,  ///< frames dropped: ingress buffer exhausted
  SW_STAT_TX_FRAMES   = 7,  ///< frame copies injected into a transmit port
  SW_STAT_TX_OCTETS   = 8,  ///< octets injected into a transmit port
  SW_STAT_TX_STALLED  = 9,  ///< frames discarded because egress was blocked
  SW_STAT_CAM_HIT     = 10, ///< CAM lookups that resolved to a port
  SW_STAT_CAM_MISS    = 11, ///< CAM lookups that fell through to flooding
  SW_STAT_CAM_LEARN   = 12, ///< address insertions written into the CAM
  SW_STAT_CAM_FLUSH   = 13  ///< CAM flush operations performed
} sw_stat_id_e;

/// Number of statistics registers.
localparam int unsigned SW_STAT_COUNT = 14;


`include "monitor/es_monitor_defs.sv"
`include "console/es_console_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype wire
`endif // ES_DEFS_SV
