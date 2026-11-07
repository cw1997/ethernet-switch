// ============================================================================
//  File        : es_mac_defs.sv
//  Description : MAC-domain declarations: the width of the beat stream that
//                every MAC hands to the switch core, and the tag that names
//                which line interface a port is built against.
//
//                Why this file exists
//                --------------------
//                The switch core must not know what kind of PHY it is attached
//                to.  The contract between the two domains is therefore stated
//                once, here, instead of being implied by whichever MAC module
//                happens to be instantiated: a MAC turns a line interface into
//                64-bit beats with frame markers and an FCS verdict, and turns
//                a frame plus its beats back into a wire-legal frame.  Every
//                rtl/mac module implements exactly that, so a new interface -
//                including an optical one - is a new leaf module and nothing
//                else.
//
//                Declarations are at compilation-unit scope, not in a package:
//                a package item is not a constant range to the synthesis
//                frontend and is rejected in a port declaration before the body
//                is parsed.  See es_defs.sv for the full rationale.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_MAC_DEFS_SV
`define ES_MAC_DEFS_SV

`default_nettype none

// ============================================================================
// 1.  Beat stream geometry
// ============================================================================
/// Octets carried by one beat.  A full beat is the widest unit the switching
/// datapath moves; the last beat of a frame is usually partial and says so in
/// its valid-octet field.
localparam int unsigned SW_MAC_BEAT_BYTES = 8;

/// Beat data width in bits.
localparam int unsigned SW_MAC_BEAT_W = 8 * SW_MAC_BEAT_BYTES;

/// Width of the valid-octet count carried alongside every beat.
localparam int unsigned SW_MAC_OCTETS_W = 4;

/// Elastic buffer word inside a MAC: the beat plus the three frame markers and
/// the FCS verdict that travel with it, packed as
/// `{octets, crc_ok, eof, sof, data}`.
///
/// The buffer exists on the MAC side of the boundary and not in the switch
/// because it is the *line interface* that cannot be stalled mid-frame; putting
/// it here is what lets the switch parser drain a beat stream at its leisure
/// without ever holding up a PHY.
localparam int unsigned SW_MAC_WF_W = SW_MAC_BEAT_W + SW_MAC_OCTETS_W + 3;

// ============================================================================
// 2.  Line interface identity
// ============================================================================
/// Which physical line interface a port is built against.  Reported by the
/// console and carried in the `version` response; no datapath logic branches on
/// it, because by the time a beat reaches the core the difference is gone.
typedef enum logic [1:0] {
  SW_MAC_IF_GMII = 2'd0,  ///< octet-aligned pins, 10 / 100 / 1000 Mbit/s
  SW_MAC_IF_MII  = 2'd1,  ///< nibble-serial pins, 10 / 100 Mbit/s
  SW_MAC_IF_RMII = 2'd2   ///< dibit-serial pins, 10 / 100 Mbit/s
} sw_mac_if_e;

`default_nettype wire

`endif  // ES_MAC_DEFS_SV
