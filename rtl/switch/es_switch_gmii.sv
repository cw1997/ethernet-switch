// ============================================================================
//  File        : es_switch_gmii.sv
//  Description : GMII top - N MAC adapters plus the staged switch fabric.
//
//                Pure switching logic.  There is no console, panel, statistics,
//                LED, DIP or CAM read-back port: FLOOD_MODE and LEARNING_EN are
//                elaboration parameters and link_up_i is only a data gate.
//                The PHY pin names are unchanged from the legacy top so a board
//                shell or a bus functional model can be reused as-is.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_SWITCH_GMII_SV
`define ES_SWITCH_GMII_SV

`default_nettype none

`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_switch_gmii #(
  parameter int unsigned NUM_PORTS      = SW_DEFAULT_NUM_PORTS,
  parameter int unsigned CLK_FREQ_HZ    = 125_000_000,
  parameter logic [NUM_PORTS*48-1:0] PORT_MAC   = '0,
  parameter logic [NUM_PORTS*2-1:0]  PORT_SPEED = {NUM_PORTS{2'd2}},
  parameter int unsigned MIN_FRAME_LEN  = SW_PL_DEF_MIN_FRAME_LEN,
  parameter int unsigned MAX_FRAME_LEN  = SW_PL_DEF_MAX_FRAME_LEN,
  parameter int unsigned SLOTS          = SW_PL_DEF_SLOTS,
  parameter int unsigned SLOT_BYTES     = SW_PL_DEF_SLOT_BYTES,
  parameter int unsigned DESC_DEPTH     = SW_PL_DEF_DESC_DEPTH,
  parameter int unsigned TX_QUEUE_DEPTH = SW_PL_DEF_TX_QUEUE_DEPTH,
  parameter int unsigned CAM_SETS       = SW_PL_DEF_CAM_SETS,
  parameter int unsigned CAM_WAYS       = SW_PL_DEF_CAM_WAYS,
  parameter int unsigned LEARNING_EN    = 1,
  parameter logic [1:0]  FLOOD_MODE     = 2'd1,
  parameter int unsigned IFG_OCTETS     = 12
) (
  input  var logic                       clk_i,
  input  var logic                       rst_ni,
  input  var logic [NUM_PORTS-1:0]       link_up_i,

  input  var logic [NUM_PORTS-1:0]       gmii_rx_en_i,
  input  var logic [NUM_PORTS*8-1:0]     gmii_rx_data_i,
  output      logic [NUM_PORTS-1:0]      gmii_tx_en_o,
  output      logic [NUM_PORTS*8-1:0]    gmii_tx_data_o
);

  logic [NUM_PORTS-1:0]   rx_valid;
  logic [NUM_PORTS-1:0]   rx_ready;
  logic [NUM_PORTS*8-1:0] rx_data;
  logic [NUM_PORTS-1:0]   rx_sof;
  logic [NUM_PORTS-1:0]   rx_eof;
  logic [NUM_PORTS-1:0]   rx_err;

  logic [NUM_PORTS-1:0]   tx_valid;
  logic [NUM_PORTS-1:0]   tx_ready;
  logic [NUM_PORTS*8-1:0] tx_data;
  logic [NUM_PORTS-1:0]   tx_sof;
  logic [NUM_PORTS-1:0]   tx_eof;

  // Quartus rejects the inline `for (genvar g = 0; ...)` form, so the genvar
  // is declared on its own (AGENTS.md 2.4).
  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_port
      localparam int unsigned BP_G =
          sw_byte_period(CLK_FREQ_HZ, sw_speed_e'(PORT_SPEED[g*2 +: 2]));

      es_mac_gmii_adapt #(
        .BYTE_PERIOD    (BP_G),
        .IFG_OCTETS     (IFG_OCTETS),
        .MIN_CLIENT_LEN (MIN_FRAME_LEN)
      ) u_adapt (
        .clk_i      (clk_i),   .rst_ni     (rst_ni),
        .gmii_rx_en_i(gmii_rx_en_i[g]), .gmii_rx_d_i(gmii_rx_data_i[g*8 +: 8]),
        .gmii_tx_en_o(gmii_tx_en_o[g]), .gmii_tx_d_o(gmii_tx_data_o[g*8 +: 8]),
        .rx_valid_o (rx_valid[g]), .rx_ready_i(rx_ready[g]),
        .rx_data_o  (rx_data[g*8 +: 8]), .rx_sof_o(rx_sof[g]),
        .rx_eof_o   (rx_eof[g]),   .rx_err_o  (rx_err[g]),
        .tx_valid_i (tx_valid[g]), .tx_ready_o(tx_ready[g]),
        .tx_data_i  (tx_data[g*8 +: 8]), .tx_sof_i(tx_sof[g]),
        .tx_eof_i   (tx_eof[g])
      );
    end
  endgenerate

  es_switch_fabric #(
    .NUM_PORTS      (NUM_PORTS),
    .PORT_MAC       (PORT_MAC),
    .MIN_FRAME_LEN  (MIN_FRAME_LEN),
    .MAX_FRAME_LEN  (MAX_FRAME_LEN),
    .SLOTS          (SLOTS),
    .SLOT_BYTES     (SLOT_BYTES),
    .DESC_DEPTH     (DESC_DEPTH),
    .TX_QUEUE_DEPTH (TX_QUEUE_DEPTH),
    .CAM_SETS       (CAM_SETS),
    .CAM_WAYS       (CAM_WAYS),
    .LEARNING_EN    (LEARNING_EN),
    .FLOOD_MODE     (FLOOD_MODE)
  ) u_fabric (
    .clk_i      (clk_i),       .rst_ni    (rst_ni),
    .link_up_i  (link_up_i),
    .rx_valid_i (rx_valid),    .rx_ready_o(rx_ready),
    .rx_data_i  (rx_data),     .rx_sof_i  (rx_sof),
    .rx_eof_i   (rx_eof),      .rx_err_i  (rx_err),
    .tx_valid_o (tx_valid),    .tx_ready_i(tx_ready),
    .tx_data_o  (tx_data),     .tx_sof_o  (tx_sof),
    .tx_eof_o   (tx_eof)
  );

endmodule : es_switch_gmii

`default_nettype wire

`endif  // ES_SWITCH_GMII_SV
