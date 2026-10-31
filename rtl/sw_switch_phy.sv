// ============================================================================
//  File        : sw_switch_phy.sv
//  Description : PHY-facing wrapper for the GMII/MII/RMII/RGMII switch core.
//
//                Each port selects one synchronous PHY representation through
//                PORT_PHY_IF.  The adapters normalize all modes to the
//                existing 8-bit, clock-enable-qualified GMII contract before
//                instantiating sw_switch.  No PHY clock is consumed here: raw
//                MII/RMII clocks and RGMII DDR I/O capture belong in an outer
//                technology-specific shell that presents symbols synchronously
//                to clk_i.  The RGMII rise/fall buses are that captured pair.
// ============================================================================
`timescale 1ns/1ps

`ifndef SW_SWITCH_PHY_SV
`define SW_SWITCH_PHY_SV

`default_nettype none

`include "sw_defs.sv"

module sw_switch_phy #(
  parameter int unsigned NUM_PORTS = 4,
  parameter int unsigned CLK_FREQ_HZ = 125_000_000,
  parameter logic [NUM_PORTS*48-1:0] PORT_MAC = '0,
  /// Port p occupies bits [2*p +: 2]; values are 0=10M, 1=100M, 2=1000M.
  parameter logic [NUM_PORTS*2-1:0] PORT_SPEED = {NUM_PORTS{2'd2}},
  /// Port p occupies bits [3*p +: 3]; select GMII, MII, RMII, or RGMII.  The
  /// field is 3 bits wide (see sw_phy_if_e) so further MAC interfaces can be
  /// assigned without renumbering these four.
  parameter logic [NUM_PORTS*3-1:0] PORT_PHY_IF = {NUM_PORTS{SW_PHY_GMII}},
  /// Port p is 1 when its receive stream includes 55 x 7 followed by D5.
  parameter logic [NUM_PORTS-1:0] PHY_RX_PREAMBLE = '0,
  parameter int unsigned RX_FIFO_DEPTH = 256,
  parameter int unsigned TX_FIFO_DEPTH = 256,
  parameter int unsigned TAG_FIFO_DEPTH = 16,
  parameter int unsigned WF_DEPTH = 16,
  parameter int unsigned MAX_FRAME_LEN = 1518,
  parameter logic [1:0] FLOOD_MODE = 2'd1,
  parameter logic LEARNING_EN = 1'b1,
  parameter int unsigned STALL_LIMIT = 0,
  parameter int unsigned CAM_SETS = 128,
  parameter int unsigned CAM_WAYS = 4,
  parameter logic CAM_AGE_EN = 1'b0,
  parameter int unsigned CAM_AGE_CYCLES = 1_000_000,
  parameter int unsigned CAM_AGE_LIMIT = 4
) (
  input logic clk_i,
  input logic rst_ni,
  input logic [NUM_PORTS-1:0] link_up_i,
  input logic [1:0] flood_mode_i,
  input logic learning_en_i,
  input logic cfg_ovr_i,
  input logic cam_flush_i,

  input logic [NUM_PORTS-1:0] phy_gmii_rx_en_i,
  input logic [NUM_PORTS-1:0] phy_gmii_rx_er_i,
  input logic [NUM_PORTS*8-1:0] phy_gmii_rxd_i,
  output logic [NUM_PORTS-1:0] phy_gmii_tx_en_o,
  output logic [NUM_PORTS-1:0] phy_gmii_tx_er_o,
  output logic [NUM_PORTS*8-1:0] phy_gmii_txd_o,

  input logic [NUM_PORTS-1:0] phy_mii_rx_dv_i,
  input logic [NUM_PORTS-1:0] phy_mii_rx_er_i,
  input logic [NUM_PORTS*4-1:0] phy_mii_rxd_i,
  output logic [NUM_PORTS-1:0] phy_mii_tx_en_o,
  output logic [NUM_PORTS-1:0] phy_mii_tx_er_o,
  output logic [NUM_PORTS*4-1:0] phy_mii_txd_o,

  input logic [NUM_PORTS-1:0] phy_rmii_crs_dv_i,
  input logic [NUM_PORTS-1:0] phy_rmii_rx_er_i,
  input logic [NUM_PORTS*2-1:0] phy_rmii_rxd_i,
  output logic [NUM_PORTS-1:0] phy_rmii_tx_en_o,
  output logic [NUM_PORTS*2-1:0] phy_rmii_txd_o,

  input logic [NUM_PORTS-1:0] phy_rgmii_rx_ce_i,
  input logic [NUM_PORTS-1:0] phy_rgmii_rx_ctl_rise_i,
  input logic [NUM_PORTS-1:0] phy_rgmii_rx_ctl_fall_i,
  input logic [NUM_PORTS*4-1:0] phy_rgmii_rxd_rise_i,
  input logic [NUM_PORTS*4-1:0] phy_rgmii_rxd_fall_i,
  output logic [NUM_PORTS-1:0] phy_rgmii_tx_ce_o,
  output logic [NUM_PORTS-1:0] phy_rgmii_tx_ctl_rise_o,
  output logic [NUM_PORTS-1:0] phy_rgmii_tx_ctl_fall_o,
  output logic [NUM_PORTS*4-1:0] phy_rgmii_txd_rise_o,
  output logic [NUM_PORTS*4-1:0] phy_rgmii_txd_fall_o,

  output logic [32*SW_STAT_COUNT-1:0] stat_o
);

  // MII/RMII symbols must be phase-aligned by the synchronous outer shell to
  // the byte period derived below. RGMII CE is a one-cycle captured-data event;
  // it is not required during idle, and RX_CTL low terminates a frame without
  // relying on an idle CE pulse.

  logic [NUM_PORTS-1:0] mac_rx_en;
  logic [NUM_PORTS*8-1:0] mac_rx_data;
  logic [NUM_PORTS-1:0] mac_tx_en;
  logic [NUM_PORTS*8-1:0] mac_tx_data;

  for (genvar g = 0; g < NUM_PORTS; g++) begin : g_phy
    localparam int unsigned BP_G =
        sw_byte_period(CLK_FREQ_HZ, sw_speed_e'(PORT_SPEED[g*2 +: 2]));

    sw_phy_adapter #(
        .PHY_IF          (PORT_PHY_IF[g*3 +: 3]),
        .BYTE_PERIOD     (BP_G),
        .PHY_RX_PREAMBLE(PHY_RX_PREAMBLE[g])
    ) u_adapter (
        .clk_i                     (clk_i),
        .rst_ni                    (rst_ni),
        .gmii_rx_en_i              (phy_gmii_rx_en_i[g]),
        .gmii_rx_er_i              (phy_gmii_rx_er_i[g]),
        .gmii_rx_data_i            (phy_gmii_rxd_i[g*8 +: 8]),
        .mii_rx_en_i               (phy_mii_rx_dv_i[g]),
        .mii_rx_er_i               (phy_mii_rx_er_i[g]),
        .mii_rx_data_i             (phy_mii_rxd_i[g*4 +: 4]),
        .rmii_rx_dv_i              (phy_rmii_crs_dv_i[g]),
        .rmii_rx_er_i              (phy_rmii_rx_er_i[g]),
        .rmii_rx_data_i            (phy_rmii_rxd_i[g*2 +: 2]),
        .rgmii_rx_ce_i             (phy_rgmii_rx_ce_i[g]),
        .rgmii_rx_rising_data_i    (phy_rgmii_rxd_rise_i[g*4 +: 4]),
        .rgmii_rx_falling_data_i   (phy_rgmii_rxd_fall_i[g*4 +: 4]),
        .rgmii_rx_rising_ctl_i     (phy_rgmii_rx_ctl_rise_i[g]),
        .rgmii_rx_falling_ctl_i    (phy_rgmii_rx_ctl_fall_i[g]),
        .gmii_rx_en_o              (mac_rx_en[g]),
        .gmii_rx_data_o            (mac_rx_data[g*8 +: 8]),
        .gmii_tx_en_i              (mac_tx_en[g]),
        .gmii_tx_data_i            (mac_tx_data[g*8 +: 8]),
        .gmii_tx_en_o              (phy_gmii_tx_en_o[g]),
        .gmii_tx_data_o            (phy_gmii_txd_o[g*8 +: 8]),
        .gmii_tx_er_o              (phy_gmii_tx_er_o[g]),
        .mii_tx_en_o               (phy_mii_tx_en_o[g]),
        .mii_tx_data_o             (phy_mii_txd_o[g*4 +: 4]),
        .mii_tx_er_o               (phy_mii_tx_er_o[g]),
        .rmii_tx_en_o              (phy_rmii_tx_en_o[g]),
        .rmii_tx_data_o            (phy_rmii_txd_o[g*2 +: 2]),
        .rgmii_tx_ce_o             (phy_rgmii_tx_ce_o[g]),
        .rgmii_tx_rising_data_o    (phy_rgmii_txd_rise_o[g*4 +: 4]),
        .rgmii_tx_falling_data_o   (phy_rgmii_txd_fall_o[g*4 +: 4]),
        .rgmii_tx_rising_ctl_o     (phy_rgmii_tx_ctl_rise_o[g]),
        .rgmii_tx_falling_ctl_o    (phy_rgmii_tx_ctl_fall_o[g])
    );
  end

  sw_switch #(
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
  ) u_switch (
      .clk_i           (clk_i),
      .rst_ni          (rst_ni),
      .link_up_i       (link_up_i),
      .flood_mode_i    (flood_mode_i),
      .learning_en_i   (learning_en_i),
      .cfg_ovr_i       (cfg_ovr_i),
      .cam_flush_i     (cam_flush_i),
      .gmii_rx_en_i    (mac_rx_en),
      .gmii_rx_data_i  (mac_rx_data),
      .gmii_tx_en_o    (mac_tx_en),
      .gmii_tx_data_o  (mac_tx_data),
      .stat_o          (stat_o)
  );

endmodule : sw_switch_phy

`default_nettype wire

`endif // SW_SWITCH_PHY_SV
