// ============================================================================
//  File        : es_common_defs.sv
//  Description : Shared common declarations; included through es_defs.sv.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_COMMON_DEFS_SV
`define ES_COMMON_DEFS_SV
`default_nettype none
localparam logic [31:0] SW_CRC32_POLY = 32'hEDB8_8320;
localparam logic [31:0] SW_CRC32_INIT = 32'hFFFF_FFFF;
localparam logic [31:0] SW_CRC32_XOROUT = 32'hFFFF_FFFF;
/// Residue of a valid frame in the *reflected* domain (see the note above).
localparam logic [31:0] SW_CRC32_RESIDUE = 32'hDEBB_20E3;

/// One reflected bit step of the CRC-32 LFSR, as the receiver and transmitter
/// both use it.  Provided so the residue above can be re-derived and checked
/// rather than taken on trust.
function automatic logic [31:0] sw_crc32_bit(input var logic [31:0] c,
                                             input var logic b);
  sw_crc32_bit = (c[0] ^ b) ? ((c >> 1) ^ SW_CRC32_POLY) : (c >> 1);
endfunction

/// Absorb one octet into the LFSR, least significant bit first.
function automatic logic [31:0] sw_crc32_absorb_octet(input var logic [31:0] c,
                                                      input var logic [7:0] d);
  logic [31:0] x;
  x = c;
  for (int unsigned i = 0; i < 8; i++) x = sw_crc32_bit(x, d[i]);
  sw_crc32_absorb_octet = x;
endfunction

/// Compute the residue of a valid frame from the polynomial: seed with all
/// ones, absorb a message, append its complemented value as the FCS, and
/// report what is left.  Provided so that `SW_CRC32_RESIDUE` can be
/// re-derived and checked rather than taken on trust.
function automatic logic [31:0] sw_crc32_residue();
  logic [31:0] c;
  logic [31:0] fcs;
  logic [31:0] x;
  c = sw_crc32_absorb_octet(SW_CRC32_INIT, 8'h00);
  fcs = c ^ SW_CRC32_XOROUT;
  x = sw_crc32_absorb_octet(c, fcs[7:0]);
  x = sw_crc32_absorb_octet(x, fcs[15:8]);
  x = sw_crc32_absorb_octet(x, fcs[23:16]);
  x = sw_crc32_absorb_octet(x, fcs[31:24]);
  sw_crc32_residue = x;
endfunction

  function automatic logic [7:0] sw_hexchar(input var logic [3:0] d);
    sw_hexchar = (d < 4'd10) ? 8'd48 + {4'd0, d} : 8'd55 + {4'd0, d};
  endfunction
/// Bits needed to encode a port index in [0, NUM_PORTS).
function automatic int sw_port_w(input int unsigned n);
  sw_port_w = (n > 2) ? $clog2(n) : 1;
endfunction
`default_nettype wire
`endif
