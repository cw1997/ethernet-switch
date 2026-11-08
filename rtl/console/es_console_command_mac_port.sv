// ============================================================================
//  File        : es_console_command_mac_port.sv
//  Description : The `mac <n>` console command: the forwarding-table entries
//                learned on port n, walked by the shared `es_console_cam_walk`
//                with the match-port filter.
//
//                This module is a thin shell that pins `FILTER_ALL` to zero and
//                forwards `arg_i` as the port filter; the traversal itself is
//                `es_console_cam_walk`.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_CONSOLE_COMMAND_MAC_PORT_SV
`define ES_CONSOLE_COMMAND_MAC_PORT_SV

`default_nettype none

`include "es_defs.sv"
`include "console/es_console_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_console_command_mac_port #(
  parameter int unsigned CAM_CAPACITY = 512
) (
  input var logic        clk_i,
  input var logic        rst_ni,
  input var logic        start_i,
  input var logic [3:0]  arg_i,
  input var logic        line_ack_i,
  output logic           line_valid_o,
  output logic [SW_CONSOLE_LINE_BYTES*8-1:0] line_text_o,
  output logic           done_o,
  output logic           cam_claim_o,
  input  var logic       cam_grant_i,
  output logic           cam_rd_req_o,
  output logic [31:0]    cam_rd_index_o,
  input  var logic       cam_rd_valid_i,
  input  var logic [127:0] cam_rd_entry_i
);

  es_console_cam_walk #(
    .CAM_CAPACITY (CAM_CAPACITY),
    .FILTER_ALL   (1'b0)
  ) u_walk (
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .start_i         (start_i),
    .arg_i           (arg_i),
    .line_ack_i      (line_ack_i),
    .line_valid_o    (line_valid_o),
    .line_text_o     (line_text_o),
    .done_o          (done_o),
    .cam_claim_o     (cam_claim_o),
    .cam_grant_i     (cam_grant_i),
    .cam_rd_req_o    (cam_rd_req_o),
    .cam_rd_index_o  (cam_rd_index_o),
    .cam_rd_valid_i  (cam_rd_valid_i),
    .cam_rd_entry_i  (cam_rd_entry_i)
  );

endmodule : es_console_command_mac_port

`default_nettype wire

`endif  // ES_CONSOLE_COMMAND_MAC_PORT_SV
