// ============================================================================
//  File        : es_switch_rmii.sv
//  Description : Top-level RMII front-end wrapper around the interface-agnostic
//                switch core (`es_switch_core`).  RMII carries four 2-bit
//                chunks per octet time, so each port's pins are assembled /
//                serialised onto the canonical octet stream by a `es_switch_rmii`
//                symbol adapter before reaching the core.
//
//                Selecting this module as the elaborated top connects the
//                switch to an RMII PHY.  RMII is a 10/100 Mbit/s front-end
//                only: a port configured for 1000 Mbit/s is rejected at
//                elaboration time.  Use `es_switch_gmii` for 1000 Mbit/s
//                ports, or `es_switch_mii` for the nibble-wide front-end.
//
//                See es_switch_core.sv for the parameter encoding and the
//                octet-stream contract.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef ES_SWITCH_RMII_SV
`define ES_SWITCH_RMII_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_switch_rmii #(
  // ---- topology ------------------------------------------------------------
  /// Number of Ethernet ports.  Any value >= 1 is supported.
  parameter int unsigned NUM_PORTS      = SW_DEFAULT_NUM_PORTS,
  /// Core clock frequency in Hz.  Must be >= the 1000BASE-T octet rate
  /// (125 MHz for full line rate); a slower core simply stretches the octet
  /// clock enables and loses line rate, nothing else.
  parameter int unsigned CLK_FREQ_HZ     = 125_000_000,
  /// Per-port MAC addresses, 48 bits per port, port p at bits [48*p +: 48].
  /// A port left at all zero gets the locally administered address
  /// 02:00:00:00:00:<p>.
  parameter logic [NUM_PORTS*48-1:0]  PORT_MAC   = '0,
  /// Per-port link speed, 2 bits per port, port p at bits [2*p +: 2]:
  /// 0 = 10 Mbit/s, 1 = 100 Mbit/s, 2 = 1000 Mbit/s, 3 = administratively
  /// down.  Defaults to 1000 Mbit/s on every port.
  parameter logic [NUM_PORTS*2-1:0]    PORT_SPEED = {NUM_PORTS{2'd2}},

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
  parameter int unsigned MAX_FRAME_LEN  = 1518,
  /// 0 = block unknown unicast, 1 = flood it, 2 = flood unknown group too.
  parameter logic [1:0]  FLOOD_MODE     = 2'd1,
  /// Source address learning default.
  parameter logic        LEARNING_EN    = 1'b1,
  /// Cycles a head-of-line frame may wait at a congested egress before it is
  /// dropped.  0 stalls forever and never drops.
  parameter int unsigned STALL_LIMIT    = 0,

  // ---- forwarding address table -------------------------------------------
  parameter int unsigned CAM_SETS       = 128,
  parameter int unsigned CAM_WAYS       = 4,
  parameter logic        CAM_AGE_EN     = 1'b0,
  /// Clocks between two ageing steps.  The effective idle timeout is
  /// CAM_AGE_CYCLES * CAM_SETS * CAM_WAYS * (CAM_AGE_LIMIT + 1) clocks.
  parameter int unsigned CAM_AGE_CYCLES = 1_000_000,
  parameter int unsigned CAM_AGE_LIMIT  = 4
) (
  input  var logic                                clk_i,
  input  var logic                                rst_ni,   ///< active-low reset

  // ---- control -------------------------------------------------------------
  input  var logic [NUM_PORTS-1:0]                link_up_i,   ///< port is enabled
  input  var logic [1:0]                          flood_mode_i,
  input  var logic                                learning_en_i,
  input  var logic                                cfg_ovr_i,   ///< use run-time config
  input  var logic                                cam_flush_i, ///< flush the CAM

  // ---- RMII front-end pins -------------------------------------------------
  input  var logic [NUM_PORTS-1:0]                rmii_crs_dv_i,
  input  var logic [NUM_PORTS*2-1:0]              rmii_rxd_i,
  output logic [NUM_PORTS-1:0]                rmii_tx_en_o,
  output logic [NUM_PORTS*2-1:0]              rmii_txd_o,

  // Telemetry PHY metadata is independent of the administrative link enable.
  input var logic [NUM_PORTS*8-1:0] phy_status_i,
  input var logic mon_req_i,
  input var logic [31:0] mon_addr_i,
  output logic mon_ready_o, mon_valid_o,
  output logic [31:0] mon_data_o,

  // ---- observability -------------------------------------------------------
  output logic [32*SW_STAT_COUNT-1:0]         stat_o
);

  // The canonical octet stream between the per-port symbol adapters and the
  // interface-agnostic core.
  logic [NUM_PORTS-1:0]   rx_oct_en;
  logic [NUM_PORTS*8-1:0] rx_oct_data;
  logic [NUM_PORTS-1:0]   tx_oct_en;
  logic [NUM_PORTS*8-1:0] tx_oct_data;

  // Elaboration-time sanity checks (excluded from synthesis).  RMII is a
  // 10/100 Mbit/s front-end: it cannot carry a 1000 Mbit/s octet stream.
`ifndef SYNTHESIS
  initial begin
    for (int unsigned p = 0; p < NUM_PORTS; p++) begin
      if (sw_speed_e'(PORT_SPEED[p*2 +: 2]) == SW_SPEED_1000M) begin
        $error("es_switch_rmii: port %0d is configured for 1000 Mbit/s, which the RMII front-end cannot carry", p);
      end
    end
  end
`endif

  es_switch_core #(
      .NUM_PORTS      (NUM_PORTS),
      .REFRESH_INTERVAL_MS (REFRESH_INTERVAL_MS),
      .CLK_FREQ_HZ    (CLK_FREQ_HZ),
      .PORT_MAC       (PORT_MAC),
      .PORT_SPEED     (PORT_SPEED),
      .RX_FIFO_DEPTH  (RX_FIFO_DEPTH),
      .TX_FIFO_DEPTH  (TX_FIFO_DEPTH),
      .TAG_FIFO_DEPTH (TAG_FIFO_DEPTH),
      .WF_DEPTH       (WF_DEPTH),
      .MAX_FRAME_LEN  (MAX_FRAME_LEN),
      .FLOOD_MODE     (FLOOD_MODE),
      .LEARNING_EN    (LEARNING_EN),
      .STALL_LIMIT    (STALL_LIMIT),
      .CAM_SETS       (CAM_SETS),
      .CAM_WAYS       (CAM_WAYS),
      .CAM_AGE_EN     (CAM_AGE_EN),
      .CAM_AGE_CYCLES (CAM_AGE_CYCLES),
      .CAM_AGE_LIMIT  (CAM_AGE_LIMIT)
  ) u_core (
      .phy_status_i (phy_status_i),
      .mon_req_i (mon_req_i), .mon_addr_i (mon_addr_i),
      .mon_ready_o (mon_ready_o), .mon_valid_o (mon_valid_o), .mon_data_o (mon_data_o),
      .clk_i         (clk_i),
      .rst_ni        (rst_ni),
      .link_up_i     (link_up_i),
      .flood_mode_i  (flood_mode_i),
      .learning_en_i (learning_en_i),
      .cfg_ovr_i     (cfg_ovr_i),
      .cam_flush_i   (cam_flush_i),
      .rx_oct_en_i   (rx_oct_en),
      .rx_oct_data_i (rx_oct_data),
      .tx_oct_en_o   (tx_oct_en),
      .tx_oct_data_o (tx_oct_data),
      .stat_o        (stat_o)
  );

  // Per-port symbol adapters: 2-bit chunks <-> canonical octets.
  // Quartus's parser rejects the SV inline form `for (genvar g = 0; ...)` and
  // also rejects a bare module-level `for` - every loop carries an explicit
  // `generate`/`endgenerate` wrapper; yosys, Verilator and Icarus accept
  // all forms (see es_switch_arbiter.sv for the full note).
  genvar g;
  generate
  for (g = 0; g < NUM_PORTS; g++) begin : g_port
    localparam int unsigned BP_G =
        sw_byte_period(CLK_FREQ_HZ, sw_speed_e'(PORT_SPEED[g*2 +: 2]));

    es_switch_rmii_adapter #(
        .BYTE_PERIOD (BP_G)
    ) u_fe (
        .clk_i         (clk_i),
        .rst_ni        (rst_ni),
        .rmii_crs_dv_i (rmii_crs_dv_i[g]),
        .rmii_rxd_i    (rmii_rxd_i[g*2 +: 2]),
        .rmii_tx_en_o  (rmii_tx_en_o[g]),
        .rmii_txd_o    (rmii_txd_o[g*2 +: 2]),
        .oct_en_o      (rx_oct_en[g]),
        .oct_d_o       (rx_oct_data[g*8 +: 8]),
        .oct_en_i      (tx_oct_en[g]),
        .oct_d_i       (tx_oct_data[g*8 +: 8])
    );
  end
  endgenerate

endmodule : es_switch_rmii

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif // ES_SWITCH_RMII_SV
