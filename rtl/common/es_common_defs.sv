// ============================================================================
//  File        : es_common_defs.sv
//  Description : Shared common declarations; included through es_defs.sv.
//
//                Everything here is a compilation-unit item that more than one
//                domain needs: the CRC-32 formulation used by both the receive
//                and the transmit path, and the port-index width every packed
//                port-mask relies on.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_COMMON_DEFS_SV
`define ES_COMMON_DEFS_SV

`default_nettype none

// ============================================================================
// 1.  CRC-32 constants (reflected IEEE 802.3 polynomial)
// ============================================================================
localparam logic [31:0] ES_CRC32_POLY   = 32'hEDB8_8320;
localparam logic [31:0] ES_CRC32_INIT   = 32'hFFFF_FFFF;
localparam logic [31:0] ES_CRC32_XOROUT = 32'hFFFF_FFFF;
/// Residue of a valid frame after its FCS is absorbed in the reflected domain.
localparam logic [31:0] ES_CRC32_RESIDUE = 32'hDEBB_20E3;

// ============================================================================
// 2.  CRC-32 helpers
// ============================================================================
/// One reflected bit step of the CRC-32 LFSR, as the receiver and transmitter
/// both use it.  Provided so the residue above can be re-derived and checked
/// rather than taken on trust.
function automatic logic [31:0] es_crc32_bit(input var logic [31:0] c,
                                             input var logic b);
  es_crc32_bit = (c[0] ^ b) ? ((c >> 1) ^ ES_CRC32_POLY) : (c >> 1);
endfunction

/// Absorb one octet into the LFSR, least significant bit first.
function automatic logic [31:0] es_crc32_absorb_octet(input var logic [31:0] c,
                                                      input var logic [7:0] d);
  logic [31:0] x;
  x = c;
  for (int unsigned i = 0; i < 8; i++) x = es_crc32_bit(x, d[i]);
  es_crc32_absorb_octet = x;
endfunction

// ============================================================================
// 3.  Width helpers
// ============================================================================
/// Bits needed to encode a port index in [0, NUM_PORTS).
///
/// A one-port fabric still needs one bit: a zero-width vector is not a legal
/// declaration, so the degenerate case is clamped rather than left to
/// `$clog2(1) = 0`.
function automatic int unsigned es_port_w(input int unsigned n);
  es_port_w = (n > 2) ? $clog2(n) : 1;
endfunction

`default_nettype wire

`endif  // ES_COMMON_DEFS_SV
