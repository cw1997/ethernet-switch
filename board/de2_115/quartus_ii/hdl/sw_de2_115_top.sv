// ============================================================================
//  File        : sw_de2_115_top.sv
//  Description : Board shell for the Terasic DE2-115: wires the interface
//                agnostic switch (via the MII front-end wrapper
//                `sw_switch_mii`) to the board's two Marvell 88E1111 PHYs,
//                the 50 MHz oscillator, the pushbuttons and the LEDs.
//
//                DE2-115 facts this shell is built on:
//                  * The PHYs are wired with four data lines per direction and
//                    JP1 selects RGMII (default) or MII.  This shell needs
//                    **JP1 in the MII position** and runs both ports at
//                    100BASE-TX; the board cannot do full 8-bit GMII, and
//                    RGMII would need a DDR adapter the RTL does not have.
//                  * MII wants a 25 MHz TX_CLK per port.  The core clock is
//                    the 50 MHz oscillator directly - no PLL, no vendor
//                    primitives anywhere in this shell - and TX_CLK is a
//                    negedge toggle register, half a clock period away from
//                    the posedge-domain TX data edges.
//                  * There is no MDIO management: MDC idles low and the PHYs
//                    keep their power-on configuration (JP1-strapped MII mode,
//                    autonegotiation enabled), so every port settles on
//                    100 Mbit/s with any modern partner.
//
//                Port names are the DE2-115 schematic names, not the rtl/
//                `<name>_i` / `<name>_o` convention, so that the pin
//                assignments in ethernet_switch.qsf map 1:1 onto the
//                Terasic pin tables.  Everything inside the module follows
//                the house style (AGENTS.md).
//
//                This file is pure RTL on purpose, so that `make lint`,
//                `make rtl` and `make synth` can elaborate it alongside the
//                three rtl/ wrappers.
//
//                Known limitation (the same one the rtl/ README states for
//                any board shell): the core is single-clock with no CDC, and
//                the PHY drives its RX pins from its own RX_CLK.  At
//                100 Mbit/s each 4-bit nibble lasts 40 ns and this shell
//                samples at 50 MHz, which works in practice but has no
//                formal timing closure to the PHY clock.  An asynchronous
//                FIFO per port is the fix if a target ever needs it.
// ============================================================================

`timescale 1ns/1ps

`ifndef SW_DE2_115_TOP_SV
`define SW_DE2_115_TOP_SV

`default_nettype none

`include "sw_defs.sv"

module sw_de2_115_top (
  // ---- board clock, buttons, LEDs (DE2-115 silkscreen names) ---------------
  input  logic        CLOCK_50,        ///< 50 MHz board oscillator
  input  logic [1:0]  KEY,             ///< active-low buttons: [0] reset, [1] CAM flush
  output logic [1:0]  LEDG,            ///< green LEDs: [0] heartbeat, [1] CAM activity
  output logic [1:0]  LEDR,            ///< red LEDs:   [0] RX activity, [1] TX activity

  // ---- ENET0 MII front-end (88E1111 #0, JP1 in MII position) ---------------
  input  logic [3:0]  ENET0_RX_DATA,   ///< RXD[3:0], driven on the PHY's RX_CLK
  input  logic        ENET0_RX_DV,     ///< RX_DV
  input  logic        ENET0_RX_ER,     ///< RX_ER
  output logic [3:0]  ENET0_TX_DATA,   ///< TXD[3:0], latched by the PHY on TX_CLK
  output logic        ENET0_TX_EN,     ///< TX_EN
  output logic        ENET0_TX_ER,     ///< TX_ER
  output logic        ENET0_TX_CLK,    ///< 25 Mbit/s MII transmit clock (100BASE-TX)
  output logic        ENET0_RESET_N,   ///< PHY reset, active low
  output logic        ENET0_MDC,       ///< tied low: no MDIO management
  input  logic        ENET0_MDIO,      ///< unused by this shell
  input  logic        ENET0_INT_N,     ///< unused by this shell

  // ---- ENET1 MII front-end (88E1111 #1) ------------------------------------
  input  logic [3:0]  ENET1_RX_DATA,
  input  logic        ENET1_RX_DV,
  input  logic        ENET1_RX_ER,
  output logic [3:0]  ENET1_TX_DATA,
  output logic        ENET1_TX_EN,
  output logic        ENET1_TX_ER,
  output logic        ENET1_TX_CLK,
  output logic        ENET1_RESET_N,
  output logic        ENET1_MDC,
  input  logic        ENET1_MDIO,
  input  logic        ENET1_INT_N
);

  // ---- board-fixed configuration ---------------------------------------------
  // At 50 MHz the core's sw_byte_period(50 MHz, 100M) is 4 - even and >= 2,
  // exactly what sw_mii's elaboration check requires - and the same call
  // yields 40 for 10 Mbit/s, so a speed-switching shell needs no core change.
  localparam int unsigned NUM_PORTS   = 2;
  localparam int unsigned CLK_FREQ_HZ = 50_000_000;

  // ---- reset -----------------------------------------------------------------
  // KEY[0] is an asynchronous mechanical button.  Two flip-flops turn it into
  // a clock-synchronous active-low reset for the core; the core samples
  // rst_ni on posedge only.  The synchronizer has no reset on purpose: Cyclone
  // IV registers power up to 0, so the reset is asserted from configuration
  // time and released as soon as the idle-high button has been sampled twice.
  logic key_rst_meta_q;
  logic key_rst_sync_q;
  logic rst_ni;

  always_ff @(posedge CLOCK_50) begin
    key_rst_meta_q <= KEY[0];
    key_rst_sync_q <= key_rst_meta_q;
  end
  assign rst_ni = key_rst_sync_q;

  // ---- CAM flush (KEY[1]) ------------------------------------------------------
  // One pulse per press.  The button is active low, so a press is the falling
  // edge of the synchronized key; pulsing instead of holding the flush level
  // keeps the MAC table semantics independent of how long the button is down.
  logic key_flush_meta_q;
  logic key_flush_sync_q;
  logic key_flush_prev_q;
  logic cam_flush;

  always_ff @(posedge CLOCK_50) begin
    if (!rst_ni) begin
      key_flush_meta_q <= 1'b1;   // idle (unpressed) value of an active-low key
      key_flush_sync_q <= 1'b1;
      key_flush_prev_q <= 1'b1;
    end else begin
      key_flush_meta_q <= KEY[1];
      key_flush_sync_q <= key_flush_meta_q;
      key_flush_prev_q <= key_flush_sync_q;
    end
  end
  assign cam_flush = ~key_flush_sync_q & key_flush_prev_q;

  // ---- MII transmit clocks ------------------------------------------------------
  // MII wants a 25 MHz TX_CLK per port at 100BASE-TX.  A toggle flip-flop on
  // the *negedge* of CLOCK_50 produces it: 50% duty, with its edges half a
  // 20 ns period away from the posedge-domain TX data edges.  That offset is
  // phase-independent - whatever cycle the TX nibbles change on, they always
  // sit 10 ns before one TX_CLK edge and 10 ns after the previous one - which
  // is exactly why the divider clocks on negedge: a posedge toggle would land
  // its rising edges either 20 ns from the data edges or *on* them, depending
  // on the parity of the datapath's reset phase.
  //
  // The 10/10 ns split is a deliberate shave against IEEE 802.3 Clause 22,
  // which asks the MAC for 15 ns of setup: the spec number exists so that any
  // compliant MAC works with any compliant PHY, while this shell only has to
  // work with the 88E1111 on this board.  Guaranteeing 15 ns from a pure-RTL
  // divide-by-two is impossible without knowing the datapath's data phase;
  // de2_115.sdc spends the 10 ns as ">= 5 ns setup at the pin, <= 5 ns of
  // routing skew" so TimeQuest enforces the budget instead of trusting it.
  //
  // This is the one deliberate deviation from the rtl/ rule that state uses
  // always_ff @(posedge clk_i): a clock divider is not data-path state, its
  // phase must not be resynchronised into the data domain, and resetting it
  // to a known phase is what makes the divider restart cleanly with the
  // core.  It exists only in board/ shells; do not copy it into rtl/.
  logic [NUM_PORTS-1:0] tx_clk_q;

  genvar g;
  generate
    for (g = 0; g < NUM_PORTS; g++) begin : g_tx_clk
      always_ff @(negedge CLOCK_50) begin
        if (!rst_ni) begin
          tx_clk_q[g] <= 1'b0;
        end else begin
          tx_clk_q[g] <= ~tx_clk_q[g];
        end
      end
    end
  endgenerate

  // ---- PHY resets and MDIO -------------------------------------------------------
  // The PHYs are held in reset together with the core and released one clock
  // after it, from a clean flopped net.  MDC idles low for both ports: with no
  // MDIO management the 88E1111 keeps its power-on defaults, which is also
  // why link_up_i below is tied high rather than driven from a link monitor.
  logic phy_rst_n_q;

  always_ff @(posedge CLOCK_50) begin
    if (!rst_ni) begin
      phy_rst_n_q <= 1'b0;
    end else begin
      phy_rst_n_q <= 1'b1;
    end
  end

  assign ENET0_RESET_N = phy_rst_n_q;
  assign ENET1_RESET_N = phy_rst_n_q;
  assign ENET0_MDC     = 1'b0;
  assign ENET1_MDC     = 1'b0;

  // ---- the switch -----------------------------------------------------------------
  // Both ports pinned to 100 Mbit/s.  The size parameters stay at the rtl/
  // defaults: RX/TX_FIFO_DEPTH 256 >= the 190 beats a maximum-length frame
  // needs, which is the only sizing rule the core enforces.
  logic [NUM_PORTS-1:0]   mii_tx_en;
  logic [NUM_PORTS-1:0]   mii_tx_er;
  logic [NUM_PORTS*4-1:0] mii_txd;
  logic [32*SW_STAT_COUNT-1:0] stat;

  sw_switch_mii #(
    .NUM_PORTS   (NUM_PORTS),
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    // Port p occupies bits [2*p +: 2] of PORT_SPEED; port 0 is the low half of
    // the concatenation.  The size casts keep the enum legal inside the
    // replication (an enum may not appear in a concat uncast).
    .PORT_SPEED  ({NUM_PORTS{2'(SW_SPEED_100M)}})
  ) u_switch (
    .clk_i         (CLOCK_50),
    .rst_ni        (rst_ni),
    .link_up_i     ({NUM_PORTS{1'b1}}),
    .flood_mode_i  (2'd1),
    .learning_en_i (1'b1),
    .cfg_ovr_i     (1'b0),
    .cam_flush_i   (cam_flush),
    .mii_rx_dv_i   ({ENET1_RX_DV,   ENET0_RX_DV}),
    .mii_rx_er_i   ({ENET1_RX_ER,   ENET0_RX_ER}),
    .mii_rxd_i     ({ENET1_RX_DATA, ENET0_RX_DATA}),
    .mii_tx_en_o   (mii_tx_en),
    .mii_tx_er_o   (mii_tx_er),
    .mii_txd_o     (mii_txd),
    .stat_o        (stat)
  );

  assign {ENET1_TX_EN,   ENET0_TX_EN}   = mii_tx_en;
  assign {ENET1_TX_ER,   ENET0_TX_ER}   = mii_tx_er;
  assign {ENET1_TX_DATA, ENET0_TX_DATA} = mii_txd;
  assign {ENET1_TX_CLK,  ENET0_TX_CLK}  = tx_clk_q;

  // ---- LEDs -------------------------------------------------------------------------
  // Bit i of stat_fold toggles whenever counter i of the statistics bus
  // changes, so OR-ing a few of them gives activity glow without extra state:
  //   LEDR[0] RX traffic, LEDR[1] TX traffic, LEDG[1] CAM lookups,
  //   LEDG[0] a ~1.5 Hz heartbeat (bit 24 of a free-running counter; the count
  //   is a power of two wide, so wrapping by overflow is exact - AGENTS.md
  //   3.2).
  logic [SW_STAT_COUNT-1:0] stat_fold;
  logic [24:0]              heartbeat_q;

  generate
    for (g = 0; g < SW_STAT_COUNT; g++) begin : g_stat_fold
      assign stat_fold[g] = ^stat[32*g +: 32];
    end
  endgenerate

  always_ff @(posedge CLOCK_50) begin
    if (!rst_ni) begin
      heartbeat_q <= '0;
    end else begin
      heartbeat_q <= heartbeat_q + 25'(1);
    end
  end

  assign LEDG = {stat_fold[SW_STAT_CAM_HIT] | stat_fold[SW_STAT_CAM_MISS] |
                   stat_fold[SW_STAT_CAM_LEARN],
                 heartbeat_q[24]};
  assign LEDR = {stat_fold[SW_STAT_TX_FRAMES] | stat_fold[SW_STAT_TX_OCTETS],
                 stat_fold[SW_STAT_RX_FRAMES] | stat_fold[SW_STAT_RX_OCTETS]};

  // ---- deliberate dummies -------------------------------------------------------------
  // Every output the switch produces is consumed somewhere, even when the
  // board shell does not display it - the house unused_* pattern.
  logic unused_stat;
  logic unused_mdio;
  logic unused_int_n;

  assign unused_stat  = ^{stat_fold[SW_STAT_RX_FILTERED], stat_fold[SW_STAT_RX_CRC_ERR],
                          stat_fold[SW_STAT_RX_RUNT],     stat_fold[SW_STAT_RX_OVERSIZE],
                          stat_fold[SW_STAT_RX_OVERFLOW], stat_fold[SW_STAT_TX_STALLED],
                          stat_fold[SW_STAT_CAM_FLUSH]};
  assign unused_mdio  = ENET0_MDIO ^ ENET1_MDIO;
  assign unused_int_n = ENET0_INT_N ^ ENET1_INT_N;

endmodule

`default_nettype wire

`endif // SW_DE2_115_TOP_SV
