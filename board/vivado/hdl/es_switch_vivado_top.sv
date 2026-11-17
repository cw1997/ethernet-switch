// ============================================================================
//  File        : es_switch_vivado_top.sv
//  Description : Eight-port, fixed 100 Mbit/s MII board template for Vivado.
//                Pure switching logic - no console, statistics, panel or LED
//                buses.  The physical pin list is unchanged (138 port bits).
//
//                Direct data wiring below assumes the synchronous es_mii_top
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
  input  var logic        clk_i,  ///< 50 MHz; always running during reset
  input  var logic        rst_button_ni,  ///< asynchronous, active-low button
  input  var logic [7:0]  mii_rx_clk_i,  ///< PHY RX clocks; currently unused
  input  var logic [7:0]  mii_tx_clk_i,  ///< PHY TX clocks, not FPGA outputs
  input  var logic [7:0]  mii_rx_dv_i,  ///< valid for whole octets in this model
  input  var logic [7:0]  mii_rx_er_i,  ///< per-port receive error indication
  input  var logic [31:0] mii_rxd_i,  ///< low nibble first, port 0 in [3:0]
  output logic     [7:0]  mii_tx_en_o,  ///< per-port transmit frame enable
  output logic     [7:0]  mii_tx_er_o,  ///< held low: adapter has no TX error source
  output logic     [31:0] mii_txd_o,  ///< port 7 in [31:28], low nibble first
  output logic     [7:0]  phy_reset_no,  ///< follows synchronised button reset
  output logic     [7:0]  phy_mdc_o,  ///< idle low; no management transactions
  inout  tri logic [7:0]  phy_mdio_io  ///< released; requires external pull-ups
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

  // The board pins are packed vectors, while es_mii_top exposes per-port
  // unpacked arrays.  Bridge between the two with a generate loop so the
  // switch core keeps its array-style interface.
  logic       link_up_a[NUM_PORTS];
  logic       mii_rx_dv_a[NUM_PORTS];
  logic       mii_rx_er_a[NUM_PORTS];
  logic [3:0] mii_rxd_a[NUM_PORTS];
  wire        mii_tx_en_a[NUM_PORTS];
  wire        mii_tx_er_a[NUM_PORTS];
  wire  [3:0] mii_txd_a[NUM_PORTS];

  genvar gv;
  generate
    for (gv = 0; gv < NUM_PORTS; gv++) begin : g_switch_port_adapt
      assign link_up_a[gv]          = 1'b1;
      assign mii_rx_dv_a[gv]        = mii_rx_dv_i[gv];
      assign mii_rx_er_a[gv]        = mii_rx_er_i[gv];
      assign mii_rxd_a[gv]          = mii_rxd_i[gv*4 +: 4];
      assign mii_tx_en_o[gv]        = mii_tx_en_a[gv];
      assign mii_tx_er_o[gv]        = mii_tx_er_a[gv];
      assign mii_txd_o[gv*4 +: 4]   = mii_txd_a[gv];
    end
  endgenerate

  es_mii_top #(
    .NUM_PORTS   (NUM_PORTS),
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .PORT_SPEED  ({NUM_PORTS{2'(ES_SPEED_100M)}})
  ) u_switch (
    .clk_i       (clk_i),
    .rst_ni      (rst_ni),
    .link_up_i   (link_up_a),
    .mii_rx_dv_i (mii_rx_dv_a),
    .mii_rx_er_i (mii_rx_er_a),
    .mii_rxd_i   (mii_rxd_a),
    .mii_tx_en_o (mii_tx_en_a),
    .mii_tx_er_o (mii_tx_er_a),
    .mii_txd_o   (mii_txd_a)
  );

  // The house unused_* pattern records intentionally unobserved signals
  // without lint waivers.  Neither reserved PHY clock drives any logic.
  logic unused_phy;
  assign unused_phy = ^{mii_rx_clk_i, mii_tx_clk_i, phy_mdio_io};

endmodule : es_switch_vivado_top

`default_nettype wire

`endif  // ES_SWITCH_VIVADO_TOP_SV
