// ============================================================================
//  File        : es_fabric_mon.sv
//  Description : Independent per-egress wire monitor for the staged fabric.
//                Reconstructs frame length, byte checksum and both MAC
//                addresses from the byte stream, so a dropped, duplicated,
//                misrouted or corrupted frame is caught without any
//                run-time-indexed unpacked storage in the testbench.
// ============================================================================
`timescale 1ns/1ps

`include "es_defs.sv"

module es_fabric_mon (
  input  var logic        clk_i,
  input  var logic        rst_ni,
  input  var logic        valid_i,
  input  var logic        ready_i,
  input  var logic        sof_i,
  input  var logic        eof_i,
  input  var logic [7:0]  data_i,
  input  var logic        clear_i,
  output logic     [11:0] len_o,
  output logic     [7:0]  sum_o,
  output logic     [47:0] dst_o,
  output logic     [47:0] src_o,
  output logic     [3:0]  cnt_o
);
  logic [11:0] idx;
  logic [11:0] len_r;
  logic [7:0]  sum_r;
  logic [47:0] dst_r;
  logic [47:0] src_r;
  logic [3:0]  cnt_r;

  always_ff @(posedge clk_i) begin
    if (!rst_ni || clear_i) begin
      idx   <= '0;
      len_r <= '0;
      sum_r <= '0;
      dst_r <= '0;
      src_r <= '0;
      cnt_r <= '0;
    end else if (valid_i && ready_i) begin
      if (sof_i) begin
        idx   <= '0;
        sum_r <= '0;
        dst_r <= '0;
        src_r <= '0;
      end
      sum_r <= sum_r + data_i;
      if (idx < 12'd6)      dst_r <= {dst_r[39:0], data_i};
      else if (idx < 12'd12) src_r <= {src_r[39:0], data_i};
      idx <= idx + 12'd1;
      if (eof_i) begin
        len_r <= idx + 12'd1;
        cnt_r <= cnt_r + 4'd1;
      end
    end
  end

  assign len_o = len_r;
  assign sum_o = sum_r;
  assign dst_o = dst_r;
  assign src_o = src_r;
  assign cnt_o = cnt_r;
endmodule : es_fabric_mon
