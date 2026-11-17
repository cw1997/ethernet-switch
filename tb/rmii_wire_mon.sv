// ============================================================================
//  File        : rmii_wire_mon.sv
//  Description : Independent RMII transmit wire monitor.  Captures one dibit
//                per clock while TX_EN is high, groups four into an octet,
//                skips the first glitched boundary dibit and undoes the
//                free-running chunk-grid rotation of the RMII serialiser.
//                Checks preamble and FCS against the es_tb_pkg reference.
// ============================================================================
`timescale 1ns/1ps

`include "es_defs.sv"
`include "es_tb_pkg.sv"

module rmii_wire_mon
  import es_tb_pkg::*;
#(
  parameter int unsigned PORT_ID = 0
) (
  input  var logic        clk_i,
  input  var logic        rst_ni,
  input  var logic        clear_i,
  input  var logic        tx_en_i,
  input  var logic [1:0]  tx_d_i,

  output      logic [15:0] cnt_o,
  output      logic [11:0] len_o,
  output      logic [47:0] dst_o,
  output      logic [47:0] src_o,
  output      logic        ok_o
);
  tb_frame_buf_t fbuf;
  int unsigned   nseen;   // dibits captured in the current frame
  int unsigned   noct;    // octets reconstructed in the current frame
  logic [7:0]    acc;     // last four dibits: {c3,c2,c1,c0}
  logic          running;

  logic [15:0]   cnt_r;
  logic [11:0]   len_r;
  logic [47:0]   dst_r;
  logic [47:0]   src_r;
  logic          ok_r;
  logic          pre_ok;
  logic [31:0]   want_fcs;
  logic [31:0]   got_fcs;
  int unsigned   k;

  assign cnt_o = cnt_r;
  assign len_o = len_r;
  assign dst_o = dst_r;
  assign src_o = src_r;
  assign ok_o  = ok_r;

  // `acc` holds the four dibits in capture order (c0 first, c3 last).  The DUT
  // presents the high pair first with a one-chunk rotation from the free-running
  // grid; reorder to {c1,c2,c3,c0} recovers the octet bit order.  This is the
  // empirically validated, phase-independent mapping.
  function automatic logic [7:0] map_oct(input logic [7:0] a);
    logic [7:0] rev;
    rev = {a[1:0], a[3:2], a[5:4], a[7:6]};  // c0 first (high pair first)
    map_oct = {rev[5:0], rev[7:6]};          // rotate one two-bit chunk
  endfunction

  always @(posedge clk_i) begin
    if (!rst_ni || clear_i) begin
      fbuf    = '0;
      nseen   = 0;
      noct    = 0;
      acc     = '0;
      running = 1'b0;
      cnt_r   = '0;
      len_r   = '0;
      dst_r   = '0;
      src_r   = '0;
      ok_r    = 1'b1;
    end else if (tx_en_i) begin
      acc   = {acc[5:0], tx_d_i};
      nseen = nseen + 1;
      // Form an octet once four dibits are available (4, 8, 12, ...).  The
      // first boundary dibit is naturally skipped by this grouping.
      if ((nseen % 4) == 0) begin
        fbuf = tb_put_octet(fbuf, noct, map_oct(acc));
        noct = noct + 1;
      end
      running = 1'b1;
    end else if (running) begin
      // One complete frame just ended.  noct counts wire octets:
      // 8 preamble/SFD + client_len + 4 FCS.
      running = 1'b0;
      cnt_r   = cnt_r + 16'd1;
      len_r   = 12'(noct - 12);
      dst_r   = {tb_get_octet(fbuf, 8),  tb_get_octet(fbuf, 9),
                 tb_get_octet(fbuf, 10), tb_get_octet(fbuf, 11),
                 tb_get_octet(fbuf, 12), tb_get_octet(fbuf, 13)};
      src_r   = {tb_get_octet(fbuf, 14), tb_get_octet(fbuf, 15),
                 tb_get_octet(fbuf, 16), tb_get_octet(fbuf, 17),
                 tb_get_octet(fbuf, 18), tb_get_octet(fbuf, 19)};

      pre_ok = 1'b1;
      for (k = 0; k < 7; k++)
        if (tb_get_octet(fbuf, k) != 8'h55) pre_ok = 1'b0;
      if (tb_get_octet(fbuf, 7) != 8'hD5) pre_ok = 1'b0;

      want_fcs = tb_crc32(fbuf, noct - 12, 8);
      got_fcs  = {tb_get_octet(fbuf, noct-1), tb_get_octet(fbuf, noct-2),
                  tb_get_octet(fbuf, noct-3), tb_get_octet(fbuf, noct-4)};
      ok_r = ok_r && pre_ok && (want_fcs == got_fcs);

      fbuf  = '0;
      nseen = 0;
      noct  = 0;
      acc   = '0;
    end
  end
endmodule : rmii_wire_mon
