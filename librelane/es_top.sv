// ============================================================================
//  File        : es_top.sv
//  Description : Pad-level top for the LibreLane (sky130A) physical flow.
//                It exposes every pad pin of the switch and instantiates
//                es_gmii_top, wiring each pad straight through.
//
//                The pad-facing pins are unpacked arrays (logic sig[N]) with
//                one element per port, matching es_gmii_top.  No logic is
//                inserted here: es_top exists to give the physical flow a
//                single, stable top-level boundary around the GMII core.
// ============================================================================
`timescale 1ns/1ps

`ifndef ES_TOP_SV
`define ES_TOP_SV

`default_nettype none

`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_top #(
  parameter int unsigned NUM_PORTS             = ES_DEFAULT_NUM_PORTS,
  parameter int unsigned CLK_FREQ_HZ           = 125_000_000,
  parameter logic [NUM_PORTS*48-1:0] PORT_MAC  = '0,
  parameter logic [NUM_PORTS*2-1:0] PORT_SPEED = {NUM_PORTS{2'd2}},
  parameter int unsigned MIN_FRAME_LEN         = ES_PL_DEF_MIN_FRAME_LEN,
  parameter int unsigned MAX_FRAME_LEN         = ES_PL_DEF_MAX_FRAME_LEN,
  parameter int unsigned SLOTS                 = ES_PL_DEF_SLOTS,
  parameter int unsigned SLOT_BYTES            = ES_PL_DEF_SLOT_BYTES,
  parameter int unsigned DESC_DEPTH            = ES_PL_DEF_DESC_DEPTH,
  parameter int unsigned TX_QUEUE_DEPTH        = ES_PL_DEF_TX_QUEUE_DEPTH,
  parameter int unsigned CAM_SETS              = ES_PL_DEF_CAM_SETS,
  parameter int unsigned CAM_WAYS              = ES_PL_DEF_CAM_WAYS,
  parameter int unsigned LEARNING_EN           = 1,
  parameter logic [1:0] FLOOD_MODE             = 2'd1,
  parameter int unsigned IFG_OCTETS            = 12
) (
  input  var logic       clk_i,  ///< core clock pad
  input  var logic       rst_ni,  ///< active-low synchronous reset pad
  input      logic       link_up_i[NUM_PORTS],  ///< per-port link-up gate pad

  input      logic       gmii_rx_en_i[NUM_PORTS],  ///< GMII receive enable pads, one per port
  input      logic [7:0] gmii_rx_data_i[NUM_PORTS],  ///< GMII receive octet pads, one per port
  output     logic       gmii_tx_en_o[NUM_PORTS],  ///< GMII transmit enable pads, one per port
  output     logic [7:0] gmii_tx_data_o[NUM_PORTS]  ///< GMII transmit octet pads, one per port
);

  es_gmii_top #(
    .NUM_PORTS      (NUM_PORTS),
    .CLK_FREQ_HZ    (CLK_FREQ_HZ),
    .PORT_MAC       (PORT_MAC),
    .PORT_SPEED     (PORT_SPEED),
    .MIN_FRAME_LEN  (MIN_FRAME_LEN),
    .MAX_FRAME_LEN  (MAX_FRAME_LEN),
    .SLOTS          (SLOTS),
    .SLOT_BYTES     (SLOT_BYTES),
    .DESC_DEPTH     (DESC_DEPTH),
    .TX_QUEUE_DEPTH (TX_QUEUE_DEPTH),
    .CAM_SETS       (CAM_SETS),
    .CAM_WAYS       (CAM_WAYS),
    .LEARNING_EN    (LEARNING_EN),
    .FLOOD_MODE     (FLOOD_MODE),
    .IFG_OCTETS     (IFG_OCTETS)
  ) u_gmii_top (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .link_up_i      (link_up_i),
    .gmii_rx_en_i   (gmii_rx_en_i),
    .gmii_rx_data_i (gmii_rx_data_i),
    .gmii_tx_en_o   (gmii_tx_en_o),
    .gmii_tx_data_o (gmii_tx_data_o)
  );

endmodule : es_top

`default_nettype wire

`endif  // ES_TOP_SV
