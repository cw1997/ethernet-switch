// ============================================================================
// sw_vivado_top: eight-port 100 Mbit/s MII board TEMPLATE, 50 MHz core.
// RX/TX clocks are PHY inputs reserved for a future clock-domain adapter.
// The direct data wiring below requires the synchronous sw_mii contract;
// it is NOT a physical MII MAC. Add CDC, RX preamble/SFD removal and PHY
// management before attaching real PHYs. TX already includes preamble/FCS.
// ============================================================================
`timescale 1ns/1ps
`ifndef SW_VIVADO_TOP_SV
`define SW_VIVADO_TOP_SV
`default_nettype none
`include "sw_defs.sv"

module sw_vivado_top (
  input  var logic       clk_i,
  input  var logic       rst_button_ni,
  input  var logic [7:0] mii_rx_clk_i,
  input  var logic [7:0] mii_tx_clk_i,
  input  var logic [7:0] mii_rx_dv_i,
  input  var logic [7:0] mii_rx_er_i,
  input  var logic [31:0] mii_rxd_i,
  output logic [7:0] mii_tx_en_o,
  output logic [7:0] mii_tx_er_o,
  output logic [31:0] mii_txd_o,
  output logic [7:0] phy_reset_no,
  output logic [7:0] phy_mdc_o,
  // MDIO needs an explicit net kind under default_nettype none in Vivado.
  inout  tri logic [7:0] phy_mdio_io
);
  localparam int unsigned NUM_PORTS = 8;
  localparam int unsigned CLK_FREQ_HZ = 50_000_000;

  // No power-on initialization is assumed. Hold the button low across at
  // least three rising clock edges after configuration, then release it.
  // These sampling flops deliberately have no reset: resetting them from
  // the asynchronous button would introduce an asynchronous reset domain.
  (* ASYNC_REG = "TRUE" *) logic rst_meta_q;
  (* ASYNC_REG = "TRUE" *) logic rst_sync_q;
  logic rst_ni;
  always_ff @(posedge clk_i) begin
    rst_meta_q <= rst_button_ni;
    rst_sync_q <= rst_meta_q;
  end
  assign rst_ni = rst_sync_q;

  assign phy_reset_no = {NUM_PORTS{rst_ni}};
  assign phy_mdc_o = '0;
  // No MDIO controller: external board pull-ups are required on both lines.
  assign phy_mdio_io = {NUM_PORTS{1'bz}};

  logic [32*SW_STAT_COUNT-1:0] stat;
  sw_switch_mii #(
    .NUM_PORTS(NUM_PORTS),
    .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .PORT_SPEED({NUM_PORTS{2'(SW_SPEED_100M)}})
  ) u_switch (
    .clk_i(clk_i),
    .rst_ni(rst_ni),
    .link_up_i({NUM_PORTS{1'b1}}),
    .flood_mode_i(2'd1),
    .learning_en_i(1'b1),
    .cfg_ovr_i(1'b0),
    .cam_flush_i(1'b0),
    .mii_rx_dv_i(mii_rx_dv_i),
    .mii_rx_er_i(mii_rx_er_i),
    .mii_rxd_i(mii_rxd_i),
    .mii_tx_en_o(mii_tx_en_o),
    .mii_tx_er_o(mii_tx_er_o),
    .mii_txd_o(mii_txd_o),
    .stat_o(stat)
  );

  // Deliberately reserved; neither PHY clock currently clocks any logic.
  logic unused_phy;
  logic unused_stat;
  assign unused_phy = ^{mii_rx_clk_i, mii_tx_clk_i, phy_mdio_io};
  assign unused_stat = ^stat;
endmodule

`default_nettype wire
`endif // SW_VIVADO_TOP_SV
