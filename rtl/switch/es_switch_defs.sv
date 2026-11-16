// ============================================================================
//  File        : es_switch_defs.sv
//  Description : Switch constants and compilation-unit helpers.
//
//                Compilation-unit declarations keep port ranges readable by
//                yosys read_verilog -sv.  Include guards prevent redefinition;
//                packages, imports and function returns are intentionally
//                absent.
//
//                Section numbers are local to this file; the umbrella header
//                rtl/es_defs.sv carries the shared widths that the sections
//                below refer to.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_DEFS_SV
`define ES_SWITCH_DEFS_SV

`default_nettype none

// ============================================================================
// 1.  MAC interface selection (by top module; default GMII)
// ============================================================================
// The switch core (`es_switch_core`) is interface-agnostic: it only talks a
// canonical, clock-enable-qualified octet stream.  The physical MAC pins are
// added by one of three top-level wrappers, one per interface, each in its own
// file, and the interface in use is chosen by which wrapper is elaborated:
//
//   es_gmii_top        GMII-style 8-bit pins (`gmii_*`; the default top)
//   es_mii_top         MII pins, two 4-bit nibbles per octet (`mii_*`)
//   es_rmii_top        RMII pins, four 2-bit chunks per octet (`rmii_*`)
//
// All three wrap the same core: the MII/RMII pin groups are adapted onto the
// canonical octet stream by es_mac_mii_serdes / es_mac_rmii_serdes, so
// the datapath, the CAM and the statistics map never see a difference.  Both
// narrow interfaces are 10/100 Mbit/s front-ends only - a port configured for
// 1000 Mbit/s is rejected at elaboration time in those wrappers.
//
// The Makefile `lint` / `rtl` / `synth` gates and the CI run all three top
// modules, so every wrapper is compiled on every change.

// ============================================================================
// 2.  Frame geometry (octets; the FCS is excluded unless stated otherwise)
// ============================================================================
localparam int unsigned SW_HDR_LEN       = 14;    ///< dst MAC + src MAC + EtherType
localparam int unsigned SW_HDR_LEN_VLAN  = 18;    ///< 802.1Q tagged header
localparam int unsigned SW_FCS_LEN       = 4;     ///< Ethernet FCS (CRC-32)
localparam int unsigned SW_MAX_ETHERTYPE = 1500;  ///< largest legal 802.3 length
localparam int unsigned SW_PREAMBLE_LEN  = 8;     ///< 7 x 0x55 + 1 x 0xD5
localparam int unsigned SW_IFG_OCTETS    = 12;    ///< minimum inter-frame gap

// `SW_LEN_W`, the width of a frame length field, is declared in es_defs.sv
// because the MAC byte stream shares it with the forwarding datapath.

// ============================================================================
// 3.  EtherType values recognised by the receive parser
// ============================================================================
localparam logic [15:0] SW_ETHERTYPE_VLAN = 16'h8100;  ///< 802.1Q customer tag
localparam logic [15:0] SW_ETHERTYPE_QINQ = 16'h88A8;  ///< 802.1ad service tag

/// True when the length/EtherType field carries an 802.1Q / 802.1ad tag, which
/// pushes the real EtherType four octets further into the header.
function automatic logic sw_is_vlan_type(input var logic [15:0] l2type);
  sw_is_vlan_type = (l2type == SW_ETHERTYPE_VLAN) || (l2type == SW_ETHERTYPE_QINQ);
endfunction

/// True when the second header word carries an 802.3 *length* rather than an
/// EtherType.  A length field is the only case in which the frame size is
/// known before the frame has been received; every EtherType frame has to be
/// measured on the wire instead.
function automatic logic sw_is_8023_length(input var logic [15:0] l2type);
  sw_is_8023_length = (l2type <= SW_MAX_ETHERTYPE[15:0]);
endfunction

// ============================================================================
// 4.  Ethernet CRC-32 (IEEE 802.3 clause 4.1)
// ============================================================================
// The constants and the LFSR helpers are declared in common/es_common_defs.sv;
// what belongs here is the formulation they implement, because getting it wrong
// rejects every valid frame:
//
//  * `SW_CRC32_POLY` is the *reflected* form of the generator 0x04C11DB7, which
//    is what the byte-at-a-time implementation in es_common_crc32 uses.
//  * The transmitter seeds the LFSR with all ones and applies a final XOR
//    before appending the resulting value as the FCS, least significant octet
//    first.
//  * The receiver runs the identical LFSR over the received octets *including*
//    the received FCS and compares the leftover value with `SW_CRC32_RESIDUE`.
//    That residue is a property of the polynomial, so one comparison validates
//    the whole frame.
//
//  The textbook "magic residue" 0xC704DD1B belongs to the MSB-first
//  (non-reflected) formulation of the polynomial.  This design uses the
//  reflected LFSR, whose registers carry the bit-reversed residue
//  reverse32(0xC704DD1B) = 0xDEBB20E3.  Using the non-reflected constant with
//  a reflected LFSR would reject every valid frame, which is exactly the kind
//  of mismatch `sw_crc32_tb` is there to catch.

// ============================================================================
// 5.  Address helpers
// ============================================================================
//  An address is held with the first transmitted octet in the most significant
//  byte, so `mac[47:40]` is the first octet on the wire.
//
//  The individual/group (I/G) bit is the *least significant* bit of that first
//  octet, i.e. bit 40 of the 48-bit value: 0 = individual (unicast) address,
//  1 = group (multicast / broadcast) address.  Getting this bit wrong makes
//  every unicast address look like a group address, which silently disables
//  source-address learning and turns the switch into a flooding hub.
typedef logic [47:0] sw_mac_t;

/// Position of the I/G bit within `sw_mac_t`.
localparam int unsigned SW_MAC_IG_BIT = 40;

localparam sw_mac_t SW_MAC_BROADCAST = 48'hFF_FF_FF_FF_FF_FF;
localparam sw_mac_t SW_MAC_NULL      = 48'h00_00_00_00_00_00;

/// True for a group (multicast) address.  The all-zero address is excluded
/// because it is neither a valid source nor a valid destination.
function automatic logic sw_is_group(input sw_mac_t mac);
  sw_is_group = (mac[SW_MAC_IG_BIT] == 1'b1) && (mac != SW_MAC_NULL);
endfunction

/// True for an individually addressed (unicast) address.
function automatic logic sw_is_unicast(input sw_mac_t mac);
  sw_is_unicast = (mac[SW_MAC_IG_BIT] == 1'b0);
endfunction

/// Locally administered (02:...) unicast address derived from a port index.
/// Used as the default address of a port that was left unassigned.
function automatic sw_mac_t sw_default_mac(input int unsigned idx);
  sw_default_mac = 48'h02_00_00_00_00_00 | 48'(idx);
endfunction

// ============================================================================
// 6.  Unknown-unicast / group-address flooding policy
// ============================================================================
// Encodings of the two-bit FLOOD_MODE parameter, not a typedef: casting a
// variable to an enum is rejected by yosys (AGENTS.md, "Shared RTL domains").
localparam logic [1:0] SW_FLOOD_BCAST_ONLY = 2'd0;  ///< only ff:ff:ff:ff:ff:ff
localparam logic [1:0] SW_FLOOD_BCAST_UKN  = 2'd1;  ///< also flood unicast misses
localparam logic [1:0] SW_FLOOD_ALL        = 2'd2;  ///< also flood group misses

`ifdef VERILATOR
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
`endif

`default_nettype wire

`endif  // ES_SWITCH_DEFS_SV
