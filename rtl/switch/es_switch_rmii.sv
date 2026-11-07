// ============================================================================
//  File        : es_switch_rmii.sv
//  Description : RMII switch: one `es_mac_rmii` per port, the interface-agnostic
//                `es_switch_core`, and the board panel.
//
//                Identical in structure to `es_switch_gmii`; only the MAC leaf
//                and its pin group differ.  The switching datapath below the MAC
//                boundary is the same instantiation with the same parameters, so
//                a change made for one interface cannot silently diverge in the
//                other two.
//
//                RMII is a 10/100 Mbit/s front-end, so a port configured for
//                1000 Mbit/s is rejected at elaboration rather than built and
//                found to lose most of every frame.
//
//                See es_switch_core.sv for the parameter encoding and the beat
//                contract, and rtl/mac/es_mac_defs.sv for the boundary itself.
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
`include "mac/es_mac_defs.sv"
`include "switch/es_switch_defs.sv"
`include "panel/es_panel_defs.sv"
`default_nettype none

module es_switch_rmii #(
  // ---- topology ------------------------------------------------------------
  /// Number of Ethernet ports.  Any value >= 1 is supported.
  parameter int unsigned NUM_PORTS   = SW_DEFAULT_NUM_PORTS,
  /// Core clock frequency in Hz.  Determines each port's octet clock enable.
  parameter int unsigned CLK_FREQ_HZ = 125_000_000,
  /// Number of independent console statistic read ports.
  parameter int unsigned NUM_CONSOLE = 1,
  /// Per-port MAC addresses, 48 bits per port, port p at bits [48*p +: 48].
  parameter logic [NUM_PORTS*48-1:0] PORT_MAC = '0,
  /// Per-port link speed, 2 bits per port, port p at bits [2*p +: 2]:
  /// 0 = 10 Mbit/s, 1 = 100 Mbit/s, 3 = administratively down.  2 (1000 Mbit/s)
  /// is rejected at elaboration.
  parameter logic [NUM_PORTS*2-1:0] PORT_SPEED = {NUM_PORTS{2'd1}},

  // ---- buffer sizing -------------------------------------------------------
  /// Payload beats buffered per ingress port.
  parameter int unsigned RX_FIFO_DEPTH  = 256,
  /// Egress beats buffered per port.
  parameter int unsigned TX_FIFO_DEPTH  = 256,
  /// Frame descriptors buffered per ingress port.
  parameter int unsigned TAG_FIFO_DEPTH = 16,
  /// Elastic beat FIFO inside each port's MAC.
  parameter int unsigned WF_DEPTH       = 16,

  // ---- switching fabric ----------------------------------------------------
  /// Largest frame accepted, in octets, FCS excluded.
  parameter int unsigned MAX_FRAME_LEN = 1518,
  /// 0 = block unknown unicast, 1 = flood it, 2 = flood unknown group too.
  parameter logic [1:0] FLOOD_MODE   = 2'd1,
  /// Source address learning default.
  parameter logic       LEARNING_EN  = 1'b1,
  /// Cycles a head-of-line frame may wait at a congested egress before it is
  /// dropped.  0 stalls forever and never drops.
  parameter int unsigned STALL_LIMIT = 0,

  // ---- forwarding address table -------------------------------------------
  /// Number of CAM sets; the table holds CAM_SETS * CAM_WAYS addresses.
  parameter int unsigned CAM_SETS   = 128,
  /// Ways per CAM set.
  parameter int unsigned CAM_WAYS   = 4,
  /// Enable idle-time ageing of learned addresses.
  parameter logic        CAM_AGE_EN = 1'b0,
  /// Clocks between two ageing steps.
  parameter int unsigned CAM_AGE_CYCLES = 1_000_000,
  /// Ageing steps an entry may survive before it is evicted.
  parameter int unsigned CAM_AGE_LIMIT  = 4
) (
  /// One synchronous core clock and active-low reset serve every port.
  input var logic clk_i,
  input var logic rst_ni,

  // ---- control -------------------------------------------------------------
  /// Administrative receive enable, one bit per port.  A port with this bit low
  /// does not accept octets from its PHY, which is how a board keeps a dead or
  /// incompatible link out of the forwarding table.  Transmit is deliberately
  /// *not* gated: a port that stopped draining would stall every ingress that
  /// floods to it, and a frame sent into a dead link is cheaper than a wedged
  /// fabric.
  input var logic [NUM_PORTS-1:0] link_up_i,

  // ---- RMII front-end pins -------------------------------------------------
  /// Packed RMII buses map port zero to the least-significant slice.
  input var logic [NUM_PORTS-1:0]   rmii_crs_dv_i,
  input var logic [NUM_PORTS*2-1:0] rmii_rxd_i,
  output    logic [NUM_PORTS-1:0]   rmii_tx_en_o,
  output    logic [NUM_PORTS*2-1:0] rmii_txd_o,

  /// PHY status bytes, one per port; used for the panel lamps only.
  input var logic [NUM_PORTS*8-1:0] phy_status_i,

  // ---- console read ports --------------------------------------------------
  input var logic [NUM_CONSOLE*sw_port_w(NUM_PORTS)-1:0] stat_port_i,
  input var logic [NUM_CONSOLE*4-1:0]                    stat_id_i,
  output    logic [NUM_CONSOLE*32-1:0]                   stat_data_o,
  input var logic        cam_rd_req_i,
  input var logic [31:0] cam_rd_index_i,
  output    logic        cam_rd_valid_o,
  output    logic [127:0] cam_rd_entry_o,
  output    logic [31:0] cam_entries_o,

  // ---- panel ---------------------------------------------------------------
  /// Board switches, decoded into the run-time configuration.
  input var logic [SW_PANEL_DIP_W-1:0] dip_i,
  /// Semantic status lamps; the board only maps them to physical LEDs.
  output logic [NUM_PORTS-1:0]   led_link_o,
  output logic [NUM_PORTS-1:0]   led_act_o,
  output logic [NUM_PORTS*2-1:0] led_speed_o,
  output logic [NUM_PORTS-1:0]   led_duplex_o,
  output logic [NUM_PORTS-1:0]   led_fault_o,
  output logic [15:0]            led_stat_o,
  /// Configuration actually in force.  Exported so that a console reports what
  /// the switch is doing rather than re-decoding the board switches itself.
  output logic [1:0]             cfg_flood_mode_o,
  output logic                   cfg_learning_en_o,
  output logic                   cfg_ovr_o,

  // ---- observability -------------------------------------------------------
  /// Packed aggregate 32-bit counters indexed by sw_stat_id_e.
  output logic [32*SW_STAT_COUNT-1:0] stat_o
);

  // --------------------------------------------------------------------------
  // Elaboration-time sanity check
  //
  // RMII cannot carry a 1000 Mbit/s octet stream, and a port configured for it
  // would silently lose most of every frame.  The block is excluded from
  // synthesis because yosys has no implementation for `$error` (AGENTS.md 3.4).
  // --------------------------------------------------------------------------
`ifndef SYNTHESIS
  initial begin
    for (int unsigned p = 0; p < NUM_PORTS; p++) begin
      if (sw_speed_e'(PORT_SPEED[p*2 +: 2]) == SW_SPEED_1000M) begin
        $error(
            "es_switch_rmii: port %0d is configured for 1000 Mbit/s, which the RMII front-end cannot carry",
            p);
      end
    end
  end
`endif

  // --------------------------------------------------------------------------
  // Port buses between the MACs and the core
  // --------------------------------------------------------------------------
  logic [NUM_PORTS-1:0]    rx_beat_valid;
  logic [NUM_PORTS*64-1:0] rx_beat_data;
  logic [NUM_PORTS-1:0]    rx_beat_sof;
  logic [NUM_PORTS-1:0]    rx_beat_eof;
  logic [NUM_PORTS-1:0]    rx_beat_crc_ok;
  logic [NUM_PORTS*4-1:0]  rx_beat_octets;
  logic [NUM_PORTS-1:0]    rx_beat_rd;

  logic [NUM_PORTS-1:0]          tx_fr_valid;
  logic [NUM_PORTS*SW_LEN_W-1:0] tx_fr_len;
  logic [NUM_PORTS-1:0]          tx_fr_ready;
  logic [NUM_PORTS-1:0]          tx_beat_valid;
  logic [NUM_PORTS*64-1:0]       tx_beat_data;
  logic [NUM_PORTS-1:0]          tx_beat_rd;

  /// Recent line activity per port, for the panel's activity lamps.
  logic [NUM_PORTS-1:0] port_active;

  // Quartus's parser rejects the SV inline form `for (genvar g = 0; ...)` and a
  // bare module-level `for`; every loop carries an explicit
  // `generate`/`endgenerate` wrapper (AGENTS.md 2.4).
  genvar g;

  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_port
      localparam int unsigned BP_G =
          sw_byte_period(CLK_FREQ_HZ, sw_speed_e'(PORT_SPEED[g*2 +: 2]));

      es_mac_rmii #(
        .BYTE_PERIOD (BP_G),
        .WF_DEPTH    (WF_DEPTH)
      ) u_mac (
        .clk_i            (clk_i),
        .rst_ni           (rst_ni),
        .link_up_i        (link_up_i[g]),
        .rmii_crs_dv_i    (rmii_crs_dv_i[g]),
        .rmii_rxd_i       (rmii_rxd_i[g*2 +: 2]),
        .rmii_tx_en_o     (rmii_tx_en_o[g]),
        .rmii_txd_o       (rmii_txd_o[g*2 +: 2]),
        .rx_beat_valid_o  (rx_beat_valid[g]),
        .rx_beat_data_o   (rx_beat_data[g*64 +: 64]),
        .rx_beat_sof_o    (rx_beat_sof[g]),
        .rx_beat_eof_o    (rx_beat_eof[g]),
        .rx_beat_crc_ok_o (rx_beat_crc_ok[g]),
        .rx_beat_octets_o (rx_beat_octets[g*4 +: 4]),
        .rx_beat_rd_i     (rx_beat_rd[g]),
        .tx_fr_valid_i    (tx_fr_valid[g]),
        .tx_fr_len_i      (tx_fr_len[g*SW_LEN_W +: SW_LEN_W]),
        .tx_fr_ready_o    (tx_fr_ready[g]),
        .tx_beat_valid_i  (tx_beat_valid[g]),
        .tx_beat_data_i   (tx_beat_data[g*64 +: 64]),
        .tx_beat_rd_o     (tx_beat_rd[g])
      );

      assign port_active[g] = rmii_crs_dv_i[g] | rmii_tx_en_o[g];
    end
  endgenerate

  // --------------------------------------------------------------------------
  // Switching fabric
  //
  // The core's run-time control comes from the panel and from nowhere else.
  // --------------------------------------------------------------------------
  logic [1:0] panel_flood_mode;
  logic       panel_learning_en;
  logic       panel_cfg_ovr;
  logic       panel_cam_flush;

  // The decoded configuration is an output as well as an internal signal: the
  // console asks the switch what its policy is, so a second decoder in a board
  // file could never drift out of step with this one.
  assign cfg_flood_mode_o  = panel_flood_mode;
  assign cfg_learning_en_o = panel_learning_en;
  assign cfg_ovr_o         = panel_cfg_ovr;

  es_switch_core #(
    .NUM_PORTS      (NUM_PORTS),
    .NUM_CONSOLE    (NUM_CONSOLE),
    .PORT_MAC       (PORT_MAC),
    .RX_FIFO_DEPTH  (RX_FIFO_DEPTH),
    .TX_FIFO_DEPTH  (TX_FIFO_DEPTH),
    .TAG_FIFO_DEPTH (TAG_FIFO_DEPTH),
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
    .clk_i           (clk_i),
    .rst_ni          (rst_ni),
    .flood_mode_i    (panel_flood_mode),
    .learning_en_i   (panel_learning_en),
    .cfg_ovr_i       (panel_cfg_ovr),
    .cam_flush_i     (panel_cam_flush),
    .rx_beat_valid_i (rx_beat_valid),
    .rx_beat_data_i  (rx_beat_data),
    .rx_beat_sof_i   (rx_beat_sof),
    .rx_beat_eof_i   (rx_beat_eof),
    .rx_beat_crc_ok_i(rx_beat_crc_ok),
    .rx_beat_octets_i(rx_beat_octets),
    .rx_beat_rd_o    (rx_beat_rd),
    .tx_fr_valid_o   (tx_fr_valid),
    .tx_fr_len_o     (tx_fr_len),
    .tx_fr_ready_i   (tx_fr_ready),
    .tx_beat_valid_o (tx_beat_valid),
    .tx_beat_data_o  (tx_beat_data),
    .tx_beat_rd_i    (tx_beat_rd),
    .stat_port_i     (stat_port_i),
    .stat_id_i       (stat_id_i),
    .stat_data_o     (stat_data_o),
    .cam_rd_req_i    (cam_rd_req_i),
    .cam_rd_index_i  (cam_rd_index_i),
    .cam_rd_valid_o  (cam_rd_valid_o),
    .cam_rd_entry_o  (cam_rd_entry_o),
    .cam_entries_o   (cam_entries_o),
    .stat_o          (stat_o)
  );

  // --------------------------------------------------------------------------
  // Panel: switch positions in, semantic lamps out
  // --------------------------------------------------------------------------
  es_panel #(
    .NUM_PORTS    (NUM_PORTS),
    .CAM_CAPACITY (CAM_SETS * CAM_WAYS)
  ) u_panel (
    .clk_i          (clk_i),
    .rst_ni         (rst_ni),
    .dip_i          (dip_i),
    .link_up_i      (link_up_i),
    .phy_status_i   (phy_status_i),
    .port_active_i  (port_active),
    .rx_crc_err_i   (stat_o[32*int'(SW_STAT_RX_CRC_ERR)  +: 32]),
    .rx_runt_i      (stat_o[32*int'(SW_STAT_RX_RUNT)     +: 32]),
    .rx_oversize_i  (stat_o[32*int'(SW_STAT_RX_OVERSIZE) +: 32]),
    .rx_overflow_i  (stat_o[32*int'(SW_STAT_RX_OVERFLOW) +: 32]),
    .cam_entries_i  (cam_entries_o),
    .flood_mode_o   (panel_flood_mode),
    .learning_en_o  (panel_learning_en),
    .cfg_ovr_o      (panel_cfg_ovr),
    .cam_flush_o    (panel_cam_flush),
    .led_link_o     (led_link_o),
    .led_act_o      (led_act_o),
    .led_speed_o    (led_speed_o),
    .led_duplex_o   (led_duplex_o),
    .led_fault_o    (led_fault_o),
    .led_stat_o     (led_stat_o)
  );

endmodule : es_switch_rmii

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_SWITCH_RMII_SV
