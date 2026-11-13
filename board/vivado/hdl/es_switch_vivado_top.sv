// ============================================================================
//  File        : es_switch_vivado_top.sv
//  Description : Eight-port, fixed 100 Mbit/s MII board template for Vivado.
//                Pure switching logic - no console, statistics, panel or LED
//                buses.  The physical pin list is unchanged (138 port bits).
//
//                Direct data wiring below assumes the synchronous es_switch_mii
//                contract; physical PHY clock capture and CDC remain board
//                integration work, as before.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_SWITCH_VIVADO_TOP_SV
`define ES_SWITCH_VIVADO_TOP_SV
`default_nettype none
`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`default_nettype none

module es_switch_vivado_top (
  input  var logic        clk_i,          ///< 50 MHz; always running during reset
  input  var logic        rst_button_ni,  ///< asynchronous, active-low button
  input  var logic [7:0]  mii_rx_clk_i,   ///< PHY RX clocks; currently unused
  input  var logic [7:0]  mii_tx_clk_i,   ///< PHY TX clocks, not FPGA outputs
  input  var logic [7:0]  mii_rx_dv_i,    ///< valid for whole octets in this model
  input  var logic [7:0]  mii_rx_er_i,    ///< per-port receive error indication
  input  var logic [31:0] mii_rxd_i,      ///< low nibble first, port 0 in [3:0]
  output      logic [7:0] mii_tx_en_o,    ///< per-port transmit frame enable
  output      logic [7:0] mii_tx_er_o,    ///< held low: adapter has no TX error source
  output      logic [31:0] mii_txd_o,     ///< port 7 in [31:28], low nibble first
  output      logic [7:0] phy_reset_no,   ///< follows synchronised button reset
  output      logic [7:0] phy_mdc_o,      ///< idle low; no management transactions
  inout   tri logic [7:0] phy_mdio_io     ///< released; requires external pull-ups
);

  localparam int unsigned NUM_PORTS   = 8;
  localparam int unsigned CLK_FREQ_HZ = 50_000_000;

  // ASYNC_REG identifies the sampling chain to Vivado; it does not debounce
  // the button or guarantee a minimum PHY reset hold time.
  (* ASYNC_REG = "TRUE" *) logic rst_meta_q;
  (* ASYNC_REG = "TRUE" *) logic rst_sync_q;
  logic rst_ni;
  always_ff @(posedge clk_i) begin
    rst_meta_q <= rst_button_ni;
    rst_sync_q <= rst_meta_q;
  end
  assign rst_ni = rst_sync_q;

  assign phy_reset_no = {NUM_PORTS{rst_ni}};
  assign phy_mdc_o    = '0;
  assign phy_mdio_io  = {NUM_PORTS{1'bz}};

  es_switch_mii #(
    .NUM_PORTS   (NUM_PORTS),
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .PORT_SPEED  ({NUM_PORTS{2'(SW_SPEED_100M)}})
  ) u_switch (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    // No management controller in this template, so nothing to ask about link
    // state; all eight ports are administratively enabled.
    .link_up_i   ({NUM_PORTS{1'b1}}),
    .mii_rx_dv_i (mii_rx_dv_i),
    .mii_rx_er_i (mii_rx_er_i),
    .mii_rxd_i   (mii_rxd_i),
    .mii_tx_en_o (mii_tx_en_o),
    .mii_tx_er_o (mii_tx_er_o),
    .mii_txd_o   (mii_txd_o)
  );

  // The house unused_* pattern records intentionally unobserved signals
  // without lint waivers.  Neither reserved PHY clock drives any logic.
  logic unused_phy;
  assign unused_phy = ^{mii_rx_clk_i, mii_tx_clk_i, phy_mdio_io};

endmodule : es_switch_vivado_top

`default_nettype wire

`endif  // ES_SWITCH_VIVADO_TOP_SV
