// ============================================================================
//  File        : es_switch_defs.sv
//  Description : Switch constants, pipeline descriptor layout and
//                compilation-unit helpers.
//
//                Compilation-unit declarations keep port ranges readable by
//                yosys read_verilog -sv.  Include guards prevent redefinition;
//                packages, imports and function returns are intentionally
//                absent.
//
//                This is the switch-domain library: the frame geometry,
//                EtherType/CRC/address helpers, descriptor field offsets and
//                the simulation-vs-synthesis geometry defaults all live here.
//                It is included after common/es_common_defs.sv and depends
//                only on ES_LEN_W (es_defs.sv) and es_port_w() (common).
//                The two declaration-only Verilator waivers are closed at the
//                end of this file, so every declaration above stays covered.
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
localparam int unsigned ES_HDR_LEN       = 14;    ///< dst MAC + src MAC + EtherType
localparam int unsigned ES_HDR_LEN_VLAN  = 18;    ///< 802.1Q tagged header
localparam int unsigned ES_FCS_LEN       = 4;     ///< Ethernet FCS (CRC-32)
localparam int unsigned ES_MAX_ETHERTYPE = 1500;  ///< largest legal 802.3 length
localparam int unsigned ES_PREAMBLE_LEN  = 8;     ///< 7 x 0x55 + 1 x 0xD5
localparam int unsigned ES_IFG_OCTETS    = 12;    ///< minimum inter-frame gap

// `ES_LEN_W`, the width of a frame length field, is declared in es_defs.sv
// because the MAC byte stream shares it with the forwarding datapath.

// ============================================================================
// 3.  EtherType values recognised by the receive parser
// ============================================================================
localparam logic [15:0] ES_ETHERTYPE_VLAN = 16'h8100;  ///< 802.1Q customer tag
localparam logic [15:0] ES_ETHERTYPE_QINQ = 16'h88A8;  ///< 802.1ad service tag

/// True when the length/EtherType field carries an 802.1Q / 802.1ad tag, which
/// pushes the real EtherType four octets further into the header.
function automatic logic es_is_vlan_type(input var logic [15:0] l2type);
  es_is_vlan_type = (l2type == ES_ETHERTYPE_VLAN) || (l2type == ES_ETHERTYPE_QINQ);
endfunction

/// True when the second header word carries an 802.3 *length* rather than an
/// EtherType.  A length field is the only case in which the frame size is
/// known before the frame has been received; every EtherType frame has to be
/// measured on the wire instead.
function automatic logic es_is_8023_length(input var logic [15:0] l2type);
  es_is_8023_length = (l2type <= ES_MAX_ETHERTYPE[15:0]);
endfunction

// ============================================================================
// 4.  Ethernet CRC-32 (IEEE 802.3 clause 4.1)
// ============================================================================
// The constants and the LFSR helpers are declared in common/es_common_defs.sv;
// what belongs here is the formulation they implement, because getting it wrong
// rejects every valid frame:
//
//  * `ES_CRC32_POLY` is the *reflected* form of the generator 0x04C11DB7, which
//    is what the byte-at-a-time implementation in es_common_crc32 uses.
//  * The transmitter seeds the LFSR with all ones and applies a final XOR
//    before appending the resulting value as the FCS, least significant octet
//    first.
//  * The receiver runs the identical LFSR over the received octets *including*
//    the received FCS and compares the leftover value with `ES_CRC32_RESIDUE`.
//    That residue is a property of the polynomial, so one comparison validates
//    the whole frame.
//
//  The textbook "magic residue" 0xC704DD1B belongs to the MSB-first
//  (non-reflected) formulation of the polynomial.  This design uses the
//  reflected LFSR, whose registers carry the bit-reversed residue
//  reverse32(0xC704DD1B) = 0xDEBB20E3.  Using the non-reflected constant with
//  a reflected LFSR would reject every valid frame, which is exactly the kind
//  of mismatch `es_crc32_tb` is there to catch.

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
typedef logic [47:0] es_mac_t;

/// Position of the I/G bit within `es_mac_t`.
localparam int unsigned ES_MAC_IG_BIT = 40;

localparam es_mac_t ES_MAC_BROADCAST = 48'hFF_FF_FF_FF_FF_FF;
localparam es_mac_t ES_MAC_NULL      = 48'h00_00_00_00_00_00;

/// True for a group (multicast) address.  The all-zero address is excluded
/// because it is neither a valid source nor a valid destination.
function automatic logic es_is_group(input es_mac_t mac);
  es_is_group = (mac[ES_MAC_IG_BIT] == 1'b1) && (mac != ES_MAC_NULL);
endfunction

/// True for an individually addressed (unicast) address.
function automatic logic es_is_unicast(input es_mac_t mac);
  es_is_unicast = (mac[ES_MAC_IG_BIT] == 1'b0);
endfunction

/// Locally administered (02:...) unicast address derived from a port index.
/// Used as the default address of a port that was left unassigned.
function automatic es_mac_t es_default_mac(input int unsigned idx);
  es_default_mac = 48'h02_00_00_00_00_00 | 48'(idx);
endfunction

// ============================================================================
// 6.  Unknown-unicast / group-address flooding policy
// ============================================================================
// Encodings of the two-bit FLOOD_MODE parameter, not a typedef: casting a
// variable to an enum is rejected by yosys (AGENTS.md, "Shared RTL domains").
localparam logic [1:0] ES_FLOOD_BCAST_ONLY = 2'd0;  ///< only ff:ff:ff:ff:ff:ff
localparam logic [1:0] ES_FLOOD_BCAST_UKN  = 2'd1;  ///< also flood unicast misses
localparam logic [1:0] ES_FLOOD_ALL        = 2'd2;  ///< also flood group misses

// ============================================================================
// 7.  Byte-stream contract between a MAC adapter and the switch core
// ============================================================================
// The switch core sees MAC client data only: no preamble or SFD.  The MAC
// adapter hunts for seven preamble octets followed by the SFD; a broken run
// produces no bytes at all rather than a partial frame (es_mac_frame_rx).
localparam logic [7:0] ES_PL_PREAMBLE_OCTET = 8'h55;
localparam logic [7:0] ES_PL_SFD_OCTET      = 8'hD5;

// ============================================================================
// 8.  Frame descriptor layout
// ============================================================================
// The pipeline levels exchange a descriptor, not a struct: yosys rejects
// package items in port ranges and has no implementation for `import`
// (AGENTS.md 2.1).  Field offsets are therefore functions over `NUM_PORTS`,
// evaluated into a `localparam` at each module.  A caller writes
//
//     localparam int unsigned DESC_DST =
//         es_pl_desc_dstm_lsb(NUM_PORTS);
//     ... desc[DESC_DST +: 48] ...
//
// Width of the occupancy/free counter of an es_mems_sync_fifo with the given
// DEPTH.  It has to be callable directly in a port range, exactly like
// es_port_w(): a module's own localparam is declared too late for that.
function automatic int unsigned es_pl_fifo_cnt_w(input int unsigned depth);
  es_pl_fifo_cnt_w = ((depth <= 2) ? 1 : $clog2(depth)) + 1;
endfunction

// Forward descriptor = {drop, stored_len, dst_mac, src_mac, len, src_port}.
// The frame bytes live in a per-port FIFO. stored_len remains nonzero for
// rejected frames whose prefix must still be consumed in order.
function automatic int unsigned es_pl_desc_w(input int unsigned nports);
  es_pl_desc_w = 1 + 48 + 48 + 2 * ES_LEN_W + es_port_w(nports);
endfunction

function automatic int unsigned es_pl_desc_len_lsb(input int unsigned nports);
  es_pl_desc_len_lsb = es_port_w(nports);
endfunction

function automatic int unsigned es_pl_desc_srcm_lsb(input int unsigned nports);
  es_pl_desc_srcm_lsb = es_port_w(nports) + ES_LEN_W;
endfunction

function automatic int unsigned es_pl_desc_dstm_lsb(input int unsigned nports);
  es_pl_desc_dstm_lsb = es_port_w(nports) + ES_LEN_W + 48;
endfunction

function automatic int unsigned es_pl_desc_stored_lsb(input int unsigned nports);
  es_pl_desc_stored_lsb = es_pl_desc_dstm_lsb(nports) + 48;
endfunction

// RX/validate append {computed CRC, wire FCS, error, VLAN, Length/Type,
// measured length}. The count includes the failing beat for an early abort.
localparam int unsigned ES_PL_MIN_WIRE_CLIENT = 60;
localparam int unsigned ES_PL_RX_TYPE_LSB = ES_LEN_W + 1;
localparam int unsigned ES_PL_RX_VLAN_LSB = ES_PL_RX_TYPE_LSB + 16;
localparam int unsigned ES_PL_RX_ERR_LSB  = ES_PL_RX_VLAN_LSB + 1;

function automatic int unsigned es_pl_rx_desc_w(input int unsigned nports);
  es_pl_rx_desc_w = es_pl_desc_w(nports) + ES_PL_RX_ERR_LSB + 1 + 64;
endfunction

function automatic int unsigned es_pl_tx_depth(input int unsigned depth,
                                              input int unsigned max_len);
  es_pl_tx_depth = (depth < 2 * max_len) ? 2 * max_len : depth;
endfunction

// ============================================================================
// 9.  CAM-level descriptor accessors
// ============================================================================
/// CAM level appends {hit, port_onehot} to the descriptor.
function automatic int unsigned es_pl_cam_w(input int unsigned nports);
  es_pl_cam_w = es_pl_desc_w(nports) + 1 + nports;
endfunction

function automatic int unsigned es_pl_cam_hit_lsb(input int unsigned nports);
  es_pl_cam_hit_lsb = es_pl_desc_w(nports);
endfunction

function automatic int unsigned es_pl_cam_port_lsb(input int unsigned nports);
  es_pl_cam_port_lsb = es_pl_desc_w(nports) + 1;
endfunction

// ============================================================================
// 10. Default geometry for the synthesis front end
// ============================================================================
// `make synth` and LibreLane both define SYNTHESIS.  A full-size frame buffer
// (4 ports x 2048 bytes x 8 = 131072 flops) makes yosys' `synth -flatten`
// take tens of minutes, far beyond a CI lint job; the gate only has to prove
// that the frontend can read and elaborate the design.  It therefore uses the
// same reduced geometry as librelane/config.json.  Simulations (SYNTHESIS
// undefined) keep the full defaults, so no behavioural test is weakened.
`ifdef SYNTHESIS
localparam int unsigned ES_PL_DEF_MIN_FRAME_LEN   = ES_PL_MIN_WIRE_CLIENT;
localparam int unsigned ES_PL_DEF_MAX_FRAME_LEN   = 256;
localparam int unsigned ES_PL_DEF_SLOTS          = 1;
localparam int unsigned ES_PL_DEF_SLOT_BYTES     = 512;
localparam int unsigned ES_PL_DEF_DESC_DEPTH     = 8;
localparam int unsigned ES_PL_DEF_TX_QUEUE_DEPTH = 64;
localparam int unsigned ES_PL_DEF_CAM_SETS       = 16;
localparam int unsigned ES_PL_DEF_CAM_WAYS       = 2;
`else
localparam int unsigned ES_PL_DEF_MIN_FRAME_LEN   = ES_PL_MIN_WIRE_CLIENT;
localparam int unsigned ES_PL_DEF_MAX_FRAME_LEN   = 1518;
localparam int unsigned ES_PL_DEF_SLOTS          = 2;
localparam int unsigned ES_PL_DEF_SLOT_BYTES     = 2048;
localparam int unsigned ES_PL_DEF_DESC_DEPTH     = 8;
localparam int unsigned ES_PL_DEF_TX_QUEUE_DEPTH = 256;
localparam int unsigned ES_PL_DEF_CAM_SETS       = 128;
localparam int unsigned ES_PL_DEF_CAM_WAYS       = 4;
`endif

`ifdef VERILATOR
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on UNUSEDPARAM */
`endif

`default_nettype wire

`endif  // ES_SWITCH_DEFS_SV
