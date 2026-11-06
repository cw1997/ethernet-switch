// ============================================================================
//  File        : es_switch_de2_115_top.sv
//  Description : DE2-115 dual-port 100FD MII switch, telemetry and UART console.
//                CLOCK_50 is the 50 MHz core clock; KEY0 releases sampled reset.
//                JP1 must select MII. RX capture has no asynchronous FIFO and
//                retains the existing board CDC limitation. TX uses a negedge
//                divider; its existing SDC budget is not a general CDC proof.
//                Hold reset through startup; no new PHY timing guarantee is added.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_SWITCH_DE2_115_TOP_SV
`define ES_SWITCH_DE2_115_TOP_SV
`default_nettype none
`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`include "monitor/es_monitor_defs.sv"
`include "console/es_console_defs.sv"
`default_nettype none
module es_switch_de2_115_top #(
  parameter int unsigned REFRESH_INTERVAL_MS = 500,
  parameter int unsigned UART_BAUD_RATE = 115200,
  parameter int unsigned UART_DATA_BITS = 8,
  parameter int unsigned UART_PARITY = SW_UART_PARITY_NONE,
  parameter int unsigned UART_STOP_BITS = 1,
  parameter int unsigned UART_FLOW_CONTROL = SW_UART_FLOW_NONE
) (
  input var logic CLOCK_50,
  input var logic [3:0] KEY,
  output logic [8:0] LEDG,
  output logic [17:0] LEDR,
  output logic [6:0] HEX0, HEX1, HEX2, HEX3, HEX4, HEX5, HEX6, HEX7,
  output logic [7:0] LCD_DATA,
  output logic LCD_EN, LCD_RS, LCD_RW, LCD_ON, LCD_BLON,
  input var logic UART_RXD, UART_CTS,
  output logic UART_TXD, UART_RTS,
  input var logic [3:0] ENET0_RX_DATA,
  input var logic ENET0_RX_DV, ENET0_RX_ER,
  output logic [3:0] ENET0_TX_DATA,
  output logic ENET0_TX_EN, ENET0_TX_ER, ENET0_TX_CLK,
  output logic ENET0_RESET_N, ENET0_MDC,
  inout tri logic ENET0_MDIO,
  input var logic ENET0_INT_N,
  input var logic [3:0] ENET1_RX_DATA,
  input var logic ENET1_RX_DV, ENET1_RX_ER,
  output logic [3:0] ENET1_TX_DATA,
  output logic ENET1_TX_EN, ENET1_TX_ER, ENET1_TX_CLK,
  output logic ENET1_RESET_N, ENET1_MDC,
  inout tri logic ENET1_MDIO,
  input var logic ENET1_INT_N
 );
  localparam int unsigned NUM_PORTS = 2;
  localparam int unsigned CLK_FREQ_HZ = 50_000_000;
  logic key_rst_meta_q, key_rst_sync_q, rst_ni;
  // Cyclone IV powers registers up low, asserting reset until KEY0 synchronizes.
  always_ff @(posedge CLOCK_50) begin
    key_rst_meta_q <= KEY[0]; key_rst_sync_q <= key_rst_meta_q;
  end
  assign rst_ni = key_rst_sync_q;
  logic cam_flush;
  logic [31:0] page;
  es_monitor_page #(.NUM_PORTS(NUM_PORTS), .CLK_FREQ_HZ(CLK_FREQ_HZ)) u_page (
    .clk_i(CLOCK_50), .rst_ni(rst_ni), .key_ni(KEY[3:1]), .flush_o(cam_flush), .page_o(page));
  logic [1:0] tx_clk_q;
  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_tx_clk
      // The clock divider is the existing board-only negedge exception.
      always_ff @(negedge CLOCK_50) begin
        if (!rst_ni) tx_clk_q[g] <= 1'b0;
        else tx_clk_q[g] <= ~tx_clk_q[g];
      end
    end
  endgenerate
  logic phy_rst_n_q;
  always_ff @(posedge CLOCK_50) begin
    if (!rst_ni) phy_rst_n_q <= 1'b0;
    else phy_rst_n_q <= 1'b1;
  end
  assign ENET0_RESET_N = phy_rst_n_q; assign ENET1_RESET_N = phy_rst_n_q;
  assign {ENET1_TX_CLK, ENET0_TX_CLK} = tx_clk_q;
  logic [15:0] phy_status;
  logic [1:0] enabled, mdio_out, mdio_oe;
  // Isolate bidirectional pads from variable input-port collapsing in Icarus.
  logic [1:0] mdio_sample;
  assign mdio_sample = {ENET1_MDIO, ENET0_MDIO};
  es_monitor_phy #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_phy0 (
    .clk_i(CLOCK_50), .rst_ni(rst_ni && phy_rst_n_q), .mdio_i(mdio_sample[0]),
    .mdc_o(ENET0_MDC), .mdio_o(mdio_out[0]), .mdio_oe_o(mdio_oe[0]),
    .status_o(phy_status[0 +: 8]), .enabled_o(enabled[0]));
  assign ENET0_MDIO = mdio_oe[0] ? mdio_out[0] : 1'bz;
  es_monitor_phy #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_phy1 (
    .clk_i(CLOCK_50), .rst_ni(rst_ni && phy_rst_n_q), .mdio_i(mdio_sample[1]),
    .mdc_o(ENET1_MDC), .mdio_o(mdio_out[1]), .mdio_oe_o(mdio_oe[1]),
    .status_o(phy_status[8 +: 8]), .enabled_o(enabled[1]));
  assign ENET1_MDIO = mdio_oe[1] ? mdio_out[1] : 1'bz;
  logic [1:0] mii_tx_en, mii_tx_er;
  logic [7:0] mii_txd;
  logic [32*SW_STAT_COUNT-1:0] stat;
  logic mon_req, mon_ready, mon_valid;
  logic [31:0] mon_addr, mon_data;
  es_switch_mii #(.NUM_PORTS(NUM_PORTS), .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .REFRESH_INTERVAL_MS(REFRESH_INTERVAL_MS), .PORT_SPEED({NUM_PORTS{2'(SW_SPEED_100M)}})) u_switch (
    .clk_i(CLOCK_50), .rst_ni(rst_ni), .link_up_i(enabled),
    .phy_status_i(phy_status), .mon_req_i(mon_req), .mon_addr_i(mon_addr),
    .mon_ready_o(mon_ready), .mon_valid_o(mon_valid), .mon_data_o(mon_data),
    .flood_mode_i(2'd1), .learning_en_i(1'b1), .cfg_ovr_i(1'b0), .cam_flush_i(cam_flush),
    .mii_rx_dv_i({ENET1_RX_DV,ENET0_RX_DV}), .mii_rx_er_i({ENET1_RX_ER,ENET0_RX_ER}),
    .mii_rxd_i({ENET1_RX_DATA,ENET0_RX_DATA}), .mii_tx_en_o(mii_tx_en),
    .mii_tx_er_o(mii_tx_er), .mii_txd_o(mii_txd), .stat_o(stat));
  assign {ENET1_TX_EN,ENET0_TX_EN} = mii_tx_en & enabled;
  assign {ENET1_TX_ER,ENET0_TX_ER} = mii_tx_er & enabled;
  assign {ENET1_TX_DATA,ENET0_TX_DATA} = mii_txd;
  logic [(NUM_PORTS+1)*SW_MON_BITS-1:0] image;
  logic cache_req, cache_idle, console_claim, console_req, console_fault;
  logic [31:0] cache_addr, console_addr;
  es_monitor_cache #(.NUM_PORTS(NUM_PORTS)) u_cache (
    .clk_i(CLOCK_50), .rst_ni(rst_ni), .pause_i(console_claim),
    .req_o(cache_req), .addr_o(cache_addr), .ready_i(mon_ready && !console_claim),
    .valid_i(mon_valid && !console_claim), .data_i(mon_data), .idle_o(cache_idle), .image_o(image));
  es_console_core #(.NUM_PORTS(NUM_PORTS), .CLK_FREQ_HZ(CLK_FREQ_HZ),
    .UART_BAUD_RATE(UART_BAUD_RATE), .UART_DATA_BITS(UART_DATA_BITS), .UART_PARITY(UART_PARITY),
    .UART_STOP_BITS(UART_STOP_BITS), .UART_FLOW_CONTROL(UART_FLOW_CONTROL)) u_console (
    .clk_i(CLOCK_50), .rst_ni(rst_ni), .rx_i(UART_RXD), .cts_ni(UART_CTS),
    .tx_o(UART_TXD), .rts_no(UART_RTS), .image_i(image), .cache_idle_i(cache_idle),
    .bus_claim_o(console_claim), .req_o(console_req), .addr_o(console_addr),
    .ready_i(mon_ready && console_claim), .valid_i(mon_valid && console_claim),
    .data_i(mon_data), .fault_o(console_fault));
  assign mon_req = console_claim ? console_req : cache_req;
  assign mon_addr = console_claim ? console_addr : cache_addr;
  logic [55:0] hex;
  logic [255:0] lcd_text;
  logic rx_kpps, tx_kpps;
  es_monitor_display #(.NUM_PORTS(NUM_PORTS)) u_display (
    .clk_i(CLOCK_50), .rst_ni(rst_ni), .page_i(page), .image_i(image),
    .hex_o(hex), .rx_kpps_o(rx_kpps), .tx_kpps_o(tx_kpps), .text_o(lcd_text));
  assign {HEX7,HEX6,HEX5,HEX4,HEX3,HEX2,HEX1,HEX0} = hex;
  es_monitor_lcd #(.CLK_FREQ_HZ(CLK_FREQ_HZ)) u_lcd (
    .clk_i(CLOCK_50), .rst_ni(rst_ni), .text_i(lcd_text), .data_o(LCD_DATA),
    .rs_o(LCD_RS), .rw_o(LCD_RW), .en_o(LCD_EN), .on_o(LCD_ON), .blon_o(LCD_BLON));
  logic [24:0] heartbeat_q;
  logic [3:0] activity;
  logic [3:0] activity_in;
  logic [1:0] port_fault_q;
  logic phy_fault_q;
  logic [31:0] load_sum;
  assign activity_in = {mii_tx_en[1] && enabled[1], ENET1_RX_DV && enabled[1],
                        mii_tx_en[0] && enabled[0], ENET0_RX_DV && enabled[0]};
  generate
    for (g = 0; g < 4; g++) begin : g_activity
      logic [31:0] hold_q;
      always_ff @(posedge CLOCK_50) begin
        if (!rst_ni) hold_q <= '0;
        else if (activity_in[g]) hold_q <= 32'(CLK_FREQ_HZ/10);
        else if (hold_q != 32'd0) hold_q <= hold_q - 32'd1;
      end
      assign activity[g] = hold_q != 32'd0;
    end
    for (g = 0; g < NUM_PORTS; g++) begin : g_fault
      always_ff @(posedge CLOCK_50) begin
        if (!rst_ni) port_fault_q[g] <= 1'b0;
        else if ((|image[(g+1)*SW_MON_BITS+(SW_MON_COUNTER+4)*32 +: 320]) ||
                     (|image[(g+1)*SW_MON_BITS+(SW_MON_COUNTER+18)*32 +: 64]) ||
                     phy_status[g*8+5] || (phy_status[g*8] && phy_status[g*8+1] && !enabled[g])) port_fault_q[g] <= 1'b1;
      end
    end
  endgenerate
  always_ff @(posedge CLOCK_50) begin
    if (!rst_ni) begin heartbeat_q <= '0; phy_fault_q <= 1'b0; end
    else begin
      // The heartbeat modulus is exactly 2**25, so natural overflow is intended.
      heartbeat_q <= heartbeat_q + 25'd1;
      if (phy_status[5] || phy_status[13]) phy_fault_q <= 1'b1;
    end
  end
  assign LEDG = {page == 32'd2, page == 32'd1, page == 32'd0,
                 tx_kpps, rx_kpps, enabled[1], enabled[0],
                 image[50*32] && phy_status[0] && phy_status[8], heartbeat_q[24]};
  assign load_sum = image[SW_MON_BITS+5*32 +: 32]+image[SW_MON_BITS+6*32 +: 32]+
                    image[2*SW_MON_BITS+5*32 +: 32]+image[2*SW_MON_BITS+6*32 +: 32];
  generate
    for (g = 0; g < 9; g++) begin : g_load
      assign LEDR[g+9] = load_sum >= 32'((g+1)*400);
    end
  endgenerate
  assign LEDR[8] = (image[SW_MON_BITS+3*32 +: 32] >= 32'd224) ||
                   (image[SW_MON_BITS+4*32 +: 32] >= 32'd224) ||
                   (image[2*SW_MON_BITS+3*32 +: 32] >= 32'd224) ||
                   (image[2*SW_MON_BITS+4*32 +: 32] >= 32'd224);
  assign LEDR[7:0] = {console_fault, phy_fault_q, port_fault_q, activity};
  logic unused_stat, unused_int_n;
  assign unused_stat = ^stat;
  assign unused_int_n = ENET0_INT_N ^ ENET1_INT_N;
endmodule
`default_nettype wire
`endif
