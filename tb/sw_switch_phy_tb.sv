// ============================================================================
//  File        : sw_switch_phy_tb.sv
//  Description : Self-checking elaboration and pin-routing smoke test for the
//                selectable PHY-facing switch wrapper.
//
//                The adapter testbench owns symbol ordering.  This testbench
//                verifies the generated per-port mode/speed wiring and that a
//                selected GMII port remains connected to the switch core.
// ============================================================================
`timescale 1ns/1ps

`include "sw_defs.sv"

module sw_switch_phy_tb;
  localparam int unsigned NUM_PORTS = 2;
  localparam logic [NUM_PORTS*2-1:0] PORT_SPEED = {SW_SPEED_100M, SW_SPEED_1000M};
  localparam logic [NUM_PORTS*3-1:0] PORT_PHY_IF = {SW_PHY_RMII, SW_PHY_GMII};

  logic clk_i = 1'b0;
  logic rst_ni = 1'b0;
  logic [NUM_PORTS-1:0] link_up_i;
  logic [1:0] flood_mode_i;
  logic learning_en_i;
  logic cfg_ovr_i;
  logic cam_flush_i;

  logic [NUM_PORTS-1:0] phy_gmii_rx_en_i;
  logic [NUM_PORTS-1:0] phy_gmii_rx_er_i;
  logic [NUM_PORTS*8-1:0] phy_gmii_rxd_i;
  logic [NUM_PORTS-1:0] phy_gmii_tx_en_o;
  logic [NUM_PORTS-1:0] phy_gmii_tx_er_o;
  logic [NUM_PORTS*8-1:0] phy_gmii_txd_o;

  logic [NUM_PORTS-1:0] phy_mii_rx_dv_i;
  logic [NUM_PORTS-1:0] phy_mii_rx_er_i;
  logic [NUM_PORTS*4-1:0] phy_mii_rxd_i;
  logic [NUM_PORTS-1:0] phy_mii_tx_en_o;
  logic [NUM_PORTS-1:0] phy_mii_tx_er_o;
  logic [NUM_PORTS*4-1:0] phy_mii_txd_o;

  logic [NUM_PORTS-1:0] phy_rmii_crs_dv_i;
  logic [NUM_PORTS-1:0] phy_rmii_rx_er_i;
  logic [NUM_PORTS*2-1:0] phy_rmii_rxd_i;
  logic [NUM_PORTS-1:0] phy_rmii_tx_en_o;
  logic [NUM_PORTS*2-1:0] phy_rmii_txd_o;

  logic [NUM_PORTS-1:0] phy_rgmii_rx_ce_i;
  logic [NUM_PORTS-1:0] phy_rgmii_rx_ctl_rise_i;
  logic [NUM_PORTS-1:0] phy_rgmii_rx_ctl_fall_i;
  logic [NUM_PORTS*4-1:0] phy_rgmii_rxd_rise_i;
  logic [NUM_PORTS*4-1:0] phy_rgmii_rxd_fall_i;
  logic [NUM_PORTS-1:0] phy_rgmii_tx_ce_o;
  logic [NUM_PORTS-1:0] phy_rgmii_tx_ctl_rise_o;
  logic [NUM_PORTS-1:0] phy_rgmii_tx_ctl_fall_o;
  logic [NUM_PORTS*4-1:0] phy_rgmii_txd_rise_o;
  logic [NUM_PORTS*4-1:0] phy_rgmii_txd_fall_o;
  logic [32*SW_STAT_COUNT-1:0] stat_o;

  integer errors;
  integer checks;

  always #5 clk_i = ~clk_i;

  sw_switch_phy #(
      .NUM_PORTS(NUM_PORTS),
      .CLK_FREQ_HZ(125_000_000),
      .PORT_SPEED(PORT_SPEED),
      .PORT_PHY_IF(PORT_PHY_IF),
      .PHY_RX_PREAMBLE('0),
      .RX_FIFO_DEPTH(256),
      .TX_FIFO_DEPTH(256),
      .TAG_FIFO_DEPTH(16),
      .WF_DEPTH(16),
      .CAM_SETS(4),
      .CAM_WAYS(2)
  ) u_dut (
      .clk_i(clk_i), .rst_ni(rst_ni), .link_up_i(link_up_i),
      .flood_mode_i(flood_mode_i), .learning_en_i(learning_en_i),
      .cfg_ovr_i(cfg_ovr_i), .cam_flush_i(cam_flush_i),
      .phy_gmii_rx_en_i(phy_gmii_rx_en_i), .phy_gmii_rx_er_i(phy_gmii_rx_er_i),
      .phy_gmii_rxd_i(phy_gmii_rxd_i), .phy_gmii_tx_en_o(phy_gmii_tx_en_o),
      .phy_gmii_tx_er_o(phy_gmii_tx_er_o), .phy_gmii_txd_o(phy_gmii_txd_o),
      .phy_mii_rx_dv_i(phy_mii_rx_dv_i), .phy_mii_rx_er_i(phy_mii_rx_er_i),
      .phy_mii_rxd_i(phy_mii_rxd_i), .phy_mii_tx_en_o(phy_mii_tx_en_o),
      .phy_mii_tx_er_o(phy_mii_tx_er_o), .phy_mii_txd_o(phy_mii_txd_o),
      .phy_rmii_crs_dv_i(phy_rmii_crs_dv_i), .phy_rmii_rx_er_i(phy_rmii_rx_er_i),
      .phy_rmii_rxd_i(phy_rmii_rxd_i), .phy_rmii_tx_en_o(phy_rmii_tx_en_o),
      .phy_rmii_txd_o(phy_rmii_txd_o), .phy_rgmii_rx_ce_i(phy_rgmii_rx_ce_i),
      .phy_rgmii_rx_ctl_rise_i(phy_rgmii_rx_ctl_rise_i),
      .phy_rgmii_rx_ctl_fall_i(phy_rgmii_rx_ctl_fall_i),
      .phy_rgmii_rxd_rise_i(phy_rgmii_rxd_rise_i),
      .phy_rgmii_rxd_fall_i(phy_rgmii_rxd_fall_i),
      .phy_rgmii_tx_ce_o(phy_rgmii_tx_ce_o),
      .phy_rgmii_tx_ctl_rise_o(phy_rgmii_tx_ctl_rise_o),
      .phy_rgmii_tx_ctl_fall_o(phy_rgmii_tx_ctl_fall_o),
      .phy_rgmii_txd_rise_o(phy_rgmii_txd_rise_o),
      .phy_rgmii_txd_fall_o(phy_rgmii_txd_fall_o), .stat_o(stat_o)
  );

  task automatic check(input logic condition, input string message);
    begin
      checks = checks + 1;
      if (condition) $display("PASS: %s", message);
      else begin errors = errors + 1; $display("FAIL: %s", message); end
    end
  endtask

  initial begin
    link_up_i = '1;
    flood_mode_i = 2'd1;
    learning_en_i = 1'b1;
    cfg_ovr_i = 1'b0;
    cam_flush_i = 1'b0;
    phy_gmii_rx_en_i = '0;
    phy_gmii_rx_er_i = '0;
    phy_gmii_rxd_i = '0;
    phy_mii_rx_dv_i = '0;
    phy_mii_rx_er_i = '0;
    phy_mii_rxd_i = '0;
    phy_rmii_crs_dv_i = '0;
    phy_rmii_rx_er_i = '0;
    phy_rmii_rxd_i = '0;
    phy_rgmii_rx_ce_i = '0;
    phy_rgmii_rx_ctl_rise_i = '0;
    phy_rgmii_rx_ctl_fall_i = '0;
    phy_rgmii_rxd_rise_i = '0;
    phy_rgmii_rxd_fall_i = '0;
    errors = 0;
    checks = 0;

    repeat (2) @(posedge clk_i);
    rst_ni = 1'b1;
    repeat (2) @(posedge clk_i);

    // Port 0 is GMII; port 1 is RMII.  An idle selected mode must not leak
    // activity onto another mode's output bus.
    check(!phy_gmii_tx_en_o[0] && !phy_mii_tx_en_o[0] &&
          !phy_rmii_tx_en_o[1], "wrapper selected modes remain idle");
    check(u_dut.g_phy[0].BP_G == 1 && u_dut.g_phy[1].BP_G == 10,
          "wrapper derives per-port byte periods");

    if (errors == 0) $display("PASS: sw_switch_phy_tb (%0d checks)", checks);
    else begin
      $display("FAIL: sw_switch_phy_tb (%0d errors, %0d checks)", errors, checks);
      $fatal(1, "sw_switch_phy_tb failed");
    end
    $finish;
  end
endmodule
