// ============================================================================
//  File        : es_switch_de2_115_top.sv
//  Description : DE2-115 dual-port 100FD MII switch with a two-port console and
//                a front panel built from the board's switches and LEDs.
//
//                What this file is, and is not
//                -----------------------------
//                It is a pin map.  Every decision about what a switch position
//                means and what a lamp shows was made in `rtl/panel/es_panel.sv`
//                and `rtl/switch/`; this file only says which package pin is
//                which signal.  That is deliberate: a board file that decodes
//                anything is a board file that can disagree with the next one.
//
//                Clocking
//                --------
//                CLOCK_50 is the 50 MHz core clock; KEY0 releases sampled reset.
//                JP1 must select MII.  RX capture has no asynchronous FIFO, so
//                the existing board CDC limitation still applies.  TX uses a
//                negedge divider whose SDC budget is a board-level estimate, not
//                a general CDC proof.  Hold reset through startup; no new PHY
//                timing guarantee is added here.
//
//                Consoles
//                --------
//                Console 0 is the board's RS-232 port.  Console 1 is brought out
//                on the JP5 expansion header as 3.3 V TTL, so a USB-serial
//                adapter makes it usable.  The two are fully independent; either
//                can be absent and the other keeps working.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_SWITCH_DE2_115_TOP_SV
`define ES_SWITCH_DE2_115_TOP_SV
`default_nettype none
`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`include "console/es_console_defs.sv"
`include "panel/es_panel_defs.sv"
`default_nettype none
module es_switch_de2_115_top #(

  /// Console UART bit rate in bits per second.
  parameter int unsigned UART_BAUD_RATE = 115200,

  /// Console character width; ASCII commands require seven or eight data bits.
  parameter int unsigned UART_DATA_BITS = 8,

  /// Console parity encoding from es_perips_defs.sv.
  parameter int unsigned UART_PARITY = SW_UART_PARITY_NONE,

  /// Number of console stop bits per character.
  parameter int unsigned UART_STOP_BITS = 1,

  /// Console CTS/RTS policy from es_perips_defs.sv.
  parameter int unsigned UART_FLOW_CONTROL = SW_UART_FLOW_NONE
) (
  /// 50 MHz board oscillator and active-low KEY vector; KEY0 releases reset.
  input var logic        CLOCK_50,
  input var logic [3:0]  KEY,
  /// Slide switches: the panel's run-time configuration.
  input var logic [17:0] SW,
  /// Board status LEDs.
  output    logic [8:0]  LEDG,
  output    logic [17:0] LEDR,
  /// Console 0: the board's RS-232 port.  CTS/RTS are active low.
  input var logic UART_RXD, UART_CTS,
  output    logic UART_TXD, UART_RTS,
  /// Console 1 on the JP5 expansion header: 3.3 V TTL, external USB-serial
  /// adapter.  The header is bidirectional, so the two directions are separate
  /// ports here and the pin assignments decide which header pin is which.
  input var logic GPIO_RXD, GPIO_CTS_N,
  output    logic GPIO_TXD, GPIO_RTS_N,
  /// Two fixed 100-Mbit MII PHY interfaces; RX/TX clocks are board-reserved.
  input var logic [3:0] ENET0_RX_DATA,
  input var logic       ENET0_RX_DV, ENET0_RX_ER,
  output    logic [3:0] ENET0_TX_DATA,
  output    logic       ENET0_TX_EN, ENET0_TX_ER, ENET0_TX_CLK,
  output    logic       ENET0_RESET_N, ENET0_MDC,
  inout  tri logic      ENET0_MDIO,
  input var logic       ENET0_INT_N,
  input var logic [3:0] ENET1_RX_DATA,
  input var logic       ENET1_RX_DV, ENET1_RX_ER,
  output    logic [3:0] ENET1_TX_DATA,
  output    logic       ENET1_TX_EN, ENET1_TX_ER, ENET1_TX_CLK,
  output    logic       ENET1_RESET_N, ENET1_MDC,
  inout  tri logic      ENET1_MDIO,
  input var logic       ENET1_INT_N
);
  // --------------------------------------------------------------------------
  // Board configuration and reset sampling
  //
  // The board fixes two 100 Mbit/s ports on the 50 MHz core.  KEY0 is sampled
  // through two registers; this path does not debounce the button or provide a
  // minimum PHY reset hold time.
  // --------------------------------------------------------------------------
  localparam int unsigned NUM_PORTS     = 2;
  localparam int unsigned NUM_CONSOLE   = 2;
  localparam int unsigned CLK_FREQ_HZ   = 50_000_000;
  /// One console per physical connector: the RS-232 port, then the header.
  localparam int unsigned CAM_CAPACITY  = 128 * 4;

  logic key_rst_meta_q, key_rst_sync_q, rst_ni;
  // Cyclone IV powers registers up low, asserting reset until KEY0 synchronizes.
  always_ff @(posedge CLOCK_50) begin
    key_rst_meta_q <= KEY[0];
    key_rst_sync_q <= key_rst_meta_q;
  end
  assign rst_ni = key_rst_sync_q;

  logic [1:0] tx_clk_q;
  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_tx_clk
      // The clock divider is the existing board-only negedge exception.
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

  // --------------------------------------------------------------------------
  // PHY management
  //
  // Port 0 occupies the least-significant packed slice.  The status bytes feed
  // the panel's link / speed / duplex lamps and the console's queries; they do
  // not gate the datapath, so a management fault shows up as a lamp rather than
  // as silently disabled traffic.
  // --------------------------------------------------------------------------
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
      es_perips_phy_88e1111 #(
        .CLK_FREQ_HZ (CLK_FREQ_HZ)
      ) u_phy (
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

  // --------------------------------------------------------------------------
  // Switch
  //
  // `link_up_i` is the administrative enable.  A port is enabled when the PHY
  // reports a 100 Mbit/s full-duplex link, which is the only mode this board's
  // MII wiring and 50 MHz core can carry at line rate.
  // --------------------------------------------------------------------------
  logic [NUM_CONSOLE*sw_port_w(NUM_PORTS)-1:0] con_stat_port;
  logic [NUM_CONSOLE*4-1:0]                    con_stat_id;
  logic [NUM_CONSOLE*32-1:0]                   con_stat_data;
  logic                                        cam_rd_req;
  logic [31:0]                                 cam_rd_index;
  logic                                        cam_rd_valid;
  logic [127:0]                                cam_rd_entry;
  logic [31:0]                                 cam_entries;
  logic [32*SW_STAT_COUNT-1:0]                 stat_agg;
  logic [1:0]                                  cfg_flood_mode;
  logic                                        cfg_learning_en;
  logic                                        cfg_ovr;

  logic [NUM_PORTS-1:0]   led_link, led_act, led_duplex, led_fault;
  logic [NUM_PORTS*2-1:0] led_speed;
  logic [15:0]            led_stat;

  es_switch_mii #(
    .NUM_PORTS     (NUM_PORTS),
    .CLK_FREQ_HZ   (CLK_FREQ_HZ),
    .NUM_CONSOLE   (NUM_CONSOLE),
    .PORT_SPEED    ({NUM_PORTS{2'(SW_SPEED_100M)}}),
    .CAM_SETS      (128),
    .CAM_WAYS      (4)
  ) u_switch (
    .clk_i         (CLOCK_50),
    .rst_ni        (rst_ni),
    .link_up_i     (phy_enabled),
    .mii_rx_dv_i   ({ENET1_RX_DV, ENET0_RX_DV}),
    .mii_rx_er_i   ({ENET1_RX_ER, ENET0_RX_ER}),
    .mii_rxd_i     ({ENET1_RX_DATA, ENET0_RX_DATA}),
    .mii_tx_en_o   ({ENET1_TX_EN, ENET0_TX_EN}),
    .mii_tx_er_o   ({ENET1_TX_ER, ENET0_TX_ER}),
    .mii_txd_o     ({ENET1_TX_DATA, ENET0_TX_DATA}),
    .phy_status_i  (phy_status),
    .stat_port_i   (con_stat_port),
    .stat_id_i     (con_stat_id),
    .stat_data_o   (con_stat_data),
    .cam_rd_req_i  (cam_rd_req),
    .cam_rd_index_i(cam_rd_index),
    .cam_rd_valid_o(cam_rd_valid),
    .cam_rd_entry_o(cam_rd_entry),
    .cam_entries_o (cam_entries),
    .dip_i         (SW[SW_PANEL_DIP_W-1:0]),
    .led_link_o    (led_link),
    .led_act_o     (led_act),
    .led_speed_o   (led_speed),
    .led_duplex_o  (led_duplex),
    .led_fault_o   (led_fault),
    .led_stat_o    (led_stat),
    .stat_o        (stat_agg),
    .cfg_flood_mode_o (cfg_flood_mode),
    .cfg_learning_en_o(cfg_learning_en),
    .cfg_ovr_o     (cfg_ovr)
  );

  // The panel's decoded configuration is read back from the switch rather than
  // re-derived from SW here, so the console can never report a policy the switch
  // is not actually applying.

  // --------------------------------------------------------------------------
  // Consoles
  //
  // Two independent ports.  Console 0 is the RS-232 connector; console 1 is on
  // the JP5 header and is present whenever the adapter is plugged in, which the
  // board cannot detect, so it is simply always present.
  // --------------------------------------------------------------------------
  logic [NUM_CONSOLE-1:0] con_tx, con_rts, con_fault;

  es_console_hub #(
    .NUM_CONSOLE  (NUM_CONSOLE),
    .NUM_PORTS    (NUM_PORTS),
    .CLK_FREQ_HZ  (CLK_FREQ_HZ),
    .UART_BAUD_RATE (UART_BAUD_RATE),
    .UART_DATA_BITS (UART_DATA_BITS),
    .UART_PARITY  (UART_PARITY),
    .UART_STOP_BITS (UART_STOP_BITS),
    .UART_FLOW_CONTROL (UART_FLOW_CONTROL),
    .CAM_CAPACITY (CAM_CAPACITY),
    .MAC_IF       (int'(SW_MAC_IF_MII))
  ) u_console (
    .clk_i          (CLOCK_50),
    .rst_ni         ({2{rst_ni}}),
    .present_i      (2'b11),
    .rx_i           ({GPIO_RXD, UART_RXD}),
    .cts_ni         ({GPIO_CTS_N, UART_CTS}),
    .tx_o           (con_tx),
    .rts_no         (con_rts),
    .fault_o        (con_fault),
    .stat_agg_i     (stat_agg),
    .link_up_i      (phy_enabled),
    .phy_status_i   (phy_status),
    .cam_entries_i  (cam_entries),
    .cfg_flood_mode_i(cfg_flood_mode),
    .cfg_learning_en_i(cfg_learning_en),
    .cfg_ovr_i      (cfg_ovr),
    .stat_port_o    (con_stat_port),
    .stat_id_o      (con_stat_id),
    .stat_data_i    (con_stat_data),
    .cam_rd_req_o   (cam_rd_req),
    .cam_rd_index_o (cam_rd_index),
    .cam_rd_valid_i (cam_rd_valid),
    .cam_rd_entry_i (cam_rd_entry)
  );

  assign UART_TXD    = con_tx[0];
  assign UART_RTS    = con_rts[0];
  assign GPIO_TXD    = con_tx[1];
  assign GPIO_RTS_N  = con_rts[1];

  // --------------------------------------------------------------------------
  // Front panel
  //
  // Only the mapping lives here.  Every lamp below is already a decision made
  // in the panel; this is the board saying which pin lights it.
  // --------------------------------------------------------------------------

  assign LEDG = {
    led_stat[SW_PANEL_LED_CAM_FULL],   // CAM full
    led_fault[1],                      // port 1 fault
    led_fault[0],                      // port 0 fault
    led_duplex[1],
    led_duplex[0],
    led_act[1],
    led_act[0],
    led_link[1],
    led_link[0]
  };

  assign LEDR = {
    led_stat[SW_PANEL_LED_RX_ERROR],   // [17] a receive error counter is non-zero
    con_fault[1],                      // [16] console 1: invalid input seen
    con_fault[0],                      // [15] console 0: invalid input seen
    led_stat[SW_PANEL_LED_HEARTBEAT],  // [14] the panel is running
    led_stat[SW_PANEL_LED_FLUSH],      // [13]
    led_stat[SW_PANEL_LED_CFG_OVR],    // [12]
    led_stat[SW_PANEL_LED_LEARN],      // [11]
    led_stat[SW_PANEL_LED_FLOOD0],     // [10]
    led_stat[SW_PANEL_LED_ANY_LINK],   // [9]
    led_stat[SW_PANEL_LED_CAM_USED],   // [8]
    led_stat[SW_PANEL_LED_CAM_BAR +: 4],  // [7:4] utilisation bar
    led_speed[3:2],                    // [3:2] port 1 rate
    led_speed[1:0]                     // [1:0] port 0 rate
  };

  // ---- deliberate dummy consumers ------------------------------------------
  // Physical pins this build has no logic for, recorded explicitly so that
  // "nothing uses this" stays a decision instead of a dangling input.  KEY[3:1]
  // are the three buttons this board does not use; SW[17:8] are the surplus
  // slide switches above the panel's eight; the PHY interrupt pins are wired to
  // the FPGA but no management path consumes them.
  logic unused_board;
  assign unused_board = ^{KEY[3:1], SW[17:SW_PANEL_DIP_W],
                          ENET0_INT_N, ENET1_INT_N};

endmodule : es_switch_de2_115_top

// Hand the nettype default back.  A file that leaves it `none` changes the
// meaning of every name compiled after it, in a file that has nothing to do
// with the change that caused the breakage.
`default_nettype wire

`endif  // ES_SWITCH_DE2_115_TOP_SV
