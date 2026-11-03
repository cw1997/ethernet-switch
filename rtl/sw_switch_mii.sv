// ============================================================================
//  File        : sw_switch_mii.sv
//  Description : Top-level MII front-end wrapper around the interface-agnostic
//                switch core (`sw_switch_core`).  MII carries two 4-bit
//                nibbles per octet time, so each port's pins are assembled /
//                serialised onto the canonical octet stream by a `sw_mii`
//                symbol adapter before reaching the core.
//
//                Selecting this module as the elaborated top connects the
//                switch to an MII PHY.  MII is a 10/100 Mbit/s front-end only:
//                a port configured for 1000 Mbit/s is rejected at elaboration
//                time.  Use `sw_switch_gmii` for 1000 Mbit/s ports, or
//                `sw_switch_rmii` for the two-wire front-end.
//
//                See sw_switch_core.sv for the parameter encoding and the
//                octet-stream contract.
// ============================================================================
// ---------------------------------------------------------------------------
//  Time resolution: the RTL carries no timing, but a declared timescale keeps
//  the design free of `timescale warnings in mixed RTL/testbench compiles.
// ---------------------------------------------------------------------------
`timescale 1ns/1ps

`ifndef SW_SWITCH_MII_SV
`define SW_SWITCH_MII_SV

// Any name used in this file that is not declared is a typo - most likely in a
// port connection - and `default_nettype none` makes it an elaboration error
// instead of an implicit one-bit net that quietly carries X through the whole
// design.  Restored at the end of the file; the rationale is in AGENTS.md.
`default_nettype none

`include "sw_defs.sv"

module sw_switch_mii #(
  // ---- topology ------------------------------------------------------------
  /// Number of Ethernet ports.  Any value >= 1 is supported.
  parameter int unsigned NUM_PORTS      = 4,
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
  input  logic                                clk_i,
  input  logic                                rst_ni,   ///< active-low reset

  // ---- control -------------------------------------------------------------
  input  logic [NUM_PORTS-1:0]                link_up_i,   ///< port is enabled
  input  logic [1:0]                          flood_mode_i,
  input  logic                                learning_en_i,
  input  logic                                cfg_ovr_i,   ///< use run-time config
  input  logic                                cam_flush_i, ///< flush the CAM

  // ---- MII front-end pins --------------------------------------------------
  input  logic [NUM_PORTS-1:0]                mii_rx_dv_i,
  input  logic [NUM_PORTS-1:0]                mii_rx_er_i,
  input  logic [NUM_PORTS*4-1:0]              mii_rxd_i,
  output logic [NUM_PORTS-1:0]                mii_tx_en_o,
  output logic [NUM_PORTS-1:0]                mii_tx_er_o,
  output logic [NUM_PORTS*4-1:0]              mii_txd_o,

  // ---- observability -------------------------------------------------------
  output logic [32*SW_STAT_COUNT-1:0]         stat_o
);

  // The canonical octet stream between the per-port symbol adapters and the
  // interface-agnostic core.
  logic [NUM_PORTS-1:0]   rx_oct_en;
  logic [NUM_PORTS*8-1:0] rx_oct_data;
  logic [NUM_PORTS-1:0]   tx_oct_en;
  logic [NUM_PORTS*8-1:0] tx_oct_data;

  // Elaboration-time sanity checks (excluded from synthesis).  MII is a
  // 10/100 Mbit/s front-end: it cannot carry a 1000 Mbit/s octet stream.
`ifndef SYNTHESIS
  initial begin
    for (int unsigned p = 0; p < NUM_PORTS; p++) begin
      if (sw_speed_e'(PORT_SPEED[p*2 +: 2]) == SW_SPEED_1000M) begin
        $error("sw_switch_mii: port %0d is configured for 1000 Mbit/s, which the MII front-end cannot carry", p);
      end
    end
  end
`endif

  sw_switch_core #(
      .NUM_PORTS      (NUM_PORTS),
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

  // Per-port symbol adapters: nibble pairs <-> canonical octets.
  // Quartus's parser rejects the SV inline form `for (genvar g = 0; ...)` and
  // also rejects a bare module-level `for` - every loop carries an explicit
  // `generate`/`endgenerate` wrapper; yosys, Verilator and Icarus accept
  // all forms (see sw_arbiter.sv for the full note).
  genvar g;
  generate
  for (g = 0; g < NUM_PORTS; g++) begin : g_port
    localparam int unsigned BP_G =
        sw_byte_period(CLK_FREQ_HZ, sw_speed_e'(PORT_SPEED[g*2 +: 2]));

    sw_mii #(
        .BYTE_PERIOD (BP_G)
    ) u_fe (
        .clk_i       (clk_i),
        .rst_ni      (rst_ni),
        .mii_rx_dv_i (mii_rx_dv_i[g]),
        .mii_rx_er_i (mii_rx_er_i[g]),
        .mii_rxd_i   (mii_rxd_i[g*4 +: 4]),
        .mii_tx_en_o (mii_tx_en_o[g]),
        .mii_tx_er_o (mii_tx_er_o[g]),
        .mii_txd_o   (mii_txd_o[g*4 +: 4]),
        .oct_en_o    (rx_oct_en[g]),
        .oct_d_o     (rx_oct_data[g*8 +: 8]),
        .oct_en_i    (tx_oct_en[g]),
        .oct_d_i     (tx_oct_data[g*8 +: 8])
    );
  end
  endgenerate

endmodule : sw_switch_mii

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif // SW_SWITCH_MII_SV
