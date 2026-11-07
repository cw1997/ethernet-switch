// ============================================================================
//  File        : es_switch_vivado_top.sv
//  Description : Eight-port, fixed 100 Mbit/s MII board template for Vivado.
//                Keeps the switch's control and statistics buses inside the
//                FPGA; the physical pin list is limited to 138 port bits.
//
//                Clock and frame contract:
//                  * The core runs directly from a 50 MHz board clock. Each
//                    octet occupies four core clocks, each nibble two clocks.
//                  * RX_DV opens the first low-nibble window. The RX stream
//                    starts at the destination MAC and includes the FCS;
//                    physical PHY preamble/SFD removal is still required.
//                  * The core already emits TX preamble, SFD and FCS. An
//                    external adapter must preserve these and the frame gap.
//
//                The RX_CLK/TX_CLK inputs are reserved, not capture clocks.
//                Direct data wiring below assumes the synchronous es_switch_mii
//                contract; it provides no CDC or physical MII timing closure.
//                A real board needs per-port PHY clock adaptation, PHY reset
//                timing and management before this template can be used.
//
//                Port p occupies data bits [4*p +: 4] and status bit p. The
//                fixed eight-port pin ranges, NUM_PORTS, XDC templates and
//                board regression must change together when resizing it.
//
//  Language    : SystemVerilog; no vendor primitives or power-on initial block.
// ============================================================================
`timescale 1ns/1ps
`ifndef ES_SWITCH_VIVADO_TOP_SV
`define ES_SWITCH_VIVADO_TOP_SV
`default_nettype none

// Shared speed encodings and the statistics layout remain identical to the
// rtl/ wrappers. Explicit input var logic avoids the implicit-net error seen
// in Vivado 2026.1 under default_nettype none, retaining the four-state type.
`include "es_defs.sv"
`include "switch/es_switch_defs.sv"
`include "console/es_console_defs.sv"
`default_nettype none

module es_switch_vivado_top (
  // ---- board clock and mechanical reset ------------------------------------
  input var logic clk_i,  ///< 50 MHz; always running during reset
  input var logic rst_button_ni,  ///< asynchronous, active-low button

  // ---- PHY-supplied clocks (reserved for future clock-domain adapters) ------
  input var logic [7:0] mii_rx_clk_i,  ///< PHY RX clocks; currently unused
  input var logic [7:0] mii_tx_clk_i,  ///< PHY TX clocks, not FPGA outputs

  // ---- synchronous MII model pins ------------------------------------------
  input var logic [7:0] mii_rx_dv_i,  ///< valid for whole octets in this model
  input var logic [7:0] mii_rx_er_i,  ///< per-port receive error indication
  input var logic [31:0] mii_rxd_i,  ///< low nibble first, port 0 in [3:0]
  output    logic [7:0] mii_tx_en_o,  ///< per-port transmit frame enable
  output    logic [7:0] mii_tx_er_o,  ///< held low: adapter has no TX error source
  output    logic [31:0] mii_txd_o,  ///< port 7 in [31:28], low nibble first

  // ---- PHY reset and unmanaged MDIO ----------------------------------------
  output    logic [7:0] phy_reset_no,  ///< follows synchronized button reset
  output    logic [7:0] phy_mdc_o,  ///< idle low; no management transactions
  // MDIO needs an explicit net kind under default_nettype none in Vivado.
  inout  tri logic [7:0] phy_mdio_io  ///< released; requires external pull-ups
);
  // ---- board-fixed configuration -------------------------------------------
  // At 50 MHz / 100 Mbit/s, sw_byte_period is 4. Its even half-period is
  // required by es_switch_mii; these settings do not support PHY speed negotiation.
  localparam int unsigned NUM_PORTS   = 8;
  localparam int unsigned CLK_FREQ_HZ = 50_000_000;

  // ---- reset sampling -------------------------------------------------------
  // No power-on initialization is assumed. Hold the button low across at
  // least three rising clock edges after configuration, then release it.
  // These sampling flops deliberately have no reset: resetting them from
  // the asynchronous button would introduce an asynchronous reset domain.
  // ASYNC_REG identifies the sampling chain to Vivado; it does not debounce
  // the button. On release the second stage rises on sample two, and the core
  // sees that new level on the following edge because all state uses NBA.
  (* ASYNC_REG = "TRUE" *)logic rst_meta_q;
  (* ASYNC_REG = "TRUE" *)logic rst_sync_q;
  logic rst_ni;
  always_ff @(posedge clk_i) begin
    rst_meta_q <= rst_button_ni;
    rst_sync_q <= rst_meta_q;
  end
  assign rst_ni = rst_sync_q;

  // ---- PHY reset and management defaults -----------------------------------
  // All PHYs follow the same synchronous reset. No minimum reset pulse or
  // oscillator-stabilization delay is added; a real PHY may require both.
  assign phy_reset_no = {NUM_PORTS{rst_ni}};
  assign phy_mdc_o = '0;
  // No MDIO controller: external board pull-ups are required on every line.
  // Keeping the FPGA driver released allows the PHY's straps/defaults to act,
  // but does not guarantee that those defaults select 100 Mbit/s full duplex.
  assign phy_mdio_io = {NUM_PORTS{1'bz}};

  // ---- switch datapath and fixed control policy -----------------------------
  // The aggregate statistics bus and the panel buses stay internal. Making them
  // physical pins would exhaust the package: this template uses 138 of them for
  // the PHY interfaces alone.
  logic [32*SW_STAT_COUNT-1:0] stat;
  // Panel lamps are not brought out by this template; they are reduced below
  // rather than left dangling, so "nothing shows this" stays an explicit
  // decision.
  logic [7:0]   led_link, led_act, led_duplex, led_fault;
  logic [15:0]  led_speed;
  logic [15:0]  led_stat;
  logic [1:0]   cfg_flood_mode;
  // Console-facing outputs this template does not use: it has no console.
  logic [31:0]  unused_stat_data;
  logic         unused_cam_valid;
  logic [127:0] unused_cam_entry;
  logic [31:0]  unused_cam_count;
  logic         cfg_learning_en, cfg_ovr;

  es_switch_mii #(
    .NUM_PORTS   (NUM_PORTS),
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    // Each packed speed field is exactly two bits; this cast represents the
    // enum in the replication, rather than truncating an arithmetic result.
    .PORT_SPEED ({NUM_PORTS{2'(SW_SPEED_100M)}})
  ) u_switch (
    .clk_i         (clk_i),
    .rst_ni        (rst_ni),
    // Ports are administratively enabled without reading PHY link status: this
    // template has no management controller, so there is nothing to ask.
    .link_up_i     ({NUM_PORTS{1'b1}}),
    .mii_rx_dv_i   (mii_rx_dv_i),
    .mii_rx_er_i   (mii_rx_er_i),
    .mii_rxd_i     (mii_rxd_i),
    .mii_tx_en_o   (mii_tx_en_o),
    .mii_tx_er_o   (mii_tx_er_o),
    .mii_txd_o     (mii_txd_o),
    .phy_status_i  ('0),
    // No console in this template, so its read ports are held idle and the
    // per-port statistics are simply not read - the aggregate bus below is the
    // only observability it offers.
    .stat_port_i   ('0),
    .stat_id_i     ('0),
    .stat_data_o   (unused_stat_data),
    .cam_rd_req_i  (1'b0),
    .cam_rd_index_i(32'd0),
    .cam_rd_valid_o(unused_cam_valid),
    .cam_rd_entry_o(unused_cam_entry),
    .cam_entries_o (unused_cam_count),
    // All board switches low: the panel then reports "no override", and the
    // elaboration-time FLOOD_MODE / LEARNING_EN defaults apply unchanged.
    .dip_i         ('0),
    .led_link_o    (led_link),
    .led_act_o     (led_act),
    .led_speed_o   (led_speed),
    .led_duplex_o  (led_duplex),
    .led_fault_o   (led_fault),
    .led_stat_o    (led_stat),
    .cfg_flood_mode_o (cfg_flood_mode),
    .cfg_learning_en_o(cfg_learning_en),
    .cfg_ovr_o     (cfg_ovr),
    .stat_o        (stat)
  );

  // ---- deliberate dummy consumers ------------------------------------------
  // The house unused_* pattern records intentionally unobserved signals
  // without lint waivers. These reductions add neither a clock monitor nor
  // synchronizers; neither reserved PHY clock currently clocks any logic.
  logic unused_phy;
  logic unused_stat;
  logic unused_panel;
  assign unused_phy   = ^{mii_rx_clk_i, mii_tx_clk_i, phy_mdio_io};
  assign unused_stat  = ^stat;
  assign unused_panel = ^{led_link, led_act, led_speed, led_duplex, led_fault,
                          led_stat, cfg_flood_mode, cfg_learning_en, cfg_ovr,
                          unused_stat_data, unused_cam_valid, unused_cam_entry,
                          unused_cam_count};
endmodule

// Restore the compilation-unit default so this board file cannot turn an
// unrelated module's implicit connection into an error merely by file order.
`default_nettype wire
`endif  // ES_SWITCH_VIVADO_TOP_SV

