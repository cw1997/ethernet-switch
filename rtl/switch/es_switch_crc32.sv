// ============================================================================
//  File        : es_switch_crc32.sv
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

`ifndef ES_SWITCH_CRC32_SV
`define ES_SWITCH_CRC32_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

// The shared CRC constants arrive through the include above and are visible at
// compilation-unit scope.  See es_defs.sv for why a package cannot be used here.
module es_switch_crc32 (
  input var logic        clk_i,      ///< core clock
  input var logic        rst_ni,     ///< active-low synchronous reset
  input var logic        en_i,       ///< absorb `din_i` this clock
  input var logic [ 7:0] din_i,      ///< octet to absorb
  input var logic        clr_i,      ///< re-seed the LFSR (start of frame)
  output    logic [31:0] crc_fin_o,  ///< LFSR ^ 0xFFFFFFFF - the value to transmit
  output    logic        resid_ok_o  ///< LFSR == 0xC704DD1B - receive check
);

  // --------------------------------------------------------------------------
  // Reflected CRC-32 lookup, computed rather than tabulated.
  //
  // This is the standard byte-wise slicing of the reflected polynomial
  // 0x04C11DB7, i.e. 0xEDB88320.  An earlier revision built the 256-entry
  // table in an `initial` block, which synthesised to a constant ROM in every
  // tool except Quartus: its constant evaluator needs tens of CPU-minutes
  // *per instance* to push an initial-block-initialised memory through
  // the elaboration (27 CPU-minutes without completing on Quartus Prime 25.1std,
  // against 35 wall-clock seconds for this form).  The function computes the
  // identical value - the same eight reflected shift steps - so the hardware
  // is bit-exact with what the table produced, at the cost of a few hundred
  // LUTs per instance instead of one RAM block.  See AGENTS.md 2.4.
  // --------------------------------------------------------------------------
  function automatic logic [31:0] crc_table_word(input var logic [7:0] idx);
    logic [31:0] c;
    c = 32'(idx);
    // Eight reflected shift steps build the table entry for octet value idx.
    for (int unsigned b = 0; b < 8; b++) begin
      c = c[0] ? ((c >> 1) ^ SW_CRC32_POLY) : (c >> 1);
    end
    crc_table_word = c;
  endfunction

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
  logic [ 7:0] crc_lsb;
  logic [ 7:0] tbl_idx;
  assign crc_lsb = crc[7:0];
  assign tbl_idx = crc_lsb ^ din_i;

  logic [31:0] crc_d;
  always_comb begin
    crc_d = (crc >> 8) ^ crc_table_word(tbl_idx);
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

endmodule : es_switch_crc32

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_SWITCH_CRC32_SV
