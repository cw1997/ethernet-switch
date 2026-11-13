// ============================================================================
//  File        : es_defs.sv
//  Description : Common switch interface widths and the declarations every
//                domain shares.  Umbrella header for the staged 8-bit
//                pipeline.  There is no statistics map or status surface.
//
//                Compilation-unit declarations keep port ranges readable by
//                yosys read_verilog -sv.  Include guards prevent redefinition;
//                packages, imports and function returns are intentionally
//                absent.
//
//                This is the umbrella header every RTL file includes.  The
//                domain libraries it pulls in are listed at the bottom, in
//                dependency order; the switch-domain declarations that used to
//                share this file's numbering now live in switch/es_switch_defs.sv.
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

// ============================================================================
// 1.  Shared interface widths
// ============================================================================
/// Default port count.  Board shells override the parameter to match their
/// physical PHY count; every width below is derived from the instance's
/// parameter, not from this default.
localparam int unsigned SW_DEFAULT_NUM_PORTS = 4;

/// Frame length in octets, excluding the FCS, shared by the forwarding
/// datapath and by the MAC beat stream.  Eleven bits cover 2047 octets, i.e. any frame
/// up to `SW_MAX_FRAME_LEN` with headroom.
localparam int unsigned SW_LEN_W = 11;

// ============================================================================
// 2.  Link speed model
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
// ----------------------------------------------------------------------------
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
  baud = 1;
  case (speed)
    SW_SPEED_10M:   baud = 10000000;
    SW_SPEED_100M:  baud = 100000000;
    SW_SPEED_1000M: baud = 1000000000;
    default:        baud = 1;
  endcase
  sw_speed_baud = baud;
endfunction

/// Number of `clk_i` cycles that make up one octet time of the canonical stream.
///
///   period = clk_freq_hz * 8 / baud        (rounded to nearest, min 1)
///
/// For the canonical 125 MHz core clock this yields 1 (1000BASE-T, full line
/// rate), 10 (100BASE-TX) and 100 (10BASE-T).  A slower core clock simply
/// stretches the period - the datapath itself never changes, because it is
/// driven exclusively by the resulting clock enable.
function automatic int unsigned sw_byte_period(input int unsigned clk_freq_hz,
                                              input sw_speed_e speed);
  int unsigned baud;
  int unsigned period;
  baud   = sw_speed_baud(speed);
  period = (clk_freq_hz * 8 + (baud / 2)) / baud;
  // A down port (baud == 1) and a very slow clock both have to yield a usable,
  // non-zero period; the octet enable is then simply very slow.
  sw_byte_period = (period == 0) ? 1 : period;
endfunction

// ============================================================================
// 3.  Domain declaration libraries
// ============================================================================
// Included, not compiled separately: each file is guarded, and pulling them in
// here is what lets a module be compiled on its own.  Dependency order is
// common -> mac -> perips -> pl -> switch.  The pipeline library (pl) is
// deliberately BEFORE switch/es_switch_defs.sv: that file closes the two
// declaration-only lint waivers at its end, so a `sw_pl_*` helper that a
// particular top does not read yet would otherwise fail `make lint` as
// UNUSEDPARAM.  pl needs only `SW_LEN_W` above and `sw_port_w()` from common.
//
// The statistics register map and the panel/console libraries are gone: the
// staged switch is pure switching logic and exports no status, counters,
// commands or lamp outputs.
`include "common/es_common_defs.sv"
`include "mac/es_mac_defs.sv"
`include "perips/es_perips_defs.sv"
`include "switch/es_switch_pl_defs.sv"
`include "switch/es_switch_defs.sv"

// Every included library hands the nettype default back before returning, so
// a consumer that wants implicit nets to stay errors has to assert it again
// after this file - which is why every module re-declares it below its own
// include.  Leave this file with the default restored.
`default_nettype wire

`endif  // ES_DEFS_SV
