// ============================================================================
//  File        : es_pl_gmii_mon.sv
//  Description : Independent GMII transmit wire monitor.  Reassembles complete
//                wire frames from the octet pins and checks preamble/SFD and
//                the CRC against the reference in es_tb_pkg.  Reports count,
//                length, dst/src MAC and an accumulated verdict per port.
// ============================================================================
`timescale 1ns/1ps

`include "es_defs.sv"
`include "es_tb_pkg.sv"

module es_pl_gmii_mon
  import es_tb_pkg::*;
#(
  parameter int unsigned PORT_ID = 0
) (
  input  var logic        clk_i,
  input  var logic        rst_ni,
  input  var logic        clear_i,
  input  var logic        tx_en_i,
  input  var logic [7:0]  tx_d_i,

  output      logic [15:0] cnt_o,
  output      logic [11:0] len_o,
  output      logic [47:0] dst_o,
  output      logic [47:0] src_o,
  output      logic        ok_o
);

  tb_frame_buf_t     buf_r;
  int unsigned       idx;
  logic [15:0]       cnt_r;
  logic [11:0]       len_r;
  logic [47:0]       dst_r;
  logic [47:0]       src_r;
  logic              ok_r;
  logic              pre_ok;
  logic              fcs_ok;
  logic [31:0]       want_fcs;
  logic [31:0]       got_fcs;
  int unsigned       client_len;
  int unsigned       k;

  assign cnt_o = cnt_r;
  assign len_o = len_r;
  assign dst_o = dst_r;
  assign src_o = src_r;
  assign ok_o  = ok_r;

  always_ff @(posedge clk_i) begin
    if (!rst_ni || clear_i) begin
      buf_r  <= '0;
      idx    <= 0;
      cnt_r  <= '0;
      len_r  <= '0;
      dst_r  <= '0;
      src_r  <= '0;
      ok_r   <= 1'b1;
    end else if (tx_en_i) begin
      buf_r <= tb_put_octet(buf_r, idx, tx_d_i);
      idx   <= idx + 1;
    end else if (idx != 0) begin
      // One complete frame just ended.  idx counts wire octets:
      // 8 preamble/SFD + client_len client octets + 4 FCS.
      client_len = idx - 12;
      cnt_r <= cnt_r + 16'd1;
      len_r <= 12'(client_len);
      dst_r <= {tb_get_octet(buf_r, 8),  tb_get_octet(buf_r, 9),
                tb_get_octet(buf_r, 10), tb_get_octet(buf_r, 11),
                tb_get_octet(buf_r, 12), tb_get_octet(buf_r, 13)};
      src_r <= {tb_get_octet(buf_r, 14), tb_get_octet(buf_r, 15),
                tb_get_octet(buf_r, 16), tb_get_octet(buf_r, 17),
                tb_get_octet(buf_r, 18), tb_get_octet(buf_r, 19)};

      pre_ok = 1'b1;
      for (k = 0; k < 7; k++) begin
        if (tb_get_octet(buf_r, k) != 8'h55) pre_ok = 1'b0;
      end
      if (tb_get_octet(buf_r, 7) != 8'hD5) pre_ok = 1'b0;

      want_fcs = tb_crc32(buf_r, client_len, 8);
      got_fcs  = {tb_get_octet(buf_r, idx-1), tb_get_octet(buf_r, idx-2),
                  tb_get_octet(buf_r, idx-3), tb_get_octet(buf_r, idx-4)};
      fcs_ok   = (want_fcs == got_fcs);
      ok_r     = ok_r && pre_ok && fcs_ok;
      idx      <= 0;
    end
  end
endmodule : es_pl_gmii_mon
