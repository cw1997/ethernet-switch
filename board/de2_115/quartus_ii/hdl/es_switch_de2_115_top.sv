// ============================================================================
//  File        : es_switch_de2_115_top.sv
//  Description : DE2-115 dual-port 100FD MII switch, pure switching logic.
//
//                This is a pin map only.  The console, front panel, status
//                lamps, DIP configuration and statistics read-back ports have
//                been removed: FLOOD_MODE / LEARNING_EN are elaboration
//                parameters of es_switch_mii and no run-time monitoring path
//                exists.  What remains is the PHY management needed to bring
//                the two 88E1111 PHYs up, the 25 MHz TX clock dividers, the
//                synchronised KEY0 reset and the switch itself.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_SWITCH_DE2_115_TOP_SV
`define ES_SWITCH_DE2_115_TOP_SV
`default_nettype none
`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_switch_de2_115_top (
  input  var logic        CLOCK_50,
  input  var logic [3:0]  KEY,

  input  var logic [3:0]  ENET0_RX_DATA,
  input  var logic        ENET0_RX_DV, ENET0_RX_ER,
  output      logic [3:0] ENET0_TX_DATA,
  output      logic       ENET0_TX_EN, ENET0_TX_ER, ENET0_TX_CLK,
  output      logic       ENET0_RESET_N, ENET0_MDC,
  inout   tri logic       ENET0_MDIO,
  input  var logic        ENET0_INT_N,

  input  var logic [3:0]  ENET1_RX_DATA,
  input  var logic        ENET1_RX_DV, ENET1_RX_ER,
  output      logic [3:0] ENET1_TX_DATA,
  output      logic       ENET1_TX_EN, ENET1_TX_ER, ENET1_TX_CLK,
  output      logic       ENET1_RESET_N, ENET1_MDC,
  inout   tri logic       ENET1_MDIO,
  input  var logic        ENET1_INT_N
);

  localparam int unsigned NUM_PORTS   = 2;
  localparam int unsigned CLK_FREQ_HZ = 50_000_000;

  // ---- reset and TX clock --------------------------------------------------
  logic key_rst_meta_q, key_rst_sync_q, rst_ni;
  always_ff @(posedge CLOCK_50) begin
    key_rst_meta_q <= KEY[0];
    key_rst_sync_q <= key_rst_meta_q;
  end
  assign rst_ni = key_rst_sync_q;

  logic [1:0] tx_clk_q;
  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_tx_clk
      // Board-only negedge exception, budgeted by de2_115.sdc.
      always_ff @(negedge CLOCK_50) begin
        if (!rst_ni) tx_clk_q[g] <= 1'b0;
        else         tx_clk_q[g] <= ~tx_clk_q[g];
      end
    end
  endgenerate

  logic phy_rst_n_q;
  always_ff @(posedge CLOCK_50) begin
    if (!rst_ni) phy_rst_n_q <= 1'b0;
    else         phy_rst_n_q <= 1'b1;
  end
  assign ENET0_RESET_N = phy_rst_n_q;
  assign ENET1_RESET_N = phy_rst_n_q;
  assign {ENET1_TX_CLK, ENET0_TX_CLK} = tx_clk_q;

  // ---- PHY management ------------------------------------------------------
  logic [NUM_PORTS*8-1:0] phy_status;
  logic [NUM_PORTS-1:0]   phy_enabled;
  logic [NUM_PORTS-1:0]   phy_mdio_i;
  logic [NUM_PORTS-1:0]   phy_mdc;
  logic [NUM_PORTS-1:0]   phy_mdio_o;
  logic [NUM_PORTS-1:0]   phy_mdio_oe;

  assign phy_mdio_i[0] = ENET0_MDIO;
  assign phy_mdio_i[1] = ENET1_MDIO;
  assign ENET0_MDIO    = phy_mdio_oe[0] ? phy_mdio_o[0] : 1'bz;
  assign ENET1_MDIO    = phy_mdio_oe[1] ? phy_mdio_o[1] : 1'bz;
  assign ENET0_MDC     = phy_mdc[0];
  assign ENET1_MDC     = phy_mdc[1];

  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_phy
      es_perips_phy_88e1111 #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_phy (
        .clk_i     (CLOCK_50),
        .rst_ni    (rst_ni),
        .mdio_i    (phy_mdio_i[g]),
        .mdc_o     (phy_mdc[g]),
        .mdio_o    (phy_mdio_o[g]),
        .mdio_oe_o (phy_mdio_oe[g]),
        .status_o  (phy_status[g*8 +: 8]),
        .enabled_o (phy_enabled[g])
      );
    end
  endgenerate

  // ---- staged switch -------------------------------------------------------
  es_switch_mii #(
    .NUM_PORTS   (NUM_PORTS),
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .PORT_SPEED  ({NUM_PORTS{2'(SW_SPEED_100M)}}),
    .CAM_SETS    (128),
    .CAM_WAYS    (4)
  ) u_switch (
    .clk_i        (CLOCK_50),
    .rst_ni       (rst_ni),
    .link_up_i    (phy_enabled),
    .mii_rx_dv_i  ({ENET1_RX_DV, ENET0_RX_DV}),
    .mii_rx_er_i  ({ENET1_RX_ER, ENET0_RX_ER}),
    .mii_rxd_i    ({ENET1_RX_DATA, ENET0_RX_DATA}),
    .mii_tx_en_o  ({ENET1_TX_EN, ENET0_TX_EN}),
    .mii_tx_er_o  ({ENET1_TX_ER, ENET0_TX_ER}),
    .mii_txd_o    ({ENET1_TX_DATA, ENET0_TX_DATA})
  );

  // Deliberate dummy consumer for status / interrupt pins that no longer have
  // a monitoring path (AGENTS.md: unused_*).
  logic unused_board;
  assign unused_board = |phy_status ^ ^{KEY[3:1], ENET0_INT_N, ENET1_INT_N};

endmodule : es_switch_de2_115_top

`default_nettype wire

`endif  // ES_SWITCH_DE2_115_TOP_SV
