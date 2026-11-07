// ============================================================================
//  File        : es_console_cmd_port.sv
//  Description : Select one zero-based port for the shared snapshot engine.
//
//                start_i launches one response.  busy_o and done_o report the
//                shared engine only while this command owns it, so the
//                dispatcher can leave the engine running for another command
//                without mistaking its completion for its own.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_CONSOLE_CMD_PORT_SV
`define ES_CONSOLE_CMD_PORT_SV

`default_nettype none

`include "es_defs.sv"
`default_nettype none

module es_console_cmd_port (
  /// start_i begins a request; selected_i scopes shared-engine status to it.
  input var logic start_i, selected_i, engine_busy_i, engine_done_i,
  /// Zero-based port index selected by the command parser.
  input var logic [31:0] port_i,
  /// start_o forwards launch; busy_o and done_o are owner-qualified.
  output    logic start_o, busy_o, done_o,
  /// One-based monitor page range corresponding to the selected port.
  output    logic [31:0] first_page_o, last_page_o);

  assign start_o      = start_i;
  assign busy_o       = selected_i && engine_busy_i;
  assign done_o       = selected_i && engine_done_i;
  // Page zero is the aggregate record, so port p lives on page p+1.
  assign first_page_o = port_i + 32'd1;
  assign last_page_o  = port_i + 32'd1;

endmodule : es_console_cmd_port

`default_nettype wire

`endif  // ES_CONSOLE_CMD_PORT_SV
