// ============================================================================
//  File        : es_switch_gmii.sv
//  Description : Top-level GMII front-end wrapper around the interface-agnostic
//                switch core (`es_switch_core`).  GMII is octet-aligned - one
//                8-bit octet per octet time - so the physical pins already
//                carry the canonical octet stream and this wrapper simply
//                passes them through to the core; no symbol adapter is needed.
//
//                Selecting this module as the elaborated top connects the
//                switch to a GMII PHY.  For the MII / RMII pin front-ends use
//                `es_switch_mii` / `es_switch_rmii` instead; the switching
//                datapath behind all three is identical.
//
//                See es_switch_core.sv for the parameter encoding and the
//                octet-stream contract.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef ES_SWITCH_GMII_SV
`define ES_SWITCH_GMII_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_switch_gmii #(
  // ---- topology ------------------------------------------------------------
  /// Number of Ethernet ports.  Any value >= 1 is supported.
  parameter int unsigned                    NUM_PORTS   = SW_DEFAULT_NUM_PORTS,
  /// Core clock frequency in Hz.  Must be >= the 1000BASE-T octet rate
  /// (125 MHz for full line rate); a slower core simply stretches the octet
  /// clock enables and loses line rate, nothing else.
  parameter int unsigned                    CLK_FREQ_HZ = 125_000_000,
  /// Per-port MAC addresses, 48 bits per port, port p at bits [48*p +: 48].
  /// A port left at all zero gets the locally administered address
  /// 02:00:00:00:00:<p>.
  parameter logic        [NUM_PORTS*48-1:0] PORT_MAC    = '0,
  /// Per-port link speed, 2 bits per port, port p at bits [2*p +: 2]:
  /// 0 = 10 Mbit/s, 1 = 100 Mbit/s, 2 = 1000 Mbit/s, 3 = administratively
  /// down.  Defaults to 1000 Mbit/s on every port.
  parameter logic        [ NUM_PORTS*2-1:0] PORT_SPEED  = {NUM_PORTS{2'd2}},

  /// Telemetry publication interval in milliseconds, rounded up to a clock.
  parameter int unsigned REFRESH_INTERVAL_MS = 500,

  // ---- buffer sizing -------------------------------------------------------
  /// Payload beats buffered per ingress port.  Must be >= ceil(MAX_FRAME_LEN/8)
  /// (190 for the default 1518 octet maximum) or maximum-length frames are
  /// reported as ingress overflow.
  parameter int unsigned RX_FIFO_DEPTH  = 256,
  /// Egress beats buffered per port.  Same sizing rule as RX_FIFO_DEPTH.
  parameter int unsigned TX_FIFO_DEPTH  = 256,
  /// Frame descriptors buffered per ingress port.
  parameter int unsigned TAG_FIFO_DEPTH = 16,
  /// Elastic beat FIFO between the octet adapter and the parser.
  parameter int unsigned WF_DEPTH       = 16,

  // ---- switching fabric ----------------------------------------------------
  /// Largest frame accepted, in octets, FCS excluded.
  parameter int unsigned       MAX_FRAME_LEN = 1518,
  /// 0 = block unknown unicast, 1 = flood it, 2 = flood unknown group too.
  parameter logic        [1:0] FLOOD_MODE    = 2'd1,
  /// Source address learning default.
  parameter logic              LEARNING_EN   = 1'b1,
  /// Cycles a head-of-line frame may wait at a congested egress before it is
  /// dropped.  0 stalls forever and never drops.
  parameter int unsigned       STALL_LIMIT   = 0,

  // ---- forwarding address table -------------------------------------------
  parameter int unsigned CAM_SETS       = 128,
  parameter int unsigned CAM_WAYS       = 4,
  parameter logic        CAM_AGE_EN     = 1'b0,
  /// Clocks between two ageing steps.  The effective idle timeout is
  /// CAM_AGE_CYCLES * CAM_SETS * CAM_WAYS * (CAM_AGE_LIMIT + 1) clocks.
  parameter int unsigned CAM_AGE_CYCLES = 1_000_000,
  parameter int unsigned CAM_AGE_LIMIT  = 4
) (
  input var logic clk_i,
  input var logic rst_ni, ///< active-low reset

  // ---- control -------------------------------------------------------------
  input var logic [NUM_PORTS-1:0] link_up_i,      ///< port is enabled
  input var logic [          1:0] flood_mode_i,
  input var logic                 learning_en_i,
  input var logic                 cfg_ovr_i,      ///< use run-time config
  input var logic                 cam_flush_i,    ///< flush the CAM

  // ---- GMII front-end pins -------------------------------------------------
  input var logic [  NUM_PORTS-1:0] gmii_rx_en_i,
  input var logic [NUM_PORTS*8-1:0] gmii_rx_data_i,
  output    logic [  NUM_PORTS-1:0] gmii_tx_en_o,
  output    logic [NUM_PORTS*8-1:0] gmii_tx_data_o,

  // Telemetry PHY metadata is independent of the administrative link enable.
  input var logic [NUM_PORTS*8-1:0] phy_status_i,
  input var logic mon_req_i,
  input var logic [31:0] mon_addr_i,
  output logic mon_ready_o, mon_valid_o,
  output logic [31:0] mon_data_o,

  // ---- observability -------------------------------------------------------
  output logic [32*SW_STAT_COUNT-1:0] stat_o
);

  // GMII is octet-aligned: the pins already carry the canonical octet stream,
  // so they are passed straight through to the interface-agnostic core.
  es_switch_core #(
    .NUM_PORTS          (NUM_PORTS),
    .REFRESH_INTERVAL_MS(REFRESH_INTERVAL_MS),
    .CLK_FREQ_HZ        (CLK_FREQ_HZ),
    .PORT_MAC           (PORT_MAC),
    .PORT_SPEED         (PORT_SPEED),
    .RX_FIFO_DEPTH      (RX_FIFO_DEPTH),
    .TX_FIFO_DEPTH      (TX_FIFO_DEPTH),
    .TAG_FIFO_DEPTH     (TAG_FIFO_DEPTH),
    .WF_DEPTH           (WF_DEPTH),
    .MAX_FRAME_LEN      (MAX_FRAME_LEN),
    .FLOOD_MODE         (FLOOD_MODE),
    .LEARNING_EN        (LEARNING_EN),
    .STALL_LIMIT        (STALL_LIMIT),
    .CAM_SETS           (CAM_SETS),
    .CAM_WAYS           (CAM_WAYS),
    .CAM_AGE_EN         (CAM_AGE_EN),
    .CAM_AGE_CYCLES     (CAM_AGE_CYCLES),
    .CAM_AGE_LIMIT      (CAM_AGE_LIMIT)
  ) u_core (
    .phy_status_i (phy_status_i),
    .mon_req_i    (mon_req_i),
    .mon_addr_i   (mon_addr_i),
    .mon_ready_o  (mon_ready_o),
    .mon_valid_o  (mon_valid_o),
    .mon_data_o   (mon_data_o),
    .clk_i        (clk_i),
    .rst_ni       (rst_ni),
    .link_up_i    (link_up_i),
    .flood_mode_i (flood_mode_i),
    .learning_en_i(learning_en_i),
    .cfg_ovr_i    (cfg_ovr_i),
    .cam_flush_i  (cam_flush_i),
    .rx_oct_en_i  (gmii_rx_en_i),
    .rx_oct_data_i(gmii_rx_data_i),
    .tx_oct_en_o  (gmii_tx_en_o),
    .tx_oct_data_o(gmii_tx_data_o),
    .stat_o       (stat_o)
  );

endmodule : es_switch_gmii

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_SWITCH_GMII_SV
