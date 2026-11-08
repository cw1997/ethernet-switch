// ============================================================================
//  File        : es_console_command_help.sv
//  Description : The `help` console command: four literal text lines naming the
//                command set.
//
//                A command module emits one response-line descriptor per
//                `line_ack_i` handshake and holds `done_o` after the last line
//                is accepted.  See es_console_port.sv for the dispatcher that
//                selects and renders these lines.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_CONSOLE_COMMAND_HELP_SV
`define ES_CONSOLE_COMMAND_HELP_SV

`default_nettype none

`include "es_defs.sv"
`include "console/es_console_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_console_command_help (
  input var logic        clk_i,
  input var logic        rst_ni,
  input var logic        start_i,
  input var logic        line_ack_i,
  output logic           line_valid_o,
  output logic [12:0]    desc_o,
  output logic           done_o
);

  localparam int unsigned LINE_COUNT = 4;

  logic [6:0] idx_q;
  logic       active_q;

  function automatic logic [12:0] desc_line(input logic [6:0] idx);
    logic        last;
    logic [3:0]  port;
    logic [3:0]  src;
    logic [3:0]  id;
    last = (idx == 7'd3);
    port = 4'd0;
    src  = SW_SRC_TEXT;
    id   = idx[3:0];
    desc_line = {last, port, src, id};
  endfunction

  always_ff @(posedge clk_i) begin
    if (!rst_ni) begin
      active_q     <= 1'b0;
      idx_q        <= '0;
      line_valid_o <= 1'b0;
      done_o       <= 1'b0;
    end else begin
      if (start_i) begin
        active_q     <= 1'b1;
        idx_q        <= '0;
        line_valid_o <= 1'b1;
        done_o       <= 1'b0;
      end else if (active_q && line_ack_i) begin
        if (idx_q == 7'(LINE_COUNT - 1)) begin
          active_q     <= 1'b0;
          line_valid_o <= 1'b0;
          done_o       <= 1'b1;
        end else begin
          idx_q <= idx_q + 7'd1;
        end
      end
    end
  end

  assign desc_o = active_q ? desc_line(idx_q) : 13'd0;

endmodule : es_console_command_help

`default_nettype wire

`endif  // ES_CONSOLE_COMMAND_HELP_SV
