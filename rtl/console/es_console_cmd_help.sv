// ============================================================================
//  File        : es_console_cmd_help.sv
//  Description : Single-line help response for the ASCII console.
//
//                start_i presents the command while the dispatcher holds it;
//                done_o acknowledges the line when the text buffer is ready;
//                this combinational command has no busy state of its own.
//                The response is left aligned in the 64-byte output word.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_CONSOLE_CMD_HELP_SV
`define ES_CONSOLE_CMD_HELP_SV
`default_nettype none

module es_console_cmd_help (
  input var logic start_i,
  input var logic ready_i,
  output logic valid_o,
  output logic done_o,
  output logic [511:0] text_o
);
  assign valid_o = start_i;
  assign done_o = valid_o && ready_i;
  assign text_o = {"help | status | port <n> | mac all | mac <n>\015\n", 144'd0};
endmodule

`default_nettype wire
`endif  // ES_CONSOLE_CMD_HELP_SV
