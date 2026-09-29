// ============================================================================
//  File        : sw_crc32.sv
//  Description : Byte-serial Ethernet CRC-32 (IEEE 802.3 clause 4.1).
//
//                The module is deliberately *octet* serial: it consumes at most
//                one octet per clock enable.  On a 125 MHz core clock that is
//                exactly 1 Gbit/s of checking/generation, so a 1000BASE-T port
//                runs the CRC at line rate.  A narrower core clock simply needs
//                a proportionally longer clock-enable period, which is why the
//                block is clock-enable driven rather than clock driven.
//
//                Two usage modes share the same LFSR:
//
//                  * Transmit (generate) - the MAC client data octets are
//                    absorbed; `crc_fin_o` is the complemented register value
//                    that has to be appended as the FCS, least significant
//                    octet first.
//
//                  * Receive (check) - the received octets *including* the
//                    received FCS are absorbed; a good frame leaves the magic
//                    residue 0xC704DD1B in the register, which is what
//                    `resid_ok_o` compares against.
//
//                Both modes are driven purely by `en_i` / `clr_i`, so the
//                module contains no frame state of its own.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef SW_CRC32_SV
`define SW_CRC32_SV

`include "sw_switch_pkg.sv"


// ---------------------------------------------------------------------------
//  Package import
//
//  The package is pulled in by the guarded `include` above, which is what makes
//  its declarations visible here.  Under simulation an explicit wildcard import
//  is added as well, because a simulator resolves a package strictly: without it
//  neither the port list nor the body can see `sw_switch_pkg` items.
//
//  Under synthesis the import is omitted.  The yosys frontend that OpenLane /
//  LibreLane drive does not accept a wildcard package import at all - neither in
//  a module header, nor inside the body, nor at file scope - and aborts with
//
//      syntax error, unexpected TOK_ID, expecting '(' or ';' or '#'
//
//  right at the module keyword, so the message points at the module rather than
//  at the import.  It does, however, make the items of an *included* package
//  visible for free, so dropping the import is both necessary and sufficient.
//  The two forms below differ only in the two tokens between the module name and
//  its port list; everything after the `endif is shared.
// ---------------------------------------------------------------------------
`ifndef SYNTHESIS
module sw_crc32 import sw_switch_pkg::*; (
`else
module sw_crc32 (
`endif
  input  logic        clk_i,      ///< core clock
  input  logic        rst_ni,     ///< active-low synchronous reset
  input  logic        en_i,       ///< absorb `din_i` this clock
  input  logic [7:0]  din_i,      ///< octet to absorb
  input  logic        clr_i,      ///< re-seed the LFSR (start of frame)
  output logic [31:0] crc_fin_o,  ///< LFSR ^ 0xFFFFFFFF - the value to transmit
  output logic        resid_ok_o  ///< LFSR == 0xC704DD1B - receive check
);

  // --------------------------------------------------------------------------
  // Reflected CRC-32 lookup table.
  //
  // This is the standard byte-wise slicing of the reflected polynomial
  // 0x04C11DB7, i.e. 0xEDB88320.  The table is generated once during
  // elaboration, so it maps onto a constant ROM in the fabric and needs no
  // run-time initialisation and no reset.
  // --------------------------------------------------------------------------
  logic [31:0] crc_table [0:255];

  initial begin
    for (int unsigned i = 0; i < 256; i++) begin
      logic [31:0] c;
      c = 32'(i);
      // Eight reflected shift steps build the table entry for octet value i.
      for (int unsigned b = 0; b < 8; b++) begin
        c = c[0] ? ((c >> 1) ^ SW_CRC32_POLY) : (c >> 1);
      end
      crc_table[i] = c;
    end
  end

  // --------------------------------------------------------------------------
  // Running LFSR.  `crc` holds the *uncomplemented* register state; both the
  // transmitted FCS and the receive residue are derived from it combinationally,
  // so the verdict is available in the very same clock that the final octet is
  // absorbed.
  // --------------------------------------------------------------------------
  logic [31:0] crc;

  // The index into the table is the low octet of the register XORed with the
  // incoming octet.  It is hoisted out of the process below because some
  // simulators over-approximate the sensitivity of an inline constant
  // part-select inside an always_* block.
  logic [7:0]  crc_lsb;
  logic [7:0]  tbl_idx;
  assign crc_lsb = crc[7:0];
  assign tbl_idx = crc_lsb ^ din_i;

  logic [31:0] crc_d;
  always_comb begin
    crc_d = (crc >> 8) ^ crc_table[tbl_idx];
  end

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      crc <= SW_CRC32_INIT;
    end else if (clr_i) begin
      crc <= SW_CRC32_INIT;
    end else if (en_i) begin
      crc <= crc_d;
    end
  end

  assign crc_fin_o  = crc ^ SW_CRC32_XOROUT;
  assign resid_ok_o = (crc == SW_CRC32_RESIDUE);

endmodule : sw_crc32

`endif // SW_CRC32_SV
