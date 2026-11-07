// ============================================================================
//  File        : es_console_cmd_port.sv
//  Description : Select one zero-based port for the shared snapshot engine.
//
//                start_i launches one response. busy_o and done_o report the
//                shared engine only while this command owns it.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_CONSOLE_CMD_PORT_SV
`define ES_CONSOLE_CMD_PORT_SV
`default_nettype none
`include "es_defs.sv"
`default_nettype none
module es_console_cmd_port (
  input var logic start_i, selected_i, engine_busy_i, engine_done_i,
  input var logic [31:0] port_i,
  output logic start_o, busy_o, done_o,
  output logic [31:0] first_page_o, last_page_o
);
  assign start_o = start_i;
  assign busy_o = selected_i && engine_busy_i;
  assign done_o = selected_i && engine_done_i;
  assign first_page_o = port_i + 32'd1;
  assign last_page_o = port_i + 32'd1;
endmodule
`default_nettype wire
`endif  // ES_CONSOLE_CMD_PORT_SV
